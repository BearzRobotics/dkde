//! The hex view of dkde-hex: offsets, hex bytes and text, drawn row by row so
//! only what is on screen costs anything, with a cursor, a selection and
//! editing in either pane.

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
const buffer_mod = @import("buffer.zig");
const Buffer = buffer_mod.Buffer;

pub const Pane = enum { hex, text };

/// A stretch of bytes the structure view knows about, drawn in a soft colour.
pub const Range = struct { start: usize, len: usize, color: u8 };

/// Fill colours for `Range.color` (taken modulo the length), chosen to read on
/// both light and dark backgrounds at low opacity.
const palette = [_][3]f64{
    .{ 0.25, 0.55, 0.95 },
    .{ 0.25, 0.75, 0.40 },
    .{ 0.95, 0.60, 0.15 },
    .{ 0.70, 0.40, 0.90 },
    .{ 0.15, 0.75, 0.75 },
    .{ 0.90, 0.35, 0.40 },
};

pub const View = struct {
    allocator: std.mem.Allocator,
    buffer: *Buffer,
    /// The widget to put in a window: the drawing area and its scroll bar.
    box: *gtk.Box,
    area: *gtk.DrawingArea,
    /// Carries the accent colour for the drawn selection and caret.
    probe: *gtk.Widget,
    adjustment: *gtk.Adjustment,
    layout: *pango.Layout,
    font: *pango.FontDescription,
    cell_w: f64 = 8,
    cell_h: f64 = 16,
    ascent: f64 = 12,

    bytes_per_row: usize = 16,
    uppercase: bool = true,
    insert_mode: bool = false,
    pane: Pane = .hex,
    /// Where the caret is; may equal the length, to append.
    cursor: usize = 0,
    /// 0 for the high nibble, 1 for the low one (hex pane).
    nibble: u1 = 0,
    anchor: ?usize = null,
    drag_origin: usize = 0,
    /// Sorted by start; not owned.
    highlights: []const Range = &.{},

    /// Called after the cursor, selection or content changed.
    changed: *const fn (*anyopaque) void,
    changed_data: *anyopaque,

    const pad = 8.0;
    const offset_chars = 8;

    pub fn create(
        allocator: std.mem.Allocator,
        buffer: *Buffer,
        changed: *const fn (*anyopaque) void,
        data: *anyopaque,
    ) !*View {
        const self = try allocator.create(View);
        errdefer allocator.destroy(self);
        const area = gtk.DrawingArea.new();
        const adjustment = gtk.Adjustment.new(0, 0, 1, 1, 10, 1);
        const scrollbar = gtk.Scrollbar.new(.vertical, adjustment);
        const box = gtk.Box.new(.horizontal, 0);
        area.as(gtk.Widget).setHexpand(1);
        area.as(gtk.Widget).setVexpand(1);
        area.as(gtk.Widget).setFocusable(1);
        area.as(gtk.Widget).setCanFocus(1);
        area.as(gtk.Widget).addCssClass("dkde-hex-view");
        box.append(area.as(gtk.Widget));
        box.append(scrollbar.as(gtk.Widget));
        const probe = common.style.accentProbe();
        box.append(probe);

        self.* = .{
            .allocator = allocator,
            .buffer = buffer,
            .box = box,
            .area = area,
            .probe = probe,
            .adjustment = adjustment,
            .layout = area.as(gtk.Widget).createPangoLayout(null),
            .font = pango.FontDescription.fromString("Monospace 11"),
            .changed = changed,
            .changed_data = data,
        };
        self.layout.setFontDescription(self.font);
        self.measure();

        area.setDrawFunc(onDraw, self, null);
        _ = gtk.DrawingArea.signals.resize.connect(area, *View, &onResize, self, .{});
        _ = gtk.Adjustment.signals.value_changed.connect(adjustment, *View, &onScrolled, self, .{});
        _ = gtk.Widget.signals.destroy.connect(area, *View, &onDestroy, self, .{});

        const keys = gtk.EventControllerKey.new();
        _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *View, &onKey, self, .{});
        area.as(gtk.Widget).addController(keys.as(gtk.EventController));

        const click = gtk.GestureClick.new();
        click.as(gtk.GestureSingle).setButton(1);
        _ = gtk.GestureClick.signals.pressed.connect(click, *View, &onPressed, self, .{});
        area.as(gtk.Widget).addController(click.as(gtk.EventController));

        const drag = gtk.GestureDrag.new();
        drag.as(gtk.GestureSingle).setButton(1);
        _ = gtk.GestureDrag.signals.drag_update.connect(drag, *View, &onDragUpdate, self, .{});
        area.as(gtk.Widget).addController(drag.as(gtk.EventController));

        const scroll = gtk.EventControllerScroll.new(.{ .vertical = true });
        _ = gtk.EventControllerScroll.signals.scroll.connect(scroll, *View, &onScroll, self, .{});
        area.as(gtk.Widget).addController(scroll.as(gtk.EventController));

        self.updateMinWidth();
        self.updateScrollRange();
        return self;
    }

    fn onDestroy(_: *gtk.DrawingArea, self: *View) callconv(.c) void {
        self.layout.as(gobject.Object).unref();
        self.font.free();
        self.allocator.destroy(self);
    }

    fn measure(self: *View) void {
        const context = self.layout.getContext();
        const metrics = context.getMetrics(self.font, null);
        defer metrics.unref();
        const scale: f64 = pango.SCALE;
        self.cell_w = @max(1, @as(f64, @floatFromInt(metrics.getApproximateCharWidth())) / scale);
        const ascent = @as(f64, @floatFromInt(metrics.getAscent())) / scale;
        const descent = @as(f64, @floatFromInt(metrics.getDescent())) / scale;
        self.cell_h = @ceil(ascent + descent) + 2;
        self.ascent = ascent + 1;
    }

    /// The widest row, so the view never gets narrower than one whole row.
    fn updateMinWidth(self: *View) void {
        const chars = self.textStart() + @as(f64, @floatFromInt(self.bytes_per_row));
        self.area.setContentWidth(@intFromFloat(@ceil(chars * self.cell_w + 2 * pad)));
    }

    pub fn widget(self: *View) *gtk.Widget {
        return self.box.as(gtk.Widget);
    }

    pub fn grabFocus(self: *View) void {
        _ = self.area.as(gtk.Widget).grabFocus();
    }

    // ---- geometry --------------------------------------------------------------

    fn rowCount(self: *const View) usize {
        // One extra row so a caret after the last byte has somewhere to be.
        return self.buffer.len() / self.bytes_per_row + 1;
    }

    fn visibleRows(self: *const View) usize {
        const h: f64 = @floatFromInt(self.area.as(gtk.Widget).getHeight());
        return @max(1, @as(usize, @intFromFloat(h / self.cell_h)));
    }

    fn updateScrollRange(self: *View) void {
        const rows: f64 = @floatFromInt(self.rowCount());
        const page: f64 = @floatFromInt(self.visibleRows());
        self.adjustment.configure(@min(self.adjustment.getValue(), @max(0, rows - page)), 0, rows, 1, page - 1, page);
    }

    fn firstRow(self: *const View) usize {
        return @intFromFloat(@max(0, @floor(self.adjustment.getValue())));
    }

    /// Characters from the left edge of the rows to the first hex digit.
    fn hexStart(_: *const View) f64 {
        return offset_chars + 2;
    }

    fn hexColumn(self: *const View, col: usize) f64 {
        return self.hexStart() + @as(f64, @floatFromInt(col * 3 + col / 8));
    }

    fn textStart(self: *const View) f64 {
        return self.hexStart() + @as(f64, @floatFromInt(self.bytes_per_row * 3 + self.bytes_per_row / 8)) + 1;
    }

    /// The byte under a point, and which pane it is in.
    fn hit(self: *const View, x: f64, y: f64) ?struct { offset: usize, pane: Pane, nibble: u1 } {
        const row = self.firstRow() + @as(usize, @intFromFloat(@max(0, y) / self.cell_h));
        const chars = (x - pad) / self.cell_w;
        const bpr = self.bytes_per_row;
        var col: usize = 0;
        var pane: Pane = .hex;
        var nib: u1 = 0;
        if (chars >= self.textStart()) {
            pane = .text;
            col = @min(bpr - 1, @as(usize, @intFromFloat(@max(0, chars - self.textStart()))));
        } else {
            const rel = @max(0, chars - self.hexStart());
            // Undo the extra gap after every eighth byte.
            const group = 8.0 * 3.0 + 1.0;
            const g: usize = @intFromFloat(rel / group);
            const within = rel - @as(f64, @floatFromInt(g)) * group;
            const in_group: usize = @min(7, @as(usize, @intFromFloat(within / 3.0)));
            col = @min(bpr - 1, g * 8 + in_group);
            if (within - @as(f64, @floatFromInt(in_group)) * 3.0 >= 1.0) nib = 1;
        }
        const offset = @min(self.buffer.len(), row * bpr + col);
        return .{ .offset = offset, .pane = pane, .nibble = nib };
    }

    // ---- drawing -----------------------------------------------------------------

    fn onResize(_: *gtk.DrawingArea, _: c_int, _: c_int, self: *View) callconv(.c) void {
        self.updateScrollRange();
    }

    fn onScrolled(_: *gtk.Adjustment, self: *View) callconv(.c) void {
        self.area.as(gtk.Widget).queueDraw();
    }

    fn selectionRange(self: *const View) ?[2]usize {
        const a = self.anchor orelse return null;
        if (a == self.cursor) return null;
        return .{ @min(a, self.cursor), @max(a, self.cursor) };
    }

    fn onDraw(_: *gtk.DrawingArea, cr: *cairo.Context, width: c_int, height: c_int, data: ?*anyopaque) callconv(.c) void {
        const self: *View = @ptrCast(@alignCast(data.?));
        const w: f64 = @floatFromInt(width);
        const h: f64 = @floatFromInt(height);
        var fg: gdk.RGBA = undefined;
        self.area.as(gtk.Widget).getColor(&fg);

        const bytes = self.buffer.slice();
        const bpr = self.bytes_per_row;
        const first = self.firstRow();
        const accent = common.style.accentOf(self.probe);
        const sel = self.selectionRange();
        const rows_on_screen = @as(usize, @intFromFloat(h / self.cell_h)) + 2;
        _ = w;

        var row: usize = 0;
        while (row < rows_on_screen) : (row += 1) {
            const line = first + row;
            const start = line * bpr;
            if (start > bytes.len) break;
            const y = @as(f64, @floatFromInt(row)) * self.cell_h;

            // Selection and caret behind the text.
            var col: usize = 0;
            while (col < bpr) : (col += 1) {
                const off = start + col;
                if (off > bytes.len) break;
                const selected = if (sel) |s| off >= s[0] and off < s[1] else false;
                const is_cursor = off == self.cursor;
                if (off < bytes.len) if (self.rangeAt(off)) |range| {
                    const c = palette[range.color % palette.len];
                    cr.setSourceRgba(c[0], c[1], c[2], 0.30);
                    // Join with the next byte of the same field so a field reads as one strip.
                    const joined = off + 1 < range.start + range.len and col + 1 < bpr and col % 8 != 7;
                    cr.rectangle(pad + self.hexColumn(col) * self.cell_w, y, if (joined) 3 * self.cell_w else 2 * self.cell_w, self.cell_h);
                    cr.fill();
                    cr.rectangle(pad + (self.textStart() + @as(f64, @floatFromInt(col))) * self.cell_w, y, self.cell_w, self.cell_h);
                    cr.fill();
                };
                if (selected) {
                    cr.setSourceRgba(accent.f_red, accent.f_green, accent.f_blue, 0.40);
                    cr.rectangle(pad + self.hexColumn(col) * self.cell_w, y, 2 * self.cell_w, self.cell_h);
                    cr.fill();
                    cr.rectangle(pad + (self.textStart() + @as(f64, @floatFromInt(col))) * self.cell_w, y, self.cell_w, self.cell_h);
                    cr.fill();
                }
                if (is_cursor) {
                    const hex_active = self.pane == .hex;
                    // The active pane gets the strong caret, the other an outline.
                    cr.setSourceRgba(accent.f_red, accent.f_green, accent.f_blue, if (hex_active) 0.85 else 0.35);
                    const hx = pad + (self.hexColumn(col) + @as(f64, @floatFromInt(self.nibble))) * self.cell_w;
                    if (hex_active) {
                        if (self.insert_mode) cr.rectangle(hx, y, 2, self.cell_h) else cr.rectangle(hx, y, self.cell_w, self.cell_h);
                    } else cr.rectangle(pad + self.hexColumn(col) * self.cell_w, y, 2 * self.cell_w, self.cell_h);
                    cr.fill();
                    cr.setSourceRgba(accent.f_red, accent.f_green, accent.f_blue, if (!hex_active) 0.85 else 0.35);
                    const tx = pad + (self.textStart() + @as(f64, @floatFromInt(col))) * self.cell_w;
                    if (!hex_active and self.insert_mode) cr.rectangle(tx, y, 2, self.cell_h) else cr.rectangle(tx, y, self.cell_w, self.cell_h);
                    cr.fill();
                }
            }

            // The text of the row, in three pieces.
            var buf: [512]u8 = undefined;
            const offset_text = (if (self.uppercase) std.fmt.bufPrint(&buf, "{X:0>8}", .{start}) else std.fmt.bufPrint(&buf, "{x:0>8}", .{start})) catch continue;
            cr.setSourceRgba(fg.f_red, fg.f_green, fg.f_blue, 0.55);
            self.drawText(cr, offset_text, pad, y);

            var hex_buf: [256]u8 = undefined;
            var n: usize = 0;
            var text_buf: [64]u8 = undefined;
            var t: usize = 0;
            col = 0;
            while (col < bpr) : (col += 1) {
                const off = start + col;
                if (col != 0 and col % 8 == 0) {
                    hex_buf[n] = ' ';
                    n += 1;
                }
                if (off < bytes.len) {
                    const digits = if (self.uppercase) "0123456789ABCDEF" else "0123456789abcdef";
                    hex_buf[n] = digits[bytes[off] >> 4];
                    hex_buf[n + 1] = digits[bytes[off] & 15];
                    text_buf[t] = if (bytes[off] >= 0x20 and bytes[off] < 0x7f) bytes[off] else '.';
                    t += 1;
                } else {
                    hex_buf[n] = ' ';
                    hex_buf[n + 1] = ' ';
                }
                hex_buf[n + 2] = ' ';
                n += 3;
            }
            cr.setSourceRgba(fg.f_red, fg.f_green, fg.f_blue, 1);
            self.drawText(cr, hex_buf[0..n], pad + self.hexStart() * self.cell_w, y);
            cr.setSourceRgba(fg.f_red, fg.f_green, fg.f_blue, 0.8);
            self.drawText(cr, text_buf[0..t], pad + self.textStart() * self.cell_w, y);
        }
    }

    fn drawText(self: *View, cr: *cairo.Context, text: []const u8, x: f64, y: f64) void {
        cr.moveTo(x, y + 1);
        self.layout.setText(@ptrCast(text.ptr), @intCast(text.len));
        pangocairo.showLayout(cr, self.layout);
    }

    // ---- moving ---------------------------------------------------------------------

    fn notify(self: *View) void {
        self.area.as(gtk.Widget).queueDraw();
        self.changed(self.changed_data);
    }

    fn ensureVisible(self: *View) void {
        const row: f64 = @floatFromInt(self.cursor / self.bytes_per_row);
        const page: f64 = @floatFromInt(self.visibleRows());
        const top = self.adjustment.getValue();
        if (row < top) self.adjustment.setValue(row) else if (row + 1 > top + page) self.adjustment.setValue(row + 1 - page);
    }

    /// Moves the caret; with `extend` the selection grows from where it was.
    pub fn moveTo(self: *View, offset: usize, extend: bool) void {
        if (extend) {
            if (self.anchor == null) self.anchor = self.cursor;
        } else self.anchor = null;
        self.cursor = @min(offset, self.buffer.len());
        self.nibble = 0;
        self.ensureVisible();
        self.notify();
    }

    /// Call after the buffer changed from outside (open, undo, redo, revert).
    pub fn refresh(self: *View) void {
        self.cursor = @min(self.cursor, self.buffer.len());
        self.anchor = null;
        self.updateScrollRange();
        self.ensureVisible();
        self.notify();
    }

    /// Colours these ranges (sorted by start). The slice must outlive its use.
    pub fn setHighlights(self: *View, ranges: []const Range) void {
        self.highlights = ranges;
        self.area.as(gtk.Widget).queueDraw();
    }

    fn rangeAt(self: *const View, off: usize) ?Range {
        const r = self.highlights;
        var lo: usize = 0;
        var hi: usize = r.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (r[mid].start <= off) lo = mid + 1 else hi = mid;
        }
        if (lo == 0) return null;
        const cand = r[lo - 1];
        return if (off < cand.start + cand.len) cand else null;
    }

    pub fn setBytesPerRow(self: *View, n: usize) void {
        self.bytes_per_row = n;
        self.updateMinWidth();
        self.updateScrollRange();
        self.ensureVisible();
        self.area.as(gtk.Widget).queueDraw();
    }

    pub fn setUppercase(self: *View, on: bool) void {
        self.uppercase = on;
        self.area.as(gtk.Widget).queueDraw();
    }

    pub fn setInsertMode(self: *View, on: bool) void {
        self.insert_mode = on;
        self.notify();
    }

    pub fn selection(self: *const View) ?[2]usize {
        return self.selectionRange();
    }

    pub fn selectAll(self: *View) void {
        self.anchor = 0;
        self.cursor = self.buffer.len();
        self.notify();
    }

    /// Selects `len` bytes at `offset` and shows them (a find result).
    pub fn select(self: *View, offset: usize, len: usize) void {
        self.anchor = offset;
        self.cursor = @min(offset + len, self.buffer.len());
        self.nibble = 0;
        self.ensureVisible();
        self.notify();
    }

    // ---- input ------------------------------------------------------------------------

    fn onPressed(gesture: *gtk.GestureClick, _: c_int, x: f64, y: f64, self: *View) callconv(.c) void {
        self.grabFocus();
        const found = self.hit(x, y) orelse return;
        const extend = gesture.as(gtk.EventController).getCurrentEventState().shift_mask;
        self.pane = found.pane;
        self.drag_origin = found.offset;
        self.moveTo(found.offset, extend);
        self.nibble = found.nibble;
        self.area.as(gtk.Widget).queueDraw();
    }

    fn onDragUpdate(gesture: *gtk.GestureDrag, dx: f64, dy: f64, self: *View) callconv(.c) void {
        var sx: f64 = 0;
        var sy: f64 = 0;
        if (gesture.getStartPoint(&sx, &sy) == 0) return;
        const found = self.hit(sx + dx, sy + dy) orelse return;
        self.anchor = self.drag_origin;
        self.cursor = found.offset;
        self.notify();
    }

    fn onScroll(_: *gtk.EventControllerScroll, _: f64, dy: f64, self: *View) callconv(.c) c_int {
        self.adjustment.setValue(self.adjustment.getValue() + dy * 3);
        return 1;
    }

    fn onKey(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, state: gdk.ModifierType, self: *View) callconv(.c) c_int {
        const ctrl = state.control_mask;
        const shift = state.shift_mask;
        const bpr = self.bytes_per_row;
        const page = self.visibleRows() * bpr;
        const len = self.buffer.len();

        if (ctrl) {
            switch (keyval) {
                gdk.KEY_a => self.selectAll(),
                gdk.KEY_c => self.copy(shift),
                gdk.KEY_x => self.cutSelection(),
                gdk.KEY_v => self.pasteClipboard(),
                gdk.KEY_z => self.undo(),
                gdk.KEY_y => self.redo(),
                gdk.KEY_Home => self.moveTo(0, shift),
                gdk.KEY_End => self.moveTo(len, shift),
                else => return 0,
            }
            return 1;
        }
        switch (keyval) {
            gdk.KEY_Left => self.moveTo(self.cursor -| 1, shift),
            gdk.KEY_Right => self.moveTo(self.cursor + 1, shift),
            gdk.KEY_Up => self.moveTo(self.cursor -| bpr, shift),
            gdk.KEY_Down => self.moveTo(self.cursor + bpr, shift),
            gdk.KEY_Page_Up => self.moveTo(self.cursor -| page, shift),
            gdk.KEY_Page_Down => self.moveTo(self.cursor + page, shift),
            gdk.KEY_Home => self.moveTo(self.cursor / bpr * bpr, shift),
            gdk.KEY_End => self.moveTo(@min(len, self.cursor / bpr * bpr + bpr - 1), shift),
            gdk.KEY_Tab, gdk.KEY_ISO_Left_Tab => {
                self.pane = if (self.pane == .hex) .text else .hex;
                self.nibble = 0;
                self.notify();
            },
            gdk.KEY_Insert => self.setInsertMode(!self.insert_mode),
            gdk.KEY_Delete => self.deleteForward(),
            gdk.KEY_BackSpace => self.deleteBackward(),
            else => return self.typed(keyval),
        }
        return 1;
    }

    /// A digit in the hex pane, or a character in the text pane.
    fn typed(self: *View, keyval: c_uint) c_int {
        if (keyval < 0x20 or keyval > 0x7e) return 0;
        const ch: u8 = @intCast(keyval);
        if (self.pane == .text) {
            self.putByte(ch);
            return 1;
        }
        const digit = std.fmt.charToDigit(ch, 16) catch return 0;
        self.putNibble(@intCast(digit));
        return 1;
    }

    fn putByte(self: *View, value: u8) void {
        self.anchor = null;
        if (self.cursor >= self.buffer.len() or self.insert_mode) {
            self.buffer.replace(self.cursor, 0, &.{value}, false) catch return;
        } else self.buffer.setByte(self.cursor, value, false) catch return;
        self.cursor += 1;
        self.nibble = 0;
        self.ensureVisible();
        self.updateScrollRange();
        self.notify();
    }

    fn putNibble(self: *View, digit: u8) void {
        self.anchor = null;
        const bytes = self.buffer.slice();
        if (self.nibble == 0) {
            const low: u8 = if (self.cursor < bytes.len and !self.insert_mode) bytes[self.cursor] & 0x0f else 0;
            const value = digit << 4 | low;
            if (self.cursor >= bytes.len or self.insert_mode) {
                self.buffer.replace(self.cursor, 0, &.{value}, true) catch return;
            } else self.buffer.setByte(self.cursor, value, true) catch return;
            self.nibble = 1;
        } else {
            const high = self.buffer.slice()[self.cursor] & 0xf0;
            self.buffer.setByte(self.cursor, high | digit, true) catch return;
            self.cursor += 1;
            self.nibble = 0;
        }
        self.ensureVisible();
        self.updateScrollRange();
        self.notify();
    }

    fn deleteSelection(self: *View) bool {
        const sel = self.selectionRange() orelse return false;
        self.buffer.replace(sel[0], sel[1] - sel[0], "", false) catch return false;
        self.cursor = sel[0];
        self.anchor = null;
        self.nibble = 0;
        self.updateScrollRange();
        return true;
    }

    fn deleteForward(self: *View) void {
        if (!self.deleteSelection()) {
            if (self.cursor >= self.buffer.len()) return;
            self.buffer.replace(self.cursor, 1, "", false) catch return;
            self.updateScrollRange();
        }
        self.notify();
    }

    fn deleteBackward(self: *View) void {
        if (!self.deleteSelection()) {
            if (self.cursor == 0) return;
            self.cursor -= 1;
            self.buffer.replace(self.cursor, 1, "", false) catch return;
            self.nibble = 0;
            self.updateScrollRange();
        }
        self.notify();
    }

    pub fn undo(self: *View) void {
        const at = (self.buffer.undo() catch return) orelse return;
        self.cursor = @min(at, self.buffer.len());
        self.refresh();
    }

    pub fn redo(self: *View) void {
        const at = (self.buffer.redo() catch return) orelse return;
        self.cursor = @min(at, self.buffer.len());
        self.refresh();
    }

    // ---- clipboard ----------------------------------------------------------------------

    /// The selection as text: hex digits by default, or the text pane's characters.
    pub fn copy(self: *View, as_text: bool) void {
        const sel = self.selectionRange() orelse return;
        const bytes = self.buffer.slice()[sel[0]..sel[1]];
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);
        for (bytes, 0..) |b, i| {
            if (as_text) {
                out.append(self.allocator, if (b >= 0x20 and b < 0x7f) b else '.') catch return;
            } else {
                if (i > 0) out.append(self.allocator, ' ') catch return;
                const digits = if (self.uppercase) "0123456789ABCDEF" else "0123456789abcdef";
                out.appendSlice(self.allocator, &.{ digits[b >> 4], digits[b & 15] }) catch return;
            }
        }
        const z = self.allocator.dupeSentinel(u8, out.items, 0) catch return;
        defer self.allocator.free(z);
        self.area.as(gtk.Widget).getClipboard().setText(z);
    }

    pub fn cutSelection(self: *View) void {
        if (self.selectionRange() == null) return;
        self.copy(false);
        _ = self.deleteSelection();
        self.notify();
    }

    pub fn pasteClipboard(self: *View) void {
        self.area.as(gtk.Widget).getClipboard().readTextAsync(null, onPasted, self);
    }

    fn onPasted(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *View = @ptrCast(@alignCast(data.?));
        const clipboard: *gdk.Clipboard = @ptrCast(@alignCast(source.?));
        var err: ?*glib.Error = null;
        const text = clipboard.readTextFinish(result, &err) orelse {
            if (err) |e| e.free();
            return;
        };
        defer glib.free(text);
        const slice = std.mem.span(text);
        // Hex digits paste as bytes (in the hex pane); anything else as its characters.
        const parsed = if (self.pane == .hex) (buffer_mod.parseHex(self.allocator, slice) catch null) else null;
        const owned = parsed != null;
        const bytes: []const u8 = parsed orelse slice;
        defer if (owned) self.allocator.free(parsed.?);
        if (bytes.len == 0) return;

        const sel = self.selectionRange();
        const at = if (sel) |s| s[0] else self.cursor;
        const remove = if (sel) |s| s[1] - s[0] else if (self.insert_mode) 0 else @min(bytes.len, self.buffer.len() - @min(at, self.buffer.len()));
        self.buffer.replace(at, remove, bytes, false) catch return;
        self.cursor = at + bytes.len;
        self.anchor = null;
        self.nibble = 0;
        self.updateScrollRange();
        self.ensureVisible();
        self.notify();
    }
};
