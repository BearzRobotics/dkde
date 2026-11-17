//! Draws a typeset line (typeset.zig's tree): stacked fractions with a bar, raised powers, roots with
//! their bar, and parentheses that grow with what is inside them. A line with nothing to stack stays
//! an ordinary label (`create` returns null for it), so only lines that need it pay for the drawing.

const std = @import("std");
const cairo = @import("cairo1");
const gdk = @import("gdk4");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const pango = @import("pango1");
const pangocairo = @import("pangocairo1");

const typeset = @import("typeset.zig");
const Node = typeset.Node;

const Metrics = struct { w: f64, asc: f64, desc: f64 };

const Ink = struct {
    layout: *pango.Layout,
    /// The font size of the surrounding text, in Pango units.
    base: c_int,
    desc: *pango.FontDescription,

    fn font(self: Ink, scale: f64) void {
        self.desc.setSize(@intFromFloat(@as(f64, @floatFromInt(self.base)) * scale));
        self.layout.setFontDescription(self.desc);
    }

    fn em(self: Ink, scale: f64) f64 {
        return @as(f64, @floatFromInt(self.base)) / 1024.0 * scale * 4.0 / 3.0;
    }

    fn textMetrics(self: Ink, text: []const u8, scale: f64) Metrics {
        self.font(scale);
        self.layout.setText(@ptrCast(text.ptr), @intCast(text.len));
        var w: c_int = 0;
        var h: c_int = 0;
        self.layout.getPixelSize(&w, &h);
        const base: f64 = @as(f64, @floatFromInt(self.layout.getBaseline())) / 1024.0;
        return .{ .w = @floatFromInt(w), .asc = base, .desc = @as(f64, @floatFromInt(h)) - base };
    }
};

const gap = 3.0;

/// Space either side of a lone operator, so "1/3+1/6" does not run its fractions together.
fn pad(ink: Ink, t: []const u8, scale: f64) f64 {
    if (t.len > 3) return 0;
    for (t) |c| if (std.mem.indexOfScalar(u8, "+-=<>*", c) == null) {
        return if (std.mem.eql(u8, t, "\u{2212}") or std.mem.eql(u8, t, "\u{00D7}")) ink.em(scale) * 0.2 else 0;
    };
    return ink.em(scale) * 0.2;
}

fn measure(ink: Ink, n: Node, scale: f64) Metrics {
    switch (n) {
        .text => |t| {
            var m = ink.textMetrics(t, scale);
            m.w += pad(ink, t, scale) * 2;
            return m;
        },
        .row => |items| {
            var m: Metrics = .{ .w = 0, .asc = 0, .desc = 0 };
            for (items) |x| {
                const c = measure(ink, x, scale);
                m.w += c.w;
                m.asc = @max(m.asc, c.asc);
                m.desc = @max(m.desc, c.desc);
            }
            return m;
        },
        .sup => |s| {
            const c = measure(ink, s.*, scale * 0.7);
            const raise = ink.em(scale) * 0.45;
            return .{ .w = c.w + 1, .asc = c.asc + raise, .desc = @max(0, c.desc - raise) };
        },
        .group => |g| {
            const c = measure(ink, g.*, scale);
            const line = ink.textMetrics("(", scale);
            const tall = c.asc + c.desc > (line.asc + line.desc) * 1.25;
            if (!tall) return .{ .w = c.w + line.w * 2, .asc = @max(c.asc, line.asc), .desc = @max(c.desc, line.desc) };
            return .{ .w = c.w + ink.em(scale) * 0.7, .asc = c.asc + 2, .desc = c.desc + 2 };
        },
        .sqrt => |s| {
            const c = measure(ink, s.*, scale);
            return .{ .w = c.w + ink.em(scale) * 0.9 + 3, .asc = c.asc + 4, .desc = c.desc };
        },
        .frac => |f| {
            const sub = scale * @as(f64, if (scale < 0.95) 0.9 else 1.0);
            const a = measure(ink, f.num.*, sub);
            const b = measure(ink, f.den.*, sub);
            const axis = ink.em(scale) * 0.28;
            return .{
                .w = @max(a.w, b.w) + 6,
                .asc = axis + gap + a.asc + a.desc,
                .desc = b.asc + b.desc + gap - axis,
            };
        },
    }
}

fn draw(ink: Ink, cr: *cairo.Context, n: Node, x: f64, base: f64, scale: f64) f64 {
    switch (n) {
        .text => |t| {
            const m = ink.textMetrics(t, scale);
            const p = pad(ink, t, scale);
            cr.moveTo(x + p, base - m.asc);
            pangocairo.showLayout(cr, ink.layout);
            return m.w + p * 2;
        },
        .row => |items| {
            var cx = x;
            for (items) |c| cx += draw(ink, cr, c, cx, base, scale);
            return cx - x;
        },
        .sup => |s| {
            const m = measure(ink, n, scale);
            const c = draw(ink, cr, s.*, x, base - ink.em(scale) * 0.45, scale * 0.7);
            _ = m;
            return c + 1;
        },
        .group => |g| {
            const m = measure(ink, n, scale);
            const c = measure(ink, g.*, scale);
            const line = ink.textMetrics("(", scale);
            const tall = c.asc + c.desc > (line.asc + line.desc) * 1.25;
            if (!tall) {
                const lw = draw(ink, cr, .{ .text = "(" }, x, base, scale);
                const iw = draw(ink, cr, g.*, x + lw, base, scale);
                _ = draw(ink, cr, .{ .text = ")" }, x + lw + iw, base, scale);
                return m.w;
            }
            // Tall content: a drawn parenthesis on each side.
            const top = base - m.asc;
            const bottom = base + m.desc;
            const arm = ink.em(scale) * 0.3;
            cr.setLineWidth(1.2);
            cr.moveTo(x + arm, top);
            cr.curveTo(x, top + (bottom - top) * 0.3, x, top + (bottom - top) * 0.7, x + arm, bottom);
            cr.stroke();
            _ = draw(ink, cr, g.*, x + arm + 2, base, scale);
            const rx = x + arm + 2 + c.w + 2;
            cr.moveTo(rx, top);
            cr.curveTo(rx + arm, top + (bottom - top) * 0.3, rx + arm, top + (bottom - top) * 0.7, rx, bottom);
            cr.stroke();
            return m.w;
        },
        .sqrt => |s| {
            const m = measure(ink, n, scale);
            const c = measure(ink, s.*, scale);
            const sign = ink.em(scale) * 0.9;
            const top = base - c.asc - 3;
            const bottom = base + c.desc;
            cr.setLineWidth(1.2);
            cr.moveTo(x + 1, base - c.asc * 0.35);
            cr.lineTo(x + sign * 0.3, base - c.asc * 0.4);
            cr.lineTo(x + sign * 0.55, bottom);
            cr.lineTo(x + sign, top);
            cr.lineTo(x + sign + c.w + 3, top);
            cr.stroke();
            _ = draw(ink, cr, s.*, x + sign + 2, base, scale);
            return m.w;
        },
        .frac => |f| {
            const sub = scale * @as(f64, if (scale < 0.95) 0.9 else 1.0);
            const m = measure(ink, n, scale);
            const a = measure(ink, f.num.*, sub);
            const b = measure(ink, f.den.*, sub);
            const axis = ink.em(scale) * 0.28;
            const bar_y = base - axis;
            // The bar.
            cr.setLineWidth(1.2);
            cr.moveTo(x + 1, bar_y);
            cr.lineTo(x + m.w - 1, bar_y);
            cr.stroke();
            // Centred above and below it.
            _ = draw(ink, cr, f.num.*, x + (m.w - a.w) / 2, bar_y - gap - a.desc, sub);
            _ = draw(ink, cr, f.den.*, x + (m.w - b.w) / 2, bar_y + gap + b.asc, sub);
            return m.w;
        },
    }
}

pub const MathView = struct {
    arena: std.heap.ArenaAllocator,
    text: []u8,
    tree: Node,
    area: *gtk.DrawingArea,
    /// Right-aligned lines (history results) or left-aligned.
    size_w: c_int = 0,
    size_h: c_int = 0,

    /// A widget that shows `text` typeset, or null when `text` has nothing to stack (use a label).
    pub fn create(gpa: std.mem.Allocator, text: []const u8, css_class: ?[:0]const u8) ?*gtk.Widget {
        var arena = std.heap.ArenaAllocator.init(gpa);
        const owned = arena.allocator().dupe(u8, text) catch {
            arena.deinit();
            return null;
        };
        const tree = typeset.parse(arena.allocator(), owned) catch {
            arena.deinit();
            return null;
        };
        if (!typeset.isStacked(tree)) {
            arena.deinit();
            return null;
        }
        const self = gpa.create(MathView) catch {
            arena.deinit();
            return null;
        };
        self.* = .{ .arena = arena, .text = owned, .tree = tree, .area = gtk.DrawingArea.new() };
        const widget = self.area.as(gtk.Widget);
        if (css_class) |c| widget.addCssClass(c);
        widget.setHalign(.end);
        self.area.setDrawFunc(onDraw, self, null);
        _ = gtk.Widget.signals.destroy.connect(self.area, *MathView, &onDestroy, self, .{});
        self.fit();
        return widget;
    }

    fn onDestroy(_: *gtk.DrawingArea, self: *MathView) callconv(.c) void {
        const gpa = std.heap.c_allocator;
        self.arena.deinit();
        gpa.destroy(self);
    }

    fn ink(_: *MathView, layout: *pango.Layout) ?Ink {
        const context = layout.getContext();
        const base_desc = context.getFontDescription() orelse return null;
        const copy = base_desc.copy() orelse return null;
        return .{ .layout = layout, .base = base_desc.getSize(), .desc = copy };
    }

    /// Asks for the size the line needs at the font it is drawn in.
    fn fit(self: *MathView) void {
        const widget = self.area.as(gtk.Widget);
        const layout = widget.createPangoLayout(null);
        defer layout.as(gobject.Object).unref();
        const k = self.ink(layout) orelse return;
        defer k.desc.free();
        const m = measure(k, self.tree, 1.0);
        const w: c_int = @intFromFloat(@ceil(m.w) + 2);
        const h: c_int = @intFromFloat(@ceil(m.asc + m.desc) + 2);
        if (w == self.size_w and h == self.size_h) return;
        self.size_w = w;
        self.size_h = h;
        self.area.setContentWidth(w);
        self.area.setContentHeight(h);
    }

    fn onDraw(area: *gtk.DrawingArea, cr: *cairo.Context, _: c_int, height: c_int, data: ?*anyopaque) callconv(.c) void {
        const self: *MathView = @ptrCast(@alignCast(data.?));
        const widget = area.as(gtk.Widget);
        const layout = widget.createPangoLayout(null);
        defer layout.as(gobject.Object).unref();
        const k = self.ink(layout) orelse return;
        defer k.desc.free();
        var fg: gdk.RGBA = undefined;
        widget.getColor(&fg);
        cr.setSourceRgba(fg.f_red, fg.f_green, fg.f_blue, fg.f_alpha);
        const m = measure(k, self.tree, 1.0);
        // The font may differ from the one the size was asked for (CSS applied after creation).
        const need_w: c_int = @intFromFloat(@ceil(m.w) + 2);
        if (need_w != self.size_w) {
            self.fit();
            widget.queueResize();
        }
        const h: f64 = @floatFromInt(height);
        const base = (h - (m.asc + m.desc)) / 2 + m.asc;
        _ = draw(k, cr, self.tree, 1, base, 1.0);
    }
};
