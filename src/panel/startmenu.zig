//! The start menu (SPEC.md 5.2): an overlay layer surface covering the output
//! so a click outside the menu can close it, with the menu itself in the
//! bottom-left corner above the bar. It is built when opened and destroyed
//! when closed, so it always reflects the installed apps.

const std = @import("std");
const gdk = @import("gdk4");
const gio = @import("gio2");
const giounix = @import("giounix2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

const surface = @import("surface.zig");
const Position = @import("position.zig").Position;

const log = std.log.scoped(.startmenu);

const default_pinned = [_][]const u8{ "dkde-files.desktop", "dkde-term.desktop", "dkde-settings.desktop" };
const default_recent_count = 5;

/// An installed app, as shown in every list of the menu.
const AppEntry = struct {
    menu: *StartMenu,
    info: *gio.AppInfo,
    id: []u8,
    name: [:0]u8,
    generic_name: ?[]u8,
    keywords: [][]u8,
    category: common.apps.Category,
};

pub const StartMenu = struct {
    allocator: std.mem.Allocator,
    config: *const common.Config,
    window: *gtk.Window,
    on_closed: *const fn (*anyopaque) void,
    on_closed_data: *anyopaque,

    apps: std.ArrayList(*AppEntry) = .empty,
    recent: std.ArrayList([]u8) = .empty,
    links: std.ArrayList(*Link) = .empty,

    menu_box: *gtk.Box = undefined,
    stack: *gtk.Stack = undefined,
    search: *gtk.SearchEntry = undefined,
    results: *gtk.Box = undefined,
    /// The page to return to when the search box is emptied.
    page: [:0]const u8 = "main",
    /// Best current search match, launched by Enter.
    first_result: ?*AppEntry = null,
    /// X11: the menu has been active once, so losing focus now means "close".
    seen_active: bool = false,

    pub fn open(
        allocator: std.mem.Allocator,
        config: *const common.Config,
        monitor: *gdk.Monitor,
        bar_height: c_int,
        position: Position,
        on_closed: *const fn (*anyopaque) void,
        on_closed_data: *anyopaque,
    ) !*StartMenu {
        const self = try allocator.create(StartMenu);
        errdefer allocator.destroy(self);

        const window = gtk.Window.new();
        window.as(gtk.Widget).addCssClass("dkde-menu-backdrop");
        self.* = .{
            .allocator = allocator,
            .config = config,
            .window = window,
            .on_closed = on_closed,
            .on_closed_data = on_closed_data,
        };
        errdefer self.freeData();

        try self.loadApps();
        self.recent = try common.state.loadList(allocator, "recent.conf", "recent", "apps");

        self.build(bar_height, position);

        surface.setup(window, .{
            .name_space = "dkde-menu",
            .layer = .overlay,
            .monitor = monitor,
            .anchors = &.{ .top, .bottom, .left, .right },
            .exclusive_zone = -1,
            .keyboard_mode = .exclusive,
            .size = bar_height,
            .menu_side = position.edge(),
        });
        // Without layer-shell there is no full-output backdrop to click, so
        // losing focus closes the menu instead.
        if (surface.isX11()) _ = gobject.Object.signals.notify.connect(window, *StartMenu, &onActiveChanged, self, .{ .detail = "is-active" });
        window.present();
        _ = self.search.as(gtk.Widget).grabFocus();
        return self;
    }

    pub fn close(self: *StartMenu) void {
        self.window.destroy();
        self.freeData();
        const callback = self.on_closed;
        const data = self.on_closed_data;
        self.allocator.destroy(self);
        callback(data);
    }

    fn freeData(self: *StartMenu) void {
        for (self.apps.items) |app| {
            app.info.as(gobject.Object).unref();
            self.allocator.free(app.id);
            self.allocator.free(app.name);
            if (app.generic_name) |g| self.allocator.free(g);
            common.config.freeStringList(self.allocator, app.keywords);
            self.allocator.destroy(app);
        }
        self.apps.deinit(self.allocator);
        common.state.freeList(self.allocator, &self.recent);
        for (self.links.items) |link| self.allocator.destroy(link);
        self.links.deinit(self.allocator);
    }

    // ---- data ----------------------------------------------------------

    fn loadApps(self: *StartMenu) !void {
        const all = gio.AppInfo.getAll();
        defer all.free();
        var node: ?*glib.List = all;
        while (node) |n| : (node = n.f_next) {
            const info: *gio.AppInfo = @ptrCast(@alignCast(n.f_data orelse continue));
            // Honours NoDisplay, OnlyShowIn and NotShowIn; GIO skips Hidden.
            if (info.shouldShow() == 0) continue;
            const desktop: *giounix.DesktopAppInfo = @ptrCast(info);

            const app = try self.allocator.create(AppEntry);
            errdefer self.allocator.destroy(app);
            const id = try self.allocator.dupe(u8, std.mem.span(info.getId() orelse continue));
            errdefer self.allocator.free(id);
            const name = try self.allocator.dupeSentinel(u8, std.mem.span(info.getDisplayName()), 0);
            errdefer self.allocator.free(name);
            const generic = if (desktop.getGenericName()) |g| try self.allocator.dupe(u8, std.mem.span(g)) else null;
            errdefer if (generic) |g| self.allocator.free(g);

            var keywords: std.ArrayList([]u8) = .empty;
            errdefer common.config.freeStringList(self.allocator, keywords.items);
            if (desktop.getKeywords()) |list| {
                const terminated: [*:null]const ?[*:0]const u8 = @ptrCast(list);
                var i: usize = 0;
                while (terminated[i]) |kw| : (i += 1) try keywords.append(self.allocator, try self.allocator.dupe(u8, std.mem.span(kw)));
            }

            app.* = .{
                .menu = self,
                .info = @ptrCast(info.as(gobject.Object).ref()),
                .id = id,
                .name = name,
                .generic_name = generic,
                .keywords = try keywords.toOwnedSlice(self.allocator),
                .category = common.apps.mainCategory(if (desktop.getCategories()) |c| std.mem.span(c) else null),
            };
            try self.apps.append(self.allocator, app);
        }
        std.mem.sort(*AppEntry, self.apps.items, {}, byName);
    }

    fn byName(_: void, a: *AppEntry, b: *AppEntry) bool {
        return std.ascii.lessThanIgnoreCase(a.name, b.name);
    }

    fn findById(self: *const StartMenu, id: []const u8) ?*AppEntry {
        for (self.apps.items) |app| if (std.mem.eql(u8, app.id, id)) return app;
        return null;
    }

    fn launch(self: *StartMenu, app: *AppEntry) void {
        common.appinfo.launch(self.allocator, app.info);
        const max: usize = @intCast(@max(1, self.config.getInt("menu", "recent-count", default_recent_count)));
        common.apps.pushRecent(self.allocator, &self.recent, app.id, max + default_pinned.len + 8) catch {};
        common.state.saveList(self.allocator, "recent.conf", "recent", "apps", self.recent.items) catch {};
        self.close();
    }

    // ---- widgets -------------------------------------------------------

    fn build(self: *StartMenu, bar_height: c_int, position: Position) void {
        const outer = self.menu_box_new();
        // The menu sits in the corner next to the panel, clear of it.
        const widget = outer.as(gtk.Widget);
        if (!surface.isX11()) switch (position) {
            .bottom => {
                widget.setHalign(.start);
                widget.setValign(.end);
                widget.setMarginBottom(bar_height);
            },
            .top => {
                widget.setHalign(.start);
                widget.setValign(.start);
                widget.setMarginTop(bar_height);
            },
            .left => {
                widget.setHalign(.start);
                widget.setValign(.end);
                widget.setMarginStart(bar_height);
            },
            .right => {
                widget.setHalign(.end);
                widget.setValign(.end);
                widget.setMarginEnd(bar_height);
            },
        };
        self.window.setChild(outer.as(gtk.Widget));
        self.menu_box = outer;

        outer.append(self.buildLeft().as(gtk.Widget));
        outer.append(self.buildRight().as(gtk.Widget));

        // Click outside the menu closes it; Escape too.
        const clicks = gtk.GestureClick.new();
        _ = gtk.GestureClick.signals.pressed.connect(clicks, *StartMenu, &onBackdropPressed, self, .{});
        self.window.as(gtk.Widget).addController(clicks.as(gtk.EventController));

        const keys = gtk.EventControllerKey.new();
        keys.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *StartMenu, &onKey, self, .{});
        self.window.as(gtk.Widget).addController(keys.as(gtk.EventController));
    }

    fn menu_box_new(_: *StartMenu) *gtk.Box {
        const box = gtk.Box.new(.horizontal, 0);
        box.as(gtk.Widget).addCssClass("dkde-menu");
        return box;
    }

    fn buildLeft(self: *StartMenu) *gtk.Box {
        const left = gtk.Box.new(.vertical, 0);
        left.as(gtk.Widget).addCssClass("dkde-menu-left");
        left.as(gtk.Widget).setSizeRequest(320, 440);

        const stack = gtk.Stack.new();
        stack.as(gtk.Widget).setVexpand(1);
        self.stack = stack;
        left.append(stack.as(gtk.Widget));

        _ = stack.addNamed(self.buildMainPage().as(gtk.Widget), "main");
        _ = stack.addNamed(self.buildAllPage().as(gtk.Widget), "all");

        const results = gtk.Box.new(.vertical, 0);
        self.results = results;
        const scroller = gtk.ScrolledWindow.new();
        scroller.setChild(results.as(gtk.Widget));
        _ = stack.addNamed(scroller.as(gtk.Widget), "results");

        const search = gtk.SearchEntry.new();
        search.as(gtk.Widget).addCssClass("dkde-menu-search");
        search.setPlaceholderText(common.tr("Search programs"));
        search.setKeyCaptureWidget(self.window.as(gtk.Widget));
        _ = gtk.SearchEntry.signals.search_changed.connect(search, *StartMenu, &onSearchChanged, self, .{});
        _ = gtk.SearchEntry.signals.activate.connect(search, *StartMenu, &onSearchActivate, self, .{});
        self.search = search;
        left.append(search.as(gtk.Widget));
        return left;
    }

    fn buildMainPage(self: *StartMenu) *gtk.Box {
        const page = gtk.Box.new(.vertical, 0);

        const list = gtk.Box.new(.vertical, 0);
        list.as(gtk.Widget).setVexpand(1);
        page.append(list.as(gtk.Widget));

        var pinned_ids: std.ArrayList(*AppEntry) = .empty;
        defer pinned_ids.deinit(self.allocator);
        const configured = self.config.getStringList(self.allocator, "menu", "pinned") catch null;
        defer if (configured) |c| common.config.freeStringList(self.allocator, c);
        if (configured) |ids| {
            for (ids) |id| if (self.findById(id)) |app| pinned_ids.append(self.allocator, app) catch {};
        } else {
            for (default_pinned) |id| if (self.findById(id)) |app| pinned_ids.append(self.allocator, app) catch {};
        }
        for (pinned_ids.items) |app| list.append(self.appButton(app).as(gtk.Widget));

        list.append(gtk.Separator.new(.horizontal).as(gtk.Widget));

        const count: usize = @intCast(@max(0, self.config.getInt("menu", "recent-count", default_recent_count)));
        var shown: usize = 0;
        for (self.recent.items) |id| {
            if (shown >= count) break;
            const app = self.findById(id) orelse continue;
            if (std.mem.indexOfScalar(*AppEntry, pinned_ids.items, app) != null) continue;
            list.append(self.appButton(app).as(gtk.Widget));
            shown += 1;
        }

        const all = gtk.Button.newWithLabel(common.tr("All Programs"));
        all.as(gtk.Widget).addCssClass("dkde-menu-all");
        _ = gtk.Button.signals.clicked.connect(all, *StartMenu, &onAllPrograms, self, .{});
        page.append(all.as(gtk.Widget));
        return page;
    }

    /// The "All Programs" tree: one expander per main category.
    fn buildAllPage(self: *StartMenu) *gtk.Box {
        const page = gtk.Box.new(.vertical, 0);

        const tree = gtk.Box.new(.vertical, 0);
        const scroller = gtk.ScrolledWindow.new();
        scroller.as(gtk.Widget).setVexpand(1);
        scroller.setChild(tree.as(gtk.Widget));
        page.append(scroller.as(gtk.Widget));

        inline for (comptime std.enums.values(common.apps.Category)) |category| {
            const folder = gtk.Box.new(.vertical, 0);
            var any = false;
            for (self.apps.items) |app| {
                if (app.category != category) continue;
                folder.append(self.appButton(app).as(gtk.Widget));
                any = true;
            }
            if (any) {
                const expander = gtk.Expander.new(common.tr(category.label()));
                expander.setChild(folder.as(gtk.Widget));
                tree.append(expander.as(gtk.Widget));
            }
        }

        const back = gtk.Button.newWithLabel(common.tr("Back"));
        back.as(gtk.Widget).addCssClass("dkde-menu-all");
        _ = gtk.Button.signals.clicked.connect(back, *StartMenu, &onBack, self, .{});
        page.append(back.as(gtk.Widget));
        return page;
    }

    fn buildRight(self: *StartMenu) *gtk.Box {
        const right = gtk.Box.new(.vertical, 0);
        right.as(gtk.Widget).addCssClass("dkde-menu-right");
        right.as(gtk.Widget).setSizeRequest(200, -1);

        // Profile picture (Settings > User) and name.
        const header = gtk.Box.new(.horizontal, 10);
        header.as(gtk.Widget).setMarginBottom(6);
        const avatar = gtk.Image.new();
        avatar.setPixelSize(48);
        avatar.as(gtk.Widget).addCssClass("dkde-avatar");
        var shared = common.Config.load(self.allocator, "dkde.conf") catch null;
        defer if (shared) |*c| c.deinit();
        const picture = if (shared) |*c| common.user.picturePath(self.allocator, c) else null;
        defer if (picture) |p| self.allocator.free(p);
        if (picture) |p| {
            if (self.allocator.dupeSentinel(u8, p, 0)) |z| {
                defer self.allocator.free(z);
                avatar.setFromFile(z);
            } else |_| avatar.setFromIconName("avatar-default-symbolic");
        } else avatar.setFromIconName("avatar-default-symbolic");
        header.append(avatar.as(gtk.Widget));
        const user = gtk.Label.new(common.user.displayName());
        user.as(gtk.Widget).addCssClass("dkde-menu-user");
        user.setXalign(0);
        user.as(gtk.Widget).setHexpand(1);
        header.append(user.as(gtk.Widget));
        right.append(header.as(gtk.Widget));

        const places = [_]struct { [:0]const u8, ?glib.UserDirectory }{
            .{ "Home", null },
            .{ "Documents", .directory_documents },
            .{ "Pictures", .directory_pictures },
            .{ "Music", .directory_music },
            .{ "Downloads", .directory_download },
        };
        inline for (places) |place| {
            const path: [*:0]const u8 = if (place[1]) |dir| (glib.getUserSpecialDir(dir) orelse glib.getHomeDir()) else glib.getHomeDir();
            right.append(self.linkButton(common.tr(place[0]), "dkde-files", std.mem.span(path)).as(gtk.Widget));
        }
        right.append(gtk.Separator.new(.horizontal).as(gtk.Widget));
        right.append(self.linkButton(common.tr("Terminal"), "dkde-term", null).as(gtk.Widget));
        right.append(self.linkButton(common.tr("Settings"), "dkde-settings", null).as(gtk.Widget));

        const spacer = gtk.Box.new(.vertical, 0);
        spacer.as(gtk.Widget).setVexpand(1);
        right.append(spacer.as(gtk.Widget));
        right.append(self.buildPower().as(gtk.Widget));
        return right;
    }

    fn buildPower(self: *StartMenu) *gtk.Box {
        const row = gtk.Box.new(.horizontal, 0);

        const shutdown = gtk.Button.newWithLabel(common.tr("Shut Down"));
        shutdown.as(gtk.Widget).setHexpand(1);
        shutdown.as(gtk.Widget).addCssClass("dkde-menu-power");
        _ = gtk.Button.signals.clicked.connect(shutdown, *StartMenu, &onShutdown, self, .{});
        row.append(shutdown.as(gtk.Widget));

        const popover = gtk.Popover.new();
        const items = gtk.Box.new(.vertical, 0);
        popover.setChild(items.as(gtk.Widget));
        // Lock and Sleep appear only when there is something to run for them.
        if (self.powerCommand("lock-command", common.power.detectLock) != null) {
            const lock = gtk.Button.newWithLabel(common.tr("Lock"));
            lock.setHasFrame(0);
            items.append(lock.as(gtk.Widget));
            _ = gtk.Button.signals.clicked.connect(lock, *StartMenu, &onLock, self, .{});
        }
        if (self.powerCommand("sleep-command", common.power.detectSleep) != null) {
            const sleep = gtk.Button.newWithLabel(common.tr("Sleep"));
            sleep.setHasFrame(0);
            items.append(sleep.as(gtk.Widget));
            _ = gtk.Button.signals.clicked.connect(sleep, *StartMenu, &onSleep, self, .{});
        }
        const restart = gtk.Button.newWithLabel(common.tr("Restart"));
        const logoff = gtk.Button.newWithLabel(common.tr("Log Off"));
        for ([_]*gtk.Button{ restart, logoff }) |b| {
            b.setHasFrame(0);
            items.append(b.as(gtk.Widget));
        }
        _ = gtk.Button.signals.clicked.connect(restart, *StartMenu, &onRestart, self, .{});
        _ = gtk.Button.signals.clicked.connect(logoff, *StartMenu, &onLogoff, self, .{});

        const more = gtk.MenuButton.new();
        more.setPopover(popover);
        more.as(gtk.Widget).addCssClass("dkde-menu-power");
        row.append(more.as(gtk.Widget));
        return row;
    }

    fn appButton(self: *StartMenu, app: *AppEntry) *gtk.Button {
        _ = self;
        const content = gtk.Box.new(.horizontal, 8);
        const icon = gtk.Image.new();
        icon.setPixelSize(24);
        if (app.info.getIcon()) |gicon| icon.setFromGicon(gicon) else icon.setFromIconName("application-x-executable");
        const label = gtk.Label.new(app.name);
        label.setXalign(0);
        label.setEllipsize(.end);
        content.append(icon.as(gtk.Widget));
        content.append(label.as(gtk.Widget));

        const button = gtk.Button.new();
        button.setChild(content.as(gtk.Widget));
        button.setHasFrame(0);
        button.as(gtk.Widget).addCssClass("dkde-menu-app");
        _ = gtk.Button.signals.clicked.connect(button, *AppEntry, &onAppClicked, app, .{});

        const click = gtk.GestureClick.new();
        click.as(gtk.GestureSingle).setButton(3);
        _ = gtk.GestureClick.signals.pressed.connect(click, *AppEntry, &onAppRightClick, app, .{});
        button.as(gtk.Widget).addController(click.as(gtk.EventController));
        const keys = gtk.EventControllerKey.new();
        _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *AppEntry, &onAppKey, app, .{});
        button.as(gtk.Widget).addController(keys.as(gtk.EventController));
        return button;
    }

    /// A button that runs `command`, optionally with one argument. Both must
    /// outlive the menu (literals and GLib's static directory strings do).
    fn linkButton(self: *StartMenu, label: [:0]const u8, command: []const u8, arg: ?[]const u8) *gtk.Button {
        const ctx = self.allocator.create(Link) catch @panic("OOM");
        self.links.append(self.allocator, ctx) catch @panic("OOM");
        ctx.* = .{ .menu = self, .command = command, .arg = arg };
        const button = gtk.Button.newWithLabel(label);
        button.setHasFrame(0);
        button.as(gtk.Widget).addCssClass("dkde-menu-link");
        button.as(gtk.Widget).setHalign(.fill);
        _ = gtk.Button.signals.clicked.connect(button, *Link, &onLink, ctx, .{});
        return button;
    }

    const Link = struct { menu: *StartMenu, command: []const u8, arg: ?[]const u8 };

    // ---- search --------------------------------------------------------

    fn runSearch(self: *StartMenu, query: []const u8) void {
        while (self.results.as(gtk.Widget).getFirstChild()) |child| self.results.remove(child);
        self.first_result = null;

        const Hit = struct { app: *AppEntry, rank: u8 };
        var hits: std.ArrayList(Hit) = .empty;
        defer hits.deinit(self.allocator);
        for (self.apps.items) |app| {
            const r = common.apps.rank(query, app.name, app.generic_name, @ptrCast(app.keywords)) orelse continue;
            hits.append(self.allocator, .{ .app = app, .rank = r }) catch return;
        }
        // Stable: apps are already sorted by name within equal ranks.
        std.mem.sort(Hit, hits.items, {}, struct {
            fn less(_: void, a: Hit, b: Hit) bool {
                return a.rank < b.rank;
            }
        }.less);

        for (hits.items) |hit| self.results.append(self.appButton(hit.app).as(gtk.Widget));
        if (hits.items.len > 0) self.first_result = hits.items[0].app;
    }

    // ---- signal handlers ----------------------------------------------

    fn onAppClicked(_: *gtk.Button, app: *AppEntry) callconv(.c) void {
        app.menu.launch(app);
    }

    const pin_action = 0;
    const location_action = 1;
    const admin_action = 2;

    fn showAppMenu(app: *AppEntry, parent: *gtk.Widget, x: f64, y: f64) void {
        const pinned = app.menu.isPinned(app.id);
        common.contextmenu.show(parent, x, y, &.{
            .{ .label = if (pinned) common.tr("Unpin from Start menu") else common.tr("Pin to Start menu"), .id = pin_action },
            .{ .label = common.tr("Open file location"), .id = location_action },
            .{ .label = common.tr("Run as administrator"), .id = admin_action },
        }, AppEntry, onAppMenuChosen, app);
    }

    fn onAppRightClick(gesture: *gtk.GestureClick, _: c_int, x: f64, y: f64, app: *AppEntry) callconv(.c) void {
        const widget = gesture.as(gtk.EventController).getWidget() orelse return;
        showAppMenu(app, widget, x, y);
    }

    fn onAppKey(ctrl: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, state: gdk.ModifierType, app: *AppEntry) callconv(.c) c_int {
        const menu_key = keyval == gdk.KEY_Menu or (keyval == gdk.KEY_F10 and state.shift_mask);
        if (!menu_key) return 0;
        const widget = ctrl.as(gtk.EventController).getWidget() orelse return 0;
        showAppMenu(app, widget, 8, 8);
        return 1;
    }

    fn onAppMenuChosen(app: *AppEntry, id: usize) void {
        switch (id) {
            pin_action => app.menu.togglePin(app.id),
            admin_action => app.menu.runAsAdmin(app),
            location_action => {
                const desktop: *giounix.DesktopAppInfo = @ptrCast(app.info);
                const filename = desktop.getFilename() orelse return;
                const dir = glib.pathGetDirname(filename);
                defer glib.free(dir);
                common.appinfo.spawn(app.menu.allocator, &.{ "dkde-files", std.mem.span(dir) });
                app.menu.close();
            },
            else => {},
        }
    }

    const AdminDone = struct {};

    fn onAdminDone(_: *AdminDone, outcome: common.elevate.Outcome, message: []const u8) void {
        if (outcome != .failed) return;
        var buf: [512]u8 = undefined;
        common.dialogs.showError(null, common.tr("Could not run as administrator"), std.fmt.bufPrintSentinel(&buf, "{s}", .{message}, 0) catch "");
    }

    /// Asks for the administrator password and starts the app as root. The
    /// menu closes first; the password prompt is its own window.
    fn runAsAdmin(self: *StartMenu, app: *AppEntry) void {
        const a = std.heap.c_allocator;
        const command = common.appinfo.commandArgv(a, app.info) orelse return;
        defer common.appinfo.freeArgv(a, command);

        var argv: std.ArrayList([]u8) = .empty;
        defer {
            for (argv.items) |x| a.free(x);
            argv.deinit(a);
        }
        common.appinfo.displayEnvArgs(a, &argv) catch return;
        for (command) |c| argv.append(a, a.dupe(u8, c) catch return) catch return;

        const view = a.alloc([]const u8, argv.items.len) catch return;
        defer a.free(view);
        for (argv.items, 0..) |x, i| view[i] = x;

        var reason_buf: [200]u8 = undefined;
        const reason = std.fmt.bufPrint(&reason_buf, "Run {s} as administrator", .{std.mem.span(app.info.getDisplayName())}) catch return;
        const done = a.create(AdminDone) catch return;
        self.close();
        common.elevate.run(null, reason, view, "", AdminDone, onAdminDone, done);
    }

    /// The pinned desktop IDs: the configured list, else the defaults.
    fn pinnedIds(self: *StartMenu) ![][]u8 {
        var cfg = try common.Config.load(self.allocator, "panel.conf");
        defer cfg.deinit();
        if (try cfg.getStringList(self.allocator, "menu", "pinned")) |list| return list;
        var out: std.ArrayList([]u8) = .empty;
        errdefer common.config.freeStringList(self.allocator, out.items);
        for (default_pinned) |id| try out.append(self.allocator, try self.allocator.dupe(u8, id));
        return try out.toOwnedSlice(self.allocator);
    }

    fn isPinned(self: *StartMenu, id: []const u8) bool {
        const ids = self.pinnedIds() catch return false;
        defer common.config.freeStringList(self.allocator, ids);
        for (ids) |p| if (std.mem.eql(u8, p, id)) return true;
        return false;
    }

    /// Pins or unpins an app. The panel's file monitor and the next menu
    /// open pick the change up.
    fn togglePin(self: *StartMenu, id: []const u8) void {
        const ids = self.pinnedIds() catch return;
        defer common.config.freeStringList(self.allocator, ids);
        var next: std.ArrayList([]const u8) = .empty;
        defer next.deinit(self.allocator);
        var found = false;
        for (ids) |p| {
            if (std.mem.eql(u8, p, id)) found = true else next.append(self.allocator, p) catch return;
        }
        if (!found) next.append(self.allocator, id) catch return;

        var cfg = common.Config.load(self.allocator, "panel.conf") catch return;
        defer cfg.deinit();
        cfg.setStringList("menu", "pinned", next.items) catch |err| log.warn("cannot save pins: {s}", .{@errorName(err)});
        self.close();
    }

    fn onLink(_: *gtk.Button, link: *Link) callconv(.c) void {
        const menu = link.menu;
        if (link.arg) |arg| {
            common.appinfo.spawn(menu.allocator, &.{ link.command, arg });
        } else common.appinfo.spawn(menu.allocator, &.{link.command});
        menu.close();
    }

    fn onAllPrograms(_: *gtk.Button, self: *StartMenu) callconv(.c) void {
        self.page = "all";
        self.stack.setVisibleChildName("all");
    }

    fn onBack(_: *gtk.Button, self: *StartMenu) callconv(.c) void {
        self.page = "main";
        self.stack.setVisibleChildName("main");
    }

    fn onSearchChanged(entry: *gtk.SearchEntry, self: *StartMenu) callconv(.c) void {
        const text = std.mem.span(entry.as(gtk.Editable).getText());
        if (text.len == 0) {
            self.stack.setVisibleChildName(self.page);
            return;
        }
        self.runSearch(text);
        self.stack.setVisibleChildName("results");
    }

    fn onSearchActivate(_: *gtk.SearchEntry, self: *StartMenu) callconv(.c) void {
        if (self.first_result) |app| self.launch(app);
    }

    /// X11 only: the menu closes when it stops being the active window.
    fn onActiveChanged(window: *gtk.Window, _: *gobject.ParamSpec, self: *StartMenu) callconv(.c) void {
        if (window.isActive() != 0) {
            self.seen_active = true;
        } else if (self.seen_active) {
            // Defer: closing frees this struct, and we are inside its signal.
            _ = glib.idleAdd(closeIdle, self);
        }
    }

    fn closeIdle(data: ?*anyopaque) callconv(.c) c_int {
        const self: *StartMenu = @ptrCast(@alignCast(data.?));
        self.close();
        return 0;
    }

    fn onBackdropPressed(gesture: *gtk.GestureClick, _: c_int, x: f64, y: f64, self: *StartMenu) callconv(.c) void {
        _ = gesture;
        const picked = self.window.as(gtk.Widget).pick(x, y, .{}) orelse {
            self.close();
            return;
        };
        const menu = self.menu_box.as(gtk.Widget);
        if (picked != menu and picked.isAncestor(menu) == 0) self.close();
    }

    fn onKey(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, _: gdk.ModifierType, self: *StartMenu) callconv(.c) c_int {
        if (keyval == gdk.KEY_Escape) {
            self.close();
            return 1;
        }
        return 0;
    }

    fn onShutdown(_: *gtk.Button, self: *StartMenu) callconv(.c) void {
        self.power("shutdown-command", "poweroff");
    }

    fn onRestart(_: *gtk.Button, self: *StartMenu) callconv(.c) void {
        self.power("restart-command", "reboot");
    }

    fn onLock(_: *gtk.Button, self: *StartMenu) callconv(.c) void {
        self.runPowerCommand("lock-command", common.power.detectLock);
    }

    fn onSleep(_: *gtk.Button, self: *StartMenu) callconv(.c) void {
        self.runPowerCommand("sleep-command", common.power.detectSleep);
    }

    /// The configured command, else the detected one; the caller frees it.
    fn powerCommand(self: *StartMenu, key: [:0]const u8, detect: *const fn (common.power.Probe) ?[]const u8) ?[]u8 {
        const configured = self.config.getString(self.allocator, "menu", key, "") catch return null;
        if (configured.len > 0) return configured;
        self.allocator.free(configured);
        const found = detect(common.power.system_probe) orelse return null;
        return self.allocator.dupe(u8, found) catch null;
    }

    fn runPowerCommand(self: *StartMenu, key: [:0]const u8, detect: *const fn (common.power.Probe) ?[]const u8) void {
        const command = self.powerCommand(key, detect) orelse return;
        defer self.allocator.free(command);
        const commandz = self.allocator.dupeSentinel(u8, command, 0) catch return;
        defer self.allocator.free(commandz);
        var argc: c_int = 0;
        var argv: [*:null]?[*:0]u8 = undefined;
        if (glib.shellParseArgv(commandz, &argc, &argv, null) == 0) return;
        defer glib.strfreev(argv);
        var list: std.ArrayList([]const u8) = .empty;
        defer list.deinit(self.allocator);
        for (argv[0..@intCast(argc)]) |arg| list.append(self.allocator, std.mem.span(arg.?)) catch return;
        common.appinfo.spawn(self.allocator, list.items);
        self.close();
    }

    fn onLogoff(_: *gtk.Button, self: *StartMenu) callconv(.c) void {
        self.power("logoff-command", "labwc --exit");
    }

    /// Runs the configured power command; there is no logind to ask.
    fn power(self: *StartMenu, key: [:0]const u8, default: []const u8) void {
        const command = self.config.getString(self.allocator, "menu", key, default) catch return;
        defer self.allocator.free(command);
        const commandz = self.allocator.dupeSentinel(u8, command, 0) catch return;
        defer self.allocator.free(commandz);

        var argc: c_int = 0;
        var argv: [*:null]?[*:0]u8 = undefined;
        if (glib.shellParseArgv(commandz, &argc, &argv, null) == 0) {
            log.warn("panel.conf: cannot parse {s}='{s}'", .{ key, command });
            return;
        }
        defer glib.strfreev(argv);

        var list: std.ArrayList([]const u8) = .empty;
        defer list.deinit(self.allocator);
        for (argv[0..@intCast(argc)]) |arg| list.append(self.allocator, std.mem.span(arg.?)) catch return;
        common.appinfo.spawn(self.allocator, list.items);
        self.close();
    }
};
