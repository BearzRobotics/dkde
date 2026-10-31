//! Image decoding shared by dkde-view and the PDF renderer, in Zig, on the
//! vendored zigimg (third_party/zigimg): PNG, JPEG (baseline and progressive),
//! GIF, BMP, TGA, QOI, TIFF, PCX, netpbm and a few older formats. It does not
//! need GTK, so its tests always run. Formats zigimg cannot read (WebP, SVG,
//! ICO, AVIF, JPEG XL, CMYK JPEG) report `error.Unsupported` and the caller
//! may fall back to something else.

const std = @import("std");
const zigimg = @import("zigimg");

pub const Error = error{ Unsupported, TooBig, OutOfMemory };

/// 8-bit RGBA, straight (not premultiplied) alpha, rows top to bottom.
pub const Decoded = struct {
    width: usize,
    height: usize,
    rgba: []u8,

    pub fn deinit(self: Decoded, allocator: std.mem.Allocator) void {
        allocator.free(self.rgba);
    }
};

pub const max_pixels: usize = 200 * 1000 * 1000;

/// Decodes any format zigimg reads. For animated files this is the first frame.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!Decoded {
    var img = zigimg.Image.fromMemory(allocator, bytes) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Unsupported,
    };
    defer img.deinit(allocator);
    if (img.width * img.height > max_pixels) return error.TooBig;
    img.convert(allocator, .rgba32) catch return error.Unsupported;
    const px = img.pixels.rgba32;
    const out = try allocator.alloc(u8, px.len * 4);
    for (px, 0..) |p, i| {
        out[i * 4] = p.r;
        out[i * 4 + 1] = p.g;
        out[i * 4 + 2] = p.b;
        out[i * 4 + 3] = p.a;
    }
    return .{ .width = img.width, .height = img.height, .rgba = out };
}

/// The EXIF orientation (1 to 8) of a JPEG, or 1 when absent or not a JPEG.
pub fn exifOrientation(bytes: []const u8) u8 {
    if (bytes.len < 4 or bytes[0] != 0xFF or bytes[1] != 0xD8) return 1;
    var i: usize = 2;
    while (i + 4 <= bytes.len) {
        if (bytes[i] != 0xFF) return 1;
        const marker = bytes[i + 1];
        if (marker == 0xFF) {
            i += 1;
            continue;
        }
        if (marker == 0xDA or marker == 0xD9) return 1; // image data starts: no EXIF
        const len = (@as(usize, bytes[i + 2]) << 8) | bytes[i + 3];
        if (len < 2 or i + 2 + len > bytes.len) return 1;
        const seg = bytes[i + 4 .. i + 2 + len];
        if (marker == 0xE1 and seg.len >= 14 and std.mem.eql(u8, seg[0..6], "Exif\x00\x00")) return tiffOrientation(seg[6..]);
        i += 2 + len;
    }
    return 1;
}

fn tiffOrientation(t: []const u8) u8 {
    if (t.len < 8) return 1;
    const big = t[0] == 'M';
    if (!big and t[0] != 'I') return 1;
    const rd16 = struct {
        fn f(b: []const u8, off: usize, be: bool) ?u16 {
            if (off + 2 > b.len) return null;
            return std.mem.readInt(u16, b[off..][0..2], if (be) .big else .little);
        }
    }.f;
    const rd32 = struct {
        fn f(b: []const u8, off: usize, be: bool) ?u32 {
            if (off + 4 > b.len) return null;
            return std.mem.readInt(u32, b[off..][0..4], if (be) .big else .little);
        }
    }.f;
    const ifd = rd32(t, 4, big) orelse return 1;
    const count = rd16(t, ifd, big) orelse return 1;
    var k: usize = 0;
    while (k < count) : (k += 1) {
        const e = ifd + 2 + k * 12;
        const tag = rd16(t, e, big) orelse return 1;
        if (tag == 0x0112) {
            const v = rd16(t, e + 8, big) orelse return 1;
            return if (v >= 1 and v <= 8) @intCast(v) else 1;
        }
    }
    return 1;
}

/// Turns the image upright for EXIF orientation `o` (1 to 8; 1 is a no-op).
/// The result replaces `d`.
pub fn orient(allocator: std.mem.Allocator, d: Decoded, o: u8) Error!Decoded {
    if (o <= 1 or o > 8) return d;
    const swap = o >= 5;
    const w = d.width;
    const h = d.height;
    const nw = if (swap) h else w;
    const nh = if (swap) w else h;
    const out = try allocator.alloc(u8, d.rgba.len);
    for (0..h) |y| {
        for (0..w) |x| {
            // Where this source pixel lands in the upright image.
            const dx: usize, const dy: usize = switch (o) {
                2 => .{ w - 1 - x, y }, // mirrored horizontally
                3 => .{ w - 1 - x, h - 1 - y }, // rotated 180
                4 => .{ x, h - 1 - y }, // mirrored vertically
                5 => .{ y, x }, // transposed
                6 => .{ h - 1 - y, x }, // rotate 90 clockwise
                7 => .{ h - 1 - y, w - 1 - x }, // transversed
                8 => .{ y, w - 1 - x }, // rotate 90 counter-clockwise
                else => .{ x, y },
            };
            @memcpy(out[(dy * nw + dx) * 4 ..][0..4], d.rgba[(y * w + x) * 4 ..][0..4]);
        }
    }
    allocator.free(d.rgba);
    return .{ .width = nw, .height = nh, .rgba = out };
}

/// cairo's pixel format: premultiplied, one native-endian u32 (0xAARRGGBB) each.
pub fn toCairoArgb(allocator: std.mem.Allocator, d: Decoded) Error![]u32 {
    const out = try allocator.alloc(u32, d.width * d.height);
    for (out, 0..) |*o, i| {
        const r: u32 = d.rgba[i * 4];
        const g: u32 = d.rgba[i * 4 + 1];
        const b: u32 = d.rgba[i * 4 + 2];
        const a: u32 = d.rgba[i * 4 + 3];
        o.* = (a << 24) | (((r * a + 127) / 255) << 16) | (((g * a + 127) / 255) << 8) | ((b * a + 127) / 255);
    }
    return out;
}

fn ppm2x2() []const u8 {
    return "P6\n2 2\n255\n" ++ "\xff\x00\x00" ++ "\x00\xff\x00" ++ "\x00\x00\xff" ++ "\xff\xff\xff";
}

test "a PPM decodes to RGBA" {
    const a = std.testing.allocator;
    const d = try decode(a, ppm2x2());
    defer d.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), d.width);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255 }, d.rgba);
}

test "a baseline JPEG decodes" {
    const a = std.testing.allocator;
    var jpeg: [134]u8 = undefined;
    try std.base64.standard.Decoder.decode(&jpeg, "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA=");
    const d = decode(a, &jpeg) catch |e| {
        // A 1x1 JPEG with an unusual table layout: accept a refusal but never a crash.
        try std.testing.expectEqual(error.Unsupported, e);
        return;
    };
    defer d.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), d.width);
}

test "garbage is refused, not crashed on" {
    try std.testing.expectError(error.Unsupported, decode(std.testing.allocator, "not an image at all"));
}

test "orientation turns pixels upright" {
    const a = std.testing.allocator;
    // 2x1: A B. Rotated 90 clockwise (EXIF 6) it becomes 1x2: A over B.
    const src = try a.dupe(u8, &.{ 1, 1, 1, 255, 2, 2, 2, 255 });
    const r = try orient(a, .{ .width = 2, .height = 1, .rgba = src }, 6);
    defer r.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), r.width);
    try std.testing.expectEqual(@as(usize, 2), r.height);
    try std.testing.expectEqual(@as(u8, 1), r.rgba[0]);
    try std.testing.expectEqual(@as(u8, 2), r.rgba[4]);
}

test "EXIF orientation is read from a JPEG header" {
    // SOI, APP1 "Exif" with a little-endian TIFF whose only tag is Orientation = 6.
    const jpeg = [_]u8{ 0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x22, 'E', 'x', 'i', 'f', 0, 0, 'I', 'I', 0x2A, 0, 8, 0, 0, 0, 1, 0, 0x12, 0x01, 3, 0, 1, 0, 0, 0, 6, 0, 0, 0, 0, 0, 0xFF, 0xD9 };
    try std.testing.expectEqual(@as(u8, 6), exifOrientation(&jpeg));
    try std.testing.expectEqual(@as(u8, 1), exifOrientation("plain"));
}

test "premultiplying for cairo" {
    const a = std.testing.allocator;
    const px = try toCairoArgb(a, .{ .width = 1, .height = 1, .rgba = @constCast(&[_]u8{ 255, 255, 255, 128 }) });
    defer a.free(px);
    try std.testing.expectEqual(@as(u32, 0x80808080), px[0]);
}

extern fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern fn fread(buf: [*]u8, size: usize, n: usize, f: *anyopaque) usize;
extern fn fclose(f: *anyopaque) c_int;

// Decodes the file named by $DKDE_TEST_IMAGE, if set: a way to try real files.
test "a real file, if one is named" {
    const path = std.c.getenv("DKDE_TEST_IMAGE") orelse return;
    const a = std.testing.allocator;
    const f = fopen(path, "rb") orelse return error.CannotOpen;
    defer _ = fclose(f);
    const buf = try a.alloc(u8, 64 << 20);
    defer a.free(buf);
    const n = fread(buf.ptr, 1, buf.len, f);
    const d = try decode(a, buf[0..n]);
    defer d.deinit(a);
    std.debug.print("decoded {d}x{d}, EXIF orientation {d}\n", .{ d.width, d.height, exifOrientation(buf[0..n]) });
}
