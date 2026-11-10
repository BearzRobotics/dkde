//! TOML configuration (ai/DKDE-SPEC.md section 23).
//!
//! A `Config` is the system defaults overlaid with the user's file, so the
//! user's file only has to hold what they changed. Missing or invalid values
//! fall back to the caller's default and log a warning; they never fail.
//!
//! Layout: a "group" is a top-level TOML table (`[panel]`), a key is a key in
//! it. A group name may be any string (`[ "profile:Default" ]`).
//!
//! Safety rules this module enforces:
//!  - A malformed user file is reported (file, line, column) and the defaults
//!    are used. It is never overwritten: every `set*` fails with
//!    `error.MalformedConfig` until the file is fixed.
//!  - Writes are read-modify-write under an advisory lock, so two programs
//!    saving different keys do not lose each other's change, and land with an
//!    atomic rename.
//!  - A parsed file keeps keys this program does not know. Saving edits the
//!    file as text (see tomltext.zig), so comments, blank lines and the order
//!    of keys survive; only a layout the text editor does not understand falls
//!    back to rewriting the file from the parsed document, which keeps the
//!    comments the TOML library keeps (all but those inside arrays and inline
//!    tables).

const std = @import("std");
const toml = @import("toml");
const glib = @import("glib2");
const gio = @import("gio2");
const gobject = @import("gobject2");

const paths = @import("paths.zig");
const migrate = @import("migrate.zig");
const fsio = @import("fsio.zig");
const tomltext = @import("tomltext.zig");

const log = std.log.scoped(.config);

const builtin = @import("builtin");
/// The standalone Windows calendar uses this file too: it has no GIO file monitor
/// and no flock, and keeps its files under %APPDATA% (see paths.zig).
const is_windows = builtin.os.tag == .windows;
const Monitor = if (is_windows) opaque {} else gio.FileMonitor;

extern "c" fn flock(fd: c_int, operation: c_int) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
const O_RDWR = 0o2;
const O_CREAT = 0o100;
const O_CLOEXEC = 0o2000000;
const LOCK_EX = 2;

pub const Error = error{
    /// The user's file does not parse; it was left untouched.
    MalformedConfig,
    SaveFailed,
    OutOfMemory,
    NoSystemDefaults,
};

pub const Config = struct {
    allocator: std.mem.Allocator,
    /// File name inside the dkde directories, e.g. "panel.toml".
    name: []const u8,
    /// System defaults with the user's file on top.
    doc: toml.Document,
    /// The user's file exists but did not parse at the last reload.
    user_malformed: bool = false,
    monitor: ?*Monitor = null,
    /// The watch callback's context and how to free it.
    watch_ctx: ?*anyopaque = null,
    watch_free: ?*const fn (std.mem.Allocator, *anyopaque) void = null,
    /// Tests point this at a temporary file instead of `$XDG_CONFIG_HOME`.
    user_path_override: ?[:0]const u8 = null,
    /// Staged mode (the Settings app): `set*` changes the values in memory and
    /// queues the change; nothing is written until `apply`.
    staged: bool = false,
    ops: std.ArrayList(Op) = .empty,
    staged_callback: ?*const fn (*anyopaque) void = null,
    staged_data: ?*anyopaque = null,

    /// One queued change.
    const Op = union(enum) {
        string: struct { group: [:0]u8, key: [:0]u8, value: [:0]u8 },
        int: struct { group: [:0]u8, key: [:0]u8, value: i32 },
        boolean: struct { group: [:0]u8, key: [:0]u8, value: bool },
        list: struct { group: [:0]u8, key: [:0]u8, values: [][:0]u8 },
        remove_group: [:0]u8,
    };

    pub fn load(allocator: std.mem.Allocator, name: []const u8) !Config {
        var self: Config = .{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .doc = try toml.Document.init(allocator),
        };
        errdefer self.deinit();
        try self.reload();
        if (!is_windows and migrate.legacyPending(allocator, std.fs.path.stem(name)))
            log.warn("found an old {s}.conf and no {s}; convert it with `dkde-setup --migrate-config`", .{ std.fs.path.stem(name), name });
        return self;
    }

    fn userPath(self: *const Config) ![:0]u8 {
        if (self.user_path_override) |path| return self.allocator.dupeSentinel(u8, path, 0);
        return paths.userConfigFile(self.allocator, self.name);
    }

    pub fn deinit(self: *Config) void {
        if (comptime !is_windows) if (self.monitor) |m| {
            _ = m.cancel();
            m.as(gobject.Object).unref();
        };
        if (self.watch_ctx) |ctx| self.watch_free.?(self.allocator, ctx);
        self.clearOps();
        self.ops.deinit(self.allocator);
        self.doc.deinit();
        self.allocator.free(self.name);
        self.* = undefined;
    }

    /// Re-reads the system defaults and then the user's file on top of them.
    pub fn reload(self: *Config) !void {
        var fresh = try toml.Document.init(self.allocator);
        errdefer fresh.deinit();

        if (try paths.systemDataFile(self.allocator, self.name)) |path| {
            defer self.allocator.free(path);
            // A broken system file was already logged; the defaults stay empty.
            mergeFile(self.allocator, &fresh, path) catch |err| switch (err) {
                error.MalformedConfig => {},
                else => |e| return e,
            };
        }

        const user_path = try self.userPath();
        defer self.allocator.free(user_path);
        self.user_malformed = false;
        mergeFile(self.allocator, &fresh, user_path) catch |err| switch (err) {
            error.MalformedConfig => self.user_malformed = true,
            else => |e| return e,
        };
        if (self.user_malformed) log.warn("{s}: using the defaults until the file is fixed; settings will not be saved", .{user_path});

        self.doc.deinit();
        self.doc = fresh;
        // Staged changes are not on disk yet: keep them on top.
        if (self.staged) for (self.ops.items) |op| applyOp(&self.doc, op);
    }

    // ---- staged changes ---------------------------------------------------------------

    /// Turns on staged mode. `callback(data)` runs whenever the number of
    /// queued changes changes.
    pub fn stage(self: *Config, comptime Data: type, callback: *const fn (*Data) void, data: *Data) void {
        self.staged = true;
        self.staged_callback = @ptrCast(callback);
        self.staged_data = data;
    }

    pub fn pendingCount(self: *const Config) usize {
        return self.ops.items.len;
    }

    fn notifyStaged(self: *Config) void {
        if (self.staged_callback) |cb| cb(self.staged_data.?);
    }

    fn clearOps(self: *Config) void {
        const a = self.allocator;
        for (self.ops.items) |op| switch (op) {
            .string => |o| {
                a.free(o.group);
                a.free(o.key);
                a.free(o.value);
            },
            .int => |o| {
                a.free(o.group);
                a.free(o.key);
            },
            .boolean => |o| {
                a.free(o.group);
                a.free(o.key);
            },
            .list => |o| {
                a.free(o.group);
                a.free(o.key);
                for (o.values) |v| a.free(v);
                a.free(o.values);
            },
            .remove_group => |g| a.free(g),
        };
        self.ops.clearRetainingCapacity();
    }

    /// Applies a change to `doc`. Out-of-memory leaves the document as it was
    /// for that one change; the caller's value is simply not stored.
    fn applyOp(doc: *toml.Document, op: Op) void {
        switch (op) {
            .string => |o| setValue(doc, o.group, o.key, .{ .string = doc.dupe(o.value) catch return }) catch return,
            .int => |o| setValue(doc, o.group, o.key, .{ .integer = o.value }) catch return,
            .boolean => |o| setValue(doc, o.group, o.key, .{ .boolean = o.value }) catch return,
            .list => |o| setList(doc, o.group, o.key, o.values) catch return,
            .remove_group => |g| _ = doc.root.remove(g),
        }
    }

    /// Queues `op` and shows its effect in memory.
    fn queue(self: *Config, op: Op) !void {
        try self.ops.append(self.allocator, op);
        applyOp(&self.doc, op);
        self.notifyStaged();
    }

    /// Writes the queued changes to the user's file (only what changed).
    pub fn apply(self: *Config) !void {
        if (self.ops.items.len == 0) return;
        var user = try self.beginWrite();
        defer user.end();
        for (self.ops.items) |op| applyOp(&user.doc, op);
        self.clearOps();
        self.notifyStaged();
        try self.finishWrite(&user);
    }

    /// Drops the queued changes and returns to what is on disk.
    pub fn discard(self: *Config) !void {
        if (self.ops.items.len == 0) return;
        self.clearOps();
        try self.reload();
        self.notifyStaged();
    }

    /// Calls `callback(data)` after the config has been reloaded because the
    /// user's file changed. Only one watch per config.
    pub fn watch(self: *Config, comptime Data: type, callback: *const fn (*Data) void, data: *Data) !void {
        if (comptime is_windows) return; // no file monitor there; the program rereads when it needs to
        const path = try self.userPath();
        defer self.allocator.free(path);

        // The directory has to exist for the monitor to see the file appear.
        if (std.fs.path.dirname(path)) |dir| fsio.makePath(dir) catch {};

        const file = gio.File.newForPath(path);
        defer file.as(gobject.Object).unref();

        var err: ?*glib.Error = null;
        const monitor = file.monitorFile(.{}, null, &err) orelse {
            log.warn("cannot watch {s}: {s}", .{ path, errMessage(err) });
            if (err) |e| e.free();
            return;
        };
        self.monitor = monitor;

        const Ctx = struct {
            config: *Config,
            data: *Data,
            callback: *const fn (*Data) void,

            fn free(allocator: std.mem.Allocator, raw: *anyopaque) void {
                allocator.destroy(@as(*@This(), @ptrCast(@alignCast(raw))));
            }

            fn onChanged(_: *gio.FileMonitor, _: *gio.File, _: ?*gio.File, event: gio.FileMonitorEvent, ctx: *@This()) callconv(.c) void {
                // `changed` fires per write; wait for the burst to finish.
                switch (event) {
                    .changes_done_hint, .created, .deleted, .renamed, .moved_in, .moved_out => {},
                    else => return,
                }
                // An invalid reload keeps nothing half-read: `reload` builds a
                // new document and only replaces the old one when it is whole,
                // and a malformed user file falls back to the defaults.
                ctx.config.reload() catch |e| {
                    log.warn("reloading {s} failed: {s}", .{ ctx.config.name, @errorName(e) });
                    return;
                };
                ctx.callback(ctx.data);
            }
        };
        const ctx = try self.allocator.create(Ctx);
        ctx.* = .{ .config = self, .data = data, .callback = callback };
        self.watch_ctx = ctx;
        self.watch_free = Ctx.free;
        _ = gio.FileMonitor.signals.changed.connect(monitor, *Ctx, &Ctx.onChanged, ctx, .{});
    }

    // ---- reading ----------------------------------------------------------------------

    fn find(self: *const Config, group: []const u8, key: []const u8) ?toml.Value {
        const table = self.doc.root.getTable(group) orelse return null;
        return table.get(key);
    }

    fn wrongType(self: *const Config, group: []const u8, key: []const u8, want: []const u8, got: toml.Value) void {
        log.warn("{s}: [{s}] {s}: expected {s}, found {s}; using default", .{ self.name, group, key, want, got.typeName() });
    }

    pub fn getBool(self: *const Config, group: [:0]const u8, key: [:0]const u8, default: bool) bool {
        const v = self.find(group, key) orelse return default;
        return switch (v) {
            .boolean => |b| b,
            else => {
                self.wrongType(group, key, "a boolean", v);
                return default;
            },
        };
    }

    pub fn getInt(self: *const Config, group: [:0]const u8, key: [:0]const u8, default: i32) i32 {
        const v = self.find(group, key) orelse return default;
        switch (v) {
            .integer => |i| return std.math.cast(i32, i) orelse {
                log.warn("{s}: [{s}] {s}: {d} is out of range; using default", .{ self.name, group, key, i });
                return default;
            },
            else => {
                self.wrongType(group, key, "an integer", v);
                return default;
            },
        }
    }

    /// A number; an integer reads as a float.
    pub fn getFloat(self: *const Config, group: [:0]const u8, key: [:0]const u8, default: f64) f64 {
        const v = self.find(group, key) orelse return default;
        return switch (v) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => {
                self.wrongType(group, key, "a number", v);
                return default;
            },
        };
    }

    /// Returns a copy owned by the caller, or `default` duplicated when the
    /// key is missing. Integers and booleans are returned as their text, so a
    /// value such as `name = 5` still reads as a string.
    pub fn getString(self: *const Config, allocator: std.mem.Allocator, group: [:0]const u8, key: [:0]const u8, default: []const u8) ![]u8 {
        const v = self.find(group, key) orelse return allocator.dupe(u8, default);
        return switch (v) {
            .string => |s| allocator.dupe(u8, s),
            .integer => |i| std.fmt.allocPrint(allocator, "{d}", .{i}),
            .boolean => |b| allocator.dupe(u8, if (b) "true" else "false"),
            else => {
                self.wrongType(group, key, "a string", v);
                return allocator.dupe(u8, default);
            },
        };
    }

    /// A copy of an array of strings, or null when the key is missing or is
    /// not an array of strings. Free with `freeStringList`.
    pub fn getStringList(self: *const Config, allocator: std.mem.Allocator, group: [:0]const u8, key: [:0]const u8) !?[][]u8 {
        const v = self.find(group, key) orelse return null;
        const arr = switch (v) {
            .array => |a| a,
            else => {
                self.wrongType(group, key, "an array", v);
                return null;
            },
        };
        var out: std.ArrayList([]u8) = .empty;
        errdefer freeStringList(allocator, out.items);
        for (arr.items.items) |item| switch (item) {
            .string => |s| try out.append(allocator, try allocator.dupe(u8, s)),
            else => {
                self.wrongType(group, key, "an array of strings", item);
                freeStringList(allocator, out.items);
                return null;
            },
        };
        return try out.toOwnedSlice(allocator);
    }

    // ---- writing ----------------------------------------------------------------------

    /// Writes one value into the user's file, keeping everything else in it,
    /// then reloads. The settings app and the file manager's bookmarks use
    /// this; running components pick the change up through their monitors.
    pub fn setString(self: *Config, group: [:0]const u8, key: [:0]const u8, value: [:0]const u8) !void {
        // A value that is already in effect is not written.
        if (self.find(group, key)) |cur| switch (cur) {
            .string => |s| if (std.mem.eql(u8, s, value)) return,
            else => {},
        };
        if (self.staged) return self.queue(.{ .string = .{
            .group = try self.allocator.dupeSentinel(u8, group, 0),
            .key = try self.allocator.dupeSentinel(u8, key, 0),
            .value = try self.allocator.dupeSentinel(u8, value, 0),
        } });
        var user = try self.beginWrite();
        defer user.end();
        try setValue(&user.doc, group, key, .{ .string = try user.doc.dupe(value) });
        try self.finishWrite(&user);
    }

    pub fn setInt(self: *Config, group: [:0]const u8, key: [:0]const u8, value: i32) !void {
        if (self.find(group, key)) |cur| switch (cur) {
            .integer => |i| if (i == value) return,
            else => {},
        };
        if (self.staged) return self.queue(.{ .int = .{
            .group = try self.allocator.dupeSentinel(u8, group, 0),
            .key = try self.allocator.dupeSentinel(u8, key, 0),
            .value = value,
        } });
        var user = try self.beginWrite();
        defer user.end();
        try setValue(&user.doc, group, key, .{ .integer = value });
        try self.finishWrite(&user);
    }

    pub fn setBool(self: *Config, group: [:0]const u8, key: [:0]const u8, value: bool) !void {
        if (self.find(group, key)) |cur| switch (cur) {
            .boolean => |b| if (b == value) return,
            else => {},
        };
        if (self.staged) return self.queue(.{ .boolean = .{
            .group = try self.allocator.dupeSentinel(u8, group, 0),
            .key = try self.allocator.dupeSentinel(u8, key, 0),
            .value = value,
        } });
        var user = try self.beginWrite();
        defer user.end();
        try setValue(&user.doc, group, key, .{ .boolean = value });
        try self.finishWrite(&user);
    }

    pub fn setStringList(self: *Config, group: [:0]const u8, key: [:0]const u8, values: []const []const u8) !void {
        if (self.staged) {
            const copy = try self.allocator.alloc([:0]u8, values.len);
            var made: usize = 0;
            errdefer {
                for (copy[0..made]) |c| self.allocator.free(c);
                self.allocator.free(copy);
            }
            for (values, 0..) |v, i| {
                copy[i] = try self.allocator.dupeSentinel(u8, v, 0);
                made += 1;
            }
            return self.queue(.{ .list = .{
                .group = try self.allocator.dupeSentinel(u8, group, 0),
                .key = try self.allocator.dupeSentinel(u8, key, 0),
                .values = copy,
            } });
        }
        var user = try self.beginWrite();
        defer user.end();
        try setList(&user.doc, group, key, values);
        try self.finishWrite(&user);
    }

    pub const Pair = struct { key: [:0]const u8, value: [:0]const u8 };

    /// Replaces a whole group in the user's file with `pairs` in one write
    /// (one file change, so a watcher reloads once). Not for staged configs.
    pub fn setGroup(self: *Config, group: [:0]const u8, pairs: []const Pair) !void {
        var user = try self.beginWrite();
        defer user.end();
        try replaceGroup(&user.doc, group, pairs);
        try self.finishWrite(&user);
    }

    pub const GroupItem = struct { group: [:0]const u8, pairs: []const Pair };

    /// `setGroup` for many groups, in one write.
    pub fn setGroups(self: *Config, items: []const GroupItem) !void {
        var user = try self.beginWrite();
        defer user.end();
        for (items) |item| try replaceGroup(&user.doc, item.group, item.pairs);
        try self.finishWrite(&user);
    }

    /// Removes a whole group from the user's file, then reloads.
    pub fn removeGroup(self: *Config, group: [:0]const u8) !void {
        if (self.staged) return self.queue(.{ .remove_group = try self.allocator.dupeSentinel(u8, group, 0) });
        var user = try self.beginWrite();
        defer user.end();
        _ = user.doc.root.remove(group);
        try self.finishWrite(&user);
    }

    /// Names of the groups starting with `prefix` (prefix removed), in file
    /// order. Free with `freeStringList`.
    pub fn groupsWithPrefix(self: *const Config, allocator: std.mem.Allocator, prefix: []const u8) ![][]u8 {
        var out: std.ArrayList([]u8) = .empty;
        errdefer freeStringList(allocator, out.items);
        for (self.doc.root.entries.keys(), self.doc.root.entries.values()) |name, v| {
            if (v != .table) continue;
            if (std.mem.startsWith(u8, name, prefix)) try out.append(allocator, try allocator.dupe(u8, name[prefix.len..]));
        }
        return try out.toOwnedSlice(allocator);
    }

    // ---- the user's file --------------------------------------------------------------

    /// The user's file opened for one read-modify-write, under an advisory
    /// lock held until `end`.
    const UserFile = struct {
        doc: toml.Document,
        path: [:0]u8,
        /// The document as first read, serialized; a write that changes
        /// nothing is skipped.
        before: []u8,
        /// The file's text as first read ("" when it does not exist).
        orig: []u8,
        lock_fd: c_int,
        allocator: std.mem.Allocator,

        fn end(self: *UserFile) void {
            if (comptime !is_windows) if (self.lock_fd >= 0) {
                _ = close(self.lock_fd); // closing releases the lock
            };
            self.allocator.free(self.before);
            self.allocator.free(self.orig);
            self.allocator.free(self.path);
            self.doc.deinit();
        }
    };

    fn beginWrite(self: *Config) !UserFile {
        if (self.user_malformed) {
            log.warn("{s}: not saving; the file has a syntax error. Fix or remove it.", .{self.name});
            return error.MalformedConfig;
        }
        const path = try self.userPath();
        errdefer self.allocator.free(path);
        if (std.fs.path.dirname(path)) |dir| fsio.makePath(dir) catch {};

        // One lock file per config, next to it. A failure to lock is logged
        // and the write goes ahead: losing the race is better than no save.
        const lock_path = try std.fmt.allocPrintSentinel(self.allocator, "{s}.lock", .{path}, 0);
        defer self.allocator.free(lock_path);
        var lock_fd: c_int = -1;
        if (comptime !is_windows) lock_fd = open(lock_path, O_RDWR | O_CREAT | O_CLOEXEC, @as(c_uint, 0o600));
        if (comptime !is_windows) {
            if (lock_fd >= 0 and flock(lock_fd, LOCK_EX) != 0) {
                log.warn("cannot lock {s}", .{lock_path});
                _ = close(lock_fd);
                lock_fd = -1;
            }
        }
        errdefer if (comptime !is_windows) if (lock_fd >= 0) {
            _ = close(lock_fd);
        };

        // Read under the lock, so the latest saved state is what is modified.
        var doc = if (readDocument(self.allocator, path)) |maybe| (maybe orelse try toml.Document.init(self.allocator)) else |err| {
            if (err == error.MalformedConfig) self.user_malformed = true;
            return err;
        };
        errdefer doc.deinit();
        const before = try doc.toOwnedString(self.allocator);
        errdefer self.allocator.free(before);
        const orig = (fsio.readFile(self.allocator, path, 1 << 20) catch null) orelse try self.allocator.dupe(u8, "");
        return .{ .doc = doc, .path = path, .before = before, .orig = orig, .lock_fd = lock_fd, .allocator = self.allocator };
    }

    /// Writes the user's file, but only when its content actually changes.
    fn finishWrite(self: *Config, user: *UserFile) !void {
        const after = try user.doc.toOwnedString(self.allocator);
        defer self.allocator.free(after);
        if (std.mem.eql(u8, user.before, after)) {
            // Nothing to write; the in-memory values are still right.
            return self.reload();
        }
        // Prefer editing the file's own text, which keeps its comments.
        const patched = patchText(self.allocator, user.orig, user.before, after);
        defer if (patched) |p| self.allocator.free(p);
        const out = patched orelse after;
        // Writes a temporary file and renames it over the target.
        fsio.writeFileAtomic(user.path, out) catch |e| {
            log.warn("cannot save {s}: {s}", .{ user.path, @errorName(e) });
            return error.SaveFailed;
        };
        try self.reload();
    }
};

// ---- helpers -------------------------------------------------------------------------------

/// `key = value` for one entry, as the TOML library writes it. Tables cannot be
/// rendered on one line, so they are unsupported here.
fn renderEntry(a: std.mem.Allocator, key: []const u8, v: toml.Value) tomltext.Error![]u8 {
    if (v == .table) return error.Unsupported;
    var tmp = toml.Document.init(a) catch return error.OutOfMemory;
    defer tmp.deinit();
    const copy = cloneValue(&tmp, v) catch return error.OutOfMemory;
    setValue(&tmp, "g", key, copy) catch return error.OutOfMemory;
    const text = tmp.toOwnedString(a) catch return error.OutOfMemory;
    defer a.free(text);
    const prefix = "[g]\n";
    if (!std.mem.startsWith(u8, text, prefix)) return error.Unsupported;
    const body = std.mem.trimEnd(u8, text[prefix.len..], "\n");
    // Another header in the output would mean a nested table.
    if (std.mem.indexOf(u8, body, "\n[") != null) return error.Unsupported;
    return a.dupe(u8, body);
}

/// Applies the difference between two serialized documents to `orig`, the
/// file's own text. Null when that cannot be done safely (an unsupported
/// layout, or the result does not parse back to exactly `after`); the caller
/// then writes `after`.
fn patchText(a: std.mem.Allocator, orig: []const u8, before_text: []const u8, after_text: []const u8) ?[]u8 {
    if (std.mem.trim(u8, orig, " \t\r\n").len == 0) return null;
    return patchTextInner(a, orig, before_text, after_text) catch null;
}

fn patchTextInner(a: std.mem.Allocator, orig: []const u8, before_text: []const u8, after_text: []const u8) ![]u8 {
    var before = try toml.Document.parse(a, before_text, .{}, null);
    defer before.deinit();
    var after = try toml.Document.parse(a, after_text, .{}, null);
    defer after.deinit();

    var text = try a.dupe(u8, orig);
    errdefer a.free(text);
    // Gone tables and keys first, then new and changed values.
    for (before.root.entries.keys(), before.root.entries.values()) |group, bv| {
        const bt = switch (bv) {
            .table => |t| t,
            else => continue,
        };
        const at: ?*toml.Table = if (after.root.get(group)) |av| switch (av) {
            .table => |t| t,
            else => null,
        } else null;
        if (at == null) {
            const next = try tomltext.removeGroup(a, text, group);
            a.free(text);
            text = next;
            continue;
        }
        for (bt.entries.keys()) |k| {
            if (at.?.get(k) != null) continue;
            const next = try tomltext.removeKey(a, text, group, k);
            a.free(text);
            text = next;
        }
    }
    for (after.root.entries.keys(), after.root.entries.values()) |group, av| {
        const at = switch (av) {
            .table => |t| t,
            else => continue,
        };
        const bt: ?*toml.Table = if (before.root.get(group)) |bv| switch (bv) {
            .table => |t| t,
            else => null,
        } else null;
        for (at.entries.keys(), at.entries.values()) |k, v| {
            const new_text = try renderEntry(a, k, v);
            defer a.free(new_text);
            if (bt) |b| if (b.get(k)) |old| {
                const old_text = try renderEntry(a, k, old);
                defer a.free(old_text);
                if (std.mem.eql(u8, old_text, new_text)) continue;
            };
            const next = try tomltext.setKey(a, text, group, k, new_text);
            a.free(text);
            text = next;
        }
    }

    // The edited text must mean exactly what the document says. Comments are
    // not part of the meaning (the file keeps its own, the document may differ).
    var check = try toml.Document.parse(a, text, .{}, null);
    defer check.deinit();
    stripComments(check.root);
    stripComments(after.root);
    const check_text = try check.toOwnedString(a);
    defer a.free(check_text);
    const after_plain = try after.toOwnedString(a);
    defer a.free(after_plain);
    if (!std.mem.eql(u8, check_text, after_plain)) return error.Unsupported;
    return text;
}

/// Clears every comment in `t` and below, so two documents compare by their values only.
fn stripComments(t: *toml.Table) void {
    t.header = .{};
    t.key_comments = .empty;
    t.footer = &.{};
    for (t.entries.values()) |v| switch (v) {
        .table => |sub| stripComments(sub),
        .array => |arr| for (arr.items.items) |item| switch (item) {
            .table => |sub| stripComments(sub),
            else => {},
        },
        else => {},
    };
}

/// Reads and parses `path`. A missing file gives null; unreadable or invalid
/// ones are logged with file, line and column and give `error.MalformedConfig`.
fn readDocument(allocator: std.mem.Allocator, path: [:0]const u8) !?toml.Document {
    var file = (fsio.openRead(path) catch |e| {
        log.warn("cannot read {s}: {s}", .{ path, @errorName(e) });
        return error.MalformedConfig;
    }) orelse return null;
    const io = fsio.io();
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    var diag: toml.Diagnostic = .{};
    return toml.Document.parseReader(allocator, &reader.interface, .{ .max_bytes = 1 << 20 }, &diag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ReadFailed => {
            log.warn("cannot read {s}: {s}", .{ path, @errorName(reader.err orelse error.Unexpected) });
            return error.MalformedConfig;
        },
        else => {
            log.warn("{s}:{f}: {s}", .{ path, diag, @errorName(e) });
            return error.MalformedConfig;
        },
    };
}

fn groupTable(doc: *toml.Document, group: []const u8) !*toml.Table {
    if (doc.root.getPtr(group)) |existing| switch (existing.*) {
        .table => |t| return t,
        else => {}, // a stray top-level value of that name is replaced by a table
    };
    const a = doc.allocator();
    const t = try a.create(toml.Table);
    t.* = .{ .kind = .explicit };
    try doc.root.put(a, try doc.dupe(group), .{ .table = t });
    return t;
}

fn setValue(doc: *toml.Document, group: []const u8, key: []const u8, v: toml.Value) !void {
    const t = try groupTable(doc, group);
    try t.put(doc.allocator(), try doc.dupe(key), v);
}

fn setList(doc: *toml.Document, group: []const u8, key: []const u8, values: anytype) !void {
    const a = doc.allocator();
    const arr = try a.create(toml.Array);
    arr.* = .{};
    for (values) |item| try arr.items.append(a, .{ .string = try doc.dupe(item) });
    try setValue(doc, group, key, .{ .array = arr });
}

fn replaceGroup(doc: *toml.Document, group: []const u8, pairs: []const Config.Pair) !void {
    _ = doc.root.remove(group);
    const t = try groupTable(doc, group);
    for (pairs) |pair| try t.put(doc.allocator(), try doc.dupe(pair.key), .{ .string = try doc.dupe(pair.value) });
}

/// Copies a value into `doc`'s arena.
fn cloneValue(doc: *toml.Document, v: toml.Value) !toml.Value {
    const a = doc.allocator();
    return switch (v) {
        .string => |s| .{ .string = try doc.dupe(s) },
        .array => |src| blk: {
            const arr = try a.create(toml.Array);
            arr.* = .{ .is_table_array = src.is_table_array };
            for (src.items.items) |item| try arr.items.append(a, try cloneValue(doc, item));
            break :blk .{ .array = arr };
        },
        .table => |src| blk: {
            const t = try a.create(toml.Table);
            t.* = .{ .kind = src.kind };
            for (src.entries.keys(), src.entries.values()) |k, item| try t.put(a, try doc.dupe(k), try cloneValue(doc, item));
            break :blk .{ .table = t };
        },
        else => v,
    };
}

/// Reads `path` (a missing file is fine) and overlays it on `dst`.
fn mergeFile(allocator: std.mem.Allocator, dst: *toml.Document, path: [:0]const u8) !void {
    var src = (try readDocument(allocator, path)) orelse return;
    defer src.deinit();
    try mergeInto(dst, &src);
}

/// Overlays `src` on `dst`: each key of each group replaces the same key in
/// `dst`; other keys of `dst` stay. Top-level non-table values are ignored.
fn mergeInto(dst: *toml.Document, src: *const toml.Document) !void {
    for (src.root.entries.keys(), src.root.entries.values()) |group, v| {
        const table = switch (v) {
            .table => |t| t,
            else => {
                log.warn("ignoring top-level key '{s}': settings belong in a [group]", .{group});
                continue;
            },
        };
        const out = try groupTable(dst, group);
        for (table.entries.keys(), table.entries.values()) |k, item| {
            try out.put(dst.allocator(), try dst.dupe(k), try cloneValue(dst, item));
        }
    }
}

// ---- complete, hand-editable files -------------------------------------------------------------

pub const Written = enum { created, merged, unchanged };

/// A complete `[profile:Default]` for term.toml, which the system defaults do
/// not carry (a system profile could not be deleted by the user).
pub const term_profile_template =
    \\
    \\# A terminal profile. Add more tables named ["profile:<name>"].
    \\["profile:Default"]
    \\# Empty runs your login shell.
    \\command = ""
    \\# Starting folder; empty is your home.
    \\directory = ""
    \\font = "Monospace 11"
    \\color-scheme = "campbell"
    \\# block, bar or underline
    \\cursor-style = "block"
    \\# Window title and tab icon; empty uses the program's own.
    \\title = ""
    \\icon = ""
    \\tab-color = ""
    \\# NAME=value pairs separated by ;
    \\environment = ""
    \\# windowed, maximized or fullscreen
    \\startup = "windowed"
    \\# always, success (only when the program ended normally) or never
    \\close-on-exit = "always"
    \\# Let programs set the clipboard (OSC 52).
    \\osc52 = true
    \\# 20 to 100; below 100 the background is see-through.
    \\opacity = 100
    \\# Start size; 0 lets the window decide.
    \\columns = 0
    \\rows = 0
    \\padding = 4
    \\copy-on-select = true
    \\
;

/// Writes the user's file for `name` with every default in it, so it can be
/// edited by hand. A missing file becomes a copy of the system defaults (with
/// their comments); an existing one only gains the keys it lacks. Run on
/// request, never automatically.
pub fn writeAllDefaults(allocator: std.mem.Allocator, name: []const u8, extra: []const u8) !Written {
    const system = (try paths.systemDataFile(allocator, name)) orelse return error.NoSystemDefaults;
    defer allocator.free(system);
    const user = try paths.userConfigFile(allocator, name);
    defer allocator.free(user);
    return mergeDefaults(allocator, system, user, extra);
}

fn mergeDefaults(allocator: std.mem.Allocator, system: [:0]const u8, user: [:0]const u8, extra: []const u8) !Written {
    const contents = (fsio.readFile(allocator, system, 1 << 20) catch return error.NoSystemDefaults) orelse return error.NoSystemDefaults;
    defer allocator.free(contents);
    const wanted_text = try std.mem.concat(allocator, u8, &.{ contents, extra });
    defer allocator.free(wanted_text);

    if (!fsio.exists(user)) {
        if (std.fs.path.dirname(user)) |dir| fsio.makePath(dir) catch {};
        fsio.writeFileAtomic(user, wanted_text) catch return error.SaveFailed;
        return .created;
    }

    // Add what is missing to the existing file, as text, so its comments and
    // layout stay and the new keys arrive with their explaining comments. A
    // file that does not parse is left alone.
    var have = (try readDocument(allocator, user)) orelse return error.SaveFailed;
    have.deinit();
    const current = (fsio.readFile(allocator, user, 1 << 20) catch return error.SaveFailed) orelse return error.SaveFailed;
    defer allocator.free(current);
    const merged = tomltext.addMissing(allocator, current, wanted_text) catch return error.SaveFailed;
    defer allocator.free(merged);
    if (std.mem.eql(u8, current, merged)) return .unchanged;
    // The result has to parse; otherwise leave the user's file as it is.
    var check = toml.Document.parse(allocator, merged, .{}, null) catch return error.SaveFailed;
    check.deinit();
    fsio.writeFileAtomic(user, merged) catch return error.SaveFailed;
    return .merged;
}

pub fn freeStringList(allocator: std.mem.Allocator, list: [][]u8) void {
    for (list) |item| allocator.free(item);
    allocator.free(list);
}

fn errMessage(err: anytype) [*:0]const u8 {
    return switch (@typeInfo(@TypeOf(err))) {
        .optional => if (err) |e| e.f_message orelse "unknown error" else "unknown error",
        else => err.f_message orelse "unknown error",
    };
}

// ---- tests ---------------------------------------------------------------------------------

fn tmpPath(a: std.mem.Allocator, name: []const u8) ![:0]u8 {
    const dir = glib.Dir.makeTmp("dkde-config-XXXXXX", null) orelse return error.NoTmp;
    defer glib.free(dir);
    return std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ std.mem.span(dir), name }, 0);
}

fn fileText(a: std.mem.Allocator, path: [:0]const u8) ![]u8 {
    var contents: [*]u8 = undefined;
    var length: usize = 0;
    if (glib.fileGetContents(path, &contents, &length, null) == 0) return a.dupe(u8, "");
    defer glib.free(contents);
    return a.dupe(u8, contents[0..length]);
}

fn writeText(path: [:0]const u8, text: []const u8) void {
    _ = glib.fileSetContents(path, text.ptr, @intCast(text.len), null);
}

fn testConfig(a: std.mem.Allocator, path: [:0]const u8) !Config {
    var cfg = try Config.load(a, "user.toml");
    cfg.user_path_override = path;
    try cfg.reload();
    return cfg;
}

test "missing file and keys fall back to defaults" {
    const a = std.testing.allocator;
    var cfg = try Config.load(a, "does-not-exist.toml");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(i32, 40), cfg.getInt("panel", "height", 40));
    try std.testing.expectEqual(true, cfg.getBool("panel", "visible", true));
    const s = try cfg.getString(a, "panel", "clock-format", "%H:%M");
    defer a.free(s);
    try std.testing.expectEqualStrings("%H:%M", s);
}

test "user values overlay system defaults" {
    const a = std.testing.allocator;
    var base = try toml.Document.parse(a, "[panel]\nheight = 40\nextra = 1\n", .{}, null);
    defer base.deinit();
    var over = try toml.Document.parse(a, "[panel]\nheight = 48\n[new]\nk = \"v\"\n", .{}, null);
    defer over.deinit();
    try mergeInto(&base, &over);
    try std.testing.expectEqual(@as(i64, 48), base.root.lookup("panel.height").?.integer);
    try std.testing.expectEqual(@as(i64, 1), base.root.lookup("panel.extra").?.integer);
    try std.testing.expectEqualStrings("v", base.root.lookup("new.k").?.string);
}

test "writing a value keeps the rest of the user file and reads back" {
    const a = std.testing.allocator;
    const path = try tmpPath(a, "user.toml");
    defer a.free(path);
    writeText(path, "[panel]\nheight = 48\nclock-format = \"%H\"\nfuture-key = [1, 2]\n");
    var cfg = try testConfig(a, path);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(i32, 48), cfg.getInt("panel", "height", 40));

    try cfg.setInt("panel", "height", 64);
    try cfg.setBool("menu", "flag", true);
    try cfg.setStringList("menu", "pinned", &.{ "a.desktop", "b.desktop" });

    try std.testing.expectEqual(@as(i32, 64), cfg.getInt("panel", "height", 40));
    try std.testing.expectEqual(true, cfg.getBool("menu", "flag", false));
    const list = (try cfg.getStringList(a, "menu", "pinned")).?;
    defer freeStringList(a, list);
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("b.desktop", list[1]);
    const clock = try cfg.getString(a, "panel", "clock-format", "x");
    defer a.free(clock);
    try std.testing.expectEqualStrings("%H", clock);

    // A key this program does not know is still in the file.
    const text = try fileText(a, path);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "future-key = [1, 2]") != null);

    try cfg.removeGroup("menu");
    try std.testing.expect((try cfg.getStringList(a, "menu", "pinned")) == null);
    _ = std.c.unlink(path);
}

test "a value already in effect is not written, and a file is not created for nothing" {
    const a = std.testing.allocator;
    const path = try tmpPath(a, "user.toml");
    defer a.free(path);
    var cfg = try testConfig(a, path);
    defer cfg.deinit();

    try cfg.setInt("panel", "height", 48);
    const first = try fileText(a, path);
    defer a.free(first);
    try std.testing.expect(first.len > 0);
    try cfg.setInt("panel", "height", 48);
    const second = try fileText(a, path);
    defer a.free(second);
    try std.testing.expectEqualStrings(first, second);
    _ = std.c.unlink(path);

    try cfg.reload();
    try setValue(&cfg.doc, "panel", "width", .{ .integer = 10 }); // stands for a system default
    try cfg.setInt("panel", "width", 10);
    const none = try fileText(a, path);
    defer a.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "a malformed user file is not overwritten" {
    const a = std.testing.allocator;
    const path = try tmpPath(a, "user.toml");
    defer a.free(path);
    const broken = "[panel]\nheight = 48\nheight = 49\n"; // duplicate key
    writeText(path, broken);
    var cfg = try testConfig(a, path);
    defer cfg.deinit();

    // Reads fall back to the defaults...
    try std.testing.expectEqual(@as(i32, 40), cfg.getInt("panel", "height", 40));
    try std.testing.expect(cfg.user_malformed);
    // ...and writes are refused instead of replacing the user's text.
    try std.testing.expectError(error.MalformedConfig, cfg.setInt("panel", "height", 64));
    try std.testing.expectError(error.MalformedConfig, cfg.setString("x", "y", "z"));
    const after = try fileText(a, path);
    defer a.free(after);
    try std.testing.expectEqualStrings(broken, after);

    // Fixing the file makes it usable again.
    writeText(path, "[panel]\nheight = 50\n");
    try cfg.reload();
    try std.testing.expect(!cfg.user_malformed);
    try std.testing.expectEqual(@as(i32, 50), cfg.getInt("panel", "height", 40));
    _ = std.c.unlink(path);
}

test "wrong types use the default instead of failing" {
    const a = std.testing.allocator;
    const path = try tmpPath(a, "user.toml");
    defer a.free(path);
    writeText(path, "[g]\nnum = \"abc\"\nflag = 3\nbig = 99999999999\ntext = 5\nlist = \"x\"\n");
    var cfg = try testConfig(a, path);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(i32, 7), cfg.getInt("g", "num", 7));
    try std.testing.expectEqual(true, cfg.getBool("g", "flag", true));
    try std.testing.expectEqual(@as(i32, 7), cfg.getInt("g", "big", 7));
    const text = try cfg.getString(a, "g", "text", "d");
    defer a.free(text);
    try std.testing.expectEqualStrings("5", text); // an integer reads as text
    try std.testing.expect((try cfg.getStringList(a, "g", "list")) == null);
    _ = std.c.unlink(path);
}

test "group names with a colon and prefix listing" {
    const a = std.testing.allocator;
    const path = try tmpPath(a, "user.toml");
    defer a.free(path);
    var cfg = try testConfig(a, path);
    defer cfg.deinit();
    try cfg.setString("profile:Work", "font", "Mono 10");
    try cfg.setString("profile:Home", "font", "Mono 12");
    try cfg.setString("terminal", "default-profile", "Work");
    const names = try cfg.groupsWithPrefix(a, "profile:");
    defer freeStringList(a, names);
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("Work", names[0]);
    _ = std.c.unlink(path);
}

test "setGroup replaces a whole group in one write" {
    const a = std.testing.allocator;
    const path = try tmpPath(a, "user.toml");
    defer a.free(path);
    writeText(path, "[context-commands]\nOld = \"x\"\n[keep]\nk = 1\n");
    var cfg = try testConfig(a, path);
    defer cfg.deinit();
    try cfg.setGroup("context-commands", &.{.{ .key = "New", .value = "y %f" }});
    const s = try cfg.getString(a, "context-commands", "Old", "gone");
    defer a.free(s);
    try std.testing.expectEqualStrings("gone", s);
    try std.testing.expectEqual(@as(i32, 1), cfg.getInt("keep", "k", 0));
    _ = std.c.unlink(path);
}

test "staged changes show at once and are written only on apply" {
    const a = std.testing.allocator;
    const path = try tmpPath(a, "user.toml");
    defer a.free(path);
    const initial = "[panel]\nheight = 48\n";
    writeText(path, initial);
    var cfg = try testConfig(a, path);
    defer cfg.deinit();
    var changes: usize = 0;
    cfg.stage(usize, struct {
        fn note(p: *usize) void {
            p.* += 1;
        }
    }.note, &changes);

    try cfg.setInt("panel", "height", 64);
    try cfg.setString("panel", "clock-format", "%H");
    try std.testing.expectEqual(@as(usize, 2), cfg.pendingCount());
    try std.testing.expectEqual(@as(i32, 64), cfg.getInt("panel", "height", 0));
    const before = try fileText(a, path);
    defer a.free(before);
    try std.testing.expectEqualStrings(initial, before);
    try cfg.reload(); // a file event keeps the staged values
    try std.testing.expectEqual(@as(i32, 64), cfg.getInt("panel", "height", 0));

    try cfg.discard();
    try std.testing.expectEqual(@as(i32, 48), cfg.getInt("panel", "height", 0));
    try std.testing.expectEqual(@as(usize, 0), cfg.pendingCount());

    try cfg.setInt("panel", "height", 70);
    try cfg.apply();
    try std.testing.expectEqual(@as(usize, 0), cfg.pendingCount());
    const after = try fileText(a, path);
    defer a.free(after);
    try std.testing.expect(std.mem.indexOf(u8, after, "height = 70") != null);
    try std.testing.expect(changes >= 3);
    _ = std.c.unlink(path);
}

test "two configs saving different keys do not lose each other's change" {
    const a = std.testing.allocator;
    const path = try tmpPath(a, "user.toml");
    defer a.free(path);
    var first = try testConfig(a, path);
    defer first.deinit();
    var second = try testConfig(a, path);
    defer second.deinit();
    // Both loaded the (empty) state before either saved.
    try first.setInt("a", "x", 1);
    try second.setInt("b", "y", 2); // reads the file again under the lock
    try first.reload();
    try std.testing.expectEqual(@as(i32, 1), first.getInt("a", "x", 0));
    try std.testing.expectEqual(@as(i32, 2), first.getInt("b", "y", 0));
    _ = std.c.unlink(path);
}

test "defaults fill a missing file, then only add what is missing" {
    const a = std.testing.allocator;
    const dirfile = try tmpPath(a, "system.toml");
    defer a.free(dirfile);
    const dir = std.fs.path.dirname(dirfile).?;
    const user = try std.fmt.allocPrintSentinel(a, "{s}/sub/user.toml", .{dir}, 0);
    defer a.free(user);
    writeText(dirfile, "# comment\n[panel]\nheight = 40\nposition = \"bottom\"\n");

    try std.testing.expectEqual(Written.created, try mergeDefaults(a, dirfile, user, "[extra]\nk = 1\n"));
    const first = try fileText(a, user);
    defer a.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, "# comment") != null and std.mem.indexOf(u8, first, "k = 1") != null);
    try std.testing.expectEqual(Written.unchanged, try mergeDefaults(a, dirfile, user, "[extra]\nk = 1\n"));

    writeText(user, "# mine\n[panel]\nheight = 64 # tall\n");
    try std.testing.expectEqual(Written.merged, try mergeDefaults(a, dirfile, user, ""));
    const second = try fileText(a, user);
    defer a.free(second);
    try std.testing.expect(std.mem.indexOf(u8, second, "height = 64 # tall") != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "# mine") != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "position = \"bottom\"") != null);
    _ = std.c.unlink(user);
}

test "saving a setting keeps the file's comments" {
    const a = std.testing.allocator;
    const path = try tmpPath(a, "user.toml");
    defer a.free(path);
    writeText(path, "# mine\n[a]\n# the x\nx = \"old\" # why\n\n# the y\ny = 2\n");
    var cfg = try testConfig(a, path);
    defer cfg.deinit();
    try cfg.setString("a", "x", "new");
    try cfg.setBool("a", "z", true);
    try cfg.setInt("b", "n", 3);
    const text = try fileText(a, path);
    defer a.free(text);
    try std.testing.expectEqualStrings("# mine\n[a]\n# the x\nx = \"new\" # why\n\n# the y\ny = 2\nz = true\n\n[b]\nn = 3\n", text);
    _ = std.c.unlink(path);
}

test "a layout the text editor does not handle still keeps comments (rewritten from the document)" {
    const a = std.testing.allocator;
    const path = try tmpPath(a, "user.toml");
    defer a.free(path);
    // An array of tables makes tomltext give up, so the document is written back.
    writeText(path, "# mine\n[a]\n# the x\nx = 1 # why\n\n# first\n[[items]]\nn = 1\n");
    var cfg = try testConfig(a, path);
    defer cfg.deinit();
    try cfg.setInt("a", "x", 2);
    const text = try fileText(a, path);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "# mine\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "# the x\nx = 2 # why") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "# first\n[[items]]") != null);
    _ = std.c.unlink(path);
}

test "the shipped defaults parse" {
    // Every data/*.toml must be valid TOML with only [group] tables at the top.
    const a = std.testing.allocator;
    inline for (.{ "dkde", "panel", "term", "files", "edit", "calendar" }) |name| {
        const text = @embedFile("data-" ++ name ++ ".toml");
        var doc = toml.Document.parse(a, text, .{}, null) catch |e| {
            std.debug.print("data/{s}.toml: {s}\n", .{ name, @errorName(e) });
            return e;
        };
        defer doc.deinit();
        for (doc.root.entries.values()) |v| try std.testing.expect(v == .table);
    }
}
