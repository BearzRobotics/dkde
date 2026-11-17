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
    /// Why the row cannot be drawn ("not understood"), found while drawing
    /// and shown only once typing pauses (changing the row's widgets while
    /// drawing made the entry jump).
    problem: [96]u8 = @splat(0),
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
    /// Shows the rows' problems a moment after typing stops.
    check_timer: c_uint = 0,
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
        area.setSizeRequest(240, 200);
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

        // The buttons wrap onto a second line when the pane is narrow, instead of running off the edge.
        const buttons = gtk.FlowBox.new();
        buttons.setSelectionMode(.none);
        buttons.setHomogeneous(0);
        buttons.setMaxChildrenPerLine(4);
        buttons.setColumnSpacing(6);
        buttons.setRowSpacing(4);
        buttons.as(gtk.Widget).addCssClass("dkde-calc-compact-row");
        const add = gtk.Button.newWithLabel(t("Add Function"));
        _ = gtk.Button.signals.clicked.connect(add, *Graph, &onAdd, self, .{});
        const reset = gtk.Button.newWithLabel(t("Reset View"));
        _ = gtk.Button.signals.clicked.connect(reset, *Graph, &onReset, self, .{});
        const save = gtk.Button.newWithLabel(t("Save…"));
        _ = gtk.Button.signals.clicked.connect(save, *Graph, &onSave, self, .{});
        buttons.insert(add.as(gtk.Widget), -1);
        buttons.insert(self.buildScale(), -1);
        buttons.insert(reset.as(gtk.Widget), -1);
        buttons.insert(save.as(gtk.Widget), -1);
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
        if (self.check_timer != 0) _ = glib.Source.remove(self.check_timer);
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

    /// Is this expression already in one of the rows?
    pub fn has(self: *Graph, text: []const u8) bool {
        for (self.curves.items) |c| {
            if (std.mem.eql(u8, std.mem.trim(u8, std.mem.span(c.entry.as(gtk.Editable).getText()), " "), text)) return true;
        }
        return false;
    }

    /// Rows still free (empty or not yet added).
    pub fn room(self: *Graph) usize {
        var free: usize = max_curves - self.curves.items.len;
        for (self.curves.items) |c| {
            if (std.mem.span(c.entry.as(gtk.Editable).getText()).len == 0) free += 1;
        }
        return free;
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
        if (parsed[curve.index].kind != .cartesian) return self.fitParam(&ev, parsed[curve.index]);
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
        const self = c.graph;
        // A warning from before is out of date as soon as the text changes.
        markProblem(c, null);
        self.refresh();
        if (self.check_timer != 0) _ = glib.Source.remove(self.check_timer);
        self.check_timer = glib.timeoutAdd(600, onCheck, self);
    }

    fn onCheck(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Graph = @ptrCast(@alignCast(data.?));
        self.check_timer = 0;
        self.showProblems();
        return 0;
    }

    /// Each row's problem (if any) beside it.
    fn showProblems(self: *Graph) void {
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();
        var problem: eval.Problem = .{};
        var ev: eval.Eval = .{ .a = a, .session = self.session, .mode = .{ .angle = .radians }, .problem = &problem };
        _ = self.parseCurves(a, &ev) catch return;
        for (self.curves.items) |c| {
            const text = std.mem.sliceTo(&c.problem, 0);
            markProblem(c, if (text.len == 0) null else text);
        }
    }

    /// A warning sign inside the entry (with the reason as its tooltip): it
    /// does not change the entry's size, so nothing moves while typing.
    fn markProblem(c: *Curve, text: ?[]const u8) void {
        const e = c.entry;
        if (text) |msg| {
            var buf: [100]u8 = undefined;
            e.setIconFromIconName(.secondary, "dialog-warning-symbolic");
            e.setIconTooltipText(.secondary, std.fmt.bufPrintSentinel(&buf, "{s}", .{msg}, 0) catch null);
            e.as(gtk.Widget).addCssClass("warning");
        } else {
            e.setIconFromIconName(.secondary, null);
            e.as(gtk.Widget).removeCssClass("warning");
        }
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

    const Kind = enum { cartesian, polar, parametric };

    /// A row: y = f(x) in `node`; a polar curve r = f(t) has f in `fx`, a parametric one (x(t), y(t))
    /// has both; `var_name` is the letter that runs along the curve.
    const Parsed = struct {
        node: ?*eval.Node,
        index: usize,
        kind: Kind = .cartesian,
        fx: ?*eval.Node = null,
        fy: ?*eval.Node = null,
        var_name: []const u8 = "t",
    };

    /// "r = 1 + cos(t)", "r(θ) = θ" or "(cos(t), sin(t))": a polar or parametric curve, else null.
    fn parseSpecial(self: *Graph, a: std.mem.Allocator, ev: *eval.Eval, text: []const u8, c: *Curve, index: usize) !?Parsed {
        _ = self;
        const trimmed = std.mem.trim(u8, text, " ");
        var parts: [2][]const u8 = undefined;
        var kind: Kind = .cartesian;
        // (x(t), y(t))
        if (trimmed.len > 4 and trimmed[0] == '(' and trimmed[trimmed.len - 1] == ')') {
            var depth: usize = 0;
            var comma: ?usize = null;
            var closes_early = false;
            for (trimmed, 0..) |ch, i| {
                if (ch == '(' or ch == '[') depth += 1;
                if (ch == ')' or ch == ']') {
                    depth -|= 1;
                    if (depth == 0 and i != trimmed.len - 1) closes_early = true;
                }
                if (ch == ',' and depth == 1 and comma == null) comma = i;
            }
            if (comma != null and !closes_early) {
                parts[0] = trimmed[1..comma.?];
                parts[1] = trimmed[comma.? + 1 .. trimmed.len - 1];
                kind = .parametric;
            }
        }
        // r = f(t)
        if (kind == .cartesian) {
            if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq| {
                const left = std.mem.trim(u8, trimmed[0..eq], " ");
                const is_r = std.mem.eql(u8, left, "r") or std.mem.eql(u8, left, "ρ") or
                    ((std.mem.startsWith(u8, left, "r(") or std.mem.startsWith(u8, left, "ρ(")) and std.mem.endsWith(u8, left, ")"));
                if (is_r) {
                    parts[0] = std.mem.trim(u8, trimmed[eq + 1 ..], " ");
                    kind = .polar;
                }
            }
        }
        if (kind == .cartesian) return null;
        var name: []const u8 = "t";
        if (std.mem.indexOf(u8, trimmed, "θ") != null) name = "θ" else if (std.mem.indexOf(u8, trimmed, "theta") != null) name = "theta";
        var p: eval.Problem = .{};
        const count: usize = if (kind == .polar) 1 else 2;
        var nodes: [2]?*eval.Node = .{ null, null };
        for (0..count) |i| {
            nodes[i] = eval.parseExpr(a, parts[i], ev.mode, &p) catch {
                setProblem(c, "not understood");
                return Parsed{ .node = null, .index = index };
            };
        }
        return Parsed{ .node = null, .index = index, .kind = kind, .fx = nodes[0], .fy = nodes[1], .var_name = name };
    }

    /// Each row's expression, parsed ("y = ..." and "f(x) = ..." are accepted;
    /// a bare function name plots f(x)).
    fn parseCurves(self: *Graph, a: std.mem.Allocator, ev: *eval.Eval) ![]Parsed {
        var out: std.ArrayList(Parsed) = .empty;
        for (self.curves.items, 0..) |c, i| {
            var text = std.mem.trim(u8, std.mem.span(c.entry.as(gtk.Editable).getText()), " ");
            if (std.mem.indexOfScalar(u8, text, '=')) |eq| text = std.mem.trim(u8, text[eq + 1 ..], " ");
            c.problem = @splat(0);
            // Polar and parametric rows are read from the whole text, before an "=" is cut off.
            const whole = std.mem.trim(u8, std.mem.span(c.entry.as(gtk.Editable).getText()), " ");
            if (try self.parseSpecial(a, ev, whole, c, i)) |special| {
                if (special.kind != .cartesian) {
                    const bad = (if (special.fx) |f| self.unknownNameWith(f, special.var_name) else null) orelse
                        (if (special.fy) |f| self.unknownNameWith(f, special.var_name) else null);
                    if (bad) |name| {
                        var buf: [96]u8 = undefined;
                        setProblem(c, std.fmt.bufPrint(&buf, "unknown: {s}", .{name}) catch "unknown name");
                        try out.append(a, .{ .node = null, .index = i });
                    } else try out.append(a, special);
                } else try out.append(a, special);
                continue;
            }
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
                setProblem(c, "not understood");
                try out.append(a, .{ .node = null, .index = i });
                continue;
            };
            const node = n.?;
            // Names other than x must have values.
            if (self.unknownName(node)) |name| {
                var buf: [96]u8 = undefined;
                setProblem(c, std.fmt.bufPrint(&buf, "unknown: {s}", .{name}) catch "unknown name");
                try out.append(a, .{ .node = null, .index = i });
                continue;
            }
            try out.append(a, .{ .node = node, .index = i });
        }
        return out.toOwnedSlice(a);
    }

    fn setProblem(c: *Curve, text: []const u8) void {
        c.problem = @splat(0);
        const n = @min(text.len, c.problem.len - 1);
        @memcpy(c.problem[0..n], text[0..n]);
    }

    fn unknownName(self: *Graph, n: *const eval.Node) ?[]const u8 {
        return self.unknownNameWith(n, "x");
    }

    /// A name with no value, other than the letter that runs along the curve.
    fn unknownNameWith(self: *Graph, n: *const eval.Node, letter: []const u8) ?[]const u8 {
        switch (n.*) {
            .number => return null,
            .name => |nm| {
                if (std.mem.eql(u8, nm.text, letter) or eval.isConstant(nm.text) or self.session.vars.contains(nm.text)) return null;
                return nm.text;
            },
            .unary => |u| return self.unknownNameWith(u.arg, letter),
            .binary => |b| return self.unknownNameWith(b.l, letter) orelse self.unknownNameWith(b.r, letter),
            .call => |c| {
                if (!eval.isBuiltin(c.name) and !self.session.funcs.contains(c.name)) return c.name;
                for (c.args) |x| if (self.unknownNameWith(x, letter)) |name| return name;
                return null;
            },
        }
    }

    const param_samples = 2400;

    /// The point of a polar or parametric curve at t.
    fn paramPoint(ev: *eval.Eval, p: Parsed, angle: f64) ?[2]f64 {
        const fx = p.fx orelse return null;
        if (p.kind == .polar) {
            const r = ev.float(fx, p.var_name, angle);
            if (!std.math.isFinite(r)) return null;
            return .{ r * @cos(angle), r * @sin(angle) };
        }
        const fy = p.fy orelse return null;
        const x = ev.float(fx, p.var_name, angle);
        const y = ev.float(fy, p.var_name, angle);
        if (!std.math.isFinite(x) or !std.math.isFinite(y)) return null;
        return .{ x, y };
    }

    /// A polar or parametric curve over t = 0 … 2π.
    fn drawParam(self: *Graph, cr: *cairo.Context, ev: *eval.Eval, p: Parsed, w: f64, h: f64) void {
        const col = colours[p.index];
        cr.setSourceRgb(col[0], col[1], col[2]);
        cr.setLineWidth(2);
        var pen = false;
        var last: [2]f64 = .{ 0, 0 };
        var i: usize = 0;
        while (i <= param_samples) : (i += 1) {
            const angle = 2 * std.math.pi * @as(f64, @floatFromInt(i)) / param_samples;
            const pt = paramPoint(ev, p, angle) orelse {
                pen = false;
                continue;
            };
            const px = self.toPx(pt[0]);
            const py = self.toPy(pt[1]);
            if (!std.math.isFinite(px) or !std.math.isFinite(py)) {
                pen = false;
                continue;
            }
            const jump = pen and (@abs(px - last[0]) > w or @abs(py - last[1]) > h);
            const cx = std.math.clamp(px, -2 * w, 3 * w);
            const cy = std.math.clamp(py, -2 * h, 3 * h);
            if (!pen or jump) cr.moveTo(cx, cy) else cr.lineTo(cx, cy);
            pen = true;
            last = .{ px, py };
        }
        cr.stroke();
    }

    /// Fits the view to a polar or parametric curve, with the same scale on both axes.
    fn fitParam(self: *Graph, ev: *eval.Eval, p: Parsed) void {
        var xmin = std.math.inf(f64);
        var xmax = -std.math.inf(f64);
        var ymin = std.math.inf(f64);
        var ymax = -std.math.inf(f64);
        var i: usize = 0;
        while (i <= 800) : (i += 1) {
            const angle = 2 * std.math.pi * @as(f64, @floatFromInt(i)) / 800;
            const pt = paramPoint(ev, p, angle) orelse continue;
            if (@abs(pt[0]) > 1e9 or @abs(pt[1]) > 1e9) continue;
            xmin = @min(xmin, pt[0]);
            xmax = @max(xmax, pt[0]);
            ymin = @min(ymin, pt[1]);
            ymax = @max(ymax, pt[1]);
        }
        if (!std.math.isFinite(xmin) or !std.math.isFinite(ymin)) return self.refresh();
        const sz = self.size();
        var span_x = xmax - xmin;
        var span_y = ymax - ymin;
        if (span_x < 1e-9) span_x = 2;
        if (span_y < 1e-9) span_y = 2;
        const per_pixel = @max(span_x * 1.25 / sz[0], span_y * 1.25 / sz[1]);
        self.sx = per_pixel;
        self.sy = per_pixel;
        self.cx = (xmin + xmax) / 2;
        self.cy = (ymin + ymax) / 2;
        self.refresh();
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
        // Polar and parametric curves.
        for (parsed) |p| if (p.kind != .cartesian) self.drawParam(cr, &ev, p, w, h);
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

    /// cairo's SVG backend is not in the bindings; the library is linked already.
    extern fn cairo_svg_surface_create(filename: [*:0]const u8, width: f64, height: f64) ?*cairo.Surface;

    fn onSave(button: *gtk.Button, self: *Graph) callconv(.c) void {
        const dialog = gtk.FileDialog.new();
        defer dialog.as(gobject.Object).unref();
        dialog.setInitialName("graph.png");
        // The file name decides the format: .svg is a scalable drawing, .csv the points, anything else a PNG.
        const filters = gio.ListStore.new(gtk.FileFilter.getGObjectType());
        defer filters.as(gobject.Object).unref();
        inline for (.{ .{ "PNG picture", "*.png" }, .{ "SVG drawing (scalable)", "*.svg" }, .{ "CSV table of points", "*.csv" } }) |f| {
            const filter = gtk.FileFilter.new();
            filter.setName(t(f[0]));
            filter.addPattern(f[1]);
            filters.append(filter.as(gobject.Object));
            filter.as(gobject.Object).unref();
        }
        dialog.setFilters(filters.as(gio.ListModel));
        const root = button.as(gtk.Widget).getRoot() orelse return;
        dialog.save(@ptrCast(@alignCast(root)), null, onSaveChosen, self);
    }

    /// The curves as a table: x, then one column per function, a row for each of
    /// `csv_rows` points across the x range on screen. Undefined values are left empty.
    const csv_rows = 401;

    fn saveCsv(self: *Graph, path: [*:0]const u8) bool {
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();
        var problem: eval.Problem = .{};
        var ev: eval.Eval = .{ .a = a, .session = self.session, .mode = .{ .angle = .radians }, .problem = &problem };
        const parsed = self.parseCurves(a, &ev) catch return false;
        var out: std.ArrayList(u8) = .empty;
        out.appendSlice(a, "x") catch return false;
        var any = false;
        for (parsed) |p| {
            if (p.node == null) continue;
            any = true;
            const c = self.curves.items[p.index];
            const text = std.mem.trim(u8, std.mem.span(c.entry.as(gtk.Editable).getText()), " ");
            out.append(a, ',') catch return false;
            out.append(a, '"') catch return false;
            for (text) |ch| {
                if (ch == '"') out.append(a, '"') catch return false;
                out.append(a, ch) catch return false;
            }
            out.append(a, '"') catch return false;
        }
        if (!any) return false;
        out.append(a, '\n') catch return false;
        const w = self.size()[0];
        const lo = self.toX(0);
        const step = (self.toX(w) - lo) / @as(f64, csv_rows - 1);
        var i: usize = 0;
        while (i < csv_rows) : (i += 1) {
            const x = lo + step * @as(f64, @floatFromInt(i));
            out.print(a, "{d}", .{x}) catch return false;
            for (parsed) |p| {
                const n = p.node orelse continue;
                const y = ev.float(n, "x", x);
                if (std.math.isFinite(y)) out.print(a, ",{d}", .{y}) catch return false else out.append(a, ',') catch return false;
            }
            out.append(a, '\n') catch return false;
        }
        common.fsio.writeFileAtomic(std.mem.span(path), out.items) catch return false;
        return true;
    }

    fn onSaveChosen(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Graph = @ptrCast(@alignCast(data.?));
        const dialog: *gtk.FileDialog = @ptrCast(@alignCast(source.?));
        const file = dialog.saveFinish(result, null) orelse return;
        defer file.as(gobject.Object).unref();
        const path = file.getPath() orelse return;
        defer glib.free(path);
        if (std.ascii.endsWithIgnoreCase(std.mem.span(path), ".csv")) {
            self.status.setText(if (self.saveCsv(path)) t("Saved.") else t("The points could not be saved."));
            return;
        }
        if (std.ascii.endsWithIgnoreCase(std.mem.span(path), ".svg")) {
            const sz = self.size();
            const svg = cairo_svg_surface_create(path, sz[0], sz[1]) orelse return self.status.setText(t("The picture could not be saved."));
            const cr = cairo.Context.create(svg);
            self.draw(cr, sz[0], sz[1], false);
            cr.destroy();
            svg.finish(); // writes the file
            const failed = svg.status() != .success;
            svg.destroy();
            self.status.setText(if (failed) t("The picture could not be saved.") else t("Saved."));
            return;
        }
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
