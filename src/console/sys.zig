//! The few libc calls the console uses directly (SPEC.md 5.11). The console
//! talks to the kernel through file descriptors and ioctls; going through libc
//! (which Zig's standard library does too) keeps this file short and the same
//! for glibc and musl.

const std = @import("std");

pub extern fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
pub extern fn close(fd: c_int) c_int;
pub extern fn read(fd: c_int, buf: [*]u8, count: usize) isize;
pub extern fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
pub extern fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
pub extern fn rename(old: [*:0]const u8, new: [*:0]const u8) c_int;
pub extern fn unlink(path: [*:0]const u8) c_int;
pub extern fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
pub extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;
pub extern fn geteuid() c_uint;
pub extern fn access(path: [*:0]const u8, mode: c_int) c_int;
pub extern fn __errno_location() *c_int;

pub const O_RDONLY = 0;
pub const O_WRONLY = 1;
pub const O_RDWR = 2;
pub const O_CREAT = 0o100;
pub const O_TRUNC = 0o1000;
pub const O_NONBLOCK = 0o4000;
pub const O_CLOEXEC = 0o2000000;
pub const O_DIRECTORY = 0o200000;
pub const EINTR = 4;
pub const EAGAIN = 11;
pub const EACCES = 13;

pub fn errno() c_int {
    return __errno_location().*;
}

/// A path as a null-terminated string on the stack.
pub fn pathZ(buf: *[std.fs.max_path_bytes]u8, path: []const u8) ?[:0]const u8 {
    if (path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

pub fn exists(path: []const u8) bool {
    var b: [std.fs.max_path_bytes]u8 = undefined;
    const z = pathZ(&b, path) orelse return false;
    return access(z.ptr, 0) == 0;
}

pub fn env(name: [:0]const u8) ?[]const u8 {
    const v = getenv(name.ptr) orelse return null;
    return std.mem.span(v);
}

pub const ReadError = error{ NotFound, AccessDenied, TooBig, Failed, OutOfMemory };

/// Whole file into memory. A missing file is `error.NotFound`.
pub fn readFile(allocator: std.mem.Allocator, path: []const u8, max: usize) ReadError![]u8 {
    var b: [std.fs.max_path_bytes]u8 = undefined;
    const z = pathZ(&b, path) orelse return error.Failed;
    const fd = open(z.ptr, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return switch (errno()) {
        2 => error.NotFound,
        EACCES => error.AccessDenied,
        else => error.Failed,
    };
    defer _ = close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = read(fd, &chunk, chunk.len);
        if (n < 0) {
            if (errno() == EINTR) continue;
            return error.Failed;
        }
        if (n == 0) break;
        if (out.items.len + @as(usize, @intCast(n)) > max) return error.TooBig;
        try out.appendSlice(allocator, chunk[0..@intCast(n)]);
    }
    return out.toOwnedSlice(allocator);
}

pub const WriteError = error{ AccessDenied, Failed };

pub fn writeAllFd(fd: c_int, data: []const u8) !void {
    var rest = data;
    while (rest.len > 0) {
        const n = write(fd, rest.ptr, rest.len);
        if (n < 0) {
            if (errno() == EINTR) continue;
            return error.Failed;
        }
        rest = rest[@intCast(n)..];
    }
}

/// Write `data` to `path` through a temporary file and a rename, so a crash or
/// a full disk never leaves a half-written configuration.
pub fn writeFileAtomic(path: []const u8, data: []const u8) WriteError!void {
    var b1: [std.fs.max_path_bytes]u8 = undefined;
    var b2: [std.fs.max_path_bytes]u8 = undefined;
    const final = pathZ(&b1, path) orelse return error.Failed;
    var tmp_name: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_name, "{s}.tmp", .{path}) catch return error.Failed;
    const tmp = pathZ(&b2, tmp_path) orelse return error.Failed;
    const fd = open(tmp.ptr, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, @as(c_uint, 0o644));
    if (fd < 0) return if (errno() == EACCES or errno() == 1 or errno() == 30) error.AccessDenied else error.Failed;
    writeAllFd(fd, data) catch {
        _ = close(fd);
        _ = unlink(tmp.ptr);
        return error.Failed;
    };
    _ = close(fd);
    if (rename(tmp.ptr, final.ptr) != 0) {
        _ = unlink(tmp.ptr);
        return error.Failed;
    }
}

pub fn makeDir(path: []const u8) void {
    var b: [std.fs.max_path_bytes]u8 = undefined;
    const z = pathZ(&b, path) orelse return;
    _ = mkdir(z.ptr, 0o755);
}

/// Print to standard output or error. Failures are ignored: there is nowhere
/// left to report them.
pub fn print(fd: c_int, comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch &buf;
    writeAllFd(fd, s) catch {};
}

// ---- logging -----------------------------------------------------------------

/// The runtime level; `[console] log-level` sets it, live. Messages go to
/// standard error, which the init system collects (dinit's log, the journal).
pub var log_level: std.log.Level = .info;
/// The VT this process is on, shown in every line; 0 for the config tool.
pub var log_vt: u32 = 0;

const Timespec = extern struct { sec: c_long, nsec: c_long };
extern fn clock_gettime(clock: c_int, ts: *Timespec) c_int;

pub fn parseLevel(text: []const u8) std.log.Level {
    if (std.mem.eql(u8, text, "error")) return .err;
    if (std.mem.eql(u8, text, "warn")) return .warn;
    if (std.mem.eql(u8, text, "debug")) return .debug;
    return .info;
}

/// `std_options.logFn`: `dkde-console[tty1] [   12.345] info(drm): message`.
/// The time is seconds since boot, as in dmesg, so lines can be lined up with
/// the kernel's.
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime fmt: []const u8,
    args: anytype,
) void {
    if (@backingInt(level) > @backingInt(log_level)) return;
    var buf: [1024]u8 = undefined;
    var ts: Timespec = undefined;
    _ = clock_gettime(7, &ts); // CLOCK_BOOTTIME
    var w: std.Io.Writer = .fixed(&buf);
    w.print("dkde-console", .{}) catch {};
    if (log_vt != 0) w.print("[tty{d}]", .{log_vt}) catch {};
    w.print(" [{d:>6}.{d:0>3}] {s}", .{ @as(u64, @intCast(ts.sec)), @as(u64, @intCast(@divTrunc(ts.nsec, 1_000_000))), @tagName(level) }) catch {};
    if (scope != .default) w.print("({s})", .{@tagName(scope)}) catch {};
    w.print(": " ++ fmt ++ "\n", args) catch {};
    writeAllFd(2, w.buffered()) catch {};
}
