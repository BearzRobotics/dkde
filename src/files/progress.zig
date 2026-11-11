//! The file operations indicator (SPEC.md 5.4), Nautilus-style: a button in
//! the header that appears while files are being copied or moved, drawn as
//! a pie of the overall progress. It opens a list of the operations, each
//! with what it is doing, how far it is, the time left and a cancel button.
//! Several operations can run at once.

const std = @import("std");
const cairo = @import("cairo1");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const common = @import("common");

const ops = @import("ops.zig");
const pure = @import("pure.zig");

const allocator = std.heap.c_allocator;

/// A finished operation stays in the list this long, then goes.
const linger_ms = 4000;
/// An operation still running after this long opens the list once.
const reveal_ms = 1500;

pub const Indicator = struct {
    parent: *gtk.Window,
    button: *gtk.MenuButton,
    pie: *gtk.DrawingArea,
    popover: *gtk.Popover,
    list: *gtk.Box,
    entries: std.ArrayList(*Entry) = .empty,

    pub fn create(parent: *gtk.Window) *Indicator {
        const self = allocator.create(Indicator) catch @panic("out of memory");
        self.* = .{
            .parent = parent,
            .button = gtk.MenuButton.new(),
            .pie = gtk.DrawingArea.new(),
            .popover = gtk.Popover.new(),
            .list = gtk.Box.new(.vertical, 12),
        };
        self.pie.setContentWidth(16);
        self.pie.setContentHeight(16);
        self.pie.setDrawFunc(onDraw, self, null);
        self.button.setChild(self.pie.as(gtk.Widget));
        self.button.as(gtk.Widget).addCssClass("flat");
        self.button.as(gtk.Widget).setTooltipText(common.tr("File operations"));
        self.button.as(gtk.Widget).setVisible(0);

        self.list.as(gtk.Widget).setMarginTop(8);
        self.list.as(gtk.Widget).setMarginBottom(8);
        self.list.as(gtk.Widget).setMarginStart(8);
        self.list.as(gtk.Widget).setMarginEnd(8);
        self.list.as(gtk.Widget).setSizeRequest(340, -1);
        self.popover.setChild(self.list.as(gtk.Widget));
        self.button.setPopover(self.popover);
        return self;
    }

    pub fn widget(self: *Indicator) *gtk.Widget {
        return self.button.as(gtk.Widget);
    }

    /// The window is closing: stop the operations it started (a copy left
    /// running would be cut off when the program exits) and free everything.
    pub fn destroy(self: *Indicator) void {
        for (self.entries.items) |entry| {
            if (entry.job) |job| {
                job.detach();
                job.cancel();
            }
            if (entry.linger != 0) _ = glib.Source.remove(entry.linger);
            if (entry.reveal != 0) _ = glib.Source.remove(entry.reveal);
            allocator.free(entry.dest_name);
            allocator.destroy(entry);
        }
        self.entries.deinit(allocator);
        allocator.destroy(self);
    }

    /// Starts copying or moving `sources` into `dest` and shows it.
    pub fn start(self: *Indicator, mode: ops.Mode, sources: []const *gio.File, dest: *gio.File) void {
        const entry = Entry.create(self, mode, dest) orelse return;
        self.entries.append(allocator, entry) catch {
            entry.free();
            return;
        };
        self.list.append(entry.row.as(gtk.Widget));
        self.button.as(gtk.Widget).setVisible(1);

        entry.job = ops.Job.start(allocator, mode, sources, dest, self.parent, .{
            .data = entry,
            .progress = Entry.onProgress,
            .finished = Entry.onFinished,
        }) catch |err| {
            common.dialogs.showError(self.parent, common.tr("Cannot start the operation"), @errorName(err));
            self.remove(entry);
            return;
        };
        entry.reveal = glib.timeoutAdd(reveal_ms, Entry.onReveal, entry);
        entry.update();
    }

    fn remove(self: *Indicator, entry: *Entry) void {
        for (self.entries.items, 0..) |e, i| if (e == entry) {
            _ = self.entries.orderedRemove(i);
            break;
        };
        self.list.remove(entry.row.as(gtk.Widget));
        entry.free();
        if (self.entries.items.len == 0) {
            self.popover.popdown();
            self.button.as(gtk.Widget).setVisible(0);
        }
        self.pie.as(gtk.Widget).queueDraw();
    }

    /// Overall progress of the operations still running, 0..1.
    fn fraction(self: *Indicator) f64 {
        var done: f64 = 0;
        var total: f64 = 0;
        for (self.entries.items) |e| {
            if (e.job == null) continue;
            done += e.fraction;
            total += 1;
        }
        return if (total == 0) 1 else done / total;
    }

    fn onDraw(area: *gtk.DrawingArea, cr: *cairo.Context, width: c_int, height: c_int, data: ?*anyopaque) callconv(.c) void {
        const self: *Indicator = @ptrCast(@alignCast(data.?));
        var fg: gdk.RGBA = undefined;
        area.as(gtk.Widget).getColor(&fg);
        const w: f64 = @floatFromInt(width);
        const h: f64 = @floatFromInt(height);
        const r = @min(w, h) / 2 - 1;
        const cx = w / 2;
        const cy = h / 2;
        // The whole circle, faint; the part done, solid.
        cr.setSourceRgba(fg.f_red, fg.f_green, fg.f_blue, 0.25);
        cr.arc(cx, cy, r, 0, 2 * std.math.pi);
        cr.fill();
        const f = self.fraction();
        if (f <= 0) return;
        cr.setSourceRgba(fg.f_red, fg.f_green, fg.f_blue, fg.f_alpha);
        cr.moveTo(cx, cy);
        const top = -std.math.pi / 2.0;
        cr.arc(cx, cy, r, top, top + f * 2 * std.math.pi);
        cr.closePath();
        cr.fill();
    }
};

const Entry = struct {
    indicator: *Indicator,
    mode: ops.Mode,
    job: ?*ops.Job = null,
    dest_name: [:0]u8,
    fraction: f64 = 0,
    linger: c_uint = 0,
    reveal: c_uint = 0,

    row: *gtk.Box,
    title: *gtk.Label,
    detail: *gtk.Label,
    bar: *gtk.ProgressBar,
    cancel: *gtk.Button,

    fn create(indicator: *Indicator, mode: ops.Mode, dest: *gio.File) ?*Entry {
        const self = allocator.create(Entry) catch return null;
        const info = dest.queryInfo("standard::display-name", .{}, null, null);
        defer if (info) |i| i.as(gobject.Object).unref();
        const name: []const u8 = if (info) |i| std.mem.span(i.getDisplayName()) else "folder";
        self.* = .{
            .indicator = indicator,
            .mode = mode,
            .dest_name = allocator.dupeSentinel(u8, name, 0) catch {
                allocator.destroy(self);
                return null;
            },
            .row = gtk.Box.new(.horizontal, 8),
            .title = gtk.Label.new(null),
            .detail = gtk.Label.new(null),
            .bar = gtk.ProgressBar.new(),
            .cancel = gtk.Button.newFromIconName("process-stop-symbolic"),
        };
        const text = gtk.Box.new(.vertical, 4);
        text.as(gtk.Widget).setHexpand(1);
        self.title.setXalign(0);
        self.title.setEllipsize(.middle);
        self.detail.setXalign(0);
        self.detail.as(gtk.Widget).addCssClass("dim-label");
        self.detail.as(gtk.Widget).addCssClass("caption");
        text.append(self.title.as(gtk.Widget));
        text.append(self.bar.as(gtk.Widget));
        text.append(self.detail.as(gtk.Widget));
        self.cancel.as(gtk.Widget).addCssClass("flat");
        self.cancel.as(gtk.Widget).setValign(.center);
        self.cancel.as(gtk.Widget).setTooltipText(common.tr("Cancel"));
        _ = gtk.Button.signals.clicked.connect(self.cancel, *Entry, &onCancel, self, .{});
        self.row.append(text.as(gtk.Widget));
        self.row.append(self.cancel.as(gtk.Widget));
        return self;
    }

    fn free(self: *Entry) void {
        if (self.linger != 0) _ = glib.Source.remove(self.linger);
        if (self.reveal != 0) _ = glib.Source.remove(self.reveal);
        allocator.free(self.dest_name);
        allocator.destroy(self);
    }

    fn onProgress(data: *anyopaque, job: *ops.Job) void {
        const self: *Entry = @ptrCast(@alignCast(data));
        _ = job;
        self.update();
    }

    /// Shows where the job is.
    fn update(self: *Entry) void {
        const job = self.job orelse return;
        const s = job.status();
        const verb = if (s.mode == .copy) "Copying" else "Moving";
        var title_buf: [512]u8 = undefined;
        var detail_buf: [256]u8 = undefined;

        if (s.phase == .counting) {
            self.title.setText(std.fmt.bufPrintSentinel(&title_buf, "Preparing to {s} to \u{201C}{s}\u{201D}", .{
                if (s.mode == .copy) "copy" else "move", self.dest_name,
            }, 0) catch "");
            var size_buf: [64]u8 = undefined;
            self.detail.setText(std.fmt.bufPrintSentinel(&detail_buf, "{d} files, {s} so far", .{
                s.files_total, pure.formatSize(&size_buf, s.bytes_total),
            }, 0) catch "");
            self.bar.pulse();
            return;
        }

        if (s.files_total > 0) {
            self.title.setText(std.fmt.bufPrintSentinel(&title_buf, "{s} {d} {s} to \u{201C}{s}\u{201D}", .{
                verb, s.files_total, if (s.files_total == 1) "file" else "files", self.dest_name,
            }, 0) catch "");
        } else {
            self.title.setText(std.fmt.bufPrintSentinel(&title_buf, "{s} to \u{201C}{s}\u{201D}", .{ verb, self.dest_name }, 0) catch "");
        }

        if (s.bytes_total > 0) {
            self.fraction = @min(1.0, @as(f64, @floatFromInt(s.bytes_done)) / @as(f64, @floatFromInt(s.bytes_total)));
        } else if (s.files_total > 0) {
            self.fraction = @min(1.0, @as(f64, @floatFromInt(s.files_done)) / @as(f64, @floatFromInt(s.files_total)));
        }

        if (s.bytes_total > 0) {
            var done_buf: [64]u8 = undefined;
            var total_buf: [64]u8 = undefined;
            var left_buf: [64]u8 = undefined;
            const left = timeLeft(&left_buf, s);
            self.detail.setText(std.fmt.bufPrintSentinel(&detail_buf, "{s} of {s}{s}{s}", .{
                pure.formatSize(&done_buf, s.bytes_done), pure.formatSize(&total_buf, s.bytes_total),
                if (left.len > 0) " \u{2014} " else "",                                                left,
            }, 0) catch "");
            self.bar.setFraction(self.fraction);
        } else if (s.files_total > 0) {
            self.detail.setText(std.fmt.bufPrintSentinel(&detail_buf, "{d} of {d} files", .{ s.files_done, s.files_total }, 0) catch "");
            self.bar.setFraction(self.fraction);
        } else {
            // A remote source: not counted first, so no total.
            self.detail.setText(std.fmt.bufPrintSentinel(&detail_buf, "{d} files done", .{s.files_done}, 0) catch "");
            self.bar.pulse();
        }
        self.indicator.pie.as(gtk.Widget).queueDraw();
    }

    /// "2 minutes left", once the rate has settled (after 2 s); else "".
    fn timeLeft(buf: []u8, s: ops.Status) []const u8 {
        if (s.elapsed_us < 2_000_000 or s.bytes_done == 0 or s.bytes_done >= s.bytes_total) return "";
        const rate = @as(f64, @floatFromInt(s.bytes_done)) / (@as(f64, @floatFromInt(s.elapsed_us)) / 1e6);
        const seconds: u64 = @intFromFloat(@as(f64, @floatFromInt(s.bytes_total - s.bytes_done)) / rate);
        return pure.formatTimeLeft(buf, seconds);
    }

    fn onFinished(data: *anyopaque, cancelled: bool, final: ops.Status) void {
        const self: *Entry = @ptrCast(@alignCast(data));
        self.job = null;
        if (self.reveal != 0) _ = glib.Source.remove(self.reveal);
        self.reveal = 0;
        var title_buf: [512]u8 = undefined;
        const verb = if (final.mode == .copy) "Copied" else "Moved";
        if (cancelled) {
            self.title.setText(common.tr("Cancelled"));
        } else {
            self.title.setText(std.fmt.bufPrintSentinel(&title_buf, "{s} {d} {s} to \u{201C}{s}\u{201D}", .{
                verb, final.files_done, if (final.files_done == 1) "file" else "files", self.dest_name,
            }, 0) catch "");
            self.bar.setFraction(1);
        }
        self.detail.setText("");
        self.cancel.as(gtk.Widget).setVisible(0);
        self.indicator.pie.as(gtk.Widget).queueDraw();
        self.linger = glib.timeoutAdd(linger_ms, onLinger, self);
    }

    fn onLinger(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Entry = @ptrCast(@alignCast(data.?));
        self.linger = 0;
        self.indicator.remove(self);
        return 0;
    }

    /// A long operation opens the list once, so it is not missed.
    fn onReveal(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Entry = @ptrCast(@alignCast(data.?));
        self.reveal = 0;
        if (self.job != null and self.indicator.button.as(gtk.Widget).getMapped() != 0) self.indicator.popover.popup();
        return 0;
    }

    fn onCancel(_: *gtk.Button, self: *Entry) callconv(.c) void {
        if (self.job) |job| job.cancel();
    }
};
