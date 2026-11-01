//! Compact Font Format fonts (PDF /FontFile3 with Type1C or CIDFontType0C,
//! and the 'CFF ' table of an OpenType font): the parser and the Type 2
//! charstring interpreter that turns a glyph into lines and cubic curves.
//! The font bytes are borrowed, every read is bounds checked, and a damaged
//! font returns an error instead of crashing.

const std = @import("std");
const zpdf = @import("zpdf");

const std_strings = zpdf.cff_std_strings.std_strings;

pub const Error = error{ BadFont, OutOfMemory };

const max_subr_depth = 10;
const max_stack = 96;

const Index = struct {
    count: u32 = 0,
    off_size: u8 = 0,
    offsets_at: usize = 0,
    data_at: usize = 0, // the byte before the first item; offsets are 1-based from here
    end: usize = 0,

    fn item(self: Index, data: []const u8, i: u32) ?[]const u8 {
        if (i >= self.count) return null;
        const a = self.offset(data, i) orelse return null;
        const b = self.offset(data, i + 1) orelse return null;
        if (b < a or self.data_at + b > data.len) return null;
        return data[self.data_at + a .. self.data_at + b];
    }

    fn offset(self: Index, data: []const u8, i: u32) ?usize {
        const at = self.offsets_at + @as(usize, i) * self.off_size;
        if (at + self.off_size > data.len) return null;
        var v: usize = 0;
        for (data[at .. at + self.off_size]) |b| v = (v << 8) | b;
        return v;
    }
};

fn u16At(d: []const u8, at: usize) ?u16 {
    if (at + 2 > d.len) return null;
    return (@as(u16, d[at]) << 8) | d[at + 1];
}

fn readIndex(d: []const u8, at: usize) Error!Index {
    const count = u16At(d, at) orelse return error.BadFont;
    if (count == 0) return .{ .end = at + 2 };
    if (at + 3 > d.len) return error.BadFont;
    const off_size = d[at + 2];
    if (off_size < 1 or off_size > 4) return error.BadFont;
    var idx: Index = .{ .count = count, .off_size = off_size, .offsets_at = at + 3 };
    idx.data_at = at + 3 + (@as(usize, count) + 1) * off_size - 1;
    const last = idx.offset(d, count) orelse return error.BadFont;
    idx.end = idx.data_at + last;
    if (idx.end > d.len) return error.BadFont;
    return idx;
}

// ---- DICT data -------------------------------------------------------------------------------

const DictEntry = struct { op: u16, args: [48]f64 = undefined, n: usize = 0 };

/// Reads the next operator and its operands; null at the end of the data.
fn nextDictEntry(d: []const u8, pos: *usize) ?DictEntry {
    var e: DictEntry = .{ .op = 0 };
    while (pos.* < d.len) {
        const b = d[pos.*];
        pos.* += 1;
        if (b <= 21) {
            e.op = b;
            if (b == 12) {
                if (pos.* >= d.len) return null;
                e.op = 0x0c00 | @as(u16, d[pos.*]);
                pos.* += 1;
            }
            return e;
        }
        var v: f64 = 0;
        switch (b) {
            28 => {
                if (pos.* + 2 > d.len) return null;
                v = @floatFromInt(@as(i16, @bitCast((@as(u16, d[pos.*]) << 8) | d[pos.* + 1])));
                pos.* += 2;
            },
            29 => {
                if (pos.* + 4 > d.len) return null;
                const u = (@as(u32, d[pos.*]) << 24) | (@as(u32, d[pos.* + 1]) << 16) | (@as(u32, d[pos.* + 2]) << 8) | d[pos.* + 3];
                v = @floatFromInt(@as(i32, @bitCast(u)));
                pos.* += 4;
            },
            30 => { // a real number in nibbles
                var text: [40]u8 = undefined;
                var n: usize = 0;
                done: while (pos.* < d.len) {
                    const byte = d[pos.*];
                    pos.* += 1;
                    for ([_]u8{ byte >> 4, byte & 15 }) |nib| {
                        if (nib == 15) break :done;
                        const piece: []const u8 = switch (nib) {
                            0...9 => &[_]u8{'0' + nib},
                            10 => ".",
                            11 => "E",
                            12 => "E-",
                            14 => "-",
                            else => "",
                        };
                        if (n + piece.len > text.len) break :done;
                        @memcpy(text[n .. n + piece.len], piece);
                        n += piece.len;
                    }
                }
                v = std.fmt.parseFloat(f64, text[0..n]) catch 0;
            },
            32...246 => v = @as(f64, @floatFromInt(@as(i32, b) - 139)),
            247...250 => {
                if (pos.* >= d.len) return null;
                v = @floatFromInt((@as(i32, b) - 247) * 256 + d[pos.*] + 108);
                pos.* += 1;
            },
            251...254 => {
                if (pos.* >= d.len) return null;
                v = @floatFromInt(-(@as(i32, b) - 251) * 256 - @as(i32, d[pos.*]) - 108);
                pos.* += 1;
            },
            else => {},
        }
        if (e.n < e.args.len) {
            e.args[e.n] = v;
            e.n += 1;
        }
    }
    return null;
}

const Private = struct {
    subrs: Index = .{},
    default_width: f64 = 0,
    nominal_width: f64 = 0,
};

pub const Font = struct {
    data: []const u8,
    charstrings: Index = .{},
    global_subrs: Index = .{},
    strings: Index = .{},
    is_cid: bool = false,
    num_glyphs: u16 = 0,
    units_per_em: u16 = 1000,
    /// Glyph id to SID (name-keyed fonts) or CID (CID-keyed fonts).
    charset: []const u16 = &.{},
    /// Glyph id to its Private DICT (always 0 for a name-keyed font).
    fd_select: []const u8 = &.{},
    privates: []const Private = &.{},
    /// The font's own character code to glyph id table.
    encoding: [256]u16 = @splat(0),
    unicode: std.AutoHashMapUnmanaged(u32, u16) = .empty,
    cid: std.AutoHashMapUnmanaged(u32, u16) = .empty,

    /// `a` must outlive the font (the renderer passes its page arena).
    pub fn parse(a: std.mem.Allocator, data: []const u8) Error!Font {
        if (data.len < 8 or data[0] != 1) return error.BadFont;
        const hdr_size = data[2];
        var f: Font = .{ .data = data };
        const names = try readIndex(data, hdr_size);
        const tops = try readIndex(data, names.end);
        f.strings = try readIndex(data, tops.end);
        f.global_subrs = try readIndex(data, f.strings.end);
        const top = tops.item(data, 0) orelse return error.BadFont;

        var charset_off: usize = 0;
        var encoding_off: usize = 0;
        var cs_off: usize = 0;
        var priv_size: usize = 0;
        var priv_off: usize = 0;
        var fdarray_off: usize = 0;
        var fdselect_off: usize = 0;
        var matrix: ?f64 = null;
        var pos: usize = 0;
        while (nextDictEntry(top, &pos)) |e| switch (e.op) {
            15 => if (e.n > 0) {
                charset_off = @intFromFloat(@max(e.args[0], 0));
            },
            16 => if (e.n > 0) {
                encoding_off = @intFromFloat(@max(e.args[0], 0));
            },
            17 => if (e.n > 0) {
                cs_off = @intFromFloat(@max(e.args[0], 0));
            },
            18 => if (e.n > 1) {
                priv_size = @intFromFloat(@max(e.args[0], 0));
                priv_off = @intFromFloat(@max(e.args[1], 0));
            },
            0x0c1e => f.is_cid = true, // ROS
            0x0c24 => if (e.n > 0) {
                fdarray_off = @intFromFloat(@max(e.args[0], 0));
            },
            0x0c25 => if (e.n > 0) {
                fdselect_off = @intFromFloat(@max(e.args[0], 0));
            },
            0x0c07 => if (e.n > 0 and e.args[0] > 0) {
                matrix = e.args[0];
            },
            else => {},
        };
        if (cs_off == 0) return error.BadFont;
        f.charstrings = try readIndex(data, cs_off);
        if (f.charstrings.count == 0) return error.BadFont;
        f.num_glyphs = @intCast(@min(f.charstrings.count, 65535));

        // Private DICTs: one for a name-keyed font, one per Font DICT for a CID-keyed one.
        if (f.is_cid and fdarray_off != 0) {
            const fds = try readIndex(data, fdarray_off);
            const privs = try a.alloc(Private, @max(fds.count, 1));
            for (privs, 0..) |*p, i| {
                p.* = .{};
                const fd = fds.item(data, @intCast(i)) orelse continue;
                var q: usize = 0;
                while (nextDictEntry(fd, &q)) |e| switch (e.op) {
                    18 => if (e.n > 1) {
                        p.* = readPrivate(data, @intFromFloat(@max(e.args[0], 0)), @intFromFloat(@max(e.args[1], 0)));
                    },
                    0x0c07 => if (matrix == null and e.n > 0 and e.args[0] > 0) {
                        matrix = e.args[0];
                    },
                    else => {},
                };
            }
            f.privates = privs;
            const sel = try a.alloc(u8, f.num_glyphs);
            @memset(sel, 0);
            if (fdselect_off != 0) readFdSelect(data, fdselect_off, sel);
            f.fd_select = sel;
        } else {
            const privs = try a.alloc(Private, 1);
            privs[0] = if (priv_off != 0) readPrivate(data, priv_size, priv_off) else .{};
            f.privates = privs;
        }
        if (matrix) |m| f.units_per_em = @intFromFloat(std.math.clamp(@round(1.0 / m), 16, 16384));

        try f.readCharset(a, charset_off);
        if (!f.is_cid) {
            try f.buildUnicode(a);
            f.readEncoding(a, encoding_off);
        } else {
            try f.cid.ensureTotalCapacity(a, f.num_glyphs);
            for (f.charset, 0..) |c, gid| f.cid.putAssumeCapacity(c, @intCast(gid));
        }
        return f;
    }

    fn readCharset(f: *Font, a: std.mem.Allocator, off: usize) Error!void {
        const n = f.num_glyphs;
        const cs = try a.alloc(u16, n);
        @memset(cs, 0);
        const d = f.data;
        if (off <= 2) { // predefined: ISOAdobe (and, roughly, Expert sets) number glyphs by SID
            for (cs, 0..) |*c, i| c.* = @intCast(i);
        } else {
            if (off >= d.len) return error.BadFont;
            const fmt = d[off];
            var p = off + 1;
            var gid: usize = 1;
            switch (fmt) {
                0 => while (gid < n) : (gid += 1) {
                    cs[gid] = u16At(d, p) orelse break;
                    p += 2;
                },
                1, 2 => while (gid < n) {
                    const first = u16At(d, p) orelse break;
                    p += 2;
                    var left: usize = 0;
                    if (fmt == 1) {
                        if (p >= d.len) break;
                        left = d[p];
                        p += 1;
                    } else {
                        left = u16At(d, p) orelse break;
                        p += 2;
                    }
                    var k: usize = 0;
                    while (k <= left and gid < n) : (k += 1) {
                        cs[gid] = @truncate(@as(usize, first) + k);
                        gid += 1;
                    }
                },
                else => return error.BadFont,
            }
        }
        f.charset = cs;
    }

    /// The glyph's name, from the standard strings or the font's own.
    pub fn glyphName(f: *const Font, gid: u16) ?[]const u8 {
        if (f.is_cid or gid >= f.charset.len) return null;
        const sid = f.charset[gid];
        if (sid < std_strings.len) return std_strings[sid];
        return f.strings.item(f.data, sid - @as(u16, std_strings.len));
    }

    fn buildUnicode(f: *Font, a: std.mem.Allocator) Error!void {
        var gid: u16 = 0;
        while (gid < f.num_glyphs) : (gid += 1) {
            const name = f.glyphName(gid) orelse continue;
            const cp = nameToUnicode(name) orelse continue;
            const r = try f.unicode.getOrPut(a, cp);
            if (!r.found_existing) r.value_ptr.* = gid;
        }
    }

    fn readEncoding(f: *Font, a: std.mem.Allocator, off: usize) void {
        _ = a;
        const d = f.data;
        if (off == 0 or off == 1) { // Standard (or Expert, treated alike): by Unicode of the standard name
            for (zpdf.encoding.standard_encoding, 0..) |cp, code| {
                if (code > 255 or cp == 0) continue;
                if (f.unicode.get(cp)) |g| f.encoding[code] = g;
            }
            return;
        }
        if (off >= d.len) return;
        const fmt = d[off];
        var p = off + 1;
        switch (fmt & 0x7f) {
            0 => {
                if (p >= d.len) return;
                const n = d[p];
                p += 1;
                var i: usize = 0;
                while (i < n and p < d.len) : (i += 1) {
                    f.encoding[d[p]] = @intCast(i + 1);
                    p += 1;
                }
            },
            1 => {
                if (p >= d.len) return;
                const n = d[p];
                p += 1;
                var gid: u16 = 1;
                var i: usize = 0;
                while (i < n and p + 1 < d.len) : (i += 1) {
                    const first = d[p];
                    const left = d[p + 1];
                    p += 2;
                    var k: usize = 0;
                    while (k <= left) : (k += 1) {
                        if (@as(usize, first) + k < 256) f.encoding[first + k] = gid;
                        gid += 1;
                    }
                }
            },
            else => {},
        }
        if (fmt & 0x80 != 0 and p < d.len) { // supplements: code and SID
            const n = d[p];
            p += 1;
            var i: usize = 0;
            while (i < n and p + 2 < d.len) : (i += 1) {
                const code = d[p];
                const sid = u16At(d, p + 1) orelse break;
                p += 3;
                for (f.charset, 0..) |s, gid| if (s == sid) {
                    f.encoding[code] = @intCast(gid);
                    break;
                };
            }
        }
    }

    // ---- lookup --------------------------------------------------------------------------------

    pub fn glyphForUnicode(f: *const Font, cp: u32) ?u16 {
        return f.unicode.get(cp);
    }

    /// The glyph the font's own encoding gives a character code (simple fonts).
    pub fn glyphForCode(f: *const Font, code: u32) ?u16 {
        if (code > 255) return null;
        const g = f.encoding[code];
        return if (g == 0) null else g;
    }

    /// The glyph of a CID in a CID-keyed font; for a name-keyed font the CID is the glyph id.
    pub fn glyphForCid(f: *const Font, cid: u32) ?u16 {
        if (!f.is_cid) return if (cid < f.num_glyphs) @intCast(cid) else null;
        return f.cid.get(cid);
    }

    // ---- outlines ------------------------------------------------------------------------------

    /// The advance width in font units.
    pub fn advance(f: *const Font, gid: u16) u16 {
        var sink: NullSink = .{};
        var w: f64 = 0;
        f.run(gid, &sink, &w, 0, 0, 0) catch return 0;
        return @intFromFloat(std.math.clamp(@round(w), 0, 65535));
    }

    /// Draws glyph `gid` into `sink` (moveTo, lineTo, curveTo, close), y up.
    pub fn outline(f: *const Font, gid: u16, sink: anytype) Error!void {
        var w: f64 = 0;
        try f.run(gid, sink, &w, 0, 0, 0);
    }

    fn run(f: *const Font, gid: u16, sink: anytype, width: *f64, ox: f64, oy: f64, depth: u8) Error!void {
        if (gid >= f.num_glyphs or depth > 2) return error.BadFont;
        const code = f.charstrings.item(f.data, gid) orelse return error.BadFont;
        const fd: usize = if (f.is_cid and gid < f.fd_select.len) f.fd_select[gid] else 0;
        const priv = if (fd < f.privates.len) f.privates[fd] else Private{};
        var st: Interp = .{ .font = f, .priv = priv, .ox = ox, .oy = oy, .depth_glyph = depth };
        st.width = priv.default_width;
        try st.exec(code, sink, 0);
        if (st.open) sink.close();
        width.* = st.width;
    }
};

fn readPrivate(d: []const u8, size: usize, off: usize) Private {
    var p: Private = .{};
    if (off >= d.len) return p;
    const dict = d[off..@min(off + size, d.len)];
    var pos: usize = 0;
    var subrs: usize = 0;
    while (nextDictEntry(dict, &pos)) |e| switch (e.op) {
        19 => if (e.n > 0) {
            subrs = @intFromFloat(@max(e.args[0], 0));
        },
        20 => if (e.n > 0) {
            p.default_width = e.args[0];
        },
        21 => if (e.n > 0) {
            p.nominal_width = e.args[0];
        },
        else => {},
    };
    if (subrs != 0) p.subrs = readIndex(d, off + subrs) catch .{};
    return p;
}

fn readFdSelect(d: []const u8, off: usize, out: []u8) void {
    if (off >= d.len) return;
    switch (d[off]) {
        0 => for (out, 0..) |*o, i| {
            if (off + 1 + i >= d.len) break;
            o.* = d[off + 1 + i];
        },
        3 => {
            const n = u16At(d, off + 1) orelse return;
            var p = off + 3;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const first = u16At(d, p) orelse return;
                if (p + 3 >= d.len) return;
                const fd = d[p + 2];
                const next = u16At(d, p + 3) orelse return;
                var g: usize = first;
                while (g < next and g < out.len) : (g += 1) out[g] = fd;
                p += 3;
            }
        },
        else => {},
    }
}

fn nameToUnicode(name: []const u8) ?u32 {
    if (zpdf.agl.glyphNameToUnicode(name)) |u| return u;
    // "uniXXXX", "uXXXX[XX]" and "name.suffix" forms.
    if (name.len >= 7 and std.mem.startsWith(u8, name, "uni")) return std.fmt.parseInt(u32, name[3..7], 16) catch null;
    if (name.len >= 5 and name[0] == 'u') if (std.fmt.parseInt(u32, name[1..], 16)) |v| return v else |_| {};
    if (std.mem.indexOfScalar(u8, name, '.')) |dot| if (dot > 0) return nameToUnicode(name[0..dot]);
    return null;
}

const NullSink = struct {
    pub fn moveTo(_: *NullSink, _: f64, _: f64) void {}
    pub fn lineTo(_: *NullSink, _: f64, _: f64) void {}
    pub fn curveTo(_: *NullSink, _: f64, _: f64, _: f64, _: f64, _: f64, _: f64) void {}
    pub fn close(_: *NullSink) void {}
};

// ---- the Type 2 charstring interpreter -------------------------------------------------------

fn bias(count: u32) i32 {
    return if (count < 1240) 107 else if (count < 33900) 1131 else 32768;
}

const Interp = struct {
    font: *const Font,
    priv: Private,
    stack: [max_stack]f64 = undefined,
    sp: usize = 0,
    x: f64 = 0,
    y: f64 = 0,
    ox: f64 = 0,
    oy: f64 = 0,
    open: bool = false,
    n_stems: usize = 0,
    width: f64 = 0,
    width_done: bool = false,
    depth_glyph: u8 = 0,
    finished: bool = false,

    fn push(self: *Interp, v: f64) void {
        if (self.sp < self.stack.len) {
            self.stack[self.sp] = v;
            self.sp += 1;
        }
    }

    /// The first stack-clearing operator may carry the width as an extra first argument.
    fn takeWidth(self: *Interp, expected_even_pairs: bool, base_args: usize) void {
        if (self.width_done) return;
        self.width_done = true;
        const extra = if (expected_even_pairs) (self.sp % 2 == 1) else (self.sp > base_args);
        if (extra and self.sp > 0) {
            self.width = self.priv.nominal_width + self.stack[0];
            // Drop the width from the bottom of the stack.
            std.mem.copyForwards(f64, self.stack[0 .. self.sp - 1], self.stack[1..self.sp]);
            self.sp -= 1;
        }
    }

    fn moveTo(self: *Interp, sink: anytype, dx: f64, dy: f64) void {
        if (self.open) sink.close();
        self.x += dx;
        self.y += dy;
        sink.moveTo(self.x + self.ox, self.y + self.oy);
        self.open = true;
    }

    fn lineTo(self: *Interp, sink: anytype, dx: f64, dy: f64) void {
        if (!self.open) {
            sink.moveTo(self.x + self.ox, self.y + self.oy);
            self.open = true;
        }
        self.x += dx;
        self.y += dy;
        sink.lineTo(self.x + self.ox, self.y + self.oy);
    }

    fn curve(self: *Interp, sink: anytype, dx1: f64, dy1: f64, dx2: f64, dy2: f64, dx3: f64, dy3: f64) void {
        if (!self.open) {
            sink.moveTo(self.x + self.ox, self.y + self.oy);
            self.open = true;
        }
        const x1 = self.x + dx1;
        const y1 = self.y + dy1;
        const x2 = x1 + dx2;
        const y2 = y1 + dy2;
        self.x = x2 + dx3;
        self.y = y2 + dy3;
        sink.curveTo(x1 + self.ox, y1 + self.oy, x2 + self.ox, y2 + self.oy, self.x + self.ox, self.y + self.oy);
    }

    fn exec(self: *Interp, code: []const u8, sink: anytype, depth: u8) Error!void {
        if (depth > max_subr_depth) return error.BadFont;
        var i: usize = 0;
        while (i < code.len and !self.finished) {
            const b = code[i];
            i += 1;
            switch (b) {
                28 => {
                    if (i + 2 > code.len) return error.BadFont;
                    self.push(@floatFromInt(@as(i16, @bitCast((@as(u16, code[i]) << 8) | code[i + 1]))));
                    i += 2;
                },
                32...246 => self.push(@floatFromInt(@as(i32, b) - 139)),
                247...250 => {
                    if (i >= code.len) return error.BadFont;
                    self.push(@floatFromInt((@as(i32, b) - 247) * 256 + code[i] + 108));
                    i += 1;
                },
                251...254 => {
                    if (i >= code.len) return error.BadFont;
                    self.push(@floatFromInt(-(@as(i32, b) - 251) * 256 - @as(i32, code[i]) - 108));
                    i += 1;
                },
                255 => {
                    if (i + 4 > code.len) return error.BadFont;
                    const u = (@as(u32, code[i]) << 24) | (@as(u32, code[i + 1]) << 16) | (@as(u32, code[i + 2]) << 8) | code[i + 3];
                    self.push(@as(f64, @floatFromInt(@as(i32, @bitCast(u)))) / 65536.0);
                    i += 4;
                },
                1, 3, 18, 23 => { // hstem, vstem, hstemhm, vstemhm
                    self.takeWidth(true, 0);
                    self.n_stems += self.sp / 2;
                    self.sp = 0;
                },
                19, 20 => { // hintmask, cntrmask: implicit vstem, then the mask bytes
                    self.takeWidth(true, 0);
                    self.n_stems += self.sp / 2;
                    self.sp = 0;
                    i += (self.n_stems + 7) / 8;
                },
                21 => { // rmoveto
                    self.takeWidth(false, 2);
                    if (self.sp >= 2) self.moveTo(sink, self.stack[self.sp - 2], self.stack[self.sp - 1]);
                    self.sp = 0;
                },
                22 => { // hmoveto
                    self.takeWidth(false, 1);
                    if (self.sp >= 1) self.moveTo(sink, self.stack[self.sp - 1], 0);
                    self.sp = 0;
                },
                4 => { // vmoveto
                    self.takeWidth(false, 1);
                    if (self.sp >= 1) self.moveTo(sink, 0, self.stack[self.sp - 1]);
                    self.sp = 0;
                },
                5 => { // rlineto
                    var k: usize = 0;
                    while (k + 2 <= self.sp) : (k += 2) self.lineTo(sink, self.stack[k], self.stack[k + 1]);
                    self.sp = 0;
                },
                6, 7 => { // hlineto, vlineto: alternate
                    var horizontal = b == 6;
                    for (self.stack[0..self.sp]) |v| {
                        if (horizontal) self.lineTo(sink, v, 0) else self.lineTo(sink, 0, v);
                        horizontal = !horizontal;
                    }
                    self.sp = 0;
                },
                8 => { // rrcurveto
                    var k: usize = 0;
                    while (k + 6 <= self.sp) : (k += 6) {
                        const a = self.stack[k..];
                        self.curve(sink, a[0], a[1], a[2], a[3], a[4], a[5]);
                    }
                    self.sp = 0;
                },
                24 => { // rcurveline
                    var k: usize = 0;
                    while (k + 6 <= self.sp -| 2) : (k += 6) {
                        const a = self.stack[k..];
                        self.curve(sink, a[0], a[1], a[2], a[3], a[4], a[5]);
                    }
                    if (k + 2 <= self.sp) self.lineTo(sink, self.stack[k], self.stack[k + 1]);
                    self.sp = 0;
                },
                25 => { // rlinecurve
                    var k: usize = 0;
                    while (k + 2 <= self.sp -| 6) : (k += 2) self.lineTo(sink, self.stack[k], self.stack[k + 1]);
                    if (k + 6 <= self.sp) {
                        const a = self.stack[k..];
                        self.curve(sink, a[0], a[1], a[2], a[3], a[4], a[5]);
                    }
                    self.sp = 0;
                },
                26 => { // vvcurveto
                    var k: usize = 0;
                    var dx1: f64 = 0;
                    if (self.sp % 2 == 1) {
                        dx1 = self.stack[0];
                        k = 1;
                    }
                    while (k + 4 <= self.sp) : (k += 4) {
                        const a = self.stack[k..];
                        self.curve(sink, dx1, a[0], a[1], a[2], 0, a[3]);
                        dx1 = 0;
                    }
                    self.sp = 0;
                },
                27 => { // hhcurveto
                    var k: usize = 0;
                    var dy1: f64 = 0;
                    if (self.sp % 2 == 1) {
                        dy1 = self.stack[0];
                        k = 1;
                    }
                    while (k + 4 <= self.sp) : (k += 4) {
                        const a = self.stack[k..];
                        self.curve(sink, a[0], dy1, a[1], a[2], a[3], 0);
                        dy1 = 0;
                    }
                    self.sp = 0;
                },
                30, 31 => { // vhcurveto, hvcurveto: alternate, the last curve may have an extra argument
                    var horizontal = b == 31;
                    var k: usize = 0;
                    while (k + 4 <= self.sp) : (k += 4) {
                        const a = self.stack[k..];
                        const last = self.sp - k == 5;
                        const extra: f64 = if (last) a[4] else 0;
                        if (horizontal) {
                            self.curve(sink, a[0], 0, a[1], a[2], extra, a[3]);
                        } else {
                            self.curve(sink, 0, a[0], a[1], a[2], a[3], extra);
                        }
                        horizontal = !horizontal;
                    }
                    self.sp = 0;
                },
                10, 29 => { // callsubr, callgsubr
                    if (self.sp == 0) return error.BadFont;
                    self.sp -= 1;
                    const idx = if (b == 10) self.priv.subrs else self.font.global_subrs;
                    const n = @as(i64, @intFromFloat(self.stack[self.sp])) + bias(idx.count);
                    if (n < 0) return error.BadFont;
                    const sub = idx.item(self.font.data, @intCast(n)) orelse return error.BadFont;
                    try self.exec(sub, sink, depth + 1);
                },
                11 => return, // return
                14 => { // endchar, possibly with the accent composition (seac)
                    self.takeWidth(false, 0);
                    if (self.sp >= 4 and !self.font.is_cid) self.seac(sink);
                    self.finished = true;
                    self.sp = 0;
                    return;
                },
                12 => {
                    if (i >= code.len) return error.BadFont;
                    const b2 = code[i];
                    i += 1;
                    try self.escape(b2, sink);
                },
                else => self.sp = 0, // reserved operators clear the stack
            }
        }
    }

    fn seac(self: *Interp, sink: anytype) void {
        const a = self.stack[self.sp - 4 .. self.sp];
        const adx = a[0];
        const ady = a[1];
        const bchar: usize = @intFromFloat(std.math.clamp(a[2], 0, 255));
        const achar: usize = @intFromFloat(std.math.clamp(a[3], 0, 255));
        if (self.open) {
            sink.close();
            self.open = false;
        }
        const f = self.font;
        var w: f64 = 0;
        for ([_]struct { c: usize, dx: f64, dy: f64 }{ .{ .c = bchar, .dx = 0, .dy = 0 }, .{ .c = achar, .dx = adx, .dy = ady } }) |part| {
            const cp = zpdf.encoding.standard_encoding[part.c];
            const gid = f.unicode.get(cp) orelse continue;
            f.run(gid, sink, &w, self.ox + part.dx, self.oy + part.dy, self.depth_glyph + 1) catch {};
        }
    }

    fn escape(self: *Interp, op: u8, sink: anytype) Error!void {
        const s = &self.stack;
        switch (op) {
            34 => { // hflex
                if (self.sp >= 7) {
                    self.curve(sink, s[0], 0, s[1], s[2], s[3], 0);
                    self.curve(sink, s[4], 0, s[5], -s[2], s[6], 0);
                }
                self.sp = 0;
            },
            35 => { // flex
                if (self.sp >= 12) {
                    self.curve(sink, s[0], s[1], s[2], s[3], s[4], s[5]);
                    self.curve(sink, s[6], s[7], s[8], s[9], s[10], s[11]);
                }
                self.sp = 0;
            },
            36 => { // hflex1
                if (self.sp >= 9) {
                    self.curve(sink, s[0], s[1], s[2], s[3], s[4], 0);
                    self.curve(sink, s[5], 0, s[6], s[7], s[8], -(s[1] + s[3] + s[7]));
                }
                self.sp = 0;
            },
            37 => { // flex1
                if (self.sp >= 11) {
                    const dx = s[0] + s[2] + s[4] + s[6] + s[8];
                    const dy = s[1] + s[3] + s[5] + s[7] + s[9];
                    self.curve(sink, s[0], s[1], s[2], s[3], s[4], s[5]);
                    if (@abs(dx) > @abs(dy)) {
                        self.curve(sink, s[6], s[7], s[8], s[9], s[10], -dy);
                    } else {
                        self.curve(sink, s[6], s[7], s[8], s[9], -dx, s[10]);
                    }
                }
                self.sp = 0;
            },
            // Arithmetic, rare in real fonts but cheap.
            9 => if (self.sp >= 1) {
                s[self.sp - 1] = @abs(s[self.sp - 1]);
            },
            10 => if (self.sp >= 2) {
                s[self.sp - 2] += s[self.sp - 1];
                self.sp -= 1;
            },
            11 => if (self.sp >= 2) {
                s[self.sp - 2] -= s[self.sp - 1];
                self.sp -= 1;
            },
            12 => if (self.sp >= 2) {
                s[self.sp - 2] = if (s[self.sp - 1] != 0) s[self.sp - 2] / s[self.sp - 1] else 0;
                self.sp -= 1;
            },
            14 => if (self.sp >= 1) {
                s[self.sp - 1] = -s[self.sp - 1];
            },
            18 => if (self.sp >= 1) {
                self.sp -= 1;
            },
            24 => if (self.sp >= 2) {
                s[self.sp - 2] *= s[self.sp - 1];
                self.sp -= 1;
            },
            26 => if (self.sp >= 1) {
                s[self.sp - 1] = @sqrt(@max(s[self.sp - 1], 0));
            },
            27 => if (self.sp >= 1 and self.sp < max_stack) {
                s[self.sp] = s[self.sp - 1];
                self.sp += 1;
            },
            28 => if (self.sp >= 2) {
                std.mem.swap(f64, &s[self.sp - 1], &s[self.sp - 2]);
            },
            else => self.sp = 0,
        }
    }
};

// ---- tests -----------------------------------------------------------------------------------

const Recorder = struct {
    moves: usize = 0,
    lines: usize = 0,
    curves: usize = 0,
    closes: usize = 0,
    min_x: f64 = 1e9,
    max_x: f64 = -1e9,
    max_y: f64 = -1e9,

    pub fn moveTo(self: *Recorder, x: f64, y: f64) void {
        self.moves += 1;
        self.track(x, y);
    }
    pub fn lineTo(self: *Recorder, x: f64, y: f64) void {
        self.lines += 1;
        self.track(x, y);
    }
    pub fn curveTo(self: *Recorder, _: f64, _: f64, _: f64, _: f64, x: f64, y: f64) void {
        self.curves += 1;
        self.track(x, y);
    }
    pub fn close(self: *Recorder) void {
        self.closes += 1;
    }
    fn track(self: *Recorder, x: f64, y: f64) void {
        self.min_x = @min(self.min_x, x);
        self.max_x = @max(self.max_x, x);
        self.max_y = @max(self.max_y, y);
    }
};

test "garbage is rejected, not trusted" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.BadFont, Font.parse(a, "short"));
    try std.testing.expectError(error.BadFont, Font.parse(a, "\x01\x00\x04\x01\x00\x00\x00\x00\x00\x00\x00\x00"));
}

test "DICT numbers" {
    // 139 -> 0, 247 0 -> 108, 251 0 -> -108, 28 0x01 0x00 -> 256
    const bytes = [_]u8{ 139, 247, 0, 251, 0, 28, 1, 0, 17 };
    var pos: usize = 0;
    const e = nextDictEntry(&bytes, &pos).?;
    try std.testing.expectEqual(@as(u16, 17), e.op);
    try std.testing.expectEqual(@as(usize, 4), e.n);
    try std.testing.expectEqual(@as(f64, 0), e.args[0]);
    try std.testing.expectEqual(@as(f64, 108), e.args[1]);
    try std.testing.expectEqual(@as(f64, -108), e.args[2]);
    try std.testing.expectEqual(@as(f64, 256), e.args[3]);
}

test "a charstring draws a square" {
    // 100 100 rmoveto, 200 hlineto, 200 vlineto, -200 hlineto, endchar
    const code = [_]u8{ 139 + 100, 139 + 100, 21 } ++ [_]u8{ 247, 92, 6 };
    _ = code;
    // Built by hand with 28 (shortint) for values over 107: 100 100 rmoveto 200 -200?...
    const cs = [_]u8{
        28, 0, 100, 28, 0, 100, 21, // 100 100 rmoveto
        28, 0, 200, 6, // 200 hlineto
        28, 0, 200, 7, // 200 vlineto
        28, 255, 56, 6, // -200 hlineto
        14, // endchar
    };
    var f: Font = .{ .data = &cs };
    var st: Interp = .{ .font = &f, .priv = .{} };
    var rec: Recorder = .{};
    try st.exec(&cs, &rec, 0);
    if (st.open) rec.close();
    try std.testing.expectEqual(@as(usize, 1), rec.moves);
    try std.testing.expectEqual(@as(usize, 3), rec.lines);
    try std.testing.expectEqual(@as(usize, 1), rec.closes);
    try std.testing.expectEqual(@as(f64, 100), rec.min_x);
    try std.testing.expectEqual(@as(f64, 300), rec.max_x);
}

extern fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern fn fread(buf: [*]u8, size: usize, n: usize, f: *anyopaque) usize;
extern fn fclose(f: *anyopaque) c_int;

/// The CFF table of an OpenType file (the one the renderer would be handed).
pub fn tableOfSfnt(d: []const u8) ?[]const u8 {
    if (d.len < 12) return null;
    const n = u16At(d, 4) orelse return null;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const rec = 12 + i * 16;
        if (rec + 16 > d.len) return null;
        if (std.mem.eql(u8, d[rec .. rec + 4], "CFF ")) {
            const off = (@as(usize, d[rec + 8]) << 24) | (@as(usize, d[rec + 9]) << 16) | (@as(usize, d[rec + 10]) << 8) | d[rec + 11];
            const len = (@as(usize, d[rec + 12]) << 24) | (@as(usize, d[rec + 13]) << 16) | (@as(usize, d[rec + 14]) << 8) | d[rec + 15];
            if (off > d.len or off + len > d.len) return null;
            return d[off .. off + len];
        }
    }
    return null;
}

fn loadFile(a: std.mem.Allocator, path: [*:0]const u8) !?[]u8 {
    const f = fopen(path, "rb") orelse return null;
    defer _ = fclose(f);
    const buf = try a.alloc(u8, 40 << 20);
    defer a.free(buf);
    const n = fread(buf.ptr, 1, buf.len, f);
    return try a.dupe(u8, buf[0..n]);
}

test "a real CID-keyed OpenType font draws glyphs" {
    const a = std.testing.allocator;
    const path = "/home/dakota/git/LiberNT/media/fonts/NotoSansSC-Regular.otf";
    const bytes = (try loadFile(a, path)) orelse return error.SkipZigTest;
    defer a.free(bytes);
    const table = tableOfSfnt(bytes) orelse return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const f = try Font.parse(arena.allocator(), table);
    try std.testing.expect(f.is_cid);
    try std.testing.expectEqual(@as(u16, 1000), f.units_per_em);
    const gid = f.glyphForCid(1) orelse return error.TestUnexpectedResult; // CID 1 is usually space or A
    _ = gid;
    var drew: usize = 0;
    var cid: u32 = 1;
    while (cid < 400) : (cid += 1) {
        const g = f.glyphForCid(cid) orelse continue;
        var rec: Recorder = .{};
        try f.outline(g, &rec);
        if (rec.moves > 0) drew += 1;
        try std.testing.expect(rec.curves + rec.lines > 0 or rec.moves == 0);
    }
    try std.testing.expect(drew > 100);
}
