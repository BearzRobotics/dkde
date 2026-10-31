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
        const user = try self.loadUserFile();
        defer user.file.free();
        user.file.setString(group, key, value);
        try self.saveUserFile(user);
    }

    pub fn setInt(self: *Config, group: [:0]const u8, key: [:0]const u8, value: i32) !void {
        const user = try self.loadUserFile();
        defer user.file.free();
        user.file.setInteger(group, key, value);
        try self.saveUserFile(user);
    }

    pub fn setBool(self: *Config, group: [:0]const u8, key: [:0]const u8, value: bool) !void {
        const user = try self.loadUserFile();
        defer user.file.free();
        user.file.setBoolean(group, key, @intFromBool(value));
        try self.saveUserFile(user);
    }

    pub fn setStringList(self: *Config, group: [:0]const u8, key: [:0]const u8, values: []const []const u8) !void {
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

    /// Removes a whole group from the user's file, then reloads.
    pub fn removeGroup(self: *Config, group: [:0]const u8) !void {
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

    const UserFile = struct { file: *glib.KeyFile, path: [:0]u8 };

    fn loadUserFile(self: *Config) !UserFile {
        const path = try self.userPath();
        errdefer self.allocator.free(path);
        const file = glib.KeyFile.new();
        _ = file.loadFromFile(path, .{}, null); // a missing file starts empty
        return .{ .file = file, .path = path };
    }

    fn saveUserFile(self: *Config, user: UserFile) !void {
        defer self.allocator.free(user.path);
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
