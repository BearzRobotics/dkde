//! Input straight from the kernel's evdev nodes (SPEC.md 5.11, *Input*): no
//! libinput, libevdev, mtdev or udev. Devices are classified by what they
//! can report, and inotify on /dev/input picks up devices plugged in later
//! (devtmpfs creates the nodes itself). Key repeat comes from the kernel as
//! `value == 2` events.

const std = @import("std");
const sys = @import("sys.zig");

const log = std.log.scoped(.evdev);

const EV_SYN = 0x00;
const EV_KEY = 0x01;
const EV_REL = 0x02;
const EV_ABS = 0x03;
const KEY_A = 30;
const BTN_MOUSE = 0x110;
const BTN_TOUCH = 0x14a;
const REL_X = 0;
const REL_Y = 1;
const REL_HWHEEL = 6;
const REL_WHEEL = 8;
const ABS_X = 0;
const ABS_Y = 1;
const KEY_MAX = 0x2ff;

pub const BTN_LEFT = 0x110;
pub const BTN_RIGHT = 0x111;
pub const BTN_MIDDLE = 0x112;

const InputEvent = extern struct { sec: c_long, usec: c_long, type: u16, code: u16, value: i32 };
const AbsInfo = extern struct { value: i32, minimum: i32, maximum: i32, fuzz: i32, flat: i32, resolution: i32 };

fn eviocgbit(ev: u32, len: u32) c_ulong {
    return (@as(c_ulong, 2) << 30) | (@as(c_ulong, len) << 16) | (@as(c_ulong, 'E') << 8) | (0x20 + ev);
}
fn eviocgabs(axis: u32) c_ulong {
    return (@as(c_ulong, 2) << 30) | (@as(c_ulong, @sizeOf(AbsInfo)) << 16) | (@as(c_ulong, 'E') << 8) | (0x40 + axis);
}

extern fn inotify_init1(flags: c_int) c_int;
extern fn inotify_add_watch(fd: c_int, path: [*:0]const u8, mask: u32) c_int;

pub const Kind = enum { keyboard, mouse, absolute };

pub const Device = struct {
    fd: c_int,
    kind: Kind,
    /// Absolute pointers: the axis ranges.
    abs_x: AbsInfo = std.mem.zeroes(AbsInfo),
    abs_y: AbsInfo = std.mem.zeroes(AbsInfo),
    /// Absolute pointers: last position seen, in device units.
    last_x: i32 = 0,
    last_y: i32 = 0,
    /// Index into the node list, so a removed device can be matched.
    number: u32,
};

/// What the console cares about, already reduced.
pub const Event = union(enum) {
    key: struct { code: u16, value: i32 },
    /// Relative pointer motion in device units.
    motion: struct { dx: i32, dy: i32 },
    /// Absolute pointer position as a fraction of the screen, 0..65535.
    position: struct { x: u16, y: u16 },
    button: struct { code: u16, pressed: bool },
    /// Positive is away from the user (up). One notch is 1.
    wheel: i32,
};

fn bitSet(bits: []const u8, n: usize) bool {
    return n / 8 < bits.len and bits[n / 8] & (@as(u8, 1) << @intCast(n % 8)) != 0;
}

/// Decide what a device is from its capability bits, or null if it is none of
/// the kinds the console uses. Split from the ioctls so it can be tested.
pub fn classify(ev_bits: []const u8, key_bits: []const u8, rel_bits: []const u8, abs_bits: []const u8) ?Kind {
    const has_keys = bitSet(ev_bits, EV_KEY);
    if (has_keys and bitSet(key_bits, KEY_A)) return .keyboard;
    if (bitSet(ev_bits, EV_REL) and bitSet(rel_bits, REL_X) and bitSet(rel_bits, REL_Y) and bitSet(key_bits, BTN_MOUSE)) return .mouse;
    // Tablets and touchpads (single-touch axes) report absolute X and Y.
    if (bitSet(ev_bits, EV_ABS) and bitSet(abs_bits, ABS_X) and bitSet(abs_bits, ABS_Y) and
        (bitSet(key_bits, BTN_MOUSE) or bitSet(key_bits, BTN_TOUCH))) return .absolute;
    return null;
}

pub const Input = struct {
    allocator: std.mem.Allocator,
    devices: std.ArrayList(Device) = .empty,
    watch_fd: c_int = -1,

    pub fn init(allocator: std.mem.Allocator) Input {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Input) void {
        self.closeAll();
        self.devices.deinit(self.allocator);
    }

    /// Open every usable device, and start watching for new ones.
    pub fn open(self: *Input) void {
        if (self.watch_fd < 0) {
            self.watch_fd = inotify_init1(sys.O_CLOEXEC | sys.O_NONBLOCK);
            if (self.watch_fd >= 0) _ = inotify_add_watch(self.watch_fd, "/dev/input", 0x100); // IN_CREATE
        }
        var n: u32 = 0;
        while (n < 64) : (n += 1) self.tryOpen(n);
    }

    /// Close the devices (and the watch): done when the VT is released, so a
    /// background console reads nothing and wakes for nothing.
    pub fn closeAll(self: *Input) void {
        for (self.devices.items) |d| _ = sys.close(d.fd);
        self.devices.clearRetainingCapacity();
        if (self.watch_fd >= 0) {
            _ = sys.close(self.watch_fd);
            self.watch_fd = -1;
        }
    }

    fn isOpen(self: *const Input, number: u32) bool {
        for (self.devices.items) |d| if (d.number == number) return true;
        return false;
    }

    fn tryOpen(self: *Input, number: u32) void {
        if (self.isOpen(number)) return;
        var pb: [32]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&pb, "/dev/input/event{d}", .{number}, 0) catch return;
        const fd = sys.open(path.ptr, sys.O_RDONLY | sys.O_NONBLOCK | sys.O_CLOEXEC);
        if (fd < 0) return;
        var ev_bits: [4]u8 = @splat(0);
        var key_bits: [(KEY_MAX + 8) / 8]u8 = @splat(0);
        var rel_bits: [4]u8 = @splat(0);
        var abs_bits: [8]u8 = @splat(0);
        _ = sys.ioctl(fd, eviocgbit(0, ev_bits.len), &ev_bits);
        _ = sys.ioctl(fd, eviocgbit(EV_KEY, key_bits.len), &key_bits);
        _ = sys.ioctl(fd, eviocgbit(EV_REL, rel_bits.len), &rel_bits);
        _ = sys.ioctl(fd, eviocgbit(EV_ABS, abs_bits.len), &abs_bits);
        const kind = classify(&ev_bits, &key_bits, &rel_bits, &abs_bits) orelse {
            _ = sys.close(fd);
            return;
        };
        var dev: Device = .{ .fd = fd, .kind = kind, .number = number };
        if (kind == .absolute) {
            _ = sys.ioctl(fd, eviocgabs(ABS_X), &dev.abs_x);
            _ = sys.ioctl(fd, eviocgabs(ABS_Y), &dev.abs_y);
            if (dev.abs_x.maximum <= dev.abs_x.minimum or dev.abs_y.maximum <= dev.abs_y.minimum) {
                _ = sys.close(fd);
                return;
            }
        }
        self.devices.append(self.allocator, dev) catch {
            _ = sys.close(fd);
            return;
        };
    }

    /// Fill `fds` with the descriptors to poll (the hotplug watch first, then
    /// the devices) and return how many were used.
    pub fn pollFds(self: *const Input, fds: []PollFd) usize {
        var n: usize = 0;
        if (self.watch_fd >= 0 and n < fds.len) {
            fds[n] = .{ .fd = self.watch_fd, .events = POLLIN, .revents = 0 };
            n += 1;
        }
        for (self.devices.items) |d| {
            if (n >= fds.len) break;
            fds[n] = .{ .fd = d.fd, .events = POLLIN, .revents = 0 };
            n += 1;
        }
        return n;
    }

    /// Read what is waiting on `fd` (one of the descriptors from `pollFds`) and
    /// append the events. A device that went away is closed and dropped.
    pub fn service(self: *Input, fd: c_int, out: *std.ArrayList(Event)) void {
        if (fd == self.watch_fd) {
            self.drainWatch();
            return;
        }
        var index: ?usize = null;
        for (self.devices.items, 0..) |d, i| if (d.fd == fd) {
            index = i;
            break;
        };
        const i = index orelse return;
        const dev = &self.devices.items[i];

        var buf: [32]InputEvent = undefined;
        var dx: i32 = 0;
        var dy: i32 = 0;
        var wheel: i32 = 0;
        var moved_abs = false;
        while (true) {
            const n = sys.read(fd, @ptrCast(&buf), @sizeOf(@TypeOf(buf)));
            if (n < 0) {
                if (sys.errno() == sys.EINTR) continue;
                if (sys.errno() == sys.EAGAIN) break;
                // The device is gone (ENODEV) or unreadable.
                _ = sys.close(fd);
                _ = self.devices.swapRemove(i);
                return;
            }
            if (n == 0) break;
            const count = @as(usize, @intCast(n)) / @sizeOf(InputEvent);
            for (buf[0..count]) |e| {
                switch (e.type) {
                    EV_KEY => if (dev.kind == .keyboard and e.code < 0x100) {
                        out.append(self.allocator, .{ .key = .{ .code = e.code, .value = e.value } }) catch {};
                    } else if (e.code >= BTN_MOUSE and e.code <= BTN_MIDDLE or e.code == BTN_TOUCH) {
                        const code: u16 = if (e.code == BTN_TOUCH) BTN_LEFT else e.code;
                        if (e.value != 2) out.append(self.allocator, .{ .button = .{ .code = code, .pressed = e.value != 0 } }) catch {};
                    },
                    EV_REL => switch (e.code) {
                        REL_X => dx += e.value,
                        REL_Y => dy += e.value,
                        REL_WHEEL => wheel += e.value,
                        else => {},
                    },
                    EV_ABS => if (dev.kind == .absolute) {
                        if (e.code == ABS_X) dev.last_x = e.value;
                        if (e.code == ABS_Y) dev.last_y = e.value;
                        moved_abs = e.code == ABS_X or e.code == ABS_Y or moved_abs;
                    },
                    else => {},
                }
            }
            if (count < buf.len) break;
        }
        if (dx != 0 or dy != 0) out.append(self.allocator, .{ .motion = .{ .dx = dx, .dy = dy } }) catch {};
        if (wheel != 0) out.append(self.allocator, .{ .wheel = wheel }) catch {};
        if (moved_abs) {
            out.append(self.allocator, .{ .position = .{
                .x = scale(dev.last_x, dev.abs_x),
                .y = scale(dev.last_y, dev.abs_y),
            } }) catch {};
        }
    }

    fn drainWatch(self: *Input) void {
        var buf: [1024]u8 align(4) = undefined;
        while (true) {
            const n = sys.read(self.watch_fd, &buf, buf.len);
            if (n <= 0) break;
        }
        // devtmpfs may still be setting the node up; scanning again is cheap
        // and ignores devices that are already open.
        var n: u32 = 0;
        while (n < 64) : (n += 1) self.tryOpen(n);
    }
};

fn scale(v: i32, info: AbsInfo) u16 {
    const span: i64 = @as(i64, info.maximum) - info.minimum;
    if (span <= 0) return 0;
    const p = std.math.clamp(@as(i64, v) - info.minimum, 0, span);
    return @intCast(@divTrunc(p * 65535, span));
}

pub const POLLIN: c_short = 1;
pub const PollFd = extern struct { fd: c_int, events: c_short, revents: c_short };

const testing = std.testing;

fn bitsOf(comptime n: usize, set: []const usize) [n]u8 {
    var b: [n]u8 = @splat(0);
    for (set) |i| b[i / 8] |= @as(u8, 1) << @intCast(i % 8);
    return b;
}

test "classify keyboards, mice and tablets" {
    const ev_kbd = bitsOf(4, &.{EV_SYN, EV_KEY});
    const keys_kbd = bitsOf(96, &.{ KEY_A, 1 });
    try testing.expectEqual(Kind.keyboard, classify(&ev_kbd, &keys_kbd, &.{}, &.{}).?);

    const ev_mouse = bitsOf(4, &.{ EV_KEY, EV_REL });
    const keys_mouse = bitsOf(96, &.{BTN_MOUSE});
    const rel = bitsOf(4, &.{ REL_X, REL_Y, REL_WHEEL });
    try testing.expectEqual(Kind.mouse, classify(&ev_mouse, &keys_mouse, &rel, &.{}).?);

    const ev_tab = bitsOf(4, &.{ EV_KEY, EV_ABS });
    const keys_tab = bitsOf(96, &.{BTN_TOUCH});
    const abs = bitsOf(8, &.{ ABS_X, ABS_Y });
    try testing.expectEqual(Kind.absolute, classify(&ev_tab, &keys_tab, &.{}, &abs).?);

    // A lid switch, or a power button with no letter keys.
    const ev_btn = bitsOf(4, &.{EV_KEY});
    const keys_btn = bitsOf(96, &.{116});
    try testing.expect(classify(&ev_btn, &keys_btn, &.{}, &.{}) == null);
}

test "absolute scaling" {
    const info: AbsInfo = .{ .value = 0, .minimum = 100, .maximum = 1100, .fuzz = 0, .flat = 0, .resolution = 0 };
    try testing.expectEqual(@as(u16, 0), scale(100, info));
    try testing.expectEqual(@as(u16, 65535), scale(1100, info));
    try testing.expectEqual(@as(u16, 32767), scale(600, info));
    try testing.expectEqual(@as(u16, 0), scale(-5, info));
}

test "struct sizes" {
    try testing.expectEqual(@as(usize, 24), @sizeOf(InputEvent));
    // EVIOCGBIT(EV_KEY, 96) and EVIOCGABS(ABS_X).
    try testing.expectEqual(@as(c_ulong, 0x80604521), eviocgbit(EV_KEY, 96));
    try testing.expectEqual(@as(c_ulong, 0x80184540), eviocgabs(ABS_X));
}
