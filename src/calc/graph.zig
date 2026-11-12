//! The Graph pane: up to six functions of x drawn together, with axes and
//! a grid, moved by dragging and zoomed with the wheel or a pinch. Pointing
//! at a curve shows the point under the pointer; the places where a curve
//! crosses zero, or two curves cross, are marked. The picture can be saved
//! as a PNG.

const std = @import("std");
const cairo = @import("cairo1");
const gdk = @import("gdk4");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const pango = @import("pango1");
const pangocairo = @import("pangocairo1");
const common = @import("common");

const eval = @import("eval.zig");
const num = @import("num.zig");
const calculus = @import("calculus.zig");

const t = common.tr;
const max_curves = 6;

const colours = [max_curves][3]f64{
    .{ 0.11, 0.42, 0.85 },
    .{ 0.85, 0.22, 0.18 },
    .{ 0.15, 0.62, 0.30 },
    .{ 0.60, 0.30, 0.75 },
    .{ 0.90, 0.55, 0.05 },
    .{ 0.05, 0.60, 0.65 },
};

const Curve = struct {
    row: *gtk.Box,
    /// "y =", or the formula's letter ("A =").
    prefix: *gtk.Label,
    entry: *gtk.Entry,
    swatch: *gtk.DrawingArea,
    error_label: *gtk.Label,
    index: usize,
    graph: *Graph,
};

const Mark = struct { x: f64, y: f64, curve: usize };

pub const Graph = struct {
    gpa: std.mem.Allocator,
    session: *eval.Session,
    root: *gtk.Box,
    area: *gtk.DrawingArea,
    list: *gtk.Box,
    status: *gtk.Label,
    curves: std.ArrayList(*Curve) = .empty,
    /// The x and y shown, in the middle and per pixel.
    cx: f64 = 0,
    cy: f64 = 0,
    /// Units per pixel, across and up (they differ once a curve is fitted).
    sx: f64 = 1.0 / 40.0,
    sy: f64 = 1.0 / 40.0,
    /// What the axes stand for, when a formula is drawn ("r", "A").
    x_title: [24]u8 = @splat(0),
    y_title: [24]u8 = @splat(0),
    // The Scale panel.
    range: [4]*gtk.Entry = undefined,
    same_scale: *gtk.CheckButton = undefined,
    /// A curve to fit the view to once the graph has its size.
    pending_fit: ?usize = null,
    drag_cx: f64 = 0,
    drag_cy: f64 = 0,
    pinch_scale: f64 = 1,
    pointer: ?[2]f64 = null,
    /// Worked out at each drawing.
    arena: std.heap.ArenaAllocator,
    marks: std.ArrayList(Mark) = .empty,

    pub fn create(gpa: std.mem.Allocator, session: *eval.Session) !*Graph {
        const self = try gpa.create(Graph);
        self.* = .{
            .gpa = gpa,
            .session = session,
            .root = gtk.Box.new(.vertical, 6),
            .area = gtk.DrawingArea.new(),
            .list = gtk.Box.new(.vertical, 4),
            .status = gtk.Label.new(""),
            .arena = .init(gpa),
        };
        const area = self.area.as(gtk.Widget);
        area.setVexpand(1);
        area.setHexpand(1);
        area.setSizeRequest(360, 300);
        area.addCssClass("dkde-calc-graph");
        self.area.setDrawFunc(onDraw, self, null);

        const drag = gtk.GestureDrag.new();
        _ = gtk.GestureDrag.signals.drag_begin.connect(drag, *Graph, &onDragBegin, self, .{});
        _ = gtk.GestureDrag.signals.drag_update.connect(drag, *Graph, &onDragUpdate, self, .{});
        area.addController(drag.as(gtk.EventController));
        const scroll = gtk.EventControllerScroll.new(.{ .vertical = true });
        _ = gtk.EventControllerScroll.signals.scroll.connect(scroll, *Graph, &onScroll, self, .{});
        area.addController(scroll.as(gtk.EventController));
        const pinch = gtk.GestureZoom.new();
        _ = gtk.Gesture.signals.begin.connect(pinch.as(gtk.Gesture), *Graph, &onPinchBegin, self, .{});
        _ = gtk.GestureZoom.signals.scale_changed.connect(pinch, *Graph, &onPinch, self, .{});
        area.addController(pinch.as(gtk.EventController));
        const motion = gtk.EventControllerMotion.new();
        _ = gtk.EventControllerMotion.signals.motion.connect(motion, *Graph, &onMotion, self, .{});
        _ = gtk.EventControllerMotion.signals.leave.connect(motion, *Graph, &onLeave, self, .{});
        area.addController(motion.as(gtk.EventController));

        const frame = gtk.Frame.new(null);
        frame.setChild(area);
        self.root.append(frame.as(gtk.Widget));

        self.status.setXalign(0);
        self.status.as(gtk.Widget).addCssClass("dim-label");
        self.status.setWrap(1);
        self.status.setMaxWidthChars(40);
        self.status.setText(t("Type a function of x below, press Plot on the scientific keypad, or Graph in a formula. Angles are in radians; drag to move, scroll to zoom."));
        self.root.append(self.status.as(gtk.Widget));

        self.root.append(self.list.as(gtk.Widget));

        const buttons = gtk.Box.new(.horizontal, 6);
        const add = gtk.Button.newWithLabel(t("Add Function"));
        _ = gtk.Button.signals.clicked.connect(add, *Graph, &onAdd, self, .{});
        const reset = gtk.Button.newWithLabel(t("Reset View"));
        _ = gtk.Button.signals.clicked.connect(reset, *Graph, &onReset, self, .{});
        const save = gtk.Button.newWithLabel(t("Save as Picture…"));
        _ = gtk.Button.signals.clicked.connect(save, *Graph, &onSave, self, .{});
        buttons.append(add.as(gtk.Widget));
        buttons.append(self.buildScale());
        buttons.append(reset.as(gtk.Widget));
        buttons.append(save.as(gtk.Widget));
        self.root.append(buttons.as(gtk.Widget));

        self.addCurve("");
        return self;
    }

    /// The Scale… button: the ranges shown, typed in; fitting; one scale for both axes.
    fn buildScale(self: *Graph) *gtk.Widget {
        const button = gtk.MenuButton.new();
        button.setLabel(t("Scale…"));
        button.as(gtk.Widget).setTooltipText(t("Set the ranges shown on the axes"));
        const popover = gtk.Popover.new();
        const g = gtk.Grid.new();
        g.setColumnSpacing(6);
        g.setRowSpacing(6);
        inline for (.{ "setMarginStart", "setMarginEnd", "setMarginTop", "setMarginBottom" }) |m| @field(gtk.Widget, m)(g.as(gtk.Widget), 8);
        const labels = [_][:0]const u8{ "x from", "to", "y from", "to" };
        for (labels, 0..) |l, i| {
            const lab = gtk.Label.new(l);
            lab.setXalign(1);
            const e = gtk.Entry.new();
            e.as(gtk.Editable).setWidthChars(9);
            e.setActivatesDefault(1);
            _ = gtk.Entry.signals.activate.connect(e, *Graph, &onRangeEnter, self, .{});
            self.range[i] = e;
            const row: c_int = @intCast(i / 2);
            const col: c_int = @intCast((i % 2) * 2);
            g.attach(lab.as(gtk.Widget), col, row, 1, 1);
            g.attach(e.as(gtk.Widget), col + 1, row, 1, 1);
        }
        self.same_scale = gtk.CheckButton.newWithLabel(t("Same scale on both axes"));
        _ = gtk.CheckButton.signals.toggled.connect(self.same_scale, *Graph, &onSameScale, self, .{});
        g.attach(self.same_scale.as(gtk.Widget), 0, 2, 4, 1);
        const actions = gtk.Box.new(.horizontal, 6);
        const fit_button = gtk.Button.newWithLabel(t("Fit to Curves"));
        _ = gtk.Button.signals.clicked.connect(fit_button, *Graph, &onFitAll, self, .{});
        const apply = gtk.Button.newWithLabel(t("Apply"));
        apply.as(gtk.Widget).addCssClass("suggested-action");
        _ = gtk.Button.signals.clicked.connect(apply, *Graph, &onApplyRange, self, .{});
        actions.append(fit_button.as(gtk.Widget));
        actions.append(apply.as(gtk.Widget));
        actions.as(gtk.Widget).setHalign(.end);
        g.attach(actions.as(gtk.Widget), 0, 3, 4, 1);
        popover.setChild(g.as(gtk.Widget));
        _ = gtk.Widget.signals.show.connect(popover, *Graph, &onScaleShown, self, .{});
        button.setPopover(popover);
        return button.as(gtk.Widget);
    }

    /// The panel opens with the ranges shown now.
    fn onScaleShown(_: *gtk.Popover, self: *Graph) callconv(.c) void {
        const sz = self.size();
        const values = [4]f64{ self.toX(0), self.toX(sz[0]), self.toY(sz[1]), self.toY(0) };
        for (values, 0..) |v, i| {
            var buf: [32]u8 = undefined;
            self.range[i].as(gtk.Editable).setText(std.fmt.bufPrintSentinel(&buf, "{d:.6}", .{v}, 0) catch "");
            trimZeros(self.range[i]);
        }
    }

    fn trimZeros(e: *gtk.Entry) void {
        const text = std.mem.span(e.as(gtk.Editable).getText());
        if (std.mem.indexOfScalar(u8, text, '.') == null) return;
        var end = text.len;
        while (end > 0 and text[end - 1] == '0') end -= 1;
        if (end > 0 and text[end - 1] == '.') end -= 1;
        var buf: [32]u8 = undefined;
        e.as(gtk.Editable).setText(std.fmt.bufPrintSentinel(&buf, "{s}", .{text[0..end]}, 0) catch return);
    }

    /// A range field's value; expressions such as 2π work.
    fn rangeValue(self: *Graph, i: usize) ?f64 {
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();
        var p: eval.Problem = .{};
        const n = eval.parseExpr(a, std.mem.span(self.range[i].as(gtk.Editable).getText()), .{ .angle = .radians }, &p) catch return null;
        var ev: eval.Eval = .{ .a = a, .session = self.session, .mode = .{ .angle = .radians }, .problem = &p };
        const v = (ev.eval(n, null) catch return null).toFloat();
        return if (std.math.isFinite(v)) v else null;
    }

    fn onRangeEnter(_: *gtk.Entry, self: *Graph) callconv(.c) void {
        self.applyRange();
    }

    fn onApplyRange(_: *gtk.Button, self: *Graph) callconv(.c) void {
        self.applyRange();
    }

    fn applyRange(self: *Graph) void {
        const x0 = self.rangeValue(0) orelse return;
        const x1 = self.rangeValue(1) orelse return;
        const y0 = self.rangeValue(2) orelse return;
        const y1 = self.rangeValue(3) orelse return;
        if (x1 <= x0 or y1 <= y0) return self.note("The end of a range must be past its start");
        const sz = self.size();
        self.sx = (x1 - x0) / sz[0];
        self.cx = (x0 + x1) / 2;
        self.sy = (y1 - y0) / sz[1];
        self.cy = (y0 + y1) / 2;
        if (self.same_scale.getActive() != 0) self.sy = self.sx;
        self.refresh();
    }

    fn onSameScale(cb: *gtk.CheckButton, self: *Graph) callconv(.c) void {
        if (cb.getActive() == 0) return;
        // Circles look round: the vertical scale follows the horizontal.
        self.sy = self.sx;
        self.refresh();
        self.onScaleShownRefresh();
    }

    fn onScaleShownRefresh(self: *Graph) void {
        onScaleShown(undefined, self);
    }

    /// Fits the vertical range to every curve over the x range shown.
    fn onFitAll(_: *gtk.Button, self: *Graph) callconv(.c) void {
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();
        var problem: eval.Problem = .{};
        var ev: eval.Eval = .{ .a = a, .session = self.session, .mode = .{ .angle = .radians }, .problem = &problem };
        const parsed = self.parseCurves(a, &ev) catch return;
        const sz = self.size();
        var ymin = std.math.inf(f64);
        var ymax = -std.math.inf(f64);
        for (parsed) |pc| {
            const n = pc.node orelse continue;
            var px: f64 = 0;
            while (px <= sz[0]) : (px += 2) {
                const y = ev.float(n, "x", self.toX(px));
                if (!std.math.isFinite(y)) continue;
                ymin = @min(ymin, y);
                ymax = @max(ymax, y);
            }
        }
        if (!std.math.isFinite(ymin)) return;
        if (ymax - ymin < 1e-9) {
            ymin -= 1;
            ymax += 1;
        }
        const margin = (ymax - ymin) * 0.08;
        self.sy = (ymax - ymin + 2 * margin) / sz[1];
        self.cy = (ymin + ymax) / 2;
        self.same_scale.setActive(0);
        self.refresh();
        self.onScaleShownRefresh();
    }

    pub fn destroy(self: *Graph) void {
        for (self.curves.items) |c| self.gpa.destroy(c);
        self.curves.deinit(self.gpa);
        self.marks.deinit(self.gpa);
        self.arena.deinit();
        self.gpa.destroy(self);
    }

    pub fn widget(self: *Graph) *gtk.Widget {
        return self.root.as(gtk.Widget);
    }

    /// Plots `text` (from Plot or a formula's Graph button) in the first empty
    /// row (or a new one), named `y` along `x` when a formula gives letters,
    /// and fits the view to it.
    pub fn plot(self: *Graph, text: []const u8, letters: ?struct { y: []const u8, x: []const u8 }) void {
        var buf: [512]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{text}, 0) catch return;
        const curve = for (self.curves.items) |c| {
            if (std.mem.span(c.entry.as(gtk.Editable).getText()).len == 0) break c;
        } else blk: {
            if (self.curves.items.len < max_curves) self.addCurve("");
            break :blk self.curves.items[self.curves.items.len - 1];
        };
        var pb: [40]u8 = undefined;
        curve.prefix.setText(if (letters) |l| (std.fmt.bufPrintSentinel(&pb, "{s} =", .{l.y}, 0) catch "y =") else "y =");
        setTitle(&self.x_title, if (letters) |l| l.x else "");
        setTitle(&self.y_title, if (letters) |l| l.y else "");
        curve.entry.as(gtk.Editable).setText(z);
        self.fit(curve);
    }

    fn setTitle(dst: *[24]u8, text: []const u8) void {
        dst.* = @splat(0);
        const n = @min(text.len, dst.len - 1);
        @memcpy(dst[0..n], text[0..n]);
    }

    /// Fits the view to a curve: x from −10 to 10 (or 0 to 10 when the curve
    /// only exists for positive x), y to what the curve does there.
    fn fit(self: *Graph, curve: *Curve) void {
        // Not shown yet (the pane has just opened): when it is drawn.
        if (self.area.as(gtk.Widget).getWidth() < 10) {
            self.pending_fit = curve.index;
            return self.refresh();
        }
        self.pending_fit = null;
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();
        var problem: eval.Problem = .{};
        var ev: eval.Eval = .{ .a = a, .session = self.session, .mode = .{ .angle = .radians }, .problem = &problem };
        const parsed = self.parseCurves(a, &ev) catch return;
        const n = parsed[curve.index].node orelse return;
        var lo: f64 = -10;
        const hi: f64 = 10;
        var negative_ok = false;
        var ymin = std.math.inf(f64);
        var ymax = -std.math.inf(f64);
        var i: usize = 0;
        while (i <= 400) : (i += 1) {
            const x = -10 + 20 * @as(f64, @floatFromInt(i)) / 400;
            const y = ev.float(n, "x", x);
            if (!std.math.isFinite(y)) continue;
            if (x < 0) negative_ok = true;
            ymin = @min(ymin, y);
            ymax = @max(ymax, y);
        }
        if (!std.math.isFinite(ymin)) return self.refresh();
        // Lengths, areas, money...: when only x ≥ 0 makes sense, show that.
        if (!negative_ok or self.x_title[0] != 0) lo = 0;
        if (self.x_title[0] != 0) {
            // Recompute y over the shown x only.
            ymin = std.math.inf(f64);
            ymax = -std.math.inf(f64);
            i = 0;
            while (i <= 400) : (i += 1) {
                const x = lo + (hi - lo) * @as(f64, @floatFromInt(i)) / 400;
                const y = ev.float(n, "x", x);
                if (!std.math.isFinite(y)) continue;
                ymin = @min(ymin, y);
                ymax = @max(ymax, y);
            }
        }
        // Keep the x axis in view when the curve is near it.
        if (ymin > 0 and ymin < (ymax - ymin)) ymin = 0;
        if (ymax < 0 and -ymax < (ymax - ymin)) ymax = 0;
        if (ymax - ymin < 1e-9) {
            ymin -= 1;
            ymax += 1;
        }
        const sz = self.size();
        const margin = (ymax - ymin) * 0.08;
        self.sx = (hi - lo) * 1.1 / sz[0];
        self.cx = (lo + hi) / 2;
        self.sy = (ymax - ymin + 2 * margin) / sz[1];
        self.cy = (ymin + ymax) / 2;
        self.refresh();
    }

    /// A line under the graph (what the axes are).
    pub fn note(self: *Graph, text: []const u8) void {
        var buf: [256]u8 = undefined;
        self.status.setText(std.fmt.bufPrintSentinel(&buf, "{s}. Drag to move, scroll to zoom.", .{text}, 0) catch "");
    }

    /// The calculator's functions or variables changed: draw again.
    pub fn refresh(self: *Graph) void {
        self.area.as(gtk.Widget).queueDraw();
    }

    fn addCurve(self: *Graph, text: [:0]const u8) void {
        if (self.curves.items.len >= max_curves) return;
        const c = self.gpa.create(Curve) catch return;
        c.* = .{
            .prefix = undefined,
            .row = gtk.Box.new(.horizontal, 6),
            .entry = gtk.Entry.new(),
            .swatch = gtk.DrawingArea.new(),
            .error_label = gtk.Label.new(""),
            .index = self.curves.items.len,
            .graph = self,
        };
        self.curves.append(self.gpa, c) catch {
            self.gpa.destroy(c);
            return;
        };
        c.swatch.as(gtk.Widget).setSizeRequest(14, 14);
        c.swatch.as(gtk.Widget).setValign(.center);
        c.swatch.setDrawFunc(onSwatch, c, null);
        const prefix = gtk.Label.new("y =");
        c.prefix = prefix;
        c.entry.as(gtk.Widget).setHexpand(1);
        c.entry.setPlaceholderText(t("a function of x, e.g. x² − 2"));
        c.entry.as(gtk.Editable).setText(text);
        _ = gtk.Editable.signals.changed.connect(c.entry.as(gtk.Editable), *Curve, &onCurveChanged, c, .{});
        c.error_label.as(gtk.Widget).addCssClass("error");
        c.error_label.as(gtk.Widget).setVisible(0);
        c.row.append(c.swatch.as(gtk.Widget));
        c.row.append(prefix.as(gtk.Widget));
        c.row.append(c.entry.as(gtk.Widget));
        c.row.append(c.error_label.as(gtk.Widget));
        self.list.append(c.row.as(gtk.Widget));
        self.refresh();
    }

    fn onSwatch(_: *gtk.DrawingArea, cr: *cairo.Context, w: c_int, h: c_int, data: ?*anyopaque) callconv(.c) void {
        const c: *Curve = @ptrCast(@alignCast(data.?));
        const col = colours[c.index];
        cr.setSourceRgb(col[0], col[1], col[2]);
        cr.arc(@as(f64, @floatFromInt(w)) / 2, @as(f64, @floatFromInt(h)) / 2, 6, 0, 2 * std.math.pi);
        cr.fill();
    }

    fn onCurveChanged(_: *gtk.Editable, c: *Curve) callconv(.c) void {
        c.graph.refresh();
    }

    fn onAdd(_: *gtk.Button, self: *Graph) callconv(.c) void {
        self.addCurve("");
        if (self.curves.items.len > 0) _ = self.curves.items[self.curves.items.len - 1].entry.as(gtk.Widget).grabFocus();
    }

    fn onReset(_: *gtk.Button, self: *Graph) callconv(.c) void {
        self.cx = 0;
        self.cy = 0;
        self.sx = 1.0 / 40.0;
        self.sy = 1.0 / 40.0;
        self.refresh();
    }

    // ---- view -------------------------------------------------------------------------

    fn size(self: *Graph) [2]f64 {
        const w = self.area.as(gtk.Widget);
        return .{ @floatFromInt(@max(1, w.getWidth())), @floatFromInt(@max(1, w.getHeight())) };
    }

    fn toX(self: *Graph, px: f64) f64 {
        return self.cx + (px - self.size()[0] / 2) * self.sx;
    }

    fn toY(self: *Graph, py: f64) f64 {
        return self.cy - (py - self.size()[1] / 2) * self.sy;
    }

    fn toPx(self: *Graph, x: f64) f64 {
        return (x - self.cx) / self.sx + self.size()[0] / 2;
    }

    fn toPy(self: *Graph, y: f64) f64 {
        return -(y - self.cy) / self.sy + self.size()[1] / 2;
    }

    fn zoomAt(self: *Graph, factor: f64, px: f64, py: f64) void {
        const x = self.toX(px);
        const y = self.toY(py);
        self.sx = std.math.clamp(self.sx * factor, 1e-12, 1e12);
        self.sy = std.math.clamp(self.sy * factor, 1e-12, 1e12);
        // Keep (x, y) under the pointer.
        self.cx = x - (px - self.size()[0] / 2) * self.sx;
        self.cy = y + (py - self.size()[1] / 2) * self.sy;
        self.refresh();
    }

    fn onDragBegin(_: *gtk.GestureDrag, _: f64, _: f64, self: *Graph) callconv(.c) void {
        self.drag_cx = self.cx;
        self.drag_cy = self.cy;
    }

    fn onDragUpdate(_: *gtk.GestureDrag, dx: f64, dy: f64, self: *Graph) callconv(.c) void {
        self.cx = self.drag_cx - dx * self.sx;
        self.cy = self.drag_cy + dy * self.sy;
        self.refresh();
    }

    fn onScroll(ctrl: *gtk.EventControllerScroll, _: f64, dy: f64, self: *Graph) callconv(.c) c_int {
        const p = self.pointer orelse .{ self.size()[0] / 2, self.size()[1] / 2 };
        const k: f64 = if (ctrl.getUnit() == .surface) @exp(dy * 0.01) else (if (dy > 0) 1.25 else 0.8);
        self.zoomAt(k, p[0], p[1]);
        return 1;
    }

    fn onPinchBegin(_: *gtk.Gesture, _: ?*gdk.EventSequence, self: *Graph) callconv(.c) void {
        self.pinch_scale = self.sx;
    }

    fn onPinch(g: *gtk.GestureZoom, s: f64, self: *Graph) callconv(.c) void {
        if (s <= 0) return;
        var px: f64 = 0;
        var py: f64 = 0;
        _ = g.as(gtk.Gesture).getBoundingBoxCenter(&px, &py);
        const want = self.pinch_scale / s;
        self.zoomAt(want / self.sx, px, py);
    }

    fn onMotion(_: *gtk.EventControllerMotion, x: f64, y: f64, self: *Graph) callconv(.c) void {
        self.pointer = .{ x, y };
        self.refresh();
    }

    fn onLeave(_: *gtk.EventControllerMotion, self: *Graph) callconv(.c) void {
        self.pointer = null;
        self.refresh();
    }

    // ---- drawing -----------------------------------------------------------------------

    const Parsed = struct { node: ?*eval.Node, index: usize };

    /// Each row's expression, parsed ("y = ..." and "f(x) = ..." are accepted;
    /// a bare function name plots f(x)).
    fn parseCurves(self: *Graph, a: std.mem.Allocator, ev: *eval.Eval) ![]Parsed {
        var out: std.ArrayList(Parsed) = .empty;
        for (self.curves.items, 0..) |c, i| {
            var text = std.mem.trim(u8, std.mem.span(c.entry.as(gtk.Editable).getText()), " ");
            if (std.mem.indexOfScalar(u8, text, '=')) |eq| text = std.mem.trim(u8, text[eq + 1 ..], " ");
            c.error_label.as(gtk.Widget).setVisible(0);
            if (text.len == 0) {
                try out.append(a, .{ .node = null, .index = i });
                continue;
            }
            if (self.session.funcs.get(text)) |f| if (f.params.len == 1) {
                text = try std.fmt.allocPrint(a, "{s}(x)", .{text});
            };
            var p: eval.Problem = .{};
            const parsed_node = eval.parseExpr(a, text, ev.mode, &p) catch null;
            // diff(f, x) plots the derivative.
            const n = if (parsed_node) |pn| (if (calculus.hasDiff(pn)) calculus.expand(a, ev, pn) catch null else pn) else null;
            _ = n orelse {
                c.error_label.setText(t("not understood"));
                c.error_label.as(gtk.Widget).setVisible(1);
                try out.append(a, .{ .node = null, .index = i });
                continue;
            };
            const node = n.?;
            // Names other than x must have values.
            if (self.unknownName(node)) |name| {
                var buf: [96]u8 = undefined;
                c.error_label.setText(std.fmt.bufPrintSentinel(&buf, "unknown: {s}", .{name}, 0) catch "unknown name");
                c.error_label.as(gtk.Widget).setVisible(1);
                try out.append(a, .{ .node = null, .index = i });
                continue;
            }
            try out.append(a, .{ .node = node, .index = i });
        }
        return out.toOwnedSlice(a);
    }

    fn unknownName(self: *Graph, n: *const eval.Node) ?[]const u8 {
        switch (n.*) {
            .number => return null,
            .name => |nm| {
                if (std.mem.eql(u8, nm.text, "x") or eval.isConstant(nm.text) or self.session.vars.contains(nm.text)) return null;
                return nm.text;
            },
            .unary => |u| return self.unknownName(u.arg),
            .binary => |b| return self.unknownName(b.l) orelse self.unknownName(b.r),
            .call => |c| {
                if (!eval.isBuiltin(c.name) and !self.session.funcs.contains(c.name)) return c.name;
                for (c.args) |x| if (self.unknownName(x)) |name| return name;
                return null;
            },
        }
    }

    fn onDraw(_: *gtk.DrawingArea, cr: *cairo.Context, w: c_int, h: c_int, data: ?*anyopaque) callconv(.c) void {
        const self: *Graph = @ptrCast(@alignCast(data.?));
        if (self.pending_fit) |i| if (i < self.curves.items.len and w >= 10) self.fit(self.curves.items[i]);
        self.draw(cr, @floatFromInt(w), @floatFromInt(h), true);
    }

    fn draw(self: *Graph, cr: *cairo.Context, w: f64, h: f64, live: bool) void {
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();
        var problem: eval.Problem = .{};
        var ev: eval.Eval = .{ .a = a, .session = self.session, .mode = .{ .angle = .radians }, .problem = &problem };

        // Paper.
        cr.setSourceRgb(1, 1, 1);
        cr.paint();
        self.drawGrid(cr, w, h);

        const parsed = self.parseCurves(a, &ev) catch return;
        self.marks.clearRetainingCapacity();
        const lo = self.toX(0);
        const hi = self.toX(w);
        // Every curve, a point per pixel; jumps across poles are not joined.
        for (parsed) |p| {
            const n = p.node orelse continue;
            const col = colours[p.index];
            cr.setSourceRgb(col[0], col[1], col[2]);
            cr.setLineWidth(2);
            var pen = false;
            var last_py: f64 = 0;
            var px: f64 = 0;
            while (px <= w) : (px += 1) {
                const y = ev.float(n, "x", self.toX(px));
                if (!std.math.isFinite(y)) {
                    pen = false;
                    continue;
                }
                const py = self.toPy(y);
                const jump = pen and @abs(py - last_py) > h * 2;
                if (!pen or jump) {
                    cr.moveTo(px, std.math.clamp(py, -h, 2 * h));
                    pen = true;
                } else cr.lineTo(px, std.math.clamp(py, -h, 2 * h));
                last_py = py;
            }
            cr.stroke();
            // Where it crosses zero.
            const roots = eval.findRootsIn(a, &ev, n, "x", lo, hi, @intFromFloat(@max(100, w))) catch &.{};
            for (roots) |r| self.marks.append(self.gpa, .{ .x = r, .y = 0, .curve = p.index }) catch {};
        }
        // Where two curves cross.
        for (parsed, 0..) |p, i| for (parsed[i + 1 ..]) |q| {
            const f = p.node orelse continue;
            const g = q.node orelse continue;
            const diff = a.create(eval.Node) catch continue;
            diff.* = .{ .binary = .{ .op = .sub, .l = f, .r = g } };
            const xs = eval.findRootsIn(a, &ev, diff, "x", lo, hi, @intFromFloat(@max(100, w))) catch &.{};
            for (xs) |x| {
                const y = ev.float(f, "x", x);
                if (std.math.isFinite(y)) self.marks.append(self.gpa, .{ .x = x, .y = y, .curve = p.index }) catch {};
            }
        };
        for (self.marks.items) |m| {
            cr.setSourceRgb(0.1, 0.1, 0.1);
            cr.arc(self.toPx(m.x), self.toPy(m.y), 3.5, 0, 2 * std.math.pi);
            cr.fill();
        }
        if (live) self.drawPointer(cr, &ev, parsed, w, h);
    }

    /// A "nice" step (1, 2 or 5 × 10ⁿ) about `want` long.
    fn niceStep(want: f64) f64 {
        const p = std.math.pow(f64, 10, @floor(std.math.log10(want)));
        const f = want / p;
        return p * (if (f < 1.5) @as(f64, 1) else if (f < 3.5) @as(f64, 2) else if (f < 7.5) @as(f64, 5) else 10);
    }

    fn drawGrid(self: *Graph, cr: *cairo.Context, w: f64, h: f64) void {
        const xstep = niceStep(80 * self.sx);
        const ystep = niceStep(60 * self.sy);
        const layout = pangocairo.createLayout(cr);
        defer layout.as(gobject.Object).unref();
        const font = pango.FontDescription.fromString("Sans 8");
        defer font.free();
        layout.setFontDescription(font);

        cr.setLineWidth(1);
        var x = @floor(self.toX(0) / xstep) * xstep;
        while (x <= self.toX(w)) : (x += xstep) {
            const px = @round(self.toPx(x)) + 0.5;
            cr.setSourceRgb(0.9, 0.9, 0.9);
            cr.moveTo(px, 0);
            cr.lineTo(px, h);
            cr.stroke();
        }
        var y = @floor(self.toY(h) / ystep) * ystep;
        while (y <= self.toY(0)) : (y += ystep) {
            const py = @round(self.toPy(y)) + 0.5;
            cr.setSourceRgb(0.9, 0.9, 0.9);
            cr.moveTo(0, py);
            cr.lineTo(w, py);
            cr.stroke();
        }
        // Axes, with their numbers beside them (kept on screen).
        const ax = std.math.clamp(@round(self.toPx(0)) + 0.5, 0.5, w - 0.5);
        const ay = std.math.clamp(@round(self.toPy(0)) + 0.5, 0.5, h - 0.5);
        cr.setSourceRgb(0.35, 0.35, 0.35);
        cr.moveTo(ax, 0);
        cr.lineTo(ax, h);
        cr.moveTo(0, ay);
        cr.lineTo(w, ay);
        cr.stroke();
        cr.setSourceRgb(0.3, 0.3, 0.3);
        x = @floor(self.toX(0) / xstep) * xstep;
        while (x <= self.toX(w)) : (x += xstep) {
            if (@abs(x) < xstep / 2) continue;
            self.label(cr, layout, self.toPx(x) + 2, @min(ay + 2, h - 14), x, xstep);
        }
        y = @floor(self.toY(h) / ystep) * ystep;
        while (y <= self.toY(0)) : (y += ystep) {
            if (@abs(y) < ystep / 2) continue;
            self.label(cr, layout, @min(ax + 3, w - 60), self.toPy(y) - 14, y, ystep);
        }
        // What the axes are, for a formula: its letters at their ends.
        const bold = pango.FontDescription.fromString("Sans Bold 10");
        defer bold.free();
        layout.setFontDescription(bold);
        const xt = std.mem.sliceTo(&self.x_title, 0);
        const yt = std.mem.sliceTo(&self.y_title, 0);
        if (xt.len > 0) {
            layout.setText(@ptrCast(xt.ptr), @intCast(xt.len));
            cr.moveTo(w - 8 - 10 * @as(f64, @floatFromInt(xt.len)), @min(ay - 18, h - 18));
            pangocairo.showLayout(cr, layout);
        }
        if (yt.len > 0) {
            layout.setText(@ptrCast(yt.ptr), @intCast(yt.len));
            cr.moveTo(@min(ax + 6, w - 20), 4);
            pangocairo.showLayout(cr, layout);
        }
    }

    fn label(_: *Graph, cr: *cairo.Context, layout: *pango.Layout, px: f64, py: f64, v: f64, step: f64) void {
        var buf: [32]u8 = undefined;
        const decimals: usize = if (step >= 1) 0 else @intFromFloat(@min(10, @ceil(-std.math.log10(step))));
        const text = if (@abs(v) >= 1e6 or @abs(v) < 1e-6) std.fmt.bufPrint(&buf, "{e:.1}", .{v}) catch return else std.fmt.bufPrint(&buf, "{d:.[1]}", .{ v, decimals }) catch return;
        layout.setText(@ptrCast(text.ptr), @intCast(text.len));
        cr.moveTo(px, py);
        pangocairo.showLayout(cr, layout);
    }

    /// The point of the nearest curve under the pointer, and any mark near it.
    fn drawPointer(self: *Graph, cr: *cairo.Context, ev: *eval.Eval, parsed: []const Parsed, w: f64, h: f64) void {
        const p = self.pointer orelse return;
        const x = self.toX(p[0]);
        var best: ?struct { y: f64, index: usize, d: f64 } = null;
        for (parsed) |c| {
            const n = c.node orelse continue;
            const y = ev.float(n, "x", x);
            if (!std.math.isFinite(y)) continue;
            const d = @abs(self.toPy(y) - p[1]);
            if (d < 40 and (best == null or d < best.?.d)) best = .{ .y = y, .index = c.index, .d = d };
        }
        var text_buf: [128]u8 = undefined;
        var text: []const u8 = "";
        var at: [2]f64 = p;
        // A marked point near the pointer wins.
        for (self.marks.items) |m| {
            if (@abs(self.toPx(m.x) - p[0]) < 8 and @abs(self.toPy(m.y) - p[1]) < 8) {
                text = std.fmt.bufPrint(&text_buf, "({d:.6}, {d:.6})", .{ m.x, m.y }) catch "";
                at = .{ self.toPx(m.x), self.toPy(m.y) };
                best = null;
                break;
            }
        }
        if (best) |b| {
            const col = colours[b.index];
            cr.setSourceRgb(col[0], col[1], col[2]);
            at = .{ p[0], self.toPy(b.y) };
            cr.arc(at[0], at[1], 4, 0, 2 * std.math.pi);
            cr.fill();
            text = std.fmt.bufPrint(&text_buf, "x = {d:.4}   y = {d:.4}", .{ x, b.y }) catch "";
        }
        if (text.len == 0) return;
        const layout = pangocairo.createLayout(cr);
        defer layout.as(gobject.Object).unref();
        layout.setText(@ptrCast(text.ptr), @intCast(text.len));
        var ink: pango.Rectangle = undefined;
        var logical: pango.Rectangle = undefined;
        layout.getPixelExtents(&ink, &logical);
        var bx = at[0] + 10;
        var by = at[1] - 24;
        const bw: f64 = @floatFromInt(logical.f_width + 8);
        if (bx + bw > w) bx = at[0] - bw - 10;
        if (by < 0) by = at[1] + 8;
        if (by + 20 > h) by = h - 20;
        cr.setSourceRgba(1, 1, 1, 0.9);
        cr.rectangle(bx, by, bw, 20);
        cr.fill();
        cr.setSourceRgb(0.1, 0.1, 0.1);
        cr.moveTo(bx + 4, by + 2);
        pangocairo.showLayout(cr, layout);
    }

    // ---- saving ------------------------------------------------------------------------

    fn onSave(button: *gtk.Button, self: *Graph) callconv(.c) void {
        const dialog = gtk.FileDialog.new();
        defer dialog.as(gobject.Object).unref();
        dialog.setInitialName("graph.png");
        const root = button.as(gtk.Widget).getRoot() orelse return;
        dialog.save(@ptrCast(@alignCast(root)), null, onSaveChosen, self);
    }

    fn onSaveChosen(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Graph = @ptrCast(@alignCast(data.?));
        const dialog: *gtk.FileDialog = @ptrCast(@alignCast(source.?));
        const file = dialog.saveFinish(result, null) orelse return;
        defer file.as(gobject.Object).unref();
        const path = file.getPath() orelse return;
        defer glib.free(path);
        const sz = self.size();
        // Twice the size on screen, for a sharp picture.
        const surface = cairo.Surface.imageCreate(.argb32, @intFromFloat(sz[0] * 2), @intFromFloat(sz[1] * 2));
        defer surface.destroy();
        const cr = cairo.Context.create(surface);
        defer cr.destroy();
        cr.scale(2, 2);
        self.draw(cr, sz[0], sz[1], false);
        surface.flush();
        if (surface.writeToPng(path) != .success) self.status.setText(t("The picture could not be saved.")) else self.status.setText(t("Saved."));
    }
};
