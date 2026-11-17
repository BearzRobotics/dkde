//! The Geometry pane of dkde-calc: a drawing canvas with points, segments, lines, circles, polygons and
//! angles. Drag a point and every length, angle and area that depends on it changes with it. The
//! measurements are listed under the canvas; a click on one puts its number in the calculator's entry.
//! The arithmetic is geom.zig (tested on its own).

const std = @import("std");
const cairo = @import("cairo1");
const gdk = @import("gdk4");
const gobject = @import("gobject2");
const glib = @import("glib2");
const gtk = @import("gtk4");
const pangocairo = @import("pangocairo1");
const common = @import("common");

const geom = @import("geom.zig");
const figure = @import("figure.zig");
const scene_mod = @import("scene.zig");
const Pt = geom.Pt;

const t = common.tr;

const Tool = enum { move, point, segment, line, circle, polygon, angle, intersect, paint, erase };

const tool_names = [_]struct { tool: Tool, label: [:0]const u8, tip: [:0]const u8 }{
    .{ .tool = .move, .label = "Move", .tip = "Drag points to move them; drag the background to pan" },
    .{ .tool = .point, .label = "Point", .tip = "Click to place a point" },
    .{ .tool = .segment, .label = "Segment", .tip = "Click two points: a segment with its length" },
    .{ .tool = .line, .label = "Line", .tip = "Click two points: the line through them, with its slope" },
    .{ .tool = .circle, .label = "Circle", .tip = "Click the centre, then a point on the circle" },
    .{ .tool = .polygon, .label = "Polygon", .tip = "Click the corners; click the first one again to close it" },
    .{ .tool = .angle, .label = "Angle", .tip = "Click a point on one arm, the corner, then a point on the other arm" },
    .{ .tool = .intersect, .label = "Cross", .tip = "Click two lines or circles: a point where they cross" },
    .{ .tool = .paint, .label = "Colour", .tip = "Click a shape to give it the chosen colour and shading" },
    .{ .tool = .erase, .label = "Erase", .tip = "Click a point or a line to remove it (and what depends on it)" },
};

const Point = scene_mod.Point;
const Style = scene_mod.Style;
const Shape = scene_mod.Shape;
const Scene = scene_mod.Scene;
pub const palette = scene_mod.palette;
const palette_names = [_][:0]const u8{ "Blue", "Red", "Green", "Orange", "Purple", "Teal", "Yellow", "Black" };
const palette_hex = [_][:0]const u8{ "#2666d9", "#d62728", "#2ba02b", "#f28c0d", "#9466bc", "#17a0a6", "#ccb20d", "#262626" };


pub const UseFn = *const fn (ctx: *anyopaque, text: []const u8) void;

pub const Geometry = struct {
    gpa: std.mem.Allocator,
    root: *gtk.Box,
    area: *gtk.DrawingArea,
    status: *gtk.Label,
    results: *gtk.Box,
    snap: *gtk.CheckButton,
    use_fn: UseFn,
    use_ctx: *anyopaque,

    scene: Scene,
    /// What new shapes get, and what the Colour tool applies.
    current: Style = .{},
    shade: *gtk.CheckButton = undefined,
    /// Lengths written beside segments (off while a lesson draws, on for your own figures).
    lengths: *gtk.CheckButton = undefined,
    tool: Tool = .move,
    /// Points picked so far for the shape being made.
    picks: std.ArrayList(usize) = .empty,
    /// The first of two shapes picked for "Cross".
    first_shape: ?usize = null,
    pointer: ?Pt = null,
    /// A drag in progress: a point being moved, or the whole view.
    dragging: ?usize = null,
    pan: bool = false,
    drag_start: Pt = .{ .x = 0, .y = 0 },
    drag_origin: Pt = .{ .x = 0, .y = 0 },

    pub fn create(gpa: std.mem.Allocator, use_ctx: *anyopaque, use_fn: UseFn) !*Geometry {
        const self = try gpa.create(Geometry);
        self.* = .{
            .gpa = gpa,
            .scene = Scene.init(gpa),
            .root = gtk.Box.new(.vertical, 6),
            .area = gtk.DrawingArea.new(),
            .status = gtk.Label.new(""),
            .results = gtk.Box.new(.vertical, 2),
            .snap = gtk.CheckButton.newWithLabel(t("Snap")),
            .use_fn = use_fn,
            .use_ctx = use_ctx,
        };

        // The tools.
        const tools = gtk.FlowBox.new();
        tools.setSelectionMode(.none);
        tools.setMaxChildrenPerLine(4);
        tools.setColumnSpacing(4);
        tools.setRowSpacing(4);
        var leader: ?*gtk.ToggleButton = null;
        inline for (tool_names) |entry| {
            const b = gtk.ToggleButton.newWithLabel(t(entry.label));
            b.as(gtk.Widget).setTooltipText(t(entry.tip));
            if (leader) |l| b.setGroup(l) else leader = b;
            if (entry.tool == .move) b.setActive(1);
            const ctx = try gpa.create(ToolCtx);
            ctx.* = .{ .geo = self, .tool = entry.tool };
            _ = gtk.ToggleButton.signals.toggled.connect(b, *ToolCtx, &onTool, ctx, .{});
            _ = gtk.Widget.signals.destroy.connect(b, *ToolCtx, &onToolDestroy, ctx, .{});
            tools.append(b.as(gtk.Widget));
        }
        self.root.append(tools.as(gtk.Widget));

        // The canvas.
        const area = self.area.as(gtk.Widget);
        area.setVexpand(1);
        area.setHexpand(1);
        area.setSizeRequest(360, 300);
        area.addCssClass("dkde-calc-graph");
        self.area.setDrawFunc(onDraw, self, null);
        const drag = gtk.GestureDrag.new();
        _ = gtk.GestureDrag.signals.drag_begin.connect(drag, *Geometry, &onDragBegin, self, .{});
        _ = gtk.GestureDrag.signals.drag_update.connect(drag, *Geometry, &onDragUpdate, self, .{});
        _ = gtk.GestureDrag.signals.drag_end.connect(drag, *Geometry, &onDragEnd, self, .{});
        area.addController(drag.as(gtk.EventController));
        const scroll = gtk.EventControllerScroll.new(.{ .vertical = true });
        _ = gtk.EventControllerScroll.signals.scroll.connect(scroll, *Geometry, &onScroll, self, .{});
        area.addController(scroll.as(gtk.EventController));
        const motion = gtk.EventControllerMotion.new();
        _ = gtk.EventControllerMotion.signals.motion.connect(motion, *Geometry, &onMotion, self, .{});
        _ = gtk.EventControllerMotion.signals.leave.connect(motion, *Geometry, &onLeave, self, .{});
        area.addController(motion.as(gtk.EventController));
        const frame = gtk.Frame.new(null);
        frame.setChild(area);
        self.root.append(frame.as(gtk.Widget));

        self.status.setXalign(0);
        self.status.setWrap(1);
        self.status.setMaxWidthChars(40);
        self.status.as(gtk.Widget).addCssClass("dim-label");
        self.root.append(self.status.as(gtk.Widget));

        // Colours and shading: what new shapes get, and what the Colour tool applies.
        const colours = gtk.Box.new(.horizontal, 2);
        var first_swatch: ?*gtk.ToggleButton = null;
        inline for (palette_hex, 0..) |hex, ci| {
            const b = gtk.ToggleButton.new();
            const dot = gtk.Label.new(null);
            dot.setMarkup("<span foreground=\"" ++ hex ++ "\" size=\"large\">\u{25CF}</span>");
            b.as(gtk.Button).setChild(dot.as(gtk.Widget));
            b.as(gtk.Button).setHasFrame(0);
            b.as(gtk.Widget).setTooltipText(t(palette_names[ci]));
            if (first_swatch) |f| b.setGroup(f) else {
                first_swatch = b;
                b.setActive(1);
            }
            const ctx = try gpa.create(ColourCtx);
            ctx.* = .{ .geo = self, .index = ci };
            _ = gtk.ToggleButton.signals.toggled.connect(b, *ColourCtx, &onColour, ctx, .{});
            _ = gtk.Widget.signals.destroy.connect(b, *ColourCtx, &onColourDestroy, ctx, .{});
            colours.append(b.as(gtk.Widget));
        }
        self.shade = gtk.CheckButton.newWithLabel(t("Shade"));
        self.shade.as(gtk.Widget).setTooltipText(t("Fill circles, polygons and angles with the colour"));
        colours.append(self.shade.as(gtk.Widget));
        self.root.append(colours.as(gtk.Widget));

        self.lengths = gtk.CheckButton.newWithLabel(t("Numbers"));
        self.lengths.setActive(1);
        self.lengths.as(gtk.Widget).setTooltipText(t("Write the length of each segment and the size of each angle on the figure"));
        _ = gtk.CheckButton.signals.toggled.connect(self.lengths, *Geometry, &onLengths, self, .{});
        colours.append(self.lengths.as(gtk.Widget));

        const options = gtk.Box.new(.horizontal, 8);
        self.snap.setActive(1);
        self.snap.as(gtk.Widget).setTooltipText(t("Snap points to the grid"));
        options.append(self.snap.as(gtk.Widget));
        const reset = gtk.Button.newWithLabel(t("Reset"));
        _ = gtk.Button.signals.clicked.connect(reset, *Geometry, &onResetView, self, .{});
        const clear = gtk.Button.newWithLabel(t("Clear"));
        _ = gtk.Button.signals.clicked.connect(clear, *Geometry, &onClearAll, self, .{});
        options.append(reset.as(gtk.Widget));
        options.append(clear.as(gtk.Widget));
        self.root.append(options.as(gtk.Widget));

        const heading = gtk.Label.new(t("Measurements (click one to use its number)"));
        heading.setXalign(0);
        heading.as(gtk.Widget).addCssClass("heading");
        self.root.append(heading.as(gtk.Widget));
        const scroller = gtk.ScrolledWindow.new();
        scroller.setChild(self.results.as(gtk.Widget));
        scroller.setMinContentHeight(90);
        scroller.setMaxContentHeight(180);
        scroller.setPropagateNaturalHeight(1);
        scroller.setPolicy(.never, .automatic);
        self.root.append(scroller.as(gtk.Widget));

        self.hint();
        return self;
    }

    // ---- lessons draw here ---------------------------------------------------------------------

    /// Empties the canvas (the view stays).
    pub fn clearCanvas(self: *Geometry) void {
        self.clearShapes();
        self.scene.points.clearRetainingCapacity();
        self.picks.clearRetainingCapacity();
        self.first_shape = null;
        self.changed();
    }







    // The figure itself is a Scene (scene.zig); these keep the canvas's size in step and pass through.

    fn sync(self: *Geometry) void {
        const s = self.size();
        self.scene.width = s[0];
        self.scene.height = s[1];
    }

    fn pt(self: *Geometry, i: usize) Pt {
        return self.scene.pt(i);
    }

    fn toWorld(self: *Geometry, px: f64, py: f64) Pt {
        self.sync();
        return self.scene.toWorld(px, py);
    }

    fn toPx(self: *Geometry, p: Pt) Pt {
        self.sync();
        return self.scene.toPx(p);
    }

    fn gridStep(scale: f64) f64 {
        return Scene.gridStep(scale);
    }

    fn addPoint(self: *Geometry, p: Pt) usize {
        return self.scene.addPoint(p);
    }

    fn clearShapes(self: *Geometry) void {
        self.scene.clearShapes();
    }

    fn nameOf(self: *Geometry, buf: []u8, i: usize) []const u8 {
        return self.scene.nameOf(buf, i);
    }

    fn num(buf: []u8, v: f64) []const u8 {
        return Scene.num(buf, v);
    }

    pub fn addShapeStyled(self: *Geometry, s: Shape, style: Style) !void {
        try self.scene.addShapeStyled(s, style);
    }

    /// Carries out the operations of one lesson step.
    pub fn runOps(self: *Geometry, ops: []const figure.Op) void {
        self.scene.runOps(ops);
        self.changed();
    }

    /// Fits the view to everything drawn.
    pub fn fitToFigure(self: *Geometry) void {
        self.sync();
        self.scene.fitToFigure();
    }

    fn onDraw(_: *gtk.DrawingArea, cr: *cairo.Context, w: c_int, h: c_int, data: ?*anyopaque) callconv(.c) void {
        const self: *Geometry = @ptrCast(@alignCast(data.?));
        var fg: gdk.RGBA = undefined;
        self.area.as(gtk.Widget).getColor(&fg);
        self.scene.numbers = self.lengths.getActive() != 0;
        var label_buf: [80]u8 = undefined;
        var overlay: scene_mod.Overlay = .{ .picks = self.picks.items, .pointer = self.pointer };
        if (self.pointer) |m| {
            var b1: [32]u8 = undefined;
            var b2: [32]u8 = undefined;
            const s = self.snapped(m);
            overlay.pointer_label = std.fmt.bufPrint(&label_buf, "({s}, {s})", .{ num(&b1, s.x), num(&b2, s.y) }) catch null;
        }
        self.scene.draw(cr, @floatFromInt(w), @floatFromInt(h), .{ fg.f_red, fg.f_green, fg.f_blue, fg.f_alpha }, overlay);
    }

    pub fn widget(self: *Geometry) *gtk.Widget {
        return self.root.as(gtk.Widget);
    }

    pub fn destroy(self: *Geometry) void {
        self.scene.deinit();
        self.picks.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    const ColourCtx = struct { geo: *Geometry, index: usize };

    fn onColourDestroy(_: *gtk.ToggleButton, ctx: *ColourCtx) callconv(.c) void {
        std.heap.c_allocator.destroy(ctx);
    }

    fn onColour(b: *gtk.ToggleButton, ctx: *ColourCtx) callconv(.c) void {
        if (b.getActive() == 0) return;
        ctx.geo.current.color = @intCast(ctx.index);
    }

    fn onLengths(_: *gtk.CheckButton, self: *Geometry) callconv(.c) void {
        self.area.as(gtk.Widget).queueDraw();
    }

    const ToolCtx = struct { geo: *Geometry, tool: Tool };

    fn onToolDestroy(_: *gtk.ToggleButton, ctx: *ToolCtx) callconv(.c) void {
        std.heap.c_allocator.destroy(ctx);
    }

    fn onTool(b: *gtk.ToggleButton, ctx: *ToolCtx) callconv(.c) void {
        if (b.getActive() == 0) return;
        ctx.geo.tool = ctx.tool;
        ctx.geo.picks.clearRetainingCapacity();
        ctx.geo.hint();
        ctx.geo.area.as(gtk.Widget).queueDraw();
    }

    fn hint(self: *Geometry) void {
        const text: [:0]const u8 = switch (self.tool) {
            .move => t("Drag a point and everything built on it follows. Drag the background to pan, scroll to zoom."),
            .point => t("Click to place points."),
            .segment => t("Click two points to draw a segment."),
            .line => t("Click two points: the line goes through both."),
            .circle => t("Click the centre, then a point on the circle."),
            .polygon => t("Click the corners; click the first corner again to close the polygon."),
            .angle => t("Click a point on one arm, then the corner, then a point on the other arm."),
            .intersect => t("Click two lines or circles; a point is put where they cross."),
            .paint => t("Choose a colour, then click a shape to colour it. \"Shade\" fills circles, polygons and angles."),
            .erase => t("Click a point or a line to remove it."),
        };
        self.status.setText(text);
    }

    // ---- coordinates ---------------------------------------------------------------------------

    fn size(self: *Geometry) [2]f64 {
        const w = self.area.as(gtk.Widget);
        return .{ @floatFromInt(w.getWidth()), @floatFromInt(w.getHeight()) };
    }



    fn snapped(self: *Geometry, p: Pt) Pt {
        if (self.snap.getActive() == 0) return p;
        const step = gridStep(self.scene.scale);
        return .{ .x = @round(p.x / step) * step, .y = @round(p.y / step) * step };
    }


    /// The point under pixel (px, py), within a few pixels.
    fn pointAt(self: *Geometry, px: f64, py: f64) ?usize {
        var best: ?usize = null;
        var best_d: f64 = 11;
        for (self.scene.points.items, 0..) |p, i| {
            if (!p.alive) continue;
            const q = self.toPx(p.p);
            const d = std.math.hypot(q.x - px, q.y - py);
            if (d < best_d) {
                best_d = d;
                best = i;
            }
        }
        return best;
    }

    // ---- making shapes -------------------------------------------------------------------------


    /// The point clicked, or a new one there.
    fn pickPoint(self: *Geometry, px: f64, py: f64) usize {
        if (self.pointAt(px, py)) |i| return i;
        const here = self.snapped(self.toWorld(px, py));
        // A click that snaps onto a point already there is that point.
        for (self.scene.points.items, 0..) |p, i| {
            if (p.alive and @abs(p.p.x - here.x) < 1e-9 and @abs(p.p.y - here.y) < 1e-9) return i;
        }
        return self.addPoint(here);
    }


    fn press(self: *Geometry, px: f64, py: f64) void {
        switch (self.tool) {
            .move => {
                if (self.pointAt(px, py)) |i| {
                    self.dragging = i;
                } else {
                    self.pan = true;
                    self.drag_origin = .{ .x = self.scene.cx, .y = self.scene.cy };
                }
            },
            .point => _ = self.pickPoint(px, py),
            .erase => self.erase(px, py),
            .intersect => self.crossShapes(px, py),
            .paint => self.paintShape(px, py),
            else => {
                const i = self.pickPoint(px, py);
                self.pickedPoint(i);
            },
        }
        self.changed();
    }

    fn pickedPoint(self: *Geometry, i: usize) void {
        // Polygon: the first corner again closes it.
        if (self.tool == .polygon and self.picks.items.len >= 3 and i == self.picks.items[0]) {
            const ids = self.gpa.dupe(usize, self.picks.items) catch return;
            self.addShape(.{ .polygon = ids }) catch {
                self.gpa.free(ids);
                return;
            };
            self.picks.clearRetainingCapacity();
            return;
        }
        // The same point twice is not a segment.
        if (self.picks.items.len > 0 and self.picks.items[self.picks.items.len - 1] == i) return;
        self.picks.append(self.gpa, i) catch return;
        const p = self.picks.items;
        switch (self.tool) {
            .segment => if (p.len == 2) self.finish(.{ .segment = .{ p[0], p[1] } }),
            .line => if (p.len == 2) self.finish(.{ .line = .{ p[0], p[1] } }),
            .circle => if (p.len == 2) self.finish(.{ .circle = .{ p[0], p[1] } }),
            .angle => if (p.len == 3) self.finish(.{ .angle = .{ p[0], p[1], p[2] } }),
            else => {},
        }
    }

    /// Adds a shape in the current colour (polygons are shaded by default).
    fn addShape(self: *Geometry, s: Shape) !void {
        var style = self.current;
        style.fill = self.shade.getActive() != 0;
        try self.scene.shapes.append(self.gpa, s);
        self.scene.styles.append(self.gpa, style) catch {
            _ = self.scene.shapes.pop();
            return error.OutOfMemory;
        };
    }


    fn finish(self: *Geometry, s: Shape) void {
        self.addShape(s) catch return;
        self.picks.clearRetainingCapacity();
    }

    fn erase(self: *Geometry, px: f64, py: f64) void {
        if (self.pointAt(px, py)) |i| {
            self.scene.points.items[i].alive = false;
            self.dropDead();
            return;
        }
        const here = self.toWorld(px, py);
        const reach = 8.0 / self.scene.scale;
        var n = self.scene.shapes.items.len;
        while (n > 0) {
            n -= 1;
            if (self.shapeNear(self.scene.shapes.items[n], here, reach)) {
                const gone = self.scene.shapes.orderedRemove(n);
                _ = self.scene.styles.orderedRemove(n);
                if (gone == .polygon) self.gpa.free(gone.polygon);
                return;
            }
        }
    }


    fn shapeNear(self: *Geometry, s: Shape, p: Pt, reach: f64) bool {
        switch (s) {
            .segment => |e| return geom.distToSegment(p, self.pt(e[0]), self.pt(e[1])) <= reach,
            .line => |e| return geom.distToLine(p, self.pt(e[0]), self.pt(e[1])) <= reach,
            .circle => |e| return @abs(geom.dist(p, self.pt(e[0])) - geom.dist(self.pt(e[0]), self.pt(e[1]))) <= reach,
            .polygon => |ids| {
                for (ids, 0..) |id, k| {
                    if (geom.distToSegment(p, self.pt(id), self.pt(ids[(k + 1) % ids.len])) <= reach) return true;
                }
                return false;
            },
            .angle => |e| return geom.distToSegment(p, self.pt(e[1]), self.pt(e[0])) <= reach or geom.distToSegment(p, self.pt(e[1]), self.pt(e[2])) <= reach,
        }
    }

    /// Removes the shapes that used a point that is gone.
    fn dropDead(self: *Geometry) void {
        var n = self.scene.shapes.items.len;
        while (n > 0) {
            n -= 1;
            if (!self.shapeAlive(self.scene.shapes.items[n])) {
                const gone = self.scene.shapes.orderedRemove(n);
                _ = self.scene.styles.orderedRemove(n);
                if (gone == .polygon) self.gpa.free(gone.polygon);
            }
        }
        var k: usize = 0;
        while (k < self.picks.items.len) {
            if (!self.scene.points.items[self.picks.items[k]].alive) _ = self.picks.orderedRemove(k) else k += 1;
        }
    }

    fn shapeAlive(self: *Geometry, s: Shape) bool {
        const alive = struct {
            fn f(g: *Geometry, ids: []const usize) bool {
                for (ids) |i| if (!g.scene.points.items[i].alive) return false;
                return true;
            }
        }.f;
        return switch (s) {
            .segment => |e| alive(self, &e),
            .line => |e| alive(self, &e),
            .circle => |e| alive(self, &e),
            .polygon => |ids| alive(self, ids),
            .angle => |e| alive(self, &e),
        };
    }

    // ---- gestures ------------------------------------------------------------------------------

    fn onDragBegin(_: *gtk.GestureDrag, x: f64, y: f64, self: *Geometry) callconv(.c) void {
        self.drag_start = .{ .x = x, .y = y };
        self.press(x, y);
    }

    fn onDragUpdate(_: *gtk.GestureDrag, dx: f64, dy: f64, self: *Geometry) callconv(.c) void {
        if (self.dragging) |i| {
            const p = self.snapped(self.toWorld(self.drag_start.x + dx, self.drag_start.y + dy));
            self.scene.points.items[i].p = p;
            self.changed();
        } else if (self.pan) {
            self.scene.cx = self.drag_origin.x - dx / self.scene.scale;
            self.scene.cy = self.drag_origin.y + dy / self.scene.scale;
            self.area.as(gtk.Widget).queueDraw();
        }
    }

    fn onDragEnd(_: *gtk.GestureDrag, _: f64, _: f64, self: *Geometry) callconv(.c) void {
        self.dragging = null;
        self.pan = false;
    }

    fn onScroll(_: *gtk.EventControllerScroll, _: f64, dy: f64, self: *Geometry) callconv(.c) c_int {
        const factor: f64 = if (dy < 0) 1.15 else 1.0 / 1.15;
        self.scene.scale = std.math.clamp(self.scene.scale * factor, 2, 4000);
        self.area.as(gtk.Widget).queueDraw();
        return 1;
    }

    fn onMotion(_: *gtk.EventControllerMotion, x: f64, y: f64, self: *Geometry) callconv(.c) void {
        self.pointer = self.toWorld(x, y);
        self.area.as(gtk.Widget).queueDraw();
    }

    fn onLeave(_: *gtk.EventControllerMotion, self: *Geometry) callconv(.c) void {
        self.pointer = null;
        self.area.as(gtk.Widget).queueDraw();
    }

    fn onResetView(_: *gtk.Button, self: *Geometry) callconv(.c) void {
        self.scene.cx = 0;
        self.scene.cy = 0;
        self.scene.scale = 40;
        self.area.as(gtk.Widget).queueDraw();
    }

    fn onClearAll(_: *gtk.Button, self: *Geometry) callconv(.c) void {
        self.clearShapes();
        self.scene.points.clearRetainingCapacity();
        self.picks.clearRetainingCapacity();
        self.changed();
    }

    fn changed(self: *Geometry) void {
        self.area.as(gtk.Widget).queueDraw();
        self.fillResults();
    }

    // ---- names and numbers ---------------------------------------------------------------------

    fn paintShape(self: *Geometry, px: f64, py: f64) void {
        const here = self.toWorld(px, py);
        const reach = 8.0 / self.scene.scale;
        var n = self.scene.shapes.items.len;
        while (n > 0) {
            n -= 1;
            // Inside a polygon or a circle counts too, so shading is easy to reach.
            if (self.shapeNear(self.scene.shapes.items[n], here, reach) or self.shapeInside(self.scene.shapes.items[n], here)) {
                self.scene.styles.items[n] = .{ .color = self.current.color, .fill = self.shade.getActive() != 0 };
                return;
            }
        }
    }

    fn shapeInside(self: *Geometry, s: Shape, p: Pt) bool {
        switch (s) {
            .circle => |e| return geom.dist(p, self.pt(e[0])) <= geom.dist(self.pt(e[0]), self.pt(e[1])),
            .polygon => |ids| {
                var inside = false;
                var j = ids.len - 1;
                for (ids, 0..) |id, i| {
                    const a = self.pt(id);
                    const b = self.pt(ids[j]);
                    if ((a.y > p.y) != (b.y > p.y) and p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x) inside = !inside;
                    j = i;
                }
                return inside;
            },
            else => return false,
        }
    }

    fn crossShapes(self: *Geometry, px: f64, py: f64) void {
        const here = self.toWorld(px, py);
        const reach = 8.0 / self.scene.scale;
        var found: ?usize = null;
        var n = self.scene.shapes.items.len;
        while (n > 0 and found == null) {
            n -= 1;
            const s = self.scene.shapes.items[n];
            if (s == .polygon or s == .angle) continue;
            if (self.shapeNear(s, here, reach)) found = n;
        }
        const second = found orelse {
            self.first_shape = null;
            return;
        };
        const first = self.first_shape orelse {
            self.first_shape = second;
            return;
        };
        self.first_shape = null;
        if (first == second) return;
        const a = self.scene.shapes.items[first];
        const b = self.scene.shapes.items[second];
        var hits: [2]?Pt = .{ null, null };
        switch (a) {
            .circle => |ca| switch (b) {
                .circle => |cb| hits = geom.circleCircle(self.pt(ca[0]), geom.dist(self.pt(ca[0]), self.pt(ca[1])), self.pt(cb[0]), geom.dist(self.pt(cb[0]), self.pt(cb[1]))),
                .segment, .line => |l| hits = geom.lineCircle(self.pt(l[0]), self.pt(l[1]), self.pt(ca[0]), geom.dist(self.pt(ca[0]), self.pt(ca[1]))),
                else => {},
            },
            .segment, .line => |la| switch (b) {
                .circle => |cb| hits = geom.lineCircle(self.pt(la[0]), self.pt(la[1]), self.pt(cb[0]), geom.dist(self.pt(cb[0]), self.pt(cb[1]))),
                .segment, .line => |lb| {
                    if (geom.intersect(self.pt(la[0]), self.pt(la[1]), self.pt(lb[0]), self.pt(lb[1]))) |p| hits[0] = p;
                },
                else => {},
            },
            else => {},
        }
        // A segment only reaches as far as its ends.
        for (&hits) |*h| if (h.*) |p| {
            if (!self.onShape(a, p) or !self.onShape(b, p)) h.* = null;
        };
        for (hits) |h| if (h) |p| {
            // No second point where one already is.
            var exists = false;
            for (self.scene.points.items) |q| if (q.alive and geom.dist(q.p, p) < 1e-9) {
                exists = true;
            };
            if (!exists) _ = self.addPoint(p);
        };
    }

    fn onShape(self: *Geometry, s: Shape, p: Pt) bool {
        return switch (s) {
            .segment => |e| geom.distToSegment(p, self.pt(e[0]), self.pt(e[1])) < 1e-6,
            else => true,
        };
    }



    const Row = struct { gpa: std.mem.Allocator, geo: *Geometry, value: []u8 };

    fn onRowClicked(_: *gtk.Button, row: *Row) callconv(.c) void {
        row.geo.use_fn(row.geo.use_ctx, row.value);
    }

    fn onRowDestroy(_: *gtk.Button, row: *Row) callconv(.c) void {
        row.gpa.free(row.value);
        row.gpa.destroy(row);
    }

    fn addRow(self: *Geometry, text: []const u8, value: ?[]const u8) void {
        var buf: [256]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{text}, 0) catch return;
        const label = gtk.Label.new(z);
        label.setXalign(0);
        label.setWrap(1);
        label.setMaxWidthChars(44);
        const v = value orelse {
            label.as(gtk.Widget).addCssClass("dim-label");
            self.results.append(label.as(gtk.Widget));
            return;
        };
        const button = gtk.Button.new();
        button.setChild(label.as(gtk.Widget));
        button.setHasFrame(0);
        const row = self.gpa.create(Row) catch return;
        row.* = .{ .gpa = self.gpa, .geo = self, .value = self.gpa.dupe(u8, v) catch {
            self.gpa.destroy(row);
            return;
        } };
        _ = gtk.Button.signals.clicked.connect(button, *Row, &onRowClicked, row, .{});
        _ = gtk.Widget.signals.destroy.connect(button, *Row, &onRowDestroy, row, .{});
        self.results.append(button.as(gtk.Widget));
    }

    fn fillResults(self: *Geometry) void {
        while (self.results.as(gtk.Widget).getFirstChild()) |c| self.results.remove(c);
        var line: [256]u8 = undefined;
        var b1: [32]u8 = undefined;
        var b2: [32]u8 = undefined;
        var n1: [16]u8 = undefined;
        var n2: [16]u8 = undefined;
        var n3: [16]u8 = undefined;
        for (self.scene.points.items, 0..) |p, i| {
            if (!p.alive) continue;
            const text = std.fmt.bufPrint(&line, "{s} = ({s}, {s})", .{ self.nameOf(&n1, i), num(&b1, p.p.x), num(&b2, p.p.y) }) catch continue;
            self.addRow(text, null);
        }
        for (self.scene.shapes.items) |s| switch (s) {
            .segment => |e| {
                const d = geom.dist(self.pt(e[0]), self.pt(e[1]));
                const m = geom.midpoint(self.pt(e[0]), self.pt(e[1]));
                const dist_text = num(&b1, d);
                const text = std.fmt.bufPrint(&line, "{s}{s} = {s}   (midpoint {s}, {s})", .{ self.nameOf(&n1, e[0]), self.nameOf(&n2, e[1]), dist_text, num(&b2, m.x), num(&n3, m.y) }) catch continue;
                self.addRow(text, dist_text);
            },
            .line => |e| {
                const a = self.pt(e[0]);
                const b = self.pt(e[1]);
                if (geom.slope(a, b)) |m| {
                    const k = a.y - m * a.x;
                    const slope_text = num(&b1, m);
                    var kb: [32]u8 = undefined;
                    const text = std.fmt.bufPrint(&line, "line {s}{s}: y = {s}x + {s}   (slope {s})", .{ self.nameOf(&n1, e[0]), self.nameOf(&n2, e[1]), slope_text, num(&kb, k), slope_text }) catch continue;
                    self.addRow(text, slope_text);
                } else {
                    const text = std.fmt.bufPrint(&line, "line {s}{s}: x = {s}   (vertical)", .{ self.nameOf(&n1, e[0]), self.nameOf(&n2, e[1]), num(&b1, a.x) }) catch continue;
                    self.addRow(text, null);
                }
            },
            .circle => |e| {
                const r = geom.dist(self.pt(e[0]), self.pt(e[1]));
                const radius = num(&b1, r);
                const text = std.fmt.bufPrint(&line, "circle centre {s}: radius {s}", .{ self.nameOf(&n1, e[0]), radius }) catch continue;
                self.addRow(text, radius);
                var ab: [32]u8 = undefined;
                const area_text = num(&ab, std.math.pi * r * r);
                const t2 = std.fmt.bufPrint(&line, "   area = {s}   (π·r²)", .{area_text}) catch continue;
                self.addRow(t2, area_text);
                var cb: [32]u8 = undefined;
                const circ = num(&cb, 2 * std.math.pi * r);
                const t3 = std.fmt.bufPrint(&line, "   circumference = {s}   (2·π·r)", .{circ}) catch continue;
                self.addRow(t3, circ);
            },
            .polygon => |ids| {
                var pts: [64]Pt = undefined;
                const count = @min(ids.len, pts.len);
                for (ids[0..count], 0..) |id, k| pts[k] = self.pt(id);
                var name: [96]u8 = undefined;
                var w: usize = 0;
                for (ids[0..count]) |id| {
                    const part = self.nameOf(&n1, id);
                    if (w + part.len > name.len) break;
                    @memcpy(name[w..][0..part.len], part);
                    w += part.len;
                }
                const area_text = num(&b1, geom.polygonArea(pts[0..count]));
                const per_text = num(&b2, geom.perimeter(pts[0..count]));
                const kind: []const u8 = if (count == 3) geom.triangleKind(pts[0], pts[1], pts[2]) else "";
                const text = std.fmt.bufPrint(&line, "{s} {s}: area {s}, perimeter {s}", .{ if (count == 3) "triangle" else "polygon", name[0..w], area_text, per_text }) catch continue;
                self.addRow(text, area_text);
                if (kind.len > 0) {
                    const t2 = std.fmt.bufPrint(&line, "   a {s} triangle", .{kind}) catch continue;
                    self.addRow(t2, null);
                }
                const t3 = std.fmt.bufPrint(&line, "   perimeter = {s}", .{per_text}) catch continue;
                self.addRow(t3, per_text);
            },
            .angle => |e| {
                const deg = geom.angleDeg(self.pt(e[0]), self.pt(e[1]), self.pt(e[2]));
                const deg_text = num(&b1, deg);
                const text = std.fmt.bufPrint(&line, "∠{s}{s}{s} = {s}°   ({s} rad)", .{ self.nameOf(&n1, e[0]), self.nameOf(&n2, e[1]), self.nameOf(&n3, e[2]), deg_text, num(&b2, deg * std.math.pi / 180.0) }) catch continue;
                self.addRow(text, deg_text);
            },
        };
        if (self.results.as(gtk.Widget).getFirstChild() == null) self.addRow(t("Nothing drawn yet."), null);
    }

    // ---- drawing -------------------------------------------------------------------------------




};
