//! INI-style configuration on top of `GKeyFile` (SPEC.md 6.1).
//!
//! A `Config` is the system defaults overlaid with the user's file, so the
//! user's file only has to hold what they changed. Missing or invalid values
//! fall back to the caller's default and log a warning; they never fail.

const std = @import("std");
const glib = @import("glib2");
const gio = @import("gio2");
const gobject = @import("gobject2");

const paths = @import("paths.zig");

const log = std.log.scoped(.config);

pub const Config = struct {
    allocator: std.mem.Allocator,
    /// File name inside the dkde directories, e.g. "panel.conf".
    name: []const u8,
    keyfile: *glib.KeyFile,
    monitor: ?*gio.FileMonitor = null,
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
            .keyfile = glib.KeyFile.new(),
        };
        errdefer self.deinit();
        try self.reload();
        return self;
    }

    fn userPath(self: *const Config) ![:0]u8 {
        if (self.user_path_override) |path| return self.allocator.dupeSentinel(u8, path, 0);
        return paths.userConfigFile(self.allocator, self.name);
    }

    pub fn deinit(self: *Config) void {
        if (self.monitor) |m| {
            _ = m.cancel();
            m.as(gobject.Object).unref();
        }
        if (self.watch_ctx) |ctx| self.watch_free.?(self.allocator, ctx);
        self.clearOps();
        self.ops.deinit(self.allocator);
        self.keyfile.free();
        self.allocator.free(self.name);
        self.* = undefined;
    }

    /// Re-reads the system defaults and then the user's file on top of them.
    pub fn reload(self: *Config) !void {
        const fresh = glib.KeyFile.new();
        errdefer fresh.free();

        if (try paths.systemDataFile(self.allocator, self.name)) |path| {
            defer self.allocator.free(path);
            mergeFile(fresh, path);
        }
        const user_path = try self.userPath();
        defer self.allocator.free(user_path);
        mergeFile(fresh, user_path);

        self.keyfile.free();
        self.keyfile = fresh;
        // Staged changes are not on disk yet: keep them on top.
        if (self.staged) for (self.ops.items) |op| applyOp(self.keyfile, op);
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

    fn applyOp(file: *glib.KeyFile, op: Op) void {
        switch (op) {
            .string => |o| file.setString(o.group, o.key, o.value),
            .int => |o| file.setInteger(o.group, o.key, o.value),
            .boolean => |o| file.setBoolean(o.group, o.key, @intFromBool(o.value)),
            .list => |o| {
                const z = std.heap.c_allocator.alloc(?[*:0]const u8, o.values.len + 1) catch return;
                defer std.heap.c_allocator.free(z);
                for (o.values, 0..) |v, i| z[i] = v.ptr;
                z[o.values.len] = null;
                file.setStringList(o.group, o.key, @ptrCast(z.ptr), o.values.len);
            },
            .remove_group => |g| _ = file.removeGroup(g, null),
        }
    }

    /// Queues `op` and shows its effect in memory.
    fn queue(self: *Config, op: Op) !void {
        try self.ops.append(self.allocator, op);
        applyOp(self.keyfile, op);
        self.notifyStaged();
    }

    /// Writes the queued changes to the user's file (only what changed).
    pub fn apply(self: *Config) !void {
        if (self.ops.items.len == 0) return;
        const user = try self.loadUserFile();
        defer user.file.free();
        for (self.ops.items) |op| applyOp(user.file, op);
        self.clearOps();
        self.notifyStaged();
        try self.saveUserFile(user);
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
        const path = try self.userPath();
        defer self.allocator.free(path);

        // The directory has to exist for the monitor to see the file appear.
        const dir = glib.pathGetDirname(path);
        defer glib.free(dir);
        _ = glib.mkdirWithParents(dir, 0o755);

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

    pub fn getBool(self: *const Config, group: [:0]const u8, key: [:0]const u8, default: bool) bool {
        var err: ?*glib.Error = null;
        const v = self.keyfile.getBoolean(group, key, &err);
        if (self.failed(group, key, err)) return default;
        return v != 0;
    }

    pub fn getInt(self: *const Config, group: [:0]const u8, key: [:0]const u8, default: i32) i32 {
        var err: ?*glib.Error = null;
        const v = self.keyfile.getInteger(group, key, &err);
        if (self.failed(group, key, err)) return default;
        return v;
    }

    /// Returns a copy owned by the caller, or `default` duplicated when the
    /// key is missing.
    pub fn getString(self: *const Config, allocator: std.mem.Allocator, group: [:0]const u8, key: [:0]const u8, default: []const u8) ![]u8 {
        var err: ?*glib.Error = null;
        const v = self.keyfile.getString(group, key, &err);
        if (self.failed(group, key, err) or v == null) return allocator.dupe(u8, default);
        defer glib.free(v);
        return allocator.dupe(u8, std.mem.span(v.?));
    }

    /// A copy of a `;`-separated list, or null when the key is missing. Free
    /// with `freeStringList`.
    pub fn getStringList(self: *const Config, allocator: std.mem.Allocator, group: [:0]const u8, key: [:0]const u8) !?[][]u8 {
        var err: ?*glib.Error = null;
        var len: usize = 0;
        const list = self.keyfile.getStringList(group, key, &len, &err);
        if (self.failed(group, key, err) or list == null) return null;
        defer glib.strfreev(list);

        var out: std.ArrayList([]u8) = .empty;
        errdefer freeStringList(allocator, out.items);
        for (list.?[0..len]) |item| try out.append(allocator, try allocator.dupe(u8, std.mem.span(item.?)));
        return try out.toOwnedSlice(allocator);
    }

    /// Writes one value into the user's file, keeping everything else in it,
    /// then reloads. The settings app and the file manager's bookmarks use
    /// this; running components pick the change up through their monitors.
    pub fn setString(self: *Config, group: [:0]const u8, key: [:0]const u8, value: [:0]const u8) !void {
        // A value that is already in effect is not written.
        if (self.keyfile.getString(group, key, null)) |cur| {
            defer glib.free(cur);
            if (std.mem.eql(u8, std.mem.span(cur), value)) return;
        }
        if (self.staged) return self.queue(.{ .string = .{
            .group = try self.allocator.dupeSentinel(u8, group, 0),
            .key = try self.allocator.dupeSentinel(u8, key, 0),
            .value = try self.allocator.dupeSentinel(u8, value, 0),
        } });
        const user = try self.loadUserFile();
        defer user.file.free();
        user.file.setString(group, key, value);
        try self.saveUserFile(user);
    }

    pub fn setInt(self: *Config, group: [:0]const u8, key: [:0]const u8, value: i32) !void {
        if (self.keyfile.hasKey(group, key, null) != 0 and self.keyfile.getInteger(group, key, null) == value) return;
        if (self.staged) return self.queue(.{ .int = .{
            .group = try self.allocator.dupeSentinel(u8, group, 0),
            .key = try self.allocator.dupeSentinel(u8, key, 0),
            .value = value,
        } });
        const user = try self.loadUserFile();
        defer user.file.free();
        user.file.setInteger(group, key, value);
        try self.saveUserFile(user);
    }

    pub fn setBool(self: *Config, group: [:0]const u8, key: [:0]const u8, value: bool) !void {
        if (self.keyfile.hasKey(group, key, null) != 0 and (self.keyfile.getBoolean(group, key, null) != 0) == value) return;
        if (self.staged) return self.queue(.{ .boolean = .{
            .group = try self.allocator.dupeSentinel(u8, group, 0),
            .key = try self.allocator.dupeSentinel(u8, key, 0),
            .value = value,
        } });
        const user = try self.loadUserFile();
        defer user.file.free();
        user.file.setBoolean(group, key, @intFromBool(value));
        try self.saveUserFile(user);
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
        const user = try self.loadUserFile();
        defer user.file.free();

        const z = try self.allocator.alloc(?[*:0]const u8, values.len + 1);
        defer self.allocator.free(z);
        var made: usize = 0;
        defer for (z[0..made]) |p| self.allocator.free(std.mem.span(p.?));
        for (values, 0..) |v, i| {
            z[i] = (try self.allocator.dupeSentinel(u8, v, 0)).ptr;
            made += 1;
        }
        z[values.len] = null;
        user.file.setStringList(group, key, @ptrCast(z.ptr), values.len);
        try self.saveUserFile(user);
    }

    pub const Pair = struct { key: [:0]const u8, value: [:0]const u8 };

    /// Replaces a whole group in the user's file with `pairs` in one write
    /// (one file change, so a watcher reloads once). Not for staged configs.
    pub fn setGroup(self: *Config, group: [:0]const u8, pairs: []const Pair) !void {
        const user = try self.loadUserFile();
        defer user.file.free();
        _ = user.file.removeGroup(group, null);
        for (pairs) |pair| user.file.setString(group, pair.key, pair.value);
        try self.saveUserFile(user);
    }

    pub const GroupItem = struct { group: [:0]const u8, pairs: []const Pair };

    /// `setGroup` for many groups, in one write.
    pub fn setGroups(self: *Config, items: []const GroupItem) !void {
        const user = try self.loadUserFile();
        defer user.file.free();
        for (items) |item| {
            _ = user.file.removeGroup(item.group, null);
            for (item.pairs) |pair| user.file.setString(item.group, pair.key, pair.value);
        }
        try self.saveUserFile(user);
    }

    /// Removes a whole group from the user's file, then reloads.
    pub fn removeGroup(self: *Config, group: [:0]const u8) !void {
        if (self.staged) return self.queue(.{ .remove_group = try self.allocator.dupeSentinel(u8, group, 0) });
        const user = try self.loadUserFile();
        defer user.file.free();
        _ = user.file.removeGroup(group, null);
        try self.saveUserFile(user);
    }

    /// Names of the groups starting with `prefix` (prefix removed), in file
    /// order. Free with `freeStringList`.
    pub fn groupsWithPrefix(self: *const Config, allocator: std.mem.Allocator, prefix: []const u8) ![][]u8 {
        var len: usize = 0;
        const groups = self.keyfile.getGroups(&len);
        defer glib.strfreev(groups);
        var out: std.ArrayList([]u8) = .empty;
        errdefer freeStringList(allocator, out.items);
        for (groups[0..len]) |group| {
            const name = std.mem.span(group.?);
            if (std.mem.startsWith(u8, name, prefix)) try out.append(allocator, try allocator.dupe(u8, name[prefix.len..]));
        }
        return try out.toOwnedSlice(allocator);
    }

    const UserFile = struct { file: *glib.KeyFile, path: [:0]u8, before: [*:0]u8 };

    fn loadUserFile(self: *Config) !UserFile {
        const path = try self.userPath();
        errdefer self.allocator.free(path);
        const file = glib.KeyFile.new();
        _ = file.loadFromFile(path, .{}, null); // a missing file starts empty
        return .{ .file = file, .path = path, .before = file.toData(null, null) orelse return error.OutOfMemory };
    }

    /// Writes the user's file, but only when its content actually changes.
    fn saveUserFile(self: *Config, user: UserFile) !void {
        defer self.allocator.free(user.path);
        defer glib.free(user.before);
        const after = user.file.toData(null, null) orelse return error.OutOfMemory;
        defer glib.free(after);
        if (std.mem.eql(u8, std.mem.span(user.before), std.mem.span(after))) {
            // Nothing to write; the in-memory values are still right.
            return self.reload();
        }
        const dir = glib.pathGetDirname(user.path);
        defer glib.free(dir);
        _ = glib.mkdirWithParents(dir, 0o755);
        var err: ?*glib.Error = null;
        if (user.file.saveToFile(user.path, &err) == 0) {
            log.warn("cannot save {s}: {s}", .{ user.path, errMessage(err) });
            if (err) |e| e.free();
            return error.SaveFailed;
        }
        try self.reload();
    }

    /// Logs and clears `err`. Returns whether the lookup failed.
    fn failed(self: *const Config, group: []const u8, key: []const u8, err: ?*glib.Error) bool {
        const e = err orelse return false;
        defer e.free();
        // A missing key is normal: the default applies without noise.
        if (e.matches(glib.KeyFile.errorQuark(), @backingInt(glib.KeyFileError.key_not_found)) != 0 or
            e.matches(glib.KeyFile.errorQuark(), @backingInt(glib.KeyFileError.group_not_found)) != 0)
            return true;
        log.warn("{s}: [{s}] {s}: {s}; using default", .{ self.name, group, key, errMessage(e) });
        return true;
    }
};

// ---- complete, hand-editable files -------------------------------------------------------------

pub const Written = enum { created, merged, unchanged };

/// A complete `[profile:Default]` for term.conf, which the system defaults do
/// not carry (a system profile could not be deleted by the user).
pub const term_profile_template =
    \\
    \\# A terminal profile. Add more groups named [profile:<name>].
    \\[profile:Default]
    \\# Empty runs your login shell.
    \\command=
    \\# Starting folder; empty is your home.
    \\directory=
    \\font=Monospace 11
    \\color-scheme=campbell
    \\# block, bar or underline
    \\cursor-style=block
    \\# Window title and tab icon; empty uses the program's own.
    \\title=
    \\icon=
    \\tab-color=
    \\# NAME=value pairs separated by ;
    \\environment=
    \\# windowed, maximized or fullscreen
    \\startup=windowed
    \\# always, never or on-success
    \\close-on-exit=always
    \\# Let programs set the clipboard (OSC 52).
    \\osc52=true
    \\# 20 to 100; below 100 the background is see-through.
    \\opacity=100
    \\# Start size; 0 lets the window decide.
    \\columns=0
    \\rows=0
    \\padding=4
    \\copy-on-select=true
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
    var contents: [*]u8 = undefined;
    var length: usize = 0;
    if (glib.fileGetContents(system, &contents, &length, null) == 0) return error.NoSystemDefaults;
    defer glib.free(contents);

    if (glib.fileTest(user, .{ .exists = true }) == 0) {
        const dir = glib.pathGetDirname(user);
        defer glib.free(dir);
        _ = glib.mkdirWithParents(dir, 0o755);
        const text = try std.mem.concat(allocator, u8, &.{ contents[0..length], extra });
        defer allocator.free(text);
        var err: ?*glib.Error = null;
        if (glib.fileSetContents(user, text.ptr, @intCast(text.len), &err) == 0) {
            if (err) |e| e.free();
            return error.SaveFailed;
        }
        return .created;
    }

    // Add what is missing to the existing file, keeping its comments.
    const have = glib.KeyFile.new();
    defer have.free();
    _ = have.loadFromFile(user, .{ .keep_comments = true }, null);
    const before = have.toData(null, null) orelse return error.OutOfMemory;
    defer glib.free(before);

    const want = glib.KeyFile.new();
    defer want.free();
    const merged_text = try std.mem.concat(allocator, u8, &.{ contents[0..length], extra });
    defer allocator.free(merged_text);
    const z = try allocator.dupeSentinel(u8, merged_text, 0);
    defer allocator.free(z);
    _ = want.loadFromData(z, merged_text.len, .{}, null);

    var n_groups: usize = 0;
    const groups = want.getGroups(&n_groups);
    defer glib.strfreev(groups);
    for (groups[0..n_groups]) |group| {
        var n_keys: usize = 0;
        const keys = want.getKeys(group.?, &n_keys, null) orelse continue;
        defer glib.strfreev(keys);
        for (keys[0..n_keys]) |key| {
            if (have.hasKey(group.?, key.?, null) != 0) continue;
            const value = want.getValue(group.?, key.?, null) orelse continue;
            defer glib.free(value);
            have.setValue(group.?, key.?, value);
        }
    }
    const after = have.toData(null, null) orelse return error.OutOfMemory;
    defer glib.free(after);
    if (std.mem.eql(u8, std.mem.span(before), std.mem.span(after))) return .unchanged;
    var err: ?*glib.Error = null;
    if (have.saveToFile(user, &err) == 0) {
        if (err) |e| e.free();
        return error.SaveFailed;
    }
    return .merged;
}

pub fn freeStringList(allocator: std.mem.Allocator, list: [][]u8) void {
    for (list) |item| allocator.free(item);
    allocator.free(list);
}

/// Merges `path` into `dest`, key by key. A missing file is not an error;
/// an unparsable one is logged and skipped.
fn mergeFile(dest: *glib.KeyFile, path: [:0]const u8) void {
    const src = glib.KeyFile.new();
    defer src.free();

    var err: ?*glib.Error = null;
    if (src.loadFromFile(path, .{}, &err) == 0) {
        if (err) |e| {
            defer e.free();
            if (e.matches(glib.fileErrorQuark(), @backingInt(glib.FileError.noent)) == 0)
                log.warn("ignoring {s}: {s}", .{ path, errMessage(e) });
        }
        return;
    }

    var n_groups: usize = 0;
    const groups = src.getGroups(&n_groups);
    defer glib.strfreev(groups);
    for (groups[0..n_groups]) |group| {
        var n_keys: usize = 0;
        const keys = src.getKeys(group.?, &n_keys, null) orelse continue;
        defer glib.strfreev(keys);
        for (keys[0..n_keys]) |key| {
            const value = src.getValue(group.?, key.?, null) orelse continue;
            defer glib.free(value);
            dest.setValue(group.?, key.?, value);
        }
    }
}

fn errMessage(err: anytype) [*:0]const u8 {
    return switch (@typeInfo(@TypeOf(err))) {
        .optional => if (err) |e| e.f_message orelse "unknown error" else "unknown error",
        else => err.f_message orelse "unknown error",
    };
}

test "missing file and keys fall back to defaults" {
    const allocator = std.testing.allocator;
    var cfg = try Config.load(allocator, "does-not-exist.conf");
    defer cfg.deinit();

    try std.testing.expectEqual(@as(i32, 40), cfg.getInt("panel", "height", 40));
    try std.testing.expectEqual(true, cfg.getBool("panel", "visible", true));
    const s = try cfg.getString(allocator, "panel", "clock-format", "%H:%M");
    defer allocator.free(s);
    try std.testing.expectEqualStrings("%H:%M", s);
}

test "user values overlay system defaults" {
    const allocator = std.testing.allocator;
    const key_file = glib.KeyFile.new();
    defer key_file.free();
    const base = glib.KeyFile.new();
    defer base.free();
    base.setInteger("panel", "height", 40);
    base.setInteger("panel", "extra", 1);
    key_file.setInteger("panel", "height", 48);

    // mergeFile reads from disk; round-trip the overlay through a temp file.
    const tmp = try std.fmt.allocPrintSentinel(allocator, "{s}/dkde-config-test.conf", .{std.mem.span(glib.getTmpDir())}, 0);
    defer allocator.free(tmp);
    _ = key_file.saveToFile(tmp, null);
    defer _ = std.c.unlink(tmp);
    mergeFile(base, tmp);

    try std.testing.expectEqual(@as(c_int, 48), base.getInteger("panel", "height", null));
    try std.testing.expectEqual(@as(c_int, 1), base.getInteger("panel", "extra", null));
}

test "writing a value keeps the rest of the user file and reads back" {
    const a = std.testing.allocator;
    const dir = glib.Dir.makeTmp("dkde-config-XXXXXX", null) orelse return error.NoTmp;
    defer glib.free(dir);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/user.conf", .{std.mem.span(dir)}, 0);
    defer a.free(path);
    const initial = "# my notes\n[panel]\nheight=48\nclock-format=%H\n";
    _ = glib.fileSetContents(path, initial.ptr, initial.len, null);

    var cfg = try Config.load(a, "user.conf");
    defer cfg.deinit();
    cfg.user_path_override = path;
    try cfg.reload();
    try std.testing.expectEqual(@as(i32, 48), cfg.getInt("panel", "height", 40));

    try cfg.setInt("panel", "height", 64);
    try cfg.setBool("menu", "flag", true);
    try cfg.setStringList("menu", "pinned", &.{ "a.desktop", "b.desktop" });

    // Everything round-trips through a fresh load...
    try std.testing.expectEqual(@as(i32, 64), cfg.getInt("panel", "height", 40));
    try std.testing.expectEqual(true, cfg.getBool("menu", "flag", false));
    const list = (try cfg.getStringList(a, "menu", "pinned")).?;
    defer freeStringList(a, list);
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("b.desktop", list[1]);
    // ...and untouched keys survive.
    const clock = try cfg.getString(a, "panel", "clock-format", "x");
    defer a.free(clock);
    try std.testing.expectEqualStrings("%H", clock);

    try cfg.removeGroup("menu");
    try std.testing.expect((try cfg.getStringList(a, "menu", "pinned")) == null);
    _ = std.c.unlink(path);
}

fn fileText(a: std.mem.Allocator, path: [:0]const u8) ![]u8 {
    var contents: [*]u8 = undefined;
    var length: usize = 0;
    if (glib.fileGetContents(path, &contents, &length, null) == 0) return a.dupe(u8, "");
    defer glib.free(contents);
    return a.dupe(u8, contents[0..length]);
}

test "a value already in effect is not written, and a file is not created for nothing" {
    const a = std.testing.allocator;
    const dir = glib.Dir.makeTmp("dkde-config-XXXXXX", null) orelse return error.NoTmp;
    defer glib.free(dir);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/user.conf", .{std.mem.span(dir)}, 0);
    defer a.free(path);

    var cfg = try Config.load(a, "user.conf");
    defer cfg.deinit();
    cfg.user_path_override = path;
    try cfg.reload();
    // Nothing set yet: the file does not exist.
    try cfg.setInt("panel", "height", 48);
    const first = try fileText(a, path);
    defer a.free(first);
    try std.testing.expect(first.len > 0);

    // The same value again leaves the file exactly as it was.
    try cfg.setInt("panel", "height", 48);
    const second = try fileText(a, path);
    defer a.free(second);
    try std.testing.expectEqualStrings(first, second);
    _ = std.c.unlink(path);

    // And with no user file, a value equal to the default creates nothing.
    try cfg.reload();
    cfg.keyfile.setInteger("panel", "width", 10); // stands for a system default
    try cfg.setInt("panel", "width", 10);
    const none = try fileText(a, path);
    defer a.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "staged changes show at once and are written only on apply" {
    const a = std.testing.allocator;
    const dir = glib.Dir.makeTmp("dkde-config-XXXXXX", null) orelse return error.NoTmp;
    defer glib.free(dir);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/user.conf", .{std.mem.span(dir)}, 0);
    defer a.free(path);
    const initial = "[panel]\nheight=48\n";
    _ = glib.fileSetContents(path, initial.ptr, initial.len, null);

    var cfg = try Config.load(a, "user.conf");
    defer cfg.deinit();
    cfg.user_path_override = path;
    try cfg.reload();
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
    // Disk is untouched.
    const before = try fileText(a, path);
    defer a.free(before);
    try std.testing.expectEqualStrings(initial, before);
    // A reload (a file event) keeps the staged values.
    try cfg.reload();
    try std.testing.expectEqual(@as(i32, 64), cfg.getInt("panel", "height", 0));

    try cfg.discard();
    try std.testing.expectEqual(@as(i32, 48), cfg.getInt("panel", "height", 0));
    try std.testing.expectEqual(@as(usize, 0), cfg.pendingCount());

    try cfg.setInt("panel", "height", 70);
    try cfg.apply();
    try std.testing.expectEqual(@as(usize, 0), cfg.pendingCount());
    const after = try fileText(a, path);
    defer a.free(after);
    try std.testing.expect(std.mem.indexOf(u8, after, "height=70") != null);
    try std.testing.expect(changes >= 3);
    _ = std.c.unlink(path);
}

test "defaults fill a missing file, then only add what is missing" {
    const a = std.testing.allocator;
    const dir = glib.Dir.makeTmp("dkde-defaults-XXXXXX", null) orelse return error.NoTmp;
    defer glib.free(dir);
    const system = try std.fmt.allocPrintSentinel(a, "{s}/system.conf", .{std.mem.span(dir)}, 0);
    defer a.free(system);
    const user = try std.fmt.allocPrintSentinel(a, "{s}/sub/user.conf", .{std.mem.span(dir)}, 0);
    defer a.free(user);
    const defaults = "# comment\n[panel]\nheight=40\nposition=bottom\n";
    _ = glib.fileSetContents(system, defaults.ptr, defaults.len, null);

    try std.testing.expectEqual(Written.created, try mergeDefaults(a, system, user, "[extra]\nk=1\n"));
    const first = try fileText(a, user);
    defer a.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, "# comment") != null and std.mem.indexOf(u8, first, "k=1") != null);
    // Nothing missing: nothing is written.
    try std.testing.expectEqual(Written.unchanged, try mergeDefaults(a, system, user, "[extra]\nk=1\n"));

    // A hand-edited file keeps its values and gains the missing keys.
    const edited = "[panel]\nheight=64\n";
    _ = glib.fileSetContents(user, edited.ptr, edited.len, null);
    try std.testing.expectEqual(Written.merged, try mergeDefaults(a, system, user, ""));
    const second = try fileText(a, user);
    defer a.free(second);
    try std.testing.expect(std.mem.indexOf(u8, second, "height=64") != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "position=bottom") != null);
    _ = std.c.unlink(user);
}
