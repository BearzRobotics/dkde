//! Falling back to a plain text login (SPEC.md 5.11, *Fallback*). The console
//! must never be the reason a user cannot log in: when it cannot start, or has
//! been crashing, it `exec`s the fallback getty on the same VT.

const std = @import("std");
const sys = @import("sys.zig");
const config = @import("consolefont").config;
const Vt = @import("vt.zig").Vt;

extern fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

pub const state_dir = "/run/dkde-console";
/// The console that has run this long counts as healthy and clears its counter.
pub const healthy_seconds = 60;
/// This many starts inside the window go straight to the fallback.
pub const max_starts = 3;

pub const Decision = struct { fall_back: bool, write_count: ?u32 };

/// Given the counter left by earlier starts, decide what this start does. The
/// third start within the window falls back without touching the counter.
pub fn decide(previous: u32) Decision {
    const this = previous + 1;
    if (this >= max_starts) return .{ .fall_back = true, .write_count = null };
    return .{ .fall_back = false, .write_count = this };
}

fn counterPath(buf: []u8, vt: u32) []const u8 {
    return std.fmt.bufPrint(buf, "{s}/tty{d}.starts", .{ state_dir, vt }) catch "";
}

pub fn readCounter(allocator: std.mem.Allocator, vt: u32) u32 {
    var pb: [64]u8 = undefined;
    const text = sys.readFile(allocator, counterPath(&pb, vt), 32) catch return 0;
    defer allocator.free(text);
    return std.fmt.parseInt(u32, std.mem.trim(u8, text, " \n"), 10) catch 0;
}

pub fn writeCounter(vt: u32, count: u32) void {
    var pb: [64]u8 = undefined;
    var nb: [16]u8 = undefined;
    sys.makeDir(state_dir);
    const text = std.fmt.bufPrint(&nb, "{d}\n", .{count}) catch return;
    sys.writeFileAtomic(counterPath(&pb, vt), text) catch {};
}

/// Replace this process with the fallback getty. Only returns if nothing could
/// be started; then it tries the plain `login`-less last resorts so the VT is
/// not left blank.
pub fn execFallback(allocator: std.mem.Allocator, template: []const u8, vt: *const Vt) void {
    vt.restoreText();
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    config.expandFallback(&aw.writer, template, vt.num) catch return;
    tryExec(allocator, aw.written());
    // The configured command did not start: the usual getty places, in order.
    var b: [96]u8 = undefined;
    for ([_][]const u8{ "/sbin/agetty --noclear tty%N linux", "/sbin/getty 38400 tty%N", "/usr/sbin/agetty --noclear tty%N linux" }) |cmd| {
        var w: std.Io.Writer = .fixed(&b);
        config.expandFallback(&w, cmd, vt.num) catch continue;
        tryExec(allocator, w.buffered());
    }
}

fn tryExec(allocator: std.mem.Allocator, command: []const u8) void {
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    defer argv.deinit(allocator);
    var strings: std.ArrayList([:0]u8) = .empty;
    defer {
        for (strings.items) |s| allocator.free(s);
        strings.deinit(allocator);
    }
    var it = std.mem.tokenizeAny(u8, command, " \t");
    while (it.next()) |tok| {
        const z = allocator.dupeSentinel(u8, tok, 0) catch return;
        strings.append(allocator, z) catch {
            allocator.free(z);
            return;
        };
        argv.append(allocator, z.ptr) catch return;
    }
    if (argv.items.len == 0) return;
    argv.append(allocator, null) catch return;
    _ = execv(argv.items[0].?, @ptrCast(argv.items.ptr));
}

test "third start in the window falls back" {
    try std.testing.expectEqual(Decision{ .fall_back = false, .write_count = 1 }, decide(0));
    try std.testing.expectEqual(Decision{ .fall_back = false, .write_count = 2 }, decide(1));
    try std.testing.expectEqual(Decision{ .fall_back = true, .write_count = null }, decide(2));
    try std.testing.expect(decide(40).fall_back);
}
