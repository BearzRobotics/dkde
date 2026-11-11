//! The terminal window (SPEC.md 5.3): client-side decorations with the tab
//! strip in the title bar, a "+" button for a new tab with the default
//! profile, and a dropdown listing every profile and container.
//!
//! A tab holds one or more panes, split as in Konsole: left/right or
//! top/bottom (Ctrl+Shift+( and Ctrl+Shift+), or Alt+Shift+Plus/Minus), each
//! with a small title bar once there are several. A pane can be maximised in
//! its tab (Ctrl+Shift+E), the split moved from the keyboard (Ctrl+Shift+[
//! and ]), the panes evened out, the focus moved by direction
//! (Ctrl+Alt+arrows), and two panes swapped by dragging one's title bar onto
//! the other. Tabs can be renamed, dragged to reorder or out into a window of
//! their own; closing something with a program still running asks first.

const std = @import("std");
const gdk = @import("gdk4");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const graphene = @import("graphene1");
const gtk = @import("gtk4");
const common = @import("common");

const profile_mod = @import("profile.zig");
const finder_mod = @import("finder.zig");
const TerminalView = @import("view.zig").TerminalView;
const session = @import("session.zig");

const log = std.log.scoped(.term);

const default_scrollback_lines = 10_000;

/// One terminal in a tab, with its title bar (shown when the tab is split).
const Pane = struct {
    view: *TerminalView,
    /// The bar above the terminal, then the terminal: what sits in the split.
    frame: *gtk.Box,
    header: *gtk.Box,
    title: *gtk.Label,
    max_button: *gtk.Button,
};

const Tab = struct {
    window: *TermWindow,
    /// What the stack shows for the tab: holds the pane tree (one frame, or
    /// nested `gtk.Paned` that end in frames).
    root: *gtk.Box,
    /// Every pane of the tab, in the order they were opened.
    panes: std.ArrayList(*Pane) = .empty,
    /// The pane that has (or last had) the keyboard focus.
    active: *Pane,
    button: *gtk.ToggleButton,
    label: *gtk.Label,
    /// A name the user gave the tab; it then stops following the program.
    custom_title: ?[]u8 = null,
    /// The pane filling the tab while the others are hidden.
    maximized: ?*Pane = null,
    /// The bell rang while the tab was not showing.
    attention: bool = false,

    fn paneOf(self: *const Tab, view: *TerminalView) ?*Pane {
        for (self.panes.items) |p| if (p.view == view) return p;
        return null;
    }

    fn profileName(self: *const Tab) []const u8 {
        return self.panes.items[0].view.profile.name;
    }

    /// The tab's label: the user's name for it, a fixed profile title, or
    /// the active pane's title.
    fn refreshLabel(self: *Tab) void {
        var buf: [300]u8 = undefined;
        const base: []const u8 = self.custom_title orelse
            (if (self.active.view.profile.title.len > 0) self.active.view.profile.title else self.active.view.title() orelse self.active.view.profile.name);
        const text = std.fmt.bufPrintSentinel(&buf, "{s}{s}", .{ if (self.attention) "\u{1F514} " else "", base[0..@min(base.len, 250)] }, 0) catch return;
        self.label.setText(text);
        self.button.as(gtk.Widget).setTooltipText(text);
    }
};

/// A pane to close once the callback that found it has returned.
const PaneRef = struct { tab: *Tab, view: *TerminalView };

/// The tab being dragged by its button, if any (drags stay in this process).
var dragged_tab: ?*Tab = null;
/// The pane being dragged by its title bar.
var dragged_pane: ?*Pane = null;
/// Every open window, so a dragged tab can join another and the session is
/// written when the last one closes.
var all_windows: std.ArrayList(*TermWindow) = .empty;

/// Every window action with its default shortcut; term.toml's [shortcuts]
/// group can give any of them another (or none, with "").
const actions = [_]struct { name: [:0]const u8, accel: ?[:0]const u8 }{
    .{ .name = "new-tab", .accel = "<Control><Shift>t" },
    .{ .name = "new-window", .accel = "<Control><Shift>n" },
    .{ .name = "close-pane", .accel = "<Control><Shift>w" },
    .{ .name = "close-tab", .accel = null },
    .{ .name = "save-output", .accel = "<Control><Shift>s" },
    .{ .name = "quit", .accel = "<Control><Shift>q" },
    .{ .name = "copy", .accel = "<Control><Shift>c" },
    .{ .name = "copy-html", .accel = null },
    .{ .name = "paste", .accel = "<Control><Shift>v" },
    .{ .name = "select-all", .accel = "<Control><Shift>a" },
    .{ .name = "find", .accel = "<Control><Shift>f" },
    .{ .name = "clear-scrollback", .accel = "<Control><Shift>k" },
    .{ .name = "reset", .accel = null },
    .{ .name = "read-only", .accel = null },
    .{ .name = "preferences", .accel = "<Control>comma" },
    .{ .name = "zoom-in", .accel = "<Control>plus" },
    .{ .name = "zoom-out", .accel = "<Control>minus" },
    .{ .name = "zoom-reset", .accel = "<Control>0" },
    .{ .name = "fullscreen", .accel = "F11" },
    .{ .name = "monitor-activity", .accel = null },
    .{ .name = "monitor-silence", .accel = null },
    .{ .name = "split-right", .accel = "<Control><Shift>parenleft" },
    .{ .name = "split-down", .accel = "<Control><Shift>parenright" },
    .{ .name = "maximize-pane", .accel = "<Control><Shift>e" },
    .{ .name = "grow-pane", .accel = "<Control><Shift>bracketright" },
    .{ .name = "shrink-pane", .accel = "<Control><Shift>bracketleft" },
    .{ .name = "equal-panes", .accel = null },
    // Ctrl+Alt+arrows switch desktops in labwc: Alt+Shift, as Windows Terminal.
    .{ .name = "focus-left", .accel = "<Alt><Shift>Left" },
    .{ .name = "focus-right", .accel = "<Alt><Shift>Right" },
    .{ .name = "focus-up", .accel = "<Alt><Shift>Up" },
    .{ .name = "focus-down", .accel = "<Alt><Shift>Down" },
    .{ .name = "rename-tab", .accel = "<Control><Alt>s" },
    .{ .name = "move-tab-left", .accel = "<Control><Shift>Page_Up" },
    .{ .name = "move-tab-right", .accel = "<Control><Shift>Page_Down" },
    .{ .name = "detach-tab", .accel = null },
    .{ .name = "next-tab", .accel = "<Control>Page_Down" },
    .{ .name = "prev-tab", .accel = "<Control>Page_Up" },
};

/// Shortcuts kept from before, also accepted.
const extra_keys = [_]struct { accel: [:0]const u8, action: [:0]const u8 }{
    .{ .accel = "<Alt><Shift>plus", .action = "split-right" },
    .{ .accel = "<Alt><Shift>minus", .action = "split-down" },
    .{ .accel = "<Control>equal", .action = "zoom-in" },
    .{ .accel = "<Control>KP_Add", .action = "zoom-in" },
    .{ .accel = "<Control>KP_Subtract", .action = "zoom-out" },
};

pub const TermWindow = struct {
    allocator: std.mem.Allocator,
    app: *gtk.Application,
    config: *common.Config,
    window: *gtk.ApplicationWindow,
    stack: *gtk.Stack,
    search_bar: *gtk.SearchBar,
    search_entry: *gtk.SearchEntry,
    search_case: *gtk.CheckButton,
    search_word: *gtk.CheckButton,
    search_regex: *gtk.CheckButton,
    search_count: *gtk.Label,
    strip: *gtk.Box,
    profile_menu: *gtk.Box,
    container_menu: *gtk.Box,
    profile_popover: *gtk.Popover,
    tabs: std.ArrayList(*Tab) = .empty,
    /// First button of the tab group, so new tabs can join it.
    group_leader: ?*gtk.ToggleButton = null,
    closing: bool = false,
    /// The user agreed to close although programs were running.
    close_confirmed: bool = false,
    menu_bar: ?*gtk.PopoverMenuBar = null,
    zoom: f64 = 1.0,
    /// The drop-down terminal (dkde-term --dropdown): no menu bar, shown and
    /// hidden by the hotkey.
    dropdown: bool = false,

    pub fn create(allocator: std.mem.Allocator, app: *gtk.Application, config: *common.Config, command: ?[]const []const u8) !*TermWindow {
        const self = try createEmpty(allocator, app, config);
        try self.newTab(null, command, null);
        self.applyProfileWindow();
        self.updateTransparency();
        return self;
    }

    /// A window with no tab yet (a restored session or a detached tab fills it).
    pub fn createEmpty(allocator: std.mem.Allocator, app: *gtk.Application, config: *common.Config) !*TermWindow {
        const self = try allocator.create(TermWindow);
        errdefer allocator.destroy(self);

        const window = gtk.ApplicationWindow.new(app);
        const popover = gtk.Popover.new();
        const menu_box = gtk.Box.new(.vertical, 0);
        const outer = gtk.Box.new(.vertical, 4);
        const container_box = gtk.Box.new(.vertical, 0);
        outer.append(menu_box.as(gtk.Widget));
        outer.append(container_box.as(gtk.Widget));
        popover.setChild(outer.as(gtk.Widget));
        self.* = .{
            .allocator = allocator,
            .app = app,
            .config = config,
            .window = window,
            .stack = gtk.Stack.new(),
            .search_bar = gtk.SearchBar.new(),
            .search_entry = gtk.SearchEntry.new(),
            .search_case = gtk.CheckButton.newWithMnemonic(common.tr("Match _Case")),
            .search_word = gtk.CheckButton.newWithMnemonic(common.tr("_Whole Words")),
            .search_regex = gtk.CheckButton.newWithMnemonic(common.tr("Regular E_xpression")),
            .search_count = gtk.Label.new(""),
            .strip = gtk.Box.new(.horizontal, 2),
            .profile_menu = menu_box,
            .container_menu = container_box,
            .profile_popover = popover,
        };

        window.as(gtk.Window).setTitle(common.tr("Terminal"));
        const w = config.getInt("terminal", "width", 900);
        const h = config.getInt("terminal", "height", 560);
        window.as(gtk.Window).setDefaultSize(@max(300, w), @max(200, h));
        window.as(gtk.Widget).addCssClass("dkde");

        // Title bar: [tabs] [+] [v]
        const header = common.header.create(window.as(gtk.Window), "utilities-terminal", false);
        self.strip.as(gtk.Widget).addCssClass("dkde-tabs");
        header.packStart(self.strip.as(gtk.Widget));
        // Tabs dropped after the last one land at the end.
        const strip_drop = gtk.DropTarget.new(gobject.ext.types.string, .{ .move = true });
        _ = gtk.DropTarget.signals.drop.connect(strip_drop, *TermWindow, &onStripDrop, self, .{});
        self.strip.as(gtk.Widget).addController(strip_drop.as(gtk.EventController));

        const add = gtk.Button.newFromIconName("tab-new-symbolic");
        add.as(gtk.Widget).setTooltipText(common.tr("New tab"));
        _ = gtk.Button.signals.clicked.connect(add, *TermWindow, &onNewTab, self, .{});
        const more = gtk.MenuButton.new();
        more.setPopover(popover);
        more.as(gtk.Widget).setTooltipText(common.tr("Open a tab with a profile or in a container"));
        _ = gtk.Widget.signals.show.connect(popover, *TermWindow, &onProfileMenuShown, self, .{});
        const group = gtk.Box.new(.horizontal, 0);
        group.as(gtk.Widget).addCssClass("linked");
        group.append(add.as(gtk.Widget));
        group.append(more.as(gtk.Widget));
        header.packStart(group.as(gtk.Widget));

        self.buildSearchBar();
        const menu_bar = self.buildMenus(app);
        self.menu_bar = menu_bar;
        _ = gobject.Object.signals.notify.connect(window, *TermWindow, &onFullscreenChanged, self, .{ .detail = "fullscreened" });

        const body = gtk.Box.new(.vertical, 0);
        body.append(menu_bar.as(gtk.Widget));
        body.append(self.search_bar.as(gtk.Widget));
        self.stack.as(gtk.Widget).setVexpand(1);
        body.append(self.stack.as(gtk.Widget));
        window.as(gtk.Window).setChild(body.as(gtk.Widget));

        self.installShortcuts();
        self.rebuildProfileMenu();
        _ = gtk.Window.signals.close_request.connect(window.as(gtk.Window), *TermWindow, &onCloseRequest, self, .{});
        _ = gtk.Widget.signals.destroy.connect(window, *TermWindow, &onDestroy, self, .{});
        self.config.watch(TermWindow, onConfigChanged, self) catch |err|
            std.log.warn("config not watched: {s}", .{@errorName(err)});
        all_windows.append(std.heap.c_allocator, self) catch {};
        return self;
    }

    fn buildSearchBar(self: *TermWindow) void {
        const row = gtk.Box.new(.horizontal, 6);
        self.search_entry.as(gtk.Widget).setSizeRequest(280, -1);
        const prev = gtk.Button.newFromIconName("go-up-symbolic");
        prev.as(gtk.Widget).setTooltipText(common.tr("Older match (Shift+Enter)"));
        const next = gtk.Button.newFromIconName("go-down-symbolic");
        next.as(gtk.Widget).setTooltipText(common.tr("Newer match"));
        self.search_count.as(gtk.Widget).addCssClass("dim-label");
        self.search_count.setWidthChars(12);
        row.append(self.search_entry.as(gtk.Widget));
        row.append(prev.as(gtk.Widget));
        row.append(next.as(gtk.Widget));
        row.append(self.search_count.as(gtk.Widget));
        row.append(self.search_case.as(gtk.Widget));
        row.append(self.search_word.as(gtk.Widget));
        row.append(self.search_regex.as(gtk.Widget));
        self.search_bar.setChild(row.as(gtk.Widget));
        self.search_bar.connectEntry(self.search_entry.as(gtk.Editable));
        self.search_bar.setShowCloseButton(1);
        _ = gtk.SearchEntry.signals.search_changed.connect(self.search_entry, *TermWindow, &onSearchChanged, self, .{});
        _ = gtk.SearchEntry.signals.next_match.connect(self.search_entry, *TermWindow, &onSearchOlder, self, .{});
        _ = gtk.SearchEntry.signals.previous_match.connect(self.search_entry, *TermWindow, &onSearchNewer, self, .{});
        _ = gtk.SearchEntry.signals.activate.connect(self.search_entry, *TermWindow, &onSearchOlder, self, .{});
        _ = gtk.SearchEntry.signals.stop_search.connect(self.search_entry, *TermWindow, &onSearchStop, self, .{});
        _ = gtk.Button.signals.clicked.connect(prev, *TermWindow, &onSearchOlderButton, self, .{});
        _ = gtk.Button.signals.clicked.connect(next, *TermWindow, &onSearchNewerButton, self, .{});
        inline for (.{ self.search_case, self.search_word, self.search_regex }) |c|
            _ = gtk.CheckButton.signals.toggled.connect(c, *TermWindow, &onSearchOption, self, .{});
        _ = gobject.Object.signals.notify.connect(self.search_bar, *TermWindow, &onSearchMode, self, .{ .detail = "search-mode-enabled" });
    }

    fn buildMenus(self: *TermWindow, app: *gtk.Application) *gtk.PopoverMenuBar {
        const mb = common.menubar;
        const menus = [_]mb.Menu{
            .{ .label = "_File", .entries = &.{
                mb.item("New _Tab", "new-tab", null),
                mb.item("New _Window", "new-window", null),
                .separator,
                mb.item("_Save Output As…", "save-output", null),
                .separator,
                mb.item("Close _Pane", "close-pane", null),
                mb.item("_Close Tab", "close-tab", null),
                mb.item("_Quit", "quit", null),
            } },
            .{ .label = "_Edit", .entries = &.{
                mb.item("_Copy", "copy", null),
                mb.item("Copy as _HTML", "copy-html", null),
                mb.item("_Paste", "paste", null),
                mb.item("Select _All", "select-all", null),
                .separator,
                mb.item("_Find…", "find", null),
                .separator,
                mb.item("C_lear Scrollback", "clear-scrollback", null),
                mb.item("_Reset", "reset", null),
                .separator,
                mb.item("Pr_eferences…", "preferences", null),
            } },
            .{ .label = "_View", .entries = &.{
                mb.item("Zoom _In", "zoom-in", null),
                mb.item("Zoom _Out", "zoom-out", null),
                mb.item("_Normal Size", "zoom-reset", null),
                .separator,
                mb.item("_Full Screen", "fullscreen", null),
                .separator,
                mb.check("_Read-Only", "read-only", false),
                mb.check("Monitor for _Activity", "monitor-activity", false),
                mb.check("Monitor for _Silence", "monitor-silence", false),
            } },
            .{ .label = "_Panes", .entries = &.{
                mb.item("Split _Left/Right", "split-right", null),
                mb.item("Split _Top/Bottom", "split-down", null),
                .separator,
                mb.check("_Maximize Pane", "maximize-pane", false),
                mb.item("_Grow Pane", "grow-pane", null),
                mb.item("S_hrink Pane", "shrink-pane", null),
                mb.item("_Equal Sizes", "equal-panes", null),
                .separator,
                mb.item("Focus Pane on the Le_ft", "focus-left", null),
                mb.item("Focus Pane on the Ri_ght", "focus-right", null),
                mb.item("Focus Pane A_bove", "focus-up", null),
                mb.item("Focus Pane Bel_ow", "focus-down", null),
            } },
            .{ .label = "_Tabs", .entries = &.{
                mb.item("_Rename Tab…", "rename-tab", null),
                mb.item("Move Tab _Left", "move-tab-left", null),
                mb.item("Move Tab R_ight", "move-tab-right", null),
                mb.item("_Detach Tab", "detach-tab", null),
                .separator,
                mb.item("_Next Tab", "next-tab", null),
                mb.item("_Previous Tab", "prev-tab", null),
            } },
        };
        const bar = mb.build(app, self.window, &menus, TermWindow, onMenubarAction, self);
        // The shortcuts, as configured (shown in the menus too).
        for (actions) |a| {
            var key_buf: [64]u8 = undefined;
            const accel = self.accelFor(a.name, a.accel, &key_buf);
            var detailed: [80]u8 = undefined;
            const name = std.fmt.bufPrintSentinel(&detailed, "win.{s}", .{a.name}, 0) catch continue;
            if (accel) |k| {
                const accels = [_:null]?[*:0]const u8{k.ptr};
                app.setAccelsForAction(name, &accels);
            } else {
                const none = [_:null]?[*:0]const u8{};
                app.setAccelsForAction(name, &none);
            }
        }
        return bar;
    }

    /// The shortcut of `action`: term.toml's [shortcuts] entry, else the default.
    fn accelFor(self: *TermWindow, action: [:0]const u8, default: ?[:0]const u8, buf: []u8) ?[:0]const u8 {
        const custom = self.config.getString(self.allocator, "shortcuts", action, "\x00") catch return default;
        defer self.allocator.free(custom);
        if (custom.len == 1 and custom[0] == 0) return default;
        if (custom.len == 0) return null;
        // Only a valid shortcut is used.
        var key: c_uint = 0;
        var mods: gdk.ModifierType = .{};
        const z = std.fmt.bufPrintSentinel(buf, "{s}", .{custom}, 0) catch return default;
        if (gtk.acceleratorParse(z, &key, &mods) == 0 or key == 0) {
            log.warn("[shortcuts] {s} = \"{s}\" is not a shortcut; using the default", .{ action, custom });
            return default;
        }
        return z;
    }

    /// Size and startup mode from the profile of the first tab.
    fn applyProfileWindow(self: *TermWindow) void {
        const tab = self.currentTab() orelse return;
        const prof = tab.active.view.profile;
        const window = self.window.as(gtk.Window);
        if (prof.columns > 0 and prof.rows > 0) {
            const pad = 2 * @as(f64, @floatFromInt(prof.padding));
            // Plus the scroll bar on the right and the title bar and menu on top.
            const w = @as(f64, @floatFromInt(prof.columns)) * tab.active.view.cellWidth() + pad + 18;
            const h = @as(f64, @floatFromInt(prof.rows)) * tab.active.view.cellHeight() + pad + 112;
            window.setDefaultSize(@intFromFloat(w), @intFromFloat(h));
        }
        switch (prof.startup) {
            .windowed => {},
            .maximized => window.maximize(),
            .fullscreen => window.fullscreen(),
        }
    }

    /// A see-through profile needs a see-through window behind it.
    fn updateTransparency(self: *TermWindow) void {
        var any = false;
        for (self.tabs.items) |tab| {
            for (tab.panes.items) |p| if (p.view.profile.opacity < 1.0) {
                any = true;
            };
        }
        const widget = self.window.as(gtk.Widget);
        if (any) widget.addCssClass("dkde-transparent") else widget.removeCssClass("dkde-transparent");
    }

    /// term.toml changed (usually in Settings): open tabs follow the new
    /// opacity of their profile. Fonts and colour schemes apply to new tabs.
    fn onConfigChanged(self: *TermWindow) void {
        for (self.tabs.items) |tab| {
            for (tab.panes.items) |p| {
                var fresh = profile_mod.load(self.allocator, self.config, p.view.profile.name) catch continue;
                defer fresh.deinit(self.allocator);
                p.view.setOpacity(fresh.opacity);
            }
        }
        self.updateTransparency();
        self.rebuildProfileMenu();
    }

    pub fn newDefaultTab(self: *TermWindow) void {
        self.newTab(null, null, null) catch |err| log.err("cannot open a tab: {s}", .{@errorName(err)});
        self.applyProfileWindow();
        self.updateTransparency();
    }

    /// Makes this the drop-down terminal: no menu bar, across the top.
    pub fn makeDropdown(self: *TermWindow, percent: u32) void {
        self.dropdown = true;
        if (self.menu_bar) |bar| bar.as(gtk.Widget).setVisible(0);
        @import("dropdown.zig").setUp(self.window.as(gtk.Window), percent);
    }

    pub fn present(self: *TermWindow) void {
        self.window.as(gtk.Window).present();
        // Once the window is on screen the terminal can take the keyboard.
        _ = glib.idleAdd(focusIdle, self);
    }

    fn focusIdle(data: ?*anyopaque) callconv(.c) c_int {
        const self: *TermWindow = @ptrCast(@alignCast(data.?));
        if (std.mem.indexOfScalar(*TermWindow, all_windows.items, self) == null) return 0;
        if (self.currentTab()) |t| t.active.view.grabFocus();
        return 0;
    }

    fn onDestroy(_: *gtk.ApplicationWindow, self: *TermWindow) callconv(.c) void {
        self.closing = true;
        if (std.mem.indexOfScalar(*TermWindow, all_windows.items, self)) |i| _ = all_windows.swapRemove(i);
        // The views free themselves when GTK destroys their widgets.
        for (self.tabs.items) |tab| freeTab(self.allocator, tab);
        self.tabs.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn freeTab(gpa: std.mem.Allocator, tab: *Tab) void {
        for (tab.panes.items) |p| gpa.destroy(p);
        tab.panes.deinit(gpa);
        if (tab.custom_title) |t| gpa.free(t);
        gpa.destroy(tab);
    }

    // ---- closing ------------------------------------------------------------

    /// The programs still running in `panes` (names, joined), and how many.
    fn running(panes: []const *Pane, out: []u8) struct { count: usize, names: []const u8 } {
        var count: usize = 0;
        var len: usize = 0;
        for (panes) |p| {
            var buf: [64]u8 = undefined;
            const name = p.view.runningProgram(&buf) orelse continue;
            count += 1;
            if (len + name.len + 2 < out.len) {
                if (len > 0) {
                    @memcpy(out[len..][0..2], ", ");
                    len += 2;
                }
                @memcpy(out[len..][0..name.len], name);
                len += name.len;
            }
        }
        return .{ .count = count, .names = out[0..len] };
    }

    const Pending = union(enum) { pane: PaneRef, tab: *Tab, window };

    /// Asks before closing when a program would be stopped; runs `what` then.
    fn confirmClose(self: *TermWindow, panes: []const *Pane, what: Pending) void {
        var names: [300]u8 = undefined;
        const r = running(panes, &names);
        if (r.count == 0) return self.doClose(what);
        const ctx = self.allocator.create(CloseAsk) catch return;
        ctx.* = .{ .window = self, .what = what };
        var buf: [400]u8 = undefined;
        const detail = std.fmt.bufPrintSentinel(&buf, "{s} {s} still running. Closing will stop {s}.", .{
            r.names,
            if (r.count == 1) "is" else "are",
            if (r.count == 1) "it" else "them",
        }, 0) catch "";
        const title: [:0]const u8 = switch (what) {
            .pane => common.tr("Close this pane?"),
            .tab => common.tr("Close this tab?"),
            .window => common.tr("Close this window?"),
        };
        common.dialogs.choose(self.window.as(gtk.Window), title, detail, &.{ "Cancel", "Close" }, 0, CloseAsk, onCloseAnswer, ctx);
    }

    const CloseAsk = struct { window: *TermWindow, what: Pending };

    fn onCloseAnswer(ctx: *CloseAsk, choice: c_int) void {
        const self = ctx.window;
        const what = ctx.what;
        self.allocator.destroy(ctx);
        if (choice != 1) return;
        // The tab or pane may have closed meanwhile.
        switch (what) {
            .pane => |ref| if (std.mem.indexOfScalar(*Tab, self.tabs.items, ref.tab) == null or ref.tab.paneOf(ref.view) == null) return,
            .tab => |tab| if (std.mem.indexOfScalar(*Tab, self.tabs.items, tab) == null) return,
            .window => self.close_confirmed = true,
        }
        self.doClose(what);
    }

    fn doClose(self: *TermWindow, what: Pending) void {
        switch (what) {
            .pane => |ref| self.closePane(ref.tab, ref.view),
            .tab => |tab| self.closeTab(tab),
            .window => self.window.as(gtk.Window).close(),
        }
    }

    fn askClosePane(self: *TermWindow, tab: *Tab, pane: *Pane) void {
        self.confirmClose(&.{pane}, .{ .pane = .{ .tab = tab, .view = pane.view } });
    }

    fn askCloseTab(self: *TermWindow, tab: *Tab) void {
        self.confirmClose(tab.panes.items, .{ .tab = tab });
    }

    fn onCloseRequest(_: *gtk.Window, self: *TermWindow) callconv(.c) c_int {
        if (self.dropdown and !self.close_confirmed) {
            // The drop-down terminal hides; its hotkey brings it back.
            self.window.as(gtk.Widget).setVisible(0);
            return 1;
        }
        if (!self.close_confirmed) {
            var panes: std.ArrayList(*Pane) = .empty;
            defer panes.deinit(self.allocator);
            for (self.tabs.items) |t| panes.appendSlice(self.allocator, t.panes.items) catch {};
            var names: [300]u8 = undefined;
            if (running(panes.items, &names).count > 0) {
                self.confirmClose(panes.items, .window);
                return 1;
            }
        }
        self.finish();
        return 0;
    }

    /// The window is going: its size, and the tabs when it is the last one.
    fn finish(self: *TermWindow) void {
        const w = self.window.as(gtk.Widget);
        if (!self.dropdown and self.window.as(gtk.Window).isMaximized() == 0 and self.window.as(gtk.Window).isFullscreen() == 0 and w.getWidth() > 0) {
            self.config.setInt("terminal", "width", w.getWidth()) catch {};
            self.config.setInt("terminal", "height", w.getHeight()) catch {};
        }
        if (all_windows.items.len <= 1 and !self.dropdown) self.saveSession();
    }

    // ---- profiles and containers -----------------------------------------------

    fn defaultProfileName(self: *TermWindow) ![]u8 {
        return self.config.getString(self.allocator, "terminal", "default-profile", "Default");
    }

    fn rebuildProfileMenu(self: *TermWindow) void {
        while (self.profile_menu.as(gtk.Widget).getFirstChild()) |child| self.profile_menu.remove(child);
        const names = self.config.groupsWithPrefix(self.allocator, "profile:") catch return;
        defer common.config.freeStringList(self.allocator, names);

        if (names.len == 0) self.addMenuItem(self.profile_menu, "Default", .{ .profile = "Default" });
        for (names) |name| self.addMenuItem(self.profile_menu, name, .{ .profile = name });
    }

    const MenuTarget = union(enum) {
        profile: []const u8,
        /// A container entered with `tool enter name`.
        container: struct { tool: []const u8, name: []const u8 },
    };

    const MenuItem = struct { window: *TermWindow, profile: ?[]u8 = null, tool: ?[]u8 = null, name: ?[]u8 = null };

    fn addMenuItem(self: *TermWindow, box: *gtk.Box, label_text: []const u8, target: MenuTarget) void {
        var buf: [256]u8 = undefined;
        const label = std.fmt.bufPrintSentinel(&buf, "{s}", .{label_text}, 0) catch return;
        const button = gtk.Button.newWithLabel(label);
        button.setHasFrame(0);
        if (button.getChild()) |child| {
            const l: *gtk.Label = @ptrCast(@alignCast(child));
            l.setXalign(0);
        }
        const item = self.allocator.create(MenuItem) catch return;
        item.* = .{ .window = self };
        switch (target) {
            .profile => |p| item.profile = self.allocator.dupe(u8, p) catch null,
            .container => |c| {
                item.tool = self.allocator.dupe(u8, c.tool) catch null;
                item.name = self.allocator.dupe(u8, c.name) catch null;
            },
        }
        _ = gtk.Button.signals.clicked.connect(button, *MenuItem, &onMenuItem, item, .{});
        _ = gtk.Widget.signals.destroy.connect(button, *MenuItem, &onMenuItemDestroy, item, .{});
        box.append(button.as(gtk.Widget));
    }

    fn onMenuItemDestroy(_: *gtk.Button, item: *MenuItem) callconv(.c) void {
        const gpa = item.window.allocator;
        if (item.profile) |p| gpa.free(p);
        if (item.tool) |t| gpa.free(t);
        if (item.name) |n| gpa.free(n);
        gpa.destroy(item);
    }

    fn onMenuItem(_: *gtk.Button, item: *MenuItem) callconv(.c) void {
        const self = item.window;
        self.profile_popover.popdown();
        if (item.profile) |p| {
            self.newTab(p, null, self.currentDirectory()) catch |err| log.err("cannot open a tab: {s}", .{@errorName(err)});
            return;
        }
        const tool = item.tool orelse return;
        const name = item.name orelse return;
        const argv = [_][]const u8{ tool, "enter", name };
        self.newTab(null, &argv, null) catch |err| log.err("cannot open a tab: {s}", .{@errorName(err)});
    }

    /// Lists the toolbox and distrobox containers under the profiles, as
    /// Ptyxis does (read each time the menu opens; they come and go).
    fn onProfileMenuShown(_: *gtk.Popover, self: *TermWindow) callconv(.c) void {
        while (self.container_menu.as(gtk.Widget).getFirstChild()) |child| self.container_menu.remove(child);
        inline for (.{ .{ "distrobox", &[_][]const u8{ "distrobox", "list", "--no-color" } }, .{ "toolbox", &[_][]const u8{ "toolbox", "list", "--containers" } } }) |tool| {
            if (common.proc.hasProgram(tool[0])) self.listContainers(tool[0], tool[1]);
        }
    }

    const ContainerJob = struct { window: *TermWindow, tool: []const u8 };

    fn listContainers(self: *TermWindow, tool: []const u8, argv: []const []const u8) void {
        const job = std.heap.c_allocator.create(ContainerJob) catch return;
        job.* = .{ .window = self, .tool = tool };
        var z: [8]?[*:0]const u8 = @splat(null);
        var bufs: [8][64]u8 = undefined;
        for (argv, 0..) |a, i| z[i] = (std.fmt.bufPrintSentinel(&bufs[i], "{s}", .{a}, 0) catch return).ptr;
        var err: ?*glib.Error = null;
        const sub = gio.Subprocess.newv(@ptrCast(&z), .{ .stdout_pipe = true, .stderr_silence = true }, &err) orelse {
            if (err) |e| e.free();
            std.heap.c_allocator.destroy(job);
            return;
        };
        sub.communicateUtf8Async(null, null, onContainers, job);
    }

    fn onContainers(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const job: *ContainerJob = @ptrCast(@alignCast(data.?));
        defer std.heap.c_allocator.destroy(job);
        const sub: *gio.Subprocess = @ptrCast(@alignCast(source.?));
        defer sub.as(gobject.Object).unref();
        var out: ?[*:0]u8 = null;
        if (sub.communicateUtf8Finish(result, @ptrCast(&out), null, null) == 0) return;
        defer if (out) |o| glib.free(o);
        const text = if (out) |o| std.mem.span(o) else return;
        // The window may have closed while the tool ran.
        if (std.mem.indexOfScalar(*TermWindow, all_windows.items, job.window) == null) return;
        const self = job.window;
        var names: [16][]const u8 = undefined;
        const n = session.containerNames(text, &names);
        for (names[0..n]) |name| {
            var buf: [160]u8 = undefined;
            const label = std.fmt.bufPrint(&buf, "{s} ({s})", .{ name, job.tool }) catch continue;
            self.addMenuItem(self.container_menu, label, .{ .container = .{ .tool = job.tool, .name = name } });
        }
    }

    // ---- tabs ---------------------------------------------------------------

    fn onNewTab(_: *gtk.Button, self: *TermWindow) callconv(.c) void {
        self.newTab(null, null, self.currentDirectory()) catch |err|
            log.err("cannot open a tab: {s}", .{@errorName(err)});
    }

    /// The shell's directory in the visible tab, so new tabs start there
    /// (OSC 7, SPEC.md 5.3). Owned by the caller.
    fn currentDirectory(self: *TermWindow) ?[]u8 {
        const tab = self.currentTab() orelse return null;
        return tab.active.view.workingDirectory(self.allocator);
    }

    fn currentTab(self: *TermWindow) ?*Tab {
        const visible = self.stack.getVisibleChild() orelse return null;
        for (self.tabs.items) |tab| if (tab.root.as(gtk.Widget) == visible) return tab;
        return null;
    }

    /// A pane for `tab` with the profile named `name`, not yet placed in the window.
    fn createPane(self: *TermWindow, tab: *Tab, name: []const u8, command: ?[]const []const u8, directory: ?[]const u8) !*Pane {
        const prof = try profile_mod.load(self.allocator, self.config, name);
        const scrollback: usize = @intCast(@max(0, self.config.getInt("terminal", "scrollback-lines", default_scrollback_lines)));
        const view = try TerminalView.create(self.allocator, prof, command, directory, scrollback, .{
            .data = tab,
            .title_changed = onTitleChanged,
            .exited = onExited,
            .focused = onPaneFocused,
            .bell = onBell,
            .menu = onViewMenu,
        });
        errdefer view.shutdown();
        if (self.zoom != 1.0) view.setZoom(self.zoom);
        const pane = try self.allocator.create(Pane);
        pane.* = .{
            .view = view,
            .frame = gtk.Box.new(.vertical, 0),
            .header = gtk.Box.new(.horizontal, 4),
            .title = gtk.Label.new(""),
            .max_button = gtk.Button.newFromIconName("view-fullscreen-symbolic"),
        };
        // Konsole's split header: title, maximise, close; drag it onto
        // another pane to swap the two.
        pane.header.as(gtk.Widget).addCssClass("dkde-pane-header");
        pane.title.setEllipsize(.end);
        pane.title.setXalign(0);
        pane.title.as(gtk.Widget).setHexpand(1);
        pane.max_button.setHasFrame(0);
        pane.max_button.as(gtk.Widget).setTooltipText(common.tr("Maximize this pane (Ctrl+Shift+E)"));
        const close = gtk.Button.newFromIconName("window-close-symbolic");
        close.setHasFrame(0);
        close.as(gtk.Widget).setTooltipText(common.tr("Close this pane"));
        pane.header.append(pane.title.as(gtk.Widget));
        pane.header.append(pane.max_button.as(gtk.Widget));
        pane.header.append(close.as(gtk.Widget));
        // The keyboard stays with the terminals, never on these buttons.
        inline for (.{ pane.max_button.as(gtk.Widget), close.as(gtk.Widget) }) |b| {
            b.setFocusable(0);
            b.setFocusOnClick(0);
        }
        pane.header.as(gtk.Widget).setVisible(0);
        _ = gtk.Button.signals.clicked.connect(pane.max_button, *Pane, &onPaneMaximize, pane, .{});
        _ = gtk.Button.signals.clicked.connect(close, *Pane, &onPaneClose, pane, .{});
        const drag = gtk.DragSource.new();
        drag.setActions(.{ .move = true });
        _ = gtk.DragSource.signals.prepare.connect(drag, *Pane, &onPaneDragPrepare, pane, .{});
        pane.header.as(gtk.Widget).addController(drag.as(gtk.EventController));
        const click = gtk.GestureClick.new();
        _ = gtk.GestureClick.signals.pressed.connect(click, *Pane, &onHeaderClick, pane, .{});
        pane.header.as(gtk.Widget).addController(click.as(gtk.EventController));
        const drop = gtk.DropTarget.new(gobject.ext.types.string, .{ .move = true });
        _ = gtk.DropTarget.signals.drop.connect(drop, *Pane, &onPaneDrop, pane, .{});
        pane.frame.as(gtk.Widget).addController(drop.as(gtk.EventController));

        view.widget().setHexpand(1);
        view.widget().setVexpand(1);
        pane.frame.append(pane.header.as(gtk.Widget));
        pane.frame.append(view.widget());
        pane.frame.as(gtk.Widget).setHexpand(1);
        pane.frame.as(gtk.Widget).setVexpand(1);
        return pane;
    }

    fn newTab(self: *TermWindow, profile_name: ?[]const u8, command: ?[]const []const u8, directory: ?[]u8) !void {
        defer if (directory) |d| self.allocator.free(d);
        const name = if (profile_name) |n| try self.allocator.dupe(u8, n) else try self.defaultProfileName();
        defer self.allocator.free(name);
        const tab = try self.makeTab();
        errdefer freeTab(self.allocator, tab);
        const pane = try self.createPane(tab, name, command, directory);
        try tab.panes.append(self.allocator, pane);
        tab.active = pane;
        tab.root.append(pane.frame.as(gtk.Widget));
        try self.addTab(tab, null);
    }

    /// An empty tab of this window (no pane yet), with its button.
    fn makeTab(self: *TermWindow) !*Tab {
        const tab = try self.allocator.create(Tab);
        tab.* = .{ .window = self, .root = gtk.Box.new(.vertical, 0), .active = undefined, .button = gtk.ToggleButton.new(), .label = gtk.Label.new("") };
        tab.root.as(gtk.Widget).setHexpand(1);
        tab.root.as(gtk.Widget).setVexpand(1);
        tab.label.setEllipsize(.end);
        tab.label.setMaxWidthChars(18);
        const close = gtk.Button.newFromIconName("window-close-symbolic");
        close.setHasFrame(0);
        close.as(gtk.Widget).setTooltipText(common.tr("Close tab"));
        const content = gtk.Box.new(.horizontal, 6);
        content.append(tab.label.as(gtk.Widget));
        content.append(close.as(gtk.Widget));
        tab.button.as(gtk.Button).setChild(content.as(gtk.Widget));
        tab.button.as(gtk.Widget).addCssClass("dkde-tab");
        _ = gtk.ToggleButton.signals.toggled.connect(tab.button, *Tab, &onTabToggled, tab, .{});
        _ = gtk.Button.signals.clicked.connect(close, *Tab, &onCloseClicked, tab, .{});
        // Drag a tab to reorder it, onto another window, or out into its own.
        const drag = gtk.DragSource.new();
        drag.setActions(.{ .move = true });
        _ = gtk.DragSource.signals.prepare.connect(drag, *Tab, &onTabDragPrepare, tab, .{});
        _ = gtk.DragSource.signals.drag_cancel.connect(drag, *Tab, &onTabDragCancel, tab, .{});
        tab.button.as(gtk.Widget).addController(drag.as(gtk.EventController));
        const drop = gtk.DropTarget.new(gobject.ext.types.string, .{ .move = true });
        _ = gtk.DropTarget.signals.drop.connect(drop, *Tab, &onTabDrop, tab, .{});
        tab.button.as(gtk.Widget).addController(drop.as(gtk.EventController));
        // Double-click renames, as in Konsole.
        const click = gtk.GestureClick.new();
        _ = gtk.GestureClick.signals.pressed.connect(click, *Tab, &onTabClick, tab, .{});
        tab.button.as(gtk.Widget).addController(click.as(gtk.EventController));
        return tab;
    }

    /// Puts `tab` (with its panes) in this window, at `index` or at the end.
    fn addTab(self: *TermWindow, tab: *Tab, index: ?usize) !void {
        tab.window = self;
        const view = tab.panes.items[0].view;
        if (view.profile.tab_color.len > 0) tabColor(self.allocator, tab.button.as(gtk.Widget), view.profile.tab_color);
        tab.button.setGroup(null);
        if (self.group_leader) |leader| tab.button.setGroup(leader) else self.group_leader = tab.button;
        const at = @min(index orelse self.tabs.items.len, self.tabs.items.len);
        try self.tabs.insert(self.allocator, at, tab);
        if (at == 0) self.strip.prepend(tab.button.as(gtk.Widget)) else self.strip.insertChildAfter(tab.button.as(gtk.Widget), self.tabs.items[at - 1].button.as(gtk.Widget));
        _ = self.stack.addChild(tab.root.as(gtk.Widget));
        self.refreshHeaders(tab);
        tab.refreshLabel();
        self.select(tab);
        self.updateTransparency();
    }

    /// Takes `tab` out of this window without stopping its panes (it is
    /// moving to another window). The caller holds references to its widgets.
    fn removeTab(self: *TermWindow, tab: *Tab) void {
        const index = std.mem.indexOfScalar(*Tab, self.tabs.items, tab) orelse return;
        _ = self.tabs.orderedRemove(index);
        if (self.group_leader == tab.button) self.group_leader = if (self.tabs.items.len > 0) self.tabs.items[0].button else null;
        tab.button.setGroup(null);
        // The other buttons stay in the group through the new leader.
        if (self.group_leader) |leader| for (self.tabs.items) |t| if (t.button != leader) t.button.setGroup(leader);
        self.strip.remove(tab.button.as(gtk.Widget));
        self.stack.remove(tab.root.as(gtk.Widget));
        if (self.tabs.items.len == 0) {
            self.close_confirmed = true;
            self.window.as(gtk.Window).close();
        } else self.select(self.tabs.items[@min(index, self.tabs.items.len - 1)]);
    }

    /// Moves `tab` to `to` (another window, or this one at another place).
    fn moveTab(self: *TermWindow, tab: *Tab, to: *TermWindow, index: ?usize) void {
        if (to == self) {
            const from = std.mem.indexOfScalar(*Tab, self.tabs.items, tab) orelse return;
            var at = @min(index orelse self.tabs.items.len, self.tabs.items.len);
            if (at == from or at == from + 1) return;
            _ = self.tabs.orderedRemove(from);
            if (at > from) at -= 1;
            self.tabs.insert(self.allocator, at, tab) catch return;
            if (at == 0) self.strip.reorderChildAfter(tab.button.as(gtk.Widget), null) else self.strip.reorderChildAfter(tab.button.as(gtk.Widget), self.tabs.items[at - 1].button.as(gtk.Widget));
            return;
        }
        _ = tab.button.as(gobject.Object).ref();
        _ = tab.root.as(gobject.Object).ref();
        defer tab.button.as(gobject.Object).unref();
        defer tab.root.as(gobject.Object).unref();
        self.removeTab(tab);
        to.addTab(tab, index) catch return;
        // The panes keep their zoom; the new window may differ.
        to.window.as(gtk.Window).present();
    }

    /// Takes the visible tab into a new window of its own.
    fn detachTab(self: *TermWindow, tab: *Tab) void {
        if (self.tabs.items.len < 2) return;
        const win = createEmpty(self.allocator, self.app, self.config) catch return;
        self.moveTab(tab, win, null);
        win.present();
    }

    fn onTabDragPrepare(_: *gtk.DragSource, _: f64, _: f64, tab: *Tab) callconv(.c) ?*gdk.ContentProvider {
        dragged_tab = tab;
        var v = std.mem.zeroes(gobject.Value);
        _ = v.init(gobject.ext.types.string);
        v.setString("dkde-term-tab");
        defer v.unset();
        return gdk.ContentProvider.newForValue(&v);
    }

    /// Dropped where nothing takes it (outside every window): its own window.
    fn onTabDragCancel(_: *gtk.DragSource, _: *gdk.Drag, reason: gdk.DragCancelReason, tab: *Tab) callconv(.c) c_int {
        defer dragged_tab = null;
        if (reason != .no_target) return 0;
        tab.window.detachTab(tab);
        return 1;
    }

    fn onTabDrop(_: *gtk.DropTarget, value: *gobject.Value, _: f64, _: f64, target: *Tab) callconv(.c) c_int {
        const text = value.getString() orelse return 0;
        if (!std.mem.eql(u8, std.mem.span(text), "dkde-term-tab")) return 0;
        const tab = dragged_tab orelse return 0;
        dragged_tab = null;
        if (tab == target) return 1;
        const index = std.mem.indexOfScalar(*Tab, target.window.tabs.items, target) orelse return 0;
        tab.window.moveTab(tab, target.window, index);
        return 1;
    }

    fn onStripDrop(_: *gtk.DropTarget, value: *gobject.Value, _: f64, _: f64, self: *TermWindow) callconv(.c) c_int {
        const text = value.getString() orelse return 0;
        if (!std.mem.eql(u8, std.mem.span(text), "dkde-term-tab")) return 0;
        const tab = dragged_tab orelse return 0;
        dragged_tab = null;
        tab.window.moveTab(tab, self, null);
        return 1;
    }

    fn onTabClick(gesture: *gtk.GestureClick, n_press: c_int, _: f64, _: f64, tab: *Tab) callconv(.c) void {
        if (n_press == 2) {
            _ = gesture.as(gtk.Gesture).setState(.claimed);
            tab.window.renameTab(tab);
        }
    }

    /// Asks for a name for `tab` (an empty one follows the program again).
    fn renameTab(self: *TermWindow, tab: *Tab) void {
        const pop = gtk.Popover.new();
        pop.as(gtk.Widget).setParent(tab.button.as(gtk.Widget));
        const box = gtk.Box.new(.vertical, 6);
        const label = gtk.Label.new(common.tr("Tab name (empty: the program's title)"));
        label.setXalign(0);
        const entry = gtk.Entry.new();
        var name_buf: [256]u8 = undefined;
        entry.as(gtk.Editable).setText(if (tab.custom_title) |t| (std.fmt.bufPrintSentinel(&name_buf, "{s}", .{t[0..@min(t.len, 250)]}, 0) catch "") else "");
        box.append(label.as(gtk.Widget));
        box.append(entry.as(gtk.Widget));
        pop.setChild(box.as(gtk.Widget));
        const ctx = self.allocator.create(RenameCtx) catch return;
        ctx.* = .{ .tab = tab, .popover = pop, .entry = entry };
        _ = gtk.Entry.signals.activate.connect(entry, *RenameCtx, &onRenameActivate, ctx, .{});
        _ = gtk.Popover.signals.closed.connect(pop, *RenameCtx, &onRenameClosed, ctx, .{});
        pop.popup();
        _ = entry.as(gtk.Widget).grabFocus();
    }

    const RenameCtx = struct { tab: *Tab, popover: *gtk.Popover, entry: *gtk.Entry, done: bool = false };

    fn onRenameActivate(_: *gtk.Entry, ctx: *RenameCtx) callconv(.c) void {
        const tab = ctx.tab;
        const gpa = tab.window.allocator;
        const text = std.mem.trim(u8, std.mem.span(ctx.entry.as(gtk.Editable).getText()), " ");
        if (tab.custom_title) |t| gpa.free(t);
        tab.custom_title = if (text.len > 0) gpa.dupe(u8, text) catch null else null;
        tab.refreshLabel();
        tab.window.updateWindowTitle();
        ctx.popover.popdown();
    }

    fn onRenameClosed(pop: *gtk.Popover, ctx: *RenameCtx) callconv(.c) void {
        const tab = ctx.tab;
        tab.window.allocator.destroy(ctx);
        pop.as(gtk.Widget).unparent();
        tab.active.view.grabFocus();
    }

    // ---- panes ----------------------------------------------------------------

    /// Puts `new` where `old` is in `parent` (the tab's root box or a paned).
    fn replaceChild(tab: *Tab, parent: *gtk.Widget, old: *gtk.Widget, new: *gtk.Widget) void {
        if (parent == tab.root.as(gtk.Widget)) {
            tab.root.remove(old);
            tab.root.append(new);
            return;
        }
        const paned: *gtk.Paned = @ptrCast(@alignCast(parent));
        if (paned.getStartChild() == old) paned.setStartChild(new) else paned.setEndChild(new);
    }

    /// Splits the active pane of the visible tab: the new pane runs the same
    /// profile, in the same directory, and goes right of or below it.
    fn splitPane(self: *TermWindow, orientation: gtk.Orientation) void {
        const tab = self.currentTab() orelse return;
        self.restoreMaximized(tab);
        const old = tab.active;
        const dir = old.view.workingDirectory(self.allocator);
        defer if (dir) |d| self.allocator.free(d);
        const pane = self.createPane(tab, old.view.profile.name, null, dir) catch |err| {
            log.err("cannot split the pane: {s}", .{@errorName(err)});
            return;
        };
        tab.panes.append(self.allocator, pane) catch {
            pane.view.shutdown();
            return;
        };
        self.placeSplit(tab, old.frame.as(gtk.Widget), pane.frame.as(gtk.Widget), orientation, null);
        self.refreshHeaders(tab);
        self.updateTransparency();
        pane.view.grabFocus();
    }

    /// Replaces `old` with a split holding `old` first and `new` second.
    fn placeSplit(self: *TermWindow, tab: *Tab, old: *gtk.Widget, new: *gtk.Widget, orientation: gtk.Orientation, permille: ?u16) void {
        _ = self;
        const parent = old.getParent() orelse return;
        const paned = gtk.Paned.new(orientation);
        paned.setResizeStartChild(1);
        paned.setResizeEndChild(1);
        paned.setShrinkStartChild(0);
        paned.setShrinkEndChild(0);
        // A visible splitter, apart from the panes' title bars (as in Konsole).
        paned.setWideHandle(1);
        paned.as(gtk.Widget).setHexpand(1);
        paned.as(gtk.Widget).setVexpand(1);
        // Removing the pane from its parent would drop the last reference to it.
        _ = old.as(gobject.Object).ref();
        replaceChild(tab, parent, old, paned.as(gtk.Widget));
        paned.setStartChild(old);
        paned.setEndChild(new);
        old.as(gobject.Object).unref();
        // Half and half (or as restored), once the size is known.
        const size = if (orientation == .horizontal) parent.getWidth() else parent.getHeight();
        if (size > 0) paned.setPosition(@divTrunc(size * @as(c_int, permille orelse 500), 1000));
    }

    /// Closes the pane of `view`; its sibling takes the space. The last pane closes the tab.
    fn closePane(self: *TermWindow, tab: *Tab, view: *TerminalView) void {
        if (self.closing) return;
        const pane = tab.paneOf(view) orelse return;
        if (tab.panes.items.len == 1) return self.closeTab(tab);
        self.restoreMaximized(tab);

        const frame = pane.frame.as(gtk.Widget);
        const parent = frame.getParent() orelse return;
        const paned: *gtk.Paned = @ptrCast(@alignCast(parent));
        const sibling = (if (paned.getStartChild() == frame) paned.getEndChild() else paned.getStartChild()) orelse return;
        const grand = parent.getParent() orelse return;

        const index = std.mem.indexOfScalar(*Pane, tab.panes.items, pane).?;
        _ = tab.panes.orderedRemove(index);
        view.shutdown();
        _ = sibling.as(gobject.Object).ref();
        paned.setStartChild(null);
        paned.setEndChild(null);
        replaceChild(tab, grand, parent, sibling);
        sibling.as(gobject.Object).unref();
        self.allocator.destroy(pane);

        // The pane that takes over, if the closed one was the active one.
        if (tab.active == pane) {
            for (tab.panes.items) |p| {
                if (p.frame.as(gtk.Widget) == sibling or p.frame.as(gtk.Widget).isAncestor(sibling) != 0) {
                    tab.active = p;
                    break;
                }
            } else tab.active = tab.panes.items[0];
            tab.active.view.grabFocus();
            tab.refreshLabel();
            self.updateWindowTitle();
        }
        self.refreshHeaders(tab);
        self.updateTransparency();
    }

    /// Pane title bars show while the tab is split (a setting can hide them).
    fn refreshHeaders(self: *TermWindow, tab: *Tab) void {
        const show = tab.panes.items.len > 1 and self.config.getBool("terminal", "pane-headers", true);
        for (tab.panes.items) |p| {
            p.header.as(gtk.Widget).setVisible(@intFromBool(show));
            refreshPaneTitle(p);
            if (show) {
                if (p == tab.active) p.header.as(gtk.Widget).addCssClass("active") else p.header.as(gtk.Widget).removeCssClass("active");
            }
        }
    }

    fn refreshPaneTitle(p: *Pane) void {
        var buf: [256]u8 = undefined;
        const t = p.view.title() orelse p.view.profile.name;
        p.title.setText(std.fmt.bufPrintSentinel(&buf, "{s}", .{t[0..@min(t.len, 250)]}, 0) catch "");
    }

    /// Fills the tab with the active pane, or brings the others back.
    fn toggleMaximize(self: *TermWindow, tab: *Tab) void {
        if (tab.maximized != null) return self.restoreMaximized(tab);
        if (tab.panes.items.len < 2) return;
        const pane = tab.active;
        var w: *gtk.Widget = pane.frame.as(gtk.Widget);
        while (w.getParent()) |parent| : (w = parent) {
            if (parent == tab.root.as(gtk.Widget)) break;
            const paned: *gtk.Paned = @ptrCast(@alignCast(parent));
            const other = if (paned.getStartChild() == w) paned.getEndChild() else paned.getStartChild();
            if (other) |o| o.setVisible(0);
        }
        tab.maximized = pane;
        pane.max_button.setIconName("view-restore-symbolic");
        common.menubar.setChecked(self.window, "maximize-pane", true);
        pane.view.grabFocus();
    }

    fn restoreMaximized(self: *TermWindow, tab: *Tab) void {
        const pane = tab.maximized orelse return;
        showAll(tab.root.as(gtk.Widget));
        tab.maximized = null;
        pane.max_button.setIconName("view-fullscreen-symbolic");
        common.menubar.setChecked(self.window, "maximize-pane", false);
        self.refreshHeaders(tab);
    }

    fn showAll(w: *gtk.Widget) void {
        if (gobject.typeCheckInstanceIsA(@ptrCast(w), gtk.Paned.getGObjectType()) != 0) {
            const paned: *gtk.Paned = @ptrCast(@alignCast(w));
            if (paned.getStartChild()) |c| {
                c.setVisible(1);
                showAll(c);
            }
            if (paned.getEndChild()) |c| {
                c.setVisible(1);
                showAll(c);
            }
        } else if (gobject.typeCheckInstanceIsA(@ptrCast(w), gtk.Box.getGObjectType()) != 0) {
            var child = w.getFirstChild();
            while (child) |c| : (child = c.getNextSibling()) {
                if (gobject.typeCheckInstanceIsA(@ptrCast(c), gtk.Paned.getGObjectType()) != 0) showAll(c);
            }
        }
    }

    /// Moves the split next to the active pane, making the pane bigger or smaller.
    fn resizePane(self: *TermWindow, grow: bool) void {
        const tab = self.currentTab() orelse return;
        const frame = tab.active.frame.as(gtk.Widget);
        const parent = frame.getParent() orelse return;
        if (parent == tab.root.as(gtk.Widget)) return;
        const paned: *gtk.Paned = @ptrCast(@alignCast(parent));
        const first = paned.getStartChild() == frame;
        const amount: c_int = 40;
        const delta: c_int = if (grow == first) amount else -amount;
        paned.setPosition(@max(20, paned.getPosition() + delta));
    }

    /// Every split of the tab in the middle.
    fn equalizePanes(self: *TermWindow) void {
        const tab = self.currentTab() orelse return;
        equalize(tab.root.as(gtk.Widget));
    }

    fn equalize(w: *gtk.Widget) void {
        var child = w.getFirstChild();
        while (child) |c| : (child = c.getNextSibling()) {
            if (gobject.typeCheckInstanceIsA(@ptrCast(c), gtk.Paned.getGObjectType()) != 0) {
                const paned: *gtk.Paned = @ptrCast(@alignCast(c));
                const size = if (paned.as(gtk.Orientable).getOrientation() == .horizontal) c.getWidth() else c.getHeight();
                paned.setPosition(@divTrunc(size, 2));
            }
            equalize(c);
        }
    }

    const Direction = enum { left, right, up, down };

    /// Moves the focus to the nearest pane on that side, as Konsole's
    /// "focus left/right/above/below" do.
    fn focusDirection(self: *TermWindow, dir: Direction) void {
        const tab = self.currentTab() orelse return;
        if (tab.panes.items.len < 2) return;
        const root = tab.root.as(gtk.Widget);
        var from: graphene.Rect = undefined;
        if (tab.active.frame.as(gtk.Widget).computeBounds(root, &from) == 0) return;
        const fx = from.f_origin.f_x + from.f_size.f_width / 2;
        const fy = from.f_origin.f_y + from.f_size.f_height / 2;
        var best: ?*Pane = null;
        var best_d: f32 = std.math.floatMax(f32);
        for (tab.panes.items) |p| {
            if (p == tab.active or p.frame.as(gtk.Widget).isVisible() == 0) continue;
            var r: graphene.Rect = undefined;
            if (p.frame.as(gtk.Widget).computeBounds(root, &r) == 0) continue;
            const cx = r.f_origin.f_x + r.f_size.f_width / 2;
            const cy = r.f_origin.f_y + r.f_size.f_height / 2;
            const ok = switch (dir) {
                .left => r.f_origin.f_x + r.f_size.f_width <= from.f_origin.f_x + 1,
                .right => r.f_origin.f_x >= from.f_origin.f_x + from.f_size.f_width - 1,
                .up => r.f_origin.f_y + r.f_size.f_height <= from.f_origin.f_y + 1,
                .down => r.f_origin.f_y >= from.f_origin.f_y + from.f_size.f_height - 1,
            };
            if (!ok) continue;
            const d = (cx - fx) * (cx - fx) + (cy - fy) * (cy - fy);
            if (d < best_d) {
                best_d = d;
                best = p;
            }
        }
        if (best) |p| p.view.grabFocus();
    }

    /// Puts the two panes in each other's place.
    fn swapPanes(tab: *Tab, a: *Pane, b: *Pane) void {
        if (a == b) return;
        const wa = a.frame.as(gtk.Widget);
        const wb = b.frame.as(gtk.Widget);
        const pa = wa.getParent() orelse return;
        const pb = wb.getParent() orelse return;
        _ = wa.as(gobject.Object).ref();
        _ = wb.as(gobject.Object).ref();
        defer wa.as(gobject.Object).unref();
        defer wb.as(gobject.Object).unref();
        const hold_a = gtk.Box.new(.vertical, 0);
        const hold_b = gtk.Box.new(.vertical, 0);
        replaceChild(tab, pa, wa, hold_a.as(gtk.Widget));
        replaceChild(tab, pb, wb, hold_b.as(gtk.Widget));
        replaceChild(tab, pa, hold_a.as(gtk.Widget), wb);
        replaceChild(tab, pb, hold_b.as(gtk.Widget), wa);
    }

    fn onPaneDragPrepare(_: *gtk.DragSource, _: f64, _: f64, pane: *Pane) callconv(.c) ?*gdk.ContentProvider {
        dragged_pane = pane;
        var v = std.mem.zeroes(gobject.Value);
        _ = v.init(gobject.ext.types.string);
        v.setString("dkde-term-pane");
        defer v.unset();
        return gdk.ContentProvider.newForValue(&v);
    }

    fn onPaneDrop(_: *gtk.DropTarget, value: *gobject.Value, _: f64, _: f64, target: *Pane) callconv(.c) c_int {
        const text = value.getString() orelse return 0;
        if (!std.mem.eql(u8, std.mem.span(text), "dkde-term-pane")) return 0;
        const pane = dragged_pane orelse return 0;
        dragged_pane = null;
        // Within one tab only.
        const tab = paneTab(target) orelse return 0;
        if (tab.paneOf(pane.view) == null) return 0;
        swapPanes(tab, pane, target);
        return 1;
    }

    fn paneTab(pane: *Pane) ?*Tab {
        for (all_windows.items) |w| for (w.tabs.items) |t| if (t.paneOf(pane.view) != null) return t;
        return null;
    }

    fn onHeaderClick(_: *gtk.GestureClick, _: c_int, _: f64, _: f64, pane: *Pane) callconv(.c) void {
        pane.view.grabFocus();
    }

    fn onPaneMaximize(_: *gtk.Button, pane: *Pane) callconv(.c) void {
        const tab = paneTab(pane) orelse return;
        tab.active = pane;
        tab.window.toggleMaximize(tab);
    }

    fn onPaneClose(_: *gtk.Button, pane: *Pane) callconv(.c) void {
        const tab = paneTab(pane) orelse return;
        tab.window.askClosePane(tab, pane);
    }

    fn onPaneFocused(data: *anyopaque, view: *TerminalView) void {
        const tab: *Tab = @ptrCast(@alignCast(data));
        const pane = tab.paneOf(view) orelse return;
        tab.active = pane;
        tab.refreshLabel();
        tab.window.refreshHeaders(tab);
        tab.window.syncPaneChecks();
        tab.window.updateWindowTitle();
    }

    /// The View menu's check marks follow the active pane.
    fn syncPaneChecks(self: *TermWindow) void {
        const tab = self.currentTab() orelse return;
        const v = tab.active.view;
        common.menubar.setChecked(self.window, "read-only", v.read_only);
        common.menubar.setChecked(self.window, "monitor-activity", v.monitor_activity);
        common.menubar.setChecked(self.window, "monitor-silence", v.monitor_silence);
        common.menubar.setChecked(self.window, "maximize-pane", tab.maximized != null);
    }

    fn onBell(data: *anyopaque, _: *TerminalView) void {
        const tab: *Tab = @ptrCast(@alignCast(data));
        if (tab.window.currentTab() == tab and tab.window.window.as(gtk.Window).isActive() != 0) return;
        if (!tab.attention) {
            tab.attention = true;
            tab.button.as(gtk.Widget).addCssClass("dkde-tab-attention");
            tab.refreshLabel();
        }
    }

    fn onViewMenu(data: *anyopaque, view: *TerminalView, action: []const u8) void {
        const tab: *Tab = @ptrCast(@alignCast(data));
        if (tab.paneOf(view)) |p| tab.active = p;
        tab.window.perform(action);
    }

    fn select(self: *TermWindow, tab: *Tab) void {
        self.stack.setVisibleChild(tab.root.as(gtk.Widget));
        tab.button.setActive(1);
        if (tab.attention) {
            tab.attention = false;
            tab.button.as(gtk.Widget).removeCssClass("dkde-tab-attention");
            tab.refreshLabel();
        }
        tab.active.view.grabFocus();
        self.syncPaneChecks();
        self.updateWindowTitle();
    }

    fn onTabToggled(button: *gtk.ToggleButton, tab: *Tab) callconv(.c) void {
        if (button.getActive() != 0) tab.window.select(tab);
    }

    fn onCloseClicked(_: *gtk.Button, tab: *Tab) callconv(.c) void {
        tab.window.askCloseTab(tab);
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
        if (tab.paneOf(view)) |p| refreshPaneTitle(p);
        if (view == tab.active.view) tab.refreshLabel();
        tab.window.updateWindowTitle();
    }

    fn onExited(data: *anyopaque, view: *TerminalView) void {
        const tab: *Tab = @ptrCast(@alignCast(data));
        // "close-on-exit": a pane can stay open to show what the program printed.
        if (!profile_mod.closesTab(view.profile.close_on_exit, view.exit_status)) {
            var buf: [96]u8 = undefined;
            const code = profile_mod.exitCode(view.exit_status);
            view.printNotice(std.fmt.bufPrint(&buf, "[Process exited with code {d}. Close the pane with Ctrl+Shift+W.]", .{code}) catch "[Process exited]");
            return;
        }
        // Closing from inside the child-watch callback would free the view
        // that is running it; do it from an idle callback.
        const ref = tab.window.allocator.create(PaneRef) catch return;
        ref.* = .{ .tab = tab, .view = view };
        _ = glib.idleAdd(closePaneIdle, ref);
    }

    fn closePaneIdle(data: ?*anyopaque) callconv(.c) c_int {
        const ref: *PaneRef = @ptrCast(@alignCast(data.?));
        const window = ref.tab.window;
        defer window.allocator.destroy(ref);
        if (!window.closing and std.mem.indexOfScalar(*Tab, window.tabs.items, ref.tab) != null and ref.tab.paneOf(ref.view) != null) window.closePane(ref.tab, ref.view);
        return 0;
    }

    fn closeTab(self: *TermWindow, tab: *Tab) void {
        if (self.closing) return;
        const index = std.mem.indexOfScalar(*Tab, self.tabs.items, tab) orelse return;
        _ = self.tabs.orderedRemove(index);

        if (self.group_leader == tab.button) self.group_leader = if (self.tabs.items.len > 0) self.tabs.items[0].button else null;
        tab.button.setGroup(null);
        if (self.group_leader) |leader| for (self.tabs.items) |t| if (t.button != leader) t.button.setGroup(leader);
        for (tab.panes.items) |p| p.view.shutdown();
        self.strip.remove(tab.button.as(gtk.Widget));
        self.stack.remove(tab.root.as(gtk.Widget));
        freeTab(self.allocator, tab);

        if (self.tabs.items.len == 0) {
            self.close_confirmed = true;
            self.window.as(gtk.Window).close();
            return;
        }
        self.select(self.tabs.items[@min(index, self.tabs.items.len - 1)]);
        self.updateTransparency();
    }

    fn updateWindowTitle(self: *TermWindow) void {
        const tab = self.currentTab() orelse return;
        var buf: [256]u8 = undefined;
        const t = tab.custom_title orelse (tab.active.view.title() orelse "Terminal");
        const text = std.fmt.bufPrintSentinel(&buf, "{s}", .{t[0..@min(t.len, 250)]}, 0) catch return;
        self.window.as(gtk.Window).setTitle(text);
    }

    /// Full screen means the terminal alone: the menu bar goes away with it.
    fn onFullscreenChanged(_: *gtk.ApplicationWindow, _: *gobject.ParamSpec, self: *TermWindow) callconv(.c) void {
        const bar = self.menu_bar orelse return;
        bar.as(gtk.Widget).setVisible(@intFromBool(self.window.as(gtk.Window).isFullscreen() == 0 and !self.dropdown));
    }

    // ---- shortcuts and actions -------------------------------------------------

    /// The shortcuts again, caught before the terminal sees the keys (the
    /// program in it would otherwise get Ctrl+Shift+T and the like).
    fn installShortcuts(self: *TermWindow) void {
        const controller = gtk.ShortcutController.new();
        controller.as(gtk.EventController).setPropagationPhase(.capture);
        for (actions) |a| {
            var buf: [64]u8 = undefined;
            const accel = self.accelFor(a.name, a.accel, &buf) orelse continue;
            addShortcut(controller, accel, a.name);
        }
        for (extra_keys) |k| addShortcut(controller, k.accel, k.action);
        self.window.as(gtk.Widget).addController(controller.as(gtk.EventController));
        self.window.as(gobject.Object).setData("dkde-term-window", self);
    }

    fn addShortcut(controller: *gtk.ShortcutController, accel: [:0]const u8, action: [:0]const u8) void {
        const trigger = gtk.ShortcutTrigger.parseString(accel) orelse return;
        // The action name lives as long as the program (it is from a table).
        const name: [*:0]const u8 = for (actions) |a| {
            if (std.mem.eql(u8, a.name, action)) break a.name.ptr;
        } else return;
        const cb = gtk.CallbackAction.new(onShortcut, @ptrCast(@constCast(name)), null);
        controller.addShortcut(gtk.Shortcut.new(trigger, @ptrCast(cb)));
    }

    fn onShortcut(widget: *gtk.Widget, _: ?*glib.Variant, data: ?*anyopaque) callconv(.c) c_int {
        const name: [*:0]const u8 = @ptrCast(data.?);
        const obj: *gobject.Object = @ptrCast(@alignCast(widget));
        const self: *TermWindow = @ptrCast(@alignCast(obj.getData("dkde-term-window") orelse return 0));
        const action = std.mem.span(name);
        // Check items: the menu's state flips first, as when clicked.
        for ([_][]const u8{ "read-only", "monitor-activity", "monitor-silence" }) |c| if (std.mem.eql(u8, c, action)) {
            const now = !self.checked(std.mem.span(name));
            common.menubar.setChecked(self.window, std.mem.span(name), now);
        };
        self.perform(action);
        return 1;
    }

    fn onMenubarAction(self: *TermWindow, action: []const u8) void {
        self.perform(action);
    }

    fn checked(self: *TermWindow, action: [:0]const u8) bool {
        const found = self.window.as(gio.ActionMap).lookupAction(action) orelse return false;
        const state = found.getState() orelse return false;
        defer state.unref();
        return state.getBoolean() != 0;
    }

    fn perform(self: *TermWindow, action: []const u8) void {
        const eql = std.mem.eql;
        const tab = self.currentTab();
        const view: ?*TerminalView = if (tab) |t| t.active.view else null;
        if (eql(u8, action, "new-tab")) return self.newTab(null, null, self.currentDirectory()) catch {};
        if (eql(u8, action, "new-window")) {
            const w = create(self.allocator, self.app, self.config, null) catch return;
            return w.present();
        }
        if (eql(u8, action, "close-tab")) return if (tab) |t| self.askCloseTab(t);
        if (eql(u8, action, "close-pane")) return if (tab) |t| self.askClosePane(t, t.active);
        if (eql(u8, action, "quit")) return self.window.as(gtk.Window).close();
        if (eql(u8, action, "save-output")) return self.saveOutput();
        if (eql(u8, action, "copy")) return if (view) |v| v.copySelection();
        if (eql(u8, action, "copy-html")) return if (view) |v| v.copySelectionHtml();
        if (eql(u8, action, "paste")) return if (view) |v| v.pasteClipboard(false);
        if (eql(u8, action, "select-all")) return if (view) |v| v.selectAll();
        if (eql(u8, action, "clear-scrollback")) return if (view) |v| v.clearScrollback();
        if (eql(u8, action, "reset")) return if (view) |v| v.reset();
        if (eql(u8, action, "read-only")) return if (view) |v| v.setReadOnly(self.checked("read-only"));
        if (eql(u8, action, "monitor-activity") or eql(u8, action, "monitor-silence")) {
            if (view) |v| v.setMonitors(self.checked("monitor-activity"), self.checked("monitor-silence"));
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
        if (eql(u8, action, "zoom-in")) return self.setZoom(self.zoom * 1.1);
        if (eql(u8, action, "zoom-out")) return self.setZoom(self.zoom / 1.1);
        if (eql(u8, action, "zoom-reset")) return self.setZoom(1.0);
        if (eql(u8, action, "fullscreen")) {
            if (self.window.as(gtk.Window).isFullscreen() != 0) self.window.as(gtk.Window).unfullscreen() else self.window.as(gtk.Window).fullscreen();
            return;
        }
        if (eql(u8, action, "split-right")) return self.splitPane(.horizontal);
        if (eql(u8, action, "split-down")) return self.splitPane(.vertical);
        if (eql(u8, action, "maximize-pane")) return if (tab) |t| self.toggleMaximize(t);
        if (eql(u8, action, "grow-pane")) return self.resizePane(true);
        if (eql(u8, action, "shrink-pane")) return self.resizePane(false);
        if (eql(u8, action, "equal-panes")) return self.equalizePanes();
        if (eql(u8, action, "focus-left")) return self.focusDirection(.left);
        if (eql(u8, action, "focus-right")) return self.focusDirection(.right);
        if (eql(u8, action, "focus-up")) return self.focusDirection(.up);
        if (eql(u8, action, "focus-down")) return self.focusDirection(.down);
        if (eql(u8, action, "rename-tab")) return if (tab) |t| self.renameTab(t);
        if (eql(u8, action, "detach-tab")) return if (tab) |t| self.detachTab(t);
        if (eql(u8, action, "move-tab-left") or eql(u8, action, "move-tab-right")) {
            const t = tab orelse return;
            const i = std.mem.indexOfScalar(*Tab, self.tabs.items, t) orelse return;
            if (eql(u8, action, "move-tab-left")) {
                if (i > 0) self.moveTab(t, self, i - 1);
            } else if (i + 1 < self.tabs.items.len) self.moveTab(t, self, i + 2);
            return;
        }
        if (eql(u8, action, "next-tab")) return self.cycle(true);
        if (eql(u8, action, "prev-tab")) return self.cycle(false);
    }

    fn setZoom(self: *TermWindow, zoom: f64) void {
        self.zoom = std.math.clamp(zoom, 0.3, 4.0);
        for (self.tabs.items) |t| for (t.panes.items) |p| p.view.setZoom(self.zoom);
    }

    // ---- saving output ------------------------------------------------------------

    fn saveOutput(self: *TermWindow) void {
        const dialog = gtk.FileDialog.new();
        defer dialog.as(gobject.Object).unref();
        dialog.setInitialName("terminal-output.txt");
        dialog.save(self.window.as(gtk.Window), null, onSaveChosen, self);
    }

    fn onSaveChosen(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *TermWindow = @ptrCast(@alignCast(data.?));
        const dialog: *gtk.FileDialog = @ptrCast(@alignCast(source.?));
        const file = dialog.saveFinish(result, null) orelse return;
        defer file.as(gobject.Object).unref();
        const path = file.getPath() orelse return;
        defer glib.free(path);
        const tab = self.currentTab() orelse return;
        // A name ending in .html or .htm keeps the colours.
        const p = std.mem.span(path);
        const html = std.ascii.endsWithIgnoreCase(p, ".html") or std.ascii.endsWithIgnoreCase(p, ".htm");
        const text = tab.active.view.outputText(html) catch return;
        defer self.allocator.free(text);
        common.fsio.writeFileAtomic(p, text) catch |e| {
            var buf: [200]u8 = undefined;
            common.dialogs.showError(self.window.as(gtk.Window), common.tr("Cannot save the output"), std.fmt.bufPrintSentinel(&buf, "{s}", .{@errorName(e)}, 0) catch "");
        };
    }

    // ---- find ----------------------------------------------------------------

    fn searchOptions(self: *TermWindow) finder_mod.Options {
        return .{
            .case_sensitive = self.search_case.getActive() != 0,
            .whole_word = self.search_word.getActive() != 0,
            .regex = self.search_regex.getActive() != 0,
        };
    }

    fn runSearch(self: *TermWindow) void {
        const tab = self.currentTab() orelse return;
        tab.active.view.searchSet(std.mem.span(self.search_entry.as(gtk.Editable).getText()), self.searchOptions());
        self.showCount();
    }

    fn showCount(self: *TermWindow) void {
        const tab = self.currentTab() orelse return;
        const c = tab.active.view.searchCount();
        self.search_entry.as(gtk.Widget).removeCssClass("error");
        var buf: [180]u8 = undefined;
        if (c.error_text) |e| {
            self.search_entry.as(gtk.Widget).addCssClass("error");
            return self.search_count.setText(std.fmt.bufPrintSentinel(&buf, "{s}", .{e[0..@min(e.len, 170)]}, 0) catch "");
        }
        if (std.mem.span(self.search_entry.as(gtk.Editable).getText()).len == 0) return self.search_count.setText("");
        if (c.total == 0) return self.search_count.setText(common.tr("No results"));
        self.search_count.setText(std.fmt.bufPrintSentinel(&buf, "{d} of {d}", .{ c.current, c.total }, 0) catch "");
    }

    fn onSearchChanged(_: *gtk.SearchEntry, self: *TermWindow) callconv(.c) void {
        self.runSearch();
    }

    fn onSearchOption(_: *gtk.CheckButton, self: *TermWindow) callconv(.c) void {
        self.runSearch();
    }

    fn step(self: *TermWindow, older: bool) void {
        const tab = self.currentTab() orelse return;
        _ = tab.active.view.searchStep(older);
        self.showCount();
    }

    fn onSearchOlder(_: *gtk.SearchEntry, self: *TermWindow) callconv(.c) void {
        self.step(true);
    }

    fn onSearchNewer(_: *gtk.SearchEntry, self: *TermWindow) callconv(.c) void {
        self.step(false);
    }

    fn onSearchOlderButton(_: *gtk.Button, self: *TermWindow) callconv(.c) void {
        self.step(true);
    }

    fn onSearchNewerButton(_: *gtk.Button, self: *TermWindow) callconv(.c) void {
        self.step(false);
    }

    fn onSearchStop(_: *gtk.SearchEntry, self: *TermWindow) callconv(.c) void {
        self.search_bar.setSearchMode(0);
    }

    fn onSearchMode(_: *gtk.SearchBar, _: *gobject.ParamSpec, self: *TermWindow) callconv(.c) void {
        if (self.search_bar.getSearchMode() != 0) return;
        if (self.currentTab()) |tab| {
            tab.active.view.searchClose();
            tab.active.view.grabFocus();
        }
    }

    fn cycle(self: *TermWindow, forward: bool) void {
        const current = self.currentTab() orelse return;
        const index = std.mem.indexOfScalar(*Tab, self.tabs.items, current) orelse return;
        const n = self.tabs.items.len;
        self.select(self.tabs.items[if (forward) (index + 1) % n else (index + n - 1) % n]);
    }

    // ---- the session ------------------------------------------------------------

    /// Writes the tabs, their splits and each pane's folder, to open again
    /// at the next start (term.toml: restore-session).
    fn saveSession(self: *TermWindow) void {
        const gpa = self.allocator;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        if (self.config.getBool("terminal", "restore-session", true)) {
            for (self.tabs.items) |tab| {
                out.writer.print("T\t{s}\t{s}\n", .{ tab.profileName(), tab.custom_title orelse "" }) catch return;
                self.writeTree(&out.writer, tab, tab.root.as(gtk.Widget).getFirstChild() orelse continue) catch return;
            }
        }
        const file = common.paths.userStateFile(gpa, "term-session") catch return;
        defer gpa.free(file);
        if (std.fs.path.dirname(file)) |dir| common.fsio.makePath(dir) catch {};
        common.fsio.writeFileAtomic(file, out.written()) catch {};
    }

    fn writeTree(self: *TermWindow, w: *std.Io.Writer, tab: *Tab, node: *gtk.Widget) !void {
        if (gobject.typeCheckInstanceIsA(@ptrCast(node), gtk.Paned.getGObjectType()) != 0) {
            const paned: *gtk.Paned = @ptrCast(@alignCast(node));
            const horizontal = paned.as(gtk.Orientable).getOrientation() == .horizontal;
            const size = if (horizontal) node.getWidth() else node.getHeight();
            const permille: c_int = if (size > 0) @divTrunc(paned.getPosition() * 1000, size) else 500;
            try w.print("S\t{s}\t{d}\n", .{ if (horizontal) "h" else "v", std.math.clamp(permille, 50, 950) });
            try self.writeTree(w, tab, paned.getStartChild() orelse return error.Broken);
            try self.writeTree(w, tab, paned.getEndChild() orelse return error.Broken);
            return;
        }
        for (tab.panes.items) |p| if (p.frame.as(gtk.Widget) == node) {
            const dir = p.view.workingDirectory(self.allocator);
            defer if (dir) |d| self.allocator.free(d);
            try w.print("V\t{s}\t{s}\n", .{ p.view.profile.name, dir orelse "" });
            return;
        };
        return error.Broken;
    }

    /// Opens the tabs of the last session in this (empty) window; false
    /// when there were none.
    pub fn restoreSession(self: *TermWindow) bool {
        if (!self.config.getBool("terminal", "restore-session", true)) return false;
        const gpa = self.allocator;
        const file = common.paths.userStateFile(gpa, "term-session") catch return false;
        defer gpa.free(file);
        const text = (common.fsio.readFile(gpa, file, 1 << 20) catch null) orelse return false;
        defer gpa.free(text);
        var parsed = session.parse(gpa, text) catch return false;
        defer parsed.deinit(gpa);
        for (parsed.tabs) |t| {
            const tab = self.makeTab() catch continue;
            tab.custom_title = if (t.title.len > 0) gpa.dupe(u8, t.title) catch null else null;
            const built = self.buildNode(tab, parsed.nodes, t.first) catch {
                for (tab.panes.items) |p| p.view.shutdown();
                freeTab(gpa, tab);
                continue;
            };
            tab.root.append(built.widget);
            if (tab.panes.items.len == 0) {
                freeTab(gpa, tab);
                continue;
            }
            tab.active = tab.panes.items[0];
            self.addTab(tab, null) catch continue;
        }
        if (self.tabs.items.len == 0) return false;
        self.select(self.tabs.items[0]);
        self.updateTransparency();
        return true;
    }

    /// Builds the pane or split at `nodes[index]`; returns its widget and
    /// the index after it (a split's children follow it).
    fn buildNode(self: *TermWindow, tab: *Tab, nodes: []const session.Node, index: usize) !struct { widget: *gtk.Widget, next: usize } {
        if (index >= nodes.len) return error.Broken;
        switch (nodes[index]) {
            .pane => |p| {
                const dir: ?[]const u8 = if (p.directory.len > 0 and common.fsio.exists(p.directory)) p.directory else null;
                const pane = try self.createPane(tab, p.profile, null, dir);
                try tab.panes.append(self.allocator, pane);
                return .{ .widget = pane.frame.as(gtk.Widget), .next = index + 1 };
            },
            .split => |sp| {
                const a = try self.buildNode(tab, nodes, index + 1);
                const b = try self.buildNode(tab, nodes, a.next);
                const paned = gtk.Paned.new(if (sp.horizontal) .horizontal else .vertical);
                paned.setResizeStartChild(1);
                paned.setResizeEndChild(1);
                paned.setShrinkStartChild(0);
                paned.setShrinkEndChild(0);
                paned.setWideHandle(1);
        // A visible splitter, apart from the panes' title bars (as in Konsole).
        paned.setWideHandle(1);
                paned.as(gtk.Widget).setHexpand(1);
                paned.as(gtk.Widget).setVexpand(1);
                paned.setStartChild(a.widget);
                paned.setEndChild(b.widget);
                // The ratio once the window has its size.
                if (self.allocator.create(RatioCtx)) |ctx| {
                    ctx.* = .{ .paned = paned, .permille = sp.permille, .gpa = self.allocator };
                    _ = glib.timeoutAdd(150, applyRatio, ctx);
                } else |_| {}
                return .{ .widget = paned.as(gtk.Widget), .next = b.next };
            },
        }
    }

    const RatioCtx = struct { paned: *gtk.Paned, permille: u16, gpa: std.mem.Allocator };

    fn applyRatio(data: ?*anyopaque) callconv(.c) c_int {
        const ctx: *RatioCtx = @ptrCast(@alignCast(data.?));
        defer ctx.gpa.destroy(ctx);
        const w = ctx.paned.as(gtk.Widget);
        const size = if (ctx.paned.as(gtk.Orientable).getOrientation() == .horizontal) w.getWidth() else w.getHeight();
        if (size > 0) ctx.paned.setPosition(@divTrunc(size * @as(c_int, ctx.permille), 1000));
        return 0;
    }
};
