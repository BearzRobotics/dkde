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
};

const Ctx = struct {
    doc: *zpdf.Document,
    cr: *cairo.Context,
    arena: std.mem.Allocator,
    resources: ?Object.Dict,
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
    c.cr.setSourceRgb(c.state.fill[0], c.state.fill[1], c.state.fill[2]);
}

fn setStroke(c: *Ctx) void {
    c.cr.setSourceRgb(c.state.stroke[0], c.state.stroke[1], c.state.stroke[2]);
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
        if (code != ' ' and code != 0) {
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
        if (colour(args)) |col| c.state.fill = col;
    } else if (eql(u8, op, "G") or eql(u8, op, "RG") or eql(u8, op, "K") or eql(u8, op, "SC") or eql(u8, op, "SCN")) {
        if (colour(args)) |col| c.state.stroke = col;
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
    }
}

/// Draws page `index` (0-based) onto `cr`, scaled by `scale` device pixels per
/// PDF point, with the page's top-left at the origin of `cr`.
pub fn renderPage(allocator: std.mem.Allocator, doc: *zpdf.Document, index: usize, cr: *cairo.Context, scale: f64) Error!void {
    if (index >= doc.pages.items.len) return error.NoSuchPage;
    const page = doc.pages.items[index];
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const x0 = page.media_box[0];
    const y0 = page.media_box[1];
    const h = page.media_box[3] - y0;
    cr.save();
    defer cr.restore();
    // PDF space has y pointing up.
    cr.translate(0, h * scale);
    cr.scale(scale, -scale);
    cr.translate(-x0, -y0);
    cr.setSourceRgb(0, 0, 0);
    cr.setLineWidth(1);

    const content = zpdf.pagetree.getPageContents(doc.parsing_arena.allocator(), arena, doc.data, &doc.xref_table, page, &doc.object_cache) catch return;
    var ctx: Ctx = .{
        .doc = doc,
        .cr = cr,
        .arena = arena,
        .resources = page.resources,
        .fonts = std.StringHashMap(*const Font).init(arena),
    };
    var lexer = Lexer.init(arena, content);
    var args: std.ArrayList(Operand) = .empty;
    while (lexer.next() catch null) |tok| {
        switch (tok) {
            .number => |v| args.append(arena, .{ .number = v }) catch return error.OutOfMemory,
            .string => |v| args.append(arena, .{ .string = v }) catch return error.OutOfMemory,
            .hex_string => |v| args.append(arena, .{ .hex_string = v }) catch return error.OutOfMemory,
            .name => |v| args.append(arena, .{ .name = v }) catch return error.OutOfMemory,
            .array => |v| args.append(arena, .{ .array = arena.dupe(Operand, v) catch return error.OutOfMemory }) catch return error.OutOfMemory,
            .operator => |op| {
                operatorStep(&ctx, op, args.items);
                args.clearRetainingCapacity();
            },
        }
    }
    // Unbalanced q at the end of a stream.
    while (ctx.depth > 0) : (ctx.depth -= 1) cr.restore();
}

// ---- tests ------------------------------------------------------------------------------------

/// A one-page PDF with `content` as its page stream and Helvetica as /F1,
/// with a correct cross-reference table.
fn buildPdf(a: std.mem.Allocator, content: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var offsets: [6]usize = undefined;
    try out.appendSlice(a, "%PDF-1.4\n");
    const objs = [_][]const u8{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
        "",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    };
    for (objs, 0..) |o, i| {
        offsets[i] = out.items.len;
        if (i == 3) {
            try out.print(a, "4 0 obj\n<< /Length {d} >>\nstream\n{s}\nendstream\nendobj\n", .{ content.len, content });
        } else try out.print(a, "{d} 0 obj\n{s}\nendobj\n", .{ i + 1, o });
    }
    const xref = out.items.len;
    try out.print(a, "xref\n0 6\n0000000000 65535 f \n", .{});
    for (offsets[0..5]) |o| try out.print(a, "{d:0>10} 00000 n \n", .{o});
    try out.print(a, "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n{d}\n%%EOF\n", .{xref});
    return out.toOwnedSlice(a);
}

test "paths, colours and text are drawn" {
    const a = std.testing.allocator;
    const pdf = try buildPdf(a,
        \\1 0 0 rg 10 10 60 40 re f
        \\0 0 1 RG 4 w 100 20 m 150 80 l S
        \\0 0.6 0 rg 120 10 m 190 10 l 190 40 l h f
        \\BT /F1 18 Tf 1 0 0 1 10 70 Tm 0 g (Hello PDF) Tj ET
    );
    defer a.free(pdf);
    const doc = try zpdf.Document.openFromMemoryCopied(a, pdf, zpdf.ErrorConfig.default());
    defer doc.close();
    try std.testing.expectEqual(@as(usize, 1), doc.pageCount());

    const surface = cairo.Surface.imageCreate(.argb32, 400, 200);
    defer surface.destroy();
    const cr = cairo.Context.create(surface);
    defer cr.destroy();
    cr.setSourceRgb(1, 1, 1);
    cr.paint();
    try renderPage(a, doc, 0, cr, 2.0);
    surface.flush();
    if (std.c.getenv("DKDE_PDF_TEST_PNG")) |path| _ = surface.writeToPng(path);
}
