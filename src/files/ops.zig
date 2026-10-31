//! Copy and move jobs (SPEC.md 5.4): asynchronous, cancellable, with
//! progress and a prompt for name conflicts. Everything goes through GIO.
//!
//! A job is a stack of (source, destination) pairs. Directories are expanded
//! into their children as they are reached, so nothing is scanned up front
//! and the main loop never waits on a big tree. Each file is copied with
//! `g_file_copy_async`, whose progress callback drives the progress bar.

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
    /// `fraction` is of the current file, in 0..1.
    progress: *const fn (data: *anyopaque, text: [:0]const u8, fraction: f64) void,
    /// Called once; the job frees itself right afterwards.
    finished: *const fn (data: *anyopaque, cancelled: bool) void,
};

const Policy = enum { ask, replace_all, skip_all };

const Item = struct {
    src: *gio.File,
    dst: *gio.File,
};

pub const Job = struct {
    allocator: std.mem.Allocator,
    mode: Mode,
    observer: Observer,
    parent: ?*gtk.Window,
    cancellable: *gio.Cancellable,
    stack: std.ArrayList(Item) = .empty,
    /// Source directories to remove once their contents have moved.
    leftover_dirs: std.ArrayList(*gio.File) = .empty,
    policy: Policy = .ask,
    done: usize = 0,
    current: ?Item = null,

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

        // Reverse so the first source is processed first (LIFO stack).
        var i = sources.len;
        while (i > 0) {
            i -= 1;
            const src = sources[i];
            const name = src.getBasename() orelse continue;
            defer glib.free(name);
            try job.stack.append(allocator, .{
                .src = @ptrCast(src.as(gobject.Object).ref()),
                .dst = dest_dir.getChild(name),
            });
        }
        job.schedule();
        return job;
    }

    pub fn cancel(self: *Job) void {
        self.cancellable.cancel();
    }

    fn destroy(self: *Job) void {
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
        const observer = self.observer;
        self.destroy();
        observer.finished(observer.data, cancelled);
    }

    /// Runs the next step from the main loop, so the UI stays responsive.
    fn schedule(self: *Job) void {
        _ = glib.idleAdd(onIdle, self);
    }

    fn onIdle(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Job = @ptrCast(@alignCast(data.?));
        self.step();
        return 0; // one-shot
    }

    fn step(self: *Job) void {
        if (self.cancellable.isCancelled() != 0) return self.finish(true);

        const item = self.stack.pop() orelse return self.finishMoves();
        self.current = item;

        var name_buf: [512]u8 = undefined;
        if (item.src.getBasename()) |name| {
            defer glib.free(name);
            const text = std.fmt.bufPrintSentinel(&name_buf, "{s} {s} ({d} done)", .{
                if (self.mode == .copy) common.tr("Copying") else common.tr("Moving"),
                std.mem.span(name),
                self.done,
            }, 0) catch "";
            self.observer.progress(self.observer.data, text, 0);
        }

        // A move on the same filesystem is a rename: instant, even for trees.
        if (self.mode == .move and self.tryRename(item)) return self.advance();

        const info = item.src.queryInfo("standard::type", .{ .nofollow_symlinks = true }, self.cancellable, null) orelse
            return self.fail(item, "cannot read the source");
        defer info.as(gobject.Object).unref();

        if (info.getFileType() == .directory) {
            self.expandDirectory(item) catch |err| return self.fail(item, @errorName(err));
            return self.advance();
        }
        self.copyFile(item, false);
    }

    /// Moves `item.current` off the slot and queues the next step.
    fn advance(self: *Job) void {
        if (self.current) |item| releaseItem(item);
        self.current = null;
        self.done += 1;
        self.schedule();
    }

    fn tryRename(self: *Job, item: Item) bool {
        _ = self;
        return item.src.move(item.dst, .{}, null, null, null, null) != 0;
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

    fn onProgress(current: i64, total: i64, data: ?*anyopaque) callconv(.c) void {
        const self: *Job = @ptrCast(@alignCast(data.?));
        const fraction: f64 = if (total > 0) @as(f64, @floatFromInt(current)) / @as(f64, @floatFromInt(total)) else 0;
        self.observer.progress(self.observer.data, "", fraction);
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
                return self.copyFile(self.current.?, false);
            }
            dst.as(gobject.Object).unref();
        }
        self.advance();
    }
};

const TestRun = struct {
    loop: *glib.MainLoop,
    cancelled: bool = false,

    fn progress(_: *anyopaque, _: [:0]const u8, _: f64) void {}

    fn finished(data: *anyopaque, cancelled: bool) void {
        const self: *TestRun = @ptrCast(@alignCast(data));
        self.cancelled = cancelled;
        self.loop.quit();
    }
};

fn runJob(mode: Mode, sources: []const *gio.File, dest: *gio.File) !bool {
    var run: TestRun = .{ .loop = glib.MainLoop.new(null, 0) };
    defer run.loop.unref();
    _ = try Job.start(std.testing.allocator, mode, sources, dest, null, .{
        .data = &run,
        .progress = TestRun.progress,
        .finished = TestRun.finished,
    });
    run.loop.run();
    return run.cancelled;
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
