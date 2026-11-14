//! dkde-tasks: Task Manager (SPEC.md 5.6), laid out as Windows 11's: a rail
//! of pages on the left (Processes, Performance, Startup apps, Users,
//! Details, Services, and Settings at the bottom). Everything shown is read
//! from /proc and /sys (sampler.zig, perfview.zig); nothing is estimated.

const std = @import("std");
const cli = @import("cli");
const gdk = @import("gdk4");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

const perfview = @import("perfview.zig");
const sampler_mod = @import("sampler.zig");
const columns = @import("columns.zig");
const actions_mod = @import("actions.zig");
const table_mod = @import("table.zig");
const users_mod = @import("users.zig");
const services_mod = @import("services.zig");
const startup_mod = @import("startup.zig");

const Sampler = sampler_mod.Sampler;
const Table = table_mod.Table;
const t = common.tr;

pub const PageId = enum {
    processes,
    performance,
    startup,
    users,
    details,
    services,
    settings,

    fn title(self: PageId) [:0]const u8 {
        return switch (self) {
            .processes => "Processes",
            .performance => "Performance",
            .startup => "Startup apps",
            .users => "Users",
            .details => "Details",
            .services => "Services",
            .settings => "Settings",
        };
    }

    fn icon(self: PageId) [:0]const u8 {
        return switch (self) {
            .processes => "view-grid-symbolic",
            .performance => "utilities-system-monitor-symbolic",
            .startup => "system-run-symbolic",
            .users => "system-users-symbolic",
            .details => "view-list-symbolic",
            .services => "preferences-system-symbolic",
            .settings => "emblem-system-symbolic",
        };
    }
};

const rail_pages = [_]PageId{ .processes, .performance, .startup, .users, .details, .services };

/// Update speed: how often everything is read again.
pub const Speed = enum {
    high,
    normal,
    low,
    paused,

    fn ms(self: Speed) c_uint {
        return switch (self) {
            .high => 500,
            .normal => 1000,
            .low => 4000,
            .paused => 0,
        };
    }
};

const App = struct {
    gpa: std.mem.Allocator,
    appearance: ?*common.style.Appearance = null,
    page: ?PageId = null,
    resource: ?[:0]const u8 = null,
    manager: ?*TaskManager = null,

    fn activate(app: *gtk.Application, self: *App) callconv(.c) void {
        if (self.manager) |m| return m.window.as(gtk.Window).present();
        common.style.load(self.gpa) catch |err|
            std.log.warn("stylesheet not loaded: {s}", .{@errorName(err)});
        self.appearance = common.style.Appearance.create(self.gpa) catch null;
        const manager = TaskManager.create(self.gpa, app) catch |err| {
            std.log.err("cannot create the window: {s}", .{@errorName(err)});
            return;
        };
        self.manager = manager;
        manager.app = self;
        if (self.page) |p| manager.showPage(p);
        if (self.resource) |r| manager.perf.select(r);
        manager.window.as(gtk.Window).present();
        instance.listen(manager);
    }
};

pub const TaskManager = struct {
    gpa: std.mem.Allocator,
    app: *App = undefined,
    window: *gtk.ApplicationWindow,
    config: common.Config,
    sampler: Sampler,
    actions: actions_mod.Actions = undefined,
    rail: *gtk.ListBox,
    rail_bottom: *gtk.ListBox,
    rail_box: *gtk.Box,
    rail_labels: std.ArrayList(*gtk.Label) = .empty,
    stack: *gtk.Stack,
    search: *gtk.SearchEntry,
    processes: *Table = undefined,
    details: *Table = undefined,
    perf: *perfview.Perf,
    users: *users_mod.Page = undefined,
    services: *services_mod.Page = undefined,
    startup: *startup_mod.Page = undefined,
    page: PageId = .processes,
    speed: Speed = .normal,
    timer: c_uint = 0,
    /// Buttons that need a selected process.
    process_buttons: std.ArrayList(*gtk.Widget) = .empty,
    efficiency_button: ?*gtk.ToggleButton = null,
    syncing: bool = false,
    speed_dropdown: ?*gtk.DropDown = null,

    fn create(gpa: std.mem.Allocator, app: *gtk.Application) !*TaskManager {
        const self = try gpa.create(TaskManager);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .window = gtk.ApplicationWindow.new(app),
            .config = try common.Config.load(gpa, "tasks.toml"),
            .sampler = Sampler.init(gpa),
            .rail = gtk.ListBox.new(),
            .rail_bottom = gtk.ListBox.new(),
            .rail_box = gtk.Box.new(.vertical, 0),
            .stack = gtk.Stack.new(),
            .search = gtk.SearchEntry.new(),
            .perf = perfview.Perf.create(gpa),
        };
        self.actions = .{ .gpa = gpa, .window = self.window.as(gtk.Window), .sampler = &self.sampler, .refreshed = onRefreshed, .owner = self };
        self.speed = std.meta.stringToEnum(Speed, self.configString("update-speed", "normal")) orelse .normal;

        const window = self.window.as(gtk.Window);
        window.setTitle(t("Task Manager"));
        window.setDefaultSize(self.config.getInt("tasks", "width", 980), self.config.getInt("tasks", "height", 680));
        if (self.config.getBool("tasks", "maximized", false)) window.maximize();
        window.as(gtk.Widget).addCssClass("dkde");
        window.as(gtk.Widget).addCssClass("dkde-tasks");

        // The header: icon, title, and the search for processes.
        const header = common.header.create(window, "utilities-system-monitor", true);
        self.search.setPlaceholderText(t("Type a name, publisher or PID to search"));
        self.search.as(gtk.Widget).setSizeRequest(160, -1);
        _ = gtk.SearchEntry.signals.search_changed.connect(self.search, *TaskManager, &onSearchChanged, self, .{});
        header.setTitleWidget(self.search.as(gtk.Widget));

        self.buildRail();
        self.buildPages();

        const body = gtk.Box.new(.horizontal, 0);
        body.append(self.rail_box.as(gtk.Widget));
        self.stack.as(gtk.Widget).setHexpand(1);
        self.stack.setTransitionType(.crossfade);
        self.stack.setTransitionDuration(120);
        body.append(self.stack.as(gtk.Widget));
        window.setChild(body.as(gtk.Widget));

        const keys = gtk.EventControllerKey.new();
        keys.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *TaskManager, &onKey, self, .{});
        window.as(gtk.Widget).addController(keys.as(gtk.EventController));

        _ = gtk.Window.signals.close_request.connect(window, *TaskManager, &onCloseRequest, self, .{});
        _ = gtk.Widget.signals.destroy.connect(self.window, *TaskManager, &onDestroy, self, .{});

        self.refresh();
        self.setSpeed(self.speed);
        const start = std.meta.stringToEnum(PageId, self.configString("start-page", "processes")) orelse .processes;
        self.showPage(if (start == .settings) .processes else start);
        if (self.config.getBool("tasks", "rail-collapsed", false)) self.setRailCollapsed(true);
        return self;
    }

    fn configString(self: *TaskManager, key: [:0]const u8, default: []const u8) []const u8 {
        // Short values only; kept in a static buffer per key use.
        const S = struct {
            var buf: [2][32]u8 = undefined;
            var which: usize = 0;
        };
        const v = self.config.getString(self.gpa, "tasks", key, default) catch return default;
        defer self.gpa.free(v);
        S.which = (S.which + 1) % 2;
        const n = @min(v.len, 31);
        @memcpy(S.buf[S.which][0..n], v[0..n]);
        return S.buf[S.which][0..n];
    }

    // ---- the rail ------------------------------------------------------------------------

    fn railRow(self: *TaskManager, page: PageId) *gtk.Widget {
        const box = gtk.Box.new(.horizontal, 12);
        box.as(gtk.Widget).addCssClass("dkde-rail-item");
        const img = gtk.Image.newFromIconName(page.icon());
        img.setPixelSize(16);
        const label = gtk.Label.new(page.title());
        label.setXalign(0);
        box.append(img.as(gtk.Widget));
        box.append(label.as(gtk.Widget));
        box.as(gtk.Widget).setTooltipText(page.title());
        self.rail_labels.append(self.gpa, label) catch {};
        return box.as(gtk.Widget);
    }

    fn buildRail(self: *TaskManager) void {
        const rail = self.rail_box;
        rail.as(gtk.Widget).addCssClass("dkde-rail");
        const menu = gtk.Button.newFromIconName("open-menu-symbolic");
        menu.setHasFrame(0);
        menu.as(gtk.Widget).setHalign(.start);
        menu.as(gtk.Widget).setTooltipText(t("Show or hide the page names"));
        menu.as(gtk.Widget).addCssClass("dkde-rail-toggle");
        _ = gtk.Button.signals.clicked.connect(menu, *TaskManager, &onRailToggle, self, .{});
        rail.append(menu.as(gtk.Widget));
        self.rail.setSelectionMode(.single);
        for (rail_pages) |p| self.rail.append(self.railRow(p));
        _ = gtk.ListBox.signals.row_activated.connect(self.rail, *TaskManager, &onRailActivated, self, .{});
        self.rail.as(gtk.Widget).setVexpand(1);
        rail.append(self.rail.as(gtk.Widget));
        self.rail_bottom.setSelectionMode(.single);
        self.rail_bottom.append(self.railRow(.settings));
        _ = gtk.ListBox.signals.row_activated.connect(self.rail_bottom, *TaskManager, &onRailActivated, self, .{});
        rail.append(self.rail_bottom.as(gtk.Widget));
    }

    fn onRailToggle(_: *gtk.Button, self: *TaskManager) callconv(.c) void {
        const collapsed = !self.config.getBool("tasks", "rail-collapsed", false);
        self.setRailCollapsed(collapsed);
        self.config.setBool("tasks", "rail-collapsed", collapsed) catch {};
    }

    fn setRailCollapsed(self: *TaskManager, collapsed: bool) void {
        for (self.rail_labels.items) |l| l.as(gtk.Widget).setVisible(@intFromBool(!collapsed));
    }

    fn onRailActivated(box: *gtk.ListBox, row: *gtk.ListBoxRow, self: *TaskManager) callconv(.c) void {
        if (self.syncing) return;
        if (box == self.rail_bottom) return self.showPage(.settings);
        const i: usize = @intCast(row.getIndex());
        if (i < rail_pages.len) self.showPage(rail_pages[i]);
    }

    pub fn showPage(self: *TaskManager, page: PageId) void {
        self.page = page;
        self.stack.setVisibleChildName(@tagName(page));
        self.syncing = true;
        defer self.syncing = false;
        if (page == .settings) {
            self.rail.unselectAll();
            if (self.rail_bottom.getRowAtIndex(0)) |r| self.rail_bottom.selectRow(r);
        } else {
            self.rail_bottom.unselectAll();
            const i = std.mem.indexOfScalar(PageId, &rail_pages, page) orelse 0;
            if (self.rail.getRowAtIndex(@intCast(i))) |r| self.rail.selectRow(r);
        }
        const searchable = page == .processes or page == .details;
        self.search.as(gtk.Widget).setSensitive(@intFromBool(searchable));
        self.processes.shown = page == .processes;
        self.details.shown = page == .details;
        switch (page) {
            .processes => self.processes.rebuild(),
            .details => self.details.rebuild(),
            .users => {
                self.users.reload();
                self.users.refresh();
            },
            .services => self.services.reload(),
            .startup => self.startup.reload(),
            else => {},
        }
        self.updateButtons();
    }

    // ---- the pages ----------------------------------------------------------------------

    fn buildPages(self: *TaskManager) void {
        const a = self.gpa;
        const all = std.enums.values(columns.Column);
        self.processes = Table.create(a, &self.sampler, &self.actions, "processes", all, &.{ .name, .pid, .status, .cpu, .memory, .disk, .gpu }, .grouped, true);
        self.details = Table.create(a, &self.sampler, &self.actions, "details", all, &columns.details_default, .flat, false);
        for ([_]*Table{ self.processes, self.details }) |tb| {
            tb.owner = self;
            tb.on_selection = onTableSelection;
            tb.on_goto = onGoto;
        }
        self.users = users_mod.Page.create(a, self.window.as(gtk.Window), &self.sampler);
        self.users.owner = self;
        self.users.on_show = onShowUser;
        self.services = services_mod.Page.create(a, self.window.as(gtk.Window), &self.sampler);
        self.startup = startup_mod.Page.create(a, self.window.as(gtk.Window));
        self.perf.owner = self;
        self.perf.on_compact = onCompact;

        _ = self.stack.addNamed(self.tablePage(self.processes, .processes), "processes");
        const perf_page = gtk.Box.new(.vertical, 0);
        perf_page.append(services_mod.commandBar(t("Performance")).as(gtk.Widget));
        self.perf.widget.setVexpand(1);
        perf_page.append(self.perf.widget);
        _ = self.stack.addNamed(perf_page.as(gtk.Widget), "performance");
        _ = self.stack.addNamed(self.startup.widget, "startup");
        _ = self.stack.addNamed(self.users.widget, "users");
        _ = self.stack.addNamed(self.tablePage(self.details, .details), "details");
        _ = self.stack.addNamed(self.services.widget, "services");
        _ = self.stack.addNamed(self.settingsPage(), "settings");
    }

    /// Processes and Details: the command bar over the table.
    fn tablePage(self: *TaskManager, tb: *Table, page: PageId) *gtk.Widget {
        const root = gtk.Box.new(.vertical, 0);
        const bar = services_mod.commandBar(page.title());
        const run = gtk.Button.newWithLabel(t("Run new task"));
        _ = gtk.Button.signals.clicked.connect(run, *TaskManager, &onRunTask, self, .{});
        bar.append(run.as(gtk.Widget));
        const end = gtk.Button.newWithLabel(t("End task"));
        _ = gtk.Button.signals.clicked.connect(end, *TaskManager, &onEndTask, self, .{});
        bar.append(end.as(gtk.Widget));
        self.process_buttons.append(self.gpa, end.as(gtk.Widget)) catch {};
        if (page == .processes) {
            const eff = gtk.ToggleButton.newWithLabel(t("Efficiency mode"));
            eff.as(gtk.Widget).setTooltipText(t("Run the process at the lowest priority, so it slows the rest of the computer least"));
            _ = gtk.ToggleButton.signals.toggled.connect(eff, *TaskManager, &onEfficiency, self, .{});
            bar.append(eff.as(gtk.Widget));
            self.efficiency_button = eff;
            self.process_buttons.append(self.gpa, eff.as(gtk.Widget)) catch {};
        } else {
            const props = gtk.Button.newWithLabel(t("Properties"));
            _ = gtk.Button.signals.clicked.connect(props, *TaskManager, &onProperties, self, .{});
            bar.append(props.as(gtk.Widget));
            self.process_buttons.append(self.gpa, props.as(gtk.Widget)) catch {};
        }
        // View: how processes are grouped, and the columns.
        const view_menu = gio.Menu.new();
        defer view_menu.as(gobject.Object).unref();
        if (page == .processes) {
            const modes = gio.Menu.new();
            modes.append(t("Group by type"), "table.mode::grouped");
            modes.append(t("Show as a tree"), "table.mode::tree");
            modes.append(t("One flat list"), "table.mode::flat");
            view_menu.appendSection(null, modes.as(gio.MenuModel));
            modes.as(gobject.Object).unref();
            const mode_action = gio.SimpleAction.newStateful("mode", glib.VariantType.new("s"), glib.Variant.newString(@tagName(tb.mode)));
            _ = gio.SimpleAction.signals.change_state.connect(mode_action, *Table, &onModeChosen, tb, .{});
            tb.action_group.as(gio.ActionMap).addAction(mode_action.as(gio.Action));
            mode_action.as(gobject.Object).unref();
        }
        const cols = tb.columnMenu();
        view_menu.appendSubmenu(t("Columns"), cols.as(gio.MenuModel));
        cols.as(gobject.Object).unref();
        const view_button = gtk.MenuButton.new();
        view_button.setLabel(t("View"));
        view_button.setMenuModel(view_menu.as(gio.MenuModel));
        bar.append(view_button.as(gtk.Widget));
        root.as(gtk.Widget).insertActionGroup("table", tb.action_group.as(gio.ActionGroup));
        root.append(bar.as(gtk.Widget));
        root.append(tb.widget);
        return root.as(gtk.Widget);
    }

    fn onModeChosen(action: *gio.SimpleAction, value: ?*glib.Variant, tb: *Table) callconv(.c) void {
        const v = value orelse return;
        const mode = std.meta.stringToEnum(table_mod.Mode, std.mem.span(v.getString(null))) orelse return;
        action.setState(v);
        tb.setMode(mode);
    }

    fn settingsPage(self: *TaskManager) *gtk.Widget {
        const root = gtk.Box.new(.vertical, 0);
        root.append(services_mod.commandBar(t("Settings")).as(gtk.Widget));
        const grid = gtk.Grid.new();
        grid.setRowSpacing(14);
        grid.setColumnSpacing(24);
        inline for (.{ "setMarginStart", "setMarginEnd", "setMarginTop" }) |m| @field(gtk.Widget, m)(grid.as(gtk.Widget), 24);

        const speeds = [_:null]?[*:0]const u8{ t("High (twice a second)"), t("Normal (every second)"), t("Low (every four seconds)"), t("Paused") };
        const speed = gtk.DropDown.newFromStrings(@ptrCast(&speeds));
        speed.setSelected(@intFromEnum(self.speed));
        _ = gobject.Object.signals.notify.connect(speed, *TaskManager, &onSpeedChosen, self, .{ .detail = "selected" });
        self.speed_dropdown = speed;
        settingRow(grid, 0, t("Real-time update speed"), t("How often the figures are read again. F5 updates them at once."), speed.as(gtk.Widget));

        var pages: [rail_pages.len + 1]?[*:0]const u8 = @splat(null);
        for (rail_pages, 0..) |p, i| pages[i] = p.title();
        const start = gtk.DropDown.newFromStrings(@ptrCast(&pages));
        const current = std.meta.stringToEnum(PageId, self.configString("start-page", "processes")) orelse .processes;
        start.setSelected(@intCast(std.mem.indexOfScalar(PageId, &rail_pages, current) orelse 0));
        _ = gobject.Object.signals.notify.connect(start, *TaskManager, &onStartChosen, self, .{ .detail = "selected" });
        settingRow(grid, 1, t("Default start page"), t("The page Task Manager opens on."), start.as(gtk.Widget));

        const shortcut = gtk.Label.new(t("Ctrl+Shift+Esc opens Task Manager, or brings it forward when it is open."));
        shortcut.setXalign(0);
        shortcut.setWrap(1);
        shortcut.as(gtk.Widget).addCssClass("dim-label");
        grid.attach(shortcut.as(gtk.Widget), 0, 2, 2, 1);
        root.append(grid.as(gtk.Widget));
        return root.as(gtk.Widget);
    }

    fn settingRow(grid: *gtk.Grid, row: c_int, title: [:0]const u8, detail: [:0]const u8, control: *gtk.Widget) void {
        const box = gtk.Box.new(.vertical, 2);
        const tl = gtk.Label.new(title);
        tl.setXalign(0);
        const dl = gtk.Label.new(detail);
        dl.setXalign(0);
        dl.setWrap(1);
        dl.as(gtk.Widget).addCssClass("dim-label");
        box.append(tl.as(gtk.Widget));
        box.append(dl.as(gtk.Widget));
        box.as(gtk.Widget).setHexpand(1);
        control.setValign(.center);
        grid.attach(box.as(gtk.Widget), 0, row, 1, 1);
        grid.attach(control, 1, row, 1, 1);
    }

    fn onSpeedChosen(dd: *gtk.DropDown, _: *gobject.ParamSpec, self: *TaskManager) callconv(.c) void {
        const i = dd.getSelected();
        if (i >= 4) return;
        const speed: Speed = @enumFromInt(i);
        self.setSpeed(speed);
        self.config.setString("tasks", "update-speed", @tagName(speed)) catch {};
    }

    fn onStartChosen(dd: *gtk.DropDown, _: *gobject.ParamSpec, self: *TaskManager) callconv(.c) void {
        const i = dd.getSelected();
        if (i >= rail_pages.len) return;
        self.config.setString("tasks", "start-page", @tagName(rail_pages[i])) catch {};
    }

    fn setSpeed(self: *TaskManager, speed: Speed) void {
        self.speed = speed;
        if (self.timer != 0) _ = glib.Source.remove(self.timer);
        self.timer = 0;
        if (speed.ms() > 0) self.timer = glib.timeoutAdd(speed.ms(), onTimer, self);
        if (self.speed_dropdown) |dd| if (dd.getSelected() != @intFromEnum(speed)) dd.setSelected(@intFromEnum(speed));
    }

    // ---- refreshing --------------------------------------------------------------------------

    fn onTimer(data: ?*anyopaque) callconv(.c) c_int {
        const self: *TaskManager = @ptrCast(@alignCast(data.?));
        self.refresh();
        return 1;
    }

    fn minimized(self: *TaskManager) bool {
        const surface = self.window.as(gtk.Native).getSurface() orelse return false;
        const toplevel: *gdk.Toplevel = @ptrCast(surface);
        return toplevel.getState().minimized;
    }

    fn refresh(self: *TaskManager) void {
        self.sampler.refresh();
        self.perf.update(&self.sampler);
        // Lists nobody sees are not touched: GTK's work on them would be most
        // of this program's CPU. They catch up when shown.
        if (self.minimized()) return;
        switch (self.page) {
            .processes => self.processes.rebuild(),
            .details => self.details.rebuild(),
            .users => {
                if (self.sampler.tick % 10 == 0) self.users.reload();
                self.users.refresh();
            },
            .services => self.services.refresh(),
            else => {},
        }
        self.updateButtons();
    }

    fn onRefreshed(owner: *anyopaque) void {
        const self: *TaskManager = @ptrCast(@alignCast(owner));
        self.refresh();
    }

    fn currentTable(self: *TaskManager) ?*Table {
        return switch (self.page) {
            .processes => self.processes,
            .details => self.details,
            else => null,
        };
    }

    fn updateButtons(self: *TaskManager) void {
        const tb = self.currentTable() orelse return;
        const pid = tb.selectedPid();
        for (self.process_buttons.items) |b| b.setSensitive(@intFromBool(pid != null));
        if (self.efficiency_button) |eff| {
            const on = if (pid) |p| (if (self.sampler.processes.getPtr(p)) |proc| proc.efficient() else false) else false;
            if ((eff.getActive() != 0) != on) {
                self.syncing = true;
                eff.setActive(@intFromBool(on));
                self.syncing = false;
            }
        }
    }

    fn onTableSelection(owner: *anyopaque) void {
        const self: *TaskManager = @ptrCast(@alignCast(owner));
        self.updateButtons();
    }

    fn onGoto(owner: *anyopaque, where: table_mod.Goto, pid: u32) void {
        const self: *TaskManager = @ptrCast(@alignCast(owner));
        switch (where) {
            .details => {
                self.showPage(.details);
                self.details.selectPid(pid);
            },
            .service => {
                const p = self.sampler.processes.getPtr(pid) orelse return;
                self.services.select(p.unitSlice());
                self.showPage(.services);
            },
        }
    }

    fn onShowUser(owner: *anyopaque, name: []const u8) void {
        const self: *TaskManager = @ptrCast(@alignCast(owner));
        self.showPage(.details);
        var zb: [40]u8 = undefined;
        self.search.as(gtk.Editable).setText(std.fmt.bufPrintSentinel(&zb, "{s}", .{name}, 0) catch return);
    }

    fn onCompact(owner: *anyopaque, on: bool) void {
        const self: *TaskManager = @ptrCast(@alignCast(owner));
        self.rail_box.as(gtk.Widget).setVisible(@intFromBool(!on));
    }

    fn onSearchChanged(entry: *gtk.SearchEntry, self: *TaskManager) callconv(.c) void {
        const text = std.mem.span(entry.as(gtk.Editable).getText());
        self.processes.setQuery(text);
        self.details.setQuery(text);
    }

    // ---- commands ----------------------------------------------------------------------------

    fn onRunTask(_: *gtk.Button, self: *TaskManager) callconv(.c) void {
        self.actions.runNewTask();
    }

    fn onEndTask(_: *gtk.Button, self: *TaskManager) callconv(.c) void {
        if (self.currentTable()) |tb| tb.endSelected();
    }

    fn onProperties(_: *gtk.Button, self: *TaskManager) callconv(.c) void {
        const tb = self.currentTable() orelse return;
        if (tb.selectedPid()) |pid| self.actions.properties(pid);
    }

    fn onEfficiency(button: *gtk.ToggleButton, self: *TaskManager) callconv(.c) void {
        if (self.syncing) return;
        const tb = self.currentTable() orelse return;
        const pid = tb.selectedPid() orelse return;
        const p = self.sampler.processes.getPtr(pid) orelse return;
        if ((button.getActive() != 0) == p.efficient()) return;
        self.actions.toggleEfficiency(pid);
    }

    fn onKey(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, state: gdk.ModifierType, self: *TaskManager) callconv(.c) c_int {
        switch (keyval) {
            gdk.KEY_F5 => {
                self.refresh();
                return 1;
            },
            gdk.KEY_Delete => {
                // Not while typing in a search field.
                if (self.window.as(gtk.Window).getFocus()) |f| if (f.getAncestor(gtk.Text.getGObjectType()) != null or gobject.typeCheckInstanceIsA(@ptrCast(f), gtk.Text.getGObjectType()) != 0) return 0;
                const tb = self.currentTable() orelse return 0;
                tb.endSelected();
                return 1;
            },
            gdk.KEY_f, gdk.KEY_e => if (state.control_mask) {
                _ = self.search.as(gtk.Widget).grabFocus();
                return 1;
            },
            else => {},
        }
        // Ctrl+1..7 pick a page.
        if (state.control_mask and keyval >= gdk.KEY_1 and keyval <= gdk.KEY_7) {
            const i = keyval - gdk.KEY_1;
            self.showPage(if (i < rail_pages.len) rail_pages[i] else .settings);
            return 1;
        }
        return 0;
    }

    fn onCloseRequest(_: *gtk.Window, self: *TaskManager) callconv(.c) c_int {
        const win = self.window.as(gtk.Window);
        const w = self.window.as(gtk.Widget);
        if (win.isMaximized() == 0 and w.getWidth() > 0) {
            self.config.setInt("tasks", "width", w.getWidth()) catch {};
            self.config.setInt("tasks", "height", w.getHeight()) catch {};
        }
        self.config.setBool("tasks", "maximized", win.isMaximized() != 0) catch {};
        return 0;
    }

    fn onDestroy(_: *gtk.ApplicationWindow, self: *TaskManager) callconv(.c) void {
        if (self.timer != 0) _ = glib.Source.remove(self.timer);
        self.processes.destroy();
        self.details.destroy();
        self.users.destroy();
        self.services.destroy();
        self.startup.destroy();
        self.perf.destroy();
        self.sampler.deinit();
        self.rail_labels.deinit(self.gpa);
        self.process_buttons.deinit(self.gpa);
        self.config.deinit();
        self.app.manager = null;
        self.gpa.destroy(self);
    }
};

/// One Task Manager at a time: a second start (Ctrl+Shift+Esc again)
/// brings the open one forward, on the page asked for.
const instance = struct {
    fn socketPath(buf: []u8) ?[:0]const u8 {
        const dir = std.mem.span(glib.getUserRuntimeDir());
        return std.fmt.bufPrintSentinel(buf, "{s}/dkde-tasks.sock", .{dir}, 0) catch null;
    }

    /// Tells a running Task Manager to show itself; true when one did.
    fn handOver(page: ?PageId) bool {
        var buf: [512]u8 = undefined;
        const path = socketPath(&buf) orelse return false;
        const addr = gio.UnixSocketAddress.new(path);
        defer addr.as(gobject.Object).unref();
        const client = gio.SocketClient.new();
        defer client.as(gobject.Object).unref();
        const conn = client.connect(addr.as(gio.SocketConnectable), null, null) orelse return false;
        defer conn.as(gobject.Object).unref();
        var mb: [32]u8 = undefined;
        const msg = std.fmt.bufPrint(&mb, "show {s}\n", .{if (page) |p| @tagName(p) else ""}) catch return false;
        const out = conn.as(gio.IOStream).getOutputStream();
        var written: usize = 0;
        _ = out.writeAll(msg.ptr, msg.len, &written, null, null);
        _ = conn.as(gio.IOStream).close(null, null);
        return true;
    }

    fn listen(manager: *TaskManager) void {
        var buf: [512]u8 = undefined;
        const path = socketPath(&buf) orelse return;
        std.Io.Dir.cwd().deleteFile(common.fsio.io(), path) catch {};
        const service = gio.SocketService.new();
        const addr = gio.UnixSocketAddress.new(path);
        defer addr.as(gobject.Object).unref();
        var err: ?*glib.Error = null;
        if (service.as(gio.SocketListener).addAddress(addr.as(gio.SocketAddress), .stream, .default, null, null, &err) == 0) {
            if (err) |e| e.free();
            return;
        }
        _ = gio.SocketService.signals.incoming.connect(service, *TaskManager, &onIncoming, manager, .{});
        service.start();
    }

    fn onIncoming(_: *gio.SocketService, conn: *gio.SocketConnection, _: ?*gobject.Object, manager: *TaskManager) callconv(.c) c_int {
        var buf: [64]u8 = undefined;
        const in = conn.as(gio.IOStream).getInputStream();
        const n = in.read(&buf, buf.len, null, null);
        if (n > 0) {
            const msg = std.mem.trim(u8, buf[0..@intCast(n)], " \n");
            if (std.mem.startsWith(u8, msg, "show ")) {
                if (std.meta.stringToEnum(PageId, msg["show ".len..])) |p| manager.showPage(p);
            }
        }
        manager.window.as(gtk.Window).present();
        return 1;
    }
};

pub const std_options: std.Options = .{ .logFn = common.log.logFn, .log_level = .debug };

pub fn main(init: std.process.Init.Minimal) !void {
    cli.handle(init.args, .{ .name = "dkde-tasks", .summary = "Task manager", .usage = "[--page PAGE] [--resource NAME]", .value_options = &.{ "--page", "--tab", "--resource" } });
    common.perf.init();
    var debug_allocator: common.perf.Gpa = .{};
    defer debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    var app: App = .{ .gpa = gpa };
    const args = init.args.vector;
    var i: usize = 1;
    while (i + 1 < args.len) : (i += 1) {
        const arg = std.mem.span(args[i]);
        if (std.mem.eql(u8, arg, "--tab") or std.mem.eql(u8, arg, "--page"))
            app.page = std.meta.stringToEnum(PageId, std.mem.span(args[i + 1]));
        if (std.mem.eql(u8, arg, "--resource")) {
            app.resource = std.mem.span(args[i + 1]);
            app.page = .performance;
        }
    }
    if (glib.getenv("DKDE_TASKS_NEW") == null and app.resource == null and instance.handOver(app.page)) return;
    defer if (app.appearance) |a| a.destroy();

    const gtk_app = gtk.Application.new("org.dkde.tasks", .{ .non_unique = true });
    defer gtk_app.as(gobject.Object).unref();
    common.runapp.quitAfterEnv(gtk_app);
    _ = gio.Application.signals.activate.connect(gtk_app, *App, &App.activate, &app, .{});
    // GApplication only gets the program name; --page is ours.
    var argv = [_]?[*:0]const u8{ init.args.vector[0], null };
    const status = gio.Application.run(gtk_app.as(gio.Application), 1, @ptrCast(&argv));
    if (status != 0) std.process.exit(@intCast(status));
}

test {
    _ = @import("proc.zig");
    _ = @import("perf.zig");
    _ = @import("perfview.zig");
    _ = @import("gpu.zig");
    _ = @import("sampler.zig");
    _ = @import("columns.zig");
    _ = @import("services.zig");
    _ = @import("users.zig");
    _ = @import("startup.zig");
    _ = @import("initsys.zig");
}
