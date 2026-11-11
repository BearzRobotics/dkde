//! Copy and move jobs (SPEC.md 5.4): asynchronous, cancellable, with
//! progress and a prompt for name conflicts. Everything goes through GIO.
//!
//! A job is a stack of (source, destination) pairs. Directories are expanded
//! into their children as they are reached, so nothing is scanned up front
//! and the main loop never waits on a big tree. Large or remote files are
//! copied with `g_file_copy_async`, whose progress callback drives the
//! progress bar. Small local files are copied directly, as many as fit in a
//! few milliseconds per main-loop turn: one turn per file made 10 000 small
//! files take 40 s, mostly waiting for the main loop.

const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

const pure = @import("pure.zig");

const log = std.log.scoped(.ops);

pub const Mode = enum { copy, move };

/// What the job reports to its window. All callbacks run on the main loop.
pub const Observer = struct {
    data: *anyopaque,
    /// Something changed; read `job.status()`. At most every `notify_us`.
    progress: *const fn (data: *anyopaque, job: *Job) void,
    /// Called once with the final numbers; the job frees itself right afterwards.
    finished: *const fn (data: *anyopaque, cancelled: bool, final: Status) void,
};

pub const Phase = enum { counting, working };

/// Where a job is, for a progress display.
pub const Status = struct {
    mode: Mode,
    phase: Phase,
    /// Files (not folders) handled so far, and in all (0: not known, e.g. a
    /// remote source, which is not counted first).
    files_done: u64,
    files_total: u64,
    bytes_done: u64,
    bytes_total: u64,
    /// Microseconds since the job started copying (after counting).
    elapsed_us: i64,
};

/// Between two progress notices, so a fast job does not redraw constantly.
const notify_us = 100_000;

const Policy = enum { ask, replace_all, skip_all };

const Item = struct {
    src: *gio.File,
    dst: *gio.File,
};

pub const Job = struct {
    allocator: std.mem.Allocator,
    mode: Mode,
    /// Null once the window has gone (`detach`).
    observer: ?Observer,
    parent: ?*gtk.Window,
    cancellable: *gio.Cancellable,
    stack: std.ArrayList(Item) = .empty,
    /// Source directories to remove once their contents have moved.
    leftover_dirs: std.ArrayList(*gio.File) = .empty,
    policy: Policy = .ask,
    done: usize = 0,
    current: ?Item = null,
    /// The current item is a small local file, copied without going async.
    current_small: bool = false,
    /// Set while onIdle runs several steps in one main-loop turn.
    batching: bool = false,
    /// A step asked for the next one while batching.
    more: bool = false,
    /// A step ended the job while batching (the value: cancelled or not);
    /// onIdle finishes it once the batch loop has stopped using the job.
    ended: ?bool = null,

    phase: Phase = .working,
    /// Sources still to count (local jobs count files and bytes first, so
    /// progress can say how much is left).
    count_stack: std.ArrayList(*gio.File) = .empty,
    files_done: u64 = 0,
    files_total: u64 = 0,
    bytes_done: u64 = 0,
    bytes_total: u64 = 0,
    /// Size of the file being copied, and how much of it is done.
    current_size: u64 = 0,
    current_bytes: u64 = 0,
    current_is_file: bool = false,
    started_us: i64 = 0,
    last_notice_us: i64 = 0,

    /// Starts a job copying or moving `sources` into the directory `dest_dir`.
    pub fn start(
        allocator: std.mem.Allocator,
        mode: Mode,
        sources: []const *gio.File,
        dest_dir: *gio.File,
        parent: ?*gtk.Window,
        observer: Observer,
    ) !*Job {
        const job = try allocator.create(Job);
        job.* = .{
            .allocator = allocator,
            .mode = mode,
            .observer = observer,
            .parent = parent,
            .cancellable = gio.Cancellable.new(),
        };
        errdefer job.destroy();

        const local = dest_dir.isNative() != 0;
        var all_local = local;
        // Reverse so the first source is processed first (LIFO stack).
        var i = sources.len;
        while (i > 0) {
            i -= 1;
            const src = sources[i];
            const name = src.getBasename() orelse continue;
            defer glib.free(name);
            const dst = dest_dir.getChild(name);
            // A move within one disk is a rename: do it now, it is instant
            // and leaves nothing to count or copy.
            if (mode == .move and local and src.isNative() != 0 and src.equal(dst) == 0 and
                dst.queryExists(null) == 0 and src.move(dst, .{ .no_fallback_for_move = true, .nofollow_symlinks = true }, null, null, null, null) != 0)
            {
                dst.as(gobject.Object).unref();
                job.files_done += 1;
                job.files_total += 1;
                continue;
            }
            if (src.isNative() == 0) all_local = false;
            try job.stack.append(allocator, .{ .src = @ptrCast(src.as(gobject.Object).ref()), .dst = dst });
        }
        // Count first when everything is local; a server would make the
        // count as slow as the copy.
        if (all_local and job.stack.items.len > 0) {
            job.phase = .counting;
            for (job.stack.items) |item| try job.count_stack.append(allocator, @ptrCast(item.src.as(gobject.Object).ref()));
        } else job.started_us = glib.getMonotonicTime();
        job.schedule();
        return job;
    }

    pub fn status(self: *const Job) Status {
        return .{
            .mode = self.mode,
            .phase = self.phase,
            .files_done = self.files_done,
            .files_total = self.files_total,
            .bytes_done = self.bytes_done + self.current_bytes,
            .bytes_total = self.bytes_total,
            .elapsed_us = if (self.started_us == 0) 0 else glib.getMonotonicTime() - self.started_us,
        };
    }

    /// The window is going: keep working, but report to no one.
    pub fn detach(self: *Job) void {
        self.observer = null;
    }

    fn notify(self: *Job, force: bool) void {
        const now = glib.getMonotonicTime();
        if (!force and now - self.last_notice_us < notify_us) return;
        self.last_notice_us = now;
        if (self.observer) |o| o.progress(o.data, self);
    }

    /// Counts one source: a file adds itself, a folder its files (folders
    /// below it are counted in later steps).
    fn countStep(self: *Job) void {
        const file = self.count_stack.pop() orelse {
            self.phase = .working;
            self.started_us = glib.getMonotonicTime();
            self.notify(true);
            return self.schedule();
        };
        defer file.as(gobject.Object).unref();
        const info = file.queryInfo("standard::type,standard::size", .{ .nofollow_symlinks = true }, self.cancellable, null);
        if (info) |fi| {
            defer fi.as(gobject.Object).unref();
            if (fi.getFileType() == .directory) {
                if (file.enumerateChildren("standard::name,standard::type,standard::size", .{ .nofollow_symlinks = true }, self.cancellable, null)) |children| {
                    defer children.as(gobject.Object).unref();
                    while (children.nextFile(self.cancellable, null)) |child| {
                        defer child.as(gobject.Object).unref();
                        if (child.getFileType() == .directory) {
                            self.count_stack.append(self.allocator, file.getChild(child.getName())) catch {};
                        } else {
                            self.files_total += 1;
                            self.bytes_total += @intCast(@max(child.getSize(), 0));
                        }
                    }
                }
            } else {
                self.files_total += 1;
                self.bytes_total += @intCast(@max(fi.getSize(), 0));
            }
        }
        self.notify(false);
        self.schedule();
    }

    pub fn cancel(self: *Job) void {
        self.cancellable.cancel();
    }

    fn destroy(self: *Job) void {
        for (self.count_stack.items) |f| f.as(gobject.Object).unref();
        self.count_stack.deinit(self.allocator);
        for (self.stack.items) |item| releaseItem(item);
        self.stack.deinit(self.allocator);
        for (self.leftover_dirs.items) |d| d.as(gobject.Object).unref();
        self.leftover_dirs.deinit(self.allocator);
        if (self.current) |item| releaseItem(item);
        self.cancellable.as(gobject.Object).unref();
        self.allocator.destroy(self);
    }

    fn releaseItem(item: Item) void {
        item.src.as(gobject.Object).unref();
        item.dst.as(gobject.Object).unref();
    }

    fn finish(self: *Job, cancelled: bool) void {
        if (self.batching) {
            self.ended = cancelled;
            return;
        }
        const observer = self.observer;
        const final = self.status();
        self.destroy();
        if (observer) |o| o.finished(o.data, cancelled, final);
    }

    /// Runs the next step from the main loop, so the UI stays responsive.
    fn schedule(self: *Job) void {
        if (self.batching) {
            self.more = true;
            return;
        }
        _ = glib.idleAdd(onIdle, self);
    }

    /// How long one main-loop turn may spend on quick steps, in microseconds.
    const batch_budget_us = 8000;
    /// Files below this size, on local disks, are copied without going async.
    const small_file = 4 << 20;

    fn onIdle(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Job = @ptrCast(@alignCast(data.?));
        // Run steps until one goes async (a big file, a question) or the
        // time budget is spent, then let the main loop draw and handle input.
        const deadline = glib.getMonotonicTime() + batch_budget_us;
        self.batching = true;
        while (true) {
            self.more = false;
            self.step();
            if (self.ended != null or !self.more) break;
            if (glib.getMonotonicTime() >= deadline) break;
        }
        self.batching = false;
        if (self.ended) |cancelled| {
            self.ended = null;
            self.finish(cancelled);
        } else if (self.more) self.schedule();
        return 0; // one-shot
    }

    fn step(self: *Job) void {
        if (self.cancellable.isCancelled() != 0) return self.finish(true);
        if (self.phase == .counting) return self.countStep();

        const item = self.stack.pop() orelse return self.finishMoves();
        self.current = item;
        self.current_is_file = false;
        self.current_size = 0;
        self.current_bytes = 0;
        self.notify(false);

        // Pasting where the files already are: a copy makes a "(copy)"
        // duplicate like other file managers, a move has nothing to do.
        if (item.src.equal(item.dst) != 0) {
            if (self.mode == .move) return self.advance();
            return self.keepBoth(item);
        }
        self.process(item);
    }

    /// Copies or moves one item whose destination is decided.
    fn process(self: *Job, item: Item) void {
        // A move on the same filesystem is a rename: instant, even for trees.
        const info = item.src.queryInfo("standard::type,standard::size", .{ .nofollow_symlinks = true }, self.cancellable, null) orelse
            return self.fail(item, "cannot read the source");
        defer info.as(gobject.Object).unref();
        self.current_is_file = info.getFileType() != .directory;
        self.current_size = @intCast(@max(info.getSize(), 0));

        if (self.mode == .move and self.tryRename(item)) return self.advance();

        if (info.getFileType() == .directory) {
            // Copying a folder into itself would never end.
            if (item.dst.hasPrefix(item.src) != 0) return self.fail(item, "cannot copy or move a folder into itself");
            self.expandDirectory(item) catch |err| return self.fail(item, @errorName(err));
            return self.advance();
        }
        self.current_small = info.getFileType() == .regular and info.getSize() < small_file and
            item.src.isNative() != 0 and item.dst.isNative() != 0;
        self.copyFile(item, false);
    }

    /// Moves `item.current` off the slot and queues the next step.
    fn advance(self: *Job) void {
        if (self.current) |item| releaseItem(item);
        self.current = null;
        self.done += 1;
        if (self.current_is_file) {
            self.files_done += 1;
            self.bytes_done += self.current_size;
        }
        self.current_is_file = false;
        self.current_size = 0;
        self.current_bytes = 0;
        self.schedule();
    }

    /// A rename only: without no_fallback_for_move, GIO would copy and delete
    /// a whole tree here, blocking the window, when the rename is not possible.
    fn tryRename(self: *Job, item: Item) bool {
        _ = self;
        return item.src.move(item.dst, .{ .no_fallback_for_move = true, .nofollow_symlinks = true }, null, null, null, null) != 0;
    }

    fn expandDirectory(self: *Job, item: Item) !void {
        var err: ?*glib.Error = null;
        if (item.dst.makeDirectory(null, &err) == 0) {
            // Merging into an existing directory is fine.
            const exists = if (err) |e| e.matches(gio.ioErrorQuark(), @backingInt(gio.IOErrorEnum.exists)) != 0 else false;
            if (err) |e| e.free();
            if (!exists) return error.MakeDirectoryFailed;
        }

        const children = item.src.enumerateChildren("standard::name", .{ .nofollow_symlinks = true }, self.cancellable, null) orelse
            return error.ListFailed;
        defer children.as(gobject.Object).unref();
        while (children.nextFile(self.cancellable, null)) |child| {
            defer child.as(gobject.Object).unref();
            const name = child.getName();
            try self.stack.append(self.allocator, .{
                .src = item.src.getChild(name),
                .dst = item.dst.getChild(name),
            });
        }
        if (self.mode == .move) {
            try self.leftover_dirs.append(self.allocator, @ptrCast(item.src.as(gobject.Object).ref()));
        }
    }

    fn copyFile(self: *Job, item: Item, overwrite: bool) void {
        if (!overwrite and item.dst.queryExists(null) != 0) {
            switch (self.policy) {
                .replace_all => return self.copyFile(item, true),
                .skip_all => return self.advance(),
                .ask => return self.askConflict(item),
            }
        }
        if (self.current_small) {
            var err: ?*glib.Error = null;
            if (item.src.copy(item.dst, .{ .overwrite = overwrite, .nofollow_symlinks = true }, self.cancellable, null, null, &err) == 0) {
                defer if (err) |e| e.free();
                const cancelled = if (err) |e| e.matches(gio.ioErrorQuark(), @backingInt(gio.IOErrorEnum.cancelled)) != 0 else false;
                if (cancelled) return self.finish(true);
                return self.fail(item, std.mem.span(if (err) |e| e.f_message orelse "unknown error" else "unknown error"));
            }
            if (self.mode == .move) _ = item.src.delete(null, null);
            return self.advance();
        }
        item.src.copyAsync(
            item.dst,
            .{ .overwrite = overwrite, .nofollow_symlinks = true },
            glib.PRIORITY_DEFAULT,
            self.cancellable,
            onProgress,
            self,
            onCopied,
            self,
        );
    }

    fn onProgress(current: i64, _: i64, data: ?*anyopaque) callconv(.c) void {
        const self: *Job = @ptrCast(@alignCast(data.?));
        self.current_bytes = @intCast(@max(current, 0));
        self.notify(false);
    }

    fn onCopied(_: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Job = @ptrCast(@alignCast(data.?));
        const item = self.current.?;
        var err: ?*glib.Error = null;
        if (item.src.copyFinish(result, &err) == 0) {
            const cancelled = if (err) |e| e.matches(gio.ioErrorQuark(), @backingInt(gio.IOErrorEnum.cancelled)) != 0 else false;
            if (cancelled) {
                if (err) |e| e.free();
                return self.finish(true);
            }
            const message = if (err) |e| e.f_message orelse "unknown error" else "unknown error";
            self.fail(item, std.mem.span(message));
            if (err) |e| e.free();
            return;
        }
        // A move across filesystems is a copy followed by deleting the source.
        if (self.mode == .move) _ = item.src.delete(null, null);
        self.advance();
    }

    /// Reports the error and carries on with the rest of the job.
    fn fail(self: *Job, item: Item, why: []const u8) void {
        const name = item.src.getBasename();
        defer if (name) |n| glib.free(n);
        var buf: [768]u8 = undefined;
        const text = std.fmt.bufPrintSentinel(&buf, "{s}: {s}", .{ if (name) |n| std.mem.span(n) else "?", why }, 0) catch "operation failed";
        log.warn("{s}", .{text});
        common.dialogs.showError(self.parent, common.tr("Could not finish copying or moving"), text);
        self.advance();
    }

    fn finishMoves(self: *Job) void {
        // Children have moved; empty source directories can go, deepest first.
        var i = self.leftover_dirs.items.len;
        while (i > 0) {
            i -= 1;
            _ = self.leftover_dirs.items[i].delete(null, null);
        }
        self.finish(false);
    }

    // ---- conflicts -------------------------------------------------------

    const Answer = enum(c_int) { skip = 0, keep_both = 1, replace = 2, replace_all = 3, skip_all = 4, cancel = 5, _ };

    fn askConflict(self: *Job, item: Item) void {
        const name = item.dst.getBasename() orelse return self.advance();
        defer glib.free(name);
        var buf: [512]u8 = undefined;
        const message = std.fmt.bufPrintSentinel(&buf, "\"{s}\" already exists here", .{std.mem.span(name)}, 0) catch "File already exists";
        common.dialogs.choose(
            self.parent,
            message,
            common.tr("Replace it, keep both files, or skip this one?"),
            &.{ "Skip", "Keep Both", "Replace", "Replace All", "Skip All", "Cancel" },
            5,
            Job,
            onAnswer,
            self,
        );
    }

    fn onAnswer(self: *Job, index: c_int) void {
        const item = self.current.?;
        switch (@as(Answer, @fromBackingInt(@intCast(if (index < 0) 5 else index)))) {
            .skip => self.advance(),
            .skip_all => {
                self.policy = .skip_all;
                self.advance();
            },
            .replace => self.copyFile(item, true),
            .replace_all => {
                self.policy = .replace_all;
                self.copyFile(item, true);
            },
            .keep_both => self.keepBoth(item),
            .cancel, _ => self.finish(true),
        }
    }

    fn keepBoth(self: *Job, item: Item) void {
        const parent = item.dst.getParent() orelse return self.advance();
        defer parent.as(gobject.Object).unref();
        const base = item.dst.getBasename() orelse return self.advance();
        defer glib.free(base);

        var n: u32 = 1;
        while (n < 1000) : (n += 1) {
            const candidate = pure.copyName(self.allocator, std.mem.span(base), n) catch return self.advance();
            defer self.allocator.free(candidate);
            const candidatez = self.allocator.dupeSentinel(u8, candidate, 0) catch return self.advance();
            defer self.allocator.free(candidatez);
            const dst = parent.getChild(candidatez);
            if (dst.queryExists(null) == 0) {
                item.dst.as(gobject.Object).unref();
                self.current = .{ .src = item.src, .dst = dst };
                // Through process, so a folder is copied as a folder.
                return self.process(self.current.?);
            }
            dst.as(gobject.Object).unref();
        }
        self.advance();
    }
};

const TestRun = struct {
    loop: *glib.MainLoop,
    cancelled: bool = false,
    final: ?Status = null,

    fn progress(_: *anyopaque, _: *Job) void {}

    fn finished(data: *anyopaque, cancelled: bool, final: Status) void {
        const self: *TestRun = @ptrCast(@alignCast(data));
        self.cancelled = cancelled;
        self.final = final;
        self.loop.quit();
    }
};

fn runJobStatus(mode: Mode, sources: []const *gio.File, dest: *gio.File) !Status {
    var run: TestRun = .{ .loop = glib.MainLoop.new(null, 0) };
    defer run.loop.unref();
    _ = try Job.start(std.testing.allocator, mode, sources, dest, null, .{
        .data = &run,
        .progress = TestRun.progress,
        .finished = TestRun.finished,
    });
    run.loop.run();
    try std.testing.expect(!run.cancelled);
    return run.final.?;
}

fn runJob(mode: Mode, sources: []const *gio.File, dest: *gio.File) !bool {
    _ = try runJobStatus(mode, sources, dest);
    return false;
}

fn writeFile(dir: []const u8, name: []const u8, content: []const u8) !void {
    const path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/{s}", .{ dir, name }, 0);
    defer std.testing.allocator.free(path);
    if (glib.fileSetContents(path, content.ptr, @intCast(content.len), null) == 0) return error.WriteFailed;
}

fn readFile(dir: []const u8, name: []const u8) ![]u8 {
    const path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/{s}", .{ dir, name }, 0);
    defer std.testing.allocator.free(path);
    var contents: [*]u8 = undefined;
    var length: usize = 0;
    if (glib.fileGetContents(path, &contents, &length, null) == 0) return error.ReadFailed;
    defer glib.free(contents);
    return std.testing.allocator.dupe(u8, contents[0..length]);
}

test "copying a directory tree copies every file and keeps the source" {
    const root = glib.Dir.makeTmp("dkde-ops-XXXXXX", null) orelse return error.NoTmp;
    defer glib.free(root);
    const base = std.mem.span(root);

    const src_path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/src", .{base}, 0);
    defer std.testing.allocator.free(src_path);
    const nested = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/src/inner", .{base}, 0);
    defer std.testing.allocator.free(nested);
    const dest_path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/dest", .{base}, 0);
    defer std.testing.allocator.free(dest_path);
    _ = glib.mkdirWithParents(nested, 0o755);
    _ = glib.mkdirWithParents(dest_path, 0o755);
    try writeFile(src_path, "a.txt", "alpha");
    try writeFile(nested, "b.txt", "beta");

    const src = gio.File.newForPath(src_path);
    defer src.as(gobject.Object).unref();
    const dest = gio.File.newForPath(dest_path);
    defer dest.as(gobject.Object).unref();

    try std.testing.expect(!try runJob(.copy, &.{src}, dest));

    const copied = try readFile(dest_path, "src/inner/b.txt");
    defer std.testing.allocator.free(copied);
    try std.testing.expectEqualStrings("beta", copied);
    const original = try readFile(src_path, "a.txt");
    defer std.testing.allocator.free(original);
    try std.testing.expectEqualStrings("alpha", original);
}

test "moving a directory removes the source" {
    const root = glib.Dir.makeTmp("dkde-ops-XXXXXX", null) orelse return error.NoTmp;
    defer glib.free(root);
    const base = std.mem.span(root);

    const src_path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/src", .{base}, 0);
    defer std.testing.allocator.free(src_path);
    const dest_path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/dest", .{base}, 0);
    defer std.testing.allocator.free(dest_path);
    _ = glib.mkdirWithParents(src_path, 0o755);
    _ = glib.mkdirWithParents(dest_path, 0o755);
    try writeFile(src_path, "a.txt", "alpha");

    const src = gio.File.newForPath(src_path);
    defer src.as(gobject.Object).unref();
    const dest = gio.File.newForPath(dest_path);
    defer dest.as(gobject.Object).unref();

    try std.testing.expect(!try runJob(.move, &.{src}, dest));

    const moved = try readFile(dest_path, "src/a.txt");
    defer std.testing.allocator.free(moved);
    try std.testing.expectEqualStrings("alpha", moved);
    try std.testing.expect(src.queryExists(null) == 0);
}

test "copying into the folder the items are in makes copies instead of asking" {
    const root = glib.Dir.makeTmp("dkde-ops-XXXXXX", null) orelse return error.NoTmp;
    defer glib.free(root);
    const base = std.mem.span(root);

    const sub_path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/sub", .{base}, 0);
    defer std.testing.allocator.free(sub_path);
    _ = glib.mkdirWithParents(sub_path, 0o755);
    try writeFile(base, "a.txt", "alpha");
    try writeFile(sub_path, "b.txt", "beta");

    const dir = gio.File.newForPath(root);
    defer dir.as(gobject.Object).unref();
    const file = dir.getChild("a.txt");
    defer file.as(gobject.Object).unref();
    const sub = dir.getChild("sub");
    defer sub.as(gobject.Object).unref();

    // No parent window: a conflict question here would never be answered.
    try std.testing.expect(!try runJob(.copy, &.{ file, sub }, dir));

    const copy = try readFile(base, "a (copy 1).txt");
    defer std.testing.allocator.free(copy);
    try std.testing.expectEqualStrings("alpha", copy);
    const nested = try readFile(base, "sub (copy 1)/b.txt");
    defer std.testing.allocator.free(nested);
    try std.testing.expectEqualStrings("beta", nested);
    const original = try readFile(base, "a.txt");
    defer std.testing.allocator.free(original);
    try std.testing.expectEqualStrings("alpha", original);
}

test "a local copy counts its files and bytes first and ends with all of them done" {
    const root = glib.Dir.makeTmp("dkde-ops-XXXXXX", null) orelse return error.NoTmp;
    defer glib.free(root);
    const base = std.mem.span(root);
    const src_path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/src/deeper", .{base}, 0);
    defer std.testing.allocator.free(src_path);
    const dest_path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/dest", .{base}, 0);
    defer std.testing.allocator.free(dest_path);
    _ = glib.mkdirWithParents(src_path, 0o755);
    _ = glib.mkdirWithParents(dest_path, 0o755);
    try writeFile(src_path[0 .. src_path.len - "/deeper".len], "a.txt", "12345");
    try writeFile(src_path, "b.txt", "123");

    const dir = gio.File.newForPath(root);
    defer dir.as(gobject.Object).unref();
    const src = dir.getChild("src");
    defer src.as(gobject.Object).unref();
    const dest = gio.File.newForPath(dest_path);
    defer dest.as(gobject.Object).unref();

    const final = try runJobStatus(.copy, &.{src}, dest);
    try std.testing.expectEqual(@as(u64, 2), final.files_total);
    try std.testing.expectEqual(@as(u64, 8), final.bytes_total);
    try std.testing.expectEqual(@as(u64, 2), final.files_done);
    try std.testing.expectEqual(@as(u64, 8), final.bytes_done);
}

test "a move within one disk renames at once" {
    const root = glib.Dir.makeTmp("dkde-ops-XXXXXX", null) orelse return error.NoTmp;
    defer glib.free(root);
    const base = std.mem.span(root);
    const dest_path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/dest", .{base}, 0);
    defer std.testing.allocator.free(dest_path);
    _ = glib.mkdirWithParents(dest_path, 0o755);
    try writeFile(base, "a.txt", "alpha");

    const dir = gio.File.newForPath(root);
    defer dir.as(gobject.Object).unref();
    const file = dir.getChild("a.txt");
    defer file.as(gobject.Object).unref();
    const dest = gio.File.newForPath(dest_path);
    defer dest.as(gobject.Object).unref();

    const final = try runJobStatus(.move, &.{file}, dest);
    try std.testing.expectEqual(@as(u64, 1), final.files_done);
    try std.testing.expect(file.queryExists(null) == 0);
    const moved = try readFile(dest_path, "a.txt");
    defer std.testing.allocator.free(moved);
    try std.testing.expectEqualStrings("alpha", moved);
}
