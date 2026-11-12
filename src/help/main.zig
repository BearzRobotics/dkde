//! dkde-help: the help viewer. It shows DKDE's own documents (Markdown in
//! share/dkde/help) and the system's manual pages (man(7) and mdoc(7), found
//! through MANPATH) in one window, with a search box. Finding, reading and
//! parsing pages is the dkman library's; markdown is md-zig's, roff is
//! gtroff-zig's. No network is used (DKDE-050).

const std = @import("std");
const cli = @import("cli");
const glib = @import("glib2");
const gio = @import("gio2");
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
    /// How the list is grouped, and the groups (in the arena).
    browse: *gtk.DropDown,
    grouping: index.Grouping = .topic,
    groups: []index.Group = &.{},
    list: *gtk.ListView,
    selection: ?*gtk.SingleSelection = null,
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
            .browse = undefined,
            .list = gtk.ListView.new(null, null),
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
        // How to browse: by topic, section, folder or letter.
        var names: [5:null]?[*:0]const u8 = .{ index.Grouping.topic.label(), index.Grouping.section.label(), index.Grouping.folder.label(), index.Grouping.letter.label(), null };
        self.browse = gtk.DropDown.newFromStrings(@ptrCast(&names));
        self.browse.as(gtk.Widget).setTooltipText(common.tr("How the list is arranged"));
        inline for (.{ "setMarginStart", "setMarginEnd", "setMarginBottom" }) |m| @field(gtk.Widget, m)(self.browse.as(gtk.Widget), 8);
        const factory = gtk.SignalListItemFactory.new();
        _ = gtk.SignalListItemFactory.signals.setup.connect(factory, *Help, &onItemSetup, self, .{});
        _ = gtk.SignalListItemFactory.signals.bind.connect(factory, *Help, &onItemBind, self, .{});
        self.list.setFactory(factory.as(gtk.ListItemFactory));
        factory.as(gobject.Object).unref();
        self.list.as(gtk.Widget).addCssClass("navigation-sidebar");
        const list_scroller = gtk.ScrolledWindow.new();
        list_scroller.setChild(self.list.as(gtk.Widget));
        list_scroller.as(gtk.Widget).setVexpand(1);
        const side = gtk.Box.new(.vertical, 0);
        side.append(self.search.as(gtk.Widget));
        side.append(self.browse.as(gtk.Widget));
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
        _ = gtk.ListView.signals.activate.connect(self.list, *Help, &onListActivate, self, .{});
        _ = gobject.Object.signals.notify.connect(self.browse, *Help, &onBrowse, self, .{ .detail = "selected" });
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

    // ---- the list ---------------------------------------------------------------------------
    //
    // A ListView over a TreeListModel: each item is a GtkStringObject, "g<n>"
    // for group n or "e<n>" for entry n. While searching, the matches are
    // listed without groups.

    const Item = union(enum) { group: usize, entry: usize };

    fn itemOf(obj: *gobject.Object) ?Item {
        const so: *gtk.StringObject = @ptrCast(@alignCast(obj));
        const text = std.mem.span(so.getString());
        if (text.len < 2) return null;
        const n = std.fmt.parseInt(usize, text[1..], 10) catch return null;
        return if (text[0] == 'g') .{ .group = n } else .{ .entry = n };
    }

    /// The children of a group (entries have none).
    fn childrenOf(obj: *gobject.Object, data: ?*anyopaque) callconv(.c) ?*gio.ListModel {
        const self: *Help = @ptrCast(@alignCast(data.?));
        const item = itemOf(obj) orelse return null;
        if (item != .group or item.group >= self.groups.len) return null;
        return self.stringList(.entry, self.groups[item.group].members);
    }

    fn stringList(self: *Help, comptime kind: std.meta.Tag(Item), ids: anytype) *gio.ListModel {
        const list = gtk.StringList.new(null);
        var buf: [24]u8 = undefined;
        for (ids, 0..) |id, i| {
            const n: usize = if (kind == .group) i else id;
            const text = std.fmt.bufPrintSentinel(&buf, "{c}{d}", .{ @as(u8, if (kind == .group) 'g' else 'e'), n }, 0) catch continue;
            list.append(text);
        }
        _ = self;
        return list.as(gio.ListModel);
    }

    /// Shows `root` (groups or matches) in the list.
    fn setRoot(self: *Help, root: *gio.ListModel) void {
        const tree = gtk.TreeListModel.new(root, 0, 0, childrenOf, self, null);
        const sel = gtk.SingleSelection.new(tree.as(gio.ListModel));
        sel.setAutoselect(0);
        sel.setCanUnselect(1);
        _ = gtk.SelectionModel.signals.selection_changed.connect(sel.as(gtk.SelectionModel), *Help, &onSelection, self, .{});
        self.list.setModel(sel.as(gtk.SelectionModel));
        sel.as(gobject.Object).unref();
        self.selection = sel;
    }

    fn showGroups(self: *Help) void {
        self.groups = index.group(self.arena.allocator(), self.entries, self.grouping) catch &.{};
        self.setRoot(self.stringList(.group, self.groups));
    }

    fn onItemSetup(_: *gtk.SignalListItemFactory, obj: *gobject.Object, _: *Help) callconv(.c) void {
        const item: *gtk.ListItem = @ptrCast(@alignCast(obj));
        const expander = gtk.TreeExpander.new();
        const label = gtk.Label.new("");
        label.setXalign(0);
        label.setEllipsize(.end);
        expander.setChild(label.as(gtk.Widget));
        item.setChild(expander.as(gtk.Widget));
    }

    fn onItemBind(_: *gtk.SignalListItemFactory, obj: *gobject.Object, self: *Help) callconv(.c) void {
        const item: *gtk.ListItem = @ptrCast(@alignCast(obj));
        const row: *gtk.TreeListRow = @ptrCast(@alignCast(item.getItem() orelse return));
        const expander: *gtk.TreeExpander = @ptrCast(@alignCast(item.getChild() orelse return));
        expander.setListRow(row);
        const label: *gtk.Label = @ptrCast(@alignCast(expander.getChild() orelse return));
        const what = itemOf(row.getItem() orelse return) orelse return;
        var buf: [300]u8 = undefined;
        switch (what) {
            .group => |g| {
                if (g >= self.groups.len) return;
                const grp = self.groups[g];
                label.setText(std.fmt.bufPrintSentinel(&buf, "{s}  ({d})", .{ grp.title, grp.members.len }, 0) catch "");
                label.as(gtk.Widget).addCssClass("heading");
            },
            .entry => |e| {
                if (e >= self.entries.len) return;
                var lb: [160]u8 = undefined;
                label.setText(std.fmt.bufPrintSentinel(&buf, "{s}", .{self.entries[e].label(&lb)}, 0) catch "");
                label.as(gtk.Widget).removeCssClass("heading");
            },
        }
    }

    fn rowAt(self: *Help, position: c_uint) ?*gtk.TreeListRow {
        const sel = self.selection orelse return null;
        const model = sel.getModel() orelse return null;
        const obj = model.getItem(position) orelse return null;
        return @ptrCast(@alignCast(obj));
    }

    /// A click: a page shows in the current tab; a group opens or closes.
    fn onSelection(sel: *gtk.SelectionModel, _: c_uint, _: c_uint, self: *Help) callconv(.c) void {
        const single: *gtk.SingleSelection = @ptrCast(@alignCast(sel));
        const obj = single.getSelectedItem() orelse return;
        const row: *gtk.TreeListRow = @ptrCast(@alignCast(obj));
        const what = itemOf(row.getItem() orelse return) orelse return;
        switch (what) {
            .entry => |e| if (e < self.entries.len) self.openEntry(e),
            .group => {
                row.setExpanded(@intFromBool(row.getExpanded() == 0));
                _ = single.as(gtk.SelectionModel).unselectAll();
            },
        }
    }

    /// Double-click or Enter on a page opens it in a new tab.
    fn onListActivate(_: *gtk.ListView, position: c_uint, self: *Help) callconv(.c) void {
        const row = self.rowAt(position) orelse return;
        defer row.as(gobject.Object).unref();
        const what = itemOf(row.getItem() orelse return) orelse return;
        if (what != .entry or what.entry >= self.entries.len) return;
        _ = self.newTab();
        self.openEntry(what.entry);
    }

    fn onBrowse(dd: *gtk.DropDown, _: *gobject.ParamSpec, self: *Help) callconv(.c) void {
        self.grouping = switch (dd.getSelected()) {
            1 => .section,
            2 => .folder,
            3 => .letter,
            else => .topic,
        };
        if (std.mem.span(self.search.as(gtk.Editable).getText()).len == 0) self.showGroups();
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
        self.showGroups();
    }

    fn selectRow(self: *Help, i: usize) void {
        if (i < self.entries.len) self.openEntry(i);
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

    /// Typing lists the matches without groups; an empty box shows the groups again.
    fn onSearch(entry: *gtk.SearchEntry, self: *Help) callconv(.c) void {
        const query = std.mem.trim(u8, std.mem.span(entry.as(gtk.Editable).getText()), " ");
        if (query.len == 0) return self.showGroups();
        const hits = index.filter(self.allocator, self.entries, query) catch return;
        defer self.allocator.free(hits);
        self.setRoot(self.stringList(.entry, hits));
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
    // Columns line up only in a fixed-width font.
    // Not wrapped either: a wide table scrolls sideways instead.
    addTag(table, "table", .{ .{ "family", @as([*:0]const u8, "monospace") }, .{ "left-margin", @as(c_int, 12) }, .{ "wrap-mode", gtk.WrapMode.none } });
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
