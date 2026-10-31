//! `dkde-parted --selftest IMAGE`: runs the commands the tool generates against
//! a scratch image file, one filesystem at a time, and says what worked. It
//! needs administrator rights (loop devices), so run it as root on a machine
//! where that is safe. It never touches a disk, only the image file it
//! creates (and deletes).

const std = @import("std");
const common = @import("common");
const model = @import("model.zig");
const fs = @import("fs.zig");
const ops = @import("ops.zig");

extern fn system(command: [*:0]const u8) c_int;
extern fn popen(command: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern fn pclose(stream: *anyopaque) c_int;
extern fn fread(ptr: [*]u8, size: usize, n: usize, stream: *anyopaque) usize;
extern fn getuid() c_uint;
extern fn write(fd: c_int, buf: [*]const u8, count: usize) isize;

fn say(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = write(1, text.ptr, text.len);
}

fn shell(a: std.mem.Allocator, command: []const u8) bool {
    const z = a.dupeSentinel(u8, command, 0) catch return false;
    defer a.free(z);
    return system(z.ptr) == 0;
}

/// stdout of `command`.
fn capture(a: std.mem.Allocator, command: []const u8) ![]u8 {
    const z = try a.dupeSentinel(u8, command, 0);
    defer a.free(z);
    const f = popen(z.ptr, "r") orelse return error.PopenFailed;
    defer _ = pclose(f);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = fread(&buf, 1, buf.len, f);
        if (n == 0) break;
        try out.appendSlice(a, buf[0..n]);
    }
    return out.toOwnedSlice(a);
}

fn runCmd(a: std.mem.Allocator, cmd: ops.Cmd) bool {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(a);
    for (cmd.argv, 0..) |w, i| {
        if (i > 0) line.append(a, ' ') catch return false;
        line.appendSlice(a, fs.quote(a, w) catch return false) catch return false;
    }
    line.appendSlice(a, " >/dev/null 2>&1") catch return false;
    return shell(a, line.items);
}

fn readDisk(a: std.mem.Allocator, image: []const u8) !model.Disk {
    const cmd = try std.fmt.allocPrint(a, "parted -m -s {s} unit B print 2>/dev/null", .{try fs.quote(a, image)});
    const out = try capture(a, cmd);
    return model.parsePartedMachine(a, image, out, 0);
}

fn step(name: []const u8, ok: bool, failures: *usize) void {
    say("    {s} {s}\n", .{ if (ok) "pass" else "FAIL", name });
    if (!ok) failures.* += 1;
}

pub fn run(allocator: std.mem.Allocator, image: []const u8) u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    if (getuid() != 0) {
        say("The self-test needs administrator rights (it attaches loop devices). Run it with sudo.\n", .{});
        return 2;
    }
    say("Self-test on the scratch image {s} (it is created and removed here).\n", .{image});
    const make = ops.Cmd{ .argv = fs.newImage(a, image, 768, "gpt") catch return 2, .root = false };
    if (!runCmd(a, make)) {
        say("Cannot create the image.\n", .{});
        return 2;
    }
    defer _ = shell(a, std.fmt.allocPrint(a, "rm -f {s}", .{fs.quote(a, image) catch ""}) catch "true");

    var failures: usize = 0;
    var tested: usize = 0;
    for (&fs.table) |*f| {
        if (!common.proc.hasProgram(f.mkfs)) {
            say("{s}: skipped ({s} is not installed; package {s})\n", .{ f.name, f.mkfs, f.package });
            continue;
        }
        tested += 1;
        say("{s}:\n", .{f.name});
        var disk = readDisk(a, image) catch {
            step("read the image", false, &failures);
            continue;
        };
        const gaps = model.freeSpace(a, disk) catch &.{};
        if (gaps.len == 0) {
            step("free space", false, &failures);
            continue;
        }
        const start_mib = gaps[0].start * disk.sector / model.mib;
        const number = fs.nextNumber(disk);
        // Create, format, then check, label and grow, each against the layout at that point.
        const create: ops.Op = .{ .create = .{ .start_mib = start_mib, .end_mib = start_mib + 64 } };
        step("create partition", runCmd(a, (ops.commands(a, disk, create) catch null) orelse continue), &failures);
        disk = readDisk(a, image) catch continue;
        const format: ops.Op = .{ .format = .{ .number = number, .fs = f, .label = "dkdetest" } };
        step("format", runCmd(a, (ops.commands(a, disk, format) catch null) orelse continue), &failures);
        disk = readDisk(a, image) catch continue;
        if (fs.checkScript(a, image, number, "", f) catch null) |argv| step("check", runCmd(a, .{ .argv = argv, .root = true }), &failures);
        if (f.relabel != null) {
            disk = readDisk(a, image) catch continue;
            const relabel: ops.Op = .{ .label = .{ .number = number, .label = "renamed" } };
            if (ops.commands(a, disk, relabel) catch null) |c| step("change label", runCmd(a, c), &failures);
        }
        if (f.grow != null) {
            disk = readDisk(a, image) catch continue;
            const grow: ops.Op = .{ .resize = .{ .number = number, .new_end_mib = start_mib + 96 } };
            if (ops.commands(a, disk, grow) catch null) |c| step("grow", runCmd(a, c), &failures);
        }
        disk = readDisk(a, image) catch continue;
        const del: ops.Op = .{ .delete = .{ .number = number } };
        step("delete partition", runCmd(a, (ops.commands(a, disk, del) catch null) orelse continue), &failures);
    }
    say("\n{d} filesystems tested, {d} step{s} failed.\n", .{ tested, failures, if (failures == 1) "" else "s" });
    return if (failures == 0) 0 else 1;
}
