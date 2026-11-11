//! Where the picture is drawn: zoom (to fit, to the window's width, or a
//! fixed level, around the pointer), moving a zoomed picture with the mouse,
//! the keys or a touchpad, pinch to zoom, a backdrop behind transparent
//! pictures, and choosing a rectangle to crop.

const std = @import("std");
const cairo = @import("cairo1");
const gdk = @import("gdk4");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");

const loader = @import("loader.zig");
const pure = @import("pure.zig");

pub const Backdrop = enum {
    checker,
    black,
    white,
    none,

    pub fn parse(text: []const u8) Backdrop {
        return std.meta.stringToEnum(Backdrop, text) orelse .checker;
    }
};

/// What the canvas tells its window.
pub const Hooks = struct {
    owner: *anyopaque,
    /// The zoom or the way it fits changed (for the status bar).
    zoomed: *const fn (*anyopaque) void,
    /// The wheel or a mouse's back/forward button asks for another picture.
    navigate: *const fn (*anyopaque, forward: bool) void,
    /// A right click at (x, y).
    context: *const fn (*anyopaque, x: f64, y: f64) void,
    /// The pointer moved (to show it again in full screen).
    moved: *const fn (*anyopaque) void,
    /// The crop rectangle changed.
    selected: *const fn (*anyopaque) void,
};

pub const Canvas = struct {
    area: *gtk.DrawingArea,
    hooks: Hooks,
    /// Borrowed from the window, which owns it.
    picture: ?*loader.Picture = null,
    /// Drawn instead of the picture's surface: an animation's frame or an
    /// SVG drawn at the current zoom. Owned.
    frame: ?*cairo.Surface = null,

    fit: pure.Fit = .best,
    /// Fitting may enlarge small pictures.
    upscale: bool = false,
    zoom: f64 = 1,
    /// Where the picture's top-left corner is, in the canvas.
    ox: f64 = 0,
    oy: f64 = 0,
    backdrop: Backdrop = .checker,
    /// Full screen and slideshows: a black surround.
    dark: bool = false,
    /// Pixels at least this large (in screen pixels) are drawn as sharp squares.
    smooth_up_to: f64 = 2,

    /// The picture made smaller once, for a zoom below 100% (drawing a large
    /// picture small with a good filter is slow).
    small: ?*cairo.Surface = null,
    small_zoom: f64 = 0,
    small_timer: c_uint = 0,

    // Moving and choosing.
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
    drag_ox: f64 = 0,
    drag_oy: f64 = 0,
    panning: bool = false,
    pinch_zoom: f64 = 1,
    wheel: f64 = 0,
    cropping: bool = false,
    /// The crop rectangle's corners, in picture pixels.
    sel: ?[4]f64 = null,

    pub fn create(gpa: std.mem.Allocator, hooks: Hooks) !*Canvas {
        const self = try gpa.create(Canvas);
        self.* = .{ .area = gtk.DrawingArea.new(), .hooks = hooks };
        const w = self.area.as(gtk.Widget);
        w.setHexpand(1);
        w.setVexpand(1);
        w.setFocusable(1);
        w.addCssClass("dkde-viewer");
        self.area.setDrawFunc(onDraw, self, null);
        _ = gtk.DrawingArea.signals.resize.connect(self.area, *Canvas, &onResize, self, .{});

        const drag = gtk.GestureDrag.new();
        drag.as(gtk.GestureSingle).setButton(1);
        _ = gtk.GestureDrag.signals.drag_begin.connect(drag, *Canvas, &onDragBegin, self, .{});
        _ = gtk.GestureDrag.signals.drag_update.connect(drag, *Canvas, &onDragUpdate, self, .{});
        _ = gtk.GestureDrag.signals.drag_end.connect(drag, *Canvas, &onDragEnd, self, .{});
        w.addController(drag.as(gtk.EventController));

        const click = gtk.GestureClick.new();
        click.as(gtk.GestureSingle).setButton(0);
        _ = gtk.GestureClick.signals.pressed.connect(click, *Canvas, &onPressed, self, .{});
        w.addController(click.as(gtk.EventController));

        const scroll = gtk.EventControllerScroll.new(.{ .vertical = true, .horizontal = true });
        _ = gtk.EventControllerScroll.signals.scroll.connect(scroll, *Canvas, &onScroll, self, .{});
        w.addController(scroll.as(gtk.EventController));

        const pinch = gtk.GestureZoom.new();
        _ = gtk.Gesture.signals.begin.connect(pinch.as(gtk.Gesture), *Canvas, &onPinchBegin, self, .{});
        _ = gtk.GestureZoom.signals.scale_changed.connect(pinch, *Canvas, &onPinch, self, .{});
        w.addController(pinch.as(gtk.EventController));

        const motion = gtk.EventControllerMotion.new();
        _ = gtk.EventControllerMotion.signals.motion.connect(motion, *Canvas, &onMotion, self, .{});
        w.addController(motion.as(gtk.EventController));
        return self;
    }

    /// Frees what the canvas owns (the widget goes with its window).
    pub fn destroy(self: *Canvas, gpa: std.mem.Allocator) void {
        if (self.small_timer != 0) _ = glib.Source.remove(self.small_timer);
        self.dropFrame();
        self.dropSmall();
        gpa.destroy(self);
    }

    pub fn widget(self: *Canvas) *gtk.Widget {
        return self.area.as(gtk.Widget);
    }

    // ---- what is shown ------------------------------------------------------------

    /// Shows `picture` (or nothing), fitted as the window last chose.
    pub fn show(self: *Canvas, picture: ?*loader.Picture, keep_zoom: bool) void {
        self.picture = picture;
        self.dropFrame();
        self.dropSmall();
        self.sel = null;
        if (!keep_zoom and self.fit == .fixed) self.fit = .best;
        self.layout();
        self.redraw();
    }

    /// The picture's pixels changed (an edit): draw them again.
    pub fn changed(self: *Canvas) void {
        self.dropFrame();
        self.dropSmall();
        self.layout();
        self.redraw();
    }

    /// Draws `surface` (owned from now on) in place of the picture.
    pub fn setFrame(self: *Canvas, surface: ?*cairo.Surface) void {
        self.dropFrame();
        self.frame = surface;
        self.dropSmall();
        self.redraw();
    }

    fn dropFrame(self: *Canvas) void {
        if (self.frame) |f| f.destroy();
        self.frame = null;
    }

    fn dropSmall(self: *Canvas) void {
        if (self.small) |s| s.destroy();
        self.small = null;
        self.small_zoom = 0;
    }

    pub fn redraw(self: *Canvas) void {
        self.area.as(gtk.Widget).queueDraw();
    }

    // ---- zoom ---------------------------------------------------------------------

    fn viewSize(self: *Canvas) [2]f64 {
        const w = self.area.as(gtk.Widget);
        return .{ @floatFromInt(@max(1, w.getWidth())), @floatFromInt(@max(1, w.getHeight())) };
    }

    fn imageSize(self: *Canvas) ?[2]f64 {
        const p = self.picture orelse return null;
        return .{ @floatFromInt(p.width), @floatFromInt(p.height) };
    }

    /// Works out the zoom (unless it is fixed) and keeps the picture in view.
    pub fn layout(self: *Canvas) void {
        const img = self.imageSize() orelse return;
        const view = self.viewSize();
        if (self.fit != .fixed) {
            self.zoom = pure.fitZoom(self.fit, img[0], img[1], view[0], view[1], self.upscale);
            self.ox = pure.clampOffset((view[0] - img[0] * self.zoom) / 2, img[0] * self.zoom, view[0]);
            // Fit to width starts at the top.
            self.oy = pure.clampOffset(if (self.fit == .width) 0 else (view[1] - img[1] * self.zoom) / 2, img[1] * self.zoom, view[1]);
        } else {
            self.ox = pure.clampOffset(self.ox, img[0] * self.zoom, view[0]);
            self.oy = pure.clampOffset(self.oy, img[1] * self.zoom, view[1]);
        }
        self.updateCursor();
        self.hooks.zoomed(self.hooks.owner);
    }

    pub fn setFit(self: *Canvas, fit: pure.Fit) void {
        self.fit = fit;
        self.layout();
        self.redraw();
    }

    /// Zooms to `zoom`, keeping the spot at (`ax`, `ay`) of the canvas where it is.
    pub fn zoomAt(self: *Canvas, zoom: f64, ax: f64, ay: f64) void {
        if (self.picture == null) return;
        const z = pure.clampZoom(zoom);
        self.ox = pure.zoomAround(self.ox, ax, self.zoom, z);
        self.oy = pure.zoomAround(self.oy, ay, self.zoom, z);
        self.zoom = z;
        self.fit = .fixed;
        self.layout();
        self.redraw();
    }

    /// Zooms around the middle of the canvas (the keys and menus).
    pub fn zoomCentred(self: *Canvas, zoom: f64) void {
        const view = self.viewSize();
        self.zoomAt(zoom, view[0] / 2, view[1] / 2);
    }

    pub fn step(self: *Canvas, in: bool) void {
        self.zoomCentred(pure.stepZoom(self.zoom, in));
    }

    /// Whether the picture is larger than the canvas (so it can be moved).
    pub fn pannable(self: *Canvas) bool {
        const img = self.imageSize() orelse return false;
        const view = self.viewSize();
        return img[0] * self.zoom > view[0] + 0.5 or img[1] * self.zoom > view[1] + 0.5;
    }

    /// Moves the picture by (dx, dy); false when it is already at that edge.
    pub fn pan(self: *Canvas, dx: f64, dy: f64) bool {
        const img = self.imageSize() orelse return false;
        const view = self.viewSize();
        const x = pure.clampOffset(self.ox + dx, img[0] * self.zoom, view[0]);
        const y = pure.clampOffset(self.oy + dy, img[1] * self.zoom, view[1]);
        if (x == self.ox and y == self.oy) return false;
        self.ox = x;
        self.oy = y;
        self.redraw();
        return true;
    }

    fn updateCursor(self: *Canvas) void {
        const w = self.area.as(gtk.Widget);
        if (self.cropping) return w.setCursorFromName("crosshair");
        if (self.panning) return w.setCursorFromName("grabbing");
        w.setCursorFromName(if (self.pannable()) "grab" else null);
    }

    pub fn hideCursor(self: *Canvas, hide: bool) void {
        if (hide) self.area.as(gtk.Widget).setCursorFromName("none") else self.updateCursor();
    }

    // ---- cropping ----------------------------------------------------------------

    pub fn startCrop(self: *Canvas) void {
        self.cropping = true;
        self.sel = null;
        self.updateCursor();
        self.redraw();
    }

    pub fn endCrop(self: *Canvas) void {
        self.cropping = false;
        self.sel = null;
        self.updateCursor();
        self.redraw();
    }

    /// The chosen rectangle, in picture pixels.
    pub fn selection(self: *Canvas) ?pure.Rect {
        const s = self.sel orelse return null;
        const p = self.picture orelse return null;
        return pure.selection(s[0], s[1], s[2], s[3], p.width, p.height);
    }

    fn toImage(self: *Canvas, x: f64, y: f64) [2]f64 {
        return .{ (x - self.ox) / self.zoom, (y - self.oy) / self.zoom };
    }

    // ---- events ------------------------------------------------------------------

    fn onResize(_: *gtk.DrawingArea, _: c_int, _: c_int, self: *Canvas) callconv(.c) void {
        self.layout();
    }

    fn onDragBegin(_: *gtk.GestureDrag, x: f64, y: f64, self: *Canvas) callconv(.c) void {
        if (self.cropping) {
            const p = self.toImage(x, y);
            self.sel = .{ p[0], p[1], p[0], p[1] };
            return;
        }
        if (!self.pannable()) return;
        self.panning = true;
        self.drag_ox = self.ox;
        self.drag_oy = self.oy;
        self.updateCursor();
    }

    fn onDragUpdate(drag: *gtk.GestureDrag, dx: f64, dy: f64, self: *Canvas) callconv(.c) void {
        if (self.cropping) {
            var sx: f64 = 0;
            var sy: f64 = 0;
            _ = drag.getStartPoint(&sx, &sy);
            const p = self.toImage(sx + dx, sy + dy);
            if (self.sel) |*s| {
                s[2] = p[0];
                s[3] = p[1];
            }
            self.redraw();
            self.hooks.selected(self.hooks.owner);
            return;
        }
        if (!self.panning) return;
        const img = self.imageSize() orelse return;
        const view = self.viewSize();
        self.ox = pure.clampOffset(self.drag_ox + dx, img[0] * self.zoom, view[0]);
        self.oy = pure.clampOffset(self.drag_oy + dy, img[1] * self.zoom, view[1]);
        self.redraw();
    }

    fn onDragEnd(_: *gtk.GestureDrag, _: f64, _: f64, self: *Canvas) callconv(.c) void {
        self.panning = false;
        self.updateCursor();
    }

    fn onPressed(click: *gtk.GestureClick, n: c_int, x: f64, y: f64, self: *Canvas) callconv(.c) void {
        _ = self.area.as(gtk.Widget).grabFocus();
        switch (click.as(gtk.GestureSingle).getCurrentButton()) {
            1 => if (n == 2 and !self.cropping and self.picture != null) {
                // Double click: between fitting and 100% (200% for a picture
                // that already fits at 100%), at the pointer, as in Loupe.
                if (self.fit != .fixed) {
                    self.zoomAt(if (self.zoom >= 0.999) 2 else 1, x, y);
                } else self.setFit(.best);
            },
            3 => self.hooks.context(self.hooks.owner, x, y),
            8 => self.hooks.navigate(self.hooks.owner, false),
            9 => self.hooks.navigate(self.hooks.owner, true),
            else => {},
        }
    }

    fn onScroll(ctrl: *gtk.EventControllerScroll, dx_in: f64, dy_in: f64, self: *Canvas) callconv(.c) c_int {
        if (self.picture == null) return 0;
        const state = ctrl.as(gtk.EventController).getCurrentEventState();
        const smooth = ctrl.getUnit() == .surface;
        if (state.control_mask) {
            const factor = if (smooth) @exp(-dy_in * 0.01) else (if (dy_in < 0) pure.stepZoom(self.zoom, true) / self.zoom else pure.stepZoom(self.zoom, false) / self.zoom);
            self.zoomAt(self.zoom * factor, self.pointer_x, self.pointer_y);
            return 1;
        }
        var dx = dx_in;
        var dy = dy_in;
        if (state.shift_mask and dx == 0) {
            dx = dy;
            dy = 0;
        }
        if (self.pannable()) {
            const k: f64 = if (smooth) 1 else 60;
            _ = self.pan(-dx * k, -dy * k);
            return 1;
        }
        // The whole picture shows: the wheel goes through the folder.
        self.wheel += if (dy != 0) dy else dx;
        const threshold: f64 = if (smooth) 40 else 1;
        if (@abs(self.wheel) >= threshold) {
            const forward = self.wheel > 0;
            self.wheel = 0;
            self.hooks.navigate(self.hooks.owner, forward);
        }
        return 1;
    }

    fn onPinchBegin(_: *gtk.Gesture, _: ?*gdk.EventSequence, self: *Canvas) callconv(.c) void {
        self.pinch_zoom = self.zoom;
    }

    fn onPinch(gesture: *gtk.GestureZoom, scale: f64, self: *Canvas) callconv(.c) void {
        var cx: f64 = 0;
        var cy: f64 = 0;
        if (gesture.as(gtk.Gesture).getBoundingBoxCenter(&cx, &cy) == 0) {
            cx = self.pointer_x;
            cy = self.pointer_y;
        }
        self.zoomAt(self.pinch_zoom * scale, cx, cy);
    }

    fn onMotion(_: *gtk.EventControllerMotion, x: f64, y: f64, self: *Canvas) callconv(.c) void {
        if (@abs(x - self.pointer_x) < 0.5 and @abs(y - self.pointer_y) < 0.5) return;
        self.pointer_x = x;
        self.pointer_y = y;
        self.hooks.moved(self.hooks.owner);
    }

    // ---- drawing -------------------------------------------------------------------

    fn onDraw(_: *gtk.DrawingArea, cr: *cairo.Context, width: c_int, height: c_int, data: ?*anyopaque) callconv(.c) void {
        const self: *Canvas = @ptrCast(@alignCast(data.?));
        const vw: f64 = @floatFromInt(width);
        const vh: f64 = @floatFromInt(height);
        if (self.dark) {
            cr.setSourceRgb(0, 0, 0);
            cr.paint();
        }
        const p = self.picture orelse return;
        const iw = @as(f64, @floatFromInt(p.width)) * self.zoom;
        const ih = @as(f64, @floatFromInt(p.height)) * self.zoom;

        if (p.has_alpha) self.drawBackdrop(cr, vw, vh, iw, ih);

        const surface = self.frame orelse p.surface;
        const sw: f64 = @floatFromInt(surface.imageGetWidth());
        const sh: f64 = @floatFromInt(surface.imageGetHeight());
        // Surface pixels to canvas pixels.
        const k = iw / sw;
        const scale: f64 = @floatFromInt(self.area.as(gtk.Widget).getScaleFactor());

        cr.save();
        // Only the part of the picture inside the canvas.
        cr.rectangle(@max(0, self.ox), @max(0, self.oy), @min(vw, self.ox + iw) - @max(0, self.ox), @min(vh, self.oy + ih) - @max(0, self.oy));
        cr.clip();
        if (k < 0.999 and self.small != null and self.small_zoom == self.zoom) {
            cr.setSourceSurface(self.small.?, @round(self.ox), @round(self.oy));
            cr.paint();
        } else {
            cr.translate(self.ox, self.oy);
            cr.scale(k, k);
            cr.setSourceSurface(surface, 0, 0);
            const filter: cairo.Filter = if (k * scale >= self.smooth_up_to) .nearest else if (k < 0.999) .bilinear else .good;
            cr.getSource().setFilter(filter);
            cr.rectangle(0, 0, sw, sh);
            cr.fill();
            // A smaller copy drawn with a good filter replaces this soon.
            if (k < 0.999) self.scheduleSmall();
        }
        cr.restore();

        if (self.cropping) self.drawSelection(cr, vw, vh);
    }

    fn drawBackdrop(self: *Canvas, cr: *cairo.Context, vw: f64, vh: f64, iw: f64, ih: f64) void {
        const x0 = @max(0, self.ox);
        const y0 = @max(0, self.oy);
        const x1 = @min(vw, self.ox + iw);
        const y1 = @min(vh, self.oy + ih);
        if (x1 <= x0 or y1 <= y0) return;
        switch (self.backdrop) {
            .none => {},
            .black, .white => {
                const v: f64 = if (self.backdrop == .white) 1 else 0;
                cr.setSourceRgb(v, v, v);
                cr.rectangle(x0, y0, x1 - x0, y1 - y0);
                cr.fill();
            },
            .checker => {
                const size: f64 = 8;
                cr.save();
                cr.rectangle(x0, y0, x1 - x0, y1 - y0);
                cr.clip();
                cr.setSourceRgb(0.8, 0.8, 0.8);
                cr.paint();
                cr.setSourceRgb(0.6, 0.6, 0.6);
                var y = @floor((y0 - self.oy) / size) * size + self.oy;
                while (y < y1) : (y += size) {
                    var x = @floor((x0 - self.ox) / size) * size + self.ox;
                    while (x < x1) : (x += size) {
                        const row: i64 = @intFromFloat(@round((y - self.oy) / size));
                        const col: i64 = @intFromFloat(@round((x - self.ox) / size));
                        if (@mod(row + col, 2) == 0) cr.rectangle(x, y, size, size);
                    }
                }
                cr.fill();
                cr.restore();
            },
        }
    }

    fn drawSelection(self: *Canvas, cr: *cairo.Context, vw: f64, vh: f64) void {
        const r = self.selection() orelse return;
        const x = self.ox + @as(f64, @floatFromInt(r.x)) * self.zoom;
        const y = self.oy + @as(f64, @floatFromInt(r.y)) * self.zoom;
        const w = @as(f64, @floatFromInt(r.w)) * self.zoom;
        const h = @as(f64, @floatFromInt(r.h)) * self.zoom;
        // Darken what will be cut away.
        cr.setFillRule(.even_odd);
        cr.rectangle(0, 0, vw, vh);
        cr.rectangle(x, y, w, h);
        cr.setSourceRgba(0, 0, 0, 0.5);
        cr.fill();
        cr.setFillRule(.winding);
        cr.setLineWidth(1);
        cr.setSourceRgb(1, 1, 1);
        cr.rectangle(@round(x) + 0.5, @round(y) + 0.5, @round(w) - 1, @round(h) - 1);
        cr.stroke();
        // Thirds, to help with composition.
        cr.setSourceRgba(1, 1, 1, 0.4);
        for (1..3) |i| {
            const f: f64 = @floatFromInt(i);
            cr.moveTo(x + w * f / 3, y);
            cr.lineTo(x + w * f / 3, y + h);
            cr.moveTo(x, y + h * f / 3);
            cr.lineTo(x + w, y + h * f / 3);
        }
        cr.stroke();
    }

    fn scheduleSmall(self: *Canvas) void {
        if (self.small_timer != 0) return;
        self.small_timer = glib.timeoutAdd(120, makeSmall, self);
    }

    fn makeSmall(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Canvas = @ptrCast(@alignCast(data.?));
        self.small_timer = 0;
        const p = self.picture orelse return 0;
        const surface = self.frame orelse p.surface;
        // An animation changes too often to be worth it.
        if (p.animation != null) return 0;
        const scale: f64 = @floatFromInt(self.area.as(gtk.Widget).getScaleFactor());
        const iw = @as(f64, @floatFromInt(p.width)) * self.zoom;
        const ih = @as(f64, @floatFromInt(p.height)) * self.zoom;
        const dw: c_int = @intFromFloat(@ceil(iw * scale));
        const dh: c_int = @intFromFloat(@ceil(ih * scale));
        if (dw < 1 or dh < 1 or @as(i64, dw) * dh > 40_000_000) return 0;
        const small = cairo.Surface.imageCreate(.argb32, dw, dh);
        if (small.status() != .success) {
            small.destroy();
            return 0;
        }
        const cr = cairo.Context.create(small);
        const k = @as(f64, @floatFromInt(dw)) / @as(f64, @floatFromInt(surface.imageGetWidth()));
        cr.scale(k, k);
        cr.setSourceSurface(surface, 0, 0);
        cr.getSource().setFilter(.good);
        cr.paint();
        cr.destroy();
        small.setDeviceScale(scale, scale);
        self.dropSmall();
        self.small = small;
        self.small_zoom = self.zoom;
        self.redraw();
        return 0;
    }
};
