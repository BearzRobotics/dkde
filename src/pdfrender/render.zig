//! Draws a PDF page with cairo from the display list that pdf-zig builds
//! (../../../pdf-zig): pdf-zig reads the file and interprets the content
//! streams; this file only draws what it is told.
//!
//! Drawn: filled, stroked and clipped paths, dashes, colours, transparency and
//! blend modes, axial and radial gradients, tiling patterns, images (Flate and
//! friends through pdf-zig, JPEG through dkde's image codec), form XObjects
//! (already expanded by pdf-zig), and text. Text uses the embedded TrueType,
//! CFF or Type 1 outlines when they can be read, and a system font of the same
//! family and style otherwise, advancing by the widths pdf-zig resolved.
//!
//! What cannot be drawn is counted in a `Diag`.

const std = @import("std");
const cairo = @import("cairo1");
const pdf = @import("pdf");
const truetype = @import("truetype");
const cff = @import("cff.zig");
const type1 = @import("type1.zig");
const imgcodec = @import("imgcodec");
pub const Diag = @import("diag.zig").Diag;

const display = pdf.display;

extern fn stbi_load_from_memory(buffer: [*]const u8, len: c_int, x: *c_int, y: *c_int, comp: *c_int, req_comp: c_int) ?[*]u8;
extern fn stbi_image_free(data: *anyopaque) void;
extern var stbi_jpeg_raw_cmyk: c_int;

pub const Error = error{ NoSuchPage, OutOfMemory };

fn has(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

// ---- documents ----------------------------------------------------------------------------

/// An open PDF file with what the renderer keeps for it between pages.
pub const Document = struct {
    gpa: std.mem.Allocator,
    /// The file's bytes (the pdf-zig document borrows them).
    bytes: []u8,
    doc: pdf.Document,
    pages: pdf.pages.PageList,
    renderer: pdf.Renderer,
    /// Font programs and other per-font data, kept until `close`.
    arena: std.heap.ArenaAllocator,
    fonts: std.AutoHashMapUnmanaged(*const pdf.font.Font, *RFont) = .empty,
    /// The file was encrypted (and opened with the empty password).
    encrypted: bool = false,

    pub const OpenError = error{ OutOfMemory, FileUnreadable, NotPdf, PasswordRequired, Unsupported };

    /// Reads and opens the file at `path`.
    pub fn open(gpa: std.mem.Allocator, path: [:0]const u8) OpenError!*Document {
        const f = std.c.fopen(path.ptr, "rb") orelse return error.FileUnreadable;
        defer _ = std.c.fclose(f);
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(gpa);
        var chunk: [65536]u8 = undefined;
        while (true) {
            const n = std.c.fread(&chunk, 1, chunk.len, f);
            if (n == 0) break;
            try list.appendSlice(gpa, chunk[0..n]);
        }
        const buf = try list.toOwnedSlice(gpa);
        return fromOwned(gpa, buf);
    }

    /// Opens a PDF held in memory (copied).
    pub fn openFromMemory(gpa: std.mem.Allocator, bytes: []const u8) OpenError!*Document {
        return fromOwned(gpa, try gpa.dupe(u8, bytes));
    }

    fn fromOwned(gpa: std.mem.Allocator, buf: []u8) OpenError!*Document {
        errdefer gpa.free(buf);
        const self = try gpa.create(Document);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .bytes = buf,
            .doc = pdf.Document.open(gpa, buf, .{}) catch |e| return switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                error.PasswordRequired => error.PasswordRequired,
                error.UnsupportedEncryption => error.Unsupported,
                else => error.NotPdf,
            },
            .pages = undefined,
            .renderer = undefined,
            .arena = std.heap.ArenaAllocator.init(gpa),
        };
        errdefer self.doc.deinit();
        self.pages = try pdf.pages.PageList.build(&self.doc);
        self.renderer = pdf.Renderer.init(&self.doc, .{});
        self.encrypted = self.doc.crypt != null;
        return self;
    }

    pub fn close(self: *Document) void {
        const gpa = self.gpa;
        self.renderer.deinit();
        self.arena.deinit();
        self.doc.deinit();
        gpa.free(self.bytes);
        gpa.destroy(self);
    }

    pub fn pageCount(self: *const Document) usize {
        return self.pages.entries.len;
    }
};

/// The size of page `index` as displayed, in points (crop box, rotation applied).
pub fn pageSize(doc: *Document, index: usize) ?struct { w: f64, h: f64 } {
    const p = pdf.pages.page(&doc.doc, doc.pages, index) orelse return null;
    const s = p.displaySize();
    return .{ .w = s.w, .h = s.h };
}

// ---- fonts --------------------------------------------------------------------------------

const Family = enum { sans, serif, mono };

/// The embedded font program: TrueType outlines (quadratic), CFF or Type 1 (cubic).
const Program = union(enum) {
    tt: truetype.Font,
    cff: cff.Font,
    t1: type1.Font,

    fn unitsPerEm(self: Program) f64 {
        return switch (self) {
            .tt => |t| @floatFromInt(t.units_per_em),
            .cff => |c| @floatFromInt(c.units_per_em),
            .t1 => |t| @floatFromInt(t.units_per_em),
        };
    }

    fn outline(self: Program, gid: u16, sink: *CairoSink) void {
        switch (self) {
            .tt => |t| t.outline(gid, sink) catch {},
            .cff => |c| c.outline(gid, sink) catch {},
            .t1 => |t| t.outline(gid, sink) catch {},
        }
    }
};

/// What the renderer knows about a font beyond pdf-zig's description of it.
const RFont = struct {
    family: Family = .sans,
    bold: bool = false,
    italic: bool = false,
    symbolic: bool = false,
    composite: bool = false,
    prog: ?Program = null,
    /// `/CIDToGIDMap` of a CIDFontType2 font, decoded once (null: identity).
    cid_to_gid: ?[]const u8 = null,
};

fn rfont(d: *Draw, f: *const pdf.font.Font) *RFont {
    const doc = d.doc;
    if (doc.fonts.get(f)) |r| return r;
    const a = doc.arena.allocator();
    const r = a.create(RFont) catch return &fallback_font;
    r.* = .{};
    const base = f.base_font;
    r.bold = has(base, "bold") != null or has(base, "black") != null;
    r.italic = has(base, "italic") != null or has(base, "oblique") != null;
    if (has(base, "times") != null or has(base, "serif") != null or has(base, "georgia") != null or
        has(base, "garamond") != null or has(base, "palatino") != null or has(base, "roman") != null) r.family = .serif;
    if (has(base, "courier") != null or has(base, "mono") != null or has(base, "consolas") != null) r.family = .mono;
    r.symbolic = f.isSymbolic();
    r.composite = f.isComposite();
    loadProgram(d, r, f);
    if (f.cid_to_gid) |st| r.cid_to_gid = doc.doc.streamData(st) catch null;
    doc.fonts.put(a, f, r) catch {};
    return r;
}

var fallback_font: RFont = .{};

fn loadProgram(d: *Draw, r: *RFont, f: *const pdf.font.Font) void {
    const st = f.program.stream orelse return;
    const doc = d.doc;
    const a = doc.arena.allocator();
    const kept = doc.doc.streamData(st) catch return;
    switch (f.program.kind) {
        .none => {},
        .type1 => {
            if (type1.Font.parse(a, kept)) |t| {
                r.prog = .{ .t1 = t };
            } else |_| d.diag.note("font-type1-damaged", f.base_font);
        },
        .truetype => {
            r.prog = if (truetype.Font.parse(kept)) |t| .{ .tt = t } else |e| blk: {
                d.diag.note(if (e == error.Unsupported) "font-cff-not-read" else "font-truetype-damaged", f.base_font);
                break :blk null;
            };
        },
        .cff, .opentype => {
            const tag: u32 = if (kept.len >= 4) (@as(u32, kept[0]) << 24) | (@as(u32, kept[1]) << 16) | (@as(u32, kept[2]) << 8) | kept[3] else 0;
            if (tag == 0x4F54544F) { // OTTO: OpenType with CFF outlines
                if (cff.tableOfSfnt(kept)) |table| {
                    loadCff(d, r, table, f.base_font);
                } else {
                    r.prog = if (truetype.Font.parse(kept)) |t| .{ .tt = t } else |_| null;
                    if (r.prog == null) d.diag.note("font-opentype-damaged", f.base_font);
                }
            } else if (tag == 0x00010000 or tag == 0x74727565 or tag == 0x74746366) {
                r.prog = if (truetype.Font.parse(kept)) |t| .{ .tt = t } else |_| null;
                if (r.prog == null) d.diag.note("font-truetype-damaged", f.base_font);
            } else if (kept.len > 4 and kept[0] == 1 and kept[1] == 0) {
                loadCff(d, r, kept, f.base_font);
            } else d.diag.note("font-program-unknown", f.base_font);
        },
    }
}

fn loadCff(d: *Draw, r: *RFont, data: []const u8, name: []const u8) void {
    r.prog = if (cff.Font.parse(d.doc.arena.allocator(), data)) |c| .{ .cff = c } else |_| blk: {
        d.diag.note("font-cff-damaged", name);
        break :blk null;
    };
}

/// Which glyph of the embedded program draws this character.
fn glyphFor(r: *const RFont, prog: Program, g: display.Glyph) ?u16 {
    if (r.composite) {
        switch (prog) {
            .tt => {
                if (r.cid_to_gid) |m| {
                    const at = @as(usize, g.cid) * 2;
                    if (at + 1 >= m.len) return 0;
                    return (@as(u16, m[at]) << 8) | m[at + 1];
                }
                return @intCast(@min(g.cid, 0xFFFF));
            },
            .cff => |c| return c.glyphForCid(g.cid),
            .t1 => return null,
        }
    }
    var cp: u32 = 0;
    if (g.text.len > 0) {
        if (std.unicode.utf8Decode(g.text[0 .. std.unicode.utf8ByteSequenceLength(g.text[0]) catch 1])) |v| cp = v else |_| {}
    }
    const code = g.code;
    switch (prog) {
        .tt => |tt| {
            if (r.symbolic or cp == 0) {
                if (tt.glyphForCode(code)) |x| return x;
                if (cp != 0) if (tt.glyphForUnicode(cp)) |x| return x;
            } else {
                if (tt.glyphForUnicode(cp)) |x| return x;
                if (tt.glyphForCode(code)) |x| return x;
            }
            // A subset with no usable cmap usually numbers its glyphs by character code.
            if (!tt.hasCmap() and code < tt.num_glyphs) return @intCast(code);
        },
        .cff => |c| {
            if (r.symbolic or cp == 0) {
                if (c.glyphForCode(code)) |x| return x;
                if (cp != 0) if (c.glyphForUnicode(cp)) |x| return x;
            } else {
                if (c.glyphForUnicode(cp)) |x| return x;
                if (c.glyphForCode(code)) |x| return x;
            }
        },
        .t1 => |t| {
            if (r.symbolic or cp == 0) {
                if (t.glyphForCode(code)) |x| return x;
                if (cp != 0) if (t.glyphForUnicode(cp)) |x| return x;
            } else {
                if (t.glyphForUnicode(cp)) |x| return x;
                if (t.glyphForCode(code)) |x| return x;
            }
        },
    }
    return null;
}

/// Receives a glyph outline and draws it into cairo's current path.
const CairoSink = struct {
    cr: *cairo.Context,
    x: f64 = 0,
    y: f64 = 0,

    pub fn moveTo(self: *CairoSink, x: f64, y: f64) void {
        self.cr.moveTo(x, y);
        self.x = x;
        self.y = y;
    }
    pub fn lineTo(self: *CairoSink, x: f64, y: f64) void {
        self.cr.lineTo(x, y);
        self.x = x;
        self.y = y;
    }
    pub fn quadTo(self: *CairoSink, cx: f64, cy: f64, x: f64, y: f64) void {
        // A quadratic curve as the equivalent cubic.
        self.cr.curveTo(self.x + 2.0 / 3.0 * (cx - self.x), self.y + 2.0 / 3.0 * (cy - self.y), x + 2.0 / 3.0 * (cx - x), y + 2.0 / 3.0 * (cy - y), x, y);
        self.x = x;
        self.y = y;
    }
    pub fn curveTo(self: *CairoSink, x1: f64, y1: f64, x2: f64, y2: f64, x: f64, y: f64) void {
        self.cr.curveTo(x1, y1, x2, y2, x, y);
        self.x = x;
        self.y = y;
    }
    pub fn close(self: *CairoSink) void {
        self.cr.closePath();
    }
};

// ---- drawing ------------------------------------------------------------------------------

const max_nesting = 8;

const Draw = struct {
    doc: *Document,
    gpa: std.mem.Allocator,
    diag: *Diag,
    /// Pixels per point.
    scale: f64,
    /// Default user space to device pixels: `base` of the display list, then the scale.
    device: display.Matrix,
    nesting: u8 = 0,
};

fn cm(m: display.Matrix) cairo.Matrix {
    var r: cairo.Matrix = undefined;
    r.init(m.a, m.b, m.c, m.d, m.e, m.f);
    return r;
}

fn buildPath(cr: *cairo.Context, path: display.Path) void {
    cr.newPath();
    for (path) |s| switch (s) {
        .move => |p| cr.moveTo(p.x, p.y),
        .line => |p| cr.lineTo(p.x, p.y),
        .curve => |c| cr.curveTo(c.c1.x, c.c1.y, c.c2.x, c.c2.y, c.p.x, c.p.y),
        .close => cr.closePath(),
    };
}

fn operatorOf(blend: []const u8) cairo.Operator {
    const eq = std.mem.eql;
    if (eq(u8, blend, "Multiply")) return .multiply;
    if (eq(u8, blend, "Screen")) return .screen;
    if (eq(u8, blend, "Overlay")) return .overlay;
    if (eq(u8, blend, "Darken")) return .darken;
    if (eq(u8, blend, "Lighten")) return .lighten;
    if (eq(u8, blend, "ColorDodge")) return .color_dodge;
    if (eq(u8, blend, "ColorBurn")) return .color_burn;
    if (eq(u8, blend, "HardLight")) return .hard_light;
    if (eq(u8, blend, "SoftLight")) return .soft_light;
    if (eq(u8, blend, "Difference")) return .difference;
    if (eq(u8, blend, "Exclusion")) return .exclusion;
    return .over;
}

/// A line thinner than one device pixel (PDF's "0 w" asks for the thinnest line
/// there is) is drawn one pixel wide, as other viewers do, rather than fading away.
fn hairlineMinimum(cr: *cairo.Context) void {
    const w = cr.getLineWidth();
    var dx: f64 = w;
    var dy: f64 = 0;
    cr.userToDeviceDistance(&dx, &dy);
    const device = @sqrt(dx * dx + dy * dy);
    if (device > 0 and device < 1.0) cr.setLineWidth(w / device);
}

/// Makes `paint` the source of `cr`. Returns false if there is nothing to draw
/// with (an unsupported pattern). Patterns are anchored in the space they were
/// defined in, not in the space of the path they fill.
fn setPaint(d: *Draw, cr: *cairo.Context, paint: display.Paint, alpha: f64) bool {
    switch (paint) {
        .color => |c| {
            cr.setSourceRgba(c.r, c.g, c.b, alpha);
            return true;
        },
        .none => return false,
        .shading => |s| {
            const pat = gradient(s.shading) orelse return false;
            defer pat.destroy();
            anchor(cr, pat, s.matrix.mul(d.device));
            return true;
        },
        .tiling => |t| return setTiling(d, cr, t),
    }
}

/// Sets `pat` as the source with `to_device` as the matrix from pattern space.
fn anchor(cr: *cairo.Context, pat: *cairo.Pattern, to_device: display.Matrix) void {
    var cur: cairo.Matrix = undefined;
    cr.getMatrix(&cur);
    var pm = cm(to_device);
    cr.setMatrix(&pm);
    cr.setSource(pat);
    cr.setMatrix(&cur);
}

fn gradient(sh: display.Shading) ?*cairo.Pattern {
    const c = sh.coords;
    const pat = switch (sh.kind) {
        .axial => cairo.Pattern.linearCreate(c[0], c[1], c[2], c[3]),
        .radial => cairo.Pattern.radialCreate(c[0], c[1], c[2], c[3], c[4], c[5]),
    };
    for (sh.stops) |s| pat.gradientAddColorStopRgba(s.offset, s.color.r, s.color.g, s.color.b, 1);
    pat.setExtend(if (sh.extend_start or sh.extend_end) .pad else .none);
    return pat;
}

/// A tiling pattern: its cell is drawn once into an image at device resolution
/// and repeated.
fn setTiling(d: *Draw, cr: *cairo.Context, t: display.Tiling) bool {
    if (d.nesting >= max_nesting) return false;
    const xs = if (t.xstep == 0) t.bbox[2] - t.bbox[0] else t.xstep;
    const ys = if (t.ystep == 0) t.bbox[3] - t.bbox[1] else t.ystep;
    if (xs == 0 or ys == 0) return false;
    // Pattern space to device pixels, and how many pixels one step covers.
    const dm = t.matrix.mul(d.device);
    const sx = @sqrt(dm.a * dm.a + dm.b * dm.b);
    const sy = @sqrt(dm.c * dm.c + dm.d * dm.d);
    const pw: c_int = @intFromFloat(std.math.clamp(@ceil(@abs(xs) * sx), 1, 2048));
    const ph: c_int = @intFromFloat(std.math.clamp(@ceil(@abs(ys) * sy), 1, 2048));
    const surface = cairo.Surface.imageCreate(.argb32, pw, ph);
    defer surface.destroy();
    const cell = cairo.Context.create(surface);
    defer cell.destroy();
    // Image pixels to pattern space: the cell's lower-left corner is the bottom-left pixel.
    const fw: f64 = @floatFromInt(pw);
    const fh: f64 = @floatFromInt(ph);
    cell.translate(0, fh);
    cell.scale(fw / @abs(xs), -fh / @abs(ys));
    cell.translate(-t.bbox[0], -t.bbox[1]);
    var inner: Draw = .{ .doc = d.doc, .gpa = d.gpa, .diag = d.diag, .scale = 1, .device = .identity, .nesting = d.nesting + 1 };
    drawCommands(&inner, cell, t.cell.commands);
    surface.flush();

    const pat = cairo.Pattern.surfaceCreate(surface);
    defer pat.destroy();
    pat.setExtend(.repeat);
    pat.setFilter(.good);
    // Pattern pixels to pattern space, then to the device.
    const img_to_pattern: display.Matrix = .{ .a = @abs(xs) / fw, .d = -@abs(ys) / fh, .e = t.bbox[0], .f = t.bbox[1] + @abs(ys) };
    anchor(cr, pat, img_to_pattern.mul(dm));
    return true;
}

fn drawCommands(d: *Draw, cr: *cairo.Context, cmds: []const display.Command) void {
    var saves: usize = 0;
    for (cmds) |cmd| switch (cmd) {
        .save => {
            cr.save();
            saves += 1;
        },
        .restore => if (saves > 0) {
            cr.restore();
            saves -= 1;
        },
        .clip => |c| {
            var old: cairo.Matrix = undefined;
            cr.getMatrix(&old);
            var m = cm(c.ctm);
            cr.transform(&m);
            buildPath(cr, c.path);
            cr.setMatrix(&old);
            cr.setFillRule(if (c.rule == .even_odd) .even_odd else .winding);
            cr.clip();
        },
        .fill => |f| drawFill(d, cr, f),
        .stroke => |s| drawStroke(d, cr, s),
        .text => |t| drawText(d, cr, t),
        .image => |im| drawImage(d, cr, im),
        .shading => |s| {
            const pat = gradient(s.shading) orelse continue;
            defer pat.destroy();
            cr.save();
            defer cr.restore();
            anchor(cr, pat, s.ctm.mul(d.device));
            cr.paintWithAlpha(s.alpha);
        },
    };
    while (saves > 0) : (saves -= 1) cr.restore();
}

fn drawFill(d: *Draw, cr: *cairo.Context, f: display.Fill) void {
    cr.save();
    defer cr.restore();
    var m = cm(f.ctm);
    cr.transform(&m);
    buildPath(cr, f.path);
    cr.setFillRule(if (f.rule == .even_odd) .even_odd else .winding);
    cr.setOperator(operatorOf(f.blend));
    if (!setPaint(d, cr, f.paint, f.alpha)) {
        cr.newPath();
        return;
    }
    switch (f.paint) {
        .color => cr.fill(),
        else => {
            // A pattern: fill through the path as a clip.
            cr.clip();
            cr.paintWithAlpha(f.alpha);
        },
    }
}

fn drawStroke(d: *Draw, cr: *cairo.Context, s: display.Stroke) void {
    cr.save();
    defer cr.restore();
    var m = cm(s.ctm);
    cr.transform(&m);
    buildPath(cr, s.path);
    cr.setLineWidth(s.style.width);
    hairlineMinimum(cr);
    cr.setLineCap(switch (s.style.cap) {
        .butt => .butt,
        .round => .round,
        .square => .square,
    });
    cr.setLineJoin(switch (s.style.join) {
        .miter => .miter,
        .round => .round,
        .bevel => .bevel,
    });
    cr.setMiterLimit(s.style.miter_limit);
    if (s.style.dash.len > 0) cr.setDash(s.style.dash.ptr, @intCast(s.style.dash.len), s.style.dash_phase) else cr.setDash(undefined, 0, 0);
    cr.setOperator(operatorOf(s.blend));
    if (!setPaint(d, cr, s.paint, s.alpha)) {
        cr.newPath();
        return;
    }
    // Cairo strokes with a pattern source as it does with a colour.
    cr.stroke();
}

fn drawText(d: *Draw, cr: *cairo.Context, t: display.Text) void {
    // Mode 3 is invisible; so is 7 (clip only). Type 3 glyphs are drawn as paths already.
    if (t.mode == 3 or t.mode == 7) return;
    const r = rfont(d, t.font);
    cr.save();
    defer cr.restore();
    var ctm = cm(t.ctm);
    cr.transform(&ctm);
    var tm = cm(t.tm);
    cr.transform(&tm);
    if (!setPaint(d, cr, t.fill, t.alpha)) {
        // A pattern fill on text: use plain black rather than nothing.
        cr.setSourceRgba(0, 0, 0, t.alpha);
    }
    const stroke_only = t.mode == 1 or t.mode == 5;
    for (t.glyphs) |g| {
        cr.save();
        cr.translate(g.x, t.rise);
        // Glyphs are drawn y-down, the page is y-up.
        cr.scale(t.h_scale, -1);
        cr.selectFontFace(switch (r.family) {
            .sans => "sans-serif",
            .serif => "serif",
            .mono => "monospace",
        }, if (r.italic) .italic else .normal, if (r.bold) .bold else .normal);
        cr.setFontSize(t.size);

        var drew = false;
        if (r.prog) |prog| {
            if (glyphFor(r, prog, g)) |gid| {
                const upm = prog.unitsPerEm();
                // Outlines are y up like text space: undo the flip, scale em to size.
                cr.scale(1, -1);
                cr.scale(t.size / upm, t.size / upm);
                var sink: CairoSink = .{ .cr = cr };
                cr.newPath();
                prog.outline(gid, &sink);
                if (stroke_only) {
                    cr.setLineWidth(upm / 40.0);
                    cr.stroke();
                } else cr.fill();
                drew = true;
            }
        }
        if (!drew and g.text.len > 0 and g.text[0] > 0x20) {
            var z: [64]u8 = undefined;
            const n = @min(g.text.len, z.len - 1);
            @memcpy(z[0..n], g.text[0..n]);
            z[n] = 0;
            cr.moveTo(0, 0);
            cr.showText(@ptrCast(&z));
        }
        cr.restore();
    }
}

// ---- images -------------------------------------------------------------------------------

fn drawImage(d: *Draw, cr: *cairo.Context, im: display.Image) void {
    var scratch = std.heap.ArenaAllocator.init(d.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const doc = &d.doc.doc;

    const res = pdf.image.decode(doc, a, im) catch |e| {
        d.diag.note(if (e == error.TooBig) "image-too-big" else "image-failed", "");
        return;
    };
    const px: pdf.image.Pixels = switch (res) {
        .pixels => |p| p,
        .codec => |k| codecPixels(d, a, im, k) orelse return,
    };
    paintPixels(d, cr, im, px);
}

/// Pixels for a stream that needs a codec: JPEG through dkde's codec (stb_image
/// for what it refuses), the rest is marked with a pale box.
fn codecPixels(d: *Draw, a: std.mem.Allocator, im: display.Image, k: pdf.image.Codec) ?pdf.image.Pixels {
    const doc = &d.doc.doc;
    const name = k.name;
    if (std.mem.eql(u8, name, "DCTDecode")) {
        if (imgcodec.decode(a, k.data)) |dec| {
            const base: pdf.image.Pixels = .{ .width = @intCast(dec.width), .height = @intCast(dec.height), .rgba = dec.rgba };
            return pdf.image.withMasks(doc, a, im.stream.dict, base) catch base;
        } else |_| {}
        d.diag.note("jpeg-fallback-stb", "");
        if (im.space == .cmyk) {
            // A CMYK JPEG: take the four components raw and let the PDF's /Decode and colour space apply.
            var cx: c_int = 0;
            var cy: c_int = 0;
            var cn: c_int = 0;
            stbi_jpeg_raw_cmyk = 1;
            const raw = stbi_load_from_memory(k.data.ptr, @intCast(@min(k.data.len, std.math.maxInt(c_int))), &cx, &cy, &cn, 4);
            stbi_jpeg_raw_cmyk = 0;
            const px4 = raw orelse {
                d.diag.note("image-jpeg-failed", "");
                return null;
            };
            defer stbi_image_free(px4);
            const w: u32 = @intCast(cx);
            const h: u32 = @intCast(cy);
            return pdf.image.fromSamples(doc, a, im, px4[0 .. @as(usize, w) * h * 4], w, h, 4) catch {
                d.diag.note("image-failed", "");
                return null;
            };
        }
        var x: c_int = 0;
        var y: c_int = 0;
        var n: c_int = 0;
        const raw = stbi_load_from_memory(k.data.ptr, @intCast(@min(k.data.len, std.math.maxInt(c_int))), &x, &y, &n, 3) orelse {
            d.diag.note("image-jpeg-failed", "");
            return null;
        };
        defer stbi_image_free(raw);
        const w: u32 = @intCast(x);
        const h: u32 = @intCast(y);
        return pdf.image.fromSamples(doc, a, im, raw[0 .. @as(usize, w) * h * 3], w, h, 3) catch {
            d.diag.note("image-failed", "");
            return null;
        };
    }
    d.diag.note(if (std.mem.eql(u8, name, "JPXDecode")) "image-jpx" else if (std.mem.eql(u8, name, "JBIG2Decode")) "image-jbig2" else "image-ccitt", "");
    // A pale box where the image goes, so the layout is still readable.
    return pale(a);
}

/// A 1x1 light grey pixel, stretched over the image's place.
fn pale(a: std.mem.Allocator) ?pdf.image.Pixels {
    const px = a.alloc(u8, 4) catch return null;
    @memcpy(px, &[4]u8{ 217, 217, 217, 255 });
    return .{ .width = 1, .height = 1, .rgba = px };
}

fn paintPixels(d: *Draw, cr: *cairo.Context, im: display.Image, px: pdf.image.Pixels) void {
    const w: usize = px.width;
    const h: usize = px.height;
    if (w == 0 or h == 0) return;
    // Cairo wants premultiplied ARGB32 in native byte order.
    const argb = d.gpa.alloc(u32, w * h) catch return d.diag.note("image-failed", "");
    defer d.gpa.free(argb);
    for (0..w * h) |i| {
        const r: u32 = px.rgba[i * 4];
        const g: u32 = px.rgba[i * 4 + 1];
        const b: u32 = px.rgba[i * 4 + 2];
        const al: u32 = px.rgba[i * 4 + 3];
        argb[i] = (al << 24) | (((r * al + 127) / 255) << 16) | (((g * al + 127) / 255) << 8) | ((b * al + 127) / 255);
    }
    const surface = cairo.Surface.imageCreateForData(@ptrCast(argb.ptr), .argb32, @intCast(w), @intCast(h), @intCast(w * 4));
    defer surface.destroy();
    surface.markDirty();
    cr.save();
    defer cr.restore();
    var m = cm(im.ctm);
    cr.transform(&m);
    // Image space is the unit square with y up; the image's first row is its top.
    cr.translate(0, 1);
    cr.scale(1.0 / @as(f64, @floatFromInt(w)), -1.0 / @as(f64, @floatFromInt(h)));
    cr.setSourceSurface(surface, 0, 0);
    // Smoothing must not fade the edges into transparency: repeat the edge pixels, then clip to the image.
    cr.getSource().setFilter(.good);
    cr.getSource().setExtend(.pad);
    cr.rectangle(0, 0, @floatFromInt(w), @floatFromInt(h));
    cr.clip();
    cr.setOperator(operatorOf(im.blend));
    cr.paintWithAlpha(im.alpha);
}

// ---- pages --------------------------------------------------------------------------------

/// Draws page `index` (0-based) onto `cr`, scaled by `scale` device pixels per
/// PDF point, with the page's top-left at the origin of `cr`. What could not
/// be drawn is recorded in `diag`.
pub fn renderPage(allocator: std.mem.Allocator, doc: *Document, index: usize, cr: *cairo.Context, scale: f64, diag: *Diag) Error!void {
    const page = pdf.pages.page(&doc.doc, doc.pages, index) orelse return error.NoSuchPage;
    diag.page = index;
    var dl = doc.renderer.render(allocator, page) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.LimitExceeded => return diag.note("page-too-complex", ""),
        else => return diag.note("page-content-unreadable", @errorName(e)),
    };
    defer dl.deinit();

    cr.save();
    defer cr.restore();
    cr.scale(scale, scale);
    var base = cm(dl.base);
    cr.transform(&base);
    cr.setSourceRgb(0, 0, 0);
    cr.setLineWidth(1);
    var d: Draw = .{ .doc = doc, .gpa = allocator, .diag = diag, .scale = scale, .device = dl.base.mul(display.Matrix.scale(scale, scale)) };
    drawCommands(&d, cr, dl.commands);
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

/// Renders page 1 of `bytes` at 2x and returns the image; the caller destroys it.
fn renderTest(a: std.mem.Allocator, bytes: []const u8, diag: *Diag, w: c_int, h: c_int) !*cairo.Surface {
    const doc = try Document.openFromMemory(a, bytes);
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

fn pixel(surface: *cairo.Surface, x: usize, y: usize) [3]u8 {
    const data = surface.imageGetData().?;
    const stride: usize = @intCast(surface.imageGetStride());
    const o = y * stride + x * 4; // BGRA
    return .{ data[o + 2], data[o + 1], data[o] };
}

/// A 1x1 JPEG, to test DCTDecode.
const tiny_jpeg_b64 = "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA=";

test "paths, colours and text are drawn" {
    const a = std.testing.allocator;
    const bytes = try buildPdf(a,
        \\1 0 0 rg 10 10 60 40 re f
        \\0 0 1 RG 4 w 100 20 m 150 80 l S
        \\0 0.6 0 rg 120 10 m 190 10 l 190 40 l h f
        \\BT /F1 18 Tf 1 0 0 1 10 70 Tm 0 g (Hello PDF) Tj ET
    , "", 0, &.{});
    defer a.free(bytes);
    var diag = Diag.init(a);
    diag.verbose = false;
    defer diag.deinit();
    const surface = try renderTest(a, bytes, &diag, 400, 200);
    defer surface.destroy();
    savePng(surface, "paths");
    try std.testing.expectEqual(@as(u32, 0), diag.total());
    // The red rectangle: page (10..70, 10..50) at scale 2 from the top of a 200-high surface.
    const red = pixel(surface, 60, 150);
    try std.testing.expect(red[0] > 200 and red[1] < 60 and red[2] < 60);
    const white = pixel(surface, 300, 20);
    try std.testing.expect(white[0] > 240 and white[1] > 240 and white[2] > 240);
}

test "inline images are drawn, with their abbreviated keys" {
    const a = std.testing.allocator;
    // A 2x1 RGB inline image (red, blue) and a 1-bit stencil painted in green; the page is 200x100 at scale 2.
    const bytes = try buildPdf(a,
        "q 40 0 0 20 10 60 cm\nBI /W 2 /H 1 /CS /RGB /BPC 8 ID \xFF\x00\x00\x00\x00\xFF EI Q\n" ++
            "0 0.6 0 rg q 30 0 0 20 100 60 cm\nBI /IM true /W 1 /H 1 /BPC 1 ID \x00 EI Q\n" ++
            "0 0 0 rg 10 10 20 20 re f", "", 0, &.{});
    defer a.free(bytes);
    var diag = Diag.init(a);
    diag.verbose = false;
    defer diag.deinit();
    const surface = try renderTest(a, bytes, &diag, 400, 200);
    defer surface.destroy();
    savePng(surface, "inline-images");
    try std.testing.expectEqual(@as(u32, 0), diag.total());
    // Page y 60..80 is surface rows 40..80 (scale 2, page 100 high: y = 200 - 2*70).
    const red = pixel(surface, 30, 60);
    const blue = pixel(surface, 70, 60);
    try std.testing.expect(red[0] > 200 and red[1] < 60 and red[2] < 60);
    try std.testing.expect(blue[2] > 200 and blue[0] < 60);
    const green = pixel(surface, 230, 60);
    try std.testing.expect(green[1] > 100 and green[0] < 60);
}

test "images, forms, transparency and rotation" {
    const a = std.testing.allocator;
    // A 2x2 RGB image: red, green / blue, white.
    const rgb = [_]u8{ 255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255 };
    const bytes = try buildPdf(a,
        \\q 60 0 0 40 10 50 cm /Im1 Do Q
        \\q 1 0 0 1 100 10 cm /Fm1 Do Q
        \\/GS1 gs 0 0 1 rg 20 5 50 30 re f
        \\BT /F1 12 Tf 1 0 0 1 10 90 Tm (top) Tj ET
    , "/XObject << /Im1 6 0 R /Fm1 7 0 R >> /ExtGState << /GS1 << /ca 0.5 >> >>", 90, &.{
        .{ .dict = "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceRGB /BitsPerComponent 8", .stream = &rgb },
        .{ .dict = "/Type /XObject /Subtype /Form /BBox [0 0 40 40] /Matrix [1 0 0 1 0 0]", .stream = "0.9 0.5 0 rg 0 0 40 40 re f 0 g 5 5 10 10 re f" },
    });
    defer a.free(bytes);
    var diag = Diag.init(a);
    diag.verbose = false;
    defer diag.deinit();
    // Rotated 90 degrees the page is 100 wide and 200 tall.
    const surface = try renderTest(a, bytes, &diag, 200, 400);
    defer surface.destroy();
    savePng(surface, "image-form-rotate");
    try std.testing.expectEqual(@as(u32, 0), diag.total());
}

test "gradients and tiling patterns are drawn" {
    const a = std.testing.allocator;
    const bytes = try buildPdf(a,
        \\/Pattern cs /P1 scn 10 10 80 80 re f
        \\/Pattern cs /P2 scn 110 10 80 80 re f
    , "/Pattern << /P1 6 0 R /P2 7 0 R >>", 0, &.{
        .{ .dict = "/PatternType 2 /Shading << /ShadingType 2 /ColorSpace /DeviceRGB /Coords [10 0 90 0] /Function << /FunctionType 2 /Domain [0 1] /C0 [1 0 0] /C1 [0 0 1] /N 1 >> >>" },
        .{ .dict = "/PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 20 20] /XStep 20 /YStep 20 /Resources << >>", .stream = "0 0.6 0 rg 0 0 10 10 re f 10 10 10 10 re f" },
    });
    defer a.free(bytes);
    var diag = Diag.init(a);
    diag.verbose = false;
    defer diag.deinit();
    const surface = try renderTest(a, bytes, &diag, 400, 200);
    defer surface.destroy();
    savePng(surface, "patterns");
    try std.testing.expectEqual(@as(u32, 0), diag.total());
    // The gradient runs from red (left) to blue (right).
    const left = pixel(surface, 24, 100);
    const right = pixel(surface, 170, 100);
    try std.testing.expect(left[0] > right[0] and right[2] > left[2]);
    // The tiling pattern has green cells and white gaps: both occur in a row.
    var green: usize = 0;
    var blank: usize = 0;
    for (230..380) |x| {
        const p = pixel(surface, x, 100);
        if (p[1] > 100 and p[0] < 80) green += 1;
        if (p[0] > 230 and p[1] > 230 and p[2] > 230) blank += 1;
    }
    try std.testing.expect(green > 20 and blank > 20);
}

test "a JPEG image is decoded, and unsupported image types are counted" {
    const a = std.testing.allocator;
    var tiny_jpeg: [134]u8 = undefined;
    try std.base64.standard.Decoder.decode(&tiny_jpeg, tiny_jpeg_b64);
    const bytes = try buildPdf(a,
        \\q 80 0 0 40 10 10 cm /Im1 Do Q
        \\q 80 0 0 40 100 10 cm /Im2 Do Q
    , "/XObject << /Im1 6 0 R /Im2 7 0 R >>", 0, &.{
        .{ .dict = "/Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode", .stream = &tiny_jpeg },
        .{ .dict = "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 1 /Filter /JBIG2Decode", .stream = "x" },
    });
    defer a.free(bytes);
    var diag = Diag.init(a);
    diag.verbose = false;
    defer diag.deinit();
    const surface = try renderTest(a, bytes, &diag, 400, 200);
    defer surface.destroy();
    savePng(surface, "jpeg-and-unsupported");
    try std.testing.expectEqual(@as(?u32, 1), diag.counts.get("image-jbig2"));
}

test {
    _ = @import("diag.zig");
    _ = @import("cff.zig");
    _ = @import("type1.zig");
}
