//! The contents of one folder as a list model, kept up to date as files come
//! and go (SPEC.md 5.4).
//!
//! This replaces GtkDirectoryList, which handles every change event by
//! searching all its items for the file and reports every file as its own
//! change. Copying 10 000 files into an open folder kept the window busy for
//! over 40 s after the copy had finished. Here files are kept by name in a hash
//! map, so an event costs O(1), changed files are queried asynchronously, and
//! the visible list is brought up to date at most every `batch_ms`, removing
//! runs and adding everything new in one splice. The list's items are
//! GFileInfo objects that stay the same object while the file is unchanged,
//! so the view keeps its selection and scroll position.

const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");

const allocator = std.heap.c_allocator;

pub const Observer = struct {
    data: *anyopaque,
    /// The first listing of a folder has finished; `folder.err` says whether
    /// it failed (no permission, gone, server dropped).
    loaded: *const fn (data: *anyopaque, folder: *Folder) void,
    /// Called just before (`done` false) and after (`done` true) the list
    /// changes, so a view can keep its place.
    changing: ?*const fn (data: *anyopaque, folder: *Folder, done: bool) void = null,
};

pub const Folder = struct {
    /// What the views show. Owned by the folder; the views hold their own refs.
    store: *gio.ListStore,
    attributes: [:0]const u8,
    observer: ?Observer = null,

    file: ?*gio.File = null,
    /// Bumped on every setFile, so answers for the previous folder are dropped.
    generation: u32 = 0,
    cancellable: ?*gio.Cancellable = null,
    monitor: ?*gio.FileMonitor = null,
    enumerator: ?*gio.FileEnumerator = null,
    loading: bool = false,
    err: ?*glib.Error = null,

    /// The truth: name -> info (one reference each). The store follows it.
    infos: std.StringHashMapUnmanaged(*gio.FileInfo) = .empty,
    /// Names whose info must be fetched again (created or changed).
    stale: std.StringHashMapUnmanaged(void) = .empty,
    query_timer: c_uint = 0,
    sync_timer: c_uint = 0,

    /// Async operations still running; the folder is freed only when none are.
    pending_ops: usize = 0,
    dead: bool = false,

    const batch_ms = 100;
    /// Changed files are queried a little later, so the several events one
    /// write makes (created, changed, done) become one query.
    const query_delay_ms = 50;
    const files_per_batch = 256;

    pub fn create(attributes: [:0]const u8) *Folder {
        const self = allocator.create(Folder) catch @panic("out of memory");
        self.* = .{ .store = gio.ListStore.new(gio.FileInfo.getGObjectType()), .attributes = attributes };
        return self;
    }

    /// Frees the folder once the operations still running have returned.
    pub fn destroy(self: *Folder) void {
        self.stop();
        self.clearInfos();
        self.infos.deinit(allocator);
        self.stale.deinit(allocator);
        self.dead = true;
        self.maybeFree();
    }

    fn maybeFree(self: *Folder) void {
        if (!self.dead or self.pending_ops > 0) return;
        self.store.as(gobject.Object).unref();
        allocator.destroy(self);
    }

    /// Shows the contents of `file` (a reference is taken).
    pub fn setFile(self: *Folder, file: *gio.File) void {
        self.stop();
        self.clearInfos();
        // Empty at once, so the old files never appear under the new path.
        self.store.removeAll();

        self.generation +%= 1;
        self.file = @ptrCast(file.as(gobject.Object).ref());
        self.cancellable = gio.Cancellable.new();
        self.loading = true;

        var err: ?*glib.Error = null;
        self.monitor = file.monitorDirectory(.{ .watch_moves = true }, null, &err);
        if (err) |e| e.free(); // some servers cannot watch; the listing still works
        if (self.monitor) |m| _ = gio.FileMonitor.signals.changed.connect(m, *Folder, &onMonitor, self, .{});

        const op = self.newOp(null) orelse return;
        file.enumerateChildrenAsync(self.attributes, .{}, glib.PRIORITY_DEFAULT, self.cancellable, onEnumerated, op);
    }

    /// Cancels everything about the current folder.
    fn stop(self: *Folder) void {
        if (self.cancellable) |c| {
            c.cancel();
            c.as(gobject.Object).unref();
            self.cancellable = null;
        }
        if (self.monitor) |m| {
            _ = m.cancel();
            m.as(gobject.Object).unref();
            self.monitor = null;
        }
        if (self.enumerator) |e| {
            e.as(gobject.Object).unref();
            self.enumerator = null;
        }
        if (self.file) |f| {
            f.as(gobject.Object).unref();
            self.file = null;
        }
        if (self.err) |e| {
            e.free();
            self.err = null;
        }
        if (self.query_timer != 0) _ = glib.Source.remove(self.query_timer);
        if (self.sync_timer != 0) _ = glib.Source.remove(self.sync_timer);
        self.query_timer = 0;
        self.sync_timer = 0;
        self.loading = false;
    }

    fn clearInfos(self: *Folder) void {
        var it = self.infos.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.as(gobject.Object).unref();
        }
        self.infos.clearRetainingCapacity();
        var names = self.stale.keyIterator();
        while (names.next()) |name| allocator.free(name.*);
        self.stale.clearRetainingCapacity();
    }

    // ---- async operations ------------------------------------------------

    const Op = struct {
        folder: *Folder,
        generation: u32,
        /// For a query: the file's name.
        name: ?[:0]u8,

        /// True when the answer is still wanted.
        fn current(op: *Op) bool {
            return !op.folder.dead and op.generation == op.folder.generation;
        }

        fn done(op: *Op) void {
            const folder = op.folder;
            if (op.name) |n| allocator.free(n);
            allocator.destroy(op);
            folder.pending_ops -= 1;
            folder.maybeFree();
        }
    };

    fn newOp(self: *Folder, name: ?[]const u8) ?*Op {
        const op = allocator.create(Op) catch return null;
        const owned = if (name) |n| allocator.dupeSentinel(u8, n, 0) catch {
            allocator.destroy(op);
            return null;
        } else null;
        op.* = .{ .folder = self, .generation = self.generation, .name = owned };
        self.pending_ops += 1;
        return op;
    }

    fn onEnumerated(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const op: *Op = @ptrCast(@alignCast(data.?));
        defer op.done();
        const file: *gio.File = @ptrCast(@alignCast(source.?));
        var err: ?*glib.Error = null;
        const enumerator = file.enumerateChildrenFinish(result, &err);
        if (!op.current()) {
            if (enumerator) |e| e.as(gobject.Object).unref();
            if (err) |e| e.free();
            return;
        }
        const self = op.folder;
        if (enumerator) |e| {
            self.enumerator = e;
            self.nextBatch();
        } else self.finishLoading(err);
    }

    fn nextBatch(self: *Folder) void {
        const enumerator = self.enumerator orelse return;
        const op = self.newOp(null) orelse return;
        enumerator.nextFilesAsync(files_per_batch, glib.PRIORITY_DEFAULT, self.cancellable, onFiles, op);
    }

    fn onFiles(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const op: *Op = @ptrCast(@alignCast(data.?));
        defer op.done();
        const enumerator: *gio.FileEnumerator = @ptrCast(@alignCast(source.?));
        var err: ?*glib.Error = null;
        const list = enumerator.nextFilesFinish(result, &err);
        defer if (list) |l| l.free();
        if (!op.current()) {
            var node = list;
            while (node) |n| : (node = n.f_next) {
                if (n.f_data) |d| gobject.Object.unref(@ptrCast(@alignCast(d)));
            }
            if (err) |e| e.free();
            return;
        }
        const self = op.folder;
        if (list == null) return self.finishLoading(err);

        var node = list;
        while (node) |n| : (node = n.f_next) {
            const info: *gio.FileInfo = @ptrCast(@alignCast(n.f_data orelse continue));
            self.put(info); // takes the list's reference
        }
        // Show the first files at once; after that, in batches.
        if (self.store.as(gio.ListModel).getNItems() == 0) self.sync() else self.scheduleSync();
        self.nextBatch();
    }

    fn finishLoading(self: *Folder, err: ?*glib.Error) void {
        self.loading = false;
        self.err = err;
        if (self.enumerator) |e| {
            e.as(gobject.Object).unref();
            self.enumerator = null;
        }
        self.sync();
        if (self.observer) |o| o.loaded(o.data, self);
    }

    // ---- live changes ----------------------------------------------------

    fn onMonitor(_: *gio.FileMonitor, file: *gio.File, other: ?*gio.File, event: gio.FileMonitorEvent, self: *Folder) callconv(.c) void {
        switch (event) {
            .created, .changed, .changes_done_hint, .attribute_changed, .moved_in => self.markStale(file),
            .deleted, .moved_out, .unmounted => self.drop(file),
            .renamed => {
                self.drop(file);
                if (other) |o| self.markStale(o);
            },
            else => {},
        }
    }

    fn markStale(self: *Folder, file: *gio.File) void {
        const name = file.getBasename() orelse return;
        defer glib.free(name);
        const span = std.mem.span(name);
        if (!self.stale.contains(span)) {
            const owned = allocator.dupe(u8, span) catch return;
            self.stale.put(allocator, owned, {}) catch {
                allocator.free(owned);
                return;
            };
        }
        if (self.query_timer == 0) self.query_timer = glib.timeoutAdd(query_delay_ms, onQueryTimer, self);
    }

    fn drop(self: *Folder, file: *gio.File) void {
        const name = file.getBasename() orelse return;
        defer glib.free(name);
        const span = std.mem.span(name);
        if (self.stale.fetchRemove(span)) |kv| allocator.free(kv.key);
        if (self.infos.fetchRemove(span)) |kv| {
            allocator.free(kv.key);
            kv.value.as(gobject.Object).unref();
            self.scheduleSync();
        }
    }

    fn onQueryTimer(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Folder = @ptrCast(@alignCast(data.?));
        self.query_timer = 0;
        const dir = self.file orelse return 0;
        var names = self.stale.keyIterator();
        while (names.next()) |name| {
            const op = self.newOp(name.*) orelse continue;
            const child = dir.getChild(op.name.?);
            defer child.as(gobject.Object).unref();
            child.queryInfoAsync(self.attributes, .{}, glib.PRIORITY_DEFAULT, self.cancellable, onQueried, op);
            allocator.free(name.*);
        }
        self.stale.clearRetainingCapacity();
        return 0;
    }

    fn onQueried(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const op: *Op = @ptrCast(@alignCast(data.?));
        defer op.done();
        const file: *gio.File = @ptrCast(@alignCast(source.?));
        var err: ?*glib.Error = null;
        const info = file.queryInfoFinish(result, &err);
        if (err) |e| e.free();
        if (!op.current()) {
            if (info) |i| i.as(gobject.Object).unref();
            return;
        }
        const self = op.folder;
        if (info) |i| self.put(i) else self.drop(file); // gone again before we looked
        self.scheduleSync();
    }

    /// Stores `info` under its name, replacing an older one (takes the ref).
    fn put(self: *Folder, info: *gio.FileInfo) void {
        // The views find the file a row stands for here, as with
        // GtkDirectoryList ("standard::file" holds the GFile).
        if (self.file) |dir| {
            const child = dir.getChild(info.getName());
            defer child.as(gobject.Object).unref();
            info.setAttributeObject("standard::file", child.as(gobject.Object));
        }
        const name = std.mem.span(info.getName());
        if (self.infos.getPtr(name)) |slot| {
            slot.*.as(gobject.Object).unref();
            slot.* = info;
            return;
        }
        const owned = allocator.dupe(u8, name) catch {
            info.as(gobject.Object).unref();
            return;
        };
        self.infos.put(allocator, owned, info) catch {
            allocator.free(owned);
            info.as(gobject.Object).unref();
        };
    }

    // ---- bringing the store up to date -----------------------------------

    fn scheduleSync(self: *Folder) void {
        if (self.sync_timer == 0) self.sync_timer = glib.timeoutAdd(batch_ms, onSyncTimer, self);
    }

    fn onSyncTimer(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Folder = @ptrCast(@alignCast(data.?));
        self.sync_timer = 0;
        self.sync();
        return 0;
    }

    /// Makes the store hold exactly the infos in the map.
    fn sync(self: *Folder) void {
        if (self.observer) |o| if (o.changing) |f| f(o.data, self, false);
        defer if (self.observer) |o| if (o.changing) |f| f(o.data, self, true);
        var wanted: std.AutoHashMapUnmanaged(*gio.FileInfo, void) = .empty;
        defer wanted.deinit(allocator);
        wanted.ensureTotalCapacity(allocator, self.infos.count()) catch return;
        var values = self.infos.valueIterator();
        while (values.next()) |info| wanted.putAssumeCapacity(info.*, {});

        // Remove what went, in runs, from the end so positions stay valid.
        const model = self.store.as(gio.ListModel);
        var have: std.AutoHashMapUnmanaged(*gio.FileInfo, void) = .empty;
        defer have.deinit(allocator);
        have.ensureTotalCapacity(allocator, model.getNItems()) catch return;
        var pos = model.getNItems();
        var run_end = pos;
        while (pos > 0) {
            pos -= 1;
            const object: *gobject.Object = @ptrCast(@alignCast(model.getItem(pos) orelse continue));
            defer object.unref();
            const info: *gio.FileInfo = @ptrCast(object);
            if (!wanted.contains(info)) continue;
            have.putAssumeCapacity(info, {});
            if (run_end > pos + 1) self.store.splice(pos + 1, run_end - pos - 1, &[_]*gobject.Object{}, 0);
            run_end = pos;
        }
        if (run_end > 0) self.store.splice(0, run_end, &[_]*gobject.Object{}, 0);

        // Add everything new in one splice.
        var added: std.ArrayList(*gobject.Object) = .empty;
        defer added.deinit(allocator);
        values = self.infos.valueIterator();
        while (values.next()) |info| {
            if (have.contains(info.*)) continue;
            added.append(allocator, info.*.as(gobject.Object)) catch return;
        }
        if (added.items.len > 0) self.store.splice(model.getNItems(), 0, added.items.ptr, @intCast(added.items.len));
    }
};

// ---- tests -----------------------------------------------------------------

const TestWait = struct {
    loop: *glib.MainLoop,
    folder: *Folder,
    want: u32,
    loaded: bool = false,

    fn onLoaded(data: *anyopaque, _: *Folder) void {
        const self: *TestWait = @ptrCast(@alignCast(data));
        self.loaded = true;
    }

    fn check(data: ?*anyopaque) callconv(.c) c_int {
        const self: *TestWait = @ptrCast(@alignCast(data.?));
        if (self.loaded and self.folder.store.as(gio.ListModel).getNItems() == self.want) {
            self.loop.quit();
            return 0;
        }
        return 1;
    }

    /// Runs the main loop until the store holds `want` items (or 10 s pass).
    fn until(self: *TestWait, want: u32) !void {
        self.want = want;
        const poll = glib.timeoutAdd(20, check, self);
        const give_up = glib.timeoutAdd(10_000, quit, self.loop);
        self.loop.run();
        _ = glib.Source.remove(give_up);
        _ = poll;
        try std.testing.expectEqual(want, self.folder.store.as(gio.ListModel).getNItems());
    }

    fn quit(data: ?*anyopaque) callconv(.c) c_int {
        const loop: *glib.MainLoop = @ptrCast(@alignCast(data.?));
        loop.quit();
        return 0;
    }
};

fn touch(dir: []const u8, name: []const u8) !void {
    const path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/{s}", .{ dir, name }, 0);
    defer std.testing.allocator.free(path);
    if (glib.fileSetContents(path, "", 0, null) == 0) return error.WriteFailed;
}

test "a folder lists its files, then follows files being added and removed" {
    const root = glib.Dir.makeTmp("dkde-folder-XXXXXX", null) orelse return error.NoTmp;
    defer glib.free(root);
    const base = std.mem.span(root);
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        var buf: [32]u8 = undefined;
        try touch(base, try std.fmt.bufPrint(&buf, "start_{d}", .{i}));
    }

    const folder = Folder.create("standard::name,standard::type");
    defer folder.destroy();
    var wait: TestWait = .{ .loop = glib.MainLoop.new(null, 0), .folder = folder, .want = 0 };
    defer wait.loop.unref();
    folder.observer = .{ .data = &wait, .loaded = TestWait.onLoaded };

    const dir = gio.File.newForPath(root);
    defer dir.as(gobject.Object).unref();
    folder.setFile(dir);
    try wait.until(300);

    // Every row knows its file: the views open, copy and drag through it.
    const first: *gio.FileInfo = @ptrCast(@alignCast(folder.store.as(gio.ListModel).getItem(0).?));
    defer first.as(gobject.Object).unref();
    const file: *gio.File = @ptrCast(@alignCast(first.getAttributeObject("standard::file") orelse return error.NoFile));
    const parent = file.getParent().?;
    defer parent.as(gobject.Object).unref();
    try std.testing.expect(parent.equal(dir) != 0);

    // 500 more arrive while the folder is shown.
    i = 0;
    while (i < 500) : (i += 1) {
        var buf: [32]u8 = undefined;
        try touch(base, try std.fmt.bufPrint(&buf, "later_{d}", .{i}));
    }
    try wait.until(800);

    // And 100 of the first ones go.
    i = 0;
    while (i < 100) : (i += 1) {
        var buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrintSentinel(&buf, "{s}/start_{d}", .{ base, i }, 0);
        _ = std.c.unlink(path);
    }
    try wait.until(700);
}

test "a folder that cannot be read reports the error" {
    const folder = Folder.create("standard::name");
    defer folder.destroy();
    var wait: TestWait = .{ .loop = glib.MainLoop.new(null, 0), .folder = folder, .want = 0 };
    defer wait.loop.unref();
    folder.observer = .{ .data = &wait, .loaded = TestWait.onLoaded };
    const missing = gio.File.newForPath("/nonexistent/dkde-folder-test");
    defer missing.as(gobject.Object).unref();
    folder.setFile(missing);
    try wait.until(0);
    try std.testing.expect(folder.err != null);
}
