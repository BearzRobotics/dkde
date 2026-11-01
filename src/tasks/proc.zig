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
    /// Nice value, -20 (greediest) to 19.
    nice: i32,
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
    var nice: i32 = 0;
    // After "(comm)": state is field 3, utime 14, stime 15, threads 20, rss 24.
    while (fields.next()) |field| : (index += 1) {
        switch (index) {
            0 => state = field[0],
            11 => utime = std.fmt.parseInt(u64, field, 10) catch return null,
            12 => stime = std.fmt.parseInt(u64, field, 10) catch return null,
            16 => nice = std.fmt.parseInt(i32, field, 10) catch 0,
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
        .nice = nice,
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

/// Bytes a process has read from and written to storage, from `/proc/<pid>/io`.
/// Only the owner (or root) may read that file.
pub const Io = struct { read: u64, write: u64 };

pub fn parseIo(content: []const u8) ?Io {
    var read: ?u64 = null;
    var write: ?u64 = null;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "read_bytes:")) read = std.fmt.parseInt(u64, std.mem.trim(u8, line["read_bytes:".len..], " \t"), 10) catch null;
        if (std.mem.startsWith(u8, line, "write_bytes:")) write = std.fmt.parseInt(u64, std.mem.trim(u8, line["write_bytes:".len..], " \t"), 10) catch null;
    }
    return .{ .read = read orelse return null, .write = write orelse return null };
}

fn baseName(path: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, path, 0) orelse path.len;
    const p = path[0..end];
    return if (std.mem.lastIndexOfScalar(u8, p, '/')) |i| p[i + 1 ..] else p;
}

/// The name to show for a process, as the Windows Task Manager shows the
/// program rather than whatever a thread called itself: the executable's file
/// name, else the first word of the command line, else the kernel's `comm`
/// (which is all a kernel thread has). `exe` is the target of `/proc/<pid>/exe`
/// (not readable for other users' processes), `cmdline` the raw
/// `/proc/<pid>/cmdline` with its NULs.
pub fn displayName(exe: []const u8, cmdline: []const u8, comm: []const u8) []const u8 {
    var name = baseName(exe);
    // A replaced executable reads "/usr/bin/foo (deleted)".
    if (std.mem.endsWith(u8, name, " (deleted)")) name = name[0 .. name.len - " (deleted)".len];
    // Some programs are installed as a file named by their version
    // (".../claude/versions/2.1.316"): that says nothing, so look further.
    const versioned = name.len > 0 and std.ascii.isDigit(name[0]);
    if (name.len > 0 and !versioned) return name;
    // argv[0], or the first word of a title the program set for itself ("sshd: user").
    const first = baseName(cmdline);
    var word = first;
    if (std.mem.indexOfScalar(u8, word, ' ')) |i| word = word[0..i];
    word = std.mem.trimEnd(u8, word, ":");
    // A login shell is run as "-bash".
    word = std.mem.trimStart(u8, word, "-");
    if (word.len > 0 and !std.ascii.isDigit(word[0])) return word;
    // Nothing better: the version-named file, or the kernel's name.
    return if (versioned) name else comm;
}

/// The command line with its NULs shown as spaces, into `out`.
pub fn cmdlineText(cmdline: []const u8, out: []u8) []const u8 {
    const n = @min(cmdline.len, out.len);
    for (cmdline[0..n], 0..) |c, i| out[i] = if (c == 0) ' ' else c;
    return std.mem.trimEnd(u8, out[0..n], " ");
}

test "io counters" {
    const io = parseIo("rchar: 1\nwchar: 2\nsyscr: 3\nsyscw: 4\nread_bytes: 4096\nwrite_bytes: 8192\ncancelled_write_bytes: 0\n").?;
    try std.testing.expectEqual(@as(u64, 4096), io.read);
    try std.testing.expectEqual(@as(u64, 8192), io.write);
    try std.testing.expect(parseIo("") == null);
}

test "display name: the program, not the thread" {
    // A thread renamed itself; the executable still says what the program is.
    try std.testing.expectEqualStrings("claude", displayName("/home/u/.local/bin/claude", "claude\x00--resume\x00", "MainThread"));
    try std.testing.expectEqualStrings("foo", displayName("/usr/bin/foo (deleted)", "", "x"));
    // Another user's process: no exe, so the command line.
    try std.testing.expectEqualStrings("sshd", displayName("", "sshd: dakota [priv]", "sshd"));
    try std.testing.expectEqualStrings("bash", displayName("", "-bash\x00", "bash"));
    try std.testing.expectEqualStrings("python3", displayName("", "/usr/bin/python3\x00-m\x00x\x00", "MainThread"));
    // Installed under its version number: the command line has the real name.
    try std.testing.expectEqualStrings("claude", displayName("/home/u/.local/share/claude/versions/2.1.316", "claude\x00", "MainThread"));
    try std.testing.expectEqualStrings("2.1.316", displayName("/x/2.1.316", "", "MainThread"));
    // A kernel thread has neither.
    try std.testing.expectEqualStrings("kworker/0:1", displayName("", "", "kworker/0:1"));
}

test "command line text" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("a -b c", cmdlineText("a\x00-b\x00c\x00", &buf));
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
    try std.testing.expectEqual(@as(i32, 0), stat.nice);
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
