//! Reads TrueType fonts (the `FontFile2` streams embedded in PDFs, and
//! OpenType files with TrueType outlines): the cmap, glyph outlines
//! (simple and composite) and advance widths. Pure, and safe on bad input:
//! every read is bounds checked and a damaged font returns an error.

const std = @import("std");

pub const Error = error{ BadFont, Unsupported };

/// The most points one glyph may have (real glyphs have a few hundred).
const max_points = 4096;

fn u16At(d: []const u8, off: usize) Error!u16 {
    if (off + 2 > d.len) return error.BadFont;
    return std.mem.readInt(u16, d[off..][0..2], .big);
}

fn i16At(d: []const u8, off: usize) Error!i16 {
    return @bitCast(try u16At(d, off));
}

fn u32At(d: []const u8, off: usize) Error!u32 {
    if (off + 4 > d.len) return error.BadFont;
    return std.mem.readInt(u32, d[off..][0..4], .big);
}

const Table = struct { off: usize = 0, len: usize = 0 };

pub const Font = struct {
    data: []const u8,
    units_per_em: u16,
    num_glyphs: u16,
    long_loca: bool,
    glyf: Table = .{},
    loca: Table = .{},
    cmap: Table = .{},
    hmtx: Table = .{},
    num_hmetrics: u16 = 0,
    /// From `hhea`, in font units: the ascender is positive, the descender negative.
    ascender: i16 = 0,
    descender: i16 = 0,

    pub fn parse(data: []const u8) Error!Font {
        if (data.len < 12) return error.BadFont;
        var base: usize = 0;
        // A TrueType collection: use its first font.
        if (std.mem.eql(u8, data[0..4], "ttcf")) base = try u32At(data, 12);
        const tag = try u32At(data, base);
        if (tag != 0x00010000 and tag != 0x74727565 and tag != 0x4F54544F) return error.BadFont; // 1.0, 'true', 'OTTO'
        const num_tables = try u16At(data, base + 4);
        var f: Font = .{ .data = data, .units_per_em = 1000, .num_glyphs = 0, .long_loca = false };
        var head = Table{};
        var maxp = Table{};
        var hhea = Table{};
        var i: usize = 0;
        while (i < num_tables) : (i += 1) {
            const rec = base + 12 + i * 16;
            if (rec + 16 > data.len) return error.BadFont;
            const name = data[rec .. rec + 4];
            const t = Table{ .off = try u32At(data, rec + 8), .len = try u32At(data, rec + 12) };
            if (t.off > data.len or t.len > data.len - t.off) continue; // a table cut short: ignore it
            if (std.mem.eql(u8, name, "head")) head = t else if (std.mem.eql(u8, name, "maxp")) maxp = t else if (std.mem.eql(u8, name, "hhea")) hhea = t else if (std.mem.eql(u8, name, "glyf")) f.glyf = t else if (std.mem.eql(u8, name, "loca")) f.loca = t else if (std.mem.eql(u8, name, "cmap")) f.cmap = t else if (std.mem.eql(u8, name, "hmtx")) f.hmtx = t else if (std.mem.eql(u8, name, "CFF ")) return error.Unsupported;
        }
        if (head.len < 54 or maxp.len < 6) return error.BadFont;
        f.units_per_em = try u16At(data, head.off + 18);
        if (f.units_per_em == 0) return error.BadFont;
        f.long_loca = (try i16At(data, head.off + 50)) != 0;
        f.num_glyphs = try u16At(data, maxp.off + 4);
        if (hhea.len >= 8) {
            f.ascender = try i16At(data, hhea.off + 4);
            f.descender = try i16At(data, hhea.off + 6);
        }
        if (hhea.len >= 36) f.num_hmetrics = try u16At(data, hhea.off + 34);
        if (f.glyf.len == 0 or f.loca.len == 0) return error.BadFont;
        return f;
    }

    // ---- cmap -------------------------------------------------------------------------------

    /// Offset of the cmap subtable for (platform, encoding), or null.
    fn subtable(self: Font, platform: u16, encoding: u16) ?usize {
        if (self.cmap.len < 4) return null;
        const n = u16At(self.data, self.cmap.off + 2) catch return null;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const rec = self.cmap.off + 4 + i * 8;
            const p = u16At(self.data, rec) catch return null;
            const e = u16At(self.data, rec + 2) catch return null;
            if (p == platform and e == encoding) {
                const off = u32At(self.data, rec + 4) catch return null;
                if (off >= self.cmap.len) return null;
                return self.cmap.off + off;
            }
        }
        return null;
    }

    fn lookup(self: Font, sub: usize, code: u32) ?u16 {
        const d = self.data;
        const format = u16At(d, sub) catch return null;
        switch (format) {
            0 => {
                if (code > 255) return null;
                if (sub + 6 + code >= d.len) return null;
                const g = d[sub + 6 + code];
                return if (g == 0) null else g;
            },
            4 => {
                if (code > 0xFFFF) return null;
                const seg2 = u16At(d, sub + 6) catch return null; // segCountX2
                const segs = seg2 / 2;
                const ends = sub + 14;
                const starts = ends + seg2 + 2;
                const deltas = starts + seg2;
                const ranges = deltas + seg2;
                var s: usize = 0;
                while (s < segs) : (s += 1) {
                    const end = u16At(d, ends + s * 2) catch return null;
                    if (code > end) continue;
                    const start = u16At(d, starts + s * 2) catch return null;
                    if (code < start) return null;
                    const delta = u16At(d, deltas + s * 2) catch return null;
                    const ro = u16At(d, ranges + s * 2) catch return null;
                    if (ro == 0) {
                        const g: u16 = @truncate(code +% delta);
                        return if (g == 0) null else g;
                    }
                    const at = ranges + s * 2 + ro + (code - start) * 2;
                    const g0 = u16At(d, at) catch return null;
                    if (g0 == 0) return null;
                    const g: u16 = g0 +% delta;
                    return if (g == 0) null else g;
                }
                return null;
            },
            6 => {
                const first = u16At(d, sub + 6) catch return null;
                const count = u16At(d, sub + 8) catch return null;
                if (code < first or code >= @as(u32, first) + count) return null;
                const g = u16At(d, sub + 10 + (code - first) * 2) catch return null;
                return if (g == 0) null else g;
            },
            12 => {
                const groups = u32At(d, sub + 12) catch return null;
                var lo: usize = 0;
                var hi: usize = groups;
                while (lo < hi) {
                    const mid = (lo + hi) / 2;
                    const g = sub + 16 + mid * 12;
                    const start = u32At(d, g) catch return null;
                    const end = u32At(d, g + 4) catch return null;
                    if (code < start) {
                        hi = mid;
                    } else if (code > end) {
                        lo = mid + 1;
                    } else {
                        const first = u32At(d, g + 8) catch return null;
                        const gid = first + (code - start);
                        return if (gid == 0 or gid > 0xFFFF) null else @intCast(gid);
                    }
                }
                return null;
            },
            else => return null,
        }
    }

    /// The glyph for a Unicode code point, through a Unicode cmap.
    pub fn glyphForUnicode(self: Font, cp: u32) ?u16 {
        if (self.subtable(3, 10)) |s| if (self.lookup(s, cp)) |g| return g;
        if (self.subtable(3, 1)) |s| if (self.lookup(s, cp)) |g| return g;
        if (self.subtable(0, 3)) |s| if (self.lookup(s, cp)) |g| return g;
        if (self.subtable(0, 4)) |s| if (self.lookup(s, cp)) |g| return g;
        return null;
    }

    /// The glyph for a raw character code in a symbolic or subset font:
    /// the (3,0) cmap at 0xF000 + code or code, then the Macintosh (1,0) cmap.
    pub fn glyphForCode(self: Font, code: u32) ?u16 {
        if (self.subtable(3, 0)) |s| {
            if (self.lookup(s, 0xF000 + code)) |g| return g;
            if (self.lookup(s, code)) |g| return g;
        }
        if (self.subtable(1, 0)) |s| if (self.lookup(s, code)) |g| return g;
        return null;
    }

    pub fn hasCmap(self: Font) bool {
        return self.cmap.len > 4;
    }

    // ---- metrics ----------------------------------------------------------------------------

    /// Advance width in font units.
    pub fn advance(self: Font, gid: u16) u16 {
        if (self.num_hmetrics == 0 or self.hmtx.len == 0) return self.units_per_em;
        const i = @min(gid, self.num_hmetrics - 1);
        return u16At(self.data, self.hmtx.off + @as(usize, i) * 4) catch self.units_per_em;
    }

    // ---- outlines ---------------------------------------------------------------------------

    fn glyphRange(self: Font, gid: u16) Error!?[]const u8 {
        if (gid >= self.num_glyphs) return null;
        var a: u32 = undefined;
        var b: u32 = undefined;
        if (self.long_loca) {
            if (@as(usize, gid) * 4 + 8 > self.loca.len) return error.BadFont;
            a = try u32At(self.data, self.loca.off + @as(usize, gid) * 4);
            b = try u32At(self.data, self.loca.off + @as(usize, gid) * 4 + 4);
        } else {
            if (@as(usize, gid) * 2 + 4 > self.loca.len) return error.BadFont;
            a = @as(u32, try u16At(self.data, self.loca.off + @as(usize, gid) * 2)) * 2;
            b = @as(u32, try u16At(self.data, self.loca.off + @as(usize, gid) * 2 + 2)) * 2;
        }
        if (b <= a) return null; // an empty glyph, such as a space
        if (b > self.glyf.len) return error.BadFont;
        return self.data[self.glyf.off + a .. self.glyf.off + b];
    }

    /// Sends the outline of `gid` to `sink` in font units, y up. `sink` has
    /// `moveTo(x, y)`, `lineTo(x, y)`, `quadTo(cx, cy, x, y)` and `close()`.
    pub fn outline(self: Font, gid: u16, sink: anytype) Error!void {
        try self.outlineAt(gid, sink, .{ 1, 0, 0, 1, 0, 0 }, 0);
    }

    fn outlineAt(self: Font, gid: u16, sink: anytype, m: [6]f64, depth: u8) Error!void {
        if (depth > 6) return error.BadFont;
        const g = (try self.glyphRange(gid)) orelse return;
        const ncont = try i16At(g, 0);
        if (ncont >= 0) return self.simple(g, @intCast(ncont), sink, m);
        // Composite glyph: pieces, each placed by an offset and a transform.
        var p: usize = 10;
        while (true) {
            const flags = try u16At(g, p);
            const child = try u16At(g, p + 2);
            p += 4;
            var dx: f64 = 0;
            var dy: f64 = 0;
            if (flags & 1 != 0) { // ARG_1_AND_2_ARE_WORDS
                if (flags & 2 != 0) {
                    dx = @floatFromInt(try i16At(g, p));
                    dy = @floatFromInt(try i16At(g, p + 2));
                }
                p += 4;
            } else {
                if (p + 2 > g.len) return error.BadFont;
                if (flags & 2 != 0) {
                    dx = @floatFromInt(@as(i8, @bitCast(g[p])));
                    dy = @floatFromInt(@as(i8, @bitCast(g[p + 1])));
                }
                p += 2;
            }
            var a: f64 = 1;
            var b: f64 = 0;
            var c: f64 = 0;
            var d: f64 = 1;
            const f2dot14 = struct {
                fn f(v: i16) f64 {
                    return @as(f64, @floatFromInt(v)) / 16384.0;
                }
            }.f;
            if (flags & 0x0008 != 0) { // WE_HAVE_A_SCALE
                a = f2dot14(try i16At(g, p));
                d = a;
                p += 2;
            } else if (flags & 0x0040 != 0) { // X and Y scale
                a = f2dot14(try i16At(g, p));
                d = f2dot14(try i16At(g, p + 2));
                p += 4;
            } else if (flags & 0x0080 != 0) { // 2x2
                a = f2dot14(try i16At(g, p));
                b = f2dot14(try i16At(g, p + 2));
                c = f2dot14(try i16At(g, p + 4));
                d = f2dot14(try i16At(g, p + 6));
                p += 8;
            }
            // child space -> this glyph's space -> the parent's `m`.
            const local = [6]f64{ a, b, c, d, dx, dy };
            try self.outlineAt(child, sink, mul(local, m), depth + 1);
            if (flags & 0x0020 == 0) break; // MORE_COMPONENTS
        }
    }

    fn simple(self: Font, g: []const u8, ncont: usize, sink: anytype, m: [6]f64) Error!void {
        _ = self;
        if (ncont == 0) return;
        const end_pts = 10;
        const npts = @as(usize, try u16At(g, end_pts + (ncont - 1) * 2)) + 1;
        if (npts > max_points) return error.BadFont;
        const ilen = try u16At(g, end_pts + ncont * 2);
        var p: usize = end_pts + ncont * 2 + 2 + ilen;
        // Flags, with repeats.
        var flags_buf: [max_points]u8 = undefined;
        var k: usize = 0;
        while (k < npts) {
            if (p >= g.len) return error.BadFont;
            const fl = g[p];
            p += 1;
            flags_buf[k] = fl;
            k += 1;
            if (fl & 8 != 0) {
                if (p >= g.len) return error.BadFont;
                var rep = g[p];
                p += 1;
                while (rep > 0 and k < npts) : (rep -= 1) {
                    flags_buf[k] = fl;
                    k += 1;
                }
            }
        }
        var coords: [max_points * 2]f64 = undefined;
        const xs = coords[0..npts];
        const ys = coords[max_points .. max_points + npts];
        var v: i32 = 0;
        for (0..npts) |i| {
            const fl = flags_buf[i];
            if (fl & 2 != 0) {
                if (p >= g.len) return error.BadFont;
                const dv: i32 = g[p];
                p += 1;
                v += if (fl & 16 != 0) dv else -dv;
            } else if (fl & 16 == 0) {
                v += try i16At(g, p);
                p += 2;
            }
            xs[i] = @floatFromInt(v);
        }
        v = 0;
        for (0..npts) |i| {
            const fl = flags_buf[i];
            if (fl & 4 != 0) {
                if (p >= g.len) return error.BadFont;
                const dv: i32 = g[p];
                p += 1;
                v += if (fl & 32 != 0) dv else -dv;
            } else if (fl & 32 == 0) {
                v += try i16At(g, p);
                p += 2;
            }
            ys[i] = @floatFromInt(v);
        }

        var first: usize = 0;
        var c: usize = 0;
        while (c < ncont) : (c += 1) {
            const last: usize = try u16At(g, end_pts + c * 2);
            if (last < first or last >= npts) return error.BadFont;
            contour(sink, xs[first .. last + 1], ys[first .. last + 1], flags_buf[first .. last + 1], m);
            first = last + 1;
        }
    }
};

fn mul(a: [6]f64, b: [6]f64) [6]f64 {
    // a then b (row vectors): result = a * b.
    return .{
        a[0] * b[0] + a[1] * b[2],
        a[0] * b[1] + a[1] * b[3],
        a[2] * b[0] + a[3] * b[2],
        a[2] * b[1] + a[3] * b[3],
        a[4] * b[0] + a[5] * b[2] + b[4],
        a[4] * b[1] + a[5] * b[3] + b[5],
    };
}

fn tx(m: [6]f64, x: f64, y: f64) [2]f64 {
    return .{ x * m[0] + y * m[2] + m[4], x * m[1] + y * m[3] + m[5] };
}

/// One closed contour of on- and off-curve points, as lines and quadratic curves.
fn contour(sink: anytype, xs: []const f64, ys: []const f64, flags: []const u8, m: [6]f64) void {
    const n = xs.len;
    if (n < 2) return;
    const on = struct {
        fn f(fl: []const u8, i: usize) bool {
            return fl[i] & 1 != 0;
        }
    }.f;
    // Find a starting point that is on the curve (or make one).
    var start: [2]f64 = undefined;
    var begin: usize = 0; // index of the first point to process after the start
    var count = n;
    if (on(flags, 0)) {
        start = .{ xs[0], ys[0] };
        begin = 1;
        count = n - 1;
    } else if (on(flags, n - 1)) {
        start = .{ xs[n - 1], ys[n - 1] };
        begin = 0;
        count = n - 1;
    } else {
        start = .{ (xs[0] + xs[n - 1]) / 2, (ys[0] + ys[n - 1]) / 2 };
        begin = 0;
        count = n;
    }
    const s0 = tx(m, start[0], start[1]);
    sink.moveTo(s0[0], s0[1]);
    var pending: ?[2]f64 = null; // an off-curve control point
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const idx = (begin + i) % n;
        const pt = [2]f64{ xs[idx], ys[idx] };
        if (on(flags, idx)) {
            if (pending) |ctl| {
                const c2 = tx(m, ctl[0], ctl[1]);
                const e = tx(m, pt[0], pt[1]);
                sink.quadTo(c2[0], c2[1], e[0], e[1]);
                pending = null;
            } else {
                const e = tx(m, pt[0], pt[1]);
                sink.lineTo(e[0], e[1]);
            }
        } else {
            if (pending) |ctl| {
                // Two off-curve points in a row: the curve passes through their midpoint.
                const mid = [2]f64{ (ctl[0] + pt[0]) / 2, (ctl[1] + pt[1]) / 2 };
                const c2 = tx(m, ctl[0], ctl[1]);
                const e = tx(m, mid[0], mid[1]);
                sink.quadTo(c2[0], c2[1], e[0], e[1]);
            }
            pending = pt;
        }
    }
    if (pending) |ctl| {
        const c2 = tx(m, ctl[0], ctl[1]);
        sink.quadTo(c2[0], c2[1], s0[0], s0[1]);
    }
    sink.close();
}

// ---- tests ----------------------------------------------------------------------------------

const Recorder = struct {
    moves: usize = 0,
    lines: usize = 0,
    quads: usize = 0,
    closes: usize = 0,
    min_x: f64 = 1e9,
    max_x: f64 = -1e9,

    pub fn moveTo(self: *Recorder, x: f64, _: f64) void {
        self.moves += 1;
        self.track(x);
    }
    pub fn lineTo(self: *Recorder, x: f64, _: f64) void {
        self.lines += 1;
        self.track(x);
    }
    pub fn quadTo(self: *Recorder, _: f64, _: f64, x: f64, _: f64) void {
        self.quads += 1;
        self.track(x);
    }
    pub fn close(self: *Recorder) void {
        self.closes += 1;
    }
    fn track(self: *Recorder, x: f64) void {
        self.min_x = @min(self.min_x, x);
        self.max_x = @max(self.max_x, x);
    }
};

extern fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern fn fread(buf: [*]u8, size: usize, n: usize, f: *anyopaque) usize;
extern fn fclose(f: *anyopaque) c_int;

fn loadSystemFont(a: std.mem.Allocator, path: [*:0]const u8) !?[]u8 {
    const f = fopen(path, "rb") orelse return null;
    defer _ = fclose(f);
    const buf = try a.alloc(u8, 32 << 20);
    const n = fread(buf.ptr, 1, buf.len, f);
    return buf[0..n];
}

test "a real font: cmap, outline and advance" {
    const a = std.testing.allocator;
    const path = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf";
    const bytes = (try loadSystemFont(a, path)) orelse return; // not installed: nothing to check
    defer a.free(bytes.ptr[0 .. 32 << 20]);
    const font = try Font.parse(bytes);
    try std.testing.expect(font.units_per_em == 2048);
    const gid = font.glyphForUnicode('A') orelse return error.NoGlyph;
    try std.testing.expect(gid > 0);
    var rec: Recorder = .{};
    try font.outline(gid, &rec);
    // "A" is an outer contour and the triangular counter.
    try std.testing.expectEqual(@as(usize, 2), rec.moves);
    try std.testing.expectEqual(@as(usize, 2), rec.closes);
    try std.testing.expect(rec.lines >= 6);
    try std.testing.expect(font.advance(gid) > 1000);
    // Space has no outline; a curved letter has quadratic segments.
    var space: Recorder = .{};
    try font.outline(font.glyphForUnicode(' ').?, &space);
    try std.testing.expectEqual(@as(usize, 0), space.moves);
    var o: Recorder = .{};
    try font.outline(font.glyphForUnicode('o').?, &o);
    try std.testing.expect(o.quads > 4);
    // An accented letter is a composite of a base and an accent.
    var e: Recorder = .{};
    try font.outline(font.glyphForUnicode(0xE9).?, &e);
    try std.testing.expect(e.moves >= 2);
}

test "damaged fonts are refused" {
    try std.testing.expectError(error.BadFont, Font.parse("short"));
    try std.testing.expectError(error.BadFont, Font.parse("\x00\x01\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"));
}
