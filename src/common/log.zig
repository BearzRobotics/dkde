//! Logging for every dkde program (SPEC.md 6.4). Each program's `main.zig` has
//!
//!     pub const std_options: std.Options = .{ .logFn = common.log.logFn, .log_level = .debug };
//!
//! and the level is chosen at run time from the environment:
//!
//!     DKDE_LOG=debug|info|warn|error   default: warn (errors and warnings)
//!     DKDE_LOG_FILE=/path/file.log     also append to this file
//!     DKDE_LOG_FILE=auto               ... to $XDG_STATE_HOME/dkde/<program>.log
//!
//! Lines go to stderr (which is lost when the session starts a program, hence
//! the file) as "HH:MM:SS level(scope) program[pid]: message". GLib and GTK
//! have their own switch: `G_MESSAGES_DEBUG=all` shows their debug messages.

const std = @import("std");

extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern fn close(fd: c_int) c_int;
extern fn getpid() c_int;
extern fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern fn time(t: ?*i64) i64;
extern const program_invocation_short_name: [*:0]const u8;

const Settings = struct {
    level: std.log.Level = .warn,
    /// A descriptor, opened on the first message, or -1 for none, -2 for "not yet tried".
    fd: c_int = -2,
};

var settings: Settings = .{};
var read_env = false;

fn levelFromName(name: []const u8) ?std.log.Level {
    if (std.mem.eql(u8, name, "debug")) return .debug;
    if (std.mem.eql(u8, name, "info")) return .info;
    if (std.mem.eql(u8, name, "warn") or std.mem.eql(u8, name, "warning")) return .warn;
    if (std.mem.eql(u8, name, "error") or std.mem.eql(u8, name, "err")) return .err;
    return null;
}

fn init() void {
    read_env = true;
    if (getenv("DKDE_LOG")) |v| {
        if (levelFromName(std.mem.span(v))) |l| settings.level = l;
    }
    if (getenv("DKDE_LOG_FILE")) |v| settings.fd = openLogFile(std.mem.span(v)) else settings.fd = -1;
}

fn openLogFile(spec: []const u8) c_int {
    var buf: [512]u8 = undefined;
    const path: [:0]const u8 = if (std.mem.eql(u8, spec, "auto")) blk: {
        const state = if (getenv("XDG_STATE_HOME")) |s| std.mem.span(s) else home: {
            const h = if (getenv("HOME")) |h| std.mem.span(h) else return -1;
            break :home std.fmt.bufPrint(buf[256..], "{s}/.local/state", .{h}) catch return -1;
        };
        var dir_buf: [300]u8 = undefined;
        const dir = std.fmt.bufPrintSentinel(&dir_buf, "{s}/dkde", .{state}, 0) catch return -1;
        _ = mkdir(std.fmt.bufPrintSentinel(buf[0..250], "{s}", .{state}, 0) catch return -1, 0o755);
        _ = mkdir(dir, 0o755);
        break :blk std.fmt.bufPrintSentinel(&buf, "{s}/{s}.log", .{ dir, std.mem.span(program_invocation_short_name) }, 0) catch return -1;
    } else std.fmt.bufPrintSentinel(&buf, "{s}", .{spec}, 0) catch return -1;
    // O_WRONLY | O_CREAT | O_APPEND
    return open(path, 0o1 | 0o100 | 0o2000, @as(c_uint, 0o644));
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (!read_env) init();
    if (@backingInt(level) > @backingInt(settings.level)) return;

    const seconds: u64 = @intCast(time(null));
    const day = seconds % 86400;
    var buf: [2048]u8 = undefined;
    const prefix = std.fmt.bufPrint(&buf, "{d:0>2}:{d:0>2}:{d:0>2} {s}({s}) {s}[{d}]: ", .{
        day / 3600,
        day % 3600 / 60,
        day % 60,
        level.asText(),
        @tagName(scope),
        std.mem.span(program_invocation_short_name),
        getpid(),
    }) catch return;
    const body = std.fmt.bufPrint(buf[prefix.len..], format ++ "\n", args) catch buf[prefix.len..];
    const line = buf[0 .. prefix.len + body.len];

    std.debug.print("{s}", .{line});
    if (settings.fd >= 0) _ = write(settings.fd, line.ptr, line.len);
}

/// Closes the log file; programs may call it just before they exit.
pub fn deinit() void {
    if (settings.fd >= 0) _ = close(settings.fd);
    settings.fd = -1;
}

test "level names" {
    try std.testing.expectEqual(std.log.Level.debug, levelFromName("debug").?);
    try std.testing.expectEqual(std.log.Level.warn, levelFromName("warning").?);
    try std.testing.expect(levelFromName("loud") == null);
}
