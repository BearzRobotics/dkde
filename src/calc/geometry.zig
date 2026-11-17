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
const Pt = geom.Pt;

const t = common.tr;

const Tool = enum { move, point, segment, line, circle, polygon, angle, intersect, erase };

const tool_names = [_]struct { tool: Tool, label: [:0]const u8, tip: [:0]const u8 }{
    .{ .tool = .move, .label = "Move", .tip = "Drag points to move them; drag the background to pan" },
    .{ .tool = .point, .label = "Point", .tip = "Click to place a point" },
    .{ .tool = .segment, .label = "Segment", .tip = "Click two points: a segment with its length" },
    .{ .tool = .line, .label = "Line", .tip = "Click two points: the line through them, with its slope" },
    .{ .tool = .circle, .label = "Circle", .tip = "Click the centre, then a point on the circle" },
    .{ .tool = .polygon, .label = "Polygon", .tip = "Click the corners; click the first one again to close it" },
    .{ .tool = .angle, .label = "Angle", .tip = "Click a point on one arm, the corner, then a point on the other arm" },
    .{ .tool = .intersect, .label = "Cross", .tip = "Click two lines or circles: a point where they cross" },
    .{ .tool = .erase, .label = "Erase", .tip = "Click a point or a line to remove it (and what depends on it)" },
};

const Point = struct { p: Pt, alive: bool = true };

const Shape = union(enum) {
    segment: [2]usize,
    line: [2]usize,
    circle: [2]usize,
    polygon: []usize,
    angle: [3]usize,
};

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

    points: std.ArrayList(Point) = .empty,
    shapes: std.ArrayList(Shape) = .empty,
    tool: Tool = .move,
    /// Points picked so far for the shape being made.
    picks: std.ArrayList(usize) = .empty,
    /// The first of two shapes picked for "Cross".
    first_shape: ?usize = null,
    /// The view: the world point in the middle, and pixels per unit.
    cx: f64 = 0,
    cy: f64 = 0,
    scale: f64 = 40,
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

    pub fn widget(self: *Geometry) *gtk.Widget {
        return self.root.as(gtk.Widget);
    }

    pub fn destroy(self: *Geometry) void {
        self.clearShapes();
        self.shapes.deinit(self.gpa);
        self.points.deinit(self.gpa);
        self.picks.deinit(self.gpa);
        self.gpa.destroy(self);
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
            .erase => t("Click a point or a line to remove it."),
        };
        self.status.setText(text);
    }

    // ---- coordinates ---------------------------------------------------------------------------

    fn size(self: *Geometry) [2]f64 {
        const w = self.area.as(gtk.Widget);
        return .{ @floatFromInt(w.getWidth()), @floatFromInt(w.getHeight()) };
    }

    fn toWorld(self: *Geometry, px: f64, py: f64) Pt {
        const s = self.size();
        return .{ .x = self.cx + (px - s[0] / 2) / self.scale, .y = self.cy - (py - s[1] / 2) / self.scale };
    }

    fn toPx(self: *Geometry, p: Pt) Pt {
        const s = self.size();
        return .{ .x = s[0] / 2 + (p.x - self.cx) * self.scale, .y = s[1] / 2 - (p.y - self.cy) * self.scale };
    }

    fn snapped(self: *Geometry, p: Pt) Pt {
        if (self.snap.getActive() == 0) return p;
        const step = gridStep(self.scale);
        return .{ .x = @round(p.x / step) * step, .y = @round(p.y / step) * step };
    }

    /// The grid spacing in world units: 1, 2, 5, 10... so lines are 30 to 80 pixels apart.
    fn gridStep(scale: f64) f64 {
        const want = 40.0 / scale;
        const mag = std.math.pow(f64, 10, @floor(std.math.log10(want)));
        const f = want / mag;
        const nice: f64 = if (f < 1.5) 1 else if (f < 3.5) 2 else if (f < 7.5) 5 else 10;
        return nice * mag;
    }

    /// The point under pixel (px, py), within a few pixels.
    fn pointAt(self: *Geometry, px: f64, py: f64) ?usize {
        var best: ?usize = null;
        var best_d: f64 = 11;
        for (self.points.items, 0..) |p, i| {
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

    fn addPoint(self: *Geometry, p: Pt) usize {
        self.points.append(self.gpa, .{ .p = p }) catch return 0;
        return self.points.items.len - 1;
    }

    /// The point clicked, or a new one there.
    fn pickPoint(self: *Geometry, px: f64, py: f64) usize {
        if (self.pointAt(px, py)) |i| return i;
        const here = self.snapped(self.toWorld(px, py));
        // A click that snaps onto a point already there is that point.
        for (self.points.items, 0..) |p, i| {
            if (p.alive and @abs(p.p.x - here.x) < 1e-9 and @abs(p.p.y - here.y) < 1e-9) return i;
        }
        return self.addPoint(here);
    }

    fn clearShapes(self: *Geometry) void {
        for (self.shapes.items) |s| if (s == .polygon) self.gpa.free(s.polygon);
        self.shapes.clearRetainingCapacity();
    }

    fn press(self: *Geometry, px: f64, py: f64) void {
        switch (self.tool) {
            .move => {
                if (self.pointAt(px, py)) |i| {
                    self.dragging = i;
                } else {
                    self.pan = true;
                    self.drag_origin = .{ .x = self.cx, .y = self.cy };
                }
            },
            .point => _ = self.pickPoint(px, py),
            .erase => self.erase(px, py),
            .intersect => self.crossShapes(px, py),
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
            self.shapes.append(self.gpa, .{ .polygon = ids }) catch {
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

    fn finish(self: *Geometry, s: Shape) void {
        self.shapes.append(self.gpa, s) catch return;
        self.picks.clearRetainingCapacity();
    }

    fn erase(self: *Geometry, px: f64, py: f64) void {
        if (self.pointAt(px, py)) |i| {
            self.points.items[i].alive = false;
            self.dropDead();
            return;
        }
        const here = self.toWorld(px, py);
        const reach = 8.0 / self.scale;
        var n = self.shapes.items.len;
        while (n > 0) {
            n -= 1;
            if (self.shapeNear(self.shapes.items[n], here, reach)) {
                const gone = self.shapes.orderedRemove(n);
                if (gone == .polygon) self.gpa.free(gone.polygon);
                return;
            }
        }
    }

    fn pt(self: *Geometry, i: usize) Pt {
        return self.points.items[i].p;
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
        var n = self.shapes.items.len;
        while (n > 0) {
            n -= 1;
            if (!self.shapeAlive(self.shapes.items[n])) {
                const gone = self.shapes.orderedRemove(n);
                if (gone == .polygon) self.gpa.free(gone.polygon);
            }
        }
        var k: usize = 0;
        while (k < self.picks.items.len) {
            if (!self.points.items[self.picks.items[k]].alive) _ = self.picks.orderedRemove(k) else k += 1;
        }
    }

    fn shapeAlive(self: *Geometry, s: Shape) bool {
        const alive = struct {
            fn f(g: *Geometry, ids: []const usize) bool {
                for (ids) |i| if (!g.points.items[i].alive) return false;
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
            self.points.items[i].p = p;
            self.changed();
        } else if (self.pan) {
            self.cx = self.drag_origin.x - dx / self.scale;
            self.cy = self.drag_origin.y + dy / self.scale;
            self.area.as(gtk.Widget).queueDraw();
        }
    }

    fn onDragEnd(_: *gtk.GestureDrag, _: f64, _: f64, self: *Geometry) callconv(.c) void {
        self.dragging = null;
        self.pan = false;
    }

    fn onScroll(_: *gtk.EventControllerScroll, _: f64, dy: f64, self: *Geometry) callconv(.c) c_int {
        const factor: f64 = if (dy < 0) 1.15 else 1.0 / 1.15;
        self.scale = std.math.clamp(self.scale * factor, 2, 4000);
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
        self.cx = 0;
        self.cy = 0;
        self.scale = 40;
        self.area.as(gtk.Widget).queueDraw();
    }

    fn onClearAll(_: *gtk.Button, self: *Geometry) callconv(.c) void {
        self.clearShapes();
        self.points.clearRetainingCapacity();
        self.picks.clearRetainingCapacity();
        self.changed();
    }

    fn changed(self: *Geometry) void {
        self.area.as(gtk.Widget).queueDraw();
        self.fillResults();
    }

    // ---- names and numbers ---------------------------------------------------------------------

    fn crossShapes(self: *Geometry, px: f64, py: f64) void {
        const here = self.toWorld(px, py);
        const reach = 8.0 / self.scale;
        var found: ?usize = null;
        var n = self.shapes.items.len;
        while (n > 0 and found == null) {
            n -= 1;
            const s = self.shapes.items[n];
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
        const a = self.shapes.items[first];
        const b = self.shapes.items[second];
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
            for (self.points.items) |q| if (q.alive and geom.dist(q.p, p) < 1e-9) {
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

    /// A, B, ... Z, then A1, B1, ...
    fn nameOf(buf: []u8, i: usize) []const u8 {
        const letter: u8 = 'A' + @as(u8, @intCast(i % 26));
        return if (i < 26) std.fmt.bufPrint(buf, "{c}", .{letter}) catch "?" else std.fmt.bufPrint(buf, "{c}{d}", .{ letter, i / 26 }) catch "?";
    }

    /// A number with at most four decimals and no trailing zeros.
    fn num(buf: []u8, v: f64) []const u8 {
        if (std.math.isNan(v)) return "?";
        const text = std.fmt.bufPrint(buf, "{d:.4}", .{v}) catch return "?";
        if (std.mem.indexOfScalar(u8, text, '.') == null) return text;
        var end = text.len;
        while (end > 0 and text[end - 1] == '0') end -= 1;
        if (end > 0 and text[end - 1] == '.') end -= 1;
        return if (end == 0 or std.mem.eql(u8, text[0..end], "-")) "0" else text[0..end];
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
        for (self.points.items, 0..) |p, i| {
            if (!p.alive) continue;
            const text = std.fmt.bufPrint(&line, "{s} = ({s}, {s})", .{ nameOf(&n1, i), num(&b1, p.p.x), num(&b2, p.p.y) }) catch continue;
            self.addRow(text, null);
        }
        for (self.shapes.items) |s| switch (s) {
            .segment => |e| {
                const d = geom.dist(self.pt(e[0]), self.pt(e[1]));
                const m = geom.midpoint(self.pt(e[0]), self.pt(e[1]));
                const dist_text = num(&b1, d);
                const text = std.fmt.bufPrint(&line, "{s}{s} = {s}   (midpoint {s}, {s})", .{ nameOf(&n1, e[0]), nameOf(&n2, e[1]), dist_text, num(&b2, m.x), num(&n3, m.y) }) catch continue;
                self.addRow(text, dist_text);
            },
            .line => |e| {
                const a = self.pt(e[0]);
                const b = self.pt(e[1]);
                if (geom.slope(a, b)) |m| {
                    const k = a.y - m * a.x;
                    const slope_text = num(&b1, m);
                    var kb: [32]u8 = undefined;
                    const text = std.fmt.bufPrint(&line, "line {s}{s}: y = {s}x + {s}   (slope {s})", .{ nameOf(&n1, e[0]), nameOf(&n2, e[1]), slope_text, num(&kb, k), slope_text }) catch continue;
                    self.addRow(text, slope_text);
                } else {
                    const text = std.fmt.bufPrint(&line, "line {s}{s}: x = {s}   (vertical)", .{ nameOf(&n1, e[0]), nameOf(&n2, e[1]), num(&b1, a.x) }) catch continue;
                    self.addRow(text, null);
                }
            },
            .circle => |e| {
                const r = geom.dist(self.pt(e[0]), self.pt(e[1]));
                const radius = num(&b1, r);
                const text = std.fmt.bufPrint(&line, "circle centre {s}: radius {s}", .{ nameOf(&n1, e[0]), radius }) catch continue;
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
                    const part = nameOf(&n1, id);
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
                const text = std.fmt.bufPrint(&line, "∠{s}{s}{s} = {s}°   ({s} rad)", .{ nameOf(&n1, e[0]), nameOf(&n2, e[1]), nameOf(&n3, e[2]), deg_text, num(&b2, deg * std.math.pi / 180.0) }) catch continue;
                self.addRow(text, deg_text);
            },
        };
        if (self.results.as(gtk.Widget).getFirstChild() == null) self.addRow(t("Nothing drawn yet."), null);
    }

    // ---- drawing -------------------------------------------------------------------------------

    fn onDraw(_: *gtk.DrawingArea, cr: *cairo.Context, w: c_int, h: c_int, data: ?*anyopaque) callconv(.c) void {
        const self: *Geometry = @ptrCast(@alignCast(data.?));
        self.draw(cr, @floatFromInt(w), @floatFromInt(h));
    }

    fn drawText(cr: *cairo.Context, x: f64, y: f64, s: []const u8) void {
        const layout = pangocairo.createLayout(cr);
        defer layout.as(gobject.Object).unref();
        layout.setText(@ptrCast(s.ptr), @intCast(s.len));
        cr.moveTo(x, y);
        pangocairo.showLayout(cr, layout);
    }

    fn draw(self: *Geometry, cr: *cairo.Context, w: f64, h: f64) void {
        var fg: gdk.RGBA = undefined;
        self.area.as(gtk.Widget).getColor(&fg);
        // The grid and the axes.
        const step = gridStep(self.scale);
        cr.setLineWidth(1);
        cr.setSourceRgba(fg.f_red, fg.f_green, fg.f_blue, 0.12);
        const left = self.toWorld(0, 0);
        const right = self.toWorld(w, h);
        var gx = @ceil(left.x / step) * step;
        while (gx <= right.x) : (gx += step) {
            const px = self.toPx(.{ .x = gx, .y = 0 }).x;
            cr.moveTo(px + 0.5, 0);
            cr.lineTo(px + 0.5, h);
        }
        var gy = @ceil(right.y / step) * step;
        while (gy <= left.y) : (gy += step) {
            const py = self.toPx(.{ .x = 0, .y = gy }).y;
            cr.moveTo(0, py + 0.5);
            cr.lineTo(w, py + 0.5);
        }
        cr.stroke();
        const origin = self.toPx(.{ .x = 0, .y = 0 });
        cr.setSourceRgba(fg.f_red, fg.f_green, fg.f_blue, 0.35);
        cr.moveTo(origin.x + 0.5, 0);
        cr.lineTo(origin.x + 0.5, h);
        cr.moveTo(0, origin.y + 0.5);
        cr.lineTo(w, origin.y + 0.5);
        cr.stroke();

        const blue = [3]f64{ 0.15, 0.4, 0.85 };
        // The shapes.
        cr.setLineWidth(2);
        for (self.shapes.items) |s| switch (s) {
            .segment => |e| {
                const a = self.toPx(self.pt(e[0]));
                const b = self.toPx(self.pt(e[1]));
                cr.setSourceRgb(blue[0], blue[1], blue[2]);
                cr.moveTo(a.x, a.y);
                cr.lineTo(b.x, b.y);
                cr.stroke();
                var buf: [32]u8 = undefined;
                const m = geom.midpoint(a, b);
                cr.setSourceRgba(fg.f_red, fg.f_green, fg.f_blue, 0.85);
                drawText(cr, m.x + 4, m.y + 2, num(&buf, geom.dist(self.pt(e[0]), self.pt(e[1]))));
            },
            .line => |e| {
                const a = self.toPx(self.pt(e[0]));
                const b = self.toPx(self.pt(e[1]));
                const dx = b.x - a.x;
                const dy = b.y - a.y;
                const len = std.math.hypot(dx, dy);
                if (len > 0) {
                    const far = (w + h) * 2;
                    cr.setSourceRgb(blue[0], blue[1], blue[2]);
                    cr.moveTo(a.x - dx / len * far, a.y - dy / len * far);
                    cr.lineTo(a.x + dx / len * far, a.y + dy / len * far);
                    cr.stroke();
                }
            },
            .circle => |e| {
                const c = self.toPx(self.pt(e[0]));
                const r = geom.dist(self.pt(e[0]), self.pt(e[1])) * self.scale;
                cr.setSourceRgb(blue[0], blue[1], blue[2]);
                cr.newSubPath();
                cr.arc(c.x, c.y, r, 0, 2 * std.math.pi);
                cr.stroke();
                // The radius.
                const p = self.toPx(self.pt(e[1]));
                cr.setSourceRgba(blue[0], blue[1], blue[2], 0.5);
                cr.setLineWidth(1);
                cr.moveTo(c.x, c.y);
                cr.lineTo(p.x, p.y);
                cr.stroke();
                cr.setLineWidth(2);
            },
            .polygon => |ids| {
                for (ids, 0..) |id, k| {
                    const p = self.toPx(self.pt(id));
                    if (k == 0) cr.moveTo(p.x, p.y) else cr.lineTo(p.x, p.y);
                }
                cr.closePath();
                cr.setSourceRgba(blue[0], blue[1], blue[2], 0.12);
                cr.fillPreserve();
                cr.setSourceRgb(blue[0], blue[1], blue[2]);
                cr.stroke();
            },
            .angle => |e| {
                const v = self.toPx(self.pt(e[1]));
                const a = self.toPx(self.pt(e[0]));
                const c = self.toPx(self.pt(e[2]));
                cr.setSourceRgb(0.8, 0.3, 0.1);
                cr.setLineWidth(1.5);
                cr.moveTo(a.x, a.y);
                cr.lineTo(v.x, v.y);
                cr.lineTo(c.x, c.y);
                cr.stroke();
                // The arc, from one arm to the other the short way round (y is down on the screen).
                const ha = std.math.atan2(a.y - v.y, a.x - v.x);
                const hc = std.math.atan2(c.y - v.y, c.x - v.x);
                var diff = hc - ha;
                while (diff > std.math.pi) diff -= 2 * std.math.pi;
                while (diff < -std.math.pi) diff += 2 * std.math.pi;
                cr.newSubPath();
                if (diff >= 0) cr.arc(v.x, v.y, 22, ha, ha + diff) else cr.arcNegative(v.x, v.y, 22, ha, ha + diff);
                cr.stroke();
                var buf: [32]u8 = undefined;
                var lab: [40]u8 = undefined;
                const label = std.fmt.bufPrint(&lab, "{s}°", .{num(&buf, geom.angleDeg(self.pt(e[0]), self.pt(e[1]), self.pt(e[2])))}) catch "";
                const mid = ha + diff / 2;
                drawText(cr, v.x + @cos(mid) * 34 - 10, v.y + @sin(mid) * 34 - 8, label);
                cr.setLineWidth(2);
            },
        };

        // What is being made: the picks so far, with a line to the pointer.
        if (self.picks.items.len > 0) {
            cr.setSourceRgba(blue[0], blue[1], blue[2], 0.5);
            cr.setLineWidth(1.5);
            const dashes = [_]f64{ 4, 3 };
            cr.setDash(&dashes, 2, 0);
            for (self.picks.items, 0..) |id, k| {
                const p = self.toPx(self.pt(id));
                if (k == 0) cr.moveTo(p.x, p.y) else cr.lineTo(p.x, p.y);
            }
            if (self.pointer) |m| {
                const p = self.toPx(m);
                cr.lineTo(p.x, p.y);
            }
            cr.stroke();
            cr.setDash(&.{}, 0, 0);
        }

        // The points, with their names.
        for (self.points.items, 0..) |p, i| {
            if (!p.alive) continue;
            const q = self.toPx(p.p);
            const picked = std.mem.indexOfScalar(usize, self.picks.items, i) != null;
            cr.newSubPath();
            cr.arc(q.x, q.y, if (picked) 6 else 4.5, 0, 2 * std.math.pi);
            cr.setSourceRgb(if (picked) 0.8 else 0.1, if (picked) 0.3 else 0.1, if (picked) 0.1 else 0.1);
            cr.fill();
            var nb: [8]u8 = undefined;
            cr.setSourceRgba(fg.f_red, fg.f_green, fg.f_blue, 0.9);
            drawText(cr, q.x + 6, q.y - 18, nameOf(&nb, i));
        }
        // The pointer's coordinates.
        if (self.pointer) |m| {
            var b1: [32]u8 = undefined;
            var b2: [32]u8 = undefined;
            var lab: [80]u8 = undefined;
            const s = self.snapped(m);
            const label = std.fmt.bufPrint(&lab, "({s}, {s})", .{ num(&b1, s.x), num(&b2, s.y) }) catch "";
            cr.setSourceRgba(fg.f_red, fg.f_green, fg.f_blue, 0.55);
            drawText(cr, 6, h - 20, label);
        }
    }
};
