//! The Startup apps page: what starts when you sign in.
//!
//! - Startup apps: the freedesktop autostart entries (common.autostart),
//!   which dkde-panel starts at the beginning of the session whatever the
//!   init system. Turning one off writes a copy into ~/.config/autostart
//!   with Hidden=true (the system's file is never touched); your own apps
//!   and commands are added the same way, and can be removed.
//! - Your services: the user services the service manager starts at login
//!   (systemd --user, or a dinit user instance as on Chimera Linux).
//! - The session script: the lines of ~/.config/labwc/autostart, shown;
//!   changed by editing the script.

const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

const simplelist = @import("simplelist.zig");
const services = @import("services.zig");
const initsys = @import("initsys.zig");

const autostart = common.autostart;
const t = common.tr;

pub const Source = enum { user, system, service, script };

pub const Entry = struct {
    entry: autostart.Entry = .{},
    source: Source = .system,
    /// Services: run by dinit (else systemd).
    dinit: bool = false,

    fn name(self: *const Entry) []const u8 {
        return autostart.Entry.get(&self.entry.name);
    }
};

/// The commands a labwc autostart script runs: its lines, without
/// comments and the trailing `&`.
pub fn scriptCommands(text: []const u8, out: [][]const u8) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        line = std.mem.trimEnd(u8, std.mem.trimEnd(u8, line, "&"), " ");
        if (line.len == 0 or n == out.len) continue;
        out[n] = line;
        n += 1;
    }
    return n;
}

/// The program a script line runs ("dkde-panel" in a restart loop).
pub fn guessName(line: []const u8) []const u8 {
    const programs = [_][]const u8{ "dkde-panel", "dkde-idle", "dkde-polkit", "display.sh" };
    for (programs) |p| if (std.mem.indexOf(u8, line, p) != null) return p;
    var it = std.mem.tokenizeAny(u8, line, " ();&");
    while (it.next()) |w| {
        if (std.mem.eql(u8, w, "while") or std.mem.eql(u8, w, "true") or std.mem.eql(u8, w, "do") or std.mem.eql(u8, w, "exec")) continue;
        return std.fs.path.basename(w);
    }
    return line;
}

const Col = enum { name, status, command, source };

pub const Page = struct {
    gpa: std.mem.Allocator,
    window: *gtk.Window,
    widget: *gtk.Widget,
    list: *simplelist.SimpleList,
    entries: std.ArrayList(Entry) = .empty,
    toggle: *gtk.Button,
    remove: *gtk.Button,
    location: *gtk.Button,
    boot_label: *gtk.Label,
    guard: *common.proc.Guard(Page),
    asked_boot: bool = false,
    user_init: initsys.Init,
    /// systemd's list of user units, kept between reloads.
    service_text: ?[]u8 = null,

    const specs = [_]simplelist.ColumnSpec{
        .{ .title = "Name", .width = 260 },
        .{ .title = "Status", .width = 100 },
        .{ .title = "Command", .expand = true },
        .{ .title = "From", .width = 170 },
    };

    pub fn create(gpa: std.mem.Allocator, window: *gtk.Window) *Page {
        const self = gpa.create(Page) catch @panic("OOM");
        self.* = .{
            .gpa = gpa,
            .window = window,
            .widget = undefined,
            .list = undefined,
            .toggle = gtk.Button.newWithLabel(t("Disable")),
            .remove = gtk.Button.newWithLabel(t("Remove")),
            .location = gtk.Button.newWithLabel(t("Open file location")),
            .boot_label = gtk.Label.new(""),
            .guard = undefined,
            .user_init = initsys.userInit(),
        };
        self.guard = common.proc.Guard(Page).create(self);
        self.list = simplelist.SimpleList.create(gpa, &specs, .{
            .owner = self,
            .text = text,
            .less = less,
            .key = key,
            .icon = icon,
            .activate = onActivate,
            .selection_changed = onSelection,
        });
        const root = gtk.Box.new(.vertical, 0);
        const bar = services.commandBar(t("Startup apps"));
        self.boot_label.as(gtk.Widget).addCssClass("dim-label");
        bar.append(self.boot_label.as(gtk.Widget));
        const add = gtk.Button.newWithLabel(t("Add…"));
        add.as(gtk.Widget).setTooltipText(t("Start an app or a command when you sign in"));
        _ = gtk.Button.signals.clicked.connect(add, *Page, &onAdd, self, .{});
        bar.append(add.as(gtk.Widget));
        for ([_]*gtk.Button{ self.remove, self.location, self.toggle }) |b| {
            b.as(gtk.Widget).setSensitive(0);
            bar.append(b.as(gtk.Widget));
        }
        _ = gtk.Button.signals.clicked.connect(self.toggle, *Page, &onToggle, self, .{});
        _ = gtk.Button.signals.clicked.connect(self.remove, *Page, &onRemove, self, .{});
        _ = gtk.Button.signals.clicked.connect(self.location, *Page, &onLocation, self, .{});
        root.append(bar.as(gtk.Widget));
        root.append(self.list.widget);
        self.widget = root.as(gtk.Widget);
        self.list.sortBy(0, false);
        return self;
    }

    pub fn destroy(self: *Page) void {
        self.guard.kill();
        self.list.destroy();
        self.entries.deinit(self.gpa);
        if (self.service_text) |x| self.gpa.free(x);
        self.gpa.destroy(self);
    }

    /// Reads everything again (when the page is shown, and after a change).
    pub fn reload(self: *Page) void {
        self.entries.clearRetainingCapacity();
        var found = autostart.list(self.gpa);
        defer found.deinit(self.gpa);
        for (found.items) |e| {
            // A user's file that hides an entry not meant for this desktop anyway.
            if (autostart.Entry.get(&e.name).len == 0) continue;
            self.entries.append(self.gpa, .{ .entry = e, .source = if (e.source == .user) .user else .system }) catch return;
        }
        self.readScript();
        self.addServices();
        self.list.update(self.entries.items.len);
        onSelection(self);
        self.askServices();
        if (!self.asked_boot and common.proc.hasProgram("systemd-analyze")) {
            self.asked_boot = true;
            common.proc.run(Page, self.guard, &.{ "systemd-analyze", "time" }, onBootTime);
        }
    }

    fn readScript(self: *Page) void {
        var pb: [512]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&pb, "{s}/labwc/autostart", .{std.mem.span(glib.getUserConfigDir())}, 0) catch return;
        var contents: [*]u8 = undefined;
        var length: usize = 0;
        if (glib.fileGetContents(path, &contents, &length, null) == 0) return;
        defer glib.free(contents);
        var lines: [32][]const u8 = undefined;
        const n = scriptCommands(contents[0..length], &lines);
        for (lines[0..n]) |line| {
            var e: Entry = .{ .source = .script };
            autostart.Entry.set(&e.entry.id, line);
            autostart.Entry.set(&e.entry.path, path);
            autostart.Entry.set(&e.entry.command, line);
            autostart.Entry.set(&e.entry.name, guessName(line));
            self.entries.append(self.gpa, e) catch return;
        }
    }

    // ---- the user's services ---------------------------------------------------------

    fn askServices(self: *Page) void {
        if (self.user_init != .systemd) return;
        common.proc.run(Page, self.guard, &.{ "systemctl", "--user", "list-unit-files", "--type=service", "--state=enabled,disabled", "--no-legend", "--no-pager" }, onServices);
    }

    fn onServices(self: *Page, ok: bool, out: []const u8) void {
        if (!ok) return;
        if (self.service_text) |x| self.gpa.free(x);
        self.service_text = self.gpa.dupe(u8, out) catch null;
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (self.entries.items[i].source == .service) _ = self.entries.orderedRemove(i) else i += 1;
        }
        self.addServices();
        self.list.update(self.entries.items.len);
        onSelection(self);
    }

    /// systemd: the user units enabled, and ones this page turned off;
    /// dinit: the user services, enabled when linked into boot.d.
    fn addServices(self: *Page) void {
        switch (self.user_init) {
            .systemd => {
                const out = self.service_text orelse return;
                var off = common.state.loadList(self.gpa, "tasks.state", "startup", "turned-off") catch std.ArrayList([]u8).empty;
                defer common.state.freeList(self.gpa, &off);
                var lines = std.mem.splitScalar(u8, out, '\n');
                while (lines.next()) |line| {
                    var it = std.mem.tokenizeScalar(u8, line, ' ');
                    const unit = it.next() orelse continue;
                    const state = it.next() orelse continue;
                    if (!std.mem.endsWith(u8, unit, ".service") or std.mem.endsWith(u8, unit, "@.service")) continue;
                    const enabled = std.mem.eql(u8, state, "enabled");
                    if (!enabled) {
                        const mine = for (off.items) |o| {
                            if (std.mem.eql(u8, o, unit)) break true;
                        } else false;
                        if (!mine) continue;
                    }
                    var e: Entry = .{ .source = .service };
                    autostart.Entry.set(&e.entry.id, unit);
                    autostart.Entry.set(&e.entry.name, unit[0 .. unit.len - ".service".len]);
                    autostart.Entry.set(&e.entry.command, "systemctl --user");
                    e.entry.enabled = enabled;
                    self.entries.append(self.gpa, e) catch return;
                }
            },
            .dinit => initsys.eachDinitFile(self.gpa, true, self, addDinit),
            .none => {},
        }
    }

    fn addDinit(self: *Page, name: []const u8, path: [:0]const u8) void {
        var e: Entry = .{ .source = .service, .dinit = true };
        autostart.Entry.set(&e.entry.id, name);
        autostart.Entry.set(&e.entry.path, path);
        autostart.Entry.set(&e.entry.name, name);
        autostart.Entry.set(&e.entry.command, "dinitctl --user");
        e.entry.enabled = initsys.dinitEnabled(true, name);
        self.entries.append(self.gpa, e) catch {};
    }

    fn onBootTime(self: *Page, ok: bool, out: []const u8) void {
        if (!ok) return;
        // "Startup finished in 7.1s (firmware) + 3.2s (loader) + ... = 17.8s"
        const line = std.mem.sliceTo(out, '\n');
        var b: [160]u8 = undefined;
        const firmware = before(line, "s (firmware)");
        const total = if (std.mem.lastIndexOfScalar(u8, line, '=')) |i| std.mem.trim(u8, line[i + 1 ..], " ") else "";
        const shown = if (firmware.len > 0)
            std.fmt.bufPrintSentinel(&b, "Last firmware (BIOS) time: {s} s   Last start-up: {s}", .{ firmware, total }, 0) catch ""
        else if (total.len > 0)
            std.fmt.bufPrintSentinel(&b, "Last start-up: {s}", .{total}, 0) catch ""
        else
            "";
        self.boot_label.setText(shown);
    }

    fn before(line: []const u8, marker: []const u8) []const u8 {
        const end = std.mem.indexOf(u8, line, marker) orelse return "";
        var start = end;
        while (start > 0 and (std.ascii.isDigit(line[start - 1]) or line[start - 1] == '.' or line[start - 1] == 'm' or line[start - 1] == 'i' or line[start - 1] == 'n')) start -= 1;
        return line[start..end];
    }

    // ---- the list -------------------------------------------------------------------------

    fn text(owner: *anyopaque, row: usize, col: usize, _: []u8) []const u8 {
        const self: *Page = @ptrCast(@alignCast(owner));
        const e = &self.entries.items[row];
        return switch (@as(Col, @enumFromInt(col))) {
            .name => e.name(),
            .status => if (e.entry.enabled) "Enabled" else "Disabled",
            .command => autostart.Entry.get(&e.entry.command),
            .source => switch (e.source) {
                .user => if (e.entry.added) "Added by you" else if (e.entry.has_system) "System (changed by you)" else "Yours",
                .system => "System",
                .service => if (e.dinit) "Your services (dinit)" else "Your services (systemd)",
                .script => "Session script",
            },
        };
    }

    fn less(owner: *anyopaque, a: usize, b: usize, col: usize) bool {
        var ba: [8]u8 = undefined;
        var bb: [8]u8 = undefined;
        const order = std.ascii.orderIgnoreCase(text(owner, a, col, &ba), text(owner, b, col, &bb));
        if (order != .eq) return order == .lt;
        return std.ascii.lessThanIgnoreCase(text(owner, a, 0, &ba), text(owner, b, 0, &bb));
    }

    fn key(owner: *anyopaque, row: usize) u64 {
        const self: *Page = @ptrCast(@alignCast(owner));
        const e = &self.entries.items[row];
        return simplelist.hashKey(autostart.Entry.get(&e.entry.id)) +% @intFromEnum(e.source) +% @as(u64, @intFromBool(e.entry.enabled)) * 7;
    }

    fn icon(owner: *anyopaque, row: usize) [:0]const u8 {
        const self: *Page = @ptrCast(@alignCast(owner));
        const e = &self.entries.items[row];
        return switch (e.source) {
            .script => "utilities-terminal",
            .service => "system-run",
            else => blk: {
                const name = autostart.Entry.getZ(&e.entry.icon);
                break :blk if (name.len > 0) name else "application-x-executable";
            },
        };
    }

    fn selected(self: *Page) ?*Entry {
        const row = self.list.selectedRow() orelse return null;
        if (row >= self.entries.items.len) return null;
        return &self.entries.items[row];
    }

    fn onSelection(owner: *anyopaque) void {
        const self: *Page = @ptrCast(@alignCast(owner));
        const e = self.selected();
        self.toggle.as(gtk.Widget).setSensitive(@intFromBool(e != null and e.?.source != .script));
        self.location.as(gtk.Widget).setSensitive(@intFromBool(e != null and autostart.Entry.get(&e.?.entry.path).len > 0));
        self.remove.as(gtk.Widget).setSensitive(@intFromBool(e != null and e.?.source == .user and !e.?.entry.has_system));
        self.toggle.setLabel(if (e != null and !e.?.entry.enabled) t("Enable") else t("Disable"));
        self.toggle.as(gtk.Widget).setTooltipText(if (e != null and e.?.source == .script) t("Edit ~/.config/labwc/autostart to change what the session script starts") else null);
    }

    fn onActivate(owner: *anyopaque, _: usize) void {
        const self: *Page = @ptrCast(@alignCast(owner));
        onToggle(self.toggle, self);
    }

    fn onToggle(_: *gtk.Button, self: *Page) callconv(.c) void {
        const e = self.selected() orelse return;
        const on = !e.entry.enabled;
        const id = autostart.Entry.get(&e.entry.id);
        switch (e.source) {
            .script => return,
            .user, .system => {
                autostart.setEnabled(id, on) catch return common.dialogs.showError(self.window, t("The change could not be saved"), null);
                self.reload();
            },
            .service => {
                var nb: [128]u8 = undefined;
                const name = std.fmt.bufPrint(&nb, "{s}", .{id}) catch return;
                if (!e.dinit) self.rememberTurnedOff(name, !on);
                const tool: []const u8 = if (e.dinit) "dinitctl" else "systemctl";
                common.proc.run(Page, self.guard, &.{ tool, "--user", if (on) "enable" else "disable", name }, onServiceChanged);
            },
        }
    }

    /// systemd lists a disabled unit like any never enabled: the ones turned
    /// off here are remembered, so they stay on the page to turn on again.
    fn rememberTurnedOff(self: *Page, unit: []const u8, off: bool) void {
        var names = common.state.loadList(self.gpa, "tasks.state", "startup", "turned-off") catch std.ArrayList([]u8).empty;
        defer common.state.freeList(self.gpa, &names);
        var i: usize = 0;
        while (i < names.items.len) {
            if (std.mem.eql(u8, names.items[i], unit)) self.gpa.free(names.orderedRemove(i)) else i += 1;
        }
        if (off) names.append(self.gpa, self.gpa.dupe(u8, unit) catch return) catch return;
        common.state.saveList(self.gpa, "tasks.state", "startup", "turned-off", names.items) catch {};
    }

    fn onServiceChanged(self: *Page, ok: bool, _: []const u8) void {
        if (!ok) common.dialogs.showError(self.window, t("The service could not be changed"), null);
        self.reload();
    }

    fn onRemove(_: *gtk.Button, self: *Page) callconv(.c) void {
        const e = self.selected() orelse return;
        if (e.source != .user or e.entry.has_system) return;
        autostart.remove(autostart.Entry.get(&e.entry.id)) catch return common.dialogs.showError(self.window, t("The entry could not be removed"), null);
        self.reload();
    }

    /// The folder the entry's file was read from, with the file selected.
    fn onLocation(_: *gtk.Button, self: *Page) callconv(.c) void {
        const e = self.selected() orelse return;
        const path = autostart.Entry.get(&e.entry.path);
        const dir = std.fs.path.dirname(path) orelse return;
        common.appinfo.spawnIn(self.gpa, &.{ "dkde-files", dir }, dir);
    }

    // ---- adding an app or a command -------------------------------------------------

    const Add = struct {
        page: *Page,
        window: *gtk.Window,
        name: *gtk.Entry,
        command: *gtk.Entry,
        terminal: *gtk.CheckButton,
        apps: *gtk.ListBox,
        search: *gtk.SearchEntry,
        infos: std.ArrayList(*gio.AppInfo) = .empty,
        icon: [128]u8 = @splat(0),
    };

    fn onAdd(_: *gtk.Button, self: *Page) callconv(.c) void {
        const st = self.gpa.create(Add) catch return;
        st.* = .{
            .page = self,
            .window = gtk.Window.new(),
            .name = gtk.Entry.new(),
            .command = gtk.Entry.new(),
            .terminal = gtk.CheckButton.newWithLabel(t("Run it in a terminal")),
            .apps = gtk.ListBox.new(),
            .search = gtk.SearchEntry.new(),
        };
        const win = st.window;
        win.setTitle(t("Add a startup app"));
        win.setTransientFor(self.window);
        win.setModal(1);
        win.setDefaultSize(520, 560);
        win.as(gtk.Widget).addCssClass("dkde");
        const box = gtk.Box.new(.vertical, 8);
        inline for (.{ "setMarginStart", "setMarginEnd", "setMarginTop", "setMarginBottom" }) |m| @field(gtk.Widget, m)(box.as(gtk.Widget), 14);
        const intro = gtk.Label.new(t("Choose an app, or type any command. It starts each time you sign in."));
        intro.setXalign(0);
        intro.setWrap(1);
        box.append(intro.as(gtk.Widget));
        st.search.setPlaceholderText(t("Search apps"));
        _ = gtk.SearchEntry.signals.search_changed.connect(st.search, *Add, &onAddSearch, st, .{});
        box.append(st.search.as(gtk.Widget));
        st.apps.setSelectionMode(.single);
        _ = gtk.ListBox.signals.row_selected.connect(st.apps, *Add, &onAppChosen, st, .{});
        st.apps.setFilterFunc(filterApps, st, null);
        self.fillApps(st);
        const scroller = gtk.ScrolledWindow.new();
        scroller.setChild(st.apps.as(gtk.Widget));
        scroller.as(gtk.Widget).setVexpand(1);
        box.append(scroller.as(gtk.Widget));
        const grid = gtk.Grid.new();
        grid.setRowSpacing(6);
        grid.setColumnSpacing(10);
        const nl = gtk.Label.new(t("Name"));
        nl.setXalign(1);
        const cl = gtk.Label.new(t("Command"));
        cl.setXalign(1);
        st.name.as(gtk.Widget).setHexpand(1);
        st.command.setPlaceholderText(t("for example: syncthing serve --no-browser"));
        grid.attach(nl.as(gtk.Widget), 0, 0, 1, 1);
        grid.attach(st.name.as(gtk.Widget), 1, 0, 1, 1);
        grid.attach(cl.as(gtk.Widget), 0, 1, 1, 1);
        grid.attach(st.command.as(gtk.Widget), 1, 1, 1, 1);
        grid.attach(st.terminal.as(gtk.Widget), 1, 2, 1, 1);
        box.append(grid.as(gtk.Widget));
        const buttons = gtk.Box.new(.horizontal, 6);
        buttons.as(gtk.Widget).setHalign(.end);
        const cancel = gtk.Button.newWithLabel(t("Cancel"));
        const ok = gtk.Button.newWithLabel(t("Add"));
        ok.as(gtk.Widget).addCssClass("suggested-action");
        buttons.append(cancel.as(gtk.Widget));
        buttons.append(ok.as(gtk.Widget));
        box.append(buttons.as(gtk.Widget));
        win.setChild(box.as(gtk.Widget));
        _ = gtk.Button.signals.clicked.connect(cancel, *Add, &onAddCancel, st, .{});
        _ = gtk.Button.signals.clicked.connect(ok, *Add, &onAddOk, st, .{});
        _ = gtk.Widget.signals.destroy.connect(win, *Add, &onAddDestroy, st, .{});
        win.present();
    }

    fn fillApps(self: *Page, st: *Add) void {
        const all = gio.AppInfo.getAll();
        defer all.free();
        var node: ?*glib.List = all;
        while (node) |n| : (node = n.f_next) {
            const info: *gio.AppInfo = @ptrCast(@alignCast(n.f_data orelse continue));
            if (info.shouldShow() == 0) {
                info.as(gobject.Object).unref();
                continue;
            }
            st.infos.append(self.gpa, info) catch {
                info.as(gobject.Object).unref();
                continue;
            };
        }
        std.mem.sort(*gio.AppInfo, st.infos.items, {}, struct {
            fn lt(_: void, a: *gio.AppInfo, b: *gio.AppInfo) bool {
                return std.ascii.lessThanIgnoreCase(std.mem.span(a.getDisplayName()), std.mem.span(b.getDisplayName()));
            }
        }.lt);
        for (st.infos.items) |info| {
            const row = gtk.Box.new(.horizontal, 8);
            inline for (.{ "setMarginStart", "setMarginEnd", "setMarginTop", "setMarginBottom" }) |m| @field(gtk.Widget, m)(row.as(gtk.Widget), 4);
            const img = if (info.getIcon()) |gi| gtk.Image.newFromGicon(gi) else gtk.Image.newFromIconName("application-x-executable");
            img.setPixelSize(24);
            row.append(img.as(gtk.Widget));
            const l = gtk.Label.new(info.getDisplayName());
            l.setXalign(0);
            row.append(l.as(gtk.Widget));
            st.apps.append(row.as(gtk.Widget));
        }
    }

    fn filterApps(row: *gtk.ListBoxRow, data: ?*anyopaque) callconv(.c) c_int {
        const st: *Add = @ptrCast(@alignCast(data.?));
        const q = std.mem.span(st.search.as(gtk.Editable).getText());
        if (q.len == 0) return 1;
        const i: usize = @intCast(row.getIndex());
        if (i >= st.infos.items.len) return 0;
        return @intFromBool(std.ascii.findIgnoreCase(std.mem.span(st.infos.items[i].getDisplayName()), q) != null);
    }

    fn onAddSearch(_: *gtk.SearchEntry, st: *Add) callconv(.c) void {
        st.apps.invalidateFilter();
    }

    fn onAppChosen(_: *gtk.ListBox, row: ?*gtk.ListBoxRow, st: *Add) callconv(.c) void {
        const r = row orelse return;
        const i: usize = @intCast(r.getIndex());
        if (i >= st.infos.items.len) return;
        const info = st.infos.items[i];
        st.name.as(gtk.Editable).setText(info.getDisplayName());
        // The entry's command, without its %f/%u field codes.
        var cb: [512]u8 = undefined;
        var n: usize = 0;
        if (info.getCommandline()) |cl| {
            var it = std.mem.tokenizeScalar(u8, std.mem.span(cl), ' ');
            while (it.next()) |w| {
                if (w.len == 2 and w[0] == '%') continue;
                if (n > 0 and n < cb.len - 1) {
                    cb[n] = ' ';
                    n += 1;
                }
                const k = @min(w.len, cb.len - 1 - n);
                @memcpy(cb[n..][0..k], w[0..k]);
                n += k;
            }
        }
        cb[n] = 0;
        st.command.as(gtk.Editable).setText(cb[0..n :0]);
        @memset(&st.icon, 0);
        if (info.getIcon()) |gi| if (gi.toString()) |s| {
            defer glib.free(s);
            autostart.Entry.set(&st.icon, std.mem.span(s));
        };
        const desktop: *@import("giounix2").DesktopAppInfo = @ptrCast(info);
        st.terminal.setActive(desktop.getBoolean("Terminal"));
    }

    fn onAddCancel(_: *gtk.Button, st: *Add) callconv(.c) void {
        st.window.destroy();
    }

    fn onAddOk(_: *gtk.Button, st: *Add) callconv(.c) void {
        const command = std.mem.trim(u8, std.mem.span(st.command.as(gtk.Editable).getText()), " ");
        if (command.len == 0) return common.dialogs.showError(st.window, t("Type a command, or choose an app"), null);
        var argc: c_int = 0;
        var argv: ?[*:null]?[*:0]u8 = null;
        var zb: [1024]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&zb, "{s}", .{command}, 0) catch return;
        if (glib.shellParseArgv(z, &argc, @ptrCast(&argv), null) == 0) {
            return common.dialogs.showError(st.window, t("That command is not complete"), t("A quote may be missing."));
        }
        glib.strfreev(@ptrCast(argv));
        var name = std.mem.trim(u8, std.mem.span(st.name.as(gtk.Editable).getText()), " ");
        if (name.len == 0) name = guessName(command);
        var idb: [96]u8 = undefined;
        const page = st.page;
        _ = autostart.addCommand(&idb, name, command, autostart.Entry.get(&st.icon), st.terminal.getActive() != 0) catch
            return common.dialogs.showError(st.window, t("The startup app could not be saved"), null);
        st.window.destroy();
        page.reload();
    }

    fn onAddDestroy(_: *gtk.Window, st: *Add) callconv(.c) void {
        for (st.infos.items) |i| i.as(gobject.Object).unref();
        st.infos.deinit(st.page.gpa);
        st.page.gpa.destroy(st);
    }
};

test "autostart script lines" {
    var out: [8][]const u8 = undefined;
    const n = scriptCommands("# comment\n(while true; do dkde-panel; sleep 1; done) &\n\ndkde-idle &\n", &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("dkde-idle", out[1]);
    try std.testing.expectEqualStrings("dkde-panel", guessName(out[0]));
}
