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
    const candidates = [_][]const u8{ "swaylock", "gtklock", "waylock", "swaylock-effects" };
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

pub const Detect = *const fn (Probe) ?[]const u8;

/// The command for `key` in `[menu]` of panel.conf, else the detected one.
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

fn realHasProgram(_: ?*anyopaque, name: []const u8) bool {
    var buf: [64]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{name}, 0) catch return false;
    const found = glib.findProgramInPath(z) orelse return false;
    glib.free(found);
    return true;
}

fn realHasLogind(_: ?*anyopaque) bool {
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
    try std.testing.expectEqualStrings("gtklock", detectLock(p).?);
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
    try std.testing.expect(detectLock(none) == null);
}
