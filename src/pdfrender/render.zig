//! Draws a PDF page with cairo, using the vendored zpdf parser
//! (third_party/zpdf) to read the file and tokenise content streams.
//!
//! What it draws so far: filled, stroked and clipped paths, colours (gray,
//! RGB, CMYK), line styles, and text from simple fonts. Text is drawn with a
//! system font of the same family and style (the embedded font program is not
//! read yet), advancing by the widths the PDF gives. Not yet: images, shading,
//! patterns, transparency, embedded font outlines, page rotation.

const std = @import("std");
const cairo = @import("cairo1");
const zpdf = @import("zpdf");
const image = @import("image.zig");
pub const Diag = @import("diag.zig").Diag;

extern fn stbi_load_from_memory(buffer: [*]const u8, len: c_int, x: *c_int, y: *c_int, comp: *c_int, req_comp: c_int) ?[*]u8;
extern fn stbi_image_free(data: *anyopaque) void;

const Object = zpdf.Object;
const Operand = zpdf.interpreter.Operand;
const Lexer = zpdf.interpreter.ContentLexer;

pub const Error = error{ NoSuchPage, OutOfMemory };

const Rgb = [3]f64;

fn has(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

const Family = enum { sans, serif, mono };

const Font = struct {
    family: Family = .sans,
    bold: bool = false,
    italic: bool = false,
    first_char: i64 = 0,
    widths: []const f64 = &.{},
    missing_width: f64 = 500,

    fn width(self: Font, code: u8) f64 {
        const i = @as(i64, code) - self.first_char;
        if (i >= 0 and i < self.widths.len) return self.widths[@intCast(i)];
        return self.missing_width;
    }
};

const State = struct {
    fill: Rgb = .{ 0, 0, 0 },
    stroke: Rgb = .{ 0, 0, 0 },
    char_space: f64 = 0,
    word_space: f64 = 0,
    h_scale: f64 = 1,
    leading: f64 = 0,
    rise: f64 = 0,
    font: ?*const Font = null,
    font_size: f64 = 0,
    render_mode: i32 = 0,
    fill_alpha: f64 = 1,
    stroke_alpha: f64 = 1,
};

const Ctx = struct {
    doc: *zpdf.Document,
    cr: *cairo.Context,
    arena: std.mem.Allocator,
    /// For big temporary buffers (decoded images) that are freed straight away.
    gpa: std.mem.Allocator,
    resources: ?Object.Dict,
    diag: *Diag,
    form_depth: u8 = 0,
    fonts: std.StringHashMap(*const Font),
    state: State = .{},
    stack: [64]State = undefined,
    depth: usize = 0,
    // Text matrices: a b c d e f.
    tm: [6]f64 = .{ 1, 0, 0, 1, 0, 0 },
    tlm: [6]f64 = .{ 1, 0, 0, 1, 0, 0 },
    pending_clip: ?cairo.FillRule = null,
    cx: f64 = 0,
    cy: f64 = 0,
    start_x: f64 = 0,
    start_y: f64 = 0,

    fn resolve(self: *Ctx, o: Object) Object {
        var cur = o;
        var n: u8 = 0;
        while (cur == .reference and n < 8) : (n += 1) cur = self.doc.resolve(cur.reference) catch return .null;
        return cur;
    }

    fn number(o: Object) ?f64 {
        return switch (o) {
            .integer => |i| @floatFromInt(i),
            .real => |r| r,
            else => null,
        };
    }

    fn dictOf(self: *Ctx, o: Object) ?Object.Dict {
        return switch (self.resolve(o)) {
            .dict => |d| d,
            .stream => |s| s.dict,
            else => null,
        };
    }

    fn font(self: *Ctx, name: []const u8) ?*const Font {
        if (self.fonts.get(name)) |f| return f;
        const res = self.resources orelse return null;
        const fonts = self.dictOf(res.get("Font") orelse return null) orelse return null;
        const fd = self.dictOf(fonts.get(name) orelse return null) orelse return null;
        const f = self.arena.create(Font) catch return null;
        f.* = .{};
        if (self.resolve(fd.get("BaseFont") orelse .null) == .name) {
            const base = self.resolve(fd.get("BaseFont").?).name;
            f.bold = has(base, "bold") != null or has(base, "black") != null;
            f.italic = has(base, "italic") != null or has(base, "oblique") != null;
            if (has(base, "times") != null or has(base, "serif") != null or
                has(base, "georgia") != null or has(base, "garamond") != null or
                has(base, "palatino") != null or has(base, "roman") != null) f.family = .serif;
            if (has(base, "courier") != null or has(base, "mono") != null or
                has(base, "consolas") != null) f.family = .mono;
        }
        if (fd.get("FirstChar")) |fc| f.first_char = switch (self.resolve(fc)) {
            .integer => |i| i,
            else => 0,
        };
        if (fd.get("Widths")) |w| if (self.resolve(w) == .array) {
            const arr = self.resolve(w).array;
            const out = self.arena.alloc(f64, arr.len) catch return null;
            for (arr, out) |item, *o| o.* = number(self.resolve(item)) orelse 0;
            f.widths = out;
        };
        if (fd.get("FontDescriptor")) |desc| if (self.dictOf(desc)) |dd| {
            if (dd.get("MissingWidth")) |mw| f.missing_width = number(self.resolve(mw)) orelse 500;
        };
        if (fd.get("FontDescriptor")) |desc| if (self.dictOf(desc)) |dd| {
            if (dd.get("FontFile") != null or dd.get("FontFile2") != null or dd.get("FontFile3") != null) self.diag.note("font-embedded-not-read", name);
        };
        if (self.resolve(fd.get("Subtype") orelse .null) == .name and std.mem.eql(u8, self.resolve(fd.get("Subtype").?).name, "Type0")) self.diag.note("font-type0-composite", name);
        // The 14 standard fonts come without widths: Courier is fixed, the rest use an average.
        if (f.widths.len == 0 and f.family == .mono) f.missing_width = 600;
        self.fonts.put(name, f) catch return null;
        return f;
    }
};

fn cmykToRgb(c: f64, m: f64, y: f64, k: f64) Rgb {
    return .{ (1 - c) * (1 - k), (1 - m) * (1 - k), (1 - y) * (1 - k) };
}

fn nums(args: []const Operand, out: []f64) bool {
    if (args.len < out.len) return false;
    const base = args.len - out.len;
    for (out, 0..) |*o, i| switch (args[base + i]) {
        .number => |n| o.* = n,
        else => return false,
    };
    return true;
}

fn colour(args: []const Operand) ?Rgb {
    // Trailing numbers: 1 = gray, 3 = RGB, 4 = CMYK.
    var vals: [4]f64 = undefined;
    var count: usize = 0;
    var i = args.len;
    while (i > 0 and count < 4) : (i -= 1) {
        switch (args[i - 1]) {
            .number => |n| {
                vals[count] = n;
                count += 1;
            },
            else => break,
        }
    }
    if (count == 0) return null;
    // Reverse into reading order.
    var v: [4]f64 = undefined;
    for (0..count) |k| v[k] = vals[count - 1 - k];
    return switch (count) {
        1 => .{ v[0], v[0], v[0] },
        3 => .{ v[0], v[1], v[2] },
        4 => cmykToRgb(v[0], v[1], v[2], v[3]),
        else => null,
    };
}

fn setFill(c: *Ctx) void {
    c.cr.setSourceRgba(c.state.fill[0], c.state.fill[1], c.state.fill[2], c.state.fill_alpha);
}

fn setStroke(c: *Ctx) void {
    c.cr.setSourceRgba(c.state.stroke[0], c.state.stroke[1], c.state.stroke[2], c.state.stroke_alpha);
}

fn paint(c: *Ctx, fill: ?cairo.FillRule, stroke: bool) void {
    const cr = c.cr;
    if (fill) |rule| {
        cr.setFillRule(rule);
        setFill(c);
        if (stroke or c.pending_clip != null) cr.fillPreserve() else cr.fill();
    }
    if (stroke) {
        setStroke(c);
        if (c.pending_clip != null) cr.strokePreserve() else cr.stroke();
    }
    if (c.pending_clip) |rule| {
        cr.setFillRule(rule);
        cr.clip();
        c.pending_clip = null;
    } else if (fill == null and !stroke) {
        cr.newPath();
    }
}

/// Moves the text position by (tx, 0) in text space.
fn advance(c: *Ctx, tx: f64) void {
    c.tm[4] += tx * c.tm[0];
    c.tm[5] += tx * c.tm[1];
}

fn newLine(c: *Ctx, tx: f64, ty: f64) void {
    c.tlm[4] += tx * c.tlm[0] + ty * c.tlm[2];
    c.tlm[5] += tx * c.tlm[1] + ty * c.tlm[3];
    c.tm = c.tlm;
}

fn showString(c: *Ctx, s: []const u8) void {
    const f = c.state.font orelse return;
    const fs = c.state.font_size;
    const cr = c.cr;
    for (s) |code| {
        cr.save();
        var m: cairo.Matrix = undefined;
        // Text space to user space: the text matrix, then the rise and horizontal scale.
        m.init(c.tm[0], c.tm[1], c.tm[2], c.tm[3], c.tm[4], c.tm[5]);
        cr.transform(&m);
        cr.translate(0, c.state.rise);
        // Glyphs are drawn y-down, the page is y-up.
        cr.scale(c.state.h_scale, -1);
        cr.selectFontFace(switch (f.family) {
            .sans => "sans-serif",
            .serif => "serif",
            .mono => "monospace",
        }, if (f.italic) .italic else .normal, if (f.bold) .bold else .normal);
        cr.setFontSize(fs);
        // Codes above 127 are taken as Latin-1, which fits WinAnsi for the common letters.
        var buf: [5]u8 = @splat(0);
        if (code < 0x80) {
            buf[0] = code;
        } else {
            buf[0] = 0xC0 | (code >> 6);
            buf[1] = 0x80 | (code & 0x3F);
        }
        // Without widths in the PDF (the standard 14 fonts), use the substitute font's own.
        var w0 = f.width(code) / 1000.0;
        if (f.widths.len == 0 and code != 0) {
            var ext: cairo.TextExtents = undefined;
            // A large size, so hinting does not round the advance to whole pixels.
            cr.setFontSize(1000);
            cr.textExtents(@ptrCast(&buf), &ext);
            w0 = ext.x_advance / 1000.0;
            cr.setFontSize(fs);
        }
        if (code != ' ' and code != 0 and c.state.render_mode != 3 and c.state.render_mode != 7) {
            setFill(c);
            cr.moveTo(0, 0);
            cr.showText(@ptrCast(&buf));
        }
        cr.restore();
        const tx = (w0 * fs + c.state.char_space + (if (code == ' ') c.state.word_space else 0)) * c.state.h_scale;
        advance(c, tx);
    }
}

fn operatorStep(c: *Ctx, op: []const u8, args: []const Operand) void {
    const cr = c.cr;
    const eql = std.mem.eql;
    var n: [6]f64 = undefined;

    // -- graphics state
    if (eql(u8, op, "q")) {
        if (c.depth < c.stack.len) {
            c.stack[c.depth] = c.state;
            c.depth += 1;
            cr.save();
        }
    } else if (eql(u8, op, "Q")) {
        if (c.depth > 0) {
            c.depth -= 1;
            c.state = c.stack[c.depth];
            cr.restore();
        }
    } else if (eql(u8, op, "cm")) {
        if (nums(args, n[0..6])) {
            var m: cairo.Matrix = undefined;
            m.init(n[0], n[1], n[2], n[3], n[4], n[5]);
            cr.transform(&m);
        }
    } else if (eql(u8, op, "w")) {
        if (nums(args, n[0..1])) cr.setLineWidth(@max(n[0], 0.01));
    } else if (eql(u8, op, "J")) {
        if (nums(args, n[0..1])) cr.setLineCap(switch (@as(i32, @intFromFloat(n[0]))) {
            1 => .round,
            2 => .square,
            else => .butt,
        });
    } else if (eql(u8, op, "j")) {
        if (nums(args, n[0..1])) cr.setLineJoin(switch (@as(i32, @intFromFloat(n[0]))) {
            1 => .round,
            2 => .bevel,
            else => .miter,
        });
    } else if (eql(u8, op, "M")) {
        if (nums(args, n[0..1])) cr.setMiterLimit(n[0]);
    } else if (eql(u8, op, "d")) {
        if (args.len >= 2 and args[args.len - 2] == .array) {
            const arr = args[args.len - 2].array;
            var dashes: [16]f64 = undefined;
            var count: usize = 0;
            for (arr) |a| if (a == .number and count < dashes.len and a.number > 0) {
                dashes[count] = a.number;
                count += 1;
            };
            const phase = args[args.len - 1].asNumber();
            if (count == 0) cr.setDash(&dashes, 0, 0) else cr.setDash(&dashes, @intCast(count), phase);
        }
    }
    // -- colour
    else if (eql(u8, op, "g") or eql(u8, op, "rg") or eql(u8, op, "k") or eql(u8, op, "sc") or eql(u8, op, "scn")) {
        if (colour(args)) |col| c.state.fill = col else c.diag.note("pattern-or-named-colour", op);
    } else if (eql(u8, op, "G") or eql(u8, op, "RG") or eql(u8, op, "K") or eql(u8, op, "SC") or eql(u8, op, "SCN")) {
        if (colour(args)) |col| c.state.stroke = col else c.diag.note("pattern-or-named-colour", op);
    }
    // -- paths
    else if (eql(u8, op, "m")) {
        if (nums(args, n[0..2])) {
            cr.moveTo(n[0], n[1]);
            c.cx = n[0];
            c.cy = n[1];
            c.start_x = n[0];
            c.start_y = n[1];
        }
    } else if (eql(u8, op, "l")) {
        if (nums(args, n[0..2])) {
            cr.lineTo(n[0], n[1]);
            c.cx = n[0];
            c.cy = n[1];
        }
    } else if (eql(u8, op, "c")) {
        if (nums(args, n[0..6])) {
            cr.curveTo(n[0], n[1], n[2], n[3], n[4], n[5]);
            c.cx = n[4];
            c.cy = n[5];
        }
    } else if (eql(u8, op, "v")) {
        if (nums(args, n[0..4])) {
            cr.curveTo(c.cx, c.cy, n[0], n[1], n[2], n[3]);
            c.cx = n[2];
            c.cy = n[3];
        }
    } else if (eql(u8, op, "y")) {
        if (nums(args, n[0..4])) {
            cr.curveTo(n[0], n[1], n[2], n[3], n[2], n[3]);
            c.cx = n[2];
            c.cy = n[3];
        }
    } else if (eql(u8, op, "h")) {
        cr.closePath();
        c.cx = c.start_x;
        c.cy = c.start_y;
    } else if (eql(u8, op, "re")) {
        if (nums(args, n[0..4])) {
            cr.rectangle(n[0], n[1], n[2], n[3]);
            c.cx = n[0];
            c.cy = n[1];
            c.start_x = n[0];
            c.start_y = n[1];
        }
    } else if (eql(u8, op, "S")) {
        paint(c, null, true);
    } else if (eql(u8, op, "s")) {
        cr.closePath();
        paint(c, null, true);
    } else if (eql(u8, op, "f") or eql(u8, op, "F")) {
        paint(c, .winding, false);
    } else if (eql(u8, op, "f*")) {
        paint(c, .even_odd, false);
    } else if (eql(u8, op, "B")) {
        paint(c, .winding, true);
    } else if (eql(u8, op, "B*")) {
        paint(c, .even_odd, true);
    } else if (eql(u8, op, "b")) {
        cr.closePath();
        paint(c, .winding, true);
    } else if (eql(u8, op, "b*")) {
        cr.closePath();
        paint(c, .even_odd, true);
    } else if (eql(u8, op, "n")) {
        paint(c, null, false);
    } else if (eql(u8, op, "W")) {
        c.pending_clip = .winding;
    } else if (eql(u8, op, "W*")) {
        c.pending_clip = .even_odd;
    }
    // -- text
    else if (eql(u8, op, "BT")) {
        c.tm = .{ 1, 0, 0, 1, 0, 0 };
        c.tlm = c.tm;
    } else if (eql(u8, op, "Tf")) {
        if (args.len >= 2 and args[args.len - 2] == .name) {
            c.state.font = c.font(args[args.len - 2].name);
            c.state.font_size = args[args.len - 1].asNumber();
        }
    } else if (eql(u8, op, "Tr")) {
        if (nums(args, n[0..1])) c.state.render_mode = @intFromFloat(n[0]);
    } else if (eql(u8, op, "Tc")) {
        if (nums(args, n[0..1])) c.state.char_space = n[0];
    } else if (eql(u8, op, "Tw")) {
        if (nums(args, n[0..1])) c.state.word_space = n[0];
    } else if (eql(u8, op, "Tz")) {
        if (nums(args, n[0..1])) c.state.h_scale = n[0] / 100.0;
    } else if (eql(u8, op, "TL")) {
        if (nums(args, n[0..1])) c.state.leading = n[0];
    } else if (eql(u8, op, "Ts")) {
        if (nums(args, n[0..1])) c.state.rise = n[0];
    } else if (eql(u8, op, "Td")) {
        if (nums(args, n[0..2])) newLine(c, n[0], n[1]);
    } else if (eql(u8, op, "TD")) {
        if (nums(args, n[0..2])) {
            c.state.leading = -n[1];
            newLine(c, n[0], n[1]);
        }
    } else if (eql(u8, op, "Tm")) {
        if (nums(args, n[0..6])) {
            c.tm = n;
            c.tlm = n;
        }
    } else if (eql(u8, op, "T*")) {
        newLine(c, 0, -c.state.leading);
    } else if (eql(u8, op, "Tj")) {
        if (args.len >= 1) switch (args[args.len - 1]) {
            .string, .hex_string => |s| showString(c, s),
            else => {},
        };
    } else if (eql(u8, op, "'") or eql(u8, op, "\"")) {
        newLine(c, 0, -c.state.leading);
        if (args.len >= 1) switch (args[args.len - 1]) {
            .string, .hex_string => |s| showString(c, s),
            else => {},
        };
    } else if (eql(u8, op, "TJ")) {
        if (args.len >= 1 and args[args.len - 1] == .array) {
            for (args[args.len - 1].array) |item| switch (item) {
                .string, .hex_string => |s| showString(c, s),
                .number => |adj| advance(c, -adj / 1000.0 * c.state.font_size * c.state.h_scale),
                else => {},
            };
        }
    } else if (eql(u8, op, "Do")) {
        if (args.len >= 1 and args[args.len - 1] == .name) doXObject(c, args[args.len - 1].name);
    } else if (eql(u8, op, "gs")) {
        if (args.len >= 1 and args[args.len - 1] == .name) extGState(c, args[args.len - 1].name);
    } else if (eql(u8, op, "sh")) {
        c.diag.note("shading-not-drawn", "sh");
    } else if (eql(u8, op, "ET") or eql(u8, op, "cs") or eql(u8, op, "CS") or eql(u8, op, "BMC") or eql(u8, op, "BDC") or
        eql(u8, op, "EMC") or eql(u8, op, "MP") or eql(u8, op, "DP") or eql(u8, op, "BX") or eql(u8, op, "EX") or
        eql(u8, op, "ri") or eql(u8, op, "i") or eql(u8, op, "d0") or eql(u8, op, "d1"))
    {
        // Nothing to draw for these.
    } else {
        c.diag.note("op-unknown", op);
    }
}

fn decoded(c: *Ctx, st: Object.Stream) ?[]u8 {
    const filter = if (st.dict.get("Filter")) |f| c.resolve(f) else null;
    const parms = if (st.dict.get("DecodeParms")) |f| c.resolve(f) else null;
    return zpdf.decompress.decompressStream(c.gpa, st.data, filter, parms) catch {
        c.diag.note("stream-decode-failed", "");
        return null;
    };
}

fn lastFilter(c: *Ctx, st: Object.Stream) ?[]const u8 {
    const f = c.resolve(st.dict.get("Filter") orelse return null);
    return switch (f) {
        .name => |n| n,
        .array => |arr| if (arr.len == 0) null else switch (c.resolve(arr[arr.len - 1])) {
            .name => |n| n,
            else => null,
        },
        else => null,
    };
}

fn intOf(c: *Ctx, o: ?Object, default: i64) i64 {
    return switch (c.resolve(o orelse return default)) {
        .integer => |i| i,
        .real => |r| @intFromFloat(r),
        else => default,
    };
}

fn baseOf(cs: image.Cs) ?image.Base {
    return switch (cs) {
        .gray => .gray,
        .rgb => .rgb,
        .cmyk => .cmyk,
        else => null,
    };
}

fn csOf(c: *Ctx, o: Object, depth: u8) image.Cs {
    if (depth > 4) return .{ .other = 1 };
    const r = c.resolve(o);
    switch (r) {
        .name => |n| {
            if (std.mem.eql(u8, n, "DeviceGray") or std.mem.eql(u8, n, "G") or std.mem.eql(u8, n, "CalGray")) return .gray;
            if (std.mem.eql(u8, n, "DeviceRGB") or std.mem.eql(u8, n, "RGB") or std.mem.eql(u8, n, "CalRGB")) return .rgb;
            if (std.mem.eql(u8, n, "DeviceCMYK") or std.mem.eql(u8, n, "CMYK")) return .cmyk;
            // A name in the page's ColorSpace resources.
            if (c.resources) |res| if (c.dictOf(res.get("ColorSpace") orelse .null)) |cs| if (cs.get(n)) |named| return csOf(c, named, depth + 1);
            c.diag.note("colorspace-unknown", n);
            return .{ .other = 1 };
        },
        .array => |arr| {
            if (arr.len == 0) return .{ .other = 1 };
            const head = switch (c.resolve(arr[0])) {
                .name => |n| n,
                else => return .{ .other = 1 },
            };
            const eql = std.mem.eql;
            if (eql(u8, head, "ICCBased") and arr.len > 1) {
                const st = switch (c.resolve(arr[1])) {
                    .stream => |s| s,
                    else => return .rgb,
                };
                return switch (intOf(c, st.dict.get("N"), 3)) {
                    1 => .gray,
                    4 => .cmyk,
                    else => .rgb,
                };
            }
            if (eql(u8, head, "CalGray")) return .gray;
            if (eql(u8, head, "CalRGB")) return .rgb;
            if ((eql(u8, head, "Indexed") or eql(u8, head, "I")) and arr.len >= 4) {
                const base = baseOf(csOf(c, arr[1], depth + 1)) orelse {
                    c.diag.note("colorspace-indexed-base", "");
                    return .{ .other = 1 };
                };
                const palette: []const u8 = switch (c.resolve(arr[3])) {
                    .string, .hex_string => |p| p,
                    .stream => |ps| decoded(c, ps) orelse &.{},
                    else => &.{},
                };
                return .{ .indexed = .{ .base = base, .hival = @intCast(@max(0, intOf(c, arr[2], 255))), .palette = palette } };
            }
            if (eql(u8, head, "Separation")) {
                c.diag.note("colorspace-separation-approx", "");
                return .ink;
            }
            if (eql(u8, head, "DeviceN")) {
                c.diag.note("colorspace-devicen-approx", "");
                const names = if (arr.len > 1) c.resolve(arr[1]) else .null;
                return .{ .other = if (names == .array) @intCast(@min(names.array.len, 8)) else 1 };
            }
            if (eql(u8, head, "Lab")) {
                c.diag.note("colorspace-lab-approx", "");
                return .rgb;
            }
            c.diag.note("colorspace-unknown", head);
            return .{ .other = 1 };
        },
        else => return .{ .other = 1 },
    }
}

fn extGState(c: *Ctx, name: []const u8) void {
    const res = c.resources orelse return;
    const gs = c.dictOf(res.get("ExtGState") orelse return) orelse return;
    const d = c.dictOf(gs.get(name) orelse return) orelse return;
    for (d.entries) |e| {
        const key = e.key;
        const v = c.resolve(e.value);
        if (std.mem.eql(u8, key, "ca")) {
            c.state.fill_alpha = Ctx.number(v) orelse 1;
        } else if (std.mem.eql(u8, key, "CA")) {
            c.state.stroke_alpha = Ctx.number(v) orelse 1;
        } else if (std.mem.eql(u8, key, "LW")) {
            if (Ctx.number(v)) |lw| c.cr.setLineWidth(@max(lw, 0.01));
        } else if (std.mem.eql(u8, key, "SMask")) {
            if (v != .name) c.diag.note("soft-mask-ignored", name);
        } else if (std.mem.eql(u8, key, "BM")) {
            const plain = switch (v) {
                .name => |n| std.mem.eql(u8, n, "Normal") or std.mem.eql(u8, n, "Compatible"),
                else => false,
            };
            if (!plain) c.diag.note("blend-mode-ignored", name);
        }
    }
}

fn doXObject(c: *Ctx, name: []const u8) void {
    const res = c.resources orelse return c.diag.note("xobject-no-resources", name);
    const xs = c.dictOf(res.get("XObject") orelse return c.diag.note("xobject-missing", name)) orelse return;
    const obj = c.resolve(xs.get(name) orelse return c.diag.note("xobject-missing", name));
    const st = switch (obj) {
        .stream => |x| x,
        else => return c.diag.note("xobject-not-stream", name),
    };
    const sub = switch (c.resolve(st.dict.get("Subtype") orelse .null)) {
        .name => |n| n,
        else => "",
    };
    if (std.mem.eql(u8, sub, "Image")) return drawImage(c, st, name);
    if (std.mem.eql(u8, sub, "Form")) return drawForm(c, st);
    c.diag.note("xobject-unknown-subtype", sub);
}

fn drawForm(c: *Ctx, st: Object.Stream) void {
    if (c.form_depth >= 12) return c.diag.note("form-too-deep", "");
    const content = decoded(c, st) orelse return;
    defer c.gpa.free(content);
    const cr = c.cr;
    const saved_state = c.state;
    const saved_res = c.resources;
    const saved_fonts = c.fonts;
    const base_depth = c.depth;
    cr.save();
    if (c.resolve(st.dict.get("Matrix") orelse .null) == .array) {
        const arr = c.resolve(st.dict.get("Matrix").?).array;
        if (arr.len >= 6) {
            var v: [6]f64 = undefined;
            for (0..6) |i| v[i] = Ctx.number(c.resolve(arr[i])) orelse 0;
            var m: cairo.Matrix = undefined;
            m.init(v[0], v[1], v[2], v[3], v[4], v[5]);
            cr.transform(&m);
        }
    }
    if (c.resolve(st.dict.get("BBox") orelse .null) == .array) {
        const arr = c.resolve(st.dict.get("BBox").?).array;
        if (arr.len >= 4) {
            var v: [4]f64 = undefined;
            for (0..4) |i| v[i] = Ctx.number(c.resolve(arr[i])) orelse 0;
            cr.rectangle(v[0], v[1], v[2] - v[0], v[3] - v[1]);
            cr.clip();
        }
    }
    if (st.dict.get("Resources")) |r| if (c.dictOf(r)) |rd| {
        c.resources = rd;
        c.fonts = std.StringHashMap(*const Font).init(c.arena);
    };
    c.form_depth += 1;
    runContent(c, content);
    c.form_depth -= 1;
    while (c.depth > base_depth) : (c.depth -= 1) cr.restore();
    cr.restore();
    c.state = saved_state;
    c.resources = saved_res;
    c.fonts = saved_fonts;
}

const Gray8 = struct { w: usize, h: usize, data: []u8 };

/// A soft mask as 8-bit gray, from a JPEG or raw samples. Caller frees `data`.
fn grayOf(c: *Ctx, st: Object.Stream) ?Gray8 {
    const d = st.dict;
    const w: usize = @intCast(@max(0, intOf(c, d.get("Width"), 0)));
    const h: usize = @intCast(@max(0, intOf(c, d.get("Height"), 0)));
    const data = decoded(c, st) orelse return null;
    defer c.gpa.free(data);
    if (lastFilter(c, st)) |f| if (std.mem.eql(u8, f, "DCTDecode") or std.mem.eql(u8, f, "DCT")) {
        var x: c_int = 0;
        var y: c_int = 0;
        var n: c_int = 0;
        const px = stbi_load_from_memory(data.ptr, @intCast(@min(data.len, std.math.maxInt(c_int))), &x, &y, &n, 1) orelse return null;
        defer stbi_image_free(px);
        const out = c.gpa.dupe(u8, px[0..@as(usize, @intCast(x)) * @as(usize, @intCast(y))]) catch return null;
        return .{ .w = @intCast(x), .h = @intCast(y), .data = out };
    };
    const px = image.toArgb(c.gpa, .{ .width = @intCast(w), .height = @intCast(h), .bpc = @intCast(intOf(c, d.get("BitsPerComponent"), 8)), .cs = .gray }, data, .{ 0, 0, 0 }, null) catch return null;
    defer c.gpa.free(px);
    const out = c.gpa.alloc(u8, px.len) catch return null;
    for (px, out) |p, *o| o.* = @truncate(p); // opaque gray: any colour channel is the value
    return .{ .w = w, .h = h, .data = out };
}

fn drawImage(c: *Ctx, st: Object.Stream, name: []const u8) void {
    const d = st.dict;
    var w: usize = @intCast(@max(0, intOf(c, d.get("Width"), 0)));
    var h: usize = @intCast(@max(0, intOf(c, d.get("Height"), 0)));
    if (w == 0 or h == 0) return c.diag.note("image-bad-dict", name);
    const is_mask = switch (c.resolve(d.get("ImageMask") orelse .null)) {
        .boolean => |b| b,
        else => false,
    };
    const filter = lastFilter(c, st) orelse "";
    var pixels: ?[]u32 = null;
    defer if (pixels) |p| c.gpa.free(p);

    // Soft mask: becomes the alpha channel.
    var alpha: ?[]u8 = null;
    defer if (alpha) |a| c.gpa.free(a);
    if (d.get("SMask")) |sm| switch (c.resolve(sm)) {
        .stream => |ms| if (grayOf(c, ms)) |g| {
            defer c.gpa.free(g.data);
            if (g.w == w and g.h == h) {
                alpha = c.gpa.dupe(u8, g.data) catch null;
            } else if (g.w > 0 and g.h > 0 and w * h < 200_000_000) {
                // Different size: nearest-neighbour onto the image's grid.
                if (c.gpa.alloc(u8, w * h) catch null) |a| {
                    for (0..h) |y| for (0..w) |x| {
                        a[y * w + x] = g.data[@min(g.h - 1, y * g.h / h) * g.w + @min(g.w - 1, x * g.w / w)];
                    };
                    alpha = a;
                }
            }
        },
        else => {},
    };
    if (d.get("Mask") != null and d.get("SMask") == null) c.diag.note("image-mask-ignored", name);

    const fill8 = [3]u8{ @intFromFloat(c.state.fill[0] * 255 + 0.5), @intFromFloat(c.state.fill[1] * 255 + 0.5), @intFromFloat(c.state.fill[2] * 255 + 0.5) };

    if (std.mem.eql(u8, filter, "JPXDecode") or std.mem.eql(u8, filter, "CCITTFaxDecode") or std.mem.eql(u8, filter, "CCF") or std.mem.eql(u8, filter, "JBIG2Decode")) {
        c.diag.note(if (filter[0] == 'J' and filter[1] == 'P') "image-jpx" else if (filter[0] == 'J') "image-jbig2" else "image-ccitt", name);
        // A pale box where the image goes, so the layout is still readable.
        c.cr.save();
        c.cr.setSourceRgba(0.85, 0.85, 0.85, 1);
        c.cr.rectangle(0, 0, 1, 1);
        c.cr.fill();
        c.cr.restore();
        return;
    }

    if (std.mem.eql(u8, filter, "DCTDecode") or std.mem.eql(u8, filter, "DCT")) {
        const data = decoded(c, st) orelse return;
        defer c.gpa.free(data);
        var x: c_int = 0;
        var y: c_int = 0;
        var n: c_int = 0;
        const px = stbi_load_from_memory(data.ptr, @intCast(@min(data.len, std.math.maxInt(c_int))), &x, &y, &n, 3) orelse return c.diag.note("image-jpeg-failed", name);
        defer stbi_image_free(px);
        w = @intCast(x);
        h = @intCast(y);
        pixels = image.fromRgb8(c.gpa, w, h, px[0 .. w * h * 3], alpha) catch |e| return c.diag.note(if (e == error.TooBig) "image-too-big" else "image-failed", name);
    } else {
        const data = decoded(c, st) orelse return;
        defer c.gpa.free(data);
        const spec: image.Spec = .{
            .width = @intCast(w),
            .height = @intCast(h),
            .bpc = @intCast(intOf(c, d.get("BitsPerComponent"), if (is_mask) 1 else 8)),
            .cs = if (is_mask) .gray else csOf(c, d.get("ColorSpace") orelse .null, 0),
            .decode = decodeArray(c, d.get("Decode")),
            .mask = is_mask,
        };
        pixels = image.toArgb(c.gpa, spec, data, fill8, alpha) catch |e| return c.diag.note(if (e == error.TooBig) "image-too-big" else "image-failed", name);
    }

    const px = pixels orelse return;
    const surface = cairo.Surface.imageCreateForData(@ptrCast(px.ptr), .argb32, @intCast(w), @intCast(h), @intCast(w * 4));
    defer surface.destroy();
    surface.markDirty();
    const cr = c.cr;
    cr.save();
    // Image space is the unit square with y up; the image's first row is its top.
    cr.translate(0, 1);
    cr.scale(1.0 / @as(f64, @floatFromInt(w)), -1.0 / @as(f64, @floatFromInt(h)));
    cr.setSourceSurface(surface, 0, 0);
    // Smoothing must not fade the edges into transparency: repeat the edge pixels, then clip to the image.
    cr.getSource().setFilter(.good);
    cr.getSource().setExtend(.pad);
    cr.rectangle(0, 0, @floatFromInt(w), @floatFromInt(h));
    cr.clip();
    cr.paintWithAlpha(c.state.fill_alpha);
    cr.restore();
}

fn decodeArray(c: *Ctx, o: ?Object) ?[]const f64 {
    const arr = switch (c.resolve(o orelse return null)) {
        .array => |a| a,
        else => return null,
    };
    const out = c.arena.alloc(f64, arr.len) catch return null;
    for (arr, out) |item, *v| v.* = Ctx.number(c.resolve(item)) orelse 0;
    return out;
}

/// Runs one content stream (a page, or a form) against the context.
fn runContent(c: *Ctx, content: []const u8) void {
    var lexer = Lexer.init(c.arena, content);
    var args: std.ArrayList(Operand) = .empty;
    while (lexer.next() catch null) |tok| {
        switch (tok) {
            .number => |v| args.append(c.arena, .{ .number = v }) catch return,
            .string => |v| args.append(c.arena, .{ .string = v }) catch return,
            .hex_string => |v| args.append(c.arena, .{ .hex_string = v }) catch return,
            .name => |v| args.append(c.arena, .{ .name = v }) catch return,
            .array => |v| args.append(c.arena, .{ .array = c.arena.dupe(Operand, v) catch return }) catch return,
            .operator => |op| {
                operatorStep(c, op, args.items);
                args.clearRetainingCapacity();
            },
        }
    }
}

/// The page's size in points once its /Rotate is applied.
pub fn pageSize(doc: *zpdf.Document, index: usize) ?struct { w: f64, h: f64 } {
    if (index >= doc.pages.items.len) return null;
    const p = doc.pages.items[index];
    const w = p.media_box[2] - p.media_box[0];
    const h = p.media_box[3] - p.media_box[1];
    return if (@mod(p.rotation, 180) == 90) .{ .w = h, .h = w } else .{ .w = w, .h = h };
}

/// Draws page `index` (0-based) onto `cr`, scaled by `scale` device pixels per
/// PDF point, with the page's top-left at the origin of `cr`. What could not
/// be drawn is recorded in `diag`.
pub fn renderPage(allocator: std.mem.Allocator, doc: *zpdf.Document, index: usize, cr: *cairo.Context, scale: f64, diag: *Diag) Error!void {
    if (index >= doc.pages.items.len) return error.NoSuchPage;
    const page = doc.pages.items[index];
    diag.page = index;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const x0 = page.media_box[0];
    const y0 = page.media_box[1];
    const w = page.media_box[2] - x0;
    const h = page.media_box[3] - y0;
    cr.save();
    defer cr.restore();
    switch (@mod(page.rotation, 360)) {
        90 => {
            cr.translate(h * scale, 0);
            cr.rotate(std.math.pi / 2.0);
        },
        180 => {
            cr.translate(w * scale, h * scale);
            cr.rotate(std.math.pi);
        },
        270 => {
            cr.translate(0, w * scale);
            cr.rotate(-std.math.pi / 2.0);
        },
        else => {},
    }
    // PDF space has y pointing up.
    cr.translate(0, h * scale);
    cr.scale(scale, -scale);
    cr.translate(-x0, -y0);
    cr.setSourceRgb(0, 0, 0);
    cr.setLineWidth(1);

    const content = zpdf.pagetree.getPageContents(doc.parsing_arena.allocator(), arena, doc.data, &doc.xref_table, page, &doc.object_cache) catch {
        diag.note("page-content-unreadable", "");
        return;
    };
    var ctx: Ctx = .{
        .doc = doc,
        .cr = cr,
        .arena = arena,
        .gpa = allocator,
        .resources = page.resources,
        .diag = diag,
        .fonts = std.StringHashMap(*const Font).init(arena),
    };
    runContent(&ctx, content);
    // Unbalanced q at the end of a stream.
    while (ctx.depth > 0) : (ctx.depth -= 1) cr.restore();
}

// ---- tests ------------------------------------------------------------------------------------

const TestObj = struct { dict: []const u8, stream: ?[]const u8 = null };

/// A one-page PDF (page 200x100 points) with a correct cross-reference table.
/// Objects 1 to 5 are the catalog, page tree, page, content and Helvetica (/F1);
/// `extra` become objects 6 and up. `resources` is the inside of /Resources.
fn buildPdf(a: std.mem.Allocator, content: []const u8, resources: []const u8, rotate: i32, extra: []const TestObj) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var offsets: std.ArrayList(usize) = .empty;
    defer offsets.deinit(a);
    try out.appendSlice(a, "%PDF-1.4\n");
    var page: std.ArrayList(u8) = .empty;
    defer page.deinit(a);
    try page.print(a, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Rotate {d} /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> {s} >> >>", .{ rotate, resources });
    const base = [_]TestObj{
        .{ .dict = "<< /Type /Catalog /Pages 2 0 R >>" },
        .{ .dict = "<< /Type /Pages /Kids [3 0 R] /Count 1 >>" },
        .{ .dict = page.items },
        .{ .dict = "", .stream = content },
        .{ .dict = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>" },
    };
    const all = try a.alloc(TestObj, base.len + extra.len);
    defer a.free(all);
    @memcpy(all[0..base.len], &base);
    @memcpy(all[base.len..], extra);
    for (all, 0..) |o, i| {
        try offsets.append(a, out.items.len);
        if (o.stream) |data| {
            // The dict text (if any) is the inside of << >> besides /Length.
            try out.print(a, "{d} 0 obj\n<< {s} /Length {d} >>\nstream\n", .{ i + 1, o.dict, data.len });
            try out.appendSlice(a, data);
            try out.appendSlice(a, "\nendstream\nendobj\n");
        } else try out.print(a, "{d} 0 obj\n{s}\nendobj\n", .{ i + 1, o.dict });
    }
    const xref = out.items.len;
    try out.print(a, "xref\n0 {d}\n0000000000 65535 f \n", .{all.len + 1});
    for (offsets.items) |o| try out.print(a, "{d:0>10} 00000 n \n", .{o});
    try out.print(a, "trailer\n<< /Size {d} /Root 1 0 R >>\nstartxref\n{d}\n%%EOF\n", .{ all.len + 1, xref });
    return out.toOwnedSlice(a);
}

/// Renders page 1 of `pdf` at 2x and returns the image; the caller destroys it.
fn renderTest(a: std.mem.Allocator, pdf: []const u8, diag: *Diag, w: c_int, h: c_int) !*cairo.Surface {
    const doc = try zpdf.Document.openFromMemoryCopied(a, pdf, zpdf.ErrorConfig.default());
    defer doc.close();
    const surface = cairo.Surface.imageCreate(.argb32, w, h);
    const cr = cairo.Context.create(surface);
    defer cr.destroy();
    cr.setSourceRgb(1, 1, 1);
    cr.paint();
    try renderPage(a, doc, 0, cr, 2.0, diag);
    surface.flush();
    return surface;
}

fn savePng(surface: *cairo.Surface, name: [:0]const u8) void {
    // DKDE_PDF_TEST_DIR=/some/dir keeps the images of the tests, to look at.
    const dir = std.c.getenv("DKDE_PDF_TEST_DIR") orelse return;
    var buf: [512]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&buf, "{s}/{s}.png", .{ std.mem.span(dir), name }, 0) catch return;
    _ = surface.writeToPng(path);
}

/// A 1x1 JPEG, to test DCTDecode.
const tiny_jpeg_b64 = "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA=";

test "paths, colours and text are drawn" {
    const a = std.testing.allocator;
    const pdf = try buildPdf(a,
        \\1 0 0 rg 10 10 60 40 re f
        \\0 0 1 RG 4 w 100 20 m 150 80 l S
        \\0 0.6 0 rg 120 10 m 190 10 l 190 40 l h f
        \\BT /F1 18 Tf 1 0 0 1 10 70 Tm 0 g (Hello PDF) Tj ET
    , "", 0, &.{});
    defer a.free(pdf);
    var diag = Diag.init(a);
    diag.verbose = false;
    defer diag.deinit();
    const surface = try renderTest(a, pdf, &diag, 400, 200);
    defer surface.destroy();
    savePng(surface, "paths");
    try std.testing.expectEqual(@as(u32, 0), diag.total());
}

test "images, forms, transparency and rotation" {
    const a = std.testing.allocator;
    // A 2x2 RGB image: red, green / blue, white.
    const rgb = [_]u8{ 255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255 };
    const pdf = try buildPdf(a,
        \\q 60 0 0 40 10 50 cm /Im1 Do Q
        \\q 1 0 0 1 100 10 cm /Fm1 Do Q
        \\/GS1 gs 0 0 1 rg 20 5 50 30 re f
        \\BT /F1 12 Tf 1 0 0 1 10 90 Tm (top) Tj ET
    , "/XObject << /Im1 6 0 R /Fm1 7 0 R >> /ExtGState << /GS1 << /ca 0.5 >> >>", 90, &.{
        .{ .dict = "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceRGB /BitsPerComponent 8", .stream = &rgb },
        .{ .dict = "/Type /XObject /Subtype /Form /BBox [0 0 40 40] /Matrix [1 0 0 1 0 0]", .stream = "0.9 0.5 0 rg 0 0 40 40 re f 0 g 5 5 10 10 re f" },
    });
    defer a.free(pdf);
    var diag = Diag.init(a);
    diag.verbose = false;
    defer diag.deinit();
    // Rotated 90 degrees the page is 100 wide and 200 tall.
    const surface = try renderTest(a, pdf, &diag, 200, 400);
    defer surface.destroy();
    savePng(surface, "image-form-rotate");
    try std.testing.expectEqual(@as(u32, 0), diag.total());
}

test "a JPEG image is decoded, and unsupported image types are counted" {
    const a = std.testing.allocator;
    var tiny_jpeg: [134]u8 = undefined;
    try std.base64.standard.Decoder.decode(&tiny_jpeg, tiny_jpeg_b64);
    const pdf = try buildPdf(a,
        \\q 80 0 0 40 10 10 cm /Im1 Do Q
        \\q 80 0 0 40 100 10 cm /Im2 Do Q
    , "/XObject << /Im1 6 0 R /Im2 7 0 R >>", 0, &.{
        .{ .dict = "/Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode", .stream = &tiny_jpeg },
        .{ .dict = "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 1 /Filter /JBIG2Decode", .stream = "x" },
    });
    defer a.free(pdf);
    var diag = Diag.init(a);
    diag.verbose = false;
    defer diag.deinit();
    const surface = try renderTest(a, pdf, &diag, 400, 200);
    defer surface.destroy();
    savePng(surface, "jpeg-and-unsupported");
    try std.testing.expectEqual(@as(?u32, 1), diag.counts.get("image-jbig2"));
}

test {
    _ = @import("image.zig");
    _ = @import("diag.zig");
}
