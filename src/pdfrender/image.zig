//! Turning PDF image samples into pixels cairo can paint (premultiplied
//! ARGB32, native-endian). Pure: it gets bytes and a description and returns
//! bytes, so it is unit tested without a document.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Base = enum { gray, rgb, cmyk };

pub const Cs = union(enum) {
    gray,
    rgb,
    cmyk,
    /// Palette entries are `base` samples, one per index up to `hival`.
    indexed: struct { base: Base, hival: u32, palette: []const u8 },
    /// A tint transform that was not evaluated: one number treated as ink (0 = white).
    ink,
    /// Anything else, by component count; drawn as gray from the first component.
    other: u8,

    pub fn components(self: Cs) usize {
        return switch (self) {
            .gray, .indexed, .ink => 1,
            .rgb => 3,
            .cmyk => 4,
            .other => |n| @max(1, n),
        };
    }
};

pub const Spec = struct {
    width: u32,
    height: u32,
    bpc: u8,
    cs: Cs,
    /// `/Decode`, if present: min,max per component.
    decode: ?[]const f64 = null,
    /// An image mask: one bit per pixel, painted in the fill colour.
    mask: bool = false,
};

pub const max_pixels: u64 = 120 * 1000 * 1000;

pub const Error = error{ TooBig, BadImage, OutOfMemory };

fn pack(a: u8, r: u8, g: u8, b: u8) u32 {
    // Premultiply.
    const pr = (@as(u32, r) * a + 127) / 255;
    const pg = (@as(u32, g) * a + 127) / 255;
    const pb = (@as(u32, b) * a + 127) / 255;
    return (@as(u32, a) << 24) | (pr << 16) | (pg << 8) | pb;
}

fn unit(v: f64) u8 {
    return @intFromFloat(std.math.clamp(v, 0, 1) * 255.0 + 0.5);
}

fn cmyk(c: f64, m: f64, y: f64, k: f64) [3]u8 {
    return .{ unit((1 - c) * (1 - k)), unit((1 - m) * (1 - k)), unit((1 - y) * (1 - k)) };
}

/// The value of sample `index` in a row (bits packed MSB first), as an integer.
fn sampleAt(row: []const u8, bpc: u8, index: usize) u32 {
    switch (bpc) {
        8 => return if (index < row.len) row[index] else 0,
        16 => return if (index * 2 < row.len) row[index * 2] else 0, // the high byte is enough for 8-bit output
        else => {
            const bit = index * bpc;
            const byte = bit / 8;
            if (byte >= row.len) return 0;
            const shift: u3 = @intCast(8 - bpc - (bit % 8));
            const mask: u32 = (@as(u32, 1) << @intCast(bpc)) - 1;
            return (@as(u32, row[byte]) >> shift) & mask;
        },
    }
}

/// `alpha` is an optional 8-bit gray soft mask the size of the image (width*height bytes).
/// Returns width*height premultiplied ARGB32 pixels.
pub fn toArgb(a: Allocator, spec: Spec, data: []const u8, fill: [3]u8, alpha: ?[]const u8) Error![]u32 {
    const w: usize = spec.width;
    const h: usize = spec.height;
    if (w == 0 or h == 0) return error.BadImage;
    if (@as(u64, w) * h > max_pixels) return error.TooBig;
    const bpc: u8 = if (spec.mask) 1 else spec.bpc;
    if (bpc != 1 and bpc != 2 and bpc != 4 and bpc != 8 and bpc != 16) return error.BadImage;
    const out = try a.alloc(u32, w * h);
    errdefer a.free(out);

    const ncomp: usize = if (spec.mask) 1 else spec.cs.components();
    const row_bytes = (w * ncomp * bpc + 7) / 8;
    const max_val: f64 = @floatFromInt((@as(u32, 1) << @intCast(@min(bpc, 8))) - 1);

    for (0..h) |y| {
        const start = y * row_bytes;
        const row: []const u8 = if (start >= data.len) &.{} else data[start..@min(data.len, start + row_bytes)];
        for (0..w) |x| {
            const al: u8 = if (alpha) |am| (if (y * w + x < am.len) am[y * w + x] else 255) else 255;
            if (spec.mask) {
                // Default decode [0 1]: sample 0 paints.
                var s = sampleAt(row, 1, x);
                if (spec.decode) |d| if (d.len >= 2 and d[0] > d[1]) {
                    s = 1 - s;
                };
                const opaque_ = s == 0;
                out[y * w + x] = if (opaque_) pack(al, fill[0], fill[1], fill[2]) else 0;
                continue;
            }
            // Components scaled to 0..1 through /Decode.
            var comp: [8]f64 = undefined;
            const n = @min(ncomp, comp.len);
            for (0..n) |k| {
                const raw: f64 = @floatFromInt(sampleAt(row, bpc, x * ncomp + k));
                var lo: f64 = 0;
                var hi: f64 = 1;
                if (spec.cs == .indexed) hi = max_val;
                if (spec.decode) |d| if (d.len >= 2 * k + 2) {
                    lo = d[2 * k];
                    hi = d[2 * k + 1];
                };
                comp[k] = lo + raw / max_val * (hi - lo);
            }
            var rgb: [3]u8 = undefined;
            switch (spec.cs) {
                .gray, .other => rgb = .{ unit(comp[0]), unit(comp[0]), unit(comp[0]) },
                .ink => {
                    const g = unit(1 - comp[0]);
                    rgb = .{ g, g, g };
                },
                .rgb => rgb = .{ unit(comp[0]), unit(comp[1]), unit(comp[2]) },
                .cmyk => rgb = cmyk(comp[0], comp[1], comp[2], comp[3]),
                .indexed => |ix| {
                    const idx: usize = @intFromFloat(std.math.clamp(@round(comp[0]), 0, @as(f64, @floatFromInt(ix.hival))));
                    const per: usize = switch (ix.base) {
                        .gray => 1,
                        .rgb => 3,
                        .cmyk => 4,
                    };
                    const p = idx * per;
                    if (p + per > ix.palette.len) {
                        rgb = .{ 0, 0, 0 };
                    } else {
                        const e = ix.palette[p .. p + per];
                        rgb = switch (ix.base) {
                            .gray => .{ e[0], e[0], e[0] },
                            .rgb => .{ e[0], e[1], e[2] },
                            .cmyk => cmyk(@as(f64, @floatFromInt(e[0])) / 255, @as(f64, @floatFromInt(e[1])) / 255, @as(f64, @floatFromInt(e[2])) / 255, @as(f64, @floatFromInt(e[3])) / 255),
                        };
                    }
                },
            }
            out[y * w + x] = pack(al, rgb[0], rgb[1], rgb[2]);
        }
    }
    return out;
}

/// Packs straight-alpha 8-bit RGBA, with an optional soft mask multiplied into the alpha.
pub fn fromRgba8(a: Allocator, w: usize, h: usize, rgba: []const u8, alpha: ?[]const u8) Error![]u32 {
    if (w * h * 4 > rgba.len) return error.BadImage;
    if (@as(u64, w) * h > max_pixels) return error.TooBig;
    const out = try a.alloc(u32, w * h);
    for (0..w * h) |i| {
        var al: u32 = rgba[i * 4 + 3];
        if (alpha) |am| if (i < am.len) {
            al = (al * am[i] + 127) / 255;
        };
        out[i] = pack(@intCast(al), rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2]);
    }
    return out;
}

/// Packs 8-bit RGB (as a JPEG decoder returns it) the same way.
pub fn fromRgb8(a: Allocator, w: usize, h: usize, rgb: []const u8, alpha: ?[]const u8) Error![]u32 {
    if (w * h * 3 > rgb.len) return error.BadImage;
    if (@as(u64, w) * h > max_pixels) return error.TooBig;
    const out = try a.alloc(u32, w * h);
    for (0..w * h) |i| {
        const al: u8 = if (alpha) |am| (if (i < am.len) am[i] else 255) else 255;
        out[i] = pack(al, rgb[i * 3], rgb[i * 3 + 1], rgb[i * 3 + 2]);
    }
    return out;
}

test "8-bit RGB and gray" {
    const a = std.testing.allocator;
    const px = try toArgb(a, .{ .width = 2, .height = 1, .bpc = 8, .cs = .rgb }, &.{ 255, 0, 0, 0, 0, 255 }, .{ 0, 0, 0 }, null);
    defer a.free(px);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), px[0]);
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), px[1]);
    const g = try toArgb(a, .{ .width = 2, .height = 1, .bpc = 8, .cs = .gray }, &.{ 0, 255 }, .{ 0, 0, 0 }, null);
    defer a.free(g);
    try std.testing.expectEqual(@as(u32, 0xFF000000), g[0]);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), g[1]);
}

test "1-bit gray with rows padded to bytes, and inverted decode" {
    const a = std.testing.allocator;
    // 3 pixels wide, 2 rows: row bytes are 1 each. Row 0 = 101, row 1 = 010.
    const data = [_]u8{ 0b10100000, 0b01000000 };
    const px = try toArgb(a, .{ .width = 3, .height = 2, .bpc = 1, .cs = .gray }, &data, .{ 0, 0, 0 }, null);
    defer a.free(px);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), px[0]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), px[1]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), px[3]);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), px[4]);
    const inv = try toArgb(a, .{ .width = 3, .height = 2, .bpc = 1, .cs = .gray, .decode = &.{ 1, 0 } }, &data, .{ 0, 0, 0 }, null);
    defer a.free(inv);
    try std.testing.expectEqual(@as(u32, 0xFF000000), inv[0]);
}

test "indexed colour at 4 bits" {
    const a = std.testing.allocator;
    const palette = [_]u8{ 255, 0, 0, 0, 255, 0, 0, 0, 255 };
    const px = try toArgb(a, .{ .width = 3, .height = 1, .bpc = 4, .cs = .{ .indexed = .{ .base = .rgb, .hival = 2, .palette = &palette } } }, &.{ 0x01, 0x20 }, .{ 0, 0, 0 }, null);
    defer a.free(px);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), px[0]);
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), px[1]);
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), px[2]);
}

test "image masks paint the fill colour where the bit is 0, and soft masks set alpha" {
    const a = std.testing.allocator;
    const px = try toArgb(a, .{ .width = 2, .height = 1, .bpc = 1, .cs = .gray, .mask = true }, &.{0b01000000}, .{ 200, 0, 0 }, null);
    defer a.free(px);
    try std.testing.expectEqual(@as(u32, 0xFFC80000), px[0]);
    try std.testing.expectEqual(@as(u32, 0), px[1]);
    const half = try toArgb(a, .{ .width = 1, .height = 1, .bpc = 8, .cs = .rgb }, &.{ 255, 255, 255 }, .{ 0, 0, 0 }, &.{128});
    defer a.free(half);
    try std.testing.expectEqual(@as(u32, 0x80808080), half[0]);
}

test "CMYK and oversize" {
    const a = std.testing.allocator;
    const px = try toArgb(a, .{ .width = 1, .height = 1, .bpc = 8, .cs = .cmyk }, &.{ 0, 0, 0, 255 }, .{ 0, 0, 0 }, null);
    defer a.free(px);
    try std.testing.expectEqual(@as(u32, 0xFF000000), px[0]);
    try std.testing.expectError(error.TooBig, toArgb(a, .{ .width = 100000, .height = 100000, .bpc = 8, .cs = .gray }, &.{}, .{ 0, 0, 0 }, null));
}
