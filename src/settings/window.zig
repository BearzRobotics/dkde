//! The settings window (SPEC.md 5.5): major categories on the left, a list of pages and then a page on the
//! right. Every control writes its config file the moment it changes; the
//! running components pick the change up through their file monitors.

const std = @import("std");
const gdk = @import("gdk4");
const gio = @import("gio2");
const giounix = @import("giounix2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const pango = @import("pango1");
const common = @import("common");

const labwc = common.labwc;
const audio = common.audio;
const users = @import("users.zig");
const hwpages = @import("hwpages.zig");
const consolepage = @import("consolepage.zig");
const termpreview = @import("termpreview.zig");

const log = std.log.scoped(.settings);

const Page = struct { id: [:0]const u8, title: [:0]const u8, icon: [:0]const u8, category: usize, desc: [:0]const u8 };
const Section = struct { id: [:0]const u8, title: [:0]const u8, icon: [:0]const u8 };

/// The sidebar: major categories. Each opens a list of its pages (SPEC.md 5.5).
const sections = [_]Section{
    .{ .id = "personalization", .title = "Personalization", .icon = "applications-graphics-symbolic" },
    .{ .id = "system", .title = "System", .icon = "computer-symbolic" },
    .{ .id = "devices", .title = "Network & devices", .icon = "network-wireless-symbolic" },
    .{ .id = "apps", .title = "Apps", .icon = "view-app-grid-symbolic" },
    .{ .id = "time", .title = "Time & language", .icon = "preferences-system-time-symbolic" },
    .{ .id = "accounts", .title = "Accounts", .icon = "avatar-default-symbolic" },
};

/// The pages. `id` is what `--page` takes; `category` indexes `sections`.
const pages = [_]Page{
    .{ .id = "appearance", .title = "Appearance", .icon = "applications-graphics-symbolic", .category = 0, .desc = "Dark mode, accent colour, icons, wallpaper" },
    .{ .id = "taskbar", .title = "Taskbar", .icon = "view-list-symbolic", .category = 0, .desc = "The panel: position, size, clock and tray" },
    .{ .id = "startmenu", .title = "Start menu", .icon = "start-here-symbolic", .category = 0, .desc = "Pinned apps and how the menu looks" },
    .{ .id = "display", .title = "Display", .icon = "video-display-symbolic", .category = 1, .desc = "Resolution, scale, arrangement and night light" },
    .{ .id = "audio", .title = "Sound", .icon = "audio-volume-high-symbolic", .category = 1, .desc = "Volume and the input and output devices" },
    .{ .id = "power", .title = "Power & lock", .icon = "system-shutdown-symbolic", .category = 1, .desc = "Sleep, screen lock and the power button" },
    .{ .id = "network", .title = "Network", .icon = "network-wireless-symbolic", .category = 2, .desc = "Wi-Fi and wired connections" },
    .{ .id = "bluetooth", .title = "Bluetooth", .icon = "bluetooth-symbolic", .category = 2, .desc = "Pair and manage Bluetooth devices" },
    .{ .id = "printers", .title = "Printers", .icon = "printer-symbolic", .category = 2, .desc = "Printers and print queues" },
    .{ .id = "mouse", .title = "Mouse & touchpad", .icon = "input-mouse-symbolic", .category = 2, .desc = "Pointer speed, scrolling and tapping" },
    .{ .id = "keyboard", .title = "Keyboard", .icon = "input-keyboard-symbolic", .category = 2, .desc = "Layouts for typing" },
    .{ .id = "shortcuts", .title = "Keyboard shortcuts", .icon = "preferences-desktop-keyboard-shortcuts-symbolic", .category = 2, .desc = "Keys that open apps and manage windows" },
    .{ .id = "defaults", .title = "Default apps", .icon = "preferences-other-symbolic", .category = 3, .desc = "Which app opens which kind of file" },
    .{ .id = "terminal", .title = "Terminal", .icon = "utilities-terminal-symbolic", .category = 3, .desc = "The terminal window you open on the desktop (dkde-term). Your own settings, with profiles" },
    .{ .id = "console", .title = "Console", .icon = "computer-symbolic", .category = 3, .desc = "The full-screen text login on Ctrl+Alt+F1 to F6, with no desktop (dkde-console). System-wide, needs an administrator password" },
    .{ .id = "datetime", .title = "Date & time", .icon = "preferences-system-time-symbolic", .category = 4, .desc = "Time zone, clock and calendar system" },
    .{ .id = "users", .title = "User", .icon = "avatar-default-symbolic", .category = 5, .desc = "Your account and the other accounts on this computer" },
};

/// Ties one control to one config key.
const Binding = struct {
    window: *SettingsWindow,
    config: *common.Config,
    group: [:0]const u8,
    key: [:0]const u8,
};

pub const SettingsWindow = struct {
    allocator: std.mem.Allocator,
    window: *gtk.ApplicationWindow,
    stack: *gtk.Stack,

    shared: common.Config, // dkde.conf
    panel: common.Config, // panel.conf
    term: common.Config, // term.conf

    bindings: std.ArrayList(*Binding) = .empty,
    /// Config group names that bindings point at; freed with the window.
    strings: std.ArrayList([:0]u8) = .empty,
    /// Installed apps, for the pickers.
    apps: std.ArrayList(*gio.AppInfo) = .empty,
    pinned: std.ArrayList([]u8) = .empty,
    /// Names of the icon themes in the Appearance drop-down, in order.
    icon_themes: std.ArrayList([:0]u8) = .empty,
    pinned_box: ?*gtk.Box = null,
    profile_box: ?*gtk.Box = null,
    /// The previews in the profile cards; they follow the staged values.
    term_previews: std.ArrayList(*termpreview.TermPreview) = .empty,
    profile_name: ?[]u8 = null,
    debounce_source: c_uint = 0,
    /// The sound tool that answered, found when the Sound page is built.
    audio_backend: ?audio.Backend = null,
    accounts_list: ?*gtk.ListBox = null,
    /// The Sound page runs external tools, so it is built on first visit.
    audio_built: bool = false,
    sidebar: ?*gtk.ListBox = null,
    /// The bar above a page: back to its category, and where you are.
    crumb_bar: *gtk.Box = undefined,
    crumb_label: *gtk.Label = undefined,
    /// The page being shown, or null while a category's list is shown.
    current_sub: ?usize = null,
    current_cat: usize = 0,
    /// Set while the code selects a sidebar row itself.
    nav_busy: bool = false,
    search_text: [64]u8 = undefined,
    search_len: usize = 0,
    account_names: std.ArrayList([:0]u8) = .empty,
    selected_account: ?usize = null,
    /// The bar that appears when settings are changed but not applied.
    apply_bar: *gtk.Box = undefined,
    apply_label: *gtk.Label = undefined,

    pub fn create(allocator: std.mem.Allocator, app: *gtk.Application) !*SettingsWindow {
        const self = try allocator.create(SettingsWindow);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .window = gtk.ApplicationWindow.new(app),
            .stack = gtk.Stack.new(),
            .shared = try common.Config.load(allocator, "dkde.conf"),
            .panel = try common.Config.load(allocator, "panel.conf"),
            .term = try common.Config.load(allocator, "term.conf"),
        };
        self.loadApps();
        // Changes are held until Apply: the files are not written before.
        self.shared.stage(SettingsWindow, onStaged, self);
        self.panel.stage(SettingsWindow, onStaged, self);
        self.term.stage(SettingsWindow, onStaged, self);

        const window = self.window;
        window.as(gtk.Window).setTitle(common.tr("Settings"));
        window.as(gtk.Window).setDefaultSize(980, 680);
        window.as(gtk.Widget).addCssClass("dkde");
        _ = common.header.create(window.as(gtk.Window), "preferences-system", true);

        const sidebar = gtk.ListBox.new();
        self.sidebar = sidebar;
        sidebar.as(gtk.Widget).addCssClass("navigation-sidebar");
        inline for (sections) |page| {
            const row = gtk.Box.new(.horizontal, 12);
            row.as(gtk.Widget).setMarginTop(8);
            row.as(gtk.Widget).setMarginBottom(8);
            row.as(gtk.Widget).setMarginStart(8);
            row.append(gtk.Image.newFromIconName(page.icon).as(gtk.Widget));
            const label = gtk.Label.new(common.tr(page.title));
            label.setXalign(0);
            row.append(label.as(gtk.Widget));
            sidebar.append(row.as(gtk.Widget));
        }
        sidebar.setFilterFunc(filterPages, self, null);
        _ = gtk.ListBox.signals.row_selected.connect(sidebar, *SettingsWindow, &onCategory, self, .{});

        self.addEagerPages();

        const scroller = gtk.ScrolledWindow.new();
        scroller.setChild(self.stack.as(gtk.Widget));
        scroller.as(gtk.Widget).setHexpand(1);
        scroller.as(gtk.Widget).addCssClass("dkde-settings-content");

        const crumb_bar = gtk.Box.new(.horizontal, 8);
        crumb_bar.as(gtk.Widget).setMarginTop(8);
        crumb_bar.as(gtk.Widget).setMarginStart(16);
        const back = gtk.Button.newFromIconName("go-previous-symbolic");
        back.as(gtk.Widget).addCssClass("flat");
        back.as(gtk.Widget).setTooltipText(common.tr("Back"));
        _ = gtk.Button.signals.clicked.connect(back, *SettingsWindow, &onBack, self, .{});
        crumb_bar.append(back.as(gtk.Widget));
        self.crumb_label = gtk.Label.new("");
        self.crumb_label.as(gtk.Widget).addCssClass("dim-label");
        crumb_bar.append(self.crumb_label.as(gtk.Widget));
        crumb_bar.as(gtk.Widget).setVisible(0);
        self.crumb_bar = crumb_bar;
        const content = gtk.Box.new(.vertical, 0);
        content.append(crumb_bar.as(gtk.Widget));
        scroller.as(gtk.Widget).setVexpand(1);
        content.append(scroller.as(gtk.Widget));
        content.as(gtk.Widget).setHexpand(1);

        const paned = gtk.Paned.new(.horizontal);
        const side_scroller = gtk.ScrolledWindow.new();
        side_scroller.setChild(sidebar.as(gtk.Widget));
        side_scroller.as(gtk.Widget).setVexpand(1);

        // Left column: who you are, a search box, then the categories.
        const side = gtk.Box.new(.vertical, 8);
        side.as(gtk.Widget).addCssClass("dkde-settings-side");
        side.as(gtk.Widget).setSizeRequest(260, -1);
        side.append(self.profileCard().as(gtk.Widget));
        const search = gtk.SearchEntry.new();
        search.setPlaceholderText(common.tr("Find a setting"));
        search.as(gtk.Widget).setMarginStart(8);
        search.as(gtk.Widget).setMarginEnd(8);
        _ = gtk.SearchEntry.signals.search_changed.connect(search, *SettingsWindow, &onSearch, self, .{});
        side.append(search.as(gtk.Widget));
        side.append(side_scroller.as(gtk.Widget));
        paned.setStartChild(side.as(gtk.Widget));
        paned.setEndChild(content.as(gtk.Widget));
        paned.setShrinkStartChild(0);
        paned.setResizeStartChild(0);
        paned.as(gtk.Widget).setVexpand(1);

        // The Apply bar, shown only while there is something to apply.
        self.apply_bar = gtk.Box.new(.horizontal, 8);
        self.apply_bar.as(gtk.Widget).addCssClass("dkde-apply-bar");
        self.apply_bar.as(gtk.Widget).setMarginTop(8);
        self.apply_bar.as(gtk.Widget).setMarginBottom(8);
        self.apply_bar.as(gtk.Widget).setMarginStart(16);
        self.apply_bar.as(gtk.Widget).setMarginEnd(16);
        self.apply_label = gtk.Label.new("");
        self.apply_label.setXalign(0);
        self.apply_label.as(gtk.Widget).setHexpand(1);
        self.apply_bar.append(self.apply_label.as(gtk.Widget));
        const revert = gtk.Button.newWithLabel(common.tr("Revert"));
        const apply = gtk.Button.newWithLabel(common.tr("Apply"));
        apply.as(gtk.Widget).addCssClass("suggested-action");
        _ = gtk.Button.signals.clicked.connect(revert, *SettingsWindow, &onRevert, self, .{});
        _ = gtk.Button.signals.clicked.connect(apply, *SettingsWindow, &onApply, self, .{});
        self.apply_bar.append(revert.as(gtk.Widget));
        self.apply_bar.append(apply.as(gtk.Widget));
        self.apply_bar.as(gtk.Widget).setVisible(0);

        const body = gtk.Box.new(.vertical, 0);
        body.append(paned.as(gtk.Widget));
        body.append(gtk.Separator.new(.horizontal).as(gtk.Widget));
        body.append(self.apply_bar.as(gtk.Widget));
        window.as(gtk.Window).setChild(body.as(gtk.Widget));

        _ = gtk.Window.signals.close_request.connect(window.as(gtk.Window), *SettingsWindow, &onCloseRequest, self, .{});
        _ = gtk.Widget.signals.destroy.connect(window, *SettingsWindow, &onDestroy, self, .{});
        if (sidebar.getRowAtIndex(0)) |row| sidebar.selectRow(row);
        return self;
    }

    /// The pages whose settings are plain config values.
    fn addEagerPages(self: *SettingsWindow) void {
        _ = self.stack.addNamed(self.appearancePage().as(gtk.Widget), "appearance");
        _ = self.stack.addNamed(self.taskbarPage().as(gtk.Widget), "taskbar");
        _ = self.stack.addNamed(self.startMenuPage().as(gtk.Widget), "startmenu");
        _ = self.stack.addNamed(self.terminalPage().as(gtk.Widget), "terminal");
        _ = self.stack.addNamed(self.keyboardPage().as(gtk.Widget), "keyboard");
        _ = self.stack.addNamed(self.mousePage().as(gtk.Widget), "mouse");
        _ = self.stack.addNamed(self.defaultsPage().as(gtk.Widget), "defaults");
        _ = self.stack.addNamed(self.userPage().as(gtk.Widget), "users");
    }

    // ---- Apply and Revert ------------------------------------------------

    fn pendingCount(self: *const SettingsWindow) usize {
        return self.shared.pendingCount() + self.panel.pendingCount() + self.term.pendingCount();
    }

    fn onStaged(self: *SettingsWindow) void {
        for (self.term_previews.items) |p| p.refresh();
        const n = self.pendingCount();
        self.apply_bar.as(gtk.Widget).setVisible(@intFromBool(n > 0));
        var buf: [96]u8 = undefined;
        self.apply_label.setText(std.fmt.bufPrintSentinel(&buf, "{d} change{s} not applied yet", .{ n, if (n == 1) "" else "s" }, 0) catch "");
    }

    /// Writes every pending change; returns false if a file could not be written.
    fn applyAll(self: *SettingsWindow) bool {
        var ok = true;
        for ([_]*common.Config{ &self.shared, &self.panel, &self.term }) |cfg| {
            cfg.apply() catch {
                ok = false;
            };
        }
        if (!ok) common.dialogs.showError(self.window.as(gtk.Window), common.tr("Cannot save the settings"), common.tr("A settings file could not be written. Your changes are still pending."));
        return ok;
    }

    fn onApply(_: *gtk.Button, self: *SettingsWindow) callconv(.c) void {
        _ = self.applyAll();
    }

    fn onRevert(_: *gtk.Button, self: *SettingsWindow) callconv(.c) void {
        self.revertAll();
    }

    /// Forgets the pending changes and shows the saved values again.
    fn revertAll(self: *SettingsWindow) void {
        for ([_]*common.Config{ &self.shared, &self.panel, &self.term }) |cfg| cfg.discard() catch {};
        // The controls still show the unapplied values: build the pages again.
        const sidebar = self.sidebar orelse return;
        while (self.stack.as(gtk.Widget).getFirstChild()) |child| self.stack.remove(child);
        self.audio_built = false;
        self.addEagerPages();
        _ = sidebar;
        if (self.current_sub) |i| self.openSub(i) else self.openCategory(self.current_cat);
    }

    fn onCloseRequest(_: *gtk.Window, self: *SettingsWindow) callconv(.c) c_int {
        if (self.pendingCount() == 0) return 0;
        common.dialogs.choose(
            self.window.as(gtk.Window),
            common.tr("Apply your changes?"),
            common.tr("Some settings have been changed but not applied."),
            &.{ "Cancel", "Discard", "Apply" },
            0,
            SettingsWindow,
            onCloseAnswer,
            self,
        );
        return 1;
    }

    fn onCloseAnswer(self: *SettingsWindow, index: c_int) void {
        switch (index) {
            1 => {
                for ([_]*common.Config{ &self.shared, &self.panel, &self.term }) |cfg| cfg.discard() catch {};
                self.window.as(gtk.Window).close();
            },
            2 => if (self.applyAll()) self.window.as(gtk.Window).close(),
            else => {},
        }
    }

    /// The account card at the top of the navigation, like Windows 11's.
    fn profileCard(self: *SettingsWindow) *gtk.Box {
        const card = gtk.Box.new(.horizontal, 12);
        card.as(gtk.Widget).addCssClass("dkde-profile-card");
        const avatar = gtk.Image.new();
        avatar.setPixelSize(48);
        avatar.as(gtk.Widget).addCssClass("dkde-avatar");
        self.showPicture(avatar);
        card.append(avatar.as(gtk.Widget));

        const texts = gtk.Box.new(.vertical, 0);
        texts.as(gtk.Widget).setValign(.center);
        const name = gtk.Label.new(common.user.displayName());
        name.setXalign(0);
        name.as(gtk.Widget).addCssClass("dkde-profile-name");
        const kind = gtk.Label.new(if (common.user.currentUserIsAdmin(self.allocator)) common.tr("Administrator") else common.tr("Local account"));
        kind.setXalign(0);
        kind.as(gtk.Widget).addCssClass("dkde-setting-desc");
        texts.append(name.as(gtk.Widget));
        texts.append(kind.as(gtk.Widget));
        card.append(texts.as(gtk.Widget));
        return card;
    }

    fn matches(self: *const SettingsWindow, title: []const u8) bool {
        return self.search_len == 0 or std.ascii.findIgnoreCase(title, self.search_text[0..self.search_len]) != null;
    }

    /// A category shows while searching if it or any of its pages matches.
    fn filterPages(row: *gtk.ListBoxRow, data: ?*anyopaque) callconv(.c) c_int {
        const self: *SettingsWindow = @ptrCast(@alignCast(data.?));
        if (self.search_len == 0) return 1;
        const index: usize = @intCast(row.getIndex());
        if (index >= sections.len) return 1;
        if (self.matches(sections[index].title)) return 1;
        for (pages) |p| if (p.category == index and self.matches(p.title)) return 1;
        return 0;
    }

    fn onSearch(entry: *gtk.SearchEntry, self: *SettingsWindow) callconv(.c) void {
        const text = std.mem.span(entry.as(gtk.Editable).getText());
        self.search_len = @min(text.len, self.search_text.len);
        @memcpy(self.search_text[0..self.search_len], text[0..self.search_len]);
        if (self.sidebar) |sb| sb.invalidateFilter();
        // A category list shows only the pages that match.
        if (self.current_sub == null) self.openCategory(self.current_cat);
    }

    /// Opens the page with this id (`users`, `taskbar`, ...) or the category
    /// with this id; unknown ids are ignored.
    pub fn showPage(self: *SettingsWindow, id: []const u8) void {
        for (pages, 0..) |page, i| {
            if (!std.mem.eql(u8, page.id, id)) continue;
            self.selectCategory(page.category);
            self.openSub(i);
            return;
        }
        for (sections, 0..) |c, i| {
            if (!std.mem.eql(u8, c.id, id)) continue;
            self.selectCategory(i);
            self.openCategory(i);
        }
    }

    fn selectCategory(self: *SettingsWindow, index: usize) void {
        const sidebar = self.sidebar orelse return;
        self.nav_busy = true;
        defer self.nav_busy = false;
        if (sidebar.getRowAtIndex(@intCast(index))) |row| sidebar.selectRow(row);
    }

    pub fn present(self: *SettingsWindow) void {
        self.window.as(gtk.Window).present();
    }

    fn onDestroy(_: *gtk.ApplicationWindow, self: *SettingsWindow) callconv(.c) void {
        if (self.debounce_source != 0) _ = glib.Source.remove(self.debounce_source);
        for (self.bindings.items) |b| self.allocator.destroy(b);
        self.bindings.deinit(self.allocator);
        for (self.account_names.items) |n| self.allocator.free(n);
        self.account_names.deinit(self.allocator);
        for (self.icon_themes.items) |t| self.allocator.free(t);
        self.icon_themes.deinit(self.allocator);
        for (self.strings.items) |str| self.allocator.free(str);
        self.strings.deinit(self.allocator);
        for (self.apps.items) |a| a.as(gobject.Object).unref();
        self.apps.deinit(self.allocator);
        common.state.freeList(self.allocator, &self.pinned);
        if (self.profile_name) |n| self.allocator.free(n);
        self.shared.deinit();
        self.panel.deinit();
        self.term.deinit();
        self.allocator.destroy(self);
    }

    fn onCategory(_: *gtk.ListBox, row: ?*gtk.ListBoxRow, self: *SettingsWindow) callconv(.c) void {
        if (self.nav_busy) return;
        const r = row orelse return;
        const index: usize = @intCast(r.getIndex());
        if (index >= sections.len) return;
        self.openCategory(index);
    }

    fn onBack(_: *gtk.Button, self: *SettingsWindow) callconv(.c) void {
        self.openCategory(self.current_cat);
    }

    /// The list of a category's pages, each with its icon and a line on what it is for.
    fn openCategory(self: *SettingsWindow, index: usize) void {
        self.current_cat = index;
        self.current_sub = null;
        self.crumb_bar.as(gtk.Widget).setVisible(0);

        // Built again each time, so a search narrows it.
        var name_buf: [64]u8 = undefined;
        const name = std.fmt.bufPrintSentinel(&name_buf, "cat:{s}", .{sections[index].id}, 0) catch return;
        if (self.stack.getChildByName(name)) |old| self.stack.remove(old);

        const page = newPage(sections[index].title);
        for (pages, 0..) |p, i| {
            if (p.category != index) continue;
            if (!self.matches(p.title) and !self.matches(sections[index].title)) continue;
            const button = gtk.Button.new();
            button.as(gtk.Widget).addCssClass("flat");
            button.as(gtk.Widget).addCssClass("dkde-setting-row");
            const row = gtk.Box.new(.horizontal, 12);
            row.append(gtk.Image.newFromIconName(p.icon).as(gtk.Widget));
            const texts = gtk.Box.new(.vertical, 2);
            texts.as(gtk.Widget).setHexpand(1);
            const title = gtk.Label.new(p.title);
            title.setXalign(0);
            texts.append(title.as(gtk.Widget));
            const sub = gtk.Label.new(p.desc);
            sub.setXalign(0);
            sub.setWrap(1);
            sub.as(gtk.Widget).addCssClass("dkde-setting-desc");
            texts.append(sub.as(gtk.Widget));
            row.append(texts.as(gtk.Widget));
            row.append(gtk.Image.newFromIconName("go-next-symbolic").as(gtk.Widget));
            button.setChild(row.as(gtk.Widget));
            const ctx = self.allocator.create(OpenCtx) catch continue;
            ctx.* = .{ .window = self, .index = i };
            _ = gtk.Button.signals.clicked.connect(button, *OpenCtx, &onOpenPage, ctx, .{});
            _ = gtk.Widget.signals.destroy.connect(button, *OpenCtx, &onOpenDestroy, ctx, .{});
            page.append(button.as(gtk.Widget));
        }
        _ = self.stack.addNamed(page.as(gtk.Widget), name);
        self.stack.setVisibleChildName(name);
    }

    const OpenCtx = struct { window: *SettingsWindow, index: usize };

    fn onOpenPage(_: *gtk.Button, ctx: *OpenCtx) callconv(.c) void {
        ctx.window.openSub(ctx.index);
    }

    fn onOpenDestroy(_: *gtk.Button, ctx: *OpenCtx) callconv(.c) void {
        ctx.window.allocator.destroy(ctx);
    }

    /// Shows one page, with the way back to its category above it.
    fn openSub(self: *SettingsWindow, index: usize) void {
        if (index >= pages.len) return;
        const id = pages[index].id;
        if (std.mem.eql(u8, id, "audio") and !self.audio_built) {
            self.audio_built = true;
            _ = self.stack.addNamed(self.audioPage().as(gtk.Widget), "audio");
        }
        // These pages run external tools, so they are built on first visit.
        if (self.stack.getChildByName(id) == null) {
            const built: ?*gtk.Box = if (std.mem.eql(u8, id, "display"))
                hwpages.DisplayPage.build(self)
            else if (std.mem.eql(u8, id, "network"))
                hwpages.NetworkPage.build(self)
            else if (std.mem.eql(u8, id, "bluetooth"))
                hwpages.BluetoothPage.build(self)
            else if (std.mem.eql(u8, id, "shortcuts"))
                hwpages.ShortcutsPage.build(self)
            else if (std.mem.eql(u8, id, "console"))
                consolepage.ConsolePage.build(self)
            else if (std.mem.eql(u8, id, "power"))
                hwpages.PowerPage.build(self)
            else if (std.mem.eql(u8, id, "datetime"))
                hwpages.DateTimePage.build(self)
            else if (std.mem.eql(u8, id, "printers"))
                hwpages.PrintersPage.build(self)
            else
                null;
            if (built) |b| _ = self.stack.addNamed(b.as(gtk.Widget), id);
        }
        self.current_sub = index;
        self.current_cat = pages[index].category;
        var buf: [160]u8 = undefined;
        self.crumb_label.setText(std.fmt.bufPrintSentinel(&buf, "{s}  \u{203A}  {s}", .{ sections[pages[index].category].title, pages[index].title }, 0) catch "");
        self.crumb_bar.as(gtk.Widget).setVisible(1);
        self.stack.setVisibleChildName(id);
    }

    // ---- page building blocks -------------------------------------------

    pub fn newPage(title: [:0]const u8) *gtk.Box {
        const page = gtk.Box.new(.vertical, 12);
        const widget = page.as(gtk.Widget);
        widget.setMarginTop(20);
        widget.setMarginBottom(20);
        widget.setMarginStart(24);
        widget.setMarginEnd(24);
        const heading = gtk.Label.new(title);
        heading.setXalign(0);
        heading.as(gtk.Widget).addCssClass("dkde-page-title");
        page.append(heading.as(gtk.Widget));
        return page;
    }

    pub fn addRow(page: *gtk.Box, label: [:0]const u8, control: *gtk.Widget) void {
        addRowDesc(page, label, null, control);
    }

    /// A setting card: the name, an optional one-line explanation underneath
    /// it, and the control at the right (as in Windows 11).
    pub fn addRowDesc(page: *gtk.Box, label: [:0]const u8, desc: ?[:0]const u8, control: *gtk.Widget) void {
        const row = gtk.Box.new(.horizontal, 12);
        row.as(gtk.Widget).addCssClass("dkde-setting-row");
        const texts = gtk.Box.new(.vertical, 2);
        texts.as(gtk.Widget).setHexpand(1);
        texts.as(gtk.Widget).setValign(.center);
        const text = gtk.Label.new(label);
        text.setXalign(0);
        texts.append(text.as(gtk.Widget));
        if (desc) |d| {
            const sub = gtk.Label.new(d);
            sub.setXalign(0);
            sub.setWrap(1);
            sub.as(gtk.Widget).addCssClass("dkde-setting-desc");
            texts.append(sub.as(gtk.Widget));
        }
        row.append(texts.as(gtk.Widget));
        control.setValign(.center);
        row.append(control);
        page.append(row.as(gtk.Widget));
    }

    fn bind(self: *SettingsWindow, config: *common.Config, group: [:0]const u8, key: [:0]const u8) *Binding {
        const b = self.allocator.create(Binding) catch @panic("OOM");
        b.* = .{ .window = self, .config = config, .group = group, .key = key };
        self.bindings.append(self.allocator, b) catch @panic("OOM");
        return b;
    }

    pub fn textEntry(self: *SettingsWindow, config: *common.Config, group: [:0]const u8, key: [:0]const u8, default: []const u8) *gtk.Entry {
        const entry = gtk.Entry.new();
        const value = config.getString(self.allocator, group, key, default) catch null;
        defer if (value) |v| self.allocator.free(v);
        var buf: [512]u8 = undefined;
        entry.as(gtk.Editable).setText(std.fmt.bufPrintSentinel(&buf, "{s}", .{value orelse default}, 0) catch "");
        entry.as(gtk.Widget).setSizeRequest(260, -1);
        _ = gtk.Editable.signals.changed.connect(entry, *Binding, &onEntryChanged, self.bind(config, group, key), .{});
        return entry;
    }

    fn onEntryChanged(entry: *gtk.Entry, b: *Binding) callconv(.c) void {
        const text = std.mem.span(entry.as(gtk.Editable).getText());
        b.config.setString(b.group, b.key, text) catch |err| log.warn("cannot save {s}: {s}", .{ b.key, @errorName(err) });
    }

    pub fn spin(self: *SettingsWindow, config: *common.Config, group: [:0]const u8, key: [:0]const u8, min: f64, max: f64, default: i32) *gtk.SpinButton {
        const button = gtk.SpinButton.newWithRange(min, max, 1);
        button.setValue(@floatFromInt(config.getInt(group, key, default)));
        _ = gtk.SpinButton.signals.value_changed.connect(button, *Binding, &onSpinChanged, self.bind(config, group, key), .{});
        return button;
    }

    fn onSpinChanged(button: *gtk.SpinButton, b: *Binding) callconv(.c) void {
        b.config.setInt(b.group, b.key, button.getValueAsInt()) catch |err| log.warn("cannot save {s}: {s}", .{ b.key, @errorName(err) });
    }

    pub fn toggle(self: *SettingsWindow, config: *common.Config, group: [:0]const u8, key: [:0]const u8, default: bool) *gtk.Switch {
        const sw = gtk.Switch.new();
        sw.setActive(@intFromBool(config.getBool(group, key, default)));
        _ = gtk.Switch.signals.state_set.connect(sw, *Binding, &onSwitch, self.bind(config, group, key), .{});
        return sw;
    }

    fn onSwitch(_: *gtk.Switch, state: c_int, b: *Binding) callconv(.c) c_int {
        b.config.setBool(b.group, b.key, state != 0) catch |err| log.warn("cannot save {s}: {s}", .{ b.key, @errorName(err) });
        return 0; // let GTK update the switch
    }

    /// A dropdown over fixed string `options`, stored by name.
    fn choice(self: *SettingsWindow, config: *common.Config, group: [:0]const u8, key: [:0]const u8, comptime options: []const [:0]const u8, default: []const u8) *gtk.DropDown {
        const terminated = comptime blk: {
            var t: [options.len + 1]?[*:0]const u8 = undefined;
            for (options, 0..) |o, i| t[i] = o.ptr;
            t[options.len] = null;
            break :blk t;
        };
        const dropdown = gtk.DropDown.newFromStrings(@ptrCast(&terminated));

        const current = config.getString(self.allocator, group, key, default) catch null;
        defer if (current) |c| self.allocator.free(c);
        inline for (options, 0..) |o, i| {
            if (std.mem.eql(u8, current orelse default, o)) dropdown.setSelected(i);
        }

        const Picker = struct {
            fn onSelected(dd: *gtk.DropDown, _: *gobject.ParamSpec, b: *Binding) callconv(.c) void {
                const index = dd.getSelected();
                if (index >= options.len) return;
                inline for (options, 0..) |o, i| {
                    if (index == i) b.config.setString(b.group, b.key, o) catch {};
                }
            }
        };
        _ = gobject.Object.signals.notify.connect(dropdown, *Binding, &Picker.onSelected, self.bind(config, group, key), .{ .detail = "selected" });
        return dropdown;
    }

    fn fontButton(self: *SettingsWindow, config: *common.Config, group: [:0]const u8, key: [:0]const u8, default: []const u8) *gtk.FontDialogButton {
        const button = gtk.FontDialogButton.new(gtk.FontDialog.new());
        const current = config.getString(self.allocator, group, key, default) catch null;
        defer if (current) |c| self.allocator.free(c);
        if (self.allocator.dupeSentinel(u8, current orelse default, 0)) |z| {
            defer self.allocator.free(z);
            const desc = pango.FontDescription.fromString(z);
            button.setFontDesc(desc);
            desc.free();
        } else |_| {}
        _ = gobject.Object.signals.notify.connect(button, *Binding, &onFont, self.bind(config, group, key), .{ .detail = "font-desc" });
        return button;
    }

    // ---- appearance ------------------------------------------------------

    fn appearancePage(self: *SettingsWindow) *gtk.Box {
        const page = newPage(common.tr("Appearance"));

        addRowDesc(page, common.tr("Dark mode"), "Use a dark colour scheme for dkde apps", self.toggle(&self.shared, "appearance", "dark", false).as(gtk.Widget));

        const accent = gtk.ColorDialogButton.new(gtk.ColorDialog.new());
        var rgba: gdk.RGBA = undefined;
        const current = self.shared.getString(self.allocator, "appearance", "accent", common.style.default_accent) catch null;
        defer if (current) |c| self.allocator.free(c);
        var cbuf: [64]u8 = undefined;
        const current_z = std.fmt.bufPrintSentinel(&cbuf, "{s}", .{current orelse common.style.default_accent}, 0) catch common.style.default_accent;
        if (rgba.parse(current_z) != 0) accent.setRgba(&rgba);
        _ = gobject.Object.signals.notify.connect(accent, *Binding, &onAccent, self.bind(&self.shared, "appearance", "accent"), .{ .detail = "rgba" });
        addRowDesc(page, common.tr("Accent colour"), "Used for the Start button, selections and highlights", accent.as(gtk.Widget));

        addRowDesc(page, common.tr("Icon theme"), "The icons used by dkde apps and the taskbar", self.iconThemePicker().as(gtk.Widget));

        const font = gtk.FontDialogButton.new(gtk.FontDialog.new());
        font.setLevel(.family);
        const font_name = self.shared.getString(self.allocator, "appearance", "font", "") catch null;
        defer if (font_name) |f| self.allocator.free(f);
        if (font_name != null and font_name.?.len > 0) {
            const z = self.allocator.dupeSentinel(u8, font_name.?, 0) catch null;
            defer if (z) |zz| self.allocator.free(zz);
            if (z) |zz| {
                const desc = pango.FontDescription.fromString(zz);
                font.setFontDesc(desc);
                desc.free();
            }
        }
        _ = gobject.Object.signals.notify.connect(font, *Binding, &onFont, self.bind(&self.shared, "appearance", "font"), .{ .detail = "font-desc" });
        addRowDesc(page, common.tr("Interface font"), "The font dkde apps use for their text", font.as(gtk.Widget));

        const wallpaper = self.textEntry(&self.panel, "wallpaper", "image", "");
        const browse = gtk.Button.newWithLabel(common.tr("Browse…"));
        _ = gtk.Button.signals.clicked.connect(browse, *Binding, &onBrowseWallpaper, self.bind(&self.panel, "wallpaper", "image"), .{});
        const wallpaper_row = gtk.Box.new(.horizontal, 6);
        wallpaper_row.append(wallpaper.as(gtk.Widget));
        wallpaper_row.append(browse.as(gtk.Widget));
        addRowDesc(page, common.tr("Wallpaper image"), "A picture for the desktop background", wallpaper_row.as(gtk.Widget));

        addRowDesc(page, common.tr("Wallpaper colour"), "Shown behind the picture, or on its own", self.textEntry(&self.panel, "wallpaper", "color", "#3a6ea5").as(gtk.Widget));
        addRowDesc(page, common.tr("Wallpaper fit"), "How the picture fills the screen", self.choice(&self.panel, "wallpaper", "fit", &.{ "cover", "contain", "fill", "center" }, "cover").as(gtk.Widget));

        const slide_dir = self.textEntry(&self.panel, "wallpaper", "slideshow-dir", "");
        const slide_browse = gtk.Button.newWithLabel(common.tr("Browse…"));
        _ = gtk.Button.signals.clicked.connect(slide_browse, *Binding, &onBrowseFolder, self.bind(&self.panel, "wallpaper", "slideshow-dir"), .{});
        const slide_row = gtk.Box.new(.horizontal, 6);
        slide_row.append(slide_dir.as(gtk.Widget));
        slide_row.append(slide_browse.as(gtk.Widget));
        addRowDesc(page, common.tr("Slideshow folder"), "Cycle through the pictures in a folder", slide_row.as(gtk.Widget));
        addRow(page, common.tr("Change picture every (minutes)"), self.spin(&self.panel, "wallpaper", "slideshow-minutes", 0, 1440, 10).as(gtk.Widget));
        const hint = gtk.Label.new(common.tr("A slideshow folder replaces the single wallpaper image. 0 minutes keeps the first picture."));
        hint.setXalign(0);
        hint.setWrap(1);
        hint.as(gtk.Widget).addCssClass("dim-label");
        page.append(hint.as(gtk.Widget));
        return page;
    }

    /// A drop-down of the installed icon themes; the first entry means "system default".
    fn iconThemePicker(self: *SettingsWindow) *gtk.DropDown {
        const names = common.icons.list(self.allocator) catch &.{};
        defer common.icons.free(self.allocator, @constCast(names));
        const list = gtk.StringList.new(null);
        list.append(common.tr("System default"));
        for (self.icon_themes.items) |t| self.allocator.free(t);
        self.icon_themes.clearRetainingCapacity();
        const current = self.shared.getString(self.allocator, "appearance", "icon-theme", "") catch null;
        defer if (current) |c| self.allocator.free(c);
        var selected: c_uint = 0;
        for (names, 0..) |n, i| {
            const z = self.allocator.dupeSentinel(u8, n, 0) catch continue;
            self.icon_themes.append(self.allocator, z) catch {
                self.allocator.free(z);
                continue;
            };
            list.append(z.ptr);
            if (current != null and std.mem.eql(u8, current.?, n)) selected = @intCast(i + 1);
        }
        const dd = gtk.DropDown.new(list.as(gio.ListModel), null);
        dd.setSelected(selected);
        _ = gobject.Object.signals.notify.connect(dd, *Binding, &onIconTheme, self.bind(&self.shared, "appearance", "icon-theme"), .{ .detail = "selected" });
        return dd;
    }

    fn onIconTheme(dd: *gtk.DropDown, _: *gobject.ParamSpec, b: *Binding) callconv(.c) void {
        const index = dd.getSelected();
        const value: [:0]const u8 = if (index == 0 or index - 1 >= b.window.icon_themes.items.len) "" else b.window.icon_themes.items[index - 1];
        b.config.setString(b.group, b.key, value) catch {};
    }

    fn onAccent(button: *gtk.ColorDialogButton, _: *gobject.ParamSpec, b: *Binding) callconv(.c) void {
        const text = button.getRgba().toString();
        defer glib.free(text);
        b.config.setString(b.group, b.key, std.mem.span(text)) catch {};
    }

    fn onFont(button: *gtk.FontDialogButton, _: *gobject.ParamSpec, b: *Binding) callconv(.c) void {
        const desc = button.getFontDesc() orelse return;
        const text = desc.toString();
        defer glib.free(text);
        b.config.setString(b.group, b.key, std.mem.span(text)) catch {};
    }

    fn onBrowseWallpaper(button: *gtk.Button, b: *Binding) callconv(.c) void {
        const dialog = gtk.FileDialog.new();
        defer dialog.as(gobject.Object).unref();
        dialog.setTitle(common.tr("Choose a wallpaper"));
        const parent: ?*gtk.Window = if (button.as(gtk.Widget).getRoot()) |root| @ptrCast(@alignCast(root)) else null;
        dialog.open(parent, null, onWallpaperChosen, b);
    }

    fn onBrowseFolder(button: *gtk.Button, b: *Binding) callconv(.c) void {
        const dialog = gtk.FileDialog.new();
        defer dialog.as(gobject.Object).unref();
        dialog.setTitle(common.tr("Choose a folder"));
        const parent: ?*gtk.Window = if (button.as(gtk.Widget).getRoot()) |root| @ptrCast(@alignCast(root)) else null;
        dialog.selectFolder(parent, null, onFolderChosen, b);
    }

    fn onFolderChosen(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const b: *Binding = @ptrCast(@alignCast(data.?));
        const dialog: *gtk.FileDialog = @ptrCast(@alignCast(source.?));
        var err: ?*glib.Error = null;
        const file = dialog.selectFolderFinish(result, &err) orelse {
            if (err) |e| e.free();
            return;
        };
        defer file.as(gobject.Object).unref();
        const path = file.getPath() orelse return;
        defer glib.free(path);
        b.config.setString(b.group, b.key, std.mem.span(path)) catch {};
    }

    fn onWallpaperChosen(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const b: *Binding = @ptrCast(@alignCast(data.?));
        const dialog: *gtk.FileDialog = @ptrCast(@alignCast(source.?));
        var err: ?*glib.Error = null;
        const file = dialog.openFinish(result, &err) orelse {
            if (err) |e| e.free();
            return;
        };
        defer file.as(gobject.Object).unref();
        const path = file.getPath() orelse return;
        defer glib.free(path);
        b.config.setString(b.group, b.key, std.mem.span(path)) catch {};
    }

    // ---- user ------------------------------------------------------------

    const PictureCtx = struct { window: *SettingsWindow, image: *gtk.Image };

    fn userPage(self: *SettingsWindow) *gtk.Box {
        const page = newPage(common.tr("User"));

        const image = gtk.Image.new();
        image.setPixelSize(96);
        image.as(gtk.Widget).addCssClass("dkde-avatar");
        self.showPicture(image);
        const ctx = self.allocator.create(PictureCtx) catch @panic("OOM");
        ctx.* = .{ .window = self, .image = image };
        const choose = gtk.Button.newWithLabel(common.tr("Choose picture…"));
        _ = gtk.Button.signals.clicked.connect(choose, *PictureCtx, &onChoosePicture, ctx, .{});
        _ = gtk.Widget.signals.destroy.connect(choose, *PictureCtx, &onPictureDestroy, ctx, .{});
        const reset = gtk.Button.newWithLabel(common.tr("Use default"));
        _ = gtk.Button.signals.clicked.connect(reset, *PictureCtx, &onResetPicture, ctx, .{});
        const buttons = gtk.Box.new(.horizontal, 6);
        buttons.append(choose.as(gtk.Widget));
        buttons.append(reset.as(gtk.Widget));
        const column = gtk.Box.new(.vertical, 8);
        column.append(image.as(gtk.Widget));
        column.append(buttons.as(gtk.Widget));
        page.append(column.as(gtk.Widget));

        addRow(page, common.tr("Name"), gtk.Label.new(common.user.displayName()).as(gtk.Widget));
        addRow(page, common.tr("Login"), gtk.Label.new(glib.getUserName()).as(gtk.Widget));
        const admin = common.user.currentUserIsAdmin(self.allocator);
        addRow(page, common.tr("Administrator (sudo)"), gtk.Label.new(if (admin) common.tr("Yes") else common.tr("No")).as(gtk.Widget));

        // Accounts: every change asks for the administrator password.
        const heading = gtk.Label.new(common.tr("Accounts"));
        heading.setXalign(0);
        heading.as(gtk.Widget).addCssClass("heading");
        heading.as(gtk.Widget).setMarginTop(12);
        page.append(heading.as(gtk.Widget));

        const list = gtk.ListBox.new();
        list.as(gtk.Widget).addCssClass("boxed-list");
        _ = gtk.ListBox.signals.row_selected.connect(list, *SettingsWindow, &onAccountSelected, self, .{});
        self.accounts_list = list;
        page.append(list.as(gtk.Widget));

        // A flow box, so the buttons wrap instead of widening the page.
        const actions = gtk.FlowBox.new();
        actions.setSelectionMode(.none);
        actions.setColumnSpacing(6);
        actions.setRowSpacing(6);
        actions.setMaxChildrenPerLine(6);
        for ([_]struct { [:0]const u8, [:0]const u8 }{
            .{ "Add user…", "add" },
            .{ "Groups…", "groups" },
            .{ "Administrator", "admin" },
            .{ "Password…", "password" },
            .{ "Full name…", "name" },
            .{ "Delete…", "delete" },
        }) |entry| {
            const button = gtk.Button.newWithLabel(entry[0]);
            if (std.mem.eql(u8, entry[1], "delete")) button.as(gtk.Widget).addCssClass("destructive-action");
            const action_ctx = self.allocator.create(AccountAction) catch continue;
            action_ctx.* = .{ .window = self, .action = entry[1] };
            _ = gtk.Button.signals.clicked.connect(button, *AccountAction, &onAccountAction, action_ctx, .{});
            _ = gtk.Widget.signals.destroy.connect(button, *AccountAction, &onAccountActionDestroy, action_ctx, .{});
            actions.append(button.as(gtk.Widget));
        }
        page.append(actions.as(gtk.Widget));

        const note = gtk.Label.new(common.tr("Changes ask for your password and need an administrator (sudo) account. The \"Administrator\" button grants or removes administrator rights for the selected account."));
        note.setXalign(0);
        note.setWrap(1);
        note.as(gtk.Widget).addCssClass("dim-label");
        page.append(note.as(gtk.Widget));
        self.rebuildAccounts();
        return page;
    }

    fn showPicture(self: *SettingsWindow, image: *gtk.Image) void {
        if (common.user.picturePath(self.allocator, &self.shared)) |path| {
            defer self.allocator.free(path);
            if (self.allocator.dupeSentinel(u8, path, 0)) |z| {
                defer self.allocator.free(z);
                image.setFromFile(z);
                return;
            } else |_| {}
        }
        image.setFromIconName("avatar-default-symbolic");
    }

    fn onPictureDestroy(_: *gtk.Button, ctx: *PictureCtx) callconv(.c) void {
        ctx.window.allocator.destroy(ctx);
    }

    fn onChoosePicture(button: *gtk.Button, ctx: *PictureCtx) callconv(.c) void {
        const dialog = gtk.FileDialog.new();
        defer dialog.as(gobject.Object).unref();
        dialog.setTitle(common.tr("Choose a profile picture"));
        const parent: ?*gtk.Window = if (button.as(gtk.Widget).getRoot()) |root| @ptrCast(@alignCast(root)) else null;
        dialog.open(parent, null, onPictureChosen, ctx);
    }

    fn onPictureChosen(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const ctx: *PictureCtx = @ptrCast(@alignCast(data.?));
        const dialog: *gtk.FileDialog = @ptrCast(@alignCast(source.?));
        var err: ?*glib.Error = null;
        const file = dialog.openFinish(result, &err) orelse {
            if (err) |e| e.free();
            return;
        };
        defer file.as(gobject.Object).unref();
        const path = file.getPath() orelse return;
        defer glib.free(path);
        ctx.window.shared.setString("user", "picture", std.mem.span(path)) catch return;
        ctx.window.showPicture(ctx.image);
    }

    fn onResetPicture(_: *gtk.Button, ctx: *PictureCtx) callconv(.c) void {
        ctx.window.shared.setString("user", "picture", "") catch return;
        ctx.window.showPicture(ctx.image);
    }

    // ---- accounts ----------------------------------------------------------

    const AccountAction = struct { window: *SettingsWindow, action: []const u8 };

    fn onAccountActionDestroy(_: *gtk.Button, ctx: *AccountAction) callconv(.c) void {
        ctx.window.allocator.destroy(ctx);
    }

    fn onAccountAction(_: *gtk.Button, ctx: *AccountAction) callconv(.c) void {
        ctx.window.accountAction(ctx.action);
    }

    fn onAccountSelected(_: *gtk.ListBox, row: ?*gtk.ListBoxRow, self: *SettingsWindow) callconv(.c) void {
        self.selected_account = if (row) |r| @intCast(r.getIndex()) else null;
    }

    fn readText(self: *SettingsWindow, path: [:0]const u8) ?[]u8 {
        var contents: [*]u8 = undefined;
        var length: usize = 0;
        if (glib.fileGetContents(path, &contents, &length, null) == 0) return null;
        defer glib.free(contents);
        return self.allocator.dupe(u8, contents[0..length]) catch null;
    }

    fn rebuildAccounts(self: *SettingsWindow) void {
        const list = self.accounts_list orelse return;
        while (list.as(gtk.Widget).getFirstChild()) |child| list.remove(child);
        for (self.account_names.items) |n| self.allocator.free(n);
        self.account_names.clearRetainingCapacity();
        self.selected_account = null;

        const passwd = self.readText("/etc/passwd") orelse return;
        defer self.allocator.free(passwd);
        const group_file = self.readText("/etc/group") orelse return;
        defer self.allocator.free(group_file);
        const found = users.parsePasswd(self.allocator, passwd) catch return;
        defer self.allocator.free(found);
        const admin = users.adminGroup(group_file);

        for (found) |u| {
            const is_admin = if (admin) |g| users.isMember(group_file, g, u.name) else false;
            var buf: [256]u8 = undefined;
            const text = std.fmt.bufPrintSentinel(&buf, "{s}{s}{s}{s}", .{
                u.name,
                if (u.full_name.len > 0) "  —  " else "",
                u.full_name,
                if (is_admin) "   [Administrator]" else "",
            }, 0) catch continue;
            const label = gtk.Label.new(text);
            label.setXalign(0);
            label.as(gtk.Widget).setMarginTop(8);
            label.as(gtk.Widget).setMarginBottom(8);
            label.as(gtk.Widget).setMarginStart(10);
            list.append(label.as(gtk.Widget));
            self.account_names.append(self.allocator, self.allocator.dupeSentinel(u8, u.name, 0) catch continue) catch {};
        }
    }

    fn selectedName(self: *SettingsWindow) ?[:0]const u8 {
        const i = self.selected_account orelse return null;
        if (i >= self.account_names.items.len) return null;
        return self.account_names.items[i];
    }

    fn accountAction(self: *SettingsWindow, action: []const u8) void {
        const eql = std.mem.eql;
        if (eql(u8, action, "add")) return self.openForm(.add_user, null, common.tr("Add user"), &.{
            .{ .label = "Username", .kind = .text },
            .{ .label = "Full name", .kind = .text },
            .{ .label = "Password", .kind = .password },
            .{ .label = "Confirm password", .kind = .password },
            .{ .label = "Administrator (sudo)", .kind = .check },
        }, common.tr("Create"));

        const name = self.selectedName() orelse {
            common.dialogs.showError(self.window.as(gtk.Window), common.tr("Select an account first"), null);
            return;
        };
        if (eql(u8, action, "password")) return self.openForm(.set_password, name, common.tr("Change password"), &.{
            .{ .label = "New password", .kind = .password },
            .{ .label = "Confirm password", .kind = .password },
        }, common.tr("Change"));
        if (eql(u8, action, "name")) return self.openForm(.edit_name, name, common.tr("Full name"), &.{
            .{ .label = "Full name", .kind = .text },
        }, common.tr("Save"));
        if (eql(u8, action, "groups")) return self.openGroups(name);
        if (eql(u8, action, "admin")) return self.toggleAdmin(name);
        if (eql(u8, action, "delete")) return self.askDelete(name);
    }

    /// Runs `argv` as root after asking for the password, then refreshes.
    fn elevated(self: *SettingsWindow, reason: []const u8, argv: []const []const u8, stdin_data: []const u8) void {
        common.elevate.run(self.window.as(gtk.Window), reason, argv, stdin_data, SettingsWindow, onElevated, self);
    }

    fn onElevated(self: *SettingsWindow, outcome: common.elevate.Outcome, message: []const u8) void {
        if (outcome == .failed) {
            var buf: [512]u8 = undefined;
            const text = std.fmt.bufPrintSentinel(&buf, "{s}", .{message}, 0) catch "";
            common.dialogs.showError(self.window.as(gtk.Window), common.tr("The change could not be made"), text);
        }
        self.rebuildAccounts();
    }

    fn isSelf(name: []const u8) bool {
        return std.mem.eql(u8, name, std.mem.span(glib.getUserName()));
    }

    fn toggleAdmin(self: *SettingsWindow, name: []const u8) void {
        const group_file = self.readText("/etc/group") orelse return;
        defer self.allocator.free(group_file);
        const group = users.adminGroup(group_file) orelse {
            common.dialogs.showError(self.window.as(gtk.Window), common.tr("No administrator group found"), common.tr("Expected a group named sudo, wheel or admin."));
            return;
        };
        var reason_buf: [200]u8 = undefined;
        if (users.isMember(group_file, group, name)) {
            if (isSelf(name)) {
                common.dialogs.showError(self.window.as(gtk.Window), common.tr("You cannot remove your own administrator rights"), common.tr("Use another administrator account for that, so you cannot lock yourself out."));
                return;
            }
            const reason = std.fmt.bufPrint(&reason_buf, "Remove administrator rights from {s}", .{name}) catch return;
            self.elevated(reason, &.{ "gpasswd", "-d", name, group }, "");
        } else {
            const reason = std.fmt.bufPrint(&reason_buf, "Make {s} an administrator", .{name}) catch return;
            self.elevated(reason, &.{ "usermod", "-aG", group, "--", name }, "");
        }
    }

    const DeleteCtx = struct { window: *SettingsWindow, name: [:0]u8 };

    fn askDelete(self: *SettingsWindow, name: [:0]const u8) void {
        if (isSelf(name) or std.mem.eql(u8, name, "root")) {
            common.dialogs.showError(self.window.as(gtk.Window), common.tr("This account cannot be deleted"), common.tr("You cannot delete the account you are signed in with, or root."));
            return;
        }
        const ctx = std.heap.c_allocator.create(DeleteCtx) catch return;
        ctx.* = .{ .window = self, .name = std.heap.c_allocator.dupeSentinel(u8, name, 0) catch return };
        var buf: [160]u8 = undefined;
        const message = std.fmt.bufPrintSentinel(&buf, "Delete the account \"{s}\"?", .{name}, 0) catch return;
        common.dialogs.choose(
            self.window.as(gtk.Window),
            message,
            common.tr("The account must not be signed in. Deleting its files cannot be undone."),
            &.{ "Cancel", "Delete account, keep files", "Delete account and files" },
            0,
            DeleteCtx,
            onDeleteAnswer,
            ctx,
        );
    }

    fn onDeleteAnswer(ctx: *DeleteCtx, index: c_int) void {
        defer {
            std.heap.c_allocator.free(ctx.name);
            std.heap.c_allocator.destroy(ctx);
        }
        if (index != 1 and index != 2) return;
        var reason_buf: [160]u8 = undefined;
        const reason = std.fmt.bufPrint(&reason_buf, "Delete the account {s}", .{ctx.name}) catch return;
        if (index == 2) {
            ctx.window.elevated(reason, &.{ "userdel", "-r", "--", ctx.name }, "");
        } else ctx.window.elevated(reason, &.{ "userdel", "--", ctx.name }, "");
    }

    // ---- form dialog -------------------------------------------------------

    const FormTag = enum { add_user, set_password, edit_name };
    const FieldKind = enum { text, password, check };
    const Field = struct { label: [:0]const u8, kind: FieldKind, initial: [:0]const u8 = "" };

    const FormCtx = struct {
        window: *SettingsWindow,
        tag: FormTag,
        target: ?[:0]u8,
        dialog: *gtk.Window,
        kinds: [8]FieldKind = undefined,
        widgets: [8]*gtk.Widget = undefined,
        count: usize = 0,
        error_label: *gtk.Label,
    };

    fn openForm(self: *SettingsWindow, tag: FormTag, target: ?[:0]const u8, title: [:0]const u8, fields: []const Field, ok_label: [:0]const u8) void {
        const dialog = gtk.Window.new();
        dialog.setTitle(title);
        dialog.setTransientFor(self.window.as(gtk.Window));
        dialog.setModal(1);
        dialog.setDefaultSize(380, -1);
        dialog.as(gtk.Widget).addCssClass("dkde");

        const box = gtk.Box.new(.vertical, 8);
        box.as(gtk.Widget).setMarginTop(16);
        box.as(gtk.Widget).setMarginBottom(16);
        box.as(gtk.Widget).setMarginStart(16);
        box.as(gtk.Widget).setMarginEnd(16);
        dialog.setChild(box.as(gtk.Widget));

        const ctx = std.heap.c_allocator.create(FormCtx) catch return;
        ctx.* = .{
            .window = self,
            .tag = tag,
            .target = if (target) |t| std.heap.c_allocator.dupeSentinel(u8, t, 0) catch null else null,
            .dialog = dialog,
            .error_label = gtk.Label.new(""),
        };
        for (fields) |f| {
            if (ctx.count >= ctx.widgets.len) break;
            const widget: *gtk.Widget = switch (f.kind) {
                .text => blk: {
                    const e = gtk.Entry.new();
                    e.as(gtk.Editable).setText(f.initial);
                    break :blk e.as(gtk.Widget);
                },
                .password => gtk.PasswordEntry.new().as(gtk.Widget),
                .check => gtk.CheckButton.newWithLabel(f.label).as(gtk.Widget),
            };
            if (f.kind != .check) {
                const l = gtk.Label.new(f.label);
                l.setXalign(0);
                box.append(l.as(gtk.Widget));
            }
            box.append(widget);
            ctx.kinds[ctx.count] = f.kind;
            ctx.widgets[ctx.count] = widget;
            ctx.count += 1;
        }
        ctx.error_label.setXalign(0);
        ctx.error_label.as(gtk.Widget).addCssClass("error");
        box.append(ctx.error_label.as(gtk.Widget));

        const buttons = gtk.Box.new(.horizontal, 8);
        buttons.as(gtk.Widget).setHalign(.end);
        const cancel = gtk.Button.newWithLabel(common.tr("Cancel"));
        const ok = gtk.Button.newWithLabel(ok_label);
        ok.as(gtk.Widget).addCssClass("suggested-action");
        buttons.append(cancel.as(gtk.Widget));
        buttons.append(ok.as(gtk.Widget));
        box.append(buttons.as(gtk.Widget));
        _ = gtk.Button.signals.clicked.connect(cancel, *FormCtx, &onFormCancel, ctx, .{});
        _ = gtk.Button.signals.clicked.connect(ok, *FormCtx, &onFormOk, ctx, .{});
        _ = gtk.Widget.signals.destroy.connect(dialog, *FormCtx, &onFormDestroy, ctx, .{});
        dialog.present();
    }

    fn onFormDestroy(_: *gtk.Window, ctx: *FormCtx) callconv(.c) void {
        if (ctx.target) |t| std.heap.c_allocator.free(t);
        std.heap.c_allocator.destroy(ctx);
    }

    fn onFormCancel(_: *gtk.Button, ctx: *FormCtx) callconv(.c) void {
        ctx.dialog.destroy();
    }

    fn fieldText(ctx: *FormCtx, i: usize) []const u8 {
        return switch (ctx.kinds[i]) {
            .text => std.mem.span(@as(*gtk.Entry, @ptrCast(@alignCast(ctx.widgets[i]))).as(gtk.Editable).getText()),
            .password => std.mem.span(@as(*gtk.PasswordEntry, @ptrCast(@alignCast(ctx.widgets[i]))).as(gtk.Editable).getText()),
            .check => if (@as(*gtk.CheckButton, @ptrCast(@alignCast(ctx.widgets[i]))).getActive() != 0) "yes" else "no",
        };
    }

    fn onFormOk(_: *gtk.Button, ctx: *FormCtx) callconv(.c) void {
        const self = ctx.window;
        const fail = struct {
            fn show(c: *FormCtx, text: [:0]const u8) void {
                c.error_label.setText(text);
            }
        }.show;

        switch (ctx.tag) {
            .add_user => {
                const name = fieldText(ctx, 0);
                const full = fieldText(ctx, 1);
                const pw = fieldText(ctx, 2);
                const pw2 = fieldText(ctx, 3);
                const admin = fieldText(ctx, 4);
                if (!users.isValidUsername(name)) return fail(ctx, common.tr("Use lower-case letters, digits, _ and -, starting with a letter."));
                if (!users.isValidFullName(full)) return fail(ctx, common.tr("The full name cannot contain : or , or control characters."));
                if (pw.len == 0) return fail(ctx, common.tr("Enter a password."));
                if (!std.mem.eql(u8, pw, pw2)) return fail(ctx, common.tr("The passwords do not match."));
                const passwd = self.readText("/etc/passwd") orelse return;
                defer self.allocator.free(passwd);
                const group_file = self.readText("/etc/group") orelse return;
                defer self.allocator.free(group_file);
                const found = users.parsePasswd(self.allocator, passwd) catch return;
                defer self.allocator.free(found);
                if (users.exists(found, name)) return fail(ctx, common.tr("That username is taken."));

                var stdin_buf: [512]u8 = undefined;
                const stdin_data = std.fmt.bufPrint(&stdin_buf, "{s}\n", .{pw}) catch return fail(ctx, common.tr("That password is too long."));
                defer @memset(&stdin_buf, 0);
                var reason_buf: [160]u8 = undefined;
                const reason = std.fmt.bufPrint(&reason_buf, "Create the account {s}", .{name}) catch return;
                const group = users.adminGroup(group_file) orelse "sudo";
                ctx.dialog.as(gtk.Widget).setVisible(0);
                self.elevated(reason, &.{ "sh", "-c", users.add_script, "dkde-adduser", name, full, admin, group }, stdin_data);
            },
            .set_password => {
                const pw = fieldText(ctx, 0);
                if (pw.len == 0) return fail(ctx, common.tr("Enter a password."));
                if (!std.mem.eql(u8, pw, fieldText(ctx, 1))) return fail(ctx, common.tr("The passwords do not match."));
                var stdin_buf: [512]u8 = undefined;
                const stdin_data = std.fmt.bufPrint(&stdin_buf, "{s}\n", .{pw}) catch return fail(ctx, common.tr("That password is too long."));
                defer @memset(&stdin_buf, 0);
                const target = ctx.target orelse return;
                var reason_buf: [160]u8 = undefined;
                const reason = std.fmt.bufPrint(&reason_buf, "Change the password of {s}", .{target}) catch return;
                ctx.dialog.as(gtk.Widget).setVisible(0);
                self.elevated(reason, &.{ "sh", "-c", users.password_script, "dkde-passwd", target }, stdin_data);
            },
            .edit_name => {
                const full = fieldText(ctx, 0);
                if (!users.isValidFullName(full)) return fail(ctx, common.tr("The full name cannot contain : or , or control characters."));
                const target = ctx.target orelse return;
                var reason_buf: [160]u8 = undefined;
                const reason = std.fmt.bufPrint(&reason_buf, "Change the full name of {s}", .{target}) catch return;
                ctx.dialog.as(gtk.Widget).setVisible(0);
                self.elevated(reason, &.{ "usermod", "-c", full, "--", target }, "");
            },
        }
        ctx.dialog.destroy();
    }

    // ---- group membership --------------------------------------------------

    const GroupRow = struct { check: *gtk.CheckButton, name: [:0]u8, was_member: bool };

    const GroupsCtx = struct {
        window: *SettingsWindow,
        user: [:0]u8,
        dialog: *gtk.Window,
        rows: std.ArrayList(GroupRow) = .empty,
        existing: std.ArrayList([:0]u8) = .empty,
        error_label: *gtk.Label,
        new_entry: *gtk.Entry,
    };

    fn openGroups(self: *SettingsWindow, user: [:0]const u8) void {
        const group_file = self.readText("/etc/group") orelse return;
        defer self.allocator.free(group_file);
        const found = users.parseGroups(self.allocator, group_file) catch return;
        defer self.allocator.free(found);

        const c = std.heap.c_allocator;
        const dialog = gtk.Window.new();
        var title_buf: [96]u8 = undefined;
        dialog.setTitle(std.fmt.bufPrintSentinel(&title_buf, "Groups of {s}", .{user}, 0) catch "Groups");
        dialog.setTransientFor(self.window.as(gtk.Window));
        dialog.setModal(1);
        dialog.setDefaultSize(420, 520);
        dialog.as(gtk.Widget).addCssClass("dkde");

        const ctx = c.create(GroupsCtx) catch return;
        ctx.* = .{
            .window = self,
            .user = c.dupeSentinel(u8, user, 0) catch return,
            .dialog = dialog,
            .error_label = gtk.Label.new(""),
            .new_entry = gtk.Entry.new(),
        };

        const box = gtk.Box.new(.vertical, 8);
        box.as(gtk.Widget).setMarginTop(12);
        box.as(gtk.Widget).setMarginBottom(12);
        box.as(gtk.Widget).setMarginStart(12);
        box.as(gtk.Widget).setMarginEnd(12);
        dialog.setChild(box.as(gtk.Widget));

        const hint = gtk.Label.new(common.tr("Tick the groups this account belongs to. Groups you created can be deleted."));
        hint.setXalign(0);
        hint.setWrap(1);
        box.append(hint.as(gtk.Widget));

        const list = gtk.Box.new(.vertical, 2);
        const scroller = gtk.ScrolledWindow.new();
        scroller.setChild(list.as(gtk.Widget));
        scroller.as(gtk.Widget).setVexpand(1);
        box.append(scroller.as(gtk.Widget));

        // People-made groups first, then the system's.
        for ([_]bool{ true, false }) |user_groups| {
            for (found) |g| {
                if (g.isUserGroup() != user_groups) continue;
                const row = gtk.Box.new(.horizontal, 6);
                const name_z = c.dupeSentinel(u8, g.name, 0) catch continue;
                const check = gtk.CheckButton.newWithLabel(name_z);
                check.as(gtk.Widget).setHexpand(1);
                const member = g.has(user);
                check.setActive(@intFromBool(member));
                row.append(check.as(gtk.Widget));
                if (user_groups) {
                    const del = gtk.Button.newFromIconName("user-trash-symbolic");
                    del.setHasFrame(0);
                    del.as(gtk.Widget).setTooltipText(common.tr("Delete this group"));
                    const dctx = c.create(DeleteGroupCtx) catch continue;
                    dctx.* = .{ .groups = ctx, .name = name_z };
                    _ = gtk.Button.signals.clicked.connect(del, *DeleteGroupCtx, &onDeleteGroup, dctx, .{});
                    _ = gtk.Widget.signals.destroy.connect(del, *DeleteGroupCtx, &onDeleteGroupDestroy, dctx, .{});
                    row.append(del.as(gtk.Widget));
                }
                list.append(row.as(gtk.Widget));
                ctx.rows.append(c, .{ .check = check, .name = name_z, .was_member = member }) catch {};
                ctx.existing.append(c, name_z) catch {};
            }
        }

        const new_row = gtk.Box.new(.horizontal, 6);
        ctx.new_entry.setPlaceholderText(common.tr("New group name"));
        ctx.new_entry.as(gtk.Widget).setHexpand(1);
        const create_button = gtk.Button.newWithLabel(common.tr("Create group"));
        _ = gtk.Button.signals.clicked.connect(create_button, *GroupsCtx, &onCreateGroup, ctx, .{});
        new_row.append(ctx.new_entry.as(gtk.Widget));
        new_row.append(create_button.as(gtk.Widget));
        box.append(new_row.as(gtk.Widget));

        ctx.error_label.setXalign(0);
        ctx.error_label.setWrap(1);
        ctx.error_label.as(gtk.Widget).addCssClass("error");
        box.append(ctx.error_label.as(gtk.Widget));

        const buttons = gtk.Box.new(.horizontal, 8);
        buttons.as(gtk.Widget).setHalign(.end);
        const cancel = gtk.Button.newWithLabel(common.tr("Cancel"));
        const apply = gtk.Button.newWithLabel(common.tr("Apply"));
        apply.as(gtk.Widget).addCssClass("suggested-action");
        buttons.append(cancel.as(gtk.Widget));
        buttons.append(apply.as(gtk.Widget));
        box.append(buttons.as(gtk.Widget));
        _ = gtk.Button.signals.clicked.connect(cancel, *GroupsCtx, &onGroupsCancel, ctx, .{});
        _ = gtk.Button.signals.clicked.connect(apply, *GroupsCtx, &onGroupsApply, ctx, .{});
        _ = gtk.Widget.signals.destroy.connect(dialog, *GroupsCtx, &onGroupsDestroy, ctx, .{});
        dialog.present();
    }

    fn onGroupsDestroy(_: *gtk.Window, ctx: *GroupsCtx) callconv(.c) void {
        const c = std.heap.c_allocator;
        for (ctx.rows.items) |row| c.free(row.name);
        ctx.rows.deinit(c);
        ctx.existing.deinit(c);
        c.free(ctx.user);
        c.destroy(ctx);
    }

    fn onGroupsCancel(_: *gtk.Button, ctx: *GroupsCtx) callconv(.c) void {
        ctx.dialog.destroy();
    }

    fn onGroupsApply(_: *gtk.Button, ctx: *GroupsCtx) callconv(.c) void {
        const self = ctx.window;
        const c = std.heap.c_allocator;
        var join: std.ArrayList(u8) = .empty;
        defer join.deinit(c);
        var leave: std.ArrayList(u8) = .empty;
        defer leave.deinit(c);

        const group_file = self.readText("/etc/group") orelse return;
        defer self.allocator.free(group_file);
        const admin = users.adminGroup(group_file);

        for (ctx.rows.items) |row| {
            const now = row.check.getActive() != 0;
            if (now == row.was_member) continue;
            if (!users.isValidGroupName(row.name)) continue;
            if (!now and isSelf(ctx.user) and admin != null and std.mem.eql(u8, row.name, admin.?)) {
                ctx.error_label.setText(common.tr("You cannot remove your own administrator rights; use another administrator account."));
                return;
            }
            const list = if (now) &join else &leave;
            if (list.items.len > 0) list.append(c, ' ') catch return;
            list.appendSlice(c, row.name) catch return;
        }
        if (join.items.len == 0 and leave.items.len == 0) return ctx.dialog.destroy();

        var reason_buf: [160]u8 = undefined;
        const reason = std.fmt.bufPrint(&reason_buf, "Change the groups of {s}", .{ctx.user}) catch return;
        // Copy before the dialog (and its context) goes away.
        const user = self.allocator.dupe(u8, ctx.user) catch return;
        defer self.allocator.free(user);
        ctx.dialog.as(gtk.Widget).setVisible(0);
        self.elevated(reason, &.{ "sh", "-c", users.groups_script, "dkde-groups", user, join.items, leave.items }, "");
        ctx.dialog.destroy();
    }

    fn onCreateGroup(_: *gtk.Button, ctx: *GroupsCtx) callconv(.c) void {
        const self = ctx.window;
        const name = std.mem.span(ctx.new_entry.as(gtk.Editable).getText());
        if (!users.isValidGroupName(name)) {
            ctx.error_label.setText(common.tr("Use lower-case letters, digits, _, - and ., starting with a letter."));
            return;
        }
        for (ctx.existing.items) |e| if (std.mem.eql(u8, e, name)) {
            ctx.error_label.setText(common.tr("That group already exists."));
            return;
        };
        var reason_buf: [160]u8 = undefined;
        const reason = std.fmt.bufPrint(&reason_buf, "Create the group {s}", .{name}) catch return;
        ctx.dialog.as(gtk.Widget).setVisible(0);
        self.elevated(reason, &.{ "groupadd", "--", name }, "");
        ctx.dialog.destroy();
    }

    const DeleteGroupCtx = struct { groups: *GroupsCtx, name: [:0]const u8 };

    fn onDeleteGroupDestroy(_: *gtk.Button, ctx: *DeleteGroupCtx) callconv(.c) void {
        std.heap.c_allocator.destroy(ctx);
    }

    const ConfirmGroupDelete = struct { window: *SettingsWindow, name: [:0]u8 };

    fn onDeleteGroup(_: *gtk.Button, ctx: *DeleteGroupCtx) callconv(.c) void {
        const confirm = std.heap.c_allocator.create(ConfirmGroupDelete) catch return;
        confirm.* = .{ .window = ctx.groups.window, .name = std.heap.c_allocator.dupeSentinel(u8, ctx.name, 0) catch return };
        var buf: [128]u8 = undefined;
        const message = std.fmt.bufPrintSentinel(&buf, "Delete the group \"{s}\"?", .{ctx.name}, 0) catch return;
        common.dialogs.choose(
            ctx.groups.dialog,
            message,
            common.tr("Files owned by this group keep the group's number."),
            &.{ "Cancel", "Delete group" },
            0,
            ConfirmGroupDelete,
            onConfirmGroupDelete,
            confirm,
        );
    }

    fn onConfirmGroupDelete(confirm: *ConfirmGroupDelete, index: c_int) void {
        defer {
            std.heap.c_allocator.free(confirm.name);
            std.heap.c_allocator.destroy(confirm);
        }
        if (index != 1) return;
        var reason_buf: [160]u8 = undefined;
        const reason = std.fmt.bufPrint(&reason_buf, "Delete the group {s}", .{confirm.name}) catch return;
        confirm.window.elevated(reason, &.{ "groupdel", "--", confirm.name }, "");
    }

    // ---- taskbar ---------------------------------------------------------

    fn taskbarPage(self: *SettingsWindow) *gtk.Box {
        const page = newPage(common.tr("Taskbar"));
        addRowDesc(page, common.tr("Position on screen"), "Which edge of the screen the taskbar sits on", self.choice(&self.panel, "panel", "position", &.{ "bottom", "top", "left", "right" }, "bottom").as(gtk.Widget));
        addRowDesc(page, common.tr("Automatically hide"), "Slide the taskbar out of the way; touch the edge to show it", self.toggle(&self.panel, "panel", "autohide", false).as(gtk.Widget));
        addRow(page, common.tr("Size (pixels)"), self.spin(&self.panel, "panel", "height", 24, 120, 40).as(gtk.Widget));
        hwpages.QuickRows.add(self, page);
        {
            const rc = self.readLabwcFile("rc.xml") catch null;
            defer if (rc) |c| self.allocator.free(c);
            var current: f64 = 4;
            if (rc) |c| if (std.mem.indexOf(u8, c, "<desktops>") != null) {
                current = xmlValueFloat(c, "number") orelse 4;
            };
            const spin_button = gtk.SpinButton.newWithRange(1, 9, 1);
            spin_button.setValue(current);
            _ = gtk.SpinButton.signals.value_changed.connect(spin_button, *SettingsWindow, &onDesktopsChanged, self, .{});
            addRowDesc(page, common.tr("Virtual desktops"), "How many desktops to switch between. Ctrl+Alt+Left/Right switches; add Shift to take the window along", spin_button.as(gtk.Widget));
        }
        addRowDesc(page, common.tr("Show desktop icons"), "Needs the panel to be restarted to take effect", self.toggle(&self.panel, "desktop", "icons", true).as(gtk.Widget));
        addRowDesc(page, common.tr("Align desktop icons to grid"), "Off lets icons rest anywhere you drop them", self.toggle(&self.panel, "desktop", "snap-to-grid", true).as(gtk.Widget));
        addRowDesc(page, common.tr("Combine windows of the same app"), "Group an app's windows into one button", self.toggle(&self.panel, "panel", "group-windows", true).as(gtk.Widget));
        addRowDesc(page, common.tr("Show window titles (off for icons only)"), "Turn off for a compact, icons-only taskbar", self.toggle(&self.panel, "panel", "show-labels", true).as(gtk.Widget));
        return page;
    }

    // ---- start menu ------------------------------------------------------

    fn loadApps(self: *SettingsWindow) void {
        const all = gio.AppInfo.getAll();
        defer all.free();
        var node: ?*glib.List = all;
        while (node) |n| : (node = n.f_next) {
            const info: *gio.AppInfo = @ptrCast(@alignCast(n.f_data orelse continue));
            if (info.shouldShow() == 0) continue;
            self.apps.append(self.allocator, @ptrCast(info.as(gobject.Object).ref())) catch return;
        }
        std.mem.sort(*gio.AppInfo, self.apps.items, {}, struct {
            fn less(_: void, a: *gio.AppInfo, b: *gio.AppInfo) bool {
                return std.ascii.lessThanIgnoreCase(std.mem.span(a.getDisplayName()), std.mem.span(b.getDisplayName()));
            }
        }.less);
    }

    fn startMenuPage(self: *SettingsWindow) *gtk.Box {
        const page = newPage(common.tr("Start menu"));

        const heading = gtk.Label.new(common.tr("Pinned apps"));
        heading.setXalign(0);
        heading.as(gtk.Widget).addCssClass("heading");
        page.append(heading.as(gtk.Widget));

        const configured = self.panel.getStringList(self.allocator, "menu", "pinned") catch null;
        if (configured) |list| {
            defer common.config.freeStringList(self.allocator, list);
            for (list) |id| self.pinned.append(self.allocator, self.allocator.dupe(u8, id) catch continue) catch {};
        } else {
            for ([_][]const u8{ "dkde-files.desktop", "dkde-term.desktop", "dkde-settings.desktop" }) |id|
                self.pinned.append(self.allocator, self.allocator.dupe(u8, id) catch continue) catch {};
        }
        const list_box = gtk.Box.new(.vertical, 4);
        self.pinned_box = list_box;
        page.append(list_box.as(gtk.Widget));
        self.rebuildPinned();

        const picker = self.appPicker(null);
        const add = gtk.Button.newWithLabel(common.tr("Pin"));
        _ = gtk.Button.signals.clicked.connect(add, *DropDownCtx, &onPin, self.dropdownCtx(picker), .{});
        const add_row = gtk.Box.new(.horizontal, 6);
        add_row.append(picker.as(gtk.Widget));
        add_row.append(add.as(gtk.Widget));
        page.append(add_row.as(gtk.Widget));

        addRowDesc(page, common.tr("Recent apps shown"), "How many recently used apps the Start menu lists", self.spin(&self.panel, "menu", "recent-count", 0, 15, 5).as(gtk.Widget));
        addRow(page, common.tr("Shut Down command"), self.textEntry(&self.panel, "menu", "shutdown-command", "poweroff").as(gtk.Widget));
        addRow(page, common.tr("Restart command"), self.textEntry(&self.panel, "menu", "restart-command", "reboot").as(gtk.Widget));
        addRow(page, common.tr("Log Off command"), self.textEntry(&self.panel, "menu", "logoff-command", "labwc --exit").as(gtk.Widget));
        return page;
    }

    const DropDownCtx = struct { window: *SettingsWindow, dropdown: *gtk.DropDown };

    fn dropdownCtx(self: *SettingsWindow, dropdown: *gtk.DropDown) *DropDownCtx {
        const ctx = self.allocator.create(DropDownCtx) catch @panic("OOM");
        ctx.* = .{ .window = self, .dropdown = dropdown };
        // Freed with the dropdown.
        _ = gtk.Widget.signals.destroy.connect(dropdown, *DropDownCtx, &onDropDownDestroy, ctx, .{});
        return ctx;
    }

    fn onDropDownDestroy(_: *gtk.DropDown, ctx: *DropDownCtx) callconv(.c) void {
        ctx.window.allocator.destroy(ctx);
    }

    /// A dropdown of installed apps; when `filter_category` is set, only apps
    /// listing it in their Categories.
    fn appPicker(self: *SettingsWindow, filter_category: ?[]const u8) *gtk.DropDown {
        const names = gtk.StringList.new(null);
        for (self.apps.items) |app| {
            if (filter_category) |cat| {
                const desktop: *giounix.DesktopAppInfo = @ptrCast(app);
                const categories = desktop.getCategories() orelse continue;
                if (std.mem.indexOf(u8, std.mem.span(categories), cat) == null) continue;
            }
            names.append(app.getDisplayName());
        }
        return gtk.DropDown.new(names.as(gio.ListModel), null);
    }

    /// The app behind position `index` of a (possibly filtered) picker.
    fn appAt(self: *SettingsWindow, filter_category: ?[]const u8, index: usize) ?*gio.AppInfo {
        var seen: usize = 0;
        for (self.apps.items) |app| {
            if (filter_category) |cat| {
                const desktop: *giounix.DesktopAppInfo = @ptrCast(app);
                const categories = desktop.getCategories() orelse continue;
                if (std.mem.indexOf(u8, std.mem.span(categories), cat) == null) continue;
            }
            if (seen == index) return app;
            seen += 1;
        }
        return null;
    }

    fn onPin(_: *gtk.Button, ctx: *DropDownCtx) callconv(.c) void {
        const self = ctx.window;
        const app = self.appAt(null, ctx.dropdown.getSelected()) orelse return;
        const id = std.mem.span(app.getId() orelse return);
        for (self.pinned.items) |p| if (std.mem.eql(u8, p, id)) return;
        self.pinned.append(self.allocator, self.allocator.dupe(u8, id) catch return) catch return;
        self.savePinned();
        self.rebuildPinned();
    }

    fn savePinned(self: *SettingsWindow) void {
        var ids: std.ArrayList([]const u8) = .empty;
        defer ids.deinit(self.allocator);
        for (self.pinned.items) |id| ids.append(self.allocator, id) catch return;
        self.panel.setStringList("menu", "pinned", ids.items) catch |err|
            log.warn("cannot save pinned apps: {s}", .{@errorName(err)});
    }

    fn rebuildPinned(self: *SettingsWindow) void {
        const box = self.pinned_box orelse return;
        while (box.as(gtk.Widget).getFirstChild()) |child| box.remove(child);
        for (self.pinned.items, 0..) |id, i| {
            const row = gtk.Box.new(.horizontal, 6);
            var name_buf: [256]u8 = undefined;
            const idz = std.fmt.bufPrintSentinel(&name_buf, "{s}", .{id}, 0) catch continue;
            const info = giounix.DesktopAppInfo.new(idz);
            const label = gtk.Label.new(if (info) |app| app.as(gio.AppInfo).getDisplayName() else idz.ptr);
            if (info) |app| app.as(gobject.Object).unref();
            label.setXalign(0);
            label.as(gtk.Widget).setHexpand(1);
            row.append(label.as(gtk.Widget));
            for ([_]struct { [:0]const u8, [:0]const u8 }{ .{ "go-up-symbolic", "up" }, .{ "go-down-symbolic", "down" }, .{ "list-remove-symbolic", "remove" } }) |b| {
                const button = gtk.Button.newFromIconName(b[0]);
                const ctx = self.allocator.create(PinCtx) catch continue;
                ctx.* = .{ .window = self, .index = i, .action = b[1] };
                _ = gtk.Button.signals.clicked.connect(button, *PinCtx, &onPinAction, ctx, .{});
                _ = gtk.Widget.signals.destroy.connect(button, *PinCtx, &onPinDestroy, ctx, .{});
                row.append(button.as(gtk.Widget));
            }
            box.append(row.as(gtk.Widget));
        }
    }

    const PinCtx = struct { window: *SettingsWindow, index: usize, action: []const u8 };

    fn onPinDestroy(_: *gtk.Button, ctx: *PinCtx) callconv(.c) void {
        ctx.window.allocator.destroy(ctx);
    }

    fn onPinAction(_: *gtk.Button, ctx: *PinCtx) callconv(.c) void {
        const self = ctx.window;
        const list = &self.pinned;
        const i = ctx.index;
        if (std.mem.eql(u8, ctx.action, "remove")) {
            self.allocator.free(list.orderedRemove(i));
        } else if (std.mem.eql(u8, ctx.action, "up") and i > 0) {
            std.mem.swap([]u8, &list.items[i], &list.items[i - 1]);
        } else if (std.mem.eql(u8, ctx.action, "down") and i + 1 < list.items.len) {
            std.mem.swap([]u8, &list.items[i], &list.items[i + 1]);
        } else return;
        self.savePinned();
        // The button that fired is about to be destroyed; rebuild when idle.
        _ = glib.idleAdd(rebuildPinnedIdle, self);
    }

    fn rebuildPinnedIdle(data: ?*anyopaque) callconv(.c) c_int {
        const self: *SettingsWindow = @ptrCast(@alignCast(data.?));
        self.rebuildPinned();
        return 0;
    }

    // ---- terminal --------------------------------------------------------

    /// term.conf holds `[terminal] default-profile` and one `[profile:<name>]`
    /// group per profile with `command`, `directory`, `font`, `color-scheme`
    /// and `cursor-style`.
    fn terminalPage(self: *SettingsWindow) *gtk.Box {
        const page = newPage(common.tr("Terminal"));

        const default_entry = self.textEntry(&self.term, "terminal", "default-profile", "Default");
        addRow(page, common.tr("Default profile"), default_entry.as(gtk.Widget));
        addRow(page, common.tr("Scrollback (lines)"), self.spin(&self.term, "terminal", "scrollback-lines", 0, 1000000, 10000).as(gtk.Widget));

        const heading = gtk.Label.new(common.tr("Profiles"));
        heading.setXalign(0);
        heading.as(gtk.Widget).addCssClass("heading");
        page.append(heading.as(gtk.Widget));

        const box = gtk.Box.new(.vertical, 8);
        self.profile_box = box;
        page.append(box.as(gtk.Widget));
        self.rebuildProfiles();

        const new_name = gtk.Entry.new();
        new_name.setPlaceholderText(common.tr("New profile name"));
        const add = gtk.Button.newWithLabel(common.tr("Add profile"));
        const ctx = self.allocator.create(NewProfileCtx) catch @panic("OOM");
        ctx.* = .{ .window = self, .entry = new_name };
        _ = gtk.Button.signals.clicked.connect(add, *NewProfileCtx, &onAddProfile, ctx, .{});
        _ = gtk.Widget.signals.destroy.connect(add, *NewProfileCtx, &onNewProfileDestroy, ctx, .{});
        const add_row = gtk.Box.new(.horizontal, 6);
        add_row.append(new_name.as(gtk.Widget));
        add_row.append(add.as(gtk.Widget));
        page.append(add_row.as(gtk.Widget));
        return page;
    }

    const NewProfileCtx = struct { window: *SettingsWindow, entry: *gtk.Entry };

    fn onNewProfileDestroy(_: *gtk.Button, ctx: *NewProfileCtx) callconv(.c) void {
        ctx.window.allocator.destroy(ctx);
    }

    fn onAddProfile(_: *gtk.Button, ctx: *NewProfileCtx) callconv(.c) void {
        const self = ctx.window;
        const name = std.mem.span(ctx.entry.as(gtk.Editable).getText());
        if (name.len == 0 or std.mem.indexOfAny(u8, name, "[]\n") != null) return;
        const group = std.fmt.allocPrintSentinel(self.allocator, "profile:{s}", .{name}, 0) catch return;
        defer self.allocator.free(group);
        // A profile exists once it has a key; start it with the login shell.
        self.term.setString(group, "command", "") catch return;
        ctx.entry.as(gtk.Editable).setText("");
        self.rebuildProfiles();
    }

    fn rebuildProfiles(self: *SettingsWindow) void {
        const box = self.profile_box orelse return;
        while (box.as(gtk.Widget).getFirstChild()) |child| box.remove(child);
        for (self.term_previews.items) |p| p.destroy();
        self.term_previews.clearRetainingCapacity();
        const names = self.term.groupsWithPrefix(self.allocator, "profile:") catch return;
        defer common.config.freeStringList(self.allocator, names);

        for (names) |name| {
            const frame = gtk.Frame.new(null);
            const inner = gtk.Box.new(.vertical, 6);
            inner.as(gtk.Widget).setMarginTop(8);
            inner.as(gtk.Widget).setMarginBottom(8);
            inner.as(gtk.Widget).setMarginStart(8);
            inner.as(gtk.Widget).setMarginEnd(8);
            frame.setChild(inner.as(gtk.Widget));

            const title = std.fmt.allocPrintSentinel(self.allocator, "{s}", .{name}, 0) catch continue;
            defer self.allocator.free(title);
            const heading = gtk.Label.new(title);
            heading.setXalign(0);
            heading.as(gtk.Widget).addCssClass("heading");
            inner.append(heading.as(gtk.Widget));

            // Group names must outlive the bindings: keep them with the window.
            const group = std.fmt.allocPrintSentinel(self.allocator, "profile:{s}", .{name}, 0) catch continue;
            self.strings.append(self.allocator, group) catch continue;

            const sub = struct {
                fn section(target: *gtk.Box, text: [:0]const u8) void {
                    const l = gtk.Label.new(text);
                    l.setXalign(0);
                    l.as(gtk.Widget).addCssClass("dim-label");
                    l.as(gtk.Widget).setMarginTop(6);
                    target.append(l.as(gtk.Widget));
                }
            };
            sub.section(inner, common.tr("Start"));
            addRowDesc(inner, common.tr("Command"), "Program and arguments, for example ssh myserver. Empty runs your login shell", self.textEntry(&self.term, group, "command", "").as(gtk.Widget));
            addRowDesc(inner, common.tr("Starting directory"), "Empty starts in your home folder", self.textEntry(&self.term, group, "directory", "").as(gtk.Widget));
            addRowDesc(inner, common.tr("Environment"), "Extra variables for the program: NAME=value;OTHER=value", self.textEntry(&self.term, group, "environment", "").as(gtk.Widget));
            addRowDesc(inner, common.tr("When the program ends"), "Keep the tab open to read what it printed", self.choice(&self.term, group, "close-on-exit", &.{ "always", "success", "never" }, "always").as(gtk.Widget));

            sub.section(inner, common.tr("Window"));
            addRowDesc(inner, common.tr("Columns"), "Width of a new window in characters; 0 uses the default size", self.spin(&self.term, group, "columns", 0, 500, 0).as(gtk.Widget));
            addRowDesc(inner, common.tr("Rows"), "Height of a new window in lines; 0 uses the default size", self.spin(&self.term, group, "rows", 0, 300, 0).as(gtk.Widget));
            addRow(inner, common.tr("Open as"), self.choice(&self.term, group, "startup", &.{ "windowed", "maximized", "fullscreen" }, "windowed").as(gtk.Widget));

            sub.section(inner, common.tr("Tab"));
            addRowDesc(inner, common.tr("Title"), "Fixed tab title; empty follows the program", self.textEntry(&self.term, group, "title", "").as(gtk.Widget));
            addRowDesc(inner, common.tr("Icon"), "An icon name such as utilities-terminal, or an image path", self.textEntry(&self.term, group, "icon", "").as(gtk.Widget));
            addRowDesc(inner, common.tr("Tab colour"), "A colour such as #e74856 or orange", self.textEntry(&self.term, group, "tab-color", "").as(gtk.Widget));

            sub.section(inner, common.tr("Appearance"));
            const preview = termpreview.TermPreview.create(&self.term, group);
            self.term_previews.append(self.allocator, preview) catch preview.destroy();
            inner.append(preview.widget());
            addRow(inner, common.tr("Font"), self.fontButton(&self.term, group, "font", "Monospace 11").as(gtk.Widget));
            addRow(inner, common.tr("Colour scheme"), self.choice(&self.term, group, "color-scheme", &.{ "campbell", "one-half-dark", "solarized-dark", "solarized-light" }, "campbell").as(gtk.Widget));
            addRow(inner, common.tr("Cursor"), self.choice(&self.term, group, "cursor-style", &.{ "block", "bar", "underline" }, "block").as(gtk.Widget));
            addRow(inner, common.tr("Background opacity (%)"), self.spin(&self.term, group, "opacity", 20, 100, 100).as(gtk.Widget));
            addRow(inner, common.tr("Padding (pixels)"), self.spin(&self.term, group, "padding", 0, 40, 4).as(gtk.Widget));

            sub.section(inner, common.tr("Behaviour"));
            addRowDesc(inner, common.tr("Copy on select"), "Selecting text also copies it to the clipboard", self.toggle(&self.term, group, "copy-on-select", true).as(gtk.Widget));
            addRow(inner, common.tr("Allow programs to set the clipboard"), self.toggle(&self.term, group, "osc52", true).as(gtk.Widget));

            const remove = gtk.Button.newWithLabel(common.tr("Remove profile"));
            const ctx = self.allocator.create(RemoveProfileCtx) catch continue;
            ctx.* = .{ .window = self, .group = group };
            _ = gtk.Button.signals.clicked.connect(remove, *RemoveProfileCtx, &onRemoveProfile, ctx, .{});
            _ = gtk.Widget.signals.destroy.connect(remove, *RemoveProfileCtx, &onRemoveProfileDestroy, ctx, .{});
            remove.as(gtk.Widget).setHalign(.end);
            inner.append(remove.as(gtk.Widget));
            box.append(frame.as(gtk.Widget));
        }
    }

    const RemoveProfileCtx = struct { window: *SettingsWindow, group: [:0]u8 };

    fn onRemoveProfileDestroy(_: *gtk.Button, ctx: *RemoveProfileCtx) callconv(.c) void {
        ctx.window.allocator.destroy(ctx);
    }

    fn onRemoveProfile(_: *gtk.Button, ctx: *RemoveProfileCtx) callconv(.c) void {
        ctx.window.term.removeGroup(ctx.group) catch return;
        _ = glib.idleAdd(rebuildProfilesIdle, ctx.window);
    }

    fn rebuildProfilesIdle(data: ?*anyopaque) callconv(.c) c_int {
        const self: *SettingsWindow = @ptrCast(@alignCast(data.?));
        self.rebuildProfiles();
        return 0;
    }

    // ---- keyboard --------------------------------------------------------

    fn keyboardPage(self: *SettingsWindow) *gtk.Box {
        const page = newPage(common.tr("Keyboard"));

        const layouts = [_]?[*:0]const u8{ "us", "gb", "de", "fr", "es", "it", "pt", "se", "no", "dk", "fi", "pl", "cz", "ru", "us(dvorak)", "us(colemak)", null };
        const picker = gtk.DropDown.newFromStrings(@ptrCast(&layouts));
        _ = gobject.Object.signals.notify.connect(picker, *DropDownCtx, &onLayoutPicked, self.dropdownCtx(picker), .{ .detail = "selected" });
        addRow(page, common.tr("Common layouts"), picker.as(gtk.Widget));

        const current = self.readLabwcFile("environment") catch null;
        defer if (current) |c| self.allocator.free(c);
        const entry = gtk.Entry.new();
        entry.as(gtk.Widget).setSizeRequest(260, -1);
        if (current) |text| if (envValue(text, "XKB_DEFAULT_LAYOUT")) |value| {
            var buf: [128]u8 = undefined;
            entry.as(gtk.Editable).setText(std.fmt.bufPrintSentinel(&buf, "{s}", .{value}, 0) catch "");
        };
        _ = gtk.Entry.signals.activate.connect(entry, *SettingsWindow, &onLayoutEntry, self, .{});
        addRow(page, common.tr("Layout (press Enter to apply)"), entry.as(gtk.Widget));

        const hint = gtk.Label.new(common.tr("Separate several layouts with commas, for example us,de. Written to labwc's environment file."));
        hint.setXalign(0);
        hint.setWrap(1);
        hint.as(gtk.Widget).addCssClass("dim-label");
        page.append(hint.as(gtk.Widget));
        return page;
    }

    fn envValue(content: []const u8, key: []const u8) ?[]const u8 {
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (std.mem.startsWith(u8, trimmed, key) and trimmed.len > key.len and trimmed[key.len] == '=') return trimmed[key.len + 1 ..];
        }
        return null;
    }

    fn onLayoutPicked(picker: *gtk.DropDown, _: *gobject.ParamSpec, ctx: *DropDownCtx) callconv(.c) void {
        const list = picker.getModel() orelse return;
        const item = list.getItem(picker.getSelected()) orelse return;
        const string: *gtk.StringObject = @ptrCast(@alignCast(item));
        defer string.as(gobject.Object).unref();
        ctx.window.applyLayout(std.mem.span(string.getString()));
    }

    fn onLayoutEntry(entry: *gtk.Entry, self: *SettingsWindow) callconv(.c) void {
        self.applyLayout(std.mem.span(entry.as(gtk.Editable).getText()));
    }

    fn applyLayout(self: *SettingsWindow, layout: []const u8) void {
        if (layout.len == 0) return;
        self.editLabwcFile("environment", EnvEdit, .{ .key = "XKB_DEFAULT_LAYOUT", .value = layout });
    }

    const EnvEdit = struct {
        key: []const u8,
        value: []const u8,
        pub fn apply(self: @This(), allocator: std.mem.Allocator, content: []const u8) ![]u8 {
            return labwc.setEnvVar(allocator, content, self.key, self.value);
        }
    };

    const DesktopsEdit = struct {
        count: u32,
        pub fn apply(self: @This(), allocator: std.mem.Allocator, content: []const u8) ![]u8 {
            return labwc.setDesktops(allocator, content, self.count);
        }
    };

    fn onDesktopsChanged(button: *gtk.SpinButton, self: *SettingsWindow) callconv(.c) void {
        self.editLabwcFile("rc.xml", DesktopsEdit, .{ .count = @intCast(button.getValueAsInt()) });
    }

    const LibinputEdit = struct {
        tag: []const u8,
        value: []const u8,
        pub fn apply(self: @This(), allocator: std.mem.Allocator, content: []const u8) ![]u8 {
            return labwc.setLibinput(allocator, content, self.tag, self.value);
        }
    };

    // ---- labwc files -----------------------------------------------------

    fn labwcPath(self: *SettingsWindow, name: []const u8) ![:0]u8 {
        return std.fmt.allocPrintSentinel(self.allocator, "{s}/labwc/{s}", .{ std.mem.span(glib.getUserConfigDir()), name }, 0);
    }

    pub fn readLabwcFile(self: *SettingsWindow, name: []const u8) ![]u8 {
        const path = try self.labwcPath(name);
        defer self.allocator.free(path);
        var contents: [*]u8 = undefined;
        var length: usize = 0;
        if (glib.fileGetContents(path, &contents, &length, null) == 0) return self.allocator.dupe(u8, "");
        defer glib.free(contents);
        return self.allocator.dupe(u8, contents[0..length]);
    }

    /// Applies `edit` to the labwc file `name`, keeping a one-time backup of
    /// the original, then asks labwc to reload (SPEC.md 5.5).
    pub fn editLabwcFile(self: *SettingsWindow, name: []const u8, comptime Edit: type, edit: Edit) void {
        const path = self.labwcPath(name) catch return;
        defer self.allocator.free(path);
        const dir = glib.pathGetDirname(path);
        defer glib.free(dir);
        _ = glib.mkdirWithParents(dir, 0o755);

        const before = self.readLabwcFile(name) catch return;
        defer self.allocator.free(before);
        const after = edit.apply(self.allocator, before) catch |err| {
            common.dialogs.showError(self.window.as(gtk.Window), common.tr("Cannot edit the labwc configuration"), @errorName(err));
            return;
        };
        defer self.allocator.free(after);

        // Back up the original once, before the first edit.
        const backup = std.fmt.allocPrintSentinel(self.allocator, "{s}.dkde-backup", .{path}, 0) catch return;
        defer self.allocator.free(backup);
        if (before.len > 0 and glib.fileTest(backup, .{ .exists = true }) == 0)
            _ = glib.fileSetContents(backup, before.ptr, @intCast(before.len), null);

        if (glib.fileSetContents(path, after.ptr, @intCast(after.len), null) == 0) {
            common.dialogs.showError(self.window.as(gtk.Window), common.tr("Cannot write the labwc configuration"), path);
            return;
        }
        common.appinfo.spawn(self.allocator, &.{ "labwc", "--reconfigure" });
    }

    // ---- sound ------------------------------------------------------------

    fn hasProgram(name: [:0]const u8) bool {
        const found = glib.findProgramInPath(name) orelse return false;
        glib.free(found);
        return true;
    }

    /// Picks the first tool that is installed *and* can reach a running
    /// sound server: wpctl for PipeWire, else pactl for PulseAudio (which
    /// is also what WSLg provides). Having a tool installed is not enough.
    fn detectBackend(self: *SettingsWindow) ?audio.Backend {
        if (hasProgram("wpctl") and self.readAudio(.wpctl) != null) return .wpctl;
        if (hasProgram("pactl") and self.readAudio(.pactl) != null) return .pactl;
        return null;
    }

    /// Runs a command and returns its output, or null.
    fn runCapture(self: *SettingsWindow, command: [:0]const u8) ?[]u8 {
        var stdout: [*:0]u8 = undefined;
        if (glib.spawnCommandLineSync(command, &stdout, null, null, null) == 0) return null;
        defer glib.free(stdout);
        return self.allocator.dupe(u8, std.mem.span(stdout)) catch null;
    }

    fn readAudio(self: *SettingsWindow, backend: audio.Backend) ?audio.State {
        switch (backend) {
            .wpctl => {
                const out = self.runCapture("wpctl get-volume @DEFAULT_AUDIO_SINK@") orelse return null;
                defer self.allocator.free(out);
                return audio.parseWpctl(out);
            },
            .pactl => {
                const vol = self.runCapture("pactl get-sink-volume @DEFAULT_SINK@") orelse return null;
                defer self.allocator.free(vol);
                const mute = self.runCapture("pactl get-sink-mute @DEFAULT_SINK@") orelse return null;
                defer self.allocator.free(mute);
                return .{ .volume_percent = audio.parsePactlVolume(vol) orelse return null, .muted = audio.parsePactlMute(mute) orelse false };
            },
        }
    }

    fn audioPage(self: *SettingsWindow) *gtk.Box {
        const page = newPage(common.tr("Sound"));
        self.audio_backend = self.detectBackend();
        const backend = self.audio_backend orelse {
            const note = gtk.Label.new(common.tr("No working sound control found. Install the package wireplumber (provides wpctl, for PipeWire) or pulseaudio-utils (provides pactl, for PulseAudio and WSL) and make sure a sound server is running."));
            note.setXalign(0);
            note.setWrap(1);
            note.as(gtk.Widget).addCssClass("dim-label");
            page.append(note.as(gtk.Widget));
            return page;
        };
        const state = self.readAudio(backend) orelse audio.State{ .volume_percent = 50, .muted = false };

        const scale = gtk.Scale.newWithRange(.horizontal, 0, 100, 1);
        scale.as(gtk.Widget).setSizeRequest(260, -1);
        scale.as(gtk.Range).setValue(@floatFromInt(@min(state.volume_percent, 100)));
        scale.setDrawValue(1);
        _ = gtk.Range.signals.value_changed.connect(scale.as(gtk.Range), *SettingsWindow, &onVolume, self, .{});
        addRow(page, common.tr("Volume"), scale.as(gtk.Widget));

        const mute = gtk.Switch.new();
        mute.setActive(@intFromBool(state.muted));
        _ = gtk.Switch.signals.state_set.connect(mute, *SettingsWindow, &onMute, self, .{});
        addRow(page, common.tr("Mute"), mute.as(gtk.Widget));
        hwpages.SoundDevices.add(self, page, backend);

        var buf: [96]u8 = undefined;
        const text = std.fmt.bufPrintSentinel(&buf, "Using {s}. This controls the default output device.", .{@tagName(backend)}, 0) catch "";
        const note = gtk.Label.new(text);
        note.setXalign(0);
        note.as(gtk.Widget).addCssClass("dim-label");
        page.append(note.as(gtk.Widget));
        return page;
    }

    fn onVolume(range: *gtk.Range, self: *SettingsWindow) callconv(.c) void {
        const backend = self.audio_backend orelse return;
        const percent: u32 = @intFromFloat(@max(0, range.getValue()));
        var arg_buf: [16]u8 = undefined;
        const arg = audio.volumeArg(&arg_buf, backend, percent);
        switch (backend) {
            .wpctl => common.appinfo.spawn(self.allocator, &.{ "wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", arg }),
            .pactl => common.appinfo.spawn(self.allocator, &.{ "pactl", "set-sink-volume", "@DEFAULT_SINK@", arg }),
        }
    }

    fn onMute(_: *gtk.Switch, state: c_int, self: *SettingsWindow) callconv(.c) c_int {
        const backend = self.audio_backend orelse return 0;
        const flag: []const u8 = if (state != 0) "1" else "0";
        switch (backend) {
            .wpctl => common.appinfo.spawn(self.allocator, &.{ "wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", flag }),
            .pactl => common.appinfo.spawn(self.allocator, &.{ "pactl", "set-sink-mute", "@DEFAULT_SINK@", flag }),
        }
        return 0;
    }

    // ---- mouse -----------------------------------------------------------

    fn mousePage(self: *SettingsWindow) *gtk.Box {
        const page = newPage(common.tr("Mouse & touchpad"));
        const rc = self.readLabwcFile("rc.xml") catch null;
        defer if (rc) |c| self.allocator.free(c);

        const speed = gtk.Scale.newWithRange(.horizontal, -1, 1, 0.1);
        speed.as(gtk.Widget).setSizeRequest(240, -1);
        speed.as(gtk.Range).setValue(if (rc) |c| (xmlValueFloat(c, "pointerSpeed") orelse 0) else 0);
        _ = gtk.Range.signals.value_changed.connect(speed.as(gtk.Range), *SettingsWindow, &onSpeed, self, .{});
        addRow(page, common.tr("Pointer speed"), speed.as(gtk.Widget));

        const natural = gtk.Switch.new();
        natural.setActive(@intFromBool(if (rc) |c| xmlValueBool(c, "naturalScroll") else false));
        _ = gtk.Switch.signals.state_set.connect(natural, *SettingsWindow, &onNatural, self, .{});
        addRow(page, common.tr("Natural scrolling"), natural.as(gtk.Widget));

        const tap = gtk.Switch.new();
        tap.setActive(@intFromBool(if (rc) |c| xmlValueBool(c, "tap") else true));
        _ = gtk.Switch.signals.state_set.connect(tap, *SettingsWindow, &onTap, self, .{});
        addRow(page, common.tr("Tap to click"), tap.as(gtk.Widget));
        return page;
    }

    fn xmlValue(content: []const u8, tag: []const u8) ?[]const u8 {
        var open_buf: [64]u8 = undefined;
        var close_buf: [64]u8 = undefined;
        const open = std.fmt.bufPrint(&open_buf, "<{s}>", .{tag}) catch return null;
        const close = std.fmt.bufPrint(&close_buf, "</{s}>", .{tag}) catch return null;
        const start = std.mem.indexOf(u8, content, open) orelse return null;
        const end = std.mem.indexOfPos(u8, content, start, close) orelse return null;
        return std.mem.trim(u8, content[start + open.len .. end], " \t\r\n");
    }

    fn xmlValueFloat(content: []const u8, tag: []const u8) ?f64 {
        return std.fmt.parseFloat(f64, xmlValue(content, tag) orelse return null) catch null;
    }

    fn xmlValueBool(content: []const u8, tag: []const u8) bool {
        return std.mem.eql(u8, xmlValue(content, tag) orelse return false, "yes");
    }

    /// Dragging the slider fires constantly; apply once it settles.
    fn onSpeed(_: *gtk.Range, self: *SettingsWindow) callconv(.c) void {
        if (self.debounce_source != 0) _ = glib.Source.remove(self.debounce_source);
        self.debounce_source = glib.timeoutAdd(400, applySpeed, self);
    }

    fn applySpeed(data: ?*anyopaque) callconv(.c) c_int {
        const self: *SettingsWindow = @ptrCast(@alignCast(data.?));
        self.debounce_source = 0;
        // The slider is found again through the visible page.
        const page = self.stack.getChildByName("mouse") orelse return 0;
        const row = page.getFirstChild().?.getNextSibling() orelse return 0;
        const scale: *gtk.Scale = @ptrCast(row.getFirstChild().?.getNextSibling().?);
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d:.1}", .{scale.as(gtk.Range).getValue()}) catch return 0;
        self.editLabwcFile("rc.xml", LibinputEdit, .{ .tag = "pointerSpeed", .value = text });
        return 0;
    }

    fn onNatural(_: *gtk.Switch, state: c_int, self: *SettingsWindow) callconv(.c) c_int {
        self.editLabwcFile("rc.xml", LibinputEdit, .{ .tag = "naturalScroll", .value = if (state != 0) "yes" else "no" });
        return 0;
    }

    fn onTap(_: *gtk.Switch, state: c_int, self: *SettingsWindow) callconv(.c) c_int {
        self.editLabwcFile("rc.xml", LibinputEdit, .{ .tag = "tap", .value = if (state != 0) "yes" else "no" });
        return 0;
    }

    // ---- default apps ----------------------------------------------------

    const Role = struct { label: [:0]const u8, mime: []const [:0]const u8, category: ?[]const u8 };
    const roles = [_]Role{
        .{ .label = "Web browser", .mime = &.{ "x-scheme-handler/http", "x-scheme-handler/https", "text/html" }, .category = "WebBrowser" },
        .{ .label = "File manager", .mime = &.{"inode/directory"}, .category = "FileManager" },
        .{ .label = "Text editor", .mime = &.{"text/plain"}, .category = "TextEditor" },
        .{ .label = "Terminal", .mime = &.{}, .category = "TerminalEmulator" },
    };

    fn defaultsPage(self: *SettingsWindow) *gtk.Box {
        const page = newPage(common.tr("Default apps"));
        inline for (roles, 0..) |role, i| {
            const picker = self.appPicker(role.category);
            // Show the current default when there is one.
            if (role.mime.len > 0) {
                if (gio.AppInfo.getDefaultForType(role.mime[0], 0)) |current| {
                    defer current.as(gobject.Object).unref();
                    self.selectApp(picker, role.category, current);
                }
            }
            const ctx = self.allocator.create(RoleCtx) catch @panic("OOM");
            ctx.* = .{ .window = self, .dropdown = picker, .role = i };
            _ = gobject.Object.signals.notify.connect(picker, *RoleCtx, &onRolePicked, ctx, .{ .detail = "selected" });
            _ = gtk.Widget.signals.destroy.connect(picker, *RoleCtx, &onRoleDestroy, ctx, .{});
            addRow(page, common.tr(role.label), picker.as(gtk.Widget));
        }
        return page;
    }

    const RoleCtx = struct { window: *SettingsWindow, dropdown: *gtk.DropDown, role: usize };

    fn onRoleDestroy(_: *gtk.DropDown, ctx: *RoleCtx) callconv(.c) void {
        ctx.window.allocator.destroy(ctx);
    }

    fn selectApp(self: *SettingsWindow, picker: *gtk.DropDown, category: ?[]const u8, app: *gio.AppInfo) void {
        const wanted = std.mem.span(app.getId() orelse return);
        var index: u32 = 0;
        while (self.appAt(category, index)) |candidate| : (index += 1) {
            if (std.mem.eql(u8, std.mem.span(candidate.getId() orelse ""), wanted)) {
                picker.setSelected(index);
                return;
            }
        }
    }

    fn onRolePicked(picker: *gtk.DropDown, _: *gobject.ParamSpec, ctx: *RoleCtx) callconv(.c) void {
        const self = ctx.window;
        const role = roles[ctx.role];
        const app = self.appAt(role.category, picker.getSelected()) orelse return;
        if (role.mime.len == 0) {
            // No MIME type names "the terminal": dkde keeps its own setting.
            const id = std.mem.span(app.getId() orelse return);
            self.shared.setString("default-apps", "terminal", id) catch {};
            return;
        }
        for (role.mime) |mime| {
            var err: ?*glib.Error = null;
            if (app.setAsDefaultForType(mime, &err) == 0) {
                if (err) |e| {
                    log.warn("cannot set default for {s}: {s}", .{ mime, e.f_message orelse "unknown" });
                    e.free();
                }
            }
        }
    }
};
