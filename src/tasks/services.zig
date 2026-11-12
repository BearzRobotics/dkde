//! The Services page: the system's services and the user's own, with their
//! state, how they start, and the process running each; started, stopped,
//! restarted, set to start automatically or not, and their logs. Both
//! systemd (systemctl, journalctl) and dinit (dinitctl, as on Chimera
//! Linux) are understood; which one runs is found at start. Changing a
//! system service, and on dinit even reading its state, needs the
//! administrator password.

const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

const simplelist = @import("simplelist.zig");
const initsys = @import("initsys.zig");
const Init = initsys.Init;
const Sampler = @import("sampler.zig").Sampler;

const t = common.tr;

pub const Service = struct {
    name: [128]u8 = @splat(0),
    description: [160]u8 = @splat(0),
    active: [16]u8 = @splat(0),
    sub: [16]u8 = @splat(0),
    file_state: [20]u8 = @splat(0),
    user: bool = false,
    pid: u32 = 0,
    /// Run by dinit (else systemd).
    dinit: bool = false,
    /// dinit: where the service writes its output, if set.
    logfile: [256]u8 = @splat(0),

    pub fn nameSlice(self: *const Service) []const u8 {
        return std.mem.sliceTo(&self.name, 0);
    }
    pub fn get(field: anytype) []const u8 {
        return std.mem.sliceTo(field, 0);
    }
    pub fn set(field: anytype, value: []const u8) void {
        const n = @min(value.len, field.len - 1);
        @memcpy(field[0..n], value[0..n]);
        field[n] = 0;
    }

    /// "Running", "Stopped", "Failed", ...
    pub fn status(self: *const Service) []const u8 {
        const a = get(&self.active);
        const sub = get(&self.sub);
        if (std.mem.eql(u8, a, "active")) {
            if (std.mem.eql(u8, sub, "running")) return "Running";
            if (std.mem.eql(u8, sub, "exited")) return "Done (exited)";
            return "Active";
        }
        if (std.mem.eql(u8, a, "failed")) return "Failed";
        if (std.mem.eql(u8, a, "activating")) return "Starting";
        if (std.mem.eql(u8, a, "deactivating")) return "Stopping";
        if (std.mem.eql(u8, a, "unknown")) return "—";
        return "Stopped";
    }

    /// The Windows names: Automatic, Manual, Disabled.
    pub fn startup(self: *const Service) []const u8 {
        const s = get(&self.file_state);
        if (std.mem.eql(u8, s, "enabled") or std.mem.eql(u8, s, "enabled-runtime") or std.mem.eql(u8, s, "generated")) return "Automatic";
        if (std.mem.eql(u8, s, "disabled")) return "Manual (disabled)";
        if (std.mem.startsWith(u8, s, "masked")) return "Masked (never)";
        if (std.mem.eql(u8, s, "static") or std.mem.eql(u8, s, "indirect")) return "Manual (when needed)";
        if (std.mem.eql(u8, s, "alias")) return "Alias";
        return if (s.len == 0) "Manual (when needed)" else s;
    }

    pub fn running(self: *const Service) bool {
        return std.mem.eql(u8, get(&self.active), "active") or std.mem.eql(u8, get(&self.active), "activating");
    }
};

/// "UNIT LOAD ACTIVE SUB DESCRIPTION" lines of `systemctl list-units --plain`.
pub fn parseUnits(gpa: std.mem.Allocator, out: *std.ArrayList(Service), text: []const u8, user: bool) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " ");
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        var unit = it.next() orelse continue;
        // Failed units may be marked with a dot.
        if (std.mem.eql(u8, unit, "●") or std.mem.eql(u8, unit, "*")) unit = it.next() orelse continue;
        if (!std.mem.endsWith(u8, unit, ".service")) continue;
        const load = it.next() orelse continue;
        if (std.mem.eql(u8, load, "not-found")) continue;
        const active = it.next() orelse continue;
        const sub = it.next() orelse continue;
        var s: Service = .{ .user = user };
        Service.set(&s.name, unit);
        Service.set(&s.active, active);
        Service.set(&s.sub, sub);
        Service.set(&s.description, std.mem.trim(u8, it.rest(), " "));
        out.append(gpa, s) catch return;
    }
}

/// "UNIT STATE PRESET" lines of `systemctl list-unit-files`: fills in how
/// listed services start, and adds the ones not loaded (stopped).
pub fn parseUnitFiles(gpa: std.mem.Allocator, out: *std.ArrayList(Service), text: []const u8, user: bool) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var it = std.mem.tokenizeScalar(u8, raw, ' ');
        const unit = it.next() orelse continue;
        const state = it.next() orelse continue;
        if (!std.mem.endsWith(u8, unit, ".service")) continue;
        // Templates ("getty@.service") are not services of their own.
        if (std.mem.endsWith(u8, unit, "@.service")) continue;
        const found = for (out.items) |*s| {
            if (s.user == user and std.mem.eql(u8, s.nameSlice(), unit)) break s;
        } else blk: {
            var s: Service = .{ .user = user };
            Service.set(&s.name, unit);
            Service.set(&s.active, "inactive");
            Service.set(&s.sub, "dead");
            out.append(gpa, s) catch return;
            break :blk &out.items[out.items.len - 1];
        };
        Service.set(&found.file_state, state);
    }
}

/// `dinitctl list`: the state of each loaded service.
pub fn parseDinitList(gpa: std.mem.Allocator, out: *std.ArrayList(Service), text: []const u8, user: bool) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const d = initsys.parseDinitLine(line) orelse continue;
        var s: Service = .{ .user = user, .dinit = true, .pid = d.pid };
        Service.set(&s.name, d.name);
        Service.set(&s.active, switch (d.state) {
            .started => "active",
            .starting => "activating",
            .stopping => "deactivating",
            .failed => "failed",
            .stopped => "inactive",
        });
        Service.set(&s.sub, if (d.pid != 0) "running" else if (d.state == .started) "started" else "dead");
        out.append(gpa, s) catch return;
    }
}

const DirScan = struct {
    gpa: std.mem.Allocator,
    out: *std.ArrayList(Service),
    user: bool,
    /// The states could not be read (system socket is root's): "unknown".
    unknown: bool,

    fn found(self: *const DirScan, name: []const u8, path: [:0]const u8) void {
        const s = for (self.out.items) |*x| {
            if (x.dinit and x.user == self.user and std.mem.eql(u8, x.nameSlice(), name)) break x;
        } else blk: {
            var x: Service = .{ .user = self.user, .dinit = true };
            Service.set(&x.name, name);
            Service.set(&x.active, if (self.unknown) "unknown" else "inactive");
            Service.set(&x.sub, "dead");
            self.out.append(self.gpa, x) catch return;
            break :blk &self.out.items[self.out.items.len - 1];
        };
        var contents: [*]u8 = undefined;
        var length: usize = 0;
        if (glib.fileGetContents(path, &contents, &length, null) != 0) {
            defer glib.free(contents);
            const f = initsys.parseDinitFile(contents[0..@min(length, 64 * 1024)]);
            Service.set(&s.description, std.mem.sliceTo(&f.description, 0));
            Service.set(&s.logfile, std.mem.sliceTo(&f.logfile, 0));
        }
        Service.set(&s.file_state, if (initsys.dinitEnabled(self.user, name)) "enabled" else "disabled");
    }
};

/// Adds the services dinit has not loaded, and how each starts, from the
/// service directories.
pub fn scanDinit(gpa: std.mem.Allocator, out: *std.ArrayList(Service), user: bool, states_known: bool) void {
    const scan: DirScan = .{ .gpa = gpa, .out = out, .user = user, .unknown = !states_known };
    initsys.eachDinitFile(gpa, user, &scan, DirScan.found);
}

const Col = enum { name, pid, description, status, startup, kind };

/// What one of the list commands is.
const Job = struct { kind: enum { units, files, dinit }, user: bool };

pub const Page = struct {
    gpa: std.mem.Allocator,
    window: *gtk.Window,
    sampler: *Sampler,
    widget: *gtk.Widget,
    list: *simplelist.SimpleList,
    services: std.ArrayList(Service) = .empty,
    incoming: std.ArrayList(Service) = .empty,
    jobs: [4]Job = undefined,
    outputs: [4]?[]u8 = @splat(null),
    job_count: usize = 0,
    pending: u8 = 0,
    guard: *common.proc.Guard(Page),
    sys_init: Init,
    user_init: Init,
    /// dinit's system states need root; read once with the password.
    sys_states: ?[]u8 = null,
    states_button: *gtk.Button,
    search: *gtk.SearchEntry,
    query: [64]u8 = undefined,
    query_len: usize = 0,
    shown: std.ArrayList(usize) = .empty,
    buttons: [6]*gtk.Button = undefined,
    status_label: *gtk.Label,
    loaded: bool = false,
    wanted: [128]u8 = undefined,
    wanted_len: usize = 0,
    action_group: *gio.SimpleActionGroup,
    menu: *gio.Menu,
    /// The service whose details or log are being read.
    reading: Service = .{},
    reading_what: enum { details, log } = .details,

    const specs = [_]simplelist.ColumnSpec{
        .{ .title = "Name", .width = 260 },
        .{ .title = "PID", .right = true, .width = 70 },
        .{ .title = "Description", .expand = true },
        .{ .title = "Status", .width = 120 },
        .{ .title = "Startup type", .width = 150 },
        .{ .title = "Kind", .width = 70 },
    };

    pub fn create(gpa: std.mem.Allocator, window: *gtk.Window, sampler: *Sampler) *Page {
        const self = gpa.create(Page) catch @panic("OOM");
        self.* = .{
            .gpa = gpa,
            .window = window,
            .sampler = sampler,
            .widget = undefined,
            .list = undefined,
            .guard = undefined,
            .sys_init = initsys.systemInit(),
            .user_init = initsys.userInit(),
            .states_button = gtk.Button.newWithLabel(t("Show states…")),
            .search = gtk.SearchEntry.new(),
            .status_label = gtk.Label.new(""),
            .action_group = gio.SimpleActionGroup.new(),
            .menu = gio.Menu.new(),
        };
        self.guard = common.proc.Guard(Page).create(self);
        self.list = simplelist.SimpleList.create(gpa, &specs, .{
            .owner = self,
            .text = text,
            .less = less,
            .key = key,
            .menu = onMenu,
            .activate = onActivate,
            .selection_changed = onSelection,
        });

        const root = gtk.Box.new(.vertical, 0);
        const bar = commandBar(t("Services"));
        self.search.setPlaceholderText(t("Search services"));
        self.search.as(gtk.Widget).setSizeRequest(220, -1);
        _ = gtk.SearchEntry.signals.search_changed.connect(self.search, *Page, &onSearch, self, .{});
        bar.append(self.search.as(gtk.Widget));
        self.states_button.as(gtk.Widget).setTooltipText(t("dinit tells the state of system services only to the administrator"));
        self.states_button.as(gtk.Widget).setVisible(0);
        _ = gtk.Button.signals.clicked.connect(self.states_button, *Page, &onReadStates, self, .{});
        bar.append(self.states_button.as(gtk.Widget));
        const names = [_][:0]const u8{ "Start", "Stop", "Restart", "Enable", "Disable", "Logs" };
        const tips = [_][:0]const u8{ "Start the service now", "Stop the service now", "Stop and start it again", "Start it each time the computer (or, for your services, your session) starts", "Do not start it at start-up; it can still be started by hand or when another service needs it", "What the service has written to its log" };
        for (names, 0..) |n, i| {
            const b = gtk.Button.newWithLabel(n);
            b.as(gtk.Widget).setTooltipText(tips[i]);
            b.as(gtk.Widget).setSensitive(0);
            _ = gtk.Button.signals.clicked.connect(b, *Page, &onButton, self, .{});
            self.buttons[i] = b;
            bar.append(b.as(gtk.Widget));
        }
        root.append(bar.as(gtk.Widget));
        root.append(self.list.widget);
        self.status_label.setXalign(0);
        self.status_label.setWrap(1);
        self.status_label.as(gtk.Widget).addCssClass("dim-label");
        self.status_label.as(gtk.Widget).setMarginStart(12);
        self.status_label.as(gtk.Widget).setMarginTop(4);
        self.status_label.as(gtk.Widget).setMarginBottom(4);
        root.append(self.status_label.as(gtk.Widget));
        self.widget = root.as(gtk.Widget);

        for ([_][:0]const u8{ "start", "stop", "restart", "enable", "disable", "mask", "unmask", "details", "log" }) |name| {
            const action = gio.SimpleAction.new(name, null);
            _ = gio.SimpleAction.signals.activate.connect(action, *Page, &onAction, self, .{});
            self.action_group.as(gio.ActionMap).addAction(action.as(gio.Action));
            action.as(gobject.Object).unref();
        }
        self.menu.append(t("Start"), "svc.start");
        self.menu.append(t("Stop"), "svc.stop");
        self.menu.append(t("Restart"), "svc.restart");
        self.menu.append(t("Enable (start at start-up)"), "svc.enable");
        self.menu.append(t("Disable (do not start at start-up)"), "svc.disable");
        self.menu.append(t("Mask (never let it start)"), "svc.mask");
        self.menu.append(t("Unmask"), "svc.unmask");
        self.menu.append(t("Details…"), "svc.details");
        self.menu.append(t("Logs…"), "svc.log");
        self.list.view.as(gtk.Widget).insertActionGroup("svc", self.action_group.as(gio.ActionGroup));
        return self;
    }

    pub fn destroy(self: *Page) void {
        self.guard.kill();
        self.list.destroy();
        self.services.deinit(self.gpa);
        self.incoming.deinit(self.gpa);
        self.shown.deinit(self.gpa);
        for (self.outputs) |o| if (o) |x| self.gpa.free(x);
        if (self.sys_states) |x| self.gpa.free(x);
        self.menu.as(gobject.Object).unref();
        self.gpa.destroy(self);
    }

    fn addJob(self: *Page, job: Job, argv: []const []const u8) void {
        const i = self.job_count;
        self.jobs[i] = job;
        self.job_count += 1;
        self.pending += 1;
        const handlers = [_]*const fn (*Page, bool, []const u8) void{ on0, on1, on2, on3 };
        common.proc.run(Page, self.guard, argv, handlers[i]);
    }

    /// Reads the services again (when the page is shown, and after a change).
    pub fn reload(self: *Page) void {
        if (self.pending > 0) return;
        self.job_count = 0;
        switch (self.sys_init) {
            .systemd => {
                self.addJob(.{ .kind = .units, .user = false }, &.{ "systemctl", "list-units", "--type=service", "--all", "--no-legend", "--plain", "--no-pager" });
                self.addJob(.{ .kind = .files, .user = false }, &.{ "systemctl", "list-unit-files", "--type=service", "--no-legend", "--no-pager" });
            },
            .dinit => self.addJob(.{ .kind = .dinit, .user = false }, &.{ "dinitctl", "--system", "list" }),
            .none => {},
        }
        switch (self.user_init) {
            .systemd => {
                self.addJob(.{ .kind = .units, .user = true }, &.{ "systemctl", "--user", "list-units", "--type=service", "--all", "--no-legend", "--plain", "--no-pager" });
                self.addJob(.{ .kind = .files, .user = true }, &.{ "systemctl", "--user", "list-unit-files", "--type=service", "--no-legend", "--no-pager" });
            },
            .dinit => self.addJob(.{ .kind = .dinit, .user = true }, &.{ "dinitctl", "--user", "list" }),
            .none => {},
        }
        if (self.job_count == 0) {
            self.status_label.setText(t("No service manager this page knows (systemd or dinit) runs on this system."));
        }
    }

    fn on0(self: *Page, ok: bool, out: []const u8) void {
        self.got(0, ok, out);
    }
    fn on1(self: *Page, ok: bool, out: []const u8) void {
        self.got(1, ok, out);
    }
    fn on2(self: *Page, ok: bool, out: []const u8) void {
        self.got(2, ok, out);
    }
    fn on3(self: *Page, ok: bool, out: []const u8) void {
        self.got(3, ok, out);
    }

    fn got(self: *Page, i: usize, ok: bool, out: []const u8) void {
        if (self.outputs[i]) |o| self.gpa.free(o);
        self.outputs[i] = if (ok) self.gpa.dupe(u8, out) catch null else null;
        self.pending -= 1;
        if (self.pending > 0) return;
        self.merge();
    }

    fn merge(self: *Page) void {
        const a = self.gpa;
        self.incoming.clearRetainingCapacity();
        var sys_dinit_known = true;
        for (self.jobs[0..self.job_count], 0..) |job, i| {
            const o = self.outputs[i];
            switch (job.kind) {
                .units => if (o) |x| parseUnits(a, &self.incoming, x, job.user),
                .files => if (o) |x| parseUnitFiles(a, &self.incoming, x, job.user),
                .dinit => {
                    // The system socket is root's: the states read with the
                    // password stand in until the next reading works.
                    const states = o orelse if (!job.user) self.sys_states else null;
                    if (states) |x| parseDinitList(a, &self.incoming, x, job.user);
                    if (!job.user and states == null) sys_dinit_known = false;
                    scanDinit(a, &self.incoming, job.user, states != null);
                },
            }
        }
        std.mem.swap(std.ArrayList(Service), &self.services, &self.incoming);
        self.states_button.as(gtk.Widget).setVisible(@intFromBool(!sys_dinit_known));
        self.loaded = true;
        self.refresh();
    }

    fn onReadStates(_: *gtk.Button, self: *Page) callconv(.c) void {
        common.elevate.runCapture(self.window, "Read the state of the system's services", &.{ "dinitctl", "--system", "list" }, Page, onStatesRead, self);
    }

    fn onStatesRead(self: *Page, outcome: common.elevate.Outcome, out: []const u8) void {
        if (outcome != .ok) return;
        if (self.sys_states) |x| self.gpa.free(x);
        self.sys_states = self.gpa.dupe(u8, out) catch null;
        self.merge();
    }

    /// The PIDs from the sampler, the search, the list.
    pub fn refresh(self: *Page) void {
        if (!self.loaded) return;
        var lowest: std.StringHashMapUnmanaged(u32) = .empty;
        defer lowest.deinit(self.gpa);
        var it = self.sampler.processes.valueIterator();
        while (it.next()) |p| {
            if (p.unit_len == 0) continue;
            const e = lowest.getOrPut(self.gpa, p.unitSlice()) catch continue;
            if (!e.found_existing or p.pid < e.value_ptr.*) e.value_ptr.* = p.pid;
        }
        self.shown.clearRetainingCapacity();
        var running: usize = 0;
        var unknown: usize = 0;
        for (self.services.items, 0..) |*s, i| {
            // systemd's from the processes' cgroups; dinit says its own.
            if (!s.dinit) s.pid = if (s.running()) lowest.get(s.nameSlice()) orelse 0 else 0;
            if (s.running()) running += 1;
            if (std.mem.eql(u8, Service.get(&s.active), "unknown")) unknown += 1;
            if (self.query_len > 0) {
                const q = self.query[0..self.query_len];
                if (std.ascii.findIgnoreCase(s.nameSlice(), q) == null and std.ascii.findIgnoreCase(Service.get(&s.description), q) == null) continue;
            }
            self.shown.append(self.gpa, i) catch return;
        }
        self.list.update(self.shown.items.len);
        self.selectWanted();
        var b: [320]u8 = undefined;
        const manager: []const u8 = switch (self.sys_init) {
            .systemd => "systemd",
            .dinit => "dinit",
            .none => "no service manager",
        };
        const msg = if (unknown > 0)
            std.fmt.bufPrintSentinel(&b, "{d} services ({s}). dinit tells the state of system services only to the administrator: Show states asks for the password.", .{ self.services.items.len, manager }, 0) catch ""
        else
            std.fmt.bufPrintSentinel(&b, "{d} services, {d} running ({s})", .{ self.services.items.len, running, manager }, 0) catch "";
        self.status_label.setText(msg);
        onSelection(self);
    }

    fn at(self: *Page, row: usize) *Service {
        return &self.services.items[self.shown.items[row]];
    }

    fn text(owner: *anyopaque, row: usize, col: usize, buf: []u8) []const u8 {
        const self: *Page = @ptrCast(@alignCast(owner));
        const s = self.at(row);
        return switch (@as(Col, @enumFromInt(col))) {
            .name => s.nameSlice(),
            .pid => if (s.pid == 0) "" else std.fmt.bufPrint(buf, "{d}", .{s.pid}) catch "",
            .description => Service.get(&s.description),
            .status => s.status(),
            .startup => s.startup(),
            .kind => if (s.user) "Yours" else "System",
        };
    }

    fn less(owner: *anyopaque, a: usize, b: usize, col: usize) bool {
        const self: *Page = @ptrCast(@alignCast(owner));
        const x = self.at(a);
        const y = self.at(b);
        if (@as(Col, @enumFromInt(col)) == .pid) return x.pid < y.pid;
        var ba: [256]u8 = undefined;
        var bb: [256]u8 = undefined;
        const ta = text(owner, a, col, &ba);
        const tb = text(owner, b, col, &bb);
        const order = std.ascii.orderIgnoreCase(ta, tb);
        if (order != .eq) return order == .lt;
        return std.ascii.lessThanIgnoreCase(x.nameSlice(), y.nameSlice());
    }

    fn key(owner: *anyopaque, row: usize) u64 {
        const self: *Page = @ptrCast(@alignCast(owner));
        const s = self.at(row);
        return simplelist.hashKey(s.nameSlice()) +% @intFromBool(s.user);
    }

    fn onSearch(entry: *gtk.SearchEntry, self: *Page) callconv(.c) void {
        const q = std.mem.span(entry.as(gtk.Editable).getText());
        const n = @min(q.len, self.query.len);
        @memcpy(self.query[0..n], q[0..n]);
        self.query_len = n;
        self.refresh();
    }

    fn selected(self: *Page) ?*Service {
        const row = self.list.selectedRow() orelse return null;
        if (row >= self.shown.items.len) return null;
        return self.at(row);
    }

    fn onSelection(owner: *anyopaque) void {
        const self: *Page = @ptrCast(@alignCast(owner));
        const s = self.selected();
        const known = s != null and !std.mem.eql(u8, Service.get(&s.?.active), "unknown");
        const on = [_]bool{
            s != null and (!known or !s.?.running()),
            s != null and (!known or s.?.running()),
            s != null and (!known or s.?.running()),
            s != null and !std.mem.eql(u8, s.?.startup(), "Automatic"),
            s != null and std.mem.eql(u8, s.?.startup(), "Automatic"),
            s != null,
        };
        for (self.buttons, on) |b, v| b.as(gtk.Widget).setSensitive(@intFromBool(v));
        // Masking is systemd's; dinit has none.
        const masked = s != null and std.mem.startsWith(u8, Service.get(&s.?.file_state), "masked");
        self.enableAction("mask", s != null and !s.?.dinit and !masked);
        self.enableAction("unmask", s != null and !s.?.dinit and masked);
        self.enableAction("enable", on[3] and !masked);
        self.enableAction("disable", on[4]);
        if (masked) self.buttons[3].as(gtk.Widget).setSensitive(0);
    }

    fn enableAction(self: *Page, name: [:0]const u8, on: bool) void {
        const found = self.action_group.as(gio.ActionMap).lookupAction(name) orelse return;
        const simple: *gio.SimpleAction = @ptrCast(@alignCast(found));
        simple.setEnabled(@intFromBool(on));
    }

    /// Selects the service `unit` (from "Go to service"), now or once read.
    pub fn select(self: *Page, unit: []const u8) void {
        const n = @min(unit.len, self.wanted.len);
        @memcpy(self.wanted[0..n], unit[0..n]);
        self.wanted_len = n;
        self.search.as(gtk.Editable).setText("");
        if (self.loaded) self.selectWanted();
    }

    fn selectWanted(self: *Page) void {
        if (self.wanted_len == 0) return;
        const unit = self.wanted[0..self.wanted_len];
        self.wanted_len = 0;
        for (self.shown.items, 0..) |i, row| {
            const s = &self.services.items[i];
            if (std.mem.eql(u8, s.nameSlice(), unit)) return self.list.selectKey(key(self, row));
        }
    }

    fn onMenu(owner: *anyopaque, _: usize, x: f64, y: f64) void {
        const self: *Page = @ptrCast(@alignCast(owner));
        simplelist.popupMenu(self.list.view.as(gtk.Widget), self.menu.as(gio.MenuModel), x, y);
    }

    fn onActivate(owner: *anyopaque, _: usize) void {
        const self: *Page = @ptrCast(@alignCast(owner));
        self.read(.details);
    }

    fn onAction(action: *gio.SimpleAction, _: ?*glib.Variant, self: *Page) callconv(.c) void {
        const name = std.mem.span(action.as(gio.Action).getName());
        if (std.mem.eql(u8, name, "details")) return self.read(.details);
        if (std.mem.eql(u8, name, "log")) return self.read(.log);
        self.control(name);
    }

    fn onButton(button: *gtk.Button, self: *Page) callconv(.c) void {
        const verbs = [_][]const u8{ "start", "stop", "restart", "enable", "disable" };
        for (self.buttons[0..verbs.len], verbs) |b, v| if (b == button) return self.control(v);
        if (button == self.buttons[5]) self.read(.log);
    }

    /// start, stop, restart, enable or disable the selected service.
    fn control(self: *Page, verb: []const u8) void {
        const s = self.selected() orelse return;
        var nb: [128]u8 = undefined;
        const name = std.fmt.bufPrint(&nb, "{s}", .{s.nameSlice()}) catch return;
        const tool: []const u8 = if (s.dinit) "dinitctl" else "systemctl";
        if (s.user) {
            common.proc.run(Page, self.guard, &.{ tool, "--user", verb, name }, onControlled);
            return;
        }
        var rb: [200]u8 = undefined;
        const reason = std.fmt.bufPrint(&rb, "Change the service “{s}”", .{name}) catch "Change a service";
        if (s.dinit) {
            common.elevate.run(self.window, reason, &.{ tool, "--system", verb, name }, "", Page, onElevated, self);
        } else common.elevate.run(self.window, reason, &.{ tool, verb, name }, "", Page, onElevated, self);
    }

    fn onControlled(self: *Page, ok: bool, _: []const u8) void {
        if (!ok) common.dialogs.showError(self.window, t("The service could not be changed"), t("The service manager reported a problem. The service's details and logs may say why."));
        self.reload();
    }

    fn onElevated(self: *Page, outcome: common.elevate.Outcome, message: []const u8) void {
        if (outcome == .failed) {
            var b: [400]u8 = undefined;
            common.dialogs.showError(self.window, t("The service could not be changed"), std.fmt.bufPrintSentinel(&b, "{s}", .{message[0..@min(message.len, 390)]}, 0) catch null);
        }
        self.reload();
    }

    // ---- details and logs -----------------------------------------------------------

    /// The service's status, or its log: systemctl status / journalctl, or
    /// dinitctl status / catlog (or its logfile). What only root may read
    /// is read with the password.
    fn read(self: *Page, what: @TypeOf(self.reading_what)) void {
        const s = self.selected() orelse return;
        self.reading = s.*;
        self.reading_what = what;
        var nb: [128]u8 = undefined;
        const name = std.fmt.bufPrint(&nb, "{s}", .{s.nameSlice()}) catch return;
        if (!s.dinit) {
            switch (what) {
                .details => if (s.user)
                    common.proc.run(Page, self.guard, &.{ "systemctl", "--user", "status", "--no-pager", "--lines=0", name }, onRead)
                else
                    common.proc.run(Page, self.guard, &.{ "systemctl", "status", "--no-pager", "--lines=0", name }, onRead),
                .log => if (s.user)
                    common.proc.run(Page, self.guard, &.{ "journalctl", "--user-unit", name, "-n", "500", "--no-pager", "-o", "short-iso" }, onRead)
                else
                    common.proc.run(Page, self.guard, &.{ "journalctl", "-u", name, "-n", "500", "--no-pager", "-o", "short-iso" }, onRead),
            }
            return;
        }
        if (what == .log and Service.get(&s.logfile).len > 0) return self.readLogfile();
        const verb: []const u8 = if (what == .log) "catlog" else "status";
        if (s.user) {
            common.proc.run(Page, self.guard, &.{ "dinitctl", "--user", verb, name }, onRead);
        } else {
            common.elevate.runCapture(self.window, "Read a system service's state and log", &.{ "dinitctl", "--system", verb, name }, Page, onReadElevated, self);
        }
    }

    fn readLogfile(self: *Page) void {
        const path = Service.get(&self.reading.logfile);
        var pb: [260]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&pb, "{s}", .{path}, 0) catch return;
        var contents: [*]u8 = undefined;
        var length: usize = 0;
        if (glib.fileGetContents(z, &contents, &length, null) != 0) {
            defer glib.free(contents);
            // The end of it: the newest lines.
            const all = contents[0..length];
            return self.showText(all[all.len -| 256 * 1024 ..], false);
        }
        if (self.reading.user) return self.showText("", false);
        common.elevate.runCapture(self.window, "Read a system service's log", &.{ "tail", "-n", "2000", path }, Page, onReadElevated, self);
    }

    fn onRead(self: *Page, _: bool, out: []const u8) void {
        // `status` exits non-zero for a stopped service; its text is still wanted.
        const denied = !self.reading.user and !self.reading.dinit and self.reading_what == .log and
            (std.mem.trim(u8, out, " \n").len == 0 or std.mem.indexOf(u8, out, "No entries") != null);
        self.showText(out, denied);
    }

    fn onReadElevated(self: *Page, outcome: common.elevate.Outcome, out: []const u8) void {
        switch (outcome) {
            .ok => self.showText(out, false),
            .cancelled => {},
            .failed => {
                var b: [400]u8 = undefined;
                const what: [:0]const u8 = if (self.reading_what == .log)
                    t("This service keeps no log dinit can show (its log-type is not buffer, and it has no logfile).")
                else
                    t("The service's state could not be read.");
                common.dialogs.showError(self.window, what, std.fmt.bufPrintSentinel(&b, "{s}", .{out[0..@min(out.len, 390)]}, 0) catch null);
            },
        }
    }

    /// The details or log in a window. `maybe_hidden`: the system journal
    /// showed nothing, which may be a matter of rights.
    fn showText(self: *Page, out: []const u8, maybe_hidden: bool) void {
        const win = gtk.Window.new();
        var tb: [200]u8 = undefined;
        win.setTitle(std.fmt.bufPrintSentinel(&tb, "{s}: {s}", .{ if (self.reading_what == .log) "Log" else "Details", self.reading.nameSlice() }, 0) catch "Service");
        win.setTransientFor(self.window);
        win.setDefaultSize(860, 540);
        win.as(gtk.Widget).addCssClass("dkde");
        const box = gtk.Box.new(.vertical, 0);
        if (maybe_hidden) {
            const note = gtk.Label.new(t("Nothing was shown. Only administrators, and members of the systemd-journal or adm group, may read the system's log."));
            note.setWrap(1);
            note.setXalign(0);
            inline for (.{ "setMarginStart", "setMarginEnd", "setMarginTop" }) |m| @field(gtk.Widget, m)(note.as(gtk.Widget), 10);
            box.append(note.as(gtk.Widget));
            const again = gtk.Button.newWithLabel(t("Read it as administrator"));
            again.as(gtk.Widget).setHalign(.start);
            again.as(gtk.Widget).setMarginStart(10);
            again.as(gtk.Widget).setMarginTop(6);
            _ = gtk.Button.signals.clicked.connect(again, *Page, &onJournalAsRoot, self, .{});
            _ = gtk.Button.signals.clicked.connect(again, *gtk.Window, &closeWindow, win, .{});
            box.append(again.as(gtk.Widget));
        }
        const view = gtk.TextView.new();
        view.setEditable(0);
        view.setMonospace(1);
        view.setLeftMargin(10);
        view.setTopMargin(8);
        const shown = if (std.mem.trim(u8, out, " \n").len > 0) out else if (self.reading_what == .log) "The log is empty." else "No details were given.";
        const z = self.gpa.dupeSentinel(u8, shown, 0) catch return;
        defer self.gpa.free(z);
        if (glib.utf8Validate(z.ptr, @intCast(z.len), null) != 0) {
            view.getBuffer().setText(z, -1);
        } else {
            const fixed = glib.utf8MakeValid(z.ptr, @intCast(z.len));
            defer glib.free(fixed);
            view.getBuffer().setText(fixed, -1);
        }
        const scroller = gtk.ScrolledWindow.new();
        scroller.setChild(view.as(gtk.Widget));
        scroller.as(gtk.Widget).setVexpand(1);
        box.append(scroller.as(gtk.Widget));
        win.setChild(box.as(gtk.Widget));
        win.present();
        // The newest lines are at the end.
        if (self.reading_what == .log) {
            var end: gtk.TextIter = undefined;
            view.getBuffer().getEndIter(&end);
            const mark = view.getBuffer().createMark(null, &end, 0);
            view.scrollToMark(mark, 0, 0, 0, 1);
        }
    }

    fn closeWindow(_: *gtk.Button, win: *gtk.Window) callconv(.c) void {
        win.destroy();
    }

    fn onJournalAsRoot(_: *gtk.Button, self: *Page) callconv(.c) void {
        var nb: [128]u8 = undefined;
        const name = std.fmt.bufPrint(&nb, "{s}", .{self.reading.nameSlice()}) catch return;
        common.elevate.runCapture(self.window, "Read the system's log", &.{ "journalctl", "-u", name, "-n", "500", "--no-pager", "-o", "short-iso" }, Page, onReadElevated, self);
    }
};

/// The bar at the top of each page: its title on the left, its commands on the right.
pub fn commandBar(title: [:0]const u8) *gtk.Box {
    const bar = gtk.Box.new(.horizontal, 6);
    bar.as(gtk.Widget).addCssClass("dkde-command-bar");
    const label = gtk.Label.new(title);
    label.setXalign(0);
    label.as(gtk.Widget).setHexpand(1);
    label.as(gtk.Widget).addCssClass("dkde-page-title");
    bar.append(label.as(gtk.Widget));
    return bar;
}

test "dinit lists" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(Service) = .empty;
    defer list.deinit(gpa);
    parseDinitList(gpa, &list, "[{+}     ] boot\n[{+}     ] sshd (pid: 412)\n[     {X}] broken (exit status: 1)\n", false);
    try std.testing.expectEqual(@as(usize, 3), list.items.len);
    try std.testing.expectEqualStrings("Active", list.items[0].status());
    try std.testing.expectEqualStrings("Running", list.items[1].status());
    try std.testing.expectEqual(@as(u32, 412), list.items[1].pid);
    try std.testing.expectEqualStrings("Failed", list.items[2].status());
}

test "systemctl lists" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(Service) = .empty;
    defer list.deinit(gpa);
    parseUnits(gpa, &list, "accounts-daemon.service loaded active running Accounts Service\nalsa-state.service loaded inactive dead Manage Sound Card State\nfoo.service not-found inactive dead foo.service\n", false);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("Running", list.items[0].status());
    try std.testing.expectEqualStrings("Accounts Service", Service.get(&list.items[0].description));
    parseUnitFiles(gpa, &list, "accounts-daemon.service enabled enabled\ngetty@.service enabled enabled\ncups.service disabled enabled\n", false);
    try std.testing.expectEqual(@as(usize, 3), list.items.len);
    try std.testing.expectEqualStrings("Automatic", list.items[0].startup());
    try std.testing.expectEqualStrings("Manual (when needed)", list.items[1].startup());
    try std.testing.expectEqualStrings("Stopped", list.items[2].status());
    try std.testing.expectEqualStrings("Manual (disabled)", list.items[2].startup());
}
