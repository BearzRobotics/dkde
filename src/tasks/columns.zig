//! The columns of the process lists (Processes and Details): their titles,
//! how a process shows in each, how busy figures are tinted, and how each
//! sorts. Shared so both pages read the same.

const std = @import("std");
const gtk = @import("gtk4");
const sampler_mod = @import("sampler.zig");
const perf = @import("perf.zig");

const Process = sampler_mod.Process;
const Sampler = sampler_mod.Sampler;

pub const Column = enum {
    name,
    pid,
    status,
    user,
    cpu,
    memory,
    disk,
    gpu,
    gpu_memory,
    threads,
    priority,
    cpu_time,
    started,
    swap,
    disk_read,
    disk_written,
    unit,
    elevated,
    command,

    pub fn title(self: Column) [:0]const u8 {
        return switch (self) {
            .name => "Name",
            .pid => "PID",
            .status => "Status",
            .user => "User name",
            .cpu => "CPU",
            .memory => "Memory",
            .disk => "Disk",
            .gpu => "GPU",
            .gpu_memory => "GPU memory",
            .threads => "Threads",
            .priority => "Priority",
            .cpu_time => "CPU time",
            .started => "Started",
            .swap => "Swap",
            .disk_read => "Disk read",
            .disk_written => "Disk written",
            .unit => "Service",
            .elevated => "Elevated",
            .command => "Command line",
        };
    }

    /// Numbers people want the biggest of first.
    pub fn bigFirst(self: Column) bool {
        return switch (self) {
            .cpu, .memory, .disk, .gpu, .gpu_memory, .threads, .cpu_time, .swap, .disk_read, .disk_written => true,
            else => false,
        };
    }

    pub fn rightAligned(self: Column) bool {
        return switch (self) {
            .name, .status, .user, .priority, .unit, .elevated, .command, .started => false,
            else => true,
        };
    }
};

/// Shown in Details the first time; the View menu turns the others on.
pub const details_default = [_]Column{ .name, .pid, .status, .user, .cpu, .memory, .disk, .gpu, .threads };

/// The Windows names for nice values: root may go above Normal, anyone below.
pub const priorities = [_]struct { label: [:0]const u8, nice: c_int }{
    .{ .label = "Realtime-like (High)", .nice = -15 },
    .{ .label = "High", .nice = -10 },
    .{ .label = "Above normal", .nice = -5 },
    .{ .label = "Normal", .nice = 0 },
    .{ .label = "Below normal", .nice = 5 },
    .{ .label = "Low", .nice = 15 },
};

pub fn priorityText(buf: []u8, nice: i32) []const u8 {
    const name: []const u8 = if (nice <= -10) "High" else if (nice < 0) "Above normal" else if (nice == 0) "Normal" else if (nice < 10) "Below normal" else "Low";
    return std.fmt.bufPrint(buf, "{s} ({d})", .{ name, nice }) catch name;
}

pub fn statusText(p: *const Process) []const u8 {
    return switch (p.state) {
        'T', 't' => "Suspended",
        'Z' => "Ended (zombie)",
        'D' => "Waiting for disk",
        else => if (p.efficient()) "Efficiency mode" else switch (p.state) {
            'R' => "Running",
            'S' => "",
            'I' => "Idle",
            else => "",
        },
    };
}

fn kb(buf: []u8, v: u64) []const u8 {
    if (v >= 10 * 1024) return std.fmt.bufPrint(buf, "{d:.1} MB", .{@as(f64, @floatFromInt(v)) / 1024}) catch "";
    return std.fmt.bufPrint(buf, "{d} kB", .{v}) catch "";
}

fn bytes(buf: []u8, v: u64) []const u8 {
    return kb(buf, v / 1024);
}

/// The text of `p` in column `c`.
pub fn text(buf: []u8, s: *const Sampler, p: *const Process, c: Column) []const u8 {
    return switch (c) {
        .name => p.nameSlice(),
        .pid => std.fmt.bufPrint(buf, "{d}", .{p.pid}) catch "",
        .status => statusText(p),
        .user => p.userSlice(),
        .cpu => std.fmt.bufPrint(buf, "{d:.1}%", .{p.cpu}) catch "",
        .memory => kb(buf, p.private_kb),
        .disk => if (p.io != .ok) "—" else blk: {
            var rb: [32]u8 = undefined;
            break :blk std.fmt.bufPrint(buf, "{s}", .{perf.fmtByteRate(&rb, p.disk_rate)}) catch "";
        },
        .gpu => if (!p.has_gpu) "" else std.fmt.bufPrint(buf, "{d:.1}%", .{p.gpu * 100}) catch "",
        .gpu_memory => if (!p.has_gpu) "" else kb(buf, p.gpu_mem_kb),
        .threads => std.fmt.bufPrint(buf, "{d}", .{p.threads}) catch "",
        .priority => priorityText(buf, p.nice),
        .cpu_time => blk: {
            const secs: u64 = @intFromFloat(@as(f64, @floatFromInt(p.ticks)) / s.clock_ticks);
            break :blk std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ secs / 3600, (secs / 60) % 60, secs % 60 }) catch "";
        },
        .started => blk: {
            const t = s.startTime(p);
            const dt = @import("glib2").DateTime.newFromUnixLocal(t) orelse break :blk "";
            defer dt.unref();
            const f = dt.format("%Y-%m-%d %H:%M") orelse break :blk "";
            defer @import("glib2").free(f);
            break :blk std.fmt.bufPrint(buf, "{s}", .{std.mem.span(f)}) catch "";
        },
        .swap => if (p.swap_kb == 0) "" else kb(buf, p.swap_kb),
        .disk_read => if (p.io != .ok) "—" else bytes(buf, p.read_bytes),
        .disk_written => if (p.io != .ok) "—" else bytes(buf, p.write_bytes),
        .unit => p.unitSlice(),
        .elevated => if (p.isKernel()) "" else if (p.euid == 0) "Yes" else "No",
        .command => p.cmdSlice(),
    };
}

/// How strongly a busy figure is tinted, 0 to 3, as in Windows.
pub fn heat(p: *const Process, c: Column) u8 {
    return switch (c) {
        .cpu => if (p.cpu >= 25) 3 else if (p.cpu >= 8) 2 else if (p.cpu >= 0.5) 1 else 0,
        .memory => if (p.private_kb >= 1024 * 1024) 3 else if (p.private_kb >= 400 * 1024) 2 else if (p.private_kb >= 100 * 1024) 1 else 0,
        .disk => if (p.disk_rate >= 50 * 1024 * 1024) 3 else if (p.disk_rate >= 10 * 1024 * 1024) 2 else if (p.disk_rate >= 1024 * 1024) 1 else 0,
        .gpu => if (p.gpu >= 0.5) 3 else if (p.gpu >= 0.15) 2 else if (p.gpu >= 0.02) 1 else 0,
        else => 0,
    };
}

pub fn applyHeat(widget: *gtk.Widget, level: u8) void {
    for ([_][:0]const u8{ "dkde-heat-1", "dkde-heat-2", "dkde-heat-3" }, 1..) |cls, i| {
        if (level == i) widget.addCssClass(cls) else widget.removeCssClass(cls);
    }
}

/// Whether `a` comes before `b` sorted by `c` (`reverse` flips it).
pub fn less(s: *const Sampler, a: *const Process, b: *const Process, c: Column, reverse: bool) bool {
    _ = s;
    // Reversed means the arguments swapped, never "not forward": with ties the latter says
    // both a<b and b<a, which is not an ordering and aborts std's sort.
    return if (reverse) before(b, a, c) else before(a, b, c);
}

fn before(a: *const Process, b: *const Process, c: Column) bool {
    return switch (c) {
        .cpu => if (a.cpu != b.cpu) a.cpu > b.cpu else a.private_kb > b.private_kb,
        .memory => a.private_kb > b.private_kb,
        .disk => if (a.disk_rate != b.disk_rate) a.disk_rate > b.disk_rate else a.private_kb > b.private_kb,
        .gpu => if (a.gpu != b.gpu) a.gpu > b.gpu else a.gpu_mem_kb > b.gpu_mem_kb,
        .gpu_memory => a.gpu_mem_kb > b.gpu_mem_kb,
        .threads => a.threads > b.threads,
        .cpu_time => a.ticks > b.ticks,
        .swap => a.swap_kb > b.swap_kb,
        .disk_read => a.read_bytes > b.read_bytes,
        .disk_written => a.write_bytes > b.write_bytes,
        .started => a.start_ticks < b.start_ticks,
        .name => std.ascii.lessThanIgnoreCase(a.nameSlice(), b.nameSlice()),
        .user => std.ascii.lessThanIgnoreCase(a.userSlice(), b.userSlice()),
        .status => std.ascii.lessThanIgnoreCase(statusText(a), statusText(b)),
        .command => std.ascii.lessThanIgnoreCase(a.cmdSlice(), b.cmdSlice()),
        .unit => std.ascii.lessThanIgnoreCase(a.unitSlice(), b.unitSlice()),
        .elevated => a.euid < b.euid,
        .priority => a.nice < b.nice,
        .pid => a.pid < b.pid,
    };
}
