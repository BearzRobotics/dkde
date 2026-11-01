//! Pseudo-terminal plumbing without GLib (SPEC.md 4.3): `openpty`, a child
//! started with `fork`/`execve` on the slave side, `TIOCSWINSZ` for resize.
//! Everything used exists in both glibc and musl.
//!
//! The caller owns the event loop: `fd()` is the master, already
//! non-blocking, to put in a `poll`.

const std = @import("std");

pub const Size = struct { cols: u16, rows: u16, cell_w: u16 = 0, cell_h: u16 = 0 };

const Winsize = extern struct { ws_row: u16, ws_col: u16, ws_xpixel: u16, ws_ypixel: u16 };

extern fn openpty(amaster: *c_int, aslave: *c_int, name: ?[*]u8, termp: ?*const anyopaque, winp: ?*const Winsize) c_int;
extern fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
extern fn fork() c_int;
extern fn setsid() c_int;
extern fn dup2(old: c_int, new: c_int) c_int;
extern fn close(fd: c_int) c_int;
extern fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
extern fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern fn _exit(status: c_int) noreturn;
extern fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
extern fn kill(pid: c_int, sig: c_int) c_int;
extern fn chdir(path: [*:0]const u8) c_int;
extern fn __errno_location() *c_int;

const TIOCSWINSZ: c_ulong = 0x5414;
const TIOCSCTTY: c_ulong = 0x540E;
const F_GETFL = 3;
const F_SETFL = 4;
const F_SETFD = 2;
const FD_CLOEXEC = 1;
const O_NONBLOCK = 0o4000;
const EAGAIN = 11;
const EINTR = 4;
const WNOHANG = 1;

fn errno() c_int {
    return __errno_location().*;
}

pub const Pty = struct {
    master: c_int,
    pid: c_int,

    pub const SpawnOptions = struct {
        /// Absolute path of the program; there is no PATH search.
        path: [:0]const u8,
        /// argv, including argv[0].
        argv: []const [:0]const u8,
        /// The whole environment, each "NAME=value".
        env: []const [:0]const u8,
        size: Size,
        cwd: ?[:0]const u8 = null,
    };

    pub const Error = error{ OpenPtyFailed, ForkFailed, OutOfMemory };

    pub fn spawn(allocator: std.mem.Allocator, opts: SpawnOptions) Error!Pty {
        // Everything the child needs is built before the fork: after it, only
        // async-signal-safe calls are allowed.
        const argv = try allocator.allocSentinel(?[*:0]const u8, opts.argv.len, null);
        defer allocator.free(argv);
        for (opts.argv, 0..) |a, i| argv[i] = a.ptr;
        const envp = try allocator.allocSentinel(?[*:0]const u8, opts.env.len, null);
        defer allocator.free(envp);
        for (opts.env, 0..) |e, i| envp[i] = e.ptr;

        var master: c_int = undefined;
        var slave: c_int = undefined;
        const ws = winsize(opts.size);
        if (openpty(&master, &slave, null, null, &ws) != 0) return error.OpenPtyFailed;
        _ = fcntl(master, F_SETFD, @as(c_int, FD_CLOEXEC));
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | @as(c_int, O_NONBLOCK));

        const pid = fork();
        if (pid < 0) {
            _ = close(master);
            _ = close(slave);
            return error.ForkFailed;
        }
        if (pid == 0) {
            _ = setsid();
            _ = ioctl(slave, TIOCSCTTY, @as(c_int, 0));
            _ = dup2(slave, 0);
            _ = dup2(slave, 1);
            _ = dup2(slave, 2);
            if (slave > 2) _ = close(slave);
            _ = close(master);
            if (opts.cwd) |c| _ = chdir(c.ptr);
            _ = execve(opts.path.ptr, argv.ptr, envp.ptr);
            _exit(127);
        }
        _ = close(slave);
        return .{ .master = master, .pid = pid };
    }

    fn winsize(s: Size) Winsize {
        return .{ .ws_row = s.rows, .ws_col = s.cols, .ws_xpixel = s.cols *| s.cell_w, .ws_ypixel = s.rows *| s.cell_h };
    }

    pub fn fd(self: *const Pty) c_int {
        return self.master;
    }

    pub fn resize(self: *const Pty, size: Size) void {
        const ws = winsize(size);
        _ = ioctl(self.master, TIOCSWINSZ, &ws);
    }

    /// Read what the child wrote. Returns 0 when nothing is waiting, and null
    /// when the child side is closed.
    pub fn readSome(self: *const Pty, buf: []u8) ?usize {
        while (true) {
            const n = read(self.master, buf.ptr, buf.len);
            if (n > 0) return @intCast(n);
            if (n == 0) return null;
            switch (errno()) {
                EINTR => continue,
                EAGAIN => return 0,
                else => return null, // EIO: the slave side closed
            }
        }
    }

    /// Write all of `data`, waiting for a slow child if it must. Input is a
    /// few bytes at a time, so this does not stall the console in practice.
    pub fn writeAll(self: *const Pty, data: []const u8) void {
        var rest = data;
        var spins: u32 = 0;
        while (rest.len > 0) {
            const n = write(self.master, rest.ptr, rest.len);
            if (n > 0) {
                rest = rest[@intCast(n)..];
                spins = 0;
                continue;
            }
            switch (errno()) {
                EINTR => continue,
                EAGAIN => {
                    spins += 1;
                    if (spins > 1000) return; // child is not reading; drop the input
                    std.Thread.yield() catch {};
                },
                else => return,
            }
        }
    }

    /// The exit status if the child has ended, else null. Reaps it.
    pub fn poll(self: *Pty) ?u32 {
        if (self.pid <= 0) return 0;
        var status: c_int = 0;
        const r = waitpid(self.pid, &status, WNOHANG);
        if (r == 0) return null;
        self.pid = 0;
        return @bitCast(status);
    }

    pub fn terminate(self: *Pty) void {
        if (self.pid > 0) {
            _ = kill(self.pid, 15);
            _ = kill(self.pid, 18); // SIGCONT, in case it was stopped
        }
    }

    pub fn deinit(self: *Pty) void {
        self.terminate();
        if (self.pid > 0) _ = waitpid(self.pid, null, 0);
        _ = close(self.master);
        self.* = .{ .master = -1, .pid = 0 };
    }
};

const PollFd = extern struct { fd: c_int, events: c_short, revents: c_short };
extern fn poll(fds: [*]PollFd, n: c_ulong, timeout: c_int) c_int;

test "a child's output arrives on the master" {
    const a = std.testing.allocator;
    var p = try Pty.spawn(a, .{
        .path = "/bin/echo",
        .argv = &.{ "echo", "hello" },
        .env = &.{"TERM=linux"},
        .size = .{ .cols = 80, .rows = 24 },
    });
    defer p.deinit();
    var buf: [64]u8 = undefined;
    var got: usize = 0;
    var tries: usize = 0;
    while (tries < 100) : (tries += 1) {
        var pfd = [1]PollFd{.{ .fd = p.fd(), .events = 1, .revents = 0 }};
        _ = poll(&pfd, 1, 50);
        const n = p.readSome(buf[got..]) orelse break;
        got += n;
    }
    try std.testing.expect(std.mem.indexOf(u8, buf[0..got], "hello") != null);
}
