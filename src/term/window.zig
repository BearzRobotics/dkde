//! The terminal window (SPEC.md 5.3): client-side decorations with the tab
//! strip in the title bar, a "+" button for a new tab with the default
//! profile, and a dropdown listing every profile.

const std = @import("std");
const gdk = @import("gdk4");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

const profile_mod = @import("profile.zig");
const TerminalView = @import("view.zig").TerminalView;

const log = std.log.scoped(.term);

const default_scrollback_lines = 10_000;

const Tab = struct {
    window: *TermWindow,
    view: *TerminalView,
    button: *gtk.ToggleButton,
    label: *gtk.Label,
};

pub const TermWindow = struct {
    allocator: std.mem.Allocator,
    config: *common.Config,
    window: *gtk.ApplicationWindow,
    stack: *gtk.Stack,
    search_bar: *gtk.SearchBar,
    search_entry: *gtk.SearchEntry,
    strip: *gtk.Box,
    profile_menu: *gtk.Box,
    profile_popover: *gtk.Popover,
    tabs: std.ArrayList(*Tab) = .empty,
    /// First button of the tab group, so new tabs can join it.
    group_leader: ?*gtk.ToggleButton = null,
    closing: bool = false,

    pub fn create(allocator: std.mem.Allocator, app: *gtk.Application, config: *common.Config, command: ?[]const []const u8) !*TermWindow {
        const self = try allocator.create(TermWindow);
        errdefer allocator.destroy(self);

        const window = gtk.ApplicationWindow.new(app);
        const popover = gtk.Popover.new();
        const menu_box = gtk.Box.new(.vertical, 0);
        popover.setChild(menu_box.as(gtk.Widget));
        self.* = .{
            .allocator = allocator,
            .config = config,
            .window = window,
            .stack = gtk.Stack.new(),
            .search_bar = gtk.SearchBar.new(),
            .search_entry = gtk.SearchEntry.new(),
            .strip = gtk.Box.new(.horizontal, 2),
            .profile_menu = menu_box,
            .profile_popover = popover,
        };

        window.as(gtk.Window).setTitle(common.tr("Terminal"));
        window.as(gtk.Window).setDefaultSize(900, 560);
        window.as(gtk.Widget).addCssClass("dkde");

        // Title bar: [tabs] [+] [v]
        const header = common.header.create(window.as(gtk.Window), "utilities-terminal", false);
        self.strip.as(gtk.Widget).addCssClass("dkde-tabs");
        // Left-aligned after the icon, like Windows Terminal; the [+] [v]
        // buttons follow the tabs.
        header.packStart(self.strip.as(gtk.Widget));

        const add = gtk.Button.newFromIconName("tab-new-symbolic");
        add.as(gtk.Widget).setTooltipText(common.tr("New tab"));
        _ = gtk.Button.signals.clicked.connect(add, *TermWindow, &onNewTab, self, .{});
        const more = gtk.MenuButton.new();
        more.setPopover(popover);
        more.as(gtk.Widget).setTooltipText(common.tr("Open a tab with a profile"));
        const group = gtk.Box.new(.horizontal, 0);
        group.as(gtk.Widget).addCssClass("linked");
        group.append(add.as(gtk.Widget));
        group.append(more.as(gtk.Widget));
        header.packStart(group.as(gtk.Widget));
        // Find bar above the terminal (Ctrl+Shift+F).
        self.search_entry.as(gtk.Widget).setHexpand(1);
        self.search_bar.setChild(self.search_entry.as(gtk.Widget));
        self.search_bar.connectEntry(self.search_entry.as(gtk.Editable));
        _ = gtk.SearchEntry.signals.search_changed.connect(self.search_entry, *TermWindow, &onSearchChanged, self, .{});
        _ = gtk.SearchEntry.signals.next_match.connect(self.search_entry, *TermWindow, &onSearchNext, self, .{});
        _ = gtk.SearchEntry.signals.previous_match.connect(self.search_entry, *TermWindow, &onSearchPrevious, self, .{});
        _ = gtk.SearchEntry.signals.activate.connect(self.search_entry, *TermWindow, &onSearchNext, self, .{});
        _ = gtk.SearchEntry.signals.stop_search.connect(self.search_entry, *TermWindow, &onSearchStop, self, .{});
        const mb = common.menubar;
        const menus = [_]mb.Menu{
            .{ .label = "_File", .entries = &.{
                mb.item("New _Tab", "new-tab", "<Control><Shift>t"),
                mb.item("_Close Tab", "close-tab", "<Control><Shift>w"),
                .separator,
                mb.item("_Quit", "quit", "<Control><Shift>q"),
            } },
            .{ .label = "_Edit", .entries = &.{
                mb.item("_Copy", "copy", "<Control><Shift>c"),
                mb.item("_Paste", "paste", "<Control><Shift>v"),
                .separator,
                mb.item("_Find…", "find", "<Control><Shift>f"),
                .separator,
                mb.item("_Preferences…", "preferences", "<Control>comma"),
            } },
            .{ .label = "_View", .entries = &.{
                mb.item("_Full Screen", "fullscreen", "F11"),
            } },
            .{ .label = "_Tabs", .entries = &.{
                mb.item("_Next Tab", "next-tab", "<Control>Page_Down"),
                mb.item("_Previous Tab", "prev-tab", "<Control>Page_Up"),
            } },
        };
        const menu_bar = mb.build(app, window, &menus, TermWindow, onMenubarAction, self);

        const body = gtk.Box.new(.vertical, 0);
        body.append(menu_bar.as(gtk.Widget));
        body.append(self.search_bar.as(gtk.Widget));
        self.stack.as(gtk.Widget).setVexpand(1);
        body.append(self.stack.as(gtk.Widget));
        window.as(gtk.Window).setChild(body.as(gtk.Widget));

        self.installShortcuts();
        self.rebuildProfileMenu();
        _ = gtk.Widget.signals.destroy.connect(window, *TermWindow, &onDestroy, self, .{});

        try self.newTab(null, command, null);
        self.applyProfileWindow();
        self.updateTransparency();
        self.config.watch(TermWindow, onConfigChanged, self) catch |err|
            std.log.warn("config not watched: {s}", .{@errorName(err)});
        return self;
    }

    /// Size and startup mode from the profile of the first tab.
    fn applyProfileWindow(self: *TermWindow) void {
        const tab = self.currentTab() orelse return;
        const prof = tab.view.profile;
        const window = self.window.as(gtk.Window);
        if (prof.columns > 0 and prof.rows > 0) {
            const pad = 2 * @as(f64, @floatFromInt(prof.padding));
            // Plus the scroll bar on the right and the title bar and menu on top.
            const w = @as(f64, @floatFromInt(prof.columns)) * tab.view.cellWidth() + pad + 18;
            const h = @as(f64, @floatFromInt(prof.rows)) * tab.view.cellHeight() + pad + 112;
            window.setDefaultSize(@intFromFloat(w), @intFromFloat(h));
        }
        switch (prof.startup) {
            .windowed => {},
            .maximized => window.maximize(),
            .fullscreen => window.fullscreen(),
        }
    }

    /// A see-through profile needs a see-through window behind it. Any tab
    /// with opacity below 100% makes the window see-through, so the class is
    /// recomputed whenever tabs or settings change.
    fn updateTransparency(self: *TermWindow) void {
        var any = false;
        for (self.tabs.items) |tab| {
            if (tab.view.profile.opacity < 1.0) any = true;
        }
        const widget = self.window.as(gtk.Widget);
        if (any) widget.addCssClass("dkde-transparent") else widget.removeCssClass("dkde-transparent");
    }

    /// term.conf changed (usually in Settings): open tabs follow the new
    /// opacity of their profile. Fonts and colour schemes apply to new tabs.
    fn onConfigChanged(self: *TermWindow) void {
        for (self.tabs.items) |tab| {
            var fresh = profile_mod.load(self.allocator, self.config, tab.view.profile.name) catch continue;
            defer fresh.deinit(self.allocator);
            tab.view.setOpacity(fresh.opacity);
        }
        self.updateTransparency();
        self.rebuildProfileMenu();
    }

    pub fn present(self: *TermWindow) void {
        self.window.as(gtk.Window).present();
    }

    fn onDestroy(_: *gtk.ApplicationWindow, self: *TermWindow) callconv(.c) void {
        self.closing = true;
        for (self.tabs.items) |tab| {
            tab.view.shutdown();
            self.allocator.destroy(tab);
        }
        self.tabs.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    // ---- profiles --------------------------------------------------------

    fn defaultProfileName(self: *TermWindow) ![]u8 {
        return self.config.getString(self.allocator, "terminal", "default-profile", "Default");
    }

    fn rebuildProfileMenu(self: *TermWindow) void {
        while (self.profile_menu.as(gtk.Widget).getFirstChild()) |child| self.profile_menu.remove(child);
        const names = self.config.groupsWithPrefix(self.allocator, "profile:") catch return;
        defer common.config.freeStringList(self.allocator, names);

        if (names.len == 0) self.addProfileItem("Default");
        for (names) |name| self.addProfileItem(name);
    }

    const ProfileItem = struct { window: *TermWindow, name: []u8 };

    fn addProfileItem(self: *TermWindow, name: []const u8) void {
        var buf: [256]u8 = undefined;
        const label = std.fmt.bufPrintSentinel(&buf, "{s}", .{name}, 0) catch return;
        const button = gtk.Button.newWithLabel(label);
        button.setHasFrame(0);
        if (button.getChild()) |child| {
            const l: *gtk.Label = @ptrCast(@alignCast(child));
            l.setXalign(0);
        }
        const item = self.allocator.create(ProfileItem) catch return;
        item.* = .{ .window = self, .name = self.allocator.dupe(u8, name) catch return };
        _ = gtk.Button.signals.clicked.connect(button, *ProfileItem, &onProfileItem, item, .{});
        _ = gtk.Widget.signals.destroy.connect(button, *ProfileItem, &onProfileItemDestroy, item, .{});
        self.profile_menu.append(button.as(gtk.Widget));
    }

    fn onProfileItemDestroy(_: *gtk.Button, item: *ProfileItem) callconv(.c) void {
        item.window.allocator.free(item.name);
        item.window.allocator.destroy(item);
    }

    fn onProfileItem(_: *gtk.Button, item: *ProfileItem) callconv(.c) void {
        item.window.profile_popover.popdown();
        item.window.newTab(item.name, null, item.window.currentDirectory()) catch |err|
            log.err("cannot open a tab: {s}", .{@errorName(err)});
    }

    // ---- tabs ---------------------------------------------------------------

    fn onNewTab(_: *gtk.Button, self: *TermWindow) callconv(.c) void {
        self.newTab(null, null, self.currentDirectory()) catch |err|
            log.err("cannot open a tab: {s}", .{@errorName(err)});
    }

    /// The shell's directory in the visible tab, so new tabs start there
    /// (OSC 7, SPEC.md 5.3). Owned by the caller; freed via `freeDirectory`.
    fn currentDirectory(self: *TermWindow) ?[]u8 {
        const tab = self.currentTab() orelse return null;
        return tab.view.workingDirectory(self.allocator);
    }

    fn currentTab(self: *TermWindow) ?*Tab {
        const visible = self.stack.getVisibleChild() orelse return null;
        for (self.tabs.items) |tab| if (tab.view.widget() == visible) return tab;
        return null;
    }

    fn newTab(self: *TermWindow, profile_name: ?[]const u8, command: ?[]const []const u8, directory: ?[]u8) !void {
        defer if (directory) |d| self.allocator.free(d);

        const name = if (profile_name) |n| try self.allocator.dupe(u8, n) else try self.defaultProfileName();
        defer self.allocator.free(name);
        const prof = try profile_mod.load(self.allocator, self.config, name);

        const tab = try self.allocator.create(Tab);
        errdefer self.allocator.destroy(tab);

        const scrollback: usize = @intCast(@max(0, self.config.getInt("terminal", "scrollback-lines", default_scrollback_lines)));
        const view = try TerminalView.create(self.allocator, prof, command, directory, scrollback, .{
            .data = tab,
            .title_changed = onTitleChanged,
            .exited = onExited,
        });
        errdefer view.shutdown();

        const name_z = try self.allocator.dupeSentinel(u8, if (prof.title.len > 0) prof.title else name, 0);
        defer self.allocator.free(name_z);
        const label = gtk.Label.new(name_z);
        label.setEllipsize(.end);
        label.setMaxWidthChars(18);
        const close = gtk.Button.newFromIconName("window-close-symbolic");
        close.setHasFrame(0);
        close.as(gtk.Widget).setTooltipText(common.tr("Close tab"));
        const content = gtk.Box.new(.horizontal, 6);
        if (view.profile.icon.len > 0) {
            const icon_z = try self.allocator.dupeSentinel(u8, view.profile.icon, 0);
            defer self.allocator.free(icon_z);
            const icon = if (icon_z[0] == '/') gtk.Image.newFromFile(icon_z) else gtk.Image.newFromIconName(icon_z);
            icon.setPixelSize(16);
            content.append(icon.as(gtk.Widget));
        }
        content.append(label.as(gtk.Widget));
        content.append(close.as(gtk.Widget));

        const button = gtk.ToggleButton.new();
        button.as(gtk.Button).setChild(content.as(gtk.Widget));
        button.as(gtk.Widget).addCssClass("dkde-tab");
        if (view.profile.tab_color.len > 0) tabColor(self.allocator, button.as(gtk.Widget), view.profile.tab_color);
        if (self.group_leader) |leader| button.setGroup(leader) else self.group_leader = button;

        tab.* = .{ .window = self, .view = view, .button = button, .label = label };
        _ = gtk.ToggleButton.signals.toggled.connect(button, *Tab, &onTabToggled, tab, .{});
        _ = gtk.Button.signals.clicked.connect(close, *Tab, &onCloseClicked, tab, .{});

        try self.tabs.append(self.allocator, tab);
        self.strip.append(button.as(gtk.Widget));
        _ = self.stack.addChild(view.widget());
        self.select(tab);
        self.updateTransparency();
    }

    fn select(self: *TermWindow, tab: *Tab) void {
        self.stack.setVisibleChild(tab.view.widget());
        tab.button.setActive(1);
        tab.view.grabFocus();
        self.updateWindowTitle();
    }

    fn onTabToggled(button: *gtk.ToggleButton, tab: *Tab) callconv(.c) void {
        if (button.getActive() != 0) tab.window.select(tab);
    }

    fn onCloseClicked(_: *gtk.Button, tab: *Tab) callconv(.c) void {
        tab.window.closeTab(tab);
    }

    /// Paints the top edge of a tab in the profile's colour.
    fn tabColor(allocator: std.mem.Allocator, widget: *gtk.Widget, color: []const u8) void {
        // Only characters a colour can contain, so the value cannot close the rule.
        for (color) |c| if (!(std.ascii.isAlphanumeric(c) or c == '#' or c == '(' or c == ')' or c == ',' or c == '.' or c == ' ' or c == '%')) return;
        const css = std.fmt.allocPrintSentinel(allocator, "button.dkde-tab {{ border-top: 3px solid {s}; }}", .{color}, 0) catch return;
        defer allocator.free(css);
        const provider = gtk.CssProvider.new();
        provider.loadFromString(css);
        widget.getStyleContext().addProvider(provider.as(gtk.StyleProvider), gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 1);
    }

    fn onTitleChanged(data: *anyopaque, view: *TerminalView) void {
        const tab: *Tab = @ptrCast(@alignCast(data));
        // A profile with a fixed title keeps it.
        if (view.profile.title.len == 0) if (view.title()) |t| {
            var buf: [256]u8 = undefined;
            const text = std.fmt.bufPrintSentinel(&buf, "{s}", .{t}, 0) catch return;
            tab.label.setText(text);
            tab.button.as(gtk.Widget).setTooltipText(text);
        };
        tab.window.updateWindowTitle();
    }

    fn onExited(data: *anyopaque, view: *TerminalView) void {
        const tab: *Tab = @ptrCast(@alignCast(data));
        // "close-on-exit": a tab can stay open to show what the program printed.
        if (!profile_mod.closesTab(view.profile.close_on_exit, view.exit_status)) {
            var buf: [96]u8 = undefined;
            const code = profile_mod.exitCode(view.exit_status);
            view.printNotice(std.fmt.bufPrint(&buf, "[Process exited with code {d}. Close the tab with Ctrl+Shift+W.]", .{code}) catch "[Process exited]");
            return;
        }
        // Closing from inside the child-watch callback would free the view
        // that is running it; do it from an idle callback.
        _ = glib.idleAdd(closeTabIdle, tab);
    }

    fn closeTabIdle(data: ?*anyopaque) callconv(.c) c_int {
        const tab: *Tab = @ptrCast(@alignCast(data.?));
        tab.window.closeTab(tab);
        return 0;
    }

    fn closeTab(self: *TermWindow, tab: *Tab) void {
        if (self.closing) return;
        const index = std.mem.indexOfScalar(*Tab, self.tabs.items, tab) orelse return;
        _ = self.tabs.orderedRemove(index);

        if (self.group_leader == tab.button) self.group_leader = if (self.tabs.items.len > 0) self.tabs.items[0].button else null;
        tab.view.shutdown();
        self.strip.remove(tab.button.as(gtk.Widget));
        self.stack.remove(tab.view.widget());
        self.allocator.destroy(tab);

        if (self.tabs.items.len == 0) {
            self.window.as(gtk.Window).close();
            return;
        }
        self.select(self.tabs.items[@min(index, self.tabs.items.len - 1)]);
        self.updateTransparency();
    }

    fn updateWindowTitle(self: *TermWindow) void {
        const tab = self.currentTab() orelse return;
        var buf: [256]u8 = undefined;
        const text = std.fmt.bufPrintSentinel(&buf, "{s}", .{tab.view.title() orelse "Terminal"}, 0) catch return;
        self.window.as(gtk.Window).setTitle(text);
    }

    // ---- shortcuts -----------------------------------------------------------

    const Shortcut = struct { trigger: [:0]const u8, action: enum { new_tab, close_tab, next_tab, prev_tab, quit, find, fullscreen } };
    const shortcuts = [_]Shortcut{
        .{ .trigger = "<Control><Shift>t", .action = .new_tab },
        .{ .trigger = "<Control><Shift>w", .action = .close_tab },
        .{ .trigger = "<Control>Page_Down", .action = .next_tab },
        .{ .trigger = "<Control>Page_Up", .action = .prev_tab },
        .{ .trigger = "<Control><Shift>q", .action = .quit },
        .{ .trigger = "<Control><Shift>f", .action = .find },
        .{ .trigger = "F11", .action = .fullscreen },
    };

    fn installShortcuts(self: *TermWindow) void {
        const controller = gtk.ShortcutController.new();
        controller.as(gtk.EventController).setPropagationPhase(.capture);
        inline for (shortcuts) |s| {
            const action = gtk.CallbackAction.new(onShortcut, @ptrCast(@constCast(&s)), null);
            controller.addShortcut(gtk.Shortcut.new(gtk.ShortcutTrigger.parseString(s.trigger), @ptrCast(action)));
        }
        self.window.as(gtk.Widget).addController(controller.as(gtk.EventController));
        self.window.as(gobject.Object).setData("dkde-term-window", self);
    }

    fn onShortcut(widget: *gtk.Widget, _: ?*glib.Variant, data: ?*anyopaque) callconv(.c) c_int {
        const shortcut: *const Shortcut = @ptrCast(@alignCast(data.?));
        const obj: *gobject.Object = @ptrCast(@alignCast(widget));
        const self: *TermWindow = @ptrCast(@alignCast(obj.getData("dkde-term-window") orelse return 0));
        switch (shortcut.action) {
            .new_tab => self.newTab(null, null, self.currentDirectory()) catch {},
            .close_tab => if (self.currentTab()) |tab| self.closeTab(tab),
            .next_tab, .prev_tab => self.cycle(shortcut.action == .next_tab),
            .quit => self.window.as(gtk.Window).close(),
            .fullscreen => {
                if (self.window.as(gtk.Window).isFullscreen() != 0) self.window.as(gtk.Window).unfullscreen() else self.window.as(gtk.Window).fullscreen();
            },
            .find => {
                self.search_bar.setSearchMode(1);
                _ = self.search_entry.as(gtk.Widget).grabFocus();
            },
        }
        return 1;
    }

    fn onMenubarAction(self: *TermWindow, action: []const u8) void {
        const eql = std.mem.eql;
        if (eql(u8, action, "new-tab")) return self.newTab(null, null, self.currentDirectory()) catch {};
        if (eql(u8, action, "close-tab")) {
            if (self.currentTab()) |tab| self.closeTab(tab);
            return;
        }
        if (eql(u8, action, "quit")) return self.window.as(gtk.Window).close();
        if (eql(u8, action, "copy")) {
            if (self.currentTab()) |tab| tab.view.copySelection();
            return;
        }
        if (eql(u8, action, "paste")) {
            if (self.currentTab()) |tab| tab.view.pasteClipboard(false);
            return;
        }
        if (eql(u8, action, "find")) {
            self.search_bar.setSearchMode(1);
            _ = self.search_entry.as(gtk.Widget).grabFocus();
            return;
        }
        if (eql(u8, action, "preferences")) {
            // Profiles, colours, fonts and scrollback live on the Terminal page of Settings.
            common.appinfo.spawn(self.allocator, &.{ "dkde-settings", "--page", "terminal" });
            return;
        }
        if (eql(u8, action, "fullscreen")) {
            if (self.window.as(gtk.Window).isFullscreen() != 0) self.window.as(gtk.Window).unfullscreen() else self.window.as(gtk.Window).fullscreen();
            return;
        }
        if (eql(u8, action, "next-tab")) return self.cycle(true);
        if (eql(u8, action, "prev-tab")) return self.cycle(false);
    }

    fn onSearchChanged(entry: *gtk.SearchEntry, self: *TermWindow) callconv(.c) void {
        const tab = self.currentTab() orelse return;
        tab.view.searchSet(std.mem.span(entry.as(gtk.Editable).getText()));
    }

    fn onSearchNext(_: *gtk.SearchEntry, self: *TermWindow) callconv(.c) void {
        if (self.currentTab()) |tab| _ = tab.view.searchStep(true);
    }

    fn onSearchPrevious(_: *gtk.SearchEntry, self: *TermWindow) callconv(.c) void {
        if (self.currentTab()) |tab| _ = tab.view.searchStep(false);
    }

    fn onSearchStop(_: *gtk.SearchEntry, self: *TermWindow) callconv(.c) void {
        self.search_bar.setSearchMode(0);
        if (self.currentTab()) |tab| {
            tab.view.searchClose();
            tab.view.grabFocus();
        }
    }

    fn cycle(self: *TermWindow, forward: bool) void {
        const current = self.currentTab() orelse return;
        const index = std.mem.indexOfScalar(*Tab, self.tabs.items, current) orelse return;
        const n = self.tabs.items.len;
        self.select(self.tabs.items[if (forward) (index + 1) % n else (index + n - 1) % n]);
    }
};
