//! Parsing of /proc for the task manager. Pure functions over file
//! contents, so they are unit tested.

const std = @import("std");

pub const Stat = struct {
    pid: u32,
    /// Command name; points into the parsed content.
    comm: []const u8,
    state: u8,
    /// utime + stime, in clock ticks.
    cpu_ticks: u64,
    threads: u32,
    rss_pages: u64,
};

/// Parses `/proc/<pid>/stat`. The command name may contain spaces and
/// parentheses, so the fields after it are found from the last ')'.
pub fn parseStat(content: []const u8) ?Stat {
    const open = std.mem.indexOfScalar(u8, content, '(') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, content, ')') orelse return null;
    if (close < open) return null;
    const pid = std.fmt.parseInt(u32, std.mem.trim(u8, content[0..open], " "), 10) catch return null;

    var fields = std.mem.tokenizeScalar(u8, content[close + 1 ..], ' ');
    var index: usize = 0;
    var state: u8 = '?';
    var utime: u64 = 0;
    var stime: u64 = 0;
    var threads: u32 = 0;
    var rss: u64 = 0;
    // After "(comm)": state is field 3, utime 14, stime 15, threads 20, rss 24.
    while (fields.next()) |field| : (index += 1) {
        switch (index) {
            0 => state = field[0],
            11 => utime = std.fmt.parseInt(u64, field, 10) catch return null,
            12 => stime = std.fmt.parseInt(u64, field, 10) catch return null,
            17 => threads = std.fmt.parseInt(u32, field, 10) catch 0,
            21 => {
                rss = std.fmt.parseInt(u64, field, 10) catch 0;
                break;
            },
            else => {},
        }
    }
    if (index < 21) return null;
    return .{
        .pid = pid,
        .comm = content[open + 1 .. close],
        .state = state,
        .cpu_ticks = utime + stime,
        .threads = threads,
        .rss_pages = rss,
    };
}

pub const CpuTimes = struct { total: u64, idle: u64 };

/// The aggregate "cpu" line of /proc/stat.
pub fn parseCpuTimes(content: []const u8) ?CpuTimes {
    var lines = std.mem.splitScalar(u8, content, '\n');
    const line = lines.next() orelse return null;
    if (!std.mem.startsWith(u8, line, "cpu ")) return null;
    var fields = std.mem.tokenizeScalar(u8, line[4..], ' ');
    var total: u64 = 0;
    var idle: u64 = 0;
    var i: usize = 0;
    while (fields.next()) |field| : (i += 1) {
        const value = std.fmt.parseInt(u64, field, 10) catch return null;
        // user nice system idle iowait irq softirq steal; guest time is already counted.
        if (i < 8) total += value;
        if (i == 3 or i == 4) idle += value;
    }
    if (i < 4) return null;
    return .{ .total = total, .idle = idle };
}

pub const Memory = struct { total_kb: u64, available_kb: u64 };

pub fn parseMeminfo(content: []const u8) ?Memory {
    var total: ?u64 = null;
    var available: ?u64 = null;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "MemTotal:")) total = kb(line);
        if (std.mem.startsWith(u8, line, "MemAvailable:")) available = kb(line);
    }
    return .{ .total_kb = total orelse return null, .available_kb = available orelse return null };
}

fn kb(line: []const u8) ?u64 {
    var it = std.mem.tokenizeAny(u8, line, " \t");
    _ = it.next();
    return std.fmt.parseInt(u64, it.next() orelse return null, 10) catch null;
}

/// The uid on the `Uid:` line of /proc/<pid>/status.
pub fn parseUid(status: []const u8) ?u32 {
    var lines = std.mem.splitScalar(u8, status, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "Uid:")) continue;
        var it = std.mem.tokenizeAny(u8, line["Uid:".len..], " \t");
        return std.fmt.parseInt(u32, it.next() orelse return null, 10) catch null;
    }
    return null;
}

/// User name for `uid` from the content of /etc/passwd.
pub fn userName(passwd: []const u8, uid: u32) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, passwd, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ':');
        const name = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const id = std.fmt.parseInt(u32, fields.next() orelse continue, 10) catch continue;
        if (id == uid) return name;
    }
    return null;
}

/// CPU percentage of one process over an interval: its share of all CPU
/// capacity, scaled so one fully busy core is 100 (like top).
pub fn cpuPercent(proc_ticks_delta: u64, total_ticks_delta: u64, cpu_count: usize) f64 {
    if (total_ticks_delta == 0) return 0;
    return @as(f64, @floatFromInt(proc_ticks_delta)) / @as(f64, @floatFromInt(total_ticks_delta)) * 100.0 * @as(f64, @floatFromInt(cpu_count));
}

test "stat with awkward command name" {
    const line = "1234 (my (odd) app) S 1 1234 1234 0 -1 4194304 100 0 0 0 250 50 0 0 20 0 3 0 5000 1000000 700 18446744073709551615";
    const stat = parseStat(line).?;
    try std.testing.expectEqual(@as(u32, 1234), stat.pid);
    try std.testing.expectEqualStrings("my (odd) app", stat.comm);
    try std.testing.expectEqual(@as(u8, 'S'), stat.state);
    try std.testing.expectEqual(@as(u64, 300), stat.cpu_ticks);
    try std.testing.expectEqual(@as(u32, 3), stat.threads);
    try std.testing.expectEqual(@as(u64, 700), stat.rss_pages);
}

test "stat rejects garbage" {
    try std.testing.expect(parseStat("") == null);
    try std.testing.expect(parseStat("12 (x) S 1 2") == null);
}

test "cpu times" {
    const t = parseCpuTimes("cpu  100 0 50 800 50 0 0 0 0 0\ncpu0 1 2 3\n").?;
    try std.testing.expectEqual(@as(u64, 1000), t.total);
    try std.testing.expectEqual(@as(u64, 850), t.idle);
}

test "meminfo" {
    const m = parseMeminfo("MemTotal:       16000000 kB\nMemFree: 1 kB\nMemAvailable:    8000000 kB\n").?;
    try std.testing.expectEqual(@as(u64, 16000000), m.total_kb);
    try std.testing.expectEqual(@as(u64, 8000000), m.available_kb);
}

test "uid and user name" {
    try std.testing.expectEqual(@as(u32, 1000), parseUid("Name:\tx\nUid:\t1000\t1000\t1000\t1000\n").?);
    const passwd = "root:x:0:0::/root:/bin/sh\ndakota:x:1000:1000::/home/dakota:/bin/bash\n";
    try std.testing.expectEqualStrings("dakota", userName(passwd, 1000).?);
    try std.testing.expect(userName(passwd, 77) == null);
}

test "cpu percent scales by core count" {
    try std.testing.expectApproxEqAbs(@as(f64, 100), cpuPercent(25, 100, 4), 1e-9);
    try std.testing.expectEqual(@as(f64, 0), cpuPercent(5, 0, 4));
}
