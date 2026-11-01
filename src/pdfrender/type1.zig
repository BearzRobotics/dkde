//! Type 1 fonts (PDF /FontFile): the PostScript font program with its
//! eexec-encrypted private section, the encrypted charstrings and subroutines,
//! and the Type 1 charstring interpreter. Same shape as cff.zig: the bytes are
//! borrowed or copied into the caller's arena, every read is bounds checked,
//! and a damaged font returns an error.

const std = @import("std");
const zpdf = @import("zpdf");

pub const Error = error{ BadFont, OutOfMemory };

const max_subr_depth = 12;
const max_stack = 64;

const Glyph = struct { name: []const u8, code: []const u8 };

pub const Font = struct {
    glyphs: []const Glyph = &.{},
    subrs: []const []const u8 = &.{},
    units_per_em: u16 = 1000,
    /// The font's own character code to glyph id table.
    encoding: [256]u16 = @splat(0),
    unicode: std.AutoHashMapUnmanaged(u32, u16) = .empty,
    by_name: std.StringHashMapUnmanaged(u16) = .empty,
    num_glyphs: u16 = 0,

    pub fn parse(a: std.mem.Allocator, data0: []const u8) Error!Font {
        const data = try unwrapPfb(a, data0);
        const eexec = std.mem.indexOf(u8, data, "eexec") orelse return error.BadFont;
        const clear = data[0..eexec];

        var f: Font = .{};
        if (findNumberAfter(clear, "/FontMatrix[")) |m| {
            if (m > 0) f.units_per_em = @intFromFloat(std.math.clamp(@round(1.0 / m), 16, 16384));
        } else if (findNumberAfter(clear, "/FontMatrix [")) |m| {
            if (m > 0) f.units_per_em = @intFromFloat(std.math.clamp(@round(1.0 / m), 16, 16384));
        }

        // The encrypted part: binary or ASCII hex, after "eexec" and one whitespace.
        var p = eexec + 5;
        while (p < data.len and (data[p] == ' ' or data[p] == '\t' or data[p] == '\r' or data[p] == '\n')) p += 1;
        if (p + 4 >= data.len) return error.BadFont;
        const private = try decryptEexec(a, data[p..]);

        const len_iv: usize = if (findNumberAfter(private, "/lenIV")) |v| @intFromFloat(std.math.clamp(v, 0, 16)) else 4;
        f.subrs = try readSubrs(a, private, len_iv);
        f.glyphs = try readCharStrings(a, private, len_iv);
        if (f.glyphs.len == 0) return error.BadFont;
        f.num_glyphs = @intCast(@min(f.glyphs.len, 65535));

        for (f.glyphs, 0..) |g, i| {
            const gid: u16 = @intCast(i);
            try f.by_name.put(a, g.name, gid);
            if (nameToUnicode(g.name)) |cp| {
                const r = try f.unicode.getOrPut(a, cp);
                if (!r.found_existing) r.value_ptr.* = gid;
            }
        }
        f.readEncoding(clear);
        return f;
    }

    fn readEncoding(f: *Font, clear: []const u8) void {
        const at = std.mem.indexOf(u8, clear, "/Encoding") orelse return;
        var pos = at + "/Encoding".len;
        const rest = clear[pos..];
        // "StandardEncoding def": the standard names for the codes.
        if (std.mem.indexOf(u8, rest[0..@min(rest.len, 40)], "StandardEncoding") != null) {
            for (zpdf.encoding.standard_encoding, 0..) |cp, code| {
                if (code > 255 or cp == 0) continue;
                if (f.unicode.get(cp)) |g| f.encoding[code] = g;
            }
            return;
        }
        // "dup 65 /A put" lines up to the closing "def".
        var tz = Tokens{ .d = clear, .pos = pos };
        while (tz.next()) |t| {
            if (std.mem.eql(u8, t, "def") or std.mem.eql(u8, t, "readonly")) break;
            if (!std.mem.eql(u8, t, "dup")) continue;
            const code_tok = tz.next() orelse break;
            const name_tok = tz.next() orelse break;
            const code = std.fmt.parseInt(usize, code_tok, 10) catch continue;
            if (code > 255 or name_tok.len < 2 or name_tok[0] != '/') continue;
            if (f.by_name.get(name_tok[1..])) |g| f.encoding[code] = g;
        }
        pos = 0;
    }

    pub fn glyphForUnicode(f: *const Font, cp: u32) ?u16 {
        return f.unicode.get(cp);
    }

    pub fn glyphForCode(f: *const Font, code: u32) ?u16 {
        if (code > 255) return null;
        const g = f.encoding[code];
        return if (g == 0) null else g;
    }

    pub fn advance(f: *const Font, gid: u16) u16 {
        var sink: NullSink = .{};
        var w: f64 = 0;
        f.run(gid, &sink, &w, 0, 0, 0) catch return 0;
        return @intFromFloat(std.math.clamp(@round(w), 0, 65535));
    }

    pub fn outline(f: *const Font, gid: u16, sink: anytype) Error!void {
        var w: f64 = 0;
        try f.run(gid, sink, &w, 0, 0, 0);
    }

    fn run(f: *const Font, gid: u16, sink: anytype, width: *f64, ox: f64, oy: f64, depth: u8) Error!void {
        if (gid >= f.glyphs.len or depth > 2) return error.BadFont;
        var st: Interp = .{ .font = f, .ox = ox, .oy = oy, .glyph_depth = depth };
        try st.exec(f.glyphs[gid].code, sink, 0);
        if (st.open) sink.close();
        width.* = st.width;
    }
};

const NullSink = struct {
    pub fn moveTo(_: *NullSink, _: f64, _: f64) void {}
    pub fn lineTo(_: *NullSink, _: f64, _: f64) void {}
    pub fn curveTo(_: *NullSink, _: f64, _: f64, _: f64, _: f64, _: f64, _: f64) void {}
    pub fn close(_: *NullSink) void {}
};

// ---- text and encryption ---------------------------------------------------------------------

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == 0x0c or c == 0;
}

fn isDelim(c: u8) bool {
    return switch (c) {
        '(', ')', '<', '>', '[', ']', '{', '}', '/', '%' => true,
        else => false,
    };
}

/// A whitespace-separated token reader for the PostScript text.
const Tokens = struct {
    d: []const u8,
    pos: usize = 0,

    fn next(self: *Tokens) ?[]const u8 {
        while (self.pos < self.d.len and isSpace(self.d[self.pos])) self.pos += 1;
        if (self.pos >= self.d.len) return null;
        const start = self.pos;
        const c = self.d[self.pos];
        self.pos += 1;
        if (c == '/') { // a name
            while (self.pos < self.d.len and !isSpace(self.d[self.pos]) and !isDelim(self.d[self.pos])) self.pos += 1;
        } else if (isDelim(c)) {
            // a single delimiter is a token
        } else {
            while (self.pos < self.d.len and !isSpace(self.d[self.pos]) and !isDelim(self.d[self.pos])) self.pos += 1;
        }
        return self.d[start..self.pos];
    }
};

fn findNumberAfter(d: []const u8, key: []const u8) ?f64 {
    const at = std.mem.indexOf(u8, d, key) orelse return null;
    var i = at + key.len;
    while (i < d.len and (isSpace(d[i]) or d[i] == '[' or d[i] == '{')) i += 1;
    var j = i;
    while (j < d.len and (std.ascii.isDigit(d[j]) or d[j] == '.' or d[j] == '-' or d[j] == '+' or d[j] == 'e' or d[j] == 'E')) j += 1;
    if (j == i) return null;
    return std.fmt.parseFloat(f64, d[i..j]) catch null;
}

fn decrypt(a: std.mem.Allocator, src: []const u8, r0: u16, skip: usize) Error![]u8 {
    const out = try a.alloc(u8, src.len);
    var r: u16 = r0;
    for (src, 0..) |c, i| {
        out[i] = c ^ @as(u8, @truncate(r >> 8));
        r = (@as(u16, c) +% r) *% 52845 +% 22719;
    }
    if (skip > out.len) return out[0..0];
    return out[skip..];
}

fn decryptEexec(a: std.mem.Allocator, src: []const u8) Error![]u8 {
    // ASCII hex form: the first four bytes are all hex digits.
    var hex = true;
    for (src[0..4]) |c| if (!std.ascii.isHex(c)) {
        hex = false;
    };
    if (!hex) return decrypt(a, src, 55665, 4);
    var bin: std.ArrayList(u8) = .empty;
    var hi: ?u8 = null;
    for (src) |c| {
        const v: u8 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => continue,
        };
        if (hi) |h| {
            try bin.append(a, (h << 4) | v);
            hi = null;
        } else hi = v;
    }
    return decrypt(a, bin.items, 55665, 4);
}

/// Removes PFB segment headers (0x80 type length) when the file has them.
fn unwrapPfb(a: std.mem.Allocator, d: []const u8) Error![]const u8 {
    if (d.len < 6 or d[0] != 0x80) return d;
    var out: std.ArrayList(u8) = .empty;
    var p: usize = 0;
    while (p + 6 <= d.len and d[p] == 0x80) {
        const kind = d[p + 1];
        if (kind == 3) break;
        const len = @as(usize, d[p + 2]) | (@as(usize, d[p + 3]) << 8) | (@as(usize, d[p + 4]) << 16) | (@as(usize, d[p + 5]) << 24);
        p += 6;
        if (p + len > d.len) break;
        try out.appendSlice(a, d[p .. p + len]);
        p += len;
    }
    return out.toOwnedSlice(a);
}

/// Reads "<len> RD <len bytes>" after the tokens already consumed; returns the
/// decrypted charstring and moves `tz` past it.
fn readBinary(a: std.mem.Allocator, tz: *Tokens, len_tok: []const u8, len_iv: usize) ?[]u8 {
    const len = std.fmt.parseInt(usize, len_tok, 10) catch return null;
    _ = tz.next() orelse return null; // RD or -|
    const start = tz.pos + 1; // exactly one space
    if (start + len > tz.d.len) return null;
    const bytes = tz.d[start .. start + len];
    tz.pos = start + len;
    return decrypt(a, bytes, 4330, len_iv) catch null;
}

fn readSubrs(a: std.mem.Allocator, d: []const u8, len_iv: usize) Error![]const []const u8 {
    const at = std.mem.indexOf(u8, d, "/Subrs") orelse return &.{};
    var tz = Tokens{ .d = d, .pos = at + "/Subrs".len };
    const count_tok = tz.next() orelse return &.{};
    const count = std.fmt.parseInt(usize, count_tok, 10) catch return &.{};
    if (count > 65535) return error.BadFont;
    const subrs = try a.alloc([]const u8, count);
    @memset(subrs, "");
    while (tz.next()) |t| {
        if (std.mem.eql(u8, t, "/CharStrings")) break;
        if (!std.mem.eql(u8, t, "dup")) continue;
        const idx_tok = tz.next() orelse break;
        const len_tok = tz.next() orelse break;
        const idx = std.fmt.parseInt(usize, idx_tok, 10) catch continue;
        const code = readBinary(a, &tz, len_tok, len_iv) orelse break;
        if (idx < subrs.len) subrs[idx] = code;
    }
    return subrs;
}

fn readCharStrings(a: std.mem.Allocator, d: []const u8, len_iv: usize) Error![]const Glyph {
    const at = std.mem.indexOf(u8, d, "/CharStrings") orelse return error.BadFont;
    var tz = Tokens{ .d = d, .pos = at + "/CharStrings".len };
    var list: std.ArrayList(Glyph) = .empty;
    // "/CharStrings 229 dict dup begin" then "/name len RD ... ND" until "end".
    while (tz.next()) |t| {
        if (t[0] == '/') {
            const len_tok = tz.next() orelse break;
            const code = readBinary(a, &tz, len_tok, len_iv) orelse continue;
            try list.append(a, .{ .name = t[1..], .code = code });
            if (list.items.len >= 65535) break;
        } else if (std.mem.eql(u8, t, "end") and list.items.len > 0) break;
    }
    return list.toOwnedSlice(a);
}

fn nameToUnicode(name: []const u8) ?u32 {
    if (zpdf.agl.glyphNameToUnicode(name)) |u| return u;
    if (name.len >= 7 and std.mem.startsWith(u8, name, "uni")) return std.fmt.parseInt(u32, name[3..7], 16) catch null;
    if (std.mem.indexOfScalar(u8, name, '.')) |dot| if (dot > 0) return nameToUnicode(name[0..dot]);
    return null;
}

// ---- the Type 1 charstring interpreter -------------------------------------------------------

const Interp = struct {
    font: *const Font,
    stack: [max_stack]f64 = undefined,
    sp: usize = 0,
    /// The PostScript stack that callothersubr and pop pass values through.
    ps: [8]f64 = undefined,
    ps_n: usize = 0,
    x: f64 = 0,
    y: f64 = 0,
    ox: f64 = 0,
    oy: f64 = 0,
    sbx: f64 = 0,
    width: f64 = 0,
    open: bool = false,
    flex: bool = false,
    flex_pts: [7][2]f64 = undefined,
    flex_n: usize = 0,
    finished: bool = false,
    glyph_depth: u8 = 0,

    fn push(self: *Interp, v: f64) void {
        if (self.sp < self.stack.len) {
            self.stack[self.sp] = v;
            self.sp += 1;
        }
    }

    fn pop(self: *Interp) f64 {
        if (self.sp == 0) return 0;
        self.sp -= 1;
        return self.stack[self.sp];
    }

    fn moveBy(self: *Interp, sink: anytype, dx: f64, dy: f64) void {
        self.x += dx;
        self.y += dy;
        if (self.flex) {
            // Inside a flex the moves are the curve's points, not new contours.
            if (self.flex_n < self.flex_pts.len) {
                self.flex_pts[self.flex_n] = .{ self.x, self.y };
                self.flex_n += 1;
            }
            return;
        }
        if (self.open) {
            sink.close();
            self.open = false;
        }
    }

    fn ensureOpen(self: *Interp, sink: anytype) void {
        if (!self.open) {
            sink.moveTo(self.x + self.ox, self.y + self.oy);
            self.open = true;
        }
    }

    fn lineBy(self: *Interp, sink: anytype, dx: f64, dy: f64) void {
        self.ensureOpen(sink);
        self.x += dx;
        self.y += dy;
        sink.lineTo(self.x + self.ox, self.y + self.oy);
    }

    fn curveBy(self: *Interp, sink: anytype, dx1: f64, dy1: f64, dx2: f64, dy2: f64, dx3: f64, dy3: f64) void {
        self.ensureOpen(sink);
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
                    self.push(@floatFromInt(@as(i32, @bitCast(u))));
                    i += 4;
                },
                13 => { // hsbw
                    if (self.sp >= 2) {
                        self.sbx = self.stack[self.sp - 2];
                        self.width = self.stack[self.sp - 1];
                        self.x = self.sbx;
                        self.y = 0;
                    }
                    self.sp = 0;
                },
                1, 3 => self.sp = 0, // hstem, vstem
                21 => { // rmoveto
                    if (self.sp >= 2) self.moveBy(sink, self.stack[self.sp - 2], self.stack[self.sp - 1]);
                    self.sp = 0;
                },
                22 => { // hmoveto
                    if (self.sp >= 1) self.moveBy(sink, self.stack[self.sp - 1], 0);
                    self.sp = 0;
                },
                4 => { // vmoveto
                    if (self.sp >= 1) self.moveBy(sink, 0, self.stack[self.sp - 1]);
                    self.sp = 0;
                },
                5 => { // rlineto
                    if (self.sp >= 2) self.lineBy(sink, self.stack[self.sp - 2], self.stack[self.sp - 1]);
                    self.sp = 0;
                },
                6 => { // hlineto
                    if (self.sp >= 1) self.lineBy(sink, self.stack[self.sp - 1], 0);
                    self.sp = 0;
                },
                7 => { // vlineto
                    if (self.sp >= 1) self.lineBy(sink, 0, self.stack[self.sp - 1]);
                    self.sp = 0;
                },
                8 => { // rrcurveto
                    if (self.sp >= 6) {
                        const a = self.stack[self.sp - 6 .. self.sp];
                        self.curveBy(sink, a[0], a[1], a[2], a[3], a[4], a[5]);
                    }
                    self.sp = 0;
                },
                30 => { // vhcurveto
                    if (self.sp >= 4) {
                        const a = self.stack[self.sp - 4 .. self.sp];
                        self.curveBy(sink, 0, a[0], a[1], a[2], a[3], 0);
                    }
                    self.sp = 0;
                },
                31 => { // hvcurveto
                    if (self.sp >= 4) {
                        const a = self.stack[self.sp - 4 .. self.sp];
                        self.curveBy(sink, a[0], 0, a[1], a[2], 0, a[3]);
                    }
                    self.sp = 0;
                },
                9 => { // closepath: the current point stays
                    if (self.open) {
                        sink.close();
                        self.open = false;
                    }
                    self.sp = 0;
                },
                10 => { // callsubr
                    const n = self.pop();
                    if (n < 0 or n >= @as(f64, @floatFromInt(self.font.subrs.len))) return error.BadFont;
                    try self.exec(self.font.subrs[@intFromFloat(n)], sink, depth + 1);
                },
                11 => return,
                14 => { // endchar
                    self.finished = true;
                    return;
                },
                12 => {
                    if (i >= code.len) return error.BadFont;
                    const b2 = code[i];
                    i += 1;
                    try self.escape(b2, sink);
                },
                else => self.sp = 0,
            }
        }
    }

    fn escape(self: *Interp, op: u8, sink: anytype) Error!void {
        switch (op) {
            0, 1, 2 => self.sp = 0, // dotsection, vstem3, hstem3
            6 => { // seac: asb adx ady bchar achar
                if (self.sp >= 5) {
                    const a = self.stack[self.sp - 5 .. self.sp];
                    const asb = a[0];
                    const adx = a[1];
                    const ady = a[2];
                    const bchar: usize = @intFromFloat(std.math.clamp(a[3], 0, 255));
                    const achar: usize = @intFromFloat(std.math.clamp(a[4], 0, 255));
                    if (self.open) {
                        sink.close();
                        self.open = false;
                    }
                    const f = self.font;
                    var w: f64 = 0;
                    const parts = [_]struct { c: usize, dx: f64, dy: f64 }{
                        .{ .c = bchar, .dx = 0, .dy = 0 },
                        .{ .c = achar, .dx = self.sbx - asb + adx, .dy = ady },
                    };
                    for (parts) |part| {
                        const cp = zpdf.encoding.standard_encoding[part.c];
                        const gid = f.unicode.get(cp) orelse continue;
                        f.run(gid, sink, &w, self.ox + part.dx, self.oy + part.dy, self.glyph_depth + 1) catch {};
                    }
                }
                self.finished = true;
                self.sp = 0;
            },
            7 => { // sbw: sbx sby wx wy
                if (self.sp >= 4) {
                    self.sbx = self.stack[self.sp - 4];
                    self.width = self.stack[self.sp - 2];
                    self.x = self.sbx;
                    self.y = self.stack[self.sp - 3];
                }
                self.sp = 0;
            },
            12 => { // div
                const b = self.pop();
                const a = self.pop();
                self.push(if (b != 0) a / b else 0);
            },
            16 => { // callothersubr: arg1 ... argn n othersubr#
                const n_which = self.pop();
                const n_args_f = self.pop();
                const which: i32 = @intFromFloat(n_which);
                const n_args: usize = @intFromFloat(std.math.clamp(n_args_f, 0, 8));
                switch (which) {
                    1 => { // start flex
                        self.flex = true;
                        self.flex_n = 0;
                    },
                    2 => {}, // a flex point: recorded by the rmoveto before it
                    0 => { // end flex: height, x, y; then the two curves
                        if (self.flex_n >= 7) {
                            const p = self.flex_pts;
                            self.flex = false;
                            self.ensureOpenAt(sink, p[0][0], p[0][1]);
                            sink.curveTo(p[1][0] + self.ox, p[1][1] + self.oy, p[2][0] + self.ox, p[2][1] + self.oy, p[3][0] + self.ox, p[3][1] + self.oy);
                            sink.curveTo(p[4][0] + self.ox, p[4][1] + self.oy, p[5][0] + self.ox, p[5][1] + self.oy, p[6][0] + self.ox, p[6][1] + self.oy);
                            self.x = p[6][0];
                            self.y = p[6][1];
                        }
                        self.flex = false;
                    },
                    else => {},
                }
                // Whatever the othersubr is, its arguments come back through pop, last first.
                self.ps_n = 0;
                var k: usize = 0;
                while (k < n_args and self.sp > 0) : (k += 1) {
                    if (self.ps_n < self.ps.len) {
                        self.ps[self.ps_n] = self.pop();
                        self.ps_n += 1;
                    } else _ = self.pop();
                }
                // For end-flex the results are the final point, in x y order after popping.
                if (which == 0 and self.ps_n >= 3) {
                    // ps holds y, x, height (top first): pop yields x first, then y.
                    const y = self.ps[0];
                    const x = self.ps[1];
                    self.ps[0] = y;
                    self.ps[1] = x;
                    self.ps_n = 2;
                }
            },
            17 => { // pop: from the PostScript stack onto the charstring stack
                if (self.ps_n > 0) {
                    self.ps_n -= 1;
                    self.push(self.ps[self.ps_n]);
                } else self.push(0);
            },
            33 => { // setcurrentpoint
                if (self.sp >= 2) {
                    self.x = self.stack[self.sp - 2];
                    self.y = self.stack[self.sp - 1];
                }
                self.sp = 0;
            },
            else => self.sp = 0,
        }
    }

    fn ensureOpenAt(self: *Interp, sink: anytype, x: f64, y: f64) void {
        if (!self.open) {
            sink.moveTo(x + self.ox, y + self.oy);
            self.open = true;
        }
    }
};

// ---- tests -----------------------------------------------------------------------------------

const Recorder = struct {
    moves: usize = 0,
    lines: usize = 0,
    curves: usize = 0,
    closes: usize = 0,

    pub fn moveTo(self: *Recorder, _: f64, _: f64) void {
        self.moves += 1;
    }
    pub fn lineTo(self: *Recorder, _: f64, _: f64) void {
        self.lines += 1;
    }
    pub fn curveTo(self: *Recorder, _: f64, _: f64, _: f64, _: f64, _: f64, _: f64) void {
        self.curves += 1;
    }
    pub fn close(self: *Recorder) void {
        self.closes += 1;
    }
};

test "garbage is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.BadFont, Font.parse(arena.allocator(), "not a font"));
    try std.testing.expectError(error.BadFont, Font.parse(arena.allocator(), "%!PS-AdobeFont-1.0\ncurrentfile eexec\nabcd"));
}

test "eexec encryption round trips" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Encrypt "hello" with four leading bytes, then decrypt.
    const plain = "XXXXhello";
    var enc: [plain.len]u8 = undefined;
    var r: u16 = 55665;
    for (plain, 0..) |p, i| {
        const c = p ^ @as(u8, @truncate(r >> 8));
        enc[i] = c;
        r = (@as(u16, c) +% r) *% 52845 +% 22719;
    }
    // A leading non-hex byte forces the binary form.
    enc[0] |= 0x80;
    var back: [plain.len]u8 = undefined;
    @memcpy(&back, &enc);
    const out = try decryptEexec(a, &back);
    try std.testing.expectEqualStrings("hello", out);
}

extern fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern fn fread(buf: [*]u8, size: usize, n: usize, f: *anyopaque) usize;
extern fn fclose(f: *anyopaque) c_int;

fn loadFile(a: std.mem.Allocator, path: [*:0]const u8) !?[]u8 {
    const f = fopen(path, "rb") orelse return null;
    defer _ = fclose(f);
    const buf = try a.alloc(u8, 8 << 20);
    defer a.free(buf);
    const n = fread(buf.ptr, 1, buf.len, f);
    return try a.dupe(u8, buf[0..n]);
}

test "a real Type 1 font draws glyphs" {
    const a = std.testing.allocator;
    const bytes = (try loadFile(a, "/mnt/wslg/distro/usr/share/fonts/type1/urw-base35/NimbusRoman-Italic.t1")) orelse return error.SkipZigTest;
    defer a.free(bytes);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const f = try Font.parse(arena.allocator(), bytes);
    try std.testing.expect(f.num_glyphs > 200);
    try std.testing.expectEqual(@as(u16, 1000), f.units_per_em);
    const gid = f.glyphForUnicode('A') orelse return error.TestUnexpectedResult;
    var rec: Recorder = .{};
    try f.outline(gid, &rec);
    try std.testing.expect(rec.moves >= 1 and rec.lines + rec.curves >= 3);
    try std.testing.expect(f.advance(gid) > 300);
    // 'eacute' is built with seac in many Type 1 fonts.
    if (f.glyphForUnicode(0xE9)) |g| {
        var r2: Recorder = .{};
        try f.outline(g, &r2);
        try std.testing.expect(r2.moves >= 2);
    }
    // The built-in encoding knows 'A' at 65.
    try std.testing.expectEqual(@as(?u16, gid), f.glyphForCode('A'));
}
