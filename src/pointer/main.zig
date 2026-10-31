//! dkde-pointer: a development aid that drives the pointer through
//! `wlr-virtual-pointer`, so hover, click and scroll behaviour can be tested
//! without hands. Not part of the desktop; it is installed with the rest only
//! because the build treats every component alike.
//!
//!     dkde-pointer [--size WxH] move X Y | click [left|right|middle] | press|release [button]
//!                  | scroll N | sleep MS
//!                  | chord ctrl+shift+escape | tap super ...
//!
//! `chord` holds the modifiers, taps the last key and lets go; `tap` presses and
//! releases one key (a lone Super press, for instance). Keys: the modifiers
//! ctrl, shift, alt, super, and escape, tab, return, space, f1 to f12, left,
//! right, up, down, a to z, 0 to 9.
//!
//! Commands run in order. `--size` is the output size the coordinates refer to
//! (default 1280x720).

const std = @import("std");
const wayland = @import("wayland");

const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;
const zwp = wayland.client.zwp;

extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern fn usleep(microseconds: c_uint) c_int;
const Timespec = extern struct { sec: i64, nsec: i64 };
extern fn clock_gettime(clock: c_int, spec: *Timespec) c_int;

extern fn memfd_create(name: [*:0]const u8, flags: c_uint) c_int;
extern fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern fn close(fd: c_int) c_int;

const Globals = struct {
    seat: ?*wl.Seat = null,
    manager: ?*zwlr.VirtualPointerManagerV1 = null,
    keyboards: ?*zwp.VirtualKeyboardManagerV1 = null,
};

/// A keymap the compositor compiles from the system's xkb data.
const keymap_text =
    "xkb_keymap {\n" ++
    "  xkb_keycodes { include \"evdev+aliases(qwerty)\" };\n" ++
    "  xkb_types { include \"complete\" };\n" ++
    "  xkb_compat { include \"complete\" };\n" ++
    "  xkb_symbols { include \"pc+us+inet(evdev)\" };\n" ++
    "};\n\x00";

const Key = struct { name: []const u8, code: u32, mod_bit: u32 = 0 };

/// Linux input event codes; the last column is the xkb modifier mask bit.
const keys = [_]Key{
    .{ .name = "ctrl", .code = 29, .mod_bit = 4 },
    .{ .name = "shift", .code = 42, .mod_bit = 1 },
    .{ .name = "alt", .code = 56, .mod_bit = 8 },
    .{ .name = "super", .code = 125, .mod_bit = 64 },
    .{ .name = "escape", .code = 1 },
    .{ .name = "tab", .code = 15 },
    .{ .name = "return", .code = 28 },
    .{ .name = "space", .code = 57 },
    .{ .name = "left", .code = 105 },
    .{ .name = "right", .code = 106 },
    .{ .name = "up", .code = 103 },
    .{ .name = "down", .code = 108 },
    .{ .name = "f1", .code = 59 },
    .{ .name = "f2", .code = 60 },
    .{ .name = "f3", .code = 61 },
    .{ .name = "f4", .code = 62 },
    .{ .name = "f5", .code = 63 },
    .{ .name = "f6", .code = 64 },
    .{ .name = "f7", .code = 65 },
    .{ .name = "f8", .code = 66 },
    .{ .name = "f9", .code = 67 },
    .{ .name = "f10", .code = 68 },
    .{ .name = "f11", .code = 87 },
    .{ .name = "f12", .code = 88 },
    .{ .name = "a", .code = 30 },
    .{ .name = "b", .code = 48 },
    .{ .name = "c", .code = 46 },
    .{ .name = "d", .code = 32 },
    .{ .name = "e", .code = 18 },
    .{ .name = "f", .code = 33 },
    .{ .name = "g", .code = 34 },
    .{ .name = "h", .code = 35 },
    .{ .name = "i", .code = 23 },
    .{ .name = "j", .code = 36 },
    .{ .name = "k", .code = 37 },
    .{ .name = "l", .code = 38 },
    .{ .name = "m", .code = 50 },
    .{ .name = "n", .code = 49 },
    .{ .name = "o", .code = 24 },
    .{ .name = "p", .code = 25 },
    .{ .name = "q", .code = 16 },
    .{ .name = "r", .code = 19 },
    .{ .name = "s", .code = 31 },
    .{ .name = "t", .code = 20 },
    .{ .name = "u", .code = 22 },
    .{ .name = "v", .code = 47 },
    .{ .name = "w", .code = 17 },
    .{ .name = "x", .code = 45 },
    .{ .name = "y", .code = 21 },
    .{ .name = "z", .code = 44 },
    .{ .name = "0", .code = 11 },
    .{ .name = "1", .code = 2 },
    .{ .name = "2", .code = 3 },
    .{ .name = "3", .code = 4 },
    .{ .name = "4", .code = 5 },
    .{ .name = "5", .code = 6 },
    .{ .name = "6", .code = 7 },
    .{ .name = "7", .code = 8 },
    .{ .name = "8", .code = 9 },
    .{ .name = "9", .code = 10 },
};

fn findKey(name: []const u8) ?Key {
    for (keys) |k| if (std.mem.eql(u8, k.name, name)) return k;
    return null;
}

fn registryEvent(registry: *wl.Registry, event: wl.Registry.Event, globals: *Globals) void {
    switch (event) {
        .global => |g| {
            const name = std.mem.span(g.interface);
            if (std.mem.eql(u8, name, std.mem.span(zwlr.VirtualPointerManagerV1.interface.name))) {
                globals.manager = registry.bind(g.name, zwlr.VirtualPointerManagerV1, @min(g.version, 2)) catch null;
            } else if (std.mem.eql(u8, name, std.mem.span(zwp.VirtualKeyboardManagerV1.interface.name))) {
                globals.keyboards = registry.bind(g.name, zwp.VirtualKeyboardManagerV1, 1) catch null;
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

/// A keyboard with a keymap, ready to send keys.
fn createKeyboard(globals: *Globals, seat: *wl.Seat) ?*zwp.VirtualKeyboardV1 {
    const manager = globals.keyboards orelse return null;
    const kb = manager.createVirtualKeyboard(seat) catch return null;
    const fd = memfd_create("dkde-keymap", 0);
    if (fd < 0) return null;
    defer _ = close(fd);
    if (write(fd, keymap_text.ptr, keymap_text.len) != @as(isize, @intCast(keymap_text.len))) return null;
    kb.keymap(1, fd, @intCast(keymap_text.len)); // 1 is xkb_v1
    return kb;
}

/// "ctrl+shift+escape": hold the modifiers, tap the last key, let go.
fn pressChord(kb: *zwp.VirtualKeyboardV1, display: *wl.Display, spec: []const u8) void {
    var held: [8]Key = undefined;
    var n: usize = 0;
    var mods: u32 = 0;
    var parts = std.mem.splitScalar(u8, spec, '+');
    var pending: ?[]const u8 = parts.next();
    while (pending) |name| {
        const next = parts.next();
        const key = findKey(name) orelse fail("unknown key: {s}", .{name});
        if (next == null) {
            // The last one is tapped.
            kb.key(now(), key.code, 1);
            _ = display.roundtrip();
            _ = usleep(50_000);
            kb.key(now(), key.code, 0);
        } else {
            kb.key(now(), key.code, 1);
            if (n < held.len) {
                held[n] = key;
                n += 1;
            }
            mods |= key.mod_bit;
            kb.modifiers(mods, 0, 0, 0);
            _ = display.roundtrip();
        }
        pending = next;
    }
    while (n > 0) {
        n -= 1;
        kb.key(now(), held[n].code, 0);
        mods &= ~held[n].mod_bit;
        kb.modifiers(mods, 0, 0, 0);
    }
    _ = display.roundtrip();
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

    var keyboard: ?*zwp.VirtualKeyboardV1 = null;

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
        } else if (std.mem.eql(u8, word, "press") or std.mem.eql(u8, word, "release")) {
            // Holds or lets go of a button, so a drag can be made in steps.
            var button: u32 = 0x110;
            if (i + 1 < args.len) {
                const which = std.mem.span(args[i + 1]);
                if (std.mem.eql(u8, which, "right")) button = 0x111;
                if (std.mem.eql(u8, which, "middle")) button = 0x112;
                if (std.mem.eql(u8, which, "left") or std.mem.eql(u8, which, "right") or std.mem.eql(u8, which, "middle")) i += 1;
            }
            pointer.button(now(), button, if (std.mem.eql(u8, word, "press")) .pressed else .released);
            pointer.frame();
            _ = display.roundtrip();
        } else if (std.mem.eql(u8, word, "scroll") and i + 1 < args.len) {
            const steps = std.fmt.parseInt(i32, std.mem.span(args[i + 1]), 10) catch fail("bad scroll", .{});
            i += 1;
            pointer.axisSource(.wheel);
            pointer.axis(now(), .vertical_scroll, .fromInt(@intCast(steps * 15)));
            pointer.axisDiscrete(now(), .vertical_scroll, .fromInt(@intCast(steps * 15)), steps);
            pointer.frame();
        } else if ((std.mem.eql(u8, word, "chord") or std.mem.eql(u8, word, "tap")) and i + 1 < args.len) {
            i += 1;
            const spec = std.mem.span(args[i]);
            const kb = keyboard orelse blk: {
                const created = createKeyboard(&globals, seat) orelse fail("no virtual keyboard: the compositor lacks zwp_virtual_keyboard_v1", .{});
                keyboard = created;
                break :blk created;
            };
            pressChord(kb, display, spec);
        } else if (std.mem.eql(u8, word, "sleep") and i + 1 < args.len) {
            const ms = std.fmt.parseInt(u32, std.mem.span(args[i + 1]), 10) catch fail("bad sleep", .{});
            i += 1;
            _ = display.roundtrip();
            _ = usleep(ms * 1000);
        } else fail("unknown command: {s}", .{word});
        _ = display.roundtrip();
    }
    pointer.destroy();
    if (keyboard) |kb| kb.destroy();
    _ = display.roundtrip();
}
