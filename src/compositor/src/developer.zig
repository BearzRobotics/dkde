// SPDX-License-Identifier: GPL-2.0-or-later
//! What Settings > For developers asks for, for the compositor and the X11 window manager (which do not use
//! `common`). The same file and keys that common/log.zig reads: `~/.config/dkde/developer.toml`, [developer]
//! `log-level`, `log-files`. `DKDE_DEBUG` in the environment still forces debug.

const std = @import("std");

extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern fn close(fd: c_int) c_int;
extern fn dup2(old: c_int, new: c_int) c_int;
extern fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;

pub const Level = enum { default, err, warn, info, debug };

pub const Developer = struct {
    level: Level = .default,
    files: bool = false,

    pub fn debug(self: Developer) bool {
        return self.level == .debug or getenv("DKDE_DEBUG") != null;
    }
};

pub fn parse(text: []const u8) Developer {
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
        if (std.mem.eql(u8, key, "log-level")) out.level = std.meta.stringToEnum(Level, if (std.mem.eql(u8, value, "error")) "err" else value) orelse .default;
        if (std.mem.eql(u8, key, "log-files")) out.files = std.mem.eql(u8, value, "true");
    }
    return out;
}

pub fn read_file() Developer {
    var path_buf: [400]u8 = undefined;
    const path = if (getenv("XDG_CONFIG_HOME")) |c|
        std.fmt.bufPrintSentinel(&path_buf, "{s}/dkde/developer.toml", .{std.mem.span(c)}, 0) catch return .{}
    else if (getenv("HOME")) |h|
        std.fmt.bufPrintSentinel(&path_buf, "{s}/.config/dkde/developer.toml", .{std.mem.span(h)}, 0) catch return .{}
    else
        return .{};
    const fd = open(path, 0);
    if (fd < 0) return .{};
    defer _ = close(fd);
    var text: [2048]u8 = undefined;
    const n = read(fd, &text, text.len);
    if (n <= 0) return .{};
    return parse(text[0..@intCast(n)]);
}

/// Sends everything the program writes to stderr (log lines, panics, library warnings) to
/// `$XDG_STATE_HOME/dkde/<name>.log` as well, when the settings ask for log files.
pub fn redirectStderr(dev: Developer, name: []const u8) void {
    if (!dev.files) return;
    var state_buf: [300]u8 = undefined;
    const state = if (getenv("XDG_STATE_HOME")) |s| std.mem.span(s) else if (getenv("HOME")) |h| (std.fmt.bufPrint(&state_buf, "{s}/.local/state", .{std.mem.span(h)}) catch return) else return;
    var dir_buf: [400]u8 = undefined;
    _ = mkdir((std.fmt.bufPrintSentinel(&dir_buf, "{s}", .{state}, 0) catch return).ptr, 0o755);
    const dir = std.fmt.bufPrintSentinel(&dir_buf, "{s}/dkde", .{state}, 0) catch return;
    _ = mkdir(dir.ptr, 0o755);
    var path_buf: [500]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "{s}/{s}.log", .{ dir, name }, 0) catch return;
    const fd = open(path, 0o1 | 0o100 | 0o2000, @as(c_uint, 0o644));
    if (fd < 0) return;
    _ = dup2(fd, 2);
    _ = close(fd);
}

test "developer.toml" {
    const d = parse("[developer]\nlog-level = \"error\"\nlog-files = true\n");
    try std.testing.expectEqual(Level.err, d.level);
    try std.testing.expect(d.files);
    try std.testing.expectEqual(Level.default, parse("").level);
}
