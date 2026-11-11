//! dkde-pdf: a PDF viewer and annotator on pdf-zig (SPEC.md 5.6, ai/DKDE-SPEC.md 20.1).
//!
//! Pages are drawn one column, rendered on demand and cached. You can zoom,
//! search (matches are highlighted), select text with the mouse and copy it,
//! follow the document's bookmarks and add your own, highlight, underline and
//! strike out text, put notes on a page, and fill in form fields.
//!
//! Everything you add is written into the PDF as standard annotations,
//! bookmarks and field values, as a new revision at the end of the file, so
//! other PDF programs show it and the original content is never rewritten.
//! Edits can be undone until the file is saved.

const std = @import("std");
const cli = @import("cli");
const cairo = @import("cairo1");
const gdk = @import("gdk4");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");
const pdf = @import("pdf");

const layout_mod = @import("layout.zig");
const render = @import("pdfrender");
const session_mod = @import("session.zig");
const Session = session_mod.Session;

pub const std_options: std.Options = .{ .logFn = common.log.logFn, .log_level = .debug };

const gap = 12.0;
const margin = 16.0;
const cache_size = 6;

const Fit = enum { custom, width, page };

/// The printer and options chosen last, for the next print in this session.
var print_settings: ?*gtk.PrintSettings = null;

/// One occurrence of the searched text: a byte range in the page's layout text.
const Match = struct { page: usize, start: u32, end: u32 };

const CacheEntry = struct { page: usize = std.math.maxInt(usize), zoom: f64 = 0, surface: ?*cairo.Surface = null, generation: u32 = 0 };

/// A bookmark row of the sidebar.
const Row = struct { item: pdf.outline.Item, depth: usize, expanded: bool };

const Action = enum {
    copy,
    highlight,
    underline,
    strikeout,
    add_note,
    edit_note,
    delete_annotation,
    add_bookmark_here,
    pick_choice,
};

/// What a menu button or a dialog needs to remember.
const Act = struct {
    viewer: *DocView,
    action: Action,
    page: usize = 0,
    x: f64 = 0,
    y: f64 = 0,
    num: u32 = 0,
    /// Field name and chosen value, for `pick_choice`.
    text: ?[:0]u8 = null,
};

const DocView = struct {
    allocator: std.mem.Allocator,
    host: *Window,
    // Shared with the window: the toolbar and status line show the active tab.
    window: *gtk.ApplicationWindow,
    scroller: *gtk.ScrolledWindow,
    area: *gtk.DrawingArea,
    page_spin: *gtk.SpinButton,
    page_total: *gtk.Label,
    zoom_label: *gtk.Label,
    search: *gtk.SearchEntry,
    status: *gtk.Label,
    paned: *gtk.Paned,
    sidebar: *gtk.Box,
    sidebar_list: *gtk.ListBox,
    diag: render.Diag,

    session: ?*Session = null,
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

    // Selection: a byte range of one page's text. `anchor` is where the drag began.
    sel_page: ?usize = null,
    sel_start: u32 = 0,
    sel_end: u32 = 0,
    anchor: u32 = 0,
    dragging: bool = false,
    drag_x: f64 = 0,
    drag_y: f64 = 0,
    drag_moved: bool = false,

    // Bookmarks and form fields, read from the document and reread after every edit.
    outline_arena: ?std.heap.ArenaAllocator = null,
    rows: std.ArrayList(Row) = .empty,
    expanded: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// Items whose open state the user has changed: the document's own default no longer applies.
    expanded_touched: std.AutoHashMapUnmanaged(u32, void) = .empty,
    field_arena: ?std.heap.ArenaAllocator = null,
    fields: []pdf.form.Field = &.{},
    fields_generation: u32 = std.math.maxInt(u32),
    show_fields: bool = true,

    author: [:0]const u8,

    fn create(allocator: std.mem.Allocator, host: *Window) !*DocView {
        const self = try allocator.create(DocView);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .host = host,
            .window = host.window,
            .scroller = gtk.ScrolledWindow.new(),
            .area = gtk.DrawingArea.new(),
            .page_spin = host.page_spin,
            .page_total = host.page_total,
            .zoom_label = host.zoom_label,
            .search = host.search,
            .status = host.status,
            .paned = gtk.Paned.new(.horizontal),
            .sidebar = gtk.Box.new(.vertical, 0),
            .sidebar_list = gtk.ListBox.new(),
            .diag = render.Diag.init(allocator),
            .author = std.mem.span(glib.getRealName()),
        };
        // The page column.
        self.area.as(gtk.Widget).setHalign(.fill);
        self.area.as(gtk.Widget).setFocusable(1);
        self.area.setDrawFunc(onDraw, self, null);
        self.scroller.setChild(self.area.as(gtk.Widget));
        self.scroller.as(gtk.Widget).setVexpand(1);
        self.scroller.as(gtk.Widget).setHexpand(1);
        self.scroller.as(gtk.Widget).addCssClass("dkde-pdf-scroller");
        _ = gtk.Adjustment.signals.value_changed.connect(self.scroller.getVadjustment(), *DocView, &onScrolled, self, .{});
        _ = gtk.DrawingArea.signals.resize.connect(self.area, *DocView, &onResize, self, .{});

        const zoom_keys = gtk.EventControllerScroll.new(.{ .vertical = true });
        _ = gtk.EventControllerScroll.signals.scroll.connect(zoom_keys, *DocView, &onScrollEvent, self, .{});
        self.area.as(gtk.Widget).addController(zoom_keys.as(gtk.EventController));

        const drag = gtk.GestureDrag.new();
        drag.as(gtk.GestureSingle).setButton(1);
        _ = gtk.GestureDrag.signals.drag_begin.connect(drag, *DocView, &onDragBegin, self, .{});
        _ = gtk.GestureDrag.signals.drag_update.connect(drag, *DocView, &onDragUpdate, self, .{});
        _ = gtk.GestureDrag.signals.drag_end.connect(drag, *DocView, &onDragEnd, self, .{});
        self.area.as(gtk.Widget).addController(drag.as(gtk.EventController));
        const multi = gtk.GestureClick.new();
        multi.as(gtk.GestureSingle).setButton(1);
        _ = gtk.GestureClick.signals.pressed.connect(multi, *DocView, &onMultiClick, self, .{});
        self.area.as(gtk.Widget).addController(multi.as(gtk.EventController));
        const right = gtk.GestureClick.new();
        right.as(gtk.GestureSingle).setButton(3);
        _ = gtk.GestureClick.signals.pressed.connect(right, *DocView, &onRightClick, self, .{});
        self.area.as(gtk.Widget).addController(right.as(gtk.EventController));

        // The bookmarks sidebar.
        const side_scroller = gtk.ScrolledWindow.new();
        side_scroller.setChild(self.sidebar_list.as(gtk.Widget));
        side_scroller.as(gtk.Widget).setVexpand(1);
        self.sidebar_list.setSelectionMode(.single);
        _ = gtk.ListBox.signals.row_activated.connect(self.sidebar_list, *DocView, &onRowActivated, self, .{});
        const side_title = gtk.Label.new(common.tr("Bookmarks"));
        side_title.setXalign(0);
        side_title.as(gtk.Widget).setMarginStart(8);
        side_title.as(gtk.Widget).setMarginTop(6);
        side_title.as(gtk.Widget).addCssClass("heading");
        const side_buttons = gtk.Box.new(.horizontal, 4);
        side_buttons.as(gtk.Widget).setMarginStart(4);
        side_buttons.as(gtk.Widget).setMarginEnd(4);
        side_buttons.as(gtk.Widget).setMarginTop(4);
        side_buttons.as(gtk.Widget).setMarginBottom(4);
        const add_bm = gtk.Button.newWithLabel(common.tr("Add"));
        add_bm.as(gtk.Widget).setTooltipText(common.tr("Bookmark the page you are looking at"));
        const remove_bm = gtk.Button.newWithLabel(common.tr("Remove"));
        remove_bm.as(gtk.Widget).setTooltipText(common.tr("Remove the selected bookmark"));
        _ = gtk.Button.signals.clicked.connect(add_bm, *DocView, &onAddBookmarkClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(remove_bm, *DocView, &onRemoveBookmarkClicked, self, .{});
        side_buttons.append(add_bm.as(gtk.Widget));
        side_buttons.append(remove_bm.as(gtk.Widget));
        self.sidebar.append(side_title.as(gtk.Widget));
        self.sidebar.append(side_scroller.as(gtk.Widget));
        self.sidebar.append(side_buttons.as(gtk.Widget));
        self.sidebar.as(gtk.Widget).setSizeRequest(230, -1);
        self.sidebar.as(gtk.Widget).setVisible(0);

        self.paned.setStartChild(self.sidebar.as(gtk.Widget));
        self.paned.setEndChild(self.scroller.as(gtk.Widget));
        self.paned.setShrinkStartChild(0);
        self.paned.setResizeStartChild(0);
        self.paned.as(gtk.Widget).setVexpand(1);

        return self;
    }

    /// The widget the notebook shows for this tab.
    fn widget(self: *DocView) *gtk.Widget {
        return self.paned.as(gtk.Widget);
    }

    fn isActive(self: *const DocView) bool {
        const a = self.host.active() orelse return false;
        return a == self;
    }

    fn isDirty(self: *const DocView) bool {
        const s = self.session orelse return false;
        return s.dirty();
    }

    /// Frees everything the tab owns (its widgets go with the notebook page).
    fn deinit(self: *DocView) void {
        self.closeDocument();
        if (self.path) |p| self.allocator.free(p);
        if (self.needle) |n| self.allocator.free(n);
        self.matches.deinit(self.allocator);
        self.rows.deinit(self.allocator);
        self.expanded.deinit(self.allocator);
        self.expanded_touched.deinit(self.allocator);
        if (self.outline_arena) |*a| a.deinit();
        if (self.field_arena) |*a| a.deinit();
        self.diag.deinit();
        self.allocator.destroy(self);
    }

    /// Puts this tab's page count, zoom and title in the shared toolbar.
    fn syncToolbar(self: *DocView) void {
        self.syncing = true;
        self.page_spin.setRange(1, @floatFromInt(@max(1, self.pages)));
        self.page_spin.setValue(@floatFromInt(self.currentPage() + 1));
        self.syncing = false;
        var buf: [32]u8 = undefined;
        self.page_total.setText(std.fmt.bufPrintSentinel(&buf, "/ {d}", .{self.pages}, 0) catch "");
        var zb: [16]u8 = undefined;
        self.zoom_label.setText(std.fmt.bufPrintSentinel(&zb, "{d:.0}%", .{self.zoom * 100}, 0) catch "");
        self.updateTitle();
        self.updateStatus();
    }

    // ---- documents ------------------------------------------------------------------------------

    fn closeDocument(self: *DocView) void {
        self.dropCache();
        if (self.layout) |*l| l.deinit(self.allocator);
        self.layout = null;
        if (self.session) |s| s.close();
        self.session = null;
        self.allocator.free(self.page_points);
        self.page_points = &.{};
        self.pages = 0;
        self.matches.clearRetainingCapacity();
        self.clearSelection();
        self.fields = &.{};
        self.fields_generation = std.math.maxInt(u32);
        self.rows.clearRetainingCapacity();
    }

    fn dropCache(self: *DocView) void {
        for (&self.cache) |*e| {
            if (e.surface) |s| s.destroy();
            e.* = .{};
        }
    }

    const OpenResult = enum { opened, failed, password };

    pub fn openPath(self: *DocView, path: [:0]const u8, password: ?[:0]const u8) OpenResult {
        const session = Session.open(self.allocator, path, if (password) |p| p else "") catch |e| {
            const title = common.tr("Cannot open the file");
            switch (e) {
                error.PasswordRequired => {
                    self.askPassword(path);
                    return .password;
                },
                error.FileUnreadable => common.dialogs.showError(self.window.as(gtk.Window), title, common.tr("The file cannot be read.")),
                error.NotPdf => common.dialogs.showError(self.window.as(gtk.Window), title, common.tr("This is not a PDF document, or it is damaged.")),
                error.Unsupported => common.dialogs.showError(self.window.as(gtk.Window), title, common.tr("This document uses encryption that is not supported.")),
                else => common.dialogs.showError(self.window.as(gtk.Window), title, common.tr("Out of memory.")),
            }
            return .failed;
        };
        self.closeDocument();
        self.session = session;
        const count = session.pageCount();
        self.pages = count;
        self.page_points = self.allocator.alloc(layout_mod.Size, count) catch return .failed;
        for (0..count) |i| {
            const size = render.pageSize(session.doc, i);
            self.page_points[i] = if (size) |sz| .{ .w = sz.w, .h = sz.h } else .{ .w = 612, .h = 792 };
        }
        const owned = self.allocator.dupeSentinel(u8, path, 0) catch return .failed;
        if (self.path) |old| self.allocator.free(old);
        self.path = owned;

        self.fit = .width;
        self.relayout();
        self.scroller.getVadjustment().setValue(0);
        if (self.isActive()) self.syncToolbar() else self.updateTitle();
        self.rebuildSidebar();
        if (self.rows.items.len > 0) self.sidebar.as(gtk.Widget).setVisible(1);
        if (!session.canEdit()) self.status.setText(common.tr("This file cannot be edited in place (it is encrypted or was damaged); you can still read it."));
        // Dev aid: run a search at once, for screenshots.
        if (glib.getenv("DKDE_DEBUG_SEARCH")) |t| self.runSearch(std.mem.span(t));
        return .opened;
    }

    fn updateTitle(self: *DocView) void {
        self.host.refreshTitles(self);
    }

    /// Writes the file where it came from. Returns false when it could not.
    fn save(self: *DocView) bool {
        const s = self.session orelse return false;
        const path = self.path orelse return false;
        return self.saveTo(path, s);
    }

    fn saveTo(self: *DocView, path: []const u8, s: *Session) bool {
        common.fsio.writeFileAtomic(path, s.bytes()) catch |err| {
            var buf: [200]u8 = undefined;
            const msg = std.fmt.bufPrintSentinel(&buf, "{s}", .{@errorName(err)}, 0) catch "";
            common.dialogs.showError(self.window.as(gtk.Window), common.tr("Cannot save the file"), msg);
            return false;
        };
        s.markSaved();
        self.updateTitle();
        self.status.setText(common.tr("Saved."));
        return true;
    }

    // ---- password ----------------------------------------------------------------------------------

    const Ask = struct { viewer: *DocView, dialog: *gtk.Window, entry: *gtk.PasswordEntry, path: [:0]u8 };

    fn askPassword(self: *DocView, path: [:0]const u8) void {
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
        _ = viewer.openPath(path, password);
    }

    fn onAskOk(_: *gtk.Button, ask: *Ask) callconv(.c) void {
        submitPassword(ask);
    }

    fn onAskActivate(_: *gtk.PasswordEntry, ask: *Ask) callconv(.c) void {
        submitPassword(ask);
    }

    // ---- layout and zoom -------------------------------------------------------------------------

    fn scale(self: *const DocView) f64 {
        return self.zoom * 96.0 / 72.0;
    }

    fn relayout(self: *DocView) void {
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
        if (self.isActive()) {
            var buf: [16]u8 = undefined;
            self.zoom_label.setText(std.fmt.bufPrintSentinel(&buf, "{d:.0}%", .{self.zoom * 100}, 0) catch "");
        }
        self.area.as(gtk.Widget).queueDraw();
    }

    fn onResize(_: *gtk.DrawingArea, _: c_int, _: c_int, self: *DocView) callconv(.c) void {
        if (self.fit != .custom) self.relayout();
    }

    fn setZoom(self: *DocView, zoom: f64) void {
        // Keep the page that is at the top of the view there.
        const page = self.currentPage();
        self.fit = .custom;
        self.zoom = std.math.clamp(zoom, 0.1, 8.0);
        self.relayout();
        self.scrollToPage(page);
    }


    fn onScrollEvent(ctrl: *gtk.EventControllerScroll, _: f64, dy: f64, self: *DocView) callconv(.c) c_int {
        if (!ctrl.as(gtk.EventController).getCurrentEventState().control_mask) return 0;
        self.setZoom(layout_mod.stepZoom(self.zoom, dy < 0));
        return 1;
    }

    // ---- pages ------------------------------------------------------------------------------------

    fn viewTop(self: *const DocView) f64 {
        return self.scroller.getVadjustment().getValue();
    }

    fn currentPage(self: *const DocView) usize {
        const l = self.layout orelse return 0;
        const h = self.scroller.getVadjustment().getPageSize();
        return layout_mod.pageAt(l, self.viewTop() + h / 3);
    }

    fn scrollToPage(self: *DocView, page: usize) void {
        const l = self.layout orelse return;
        if (page >= l.tops.len) return;
        self.scroller.getVadjustment().setValue(l.tops[page] - margin / 2);
    }

    /// Scrolls so that the point (`x`, `y`) of page `page`, in page points from its top left, is near the top.
    fn scrollToPoint(self: *DocView, page: usize, y: f64) void {
        const l = self.layout orelse return;
        if (page >= l.tops.len) return;
        self.scroller.getVadjustment().setValue(l.tops[page] + y * self.scale() - margin);
    }

    fn gotoPageNumber(self: *DocView, number: c_int) void {
        if (self.syncing) return;
        const page: usize = @intCast(@max(1, number));
        self.scrollToPage(page - 1);
    }

    fn onScrolled(_: *gtk.Adjustment, self: *DocView) callconv(.c) void {
        if (self.isActive()) {
            self.syncing = true;
            self.page_spin.setValue(@floatFromInt(self.currentPage() + 1));
            self.syncing = false;
        }
        self.area.as(gtk.Widget).queueDraw();
    }

    fn updateStatus(self: *DocView) void {
        var buf: [160]u8 = undefined;
        if (self.needle != null) {
            self.status.setText(std.fmt.bufPrintSentinel(&buf, "{d} match(es)", .{self.matches.items.len}, 0) catch "");
        } else self.status.setText("");
    }

    /// Where page `index` is drawn: its left edge in the area.
    fn pageLeft(self: *const DocView, index: usize) f64 {
        const l = self.layout orelse return 0;
        const w: f64 = @floatFromInt(self.area.as(gtk.Widget).getWidth());
        return @max(0, (w - l.sizes[index].w) / 2);
    }

    // ---- drawing -------------------------------------------------------------------------------------

    fn cached(self: *DocView, index: usize) ?*cairo.Surface {
        const s = self.session orelse return null;
        for (self.cache) |e| if (e.page == index and e.zoom == self.zoom and e.generation == s.generation) return e.surface;
        const l = self.layout orelse return null;
        const size = l.sizes[index];
        const surface = cairo.Surface.imageCreate(.argb32, @intFromFloat(size.w), @intFromFloat(size.h));
        const cr = cairo.Context.create(surface);
        defer cr.destroy();
        cr.setSourceRgb(1, 1, 1);
        cr.paint();
        render.renderPage(self.allocator, s.doc, index, cr, self.scale(), &self.diag) catch |e|
            std.log.warn("page {d} not drawn: {s}", .{ index + 1, @errorName(e) });

        const slot = &self.cache[self.next_slot];
        self.next_slot = (self.next_slot + 1) % cache_size;
        if (slot.surface) |old| old.destroy();
        slot.* = .{ .page = index, .zoom = self.zoom, .surface = surface, .generation = s.generation };
        return surface;
    }

    fn onDraw(_: *gtk.DrawingArea, cr: *cairo.Context, width: c_int, _: c_int, data: ?*anyopaque) callconv(.c) void {
        const self: *DocView = @ptrCast(@alignCast(data.?));
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
            self.drawOverlays(cr, i, x, y);
        }
    }

    /// Search matches, the selection and fillable fields, on top of a page.
    fn drawOverlays(self: *DocView, cr: *cairo.Context, page: usize, x: f64, y: f64) void {
        const s = self.session orelse return;
        const sc = self.scale();
        const lay = s.layout(page) catch null;
        var scratch: std.ArrayList(pdf.text.Rect) = .empty;
        defer scratch.deinit(self.allocator);

        if (lay) |ly| {
            for (self.matches.items, 0..) |m, idx| {
                if (m.page != page) continue;
                scratch.clearRetainingCapacity();
                ly.rectsFor(self.allocator, m.start, m.end, &scratch) catch continue;
                const current = idx == self.match_index;
                cr.setSourceRgba(1, if (current) 0.5 else 0.85, 0, if (current) 0.55 else 0.35);
                for (scratch.items) |r| {
                    cr.rectangle(x + r.x0 * sc, y + r.y0 * sc, (r.x1 - r.x0) * sc, (r.y1 - r.y0) * sc);
                    cr.fill();
                }
            }
            if (self.sel_page == page and self.sel_start != self.sel_end) {
                scratch.clearRetainingCapacity();
                ly.rectsFor(self.allocator, self.sel_start, self.sel_end, &scratch) catch {};
                cr.setSourceRgba(0.2, 0.45, 0.95, 0.35);
                for (scratch.items) |r| {
                    cr.rectangle(x + r.x0 * sc, y + r.y0 * sc, (r.x1 - r.x0) * sc, (r.y1 - r.y0) * sc);
                    cr.fill();
                }
            }
        }

        if (self.show_fields) {
            self.ensureFields();
            const p = pdf.pages.page(&s.doc.doc, s.doc.pages, page) orelse return;
            const base = pdf.interp.baseMatrix(p);
            for (self.fields) |f| {
                if (f.kind == .signature or f.kind == .push_button) continue;
                for (f.widgets) |wd| {
                    if (wd.page != page) continue;
                    const a = base.apply(wd.rect.x0, wd.rect.y0);
                    const b = base.apply(wd.rect.x1, wd.rect.y1);
                    const rx = @min(a.x, b.x) * sc;
                    const ry = @min(a.y, b.y) * sc;
                    const rw = @abs(b.x - a.x) * sc;
                    const rh = @abs(b.y - a.y) * sc;
                    cr.setSourceRgba(0.25, 0.5, 1, if (f.read_only) 0.05 else 0.12);
                    cr.rectangle(x + rx, y + ry, rw, rh);
                    cr.fill();
                    cr.setSourceRgba(0.25, 0.5, 1, 0.5);
                    cr.setLineWidth(1);
                    cr.rectangle(x + rx + 0.5, y + ry + 0.5, rw - 1, rh - 1);
                    cr.stroke();
                }
            }
        }
    }

    /// Rereads the form fields when the file has changed.
    fn ensureFields(self: *DocView) void {
        const s = self.session orelse return;
        if (self.fields_generation == s.generation) return;
        if (self.field_arena) |*a| a.deinit();
        self.field_arena = std.heap.ArenaAllocator.init(self.allocator);
        self.fields = s.fields(self.field_arena.?.allocator()) catch &.{};
        self.fields_generation = s.generation;
    }

    // ---- search ------------------------------------------------------------------------------------

    fn searchFor(self: *DocView, text: []const u8) void {
        if (self.needle) |n| if (std.mem.eql(u8, n, text)) return self.step(true);
        self.runSearch(text);
    }

    fn runSearch(self: *DocView, text: []const u8) void {
        self.matches.clearRetainingCapacity();
        if (self.needle) |n| self.allocator.free(n);
        self.needle = null;
        self.match_index = 0;
        const s = self.session orelse return;
        if (text.len == 0) return self.area.as(gtk.Widget).queueDraw();
        self.needle = self.allocator.dupeSentinel(u8, text, 0) catch return;
        var found: std.ArrayList([2]u32) = .empty;
        defer found.deinit(self.allocator);
        for (0..self.pages) |i| {
            const lay = s.layout(i) catch continue;
            found.clearRetainingCapacity();
            lay.find(self.allocator, text, &found) catch continue;
            for (found.items) |r| self.matches.append(self.allocator, .{ .page = i, .start = r[0], .end = r[1] }) catch {};
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

    fn step(self: *DocView, forward: bool) void {
        const count = self.matches.items.len;
        if (count == 0) return;
        self.match_index = if (forward) (self.match_index + 1) % count else (self.match_index + count - 1) % count;
        self.showMatch();
    }

    fn showMatch(self: *DocView) void {
        const s = self.session orelse return;
        const m = self.matches.items[self.match_index];
        if (s.layout(m.page)) |lay| {
            var rects: std.ArrayList(pdf.text.Rect) = .empty;
            defer rects.deinit(self.allocator);
            lay.rectsFor(self.allocator, m.start, m.end, &rects) catch {};
            if (rects.items.len > 0) {
                const adj = self.scroller.getVadjustment();
                const l = self.layout.?;
                const top = l.tops[m.page] + rects.items[0].y0 * self.scale();
                // Only scroll when the match is out of view, and keep some context above it.
                if (top < adj.getValue() or top > adj.getValue() + adj.getPageSize() - 60) adj.setValue(top - adj.getPageSize() / 3);
            }
        } else |_| {}
        var buf: [64]u8 = undefined;
        self.status.setText(std.fmt.bufPrintSentinel(&buf, "Match {d} of {d}", .{ self.match_index + 1, self.matches.items.len }, 0) catch "");
        self.area.as(gtk.Widget).queueDraw();
    }

    // ---- selection and clicks -----------------------------------------------------------------------

    const Spot = struct { page: usize, x: f64, y: f64 };

    /// The page under the area point (`ax`, `ay`) and the point on it in page points.
    fn spotAt(self: *const DocView, ax: f64, ay: f64) ?Spot {
        const l = self.layout orelse return null;
        if (self.pages == 0) return null;
        const page = layout_mod.pageAt(l, ay);
        const sc = self.scale();
        return .{ .page = page, .x = (ax - self.pageLeft(page)) / sc, .y = (ay - l.tops[page]) / sc };
    }

    fn clearSelection(self: *DocView) void {
        self.sel_page = null;
        self.sel_start = 0;
        self.sel_end = 0;
        self.dragging = false;
    }

    fn onDragBegin(_: *gtk.GestureDrag, x: f64, y: f64, self: *DocView) callconv(.c) void {
        _ = self.area.as(gtk.Widget).grabFocus();
        self.drag_x = x;
        self.drag_y = y;
        self.drag_moved = false;
        const s = self.session orelse return;
        const spot = self.spotAt(x, y) orelse return;
        const lay = s.layout(spot.page) catch return;
        const off = lay.offsetAt(spot.x, spot.y) orelse return;
        self.dragging = true;
        self.sel_page = spot.page;
        self.anchor = off;
        self.sel_start = off;
        self.sel_end = off;
    }

    fn onDragUpdate(_: *gtk.GestureDrag, dx: f64, dy: f64, self: *DocView) callconv(.c) void {
        if (!self.dragging) return;
        if (!self.drag_moved and dx * dx + dy * dy < 9) return;
        self.drag_moved = true;
        const s = self.session orelse return;
        const page = self.sel_page orelse return;
        const l = self.layout orelse return;
        // Stay on the page the drag began on: points beyond it select to its edge.
        const sc = self.scale();
        const px = (self.drag_x + dx - self.pageLeft(page)) / sc;
        const py = (self.drag_y + dy - l.tops[page]) / sc;
        const lay = s.layout(page) catch return;
        const off = lay.offsetAt(px, py) orelse return;
        self.sel_start = @min(self.anchor, off);
        self.sel_end = @max(self.anchor, off);
        self.area.as(gtk.Widget).queueDraw();
    }

    fn onDragEnd(_: *gtk.GestureDrag, _: f64, _: f64, self: *DocView) callconv(.c) void {
        self.dragging = false;
        if (self.drag_moved) {
            if (self.sel_start != self.sel_end) self.status.setText(common.tr("Selected. Ctrl+C copies, Ctrl+H highlights."));
            return;
        }
        // A click without a drag: it hits a note, a form field, or clears the selection.
        self.clearSelection();
        self.area.as(gtk.Widget).queueDraw();
        const spot = self.spotAt(self.drag_x, self.drag_y) orelse return;
        if (self.hitField(spot)) return;
        if (self.hitAnnotation(spot)) |a| if (a.kind == .note) return self.editNote(spot.page, a.num);
    }

    /// Double click selects a word, triple click the line.
    fn onMultiClick(_: *gtk.GestureClick, n_press: c_int, x: f64, y: f64, self: *DocView) callconv(.c) void {
        if (n_press < 2) return;
        const s = self.session orelse return;
        const spot = self.spotAt(x, y) orelse return;
        const lay = s.layout(spot.page) catch return;
        const off = lay.offsetAt(spot.x, spot.y) orelse return;
        var lo: usize = off;
        var hi: usize = off;
        const text = lay.text;
        if (n_press == 2) {
            while (lo > 0 and isWordByte(text[lo - 1])) lo -= 1;
            while (hi < text.len and isWordByte(text[hi])) hi += 1;
        } else {
            while (lo > 0 and text[lo - 1] != '\n') lo -= 1;
            while (hi < text.len and text[hi] != '\n') hi += 1;
        }
        self.sel_page = spot.page;
        self.sel_start = @intCast(lo);
        self.sel_end = @intCast(hi);
        self.drag_moved = true; // the click that follows must not clear it
        self.area.as(gtk.Widget).queueDraw();
    }

    fn isWordByte(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c >= 0x80 or c == '_';
    }

    fn selectedText(self: *DocView) ?[]const u8 {
        const s = self.session orelse return null;
        const page = self.sel_page orelse return null;
        if (self.sel_start == self.sel_end) return null;
        const lay = s.layout(page) catch return null;
        const hi = @min(self.sel_end, lay.text.len);
        return std.mem.trimEnd(u8, lay.text[self.sel_start..hi], "\n");
    }

    fn copySelection(self: *DocView) void {
        const text = self.selectedText() orelse return self.copyPageText();
        const z = self.allocator.dupeSentinel(u8, text, 0) catch return;
        defer self.allocator.free(z);
        self.window.as(gtk.Widget).getClipboard().setText(z);
        self.status.setText(common.tr("Copied."));
    }

    fn copyPageText(self: *DocView) void {
        const s = self.session orelse return;
        const lay = s.layout(self.currentPage()) catch return;
        const z = self.allocator.dupeSentinel(u8, lay.text, 0) catch return;
        defer self.allocator.free(z);
        self.window.as(gtk.Widget).getClipboard().setText(z);
        self.status.setText(common.tr("Copied the text of this page."));
    }

    // ---- annotations ----------------------------------------------------------------------------------

    fn dateNow(buf: *[20]u8) []const u8 {
        return session_mod.pdfDate(buf, @divFloor(glib.getRealTime(), 1_000_000));
    }

    fn meta(self: *DocView, buf: *[20]u8, contents: []const u8, color: [3]f64) pdf.annot.Meta {
        return .{ .contents = contents, .author = self.author, .date = dateNow(buf), .color = color };
    }

    /// Reports an editing failure to the user.
    fn editFailed(self: *DocView, err: anyerror) void {
        const msg: [:0]const u8 = switch (err) {
            error.CannotEdit => common.tr("This file cannot be edited in place."),
            error.ReadOnly => common.tr("This field is read-only."),
            error.TooLong => common.tr("That text is longer than the field allows."),
            else => common.tr("The change could not be made."),
        };
        common.dialogs.showError(self.window.as(gtk.Window), common.tr("Cannot change the PDF"), msg);
    }

    /// An edit happened: redraw everything that depends on the file.
    fn changed(self: *DocView) void {
        self.dropCache();
        self.clearSelection();
        self.matches.clearRetainingCapacity();
        self.fields_generation = std.math.maxInt(u32);
        self.rebuildSidebar();
        self.updateTitle();
        self.area.as(gtk.Widget).queueDraw();
    }

    fn markSelection(self: *DocView, kind: pdf.annot.Kind) void {
        const s = self.session orelse return;
        const page = self.sel_page orelse return self.status.setText(common.tr("Select some text first."));
        if (self.sel_start == self.sel_end) return self.status.setText(common.tr("Select some text first."));
        const lay = s.layout(page) catch return;
        var rects: std.ArrayList(pdf.text.Rect) = .empty;
        defer rects.deinit(self.allocator);
        lay.rectsFor(self.allocator, self.sel_start, self.sel_end, &rects) catch return;
        var date: [20]u8 = undefined;
        const color: [3]f64 = switch (kind) {
            .highlight => .{ 1, 0.92, 0.2 },
            .underline => .{ 0.1, 0.5, 0.1 },
            else => .{ 0.85, 0.1, 0.1 },
        };
        s.markup(page, kind, rects.items, self.meta(&date, "", color)) catch |e| return self.editFailed(e);
        self.changed();
    }

    const Hit = struct { num: u32, kind: pdf.annot.Kind };

    /// The annotation (other than form widgets, links and pop-ups) under `spot`.
    fn hitAnnotation(self: *DocView, spot: Spot) ?Hit {
        const s = self.session orelse return null;
        const p = pdf.pages.page(&s.doc.doc, s.doc.pages, spot.page) orelse return null;
        const inv = pdf.interp.baseMatrix(p).invert() orelse return null;
        const u = inv.apply(spot.x, spot.y);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const list = s.annotations(arena.allocator(), spot.page) catch return null;
        // The last one drawn is on top.
        var i = list.len;
        while (i > 0) {
            i -= 1;
            const a = list[i];
            switch (a.kind) {
                .highlight, .underline, .strikeout, .squiggly, .note, .free_text, .ink => {},
                else => continue,
            }
            if (a.num == 0) continue;
            if (u.x >= a.rect.x0 and u.x <= a.rect.x1 and u.y >= a.rect.y0 and u.y <= a.rect.y1) return .{ .num = a.num, .kind = a.kind };
        }
        return null;
    }

    fn editNote(self: *DocView, page: usize, num: u32) void {
        const s = self.session orelse return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const list = s.annotations(arena.allocator(), page) catch return;
        for (list) |a| if (a.num == num) {
            const act = self.allocator.create(Act) catch return;
            act.* = .{ .viewer = self, .action = .edit_note, .page = page, .num = num };
            self.openTextDialog(act, common.tr("Note"), a.contents, true);
            return;
        };
    }

    // ---- text dialog (notes, form fields) ---------------------------------------------------------------

    const TextDialog = struct {
        act: *Act,
        dialog: *gtk.Window,
        view: *gtk.TextView,
        field_name: ?[:0]u8 = null,
    };

    fn openTextDialog(self: *DocView, act: *Act, title: [:0]const u8, initial: []const u8, deletable: bool) void {
        const dialog = gtk.Window.new();
        dialog.setTitle(title);
        dialog.setTransientFor(self.window.as(gtk.Window));
        dialog.setModal(1);
        dialog.setDefaultSize(380, 220);
        dialog.as(gtk.Widget).addCssClass("dkde");
        const box = gtk.Box.new(.vertical, 8);
        box.as(gtk.Widget).setMarginTop(12);
        box.as(gtk.Widget).setMarginBottom(12);
        box.as(gtk.Widget).setMarginStart(12);
        box.as(gtk.Widget).setMarginEnd(12);
        dialog.setChild(box.as(gtk.Widget));

        const view = gtk.TextView.new();
        view.setWrapMode(.word_char);
        const z = self.allocator.dupeSentinel(u8, initial, 0) catch return;
        defer self.allocator.free(z);
        view.getBuffer().setText(z, -1);
        const scroller = gtk.ScrolledWindow.new();
        scroller.setChild(view.as(gtk.Widget));
        scroller.as(gtk.Widget).setVexpand(1);
        box.append(scroller.as(gtk.Widget));

        const row = gtk.Box.new(.horizontal, 8);
        row.as(gtk.Widget).setHalign(.end);
        const cancel = gtk.Button.newWithLabel(common.tr("Cancel"));
        const ok = gtk.Button.newWithLabel(common.tr("OK"));
        ok.as(gtk.Widget).addCssClass("suggested-action");
        const td = self.allocator.create(TextDialog) catch return;
        td.* = .{ .act = act, .dialog = dialog, .view = view };
        if (act.text) |t| td.field_name = t;
        if (deletable) {
            const del = gtk.Button.newWithLabel(common.tr("Delete"));
            del.as(gtk.Widget).addCssClass("destructive-action");
            _ = gtk.Button.signals.clicked.connect(del, *TextDialog, &onTextDelete, td, .{});
            row.append(del.as(gtk.Widget));
        }
        row.append(cancel.as(gtk.Widget));
        row.append(ok.as(gtk.Widget));
        box.append(row.as(gtk.Widget));
        _ = gtk.Button.signals.clicked.connect(cancel, *TextDialog, &onTextCancel, td, .{});
        _ = gtk.Button.signals.clicked.connect(ok, *TextDialog, &onTextOk, td, .{});
        _ = gtk.Widget.signals.destroy.connect(dialog, *TextDialog, &onTextDestroy, td, .{});
        dialog.present();
        _ = view.as(gtk.Widget).grabFocus();
    }

    fn onTextCancel(_: *gtk.Button, td: *TextDialog) callconv(.c) void {
        td.dialog.destroy();
    }

    fn onTextDestroy(_: *gtk.Window, td: *TextDialog) callconv(.c) void {
        const v = td.act.viewer;
        if (td.act.text) |t| v.allocator.free(t);
        v.allocator.destroy(td.act);
        v.allocator.destroy(td);
    }

    fn bufferText(self: *DocView, view: *gtk.TextView) ?[]u8 {
        const buf = view.getBuffer();
        var start: gtk.TextIter = undefined;
        var end: gtk.TextIter = undefined;
        buf.getBounds(&start, &end);
        const raw = buf.getText(&start, &end, 0);
        defer glib.free(raw);
        return self.allocator.dupe(u8, std.mem.span(raw)) catch null;
    }

    fn onTextDelete(_: *gtk.Button, td: *TextDialog) callconv(.c) void {
        const v = td.act.viewer;
        const s = v.session orelse return;
        const act = td.act;
        td.dialog.destroy(); // frees td and act
        s.removeAnnotation(act.page, act.num) catch |e| return v.editFailed(e);
        v.changed();
    }

    fn onTextOk(_: *gtk.Button, td: *TextDialog) callconv(.c) void {
        const v = td.act.viewer;
        const s = v.session orelse return;
        const text = v.bufferText(td.view) orelse return;
        defer v.allocator.free(text);
        // Copy what is needed: destroying the dialog frees `td` and the act.
        const action = td.act.action;
        const page = td.act.page;
        const x = td.act.x;
        const y = td.act.y;
        const num = td.act.num;
        const field_name: ?[]u8 = if (td.act.text) |t| v.allocator.dupe(u8, t) catch null else null;
        defer if (field_name) |f| v.allocator.free(f);
        td.dialog.destroy();
        var date: [20]u8 = undefined;
        switch (action) {
            .add_note => s.addNote(page, x, y, v.meta(&date, text, .{ 1, 0.92, 0.2 })) catch |e| return v.editFailed(e),
            .edit_note => s.setNoteText(num, text, dateNow(&date)) catch |e| return v.editFailed(e),
            .pick_choice => {
                const name = field_name orelse return;
                v.ensureFields();
                for (v.fields) |f| if (std.mem.eql(u8, f.name, name)) {
                    s.fillText(f, text) catch |e| return v.editFailed(e);
                    break;
                };
            },
            else => return,
        }
        v.changed();
    }

    // ---- form fields ------------------------------------------------------------------------------------

    /// Handles a click on a form field. Returns true when the click was on one.
    fn hitField(self: *DocView, spot: Spot) bool {
        const s = self.session orelse return false;
        self.ensureFields();
        const p = pdf.pages.page(&s.doc.doc, s.doc.pages, spot.page) orelse return false;
        const inv = pdf.interp.baseMatrix(p).invert() orelse return false;
        const u = inv.apply(spot.x, spot.y);
        for (self.fields) |f| {
            for (f.widgets, 0..) |wd, wi| {
                if (wd.page != spot.page) continue;
                if (u.x < wd.rect.x0 or u.x > wd.rect.x1 or u.y < wd.rect.y0 or u.y > wd.rect.y1) continue;
                self.activateField(f, wi, spot);
                return true;
            }
        }
        return false;
    }

    fn activateField(self: *DocView, f: pdf.form.Field, which: usize, spot: Spot) void {
        const s = self.session orelse return;
        if (f.read_only) return self.status.setText(common.tr("This field is read-only."));
        switch (f.kind) {
            .checkbox => {
                s.fillChecked(f, which, !f.widgets[which].on) catch |e| return self.editFailed(e);
                self.changed();
            },
            .radio => {
                s.fillChecked(f, which, true) catch |e| return self.editFailed(e);
                self.changed();
            },
            .text => {
                const act = self.allocator.create(Act) catch return;
                act.* = .{ .viewer = self, .action = .pick_choice, .page = spot.page };
                act.text = self.allocator.dupeSentinel(u8, f.name, 0) catch {
                    self.allocator.destroy(act);
                    return;
                };
                self.openTextDialog(act, if (f.name.len > 0) (self.allocator.dupeSentinel(u8, f.name, 0) catch return) else common.tr("Field"), f.value, false);
            },
            .combo, .list => {
                if (f.options.len == 0 and f.kind == .combo) {
                    const act = self.allocator.create(Act) catch return;
                    act.* = .{ .viewer = self, .action = .pick_choice, .page = spot.page };
                    act.text = self.allocator.dupeSentinel(u8, f.name, 0) catch {
                        self.allocator.destroy(act);
                        return;
                    };
                    return self.openTextDialog(act, common.tr("Field"), f.value, false);
                }
                self.showChoices(f, spot);
            },
            else => self.status.setText(common.tr("This kind of field cannot be filled here.")),
        }
    }

    // ---- popup menus -------------------------------------------------------------------------------------

    fn onRightClick(_: *gtk.GestureClick, _: c_int, x: f64, y: f64, self: *DocView) callconv(.c) void {
        const spot = self.spotAt(x, y) orelse return;
        const pop = self.newPopover(x, y);
        const box = gtk.Box.new(.vertical, 0);
        pop.setChild(box.as(gtk.Widget));

        const have_sel = self.selectedText() != null;
        if (have_sel) {
            self.menuButton(box, pop, common.tr("Copy"), .{ .viewer = self, .action = .copy });
            self.menuButton(box, pop, common.tr("Highlight"), .{ .viewer = self, .action = .highlight });
            self.menuButton(box, pop, common.tr("Underline"), .{ .viewer = self, .action = .underline });
            self.menuButton(box, pop, common.tr("Strike out"), .{ .viewer = self, .action = .strikeout });
        }
        if (self.hitAnnotation(spot)) |a| {
            if (a.kind == .note) self.menuButton(box, pop, common.tr("Edit note…"), .{ .viewer = self, .action = .edit_note, .page = spot.page, .num = a.num });
            self.menuButton(box, pop, common.tr("Delete annotation"), .{ .viewer = self, .action = .delete_annotation, .page = spot.page, .num = a.num });
        }
        self.menuButton(box, pop, common.tr("Add note here…"), .{ .viewer = self, .action = .add_note, .page = spot.page, .x = spot.x, .y = spot.y });
        self.menuButton(box, pop, common.tr("Bookmark this place"), .{ .viewer = self, .action = .add_bookmark_here, .page = spot.page, .y = spot.y });
        pop.popup();
    }

    fn newPopover(self: *DocView, x: f64, y: f64) *gtk.Popover {
        const pop = gtk.Popover.new();
        pop.as(gtk.Widget).setParent(self.area.as(gtk.Widget));
        var rect: gdk.Rectangle = .{ .f_x = @intFromFloat(x), .f_y = @intFromFloat(y), .f_width = 1, .f_height = 1 };
        pop.setPointingTo(&rect);
        pop.setHasArrow(0);
        _ = gtk.Popover.signals.closed.connect(pop, *DocView, &onPopoverClosed, self, .{});
        return pop;
    }

    fn onPopoverClosed(pop: *gtk.Popover, _: *DocView) callconv(.c) void {
        // Unparent once the popover is done closing, not from inside its own signal.
        _ = glib.idleAdd(unparentIdle, pop);
    }

    fn unparentIdle(data: ?*anyopaque) callconv(.c) c_int {
        const pop: *gtk.Popover = @ptrCast(@alignCast(data.?));
        pop.as(gtk.Widget).unparent();
        return 0;
    }

    fn menuButton(self: *DocView, box: *gtk.Box, pop: *gtk.Popover, label: [:0]const u8, act_value: Act) void {
        const button = gtk.Button.newWithLabel(label);
        button.setHasFrame(0);
        if (button.getChild()) |child| {
            const l: *gtk.Label = @ptrCast(@alignCast(child));
            l.setXalign(0);
        }
        const act = self.allocator.create(Act) catch return;
        act.* = act_value;
        _ = pop;
        _ = gtk.Button.signals.clicked.connect(button, *Act, &onMenuButton, act, .{});
        _ = gtk.Widget.signals.destroy.connect(button, *Act, &onMenuButtonDestroy, act, .{});
        box.append(button.as(gtk.Widget));
    }

    fn onMenuButtonDestroy(_: *gtk.Button, act: *Act) callconv(.c) void {
        if (act.text) |t| act.viewer.allocator.free(t);
        act.viewer.allocator.destroy(act);
    }

    fn onMenuButton(button: *gtk.Button, act: *Act) callconv(.c) void {
        // Close the popover that holds the button.
        if (button.as(gtk.Widget).getAncestor(gtk.Popover.getGObjectType())) |p| {
            const pop: *gtk.Popover = @ptrCast(@alignCast(p));
            pop.popdown();
        }
        const v = act.viewer;
        const s = v.session orelse return;
        switch (act.action) {
            .copy => v.copySelection(),
            .highlight => v.markSelection(.highlight),
            .underline => v.markSelection(.underline),
            .strikeout => v.markSelection(.strikeout),
            .add_note => {
                const copy = v.allocator.create(Act) catch return;
                copy.* = .{ .viewer = v, .action = .add_note, .page = act.page, .x = act.x, .y = act.y };
                v.openTextDialog(copy, common.tr("New note"), "", false);
            },
            .edit_note => v.editNote(act.page, act.num),
            .delete_annotation => {
                s.removeAnnotation(act.page, act.num) catch |e| return v.editFailed(e);
                v.changed();
            },
            .add_bookmark_here => v.askBookmarkTitle(act.page, act.y),
            .pick_choice => {},
        }
    }

    /// The options of a list or combo box, as a popup menu at the field.
    fn showChoices(self: *DocView, f: pdf.form.Field, spot: Spot) void {
        const l = self.layout orelse return;
        const sc = self.scale();
        const pop = self.newPopover(self.pageLeft(spot.page) + spot.x * sc, l.tops[spot.page] + spot.y * sc);
        const box = gtk.Box.new(.vertical, 0);
        pop.setChild(box.as(gtk.Widget));
        for (f.options) |opt| {
            const label = self.allocator.dupeSentinel(u8, opt, 0) catch continue;
            defer self.allocator.free(label);
            const button = gtk.Button.newWithLabel(label);
            button.setHasFrame(0);
            const act = self.allocator.create(Act) catch continue;
            act.* = .{ .viewer = self, .action = .pick_choice, .page = spot.page };
            // The field name and the choice travel together as "name\x00choice".
            const packed_text = std.fmt.allocPrintSentinel(self.allocator, "{s}\x00{s}", .{ f.name, opt }, 0) catch {
                self.allocator.destroy(act);
                continue;
            };
            act.text = packed_text;
            _ = gtk.Button.signals.clicked.connect(button, *Act, &onChoiceButton, act, .{});
            _ = gtk.Widget.signals.destroy.connect(button, *Act, &onMenuButtonDestroy, act, .{});
            box.append(button.as(gtk.Widget));
        }
        pop.popup();
    }

    fn onChoiceButton(button: *gtk.Button, act: *Act) callconv(.c) void {
        if (button.as(gtk.Widget).getAncestor(gtk.Popover.getGObjectType())) |p| {
            const pop: *gtk.Popover = @ptrCast(@alignCast(p));
            pop.popdown();
        }
        const v = act.viewer;
        const s = v.session orelse return;
        const packed_text = act.text orelse return;
        const nul = std.mem.indexOfScalar(u8, packed_text, 0) orelse return;
        const name = packed_text[0..nul];
        const choice = packed_text[nul + 1 ..];
        v.ensureFields();
        for (v.fields) |f| if (std.mem.eql(u8, f.name, name)) {
            s.fillChoice(f, choice) catch |e| return v.editFailed(e);
            v.changed();
            return;
        };
    }

    // ---- bookmarks ----------------------------------------------------------------------------------------

    fn rebuildSidebar(self: *DocView) void {
        while (self.sidebar_list.as(gtk.Widget).getFirstChild()) |child| self.sidebar_list.remove(child);
        self.rows.clearRetainingCapacity();
        if (self.outline_arena) |*a| a.deinit();
        self.outline_arena = null;
        const s = self.session orelse return;
        self.outline_arena = std.heap.ArenaAllocator.init(self.allocator);
        const items = s.outline(self.outline_arena.?.allocator()) catch return;
        self.flatten(items, 0);
        for (self.rows.items, 0..) |row, i| self.addRow(row, i);
        if (self.rows.items.len == 0) {
            const hint = gtk.Label.new(common.tr("No bookmarks yet.\nPress Ctrl+D to bookmark a page."));
            hint.as(gtk.Widget).setMarginStart(12);
            hint.as(gtk.Widget).setMarginTop(12);
            hint.setXalign(0);
            self.sidebar_list.append(hint.as(gtk.Widget));
        }
    }

    fn flatten(self: *DocView, items: []const pdf.outline.Item, depth: usize) void {
        for (items) |it| {
            const open = self.expanded.contains(it.num) or (it.open and !self.expanded_touched.contains(it.num));
            self.rows.append(self.allocator, .{ .item = it, .depth = depth, .expanded = open }) catch return;
            if (open and it.children.len > 0) self.flatten(it.children, depth + 1);
        }
    }

    const RowToggle = struct { viewer: *DocView, num: u32 };

    fn addRow(self: *DocView, row: Row, index: usize) void {
        _ = index;
        const box = gtk.Box.new(.horizontal, 2);
        box.as(gtk.Widget).setMarginStart(@intCast(4 + row.depth * 14));
        if (row.item.children.len > 0) {
            const toggle = gtk.Button.newFromIconName(if (row.expanded) "pan-down-symbolic" else "pan-end-symbolic");
            toggle.setHasFrame(0);
            const t = self.allocator.create(RowToggle) catch return;
            t.* = .{ .viewer = self, .num = row.item.num };
            _ = gtk.Button.signals.clicked.connect(toggle, *RowToggle, &onToggleRow, t, .{});
            _ = gtk.Widget.signals.destroy.connect(toggle, *RowToggle, &onToggleDestroy, t, .{});
            box.append(toggle.as(gtk.Widget));
        } else {
            const pad = gtk.Box.new(.horizontal, 0);
            pad.as(gtk.Widget).setSizeRequest(26, -1);
            box.append(pad.as(gtk.Widget));
        }
        const label_text = self.allocator.dupeSentinel(u8, if (row.item.title.len > 0) row.item.title else "(untitled)", 0) catch return;
        defer self.allocator.free(label_text);
        const label = gtk.Label.new(label_text);
        label.setXalign(0);
        label.setEllipsize(.end);
        label.as(gtk.Widget).setHexpand(1);
        box.append(label.as(gtk.Widget));
        self.sidebar_list.append(box.as(gtk.Widget));
    }

    fn onToggleDestroy(_: *gtk.Button, t: *RowToggle) callconv(.c) void {
        t.viewer.allocator.destroy(t);
    }

    fn onToggleRow(_: *gtk.Button, t: *RowToggle) callconv(.c) void {
        const v = t.viewer;
        v.expanded_touched.put(v.allocator, t.num, {}) catch {};
        if (v.expanded.contains(t.num)) {
            _ = v.expanded.remove(t.num);
        } else v.expanded.put(v.allocator, t.num, {}) catch {};
        // Rebuild after this handler returns: it is the button being replaced.
        _ = glib.idleAdd(rebuildIdle, v);
    }

    fn rebuildIdle(data: ?*anyopaque) callconv(.c) c_int {
        const v: *DocView = @ptrCast(@alignCast(data.?));
        v.rebuildSidebar();
        return 0;
    }

    fn onRowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *DocView) callconv(.c) void {
        const index: usize = @intCast(@max(0, row.getIndex()));
        if (index >= self.rows.items.len) return;
        const dest = self.rows.items[index].item.dest orelse return self.status.setText(common.tr("This bookmark has no destination."));
        const s = self.session orelse return;
        if (dest.y) |uy| {
            if (pdf.pages.page(&s.doc.doc, s.doc.pages, dest.page)) |p| {
                const pt = pdf.interp.baseMatrix(p).apply(dest.x orelse 0, uy);
                return self.scrollToPoint(dest.page, pt.y);
            }
        }
        self.scrollToPage(dest.page);
    }

    fn selectedRow(self: *DocView) ?usize {
        const row = self.sidebar_list.getSelectedRow() orelse return null;
        const i: usize = @intCast(@max(0, row.getIndex()));
        return if (i < self.rows.items.len) i else null;
    }

    fn onAddBookmarkClicked(_: *gtk.Button, self: *DocView) callconv(.c) void {
        self.askBookmarkTitle(self.currentPage(), null);
    }

    fn onRemoveBookmarkClicked(_: *gtk.Button, self: *DocView) callconv(.c) void {
        const s = self.session orelse return;
        const i = self.selectedRow() orelse return self.status.setText(common.tr("Select a bookmark to remove."));
        s.removeBookmark(self.rows.items[i].item.num) catch |e| return self.editFailed(e);
        self.changed();
    }

    const BookmarkAsk = struct { viewer: *DocView, dialog: *gtk.Window, entry: *gtk.Entry, page: usize, top: ?f64 };

    fn askBookmarkTitle(self: *DocView, page: usize, top: ?f64) void {
        const dialog = gtk.Window.new();
        dialog.setTitle(common.tr("Add bookmark"));
        dialog.setTransientFor(self.window.as(gtk.Window));
        dialog.setModal(1);
        dialog.setDefaultSize(340, -1);
        dialog.as(gtk.Widget).addCssClass("dkde");
        const box = gtk.Box.new(.vertical, 8);
        box.as(gtk.Widget).setMarginTop(12);
        box.as(gtk.Widget).setMarginBottom(12);
        box.as(gtk.Widget).setMarginStart(12);
        box.as(gtk.Widget).setMarginEnd(12);
        dialog.setChild(box.as(gtk.Widget));
        const entry = gtk.Entry.new();
        // A starting title: the text at the top of the page, or "Page N".
        var title_buf: [96:0]u8 = undefined;
        const suggestion = self.suggestTitle(page, &title_buf);
        entry.as(gtk.Editable).setText(suggestion);
        box.append(entry.as(gtk.Widget));
        const row = gtk.Box.new(.horizontal, 8);
        row.as(gtk.Widget).setHalign(.end);
        const cancel = gtk.Button.newWithLabel(common.tr("Cancel"));
        const ok = gtk.Button.newWithLabel(common.tr("Add"));
        ok.as(gtk.Widget).addCssClass("suggested-action");
        row.append(cancel.as(gtk.Widget));
        row.append(ok.as(gtk.Widget));
        box.append(row.as(gtk.Widget));
        const ask = self.allocator.create(BookmarkAsk) catch return;
        ask.* = .{ .viewer = self, .dialog = dialog, .entry = entry, .page = page, .top = top };
        _ = gtk.Button.signals.clicked.connect(cancel, *BookmarkAsk, &onBookmarkCancel, ask, .{});
        _ = gtk.Button.signals.clicked.connect(ok, *BookmarkAsk, &onBookmarkOk, ask, .{});
        _ = gtk.Entry.signals.activate.connect(entry, *BookmarkAsk, &onBookmarkActivate, ask, .{});
        _ = gtk.Widget.signals.destroy.connect(dialog, *BookmarkAsk, &onBookmarkDestroy, ask, .{});
        dialog.present();
        _ = entry.as(gtk.Widget).grabFocus();
    }

    fn suggestTitle(self: *DocView, page: usize, buf: *[96:0]u8) [:0]const u8 {
        const s = self.session orelse return "Page";
        const lay = s.layout(page) catch return std.fmt.bufPrintSentinel(buf, "Page {d}", .{page + 1}, 0) catch "Page";
        const first = std.mem.trim(u8, lay.text[0..@min(lay.text.len, 200)], " \n");
        const line_end = std.mem.indexOfScalar(u8, first, '\n') orelse first.len;
        const line = first[0..@min(line_end, 60)];
        if (line.len > 0) return std.fmt.bufPrintSentinel(buf, "{s}", .{line}, 0) catch "Page";
        return std.fmt.bufPrintSentinel(buf, "Page {d}", .{page + 1}, 0) catch "Page";
    }

    fn onBookmarkCancel(_: *gtk.Button, ask: *BookmarkAsk) callconv(.c) void {
        ask.dialog.destroy();
    }

    fn onBookmarkDestroy(_: *gtk.Window, ask: *BookmarkAsk) callconv(.c) void {
        ask.viewer.allocator.destroy(ask);
    }

    fn submitBookmark(ask: *BookmarkAsk) void {
        const v = ask.viewer;
        const s = v.session orelse return;
        const title = v.allocator.dupe(u8, std.mem.span(ask.entry.as(gtk.Editable).getText())) catch return;
        defer v.allocator.free(title);
        const page = ask.page;
        const top = ask.top;
        ask.dialog.destroy();
        if (title.len == 0) return;
        s.addBookmark(page, title, top) catch |e| return v.editFailed(e);
        v.sidebar.as(gtk.Widget).setVisible(1);
        v.changed();
    }

    fn onBookmarkOk(_: *gtk.Button, ask: *BookmarkAsk) callconv(.c) void {
        submitBookmark(ask);
    }

    fn onBookmarkActivate(_: *gtk.Entry, ask: *BookmarkAsk) callconv(.c) void {
        submitBookmark(ask);
    }

    // ---- menu -----------------------------------------------------------------------------------------

    fn onSaveChosen(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *DocView = @ptrCast(@alignCast(data.?));
        const dialog: *gtk.FileDialog = @ptrCast(@alignCast(source.?));
        var err: ?*glib.Error = null;
        const file = dialog.saveFinish(result, &err) orelse {
            if (err) |e| e.free();
            return;
        };
        defer file.as(gobject.Object).unref();
        const path = file.getPath() orelse return;
        defer glib.free(path);
        const s = self.session orelse return;
        if (!self.saveTo(std.mem.span(path), s)) return;
        // From now on the file is the one just written.
        if (self.allocator.dupeSentinel(u8, std.mem.span(path), 0)) |owned| {
            if (self.path) |old| self.allocator.free(old);
            self.path = owned;
            self.updateTitle();
        } else |_| {}
    }

    /// A menu action for this tab (opening and closing tabs belong to the window).
    // ---- printing -------------------------------------------------------------------------------

    /// Prints the document as it is on screen, with the annotations and form
    /// values added (saved or not), through GTK's print dialog: a printer,
    /// a PDF file, page ranges, copies. Each page is fitted to the paper and
    /// centred; landscape pages turn the paper.
    fn printDocument(self: *DocView) void {
        const s = self.session orelse return;
        _ = s;
        const op = gtk.PrintOperation.new();
        defer op.as(gobject.Object).unref();
        op.setNPages(@intCast(self.pages));
        op.setUnit(.points);
        op.setEmbedPageSetup(1);
        if (print_settings) |ps| op.setPrintSettings(ps);
        if (self.path) |p| {
            var buf: [256]u8 = undefined;
            op.setJobName(std.fmt.bufPrintSentinel(&buf, "{s}", .{std.fs.path.basename(p)}, 0) catch "PDF");
        }
        _ = gtk.PrintOperation.signals.request_page_setup.connect(op, *DocView, &onPrintPageSetup, self, .{});
        _ = gtk.PrintOperation.signals.draw_page.connect(op, *DocView, &onPrintPage, self, .{});
        // Not asynchronous: the dialog is modal and the pages are drawn
        // before run returns, so the tab (and its document) stay open.
        var err: ?*glib.Error = null;
        const result = op.run(.print_dialog, self.window.as(gtk.Window), &err);
        if (err) |e| {
            defer e.free();
            common.dialogs.showError(self.window.as(gtk.Window), common.tr("Cannot print"), if (e.f_message) |m| std.mem.span(m) else "");
            return;
        }
        if (result == .apply) {
            if (print_settings) |old| old.as(gobject.Object).unref();
            print_settings = if (op.getPrintSettings()) |ps| @ptrCast(ps.as(gobject.Object).ref()) else null;
        }
    }

    fn onPrintPageSetup(_: *gtk.PrintOperation, _: *gtk.PrintContext, page_nr: c_int, setup: *gtk.PageSetup, self: *DocView) callconv(.c) void {
        const page: usize = @intCast(page_nr);
        if (page >= self.page_points.len) return;
        const size = self.page_points[page];
        setup.setOrientation(if (size.w > size.h) .landscape else .portrait);
    }

    fn onPrintPage(_: *gtk.PrintOperation, context: *gtk.PrintContext, page_nr: c_int, self: *DocView) callconv(.c) void {
        const s = self.session orelse return;
        const page: usize = @intCast(page_nr);
        if (page >= self.page_points.len) return;
        const cr = context.getCairoContext();
        const pw = context.getWidth();
        const ph = context.getHeight();
        const size = self.page_points[page];
        if (size.w <= 0 or size.h <= 0) return;
        const fit = @min(pw / size.w, ph / size.h);
        cr.save();
        defer cr.restore();
        cr.translate((pw - size.w * fit) / 2, (ph - size.h * fit) / 2);
        render.renderPage(self.allocator, s.doc, page, cr, fit, &self.diag) catch |e|
            std.log.warn("printing page {d}: {s}", .{ page + 1, @errorName(e) });
    }

    fn perform(self: *DocView, action: []const u8) void {
        const eql = std.mem.eql;
        if (eql(u8, action, "save")) {
            if (self.session != null) _ = self.save();
            return;
        }
        if (eql(u8, action, "print")) return self.printDocument();
        if (eql(u8, action, "save-as")) {
            if (self.session == null) return;
            const dialog = gtk.FileDialog.new();
            defer dialog.as(gobject.Object).unref();
            return dialog.save(self.window.as(gtk.Window), null, onSaveChosen, self);
        }
        if (eql(u8, action, "reload")) {
            const path = self.path orelse return;
            const copy = self.allocator.dupeSentinel(u8, path, 0) catch return;
            defer self.allocator.free(copy);
            _ = self.openPath(copy, null);
            return;
        }
        if (eql(u8, action, "undo")) {
            const s = self.session orelse return;
            s.undo() catch return self.status.setText(common.tr("Nothing to undo."));
            return self.changed();
        }
        if (eql(u8, action, "copy")) return self.copySelection();
        if (eql(u8, action, "copy-text")) return self.copyPageText();
        if (eql(u8, action, "select-all")) {
            const s = self.session orelse return;
            const page = self.currentPage();
            const lay = s.layout(page) catch return;
            self.sel_page = page;
            self.sel_start = 0;
            self.sel_end = @intCast(lay.text.len);
            return self.area.as(gtk.Widget).queueDraw();
        }
        if (eql(u8, action, "find")) return self.focusSearch();
        if (eql(u8, action, "find-next")) return self.step(true);
        if (eql(u8, action, "find-prev")) return self.step(false);
        if (eql(u8, action, "highlight")) return self.markSelection(.highlight);
        if (eql(u8, action, "underline")) return self.markSelection(.underline);
        if (eql(u8, action, "strikeout")) return self.markSelection(.strikeout);
        if (eql(u8, action, "add-note")) {
            // At the top left of what is on screen, where there is room.
            const page = self.currentPage();
            const act = self.allocator.create(Act) catch return;
            act.* = .{ .viewer = self, .action = .add_note, .page = page, .x = 40, .y = 40 };
            return self.openTextDialog(act, common.tr("New note"), "", false);
        }
        if (eql(u8, action, "add-bookmark")) return self.askBookmarkTitle(self.currentPage(), null);
        if (eql(u8, action, "toggle-sidebar")) {
            const w = self.sidebar.as(gtk.Widget);
            return w.setVisible(@intFromBool(w.getVisible() == 0));
        }
        if (eql(u8, action, "toggle-fields")) {
            self.show_fields = !self.show_fields;
            return self.area.as(gtk.Widget).queueDraw();
        }
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

    fn focusSearch(self: *DocView) void {
        _ = self.search.as(gtk.Widget).grabFocus();
    }
};

/// One window: the menu, the toolbar and a notebook with one tab per open PDF.
const Window = struct {
    allocator: std.mem.Allocator,
    window: *gtk.ApplicationWindow,
    notebook: *gtk.Notebook,
    page_spin: *gtk.SpinButton,
    page_total: *gtk.Label,
    zoom_label: *gtk.Label,
    search: *gtk.SearchEntry,
    status: *gtk.Label,
    tabs: std.ArrayList(*DocView) = .empty,
    /// The label of each tab, in the same order as `tabs`.
    labels: std.ArrayList(*gtk.Label) = .empty,
    /// The data of each tab's close button, owned here (GTK does not destroy a
    /// notebook's tab labels with the window), in the same order as `tabs`.
    closers: std.ArrayList(*TabClose) = .empty,
    initial_file: ?[:0]const u8,

    pub fn create(allocator: std.mem.Allocator, app: *gtk.Application) !*Window {
        const self = try allocator.create(Window);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .window = gtk.ApplicationWindow.new(app),
            .notebook = gtk.Notebook.new(),
            .page_spin = gtk.SpinButton.newWithRange(1, 1, 1),
            .page_total = gtk.Label.new("/ 0"),
            .zoom_label = gtk.Label.new("100%"),
            .search = gtk.SearchEntry.new(),
            .status = gtk.Label.new(""),
            .initial_file = initial_path,
        };
        const window = self.window.as(gtk.Window);
        window.setTitle(common.tr("PDF Viewer"));
        window.setDefaultSize(1000, 740);
        self.window.as(gtk.Widget).addCssClass("dkde");
        _ = common.header.create(window, "application-pdf", true);

        const mb = common.menubar;
        const menus = [_]mb.Menu{
            .{ .label = "_File", .entries = &.{
                mb.item("New _Tab", "new-tab", "<Control>t"),
                mb.item("_Open…", "open", "<Control>o"),
                mb.item("_Save", "save", "<Control>s"),
                mb.item("Save _As…", "save-as", "<Control><Shift>s"),
                mb.item("_Print…", "print", "<Control>p"),
                mb.item("_Reload", "reload", "F5"),
                .separator,
                mb.item("_Close Tab", "close-tab", "<Control>w"),
                mb.item("E_xit", "close", "<Control>q"),
            } },
            .{ .label = "_Edit", .entries = &.{
                mb.item("_Undo", "undo", "<Control>z"),
                .separator,
                mb.item("_Copy", "copy", "<Control>c"),
                mb.item("Copy page _text", "copy-text", null),
                mb.item("Select _all on page", "select-all", "<Control>a"),
                .separator,
                mb.item("_Find…", "find", "<Control>f"),
                mb.item("Find _Next", "find-next", "F3"),
                mb.item("Find _Previous", "find-prev", "<Shift>F3"),
            } },
            .{ .label = "_Annotate", .entries = &.{
                mb.item("_Highlight selection", "highlight", "<Control>h"),
                mb.item("_Underline selection", "underline", "<Control>u"),
                mb.item("S_trike out selection", "strikeout", null),
                mb.item("Add _note…", "add-note", "<Control>m"),
                .separator,
                mb.item("Add _bookmark here", "add-bookmark", "<Control>d"),
            } },
            .{ .label = "_View", .entries = &.{
                mb.item("Zoom _In", "zoom-in", "<Control>plus"),
                mb.item("Zoom _Out", "zoom-out", "<Control>minus"),
                mb.item("_Actual size", "zoom-100", "<Control>0"),
                .separator,
                mb.item("Fit _width", "fit-width", null),
                mb.item("Fit _page", "fit-page", null),
                .separator,
                mb.item("_Bookmarks", "toggle-sidebar", "F9"),
                mb.check("Show form _fields", "toggle-fields", true),
                .separator,
                mb.item("_Next Tab", "next-tab", "<Control>Page_Down"),
                mb.item("_Previous Tab", "prev-tab", "<Control>Page_Up"),
            } },
            .{ .label = "_Go", .entries = &.{
                mb.item("_First page", "first", "Home"),
                mb.item("_Previous page", "prev", "<Alt>Left"),
                mb.item("_Next page", "next", "<Alt>Right"),
                mb.item("_Last page", "last", "End"),
            } },
        };
        const menu_bar = mb.build(app, self.window, &menus, Window, onMenubarAction, self);

        // Toolbar: page, zoom, search (they act on the tab that is showing).
        const toolbar = gtk.Box.new(.horizontal, 8);
        toolbar.as(gtk.Widget).setMarginStart(8);
        toolbar.as(gtk.Widget).setMarginEnd(8);
        toolbar.as(gtk.Widget).setMarginTop(4);
        toolbar.as(gtk.Widget).setMarginBottom(4);
        _ = gtk.SpinButton.signals.value_changed.connect(self.page_spin, *Window, &onPageSpin, self, .{});
        toolbar.append(gtk.Label.new(common.tr("Page")).as(gtk.Widget));
        toolbar.append(self.page_spin.as(gtk.Widget));
        toolbar.append(self.page_total.as(gtk.Widget));
        const spacer = gtk.Box.new(.horizontal, 0);
        spacer.as(gtk.Widget).setHexpand(1);
        toolbar.append(spacer.as(gtk.Widget));
        toolbar.append(zoomButton(self, "\u{2212}", common.tr("Zoom out"), onZoomOut));
        toolbar.append(self.zoom_label.as(gtk.Widget));
        toolbar.append(zoomButton(self, "+", common.tr("Zoom in"), onZoomIn));
        self.search.setPlaceholderText(common.tr("Search"));
        self.search.as(gtk.Widget).setSizeRequest(200, -1);
        _ = gtk.SearchEntry.signals.activate.connect(self.search, *Window, &onSearchActivate, self, .{});
        _ = gtk.SearchEntry.signals.next_match.connect(self.search, *Window, &onNextMatch, self, .{});
        _ = gtk.SearchEntry.signals.previous_match.connect(self.search, *Window, &onPrevMatch, self, .{});
        toolbar.append(self.search.as(gtk.Widget));

        self.notebook.setScrollable(1);
        self.notebook.as(gtk.Widget).setVexpand(1);
        _ = gtk.Notebook.signals.switch_page.connect(self.notebook, *Window, &onSwitchPage, self, .{});

        self.status.setXalign(0);
        self.status.as(gtk.Widget).setMarginStart(8);
        self.status.as(gtk.Widget).setMarginTop(2);
        self.status.as(gtk.Widget).setMarginBottom(2);
        self.status.as(gtk.Widget).addCssClass("dkde-files-status");

        const root = gtk.Box.new(.vertical, 0);
        root.append(menu_bar.as(gtk.Widget));
        root.append(toolbar.as(gtk.Widget));
        root.append(self.notebook.as(gtk.Widget));
        root.append(self.status.as(gtk.Widget));
        window.setChild(root.as(gtk.Widget));

        _ = gtk.Window.signals.close_request.connect(window, *Window, &onCloseRequest, self, .{});
        _ = gtk.Widget.signals.destroy.connect(self.window, *Window, &onDestroy, self, .{});
        _ = self.newTab() catch return error.OutOfMemory;
        return self;
    }

    pub fn present(self: *Window) void {
        self.window.as(gtk.Window).present();
        if (self.initial_file) |p| self.openFile(p);
    }

    fn zoomButton(self: *Window, icon: [:0]const u8, tip: [:0]const u8, comptime handler: fn (*gtk.Button, *Window) callconv(.c) void) *gtk.Widget {
        const b = gtk.Button.newWithLabel(icon);
        b.as(gtk.Widget).setTooltipText(tip);
        _ = gtk.Button.signals.clicked.connect(b, *Window, &handler, self, .{});
        return b.as(gtk.Widget);
    }

    fn onDestroy(_: *gtk.ApplicationWindow, self: *Window) callconv(.c) void {
        for (self.tabs.items) |t| t.deinit();
        self.tabs.deinit(self.allocator);
        self.labels.deinit(self.allocator);
        for (self.closers.items) |c| self.allocator.destroy(c);
        self.closers.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// The tab that is showing.
    fn active(self: *const Window) ?*DocView {
        const n = self.notebook.getCurrentPage();
        if (n < 0 or @as(usize, @intCast(n)) >= self.tabs.items.len) return null;
        return self.tabs.items[@intCast(n)];
    }

    // ---- tabs ------------------------------------------------------------------------------------

    const TabClose = struct { window: *Window, doc: *DocView };

    fn newTab(self: *Window) !*DocView {
        const doc = try DocView.create(self.allocator, self);
        errdefer doc.deinit();
        const label = gtk.Label.new(common.tr("New tab"));
        label.setEllipsize(.end);
        label.setMaxWidthChars(24);
        const close = gtk.Button.newFromIconName("window-close-symbolic");
        close.setHasFrame(0);
        close.as(gtk.Widget).setTooltipText(common.tr("Close tab"));
        const head = gtk.Box.new(.horizontal, 4);
        head.append(label.as(gtk.Widget));
        head.append(close.as(gtk.Widget));
        const tc = try self.allocator.create(TabClose);
        errdefer self.allocator.destroy(tc);
        tc.* = .{ .window = self, .doc = doc };
        _ = gtk.Button.signals.clicked.connect(close, *TabClose, &onTabCloseClicked, tc, .{});
        try self.tabs.append(self.allocator, doc);
        errdefer _ = self.tabs.pop();
        try self.labels.append(self.allocator, label);
        errdefer _ = self.labels.pop();
        try self.closers.append(self.allocator, tc);
        const index = self.notebook.appendPage(doc.widget(), head.as(gtk.Widget));
        self.notebook.setTabReorderable(doc.widget(), 0);
        self.notebook.setCurrentPage(index);
        return doc;
    }

    fn onTabCloseClicked(_: *gtk.Button, tc: *TabClose) callconv(.c) void {
        tc.window.closeTab(tc.doc);
    }

    fn indexOf(self: *const Window, doc: *const DocView) ?usize {
        for (self.tabs.items, 0..) |t, i| if (t == doc) return i;
        return null;
    }

    /// Closes a tab, asking first when it has changes that are not saved.
    fn closeTab(self: *Window, doc: *DocView) void {
        if (doc.isDirty()) {
            const ask = self.allocator.create(CloseAsk) catch return;
            ask.* = .{ .window = self, .doc = doc };
            return common.dialogs.choose(self.window.as(gtk.Window), common.tr("Save the changes to this PDF?"), common.tr("Your annotations, bookmarks and form entries are not saved yet."), &.{ "Save", "Discard", "Cancel" }, 2, CloseAsk, onCloseAskChoice, ask);
        }
        self.removeTab(doc);
    }

    const CloseAsk = struct { window: *Window, doc: *DocView };

    fn onCloseAskChoice(ask: *CloseAsk, choice: c_int) void {
        const self = ask.window;
        const doc = ask.doc;
        self.allocator.destroy(ask);
        // The tab may have gone while the question was open.
        if (self.indexOf(doc) == null) return;
        switch (choice) {
            0 => if (doc.save()) self.removeTab(doc),
            1 => self.removeTab(doc),
            else => {},
        }
    }

    fn removeTab(self: *Window, doc: *DocView) void {
        const i = self.indexOf(doc) orelse return;
        // The last tab is emptied, not removed: the window always shows something.
        if (self.tabs.items.len == 1) {
            if (doc.session == null) return;
            self.dropTab(i);
            doc.deinit();
            _ = self.newTab() catch return;
            return;
        }
        self.dropTab(i);
        doc.deinit();
    }

    /// Takes tab `i` out of the notebook and the window's lists. It runs from the
    /// tab's close button, so its data is freed only after the page is gone.
    fn dropTab(self: *Window, i: usize) void {
        _ = self.tabs.orderedRemove(i);
        _ = self.labels.orderedRemove(i);
        const tc = self.closers.orderedRemove(i);
        self.notebook.removePage(@intCast(i));
        self.allocator.destroy(tc);
    }

    /// Opens `path` in the empty tab that is showing, or in a new tab.
    fn openFile(self: *Window, path: [:0]const u8) void {
        var doc = self.active() orelse return;
        if (doc.session != null) doc = self.newTab() catch return;
        const result = doc.openPath(path, null);
        if (result == .failed and self.tabs.items.len > 1) self.removeTab(doc);
    }

    /// The tab's label and, for the tab that is showing, the window title.
    fn refreshTitles(self: *Window, doc: *DocView) void {
        const i = self.indexOf(doc) orelse return;
        const name: []const u8 = if (doc.path) |p| std.fs.path.basename(p) else "New tab";
        var buf: [300]u8 = undefined;
        const text = std.fmt.bufPrintSentinel(&buf, "{s}{s}", .{ if (doc.isDirty()) "* " else "", name }, 0) catch return;
        self.labels.items[i].setText(text);
        if (doc.isActive()) {
            var tbuf: [360]u8 = undefined;
            self.window.as(gtk.Window).setTitle(std.fmt.bufPrintSentinel(&tbuf, "{s} \u{2014} PDF Viewer", .{text}, 0) catch "PDF Viewer");
        }
    }

    fn onSwitchPage(_: *gtk.Notebook, _: *gtk.Widget, number: c_uint, self: *Window) callconv(.c) void {
        // The signal comes before the page changes: use the number it gives.
        if (number >= self.tabs.items.len) return;
        const doc = self.tabs.items[number];
        doc.syncToolbar();
        if (doc.session == null) {
            self.window.as(gtk.Window).setTitle(common.tr("PDF Viewer"));
            self.status.setText("");
        }
    }

    // ---- toolbar, close, menu -----------------------------------------------------------------------

    fn onPageSpin(button: *gtk.SpinButton, self: *Window) callconv(.c) void {
        if (self.active()) |d| d.gotoPageNumber(button.getValueAsInt());
    }

    fn onZoomIn(_: *gtk.Button, self: *Window) callconv(.c) void {
        if (self.active()) |d| d.setZoom(layout_mod.stepZoom(d.zoom, true));
    }

    fn onZoomOut(_: *gtk.Button, self: *Window) callconv(.c) void {
        if (self.active()) |d| d.setZoom(layout_mod.stepZoom(d.zoom, false));
    }

    fn onSearchActivate(entry: *gtk.SearchEntry, self: *Window) callconv(.c) void {
        if (self.active()) |d| d.searchFor(std.mem.span(entry.as(gtk.Editable).getText()));
    }

    fn onNextMatch(_: *gtk.SearchEntry, self: *Window) callconv(.c) void {
        if (self.active()) |d| d.step(true);
    }

    fn onPrevMatch(_: *gtk.SearchEntry, self: *Window) callconv(.c) void {
        if (self.active()) |d| d.step(false);
    }

    /// Asks before closing the window when any tab has unsaved changes.
    fn onCloseRequest(_: *gtk.Window, self: *Window) callconv(.c) c_int {
        var dirty = false;
        for (self.tabs.items) |t| {
            if (t.isDirty()) dirty = true;
        }
        if (!dirty) return 0;
        common.dialogs.choose(self.window.as(gtk.Window), common.tr("Save the changes to your PDFs?"), common.tr("Your annotations, bookmarks and form entries are not saved yet."), &.{ "Save all", "Discard", "Cancel" }, 2, Window, onWindowCloseChoice, self);
        return 1;
    }

    fn onWindowCloseChoice(self: *Window, choice: c_int) void {
        switch (choice) {
            0 => for (self.tabs.items) |t| if (t.isDirty() and !t.save()) return,
            1 => {},
            else => return,
        }
        for (self.tabs.items) |t| if (t.session) |s| s.markSaved();
        self.window.as(gtk.Window).close();
    }

    fn onOpenChosen(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        const dialog: *gtk.FileDialog = @ptrCast(@alignCast(source.?));
        var err: ?*glib.Error = null;
        const file = dialog.openFinish(result, &err) orelse {
            if (err) |e| e.free();
            return;
        };
        defer file.as(gobject.Object).unref();
        const path = file.getPath() orelse return;
        defer glib.free(path);
        self.openFile(std.mem.span(path));
    }

    fn onMenubarAction(self: *Window, action: []const u8) void {
        const eql = std.mem.eql;
        if (eql(u8, action, "new-tab")) {
            _ = self.newTab() catch return;
            return;
        }
        if (eql(u8, action, "open")) {
            const dialog = gtk.FileDialog.new();
            defer dialog.as(gobject.Object).unref();
            return dialog.open(self.window.as(gtk.Window), null, onOpenChosen, self);
        }
        if (eql(u8, action, "close")) return self.window.as(gtk.Window).close();
        if (eql(u8, action, "close-tab")) {
            if (self.active()) |d| self.closeTab(d);
            return;
        }
        if (eql(u8, action, "next-tab") or eql(u8, action, "prev-tab")) {
            const n = self.tabs.items.len;
            if (n < 2) return;
            const cur: usize = @intCast(@max(0, self.notebook.getCurrentPage()));
            const next = if (eql(u8, action, "next-tab")) (cur + 1) % n else (cur + n - 1) % n;
            return self.notebook.setCurrentPage(@intCast(next));
        }
        if (self.active()) |d| d.perform(action);
    }
};

/// The file named on the command line, if any.
var initial_path: ?[:0]const u8 = null;

pub fn main(init: std.process.Init.Minimal) !void {
    cli.handle(init.args, .{ .name = "dkde-pdf", .summary = "PDF viewer and annotator", .usage = "[FILE]" });
    if (init.args.vector.len > 1) initial_path = std.mem.span(init.args.vector[1]);
    try common.runapp.run("org.dkde.pdf", Window, init);
}

test {
    _ = @import("layout.zig");
    _ = @import("session.zig");
}
