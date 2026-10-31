//! dkde-pdf: a PDF viewer on poppler-glib (SPEC.md 5.6). Pages are drawn one
//! column, rendered on demand and cached; zoom, fit modes, go to page, text
//! search with highlights, and copying a page's text. Built with `-Dpdf=true`.

const std = @import("std");
const cairo = @import("cairo1");
const gdk = @import("gdk4");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

const layout_mod = @import("layout.zig");
const pop = @import("poppler.zig");

pub const std_options: std.Options = .{ .logFn = common.log.logFn, .log_level = .debug };

const gap = 12.0;
const margin = 16.0;
const cache_size = 6;

const Fit = enum { custom, width, page };

const Match = struct { page: usize, rect: pop.Rectangle };

const CacheEntry = struct { page: usize = std.math.maxInt(usize), zoom: f64 = 0, surface: ?*cairo.Surface = null };

const Viewer = struct {
    allocator: std.mem.Allocator,
    window: *gtk.ApplicationWindow,
    scroller: *gtk.ScrolledWindow,
    area: *gtk.DrawingArea,
    page_spin: *gtk.SpinButton,
    page_total: *gtk.Label,
    zoom_label: *gtk.Label,
    search: *gtk.SearchEntry,
    status: *gtk.Label,

    doc: ?*pop.Document = null,
    path: ?[:0]u8 = null,
    pages: usize = 0,
    page_points: []layout_mod.Size = &.{},
    layout: ?layout_mod.Layout = null,
    zoom: f64 = 1.0,
    fit: Fit = .width,
    cache: [cache_size]CacheEntry = @splat(.{}),
    next_slot: usize = 0,
    /// Set while the page box is updated from scrolling, so that does not scroll again.
    syncing: bool = false,

    needle: ?[:0]u8 = null,
    matches: std.ArrayList(Match) = .empty,
    match_index: usize = 0,

    initial_file: ?[:0]const u8,

    pub fn create(allocator: std.mem.Allocator, app: *gtk.Application) !*Viewer {
        const self = try allocator.create(Viewer);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .window = gtk.ApplicationWindow.new(app),
            .scroller = gtk.ScrolledWindow.new(),
            .area = gtk.DrawingArea.new(),
            .page_spin = gtk.SpinButton.newWithRange(1, 1, 1),
            .page_total = gtk.Label.new("/ 0"),
            .zoom_label = gtk.Label.new("100%"),
            .search = gtk.SearchEntry.new(),
            .status = gtk.Label.new(""),
            .initial_file = initial_path,
        };
        const window = self.window.as(gtk.Window);
        window.setTitle(common.tr("PDF Viewer"));
        window.setDefaultSize(900, 720);
        self.window.as(gtk.Widget).addCssClass("dkde");
        _ = common.header.create(window, "application-pdf", true);

        const mb = common.menubar;
        const menus = [_]mb.Menu{
            .{ .label = "_File", .entries = &.{
                mb.item("_Open…", "open", "<Control>o"),
                mb.item("_Reload", "reload", "F5"),
                .separator,
                mb.item("E_xit", "close", "<Control>q"),
            } },
            .{ .label = "_Edit", .entries = &.{
                mb.item("_Find…", "find", "<Control>f"),
                mb.item("Find _Next", "find-next", "F3"),
                mb.item("Find _Previous", "find-prev", "<Shift>F3"),
                .separator,
                mb.item("Copy page _text", "copy-text", null),
            } },
            .{ .label = "_View", .entries = &.{
                mb.item("Zoom _In", "zoom-in", "<Control>plus"),
                mb.item("Zoom _Out", "zoom-out", "<Control>minus"),
                mb.item("_Actual size", "zoom-100", "<Control>0"),
                .separator,
                mb.item("Fit _width", "fit-width", null),
                mb.item("Fit _page", "fit-page", null),
            } },
            .{ .label = "_Go", .entries = &.{
                mb.item("_First page", "first", "Home"),
                mb.item("_Previous page", "prev", "<Alt>Left"),
                mb.item("_Next page", "next", "<Alt>Right"),
                mb.item("_Last page", "last", "End"),
            } },
        };
        const menu_bar = mb.build(app, self.window, &menus, Viewer, onMenubarAction, self);

        // Toolbar: page, zoom, search.
        const toolbar = gtk.Box.new(.horizontal, 8);
        toolbar.as(gtk.Widget).setMarginStart(8);
        toolbar.as(gtk.Widget).setMarginEnd(8);
        toolbar.as(gtk.Widget).setMarginTop(4);
        toolbar.as(gtk.Widget).setMarginBottom(4);
        _ = gtk.SpinButton.signals.value_changed.connect(self.page_spin, *Viewer, &onPageSpin, self, .{});
        toolbar.append(gtk.Label.new(common.tr("Page")).as(gtk.Widget));
        toolbar.append(self.page_spin.as(gtk.Widget));
        toolbar.append(self.page_total.as(gtk.Widget));
        const spacer = gtk.Box.new(.horizontal, 0);
        spacer.as(gtk.Widget).setHexpand(1);
        toolbar.append(spacer.as(gtk.Widget));
        toolbar.append(self.zoomButton("\u{2212}", common.tr("Zoom out"), onZoomOut));
        toolbar.append(self.zoom_label.as(gtk.Widget));
        toolbar.append(self.zoomButton("+", common.tr("Zoom in"), onZoomIn));
        self.search.setPlaceholderText(common.tr("Search"));
        self.search.as(gtk.Widget).setSizeRequest(200, -1);
        _ = gtk.SearchEntry.signals.activate.connect(self.search, *Viewer, &onSearchActivate, self, .{});
        _ = gtk.SearchEntry.signals.next_match.connect(self.search, *Viewer, &onNextMatch, self, .{});
        _ = gtk.SearchEntry.signals.previous_match.connect(self.search, *Viewer, &onPrevMatch, self, .{});
        toolbar.append(self.search.as(gtk.Widget));

        self.area.as(gtk.Widget).setHalign(.fill);
        self.area.as(gtk.Widget).setFocusable(1);
        self.area.setDrawFunc(onDraw, self, null);
        self.scroller.setChild(self.area.as(gtk.Widget));
        self.scroller.as(gtk.Widget).setVexpand(1);
        self.scroller.as(gtk.Widget).addCssClass("dkde-pdf-scroller");
        _ = gtk.Adjustment.signals.value_changed.connect(self.scroller.getVadjustment(), *Viewer, &onScrolled, self, .{});
        _ = gtk.DrawingArea.signals.resize.connect(self.area, *Viewer, &onResize, self, .{});

        const zoom_keys = gtk.EventControllerScroll.new(.{ .vertical = true });
        _ = gtk.EventControllerScroll.signals.scroll.connect(zoom_keys, *Viewer, &onScrollEvent, self, .{});
        self.area.as(gtk.Widget).addController(zoom_keys.as(gtk.EventController));

        self.status.setXalign(0);
        self.status.as(gtk.Widget).setMarginStart(8);
        self.status.as(gtk.Widget).setMarginTop(2);
        self.status.as(gtk.Widget).setMarginBottom(2);
        self.status.as(gtk.Widget).addCssClass("dkde-files-status");

        const root = gtk.Box.new(.vertical, 0);
        root.append(menu_bar.as(gtk.Widget));
        root.append(toolbar.as(gtk.Widget));
        root.append(self.scroller.as(gtk.Widget));
        root.append(self.status.as(gtk.Widget));
        window.setChild(root.as(gtk.Widget));

        _ = gtk.Widget.signals.destroy.connect(self.window, *Viewer, &onDestroy, self, .{});
        return self;
    }

    pub fn present(self: *Viewer) void {
        self.window.as(gtk.Window).present();
        if (self.initial_file) |p| self.openPath(p, null);
    }

    fn zoomButton(self: *Viewer, icon: [:0]const u8, tip: [:0]const u8, comptime handler: fn (*gtk.Button, *Viewer) callconv(.c) void) *gtk.Widget {
        const b = gtk.Button.newWithLabel(icon);
        b.as(gtk.Widget).setTooltipText(tip);
        _ = gtk.Button.signals.clicked.connect(b, *Viewer, &handler, self, .{});
        return b.as(gtk.Widget);
    }

    fn onDestroy(_: *gtk.ApplicationWindow, self: *Viewer) callconv(.c) void {
        self.closeDocument();
        if (self.path) |p| self.allocator.free(p);
        if (self.needle) |n| self.allocator.free(n);
        self.matches.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    // ---- documents ------------------------------------------------------------------------------

    fn closeDocument(self: *Viewer) void {
        self.dropCache();
        if (self.layout) |*l| l.deinit(self.allocator);
        self.layout = null;
        if (self.doc) |d| pop.unref(d);
        self.doc = null;
        self.allocator.free(self.page_points);
        self.page_points = &.{};
        self.pages = 0;
        self.matches.clearRetainingCapacity();
    }

    fn dropCache(self: *Viewer) void {
        for (&self.cache) |*e| {
            if (e.surface) |s| s.destroy();
            e.* = .{};
        }
    }

    pub fn openPath(self: *Viewer, path: [:0]const u8, password: ?[:0]const u8) void {
        var err: ?*glib.Error = null;
        const uri = glib.filenameToUri(path, null, &err) orelse {
            if (err) |e| e.free();
            return;
        };
        defer glib.free(uri);
        const doc = pop.newFromFile(uri, if (password) |p| p.ptr else null, &err) orelse {
            if (err) |e| {
                defer e.free();
                if (e.f_code == pop.error_encrypted) return self.askPassword(path);
                common.dialogs.showError(self.window.as(gtk.Window), common.tr("Cannot open the file"), std.mem.span(e.f_message orelse "unknown error"));
            }
            return;
        };
        self.closeDocument();
        self.doc = doc;
        const count: usize = @intCast(@max(0, pop.pageCount(doc)));
        self.pages = count;
        self.page_points = self.allocator.alloc(layout_mod.Size, count) catch return;
        for (0..count) |i| {
            var w: f64 = 612;
            var h: f64 = 792;
            if (pop.getPage(doc, @intCast(i))) |page| {
                pop.pageSize(page, &w, &h);
                pop.unref(page);
            }
            self.page_points[i] = .{ .w = w, .h = h };
        }
        const owned = self.allocator.dupeSentinel(u8, path, 0) catch return;
        if (self.path) |old| self.allocator.free(old);
        self.path = owned;

        self.syncing = true;
        self.page_spin.setRange(1, @floatFromInt(@max(1, count)));
        self.page_spin.setValue(1);
        self.syncing = false;
        var buf: [32]u8 = undefined;
        self.page_total.setText(std.fmt.bufPrintSentinel(&buf, "/ {d}", .{count}, 0) catch "");
        if (pop.title(doc)) |t| {
            defer glib.free(t);
            var tbuf: [320]u8 = undefined;
            if (std.mem.span(t).len > 0) self.window.as(gtk.Window).setTitle(std.fmt.bufPrintSentinel(&tbuf, "{s} \u{2014} PDF Viewer", .{std.mem.span(t)}, 0) catch "PDF Viewer");
        } else {
            var tbuf: [320]u8 = undefined;
            self.window.as(gtk.Window).setTitle(std.fmt.bufPrintSentinel(&tbuf, "{s} \u{2014} PDF Viewer", .{std.fs.path.basename(path)}, 0) catch "PDF Viewer");
        }
        self.fit = .width;
        self.relayout();
        self.scroller.getVadjustment().setValue(0);
        self.updateStatus();
        // Dev aid: run a search at once, for screenshots.
        if (glib.getenv("DKDE_DEBUG_SEARCH")) |t| self.runSearch(std.mem.span(t));
    }

    // ---- password ----------------------------------------------------------------------------------

    const Ask = struct { viewer: *Viewer, dialog: *gtk.Window, entry: *gtk.PasswordEntry, path: [:0]u8 };

    fn askPassword(self: *Viewer, path: [:0]const u8) void {
        const dialog = gtk.Window.new();
        dialog.setTitle(common.tr("Password required"));
        dialog.setTransientFor(self.window.as(gtk.Window));
        dialog.setModal(1);
        dialog.setDefaultSize(340, -1);
        dialog.as(gtk.Widget).addCssClass("dkde");
        const box = gtk.Box.new(.vertical, 8);
        box.as(gtk.Widget).setMarginTop(16);
        box.as(gtk.Widget).setMarginBottom(16);
        box.as(gtk.Widget).setMarginStart(16);
        box.as(gtk.Widget).setMarginEnd(16);
        dialog.setChild(box.as(gtk.Widget));
        const label = gtk.Label.new(common.tr("This document is protected. Enter its password."));
        label.setWrap(1);
        label.setXalign(0);
        box.append(label.as(gtk.Widget));
        const entry = gtk.PasswordEntry.new();
        entry.setShowPeekIcon(1);
        box.append(entry.as(gtk.Widget));
        const row = gtk.Box.new(.horizontal, 8);
        row.as(gtk.Widget).setHalign(.end);
        const cancel = gtk.Button.newWithLabel(common.tr("Cancel"));
        const ok = gtk.Button.newWithLabel(common.tr("Open"));
        ok.as(gtk.Widget).addCssClass("suggested-action");
        row.append(cancel.as(gtk.Widget));
        row.append(ok.as(gtk.Widget));
        box.append(row.as(gtk.Widget));

        const ask = self.allocator.create(Ask) catch return;
        ask.* = .{ .viewer = self, .dialog = dialog, .entry = entry, .path = self.allocator.dupeSentinel(u8, path, 0) catch return };
        _ = gtk.Button.signals.clicked.connect(cancel, *Ask, &onAskCancel, ask, .{});
        _ = gtk.Button.signals.clicked.connect(ok, *Ask, &onAskOk, ask, .{});
        _ = gtk.PasswordEntry.signals.activate.connect(entry, *Ask, &onAskActivate, ask, .{});
        _ = gtk.Widget.signals.destroy.connect(dialog, *Ask, &onAskDestroy, ask, .{});
        dialog.present();
    }

    fn onAskCancel(_: *gtk.Button, ask: *Ask) callconv(.c) void {
        ask.dialog.destroy();
    }

    fn onAskDestroy(_: *gtk.Window, ask: *Ask) callconv(.c) void {
        ask.viewer.allocator.free(ask.path);
        ask.viewer.allocator.destroy(ask);
    }

    fn submitPassword(ask: *Ask) void {
        const password = ask.viewer.allocator.dupeSentinel(u8, std.mem.span(ask.entry.as(gtk.Editable).getText()), 0) catch return;
        defer {
            // Do not leave the password lying around in freed memory.
            @memset(password, 0);
            ask.viewer.allocator.free(password);
        }
        const viewer = ask.viewer;
        const path = viewer.allocator.dupeSentinel(u8, ask.path, 0) catch return;
        defer viewer.allocator.free(path);
        ask.dialog.destroy();
        viewer.openPath(path, password);
    }

    fn onAskOk(_: *gtk.Button, ask: *Ask) callconv(.c) void {
        submitPassword(ask);
    }

    fn onAskActivate(_: *gtk.PasswordEntry, ask: *Ask) callconv(.c) void {
        submitPassword(ask);
    }

    // ---- layout and zoom -------------------------------------------------------------------------

    fn scale(self: *const Viewer) f64 {
        return self.zoom * 96.0 / 72.0;
    }

    fn relayout(self: *Viewer) void {
        if (self.pages == 0) return;
        const avail_w = @as(f64, @floatFromInt(self.scroller.as(gtk.Widget).getWidth())) - 2 * margin - 16;
        const avail_h = @as(f64, @floatFromInt(self.scroller.as(gtk.Widget).getHeight())) - 2 * margin;
        const first = self.page_points[0];
        switch (self.fit) {
            .width => if (avail_w > 50) {
                self.zoom = layout_mod.fitWidth(first.w, avail_w);
            },
            .page => if (avail_w > 50 and avail_h > 50) {
                self.zoom = layout_mod.fitPage(first.w, first.h, avail_w, avail_h);
            },
            .custom => {},
        }
        self.dropCache();
        if (self.layout) |*l| l.deinit(self.allocator);
        self.layout = layout_mod.compute(self.allocator, self.page_points, self.scale(), gap, margin) catch null;
        if (self.layout) |l| {
            self.area.setContentWidth(@intFromFloat(l.max_width + 2 * margin));
            self.area.setContentHeight(@intFromFloat(l.total_height));
        }
        var buf: [16]u8 = undefined;
        self.zoom_label.setText(std.fmt.bufPrintSentinel(&buf, "{d:.0}%", .{self.zoom * 100}, 0) catch "");
        self.area.as(gtk.Widget).queueDraw();
    }

    fn onResize(_: *gtk.DrawingArea, _: c_int, _: c_int, self: *Viewer) callconv(.c) void {
        if (self.fit != .custom) self.relayout();
    }

    fn setZoom(self: *Viewer, zoom: f64) void {
        // Keep the page that is at the top of the view there.
        const page = self.currentPage();
        self.fit = .custom;
        self.zoom = std.math.clamp(zoom, 0.1, 8.0);
        self.relayout();
        self.scrollToPage(page);
    }

    fn onZoomIn(_: *gtk.Button, self: *Viewer) callconv(.c) void {
        self.setZoom(layout_mod.stepZoom(self.zoom, true));
    }

    fn onZoomOut(_: *gtk.Button, self: *Viewer) callconv(.c) void {
        self.setZoom(layout_mod.stepZoom(self.zoom, false));
    }

    fn onScrollEvent(ctrl: *gtk.EventControllerScroll, _: f64, dy: f64, self: *Viewer) callconv(.c) c_int {
        if (!ctrl.as(gtk.EventController).getCurrentEventState().control_mask) return 0;
        self.setZoom(layout_mod.stepZoom(self.zoom, dy < 0));
        return 1;
    }

    // ---- pages ------------------------------------------------------------------------------------

    fn viewTop(self: *const Viewer) f64 {
        return self.scroller.getVadjustment().getValue();
    }

    fn currentPage(self: *const Viewer) usize {
        const l = self.layout orelse return 0;
        const h = self.scroller.getVadjustment().getPageSize();
        return layout_mod.pageAt(l, self.viewTop() + h / 3);
    }

    fn scrollToPage(self: *Viewer, page: usize) void {
        const l = self.layout orelse return;
        if (page >= l.tops.len) return;
        self.scroller.getVadjustment().setValue(l.tops[page] - margin / 2);
    }

    fn onPageSpin(button: *gtk.SpinButton, self: *Viewer) callconv(.c) void {
        if (self.syncing) return;
        const page: usize = @intCast(@max(1, button.getValueAsInt()));
        self.scrollToPage(page - 1);
    }

    fn onScrolled(_: *gtk.Adjustment, self: *Viewer) callconv(.c) void {
        self.syncing = true;
        self.page_spin.setValue(@floatFromInt(self.currentPage() + 1));
        self.syncing = false;
        self.area.as(gtk.Widget).queueDraw();
    }

    fn updateStatus(self: *Viewer) void {
        var buf: [160]u8 = undefined;
        if (self.needle != null) {
            self.status.setText(std.fmt.bufPrintSentinel(&buf, "{d} matches", .{self.matches.items.len}, 0) catch "");
        } else self.status.setText("");
    }

    // ---- drawing -------------------------------------------------------------------------------------

    fn cached(self: *Viewer, index: usize) ?*cairo.Surface {
        const doc = self.doc orelse return null;
        for (self.cache) |e| if (e.page == index and e.zoom == self.zoom) return e.surface;
        const l = self.layout orelse return null;
        const size = l.sizes[index];
        const page = pop.getPage(doc, @intCast(index)) orelse return null;
        defer pop.unref(page);
        const surface = cairo.Surface.imageCreate(.argb32, @intFromFloat(size.w), @intFromFloat(size.h));
        const cr = cairo.Context.create(surface);
        defer cr.destroy();
        cr.setSourceRgb(1, 1, 1);
        cr.paint();
        cr.scale(self.scale(), self.scale());
        pop.render(page, cr);

        const slot = &self.cache[self.next_slot];
        self.next_slot = (self.next_slot + 1) % cache_size;
        if (slot.surface) |old| old.destroy();
        slot.* = .{ .page = index, .zoom = self.zoom, .surface = surface };
        return surface;
    }

    fn onDraw(_: *gtk.DrawingArea, cr: *cairo.Context, width: c_int, _: c_int, data: ?*anyopaque) callconv(.c) void {
        const self: *Viewer = @ptrCast(@alignCast(data.?));
        const l = self.layout orelse return;
        const adj = self.scroller.getVadjustment();
        const range = layout_mod.visibleRange(l, adj.getValue() - 50, adj.getValue() + adj.getPageSize() + 50);
        const w: f64 = @floatFromInt(width);
        for (range[0]..@min(range[1], l.tops.len)) |i| {
            const size = l.sizes[i];
            const x = @max(0, (w - size.w) / 2);
            const y = l.tops[i];
            // A soft shadow, then the page.
            cr.setSourceRgba(0, 0, 0, 0.25);
            cr.rectangle(x + 2, y + 2, size.w, size.h);
            cr.fill();
            const surface = self.cached(i) orelse continue;
            cr.setSourceSurface(surface, x, y);
            cr.paint();
            self.drawMatches(cr, i, x, y, size.h);
        }
    }

    fn drawMatches(self: *Viewer, cr: *cairo.Context, page: usize, x: f64, y: f64, page_h: f64) void {
        const s = self.scale();
        for (self.matches.items, 0..) |m, idx| {
            if (m.page != page) continue;
            // Poppler's y axis points up from the bottom of the page.
            const top = page_h - m.rect.y2 * s;
            cr.setSourceRgba(1, if (idx == self.match_index) 0.55 else 0.9, 0, if (idx == self.match_index) 0.55 else 0.4);
            cr.rectangle(x + m.rect.x1 * s, y + top, (m.rect.x2 - m.rect.x1) * s, (m.rect.y2 - m.rect.y1) * s);
            cr.fill();
        }
    }

    // ---- search ------------------------------------------------------------------------------------

    fn onSearchActivate(entry: *gtk.SearchEntry, self: *Viewer) callconv(.c) void {
        const text = std.mem.span(entry.as(gtk.Editable).getText());
        if (self.needle) |n| if (std.mem.eql(u8, n, text)) return self.step(true);
        self.runSearch(text);
    }

    fn onNextMatch(_: *gtk.SearchEntry, self: *Viewer) callconv(.c) void {
        self.step(true);
    }

    fn onPrevMatch(_: *gtk.SearchEntry, self: *Viewer) callconv(.c) void {
        self.step(false);
    }

    fn runSearch(self: *Viewer, text: []const u8) void {
        self.matches.clearRetainingCapacity();
        if (self.needle) |n| self.allocator.free(n);
        self.needle = null;
        self.match_index = 0;
        const doc = self.doc orelse return;
        if (text.len == 0) return self.area.as(gtk.Widget).queueDraw();
        const z = self.allocator.dupeSentinel(u8, text, 0) catch return;
        self.needle = z;
        var rects: [64]pop.Rectangle = undefined;
        for (0..self.pages) |i| {
            const page = pop.getPage(doc, @intCast(i)) orelse continue;
            defer pop.unref(page);
            const n = pop.find(page, z, &rects);
            for (rects[0..n]) |r| self.matches.append(self.allocator, .{ .page = i, .rect = r }) catch {};
        }
        self.updateStatus();
        if (self.matches.items.len > 0) {
            // Start from the first match at or after the current page.
            const here = self.currentPage();
            for (self.matches.items, 0..) |m, i| if (m.page >= here) {
                self.match_index = i;
                break;
            };
            self.showMatch();
        } else self.area.as(gtk.Widget).queueDraw();
    }

    fn step(self: *Viewer, forward: bool) void {
        const count = self.matches.items.len;
        if (count == 0) return;
        self.match_index = if (forward) (self.match_index + 1) % count else (self.match_index + count - 1) % count;
        self.showMatch();
    }

    fn showMatch(self: *Viewer) void {
        const l = self.layout orelse return;
        const m = self.matches.items[self.match_index];
        const top = l.tops[m.page] + l.sizes[m.page].h - m.rect.y2 * self.scale();
        const adj = self.scroller.getVadjustment();
        // Only scroll when the match is out of view, and keep some context above it.
        if (top < adj.getValue() or top > adj.getValue() + adj.getPageSize() - 60) adj.setValue(top - adj.getPageSize() / 3);
        var buf: [64]u8 = undefined;
        self.status.setText(std.fmt.bufPrintSentinel(&buf, "Match {d} of {d}", .{ self.match_index + 1, self.matches.items.len }, 0) catch "");
        self.area.as(gtk.Widget).queueDraw();
    }

    // ---- menu -----------------------------------------------------------------------------------------

    fn onOpenChosen(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Viewer = @ptrCast(@alignCast(data.?));
        const dialog: *gtk.FileDialog = @ptrCast(@alignCast(source.?));
        var err: ?*glib.Error = null;
        const file = dialog.openFinish(result, &err) orelse {
            if (err) |e| e.free();
            return;
        };
        defer file.as(gobject.Object).unref();
        const path = file.getPath() orelse return;
        defer glib.free(path);
        self.openPath(std.mem.span(path), null);
    }

    fn onMenubarAction(self: *Viewer, action: []const u8) void {
        const eql = std.mem.eql;
        if (eql(u8, action, "open")) {
            const dialog = gtk.FileDialog.new();
            defer dialog.as(gobject.Object).unref();
            return dialog.open(self.window.as(gtk.Window), null, onOpenChosen, self);
        }
        if (eql(u8, action, "reload")) {
            const path = self.path orelse return;
            const copy = self.allocator.dupeSentinel(u8, path, 0) catch return;
            defer self.allocator.free(copy);
            return self.openPath(copy, null);
        }
        if (eql(u8, action, "close")) return self.window.as(gtk.Window).close();
        if (eql(u8, action, "find")) return self.focusSearch();
        if (eql(u8, action, "find-next")) return self.step(true);
        if (eql(u8, action, "find-prev")) return self.step(false);
        if (eql(u8, action, "copy-text")) return self.copyPageText();
        if (eql(u8, action, "zoom-in")) return self.setZoom(layout_mod.stepZoom(self.zoom, true));
        if (eql(u8, action, "zoom-out")) return self.setZoom(layout_mod.stepZoom(self.zoom, false));
        if (eql(u8, action, "zoom-100")) return self.setZoom(1.0);
        if (eql(u8, action, "fit-width")) {
            self.fit = .width;
            return self.relayout();
        }
        if (eql(u8, action, "fit-page")) {
            self.fit = .page;
            return self.relayout();
        }
        if (eql(u8, action, "first")) return self.scrollToPage(0);
        if (eql(u8, action, "last")) return self.scrollToPage(self.pages -| 1);
        if (eql(u8, action, "prev")) return self.scrollToPage(self.currentPage() -| 1);
        if (eql(u8, action, "next")) return self.scrollToPage(@min(self.pages -| 1, self.currentPage() + 1));
    }

    fn focusSearch(self: *Viewer) void {
        _ = self.search.as(gtk.Widget).grabFocus();
    }

    fn copyPageText(self: *Viewer) void {
        const doc = self.doc orelse return;
        const page = pop.getPage(doc, @intCast(self.currentPage())) orelse return;
        defer pop.unref(page);
        const text = pop.pageText(page) orelse return;
        defer glib.free(text);
        self.window.as(gtk.Widget).getClipboard().setText(text);
        self.status.setText(common.tr("Copied the text of this page."));
    }
};

/// The file named on the command line, if any.
var initial_path: ?[:0]const u8 = null;

pub fn main(init: std.process.Init.Minimal) !void {
    if (init.args.vector.len > 1) initial_path = std.mem.span(init.args.vector[1]);
    try common.runapp.run("org.dkde.pdf", Viewer, init);
}

test {
    _ = @import("layout.zig");
}
