//! Pseudo-terminal plumbing (SPEC.md 5.3): `openpty`, a child started on the
//! slave side, non-blocking reads and writes, and `TIOCSWINSZ` for resize.
//! `openpty` and the spawn path exist in both glibc and musl.

const std = @import("std");
const glib = @import("glib2");

const log = std.log.scoped(.pty);

const Winsize = extern struct { ws_row: u16, ws_col: u16, ws_xpixel: u16, ws_ypixel: u16 };

extern fn openpty(amaster: *c_int, aslave: *c_int, name: ?[*]u8, termp: ?*const anyopaque, winp: ?*const Winsize) c_int;
extern fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
extern fn setsid() c_int;
extern fn dup2(old: c_int, new: c_int) c_int;
extern fn close(fd: c_int) c_int;
extern fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
extern fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
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

pub const Pty = struct {
    allocator: std.mem.Allocator,
    master: c_int,
    pid: glib.Pid = 0,
    /// Bytes waiting for the child to accept them.
    outbox: std.ArrayList(u8) = .empty,
    out_watch: c_uint = 0,

    pub const Size = struct { cols: u16, rows: u16, cell_w: u16 = 0, cell_h: u16 = 0 };

    pub const SpawnOptions = struct {
        /// argv; the first element is searched for in PATH.
        argv: []const []const u8,
        cwd: ?[]const u8 = null,
        /// Extra environment, each "NAME=value".
        env: []const []const u8 = &.{},
        size: Size,
    };

    pub fn spawn(allocator: std.mem.Allocator, opts: SpawnOptions) !*Pty {
        var master: c_int = undefined;
        var slave: c_int = undefined;
        const ws = winsize(opts.size);
        if (openpty(&master, &slave, null, null, &ws) != 0) return error.OpenPtyFailed;
        errdefer _ = close(master);
        defer _ = close(slave);

        // The child must not inherit the master; reads must not block the UI.
        _ = fcntl(master, F_SETFD, @as(c_int, FD_CLOEXEC));
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | @as(c_int, O_NONBLOCK));

        const argv = try allocator.alloc(?[*:0]u8, opts.argv.len + 1);
        defer allocator.free(argv);
        var made: usize = 0;
        defer for (argv[0..made]) |a| allocator.free(std.mem.span(a.?));
        for (opts.argv, 0..) |arg, i| {
            argv[i] = (try allocator.dupeSentinel(u8, arg, 0)).ptr;
            made += 1;
        }
        argv[opts.argv.len] = null;

        var envp = glib.getEnviron();
        envp = glib.environSetenv(envp, "TERM", "xterm-256color", 1);
        envp = glib.environSetenv(envp, "COLORTERM", "truecolor", 1);
        defer glib.strfreev(envp);
        for (opts.env) |entry| {
            const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
            if (eq == 0) continue;
            const name = try allocator.dupeSentinel(u8, entry[0..eq], 0);
            defer allocator.free(name);
            const value = try allocator.dupeSentinel(u8, entry[eq + 1 ..], 0);
            defer allocator.free(value);
            envp = glib.environSetenv(envp, name, value, 1);
        }

        const cwd_z: ?[:0]u8 = if (opts.cwd) |c| try allocator.dupeSentinel(u8, c, 0) else null;
        defer if (cwd_z) |c| allocator.free(c);

        const self = try allocator.create(Pty);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .master = master };

        var err: ?*glib.Error = null;
        var slave_fd = slave;
        if (glib.spawnAsync(
            if (cwd_z) |c| c.ptr else null,
            @ptrCast(argv.ptr),
            envp,
            .{ .search_path = true, .do_not_reap_child = true, .leave_descriptors_open = true },
            childSetup,
            &slave_fd,
            &self.pid,
            &err,
        ) == 0) {
            if (err) |e| {
                log.err("cannot start {s}: {s}", .{ opts.argv[0], e.f_message orelse "unknown error" });
                e.free();
            }
            return error.SpawnFailed;
        }
        return self;
    }

    /// Runs in the child between fork and exec: become the session leader
    /// with the slave as controlling terminal and stdio.
    fn childSetup(data: ?*anyopaque) callconv(.c) void {
        const slave: *c_int = @ptrCast(@alignCast(data.?));
        _ = setsid();
        _ = ioctl(slave.*, TIOCSCTTY, @as(c_int, 0));
        _ = dup2(slave.*, 0);
        _ = dup2(slave.*, 1);
        _ = dup2(slave.*, 2);
        if (slave.* > 2) _ = close(slave.*);
    }

    pub fn deinit(self: *Pty) void {
        if (self.out_watch != 0) _ = glib.Source.remove(self.out_watch);
        _ = close(self.master);
        if (self.pid != 0) glib.spawnClosePid(self.pid);
        self.outbox.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn resize(self: *Pty, size: Size) void {
        const ws = winsize(size);
        _ = ioctl(self.master, TIOCSWINSZ, &ws);
    }

    pub const ReadResult = union(enum) { data: usize, would_block, closed };

    /// Reads whatever is available into `buf`.
    pub fn readSome(self: *Pty, buf: []u8) ReadResult {
        while (true) {
            const n = read(self.master, buf.ptr, buf.len);
            if (n > 0) return .{ .data = @intCast(n) };
            if (n == 0) return .closed;
            switch (__errno_location().*) {
                EINTR => continue,
                EAGAIN => return .would_block,
                else => return .closed, // EIO when the child side closes
            }
        }
    }

    /// Sends bytes to the child, queueing what it will not take yet.
    pub fn send(self: *Pty, bytes: []const u8) void {
        if (bytes.len == 0) return;
        var rest = bytes;
        if (self.outbox.items.len == 0) {
            while (rest.len > 0) {
                const n = write(self.master, rest.ptr, rest.len);
                if (n > 0) {
                    rest = rest[@intCast(n)..];
                    continue;
                }
                if (n < 0 and __errno_location().* == EINTR) continue;
                break;
            }
        }
        if (rest.len == 0) return;
        self.outbox.appendSlice(self.allocator, rest) catch return;
        if (self.out_watch == 0) self.out_watch = glib.timeoutAdd(10, flushTick, self);
    }

    fn flushTick(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Pty = @ptrCast(@alignCast(data.?));
        while (self.outbox.items.len > 0) {
            const n = write(self.master, self.outbox.items.ptr, self.outbox.items.len);
            if (n > 0) {
                self.outbox.replaceRangeAssumeCapacity(0, @intCast(n), &.{});
                continue;
            }
            if (n < 0 and __errno_location().* == EINTR) continue;
            break;
        }
        if (self.outbox.items.len == 0) {
            self.out_watch = 0;
            return 0; // done
        }
        return 1; // try again shortly
    }
};

fn winsize(size: Pty.Size) Winsize {
    return .{ .ws_row = size.rows, .ws_col = size.cols, .ws_xpixel = size.cols * size.cell_w, .ws_ypixel = size.rows * size.cell_h };
}

/// Reads from the pty until the child closes it or `needle` appears.
fn collect(pty: *Pty, out: *std.ArrayList(u8), needle: []const u8) !void {
    var buf: [256]u8 = undefined;
    var tries: usize = 0;
    while (tries < 400) : (tries += 1) {
        switch (pty.readSome(&buf)) {
            .data => |n| {
                try out.appendSlice(std.testing.allocator, buf[0..n]);
                if (std.mem.indexOf(u8, out.items, needle) != null) return;
            },
            .closed => return,
            .would_block => {
                const ts: std.c.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
                _ = std.c.nanosleep(&ts, null);
            },
        }
    }
}

test "a child sees the pty as its terminal, at the requested size" {
    const a = std.testing.allocator;
    const pty = try Pty.spawn(a, .{
        .argv = &.{ "/bin/sh", "-c", "stty size; echo term=$TERM; tty" },
        .size = .{ .cols = 100, .rows = 30 },
    });
    defer pty.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try collect(pty, &out, "/dev/pts");

    try std.testing.expect(std.mem.indexOf(u8, out.items, "30 100") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "term=xterm-256color") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "/dev/pts/") != null);
}

test "input sent to the pty reaches the child" {
    const a = std.testing.allocator;
    const pty = try Pty.spawn(a, .{
        .argv = &.{ "/bin/sh", "-c", "read line; echo got:$line" },
        .size = .{ .cols = 80, .rows = 24 },
    });
    defer pty.deinit();
    pty.send("hello\n");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try collect(pty, &out, "got:hello");
    try std.testing.expect(std.mem.indexOf(u8, out.items, "got:hello") != null);
}
