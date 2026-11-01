//! Parsing and formatting for the Performance tab. Pure functions over file
//! contents, so they are unit tested; the widgets live in perfview.zig.

const std = @import("std");
const proc = @import("proc.zig");

pub const CpuTimes = proc.CpuTimes;

/// Fraction of time busy between two readings of the same counters.
pub fn busy(prev: CpuTimes, now: CpuTimes) f64 {
    const total = now.total -| prev.total;
    if (total == 0) return 0;
    const idle = now.idle -| prev.idle;
    return std.math.clamp(1.0 - @as(f64, @floatFromInt(idle)) / @as(f64, @floatFromInt(total)), 0, 1);
}

/// The per-core `cpuN` lines of /proc/stat, in order. Returns how many.
pub fn parseCoreTimes(content: []const u8, out: []CpuTimes) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len < 5 or !std.mem.startsWith(u8, line, "cpu") or !std.ascii.isDigit(line[3])) continue;
        if (n >= out.len) break;
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        var fields = std.mem.tokenizeScalar(u8, line[space..], ' ');
        var total: u64 = 0;
        var idle: u64 = 0;
        var i: usize = 0;
        while (fields.next()) |field| : (i += 1) {
            const value = std.fmt.parseInt(u64, field, 10) catch break;
            if (i < 8) total += value;
            if (i == 3 or i == 4) idle += value;
        }
        if (i < 4) continue;
        out[n] = .{ .total = total, .idle = idle };
        n += 1;
    }
    return n;
}

pub const CpuInfo = struct {
    /// Points into the parsed content.
    model: []const u8 = "",
    /// Mean of the "cpu MHz" lines; 0 when the kernel gives none.
    mhz: f64 = 0,
    sockets: u32 = 1,
    cores_per_socket: u32 = 0,
    /// vmx (Intel) or svm (AMD) among the flags.
    hw_virtualization: bool = false,
    /// Running under a hypervisor.
    hypervisor: bool = false,
};

pub fn parseCpuInfo(content: []const u8) CpuInfo {
    var info: CpuInfo = .{};
    var mhz_sum: f64 = 0;
    var mhz_n: u32 = 0;
    var sockets: u64 = 0; // bit set of "physical id"
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.mem.eql(u8, key, "model name") or std.mem.eql(u8, key, "Hardware") or std.mem.eql(u8, key, "cpu model")) {
            if (info.model.len == 0) info.model = value;
        } else if (std.mem.eql(u8, key, "cpu MHz")) {
            mhz_sum += std.fmt.parseFloat(f64, value) catch continue;
            mhz_n += 1;
        } else if (std.mem.eql(u8, key, "physical id")) {
            const id = std.fmt.parseInt(u6, value, 10) catch continue;
            sockets |= @as(u64, 1) << id;
        } else if (std.mem.eql(u8, key, "cpu cores")) {
            info.cores_per_socket = std.fmt.parseInt(u32, value, 10) catch info.cores_per_socket;
        } else if (std.mem.eql(u8, key, "flags") and !info.hypervisor and !info.hw_virtualization) {
            var flags = std.mem.tokenizeScalar(u8, value, ' ');
            while (flags.next()) |flag| {
                if (std.mem.eql(u8, flag, "vmx") or std.mem.eql(u8, flag, "svm")) info.hw_virtualization = true;
                if (std.mem.eql(u8, flag, "hypervisor")) info.hypervisor = true;
            }
        }
    }
    if (mhz_n > 0) info.mhz = mhz_sum / @as(f64, @floatFromInt(mhz_n));
    info.sockets = @max(1, @popCount(sockets));
    return info;
}

/// Number of CPUs in a list such as "0-3,8,10-11".
pub fn countCpuList(list: []const u8) u32 {
    var n: u32 = 0;
    var parts = std.mem.tokenizeAny(u8, list, ",\n ");
    while (parts.next()) |part| {
        if (std.mem.indexOfScalar(u8, part, '-')) |dash| {
            const lo = std.fmt.parseInt(u32, part[0..dash], 10) catch continue;
            const hi = std.fmt.parseInt(u32, part[dash + 1 ..], 10) catch continue;
            if (hi >= lo) n += hi - lo + 1;
        } else {
            _ = std.fmt.parseInt(u32, part, 10) catch continue;
            n += 1;
        }
    }
    return n;
}

/// "32K", "1024K", "32M" as kibibytes.
pub fn parseCacheSize(text: []const u8) ?u64 {
    const t = std.mem.trim(u8, text, " \t\n");
    if (t.len < 2) return null;
    const value = std.fmt.parseInt(u64, t[0 .. t.len - 1], 10) catch return null;
    return switch (t[t.len - 1]) {
        'K' => value,
        'M' => value * 1024,
        'G' => value * 1024 * 1024,
        else => null,
    };
}

pub const Mem = struct {
    total: u64 = 0,
    available: u64 = 0,
    buffers: u64 = 0,
    cached: u64 = 0,
    swap_total: u64 = 0,
    swap_free: u64 = 0,
    committed: u64 = 0,
    commit_limit: u64 = 0,
    reclaimable: u64 = 0,
    unreclaimable: u64 = 0,
    shmem: u64 = 0,
};

/// All sizes in kB, as /proc/meminfo gives them.
pub fn parseMem(content: []const u8) ?Mem {
    var m: Mem = .{};
    var have_total = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = line[0..colon];
        var it = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
        const value = std.fmt.parseInt(u64, it.next() orelse continue, 10) catch continue;
        if (std.mem.eql(u8, key, "MemTotal")) {
            m.total = value;
            have_total = true;
        } else if (std.mem.eql(u8, key, "MemAvailable")) m.available = value else if (std.mem.eql(u8, key, "Buffers")) m.buffers = value else if (std.mem.eql(u8, key, "Cached")) m.cached = value else if (std.mem.eql(u8, key, "SwapTotal")) m.swap_total = value else if (std.mem.eql(u8, key, "SwapFree")) m.swap_free = value else if (std.mem.eql(u8, key, "Committed_AS")) m.committed = value else if (std.mem.eql(u8, key, "CommitLimit")) m.commit_limit = value else if (std.mem.eql(u8, key, "SReclaimable")) m.reclaimable = value else if (std.mem.eql(u8, key, "SUnreclaim")) m.unreclaimable = value else if (std.mem.eql(u8, key, "Shmem")) m.shmem = value;
    }
    return if (have_total) m else null;
}

pub const DiskStat = struct {
    reads: u64 = 0,
    read_sectors: u64 = 0,
    read_ms: u64 = 0,
    writes: u64 = 0,
    write_sectors: u64 = 0,
    write_ms: u64 = 0,
    /// Milliseconds the device had work queued.
    io_ms: u64 = 0,
};

/// /sys/block/<disk>/stat.
pub fn parseDiskStat(content: []const u8) ?DiskStat {
    var it = std.mem.tokenizeAny(u8, content, " \t\n");
    var f: [11]u64 = undefined;
    for (&f) |*slot| slot.* = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
    return .{
        .reads = f[0],
        .read_sectors = f[2],
        .read_ms = f[3],
        .writes = f[4],
        .write_sectors = f[6],
        .write_ms = f[7],
        .io_ms = f[9],
    };
}

pub const NetBytes = struct { rx: u64, tx: u64 };

/// One interface's counters from /proc/net/dev.
pub fn parseNetDev(content: []const u8, name: []const u8) ?NetBytes {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..colon], " "), name)) continue;
        var it = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
        var f: [9]u64 = undefined;
        for (&f) |*slot| slot.* = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
        return .{ .rx = f[0], .tx = f[8] };
    }
    return null;
}

/// Link quality from /proc/net/wireless as a percentage.
pub fn parseWirelessQuality(content: []const u8, name: []const u8) ?u32 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..colon], " "), name)) continue;
        var it = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
        _ = it.next() orelse return null; // status
        const link = std.mem.trimEnd(u8, it.next() orelse return null, ".");
        const q = std.fmt.parseInt(u32, link, 10) catch return null;
        return @min(100, q * 100 / 70);
    }
    return null;
}

/// First field of /proc/uptime, in seconds.
pub fn parseUptime(content: []const u8) ?u64 {
    var it = std.mem.tokenizeAny(u8, content, " \n");
    const text = it.next() orelse return null;
    const secs = std.fmt.parseFloat(f64, text) catch return null;
    return @intFromFloat(@max(0, secs));
}

pub const PciNames = struct { vendor: ?[]const u8 = null, device: ?[]const u8 = null };

/// Looks a vendor and device id up in a pci.ids file.
pub fn pciNames(content: []const u8, vendor: u16, device: u16) PciNames {
    var out: PciNames = .{};
    var vbuf: [4]u8 = undefined;
    var dbuf: [4]u8 = undefined;
    _ = std.fmt.bufPrint(&vbuf, "{x:0>4}", .{vendor}) catch return out;
    _ = std.fmt.bufPrint(&dbuf, "{x:0>4}", .{device}) catch return out;
    var in_vendor = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] != '\t') {
            if (in_vendor) return out; // left our vendor's block
            if (line.len > 6 and std.ascii.eqlIgnoreCase(line[0..4], &vbuf)) {
                in_vendor = true;
                out.vendor = std.mem.trim(u8, line[4..], " ");
            }
        } else if (in_vendor and line.len > 7 and line[1] != '\t' and std.ascii.eqlIgnoreCase(line[1..5], &dbuf)) {
            out.device = std.mem.trim(u8, line[5..], " ");
            return out;
        }
    }
    return out;
}

/// The SSID of `device` from `nmcli -t -f ACTIVE,SSID,DEVICE dev wifi`. Colons
/// inside the SSID are escaped as `\:`.
pub fn parseNmcliSsid(output: []const u8, device: []const u8, buf: []u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "yes:")) continue;
        const last = std.mem.lastIndexOfScalar(u8, line, ':') orelse continue;
        if (!std.mem.eql(u8, line[last + 1 ..], device)) continue;
        const raw = line[4..last];
        var n: usize = 0;
        var i: usize = 0;
        while (i < raw.len and n < buf.len) : (i += 1) {
            if (raw[i] == '\\' and i + 1 < raw.len) i += 1;
            buf[n] = raw[i];
            n += 1;
        }
        return buf[0..n];
    }
    return null;
}

// ---- formatting --------------------------------------------------------------

/// "7.5 GB" from kibibytes.
pub fn fmtKb(buf: []u8, kb: u64) []const u8 {
    const v: f64 = @floatFromInt(kb);
    return (if (kb >= 1048576)
        std.fmt.bufPrint(buf, "{d:.1} GB", .{v / 1048576.0})
    else if (kb >= 1024)
        std.fmt.bufPrint(buf, "{d:.0} MB", .{v / 1024.0})
    else
        std.fmt.bufPrint(buf, "{d} KB", .{kb})) catch "";
}

/// "512 B/s", "1.5 MB/s".
pub fn fmtByteRate(buf: []u8, bytes_per_sec: f64) []const u8 {
    const v = @max(0, bytes_per_sec);
    return (if (v >= 1024 * 1024 * 1024)
        std.fmt.bufPrint(buf, "{d:.1} GB/s", .{v / (1024 * 1024 * 1024)})
    else if (v >= 1024 * 1024)
        std.fmt.bufPrint(buf, "{d:.1} MB/s", .{v / (1024 * 1024)})
    else if (v >= 1024)
        std.fmt.bufPrint(buf, "{d:.0} KB/s", .{v / 1024})
    else
        std.fmt.bufPrint(buf, "{d:.0} B/s", .{v})) catch "";
}

/// "512 Kbps", "1.5 Mbps", as Windows shows network traffic.
pub fn fmtBitRate(buf: []u8, bytes_per_sec: f64) []const u8 {
    const bits = @max(0, bytes_per_sec) * 8;
    return (if (bits >= 1e9)
        std.fmt.bufPrint(buf, "{d:.1} Gbps", .{bits / 1e9})
    else if (bits >= 1e6)
        std.fmt.bufPrint(buf, "{d:.1} Mbps", .{bits / 1e6})
    else
        std.fmt.bufPrint(buf, "{d:.0} Kbps", .{bits / 1e3})) catch "";
}

/// "d:hh:mm:ss", as the Windows up time.
pub fn fmtUptime(buf: []u8, secs: u64) []const u8 {
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}:{d:0>2}", .{ secs / 86400, secs / 3600 % 24, secs / 60 % 60, secs % 60 }) catch "";
}

/// IPv6 text with the longest run of zero groups compressed.
pub fn fmtIp6(buf: []u8, addr: [16]u8) []const u8 {
    var g: [8]u16 = undefined;
    for (&g, 0..) |*slot, i| slot.* = @as(u16, addr[i * 2]) << 8 | addr[i * 2 + 1];
    var best_start: usize = 8;
    var best_len: usize = 0;
    var i: usize = 0;
    while (i < 8) {
        if (g[i] != 0) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < 8 and g[j] == 0) j += 1;
        if (j - i > best_len and j - i >= 2) {
            best_start = i;
            best_len = j - i;
        }
        i = j;
    }
    var w: std.Io.Writer = .fixed(buf);
    i = 0;
    while (i < 8) {
        if (i == best_start) {
            w.writeAll("::") catch return "";
            i += best_len;
            continue;
        }
        if (i > 0 and i != best_start + best_len) w.writeByte(':') catch return "";
        w.print("{x}", .{g[i]}) catch return "";
        i += 1;
    }
    return w.buffered();
}

test "per-core times skip the aggregate line" {
    var out: [4]CpuTimes = undefined;
    const n = parseCoreTimes("cpu  1 2 3 4 5 6 7 8\ncpu0 10 0 10 70 10 0 0 0\ncpu1 20 0 20 40 20 0 0 0\nintr 5\n", &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(u64, 100), out[0].total);
    try std.testing.expectEqual(@as(u64, 80), out[0].idle);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), busy(.{ .total = 0, .idle = 0 }, out[0]), 1e-9);
}

test "cpuinfo" {
    const text = "processor : 0\nmodel name\t: Fancy CPU @ 3GHz\ncpu MHz\t\t: 3000.0\nphysical id\t: 0\ncpu cores\t: 4\nflags\t\t: fpu vmx hypervisor\n\nprocessor : 1\nmodel name\t: Fancy CPU @ 3GHz\ncpu MHz\t\t: 1000.0\nphysical id\t: 1\n";
    const info = parseCpuInfo(text);
    try std.testing.expectEqualStrings("Fancy CPU @ 3GHz", info.model);
    try std.testing.expectApproxEqAbs(@as(f64, 2000), info.mhz, 1e-9);
    try std.testing.expectEqual(@as(u32, 2), info.sockets);
    try std.testing.expectEqual(@as(u32, 4), info.cores_per_socket);
    try std.testing.expect(info.hw_virtualization and info.hypervisor);
}

test "cpu lists and cache sizes" {
    try std.testing.expectEqual(@as(u32, 7), countCpuList("0-3,8,10-11\n"));
    try std.testing.expectEqual(@as(u32, 1), countCpuList("5"));
    try std.testing.expectEqual(@as(?u64, 1024), parseCacheSize("1M\n"));
    try std.testing.expectEqual(@as(?u64, 32), parseCacheSize("32K"));
    try std.testing.expect(parseCacheSize("") == null);
}

test "meminfo" {
    const m = parseMem("MemTotal: 100 kB\nMemAvailable: 40 kB\nCached: 10 kB\nSwapTotal: 8 kB\nSwapFree: 6 kB\nCommitted_AS: 70 kB\nCommitLimit: 90 kB\nSReclaimable: 3 kB\nSUnreclaim: 2 kB\n").?;
    try std.testing.expectEqual(@as(u64, 100), m.total);
    try std.testing.expectEqual(@as(u64, 40), m.available);
    try std.testing.expectEqual(@as(u64, 70), m.committed);
    try std.testing.expect(parseMem("Cached: 1 kB\n") == null);
}

test "disk stat" {
    const d = parseDiskStat("  100 1 2000 30 50 2 800 20 0 40 60 0 0 0 0\n").?;
    try std.testing.expectEqual(@as(u64, 2000), d.read_sectors);
    try std.testing.expectEqual(@as(u64, 40), d.io_ms);
    try std.testing.expectEqual(@as(u64, 20), d.write_ms);
    try std.testing.expect(parseDiskStat("1 2 3") == null);
}

test "net dev and wireless" {
    const dev = "Inter-|   Receive\n face |bytes packets\n  eth0: 1000 10 0 0 0 0 0 0 2000 20 0 0 0 0 0 0\n    lo: 5 1 0 0 0 0 0 0 5 1 0 0 0 0 0 0\n";
    const e = parseNetDev(dev, "eth0").?;
    try std.testing.expectEqual(@as(u64, 1000), e.rx);
    try std.testing.expectEqual(@as(u64, 2000), e.tx);
    try std.testing.expect(parseNetDev(dev, "wlan0") == null);
    const wl = "Inter-| sta-|\n face | tus | link\n wlan0: 0000   35.  -60.  -256   0 0 0 0 0 0\n";
    try std.testing.expectEqual(@as(?u32, 50), parseWirelessQuality(wl, "wlan0"));
}

test "uptime" {
    try std.testing.expectEqual(@as(?u64, 90061), parseUptime("90061.55 12345.67\n"));
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1:01:01:01", fmtUptime(&buf, 90061));
}

test "pci names" {
    const ids = "# comment\n1002  Advanced Micro Devices, Inc. [AMD/ATI]\n\t67df  Ellesmere [Radeon RX 480]\n\t\t1002 0b04  Subsystem\n8086  Intel Corporation\n\t1912  HD Graphics 530\n";
    const a = pciNames(ids, 0x8086, 0x1912);
    try std.testing.expectEqualStrings("Intel Corporation", a.vendor.?);
    try std.testing.expectEqualStrings("HD Graphics 530", a.device.?);
    const b = pciNames(ids, 0x1002, 0x9999);
    try std.testing.expectEqualStrings("Advanced Micro Devices, Inc. [AMD/ATI]", b.vendor.?);
    try std.testing.expect(b.device == null);
    try std.testing.expect(pciNames(ids, 0x10de, 1).vendor == null);
}

test "nmcli ssid" {
    var buf: [64]u8 = undefined;
    const out = "no:Other:wlan1\nyes:Cafe\\: Free:wlan0\n";
    try std.testing.expectEqualStrings("Cafe: Free", parseNmcliSsid(out, "wlan0", &buf).?);
    try std.testing.expect(parseNmcliSsid(out, "wlan1", &buf) == null);
}

test "formatting" {
    var buf: [48]u8 = undefined;
    try std.testing.expectEqualStrings("7.5 GB", fmtKb(&buf, 7864320));
    try std.testing.expectEqualStrings("1.5 MB/s", fmtByteRate(&buf, 1.5 * 1024 * 1024));
    try std.testing.expectEqualStrings("8.0 Mbps", fmtBitRate(&buf, 1e6));
    var a: [16]u8 = @splat(0);
    a[0] = 0xfe;
    a[1] = 0x80;
    a[15] = 1;
    try std.testing.expectEqualStrings("fe80::1", fmtIp6(&buf, a));
    try std.testing.expectEqualStrings("::", fmtIp6(&buf, @splat(0)));
}
