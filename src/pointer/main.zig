//! dkde-pointer: a development aid that drives the pointer through
//! `wlr-virtual-pointer`, so hover, click and scroll behaviour can be tested
//! without hands. Not part of the desktop; it is installed with the rest only
//! because the build treats every component alike.
//!
//!     dkde-pointer [--size WxH] move X Y | click [left|right|middle] | scroll N | sleep MS ...
//!
//! Commands run in order. `--size` is the output size the coordinates refer to
//! (default 1280x720).

const std = @import("std");
const wayland = @import("wayland");

const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern fn usleep(microseconds: c_uint) c_int;
const Timespec = extern struct { sec: i64, nsec: i64 };
extern fn clock_gettime(clock: c_int, spec: *Timespec) c_int;

const Globals = struct {
    seat: ?*wl.Seat = null,
    manager: ?*zwlr.VirtualPointerManagerV1 = null,
};

fn registryEvent(registry: *wl.Registry, event: wl.Registry.Event, globals: *Globals) void {
    switch (event) {
        .global => |g| {
            const name = std.mem.span(g.interface);
            if (std.mem.eql(u8, name, std.mem.span(zwlr.VirtualPointerManagerV1.interface.name))) {
                globals.manager = registry.bind(g.name, zwlr.VirtualPointerManagerV1, @min(g.version, 2)) catch null;
            } else if (std.mem.eql(u8, name, std.mem.span(wl.Seat.interface.name))) {
                if (globals.seat == null) globals.seat = registry.bind(g.name, wl.Seat, 1) catch null;
            }
        },
        .global_remove => {},
    }
}

fn now() u32 {
    var spec: Timespec = undefined;
    _ = clock_gettime(1, &spec); // CLOCK_MONOTONIC
    return @truncate(@as(u64, @intCast(spec.sec)) * 1000 + @as(u64, @intCast(spec.nsec)) / 1_000_000);
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("dkde-pointer: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

pub fn main(init: std.process.Init.Minimal) !void {
    const display = wl.Display.connect(null) catch fail("cannot connect to the compositor", .{});
    const registry = try display.getRegistry();
    var globals: Globals = .{};
    registry.setListener(*Globals, registryEvent, &globals);
    if (display.roundtrip() != .SUCCESS) fail("no answer from the compositor", .{});
    const manager = globals.manager orelse fail("the compositor has no wlr-virtual-pointer", .{});
    const seat = globals.seat orelse fail("no seat", .{});
    const pointer = try manager.createVirtualPointer(seat);

    var width: u32 = 1280;
    var height: u32 = 720;
    const args = init.args.vector[1..];
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const word = std.mem.span(args[i]);
        if (std.mem.eql(u8, word, "--size") and i + 1 < args.len) {
            i += 1;
            var parts = std.mem.splitScalar(u8, std.mem.span(args[i]), 'x');
            width = std.fmt.parseInt(u32, parts.next() orelse "", 10) catch fail("bad --size", .{});
            height = std.fmt.parseInt(u32, parts.next() orelse "", 10) catch fail("bad --size", .{});
        } else if (std.mem.eql(u8, word, "move") and i + 2 < args.len) {
            const x = std.fmt.parseInt(u32, std.mem.span(args[i + 1]), 10) catch fail("bad x", .{});
            const y = std.fmt.parseInt(u32, std.mem.span(args[i + 2]), 10) catch fail("bad y", .{});
            i += 2;
            pointer.motionAbsolute(now(), x, y, width, height);
            pointer.frame();
            if (getenv("DKDE_POINTER_TIMES") != null) std.debug.print("pointer-move {d}\n", .{now()});
        } else if (std.mem.eql(u8, word, "click")) {
            var button: u32 = 0x110; // BTN_LEFT
            if (i + 1 < args.len) {
                const which = std.mem.span(args[i + 1]);
                if (std.mem.eql(u8, which, "right")) button = 0x111;
                if (std.mem.eql(u8, which, "middle")) button = 0x112;
                if (std.mem.eql(u8, which, "left") or std.mem.eql(u8, which, "right") or std.mem.eql(u8, which, "middle")) i += 1;
            }
            pointer.button(now(), button, .pressed);
            pointer.frame();
            _ = display.roundtrip();
            _ = usleep(60_000);
            pointer.button(now(), button, .released);
            pointer.frame();
        } else if (std.mem.eql(u8, word, "scroll") and i + 1 < args.len) {
            const steps = std.fmt.parseInt(i32, std.mem.span(args[i + 1]), 10) catch fail("bad scroll", .{});
            i += 1;
            pointer.axisSource(.wheel);
            pointer.axis(now(), .vertical_scroll, .fromInt(@intCast(steps * 15)));
            pointer.axisDiscrete(now(), .vertical_scroll, .fromInt(@intCast(steps * 15)), steps);
            pointer.frame();
        } else if (std.mem.eql(u8, word, "sleep") and i + 1 < args.len) {
            const ms = std.fmt.parseInt(u32, std.mem.span(args[i + 1]), 10) catch fail("bad sleep", .{});
            i += 1;
            _ = display.roundtrip();
            _ = usleep(ms * 1000);
        } else fail("unknown command: {s}", .{word});
        _ = display.roundtrip();
    }
    pointer.destroy();
    _ = display.roundtrip();
}
