//! Lock and sleep commands (SPEC.md 5.1). dkde has no lock screen of its own
//! (see the spec) and no logind to ask, so both are commands: the configured
//! one, or the first usual tool that is installed.

const std = @import("std");
const glib = @import("glib2");
const appinfo = @import("appinfo.zig");
const Config = @import("config.zig").Config;

/// What can be asked of the system: whether a program is on PATH, and whether
/// logind (or elogind) is running.
pub const Probe = struct {
    context: ?*anyopaque = null,
    has_program: *const fn (?*anyopaque, []const u8) bool,
    has_logind: *const fn (?*anyopaque) bool,
};

/// The first locker found, or null when there is none.
pub fn detectLock(p: Probe) ?[]const u8 {
    return detectLockFor(p, std.c.getenv("WAYLAND_DISPLAY") != null or std.c.getenv("DISPLAY") == null);
}

/// The lockers that fit the session: Wayland ones on Wayland, X11 ones on X11.
pub fn detectLockFor(p: Probe, wayland: bool) ?[]const u8 {
    const wayland_lockers = [_][]const u8{ "swaylock", "gtklock", "waylock", "swaylock-effects" };
    const x11_lockers = [_][]const u8{ "xsecurelock", "i3lock", "slock", "xlock" };
    const candidates: []const []const u8 = if (wayland) &wayland_lockers else &x11_lockers;
    for (candidates) |c| if (p.has_program(p.context, c)) return c;
    return null;
}

/// How to suspend this machine: logind when it runs, then the usual helpers
/// of systems without it.
pub fn detectSleep(p: Probe) ?[]const u8 {
    if (p.has_logind(p.context) and p.has_program(p.context, "loginctl")) return "loginctl suspend";
    if (p.has_program(p.context, "zzz")) return "zzz";
    if (p.has_program(p.context, "pm-suspend")) return "pm-suspend";
    if (p.has_program(p.context, "systemctl")) return "systemctl suspend";
    return null;
}

/// How to power off: through logind (or elogind) when it runs, which authorizes
/// an active local session itself (no password); the bare command otherwise.
pub fn detectPoweroff(p: Probe) ?[]const u8 {
    if (p.has_logind(p.context) and p.has_program(p.context, "loginctl")) return "loginctl poweroff";
    return "poweroff";
}

/// How to restart: see `detectPoweroff`.
pub fn detectReboot(p: Probe) ?[]const u8 {
    if (p.has_logind(p.context) and p.has_program(p.context, "loginctl")) return "loginctl reboot";
    return "reboot";
}

pub const Detect = *const fn (Probe) ?[]const u8;

/// The command for `key` in `[menu]` of panel.toml, else the detected one.
/// The caller frees it. Null when there is nothing to run.
pub fn resolve(allocator: std.mem.Allocator, cfg: *const Config, key: [:0]const u8, detect: Detect) ?[]u8 {
    const configured = cfg.getString(allocator, "menu", key, "") catch return null;
    if (configured.len > 0) return configured;
    allocator.free(configured);
    const found = detect(system_probe) orelse return null;
    return allocator.dupe(u8, found) catch null;
}

/// Starts the lock or sleep command; false when there is none or it cannot be parsed.
pub fn run(allocator: std.mem.Allocator, cfg: *const Config, key: [:0]const u8, detect: Detect) bool {
    const command = resolve(allocator, cfg, key, detect) orelse return false;
    defer allocator.free(command);
    const z = allocator.dupeSentinel(u8, command, 0) catch return false;
    defer allocator.free(z);
    var argc: c_int = 0;
    var argv: [*:null]?[*:0]u8 = undefined;
    if (glib.shellParseArgv(z, &argc, &argv, null) == 0) return false;
    defer glib.strfreev(argv);
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(allocator);
    for (argv[0..@intCast(argc)]) |arg| list.append(allocator, std.mem.span(arg.?)) catch return false;
    appinfo.spawn(allocator, list.items);
    return true;
}

// ---- battery and dimming -------------------------------------------------------------------------------

/// True when a battery reports "Discharging" (so the machine is running on it). `DKDE_SYSFS_ROOT` replaces /sys, for tests.
pub fn onBattery() bool {
    const root = if (glib.getenv("DKDE_SYSFS_ROOT")) |r| std.mem.span(r) else "/sys";
    var n: u8 = 0;
    while (n < 4) : (n += 1) {
        var path_buf: [192]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&path_buf, "{s}/class/power_supply/BAT{d}/status", .{ root, n }, 0) catch continue;
        var contents: [*]u8 = undefined;
        var len: usize = 0;
        if (glib.fileGetContents(path, &contents, &len, null) == 0) continue;
        defer glib.free(contents);
        if (std.mem.startsWith(u8, std.mem.trim(u8, contents[0..len], " \n"), "Discharging")) return true;
    }
    return false;
}

/// The `[power]` key that holds a timeout: the ordinary one, or its "-battery" twin when the machine runs on
/// a battery and the settings keep separate times for that.
pub fn timeoutKey(buf: []u8, key: []const u8, on_battery: bool, separate: bool) []const u8 {
    if (on_battery and separate) return std.fmt.bufPrint(buf, "{s}-battery", .{key}) catch key;
    return key;
}

pub const Brightness = enum { brightnessctl, light };

pub fn detectBrightness(p: Probe) ?Brightness {
    if (p.has_program(p.context, "brightnessctl")) return .brightnessctl;
    if (p.has_program(p.context, "light")) return .light;
    return null;
}

/// The command that dims the backlight to `percent` (and remembers the old level), and the one that restores it.
pub fn dimCommand(buf: []u8, tool: Brightness, percent: u32) []const u8 {
    return switch (tool) {
        .brightnessctl => std.fmt.bufPrint(buf, "brightnessctl -s set {d}%", .{percent}) catch "",
        .light => std.fmt.bufPrint(buf, "light -O && light -S {d}", .{percent}) catch "",
    };
}

pub fn restoreCommand(tool: Brightness) []const u8 {
    return switch (tool) {
        .brightnessctl => "brightnessctl -r",
        .light => "light -I",
    };
}

test "battery keys and dim commands" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("lock-after-battery", timeoutKey(&buf, "lock-after", true, true));
    try std.testing.expectEqualStrings("lock-after", timeoutKey(&buf, "lock-after", true, false));
    try std.testing.expectEqualStrings("lock-after", timeoutKey(&buf, "lock-after", false, true));
    try std.testing.expectEqualStrings("brightnessctl -s set 30%", dimCommand(&buf, .brightnessctl, 30));
    try std.testing.expectEqualStrings("brightnessctl -r", restoreCommand(.brightnessctl));
}

fn realHasProgram(_: ?*anyopaque, name: []const u8) bool {
    var buf: [64]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{name}, 0) catch return false;
    const found = glib.findProgramInPath(z) orelse return false;
    glib.free(found);
    return true;
}

fn realHasLogind(_: ?*anyopaque) bool {
    // systemd-logind and elogind both create /run/systemd/seats.
    return glib.fileTest("/run/systemd/seats", .{ .exists = true }) != 0;
}

pub const system_probe: Probe = .{ .has_program = realHasProgram, .has_logind = realHasLogind };

test "lock tool is the first one found" {
    const Fake = struct {
        fn has(_: ?*anyopaque, name: []const u8) bool {
            return std.mem.eql(u8, name, "gtklock") or std.mem.eql(u8, name, "waylock");
        }
        fn logind(_: ?*anyopaque) bool {
            return false;
        }
    };
    const p: Probe = .{ .has_program = Fake.has, .has_logind = Fake.logind };
    try std.testing.expectEqualStrings("gtklock", detectLockFor(p, true).?);
}

test "sleep prefers logind, then the helpers" {
    const Fake = struct {
        var logind_on = true;
        fn has(_: ?*anyopaque, name: []const u8) bool {
            return std.mem.eql(u8, name, "loginctl") or std.mem.eql(u8, name, "zzz");
        }
        fn logind(_: ?*anyopaque) bool {
            return logind_on;
        }
    };
    const p: Probe = .{ .has_program = Fake.has, .has_logind = Fake.logind };
    try std.testing.expectEqualStrings("loginctl suspend", detectSleep(p).?);
    Fake.logind_on = false;
    try std.testing.expectEqualStrings("zzz", detectSleep(p).?);
    const none: Probe = .{ .has_program = struct {
        fn f(_: ?*anyopaque, _: []const u8) bool {
            return false;
        }
    }.f, .has_logind = Fake.logind };
    try std.testing.expect(detectSleep(none) == null);
    try std.testing.expect(detectLockFor(none, true) == null and detectLockFor(none, false) == null);
    // On X11 the X lockers are the ones that count.
    const x_only: Probe = .{ .has_program = struct {
        fn f(_: ?*anyopaque, name: []const u8) bool {
            return std.mem.eql(u8, name, "i3lock") or std.mem.eql(u8, name, "swaylock");
        }
    }.f, .has_logind = Fake.logind };
    try std.testing.expectEqualStrings("i3lock", detectLockFor(x_only, false).?);
    try std.testing.expectEqualStrings("swaylock", detectLockFor(x_only, true).?);
}

test "power off and restart go through logind when it runs" {
    const Fake = struct {
        var on = true;
        fn has(_: ?*anyopaque, name: []const u8) bool {
            return std.mem.eql(u8, name, "loginctl");
        }
        fn logind(_: ?*anyopaque) bool {
            return on;
        }
    };
    const p: Probe = .{ .has_program = Fake.has, .has_logind = Fake.logind };
    try std.testing.expectEqualStrings("loginctl poweroff", detectPoweroff(p).?);
    try std.testing.expectEqualStrings("loginctl reboot", detectReboot(p).?);
    Fake.on = false;
    try std.testing.expectEqualStrings("poweroff", detectPoweroff(p).?);
    try std.testing.expectEqualStrings("reboot", detectReboot(p).?);
}
