//! The screenshot editor (SPEC.md 5.6): a full-screen overlay on the frozen
//! screen, in the manner of Flameshot. Drag to choose an area, resize or move
//! it by its handles, draw on it with the tools of the toolbar that floats by
//! it, then copy, save or capture the area as a scrolling picture.
//!
//! Wheel: thickness. Keys: Enter or Ctrl+C copy, Ctrl+S save, Esc cancel,
//! Ctrl+Z undo, Ctrl+Shift+Z or Ctrl+Y redo, Ctrl+A the whole screen, arrows
//! nudge the area (with Shift they resize it), [ and ] change the thickness.
//!
//! Everything is kept in image pixels (annot.zig); the window may be a
//! different size and the drawing scales.

const std = @import("std");
const cairo = @import("cairo1");
const gdk = @import("gdk4");
const gdkpixbuf = @import("gdkpixbuf2");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

const annot = @import("annot.zig");

const log = std.log.scoped(.editor);

/// What the editor tells the program that opened it. It is closed after any
/// of these.
pub const Host = struct {
    ctx: *anyopaque,
    copy: *const fn (*anyopaque, *gdk.Texture) void,
    save: *const fn (*anyopaque, *gdk.Texture) void,
    /// A scrolling capture of this area of an image `w` by `h` pixels.
    scroll: *const fn (*anyopaque, annot.RectI, i32, i32) void,
    cancel: *const fn (*anyopaque) void,
};

const Annotation = struct {
    shape: annot.Shape,
    /// The mosaic of a pixelated box, made when the box is finished.
    patch: ?*gdkpixbuf.Pixbuf = null,

    fn deinit(self: *Annotation, allocator: std.mem.Allocator) void {
        if (self.shape.points.len > 0) allocator.free(self.shape.points);
        if (self.shape.text.len > 0) allocator.free(self.shape.text);
        if (self.patch) |p| p.as(gobject.Object).unref();
    }
};

const Drag = union(enum) {
    none,
    new_selection: annot.Point,
    handle: struct { which: annot.Handle, orig: annot.RectF, start: annot.Point },
    draw,
};

const ToolInfo = struct { tool: annot.Tool, glyph: [:0]const u8, tip: [:0]const u8 };
const tool_list = [_]ToolInfo{
    .{ .tool = .select, .glyph = "\u{2725}", .tip = "Select and move the area" },
    .{ .tool = .pen, .glyph = "\u{270E}", .tip = "Pen" },
    .{ .tool = .line, .glyph = "\u{2571}", .tip = "Line" },
    .{ .tool = .arrow, .glyph = "\u{279A}", .tip = "Arrow" },
    .{ .tool = .rect, .glyph = "\u{25AD}", .tip = "Rectangle" },
    .{ .tool = .ellipse, .glyph = "\u{25EF}", .tip = "Ellipse" },
    .{ .tool = .marker, .glyph = "\u{25AC}", .tip = "Highlighter" },
    .{ .tool = .pixelate, .glyph = "\u{25A6}", .tip = "Pixelate" },
    .{ .tool = .text, .glyph = "T", .tip = "Text" },
    .{ .tool = .counter, .glyph = "\u{2460}", .tip = "Numbered marker" },
};

const Action = enum { undo, redo, scroll, save, copy, close };

pub const Editor = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    host: Host,
    pixbuf: *gdkpixbuf.Pixbuf,
    window: *gtk.Window,
    area: *gtk.DrawingArea,
    bar: *gtk.Box,
    colors: *gtk.DrawingArea,
    hint: *gtk.Label,
    entry: *gtk.Entry,
    undo_button: *gtk.Button,
    redo_button: *gtk.Button,

    sel: ?annot.RectF = null,
    tool: annot.Tool = .select,
    color: u32 = annot.palette[0],
    width: f64 = annot.default_width,
    shapes: std.ArrayList(Annotation) = .empty,
    redo: std.ArrayList(Annotation) = .empty,
    current: ?Annotation = null,
    drag: Drag = .none,
    drag_start: annot.Point = .{ .x = 0, .y = 0 },
    cursor_name: [:0]const u8 = "crosshair",
    text_at: annot.Point = .{ .x = 0, .y = 0 },
    closed: bool = false,

    // ---- opening and closing ------------------------------------------------------

    /// Takes ownership of `pixbuf`, the frozen screen.
    /// `area` is the selection to start with (`--area`), if any.
    pub fn show(allocator: std.mem.Allocator, host: Host, pixbuf: *gdkpixbuf.Pixbuf, area: ?annot.RectF) !*Editor {
        const self = try allocator.create(Editor);
        errdefer allocator.destroy(self);
        const overlay = gtk.Overlay.new();
        self.* = .{
            .allocator = allocator,
            .arena = .init(allocator),
            .host = host,
            .pixbuf = pixbuf,
            .window = gtk.Window.new(),
            .area = gtk.DrawingArea.new(),
            .bar = gtk.Box.new(.horizontal, 2),
            .colors = gtk.DrawingArea.new(),
            .hint = gtk.Label.new(common.tr("Drag to choose an area. Ctrl+A takes the whole screen, Esc cancels.")),
            .entry = gtk.Entry.new(),
            .undo_button = undefined,
            .redo_button = undefined,
        };

        self.window.setTitle(common.tr("Screenshot"));
        self.window.setDecorated(0);
        self.window.as(gtk.Widget).addCssClass("dkde");
        overlay.setChild(self.area.as(gtk.Widget));
        self.window.setChild(overlay.as(gtk.Widget));
        self.area.setDrawFunc(onDraw, self, null);
        self.area.as(gtk.Widget).setCursorFromName("crosshair");

        self.buildBar();
        overlay.addOverlay(self.bar.as(gtk.Widget));
        self.bar.as(gtk.Widget).setHalign(.start);
        self.bar.as(gtk.Widget).setValign(.start);
        self.bar.as(gtk.Widget).setVisible(0);

        self.hint.as(gtk.Widget).addCssClass("dkde-snip-hint");
        self.hint.as(gtk.Widget).setHalign(.center);
        self.hint.as(gtk.Widget).setValign(.start);
        self.hint.as(gtk.Widget).setMarginTop(24);
        self.hint.as(gtk.Widget).setCanTarget(0);
        overlay.addOverlay(self.hint.as(gtk.Widget));

        self.entry.as(gtk.Widget).addCssClass("dkde-snip-text");
        self.entry.as(gtk.Widget).setHalign(.start);
        self.entry.as(gtk.Widget).setValign(.start);
        self.entry.as(gtk.Widget).setVisible(0);
        self.entry.as(gtk.Widget).setSizeRequest(220, -1);
        overlay.addOverlay(self.entry.as(gtk.Widget));
        _ = gtk.Entry.signals.activate.connect(self.entry, *Editor, &onEntryActivate, self, .{});

        const drag = gtk.GestureDrag.new();
        drag.as(gtk.GestureSingle).setButton(1);
        _ = gtk.GestureDrag.signals.drag_begin.connect(drag, *Editor, &onBegin, self, .{});
        _ = gtk.GestureDrag.signals.drag_update.connect(drag, *Editor, &onUpdate, self, .{});
        _ = gtk.GestureDrag.signals.drag_end.connect(drag, *Editor, &onEnd, self, .{});
        self.area.as(gtk.Widget).addController(drag.as(gtk.EventController));

        const motion = gtk.EventControllerMotion.new();
        _ = gtk.EventControllerMotion.signals.motion.connect(motion, *Editor, &onMotion, self, .{});
        self.area.as(gtk.Widget).addController(motion.as(gtk.EventController));

        const wheel = gtk.EventControllerScroll.new(.{ .vertical = true });
        _ = gtk.EventControllerScroll.signals.scroll.connect(wheel, *Editor, &onWheel, self, .{});
        self.area.as(gtk.Widget).addController(wheel.as(gtk.EventController));

        const keys = gtk.EventControllerKey.new();
        keys.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *Editor, &onKey, self, .{});
        self.window.as(gtk.Widget).addController(keys.as(gtk.EventController));

        self.sel = area;
        self.window.fullscreen();
        self.window.present();
        // The toolbar needs the window's size, which it has once it is shown.
        if (area != null) _ = glib.idleAdd(onShownIdle, self);
        return self;
    }

    fn onShownIdle(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Editor = @ptrCast(@alignCast(data.?));
        if (self.closed) return 0;
        // Still no size: look again shortly.
        if (self.area.as(gtk.Widget).getWidth() < 2) return 1;
        self.placeBar();
        self.area.as(gtk.Widget).queueDraw();
        return 0;
    }

    /// Closes the window and frees everything. Safe to call once.
    fn destroy(self: *Editor) void {
        if (self.closed) return;
        self.closed = true;
        self.window.destroy();
        for (self.shapes.items) |*s| s.deinit(self.allocator);
        for (self.redo.items) |*s| s.deinit(self.allocator);
        if (self.current) |*c| c.deinit(self.allocator);
        self.shapes.deinit(self.allocator);
        self.redo.deinit(self.allocator);
        self.pixbuf.as(gobject.Object).unref();
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    // ---- the toolbar ---------------------------------------------------------------------

    const ToolCtx = struct { editor: *Editor, tool: annot.Tool };
    const ActionCtx = struct { editor: *Editor, action: Action };

    fn buildBar(self: *Editor) void {
        const a = self.arena.allocator();
        self.bar.as(gtk.Widget).addCssClass("dkde-snip-bar");

        var first: ?*gtk.ToggleButton = null;
        for (tool_list) |t| {
            const b = gtk.ToggleButton.new();
            b.as(gtk.Button).setLabel(t.glyph);
            b.as(gtk.Widget).setTooltipText(t.tip);
            if (first) |f| b.setGroup(f) else first = b;
            if (t.tool == .select) b.setActive(1);
            const ctx = a.create(ToolCtx) catch continue;
            ctx.* = .{ .editor = self, .tool = t.tool };
            _ = gtk.ToggleButton.signals.toggled.connect(b, *ToolCtx, &onTool, ctx, .{});
            self.bar.append(b.as(gtk.Widget));
        }

        self.bar.append(gtk.Separator.new(.vertical).as(gtk.Widget));
        // The colours and the thickness.
        self.colors.as(gtk.Widget).setSizeRequest(annot.palette.len * 22 + 52, 28);
        self.colors.setDrawFunc(onDrawColors, self, null);
        const click = gtk.GestureClick.new();
        _ = gtk.GestureClick.signals.pressed.connect(click, *Editor, &onColorClick, self, .{});
        self.colors.as(gtk.Widget).addController(click.as(gtk.EventController));
        self.colors.as(gtk.Widget).setTooltipText(common.tr("Colour. The mouse wheel changes the thickness."));
        self.bar.append(self.colors.as(gtk.Widget));
        self.bar.append(gtk.Separator.new(.vertical).as(gtk.Widget));

        self.undo_button = self.actionButton("edit-undo-symbolic", null, "Undo (Ctrl+Z)", .undo);
        self.redo_button = self.actionButton("edit-redo-symbolic", null, "Redo (Ctrl+Shift+Z)", .redo);
        self.undo_button.as(gtk.Widget).setSensitive(0);
        self.redo_button.as(gtk.Widget).setSensitive(0);
        self.bar.append(gtk.Separator.new(.vertical).as(gtk.Widget));
        _ = self.actionButton(null, "\u{21F5}", "Scrolling capture: scrolls the window under the area and joins the pictures", .scroll);
        _ = self.actionButton("document-save-symbolic", null, "Save (Ctrl+S)", .save);
        _ = self.actionButton("edit-copy-symbolic", null, "Copy (Enter)", .copy);
        _ = self.actionButton("window-close-symbolic", null, "Cancel (Esc)", .close);
    }

    fn actionButton(self: *Editor, icon: ?[:0]const u8, glyph: ?[:0]const u8, tip: [:0]const u8, action: Action) *gtk.Button {
        const b = if (icon) |i| gtk.Button.newFromIconName(i) else gtk.Button.newWithLabel(glyph.?);
        b.as(gtk.Widget).setTooltipText(tip);
        const ctx = self.arena.allocator().create(ActionCtx) catch return b;
        ctx.* = .{ .editor = self, .action = action };
        _ = gtk.Button.signals.clicked.connect(b, *ActionCtx, &onAction, ctx, .{});
        self.bar.append(b.as(gtk.Widget));
        return b;
    }

    fn onTool(button: *gtk.ToggleButton, ctx: *ToolCtx) callconv(.c) void {
        if (button.getActive() == 0) return;
        ctx.editor.commitText();
        ctx.editor.tool = ctx.tool;
        ctx.editor.updateCursor(.none);
    }

    fn onAction(_: *gtk.Button, ctx: *ActionCtx) callconv(.c) void {
        ctx.editor.run(ctx.action);
    }

    fn run(self: *Editor, action: Action) void {
        switch (action) {
            .undo => self.undo(),
            .redo => self.redoLast(),
            .copy => self.finish(.copy),
            .save => self.finish(.save),
            .scroll => self.finish(.scroll),
            .close => self.finish(.cancel),
        }
    }

    /// Puts the toolbar by the selection.
    fn placeBar(self: *Editor) void {
        const sel = self.sel orelse return self.bar.as(gtk.Widget).setVisible(0);
        const widget = self.area.as(gtk.Widget);
        const ww: f64 = @floatFromInt(widget.getWidth());
        const wh: f64 = @floatFromInt(widget.getHeight());
        if (ww < 1 or wh < 1) return;
        const bar = self.bar.as(gtk.Widget);
        // A hidden widget measures as nothing: show it, then ask its size. The
        // margins that put it in place count in that size, so clear them first.
        bar.setVisible(1);
        bar.setMarginStart(0);
        bar.setMarginTop(0);
        var nat: gtk.Requisition = undefined;
        bar.getPreferredSize(null, &nat);
        const k = self.imageToWidget();
        const sel_w: annot.RectF = .{ .x = sel.x * k.x, .y = sel.y * k.y, .w = sel.w * k.x, .h = sel.h * k.y };
        const pos = annot.barPosition(sel_w, @floatFromInt(nat.f_width), @floatFromInt(nat.f_height), ww, wh);
        bar.setMarginStart(@intFromFloat(pos.x));
        bar.setMarginTop(@intFromFloat(pos.y));
        bar.setVisible(1);
        self.hint.as(gtk.Widget).setVisible(0);
    }

    fn updateUndoButtons(self: *Editor) void {
        self.undo_button.as(gtk.Widget).setSensitive(@intFromBool(self.shapes.items.len > 0));
        self.redo_button.as(gtk.Widget).setSensitive(@intFromBool(self.redo.items.len > 0));
    }

    // ---- coordinates ------------------------------------------------------------------------

    fn imageSize(self: *Editor) annot.Point {
        return .{ .x = @floatFromInt(self.pixbuf.getWidth()), .y = @floatFromInt(self.pixbuf.getHeight()) };
    }

    /// Widget pixels per image pixel.
    fn imageToWidget(self: *Editor) annot.Point {
        const widget = self.area.as(gtk.Widget);
        const img = self.imageSize();
        return .{
            .x = @as(f64, @floatFromInt(@max(1, widget.getWidth()))) / img.x,
            .y = @as(f64, @floatFromInt(@max(1, widget.getHeight()))) / img.y,
        };
    }

    fn toImage(self: *Editor, x: f64, y: f64) annot.Point {
        const k = self.imageToWidget();
        const img = self.imageSize();
        return .{ .x = std.math.clamp(x / k.x, 0, img.x), .y = std.math.clamp(y / k.y, 0, img.y) };
    }

    /// The reach of a handle, in image pixels (about 9 on the screen).
    fn tolerance(self: *Editor) f64 {
        return 9 / self.imageToWidget().x;
    }

    fn clampToSelection(self: *Editor, p: annot.Point) annot.Point {
        const s = self.sel orelse return p;
        return .{ .x = std.math.clamp(p.x, s.x, s.x + s.w), .y = std.math.clamp(p.y, s.y, s.y + s.h) };
    }

    // ---- the mouse ----------------------------------------------------------------------------

    fn updateCursor(self: *Editor, h: annot.Handle) void {
        const name: [:0]const u8 = switch (h) {
            .inside => if (self.tool == .select) "move" else if (self.tool == .text) "text" else "crosshair",
            .none => "crosshair",
            else => annot.cursorFor(h),
        };
        if (std.mem.eql(u8, name, self.cursor_name)) return;
        self.cursor_name = name;
        self.area.as(gtk.Widget).setCursorFromName(name);
    }

    fn idle(self: *Editor) bool {
        return switch (self.drag) {
            .none => true,
            else => false,
        };
    }

    fn drawing(self: *Editor) bool {
        return switch (self.drag) {
            .draw => true,
            else => false,
        };
    }

    fn onMotion(_: *gtk.EventControllerMotion, x: f64, y: f64, self: *Editor) callconv(.c) void {
        if (!self.idle()) return;
        const sel = self.sel orelse return self.updateCursor(.none);
        const p = self.toImage(x, y);
        self.updateCursor(annot.hit(sel, p.x, p.y, self.tolerance()));
    }

    fn onBegin(_: *gtk.GestureDrag, x: f64, y: f64, self: *Editor) callconv(.c) void {
        self.commitText();
        self.drag_start = .{ .x = x, .y = y };
        const p = self.toImage(x, y);
        const sel = self.sel orelse {
            self.drag = .{ .new_selection = p };
            self.sel = .{ .x = p.x, .y = p.y, .w = 0, .h = 0 };
            return;
        };
        const h = annot.hit(sel, p.x, p.y, self.tolerance());
        switch (h) {
            .none => {
                // Outside the area with the pointer tool: a new area.
                if (self.tool == .select) {
                    self.drag = .{ .new_selection = p };
                    self.sel = .{ .x = p.x, .y = p.y, .w = 0, .h = 0 };
                    self.bar.as(gtk.Widget).setVisible(0);
                }
            },
            .inside => {
                if (self.tool == .select) {
                    self.drag = .{ .handle = .{ .which = .inside, .orig = sel, .start = p } };
                } else self.startShape(p);
            },
            else => self.drag = .{ .handle = .{ .which = h, .orig = sel, .start = p } },
        }
    }

    fn onUpdate(_: *gtk.GestureDrag, dx: f64, dy: f64, self: *Editor) callconv(.c) void {
        const p = self.toImage(self.drag_start.x + dx, self.drag_start.y + dy);
        const img = self.imageSize();
        switch (self.drag) {
            .none => return,
            .new_selection => |from| self.sel = annot.clampRect(annot.normalizeF(from.x, from.y, p.x, p.y), img.x, img.y),
            .handle => |h| self.sel = annot.dragSelection(h.orig, h.which, p.x - h.start.x, p.y - h.start.y, img.x, img.y),
            .draw => self.extendShape(self.clampToSelection(p)),
        }
        if (!self.drawing()) self.placeBar();
        self.area.as(gtk.Widget).queueDraw();
    }

    fn onEnd(_: *gtk.GestureDrag, dx: f64, dy: f64, self: *Editor) callconv(.c) void {
        const p = self.toImage(self.drag_start.x + dx, self.drag_start.y + dy);
        defer {
            self.drag = .none;
            self.area.as(gtk.Widget).queueDraw();
        }
        switch (self.drag) {
            .none, .handle => {},
            .new_selection => {
                const s = self.sel orelse return;
                // A click, or a sliver: no area yet.
                if (s.w < 6 or s.h < 6) {
                    self.sel = null;
                    self.bar.as(gtk.Widget).setVisible(0);
                    return;
                }
                self.placeBar();
            },
            .draw => {
                self.extendShape(self.clampToSelection(p));
                self.commitShape();
            },
        }
        if (self.sel != null) self.placeBar();
    }

    fn onWheel(_: *gtk.EventControllerScroll, _: f64, dy: f64, self: *Editor) callconv(.c) c_int {
        self.width = annot.stepWidth(self.width, dy);
        self.colors.as(gtk.Widget).queueDraw();
        return 1;
    }

    // ---- drawing a shape ----------------------------------------------------------------------

    fn startShape(self: *Editor, p: annot.Point) void {
        const base: annot.Shape = .{ .tool = self.tool, .color = self.color, .width = self.width, .a = p, .b = p };
        switch (self.tool) {
            .select => {},
            .pen, .marker => {
                const pts = self.allocator.alloc(annot.Point, 1) catch return;
                pts[0] = p;
                var s = base;
                s.points = pts;
                self.current = .{ .shape = s };
                self.drag = .draw;
            },
            .line, .arrow, .rect, .ellipse, .pixelate => {
                self.current = .{ .shape = base };
                self.drag = .draw;
            },
            .text => self.showEntry(p),
            .counter => {
                var s = base;
                s.number = self.nextNumber();
                self.push(.{ .shape = s });
            },
        }
    }

    /// One more than the highest counter so far, so undoing one frees its number.
    fn nextNumber(self: *Editor) u32 {
        var n: u32 = 0;
        for (self.shapes.items) |it| {
            if (it.shape.tool == .counter and it.shape.number > n) n = it.shape.number;
        }
        return n + 1;
    }

    fn extendShape(self: *Editor, p: annot.Point) void {
        var cur = self.current orelse return;
        switch (cur.shape.tool) {
            .pen, .marker => {
                const n = cur.shape.points.len;
                // Skip points that did not move: long drags stay small.
                const last = cur.shape.points[n - 1];
                if (@abs(last.x - p.x) < 0.5 and @abs(last.y - p.y) < 0.5) return;
                const grown = self.allocator.realloc(cur.shape.points, n + 1) catch return;
                grown[n] = p;
                cur.shape.points = grown;
            },
            else => cur.shape.b = p,
        }
        self.current = cur;
    }

    fn commitShape(self: *Editor) void {
        var cur = self.current orelse return;
        self.current = null;
        const s = cur.shape;
        // A click without a drag draws nothing, except a dot of the pen.
        const moved = @abs(s.a.x - s.b.x) >= 2 or @abs(s.a.y - s.b.y) >= 2;
        const flat = (s.tool == .line or s.tool == .arrow or s.tool == .rect or s.tool == .ellipse or s.tool == .pixelate) and !moved;
        if (flat) return cur.deinit(self.allocator);
        if (s.tool == .pixelate) {
            cur.patch = self.makePatch(annot.normalizeF(s.a.x, s.a.y, s.b.x, s.b.y), s.width);
            if (cur.patch == null) return cur.deinit(self.allocator);
        }
        self.push(cur);
    }

    fn push(self: *Editor, item: Annotation) void {
        self.shapes.append(self.allocator, item) catch {
            var it = item;
            it.deinit(self.allocator);
            return;
        };
        // Drawing after an undo drops what could have been redone.
        for (self.redo.items) |*r| r.deinit(self.allocator);
        self.redo.clearRetainingCapacity();
        self.updateUndoButtons();
        self.area.as(gtk.Widget).queueDraw();
    }

    fn undo(self: *Editor) void {
        const last = self.shapes.pop() orelse return;
        self.redo.append(self.allocator, last) catch {
            var l = last;
            l.deinit(self.allocator);
        };
        self.updateUndoButtons();
        self.area.as(gtk.Widget).queueDraw();
    }

    fn redoLast(self: *Editor) void {
        const item = self.redo.pop() orelse return;
        self.shapes.append(self.allocator, item) catch {
            var l = item;
            l.deinit(self.allocator);
        };
        self.updateUndoButtons();
        self.area.as(gtk.Widget).queueDraw();
    }

    /// The mosaic of `rect` of the frozen screen.
    fn makePatch(self: *Editor, rect: annot.RectF, width: f64) ?*gdkpixbuf.Pixbuf {
        const r = annot.toRectI(annot.clampRect(rect, self.imageSize().x, self.imageSize().y));
        if (r.w < 1 or r.h < 1) return null;
        const sub = self.pixbuf.newSubpixbuf(r.x, r.y, r.w, r.h);
        defer sub.as(gobject.Object).unref();
        // The subpixbuf shares memory with the screen; the mosaic is its own copy.
        const copy = sub.copy() orelse return null;
        const stride: usize = @intCast(copy.getRowstride());
        const pixels = copy.getPixels()[0 .. stride * @as(usize, @intCast(r.h))];
        annot.pixelate(pixels, stride, @intCast(copy.getNChannels()), r.w, r.h, .{ .x = 0, .y = 0, .w = r.w, .h = r.h }, annot.pixelBlock(width));
        return copy;
    }

    // ---- text ------------------------------------------------------------------------------------

    fn showEntry(self: *Editor, p: annot.Point) void {
        self.text_at = p;
        const k = self.imageToWidget();
        const entry = self.entry.as(gtk.Widget);
        entry.setMarginStart(@intFromFloat(p.x * k.x));
        entry.setMarginTop(@intFromFloat(p.y * k.y));
        self.entry.as(gtk.Editable).setText("");
        entry.setVisible(1);
        _ = entry.grabFocus();
    }

    fn entryVisible(self: *Editor) bool {
        return self.entry.as(gtk.Widget).getVisible() != 0;
    }

    fn onEntryActivate(_: *gtk.Entry, self: *Editor) callconv(.c) void {
        self.commitText();
    }

    /// The typed text becomes a shape; an empty entry is just closed.
    fn commitText(self: *Editor) void {
        if (!self.entryVisible()) return;
        const text = std.mem.span(self.entry.as(gtk.Editable).getText());
        self.entry.as(gtk.Widget).setVisible(0);
        _ = self.area.as(gtk.Widget).grabFocus();
        if (text.len == 0) return;
        const owned = self.allocator.dupe(u8, text) catch return;
        self.push(.{ .shape = .{ .tool = .text, .color = self.color, .width = self.width, .a = self.text_at, .text = owned } });
    }

    // ---- the keyboard ------------------------------------------------------------------------------

    fn onKey(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, state: gdk.ModifierType, self: *Editor) callconv(.c) c_int {
        const ctrl = state.control_mask;
        const shift = state.shift_mask;
        if (keyval == gdk.KEY_Escape) {
            // The first Escape closes a text being typed; the next one the editor.
            if (self.entryVisible()) {
                self.entry.as(gtk.Widget).setVisible(0);
                return 1;
            }
            self.finish(.cancel);
            return 1;
        }
        if (self.entryVisible()) return 0; // the entry has the keys while typing
        if (keyval == gdk.KEY_Return or keyval == gdk.KEY_KP_Enter) {
            if (self.sel != null) self.finish(.copy);
            return 1;
        }
        if (ctrl and (keyval == gdk.KEY_c or keyval == gdk.KEY_C)) {
            if (self.sel != null) self.finish(.copy);
            return 1;
        }
        if (ctrl and (keyval == gdk.KEY_s or keyval == gdk.KEY_S)) {
            if (self.sel != null) self.finish(.save);
            return 1;
        }
        if (ctrl and (keyval == gdk.KEY_z or keyval == gdk.KEY_Z)) {
            if (shift) self.redoLast() else self.undo();
            return 1;
        }
        if (ctrl and (keyval == gdk.KEY_y or keyval == gdk.KEY_Y)) {
            self.redoLast();
            return 1;
        }
        if (ctrl and (keyval == gdk.KEY_a or keyval == gdk.KEY_A)) {
            const img = self.imageSize();
            self.sel = .{ .x = 0, .y = 0, .w = img.x, .h = img.y };
            self.placeBar();
            self.area.as(gtk.Widget).queueDraw();
            return 1;
        }
        if (keyval == gdk.KEY_bracketright) return self.stepKey(-1);
        if (keyval == gdk.KEY_bracketleft) return self.stepKey(1);
        const arrow: ?[2]f64 = switch (keyval) {
            gdk.KEY_Left => .{ -1, 0 },
            gdk.KEY_Right => .{ 1, 0 },
            gdk.KEY_Up => .{ 0, -1 },
            gdk.KEY_Down => .{ 0, 1 },
            else => null,
        };
        if (arrow) |d| {
            if (self.sel) |s| {
                const img = self.imageSize();
                // Shift grows or shrinks the area from its bottom right corner.
                self.sel = annot.dragSelection(s, if (shift) .se else .inside, d[0], d[1], img.x, img.y);
                self.placeBar();
                self.area.as(gtk.Widget).queueDraw();
            }
            return 1;
        }
        return 0;
    }

    fn stepKey(self: *Editor, dy: f64) c_int {
        self.width = annot.stepWidth(self.width, dy);
        self.colors.as(gtk.Widget).queueDraw();
        return 1;
    }

    // ---- the result ----------------------------------------------------------------------------------

    const Outcome = enum { copy, save, scroll, cancel };

    fn finish(self: *Editor, outcome: Outcome) void {
        log.info("finish: {s}", .{@tagName(outcome)});
        self.commitText();
        const host = self.host;
        switch (outcome) {
            .cancel => {
                self.destroy();
                host.cancel(host.ctx);
            },
            .copy, .save => {
                const texture = self.exportTexture() orelse {
                    log.warn("cannot make the picture", .{});
                    return;
                };
                self.destroy();
                if (outcome == .copy) host.copy(host.ctx, texture) else host.save(host.ctx, texture);
            },
            .scroll => {
                const sel = self.sel orelse return;
                const img = self.imageSize();
                const rect = annot.toRectI(sel);
                self.destroy();
                host.scroll(host.ctx, rect, @intFromFloat(img.x), @intFromFloat(img.y));
            },
        }
    }

    /// The chosen area of the screen with the drawing on it.
    fn exportTexture(self: *Editor) ?*gdk.Texture {
        const sel = self.sel orelse return null;
        const img = self.imageSize();
        const r = annot.toRectI(annot.clampRect(sel, img.x, img.y));
        if (r.w < 1 or r.h < 1) return null;
        const surface = cairo.Surface.imageCreate(.argb32, r.w, r.h);
        defer surface.destroy();
        const cr = cairo.Context.create(surface);
        defer cr.destroy();
        cr.translate(@floatFromInt(-r.x), @floatFromInt(-r.y));
        gdk.cairoSetSourcePixbuf(cr, self.pixbuf, 0, 0);
        cr.paint();
        for (self.shapes.items) |*s| paintShape(cr, s);
        surface.flush();
        const data = surface.imageGetData() orelse return null;
        const stride: usize = @intCast(surface.imageGetStride());
        const bytes = glib.Bytes.new(data, stride * @as(usize, @intCast(r.h)));
        defer bytes.unref();
        const texture = gdk.MemoryTexture.new(r.w, r.h, .b8g8r8a8_premultiplied, bytes, stride);
        return texture.as(gdk.Texture);
    }

    // ---- painting -------------------------------------------------------------------------------------

    fn setColor(cr: *cairo.Context, color: u32, alpha: f64) void {
        cr.setSourceRgba(
            @as(f64, @floatFromInt((color >> 16) & 255)) / 255.0,
            @as(f64, @floatFromInt((color >> 8) & 255)) / 255.0,
            @as(f64, @floatFromInt(color & 255)) / 255.0,
            alpha,
        );
    }

    /// Black or white, whichever reads better on `color`.
    fn contrast(color: u32) u32 {
        const r: f64 = @floatFromInt((color >> 16) & 255);
        const g: f64 = @floatFromInt((color >> 8) & 255);
        const b: f64 = @floatFromInt(color & 255);
        return if (0.299 * r + 0.587 * g + 0.114 * b > 150) 0x000000 else 0xFFFFFF;
    }

    fn paintShape(cr: *cairo.Context, item: *const Annotation) void {
        const s = item.shape;
        cr.save();
        defer cr.restore();
        cr.setLineCap(.round);
        cr.setLineJoin(.round);
        cr.setLineWidth(s.width);
        setColor(cr, s.color, 1);
        switch (s.tool) {
            .select => {},
            .pen => {
                if (s.points.len == 1) {
                    cr.arc(s.points[0].x, s.points[0].y, s.width / 2, 0, 2 * std.math.pi);
                    cr.fill();
                    return;
                }
                cr.moveTo(s.points[0].x, s.points[0].y);
                for (s.points[1..]) |p| cr.lineTo(p.x, p.y);
                cr.stroke();
            },
            .marker => {
                setColor(cr, s.color, 0.4);
                cr.setLineCap(.butt);
                cr.setLineWidth(s.width * 5);
                cr.moveTo(s.points[0].x, s.points[0].y);
                for (s.points[1..]) |p| cr.lineTo(p.x, p.y);
                if (s.points.len == 1) cr.lineTo(s.points[0].x + 0.01, s.points[0].y);
                cr.stroke();
            },
            .line => {
                cr.moveTo(s.a.x, s.a.y);
                cr.lineTo(s.b.x, s.b.y);
                cr.stroke();
            },
            .arrow => {
                const wings = annot.arrowWings(s.a, s.b, s.width);
                cr.moveTo(s.a.x, s.a.y);
                cr.lineTo(s.b.x, s.b.y);
                cr.stroke();
                cr.moveTo(s.b.x, s.b.y);
                cr.lineTo(wings[0].x, wings[0].y);
                cr.lineTo(wings[1].x, wings[1].y);
                cr.closePath();
                cr.fill();
            },
            .rect => {
                const r = annot.normalizeF(s.a.x, s.a.y, s.b.x, s.b.y);
                cr.rectangle(r.x, r.y, r.w, r.h);
                cr.stroke();
            },
            .ellipse => {
                const r = annot.normalizeF(s.a.x, s.a.y, s.b.x, s.b.y);
                if (r.w < 1 or r.h < 1) return;
                // The path is made under a squashed circle, and stroked after the
                // transform is put back, or the line would be squashed too.
                cr.save();
                cr.translate(r.x + r.w / 2, r.y + r.h / 2);
                cr.scale(r.w / 2, r.h / 2);
                cr.arc(0, 0, 1, 0, 2 * std.math.pi);
                cr.restore();
                cr.stroke();
            },
            .pixelate => {
                const r = annot.toRectI(annot.normalizeF(s.a.x, s.a.y, s.b.x, s.b.y));
                if (item.patch) |patch| {
                    gdk.cairoSetSourcePixbuf(cr, patch, @floatFromInt(r.x), @floatFromInt(r.y));
                    cr.paint();
                } else {
                    // While dragging: only the box, until the mosaic is made.
                    cr.setLineWidth(1);
                    cr.rectangle(@floatFromInt(r.x), @floatFromInt(r.y), @floatFromInt(r.w), @floatFromInt(r.h));
                    cr.stroke();
                }
            },
            .text => {
                const size = 12 + s.width * 3;
                cr.selectFontFace("sans-serif", .normal, .bold);
                cr.setFontSize(size);
                var ext: cairo.TextExtents = undefined;
                const z = std.heap.c_allocator.dupeSentinel(u8, s.text, 0) catch return;
                defer std.heap.c_allocator.free(z);
                cr.textExtents(z.ptr, &ext);
                // The point is the top-left of the text.
                cr.moveTo(s.a.x - ext.x_bearing, s.a.y - ext.y_bearing);
                cr.showText(z.ptr);
            },
            .counter => {
                const radius = 10 + s.width * 2;
                cr.arc(s.a.x, s.a.y, radius, 0, 2 * std.math.pi);
                cr.fill();
                var buf: [16]u8 = undefined;
                const label = std.fmt.bufPrintSentinel(&buf, "{d}", .{s.number}, 0) catch return;
                setColor(cr, contrast(s.color), 1);
                cr.selectFontFace("sans-serif", .normal, .bold);
                cr.setFontSize(radius * 1.1);
                var ext: cairo.TextExtents = undefined;
                cr.textExtents(label.ptr, &ext);
                cr.moveTo(s.a.x - ext.width / 2 - ext.x_bearing, s.a.y - ext.height / 2 - ext.y_bearing);
                cr.showText(label.ptr);
            },
        }
    }

    fn onDraw(_: *gtk.DrawingArea, cr: *cairo.Context, width: c_int, height: c_int, data: ?*anyopaque) callconv(.c) void {
        const self: *Editor = @ptrCast(@alignCast(data.?));
        const img = self.imageSize();
        const sx = @as(f64, @floatFromInt(width)) / img.x;
        const sy = @as(f64, @floatFromInt(height)) / img.y;

        // The screen, dimmed everywhere but the area.
        cr.save();
        cr.scale(sx, sy);
        gdk.cairoSetSourcePixbuf(cr, self.pixbuf, 0, 0);
        cr.paint();
        cr.setSourceRgba(0, 0, 0, 0.5);
        if (self.sel) |s| {
            cr.rectangle(0, 0, img.x, img.y);
            cr.rectangle(s.x, s.y, s.w, s.h);
            cr.setFillRule(.even_odd);
            cr.fill();
            cr.setFillRule(.winding);
            // The drawing, only inside the area.
            cr.save();
            cr.rectangle(s.x, s.y, s.w, s.h);
            cr.clip();
            for (self.shapes.items) |*it| paintShape(cr, it);
            if (self.current) |*c| paintShape(cr, c);
            cr.restore();
        } else cr.paint();
        cr.restore();

        // The frame, the handles and the size, in screen pixels.
        const s = self.sel orelse return;
        const x = s.x * sx;
        const y = s.y * sy;
        const w = s.w * sx;
        const h = s.h * sy;
        cr.setSourceRgb(0.30, 0.64, 1.0);
        cr.setLineWidth(2);
        cr.rectangle(x, y, w, h);
        cr.stroke();
        const points = [_][2]f64{
            .{ x, y },         .{ x + w / 2, y },         .{ x + w, y },
            .{ x + w, y + h / 2 }, .{ x + w, y + h },     .{ x + w / 2, y + h },
            .{ x, y + h },     .{ x, y + h / 2 },
        };
        for (points) |p| {
            cr.arc(p[0], p[1], 5, 0, 2 * std.math.pi);
            cr.setSourceRgb(1, 1, 1);
            cr.fillPreserve();
            cr.setSourceRgb(0.30, 0.64, 1.0);
            cr.setLineWidth(1.5);
            cr.stroke();
        }

        // "1280 x 720", above the area or inside it when there is no room.
        var buf: [32]u8 = undefined;
        const label = std.fmt.bufPrintSentinel(&buf, "{d} \u{D7} {d}", .{ @as(i32, @intFromFloat(@round(s.w))), @as(i32, @intFromFloat(@round(s.h))) }, 0) catch return;
        cr.selectFontFace("sans-serif", .normal, .normal);
        cr.setFontSize(12);
        var ext: cairo.TextExtents = undefined;
        cr.textExtents(label.ptr, &ext);
        const pw = ext.width + 14;
        const ph = 22.0;
        const px = std.math.clamp(x, 0, @max(0, @as(f64, @floatFromInt(width)) - pw));
        const py = if (y - ph - 4 >= 0) y - ph - 4 else y + 4;
        cr.setSourceRgba(0, 0, 0, 0.75);
        cr.rectangle(px, py, pw, ph);
        cr.fill();
        cr.setSourceRgb(1, 1, 1);
        cr.moveTo(px + 7 - ext.x_bearing, py + ph / 2 - ext.height / 2 - ext.y_bearing);
        cr.showText(label.ptr);
    }

    // ---- the colours ---------------------------------------------------------------------------------

    fn onDrawColors(_: *gtk.DrawingArea, cr: *cairo.Context, width: c_int, height: c_int, data: ?*anyopaque) callconv(.c) void {
        const self: *Editor = @ptrCast(@alignCast(data.?));
        const h: f64 = @floatFromInt(height);
        _ = width;
        for (annot.palette, 0..) |c, i| {
            const cx = 11.0 + @as(f64, @floatFromInt(i)) * 22;
            setColor(cr, c, 1);
            cr.arc(cx, h / 2, 8, 0, 2 * std.math.pi);
            cr.fill();
            // A ring on the one in use; a hairline so white and black show on the bar.
            setColor(cr, 0x808080, 1);
            cr.setLineWidth(1);
            cr.arc(cx, h / 2, 8, 0, 2 * std.math.pi);
            cr.stroke();
            if (c == self.color) {
                cr.setSourceRgb(0.30, 0.64, 1.0);
                cr.setLineWidth(2.5);
                cr.arc(cx, h / 2, 10.5, 0, 2 * std.math.pi);
                cr.stroke();
            }
        }
        // The thickness: a dot of that size and its number.
        const bx = @as(f64, annot.palette.len) * 22 + 14;
        setColor(cr, self.color, 1);
        cr.arc(bx, h / 2, @min(self.width, 12) / 2 + 1, 0, 2 * std.math.pi);
        cr.fill();
        var buf: [8]u8 = undefined;
        const label = std.fmt.bufPrintSentinel(&buf, "{d}", .{@as(i32, @intFromFloat(self.width))}, 0) catch return;
        cr.setSourceRgb(0.94, 0.94, 0.94);
        cr.selectFontFace("sans-serif", .normal, .normal);
        cr.setFontSize(12);
        cr.moveTo(bx + 12, h / 2 + 4);
        cr.showText(label.ptr);
    }

    fn onColorClick(_: *gtk.GestureClick, _: c_int, x: f64, _: f64, self: *Editor) callconv(.c) void {
        const i: usize = @intFromFloat(@max(0, @floor(x / 22)));
        if (i >= annot.palette.len) return;
        self.color = annot.palette[i];
        self.colors.as(gtk.Widget).queueDraw();
    }
};

// ---- tests: every tool painted on an offscreen surface, then the pixels read ------------------

const testing = std.testing;

const Canvas = struct {
    surface: *cairo.Surface,
    cr: *cairo.Context,
    stride: usize,

    fn init(w: i32, h: i32) Canvas {
        const surface = cairo.Surface.imageCreate(.argb32, w, h);
        return .{ .surface = surface, .cr = cairo.Context.create(surface), .stride = @intCast(surface.imageGetStride()) };
    }

    fn deinit(self: *Canvas) void {
        self.cr.destroy();
        self.surface.destroy();
    }

    /// 0xAARRGGBB (premultiplied, as cairo keeps it) of a pixel.
    fn at(self: *Canvas, x: usize, y: usize) u32 {
        self.surface.flush();
        const d = self.surface.imageGetData().?;
        return std.mem.readInt(u32, d[y * self.stride + x * 4 ..][0..4], .little);
    }

    fn alpha(self: *Canvas, x: usize, y: usize) u8 {
        return @intCast(self.at(x, y) >> 24);
    }

    fn painted(self: *Canvas, x: usize, y: usize) bool {
        return self.alpha(x, y) > 200;
    }

    fn clear(self: *Canvas, x: usize, y: usize) bool {
        return self.alpha(x, y) == 0;
    }
};

test "a rectangle is an outline" {
    var c = Canvas.init(100, 80);
    defer c.deinit();
    const item: Annotation = .{ .shape = .{ .tool = .rect, .color = 0xE53935, .width = 4, .a = .{ .x = 10, .y = 10 }, .b = .{ .x = 60, .y = 50 } } };
    Editor.paintShape(c.cr, &item);
    try testing.expect(c.painted(10, 30)); // left edge
    try testing.expect(c.painted(35, 10)); // top edge
    try testing.expect(c.clear(35, 30)); // inside: not filled
    try testing.expect(c.clear(3, 3)); // outside
    // Red: premultiplied opaque, so the colour is exact.
    try testing.expectEqual(@as(u32, 0xFFE53935), c.at(10, 30));
}

test "a line has the thickness asked for" {
    var c = Canvas.init(100, 40);
    defer c.deinit();
    const item: Annotation = .{ .shape = .{ .tool = .line, .color = 0x1E88E5, .width = 6, .a = .{ .x = 5, .y = 20 }, .b = .{ .x = 95, .y = 20 } } };
    Editor.paintShape(c.cr, &item);
    try testing.expect(c.painted(50, 20));
    try testing.expect(c.painted(50, 18) and c.painted(50, 22));
    try testing.expect(c.clear(50, 12));
    try testing.expect(c.clear(50, 28));
}

test "an arrow has a head at its tip" {
    var c = Canvas.init(120, 60);
    defer c.deinit();
    const item: Annotation = .{ .shape = .{ .tool = .arrow, .color = 0x43A047, .width = 3, .a = .{ .x = 10, .y = 30 }, .b = .{ .x = 100, .y = 30 } } };
    Editor.paintShape(c.cr, &item);
    // The shaft is thin; near the tip the head is wide.
    try testing.expect(c.painted(40, 30) and c.clear(40, 24));
    // The head: 18 long for this thickness, about 8 either side at its base,
    // so 10 pixels back from the tip it is about 5 either side of the line.
    try testing.expect(c.painted(90, 27) and c.painted(90, 33));
    try testing.expect(c.clear(90, 22) and c.clear(90, 38));
    try testing.expect(c.painted(97, 30));
}

test "an ellipse is a round outline and not squashed" {
    var c = Canvas.init(120, 80);
    defer c.deinit();
    // 100 wide and 40 tall, so the transform that makes the path is not uniform.
    const item: Annotation = .{ .shape = .{ .tool = .ellipse, .color = 0x8E24AA, .width = 6, .a = .{ .x = 10, .y = 20 }, .b = .{ .x = 110, .y = 60 } } };
    Editor.paintShape(c.cr, &item);
    try testing.expect(c.painted(10, 40)); // left
    try testing.expect(c.painted(110, 40)); // right (edge pixels of a width-6 stroke)
    try testing.expect(c.painted(60, 20)); // top
    try testing.expect(c.painted(60, 60)); // bottom
    try testing.expect(c.clear(60, 40)); // inside
    try testing.expect(c.clear(12, 22)); // the box's corner is outside the curve
    // The stroke is as thick at the left as at the top: not squashed by the scale.
    try testing.expect(c.painted(12, 40) and c.painted(60, 22));
    try testing.expect(c.clear(18, 40) and c.clear(60, 28));
}

test "the highlighter is translucent and wide" {
    var c = Canvas.init(100, 60);
    defer c.deinit();
    var pts = [_]annot.Point{ .{ .x = 10, .y = 30 }, .{ .x = 90, .y = 30 } };
    const item: Annotation = .{ .shape = .{ .tool = .marker, .color = 0xFDD835, .width = 4, .points = &pts } };
    Editor.paintShape(c.cr, &item);
    const a = c.alpha(50, 30);
    try testing.expect(a > 90 and a < 115); // 40% of 255
    try testing.expect(c.alpha(50, 38) > 90); // 4 * 5 = 20 px wide
    try testing.expect(c.clear(50, 45));
}

test "a click of the pen leaves a dot, a drag a stroke" {
    var c = Canvas.init(60, 40);
    defer c.deinit();
    var dot = [_]annot.Point{.{ .x = 30, .y = 20 }};
    Editor.paintShape(c.cr, &.{ .shape = .{ .tool = .pen, .color = 0x000000, .width = 8, .points = &dot } });
    try testing.expect(c.painted(30, 20));
    try testing.expect(c.clear(30, 30));
    var c2 = Canvas.init(60, 40);
    defer c2.deinit();
    var stroke = [_]annot.Point{ .{ .x = 5, .y = 5 }, .{ .x = 55, .y = 5 }, .{ .x = 55, .y = 35 } };
    Editor.paintShape(c2.cr, &.{ .shape = .{ .tool = .pen, .color = 0x000000, .width = 3, .points = &stroke } });
    try testing.expect(c2.painted(30, 5) and c2.painted(55, 20));
    try testing.expect(c2.clear(30, 20));
}

test "a counter is a filled circle with its number in a readable colour" {
    var c = Canvas.init(80, 80);
    defer c.deinit();
    // Yellow is light: the number is black. Width 3 makes the radius 16.
    Editor.paintShape(c.cr, &.{ .shape = .{ .tool = .counter, .color = 0xFDD835, .width = 3, .a = .{ .x = 40, .y = 40 }, .number = 7 } });
    try testing.expectEqual(@as(u32, 0xFFFDD835), c.at(40 + 13, 40));
    try testing.expect(c.clear(40 + 20, 40));
    // Some pixels in the middle are the number's black.
    var dark = false;
    for (32..48) |x| {
        for (32..48) |y| {
            if (c.at(x, y) == 0xFF000000) dark = true;
        }
    }
    try testing.expect(dark);
}

test "text is drawn from its top-left corner" {
    var c = Canvas.init(160, 60);
    defer c.deinit();
    Editor.paintShape(c.cr, &.{ .shape = .{ .tool = .text, .color = 0xE53935, .width = 3, .a = .{ .x = 10, .y = 10 }, .text = "Hello" } });
    var any = false;
    for (10..70) |x| {
        for (10..40) |y| {
            if (c.painted(x, y)) any = true;
        }
    }
    try testing.expect(any);
    // Nothing above or left of the corner.
    for (0..9) |x| try testing.expect(c.clear(x, 20));
    for (0..9) |y| try testing.expect(c.clear(30, y));
}

test "a pixelated box shows its mosaic where the box is" {
    var c = Canvas.init(60, 40);
    defer c.deinit();
    const patch = gdkpixbuf.Pixbuf.new(.rgb, 1, 8, 20, 10).?;
    defer patch.as(gobject.Object).unref();
    patch.fill(0x336699FF);
    const item: Annotation = .{ .shape = .{ .tool = .pixelate, .color = 0, .width = 3, .a = .{ .x = 10, .y = 10 }, .b = .{ .x = 30, .y = 20 } }, .patch = patch };
    Editor.paintShape(c.cr, &item);
    try testing.expectEqual(@as(u32, 0xFF336699), c.at(15, 15));
    try testing.expect(c.clear(5, 15));
    try testing.expect(c.clear(35, 15));
    try testing.expect(c.clear(15, 25));
}

test "the dim colour for a counter follows the colour under it" {
    try testing.expectEqual(@as(u32, 0x000000), Editor.contrast(0xFDD835)); // yellow
    try testing.expectEqual(@as(u32, 0xFFFFFF), Editor.contrast(0x1E88E5)); // blue
    try testing.expectEqual(@as(u32, 0xFFFFFF), Editor.contrast(0x000000));
    try testing.expectEqual(@as(u32, 0x000000), Editor.contrast(0xFFFFFF));
}
