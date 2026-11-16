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
//! The Developer page of Settings writes the same choices to `developer.toml` ([developer] `log-level`,
//! `log-files`, `glib-debug`), which programs started afterwards read when the environment names none.
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
extern fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
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

/// What developer.toml asks for.
pub const Developer = struct {
    level: ?std.log.Level = null,
    files: bool = false,
    glib_debug: bool = false,
};

/// Reads the `[developer]` keys out of the text of developer.toml. Only what logging needs, so no TOML library.
pub fn parseDeveloper(text: []const u8) Developer {
    var out: Developer = .{};
    var in_group = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            in_group = std.mem.eql(u8, line, "[developer]");
            continue;
        }
        if (!in_group) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, std.mem.trim(u8, line[eq + 1 ..], " \t"), "\"");
        if (std.mem.eql(u8, key, "log-level")) out.level = levelFromName(value);
        if (std.mem.eql(u8, key, "log-files")) out.files = std.mem.eql(u8, value, "true");
        if (std.mem.eql(u8, key, "glib-debug")) out.glib_debug = std.mem.eql(u8, value, "true");
    }
    return out;
}

fn readDeveloper() Developer {
    var path_buf: [400]u8 = undefined;
    const path = if (getenv("XDG_CONFIG_HOME")) |c|
        std.fmt.bufPrintSentinel(&path_buf, "{s}/dkde/developer.toml", .{std.mem.span(c)}, 0) catch return .{}
    else if (getenv("HOME")) |h|
        std.fmt.bufPrintSentinel(&path_buf, "{s}/.config/dkde/developer.toml", .{std.mem.span(h)}, 0) catch return .{}
    else
        return .{};
    const fd = open(path, 0); // O_RDONLY
    if (fd < 0) return .{};
    defer _ = close(fd);
    var text: [2048]u8 = undefined;
    const n = read(fd, &text, text.len);
    if (n <= 0) return .{};
    return parseDeveloper(text[0..@intCast(n)]);
}

fn init() void {
    read_env = true;
    const dev = readDeveloper();
    if (dev.level) |l| settings.level = l;
    if (getenv("DKDE_LOG")) |v| {
        if (levelFromName(std.mem.span(v))) |l| settings.level = l;
    }
    if (dev.glib_debug) _ = setenv("G_MESSAGES_DEBUG", "all", 0);
    if (getenv("DKDE_LOG_FILE")) |v| {
        settings.fd = openLogFile(std.mem.span(v));
    } else if (dev.files) {
        settings.fd = openLogFile("auto");
    } else settings.fd = -1;
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

test "developer.toml" {
    const d = parseDeveloper("[other]\nlog-level = \"error\"\n[developer]\nlog-level = \"debug\"\nlog-files = true\nglib-debug = false\n");
    try std.testing.expectEqual(std.log.Level.debug, d.level.?);
    try std.testing.expect(d.files and !d.glib_debug);
    try std.testing.expect(parseDeveloper("").level == null);
}

test "level names" {
    try std.testing.expectEqual(std.log.Level.debug, levelFromName("debug").?);
    try std.testing.expectEqual(std.log.Level.warn, levelFromName("warning").?);
    try std.testing.expect(levelFromName("loud") == null);
}
