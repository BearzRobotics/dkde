//! The file manager window (SPEC.md 5.4).

const std = @import("std");
const gdk = @import("gdk4");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

const archive = @import("archive.zig");
const context = @import("context.zig");
const clipboard = @import("clipboard.zig");
const ops = @import("ops.zig");
const props = @import("props.zig");
const pure = @import("pure.zig");

const log = std.log.scoped(.files);

const list_attributes = "standard::name,standard::display-name,standard::type,standard::icon," ++
    "standard::content-type,standard::size,standard::is-hidden,standard::is-backup," ++
    "time::modified,access::can-rename,access::can-delete";

const Column = enum { name, size, kind, modified };

/// How a folder is shown (SPEC.md 5.4). The tag names are the `view` values in files.conf.
const ViewMode = enum {
    details,
    list,
    small,
    medium,
    large,

    fn parse(text: []const u8) ViewMode {
        if (std.mem.eql(u8, text, "grid")) return .medium; // the older setting
        return std.meta.stringToEnum(ViewMode, text) orelse .details;
    }
};
const columns = [_]Column{ .name, .size, .kind, .modified };

/// Everything that belongs to one tab. The window's own fields of the same
/// names always hold the *active* tab's state; switching tabs swaps them.
const Tab = struct {
    dir_list: *gtk.DirectoryList,
    filter: *gtk.CustomFilter,
    selection: *gtk.MultiSelection,
    column_view: *gtk.ColumnView,
    grid_view: *gtk.GridView,
    view_stack: *gtk.Stack,
    scroller_list: *gtk.ScrolledWindow,
    scroller_grid: *gtk.ScrolledWindow,
    current: *gio.File,
    back: std.ArrayList(*gio.File),
    forward: std.ArrayList(*gio.File),
    query: [128]u8,
    query_len: usize,
    label: *gtk.Label,
};

pub const FilesWindow = struct {
    allocator: std.mem.Allocator,
    config: *common.Config,
    window: *gtk.ApplicationWindow,
    view_mode: ViewMode = .details,

    // Model chain: DirectoryList -> filter -> sort -> selection.
    dir_list: *gtk.DirectoryList,
    filter: *gtk.CustomFilter,
    selection: *gtk.MultiSelection,
    column_view: *gtk.ColumnView,
    grid_view: *gtk.GridView,
    view_stack: *gtk.Stack,
    scroller_list: *gtk.ScrolledWindow,
    scroller_grid: *gtk.ScrolledWindow,

    sidebar: *gtk.ListBox,
    /// Navigation target of each sidebar row, null for headings.
    sidebar_paths: std.ArrayList(?[:0]u8) = .empty,
    sidebar_bookmark: std.ArrayList(bool) = .empty,

    path_stack: *gtk.Stack,
    crumbs: *gtk.Box,
    crumb_ctxs: std.ArrayList(*CrumbCtx) = .empty,
    path_entry: *gtk.Entry,
    search: *gtk.SearchEntry,
    status: *gtk.Label,
    /// For archive commands that finish after the user may have closed the window.
    proc_guard: *common.proc.Guard(FilesWindow) = undefined,
    progress_box: *gtk.Box,
    progress_bar: *gtk.ProgressBar,
    progress_label: *gtk.Label,
    back_button: *gtk.Button,
    forward_button: *gtk.Button,

    current: *gio.File,
    back: std.ArrayList(*gio.File) = .empty,
    forward: std.ArrayList(*gio.File) = .empty,

    show_hidden: bool = false,
    /// Lower-cased type-to-search text; empty shows everything.
    query: [128]u8 = undefined,
    query_len: usize = 0,

    notebook: *gtk.Notebook,
    tabs: std.ArrayList(*Tab) = .empty,
    active_tab: usize = 0,
    /// True while code (not the user) changes the notebook's page.
    switching: bool = false,

    job: ?*ops.Job = null,
    /// Set by a cell's right-click so the background handler skips it.
    menu_handled: bool = false,

    // ---- construction ----------------------------------------------------

    pub fn create(allocator: std.mem.Allocator, app: *gtk.Application, config: *common.Config, start: ?[:0]const u8) !*FilesWindow {
        const self = try allocator.create(FilesWindow);
        errdefer allocator.destroy(self);

        const start_file = if (start) |p| gio.File.newForCommandlineArg(p) else gio.File.newForPath(glib.getHomeDir());

        self.* = .{
            .allocator = allocator,
            .config = config,
            .window = gtk.ApplicationWindow.new(app),
            .dir_list = undefined,
            .filter = undefined,
            .selection = undefined,
            .column_view = undefined,
            .grid_view = undefined,
            .view_stack = undefined,
            .scroller_list = undefined,
            .scroller_grid = undefined,
            .notebook = gtk.Notebook.new(),
            .sidebar = gtk.ListBox.new(),
            .path_stack = gtk.Stack.new(),
            .crumbs = gtk.Box.new(.horizontal, 0),
            .path_entry = gtk.Entry.new(),
            .search = gtk.SearchEntry.new(),
            .status = gtk.Label.new(""),
            .progress_box = gtk.Box.new(.horizontal, 8),
            .progress_bar = gtk.ProgressBar.new(),
            .progress_label = gtk.Label.new(""),
            .back_button = gtk.Button.newFromIconName("go-previous-symbolic"),
            .forward_button = gtk.Button.newFromIconName("go-next-symbolic"),
            .current = start_file,
        };

        self.proc_guard = common.proc.Guard(FilesWindow).create(self);
        if (config.getString(allocator, "files", "view", "details")) |v| {
            defer allocator.free(v);
            self.view_mode = ViewMode.parse(v);
        } else |_| {}
        self.makeViews();
        self.buildWindow(app);
        self.registerTab();
        self.installShortcuts();
        self.rebuildSidebar();
        self.go(self.current, false);
        _ = gtk.Widget.signals.destroy.connect(self.window, *FilesWindow, &onWindowDestroy, self, .{});
        return self;
    }

    fn onWindowDestroy(_: *gtk.ApplicationWindow, self: *FilesWindow) callconv(.c) void {
        self.proc_guard.kill();
        if (self.job) |job| job.cancel();
        for (self.crumb_ctxs.items) |ctx| {
            self.allocator.free(ctx.path);
            self.allocator.destroy(ctx);
        }
        self.crumb_ctxs.deinit(self.allocator);
        for (self.sidebar_paths.items) |p| if (p) |path| self.allocator.free(path);
        self.sidebar_paths.deinit(self.allocator);
        self.sidebar_bookmark.deinit(self.allocator);
        // The live state is in the window's fields; fold it into its tab, then free all tabs.
        if (self.tabs.items.len > 0) self.snapshotInto(self.tabs.items[self.active_tab]);
        for (self.tabs.items) |tab| {
            tab.current.as(gobject.Object).unref();
            for (tab.back.items) |f| f.as(gobject.Object).unref();
            tab.back.deinit(self.allocator);
            for (tab.forward.items) |f| f.as(gobject.Object).unref();
            tab.forward.deinit(self.allocator);
            self.allocator.destroy(tab);
        }
        self.tabs.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Creates a fresh set of models and views for a new tab and puts them in
    /// the window's per-tab fields (callers save the old set first).
    fn makeViews(self: *FilesWindow) void {
        self.dir_list = gtk.DirectoryList.new(list_attributes, null);
        self.dir_list.setIoPriority(glib.PRIORITY_DEFAULT);
        self.dir_list.setMonitored(1);
        self.filter = gtk.CustomFilter.new(filterFunc, self, null);
        self.column_view = gtk.ColumnView.new(null);
        self.view_stack = gtk.Stack.new();
        self.scroller_list = gtk.ScrolledWindow.new();
        self.scroller_grid = gtk.ScrolledWindow.new();
        self.query_len = 0;
        self.buildModels();

        self.scroller_list.setChild(self.column_view.as(gtk.Widget));
        self.scroller_grid.setChild(self.grid_view.as(gtk.Widget));
        _ = self.view_stack.addNamed(self.scroller_list.as(gtk.Widget), "list");
        _ = self.view_stack.addNamed(self.scroller_grid.as(gtk.Widget), "grid");
        self.view_stack.as(gtk.Widget).setHexpand(1);
        self.view_stack.as(gtk.Widget).setVexpand(1);
        self.applyViewTo(self.view_stack, self.grid_view);

        // Right-click on empty space.
        const bg_click = gtk.GestureClick.new();
        bg_click.as(gtk.GestureSingle).setButton(3);
        _ = gtk.GestureClick.signals.pressed.connect(bg_click, *FilesWindow, &onBackgroundRightClick, self, .{});
        self.view_stack.as(gtk.Widget).addController(bg_click.as(gtk.EventController));
    }

    fn buildModels(self: *FilesWindow) void {
        const filtered = gtk.FilterListModel.new(self.dir_list.as(gio.ListModel), self.filter.as(gtk.Filter));
        const sorter = self.column_view.getSorter();
        const sorted = gtk.SortListModel.new(filtered.as(gio.ListModel), sorter);
        self.selection = gtk.MultiSelection.new(sorted.as(gio.ListModel));

        // Details view.
        self.column_view.setModel(self.selection.as(gtk.SelectionModel));
        self.column_view.setEnableRubberband(1);
        self.column_view.as(gtk.Widget).addCssClass("dkde-files-view");
        const titles = [_][:0]const u8{ "Name", "Size", "Type", "Modified" };
        inline for (columns, 0..) |kind, i| {
            const factory = gtk.SignalListItemFactory.new();
            _ = gtk.SignalListItemFactory.signals.setup.connect(factory, *FilesWindow, &onCellSetup, self, .{});
            _ = gtk.SignalListItemFactory.signals.bind.connect(factory, *Column, &onCellBind, @constCast(&columns[i]), .{});
            const column = gtk.ColumnViewColumn.new(common.tr(titles[i]), factory.as(gtk.ListItemFactory));
            column.setSorter(gtk.CustomSorter.new(compareFunc, @ptrCast(@constCast(&columns[i])), null).as(gtk.Sorter));
            column.setResizable(1);
            column.setExpand(@intFromBool(kind == .name));
            self.column_view.appendColumn(column);
            if (kind == .name) self.column_view.sortByColumn(column, .ascending);
        }
        _ = gtk.ColumnView.signals.activate.connect(self.column_view, *FilesWindow, &onActivate, self, .{});

        // Icon view shares the same selection model.
        const grid_factory = gtk.SignalListItemFactory.new();
        _ = gtk.SignalListItemFactory.signals.setup.connect(grid_factory, *FilesWindow, &onGridSetup, self, .{});
        _ = gtk.SignalListItemFactory.signals.bind.connect(grid_factory, *FilesWindow, &onGridBind, self, .{});
        self.grid_view = gtk.GridView.new(self.selection.as(gtk.SelectionModel), grid_factory.as(gtk.ListItemFactory));
        self.grid_view.setEnableRubberband(1);
        self.grid_view.setMaxColumns(12);
        self.grid_view.as(gtk.Widget).addCssClass("dkde-files-view");
        _ = gtk.GridView.signals.activate.connect(self.grid_view, *FilesWindow, &onGridActivate, self, .{});

        _ = gio.ListModel.signals.items_changed.connect(self.selection.as(gio.ListModel), *FilesWindow, &onItemsChanged, self, .{});
        _ = gtk.SelectionModel.signals.selection_changed.connect(self.selection.as(gtk.SelectionModel), *FilesWindow, &onSelectionChanged, self, .{});
    }

    fn buildWindow(self: *FilesWindow, app: *gtk.Application) void {
        const window = self.window;
        window.as(gtk.Window).setDefaultSize(960, 640);
        window.as(gtk.Widget).addCssClass("dkde");
        window.as(gtk.Window).setTitle(common.tr("Files"));

        // Header: navigation, path bar, search, view switch.
        const header = common.header.create(window.as(gtk.Window), "system-file-manager", false);
        _ = gtk.Button.signals.clicked.connect(self.back_button, *FilesWindow, &onBackClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(self.forward_button, *FilesWindow, &onForwardClicked, self, .{});
        const up = gtk.Button.newFromIconName("go-up-symbolic");
        _ = gtk.Button.signals.clicked.connect(up, *FilesWindow, &onUpClicked, self, .{});
        header.packStart(self.back_button.as(gtk.Widget));
        header.packStart(self.forward_button.as(gtk.Widget));
        header.packStart(up.as(gtk.Widget));

        self.crumbs.as(gtk.Widget).addCssClass("linked");
        self.path_entry.as(gtk.Widget).setHexpand(1);
        _ = gtk.Entry.signals.activate.connect(self.path_entry, *FilesWindow, &onPathEntryActivate, self, .{});
        const entry_keys = gtk.EventControllerKey.new();
        _ = gtk.EventControllerKey.signals.key_pressed.connect(entry_keys, *FilesWindow, &onPathEntryKey, self, .{});
        self.path_entry.as(gtk.Widget).addController(entry_keys.as(gtk.EventController));
        _ = self.path_stack.addNamed(self.crumbs.as(gtk.Widget), "crumbs");
        _ = self.path_stack.addNamed(self.path_entry.as(gtk.Widget), "entry");
        self.path_stack.as(gtk.Widget).setHexpand(1);
        header.setTitleWidget(self.path_stack.as(gtk.Widget));

        self.search.setPlaceholderText(common.tr("Search this folder"));
        _ = gtk.SearchEntry.signals.search_changed.connect(self.search, *FilesWindow, &onSearchChanged, self, .{});
        _ = gtk.SearchEntry.signals.stop_search.connect(self.search, *FilesWindow, &onSearchStop, self, .{});
        header.packEnd(self.search.as(gtk.Widget));

        // Tabs.
        self.notebook.setScrollable(1);
        self.notebook.setShowTabs(0);
        self.notebook.as(gtk.Widget).setHexpand(1);
        self.notebook.as(gtk.Widget).setVexpand(1);
        _ = gtk.Notebook.signals.switch_page.connect(self.notebook, *FilesWindow, &onSwitchPage, self, .{});

        const cancel = gtk.Button.newWithLabel(common.tr("Cancel"));
        _ = gtk.Button.signals.clicked.connect(cancel, *FilesWindow, &onCancelJob, self, .{});
        self.progress_label.setXalign(0);
        self.progress_bar.as(gtk.Widget).setHexpand(1);
        self.progress_bar.as(gtk.Widget).setValign(.center);
        self.progress_box.append(self.progress_label.as(gtk.Widget));
        self.progress_box.append(self.progress_bar.as(gtk.Widget));
        self.progress_box.append(cancel.as(gtk.Widget));
        self.progress_box.as(gtk.Widget).setVisible(0);
        self.progress_box.as(gtk.Widget).setMarginStart(8);
        self.progress_box.as(gtk.Widget).setMarginEnd(8);

        self.status.setXalign(0);
        self.status.as(gtk.Widget).addCssClass("dkde-files-status");
        self.status.as(gtk.Widget).setMarginStart(8);

        // Sidebar of places and bookmarks.
        self.sidebar.as(gtk.Widget).addCssClass("navigation-sidebar");
        _ = gtk.ListBox.signals.row_activated.connect(self.sidebar, *FilesWindow, &onSidebarActivated, self, .{});
        const side_click = gtk.GestureClick.new();
        side_click.as(gtk.GestureSingle).setButton(3);
        _ = gtk.GestureClick.signals.pressed.connect(side_click, *FilesWindow, &onSidebarRightClick, self, .{});
        self.sidebar.as(gtk.Widget).addController(side_click.as(gtk.EventController));
        const side_scroller = gtk.ScrolledWindow.new();
        side_scroller.setChild(self.sidebar.as(gtk.Widget));
        side_scroller.as(gtk.Widget).setSizeRequest(190, -1);

        const right = gtk.Box.new(.vertical, 0);
        right.append(self.notebook.as(gtk.Widget));
        right.append(self.progress_box.as(gtk.Widget));
        right.append(self.status.as(gtk.Widget));

        const paned = gtk.Paned.new(.horizontal);
        paned.setStartChild(side_scroller.as(gtk.Widget));
        paned.setEndChild(right.as(gtk.Widget));
        paned.setShrinkStartChild(0);
        paned.setResizeStartChild(0);

        self.show_hidden = self.config.getBool("files", "show-hidden", false);

        // Classic menu bar above the panes.
        const mb = common.menubar;
        const menus = [_]mb.Menu{
            .{ .label = "_File", .entries = &.{
                mb.item("New _Tab", "new-tab", "<Control>t"),
                mb.item("New _Folder", "new-folder", "<Control><Shift>n"),
                mb.item("_Open", "open", null),
                mb.item("Open in New _Window", "open-window", null),
                mb.item("Open _Terminal Here", "terminal-here", null),
                mb.item("Open Folder as _Administrator", "open-admin", null),
                mb.item("_Properties", "properties", "<Alt>Return"),
                .separator,
                mb.item("_Close Tab", "close-tab", "<Control>w"),
                mb.item("E_xit", "close", "<Control>q"),
            } },
            .{ .label = "_Edit", .entries = &.{
                mb.item("Cu_t", "cut", "<Control>x"),
                mb.item("_Copy", "copy", "<Control>c"),
                mb.item("_Paste", "paste", "<Control>v"),
                .separator,
                mb.item("_Rename", "rename", "F2"),
                mb.item("Move to _Trash", "trash", "Delete"),
                mb.item("_Delete Permanently", "delete-permanent", "<Shift>Delete"),
                .separator,
                mb.item("_Restore from Trash", "restore", null),
                mb.item("_Empty Trash", "empty-trash", null),
            } },
            .{ .label = "_View", .entries = &.{
                mb.check("_Details", "view-details", self.view_mode == .details),
                mb.check("_List", "view-list", self.view_mode == .list),
                mb.check("_Small Icons", "view-small", self.view_mode == .small),
                mb.check("_Medium Icons", "view-medium", self.view_mode == .medium),
                mb.check("Lar_ge Icons", "view-large", self.view_mode == .large),
                .separator,
                mb.check("Show _Hidden Files", "toggle-hidden", self.show_hidden),
            } },
            .{ .label = "_Go", .entries = &.{
                mb.item("_Back", "back", "<Alt>Left"),
                mb.item("_Forward", "forward", "<Alt>Right"),
                mb.item("_Up", "up", "<Alt>Up"),
                mb.item("_Location…", "focus-path", "<Control>l"),
                .separator,
                mb.item("Add _Bookmark", "bookmark", "<Control>d"),
            } },
        };
        const menu_bar = mb.build(app, window, &menus, FilesWindow, onMenubarAction, self);
        const root = gtk.Box.new(.vertical, 0);
        root.append(menu_bar.as(gtk.Widget));
        paned.as(gtk.Widget).setVexpand(1);
        root.append(paned.as(gtk.Widget));
        window.as(gtk.Window).setChild(root.as(gtk.Widget));
    }

    pub fn present(self: *FilesWindow) void {
        self.window.as(gtk.Window).present();
        // Dev aid for screenshot checks: open the context menu on its own.
        if (glib.getenv("DKDE_DEBUG_OPEN_TAB") != null) _ = glib.timeoutAdd(1000, openDebugTab, self);
        if (glib.getenv("DKDE_DEBUG_OPEN_MENU") != null) _ = glib.timeoutAdd(1500, openDebugMenu, self);
    }

    fn openDebugTab(data: ?*anyopaque) callconv(.c) c_int {
        const self: *FilesWindow = @ptrCast(@alignCast(data.?));
        self.addTab(gio.File.newForPath("/usr/share"));
        return 0;
    }

    fn openDebugMenu(data: ?*anyopaque) callconv(.c) c_int {
        const self: *FilesWindow = @ptrCast(@alignCast(data.?));
        self.showContextMenu(self.view_stack.as(gtk.Widget), 200, 200, false);
        return 0;
    }

    // ---- tabs -----------------------------------------------------------------

    fn snapshotInto(self: *FilesWindow, t: *Tab) void {
        t.dir_list = self.dir_list;
        t.filter = self.filter;
        t.selection = self.selection;
        t.column_view = self.column_view;
        t.grid_view = self.grid_view;
        t.view_stack = self.view_stack;
        t.scroller_list = self.scroller_list;
        t.scroller_grid = self.scroller_grid;
        t.current = self.current;
        t.back = self.back;
        t.forward = self.forward;
        t.query = self.query;
        t.query_len = self.query_len;
    }

    fn loadFrom(self: *FilesWindow, t: *const Tab) void {
        self.dir_list = t.dir_list;
        self.filter = t.filter;
        self.selection = t.selection;
        self.column_view = t.column_view;
        self.grid_view = t.grid_view;
        self.view_stack = t.view_stack;
        self.scroller_list = t.scroller_list;
        self.scroller_grid = t.scroller_grid;
        self.current = t.current;
        self.back = t.back;
        self.forward = t.forward;
        self.query = t.query;
        self.query_len = t.query_len;
        self.search.setKeyCaptureWidget(self.view_stack.as(gtk.Widget));
    }

    const TabClose = struct { window: *FilesWindow, page: *gtk.Widget };

    fn onTabCloseDestroy(_: *gtk.Button, ctx: *TabClose) callconv(.c) void {
        ctx.window.allocator.destroy(ctx);
    }

    fn onTabCloseClicked(_: *gtk.Button, ctx: *TabClose) callconv(.c) void {
        for (ctx.window.tabs.items, 0..) |t, i| {
            if (t.view_stack.as(gtk.Widget) == ctx.page) return ctx.window.closeTab(i);
        }
    }

    /// The tab strip contents: the folder's name and a close button.
    fn tabHeader(self: *FilesWindow, label: *gtk.Label, page: *gtk.Widget) *gtk.Box {
        label.setEllipsize(.end);
        label.setWidthChars(10);
        label.setMaxWidthChars(22);
        const close = gtk.Button.newFromIconName("window-close-symbolic");
        close.setHasFrame(0);
        close.as(gtk.Widget).setTooltipText(common.tr("Close tab"));
        const ctx = self.allocator.create(TabClose) catch @panic("OOM");
        ctx.* = .{ .window = self, .page = page };
        _ = gtk.Button.signals.clicked.connect(close, *TabClose, &onTabCloseClicked, ctx, .{});
        _ = gtk.Widget.signals.destroy.connect(close, *TabClose, &onTabCloseDestroy, ctx, .{});
        const box = gtk.Box.new(.horizontal, 6);
        box.append(label.as(gtk.Widget));
        box.append(close.as(gtk.Widget));
        return box;
    }

    /// Registers the views already in the window's fields as the first tab.
    fn registerTab(self: *FilesWindow) void {
        const label = gtk.Label.new("Files");
        const tab = self.allocator.create(Tab) catch @panic("OOM");
        tab.label = label;
        self.snapshotInto(tab);
        self.tabs.append(self.allocator, tab) catch @panic("OOM");
        _ = self.notebook.appendPage(self.view_stack.as(gtk.Widget), self.tabHeader(label, self.view_stack.as(gtk.Widget)).as(gtk.Widget));
        self.search.setKeyCaptureWidget(self.view_stack.as(gtk.Widget));
        self.notebook.setShowTabs(0);
    }

    /// Opens `file` in a new tab and shows it.
    pub fn addTab(self: *FilesWindow, file: *gio.File) void {
        self.snapshotInto(self.tabs.items[self.active_tab]);
        self.makeViews();
        self.current = @ptrCast(file.as(gobject.Object).ref());
        self.back = .empty;
        self.forward = .empty;

        const label = gtk.Label.new("Files");
        const tab = self.allocator.create(Tab) catch return;
        tab.label = label;
        self.snapshotInto(tab);
        self.tabs.append(self.allocator, tab) catch return;
        self.active_tab = self.tabs.items.len - 1;

        self.switching = true;
        const index = self.notebook.appendPage(self.view_stack.as(gtk.Widget), self.tabHeader(label, self.view_stack.as(gtk.Widget)).as(gtk.Widget));
        self.notebook.setCurrentPage(index);
        self.switching = false;
        self.notebook.setShowTabs(@intFromBool(self.tabs.items.len > 1));
        self.search.setKeyCaptureWidget(self.view_stack.as(gtk.Widget));
        self.go(self.current, false);
    }

    fn activateTab(self: *FilesWindow, index: usize) void {
        if (index == self.active_tab or index >= self.tabs.items.len) return;
        self.snapshotInto(self.tabs.items[self.active_tab]);
        self.active_tab = index;
        self.loadFrom(self.tabs.items[index]);
        self.switching = true;
        self.notebook.setCurrentPage(@intCast(index));
        self.switching = false;
        // Things that follow the folder, not the tab's widgets.
        self.filter.as(gtk.Filter).changed(.different);
        self.rebuildCrumbs();
        self.path_stack.setVisibleChildName("crumbs");
        self.back_button.as(gtk.Widget).setSensitive(@intFromBool(self.back.items.len > 0));
        self.forward_button.as(gtk.Widget).setSensitive(@intFromBool(self.forward.items.len > 0));
        const name = self.current.getBasename();
        defer if (name) |n| glib.free(n);
        var buf: [512]u8 = undefined;
        self.window.as(gtk.Window).setTitle(std.fmt.bufPrintSentinel(&buf, "{s}", .{if (name) |n| std.mem.span(n) else "Files"}, 0) catch "Files");
        self.updateStatus();
    }

    fn onSwitchPage(_: *gtk.Notebook, page: *gtk.Widget, _: c_uint, self: *FilesWindow) callconv(.c) void {
        if (self.switching) return;
        for (self.tabs.items, 0..) |t, i| {
            if (t.view_stack.as(gtk.Widget) == page) return self.activateTab(i);
        }
    }

    fn closeTab(self: *FilesWindow, index: usize) void {
        if (self.tabs.items.len <= 1) return self.window.as(gtk.Window).close();
        self.snapshotInto(self.tabs.items[self.active_tab]);
        const tab = self.tabs.orderedRemove(index);
        self.notebook.removePage(@intCast(index));
        tab.current.as(gobject.Object).unref();
        for (tab.back.items) |f| f.as(gobject.Object).unref();
        tab.back.deinit(self.allocator);
        for (tab.forward.items) |f| f.as(gobject.Object).unref();
        tab.forward.deinit(self.allocator);
        self.allocator.destroy(tab);

        if (index == self.active_tab) {
            // The live state belonged to the closed tab; load a neighbour.
            self.active_tab = @min(index, self.tabs.items.len - 1);
            const neighbour = self.active_tab;
            self.active_tab = if (neighbour == 0) 1 else 0; // force activateTab to run
            if (self.tabs.items.len == 1) self.active_tab = 1;
            self.loadFrom(self.tabs.items[neighbour]);
            self.active_tab = neighbour;
            self.switching = true;
            self.notebook.setCurrentPage(@intCast(neighbour));
            self.switching = false;
            self.filter.as(gtk.Filter).changed(.different);
            self.rebuildCrumbs();
            self.updateStatus();
        } else if (index < self.active_tab) {
            self.active_tab -= 1;
        }
        self.notebook.setShowTabs(@intFromBool(self.tabs.items.len > 1));
    }

    // ---- navigation ------------------------------------------------------

    /// Navigates to `file` (takes no ownership; a reference is kept).
    pub fn go(self: *FilesWindow, file: *gio.File, push_history: bool) void {
        if (push_history and self.current != file) {
            self.back.append(self.allocator, self.current) catch {};
            for (self.forward.items) |f| f.as(gobject.Object).unref();
            self.forward.clearRetainingCapacity();
        } else if (self.current != file) {
            self.current.as(gobject.Object).unref();
        }
        if (self.current != file) self.current = @ptrCast(file.as(gobject.Object).ref());
        self.afterNavigate();
    }

    fn afterNavigate(self: *FilesWindow) void {
        self.dir_list.setFile(self.current);
        self.search.as(gtk.Editable).setText("");
        self.query_len = 0;
        _ = self.selection.as(gtk.SelectionModel).unselectAll();
        self.rebuildCrumbs();
        self.path_stack.setVisibleChildName("crumbs");
        self.back_button.as(gtk.Widget).setSensitive(@intFromBool(self.back.items.len > 0));
        self.forward_button.as(gtk.Widget).setSensitive(@intFromBool(self.forward.items.len > 0));

        const name = self.current.getBasename();
        defer if (name) |n| glib.free(n);
        var buf: [512]u8 = undefined;
        const title = std.fmt.bufPrintSentinel(&buf, "{s}", .{if (name) |n| std.mem.span(n) else "Files"}, 0) catch "Files";
        self.window.as(gtk.Window).setTitle(title);
        if (self.tabs.items.len > self.active_tab) self.tabs.items[self.active_tab].label.setText(title);
        self.updateStatus();
    }

    fn goBack(self: *FilesWindow) void {
        const prev = self.back.pop() orelse return;
        self.forward.append(self.allocator, self.current) catch {};
        self.current = prev;
        self.afterNavigate();
    }

    fn goForward(self: *FilesWindow) void {
        const next = self.forward.pop() orelse return;
        self.back.append(self.allocator, self.current) catch {};
        self.current = next;
        self.afterNavigate();
    }

    fn goUp(self: *FilesWindow) void {
        const parent = self.current.getParent() orelse return;
        defer parent.as(gobject.Object).unref();
        self.go(parent, true);
    }

    fn goPath(self: *FilesWindow, path: []const u8) void {
        const pathz = self.allocator.dupeSentinel(u8, path, 0) catch return;
        defer self.allocator.free(pathz);
        const file = gio.File.newForCommandlineArg(pathz);
        defer file.as(gobject.Object).unref();
        self.go(file, true);
    }

    fn isInTrash(self: *const FilesWindow) bool {
        const trash = trashFilesDir(self.allocator) catch return false;
        defer self.allocator.free(trash);
        const path = self.current.getPath() orelse return false;
        defer glib.free(path);
        return std.mem.startsWith(u8, std.mem.span(path), trash);
    }

    fn trashFilesDir(allocator: std.mem.Allocator) ![:0]u8 {
        return std.fmt.allocPrintSentinel(allocator, "{s}/Trash/files", .{std.mem.span(glib.getUserDataDir())}, 0);
    }

    fn rebuildCrumbs(self: *FilesWindow) void {
        while (self.crumbs.as(gtk.Widget).getFirstChild()) |child| self.crumbs.remove(child);
        for (self.crumb_ctxs.items) |ctx| {
            self.allocator.free(ctx.path);
            self.allocator.destroy(ctx);
        }
        self.crumb_ctxs.clearRetainingCapacity();

        const path_c = self.current.getPath() orelse {
            const uri = self.current.getUri();
            defer glib.free(uri);
            const label = gtk.Label.new(uri);
            self.crumbs.append(label.as(gtk.Widget));
            return;
        };
        defer glib.free(path_c);
        const path = std.mem.span(path_c);
        self.path_entry.as(gtk.Editable).setText(path_c);

        const list = pure.breadcrumbs(self.allocator, path) catch return;
        defer self.allocator.free(list);
        for (list) |crumb| {
            const ctx = self.allocator.create(CrumbCtx) catch return;
            ctx.* = .{ .window = self, .path = self.allocator.dupeSentinel(u8, crumb.path, 0) catch return };
            self.crumb_ctxs.append(self.allocator, ctx) catch return;
            const label = self.allocator.dupeSentinel(u8, crumb.label, 0) catch return;
            defer self.allocator.free(label);
            const button = gtk.Button.newWithLabel(label);
            _ = gtk.Button.signals.clicked.connect(button, *CrumbCtx, &onCrumbClicked, ctx, .{});
            self.crumbs.append(button.as(gtk.Widget));
        }
    }

    // ---- sidebar ---------------------------------------------------------

    fn rebuildSidebar(self: *FilesWindow) void {
        while (self.sidebar.as(gtk.Widget).getFirstChild()) |child| self.sidebar.remove(child);
        for (self.sidebar_paths.items) |p| if (p) |s| self.allocator.free(s);
        self.sidebar_paths.clearRetainingCapacity();
        self.sidebar_bookmark.clearRetainingCapacity();

        self.addSidebarRow(common.tr("Home"), "user-home-symbolic", std.mem.span(glib.getHomeDir()), false);
        const dirs = [_]struct { [:0]const u8, [:0]const u8, glib.UserDirectory }{
            .{ "Desktop", "user-desktop-symbolic", .directory_desktop },
            .{ "Documents", "folder-documents-symbolic", .directory_documents },
            .{ "Downloads", "folder-download-symbolic", .directory_download },
            .{ "Music", "folder-music-symbolic", .directory_music },
            .{ "Pictures", "folder-pictures-symbolic", .directory_pictures },
            .{ "Videos", "folder-videos-symbolic", .directory_videos },
        };
        inline for (dirs) |d| {
            if (glib.getUserSpecialDir(d[2])) |path| {
                if (!std.mem.eql(u8, std.mem.span(path), std.mem.span(glib.getHomeDir())))
                    self.addSidebarRow(common.tr(d[0]), d[1], std.mem.span(path), false);
            }
        }
        if (trashFilesDir(self.allocator)) |trash| {
            defer self.allocator.free(trash);
            self.addSidebarRow(common.tr("Trash"), "user-trash-symbolic", trash, false);
        } else |_| {}

        if (self.config.getStringList(self.allocator, "bookmarks", "paths") catch null) |list| {
            defer common.config.freeStringList(self.allocator, list);
            if (list.len > 0) self.addSidebarHeading(common.tr("Bookmarks"));
            for (list) |path| {
                const base = std.fs.path.basename(path);
                var buf: [256]u8 = undefined;
                const label = std.fmt.bufPrintSentinel(&buf, "{s}", .{base}, 0) catch continue;
                self.addSidebarRow(label, "folder-symbolic", path, true);
            }
        }

        // Mounted filesystems, read straight from the kernel (no gvfs).
        if (readMountinfo(self.allocator)) |content| {
            defer self.allocator.free(content);
            if (pure.parseMountinfo(self.allocator, content)) |mounts| {
                defer pure.freeMounts(self.allocator, mounts);
                if (mounts.len > 0) self.addSidebarHeading(common.tr("Devices"));
                for (mounts) |m| {
                    const label = if (std.mem.eql(u8, m.mount_point, "/")) "File System" else std.fs.path.basename(m.mount_point);
                    var buf: [256]u8 = undefined;
                    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{label}, 0) catch continue;
                    self.addSidebarRow(z, "drive-harddisk-symbolic", m.mount_point, false);
                }
            } else |_| {}
        } else |_| {}
    }

    fn readMountinfo(allocator: std.mem.Allocator) ![]u8 {
        var contents: [*]u8 = undefined;
        var length: usize = 0;
        if (glib.fileGetContents("/proc/self/mountinfo", &contents, &length, null) == 0) return error.Unreadable;
        defer glib.free(contents);
        return allocator.dupe(u8, contents[0..length]);
    }

    fn addSidebarRow(self: *FilesWindow, label: [:0]const u8, icon: [:0]const u8, path: []const u8, bookmark: bool) void {
        const target = self.allocator.dupeSentinel(u8, path, 0) catch return;
        self.sidebar_paths.append(self.allocator, target) catch return;
        self.sidebar_bookmark.append(self.allocator, bookmark) catch return;

        const row = gtk.Box.new(.horizontal, 8);
        row.append(gtk.Image.newFromIconName(icon).as(gtk.Widget));
        const text = gtk.Label.new(label);
        text.setXalign(0);
        row.append(text.as(gtk.Widget));
        self.sidebar.append(row.as(gtk.Widget));
    }

    fn addSidebarHeading(self: *FilesWindow, label: [:0]const u8) void {
        self.sidebar_paths.append(self.allocator, null) catch return;
        self.sidebar_bookmark.append(self.allocator, false) catch return;
        const text = gtk.Label.new(label);
        text.setXalign(0);
        text.as(gtk.Widget).addCssClass("heading");
        text.as(gtk.Widget).setMarginTop(8);
        self.sidebar.append(text.as(gtk.Widget));
        if (self.sidebar.getRowAtIndex(@intCast(self.sidebar_paths.items.len - 1))) |row| {
            row.setSelectable(0);
            row.setActivatable(0);
        }
    }

    // ---- model callbacks -------------------------------------------------

    fn filterFunc(item: *gobject.Object, data: ?*anyopaque) callconv(.c) c_int {
        const self: *FilesWindow = @ptrCast(@alignCast(data.?));
        const info: *gio.FileInfo = @ptrCast(item);
        if (!self.show_hidden and (info.getIsHidden() != 0 or info.getIsBackup() != 0)) return 0;
        if (self.query_len == 0) return 1;
        const name = std.mem.span(info.getDisplayName());
        return @intFromBool(std.ascii.findIgnoreCase(name, self.query[0..self.query_len]) != null);
    }

    fn compareFunc(a_raw: ?*const anyopaque, b_raw: ?*const anyopaque, data: ?*anyopaque) callconv(.c) c_int {
        const a: *gio.FileInfo = @ptrCast(@alignCast(@constCast(a_raw.?)));
        const b: *gio.FileInfo = @ptrCast(@alignCast(@constCast(b_raw.?)));
        const column: *const Column = @ptrCast(@alignCast(data.?));
        // Folders sort before files whatever the column.
        const a_dir = a.getFileType() == .directory;
        const b_dir = b.getFileType() == .directory;
        if (a_dir != b_dir) return if (a_dir) -1 else 1;

        const order: std.math.Order = switch (column.*) {
            .name => std.ascii.orderIgnoreCase(std.mem.span(a.getDisplayName()), std.mem.span(b.getDisplayName())),
            .size => std.math.order(a.getSize(), b.getSize()),
            .kind => std.mem.order(u8, std.mem.span(a.getContentType() orelse ""), std.mem.span(b.getContentType() orelse "")),
            .modified => std.math.order(a.getAttributeUint64("time::modified"), b.getAttributeUint64("time::modified")),
        };
        return switch (order) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        };
    }

    fn fileOf(info: *gio.FileInfo) ?*gio.File {
        const obj = info.getAttributeObject("standard::file") orelse return null;
        return @ptrCast(obj);
    }

    // ---- cells -----------------------------------------------------------

    fn onCellSetup(_: *gtk.SignalListItemFactory, item_obj: *gobject.Object, self: *FilesWindow) callconv(.c) void {
        const item: *gtk.ListItem = @ptrCast(item_obj);
        const box = gtk.Box.new(.horizontal, 8);
        const icon = gtk.Image.new();
        icon.setPixelSize(20);
        const label = gtk.Label.new(null);
        label.setXalign(0);
        label.setEllipsize(.end);
        box.append(icon.as(gtk.Widget));
        box.append(label.as(gtk.Widget));
        item.setChild(box.as(gtk.Widget));
        self.attachItemMenu(box.as(gtk.Widget), item);
    }

    fn onCellBind(_: *gtk.SignalListItemFactory, item_obj: *gobject.Object, column: *Column) callconv(.c) void {
        const item: *gtk.ListItem = @ptrCast(item_obj);
        const info: *gio.FileInfo = @ptrCast(item.getItem() orelse return);
        const box: *gtk.Box = @ptrCast(item.getChild().?);
        const icon: *gtk.Image = @ptrCast(box.as(gtk.Widget).getFirstChild().?);
        const label: *gtk.Label = @ptrCast(icon.as(gtk.Widget).getNextSibling().?);

        var buf: [256]u8 = undefined;
        switch (column.*) {
            .name => {
                icon.as(gtk.Widget).setVisible(1);
                if (info.getIcon()) |gicon| icon.setFromGicon(gicon) else icon.setFromIconName("text-x-generic");
                label.setText(info.getDisplayName());
            },
            .size => {
                icon.as(gtk.Widget).setVisible(0);
                const is_dir = info.getFileType() == .directory;
                var size_buf: [64]u8 = undefined;
                const text = if (is_dir) "" else pure.formatSize(&size_buf, @intCast(info.getSize()));
                label.setText(std.fmt.bufPrintSentinel(&buf, "{s}", .{text}, 0) catch "");
            },
            .kind => {
                icon.as(gtk.Widget).setVisible(0);
                if (info.getContentType()) |ct| {
                    const description = gio.contentTypeGetDescription(ct);
                    defer glib.free(description);
                    label.setText(description);
                } else label.setText("");
            },
            .modified => {
                icon.as(gtk.Widget).setVisible(0);
                if (info.getModificationDateTime()) |dt| {
                    defer dt.unref();
                    if (dt.format("%x %H:%M")) |text| {
                        defer glib.free(text);
                        label.setText(text);
                    }
                } else label.setText("");
            },
        }
    }

    fn onGridSetup(_: *gtk.SignalListItemFactory, item_obj: *gobject.Object, self: *FilesWindow) callconv(.c) void {
        const item: *gtk.ListItem = @ptrCast(item_obj);
        const mode = self.view_mode;
        const row = mode == .small or mode == .list;
        const box = gtk.Box.new(if (row) .horizontal else .vertical, if (row) 6 else 4);
        box.as(gtk.Widget).setSizeRequest(switch (mode) {
            .small => 190,
            .list => -1,
            .large => 140,
            else => 96,
        }, -1);
        const icon = gtk.Image.new();
        icon.setPixelSize(switch (mode) {
            .small, .list => 16,
            .large => 96,
            else => 48,
        });
        const label = gtk.Label.new(null);
        if (row) {
            label.setEllipsize(.end);
            label.setXalign(0);
            label.setMaxWidthChars(if (mode == .list) 60 else 22);
            box.as(gtk.Widget).setMarginTop(2);
            box.as(gtk.Widget).setMarginBottom(2);
            box.as(gtk.Widget).setMarginStart(4);
        } else {
            label.setEllipsize(.middle);
            label.setMaxWidthChars(if (mode == .large) 16 else 12);
            label.setWrap(1);
            label.setLines(2);
            label.setJustify(.center);
        }
        box.append(icon.as(gtk.Widget));
        box.append(label.as(gtk.Widget));
        item.setChild(box.as(gtk.Widget));
        self.attachItemMenu(box.as(gtk.Widget), item);
    }

    fn onGridBind(_: *gtk.SignalListItemFactory, item_obj: *gobject.Object, _: *FilesWindow) callconv(.c) void {
        const item: *gtk.ListItem = @ptrCast(item_obj);
        const info: *gio.FileInfo = @ptrCast(item.getItem() orelse return);
        const box: *gtk.Box = @ptrCast(item.getChild().?);
        const icon: *gtk.Image = @ptrCast(box.as(gtk.Widget).getFirstChild().?);
        const label: *gtk.Label = @ptrCast(icon.as(gtk.Widget).getNextSibling().?);
        if (info.getIcon()) |gicon| icon.setFromGicon(gicon) else icon.setFromIconName("text-x-generic");
        label.setText(info.getDisplayName());
    }

    /// Right-click on a cell selects its row (unless already selected) and
    /// opens the context menu there.
    fn attachItemMenu(self: *FilesWindow, widget: *gtk.Widget, item: *gtk.ListItem) void {
        const click = gtk.GestureClick.new();
        click.as(gtk.GestureSingle).setButton(3);
        const ctx = self.allocator.create(ItemMenuCtx) catch return;
        ctx.* = .{ .window = self, .item = item };
        _ = gtk.GestureClick.signals.pressed.connect(click, *ItemMenuCtx, &onItemRightClick, ctx, .{});
        _ = gtk.Widget.signals.destroy.connect(widget, *ItemMenuCtx, &onItemMenuDestroy, ctx, .{});
        widget.addController(click.as(gtk.EventController));
    }

    const ItemMenuCtx = struct { window: *FilesWindow, item: *gtk.ListItem };

    fn onItemMenuDestroy(_: *gtk.Widget, ctx: *ItemMenuCtx) callconv(.c) void {
        ctx.window.allocator.destroy(ctx);
    }

    fn onItemRightClick(gesture: *gtk.GestureClick, _: c_int, x: f64, y: f64, ctx: *ItemMenuCtx) callconv(.c) void {
        const self = ctx.window;
        const position = ctx.item.getPosition();
        const model = self.selection.as(gtk.SelectionModel);
        if (model.isSelected(position) == 0) _ = model.selectItem(position, 1);
        self.menu_handled = true;
        self.showContextMenu(gesture.as(gtk.EventController).getWidget() orelse return, x, y, true);
    }

    fn onBackgroundRightClick(gesture: *gtk.GestureClick, _: c_int, x: f64, y: f64, self: *FilesWindow) callconv(.c) void {
        if (self.menu_handled) {
            self.menu_handled = false;
            return;
        }
        _ = self.selection.as(gtk.SelectionModel).unselectAll();
        self.showContextMenu(gesture.as(gtk.EventController).getWidget() orelse return, x, y, false);
    }

    // ---- selection -------------------------------------------------------

    /// Selected files, each with its own reference. Free with `freeFiles`.
    fn selectedFiles(self: *FilesWindow) !std.ArrayList(*gio.File) {
        var out: std.ArrayList(*gio.File) = .empty;
        errdefer freeFiles(self.allocator, &out);
        const bits = self.selection.as(gtk.SelectionModel).getSelection();
        defer bits.unref();
        const n: usize = @intCast(bits.getSize());
        const model = self.selection.as(gio.ListModel);
        for (0..n) |i| {
            const pos = bits.getNth(@intCast(i));
            const obj: *gobject.Object = @ptrCast(@alignCast(model.getItem(pos) orelse continue));
            defer obj.unref();
            const info: *gio.FileInfo = @ptrCast(obj);
            const file = fileOf(info) orelse continue;
            try out.append(self.allocator, @ptrCast(file.as(gobject.Object).ref()));
        }
        return out;
    }

    fn freeFiles(allocator: std.mem.Allocator, list: *std.ArrayList(*gio.File)) void {
        for (list.items) |f| f.as(gobject.Object).unref();
        list.deinit(allocator);
    }

    fn updateStatus(self: *FilesWindow) void {
        const model = self.selection.as(gio.ListModel);
        const total = model.getNItems();
        const bits = self.selection.as(gtk.SelectionModel).getSelection();
        defer bits.unref();
        const selected = bits.getSize();
        var buf: [128]u8 = undefined;
        const text = if (selected > 0)
            std.fmt.bufPrintSentinel(&buf, "{d} of {d} selected", .{ selected, total }, 0) catch ""
        else
            std.fmt.bufPrintSentinel(&buf, "{d} items", .{total}, 0) catch "";
        self.status.setText(text);
    }

    // ---- file actions ----------------------------------------------------

    fn openSelected(self: *FilesWindow) void {
        var files = self.selectedFiles() catch return;
        defer freeFiles(self.allocator, &files);
        if (files.items.len == 1) {
            if (self.isDirectory(files.items[0])) return self.go(files.items[0], true);
        }
        for (files.items) |f| self.openFile(f);
    }

    fn isDirectory(_: *FilesWindow, file: *gio.File) bool {
        const info = file.queryInfo("standard::type", .{}, null, null) orelse return false;
        defer info.as(gobject.Object).unref();
        return info.getFileType() == .directory;
    }

    fn openFile(self: *FilesWindow, file: *gio.File) void {
        const uri = file.getUri();
        defer glib.free(uri);
        var err: ?*glib.Error = null;
        if (gio.AppInfo.launchDefaultForUri(uri, null, &err) == 0) {
            const message = if (err) |e| e.f_message orelse "unknown error" else "unknown error";
            common.dialogs.showError(self.window.as(gtk.Window), common.tr("Cannot open this file"), std.mem.span(message));
            if (err) |e| e.free();
        }
    }

    fn openWith(self: *FilesWindow, file: *gio.File, app: *gio.AppInfo) void {
        _ = self;
        var list = glib.List{ .f_data = file, .f_next = null, .f_prev = null };
        var err: ?*glib.Error = null;
        // launch() takes files, not URIs.
        _ = app.launch(&list, null, &err);
        if (err) |e| e.free();
    }

    /// Puts the selected files on the system clipboard, so they can be pasted
    /// into another window or another program.
    fn copySelection(self: *FilesWindow, cut: bool) void {
        var files = self.selectedFiles() catch return;
        defer freeFiles(self.allocator, &files);
        if (files.items.len == 0) return;

        var uris: std.ArrayList([]const u8) = .empty;
        defer {
            for (uris.items) |u| glib.free(@constCast(u.ptr));
            uris.deinit(self.allocator);
        }
        var paths: std.ArrayList(u8) = .empty;
        defer paths.deinit(self.allocator);
        for (files.items) |f| {
            uris.append(self.allocator, std.mem.span(f.getUri())) catch return;
            if (paths.items.len > 0) paths.append(self.allocator, '\n') catch return;
            if (f.getPath()) |p| {
                defer glib.free(p);
                paths.appendSlice(self.allocator, std.mem.span(p)) catch return;
            } else paths.appendSlice(self.allocator, std.mem.span(f.getUri())) catch return;
        }
        const gnome = clipboard.gnomeText(self.allocator, cut, uris.items) catch return;
        defer self.allocator.free(gnome);
        const list = clipboard.uriListText(self.allocator, uris.items) catch return;
        defer self.allocator.free(list);

        var providers = [_]*gdk.ContentProvider{
            gdk.ContentProvider.newForBytes(clipboard.gnome_mime, glib.Bytes.new(gnome.ptr, gnome.len)),
            gdk.ContentProvider.newForBytes(clipboard.uri_list_mime, glib.Bytes.new(list.ptr, list.len)),
            // Pasting into a text field gives the paths.
            gdk.ContentProvider.newForBytes("text/plain;charset=utf-8", glib.Bytes.new(paths.items.ptr, paths.items.len)),
        };
        const union_provider = gdk.ContentProvider.newUnion(&providers, providers.len);
        _ = self.window.as(gtk.Widget).getClipboard().setContent(union_provider);
    }

    /// True when the clipboard holds files.
    fn clipboardHasFiles(self: *FilesWindow) bool {
        const formats = self.window.as(gtk.Widget).getClipboard().getFormats();
        return formats.containMimeType(clipboard.gnome_mime) != 0 or formats.containMimeType(clipboard.uri_list_mime) != 0;
    }

    fn paste(self: *FilesWindow) void {
        if (self.job != null or !self.clipboardHasFiles()) return;
        const mimes = [_]?[*:0]const u8{ clipboard.gnome_mime, clipboard.uri_list_mime, null };
        self.window.as(gtk.Widget).getClipboard().readAsync(@ptrCast(@constCast(&mimes)), glib.PRIORITY_DEFAULT, null, onClipboardRead, self);
    }

    fn onClipboardRead(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *FilesWindow = @ptrCast(@alignCast(data.?));
        const cb: *gdk.Clipboard = @ptrCast(@alignCast(source.?));
        var err: ?*glib.Error = null;
        var mime: [*:0]const u8 = undefined;
        const stream = cb.readFinish(result, &mime, &err) orelse {
            if (err) |e| e.free();
            return;
        };
        defer stream.as(gobject.Object).unref();

        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(self.allocator);
        while (text.items.len < 1 << 22) {
            const chunk = stream.readBytes(65536, null, &err) orelse {
                if (err) |e| e.free();
                return;
            };
            defer chunk.unref();
            const n = chunk.getSize();
            if (n == 0) break;
            const ptr: [*]const u8 = @ptrCast(chunk.getData(null) orelse break);
            text.appendSlice(self.allocator, ptr[0..n]) catch return;
        }

        const parsed = clipboard.parse(self.allocator, text.items) catch return;
        defer parsed.deinit(self.allocator);
        var sources: std.ArrayList(*gio.File) = .empty;
        defer {
            for (sources.items) |f| f.as(gobject.Object).unref();
            sources.deinit(self.allocator);
        }
        for (parsed.uris) |uri| {
            const z = self.allocator.dupeSentinel(u8, uri, 0) catch return;
            defer self.allocator.free(z);
            sources.append(self.allocator, gio.File.newForUri(z)) catch return;
        }
        if (sources.items.len == 0 or self.job != null) return;
        self.startJob(if (parsed.cut) .move else .copy, sources.items, self.current);
        // A cut can be pasted once.
        if (parsed.cut) _ = cb.setContent(null);
    }

    fn startJob(self: *FilesWindow, mode: ops.Mode, sources: []const *gio.File, dest: *gio.File) void {
        self.progress_box.as(gtk.Widget).setVisible(1);
        self.progress_bar.setFraction(0);
        self.job = ops.Job.start(self.allocator, mode, sources, dest, self.window.as(gtk.Window), .{
            .data = self,
            .progress = onJobProgress,
            .finished = onJobFinished,
        }) catch |err| {
            common.dialogs.showError(self.window.as(gtk.Window), common.tr("Cannot start the operation"), @errorName(err));
            self.progress_box.as(gtk.Widget).setVisible(0);
            return;
        };
    }

    fn onJobProgress(data: *anyopaque, text: [:0]const u8, fraction: f64) void {
        const self: *FilesWindow = @ptrCast(@alignCast(data));
        if (text.len > 0) self.progress_label.setText(text);
        self.progress_bar.setFraction(fraction);
    }

    fn onJobFinished(data: *anyopaque, _: bool) void {
        const self: *FilesWindow = @ptrCast(@alignCast(data));
        self.job = null;
        self.progress_box.as(gtk.Widget).setVisible(0);
    }

    fn onCancelJob(_: *gtk.Button, self: *FilesWindow) callconv(.c) void {
        if (self.job) |job| job.cancel();
    }

    fn trashSelection(self: *FilesWindow) void {
        var files = self.selectedFiles() catch return;
        defer freeFiles(self.allocator, &files);
        for (files.items) |f| {
            var err: ?*glib.Error = null;
            if (f.trash(null, &err) == 0) {
                const message = if (err) |e| e.f_message orelse "unknown error" else "unknown error";
                common.dialogs.showError(self.window.as(gtk.Window), common.tr("Cannot move to Trash"), std.mem.span(message));
                if (err) |e| e.free();
                break;
            }
        }
    }

    fn askDeletePermanently(self: *FilesWindow) void {
        var files = self.selectedFiles() catch return;
        defer freeFiles(self.allocator, &files);
        if (files.items.len == 0) return;
        common.dialogs.choose(
            self.window.as(gtk.Window),
            common.tr("Delete permanently?"),
            common.tr("The selected items will be gone for good. This cannot be undone."),
            &.{ "Cancel", "Delete" },
            0,
            FilesWindow,
            onDeleteAnswer,
            self,
        );
    }

    fn onDeleteAnswer(self: *FilesWindow, index: c_int) void {
        if (index != 1) return;
        var files = self.selectedFiles() catch return;
        defer freeFiles(self.allocator, &files);
        for (files.items) |f| self.deleteRecursive(f);
    }

    fn deleteRecursive(self: *FilesWindow, file: *gio.File) void {
        if (self.isDirectory(file)) {
            if (file.enumerateChildren("standard::name", .{ .nofollow_symlinks = true }, null, null)) |children| {
                defer children.as(gobject.Object).unref();
                while (children.nextFile(null, null)) |child| {
                    defer child.as(gobject.Object).unref();
                    const sub = file.getChild(child.getName());
                    defer sub.as(gobject.Object).unref();
                    self.deleteRecursive(sub);
                }
            }
        }
        var err: ?*glib.Error = null;
        if (file.delete(null, &err) == 0) {
            if (err) |e| e.free();
        }
    }

    /// Restores trashed items to where they came from, using the `.trashinfo`
    /// files, because browsing `trash:///` would need gvfs.
    fn restoreSelection(self: *FilesWindow) void {
        var files = self.selectedFiles() catch return;
        defer freeFiles(self.allocator, &files);
        for (files.items) |f| {
            const base = f.getBasename() orelse continue;
            defer glib.free(base);
            const info_path = std.fmt.allocPrintSentinel(self.allocator, "{s}/Trash/info/{s}.trashinfo", .{ std.mem.span(glib.getUserDataDir()), std.mem.span(base) }, 0) catch continue;
            defer self.allocator.free(info_path);

            var contents: [*]u8 = undefined;
            var length: usize = 0;
            if (glib.fileGetContents(info_path, &contents, &length, null) == 0) continue;
            defer glib.free(contents);
            const original = (pure.trashOriginalPath(self.allocator, contents[0..length]) catch null) orelse continue;
            defer self.allocator.free(original);
            const originalz = self.allocator.dupeSentinel(u8, original, 0) catch continue;
            defer self.allocator.free(originalz);

            const dest = gio.File.newForPath(originalz);
            defer dest.as(gobject.Object).unref();
            var err: ?*glib.Error = null;
            if (f.move(dest, .{}, null, null, null, &err) != 0) {
                const info_file = gio.File.newForPath(info_path);
                defer info_file.as(gobject.Object).unref();
                _ = info_file.delete(null, null);
            } else {
                const message = if (err) |e| e.f_message orelse "unknown error" else "unknown error";
                common.dialogs.showError(self.window.as(gtk.Window), common.tr("Cannot restore this item"), std.mem.span(message));
                if (err) |e| e.free();
            }
        }
    }

    fn emptyTrash(self: *FilesWindow) void {
        const trash = trashFilesDir(self.allocator) catch return;
        defer self.allocator.free(trash);
        const dir = gio.File.newForPath(trash);
        defer dir.as(gobject.Object).unref();
        if (dir.enumerateChildren("standard::name", .{ .nofollow_symlinks = true }, null, null)) |children| {
            defer children.as(gobject.Object).unref();
            while (children.nextFile(null, null)) |child| {
                defer child.as(gobject.Object).unref();
                const f = dir.getChild(child.getName());
                defer f.as(gobject.Object).unref();
                self.deleteRecursive(f);
            }
        }
        const info_dir_path = std.fmt.allocPrintSentinel(self.allocator, "{s}/Trash/info", .{std.mem.span(glib.getUserDataDir())}, 0) catch return;
        defer self.allocator.free(info_dir_path);
        const info_dir = gio.File.newForPath(info_dir_path);
        defer info_dir.as(gobject.Object).unref();
        if (info_dir.enumerateChildren("standard::name", .{}, null, null)) |children| {
            defer children.as(gobject.Object).unref();
            while (children.nextFile(null, null)) |child| {
                defer child.as(gobject.Object).unref();
                const f = info_dir.getChild(child.getName());
                defer f.as(gobject.Object).unref();
                _ = f.delete(null, null);
            }
        }
    }

    fn renameSelection(self: *FilesWindow) void {
        var files = self.selectedFiles() catch return;
        defer freeFiles(self.allocator, &files);
        if (files.items.len != 1) return;
        const target = files.items[0];
        const base = target.getBasename() orelse return;
        defer glib.free(base);

        const ctx = self.allocator.create(RenameCtx) catch return;
        ctx.* = .{ .window = self, .file = @ptrCast(target.as(gobject.Object).ref()) };
        self.promptText(common.tr("Rename"), std.mem.span(base), RenameCtx, onRenameText, ctx);
    }

    const RenameCtx = struct { window: *FilesWindow, file: *gio.File };

    fn onRenameText(ctx: *RenameCtx, text: ?[:0]const u8) void {
        defer {
            ctx.file.as(gobject.Object).unref();
            ctx.window.allocator.destroy(ctx);
        }
        const name = text orelse return;
        var err: ?*glib.Error = null;
        if (ctx.file.setDisplayName(name, null, &err)) |renamed| {
            renamed.as(gobject.Object).unref();
        } else {
            const message = if (err) |e| e.f_message orelse "unknown error" else "unknown error";
            common.dialogs.showError(ctx.window.window.as(gtk.Window), common.tr("Cannot rename"), std.mem.span(message));
            if (err) |e| e.free();
        }
    }

    fn newFolder(self: *FilesWindow) void {
        self.promptText(common.tr("New Folder"), "New Folder", FilesWindow, onNewFolderText, self);
    }

    fn onNewFolderText(self: *FilesWindow, text: ?[:0]const u8) void {
        const name = text orelse return;
        const dir = self.current.getChild(name);
        defer dir.as(gobject.Object).unref();
        var err: ?*glib.Error = null;
        if (dir.makeDirectory(null, &err) == 0) {
            const message = if (err) |e| e.f_message orelse "unknown error" else "unknown error";
            common.dialogs.showError(self.window.as(gtk.Window), common.tr("Cannot create the folder"), std.mem.span(message));
            if (err) |e| e.free();
        }
    }

    fn showProperties(self: *FilesWindow) void {
        var files = self.selectedFiles() catch return;
        defer freeFiles(self.allocator, &files);
        const file = if (files.items.len > 0) files.items[0] else self.current;
        props.show(self.allocator, self.window.as(gtk.Window), file);
    }

    const AdminDone = struct { window: *FilesWindow };

    fn onAdminDone(done: *AdminDone, outcome: common.elevate.Outcome, message: []const u8) void {
        defer std.heap.c_allocator.destroy(done);
        if (outcome != .failed) return;
        var buf: [512]u8 = undefined;
        common.dialogs.showError(done.window.window.as(gtk.Window), common.tr("Could not open as administrator"), std.fmt.bufPrintSentinel(&buf, "{s}", .{message}, 0) catch "");
    }

    /// Opens the current folder in a second file manager running as root.
    fn openAsAdmin(self: *FilesWindow) void {
        const path_c = self.current.getPath() orelse return;
        defer glib.free(path_c);
        const a = std.heap.c_allocator;
        var argv: std.ArrayList([]u8) = .empty;
        defer {
            for (argv.items) |x| a.free(x);
            argv.deinit(a);
        }
        common.appinfo.displayEnvArgs(a, &argv) catch return;
        argv.append(a, a.dupe(u8, "dkde-files") catch return) catch return;
        argv.append(a, a.dupe(u8, std.mem.span(path_c)) catch return) catch return;
        const view = a.alloc([]const u8, argv.items.len) catch return;
        defer a.free(view);
        for (argv.items, 0..) |x, i| view[i] = x;

        const done = a.create(AdminDone) catch return;
        done.* = .{ .window = self };
        common.elevate.run(self.window.as(gtk.Window), "Open this folder with administrator rights", view, "", AdminDone, onAdminDone, done);
    }

    fn onMenubarAction(self: *FilesWindow, action: []const u8) void {
        self.perform(action, null);
    }

    fn toggleHidden(self: *FilesWindow) void {
        self.show_hidden = !self.show_hidden;
        common.menubar.setChecked(self.window, "toggle-hidden", self.show_hidden);
        self.filter.as(gtk.Filter).changed(.different);
        self.config.setBool("files", "show-hidden", self.show_hidden) catch {};
    }

    fn addBookmark(self: *FilesWindow) void {
        const path_c = self.current.getPath() orelse return;
        defer glib.free(path_c);
        const path = std.mem.span(path_c);

        var existing = (self.config.getStringList(self.allocator, "bookmarks", "paths") catch null) orelse
            self.allocator.alloc([]u8, 0) catch return;
        defer common.config.freeStringList(self.allocator, existing);
        for (existing) |p| if (std.mem.eql(u8, p, path)) return;

        var list: std.ArrayList([]const u8) = .empty;
        defer list.deinit(self.allocator);
        for (existing) |p| list.append(self.allocator, p) catch return;
        list.append(self.allocator, path) catch return;
        self.config.setStringList("bookmarks", "paths", list.items) catch return;
        existing = &.{};
        self.rebuildSidebar();
    }

    fn removeBookmark(self: *FilesWindow, path: []const u8) void {
        const existing = (self.config.getStringList(self.allocator, "bookmarks", "paths") catch null) orelse return;
        defer common.config.freeStringList(self.allocator, existing);
        var list: std.ArrayList([]const u8) = .empty;
        defer list.deinit(self.allocator);
        for (existing) |p| if (!std.mem.eql(u8, p, path)) list.append(self.allocator, p) catch return;
        self.config.setStringList("bookmarks", "paths", list.items) catch return;
        self.rebuildSidebar();
    }

    // ---- text prompt -----------------------------------------------------

    /// A small modal asking for one line of text; `callback` gets null on cancel.
    fn promptText(
        self: *FilesWindow,
        title: [:0]const u8,
        initial: []const u8,
        comptime Data: type,
        callback: *const fn (*Data, ?[:0]const u8) void,
        data: *Data,
    ) void {
        const Prompt = struct {
            window: *gtk.Window,
            entry: *gtk.Entry,
            callback: *const fn (*Data, ?[:0]const u8) void,
            data: *Data,
            answered: bool = false,

            fn answer(p: *@This(), accept: bool) void {
                if (p.answered) return;
                p.answered = true;
                if (accept) {
                    const text = std.mem.span(p.entry.as(gtk.Editable).getText());
                    if (text.len > 0 and std.mem.indexOfScalar(u8, text, '/') == null) {
                        p.callback(p.data, text);
                    } else p.callback(p.data, null);
                } else p.callback(p.data, null);
                p.window.destroy();
            }
            fn onOk(_: *gtk.Button, p: *@This()) callconv(.c) void {
                p.answer(true);
            }
            fn onCancel(_: *gtk.Button, p: *@This()) callconv(.c) void {
                p.answer(false);
            }
            fn onActivate(_: *gtk.Entry, p: *@This()) callconv(.c) void {
                p.answer(true);
            }
            fn onClose(_: *gtk.Window, p: *@This()) callconv(.c) c_int {
                p.answer(false);
                return 0;
            }
            fn onDestroy(_: *gtk.Window, p: *@This()) callconv(.c) void {
                std.heap.c_allocator.destroy(p);
            }
        };

        const window = gtk.Window.new();
        window.setTitle(title);
        window.setTransientFor(self.window.as(gtk.Window));
        window.setModal(1);
        window.setDefaultSize(340, -1);
        window.as(gtk.Widget).addCssClass("dkde");

        const box = gtk.Box.new(.vertical, 12);
        box.as(gtk.Widget).setMarginTop(16);
        box.as(gtk.Widget).setMarginBottom(16);
        box.as(gtk.Widget).setMarginStart(16);
        box.as(gtk.Widget).setMarginEnd(16);
        const entry = gtk.Entry.new();
        var buf: [512]u8 = undefined;
        entry.as(gtk.Editable).setText(std.fmt.bufPrintSentinel(&buf, "{s}", .{initial}, 0) catch "");
        const buttons = gtk.Box.new(.horizontal, 8);
        buttons.as(gtk.Widget).setHalign(.end);
        const cancel = gtk.Button.newWithLabel(common.tr("Cancel"));
        const ok = gtk.Button.newWithLabel(common.tr("OK"));
        buttons.append(cancel.as(gtk.Widget));
        buttons.append(ok.as(gtk.Widget));
        box.append(entry.as(gtk.Widget));
        box.append(buttons.as(gtk.Widget));
        window.setChild(box.as(gtk.Widget));

        const prompt = std.heap.c_allocator.create(Prompt) catch return;
        prompt.* = .{ .window = window, .entry = entry, .callback = callback, .data = data };
        _ = gtk.Button.signals.clicked.connect(ok, *Prompt, &Prompt.onOk, prompt, .{});
        _ = gtk.Button.signals.clicked.connect(cancel, *Prompt, &Prompt.onCancel, prompt, .{});
        _ = gtk.Entry.signals.activate.connect(entry, *Prompt, &Prompt.onActivate, prompt, .{});
        _ = gtk.Window.signals.close_request.connect(window, *Prompt, &Prompt.onClose, prompt, .{});
        _ = gtk.Widget.signals.destroy.connect(window, *Prompt, &Prompt.onDestroy, prompt, .{});

        window.present();
        _ = entry.as(gtk.Widget).grabFocus();
        // Select the name without its extension, like a rename should.
        const dot = std.mem.lastIndexOfScalar(u8, initial, '.');
        entry.as(gtk.Editable).selectRegion(0, if (dot) |d| @intCast(@max(d, 1)) else -1);
    }

    // ---- context menu ----------------------------------------------------

    fn showContextMenu(self: *FilesWindow, parent: *gtk.Widget, x: f64, y: f64, on_item: bool) void {
        const popover = gtk.Popover.new();
        popover.as(gtk.Widget).addCssClass("dkde-context-menu");
        popover.as(gtk.Widget).setParent(parent);
        popover.setHasArrow(0);
        const rect: gdk.Rectangle = .{ .f_x = @intFromFloat(x), .f_y = @intFromFloat(y), .f_width = 1, .f_height = 1 };
        popover.setPointingTo(&rect);
        _ = gtk.Popover.signals.closed.connect(popover, *FilesWindow, &onMenuClosed, self, .{});

        const box = gtk.Box.new(.vertical, 0);
        popover.setChild(box.as(gtk.Widget));

        var sel = self.describeSelection(on_item);
        defer sel.deinit(self.allocator);

        // Quick row: emoji buttons.
        const quick = self.configuredIds("quick", context.default_quick);
        defer quick.deinit(self.allocator);
        const row = gtk.Box.new(.horizontal, 2);
        row.as(gtk.Widget).setMarginBottom(2);
        var quick_count: usize = 0;
        for (quick.ids) |id| {
            const entry = self.entryFor(id, &sel) orelse continue;
            defer if (entry.free_label) self.allocator.free(entry.label);
            self.quickButton(row, popover, id, entry);
            quick_count += 1;
        }
        if (quick_count > 0) {
            box.append(row.as(gtk.Widget));
            box.append(gtk.Separator.new(.horizontal).as(gtk.Widget));
        }

        // Text entries.
        const list = if (sel.on_item) self.configuredIds("item", context.default_item) else self.configuredIds("folder", context.default_folder);
        defer list.deinit(self.allocator);
        var pending_separator = false;
        var shown: usize = 0;
        for (list.ids) |id| {
            if (std.mem.eql(u8, id, context.separator)) {
                pending_separator = true;
                continue;
            }
            if (std.mem.eql(u8, id, "open-with")) {
                if (sel.single != null and !sel.is_dir and !sel.in_trash) {
                    if (pending_separator and shown > 0) box.append(gtk.Separator.new(.horizontal).as(gtk.Widget));
                    pending_separator = false;
                    shown += self.openWithItems(box, popover);
                }
                continue;
            }
            const entry = self.entryFor(id, &sel) orelse continue;
            if (pending_separator and shown > 0) box.append(gtk.Separator.new(.horizontal).as(gtk.Widget));
            pending_separator = false;
            defer if (entry.free_label) self.allocator.free(entry.label);
            self.menuItem(box, popover, entry.label, id, entry.enabled);
            shown += 1;
        }
        popover.popup();
    }

    /// What the menu needs to know about the selection (or the folder).
    const SelectionFacts = struct {
        on_item: bool,
        count: usize = 0,
        in_trash: bool = false,
        single: ?*gio.File = null,
        is_dir: bool = false,
        is_regular: bool = false,
        is_exec: bool = false,
        archive: ?archive.Kind = null,

        fn deinit(self: *SelectionFacts, _: std.mem.Allocator) void {
            if (self.single) |f| f.as(gobject.Object).unref();
        }
    };

    fn describeSelection(self: *FilesWindow, on_item: bool) SelectionFacts {
        var facts: SelectionFacts = .{ .on_item = false, .in_trash = self.isInTrash() };
        var files = self.selectedFiles() catch return facts;
        defer freeFiles(self.allocator, &files);
        facts.count = files.items.len;
        facts.on_item = on_item and files.items.len > 0;
        if (files.items.len != 1) return facts;
        const file = files.items[0];
        facts.single = @ptrCast(file.as(gobject.Object).ref());
        const info = file.queryInfo("standard::type,standard::name,unix::mode", .{}, null, null) orelse return facts;
        defer info.as(gobject.Object).unref();
        facts.is_dir = info.getFileType() == .directory;
        facts.is_regular = info.getFileType() == .regular;
        if (info.hasAttribute("unix::mode") != 0) facts.is_exec = info.getAttributeUint32("unix::mode") & 0o111 != 0;
        if (facts.is_regular) facts.archive = archive.kindOf(std.mem.span(info.getName()));
        return facts;
    }

    const Entry = struct { label: [:0]const u8, enabled: bool = true, free_label: bool = false };

    /// The menu entry for `id`, or null when it does not apply here.
    fn entryFor(self: *FilesWindow, id: []const u8, sel: *const SelectionFacts) ?Entry {
        const eql = std.mem.eql;
        const item = sel.on_item;
        const t = common.tr;
        if (eql(u8, id, "open")) return if (item) .{ .label = t("Open") } else null;
        if (eql(u8, id, "open-tab")) return if (item and sel.is_dir) .{ .label = t("Open in New Tab") } else null;
        if (eql(u8, id, "open-window")) return if (!item or sel.is_dir) .{ .label = t("Open in New Window") } else null;
        if (eql(u8, id, "run")) return if (item and sel.is_regular and sel.is_exec and !sel.in_trash) .{ .label = t("Run") } else null;
        if (eql(u8, id, "run-admin")) return if (item and sel.is_regular and sel.is_exec and !sel.in_trash) .{ .label = t("Run as Administrator") } else null;
        if (eql(u8, id, "exec")) {
            if (!item or !sel.is_regular or sel.in_trash) return null;
            return .{ .label = if (sel.is_exec) t("Unmark as Executable") else t("Mark as Executable") };
        }
        if (eql(u8, id, "extract")) {
            const kind = sel.archive orelse return null;
            if (!item or sel.in_trash) return null;
            return .{ .label = t("Extract Here"), .enabled = common.proc.hasProgram(archive.extractTool(kind)) };
        }
        if (eql(u8, id, "compress-zip")) return if (item and !sel.in_trash) .{ .label = t("Compress to .zip"), .enabled = common.proc.hasProgram("zip") } else null;
        if (eql(u8, id, "compress-targz")) return if (item and !sel.in_trash) .{ .label = t("Compress to .tar.gz"), .enabled = common.proc.hasProgram("tar") } else null;
        if (eql(u8, id, "restore")) return if (item and sel.in_trash) .{ .label = t("Restore") } else null;
        if (eql(u8, id, "delete-permanent")) return if (item and sel.in_trash) .{ .label = t("Delete Permanently") } else null;
        if (eql(u8, id, "empty-trash")) return if (!item and sel.in_trash) .{ .label = t("Empty Trash") } else null;
        if (eql(u8, id, "cut")) return if (item and !sel.in_trash) .{ .label = t("Cut") } else null;
        if (eql(u8, id, "copy")) return if (item) .{ .label = t("Copy") } else null;
        if (eql(u8, id, "paste")) return if (!sel.in_trash) .{ .label = t("Paste"), .enabled = self.clipboardHasFiles() } else null;
        if (eql(u8, id, "rename")) return if (item and !sel.in_trash) .{ .label = t("Rename\u{2026}"), .enabled = sel.count == 1 } else null;
        if (eql(u8, id, "trash")) return if (item and !sel.in_trash) .{ .label = t("Move to Trash") } else null;
        if (eql(u8, id, "new-folder")) return if (!item and !sel.in_trash) .{ .label = t("New Folder") } else null;
        if (eql(u8, id, "terminal-here")) return if (!sel.in_trash) .{ .label = t("Open Terminal Here") } else null;
        if (eql(u8, id, "open-admin")) return if (!sel.in_trash) .{ .label = t("Open Folder as Administrator") } else null;
        if (eql(u8, id, "toggle-hidden")) return .{ .label = t("Show Hidden Files") };
        if (eql(u8, id, "bookmark")) return if (!sel.in_trash) .{ .label = t("Add to Bookmarks") } else null;
        if (eql(u8, id, "properties")) return .{ .label = t("Properties"), .enabled = !item or sel.count == 1 };
        if (std.mem.startsWith(u8, id, context.command_prefix)) {
            const label = self.allocator.dupeSentinel(u8, id[context.command_prefix.len..], 0) catch return null;
            return .{ .label = label, .enabled = sel.on_item or !self.commandNeedsFile(id), .free_label = true };
        }
        return null;
    }

    fn commandNeedsFile(self: *FilesWindow, id: []const u8) bool {
        const name = self.allocator.dupeSentinel(u8, id[context.command_prefix.len..], 0) catch return false;
        defer self.allocator.free(name);
        const template = self.config.getString(self.allocator, "context-commands", name, "") catch return false;
        defer self.allocator.free(template);
        return std.mem.indexOf(u8, template, "%f") != null or std.mem.indexOf(u8, template, "%F") != null;
    }

    const IdList = struct {
        ids: []const []const u8,
        /// Backing text when the ids came from the configuration.
        owned_text: ?[]u8 = null,

        fn deinit(self: IdList, allocator: std.mem.Allocator) void {
            allocator.free(self.ids);
            if (self.owned_text) |t| allocator.free(t);
        }
    };

    /// `[context] <key>` as ids, or the default when it is not set.
    fn configuredIds(self: *FilesWindow, key: [:0]const u8, default: []const u8) IdList {
        const text = self.config.getString(self.allocator, "context", key, "") catch return .{ .ids = &.{} };
        if (text.len == 0) {
            self.allocator.free(text);
            const ids = context.parseList(self.allocator, default) catch &.{};
            return .{ .ids = ids };
        }
        const ids = context.parseList(self.allocator, text) catch {
            self.allocator.free(text);
            return .{ .ids = &.{} };
        };
        return .{ .ids = ids, .owned_text = text };
    }

    fn quickButton(self: *FilesWindow, row: *gtk.Box, popover: *gtk.Popover, id: []const u8, entry: Entry) void {
        const button = gtk.Button.newWithLabel(@ptrCast(context.emoji(id).ptr));
        button.setHasFrame(0);
        button.as(gtk.Widget).setTooltipText(entry.label);
        button.as(gtk.Widget).setSensitive(@intFromBool(entry.enabled));
        button.as(gtk.Widget).setHexpand(1);
        const ctx = std.heap.c_allocator.create(MenuAction) catch return;
        const owned = std.heap.c_allocator.dupe(u8, id) catch {
            std.heap.c_allocator.destroy(ctx);
            return;
        };
        ctx.* = .{ .window = self, .popover = popover, .action = owned, .owned = true };
        _ = gtk.Button.signals.clicked.connect(button, *MenuAction, &onMenuAction, ctx, .{});
        _ = gtk.Widget.signals.destroy.connect(button, *MenuAction, &onMenuActionDestroy, ctx, .{});
        row.append(button.as(gtk.Widget));
    }

    const MenuAction = struct {
        window: *FilesWindow,
        popover: *gtk.Popover,
        action: []const u8,
        app: ?*gio.AppInfo = null,
        /// `action` was allocated for this button.
        owned: bool = false,
    };

    fn menuItem(self: *FilesWindow, box: *gtk.Box, popover: *gtk.Popover, label: [:0]const u8, action: []const u8, enabled: bool) void {
        const button = gtk.Button.newWithLabel(label);
        button.setHasFrame(0);
        button.as(gtk.Widget).setSensitive(@intFromBool(enabled));
        if (button.getChild()) |child| {
            const l: *gtk.Label = @ptrCast(child);
            l.setXalign(0);
        }
        const ctx = std.heap.c_allocator.create(MenuAction) catch return;
        const owned = std.heap.c_allocator.dupe(u8, action) catch {
            std.heap.c_allocator.destroy(ctx);
            return;
        };
        ctx.* = .{ .window = self, .popover = popover, .action = owned, .owned = true };
        _ = gtk.Button.signals.clicked.connect(button, *MenuAction, &onMenuAction, ctx, .{});
        _ = gtk.Widget.signals.destroy.connect(button, *MenuAction, &onMenuActionDestroy, ctx, .{});
        box.append(button.as(gtk.Widget));
    }

    /// "Open With" entries for the selected file; returns how many it added.
    fn openWithItems(self: *FilesWindow, box: *gtk.Box, popover: *gtk.Popover) usize {
        var files = self.selectedFiles() catch return 0;
        defer freeFiles(self.allocator, &files);
        const info = files.items[0].queryInfo("standard::content-type", .{}, null, null) orelse return 0;
        defer info.as(gobject.Object).unref();
        const content_type = info.getContentType() orelse return 0;
        const apps = gio.AppInfo.getAllForType(content_type);
        defer apps.free();

        var shown: usize = 0;
        var node: ?*glib.List = apps;
        while (node) |n| : (node = n.f_next) {
            if (shown >= 6) break;
            const app: *gio.AppInfo = @ptrCast(@alignCast(n.f_data orelse continue));
            var buf: [256]u8 = undefined;
            const label = std.fmt.bufPrintSentinel(&buf, "Open With {s}", .{std.mem.span(app.getDisplayName())}, 0) catch continue;
            const button = gtk.Button.newWithLabel(label);
            button.setHasFrame(0);
            if (button.getChild()) |child| {
                const l: *gtk.Label = @ptrCast(child);
                l.setXalign(0);
            }
            const ctx = std.heap.c_allocator.create(MenuAction) catch return shown;
            ctx.* = .{ .window = self, .popover = popover, .action = "open-with", .app = @ptrCast(app.as(gobject.Object).ref()) };
            _ = gtk.Button.signals.clicked.connect(button, *MenuAction, &onMenuAction, ctx, .{});
            _ = gtk.Widget.signals.destroy.connect(button, *MenuAction, &onMenuActionDestroy, ctx, .{});
            box.append(button.as(gtk.Widget));
            shown += 1;
        }
        return shown;
    }

    fn onMenuActionDestroy(_: *gtk.Button, ctx: *MenuAction) callconv(.c) void {
        if (ctx.app) |app| app.as(gobject.Object).unref();
        if (ctx.owned) std.heap.c_allocator.free(ctx.action);
        std.heap.c_allocator.destroy(ctx);
    }

    fn onMenuClosed(popover: *gtk.Popover, _: *FilesWindow) callconv(.c) void {
        // Unparenting from inside the signal can crash GTK; do it when idle.
        _ = glib.idleAdd(unparentIdle, popover);
    }

    fn unparentIdle(data: ?*anyopaque) callconv(.c) c_int {
        const popover: *gtk.Popover = @ptrCast(@alignCast(data.?));
        popover.as(gtk.Widget).unparent();
        return 0;
    }

    fn onMenuAction(_: *gtk.Button, ctx: *MenuAction) callconv(.c) void {
        ctx.popover.popdown();
        ctx.window.perform(ctx.action, ctx.app);
    }

    /// Runs a named action: the one place menus and shortcuts meet.
    // ---- archives ---------------------------------------------------------------------

    fn nameTaken(dir: *gio.File, name: []const u8) bool {
        var buf: [512]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{name}, 0) catch return true;
        const child = dir.getChild(z);
        defer child.as(gobject.Object).unref();
        return child.queryExists(null) != 0;
    }

    /// Unpacks the selected archive into a new folder next to it, named after it.
    fn extractSelected(self: *FilesWindow) void {
        var files = self.selectedFiles() catch return;
        defer freeFiles(self.allocator, &files);
        if (files.items.len != 1) return;
        const file = files.items[0];
        const name_c = file.getBasename() orelse return;
        defer glib.free(name_c);
        const name = std.mem.span(name_c);
        const kind = archive.kindOf(name) orelse return;
        const parent = file.getParent() orelse return;
        defer parent.as(gobject.Object).unref();
        var buf: [512]u8 = undefined;
        const dest_name = archive.uniqueName(&buf, archive.stem(name), "", parent, nameTaken);
        const path = file.getPath() orelse return;
        defer glib.free(path);
        const parent_path = parent.getPath() orelse return;
        defer glib.free(parent_path);
        const dest = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ std.mem.span(parent_path), dest_name }) catch return;
        defer self.allocator.free(dest);
        self.status.setText(common.tr("Extracting\u{2026}"));
        common.proc.run(FilesWindow, self.proc_guard, &.{ "sh", "-c", archive.extractScript(kind), "sh", std.mem.span(path), dest }, onArchiveDone);
    }

    /// Packs the selection into one archive in the folder being shown.
    fn compressSelected(self: *FilesWindow, kind: archive.Pack) void {
        var files = self.selectedFiles() catch return;
        defer freeFiles(self.allocator, &files);
        if (files.items.len == 0) return;
        const dir_path = self.current.getPath() orelse return;
        defer glib.free(dir_path);

        // One item is named after itself; several become "Archive".
        var base_buf: [256]u8 = undefined;
        const base: []const u8 = blk: {
            if (files.items.len == 1) {
                const n = files.items[0].getBasename() orelse break :blk "Archive";
                defer glib.free(n);
                const len = @min(std.mem.span(n).len, base_buf.len);
                @memcpy(base_buf[0..len], std.mem.span(n)[0..len]);
                break :blk base_buf[0..len];
            }
            break :blk "Archive";
        };
        var out_buf: [512]u8 = undefined;
        const out = archive.uniqueName(&out_buf, base, archive.packExtension(kind), self.current, nameTaken);

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.allocator);
        var owned: std.ArrayList([*:0]u8) = .empty;
        defer {
            for (owned.items) |o| glib.free(o);
            owned.deinit(self.allocator);
        }
        argv.appendSlice(self.allocator, &.{ "sh", "-c", archive.packScript(kind), "sh", std.mem.span(dir_path), out }) catch return;
        for (files.items) |f| {
            const n = f.getBasename() orelse continue;
            owned.append(self.allocator, n) catch continue;
            argv.append(self.allocator, std.mem.span(n)) catch return;
        }
        self.status.setText(common.tr("Compressing\u{2026}"));
        common.proc.run(FilesWindow, self.proc_guard, argv.items, onArchiveDone);
    }

    fn onArchiveDone(self: *FilesWindow, ok: bool, _: []const u8) void {
        self.status.setText(if (ok) common.tr("Done.") else common.tr("The archive command failed."));
    }

    fn perform(self: *FilesWindow, action: []const u8, app: ?*gio.AppInfo) void {
        const eql = std.mem.eql;
        if (eql(u8, action, "open")) return self.openSelected();
        if (eql(u8, action, "back")) return self.goBack();
        if (eql(u8, action, "forward")) return self.goForward();
        if (eql(u8, action, "up")) return self.goUp();
        if (std.mem.startsWith(u8, action, "view-")) return self.setViewMode(ViewMode.parse(action[5..]));
        if (eql(u8, action, "open-window")) return self.openInNewWindow();
        if (eql(u8, action, "run")) return self.runSelected(false);
        if (eql(u8, action, "run-admin")) return self.runSelected(true);
        if (eql(u8, action, "exec")) return self.toggleExecutable();
        if (std.mem.startsWith(u8, action, context.command_prefix)) return self.runCustomCommand(action[context.command_prefix.len..]);
        if (eql(u8, action, "close")) return self.window.as(gtk.Window).close();
        if (eql(u8, action, "close-tab")) return self.closeTab(self.active_tab);
        if (eql(u8, action, "new-tab")) return self.addTab(self.current);
        if (eql(u8, action, "open-tab")) {
            var files = self.selectedFiles() catch return;
            defer freeFiles(self.allocator, &files);
            for (files.items) |f| if (self.isDirectory(f)) self.addTab(f);
            return;
        }
        if (eql(u8, action, "focus-path")) {
            self.path_stack.setVisibleChildName("entry");
            _ = self.path_entry.as(gtk.Widget).grabFocus();
            return;
        }
        if (eql(u8, action, "open-admin")) return self.openAsAdmin();
        if (eql(u8, action, "terminal-here")) {
            const path = self.current.getPath() orelse return;
            defer glib.free(path);
            return common.appinfo.spawnIn(self.allocator, &.{"dkde-term"}, std.mem.span(path));
        }
        if (eql(u8, action, "extract")) return self.extractSelected();
        if (eql(u8, action, "compress-zip")) return self.compressSelected(.zip);
        if (eql(u8, action, "compress-targz")) return self.compressSelected(.tar_gz);
        if (eql(u8, action, "cut")) return self.copySelection(true);
        if (eql(u8, action, "copy")) return self.copySelection(false);
        if (eql(u8, action, "paste")) return self.paste();
        if (eql(u8, action, "rename")) return self.renameSelection();
        if (eql(u8, action, "new-folder")) return self.newFolder();
        if (eql(u8, action, "trash")) return self.trashSelection();
        if (eql(u8, action, "delete-permanent")) return self.askDeletePermanently();
        if (eql(u8, action, "restore")) return self.restoreSelection();
        if (eql(u8, action, "empty-trash")) return self.emptyTrash();
        if (eql(u8, action, "properties")) return self.showProperties();
        if (eql(u8, action, "toggle-hidden")) return self.toggleHidden();
        if (eql(u8, action, "bookmark")) return self.addBookmark();
        if (eql(u8, action, "open-with")) {
            var files = self.selectedFiles() catch return;
            defer freeFiles(self.allocator, &files);
            if (files.items.len > 0 and app != null) self.openWith(files.items[0], app.?);
        }
    }

    // ---- run, new window, executable bit, custom commands ----------------

    /// The one selected file, or null.
    fn singleSelected(self: *FilesWindow) ?*gio.File {
        var files = self.selectedFiles() catch return null;
        defer freeFiles(self.allocator, &files);
        if (files.items.len != 1) return null;
        return @ptrCast(files.items[0].as(gobject.Object).ref());
    }

    fn openInNewWindow(self: *FilesWindow) void {
        const target = self.singleSelected();
        defer if (target) |t| t.as(gobject.Object).unref();
        const file = if (target != null and self.isDirectory(target.?)) target.? else self.current;
        const path = file.getPath() orelse return;
        defer glib.free(path);
        common.appinfo.spawnIn(self.allocator, &.{ "dkde-files", std.mem.span(path) }, std.mem.span(path));
    }

    fn runSelected(self: *FilesWindow, as_admin: bool) void {
        const file = self.singleSelected() orelse return;
        defer file.as(gobject.Object).unref();
        const path_c = file.getPath() orelse return;
        defer glib.free(path_c);
        const path = std.mem.span(path_c);
        if (!as_admin) {
            const dir = std.fs.path.dirname(path) orelse "/";
            return common.appinfo.spawnIn(self.allocator, &.{path}, dir);
        }
        const a = std.heap.c_allocator;
        var argv: std.ArrayList([]u8) = .empty;
        defer {
            for (argv.items) |x| a.free(x);
            argv.deinit(a);
        }
        common.appinfo.displayEnvArgs(a, &argv) catch return;
        argv.append(a, a.dupe(u8, path) catch return) catch return;
        const view = a.alloc([]const u8, argv.items.len) catch return;
        defer a.free(view);
        for (argv.items, 0..) |x, i| view[i] = x;
        const done = a.create(AdminDone) catch return;
        done.* = .{ .window = self };
        common.elevate.run(self.window.as(gtk.Window), "Run this program with administrator rights", view, "", AdminDone, onAdminDone, done);
    }

    /// Sets or clears the three execute bits.
    fn toggleExecutable(self: *FilesWindow) void {
        const file = self.singleSelected() orelse return;
        defer file.as(gobject.Object).unref();
        const info = file.queryInfo("unix::mode", .{}, null, null) orelse return;
        defer info.as(gobject.Object).unref();
        const mode = info.getAttributeUint32("unix::mode");
        const new_mode: u32 = if (mode & 0o111 != 0) mode & ~@as(u32, 0o111) else mode | 0o111;
        var err: ?*glib.Error = null;
        if (file.setAttributeUint32("unix::mode", new_mode, .{}, null, &err) == 0) {
            const message = if (err) |e| e.f_message orelse "unknown error" else "unknown error";
            common.dialogs.showError(self.window.as(gtk.Window), common.tr("Cannot change the permissions"), std.mem.span(message));
            if (err) |e| e.free();
        }
    }

    /// A command from `[context-commands]`, run in the current folder.
    fn runCustomCommand(self: *FilesWindow, label: []const u8) void {
        const key = self.allocator.dupeSentinel(u8, label, 0) catch return;
        defer self.allocator.free(key);
        const template = self.config.getString(self.allocator, "context-commands", key, "") catch return;
        defer self.allocator.free(template);
        if (template.len == 0) return;

        var files = self.selectedFiles() catch return;
        defer freeFiles(self.allocator, &files);
        var paths: std.ArrayList([]const u8) = .empty;
        defer {
            for (paths.items) |p| glib.free(@constCast(p.ptr));
            paths.deinit(self.allocator);
        }
        for (files.items) |f| {
            const p = f.getPath() orelse continue;
            paths.append(self.allocator, std.mem.span(p)) catch return;
        }
        const dir_c = self.current.getPath() orelse return;
        defer glib.free(dir_c);
        const dir = std.mem.span(dir_c);
        const command = context.expand(self.allocator, template, paths.items, dir) catch return;
        defer self.allocator.free(command);
        common.appinfo.spawnIn(self.allocator, &.{ "sh", "-c", command }, dir);
    }

    // ---- view modes ------------------------------------------------------

    fn setViewMode(self: *FilesWindow, mode: ViewMode) void {
        self.view_mode = mode;
        for (self.tabs.items, 0..) |t, i| {
            if (i == self.active_tab) self.applyViewTo(self.view_stack, self.grid_view) else self.applyViewTo(t.view_stack, t.grid_view);
        }
        self.syncViewChecks();
        self.config.setString("files", "view", @tagName(mode)) catch {};
    }

    fn syncViewChecks(self: *FilesWindow) void {
        inline for (@typeInfo(ViewMode).@"enum".field_names) |name| {
            common.menubar.setChecked(self.window, "view-" ++ name, self.view_mode == @field(ViewMode, name));
        }
    }

    /// Shows `mode` in one tab's stack; icon modes get a fresh item factory.
    fn applyViewTo(self: *FilesWindow, stack: *gtk.Stack, grid: *gtk.GridView) void {
        if (self.view_mode == .details) return stack.setVisibleChildName("list");
        const factory = gtk.SignalListItemFactory.new();
        _ = gtk.SignalListItemFactory.signals.setup.connect(factory, *FilesWindow, &onGridSetup, self, .{});
        _ = gtk.SignalListItemFactory.signals.bind.connect(factory, *FilesWindow, &onGridBind, self, .{});
        grid.setFactory(factory.as(gtk.ListItemFactory));
        grid.setMaxColumns(if (self.view_mode == .list) 1 else 12);
        stack.setVisibleChildName("grid");
    }

    // ---- shortcuts -------------------------------------------------------

    const Shortcut = struct { trigger: [:0]const u8, action: []const u8 };
    const shortcuts = [_]Shortcut{
        .{ .trigger = "<Control>c", .action = "copy" },
        .{ .trigger = "<Control>x", .action = "cut" },
        .{ .trigger = "<Control>v", .action = "paste" },
        .{ .trigger = "F2", .action = "rename" },
        .{ .trigger = "Delete", .action = "trash" },
        .{ .trigger = "<Shift>Delete", .action = "delete-permanent" },
        .{ .trigger = "<Control>h", .action = "toggle-hidden" },
        .{ .trigger = "<Control><Shift>n", .action = "new-folder" },
        .{ .trigger = "<Control>d", .action = "bookmark" },
        .{ .trigger = "<Alt>Return", .action = "properties" },
        .{ .trigger = "<Control>l", .action = "focus-path" },
        .{ .trigger = "<Alt>Left", .action = "back" },
        .{ .trigger = "<Alt>Right", .action = "forward" },
        .{ .trigger = "<Alt>Up", .action = "up" },
        .{ .trigger = "BackSpace", .action = "up" },
        .{ .trigger = "<Control>w", .action = "close-tab" },
        .{ .trigger = "<Control>t", .action = "new-tab" },
        .{ .trigger = "<Control>q", .action = "close" },
        .{ .trigger = "Menu", .action = "context-menu" },
        .{ .trigger = "<Shift>F10", .action = "context-menu" },
    };

    fn installShortcuts(self: *FilesWindow) void {
        const controller = gtk.ShortcutController.new();
        controller.as(gtk.EventController).setPropagationPhase(.capture);
        inline for (shortcuts) |s| {
            const trigger = gtk.ShortcutTrigger.parseString(s.trigger);
            const action = gtk.CallbackAction.new(onShortcut, @ptrCast(@constCast(&s)), null);
            controller.addShortcut(gtk.Shortcut.new(trigger, @ptrCast(action)));
        }
        controller.as(gtk.EventController).setPropagationPhase(.capture);
        self.window.as(gtk.Widget).addController(controller.as(gtk.EventController));
        windowRegistry(self);
    }

    /// The shortcut callback only gets the widget, so find the window through
    /// object data.
    fn windowRegistry(self: *FilesWindow) void {
        self.window.as(gobject.Object).setData("dkde-files-window", self);
    }

    fn onShortcut(widget: *gtk.Widget, _: ?*glib.Variant, data: ?*anyopaque) callconv(.c) c_int {
        const shortcut: *const Shortcut = @ptrCast(@alignCast(data.?));
        const obj: *gobject.Object = @ptrCast(widget);
        const self: *FilesWindow = @ptrCast(@alignCast(obj.getData("dkde-files-window") orelse return 0));

        // Typing in an entry must keep its own editing keys.
        if (isEditing(self) and !std.mem.startsWith(u8, shortcut.trigger, "<Control>")) return 0;

        const eql = std.mem.eql;
        if (eql(u8, shortcut.action, "focus-path")) {
            self.path_stack.setVisibleChildName("entry");
            _ = self.path_entry.as(gtk.Widget).grabFocus();
        } else if (eql(u8, shortcut.action, "back")) self.goBack() else if (eql(u8, shortcut.action, "forward")) self.goForward() else if (eql(u8, shortcut.action, "up")) self.goUp() else if (eql(u8, shortcut.action, "close")) self.window.as(gtk.Window).close() else if (eql(u8, shortcut.action, "context-menu")) {
            self.showContextMenu(self.view_stack.as(gtk.Widget), 24, 24, self.selection.as(gtk.SelectionModel).getSelection().getSize() > 0);
        } else self.perform(shortcut.action, null);
        return 1;
    }

    fn isEditing(self: *FilesWindow) bool {
        const focus = self.window.as(gtk.Window).getFocus() orelse return false;
        return gobject.typeCheckInstanceIsA(@ptrCast(@alignCast(focus)), gtk.Editable.getGObjectType()) != 0;
    }

    // ---- signal handlers -------------------------------------------------

    fn onActivate(_: *gtk.ColumnView, position: c_uint, self: *FilesWindow) callconv(.c) void {
        self.activateAt(position);
    }

    fn onGridActivate(_: *gtk.GridView, position: c_uint, self: *FilesWindow) callconv(.c) void {
        self.activateAt(position);
    }

    fn activateAt(self: *FilesWindow, position: c_uint) void {
        const model = self.selection.as(gio.ListModel);
        const obj: *gobject.Object = @ptrCast(@alignCast(model.getItem(position) orelse return));
        defer obj.unref();
        const info: *gio.FileInfo = @ptrCast(obj);
        const file = fileOf(info) orelse return;
        if (info.getFileType() == .directory) self.go(file, true) else self.openFile(file);
    }

    fn onItemsChanged(_: *gio.ListModel, _: c_uint, _: c_uint, _: c_uint, self: *FilesWindow) callconv(.c) void {
        self.updateStatus();
    }

    fn onSelectionChanged(_: *gtk.SelectionModel, _: c_uint, _: c_uint, self: *FilesWindow) callconv(.c) void {
        self.updateStatus();
    }

    fn onBackClicked(_: *gtk.Button, self: *FilesWindow) callconv(.c) void {
        self.goBack();
    }

    fn onForwardClicked(_: *gtk.Button, self: *FilesWindow) callconv(.c) void {
        self.goForward();
    }

    fn onUpClicked(_: *gtk.Button, self: *FilesWindow) callconv(.c) void {
        self.goUp();
    }

    fn onToggleView(_: *gtk.Button, self: *FilesWindow) callconv(.c) void {
        self.toggleView();
    }

    const CrumbCtx = struct { window: *FilesWindow, path: [:0]u8 };

    fn onCrumbClicked(_: *gtk.Button, ctx: *CrumbCtx) callconv(.c) void {
        ctx.window.goPath(ctx.path);
    }

    fn onPathEntryActivate(entry: *gtk.Entry, self: *FilesWindow) callconv(.c) void {
        self.goPath(std.mem.span(entry.as(gtk.Editable).getText()));
        _ = self.view_stack.as(gtk.Widget).grabFocus();
    }

    fn onPathEntryKey(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, _: gdk.ModifierType, self: *FilesWindow) callconv(.c) c_int {
        if (keyval == gdk.KEY_Escape) {
            self.path_stack.setVisibleChildName("crumbs");
            _ = self.view_stack.as(gtk.Widget).grabFocus();
            return 1;
        }
        return 0;
    }

    fn onSearchChanged(entry: *gtk.SearchEntry, self: *FilesWindow) callconv(.c) void {
        const text = std.mem.span(entry.as(gtk.Editable).getText());
        self.query_len = @min(text.len, self.query.len);
        @memcpy(self.query[0..self.query_len], text[0..self.query_len]);
        self.filter.as(gtk.Filter).changed(.different);
    }

    fn onSearchStop(entry: *gtk.SearchEntry, self: *FilesWindow) callconv(.c) void {
        entry.as(gtk.Editable).setText("");
        _ = self.view_stack.as(gtk.Widget).grabFocus();
    }

    fn onSidebarActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *FilesWindow) callconv(.c) void {
        const index: usize = @intCast(row.getIndex());
        if (index >= self.sidebar_paths.items.len) return;
        if (self.sidebar_paths.items[index]) |path| self.goPath(path);
    }

    fn onSidebarRightClick(gesture: *gtk.GestureClick, _: c_int, x: f64, y: f64, self: *FilesWindow) callconv(.c) void {
        _ = gesture;
        _ = x;
        const row = self.sidebar.getRowAtY(@intFromFloat(y)) orelse return;
        const index: usize = @intCast(row.getIndex());
        if (index >= self.sidebar_bookmark.items.len or !self.sidebar_bookmark.items[index]) return;
        if (self.sidebar_paths.items[index]) |path| self.removeBookmark(path);
    }
};

test {
    _ = @import("archive.zig");
}
