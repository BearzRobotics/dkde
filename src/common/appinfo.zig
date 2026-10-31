//! Matching a window's `app_id` to a desktop entry (SPEC.md 4.2). Used by the
//! taskbar and the start menu.

const std = @import("std");
const gio = @import("gio2");
const giounix = @import("giounix2");
const config_mod = @import("config.zig");
const glib = @import("glib2");
const gobject = @import("gobject2");

/// Whether a desktop entry identified by `desktop_id` (e.g. "org.gnome.Nautilus.desktop")
/// and an optional `StartupWMClass` belongs to a window with `app_id`.
/// Comparison is case-insensitive; Wayland clients are inconsistent about case.
pub fn matches(desktop_id: []const u8, wm_class: ?[]const u8, app_id: []const u8) bool {
    if (app_id.len == 0) return false;
    if (wm_class) |class| {
        if (std.ascii.eqlIgnoreCase(class, app_id)) return true;
    }
    const suffix = ".desktop";
    const stem = if (std.mem.endsWith(u8, desktop_id, suffix))
        desktop_id[0 .. desktop_id.len - suffix.len]
    else
        desktop_id;
    return std.ascii.eqlIgnoreCase(stem, app_id);
}

/// Finds the desktop entry for `app_id`, or null. The caller owns the
/// returned reference.
pub fn find(app_id: []const u8) ?*gio.AppInfo {
    if (app_id.len == 0) return null;

    const all = gio.AppInfo.getAll();
    defer all.free();
    var node: ?*glib.List = all;
    while (node) |n| : (node = n.f_next) {
        const info: *gio.AppInfo = @ptrCast(@alignCast(n.f_data orelse continue));
        const id = std.mem.span(info.getId() orelse continue);
        const desktop: *giounix.DesktopAppInfo = @ptrCast(info);
        const wm_class = if (desktop.getStartupWmClass()) |c| std.mem.span(c) else null;
        if (matches(id, wm_class, app_id)) return @ptrCast(info.as(gobject.Object).ref());
    }
    return null;
}

test "matches by desktop id, ignoring case and suffix" {
    try std.testing.expect(matches("org.gnome.Nautilus.desktop", null, "org.gnome.Nautilus"));
    try std.testing.expect(matches("firefox.desktop", null, "Firefox"));
    try std.testing.expect(!matches("firefox.desktop", null, "firefox-esr"));
}

test "matches by StartupWMClass" {
    try std.testing.expect(matches("code.desktop", "Code", "code"));
    try std.testing.expect(matches("x.desktop", "Some-Class", "some-class"));
}

test "empty app_id never matches" {
    try std.testing.expect(!matches("a.desktop", "", ""));
}

/// Starts `argv` detached, searching `PATH`. Logs failures.
pub fn spawn(allocator: std.mem.Allocator, argv: []const []const u8) void {
    spawnIn(allocator, argv, null);
}

/// Like `spawn`, with `cwd` as the working directory.
pub fn spawnIn(allocator: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) void {
    // dkde binaries sit next to each other; this also covers uninstalled builds.
    const sibling = siblingBinary(allocator, argv[0]);
    defer if (sibling) |path| allocator.free(path);

    const z = allocator.alloc(?[*:0]u8, argv.len + 1) catch return;
    defer allocator.free(z);
    var made: usize = 0;
    defer for (z[0..made]) |p| allocator.free(std.mem.span(p.?));
    for (argv, 0..) |arg, i| {
        const copy = allocator.dupeSentinel(u8, if (i == 0) sibling orelse arg else arg, 0) catch return;
        z[i] = copy.ptr;
        made += 1;
    }
    z[argv.len] = null;

    const cwd_z: ?[:0]u8 = if (cwd) |c| allocator.dupeSentinel(u8, c, 0) catch return else null;
    defer if (cwd_z) |c| allocator.free(c);
    var err: ?*glib.Error = null;
    if (glib.spawnAsync(if (cwd_z) |c| c.ptr else null, @ptrCast(z.ptr), null, .{ .search_path = true }, null, null, null, &err) == 0) {
        if (err) |e| {
            std.log.warn("cannot start {s}: {s}", .{ argv[0], e.f_message orelse "unknown error" });
            e.free();
        }
    }
}

/// Launches a desktop entry. `Terminal=true` entries run inside `dkde-term`
/// (SPEC.md 5.2); GIO would pick its own terminal emulator.
pub fn launch(allocator: std.mem.Allocator, info: *gio.AppInfo) void {
    const desktop: *giounix.DesktopAppInfo = @ptrCast(info);
    if (desktop.getBoolean("Terminal") != 0) {
        if (launchInTerminal(allocator, info)) return;
    }
    var err: ?*glib.Error = null;
    if (info.launch(null, null, &err) == 0) {
        if (err) |e| {
            std.log.warn("cannot launch {s}: {s}", .{ info.getName(), e.f_message orelse "unknown error" });
            e.free();
        }
    }
}

fn launchInTerminal(allocator: std.mem.Allocator, info: *gio.AppInfo) bool {
    const commandline = info.getCommandline() orelse return false;
    var argc: c_int = 0;
    var argv: [*:null]?[*:0]u8 = undefined;
    if (glib.shellParseArgv(commandline, &argc, &argv, null) == 0) return false;
    defer glib.strfreev(argv);

    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(allocator);
    const terminal = defaultTerminal(allocator);
    defer if (terminal) |t| allocator.free(t);
    out.appendSlice(allocator, &.{ terminal orelse "dkde-term", "-e" }) catch return false;
    for (argv[0..@intCast(argc)]) |arg| {
        const a = std.mem.span(arg.?);
        // Field codes such as %U have no meaning without files.
        if (a.len == 2 and a[0] == '%') continue;
        out.append(allocator, a) catch return false;
    }
    spawn(allocator, out.items);
    return true;
}

/// The executable of the terminal chosen in Settings (`[default-apps]
/// terminal` in dkde.conf), or null for dkde-term.
fn defaultTerminal(allocator: std.mem.Allocator) ?[]u8 {
    var cfg = config_mod.Config.load(allocator, "dkde.conf") catch return null;
    defer cfg.deinit();
    const id = cfg.getString(allocator, "default-apps", "terminal", "") catch return null;
    defer allocator.free(id);
    if (id.len == 0) return null;
    const idz = allocator.dupeSentinel(u8, id, 0) catch return null;
    defer allocator.free(idz);
    const info = giounix.DesktopAppInfo.new(idz) orelse return null;
    defer info.as(gobject.Object).unref();
    const exe = info.as(gio.AppInfo).getExecutable();
    return allocator.dupe(u8, std.mem.span(exe)) catch null;
}

/// Path of `name` in the directory of the running executable, if it exists.
fn siblingBinary(allocator: std.mem.Allocator, name: []const u8) ?[:0]u8 {
    if (!std.mem.startsWith(u8, name, "dkde-")) return null;
    const exe = glib.fileReadLink("/proc/self/exe", null) orelse return null;
    defer glib.free(exe);
    const dir = glib.pathGetDirname(exe);
    defer glib.free(dir);
    const path = std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ std.mem.span(dir), name }, 0) catch return null;
    if (glib.fileTest(path, .{ .is_executable = true }) == 0) {
        allocator.free(path);
        return null;
    }
    return path;
}

/// The command line of a desktop entry as separate arguments, with the
/// `%U`-style field codes dropped. Each argument is owned by the caller
/// (free with `freeArgv`).
pub fn commandArgv(allocator: std.mem.Allocator, info: *gio.AppInfo) ?[][]u8 {
    const commandline = info.getCommandline() orelse return null;
    var argc: c_int = 0;
    var argv: [*:null]?[*:0]u8 = undefined;
    if (glib.shellParseArgv(commandline, &argc, &argv, null) == 0) return null;
    defer glib.strfreev(argv);

    var out: std.ArrayList([]u8) = .empty;
    errdefer freeArgv(allocator, out.items);
    for (argv[0..@intCast(argc)]) |arg| {
        const a = std.mem.span(arg.?);
        if (a.len == 2 and a[0] == '%') continue;
        const copy = allocator.dupe(u8, a) catch return null;
        out.append(allocator, copy) catch {
            allocator.free(copy);
            return null;
        };
    }
    return out.toOwnedSlice(allocator) catch null;
}

pub fn freeArgv(allocator: std.mem.Allocator, argv: [][]u8) void {
    for (argv) |a| allocator.free(a);
    allocator.free(argv);
}

/// `env VAR=value ...` for the variables a root GUI app needs to find the
/// user's display (sudo clears the environment).
pub fn displayEnvArgs(allocator: std.mem.Allocator, out: *std.ArrayList([]u8)) !void {
    try out.append(allocator, try allocator.dupe(u8, "env"));
    const names = [_][:0]const u8{ "WAYLAND_DISPLAY", "XDG_RUNTIME_DIR", "DISPLAY", "GDK_BACKEND", "XAUTHORITY", "DKDE_DATA_DIR" };
    for (names) |name| {
        const value = glib.getenv(name) orelse continue;
        try out.append(allocator, try std.fmt.allocPrint(allocator, "{s}={s}", .{ name, std.mem.span(value) }));
    }
}
