//! A figure on a canvas, without any window: the points, shapes and styles, how they are drawn with
//! cairo, and the operations lessons use to build one. The Geometry pane shows a Scene in a widget; the
//! command-line renderer draws the same Scene to a PNG or SVG file.

const std = @import("std");
const cairo = @import("cairo1");
const gobject = @import("gobject2");
const pangocairo = @import("pangocairo1");

const geom = @import("geom.zig");
const figure = @import("figure.zig");
const Pt = geom.Pt;

pub const Point = struct { p: Pt, z: f64 = 0, alive: bool = true, name: [6]u8 = @splat(0) };

/// How a shape is drawn: one of the palette's colours, and shaded or not.
pub const Style = struct { color: u8 = 0, fill: bool = false };

pub const palette = [_][3]f64{
    .{ 0.15, 0.40, 0.85 }, // blue
    .{ 0.84, 0.15, 0.16 }, // red
    .{ 0.17, 0.63, 0.17 }, // green
    .{ 0.95, 0.55, 0.05 }, // orange
    .{ 0.58, 0.40, 0.74 }, // purple
    .{ 0.09, 0.62, 0.65 }, // teal
    .{ 0.80, 0.70, 0.05 }, // yellow
    .{ 0.15, 0.15, 0.15 }, // black
};

pub const Shape = union(enum) {
    segment: [2]usize,
    line: [2]usize,
    circle: [2]usize,
    polygon: []usize,
    angle: [3]usize,
};

/// What is drawn over the figure while it is being made.
pub const Overlay = struct {
    picks: []const usize = &.{},
    pointer: ?Pt = null,
    pointer_label: ?[]const u8 = null,
};

pub const Scene = struct {
    gpa: std.mem.Allocator,
    points: std.ArrayList(Point) = .empty,
    shapes: std.ArrayList(Shape) = .empty,
    /// The look of each shape, in step with `shapes`.
    styles: std.ArrayList(Style) = .empty,
    /// The view: the world point in the middle, and pixels per unit.
    cx: f64 = 0,
    cy: f64 = 0,
    scale: f64 = 40,
    /// The size of the canvas in pixels.
    width: f64 = 0,
    height: f64 = 0,
    /// Lengths and angle sizes written on the figure.
    numbers: bool = true,
    /// A fit asked for before the canvas had a size: done at the first drawing.
    fit_pending: bool = false,
    /// Three dimensions: points have a height, and are drawn in parallel projection turned by yaw and pitch.
    view3d: bool = false,
    yaw: f64 = -0.62,
    pitch: f64 = 0.42,

    pub fn init(gpa: std.mem.Allocator) Scene {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Scene) void {
        self.clearShapes();
        self.shapes.deinit(self.gpa);
        self.styles.deinit(self.gpa);
        self.points.deinit(self.gpa);
    }

    /// Empties the canvas (the view stays).
    pub fn clearAll(self: *Scene) void {
        self.clearShapes();
        self.points.clearRetainingCapacity();
    }

    pub fn size(self: *Scene) [2]f64 {
        return .{ self.width, self.height };
    }

    /// Where a point is on the flat figure: its own place, or in 3D its projection.
    pub fn pt(self: *Scene, i: usize) Pt {
        const q = self.points.items[i];
        if (!self.view3d) return q.p;
        const c = @cos(self.yaw);
        const sn = @sin(self.yaw);
        const x1 = q.p.x * c - q.p.y * sn;
        const y1 = q.p.x * sn + q.p.y * c;
        return .{ .x = x1, .y = y1 * @sin(self.pitch) + q.z * @cos(self.pitch) };
    }

    /// How far a point is from the viewer in 3D (larger is further away).
    pub fn depth(self: *Scene, i: usize) f64 {
        const q = self.points.items[i];
        const y1 = q.p.x * @sin(self.yaw) + q.p.y * @cos(self.yaw);
        return y1 * @cos(self.pitch) - q.z * @sin(self.pitch);
    }

    /// How lit a face is (0.2 to 0.8): its normal against a light up, to the left and in front.
    fn faceLight(self: *Scene, ids: []const usize) f64 {
        const v = struct {
            fn at(sc: *Scene, i: usize) [3]f64 {
                const q = sc.pt(i);
                return .{ q.x, q.y, sc.depth(i) };
            }
        }.at;
        const a = v(self, ids[0]);
        const b = v(self, ids[1]);
        const c = v(self, ids[2]);
        const u = [3]f64{ b[0] - a[0], b[1] - a[1], b[2] - a[2] };
        const w = [3]f64{ c[0] - a[0], c[1] - a[1], c[2] - a[2] };
        const n = [3]f64{ u[1] * w[2] - u[2] * w[1], u[2] * w[0] - u[0] * w[2], u[0] * w[1] - u[1] * w[0] };
        const len = @sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
        if (len == 0) return 0.35;
        const l = [3]f64{ -0.35, 0.55, -0.76 };
        const d = @abs((n[0] * l[0] + n[1] * l[1] + n[2] * l[2]) / len);
        return 0.2 + 0.6 * d;
    }

    fn shapeDepth(self: *Scene, s: Shape) f64 {
        var sum: f64 = 0;
        var n: f64 = 0;
        switch (s) {
            .segment, .line, .circle => |e| {
                for (e) |i| {
                    sum += self.depth(i);
                    n += 1;
                }
            },
            .angle => |e| {
                for (e) |i| {
                    sum += self.depth(i);
                    n += 1;
                }
            },
            .polygon => |ids| {
                for (ids) |i| {
                    sum += self.depth(i);
                    n += 1;
                }
            },
        }
        return if (n > 0) sum / n else 0;
    }

    pub fn toWorld(self: *Scene, px: f64, py: f64) Pt {
        const s = self.size();
        return .{ .x = self.cx + (px - s[0] / 2) / self.scale, .y = self.cy - (py - s[1] / 2) / self.scale };
    }

    pub fn toPx(self: *Scene, p: Pt) Pt {
        const s = self.size();
        return .{ .x = s[0] / 2 + (p.x - self.cx) * self.scale, .y = s[1] / 2 - (p.y - self.cy) * self.scale };
    }

    /// The grid spacing in world units: 1, 2, 5, 10... so lines are 30 to 80 pixels apart.
    pub fn gridStep(scale: f64) f64 {
        const want = 40.0 / scale;
        const mag = std.math.pow(f64, 10, @floor(std.math.log10(want)));
        const f = want / mag;
        const nice: f64 = if (f < 1.5) 1 else if (f < 3.5) 2 else if (f < 7.5) 5 else 10;
        return nice * mag;
    }

    pub fn addPoint(self: *Scene, p: Pt) usize {
        self.points.append(self.gpa, .{ .p = p }) catch return 0;
        return self.points.items.len - 1;
    }

    pub fn findPoint(self: *Scene, name: []const u8) ?usize {
        for (self.points.items, 0..) |p, i| {
            if (p.alive and std.mem.eql(u8, std.mem.sliceTo(&p.name, 0), name)) return i;
        }
        return null;
    }

    pub fn addNamed(self: *Scene, name: []const u8, p: Pt) void {
        var point: Point = .{ .p = p };
        const n = @min(name.len, point.name.len - 1);
        @memcpy(point.name[0..n], name[0..n]);
        self.points.append(self.gpa, point) catch {};
    }

    /// A, B, ... Z, then A1, B1, ...
    pub fn nameOf(self: *Scene, buf: []u8, i: usize) []const u8 {
        const given = std.mem.sliceTo(&self.points.items[i].name, 0);
        if (given.len > 0) {
            const n = @min(given.len, buf.len);
            @memcpy(buf[0..n], given[0..n]);
            return buf[0..n];
        }
        const letter: u8 = 'A' + @as(u8, @intCast(i % 26));
        return if (i < 26) std.fmt.bufPrint(buf, "{c}", .{letter}) catch "?" else std.fmt.bufPrint(buf, "{c}{d}", .{ letter, i / 26 }) catch "?";
    }

    /// A number with at most four decimals and no trailing zeros.
    pub fn num(buf: []u8, v: f64) []const u8 {
        if (std.math.isNan(v)) return "?";
        const text = std.fmt.bufPrint(buf, "{d:.4}", .{v}) catch return "?";
        if (std.mem.indexOfScalar(u8, text, '.') == null) return text;
        var end = text.len;
        while (end > 0 and text[end - 1] == '0') end -= 1;
        if (end > 0 and text[end - 1] == '.') end -= 1;
        return if (end == 0 or std.mem.eql(u8, text[0..end], "-")) "0" else text[0..end];
    }

    pub fn clearShapes(self: *Scene) void {
        for (self.shapes.items) |s| if (s == .polygon) self.gpa.free(s.polygon);
        self.shapes.clearRetainingCapacity();
        self.styles.clearRetainingCapacity();
    }

    pub fn addShapeStyled(self: *Scene, s: Shape, style: Style) !void {
        try self.shapes.append(self.gpa, s);
        self.styles.append(self.gpa, style) catch {
            _ = self.shapes.pop();
            return error.OutOfMemory;
        };
    }

    /// Carries out the operations of one lesson step.
    pub fn runOps(self: *Scene, ops: []const figure.Op) void {
        for (ops) |op| self.runOp(op);
    }

    pub fn runOp(self: *Scene, op: figure.Op) void {
        switch (op) {
            .clear => {
                self.clearShapes();
                self.points.clearRetainingCapacity();
                self.view3d = false;
                self.yaw = -0.62;
                self.pitch = 0.42;
            },
            .view3d => self.view3d = true,
            .pt => |o| {
                if (self.findPoint(o.n)) |i| {
                    self.points.items[i].p = .{ .x = o.x, .y = o.y };
                    self.points.items[i].z = o.z;
                    return;
                }
                self.addNamed(o.n, .{ .x = o.x, .y = o.y });
                self.points.items[self.points.items.len - 1].z = o.z;
            },
            .seg => |o| {
                const a = self.findPoint(o.a) orelse return;
                const b = self.findPoint(o.b) orelse return;
                self.addShapeStyled(.{ .segment = .{ a, b } }, .{ .color = o.colour }) catch {};
            },
            .line => |o| {
                const a = self.findPoint(o.a) orelse return;
                const b = self.findPoint(o.b) orelse return;
                self.addShapeStyled(.{ .line = .{ a, b } }, .{ .color = o.colour }) catch {};
            },
            .circle => |o| {
                const c = self.findPoint(o.c) orelse return;
                const tp = self.findPoint(o.t) orelse return;
                self.addShapeStyled(.{ .circle = .{ c, tp } }, .{ .color = o.colour, .fill = o.fill }) catch {};
            },
            .poly => |o| {
                const ids = self.gpa.alloc(usize, o.names.len) catch return;
                for (o.names, 0..) |n, k| ids[k] = self.findPoint(n) orelse {
                    self.gpa.free(ids);
                    return;
                };
                self.addShapeStyled(.{ .polygon = ids }, .{ .color = o.colour, .fill = o.fill }) catch self.gpa.free(ids);
            },
            .angle => |o| {
                const a = self.findPoint(o.a) orelse return;
                const v = self.findPoint(o.v) orelse return;
                const c = self.findPoint(o.c) orelse return;
                self.addShapeStyled(.{ .angle = .{ a, v, c } }, .{ .color = o.colour, .fill = o.fill }) catch {};
            },
            .cross => |o| {
                const a0 = self.findPoint(o.a0) orelse return;
                const a1 = self.findPoint(o.a1) orelse return;
                const b0 = self.findPoint(o.b0) orelse return;
                const b1 = self.findPoint(o.b1) orelse return;
                var hits: [2]?Pt = .{ null, null };
                switch (o.kind) {
                    .circle_circle => hits = geom.circleCircle(self.pt(a0), geom.dist(self.pt(a0), self.pt(a1)), self.pt(b0), geom.dist(self.pt(b0), self.pt(b1))),
                    .line_circle => hits = geom.lineCircle(self.pt(a0), self.pt(a1), self.pt(b0), geom.dist(self.pt(b0), self.pt(b1))),
                    .line_line => hits[0] = geom.intersect(self.pt(a0), self.pt(a1), self.pt(b0), self.pt(b1)),
                }
                const at = hits[o.which] orelse hits[0] orelse return;
                self.addNamed(o.n, at);
            },
        }
    }

    /// Fits the view to everything drawn (points, and the reach of the circles), with a margin.
    pub fn fitToFigure(self: *Scene) void {
        var min_x: f64 = std.math.inf(f64);
        var max_x: f64 = -std.math.inf(f64);
        var min_y: f64 = std.math.inf(f64);
        var max_y: f64 = -std.math.inf(f64);
        for (self.points.items, 0..) |p, i| {
            if (!p.alive) continue;
            const q = self.pt(i);
            min_x = @min(min_x, q.x);
            max_x = @max(max_x, q.x);
            min_y = @min(min_y, q.y);
            max_y = @max(max_y, q.y);
        }
        if (!self.view3d) for (self.shapes.items) |s| if (s == .circle) {
            const c = self.pt(s.circle[0]);
            const r = geom.dist(c, self.pt(s.circle[1]));
            min_x = @min(min_x, c.x - r);
            max_x = @max(max_x, c.x + r);
            min_y = @min(min_y, c.y - r);
            max_y = @max(max_y, c.y + r);
        };
        if (!(min_x <= max_x)) return;
        const sz = self.size();
        if (sz[0] < 50 or sz[1] < 50) {
            self.fit_pending = true;
            return;
        }
        self.fit_pending = false;
        const w = @max(max_x - min_x, 1);
        const h = @max(max_y - min_y, 1);
        self.cx = (min_x + max_x) / 2;
        self.cy = (min_y + max_y) / 2;
        self.scale = std.math.clamp(@min((sz[0] - 40) / w, (sz[1] - 40) / h), 6, 120);
    }

    /// The figure as a one-step lesson file (the text form of figure.zig inside TOML), so it can be opened
    /// again, or found in the Learn view.
    pub fn figureToml(self: *Scene, a: std.mem.Allocator, title: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        const w = &out;
        try w.print(a, "id = \"{s}\"\ncourse = \"My figures\"\nbook = 1\norder = 1\ntitle = \"{s}\"\nstatement = \"A figure you drew.\"\n\n[[step]]\ntext = \"{s}\"\ndraw = [\n  \"clear\",\n", .{ title, title, title });
        if (self.view3d) try w.appendSlice(a, "  \"view3d\",\n");
        var nb: [8]u8 = undefined;
        for (self.points.items, 0..) |p, i| {
            if (!p.alive) continue;
            const name = self.nameOf(&nb, i);
            if (self.view3d or p.z != 0) {
                try w.print(a, "  \"point {s} {d} {d} {d}\",\n", .{ name, p.p.x, p.p.y, p.z });
            } else try w.print(a, "  \"point {s} {d} {d}\",\n", .{ name, p.p.x, p.p.y });
        }
        for (self.shapes.items, 0..) |shape, si| {
            const st = self.styles.items[si];
            const colour = figure.colour_names[@min(st.color, figure.colour_names.len - 1)];
            const fill: []const u8 = if (st.fill) " fill" else "";
            var b1: [8]u8 = undefined;
            var b2: [8]u8 = undefined;
            var b3: [8]u8 = undefined;
            switch (shape) {
                .segment => |e| try w.print(a, "  \"segment {s} {s} {s}\",\n", .{ self.nameOf(&b1, e[0]), self.nameOf(&b2, e[1]), colour }),
                .line => |e| try w.print(a, "  \"line {s} {s} {s}\",\n", .{ self.nameOf(&b1, e[0]), self.nameOf(&b2, e[1]), colour }),
                .circle => |e| try w.print(a, "  \"circle {s} {s} {s}{s}\",\n", .{ self.nameOf(&b1, e[0]), self.nameOf(&b2, e[1]), colour, fill }),
                .angle => |e| try w.print(a, "  \"angle {s} {s} {s} {s}{s}\",\n", .{ self.nameOf(&b1, e[0]), self.nameOf(&b2, e[1]), self.nameOf(&b3, e[2]), colour, fill }),
                .polygon => |ids| {
                    try w.appendSlice(a, "  \"polygon");
                    for (ids) |id| {
                        var b: [8]u8 = undefined;
                        try w.print(a, " {s}", .{self.nameOf(&b, id)});
                    }
                    try w.print(a, " {s}{s}\",\n", .{ colour, fill });
                },
            }
        }
        try w.appendSlice(a, "]\n");
        return out.toOwnedSlice(a);
    }

    pub fn drawText(cr: *cairo.Context, x: f64, y: f64, s: []const u8) void {
        const layout = pangocairo.createLayout(cr);
        defer layout.as(gobject.Object).unref();
        layout.setText(@ptrCast(s.ptr), @intCast(s.len));
        cr.moveTo(x, y);
        pangocairo.showLayout(cr, layout);
    }

    pub fn draw(self: *Scene, cr: *cairo.Context, w: f64, h: f64, fg: [4]f64, overlay: Overlay) void {
        self.width = w;
        self.height = h;
        if (self.fit_pending) self.fitToFigure();
        // The grid and the axes (not in 3D).
        const step = gridStep(self.scale);
        cr.setLineWidth(1);
        cr.setSourceRgba(fg[0], fg[1], fg[2], 0.12);
        const left = self.toWorld(0, 0);
        const right = self.toWorld(w, h);
        var gx = @ceil(left.x / step) * step;
        while (!self.view3d and gx <= right.x) : (gx += step) {
            const px = self.toPx(.{ .x = gx, .y = 0 }).x;
            cr.moveTo(px + 0.5, 0);
            cr.lineTo(px + 0.5, h);
        }
        var gy = @ceil(right.y / step) * step;
        while (!self.view3d and gy <= left.y) : (gy += step) {
            const py = self.toPx(.{ .x = 0, .y = gy }).y;
            cr.moveTo(0, py + 0.5);
            cr.lineTo(w, py + 0.5);
        }
        cr.stroke();
        const origin = self.toPx(.{ .x = 0, .y = 0 });
        if (!self.view3d) {
            cr.setSourceRgba(fg[0], fg[1], fg[2], 0.35);
            cr.moveTo(origin.x + 0.5, 0);
            cr.lineTo(origin.x + 0.5, h);
            cr.moveTo(0, origin.y + 0.5);
            cr.lineTo(w, origin.y + 0.5);
            cr.stroke();
        }

        const blue = palette[0];
        // The shapes.
        cr.setLineWidth(2);
        // In 3D the shapes are drawn far to near, so the near ones cover the far ones.
        const order = self.gpa.alloc(usize, self.shapes.items.len) catch return;
        defer self.gpa.free(order);
        for (order, 0..) |*o, k| o.* = k;
        if (self.view3d) {
            const keys = self.gpa.alloc(f64, order.len) catch return;
            defer self.gpa.free(keys);
            for (keys, 0..) |*k, i| k.* = self.shapeDepth(self.shapes.items[i]);
            const Ctx = struct { keys: []const f64 };
            std.mem.sort(usize, order, Ctx{ .keys = keys }, struct {
                fn less(c: Ctx, a: usize, b: usize) bool {
                    return c.keys[a] > c.keys[b];
                }
            }.less);
        }
        for (order) |si| {
            const s = self.shapes.items[si];
            const st = self.styles.items[si];
            const col = palette[st.color];
            switch (s) {
            .segment => |e| {
                const a = self.toPx(self.pt(e[0]));
                const b = self.toPx(self.pt(e[1]));
                cr.setSourceRgb(col[0], col[1], col[2]);
                cr.moveTo(a.x, a.y);
                cr.lineTo(b.x, b.y);
                cr.stroke();
                if (self.numbers and !self.view3d) {
                    var buf: [32]u8 = undefined;
                    const m = geom.midpoint(a, b);
                    cr.setSourceRgba(fg[0], fg[1], fg[2], 0.85);
                    drawText(cr, m.x + 4, m.y + 2, num(&buf, geom.dist(self.pt(e[0]), self.pt(e[1]))));
                }
            },
            .line => |e| {
                const a = self.toPx(self.pt(e[0]));
                const b = self.toPx(self.pt(e[1]));
                const dx = b.x - a.x;
                const dy = b.y - a.y;
                const len = std.math.hypot(dx, dy);
                if (len > 0) {
                    const far = (w + h) * 2;
                    cr.setSourceRgb(col[0], col[1], col[2]);
                    cr.moveTo(a.x - dx / len * far, a.y - dy / len * far);
                    cr.lineTo(a.x + dx / len * far, a.y + dy / len * far);
                    cr.stroke();
                }
            },
            .circle => |e| {
                const c = self.toPx(self.pt(e[0]));
                const r = geom.dist(self.pt(e[0]), self.pt(e[1])) * self.scale;
                cr.newSubPath();
                cr.arc(c.x, c.y, r, 0, 2 * std.math.pi);
                if (st.fill) {
                    cr.setSourceRgba(col[0], col[1], col[2], 0.3);
                    cr.fillPreserve();
                }
                cr.setSourceRgb(col[0], col[1], col[2]);
                cr.stroke();
                // The radius.
                const p = self.toPx(self.pt(e[1]));
                cr.setSourceRgba(col[0], col[1], col[2], 0.5);
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
                const light = if (self.view3d and ids.len >= 3) self.faceLight(ids) else 0.35;
                cr.setSourceRgba(col[0], col[1], col[2], if (st.fill) light else 0.08);
                cr.fillPreserve();
                cr.setSourceRgb(col[0], col[1], col[2]);
                cr.stroke();
            },
            .angle => |e| {
                const v = self.toPx(self.pt(e[1]));
                const a = self.toPx(self.pt(e[0]));
                const c = self.toPx(self.pt(e[2]));
                cr.setSourceRgb(col[0], col[1], col[2]);
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
                if (st.fill) cr.moveTo(v.x, v.y);
                if (diff >= 0) cr.arc(v.x, v.y, 22, ha, ha + diff) else cr.arcNegative(v.x, v.y, 22, ha, ha + diff);
                if (st.fill) {
                    cr.closePath();
                    cr.setSourceRgba(col[0], col[1], col[2], 0.35);
                    cr.fillPreserve();
                    cr.setSourceRgb(col[0], col[1], col[2]);
                }
                cr.stroke();
                if (self.numbers and !self.view3d) {
                    var buf: [32]u8 = undefined;
                    var lab: [40]u8 = undefined;
                    const label = std.fmt.bufPrint(&lab, "{s}°", .{num(&buf, geom.angleDeg(self.pt(e[0]), self.pt(e[1]), self.pt(e[2])))}) catch "";
                    const mid = ha + diff / 2;
                    drawText(cr, v.x + @cos(mid) * 34 - 10, v.y + @sin(mid) * 34 - 8, label);
                }
                cr.setLineWidth(2);
            },
            }
        }

        // What is being made: the picks so far, with a line to the pointer.
        if (overlay.picks.len > 0) {
            cr.setSourceRgba(blue[0], blue[1], blue[2], 0.5);
            cr.setLineWidth(1.5);
            const dashes = [_]f64{ 4, 3 };
            cr.setDash(&dashes, 2, 0);
            for (overlay.picks, 0..) |id, k| {
                const p = self.toPx(self.pt(id));
                if (k == 0) cr.moveTo(p.x, p.y) else cr.lineTo(p.x, p.y);
            }
            if (overlay.pointer) |m| {
                const p = self.toPx(m);
                cr.lineTo(p.x, p.y);
            }
            cr.stroke();
            cr.setDash(&.{}, 0, 0);
        }

        // The points, with their names.
        for (self.points.items, 0..) |p, i| {
            if (!p.alive) continue;
            if (p.name[0] == '_') continue;
            const q = self.toPx(self.pt(i));
            const picked = std.mem.indexOfScalar(usize, overlay.picks, i) != null;
            cr.newSubPath();
            cr.arc(q.x, q.y, if (picked) 6 else 4.5, 0, 2 * std.math.pi);
            cr.setSourceRgb(if (picked) 0.8 else 0.1, if (picked) 0.3 else 0.1, if (picked) 0.1 else 0.1);
            cr.fill();
            var nb: [8]u8 = undefined;
            cr.setSourceRgba(fg[0], fg[1], fg[2], 0.9);
            drawText(cr, q.x + 6, q.y - 18, self.nameOf(&nb, i));
        }
        // The pointer's coordinates.
        if (overlay.pointer_label) |label| {
            cr.setSourceRgba(fg[0], fg[1], fg[2], 0.55);
            drawText(cr, 6, h - 20, label);
        }
    }
};

test "a figure written out reads back the same" {
    const lessonfile = @import("lessonfile.zig");
    const gpa = std.testing.allocator;
    var scene = Scene.init(gpa);
    defer scene.deinit();
    scene.runOps(&.{
        figure.P("A", 0, 0),
        figure.P("B", 4, 0),
        figure.P("C", 2, 3.5),
        figure.S("A", "B", 1),
        figure.T(&.{ "A", "B", "C" }, 2, true),
        figure.C("A", "B", 0, false),
    });
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const text = try scene.figureToml(arena.allocator(), "test");
    var problems: std.ArrayList([]const u8) = .empty;
    const got = lessonfile.parseLesson(arena.allocator(), text, "test.toml", &problems) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), got.lesson.steps.len);
    var again = Scene.init(gpa);
    defer again.deinit();
    again.runOps(got.lesson.steps[0].ops);
    try std.testing.expectEqual(scene.points.items.len, again.points.items.len);
    try std.testing.expectEqual(scene.shapes.items.len, again.shapes.items.len);
    try std.testing.expectEqual(@as(usize, 0), problems.items.len);
}
