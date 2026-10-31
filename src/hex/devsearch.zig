//! Searching a whole device (or image, or process region) that is bigger than
//! the window dkde-hex keeps in memory. The scan reads one chunk per `step`,
//! so the caller can run it from an idle handler and keep the window alive.

const std = @import("std");
const Allocator = std.mem.Allocator;
const analyze = @import("analyze.zig");
const disk = @import("disk.zig");

pub const chunk_bytes: u64 = 8 << 20;

pub const Step = union(enum) {
    /// Not finished; look at `progress()`.
    more,
    /// A match starts at this device offset (relative to the handle).
    found: u64,
    /// Every position was tried and none matched.
    none,
};

/// Searches `[0, size)` for a pattern, starting at `from` and wrapping once.
/// Forwards, it tries starts `from..size`, then `0..from`; backwards, starts
/// below `from` going down, then the rest going down from the end.
pub const Scan = struct {
    handle: disk.Handle,
    /// Added to every offset read (process memory regions start at an address).
    origin: u64,
    pattern: analyze.Pattern,
    forward: bool,
    buf: []u8,
    /// The two ranges of match start offsets, in the order they are tried.
    seg: [2][2]u64,
    seg_index: usize = 0,
    /// Forwards: next start to try. Backwards: one past the next start.
    pos: u64,
    done_starts: u64 = 0,
    total_starts: u64,

    /// `pattern` is borrowed and must outlive the scan.
    pub fn init(a: Allocator, handle: disk.Handle, origin: u64, pattern: analyze.Pattern, from: u64, forward: bool) Allocator.Error!Scan {
        const plen: u64 = pattern.bytes.len;
        const size = handle.size;
        const buf = try a.alloc(u8, @intCast(chunk_bytes + plen));
        // Start offsets are 0 .. size-plen; nothing fits when the pattern is longer than the device.
        const n_starts: u64 = if (plen == 0 or plen > size) 0 else size - plen + 1;
        const f = @min(from, n_starts);
        var s: Scan = .{
            .handle = handle,
            .origin = origin,
            .pattern = pattern,
            .forward = forward,
            .buf = buf,
            .seg = if (forward) .{ .{ f, n_starts }, .{ 0, f } } else .{ .{ 0, f }, .{ f, n_starts } },
            .pos = 0,
            .total_starts = n_starts,
        };
        s.enter();
        return s;
    }

    pub fn deinit(self: *Scan, a: Allocator) void {
        a.free(self.buf);
    }

    fn enter(self: *Scan) void {
        const r = self.seg[self.seg_index];
        // The backward order reads each range from its end.
        self.pos = if (self.forward) r[0] else r[1];
    }

    /// 0 to 100.
    pub fn percent(self: *const Scan) u32 {
        if (self.total_starts == 0) return 100;
        return @intCast(@min(100, self.done_starts * 100 / self.total_starts));
    }

    pub fn step(self: *Scan) Step {
        while (self.seg_index < 2) {
            const r = self.seg[self.seg_index];
            const remaining = if (self.forward) r[1] - self.pos else self.pos - r[0];
            if (remaining == 0) {
                self.seg_index += 1;
                if (self.seg_index < 2) self.enter();
                continue;
            }
            const count = @min(remaining, chunk_bytes);
            const lo = if (self.forward) self.pos else self.pos - count;
            const hi = lo + count; // starts lo..hi
            const want: usize = @intCast(count + self.pattern.bytes.len - 1);
            const got = self.handle.readAt(self.origin + lo, self.buf[0..want]) catch 0; // an unreadable chunk matches nothing
            const data = self.buf[0..got];
            if (self.forward) {
                self.pos = hi;
            } else {
                self.pos = lo;
            }
            self.done_starts += count;
            if (self.forward) {
                var i: usize = 0;
                while (i < count) : (i += 1) if (analyze.matchesAt(data, i, self.pattern)) return .{ .found = lo + i };
            } else {
                var i: usize = @intCast(count);
                while (i > 0) {
                    i -= 1;
                    if (analyze.matchesAt(data, i, self.pattern)) return .{ .found = lo + i };
                }
            }
            return .more;
        }
        return .none;
    }
};

fn testHandle(a: Allocator, bytes: []const u8) !struct { path: [:0]u8, h: disk.Handle } {
    const glib = @import("glib2");
    const dir = glib.Dir.makeTmp("dkde-ds-XXXXXX", null) orelse return error.NoTmp;
    defer glib.free(dir);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/s.img", .{std.mem.span(dir)}, 0);
    _ = glib.fileSetContents(path, bytes.ptr, @intCast(bytes.len), null);
    return .{ .path = path, .h = try disk.Handle.openPath(path, false) };
}

fn runScan(s: *Scan) ?u64 {
    while (true) switch (s.step()) {
        .more => {},
        .found => |at| return at,
        .none => return null,
    };
}

test "whole-device search goes both ways, wraps, and finds across chunk edges" {
    const a = std.testing.allocator;
    const size: usize = chunk_bytes * 2 + 100;
    const img = try a.alloc(u8, size);
    defer a.free(img);
    @memset(img, 0);
    @memcpy(img[10..13], "abc");
    // Straddles the first chunk boundary.
    @memcpy(img[chunk_bytes - 1 ..][0..3], "abc");
    @memcpy(img[size - 3 ..], "abc");
    var t = try testHandle(a, img);
    defer {
        t.h.closeHandle();
        _ = std.c.unlink(t.path);
        a.free(t.path);
    }
    var bytes = "abc".*;
    var care = [_]bool{ true, true, true };
    const p: analyze.Pattern = .{ .bytes = &bytes, .care = &care };

    var s = try Scan.init(a, t.h, 0, p, 11, true);
    try std.testing.expectEqual(@as(?u64, chunk_bytes - 1), runScan(&s));
    s.deinit(a);
    s = try Scan.init(a, t.h, 0, p, chunk_bytes, true);
    try std.testing.expectEqual(@as(?u64, size - 3), runScan(&s));
    s.deinit(a);
    // Wraps to the start.
    s = try Scan.init(a, t.h, 0, p, size - 2, true);
    try std.testing.expectEqual(@as(?u64, 10), runScan(&s));
    s.deinit(a);
    // Backwards.
    s = try Scan.init(a, t.h, 0, p, size - 3, false);
    try std.testing.expectEqual(@as(?u64, chunk_bytes - 1), runScan(&s));
    s.deinit(a);
    s = try Scan.init(a, t.h, 0, p, 10, false);
    try std.testing.expectEqual(@as(?u64, size - 3), runScan(&s));
    s.deinit(a);
}

test "whole-device search with no match, and a pattern longer than the device" {
    const a = std.testing.allocator;
    var t = try testHandle(a, "hello world");
    defer {
        t.h.closeHandle();
        _ = std.c.unlink(t.path);
        a.free(t.path);
    }
    var bytes = "zzz".*;
    var care = [_]bool{ true, true, true };
    var s = try Scan.init(a, t.h, 0, .{ .bytes = &bytes, .care = &care }, 0, true);
    defer s.deinit(a);
    try std.testing.expectEqual(@as(?u64, null), runScan(&s));
    var long: [40]u8 = @splat('x');
    var care2: [40]bool = @splat(true);
    var s2 = try Scan.init(a, t.h, 0, .{ .bytes = &long, .care = &care2 }, 0, false);
    defer s2.deinit(a);
    try std.testing.expectEqual(@as(?u64, null), runScan(&s2));
}
