// SPDX-License-Identifier: GPL-2.0-or-later
//! Searching for files by name (SPEC.md 5.4).
//!
//! Plain text matches any part of a name. Text with `*` (any run of characters)
//! or `?` (any one character) is a pattern for the whole name: `*.pdf`,
//! `photo?.jpg`. Case is ignored in every script, and a letter typed as one
//! character matches the same letter stored as letter plus accent mark.
//!
//! `Results` searches a folder and everything below it. It walks with GIO's
//! asynchronous calls, one folder at a time, so the window stays responsive,
//! remote places work, and stopping takes effect at once. Links to folders are
//! listed and never entered, and no folder is read twice, so loops end.

const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");

const allocator = std.heap.c_allocator;
const testing = std.testing;

/// On a result's info: the folder it is in, as shown to the person (relative to
/// the folder searched, empty for that folder itself).
pub const location_attribute = "dkde::location";

/// `text` as it is compared: normalised, case folded, normalised again (folding
/// can pull composed characters apart). Null when it is not UTF-8. The caller
/// frees it with `glib.free`.
fn fold(text: [*:0]const u8) ?[*:0]u8 {
    const normal = glib.utf8Normalize(text, -1, .all_compose) orelse return null;
    defer glib.free(normal);
    const folded = glib.utf8Casefold(normal, -1);
    defer glib.free(folded);
    return glib.utf8Normalize(folded, -1, .all_compose);
}

/// A compiled search.
pub const Matcher = struct {
    needle: [*:0]u8,
    /// Set when the text has wildcards.
    pattern: ?*glib.PatternSpec,

    /// Null for empty text (everything matches), and for text that is not UTF-8.
    pub fn init(text: [*:0]const u8) ?Matcher {
        if (text[0] == 0) return null;
        const needle = fold(text) orelse return null;
        const wild = std.mem.indexOfAny(u8, std.mem.span(needle), "*?") != null;
        return .{ .needle = needle, .pattern = if (wild) glib.PatternSpec.new(needle) else null };
    }

    pub fn deinit(self: Matcher) void {
        if (self.pattern) |p| p.free();
        glib.free(self.needle);
    }

    pub fn matches(self: Matcher, name: [*:0]const u8) bool {
        const folded = fold(name) orelse return false;
        defer glib.free(folded);
        if (self.pattern) |p| return p.matchString(folded) != 0;
        return std.mem.indexOf(u8, std.mem.span(folded), std.mem.span(self.needle)) != null;
    }
};

// ---- searching below a folder ---------------------------------------------------

/// Folders that hold the running system rather than files. They are skipped
/// unless the search starts inside one.
const system_folders = [_][]const u8{ "/proc", "/sys", "/dev", "/run" };

pub const Observer = struct {
    data: *anyopaque,
    /// The list or the state changed.
    changed: *const fn (data: *anyopaque) void,
    /// Called just before (`done` false) and after (`done` true) the list
    /// changes, so a view can keep its place.
    changing: ?*const fn (data: *anyopaque, done: bool) void = null,
};

pub const Results = struct {
    /// What the views show: one GFileInfo per match, with "standard::file" set
    /// as in a folder's list. Owned here; the views hold their own refs.
    store: *gio.ListStore,
    attributes: [:0]u8,
    observer: ?Observer = null,

    /// True from `start` until the walk ends or is stopped.
    running: bool = false,
    /// The walk ended early: the person stopped it.
    stopped: bool = false,
    /// There were more matches than `limit`.
    truncated: bool = false,
    /// Folders below the one searched that could not be read.
    unreadable: usize = 0,
    /// Why the folder searched itself could not be read.
    err: ?*glib.Error = null,
    limit: usize = 10_000,

    root: ?*gio.File = null,
    matcher: ?Matcher = null,
    hidden: bool = false,

    /// Folders still to read; `next_folder` is the first not yet taken.
    queue: std.ArrayList(Pending) = .empty,
    next_folder: usize = 0,
    current: ?Pending = null,
    enumerator: ?*gio.FileEnumerator = null,
    /// Ids of the folders queued, so none is read twice.
    seen: std.StringHashMapUnmanaged(void) = .empty,
    /// Matches not yet in the store (one reference each).
    waiting: std.ArrayList(*gio.FileInfo) = .empty,
    found: usize = 0,
    /// Watches on folders that hold results, so results that go away leave the list.
    watches: std.ArrayList(*gio.FileMonitor) = .empty,
    watching_current: bool = false,

    generation: u32 = 0,
    cancellable: ?*gio.Cancellable = null,
    start_timer: c_uint = 0,
    flush_timer: c_uint = 0,
    pending_ops: usize = 0,
    dead: bool = false,

    const batch_ms = 100;
    const files_per_batch = 256;
    /// Deeper than any real tree: a stop for servers that give folders no id.
    const max_depth = 64;
    /// Watches are a limited system resource.
    const max_watches = 128;

    const Pending = struct { folder: *gio.File, depth: u32 };

    pub fn create(attributes: []const u8) *Results {
        const self = allocator.create(Results) catch @panic("out of memory");
        self.* = .{
            .store = gio.ListStore.new(gio.FileInfo.getGObjectType()),
            .attributes = std.fmt.allocPrintSentinel(allocator, "{s},standard::is-symlink,id::file", .{attributes}, 0) catch @panic("out of memory"),
        };
        return self;
    }

    /// Frees the results once the operations still running have returned.
    pub fn destroy(self: *Results) void {
        self.observer = null;
        // The list is left alone: views being torn down may still be on it.
        self.reset();
        self.queue.deinit(allocator);
        self.seen.deinit(allocator);
        self.waiting.deinit(allocator);
        self.watches.deinit(allocator);
        self.dead = true;
        self.maybeFree();
    }

    fn maybeFree(self: *Results) void {
        if (!self.dead or self.pending_ops > 0) return;
        self.store.as(gobject.Object).unref();
        allocator.free(self.attributes);
        allocator.destroy(self);
    }

    /// Empties the list and searches `root` (a reference is taken) and the
    /// folders below it for `text`, beginning after `delay_ms`, so that typing
    /// does not start a walk for every letter.
    pub fn start(self: *Results, root: *gio.File, text: [*:0]const u8, hidden: bool, delay_ms: c_uint) void {
        self.clear();
        self.matcher = Matcher.init(text) orelse return;
        self.root = @ptrCast(root.as(gobject.Object).ref());
        self.hidden = hidden;
        self.running = true;
        self.cancellable = gio.Cancellable.new();
        if (delay_ms == 0) self.begin() else self.start_timer = glib.timeoutAdd(delay_ms, onStartTimer, self);
        self.notify();
    }

    /// Ends the walk, keeping what it found.
    pub fn stop(self: *Results) void {
        if (!self.running) return;
        self.stopped = true;
        self.endWalk();
        self.flush();
    }

    /// Ends the walk and empties the list.
    pub fn clear(self: *Results) void {
        self.reset();
        self.store.removeAll();
    }

    fn reset(self: *Results) void {
        self.endWalk();
        for (self.waiting.items) |info| info.as(gobject.Object).unref();
        self.waiting.clearRetainingCapacity();
        for (self.watches.items) |m| {
            _ = m.cancel();
            // A queued event must not reach us after this.
            _ = gobject.signalHandlersDisconnectMatched(m.as(gobject.Object), .{ .data = true }, 0, 0, null, null, self);
            m.as(gobject.Object).unref();
        }
        self.watches.clearRetainingCapacity();
        if (self.root) |r| r.as(gobject.Object).unref();
        self.root = null;
        if (self.matcher) |m| m.deinit();
        self.matcher = null;
        if (self.err) |e| e.free();
        self.err = null;
        self.found = 0;
        self.unreadable = 0;
        self.truncated = false;
        self.stopped = false;
    }

    fn endWalk(self: *Results) void {
        // Answers still on their way belong to the old walk.
        self.generation +%= 1;
        self.running = false;
        if (self.cancellable) |c| {
            c.cancel();
            c.as(gobject.Object).unref();
            self.cancellable = null;
        }
        if (self.start_timer != 0) _ = glib.Source.remove(self.start_timer);
        self.start_timer = 0;
        if (self.flush_timer != 0) _ = glib.Source.remove(self.flush_timer);
        self.flush_timer = 0;
        self.closeEnumerator();
        if (self.current) |c| c.folder.as(gobject.Object).unref();
        self.current = null;
        for (self.queue.items[self.next_folder..]) |p| p.folder.as(gobject.Object).unref();
        self.queue.clearRetainingCapacity();
        self.next_folder = 0;
        var ids = self.seen.keyIterator();
        while (ids.next()) |id| allocator.free(id.*);
        self.seen.clearRetainingCapacity();
    }

    fn closeEnumerator(self: *Results) void {
        if (self.enumerator) |e| e.as(gobject.Object).unref();
        self.enumerator = null;
    }

    fn finish(self: *Results) void {
        self.endWalk();
        self.flush();
    }

    fn notify(self: *Results) void {
        if (self.observer) |o| o.changed(o.data);
    }

    fn onStartTimer(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Results = @ptrCast(@alignCast(data.?));
        self.start_timer = 0;
        self.begin();
        return 0;
    }

    fn begin(self: *Results) void {
        const root = self.root orelse return;
        // The folder searched counts as seen, so a bind mount of it is not read again.
        if (root.queryInfo("id::file", .{}, null, null)) |info| {
            defer info.as(gobject.Object).unref();
            _ = self.remember(info);
        }
        self.queue.append(allocator, .{ .folder = @ptrCast(root.as(gobject.Object).ref()), .depth = 0 }) catch {
            root.as(gobject.Object).unref();
            return self.finish();
        };
        self.nextFolder();
    }

    /// False when this folder was queued before.
    fn remember(self: *Results, info: *gio.FileInfo) bool {
        if (info.hasAttribute("id::file") == 0) return true;
        const id = info.getAttributeString("id::file") orelse return true;
        const span = std.mem.span(id);
        if (self.seen.contains(span)) return false;
        const owned = allocator.dupe(u8, span) catch return false;
        self.seen.put(allocator, owned, {}) catch {
            allocator.free(owned);
            return false;
        };
        return true;
    }

    const Op = struct {
        results: *Results,
        generation: u32,

        fn current(op: Op) bool {
            return !op.results.dead and op.generation == op.results.generation;
        }

        /// Frees the operation; returns what it was.
        fn take(data: ?*anyopaque) struct { results: *Results, wanted: bool } {
            const op: *Op = @ptrCast(@alignCast(data.?));
            const results = op.results;
            const wanted = op.current();
            allocator.destroy(op);
            return .{ .results = results, .wanted = wanted };
        }
    };

    /// Call `done` once the operation's callback is finished with `self`.
    fn newOp(self: *Results) ?*Op {
        const op = allocator.create(Op) catch return null;
        op.* = .{ .results = self, .generation = self.generation };
        self.pending_ops += 1;
        return op;
    }

    fn done(self: *Results) void {
        self.pending_ops -= 1;
        self.maybeFree();
    }

    fn nextFolder(self: *Results) void {
        self.closeEnumerator();
        if (self.current) |c| c.folder.as(gobject.Object).unref();
        self.current = null;
        if (self.next_folder >= self.queue.items.len) return self.finish();
        const next = self.queue.items[self.next_folder];
        self.next_folder += 1;
        // Drop the taken entries now and then rather than moving the rest each time.
        if (self.next_folder >= 512 and self.next_folder * 2 >= self.queue.items.len) {
            self.queue.replaceRangeAssumeCapacity(0, self.next_folder, &.{});
            self.next_folder = 0;
        }
        self.current = next;
        self.watching_current = false;
        const op = self.newOp() orelse return self.finish();
        next.folder.enumerateChildrenAsync(self.attributes, .{}, glib.PRIORITY_DEFAULT_IDLE, self.cancellable, onEnumerated, op);
    }

    fn onEnumerated(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const op = Op.take(data);
        const self = op.results;
        defer self.done();
        const folder: *gio.File = @ptrCast(@alignCast(source.?));
        var err: ?*glib.Error = null;
        const enumerator = folder.enumerateChildrenFinish(result, &err);
        if (!op.wanted) {
            if (enumerator) |e| e.as(gobject.Object).unref();
            if (err) |e| e.free();
            return;
        }
        if (enumerator) |e| {
            self.enumerator = e;
            return self.nextBatch();
        }
        if (self.current.?.depth == 0) {
            self.err = err;
        } else {
            self.unreadable += 1;
            if (err) |e| e.free();
        }
        self.nextFolder();
    }

    fn nextBatch(self: *Results) void {
        const enumerator = self.enumerator orelse return;
        const op = self.newOp() orelse return self.finish();
        enumerator.nextFilesAsync(files_per_batch, glib.PRIORITY_DEFAULT_IDLE, self.cancellable, onFiles, op);
    }

    fn onFiles(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const op = Op.take(data);
        const self = op.results;
        defer self.done();
        const enumerator: *gio.FileEnumerator = @ptrCast(@alignCast(source.?));
        var err: ?*glib.Error = null;
        const list = enumerator.nextFilesFinish(result, &err);
        defer if (list) |l| l.free();
        const failed = err != null;
        if (err) |e| e.free();

        var node = list;
        while (node) |n| : (node = n.f_next) {
            const info: *gio.FileInfo = @ptrCast(@alignCast(n.f_data orelse continue));
            if (op.wanted and !self.truncated) self.visit(info) else info.as(gobject.Object).unref();
        }
        if (!op.wanted) return;
        if (self.truncated) return self.finish();
        if (list == null) {
            if (failed) self.unreadable += 1;
            return self.nextFolder();
        }
        self.nextBatch();
    }

    /// Looks at one file of the current folder (takes the reference).
    fn visit(self: *Results, info: *gio.FileInfo) void {
        var keep = false;
        defer if (!keep) info.as(gobject.Object).unref();
        // What the view hides is neither listed nor entered.
        if (!self.hidden and (isSet(info, "standard::is-hidden") or isSet(info, "standard::is-backup"))) return;
        const here = self.current orelse return;
        const child = here.folder.getChild(info.getName());
        defer child.as(gobject.Object).unref();

        if (info.getFileType() == .directory and !isSet(info, "standard::is-symlink") and
            here.depth < max_depth and !self.isSystemFolder(child) and self.remember(info))
        {
            _ = child.as(gobject.Object).ref();
            self.queue.append(allocator, .{ .folder = child, .depth = here.depth + 1 }) catch child.as(gobject.Object).unref();
        }

        if (!self.matcher.?.matches(info.getDisplayName())) return;
        if (self.found >= self.limit) {
            self.truncated = true;
            return;
        }
        info.setAttributeObject("standard::file", child.as(gobject.Object));
        self.setLocation(info, here.folder);
        self.waiting.append(allocator, info) catch return;
        keep = true;
        self.found += 1;
        self.watch(here.folder);
        if (self.flush_timer == 0) self.flush_timer = glib.timeoutAdd(batch_ms, onFlushTimer, self);
    }

    fn isSet(info: *gio.FileInfo, attribute: [*:0]const u8) bool {
        return info.hasAttribute(attribute) != 0 and info.getAttributeBoolean(attribute) != 0;
    }

    fn isSystemFolder(self: *Results, folder: *gio.File) bool {
        const path = folder.getPath() orelse return false;
        defer glib.free(path);
        const root = self.root.?.getPath();
        defer if (root) |r| glib.free(r);
        return skips(if (root) |r| std.mem.span(r) else "", std.mem.span(path));
    }

    fn setLocation(self: *Results, info: *gio.FileInfo, folder: *gio.File) void {
        const relative = self.root.?.getRelativePath(folder) orelse return info.setAttributeString(location_attribute, "");
        defer glib.free(relative);
        // A path is bytes; the view needs text.
        const text = glib.filenameDisplayName(relative);
        defer glib.free(text);
        info.setAttributeString(location_attribute, text);
    }

    fn onFlushTimer(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Results = @ptrCast(@alignCast(data.?));
        self.flush_timer = 0;
        self.flush();
        return 0;
    }

    /// Moves the waiting matches into the store, in one change.
    fn flush(self: *Results) void {
        if (self.waiting.items.len > 0) {
            if (self.observer) |o| if (o.changing) |f| f(o.data, false);
            const objects: [*]*gobject.Object = @ptrCast(self.waiting.items.ptr);
            self.store.splice(self.store.as(gio.ListModel).getNItems(), 0, objects, @intCast(self.waiting.items.len));
            for (self.waiting.items) |info| info.as(gobject.Object).unref();
            self.waiting.clearRetainingCapacity();
            if (self.observer) |o| if (o.changing) |f| f(o.data, true);
        }
        self.notify();
    }

    // ---- keeping the list true ----------------------------------------------

    fn watch(self: *Results, folder: *gio.File) void {
        if (self.watching_current or self.watches.items.len >= max_watches) return;
        self.watching_current = true;
        const monitor = folder.monitorDirectory(.{ .watch_moves = true }, null, null) orelse return;
        self.watches.append(allocator, monitor) catch {
            monitor.as(gobject.Object).unref();
            return;
        };
        _ = gio.FileMonitor.signals.changed.connect(monitor, *Results, &onMonitor, self, .{});
    }

    fn onMonitor(_: *gio.FileMonitor, file: *gio.File, other: ?*gio.File, event: gio.FileMonitorEvent, self: *Results) callconv(.c) void {
        switch (event) {
            .deleted, .moved_out, .unmounted => self.removed(file),
            .renamed => if (other) |o| self.renamed(file, o),
            else => {},
        }
    }

    /// Takes `file`, and anything listed from inside it, out of the list.
    pub fn removed(self: *Results, file: *gio.File) void {
        var i = self.waiting.items.len;
        while (i > 0) {
            i -= 1;
            if (!isAtOrBelow(self.waiting.items[i], file)) continue;
            self.waiting.orderedRemove(i).as(gobject.Object).unref();
            self.found -= 1;
        }
        const model = self.store.as(gio.ListModel);
        var pos = model.getNItems();
        var any = false;
        while (pos > 0) {
            pos -= 1;
            const object: *gobject.Object = @ptrCast(@alignCast(model.getItem(pos) orelse continue));
            defer object.unref();
            if (!isAtOrBelow(@ptrCast(object), file)) continue;
            self.store.remove(pos);
            self.found -= 1;
            any = true;
        }
        if (any) self.notify();
    }

    fn isAtOrBelow(info: *gio.FileInfo, file: *gio.File) bool {
        const object = info.getAttributeObject("standard::file") orelse return false;
        const own: *gio.File = @ptrCast(@alignCast(object));
        return own.equal(file) != 0 or own.hasPrefix(file) != 0;
    }

    /// A listed file has a new name: it stays only if that still matches.
    pub fn renamed(self: *Results, from: *gio.File, to: *gio.File) void {
        const before = self.found;
        self.removed(from);
        if (self.found == before) return; // it was not listed (or has been handled)
        const matcher = self.matcher orelse return;
        const info = to.queryInfo(self.attributes, .{}, null, null) orelse return;
        var keep = false;
        defer if (!keep) info.as(gobject.Object).unref();
        if (!self.hidden and (isSet(info, "standard::is-hidden") or isSet(info, "standard::is-backup"))) return;
        if (!matcher.matches(info.getDisplayName())) return;
        const parent = to.getParent() orelse return;
        defer parent.as(gobject.Object).unref();
        info.setAttributeObject("standard::file", to.as(gobject.Object));
        self.setLocation(info, parent);
        self.waiting.append(allocator, info) catch return;
        keep = true;
        self.found += 1;
        self.flush();
    }
};

fn within(path: []const u8, folder: []const u8) bool {
    if (!std.mem.startsWith(u8, path, folder)) return false;
    return path.len == folder.len or path[folder.len] == '/';
}

/// Whether the walk of `root` leaves out `path`.
fn skips(root: []const u8, path: []const u8) bool {
    for (system_folders) |system| {
        if (std.mem.eql(u8, path, system)) return !within(root, system);
    }
    return false;
}

// ---- tests -----------------------------------------------------------------

fn expectMatch(want: bool, query: [*:0]const u8, name: [*:0]const u8) !void {
    const matcher = Matcher.init(query) orelse return error.NoMatcher;
    defer matcher.deinit();
    testing.expectEqual(want, matcher.matches(name)) catch |e| {
        std.debug.print("'{s}' against '{s}'\n", .{ query, name });
        return e;
    };
}

test "plain text matches any part of a name" {
    try expectMatch(true, "port", "Report 2026.pdf");
    try expectMatch(true, ".PDF", "Report 2026.pdf");
    try expectMatch(false, "reports", "Report 2026.pdf");
    try expectMatch(true, "[1]", "notes [1].txt");
    try expectMatch(false, "[1]", "notes 1.txt");
}

test "wildcards match the whole name" {
    try expectMatch(true, "*.pdf", "Report.PDF");
    try expectMatch(false, "*.pdf", "Report.pdf.part");
    try expectMatch(false, "*.pdf", "pdf");
    try expectMatch(true, "photo?.jpg", "photo1.jpg");
    try expectMatch(true, "photo?.jpg", "Photo\u{e9}.JPG");
    try expectMatch(false, "photo?.jpg", "photo.jpg");
    try expectMatch(false, "photo?.jpg", "photo12.jpg");
    try expectMatch(false, "photo?.jpg", "my photo1.jpg");
    try expectMatch(true, "*photo*", "my photo12.jpg");
    try expectMatch(true, "IMG_*.j*g", "img_0001.jpeg");
    try expectMatch(false, "rep*", "my report");
    try expectMatch(true, "*", "anything");
}

test "case and accents compare alike in any script" {
    try expectMatch(true, "\u{e9}t\u{e9}", "\u{c9}T\u{c9}.txt"); // été / ÉTÉ
    try expectMatch(true, "\u{e9}", "e\u{301}.txt"); // one character against two
    try expectMatch(true, "E\u{301}", "\u{e9}.txt");
    try expectMatch(true, "\u{3b1}\u{3b8}\u{3ae}\u{3bd}\u{3b1}", "\u{391}\u{398}\u{389}\u{39d}\u{391}"); // Greek
    try expectMatch(true, "\u{43c}\u{438}\u{440}", "\u{41c}\u{418}\u{420}.doc"); // Cyrillic
    try expectMatch(true, "strasse", "Stra\u{df}e.txt");
    try expectMatch(false, "e", "\u{e9}.txt"); // an accent still counts
}

test "no search for empty or broken text, and no match for a broken name" {
    try testing.expect(Matcher.init("") == null);
    try testing.expect(Matcher.init("\xff\xfe") == null);
    try expectMatch(false, "a", "a\xff");
}

test "system folders are skipped unless the search starts in one" {
    try testing.expect(skips("/", "/proc"));
    try testing.expect(skips("/", "/run"));
    try testing.expect(skips("/home/a", "/sys"));
    try testing.expect(!skips("/", "/running"));
    try testing.expect(!skips("/", "/home/a/proc"));
    try testing.expect(!skips("/proc", "/proc"));
    try testing.expect(!skips("/run/media/a/stick", "/run/media/a/stick/run"));
}

/// A scratch tree and a main loop for searching it.
const Tree = struct {
    base: [*:0]u8,
    root: *gio.File,
    results: *Results,

    fn init() !Tree {
        const base = glib.Dir.makeTmp("dkde-search-XXXXXX", null) orelse return error.NoTmp;
        return .{ .base = base, .root = gio.File.newForPath(base), .results = Results.create("standard::name,standard::display-name,standard::type,standard::is-hidden,standard::is-backup") };
    }

    fn deinit(self: Tree) void {
        self.results.destroy();
        // Operations that were cancelled answer on the main loop.
        while (glib.MainContext.iteration(null, 0) != 0) {}
        removeAll(self.root);
        self.root.as(gobject.Object).unref();
        glib.free(self.base);
    }

    fn removeAll(file: *gio.File) void {
        if (file.queryFileType(.{ .nofollow_symlinks = true }, null) == .directory) {
            if (file.enumerateChildren("standard::name", .{ .nofollow_symlinks = true }, null, null)) |children| {
                defer children.as(gobject.Object).unref();
                while (children.nextFile(null, null)) |info| {
                    defer info.as(gobject.Object).unref();
                    const child = file.getChild(info.getName());
                    defer child.as(gobject.Object).unref();
                    removeAll(child);
                }
            }
        }
        _ = file.delete(null, null);
    }

    fn at(self: Tree, relative: [*:0]const u8) *gio.File {
        return self.root.getChild(relative);
    }

    fn folder(self: Tree, relative: [*:0]const u8) !void {
        const file = self.at(relative);
        defer file.as(gobject.Object).unref();
        if (file.makeDirectory(null, null) == 0) return error.MakeFailed;
    }

    fn touch(self: Tree, relative: [*:0]const u8) !void {
        const file = self.at(relative);
        defer file.as(gobject.Object).unref();
        const path = file.getPath().?;
        defer glib.free(path);
        if (glib.fileSetContents(path, "", 0, null) == 0) return error.WriteFailed;
    }

    fn link(self: Tree, relative: [*:0]const u8, target: [*:0]const u8) !void {
        const file = self.at(relative);
        defer file.as(gobject.Object).unref();
        if (file.makeSymbolicLink(target, null, null) == 0) return error.LinkFailed;
    }

    const Wait = struct {
        results: *Results,
        want: ?u32,
        loop: *glib.MainLoop,

        fn check(data: ?*anyopaque) callconv(.c) c_int {
            const w: *Wait = @ptrCast(@alignCast(data.?));
            const ready = if (w.want) |n| w.results.store.as(gio.ListModel).getNItems() == n else !w.results.running;
            if (ready) w.loop.quit();
            return 1;
        }

        fn giveUp(data: ?*anyopaque) callconv(.c) c_int {
            const loop: *glib.MainLoop = @ptrCast(@alignCast(data.?));
            loop.quit();
            return 1;
        }
    };

    /// Runs the main loop until the walk ends, or until the list holds `want`.
    fn wait(self: Tree, want: ?u32) !void {
        var w: Wait = .{ .results = self.results, .want = want, .loop = glib.MainLoop.new(null, 0) };
        defer w.loop.unref();
        const poll = glib.timeoutAdd(10, Wait.check, &w);
        const limit = glib.timeoutAdd(10_000, Wait.giveUp, w.loop);
        w.loop.run();
        _ = glib.Source.remove(poll);
        _ = glib.Source.remove(limit);
        if (want) |n| try testing.expectEqual(n, self.results.store.as(gio.ListModel).getNItems()) else try testing.expect(!self.results.running);
    }

    fn run(self: Tree, text: [*:0]const u8, hidden: bool) !void {
        self.results.start(self.root, text, hidden, 0);
        try self.wait(null);
    }

    /// The results as "location/name" lines, sorted.
    fn expect(self: Tree, want: []const []const u8) !void {
        var got: std.ArrayList([]u8) = .empty;
        defer {
            for (got.items) |g| testing.allocator.free(g);
            got.deinit(testing.allocator);
        }
        const model = self.results.store.as(gio.ListModel);
        for (0..model.getNItems()) |i| {
            const object: *gobject.Object = @ptrCast(@alignCast(model.getItem(@intCast(i)).?));
            defer object.unref();
            const info: *gio.FileInfo = @ptrCast(object);
            const where = std.mem.span(info.getAttributeString(location_attribute).?);
            const line = try std.fmt.allocPrint(testing.allocator, "{s}{s}{s}", .{ where, if (where.len > 0) "/" else "", info.getDisplayName() });
            try got.append(testing.allocator, line);
            // Every row's file is where its location says.
            const file: *gio.File = @ptrCast(@alignCast(info.getAttributeObject("standard::file").?));
            const relative = self.root.getRelativePath(file).?;
            defer glib.free(relative);
            try testing.expectEqualStrings(line, std.mem.span(relative));
        }
        std.mem.sort([]u8, got.items, {}, struct {
            fn less(_: void, a: []u8, b: []u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.less);
        try testing.expectEqual(want.len, got.items.len);
        for (want, got.items) |w, g| try testing.expectEqualStrings(w, g);
    }
};

test "a search finds matches in every folder below, with where they are" {
    const tree = try Tree.init();
    defer tree.deinit();
    try tree.folder("a");
    try tree.folder("a/deeper");
    try tree.folder("pdfs");
    try tree.folder(".secret");
    try tree.touch("top.pdf");
    try tree.touch("a/one.PDF");
    try tree.touch("a/deeper/two.pdf");
    try tree.touch("a/deeper/two.txt");
    try tree.touch("pdfs/three.pdf");
    try tree.touch(".secret/four.pdf");
    try tree.touch("a/.five.pdf");

    try tree.run("*.pdf", false);
    try tree.expect(&.{ "a/deeper/two.pdf", "a/one.PDF", "pdfs/three.pdf", "top.pdf" });
    // Folders match too.
    try tree.run("pdf", false);
    try tree.expect(&.{ "a/deeper/two.pdf", "a/one.PDF", "pdfs", "pdfs/three.pdf", "top.pdf" });
    try tree.run("*.pdf", true);
    try tree.expect(&.{ ".secret/four.pdf", "a/.five.pdf", "a/deeper/two.pdf", "a/one.PDF", "pdfs/three.pdf", "top.pdf" });
    try testing.expectEqual(@as(usize, 0), tree.results.unreadable);
    try testing.expect(tree.results.err == null);
}

test "links to folders are listed but not entered, so loops end" {
    const tree = try Tree.init();
    defer tree.deinit();
    try tree.folder("a");
    try tree.touch("a/note.txt");
    try tree.link("a/loop", "..");
    try tree.link("again", "a");
    try tree.run("*", false);
    try tree.expect(&.{ "a", "a/loop", "a/note.txt", "again" });
    try testing.expect(!tree.results.truncated);
}

test "a search stops at its limit, and can be stopped" {
    const tree = try Tree.init();
    defer tree.deinit();
    for (0..30) |i| {
        var buf: [32]u8 = undefined;
        try tree.touch(try std.fmt.bufPrintSentinel(&buf, "file-{d}", .{i}, 0));
    }
    tree.results.limit = 12;
    try tree.run("file", false);
    try testing.expect(tree.results.truncated);
    try testing.expectEqual(@as(u32, 12), tree.results.store.as(gio.ListModel).getNItems());

    tree.results.limit = 100;
    tree.results.start(tree.root, "file", false, 60_000);
    try testing.expect(tree.results.running);
    tree.results.stop();
    try testing.expect(!tree.results.running and tree.results.stopped);
    // A new search forgets the last one.
    try tree.run("file-1", false);
    try testing.expect(!tree.results.truncated and !tree.results.stopped);
    try testing.expectEqual(@as(u32, 11), tree.results.store.as(gio.ListModel).getNItems());

    // Replacing a walk in progress leaves nothing of it behind.
    tree.results.start(tree.root, "file", false, 0);
    _ = glib.MainContext.iteration(null, 0);
    try tree.run("file-2", false);
    try testing.expectEqual(@as(u32, 11), tree.results.store.as(gio.ListModel).getNItems());
}

test "an unreadable folder is counted, and a missing one reported" {
    const tree = try Tree.init();
    defer tree.deinit();
    try tree.folder("closed");
    try tree.touch("open.txt");
    const closed = tree.at("closed");
    defer closed.as(gobject.Object).unref();
    const path = closed.getPath().?;
    defer glib.free(path);
    // Root reads it anyway.
    if (std.c.getuid() != 0) {
        try testing.expectEqual(@as(c_int, 0), std.c.chmod(path, 0));
        defer _ = std.c.chmod(path, 0o700);
        try tree.run("open", false);
        try testing.expectEqual(@as(usize, 1), tree.results.unreadable);
        try tree.expect(&.{"open.txt"});
    }
    const missing = tree.at("nowhere");
    defer missing.as(gobject.Object).unref();
    tree.results.start(missing, "x", false, 0);
    try tree.wait(null);
    try testing.expect(tree.results.err != null);
}

test "results follow files being deleted and renamed" {
    const tree = try Tree.init();
    defer tree.deinit();
    try tree.folder("sub");
    try tree.folder("sub/x-folder");
    try tree.touch("sub/x-folder/x-inside");
    try tree.touch("sub/x-one");
    try tree.touch("sub/x-two");
    try tree.run("x-", false);
    try tree.expect(&.{ "sub/x-folder", "sub/x-folder/x-inside", "sub/x-one", "sub/x-two" });

    // Told directly, as the window does after its own actions.
    const folder = tree.at("sub/x-folder");
    defer folder.as(gobject.Object).unref();
    tree.results.removed(folder);
    try tree.expect(&.{ "sub/x-one", "sub/x-two" });

    // Seen by the watch.
    const one = tree.at("sub/x-one");
    defer one.as(gobject.Object).unref();
    try testing.expect(one.delete(null, null) != 0);
    try tree.wait(1);

    const two = tree.at("sub/x-two");
    defer two.as(gobject.Object).unref();
    const renamed = two.setDisplayName("x-three", null, null).?;
    defer renamed.as(gobject.Object).unref();
    tree.results.renamed(two, renamed);
    try tree.expect(&.{"sub/x-three"});
    // The watch reports the same rename; nothing is listed twice.
    var spins: usize = 0;
    while (spins < 50) : (spins += 1) {
        _ = glib.MainContext.iteration(null, 0);
        glib.usleep(2000);
    }
    try tree.expect(&.{"sub/x-three"});
    // A name that no longer matches leaves the list.
    const gone = renamed.setDisplayName("other", null, null).?;
    defer gone.as(gobject.Object).unref();
    tree.results.renamed(renamed, gone);
    try tree.expect(&.{});
}
