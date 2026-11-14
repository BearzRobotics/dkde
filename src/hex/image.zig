//! Copying a device, partition or process region into an image file, one
//! chunk per `step` so the caller can run it from an idle handler.
//! The source is only read.

const std = @import("std");
const Allocator = std.mem.Allocator;
const disk = @import("disk.zig");

pub const chunk_bytes: usize = 4 << 20;

pub const Step = enum { more, done, write_failed };

pub const Copier = struct {
    src: disk.Handle,
    /// Added to every offset read (process memory regions start at an address).
    origin: u64,
    dest: disk.Handle,
    buf: []u8,
    pos: u64 = 0,
    total: u64,
    /// Bytes that could not be read; they are written as zeros so offsets stay true.
    unreadable: u64 = 0,

    pub fn init(a: Allocator, src: disk.Handle, origin: u64, dest: disk.Handle) Allocator.Error!Copier {
        return .{ .src = src, .origin = origin, .dest = dest, .buf = try a.alloc(u8, chunk_bytes), .total = src.size };
    }

    /// Closes the destination too.
    pub fn deinit(self: *Copier, a: Allocator) void {
        a.free(self.buf);
        self.dest.flush();
        self.dest.closeHandle();
    }

    pub fn percent(self: *const Copier) u32 {
        if (self.total == 0) return 100;
        return @intCast(@min(100, self.pos * 100 / self.total));
    }

    pub fn step(self: *Copier) Step {
        if (self.pos >= self.total) return .done;
        const want: usize = @intCast(@min(chunk_bytes, self.total - self.pos));
        const chunk = self.buf[0..want];
        const got = self.src.readAt(self.origin + self.pos, chunk) catch 0;
        if (got < want) {
            // A bad region or a short read: keep going so one bad sector does not end the copy.
            @memset(chunk[got..], 0);
            self.unreadable += want - got;
        }
        self.dest.writeAt(self.pos, chunk) catch return .write_failed;
        self.pos += want;
        return if (self.pos >= self.total) .done else .more;
    }
};

fn tmpPath(a: Allocator, name: []const u8) ![:0]u8 {
    const glib = @import("glib2");
    const dir = glib.Dir.makeTmp("dkde-img-XXXXXX", null) orelse return error.NoTmp;
    defer glib.free(dir);
    return std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ std.mem.span(dir), name }, 0);
}

test "an image is a byte-for-byte copy and the source is never the destination" {
    const glib = @import("glib2");
    const a = std.testing.allocator;
    const size = chunk_bytes + 12345;
    const content = try a.alloc(u8, size);
    defer a.free(content);
    for (content, 0..) |*b, i| b.* = @truncate(i *% 31);
    const src_path = try tmpPath(a, "src.img");
    defer a.free(src_path);
    _ = glib.fileSetContents(src_path, content.ptr, @intCast(size), null);
    defer _ = std.c.unlink(src_path);
    var src = try disk.Handle.openPath(src_path, false);
    defer src.closeHandle();

    try std.testing.expectError(error.SameFile, disk.Handle.createFile(src_path, src));
    // Refusing must leave the source intact.
    try std.testing.expectEqual(@as(u64, size), (try disk.Handle.openPath(src_path, false)).size);

    const out_path = try tmpPath(a, "out.img");
    defer a.free(out_path);
    defer _ = std.c.unlink(out_path);
    const dest = try disk.Handle.createFile(out_path, src);
    var c = try Copier.init(a, src, 0, dest);
    while (c.step() == .more) {}
    try std.testing.expectEqual(@as(u32, 100), c.percent());
    try std.testing.expectEqual(@as(u64, 0), c.unreadable);
    c.deinit(a);

    var check = try disk.Handle.openPath(out_path, false);
    defer check.closeHandle();
    try std.testing.expectEqual(@as(u64, size), check.size);
    const copy = try a.alloc(u8, size);
    defer a.free(copy);
    _ = try check.readAt(0, copy);
    try std.testing.expectEqualSlices(u8, content, copy);
}

test "a device node is refused as a destination" {
    const a = std.testing.allocator;
    const src_path = try tmpPath(a, "s.img");
    defer a.free(src_path);
    const glib = @import("glib2");
    _ = glib.fileSetContents(src_path, "x", 1, null);
    defer _ = std.c.unlink(src_path);
    var src = try disk.Handle.openPath(src_path, false);
    defer src.closeHandle();
    try std.testing.expectError(error.NotAFile, disk.Handle.createFile("/dev/null", src));
}
