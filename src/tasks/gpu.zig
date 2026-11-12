//! How busy GPUs are, from the kernel's per-client statistics: each open
//! DRM file of a process has an fdinfo file (/proc/PID/fdinfo/FD) with the
//! nanoseconds each engine has spent on that client and the memory it holds
//! (Documentation/gpu/drm-usage-stats.rst). i915, xe, amdgpu, nouveau, msm,
//! panfrost, v3d and others write it. Summing the clients over a second
//! gives the GPU's real utilization, and each process's share of it.
//!
//! NVIDIA's own driver writes none of this; `nvidia-smi` reports it
//! instead (parseNvidiaSmi).

const std = @import("std");

pub const max_engines = 8;

pub const Engine = struct {
    name: [24]u8 = @splat(0),
    ns: u64 = 0,

    pub fn nameSlice(self: *const Engine) []const u8 {
        return std.mem.sliceTo(&self.name, 0);
    }
};

/// One DRM client (an open GPU file): which GPU, its engines' busy time,
/// and its memory.
pub const Client = struct {
    /// The GPU's PCI address ("0000:03:00.0"), or the device name.
    pdev: [32]u8 = @splat(0),
    client_id: u64 = 0,
    engines: [max_engines]Engine = @splat(.{}),
    engine_count: usize = 0,
    /// GPU memory held, in kB (resident where told, else total).
    memory_kb: u64 = 0,

    pub fn pdevSlice(self: *const Client) []const u8 {
        return std.mem.sliceTo(&self.pdev, 0);
    }
};

/// Reads one fdinfo file; null when it is not a DRM client's.
pub fn parseFdinfo(text: []const u8) ?Client {
    var c: Client = .{};
    var is_drm = false;
    var resident_kb: ?u64 = null;
    var legacy_kb: ?u64 = null;
    var shared_kb: u64 = 0;
    var total_kb: u64 = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.mem.eql(u8, key, "drm-driver")) {
            is_drm = true;
        } else if (std.mem.eql(u8, key, "drm-pdev")) {
            const n = @min(value.len, c.pdev.len - 1);
            @memcpy(c.pdev[0..n], value[0..n]);
        } else if (std.mem.eql(u8, key, "drm-client-id")) {
            c.client_id = std.fmt.parseInt(u64, value, 10) catch 0;
        } else if (std.mem.startsWith(u8, key, "drm-engine-") and !std.mem.startsWith(u8, key, "drm-engine-capacity")) {
            if (c.engine_count == max_engines) continue;
            const ns = std.fmt.parseInt(u64, firstWord(value), 10) catch continue;
            var e: Engine = .{ .ns = ns };
            const name = key["drm-engine-".len..];
            const n = @min(name.len, e.name.len - 1);
            @memcpy(e.name[0..n], name[0..n]);
            c.engines[c.engine_count] = e;
            c.engine_count += 1;
        } else if (std.mem.startsWith(u8, key, "drm-resident-")) {
            if (memoryKb(value)) |kb| resident_kb = (resident_kb orelse 0) + kb;
        } else if (std.mem.startsWith(u8, key, "drm-memory-")) {
            // The older name for what is resident; drivers that write both
            // (amdgpu) would otherwise be counted twice.
            if (memoryKb(value)) |kb| legacy_kb = (legacy_kb orelse 0) + kb;
        } else if (std.mem.startsWith(u8, key, "drm-shared-")) {
            if (memoryKb(value)) |kb| shared_kb += kb;
        } else if (std.mem.startsWith(u8, key, "drm-total-")) {
            if (memoryKb(value)) |kb| total_kb += kb;
        }
    }
    if (!is_drm) return null;
    // Memory shared with other processes is not this one's own.
    c.memory_kb = (resident_kb orelse legacy_kb orelse total_kb) -| shared_kb;
    return c;
}

fn firstWord(s: []const u8) []const u8 {
    return s[0 .. std.mem.indexOfAny(u8, s, " \t") orelse s.len];
}

/// "1234 KiB", "12 MiB", "4096" (bytes) as kB.
fn memoryKb(value: []const u8) ?u64 {
    var it = std.mem.tokenizeAny(u8, value, " \t");
    const n = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
    const unit = it.next() orelse return n / 1024;
    if (std.mem.eql(u8, unit, "KiB")) return n;
    if (std.mem.eql(u8, unit, "MiB")) return n * 1024;
    if (std.mem.eql(u8, unit, "GiB")) return n * 1024 * 1024;
    return n / 1024;
}

/// How busy one client was between two readings: the busiest engine's share
/// of the time (0 to 1), as Windows shows a process's GPU use.
pub fn clientBusy(prev: *const Client, now: *const Client, elapsed_ns: u64) f64 {
    if (elapsed_ns == 0) return 0;
    var best: f64 = 0;
    for (now.engines[0..now.engine_count]) |*e| {
        const before = for (prev.engines[0..prev.engine_count]) |*p| {
            if (std.mem.eql(u8, p.nameSlice(), e.nameSlice())) break p.ns;
        } else continue;
        const share = @as(f64, @floatFromInt(e.ns -| before)) / @as(f64, @floatFromInt(elapsed_ns));
        best = @max(best, share);
    }
    return @min(best, 1);
}

/// The busy time per engine of a whole GPU over one interval: the sum of
/// its clients' engine deltas, the busiest engine giving the GPU's figure.
pub const Load = struct {
    pdev: [32]u8 = @splat(0),
    engines: [max_engines]Engine = @splat(.{}),
    engine_count: usize = 0,

    pub fn add(self: *Load, engine: []const u8, ns: u64) void {
        for (self.engines[0..self.engine_count]) |*e| {
            if (std.mem.eql(u8, e.nameSlice(), engine)) {
                e.ns += ns;
                return;
            }
        }
        if (self.engine_count == max_engines) return;
        var e: Engine = .{ .ns = ns };
        const n = @min(engine.len, e.name.len - 1);
        @memcpy(e.name[0..n], engine[0..n]);
        self.engines[self.engine_count] = e;
        self.engine_count += 1;
    }

    /// The busiest engine's share of `elapsed_ns` (0 to 1).
    pub fn busy(self: *const Load, elapsed_ns: u64) f64 {
        if (elapsed_ns == 0) return 0;
        var best: u64 = 0;
        for (self.engines[0..self.engine_count]) |e| best = @max(best, e.ns);
        return @min(1, @as(f64, @floatFromInt(best)) / @as(f64, @floatFromInt(elapsed_ns)));
    }
};

/// One line of `nvidia-smi --query-gpu=pci.bus_id,utilization.gpu,
/// memory.used,memory.total,temperature.gpu,power.draw,clocks.gr
/// --format=csv,noheader,nounits`.
pub const Nvidia = struct {
    bus: [32]u8 = @splat(0),
    utilization: ?f64 = null,
    memory_used_mb: ?f64 = null,
    memory_total_mb: ?f64 = null,
    temperature: ?f64 = null,
    power_w: ?f64 = null,
    clock_mhz: ?f64 = null,
};

pub fn parseNvidiaSmi(line: []const u8) ?Nvidia {
    var n: Nvidia = .{};
    var it = std.mem.splitScalar(u8, line, ',');
    const bus = std.mem.trim(u8, it.next() orelse return null, " ");
    if (bus.len == 0) return null;
    // nvidia-smi writes "00000000:01:00.0"; sysfs writes "0000:01:00.0".
    const short = if (bus.len == 16 and std.mem.startsWith(u8, bus, "0000")) bus[4..] else bus;
    const k = @min(short.len, n.bus.len - 1);
    for (short[0..k], 0..) |ch, i| n.bus[i] = std.ascii.toLower(ch);
    const fields = [_]*?f64{ &n.utilization, &n.memory_used_mb, &n.memory_total_mb, &n.temperature, &n.power_w, &n.clock_mhz };
    for (fields) |f| {
        const v = std.mem.trim(u8, it.next() orelse break, " ");
        f.* = std.fmt.parseFloat(f64, v) catch null; // "[N/A]", "[Not Supported]"
    }
    return n;
}

test "an amdgpu client" {
    const text = "pos:\t0\nflags:\t02100002\ndrm-driver:\tamdgpu\ndrm-client-id:\t17\ndrm-pdev:\t0000:03:00.0\n" ++
        "drm-resident-vram:\t65536 KiB\ndrm-resident-gtt:\t2048 KiB\ndrm-memory-vram:\t65536 KiB\ndrm-shared-vram:\t1024 KiB\n" ++
        "drm-engine-gfx:\t4000000 ns\ndrm-engine-compute:\t0 ns\n";
    const c = parseFdinfo(text).?;
    try std.testing.expectEqualStrings("0000:03:00.0", c.pdevSlice());
    try std.testing.expectEqual(@as(u64, 17), c.client_id);
    try std.testing.expectEqual(@as(usize, 2), c.engine_count);
    // Resident, not also the legacy alias; less what is shared.
    try std.testing.expectEqual(@as(u64, 65536 + 2048 - 1024), c.memory_kb);
    var later = c;
    later.engines[0].ns += 250_000_000;
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), clientBusy(&c, &later, 1_000_000_000), 1e-9);
}

test "an i915 client and a file that is not a GPU's" {
    const text = "drm-driver:\ti915\ndrm-pdev:\t0000:00:02.0\ndrm-client-id:\t4\ndrm-engine-render:\t123 ns\ndrm-engine-capacity-video:\t2\ndrm-total-system0:\t12 MiB\n";
    const c = parseFdinfo(text).?;
    try std.testing.expectEqual(@as(usize, 1), c.engine_count);
    try std.testing.expectEqualStrings("render", c.engines[0].nameSlice());
    try std.testing.expectEqual(@as(u64, 12 * 1024), c.memory_kb);
    try std.testing.expect(parseFdinfo("pos:\t0\nflags:\t0100002\n") == null);
}

test "a GPU's load is its busiest engine" {
    var l: Load = .{};
    l.add("gfx", 300);
    l.add("video", 100);
    l.add("gfx", 200);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), l.busy(1000), 1e-9);
}

test "nvidia-smi" {
    const n = parseNvidiaSmi("00000000:01:00.0, 37, 1024, 8192, 55, 41.20, 1500").?;
    try std.testing.expectEqualStrings("0000:01:00.0", std.mem.sliceTo(&n.bus, 0));
    try std.testing.expectEqual(@as(f64, 37), n.utilization.?);
    try std.testing.expectEqual(@as(f64, 41.2), n.power_w.?);
    const na = parseNvidiaSmi("00000000:01:00.0, [N/A], 10, 100, 40, [N/A], 300").?;
    try std.testing.expect(na.utilization == null);
}
