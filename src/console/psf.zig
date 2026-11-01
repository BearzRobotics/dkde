//! PSF bitmap console fonts (SPEC.md 5.11, *Fonts*). Reads PSF2, the format
//! of the kernel's own fonts, and PSF1, which the older kbd fonts (and the
//! built-in Terminus 16) use. A font is a header, a glyph bitmap array and an
//! optional Unicode table; drawing a glyph is copying bits.
//!
//! The font borrows the bytes it is given: they are either `@embedFile` data or
//! a buffer the caller keeps alive.

const std = @import("std");

pub const Font = struct {
    width: u32,
    height: u32,
    glyph_count: u32,
    /// Bytes per bitmap row: ceil(width / 8).
    row_bytes: u32,
    /// Bytes per glyph: `row_bytes * height`.
    glyph_bytes: u32,
    bitmap: []const u8,
    /// The Unicode table bytes, or empty when the font has none (then glyph
    /// index == code point for the first `glyph_count` code points).
    unicode: []const u8,
    is_psf2: bool,
    /// Code point -> glyph index, built once from the table.
    map: std.AutoHashMapUnmanaged(u21, u32) = .empty,

    pub const Error = error{ NotPsf, Truncated, BadGeometry, OutOfMemory };

    pub fn parse(allocator: std.mem.Allocator, data: []const u8) Error!Font {
        var f: Font = undefined;
        if (data.len >= 4 and data[0] == 0x36 and data[1] == 0x04) {
            const mode = data[2];
            f = .{
                .width = 8,
                .height = data[3],
                .glyph_count = if (mode & 1 != 0) 512 else 256,
                .row_bytes = 1,
                .glyph_bytes = data[3],
                .bitmap = undefined,
                .unicode = &.{},
                .is_psf2 = false,
            };
            const need = 4 + @as(usize, f.glyph_count) * f.glyph_bytes;
            if (f.height == 0) return error.BadGeometry;
            if (data.len < need) return error.Truncated;
            f.bitmap = data[4..need];
            if (mode & 6 != 0) f.unicode = data[need..];
        } else if (data.len >= 32 and std.mem.readInt(u32, data[0..4], .little) == 0x864ab572) {
            const rd = struct {
                fn u(d: []const u8, at: usize) u32 {
                    return std.mem.readInt(u32, d[at..][0..4], .little);
                }
            }.u;
            const header = rd(data, 8);
            const flags = rd(data, 12);
            const length = rd(data, 16);
            const charsize = rd(data, 20);
            const height = rd(data, 24);
            const width = rd(data, 28);
            if (width == 0 or height == 0 or width > 128 or height > 128 or length == 0) return error.BadGeometry;
            const row_bytes = (width + 7) / 8;
            if (charsize != row_bytes * height) return error.BadGeometry;
            const total = @as(u64, header) + @as(u64, length) * charsize;
            if (header < 32 or total > data.len) return error.Truncated;
            f = .{
                .width = width,
                .height = height,
                .glyph_count = length,
                .row_bytes = row_bytes,
                .glyph_bytes = charsize,
                .bitmap = data[header..@intCast(total)],
                .unicode = if (flags & 1 != 0) data[@intCast(total)..] else &.{},
                .is_psf2 = true,
            };
        } else return error.NotPsf;

        try f.buildMap(allocator);
        return f;
    }

    pub fn deinit(self: *Font, allocator: std.mem.Allocator) void {
        self.map.deinit(allocator);
    }

    fn buildMap(self: *Font, allocator: std.mem.Allocator) Error!void {
        errdefer self.map.deinit(allocator);
        if (self.unicode.len == 0) return; // identity mapping, see `glyphIndex`
        var index: u32 = 0;
        var i: usize = 0;
        const t = self.unicode;
        // PSF1 entries are UCS-2 little endian ending in 0xFFFF, with 0xFFFE
        // starting a sequence. PSF2 entries are UTF-8 ending in 0xFF, with
        // 0xFE starting a sequence. Sequences (combining characters) are
        // skipped: this reader maps single code points only.
        while (index < self.glyph_count and i < t.len) {
            var in_seq = false;
            if (self.is_psf2) {
                while (i < t.len and t[i] != 0xFF) {
                    if (t[i] == 0xFE) {
                        in_seq = true;
                        i += 1;
                        continue;
                    }
                    const n = std.unicode.utf8ByteSequenceLength(t[i]) catch {
                        i += 1;
                        continue;
                    };
                    if (i + n > t.len) {
                        i = t.len;
                        break;
                    }
                    const cp = std.unicode.utf8Decode(t[i..][0..n]) catch {
                        i += n;
                        continue;
                    };
                    i += n;
                    if (!in_seq) try self.put(allocator, cp, index);
                }
                i += 1;
            } else {
                while (i + 1 < t.len) {
                    const v = std.mem.readInt(u16, t[i..][0..2], .little);
                    i += 2;
                    if (v == 0xFFFF) break;
                    if (v == 0xFFFE) {
                        in_seq = true;
                        continue;
                    }
                    if (!in_seq) try self.put(allocator, v, index);
                }
            }
            index += 1;
        }
    }

    fn put(self: *Font, allocator: std.mem.Allocator, cp: u21, index: u32) Error!void {
        // The first glyph listed for a code point wins.
        const r = self.map.getOrPut(allocator, cp) catch return error.OutOfMemory;
        if (!r.found_existing) r.value_ptr.* = index;
    }

    /// Glyph index for a code point, or null when the font has no glyph.
    pub fn glyphIndex(self: *const Font, cp: u21) ?u32 {
        if (self.unicode.len == 0) return if (cp < self.glyph_count) cp else null;
        return self.map.get(cp);
    }

    /// The bitmap of glyph `index`: `height` rows of `row_bytes`, top row first,
    /// most significant bit leftmost.
    pub fn glyph(self: *const Font, index: u32) []const u8 {
        const start = @as(usize, index) * self.glyph_bytes;
        return self.bitmap[start..][0..self.glyph_bytes];
    }

    pub fn lookup(self: *const Font, cp: u21) ?[]const u8 {
        return self.glyph(self.glyphIndex(cp) orelse return null);
    }

    /// Whether the pixel at (x, y) of a glyph bitmap is set.
    pub inline fn pixel(self: *const Font, bitmap: []const u8, x: u32, y: u32) bool {
        const byte = bitmap[y * self.row_bytes + x / 8];
        return byte & (@as(u8, 0x80) >> @intCast(x % 8)) != 0;
    }
};

/// The fonts built into the program (SPEC.md 5.11): Terminus at 16, 24 and
/// 32 pixels high.
pub const builtin_data = [_]struct { name: []const u8, data: []const u8 }{
    .{ .name = "terminus-16", .data = @embedFile("terminus16") },
    .{ .name = "terminus-24", .data = @embedFile("terminus24") },
    .{ .name = "terminus-32", .data = @embedFile("terminus32") },
};

const testing = std.testing;

test "built-in fonts parse and have ASCII, accents and a box fallback source" {
    for (builtin_data) |b| {
        var f = try Font.parse(testing.allocator, b.data);
        defer f.deinit(testing.allocator);
        try testing.expect(f.glyphIndex('A') != null);
        try testing.expect(f.glyphIndex(0xE9) != null); // é
        try testing.expect(f.glyphIndex(0x2588) != null); // full block
        try testing.expect(f.lookup('A').?.len == f.glyph_bytes);
    }
}

test "heights are 16, 24 and 32" {
    const want = [_]u32{ 16, 24, 32 };
    for (builtin_data, want) |b, h| {
        var f = try Font.parse(testing.allocator, b.data);
        defer f.deinit(testing.allocator);
        try testing.expectEqual(h, f.height);
    }
}

test "psf1 without a table maps code points to glyph numbers" {
    var data: [4 + 256 * 8]u8 = @splat(0);
    data[0] = 0x36;
    data[1] = 0x04;
    data[2] = 0;
    data[3] = 8;
    data[4 + 'A' * 8] = 0xAA;
    var f = try Font.parse(testing.allocator, &data);
    defer f.deinit(testing.allocator);
    try testing.expectEqual(@as(?u32, 'A'), f.glyphIndex('A'));
    try testing.expect(f.glyphIndex(300) == null);
    try testing.expect(f.pixel(f.lookup('A').?, 0, 0));
    try testing.expect(!f.pixel(f.lookup('A').?, 1, 0));
}

test "garbage is rejected" {
    try testing.expectError(error.NotPsf, Font.parse(testing.allocator, "not a font at all, no"));
    try testing.expectError(error.NotPsf, Font.parse(testing.allocator, ""));
    var short: [10]u8 = .{ 0x36, 0x04, 0, 16, 0, 0, 0, 0, 0, 0 };
    try testing.expectError(error.Truncated, Font.parse(testing.allocator, &short));
}

test "psf2 unicode table and sequences" {
    // 2 glyphs, 8x2. Glyph 0 is U+0041 and U+00C0; glyph 1 is U+0042 followed
    // by a sequence that must be ignored.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const hdr = [_]u32{ 0x864ab572, 0, 32, 1, 2, 2, 2, 8 };
    for (hdr) |v| try buf.appendSlice(testing.allocator, &std.mem.toBytes(std.mem.nativeToLittle(u32, v)));
    try buf.appendSlice(testing.allocator, &.{ 0xF0, 0x0F, 0x0F, 0xF0 });
    try buf.appendSlice(testing.allocator, &.{ 'A', 0xC3, 0x80, 0xFF });
    try buf.appendSlice(testing.allocator, &.{ 'B', 0xFE, 'x', 0xFF });
    var f = try Font.parse(testing.allocator, buf.items);
    defer f.deinit(testing.allocator);
    try testing.expectEqual(@as(?u32, 0), f.glyphIndex('A'));
    try testing.expectEqual(@as(?u32, 0), f.glyphIndex(0xC0));
    try testing.expectEqual(@as(?u32, 1), f.glyphIndex('B'));
    try testing.expect(f.glyphIndex('x') == null);
}
