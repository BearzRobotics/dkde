//! The kernel's VT layer (SPEC.md 5.11, *VT handling*). It is the protocol every
//! display program uses, so the console coexists with labwc under seatd, or any
//! other compositor, on another VT.

const std = @import("std");
const sys = @import("sys.zig");

const log = std.log.scoped(.vt);

const KDSETMODE: c_ulong = 0x4B3A;
const KDSKBMODE: c_ulong = 0x4B45;
const KDGKBMODE: c_ulong = 0x4B44;
const KD_TEXT = 0;
const KD_GRAPHICS = 1;
const K_UNICODE = 3;
const K_OFF = 4;

const VT_GETMODE: c_ulong = 0x5601;
const VT_SETMODE: c_ulong = 0x5602;
const VT_GETSTATE: c_ulong = 0x5603;
const VT_RELDISP: c_ulong = 0x5605;
const VT_ACTIVATE: c_ulong = 0x5606;
const VT_AUTO = 0;
const VT_PROCESS = 1;
const VT_ACKACQ = 2;

const VtMode = extern struct { mode: u8, waitv: u8, relsig: i16, acqsig: i16, frsig: i16 };
const VtState = extern struct { v_active: u16, v_signal: u16, v_state: u16 };

pub const SIGHUP = 1;
pub const SIGINT = 2;
pub const SIGTERM = 15;
pub const SIGCHLD = 17;
pub const SIGUSR1 = 10; // the kernel asks us to release the VT
pub const SIGUSR2 = 12; // the VT is ours again

pub const Vt = struct {
    fd: c_int,
    num: u32,

    pub fn open(num: u32) ?Vt {
        var b: [24]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&b, "/dev/tty{d}", .{num}, 0) catch return null;
        const fd = sys.open(path.ptr, sys.O_RDWR | sys.O_CLOEXEC | 0o400); // O_NOCTTY
        if (fd < 0) return null;
        return .{ .fd = fd, .num = num };
    }

    pub fn close(self: *Vt) void {
        _ = sys.close(self.fd);
        self.fd = -1;
    }

    /// Put the VT back the way a text getty expects it. Every start does this
    /// first, because a crash cannot (SPEC.md 5.11, *Restoring the VT*).
    pub fn restoreText(self: *const Vt) void {
        _ = sys.ioctl(self.fd, KDSETMODE, @as(c_ulong, KD_TEXT));
        _ = sys.ioctl(self.fd, KDSKBMODE, @as(c_ulong, K_UNICODE));
        const auto: VtMode = .{ .mode = VT_AUTO, .waitv = 0, .relsig = 0, .acqsig = 0, .frsig = 0 };
        _ = sys.ioctl(self.fd, VT_SETMODE, &auto);
    }

    /// Take the VT: switching away asks us first, the kernel stops drawing text
    /// on it, and keystrokes reach only us.
    pub fn take(self: *const Vt) bool {
        const mode: VtMode = .{ .mode = VT_PROCESS, .waitv = 0, .relsig = SIGUSR1, .acqsig = SIGUSR2, .frsig = 0 };
        if (sys.ioctl(self.fd, VT_SETMODE, &mode) != 0) {
            log.err("tty{d}: VT_SETMODE failed (errno {d}); switching away will not be announced", .{ self.num, sys.errno() });
            return false;
        }
        if (sys.ioctl(self.fd, KDSETMODE, @as(c_ulong, KD_GRAPHICS)) != 0)
            log.warn("tty{d}: KDSETMODE KD_GRAPHICS failed (errno {d}); the kernel may draw over the screen", .{ self.num, sys.errno() });
        if (sys.ioctl(self.fd, KDSKBMODE, @as(c_ulong, K_OFF)) != 0)
            log.warn("tty{d}: KDSKBMODE K_OFF failed (errno {d}); keys may also reach the kernel console", .{ self.num, sys.errno() });
        log.debug("tty{d}: taken (VT_PROCESS, KD_GRAPHICS, K_OFF)", .{self.num});
        return true;
    }

    /// Whether this VT is the one on screen.
    pub fn isActive(self: *const Vt) bool {
        var st: VtState = undefined;
        if (sys.ioctl(self.fd, VT_GETSTATE, &st) != 0) return true;
        return st.v_active == self.num;
    }

    /// Acknowledge a release request. Always sent, even mid-redraw: without it
    /// the kernel refuses the switch and the user cannot leave.
    pub fn ackRelease(self: *const Vt) void {
        if (sys.ioctl(self.fd, VT_RELDISP, @as(c_ulong, 1)) != 0) log.warn("tty{d}: VT_RELDISP (release) failed, errno {d}", .{ self.num, sys.errno() });
    }

    pub fn ackAcquire(self: *const Vt) void {
        if (sys.ioctl(self.fd, VT_RELDISP, @as(c_ulong, VT_ACKACQ)) != 0) log.warn("tty{d}: VT_RELDISP (acquire) failed, errno {d}", .{ self.num, sys.errno() });
    }

    pub fn activate(self: *const Vt, n: u32) void {
        log.debug("switching to tty{d}", .{n});
        if (sys.ioctl(self.fd, VT_ACTIVATE, @as(c_ulong, n)) != 0) log.warn("VT_ACTIVATE {d} failed, errno {d}", .{ n, sys.errno() });
    }
};

// ---- signals through a pipe -----------------------------------------------------

extern fn signal(sig: c_int, handler: *const fn (c_int) callconv(.c) void) ?*anyopaque;
extern fn pipe2(fds: *[2]c_int, flags: c_int) c_int;

var pipe_write: c_int = -1;

fn handler(sig: c_int) callconv(.c) void {
    const saved = sys.errno();
    const b: [1]u8 = .{@intCast(sig)};
    _ = sys.write(pipe_write, &b, 1);
    sys.__errno_location().* = saved;
}

/// Install handlers that turn the signals the console cares about into bytes
/// on a pipe, so the main loop sees them in its `poll`. Returns the read end.
pub fn installSignals() ?c_int {
    var fds: [2]c_int = undefined;
    if (pipe2(&fds, sys.O_CLOEXEC | sys.O_NONBLOCK) != 0) return null;
    pipe_write = fds[1];
    for ([_]c_int{ SIGUSR1, SIGUSR2, SIGTERM, SIGINT, SIGHUP, SIGCHLD }) |s| _ = signal(s, handler);
    return fds[0];
}

/// Pending signal numbers, oldest first.
pub fn drainSignals(fd: c_int, buf: []u8) []const u8 {
    const n = sys.read(fd, buf.ptr, buf.len);
    return if (n > 0) buf[0..@intCast(n)] else buf[0..0];
}
