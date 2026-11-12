//! Startup apps: the freedesktop autostart entries (XDG Autostart spec),
//! read from ~/.config/autostart and $XDG_CONFIG_DIRS/autostart (usually
//! /etc/xdg/autostart). The user's file of a name replaces the system's.
//!
//! dkde-panel starts the enabled ones once per session (`runOnce`), so
//! they work whatever the init system is; dkde-tasks lists them, turns them
//! on and off, and adds the user's own commands (`addCommand`).

const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const giounix = @import("giounix2");
const appinfo = @import("appinfo.zig");

pub const Source = enum { user, system };

pub const Entry = struct {
    /// The file name, "foo.desktop": what identifies the entry.
    id: [128]u8 = @splat(0),
    /// Where it was read from.
    path: [512]u8 = @splat(0),
    name: [96]u8 = @splat(0),
    command: [256]u8 = @splat(0),
    icon: [96]u8 = @splat(0),
    enabled: bool = true,
    source: Source = .system,
    /// The user's file replaces one of the system's.
    has_system: bool = false,
    /// Added with dkde-tasks (Add): can be removed.
    added: bool = false,
    /// X-GNOME-Autostart-Delay: seconds to wait before starting.
    delay: u32 = 0,

    pub fn get(field: anytype) []const u8 {
        return std.mem.sliceTo(field, 0);
    }
    pub fn getZ(field: anytype) [:0]const u8 {
        return std.mem.sliceTo(@as([*:0]const u8, @ptrCast(field)), 0);
    }
    pub fn set(field: anytype, value: []const u8) void {
        @memset(field, 0);
        const n = @min(value.len, field.len - 1);
        @memcpy(field[0..n], value[0..n]);
    }
};

/// Whether an entry is meant for this desktop: OnlyShowIn and NotShowIn
/// against $XDG_CURRENT_DESKTOP (a colon-separated list).
pub fn showsIn(only: ?[]const u8, not: ?[]const u8, desktops: []const u8) bool {
    if (only) |names| {
        var it = std.mem.tokenizeScalar(u8, names, ';');
        while (it.next()) |d| if (inList(desktops, d)) return true;
        return false;
    }
    if (not) |names| {
        var it = std.mem.tokenizeScalar(u8, names, ';');
        while (it.next()) |d| if (inList(desktops, d)) return false;
    }
    return true;
}

fn inList(desktops: []const u8, name: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, desktops, ':');
    while (it.next()) |d| if (std.ascii.eqlIgnoreCase(d, name)) return true;
    return false;
}

pub fn currentDesktops() []const u8 {
    return std.mem.span(glib.getenv("XDG_CURRENT_DESKTOP") orelse "dkde");
}

/// ~/.config/autostart
pub fn userDir(buf: []u8) ?[:0]const u8 {
    return std.fmt.bufPrintSentinel(buf, "{s}/autostart", .{std.mem.span(glib.getUserConfigDir())}, 0) catch null;
}

/// Every entry meant for this desktop: the user's first, then the system's
/// that the user has no file of the same name for.
pub fn list(gpa: std.mem.Allocator) std.ArrayList(Entry) {
    var out: std.ArrayList(Entry) = .empty;
    const desktops = currentDesktops();
    var ub: [512]u8 = undefined;
    if (userDir(&ub)) |dir| readDir(gpa, &out, dir, .user, desktops);
    const dirs = glib.getSystemConfigDirs();
    var i: usize = 0;
    while (@intFromPtr(dirs[i]) != 0) : (i += 1) {
        var sb: [512]u8 = undefined;
        const dir = std.fmt.bufPrint(&sb, "{s}/autostart", .{std.mem.span(dirs[i])}) catch continue;
        readDir(gpa, &out, dir, .system, desktops);
    }
    return out;
}

fn readDir(gpa: std.mem.Allocator, out: *std.ArrayList(Entry), dir: []const u8, source: Source, desktops: []const u8) void {
    var zb: [512]u8 = undefined;
    const zdir = std.fmt.bufPrintSentinel(&zb, "{s}", .{dir}, 0) catch return;
    const file = gio.File.newForPath(zdir);
    defer file.as(gobject.Object).unref();
    const children = file.enumerateChildren("standard::name", .{}, null, null) orelse return;
    defer children.as(gobject.Object).unref();
    while (children.nextFile(null, null)) |info| {
        defer info.as(gobject.Object).unref();
        const name = std.mem.span(info.getName());
        if (!std.mem.endsWith(u8, name, ".desktop")) continue;
        // A name seen before (in the user's folder, or an earlier system folder) wins.
        const known = for (out.items) |*e| {
            if (std.mem.eql(u8, Entry.get(&e.id), name)) break e;
        } else null;
        if (known) |e| {
            if (source == .system and e.source == .user) e.has_system = true;
            continue;
        }
        var pb: [768]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&pb, "{s}/{s}", .{ dir, name }, 0) catch continue;
        // A user's file may hide one of the system's even when it is not for
        // this desktop: it is still kept, so the system's stays hidden.
        if (read(path, name, source, desktops)) |e| {
            out.append(gpa, e) catch return;
        } else if (source == .user) {
            var hidden: Entry = .{ .source = .user, .enabled = false };
            Entry.set(&hidden.id, name);
            Entry.set(&hidden.path, path);
            Entry.set(&hidden.name, "");
            out.append(gpa, hidden) catch return;
        }
    }
}

/// Reads one entry; null when it is not for this desktop or its program
/// is not installed (TryExec).
pub fn read(path: [:0]const u8, id: []const u8, source: Source, desktops: []const u8) ?Entry {
    const kf = glib.KeyFile.new();
    defer kf.free();
    if (kf.loadFromFile(path, .{}, null) == 0) return null;
    var e: Entry = .{ .source = source };
    Entry.set(&e.id, id);
    Entry.set(&e.path, path);
    const only = kf.getString("Desktop Entry", "OnlyShowIn", null);
    defer if (only) |x| glib.free(x);
    const not = kf.getString("Desktop Entry", "NotShowIn", null);
    defer if (not) |x| glib.free(x);
    if (!showsIn(if (only) |x| std.mem.span(x) else null, if (not) |x| std.mem.span(x) else null, desktops)) return null;
    if (kf.getString("Desktop Entry", "TryExec", null)) |te| {
        defer glib.free(te);
        const found = glib.findProgramInPath(te) orelse return null;
        glib.free(found);
    }
    inline for (.{ .{ "Name", &e.name, true }, .{ "Exec", &e.command, false }, .{ "Icon", &e.icon, false } }) |f| {
        const v = if (f[2]) kf.getLocaleString("Desktop Entry", f[0], null, null) else kf.getString("Desktop Entry", f[0], null);
        if (v) |x| {
            defer glib.free(x);
            Entry.set(f[1], std.mem.span(x));
        }
    }
    if (Entry.get(&e.name).len == 0 and id.len > ".desktop".len) Entry.set(&e.name, id[0 .. id.len - ".desktop".len]);
    const hidden = kf.getBoolean("Desktop Entry", "Hidden", null) != 0;
    const gnome_off = kf.hasKey("Desktop Entry", "X-GNOME-Autostart-enabled", null) != 0 and
        kf.getBoolean("Desktop Entry", "X-GNOME-Autostart-enabled", null) == 0;
    e.enabled = !hidden and !gnome_off and Entry.get(&e.command).len > 0;
    e.added = kf.getBoolean("Desktop Entry", "X-dkde-Added", null) != 0;
    const delay = kf.getInteger("Desktop Entry", "X-GNOME-Autostart-Delay", null);
    e.delay = @intCast(std.math.clamp(delay, 0, 600));
    return e;
}

pub const Error = error{ Unreadable, Unwritable };

/// Turns an entry on or off: the user's copy (made from the system's file
/// when there is none) gets Hidden set, so the system's file is never touched.
pub fn setEnabled(id: []const u8, on: bool) Error!void {
    var ub: [512]u8 = undefined;
    const dir = userDir(&ub) orelse return error.Unwritable;
    var pb: [768]u8 = undefined;
    const user_path = std.fmt.bufPrintSentinel(&pb, "{s}/{s}", .{ dir, id }, 0) catch return error.Unwritable;
    const kf = glib.KeyFile.new();
    defer kf.free();
    const flags: glib.KeyFileFlags = .{ .keep_comments = true, .keep_translations = true };
    if (kf.loadFromFile(user_path, flags, null) == 0) {
        if (!loadSystem(kf, id, flags)) return error.Unreadable;
    }
    kf.setBoolean("Desktop Entry", "Hidden", @intFromBool(!on));
    if (kf.hasKey("Desktop Entry", "X-GNOME-Autostart-enabled", null) != 0) kf.setBoolean("Desktop Entry", "X-GNOME-Autostart-enabled", @intFromBool(on));
    try save(kf, dir, user_path);
}

fn loadSystem(kf: *glib.KeyFile, id: []const u8, flags: glib.KeyFileFlags) bool {
    const dirs = glib.getSystemConfigDirs();
    var i: usize = 0;
    while (@intFromPtr(dirs[i]) != 0) : (i += 1) {
        var sb: [768]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&sb, "{s}/autostart/{s}", .{ std.mem.span(dirs[i]), id }, 0) catch continue;
        if (kf.loadFromFile(path, flags, null) != 0) return true;
    }
    return false;
}

fn save(kf: *glib.KeyFile, dir: [:0]const u8, path: [:0]const u8) Error!void {
    _ = glib.mkdirWithParents(dir, 0o700);
    var err: ?*glib.Error = null;
    if (kf.saveToFile(path, &err) == 0) {
        if (err) |x| x.free();
        return error.Unwritable;
    }
}

/// The file name for a new entry: the name's letters and digits, made
/// unique among the user's entries ("my-script.desktop", "my-script-2.desktop").
pub fn idFor(buf: []u8, name: []const u8, exists: *const fn ([]const u8) bool) []const u8 {
    var stem_buf: [64]u8 = undefined;
    var n: usize = 0;
    for (name) |c| {
        if (n == stem_buf.len) break;
        if (std.ascii.isAlphanumeric(c)) {
            stem_buf[n] = std.ascii.toLower(c);
            n += 1;
        } else if (n > 0 and stem_buf[n - 1] != '-') {
            stem_buf[n] = '-';
            n += 1;
        }
    }
    while (n > 0 and stem_buf[n - 1] == '-') n -= 1;
    const stem = if (n == 0) "startup" else stem_buf[0..n];
    var i: usize = 1;
    while (i < 1000) : (i += 1) {
        const id = (if (i == 1) std.fmt.bufPrint(buf, "{s}.desktop", .{stem}) else std.fmt.bufPrint(buf, "{s}-{d}.desktop", .{ stem, i })) catch return "startup.desktop";
        if (!exists(id)) return id;
    }
    return "startup.desktop";
}

fn userEntryExists(id: []const u8) bool {
    var ub: [512]u8 = undefined;
    const dir = userDir(&ub) orelse return false;
    var pb: [768]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&pb, "{s}/{s}", .{ dir, id }, 0) catch return false;
    return glib.fileTest(path, .{ .exists = true }) != 0;
}

/// Adds the user's own startup command (or app: `icon` from its entry).
/// Returns the new entry's id.
pub fn addCommand(buf: []u8, name: []const u8, command: []const u8, icon: ?[]const u8, terminal: bool) Error![]const u8 {
    var ub: [512]u8 = undefined;
    const dir = userDir(&ub) orelse return error.Unwritable;
    const id = idFor(buf, name, userEntryExists);
    var pb: [768]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&pb, "{s}/{s}", .{ dir, id }, 0) catch return error.Unwritable;
    const kf = glib.KeyFile.new();
    defer kf.free();
    var nb: [256]u8 = undefined;
    var cb: [1024]u8 = undefined;
    kf.setString("Desktop Entry", "Type", "Application");
    kf.setString("Desktop Entry", "Name", std.fmt.bufPrintSentinel(&nb, "{s}", .{name}, 0) catch return error.Unwritable);
    kf.setString("Desktop Entry", "Exec", std.fmt.bufPrintSentinel(&cb, "{s}", .{command}, 0) catch return error.Unwritable);
    if (icon) |i| if (i.len > 0) {
        var ib: [256]u8 = undefined;
        kf.setString("Desktop Entry", "Icon", std.fmt.bufPrintSentinel(&ib, "{s}", .{i}, 0) catch return error.Unwritable);
    };
    if (terminal) kf.setBoolean("Desktop Entry", "Terminal", 1);
    kf.setBoolean("Desktop Entry", "X-dkde-Added", 1);
    try save(kf, dir, path);
    return id;
}

/// Deletes the user's own file of an entry (one they added).
pub fn remove(id: []const u8) Error!void {
    var ub: [512]u8 = undefined;
    const dir = userDir(&ub) orelse return error.Unwritable;
    var pb: [768]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&pb, "{s}/{s}", .{ dir, id }, 0) catch return error.Unwritable;
    if (glib.unlink(path) != 0) return error.Unwritable;
}

// ---- starting them -----------------------------------------------------------

/// Starts the enabled entries, once per session: dkde-panel calls this when
/// it starts, and it is restarted if it exits, so a mark in the runtime
/// folder (with the compositor's pid, which differs each session) says it
/// was done.
pub fn runOnce(gpa: std.mem.Allocator) void {
    var mb: [512]u8 = undefined;
    const mark = std.fmt.bufPrintSentinel(&mb, "{s}/dkde-autostart.done", .{std.mem.span(glib.getUserRuntimeDir())}, 0) catch return;
    const session = std.mem.span(glib.getenv("LABWC_PID") orelse glib.getenv("WAYLAND_DISPLAY") orelse "");
    var contents: [*]u8 = undefined;
    var length: usize = 0;
    if (glib.fileGetContents(mark, &contents, &length, null) != 0) {
        defer glib.free(contents);
        if (std.mem.eql(u8, std.mem.trim(u8, contents[0..length], "\n"), session)) return;
    }
    var sb: [64]u8 = undefined;
    const text = std.fmt.bufPrintSentinel(&sb, "{s}\n", .{session}, 0) catch return;
    _ = glib.fileSetContents(mark, text.ptr, @intCast(text.len), null);
    run(gpa);
}

/// Starts every enabled entry now (or after its delay).
pub fn run(gpa: std.mem.Allocator) void {
    var entries = list(gpa);
    defer entries.deinit(gpa);
    for (entries.items) |*e| {
        if (!e.enabled) continue;
        std.log.info("autostart: {s}", .{Entry.get(&e.id)});
        if (e.delay == 0) {
            launchPath(gpa, Entry.getZ(&e.path));
            continue;
        }
        const copy = gpa.dupeSentinel(u8, Entry.get(&e.path), 0) catch continue;
        const Later = struct {
            var allocator: std.mem.Allocator = undefined;
            fn fire(data: ?*anyopaque) callconv(.c) c_int {
                const p: [*:0]u8 = @ptrCast(data.?);
                const s = std.mem.span(p);
                launchPath(allocator, s);
                allocator.free(s);
                return 0;
            }
        };
        Later.allocator = gpa;
        _ = glib.timeoutAddSeconds(e.delay, Later.fire, copy.ptr);
    }
}

fn launchPath(gpa: std.mem.Allocator, path: [:0]const u8) void {
    const info = giounix.DesktopAppInfo.newFromFilename(path) orelse {
        std.log.warn("autostart: {s} cannot be read", .{path});
        return;
    };
    defer info.as(gobject.Object).unref();
    appinfo.launch(gpa, info.as(gio.AppInfo));
}

test "entries for this desktop" {
    try std.testing.expect(showsIn(null, null, "dkde"));
    try std.testing.expect(!showsIn("GNOME;X-Cinnamon;", null, "dkde"));
    try std.testing.expect(showsIn("GNOME;dkde;", null, "dkde"));
    try std.testing.expect(!showsIn(null, "KDE;dkde;", "ubuntu:dkde"));
}

test "file names for new entries" {
    const S = struct {
        fn taken(id: []const u8) bool {
            return std.mem.eql(u8, id, "my-script.desktop");
        }
        fn none(_: []const u8) bool {
            return false;
        }
    };
    var b: [96]u8 = undefined;
    try std.testing.expectEqualStrings("my-script-2.desktop", idFor(&b, "My Script!", S.taken));
    try std.testing.expectEqualStrings("startup.desktop", idFor(&b, "!!!", S.none));
}
