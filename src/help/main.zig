//! dkde-help: the help viewer. It shows DKDE's own documents (Markdown in
//! share/dkde/help) and the system's manual pages (man(7) and mdoc(7), found
//! through MANPATH) in one window, with a search box. Finding, reading and
//! parsing pages is the dkman library's; markdown is md-zig's, roff is
//! gtroff-zig's. No network is used (DKDE-050).

const std = @import("std");
const cli = @import("cli");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const pango = @import("pango1");
const common = @import("common");

const index = @import("index.zig");
const render = @import("render.zig");

pub const std_options: std.Options = .{ .logFn = common.log.logFn, .log_level = .debug };

const Help = struct {
    allocator: std.mem.Allocator,
    /// Owns the entry list and the manual directory names.
    arena: std.heap.ArenaAllocator,
    entries: []index.Entry = &.{},
    dirs: []const []const u8 = &.{},
    window: *gtk.ApplicationWindow,
    search: *gtk.SearchEntry,
    list: *gtk.ListBox,
    tabs: *gtk.Notebook,
    tag_table: *gtk.TextTagTable,
    /// One per notebook page, in page order (tabs are not reorderable).
    pages: std.ArrayList(Page) = .empty,

    pub fn create(allocator: std.mem.Allocator, app: *gtk.Application) !*Help {
        const self = try allocator.create(Help);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .arena = .init(allocator),
            .window = gtk.ApplicationWindow.new(app),
            .search = gtk.SearchEntry.new(),
            .list = gtk.ListBox.new(),
            .tabs = gtk.Notebook.new(),
            .tag_table = gtk.TextTagTable.new(),
        };
        errdefer self.arena.deinit();

        const window = self.window.as(gtk.Window);
        window.setTitle(common.tr("Help"));
        window.setDefaultSize(960, 640);
        self.window.as(gtk.Widget).addCssClass("dkde");
        _ = common.header.create(window, "help-browser", true);

        self.search.setPlaceholderText(common.tr("Search help"));
        inline for (.{ "setMarginStart", "setMarginEnd", "setMarginTop", "setMarginBottom" }) |m| @field(gtk.Widget, m)(self.search.as(gtk.Widget), 8);
        self.list.setSelectionMode(.single);
        const list_scroller = gtk.ScrolledWindow.new();
        list_scroller.setChild(self.list.as(gtk.Widget));
        list_scroller.as(gtk.Widget).setVexpand(1);
        const side = gtk.Box.new(.vertical, 0);
        side.append(self.search.as(gtk.Widget));
        side.append(list_scroller.as(gtk.Widget));

        addTags(self.tag_table);
        self.tabs.setScrollable(1);
        self.tabs.as(gtk.Widget).setHexpand(1);
        _ = gtk.Widget.signals.destroy.connect(self.window, *Help, &onDestroy, self, .{});
        _ = self.newTab();
        _ = gtk.Notebook.signals.switch_page.connect(self.tabs, *Help, &onSwitchPage, self, .{});

        // The "+" button beside the tabs; Ctrl+T and Ctrl+W do the same.
        const add = gtk.Button.newFromIconName("tab-new-symbolic");
        add.setHasFrame(0);
        add.as(gtk.Widget).setTooltipText(common.tr("New tab (Ctrl+T)"));
        _ = gtk.Button.signals.clicked.connect(add, *Help, &onNewTab, self, .{});
        self.tabs.setActionWidget(add.as(gtk.Widget), .end);
        const keys = gtk.ShortcutController.new();
        addShortcut(keys, "<Control>t", &keyNewTab, self);
        addShortcut(keys, "<Control>w", &keyCloseTab, self);
        window.as(gtk.Widget).addController(keys.as(gtk.EventController));

        const paned = gtk.Paned.new(.horizontal);
        paned.setStartChild(side.as(gtk.Widget));
        paned.setEndChild(self.tabs.as(gtk.Widget));
        paned.setPosition(270);
        paned.setShrinkStartChild(0);
        window.setChild(paned.as(gtk.Widget));

        self.loadIndex();
        _ = gtk.ListBox.signals.row_selected.connect(self.list, *Help, &onRow, self, .{});
        _ = gtk.ListBox.signals.row_activated.connect(self.list, *Help, &onRowActivated, self, .{});
        _ = gtk.SearchEntry.signals.search_changed.connect(self.search, *Help, &onSearch, self, .{});
        _ = gtk.SearchEntry.signals.activate.connect(self.search, *Help, &onActivate, self, .{});

        self.openOperands();
        return self;
    }

    pub fn present(self: *Help) void {
        self.window.as(gtk.Window).present();
        _ = self.search.as(gtk.Widget).grabFocus();
    }

    const Page = struct {
        scroller: *gtk.ScrolledWindow,
        view: *gtk.TextView,
        label: *gtk.Label,
        /// The data of the tab's close button. It is owned here, not by the
        /// button: GTK does not destroy a notebook's tab labels with the window.
        close: *CloseCtx,
    };

    const CloseCtx = struct { help: *Help, scroller: *gtk.ScrolledWindow };

    /// Adds an empty tab, makes it current and returns its view.
    fn newTab(self: *Help) *gtk.TextView {
        const view = gtk.TextView.newWithBuffer(gtk.TextBuffer.new(self.tag_table));
        view.setEditable(0);
        view.setCursorVisible(0);
        view.setWrapMode(.word);
        view.setLeftMargin(20);
        view.setRightMargin(20);
        view.setTopMargin(12);
        view.setBottomMargin(12);
        view.setPixelsBelowLines(2);
        const scroller = gtk.ScrolledWindow.new();
        scroller.setChild(view.as(gtk.Widget));

        const label = gtk.Label.new(common.tr("Help"));
        label.setEllipsize(.end);
        label.setMaxWidthChars(24);
        const close = gtk.Button.newFromIconName("window-close-symbolic");
        close.setHasFrame(0);
        close.as(gtk.Widget).setTooltipText(common.tr("Close tab (Ctrl+W)"));
        const head = gtk.Box.new(.horizontal, 4);
        head.append(label.as(gtk.Widget));
        head.append(close.as(gtk.Widget));

        const ctx = self.allocator.create(CloseCtx) catch return view;
        ctx.* = .{ .help = self, .scroller = scroller };
        self.pages.append(self.allocator, .{ .scroller = scroller, .view = view, .label = label, .close = ctx }) catch {
            self.allocator.destroy(ctx);
            return view;
        };
        const n = self.tabs.appendPage(scroller.as(gtk.Widget), head.as(gtk.Widget));
        _ = gtk.Button.signals.clicked.connect(close, *CloseCtx, &onCloseTab, ctx, .{});
        self.tabs.setCurrentPage(n);
        self.updateTabBar();
        return view;
    }

    fn currentIndex(self: *Help) usize {
        const n = self.tabs.getCurrentPage();
        return if (n < 0) 0 else @intCast(n);
    }

    fn currentView(self: *Help) *gtk.TextView {
        return self.pages.items[@min(self.currentIndex(), self.pages.items.len - 1)].view;
    }

    fn setTabTitle(self: *Help, text: [:0]const u8) void {
        self.pages.items[@min(self.currentIndex(), self.pages.items.len - 1)].label.setText(text);
    }

    /// A lone tab needs no tab bar.
    fn updateTabBar(self: *Help) void {
        self.tabs.setShowTabs(@intFromBool(self.pages.items.len > 1));
    }

    fn closeTab(self: *Help, scroller: *gtk.ScrolledWindow) void {
        // The last tab is emptied rather than closed: the window always has one.
        if (self.pages.items.len == 1) {
            self.message("");
            self.setTabTitle(common.tr("Help"));
            return;
        }
        for (self.pages.items, 0..) |pg, i| {
            if (pg.scroller != scroller) continue;
            const gone = self.pages.orderedRemove(i);
            self.tabs.removePage(@intCast(i));
            // This runs from the close button's own handler; nothing touches the data afterwards.
            self.allocator.destroy(gone.close);
            break;
        }
        self.updateTabBar();
    }

    fn onCloseTab(_: *gtk.Button, ctx: *CloseCtx) callconv(.c) void {
        ctx.help.closeTab(ctx.scroller);
    }

    fn onDestroy(_: *gtk.ApplicationWindow, self: *Help) callconv(.c) void {
        for (self.pages.items) |pg| self.allocator.destroy(pg.close);
        self.pages.deinit(self.allocator);
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    fn onNewTab(_: *gtk.Button, self: *Help) callconv(.c) void {
        _ = self.newTab();
    }

    fn keyNewTab(_: *gtk.Widget, _: ?*glib.Variant, self: *Help) callconv(.c) c_int {
        _ = self.newTab();
        return 1;
    }

    fn keyCloseTab(_: *gtk.Widget, _: ?*glib.Variant, self: *Help) callconv(.c) c_int {
        self.closeTab(self.pages.items[@min(self.currentIndex(), self.pages.items.len - 1)].scroller);
        return 1;
    }

    /// Switching tabs keeps the window title in step with the page shown.
    fn onSwitchPage(_: *gtk.Notebook, _: *gtk.Widget, n: c_uint, self: *Help) callconv(.c) void {
        if (n >= self.pages.items.len) return;
        const text = std.mem.span(self.pages.items[n].label.getText());
        self.window.as(gtk.Window).setTitle(self.titleFor(text));
    }

    /// Double-click or Enter on a list row opens the page in a new tab.
    fn onRowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Help) callconv(.c) void {
        const i: usize = @intCast(row.getIndex());
        if (i >= self.entries.len) return;
        _ = self.newTab();
        self.openEntry(i);
    }

    fn openEntry(self: *Help, i: usize) void {
        var buf: [160]u8 = undefined;
        const label = self.entries[i].label(&buf);
        const title = self.titleFor(label);
        self.window.as(gtk.Window).setTitle(title);
        const z = self.arena.allocator().dupeSentinel(u8, label, 0) catch return;
        self.setTabTitle(z);
        self.show(self.entries[i].path);
    }

    fn loadIndex(self: *Help) void {
        const a = self.arena.allocator();
        const manpath: ?[]const u8 = if (glib.getenv("MANPATH")) |m| std.mem.span(m) else null;
        const help_dir: ?[]const u8 = helpDir(a);
        self.dirs = dkman.paths.searchDirs(a, manpath) catch &.{};
        self.entries = index.all(a, common.fsio.io(), help_dir, manpath) catch &.{};

        var buf: [160]u8 = undefined;
        for (self.entries) |e| {
            const text = std.fmt.allocPrintSentinel(a, "{s}", .{e.label(&buf)}, 0) catch continue;
            const label = gtk.Label.new(text);
            label.setXalign(0);
            label.as(gtk.Widget).setMarginStart(8);
            label.as(gtk.Widget).setMarginEnd(8);
            self.list.append(label.as(gtk.Widget));
        }
    }

    fn selectRow(self: *Help, i: usize) void {
        if (self.list.getRowAtIndex(@intCast(i))) |row| self.list.selectRow(row);
    }

    /// Operands: `NAME`, `SECTION NAME` or a file path, as man(1) takes them.
    fn openOperands(self: *Help) void {
        const args = common.runapp.args;
        if (args.len == 0) {
            if (self.entries.len > 0) self.selectRow(0);
            return;
        }
        const first = std.mem.span(args[0]);
        if (std.mem.indexOfScalar(u8, first, '/') != null or common.fsio.exists(first)) {
            const base = std.fs.path.basename(first);
            self.window.as(gtk.Window).setTitle(self.titleFor(base));
            if (self.arena.allocator().dupeSentinel(u8, base, 0)) |z| self.setTabTitle(z) else |_| {}
            self.show(first);
            return;
        }
        const name = if (args.len > 1) std.mem.span(args[1]) else first;
        const section: ?[]const u8 = if (args.len > 1) first else null;
        for (self.entries, 0..) |e, i| {
            if (!std.mem.eql(u8, e.name, name)) continue;
            if (section) |s| if (!std.mem.startsWith(u8, e.section, s)) continue;
            self.selectRow(i);
            return;
        }
        self.message("No help found for that name.");
    }

    fn titleFor(self: *Help, what: []const u8) [:0]const u8 {
        return std.fmt.allocPrintSentinel(self.arena.allocator(), "{s} - Help", .{what}, 0) catch "Help";
    }

    fn message(self: *Help, text: [:0]const u8) void {
        self.currentView().getBuffer().setText(text, @intCast(text.len));
    }

    fn show(self: *Help, path: []const u8) void {
        const rendered = index.load(self.allocator, common.fsio.io(), path, self.dirs) catch |err| {
            var buf: [256:0]u8 = undefined;
            const text = std.fmt.bufPrintSentinel(&buf, "Cannot show {s}: {s}", .{ path, @errorName(err) }, 0) catch "Cannot show this page.";
            self.message(text);
            return;
        };
        defer rendered.deinit(self.allocator);
        const view = self.currentView();
        const buffer = view.getBuffer();
        const text = self.allocator.dupeSentinel(u8, rendered.text, 0) catch return;
        defer self.allocator.free(text);
        buffer.setText(text, @intCast(rendered.text.len));
        var start: gtk.TextIter = undefined;
        var end: gtk.TextIter = undefined;
        for (rendered.spans) |s| {
            buffer.getIterAtOffset(&start, @intCast(s.start));
            buffer.getIterAtOffset(&end, @intCast(s.end));
            buffer.applyTagByName(@tagName(s.style), &start, &end);
        }
        // Back to the top of the new page.
        buffer.getStartIter(&start);
        _ = view.scrollToIter(&start, 0, 0, 0, 0);
    }

    /// Clicking a row shows the page in the current tab.
    fn onRow(_: *gtk.ListBox, row: ?*gtk.ListBoxRow, self: *Help) callconv(.c) void {
        const r = row orelse return;
        const i: usize = @intCast(r.getIndex());
        if (i >= self.entries.len) return;
        self.openEntry(i);
    }

    fn onSearch(entry: *gtk.SearchEntry, self: *Help) callconv(.c) void {
        const query = std.mem.span(entry.as(gtk.Editable).getText());
        const hits = index.filter(self.allocator, self.entries, query) catch return;
        defer self.allocator.free(hits);
        // Rows are shown or hidden, never rebuilt, so the selection and the
        // scroll position survive typing.
        var next: usize = 0;
        for (self.entries, 0..) |_, i| {
            const visible = next < hits.len and hits[next] == i;
            if (visible) next += 1;
            if (self.list.getRowAtIndex(@intCast(i))) |row| row.as(gtk.Widget).setVisible(@intFromBool(visible));
        }
    }

    /// Enter in the search box opens the first match.
    fn onActivate(entry: *gtk.SearchEntry, self: *Help) callconv(.c) void {
        const query = std.mem.span(entry.as(gtk.Editable).getText());
        const hits = index.filter(self.allocator, self.entries, query) catch return;
        defer self.allocator.free(hits);
        if (hits.len > 0) self.selectRow(hits[0]);
    }
};

const dkman = @import("dkman");

/// DKDE's documents: $DKDE_HELP_DIR (used from the source tree), otherwise
/// share/dkde/help in the first data directory that has it.
fn helpDir(allocator: std.mem.Allocator) ?[]const u8 {
    if (glib.getenv("DKDE_HELP_DIR")) |d| return std.mem.span(d);
    const found = common.paths.systemDataFile(allocator, "help") catch return null;
    return if (found) |f| f else null;
}

fn addShortcut(keys: *gtk.ShortcutController, comptime accel: [:0]const u8, comptime handler: anytype, help: *Help) void {
    const trigger = gtk.ShortcutTrigger.parseString(accel) orelse return;
    const action = gtk.CallbackAction.new(@ptrCast(&handler), help, null);
    keys.addShortcut(gtk.Shortcut.new(trigger, action.as(gtk.ShortcutAction)));
}

fn addTags(table: *gtk.TextTagTable) void {
    addTag(table, "h1", .{ .{ "weight", @as(c_int, 700) }, .{ "scale", @as(f64, 1.6) }, .{ "pixels-below-lines", @as(c_int, 6) } });
    addTag(table, "h2", .{ .{ "weight", @as(c_int, 700) }, .{ "scale", @as(f64, 1.35) } });
    addTag(table, "h3", .{ .{ "weight", @as(c_int, 700) }, .{ "scale", @as(f64, 1.15) } });
    addTag(table, "bold", .{.{ "weight", @as(c_int, 700) }});
    addTag(table, "italic", .{.{ "style", pango.Style.italic }});
    addTag(table, "code", .{.{ "family", @as([*:0]const u8, "monospace") }});
    addTag(table, "code_block", .{ .{ "family", @as([*:0]const u8, "monospace") }, .{ "left-margin", @as(c_int, 36) } });
    addTag(table, "quote", .{.{ "left-margin", @as(c_int, 40) }});
    addTag(table, "link", .{ .{ "foreground", @as([*:0]const u8, "#2a6ebb") }, .{ "underline", pango.Underline.single } });
    addTag(table, "strike", .{.{ "strikethrough", true }});
    addTag(table, "term", .{.{ "weight", @as(c_int, 700) }});
}

fn addTag(table: *gtk.TextTagTable, comptime name: [:0]const u8, props: anytype) void {
    const tag = gtk.TextTag.new(name);
    inline for (props) |p| {
        var v = gobject.ext.Value.newFrom(p[1]);
        defer v.unset();
        tag.as(gobject.Object).setProperty(p[0], &v);
    }
    _ = table.add(tag);
    tag.as(gobject.Object).unref();
}

pub fn main(init: std.process.Init.Minimal) !void {
    cli.handle(init.args, .{
        .name = "dkde-help",
        .summary = "Help viewer for DKDE documents and manual pages",
        .usage = "[[SECTION] NAME | FILE]",
    });
    try common.runapp.run("org.dkde.help", Help, init);
}

test {
    _ = @import("render.zig");
    _ = @import("index.zig");
}
