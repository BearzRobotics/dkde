//! TrueType faces for the console (SPEC.md 5.11, *Fonts*, M9). The outlines are
//! read by the shared `truetype` module; this file scales them to a cell and
//! fills them with anti-aliasing into 8-bit coverage bitmaps, one per glyph,
//! made the first time a character is drawn and kept in a small cache.
//!
//! The fill is the exact-area "accumulation buffer" method: every outline
//! edge adds its signed coverage to the pixels it crosses, and a running sum
//! along each row turns that into the coverage of each pixel. No hinting.

const std = @import("std");
const truetype = @import("truetype");

pub const Error = error{ BadFont, Unsupported, OutOfMemory };

/// Most glyph bitmaps one face keeps. A full cache is emptied; a screen rarely
/// shows more than a few hundred different characters.
const max_cached = 2048;

pub const Face = struct {
    allocator: std.mem.Allocator,
    font: truetype.Font,
    /// Pixels per font unit.
    scale: f32,
    cell_w: u32,
    cell_h: u32,
    /// Distance from the top of the cell to the baseline.
    baseline: u32,
    cache: std.AutoHashMapUnmanaged(Key, Entry) = .empty,
    /// The font file bytes when the face owns them.
    owned: ?[]u8 = null,

    pub const Key = struct { cp: u21, wide: bool, bold: bool, cell_w: u16 };
    /// What was found for a key, kept so a missing glyph is looked up once.
    const Entry = union(enum) { missing, blank, bitmap: []u8 };

    /// A face whose cell is `cell_h` pixels tall. `data` must outlive the face.
    pub fn init(allocator: std.mem.Allocator, data: []const u8, cell_h: u32) Error!Face {
        const font = truetype.Font.parse(data) catch |e| return switch (e) {
            error.Unsupported => error.Unsupported,
            else => error.BadFont,
        };
        var asc: f32 = @floatFromInt(font.ascender);
        var desc: f32 = @floatFromInt(font.descender);
        // A font without usable `hhea` metrics: assume the usual 80/20 split.
        if (asc - desc < 1) {
            asc = @as(f32, @floatFromInt(font.units_per_em)) * 0.8;
            desc = -@as(f32, @floatFromInt(font.units_per_em)) * 0.2;
        }
        var f: Face = .{ .allocator = allocator, .font = font, .scale = 1, .cell_w = 0, .cell_h = 0, .baseline = 0 };
        f.setSize(cell_h, asc, desc);
        return f;
    }

    fn setSize(self: *Face, cell_h: u32, asc: f32, desc: f32) void {
        const h = std.math.clamp(cell_h, 4, 512);
        self.scale = @as(f32, @floatFromInt(h)) / (asc - desc);
        const m = self.font.glyphForUnicode('M') orelse self.font.glyphForUnicode('0') orelse 0;
        const w: f32 = @as(f32, @floatFromInt(self.font.advance(m))) * self.scale;
        self.cell_w = std.math.clamp(@as(u32, @intFromFloat(@round(w))), 2, 1024);
        self.cell_h = h;
        self.baseline = @min(h, @as(u32, @intFromFloat(@round(asc * self.scale))));
    }

    /// The same face at another cell height, without reading the file again.
    pub fn resize(self: *Face, cell_h: u32) void {
        self.clear();
        var asc: f32 = @floatFromInt(self.font.ascender);
        var desc: f32 = @floatFromInt(self.font.descender);
        if (asc - desc < 1) {
            asc = @as(f32, @floatFromInt(self.font.units_per_em)) * 0.8;
            desc = -@as(f32, @floatFromInt(self.font.units_per_em)) * 0.2;
        }
        self.setSize(cell_h, asc, desc);
    }

    pub fn deinit(self: *Face) void {
        self.clear();
        self.cache.deinit(self.allocator);
        if (self.owned) |o| self.allocator.free(o);
    }

    fn clear(self: *Face) void {
        var it = self.cache.valueIterator();
        while (it.next()) |v| switch (v.*) {
            .bitmap => |b| self.allocator.free(b),
            else => {},
        };
        self.cache.clearRetainingCapacity();
    }

    pub fn has(self: *const Face, cp: u21) bool {
        return self.font.glyphForUnicode(cp) != null;
    }

    /// Coverage (0-255) of `cp`, `cells * grid_w` by `cell_h` pixels, row by
    /// row, or null when the face has no glyph for it. `grid_w` is the width of
    /// the console's cell, which is the first face's, so a fallback face of
    /// another width is centred in it and clipped.
    pub fn coverage(self: *Face, cp: u21, wide: bool, bold: bool, grid_w: u32) ?[]const u8 {
        const key: Key = .{ .cp = cp, .wide = wide, .bold = bold, .cell_w = @intCast(grid_w) };
        if (self.cache.get(key)) |hit| return switch (hit) {
            .bitmap => |b| b,
            else => null,
        };
        if (self.cache.count() >= max_cached) self.clear();
        const entry: Entry = if (self.font.glyphForUnicode(cp)) |gid|
            (if (self.render(gid, if (wide) grid_w * 2 else grid_w, bold) catch null) |b| Entry{ .bitmap = b } else .blank)
        else
            .missing;
        self.cache.put(self.allocator, key, entry) catch {
            if (entry == .bitmap) self.allocator.free(entry.bitmap);
            return null;
        };
        return if (entry == .bitmap) entry.bitmap else null;
    }

    fn render(self: *Face, gid: u16, w: u32, bold: bool) !?[]u8 {
        const a = self.allocator;
        const h = self.cell_h;
        // The glyph is centred when the cell is wider than its advance by
        // more than a pixel (a fallback face, a double-width character).
        const adv = @as(f32, @floatFromInt(self.font.advance(gid))) * self.scale;
        const wf: f32 = @floatFromInt(w);
        const x_off: f32 = if (@abs(wf - adv) > 1.0) @floor((wf - adv) / 2) else 0;

        const stride = w + 2;
        const acc = try a.alloc(f32, stride * h);
        defer a.free(acc);
        @memset(acc, 0);
        var sink: Sink = .{
            .acc = acc,
            .stride = stride,
            .w = @floatFromInt(w),
            .h = @floatFromInt(h),
            .scale = self.scale,
            .x_off = x_off,
            .baseline = @floatFromInt(self.baseline),
        };
        self.font.outline(gid, &sink) catch return null;
        sink.finish();

        const out = try a.alloc(u8, w * h);
        errdefer a.free(out);
        var any = false;
        var y: usize = 0;
        while (y < h) : (y += 1) {
            var sum: f32 = 0;
            var x: usize = 0;
            while (x < w) : (x += 1) {
                sum += acc[y * stride + x];
                const c = @min(@abs(sum), 1.0);
                const v: u8 = @intFromFloat(@round(c * 255));
                out[y * w + x] = v;
                if (v != 0) any = true;
            }
        }
        if (!any) {
            a.free(out);
            return null; // blank glyph (a space): nothing to draw
        }
        if (bold) embolden(out, w, h);
        return out;
    }
};

/// No bold face: widen every stroke by one pixel to the right.
fn embolden(bm: []u8, w: u32, h: u32) void {
    var y: usize = 0;
    while (y < h) : (y += 1) {
        const row = bm[y * w ..][0..w];
        var x: usize = w - 1;
        while (x > 0) : (x -= 1) row[x] = @max(row[x], row[x - 1]);
    }
}

/// Receives an outline in font units (y up) and adds its edges to the
/// accumulation buffer in pixels (y down).
const Sink = struct {
    acc: []f32,
    stride: usize,
    w: f32,
    h: f32,
    scale: f32,
    x_off: f32,
    baseline: f32,
    start: [2]f32 = .{ 0, 0 },
    cur: [2]f32 = .{ 0, 0 },
    open: bool = false,

    fn map(self: *const Sink, x: f64, y: f64) [2]f32 {
        return .{
            @as(f32, @floatCast(x)) * self.scale + self.x_off,
            self.baseline - @as(f32, @floatCast(y)) * self.scale,
        };
    }

    pub fn moveTo(self: *Sink, x: f64, y: f64) void {
        self.finish();
        self.start = self.map(x, y);
        self.cur = self.start;
        self.open = true;
    }

    pub fn lineTo(self: *Sink, x: f64, y: f64) void {
        const p = self.map(x, y);
        self.edge(self.cur, p);
        self.cur = p;
    }

    pub fn quadTo(self: *Sink, cx: f64, cy: f64, x: f64, y: f64) void {
        const c = self.map(cx, cy);
        const p = self.map(x, y);
        const p0 = self.cur;
        // Segments by how far the curve strays from its chord.
        const dx = p0[0] - 2 * c[0] + p[0];
        const dy = p0[1] - 2 * c[1] + p[1];
        const dev = @sqrt(dx * dx + dy * dy);
        const n: usize = @intFromFloat(std.math.clamp(@ceil(@sqrt(dev * 2.0)), 1, 16));
        var prev = p0;
        var i: usize = 1;
        while (i <= n) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
            const u = 1 - t;
            const q: [2]f32 = .{
                u * u * p0[0] + 2 * u * t * c[0] + t * t * p[0],
                u * u * p0[1] + 2 * u * t * c[1] + t * t * p[1],
            };
            self.edge(prev, q);
            prev = q;
        }
        self.cur = p;
    }

    pub fn close(self: *Sink) void {
        self.finish();
    }

    /// Close the contour that is open.
    fn finish(self: *Sink) void {
        if (self.open) self.edge(self.cur, self.start);
        self.open = false;
    }

    fn edge(self: *Sink, a: [2]f32, b: [2]f32) void {
        // Clamp sideways so an outline that leaves the cell still adds its
        // full coverage to the edge column instead of indexing outside.
        const p0 = [2]f32{ std.math.clamp(a[0], 0, self.w), a[1] };
        const p1 = [2]f32{ std.math.clamp(b[0], 0, self.w), b[1] };
        self.line(p0, p1);
    }

    fn line(self: *Sink, a: [2]f32, b: [2]f32) void {
        if (a[1] == b[1]) return;
        const dir: f32 = if (a[1] < b[1]) 1 else -1;
        const p0 = if (a[1] < b[1]) a else b;
        const p1 = if (a[1] < b[1]) b else a;
        const dxdy = (p1[0] - p0[0]) / (p1[1] - p0[1]);
        var x = std.math.clamp(p0[0] - @min(p0[1], 0) * dxdy, 0, self.w);
        const y0: usize = @intFromFloat(@max(0, @floor(p0[1])));
        const y1: usize = @intFromFloat(@min(self.h, @ceil(@max(p1[1], 0))));
        var y = y0;
        while (y < y1) : (y += 1) {
            const row = y * self.stride;
            const yf: f32 = @floatFromInt(y);
            const dy = @min(yf + 1, p1[1]) - @max(yf, p0[1]);
            // Rounding must never carry x outside the buffer.
            const xnext = std.math.clamp(x + dxdy * dy, 0, self.w);
            const d = dy * dir;
            const lo = @min(x, xnext);
            const hi = @max(x, xnext);
            const lo_floor = @floor(lo);
            const lo_i: usize = @intFromFloat(lo_floor);
            const hi_ceil = @ceil(hi);
            const hi_i: usize = @intFromFloat(hi_ceil);
            if (hi_i <= lo_i + 1) {
                const xmf = 0.5 * (x + xnext) - lo_floor;
                self.acc[row + lo_i] += d - d * xmf;
                self.acc[row + lo_i + 1] += d * xmf;
            } else {
                const s = 1 / (hi - lo);
                const lo_f = lo - lo_floor;
                const a0 = 0.5 * s * (1 - lo_f) * (1 - lo_f);
                const hi_f = hi - hi_ceil + 1;
                const am = 0.5 * s * hi_f * hi_f;
                self.acc[row + lo_i] += d * a0;
                if (hi_i == lo_i + 2) {
                    self.acc[row + lo_i + 1] += d * (1 - a0 - am);
                } else {
                    const a1 = s * (1.5 - lo_f);
                    self.acc[row + lo_i + 1] += d * (a1 - a0);
                    var xi = lo_i + 2;
                    while (xi < hi_i - 1) : (xi += 1) self.acc[row + xi] += d * s;
                    const a2 = a1 + @as(f32, @floatFromInt(hi_i - lo_i - 3)) * s;
                    self.acc[row + hi_i - 1] += d * (1 - a2 - am);
                }
                self.acc[row + hi_i] += d * am;
            }
            x = xnext;
        }
    }
};

/// Whether `data` looks like a TrueType/OpenType file (not a PSF font).
pub fn looksLikeTrueType(data: []const u8) bool {
    if (data.len < 4) return false;
    const tag = std.mem.readInt(u32, data[0..4], .big);
    return tag == 0x00010000 or tag == 0x74727565 or tag == 0x4F54544F or tag == 0x74746366;
}

/// Whether every glyph has the same width, judged by "i" against "M". Only
/// such fonts make a terminal grid.
pub fn isMonospace(data: []const u8) bool {
    const f = truetype.Font.parse(data) catch return false;
    const i = f.glyphForUnicode('i') orelse return false;
    const m = f.glyphForUnicode('M') orelse return false;
    return f.advance(i) == f.advance(m);
}

// ---- tests ---------------------------------------------------------------------

const testing = std.testing;

extern fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern fn fread(buf: [*]u8, size: usize, n: usize, f: *anyopaque) usize;
extern fn fclose(f: *anyopaque) c_int;

fn readSystemFont(a: std.mem.Allocator, path: [:0]const u8) ?[]u8 {
    const f = fopen(path, "rb") orelse return null;
    defer _ = fclose(f);
    const buf = a.alloc(u8, 16 << 20) catch return null;
    const n = fread(buf.ptr, 1, buf.len, f);
    return a.realloc(buf, n) catch buf[0..n];
}

test "a square contour fills exactly its pixels" {
    var acc: [24]f32 = @splat(0);
    var s: Sink = .{ .acc = &acc, .stride = 6, .w = 4, .h = 4, .scale = 1, .x_off = 0, .baseline = 4 };
    // A 2x2 square from (1,1) to (3,3) in pixel space, y up from the baseline.
    s.moveTo(1, 3);
    s.lineTo(3, 3);
    s.lineTo(3, 1);
    s.lineTo(1, 1);
    s.close();
    var rows: [4][4]f32 = undefined;
    for (0..4) |y| {
        var sum: f32 = 0;
        for (0..4) |x| {
            sum += acc[y * 6 + x];
            rows[y][x] = @abs(sum);
        }
    }
    try testing.expectEqual(@as(f32, 0), rows[0][1]);
    try testing.expectApproxEqAbs(@as(f32, 1), rows[1][1], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1), rows[2][2], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0), rows[1][3], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0), rows[3][1], 1e-5);
}

test "a real monospace font gets a cell and draws letters" {
    const a = testing.allocator;
    const data = readSystemFont(a, "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf") orelse return;
    defer a.free(data);
    var face = try Face.init(a, data, 24);
    defer face.deinit();
    try testing.expectEqual(@as(u32, 24), face.cell_h);
    try testing.expect(face.cell_w >= 12 and face.cell_w <= 16);
    const bm = face.coverage('A', false, false, face.cell_w) orelse return error.NoGlyph;
    var ink: u32 = 0;
    for (bm) |v| ink += v;
    try testing.expect(ink > 255 * 20);
    // Partial coverage exists (anti-aliasing), and a space is blank.
    var partial = false;
    for (bm) |v| if (v > 0 and v < 255) {
        partial = true;
    };
    try testing.expect(partial);
    try testing.expect(face.coverage(' ', false, false, face.cell_w) == null);
    // Bold has more ink.
    const bold = face.coverage('A', false, true, face.cell_w).?;
    var ink2: u32 = 0;
    for (bold) |v| ink2 += v;
    try testing.expect(ink2 > ink);
}

test "resize gives a new cell and drops the cache; a missing glyph is remembered" {
    const a = testing.allocator;
    const data = readSystemFont(a, "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf") orelse return;
    defer a.free(data);
    var face = try Face.init(a, data, 24);
    defer face.deinit();
    _ = face.coverage('A', false, false, face.cell_w).?;
    try testing.expect(face.cache.count() == 1);
    face.resize(16);
    try testing.expectEqual(@as(u32, 16), face.cell_h);
    try testing.expectEqual(@as(usize, 0), face.cache.count());
    // U+10FFFD has no glyph: the answer is cached, not asked again.
    try testing.expect(face.coverage(0x10FFFD, false, false, face.cell_w) == null);
    try testing.expect(face.coverage(0x10FFFD, false, false, face.cell_w) == null);
    try testing.expectEqual(@as(usize, 1), face.cache.count());
}
