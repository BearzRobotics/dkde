//! The Security page: AppArmor or SELinux, whichever the kernel runs. It shows
//! the state, the profiles (AppArmor) or settings (SELinux), and the recent
//! refusals in plain words. Reading the profiles and the audit log, and
//! every change, needs the administrator password (security.zig parses what
//! the tools print). The page is not offered when neither is active.

const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

pub const security = @import("security.zig");
const edit = @import("securityedit.zig");
const simplelist = @import("simplelist.zig");
const services = @import("services.zig");

const t = common.tr;

/// Which security module this machine runs, from the kernel's own files.
/// Set from Task Manager's settings: use this module instead of the detected one (`.none` hides the page).
pub var forced: ?security.Kind = null;

pub fn detect() security.Kind {
    if (forced) |f| return f;
    var a_buf: [16]u8 = undefined;
    var s_buf: [16]u8 = undefined;
    const apparmor = readSmall("/sys/module/apparmor/parameters/enabled", &a_buf);
    const selinux = readSmall("/sys/fs/selinux/enforce", &s_buf);
    return security.detect(apparmor, selinux);
}

fn readSmall(path: [:0]const u8, buf: []u8) ?[]const u8 {
    var contents: [*]u8 = undefined;
    var length: usize = 0;
    if (glib.fileGetContents(path, &contents, &length, null) == 0) return null;
    defer glib.free(contents);
    const n = @min(length, buf.len);
    @memcpy(buf[0..n], contents[0..n]);
    return buf[0..n];
}

const profile_specs = [_]simplelist.ColumnSpec{
    .{ .title = "Profile", .expand = true },
    .{ .title = "Mode", .width = 190 },
    .{ .title = "Processes", .right = true, .width = 100, .big_first = true },
};
const boolean_specs = [_]simplelist.ColumnSpec{
    .{ .title = "Setting", .expand = true },
    .{ .title = "State", .width = 100 },
};
const denial_specs = [_]simplelist.ColumnSpec{
    .{ .title = "When", .width = 140 },
    .{ .title = "Program", .width = 170 },
    .{ .title = "Tried to", .width = 200 },
    .{ .title = "What", .expand = true },
    .{ .title = "Times", .right = true, .width = 70, .big_first = true },
};

pub const Page = struct {
    gpa: std.mem.Allocator,
    window: *gtk.Window,
    kind: security.Kind,
    widget: *gtk.Widget,
    guard: *common.proc.Guard(Page),
    stack: *gtk.Stack,
    status: *gtk.Label,
    detail: *gtk.Label,
    first_list: *simplelist.SimpleList,
    denial_list: *simplelist.SimpleList,
    /// Buttons that need a selected row: AppArmor Enforce, Complain; SELinux Turn on, Turn off.
    row_buttons: [2]*gtk.Button,
    mode_button: *gtk.Button,
    /// Everything parsed lives here and is replaced on each load.
    data: std.heap.ArenaAllocator,
    profiles: []security.Profile = &.{},
    booleans: []security.Boolean = &.{},
    denials: []security.Denial = &.{},
    /// SELinux: whether it enforces (from getenforce).
    enforcing: bool = true,
    loaded: bool = false,
    first_loaded_denials: bool = false,
    /// What the next dialog step acts on: a profile file name or module name, and a rule or audit line.
    edit_file: []const u8 = "",
    edit_rule: []const u8 = "",
    /// More actions: AppArmor (disable, edit profile, new profile), SELinux (boot mode, relabel, modules, ports,
    /// files), and "Allow…" for the selected refusal (both).
    allow_button: *gtk.Button = undefined,
    disable_button: *gtk.Button = undefined,
    edit_button: *gtk.Button = undefined,
    permissive_button: *gtk.Button = undefined,
    module_buttons: [3]*gtk.Button = undefined,
    port_remove: *gtk.Button = undefined,
    modules: *Table = undefined,
    ports: *Table = undefined,
    path_entry: *gtk.Entry = undefined,
    tables: std.heap.ArenaAllocator = undefined,

    pub fn create(gpa: std.mem.Allocator, window: *gtk.Window, kind: security.Kind) *Page {
        const self = gpa.create(Page) catch @panic("OOM");
        self.* = .{
            .gpa = gpa,
            .window = window,
            .kind = kind,
            .widget = undefined,
            .guard = undefined,
            .stack = gtk.Stack.new(),
            .status = gtk.Label.new(""),
            .detail = gtk.Label.new(""),
            .first_list = undefined,
            .denial_list = undefined,
            .row_buttons = undefined,
            .mode_button = gtk.Button.newWithLabel(""),
            .data = .init(gpa),
        };
        self.guard = common.proc.Guard(Page).create(self);
        const apparmor = kind == .apparmor;
        self.first_list = simplelist.SimpleList.create(gpa, if (apparmor) &profile_specs else &boolean_specs, .{
            .owner = self,
            .text = firstText,
            .less = firstLess,
            .key = firstKey,
            .selection_changed = onSelection,
        });
        self.denial_list = simplelist.SimpleList.create(gpa, &denial_specs, .{
            .owner = self,
            .text = denialText,
            .less = denialLess,
            .key = denialKey,
            .selection_changed = onSelection,
        });
        self.denial_list.sortBy(0, true);

        const root = gtk.Box.new(.vertical, 0);
        const bar = services.commandBar(if (apparmor) t("AppArmor") else t("SELinux"));
        const switcher = gtk.StackSwitcher.new();
        switcher.setStack(self.stack);
        bar.append(switcher.as(gtk.Widget));
        bar.append(common.elevate.padlock(window).as(gtk.Widget));
        common.elevate.onChange(onLockChanged, self);
        const load_button = gtk.Button.newWithLabel(t("Load…"));
        load_button.as(gtk.Widget).setTooltipText(if (apparmor) t("Read the profiles and the recent refusals; needs the administrator password") else t("Read the settings and the recent refusals; the log needs the administrator password"));
        _ = gtk.Button.signals.clicked.connect(load_button, *Page, &onLoad, self, .{});
        bar.append(load_button.as(gtk.Widget));
        const names = if (apparmor) [2][:0]const u8{ "Enforce", "Complain" } else [2][:0]const u8{ "Turn on", "Turn off" };
        const tips = if (apparmor)
            [2][:0]const u8{ "Make the selected profile block what it forbids", "Make the selected profile only log what it would forbid, to find out what it needs" }
        else
            [2][:0]const u8{ "Turn the selected setting on (kept after a restart)", "Turn the selected setting off (kept after a restart)" };
        for (names, 0..) |n, i| {
            const b = gtk.Button.newWithLabel(n);
            b.as(gtk.Widget).setTooltipText(tips[i]);
            b.as(gtk.Widget).setSensitive(0);
            _ = gtk.Button.signals.clicked.connect(b, *Page, if (i == 0) &onFirst else &onSecond, self, .{});
            self.row_buttons[i] = b;
            bar.append(b.as(gtk.Widget));
        }
        if (!apparmor) {
            self.mode_button.as(gtk.Widget).setSensitive(0);
            _ = gtk.Button.signals.clicked.connect(self.mode_button, *Page, &onMode, self, .{});
            bar.append(self.mode_button.as(gtk.Widget));
        }
        self.tables = .init(gpa);
        const apparmor_kind = apparmor;
        // The actions that go beyond switching modes: all through the administrator prompt.
        self.allow_button = addAction(bar, t("Allow…"), t("Write the rule that would allow the selected refused action, after showing it to you"), onAllow, self);
        self.allow_button.as(gtk.Widget).setSensitive(0);
        if (apparmor_kind) {
            self.disable_button = addAction(bar, t("Disable"), t("Stop using the selected profile at all (Enforce turns it back on)"), onDisableProfile, self);
            self.disable_button.as(gtk.Widget).setSensitive(0);
            self.edit_button = addAction(bar, t("Edit profile…"), t("Read and change the selected profile's rules; the new text must parse before it replaces the file"), onEditProfile, self);
            self.edit_button.as(gtk.Widget).setSensitive(0);
            _ = addAction(bar, t("New profile…"), t("Start a profile for a program, in complain mode, to learn what it needs"), onNewProfile, self);
        } else {
            self.permissive_button = addAction(bar, t("Make domain permissive"), t("Let the selected refusal's program do what it likes (refusals are only logged) without making all of SELinux permissive"), onPermissiveDomain, self);
            self.permissive_button.as(gtk.Widget).setSensitive(0);
            _ = addAction(bar, t("At boot…"), t("Choose enforcing, permissive or disabled for the next start-up"), onBootMode, self);
            _ = addAction(bar, t("Relabel at next boot"), t("Re-read every file's security label when the computer next starts; slow, and needed after switching SELinux on"), onRelabel, self);
        }
        root.append(services.scrolled(bar));

        self.status.setXalign(0);
        self.status.setWrap(1);
        self.status.as(gtk.Widget).setMarginStart(12);
        self.status.as(gtk.Widget).setMarginTop(6);
        self.status.as(gtk.Widget).setMarginBottom(4);
        self.status.setText(t("Unlock with the padlock (once, instead of for each action), or choose Load… to read the current state. Reading it needs the administrator password."));
        root.append(self.status.as(gtk.Widget));

        _ = self.stack.addTitled(self.first_list.widget, "first", if (apparmor) t("Profiles") else t("Settings"));
        _ = self.stack.addTitled(self.denial_list.widget, "denials", t("Recent refusals"));
        if (!apparmor) self.buildSelinuxTabs(gpa);
        self.stack.as(gtk.Widget).setVexpand(1);
        root.append(self.stack.as(gtk.Widget));

        self.detail.setXalign(0);
        self.detail.setWrap(1);
        self.detail.setSelectable(1);
        self.detail.as(gtk.Widget).addCssClass("dim-label");
        self.detail.as(gtk.Widget).setMarginStart(12);
        self.detail.as(gtk.Widget).setMarginTop(4);
        self.detail.as(gtk.Widget).setMarginBottom(6);
        root.append(self.detail.as(gtk.Widget));
        self.widget = root.as(gtk.Widget);
        return self;
    }

    /// The padlock opened: read what the page shows, without a password to type.
    fn onLockChanged(data: ?*anyopaque) void {
        const self: *Page = @ptrCast(@alignCast(data.?));
        if (common.elevate.isUnlocked() and self.widget.getMapped() != 0) self.load();
    }

    pub fn destroy(self: *Page) void {
        common.elevate.removeListener(onLockChanged, self);
        self.guard.kill();
        self.first_list.destroy();
        self.denial_list.destroy();
        self.data.deinit();
        if (self.kind == .selinux) {
            self.modules.list.destroy();
            self.ports.list.destroy();
            self.gpa.destroy(self.modules);
            self.gpa.destroy(self.ports);
        }
        self.tables.deinit();
        self.gpa.destroy(self);
    }

    /// Called when the page is shown: reads what needs no password.
    pub fn reload(self: *Page) void {
        if (glib.getenv("DKDE_DEBUG_SECURITY") != null and !self.loaded) return self.load();
        if (common.elevate.isUnlocked()) return self.load();
        if (self.kind == .selinux) {
            common.proc.run(Page, self.guard, &.{"getenforce"}, onGetenforce);
            common.proc.run(Page, self.guard, &.{ "getsebool", "-a" }, onBooleans);
        }
    }

    // ---- reading -------------------------------------------------------------------------

    fn onLoad(_: *gtk.Button, self: *Page) callconv(.c) void {
        self.load();
    }

    /// Dev aid: DKDE_DEBUG_SECURITY=<folder> reads aa-status.json and journal.txt from there instead of
    /// asking for the password, so the page can be tried (and shown in screenshots) with sample data.
    fn loadDebug(self: *Page, dir: []const u8) void {
        var path: [512]u8 = undefined;
        for ([_]struct { name: []const u8, which: u8 }{ .{ .name = "aa-status.json", .which = 0 }, .{ .name = "journal.txt", .which = 1 } }) |f| {
            const p = std.fmt.bufPrintSentinel(&path, "{s}/{s}", .{ dir, f.name }, 0) catch continue;
            var contents: [*]u8 = undefined;
            var length: usize = 0;
            if (glib.fileGetContents(p, &contents, &length, null) == 0) continue;
            defer glib.free(contents);
            if (f.which == 0) self.onAaStatus(.ok, contents[0..length]) else self.onLog(.ok, contents[0..length]);
        }
        // Show the refusals with the first one explained.
        if (glib.getenv("DKDE_DEBUG_SECURITY_TAB") != null) {
            self.stack.setVisibleChildName("denials");
            self.denial_list.selection.setSelected(0);
            onSelection(self);
        }
    }

    fn load(self: *Page) void {
        if (glib.getenv("DKDE_DEBUG_SECURITY")) |dir| return self.loadDebug(std.mem.span(dir));
        switch (self.kind) {
            .apparmor => common.elevate.runCapture(self.window, "Read the AppArmor profiles", &.{ "aa-status", "--json" }, Page, onAaStatus, self),
            .selinux => self.reload(),
            .none => {},
        }
        self.loadDenials();
    }

    fn loadDenials(self: *Page) void {
        // The kernel's messages and the audit log, where both kinds of refusal are written.
        common.elevate.runCapture(self.window, "Read the log of refused actions", &.{ "journalctl", "-o", "short-iso", "--no-pager", "-n", "4000", "_TRANSPORT=kernel", "+", "_TRANSPORT=audit" }, Page, onLog, self);
    }

    fn onAaStatus(self: *Page, outcome: common.elevate.Outcome, out: []const u8) void {
        if (outcome != .ok) {
            if (outcome == .failed) self.status.setText(t("Could not read the profiles. Is the apparmor-utils package installed?"));
            return;
        }
        const a = self.data.allocator();
        const list = security.parseAaStatus(a, out) catch {
            self.status.setText(t("aa-status gave output this page cannot read (it needs a version with --json)."));
            return;
        };
        self.profiles = list;
        var enforce: usize = 0;
        var complain: usize = 0;
        var processes: usize = 0;
        for (list) |p| {
            if (p.mode == .enforce or p.mode == .kill) enforce += 1;
            if (p.mode == .complain) complain += 1;
            processes += p.processes;
        }
        var buf: [256]u8 = undefined;
        self.status.setText(std.fmt.bufPrintSentinel(&buf, "AppArmor is on: {d} profiles ({d} enforcing, {d} only logging); {d} confined processes.", .{ list.len, enforce, complain, processes }, 0) catch "");
        self.loaded = true;
        self.first_list.update(list.len);
        onSelection(self);
    }

    fn onGetenforce(self: *Page, ok: bool, out: []const u8) void {
        if (!ok) return;
        const mode = std.mem.trim(u8, out, " \n");
        self.enforcing = std.mem.eql(u8, mode, "Enforcing");
        var buf: [160]u8 = undefined;
        self.status.setText(std.fmt.bufPrintSentinel(&buf, "SELinux is {s}.{s}", .{ mode, if (std.mem.eql(u8, mode, "Permissive")) " Refusals are only logged." else "" }, 0) catch "");
        self.mode_button.setLabel(if (self.enforcing) t("Make permissive") else t("Make enforcing"));
        self.mode_button.as(gtk.Widget).setTooltipText(t("Changes the running system only; edit /etc/selinux/config to keep it after a restart"));
        self.mode_button.as(gtk.Widget).setSensitive(1);
    }

    fn onBooleans(self: *Page, ok: bool, out: []const u8) void {
        if (!ok) {
            self.status.setText(t("Could not read the SELinux settings (getsebool)."));
            return;
        }
        // The page's data arena keeps denials too, so only the booleans are replaced.
        const list = security.parseBooleans(self.gpa, out) catch return;
        if (self.booleans.len > 0) self.gpa.free(self.booleans);
        // The names point into `out`, which goes away: keep copies.
        const a = self.data.allocator();
        for (list) |*b| b.name = a.dupe(u8, b.name) catch b.name;
        self.booleans = list;
        self.first_list.update(list.len);
        onSelection(self);
    }

    fn onLog(self: *Page, outcome: common.elevate.Outcome, out: []const u8) void {
        if (outcome != .ok) {
            if (outcome == .failed) self.detail.setText(t("Could not read the log of refused actions."));
            return;
        }
        const a = self.data.allocator();
        var list: std.ArrayList(security.Denial) = .empty;
        var lines = std.mem.splitScalar(u8, out, '\n');
        var buf: [160]u8 = undefined;
        var time_buf: [16]u8 = undefined;
        while (lines.next()) |line| {
            const d = security.parseDenial(line, &buf, &time_buf) orelse continue;
            // Copy: the line, the buffers and the log text are all gone after this call.
            list.append(a, .{
                .time = a.dupe(u8, d.time) catch "",
                .who = a.dupe(u8, d.who) catch "",
                .confinement = a.dupe(u8, d.confinement) catch "",
                .action = a.dupe(u8, d.action) catch "",
                .target = a.dupe(u8, d.target) catch "",
                .class = a.dupe(u8, d.class) catch "",
                .only_logged = d.only_logged,
            }) catch break;
        }
        const n = security.collapse(list.items);
        self.denials = list.items[0..n];
        self.first_loaded_denials = true;
        self.denial_list.update(n);
        var sb: [160]u8 = undefined;
        self.detail.setText(if (n == 0) t("No refused actions in the log.") else std.fmt.bufPrintSentinel(&sb, "{d} kinds of refused action in the log. Select one to read it in words.", .{n}, 0) catch "");
    }


    // ---- the lists -----------------------------------------------------------------------

    fn page(owner: *anyopaque) *Page {
        return @ptrCast(@alignCast(owner));
    }

    fn firstCount(self: *const Page) usize {
        return if (self.kind == .apparmor) self.profiles.len else self.booleans.len;
    }

    fn firstText(owner: *anyopaque, row: usize, col: usize, buf: []u8) []const u8 {
        const self = page(owner);
        if (self.kind == .apparmor) {
            const p = self.profiles[row];
            return switch (col) {
                0 => p.name,
                1 => p.mode.label(),
                else => std.fmt.bufPrint(buf, "{d}", .{p.processes}) catch "",
            };
        }
        const b = self.booleans[row];
        return if (col == 0) b.name else if (b.on) "On" else "Off";
    }

    fn firstLess(owner: *anyopaque, a: usize, b: usize, col: usize) bool {
        const self = page(owner);
        if (self.kind == .apparmor) {
            const x = self.profiles[a];
            const y = self.profiles[b];
            return switch (col) {
                0 => std.ascii.lessThanIgnoreCase(x.name, y.name),
                1 => @intFromEnum(x.mode) < @intFromEnum(y.mode),
                else => x.processes < y.processes,
            };
        }
        const x = self.booleans[a];
        const y = self.booleans[b];
        return if (col == 0) std.ascii.lessThanIgnoreCase(x.name, y.name) else @intFromBool(x.on) < @intFromBool(y.on);
    }

    fn firstKey(owner: *anyopaque, row: usize) u64 {
        const self = page(owner);
        const name = if (self.kind == .apparmor) self.profiles[row].name else self.booleans[row].name;
        return std.hash.Wyhash.hash(0, name);
    }

    fn denialText(owner: *anyopaque, row: usize, col: usize, buf: []u8) []const u8 {
        const d = page(owner).denials[row];
        return switch (col) {
            0 => d.time,
            1 => d.who,
            2 => if (d.only_logged) (std.fmt.bufPrint(buf, "{s} (only logged)", .{d.action}) catch d.action) else d.action,
            3 => d.target,
            else => std.fmt.bufPrint(buf, "{d}", .{d.count}) catch "",
        };
    }

    fn denialLess(owner: *anyopaque, a: usize, b: usize, col: usize) bool {
        const list = page(owner).denials;
        const x = list[a];
        const y = list[b];
        return switch (col) {
            0 => std.mem.order(u8, x.time, y.time) == .lt,
            1 => std.ascii.lessThanIgnoreCase(x.who, y.who),
            2 => std.ascii.lessThanIgnoreCase(x.action, y.action),
            3 => std.ascii.lessThanIgnoreCase(x.target, y.target),
            else => x.count < y.count,
        };
    }

    fn denialKey(owner: *anyopaque, row: usize) u64 {
        const d = page(owner).denials[row];
        var h = std.hash.Wyhash.init(0);
        h.update(d.who);
        h.update(d.action);
        h.update(d.target);
        return h.final();
    }

    fn onSelection(owner: *anyopaque) void {
        const self = page(owner);
        const row = self.first_list.selectedRow();
        for (self.row_buttons) |b| b.as(gtk.Widget).setSensitive(@intFromBool(row != null));
        const refusal = self.denial_list.selectedRow();
        self.allow_button.as(gtk.Widget).setSensitive(@intFromBool(refusal != null));
        if (self.kind == .apparmor) {
            self.disable_button.as(gtk.Widget).setSensitive(@intFromBool(row != null));
            self.edit_button.as(gtk.Widget).setSensitive(@intFromBool(row != null));
        } else {
            self.permissive_button.as(gtk.Widget).setSensitive(@intFromBool(refusal != null));
        }
        if (refusal) |r| {
            if (r < self.denials.len) self.describe(self.denials[r]);
        }
    }

    /// A refusal in words, with what it means and what can be done.
    fn describe(self: *Page, d: security.Denial) void {
        var s: [320]u8 = undefined;
        const line = security.sentence(&s, d);
        var out: [640]u8 = undefined;
        const hint: []const u8 = if (d.only_logged)
            "It was only logged, because this is in complain or permissive mode, so nothing stopped working."
        else if (self.kind == .apparmor)
            "If this breaks something you need, put the profile in Complain mode to see everything it wants, then adjust it (aa-logprof) or enforce it again."
        else
            "If this breaks something you need, check the setting list for a boolean that allows it before writing policy (audit2why explains each refusal).";
        self.detail.setText(std.fmt.bufPrintSentinel(&out, "{s}{s}{s}. {s}", .{
            line,
            if (d.confinement.len > 0) " — confined as " else "",
            d.confinement,
            hint,
        }, 0) catch "");
    }

    // ---- changes ---------------------------------------------------------------------------

    fn selectedName(self: *Page) ?[]const u8 {
        const row = self.first_list.selectedRow() orelse return null;
        return if (self.kind == .apparmor) self.profiles[row].name else self.booleans[row].name;
    }

    fn onFirst(_: *gtk.Button, self: *Page) callconv(.c) void {
        self.change(true);
    }
    fn onSecond(_: *gtk.Button, self: *Page) callconv(.c) void {
        self.change(false);
    }

    /// AppArmor: enforce or complain. SELinux: boolean on or off, kept across restarts.
    fn change(self: *Page, first: bool) void {
        const name = self.selectedName() orelse return;
        if (self.kind == .apparmor) {
            common.elevate.run(self.window, "Change an AppArmor profile's mode", &.{ if (first) "aa-enforce" else "aa-complain", name }, "", Page, onChanged, self);
        } else {
            common.elevate.run(self.window, "Change an SELinux setting", &.{ "setsebool", "-P", name, if (first) "on" else "off" }, "", Page, onChanged, self);
        }
    }

    fn onMode(_: *gtk.Button, self: *Page) callconv(.c) void {
        common.elevate.run(self.window, "Change SELinux between enforcing and permissive", &.{ "setenforce", if (self.enforcing) "0" else "1" }, "", Page, onChanged, self);
    }

    // ---- the extra actions ---------------------------------------------------------------------

    fn addAction(bar: *gtk.Box, label: [:0]const u8, tip: [:0]const u8, comptime handler: fn (*gtk.Button, *Page) callconv(.c) void, self: *Page) *gtk.Button {
        const b = gtk.Button.newWithLabel(label);
        b.as(gtk.Widget).setTooltipText(tip);
        _ = gtk.Button.signals.clicked.connect(b, *Page, &handler, self, .{});
        bar.append(b.as(gtk.Widget));
        return b;
    }

    fn fail(self: *Page, message: []const u8) void {
        var b: [400]u8 = undefined;
        common.dialogs.showError(self.window, t("The change could not be made"), std.fmt.bufPrintSentinel(&b, "{s}", .{message[0..@min(message.len, 390)]}, 0) catch null);
    }

    /// Runs a command with the administrator prompt; the arguments are copied first, since they point at widgets.
    fn runArgs(self: *Page, reason: []const u8, argv: []const []const u8, stdin: []const u8) void {
        const a = self.tables.allocator();
        const owned = a.alloc([]const u8, argv.len) catch return;
        for (argv, 0..) |arg, i| owned[i] = a.dupe(u8, arg) catch return;
        const input = a.dupe(u8, stdin) catch return;
        common.elevate.run(self.window, reason, owned, input, Page, onChanged, self);
    }

    // A window showing text, optionally editable, with an Apply button that hands the text to a callback.
    const TextDialog = struct {
        page: *Page,
        window: *gtk.Window,
        view: *gtk.TextView,
        apply: *const fn (*Page, []const u8) void,
    };

    fn textDialog(self: *Page, title: [:0]const u8, intro: [:0]const u8, body: []const u8, editable: bool, apply_label: [:0]const u8, apply: *const fn (*Page, []const u8) void) void {
        const d = std.heap.c_allocator.create(TextDialog) catch return;
        const dialog = gtk.Window.new();
        dialog.setTitle(title);
        dialog.setTransientFor(self.window);
        dialog.setModal(1);
        common.dialogs.closeOnEscape(dialog);
        dialog.setDefaultSize(640, 420);
        dialog.as(gtk.Widget).addCssClass("dkde");
        const box = gtk.Box.new(.vertical, 10);
        box.as(gtk.Widget).setMarginTop(16);
        box.as(gtk.Widget).setMarginBottom(16);
        box.as(gtk.Widget).setMarginStart(16);
        box.as(gtk.Widget).setMarginEnd(16);
        dialog.setChild(box.as(gtk.Widget));
        const label = gtk.Label.new(intro);
        label.setWrap(1);
        label.setXalign(0);
        box.append(label.as(gtk.Widget));
        const view = gtk.TextView.new();
        view.setMonospace(1);
        view.setEditable(@intFromBool(editable));
        const z = std.heap.c_allocator.dupeSentinel(u8, body, 0) catch return;
        defer std.heap.c_allocator.free(z);
        view.getBuffer().setText(z.ptr, @intCast(body.len));
        const scroll = gtk.ScrolledWindow.new();
        scroll.setChild(view.as(gtk.Widget));
        scroll.as(gtk.Widget).setVexpand(1);
        box.append(scroll.as(gtk.Widget));
        const apply_button = gtk.Button.newWithLabel(apply_label);
        apply_button.as(gtk.Widget).addCssClass("suggested-action");
        apply_button.as(gtk.Widget).setHalign(.end);
        d.* = .{ .page = self, .window = dialog, .view = view, .apply = apply };
        _ = gtk.Button.signals.clicked.connect(apply_button, *TextDialog, &onTextApply, d, .{});
        box.append(apply_button.as(gtk.Widget));
        _ = gtk.Widget.signals.destroy.connect(dialog, *TextDialog, &onTextDestroy, d, .{});
        dialog.present();
    }

    fn onTextDestroy(_: *gtk.Window, d: *TextDialog) callconv(.c) void {
        std.heap.c_allocator.destroy(d);
    }

    fn onTextApply(_: *gtk.Button, d: *TextDialog) callconv(.c) void {
        const buffer = d.view.getBuffer();
        var start: gtk.TextIter = undefined;
        var end: gtk.TextIter = undefined;
        buffer.getBounds(&start, &end);
        const text_z = buffer.getText(&start, &end, 0);
        defer glib.free(@ptrCast(text_z));
        const page_ = d.page;
        const apply = d.apply;
        const copy = page_.tables.allocator().dupe(u8, std.mem.span(text_z)) catch return;
        d.window.destroy();
        apply(page_, copy);
    }

    // A one-line question.
    const Prompt = struct { page: *Page, window: *gtk.Window, entry: *gtk.Entry, ok: *const fn (*Page, []const u8) void };

    fn prompt(self: *Page, title: [:0]const u8, label: [:0]const u8, placeholder: [:0]const u8, ok_label: [:0]const u8, ok: *const fn (*Page, []const u8) void) void {
        const d = std.heap.c_allocator.create(Prompt) catch return;
        const dialog = gtk.Window.new();
        dialog.setTitle(title);
        dialog.setTransientFor(self.window);
        dialog.setModal(1);
        common.dialogs.closeOnEscape(dialog);
        dialog.setDefaultSize(460, -1);
        dialog.as(gtk.Widget).addCssClass("dkde");
        const box = gtk.Box.new(.vertical, 10);
        box.as(gtk.Widget).setMarginTop(16);
        box.as(gtk.Widget).setMarginBottom(16);
        box.as(gtk.Widget).setMarginStart(16);
        box.as(gtk.Widget).setMarginEnd(16);
        dialog.setChild(box.as(gtk.Widget));
        const l = gtk.Label.new(label);
        l.setWrap(1);
        l.setXalign(0);
        box.append(l.as(gtk.Widget));
        const entry = gtk.Entry.new();
        entry.setPlaceholderText(placeholder);
        box.append(entry.as(gtk.Widget));
        const button = gtk.Button.newWithLabel(ok_label);
        button.as(gtk.Widget).addCssClass("suggested-action");
        button.as(gtk.Widget).setHalign(.end);
        d.* = .{ .page = self, .window = dialog, .entry = entry, .ok = ok };
        _ = gtk.Button.signals.clicked.connect(button, *Prompt, &onPromptOk, d, .{});
        _ = gtk.Entry.signals.activate.connect(entry, *Prompt, &onPromptEnter, d, .{});
        box.append(button.as(gtk.Widget));
        _ = gtk.Widget.signals.destroy.connect(dialog, *Prompt, &onPromptDestroy, d, .{});
        dialog.present();
    }

    fn onPromptDestroy(_: *gtk.Window, d: *Prompt) callconv(.c) void {
        std.heap.c_allocator.destroy(d);
    }
    fn onPromptEnter(_: *gtk.Entry, d: *Prompt) callconv(.c) void {
        finishPrompt(d);
    }
    fn onPromptOk(_: *gtk.Button, d: *Prompt) callconv(.c) void {
        finishPrompt(d);
    }
    fn finishPrompt(d: *Prompt) void {
        const page_ = d.page;
        const ok = d.ok;
        const text_in = std.mem.trim(u8, std.mem.span(d.entry.as(gtk.Editable).getText()), " ");
        const copy = page_.tables.allocator().dupe(u8, text_in) catch return;
        d.window.destroy();
        ok(page_, copy);
    }

    // ---- AppArmor: disable, edit a profile, start a new one, allow a refusal ----------------------

    fn selectedProfile(self: *Page) ?security.Profile {
        const row = self.first_list.selectedRow() orelse return null;
        return if (row < self.profiles.len) self.profiles[row] else null;
    }

    fn onDisableProfile(_: *gtk.Button, self: *Page) callconv(.c) void {
        const p = self.selectedProfile() orelse return;
        if (!edit.validPath(p.name) and !edit.validName(p.name)) return self.fail("This profile's name cannot be used safely.");
        self.runArgs("Disable an AppArmor profile", &.{ "aa-disable", p.name }, "");
    }

    fn onEditProfile(_: *gtk.Button, self: *Page) callconv(.c) void {
        const p = self.selectedProfile() orelse return;
        const file = edit.profileFile(self.tables.allocator(), p.name) catch return self.fail("This profile's file name cannot be worked out safely.");
        const path = std.fmt.allocPrint(self.tables.allocator(), "/etc/apparmor.d/{s}", .{file}) catch return;
        self.edit_file = file;
        common.elevate.runCapture(self.window, "Read an AppArmor profile", &.{ "cat", path }, Page, onProfileRead, self);
    }

    fn onProfileRead(self: *Page, outcome: common.elevate.Outcome, out: []const u8) void {
        if (outcome == .failed) return self.fail("The profile's file could not be read (profiles that are built into the kernel or named differently have no file).");
        if (outcome != .ok) return;
        self.textDialog(t("Edit profile"), t("The profile as it is in /etc/apparmor.d. Saving checks that it parses, keeps a copy of the old file once, and loads it."), out, true, t("Save and load"), saveProfile);
    }

    fn saveProfile(self: *Page, text: []const u8) void {
        self.runArgs("Replace an AppArmor profile", &.{ "sh", "-c", edit.save_profile_script, "sh", self.edit_file }, text);
    }

    fn onNewProfile(_: *gtk.Button, self: *Page) callconv(.c) void {
        self.prompt(t("New profile"), t("The full path of the program to confine, for example /usr/bin/myapp. The profile starts in complain mode: use the program, then Allow what the refusals show it needs."), "/usr/bin/…", t("Create"), createProfile);
    }

    fn createProfile(self: *Page, path: []const u8) void {
        var argv: [3][]const u8 = undefined;
        const n = edit.newProfileArgs(path, &argv) catch return self.fail("Enter an absolute path without quotes or special characters.");
        self.runArgs("Start an AppArmor profile for a program", argv[0..n], "");
    }

    // ---- allowing what was refused ------------------------------------------------------------

    fn selectedDenial(self: *Page) ?security.Denial {
        const row = self.denial_list.selectedRow() orelse return null;
        return if (row < self.denials.len) self.denials[row] else null;
    }

    fn onAllow(_: *gtk.Button, self: *Page) callconv(.c) void {
        const d = self.selectedDenial() orelse return;
        if (self.kind == .apparmor) return self.allowAppArmor(d);
        self.allowSelinux(d);
    }

    fn allowAppArmor(self: *Page, d: security.Denial) void {
        const a = self.tables.allocator();
        const rule = (edit.appArmorRule(a, d) catch return self.fail("This refusal names something that cannot be turned into a rule safely.")) orelse return self.fail("There is no simple rule for this kind of refusal. Edit the profile instead.");
        const file = edit.profileFile(a, d.confinement) catch return self.fail("The profile's file name cannot be worked out safely.");
        self.edit_file = file;
        self.edit_rule = rule;
        var body: [600]u8 = undefined;
        const text_body = std.fmt.bufPrint(&body, "Add to /etc/apparmor.d/local/{s}:\n\n    {s}\n\nThen the profile is reloaded. {s}", .{ file, rule, if (d.only_logged) "This was only logged, so the program works today; the rule keeps it working when the profile is enforced." else "" }) catch return;
        self.textDialog(t("Allow this"), t("This rule would let the program do what was refused. Check it is what you want: it widens what the program may do."), text_body, false, t("Add the rule"), applyAppArmorRule);
    }

    fn applyAppArmorRule(self: *Page, _: []const u8) void {
        common.elevate.runCapture(self.window, "Allow an action in an AppArmor profile", &.{ "sh", "-c", edit.add_rule_script, "sh", self.edit_file, self.edit_rule }, Page, onRuleAdded, self);
    }

    fn onRuleAdded(self: *Page, outcome: common.elevate.Outcome, out: []const u8) void {
        if (outcome == .failed) return self.fail(out);
        if (outcome != .ok) return;
        if (std.mem.indexOf(u8, out, "LOCAL-UNUSED") != null) {
            self.detail.setText(t("The rule was written, but this profile does not include its local override file, so it has no effect. Use Edit profile… and add the line #include <local/NAME> inside it."));
        } else self.detail.setText(t("Rule added and the profile reloaded."));
        self.load();
    }

    fn allowSelinux(self: *Page, d: security.Denial) void {
        if (d.raw.len == 0) return self.fail("The audit line is not available for this refusal.");
        const a = self.tables.allocator();
        self.edit_file = edit.moduleName(a, d) catch return self.fail("A module name could not be made from this refusal.");
        self.edit_rule = a.dupe(u8, d.raw) catch return;
        // audit2allow needs no privileges to say what it would allow.
        const line = std.fmt.allocPrint(a, "{s}\n", .{d.raw}) catch return;
        common.proc.runInput(Page, self.guard, &.{ "audit2allow" }, line, onAllowPreview);
    }

    fn onAllowPreview(self: *Page, ok: bool, out: []const u8) void {
        if (!ok or out.len == 0) return self.fail("audit2allow (policycoreutils-python-utils) is needed to build a rule, and could not make one from this refusal.");
        self.textDialog(t("Allow this"), t("This policy module would let the program do what was refused. Check it is what you want: it widens what the program may do."), out, false, t("Install the module"), installModule);
    }

    fn installModule(self: *Page, _: []const u8) void {
        const input = std.fmt.allocPrint(self.tables.allocator(), "{s}\n", .{self.edit_rule}) catch return;
        self.runArgs("Install an SELinux policy module", &.{ "sh", "-c", edit.allow_script, "sh", self.edit_file }, input);
    }

    fn onPermissiveDomain(_: *gtk.Button, self: *Page) callconv(.c) void {
        const d = self.selectedDenial() orelse return;
        if (!edit.validType(d.confinement)) return self.fail("This refusal does not name a domain.");
        self.runArgs("Make an SELinux domain permissive", &.{ "semanage", "permissive", "-a", d.confinement }, "");
    }

    // ---- SELinux: boot mode, relabel ------------------------------------------------------------

    fn onBootMode(_: *gtk.Button, self: *Page) callconv(.c) void {
        self.prompt(t("SELinux at boot"), t("Type enforcing, permissive or disabled. This is read at the next start-up; Make permissive / Make enforcing change the running system."), "enforcing", t("Save"), setBootMode);
    }

    fn setBootMode(self: *Page, mode: []const u8) void {
        if (!edit.modeValid(mode)) return self.fail("Type enforcing, permissive or disabled.");
        self.runArgs("Choose SELinux's mode for the next start-up", &.{ "sh", "-c", edit.set_boot_mode_script, "sh", mode }, "");
    }

    fn onRelabel(_: *gtk.Button, self: *Page) callconv(.c) void {
        self.runArgs("Relabel every file at the next start-up", &.{ "touch", "/.autorelabel" }, "");
    }

    // ---- SELinux: modules, ports, files -----------------------------------------------------------

    /// A list of up to three text columns for the modules and the ports.
    const Table = struct {
        list: *simplelist.SimpleList,
        rows: [][3][]const u8 = &.{},

        fn text(owner: *anyopaque, row: usize, col: usize, _: []u8) []const u8 {
            const tb: *Table = @ptrCast(@alignCast(owner));
            return tb.rows[row][@min(col, 2)];
        }
        fn less(owner: *anyopaque, a: usize, b: usize, col: usize) bool {
            const tb: *Table = @ptrCast(@alignCast(owner));
            return std.ascii.lessThanIgnoreCase(tb.rows[a][@min(col, 2)], tb.rows[b][@min(col, 2)]);
        }
        fn key(owner: *anyopaque, row: usize) u64 {
            const tb: *Table = @ptrCast(@alignCast(owner));
            return std.hash.Wyhash.hash(0, tb.rows[row][0]) ^ std.hash.Wyhash.hash(1, tb.rows[row][1]);
        }
    };

    const module_specs = [_]simplelist.ColumnSpec{ .{ .title = "Module", .expand = true }, .{ .title = "Version", .width = 120 }, .{ .title = "State", .width = 120 } };
    const port_specs = [_]simplelist.ColumnSpec{ .{ .title = "Type", .expand = true }, .{ .title = "Protocol", .width = 100 }, .{ .title = "Ports", .width = 200 } };

    fn newTable(gpa: std.mem.Allocator, specs: []const simplelist.ColumnSpec, selection: *const fn (*anyopaque) void) *Table {
        const tb = gpa.create(Table) catch @panic("OOM");
        tb.* = .{ .list = undefined };
        tb.list = simplelist.SimpleList.create(gpa, specs, .{ .owner = tb, .text = Table.text, .less = Table.less, .key = Table.key, .selection_changed = selection });
        return tb;
    }

    fn buildSelinuxTabs(self: *Page, gpa: std.mem.Allocator) void {
        self.modules = newTable(gpa, &module_specs, onTableSelection);
        self.ports = newTable(gpa, &port_specs, onTableSelection);
        _ = self.stack.addTitled(self.moduleBox(), "modules", t("Policy modules"));
        _ = self.stack.addTitled(self.portBox(), "ports", t("Ports"));
        _ = self.stack.addTitled(self.fileBox(), "files", t("File labels"));
    }

    fn onTableSelection(owner: *anyopaque) void {
        _ = owner;
    }

    fn tabBox(list: *simplelist.SimpleList, buttons: []const *gtk.Button) *gtk.Widget {
        const box = gtk.Box.new(.vertical, 6);
        const row = gtk.Box.new(.horizontal, 6);
        row.as(gtk.Widget).setMarginStart(8);
        row.as(gtk.Widget).setMarginTop(6);
        for (buttons) |b| row.append(b.as(gtk.Widget));
        box.append(row.as(gtk.Widget));
        list.widget.setVexpand(1);
        box.append(list.widget);
        return box.as(gtk.Widget);
    }

    fn moduleBox(self: *Page) *gtk.Widget {
        const load_b = gtk.Button.newWithLabel(t("Load modules"));
        _ = gtk.Button.signals.clicked.connect(load_b, *Page, &onLoadModules, self, .{});
        const names = [3][:0]const u8{ "Remove", "Disable", "Enable" };
        for (names, 0..) |n, i| {
            const b = gtk.Button.newWithLabel(n);
            _ = gtk.Button.signals.clicked.connect(b, *Page, if (i == 0) &onModuleRemove else if (i == 1) &onModuleDisable else &onModuleEnable, self, .{});
            self.module_buttons[i] = b;
        }
        return tabBox(self.modules.list, &.{ load_b, self.module_buttons[0], self.module_buttons[1], self.module_buttons[2] });
    }

    fn portBox(self: *Page) *gtk.Widget {
        const load_b = gtk.Button.newWithLabel(t("Load local ports"));
        _ = gtk.Button.signals.clicked.connect(load_b, *Page, &onLoadPorts, self, .{});
        const add_b = gtk.Button.newWithLabel(t("Add port…"));
        _ = gtk.Button.signals.clicked.connect(add_b, *Page, &onAddPort, self, .{});
        self.port_remove = gtk.Button.newWithLabel(t("Remove"));
        _ = gtk.Button.signals.clicked.connect(self.port_remove, *Page, &onRemovePort, self, .{});
        return tabBox(self.ports.list, &.{ load_b, add_b, self.port_remove });
    }

    fn fileBox(self: *Page) *gtk.Widget {
        const box = gtk.Box.new(.vertical, 8);
        box.as(gtk.Widget).setMarginStart(12);
        box.as(gtk.Widget).setMarginTop(10);
        const hint = gtk.Label.new(t("A file's label decides which programs may touch it. Type a path, then show its label, put the default one back (restorecon), or give a folder a label permanently."));
        hint.setWrap(1);
        hint.setXalign(0);
        box.append(hint.as(gtk.Widget));
        self.path_entry = gtk.Entry.new();
        self.path_entry.setPlaceholderText("/srv/www");
        box.append(self.path_entry.as(gtk.Widget));
        const row = gtk.Box.new(.horizontal, 6);
        const show_b = gtk.Button.newWithLabel(t("Show label"));
        _ = gtk.Button.signals.clicked.connect(show_b, *Page, &onShowLabel, self, .{});
        const restore_b = gtk.Button.newWithLabel(t("Restore default label"));
        _ = gtk.Button.signals.clicked.connect(restore_b, *Page, &onRestoreLabel, self, .{});
        const set_b = gtk.Button.newWithLabel(t("Set label…"));
        _ = gtk.Button.signals.clicked.connect(set_b, *Page, &onSetLabel, self, .{});
        row.append(show_b.as(gtk.Widget));
        row.append(restore_b.as(gtk.Widget));
        row.append(set_b.as(gtk.Widget));
        box.append(row.as(gtk.Widget));
        return box.as(gtk.Widget);
    }

    fn pathText(self: *Page) ?[]const u8 {
        const text_in = std.mem.trim(u8, std.mem.span(self.path_entry.as(gtk.Editable).getText()), " ");
        if (!edit.validPath(text_in)) {
            self.fail("Type an absolute path without quotes or special characters.");
            return null;
        }
        return self.tables.allocator().dupe(u8, text_in) catch null;
    }

    fn onShowLabel(_: *gtk.Button, self: *Page) callconv(.c) void {
        const path = self.pathText() orelse return;
        common.proc.run(Page, self.guard, &.{ "ls", "-Zd", path }, onLabelShown);
    }

    fn onLabelShown(self: *Page, ok: bool, out: []const u8) void {
        var buf: [400]u8 = undefined;
        self.detail.setText(if (ok) (std.fmt.bufPrintSentinel(&buf, "{s}", .{std.mem.trim(u8, out, " \n")}, 0) catch "") else t("Could not read the label (does the path exist?)."));
    }

    fn onRestoreLabel(_: *gtk.Button, self: *Page) callconv(.c) void {
        const path = self.pathText() orelse return;
        self.runArgs("Put the default security label back", &.{ "restorecon", "-Rv", path }, "");
    }

    fn onSetLabel(_: *gtk.Button, self: *Page) callconv(.c) void {
        const path = self.pathText() orelse return;
        self.edit_file = path;
        self.prompt(t("Set label"), t("The SELinux type to give this path and everything under it, for example httpd_sys_content_t. It is remembered for restorecon and relabelling."), "httpd_sys_content_t", t("Set"), applyLabel);
    }

    fn applyLabel(self: *Page, type_name: []const u8) void {
        if (!edit.validType(type_name)) return self.fail("A type has letters, digits and underscores only.");
        self.runArgs("Give a path an SELinux label", &.{ "sh", "-c", "semanage fcontext -a -t \"$1\" \"$2(/.*)?\" && restorecon -Rv \"$2\"", "sh", type_name, self.edit_file }, "");
    }

    fn fillTable(tb: *Table, rows: [][3][]const u8) void {
        tb.rows = rows;
        tb.list.update(rows.len);
    }

    fn onLoadModules(_: *gtk.Button, self: *Page) callconv(.c) void {
        common.elevate.runCapture(self.window, "List the SELinux policy modules", &.{ "semodule", "-l" }, Page, onModulesRead, self);
    }

    fn onModulesRead(self: *Page, outcome: common.elevate.Outcome, out: []const u8) void {
        if (outcome != .ok) {
            if (outcome == .failed) self.detail.setText(t("Could not list the modules (semodule)."));
            return;
        }
        const a = self.tables.allocator();
        const mods = edit.parseModules(a, out) catch return;
        const rows = a.alloc([3][]const u8, mods.len) catch return;
        for (mods, 0..) |m, i| rows[i] = .{ m.name, m.version, if (m.disabled) "Disabled" else "Active" };
        fillTable(self.modules, rows);
    }

    fn selectedModule(self: *Page) ?[]const u8 {
        const row = self.modules.list.selectedRow() orelse return null;
        return if (row < self.modules.rows.len) self.modules.rows[row][0] else null;
    }

    fn onModuleRemove(_: *gtk.Button, self: *Page) callconv(.c) void {
        const name = self.selectedModule() orelse return;
        self.runArgs("Remove an SELinux policy module", &.{ "semodule", "-r", name }, "");
    }
    fn onModuleDisable(_: *gtk.Button, self: *Page) callconv(.c) void {
        const name = self.selectedModule() orelse return;
        self.runArgs("Disable an SELinux policy module", &.{ "semodule", "-d", name }, "");
    }
    fn onModuleEnable(_: *gtk.Button, self: *Page) callconv(.c) void {
        const name = self.selectedModule() orelse return;
        self.runArgs("Enable an SELinux policy module", &.{ "semodule", "-e", name }, "");
    }

    fn onLoadPorts(_: *gtk.Button, self: *Page) callconv(.c) void {
        // Only the ports changed on this machine: the built-in ones cannot be removed.
        common.elevate.runCapture(self.window, "List the SELinux port labels set on this machine", &.{ "semanage", "port", "-l", "-C" }, Page, onPortsRead, self);
    }

    fn onPortsRead(self: *Page, outcome: common.elevate.Outcome, out: []const u8) void {
        if (outcome != .ok) {
            if (outcome == .failed) self.detail.setText(t("Could not list the ports (semanage, from policycoreutils-python-utils)."));
            return;
        }
        const a = self.tables.allocator();
        const ports = edit.parsePorts(a, out) catch return;
        const rows = a.alloc([3][]const u8, ports.len) catch return;
        for (ports, 0..) |p, i| rows[i] = .{ p.type_name, p.proto, p.ports };
        fillTable(self.ports, rows);
        if (ports.len == 0) self.detail.setText(t("No ports have been given a label on this machine."));
    }

    fn onAddPort(_: *gtk.Button, self: *Page) callconv(.c) void {
        self.prompt(t("Add a port label"), t("Type: the SELinux type, the protocol (tcp or udp) and the port, for example: http_port_t tcp 8080"), "http_port_t tcp 8080", t("Add"), applyPort);
    }

    fn applyPort(self: *Page, text_in: []const u8) void {
        var it = std.mem.tokenizeScalar(u8, text_in, ' ');
        const type_name = it.next() orelse return self.fail("Type the type, protocol and port.");
        const proto = it.next() orelse return self.fail("Type the type, protocol and port.");
        const port = it.next() orelse return self.fail("Type the type, protocol and port.");
        if (!edit.validType(type_name)) return self.fail("A type has letters, digits and underscores only.");
        if (!std.mem.eql(u8, proto, "tcp") and !std.mem.eql(u8, proto, "udp")) return self.fail("The protocol is tcp or udp.");
        for (port) |ch| if (!(std.ascii.isDigit(ch) or ch == '-')) return self.fail("The port is a number or a range such as 8000-8100.");
        self.runArgs("Give a port an SELinux label", &.{ "semanage", "port", "-a", "-t", type_name, "-p", proto, port }, "");
    }

    fn onRemovePort(_: *gtk.Button, self: *Page) callconv(.c) void {
        const row = self.ports.list.selectedRow() orelse return;
        if (row >= self.ports.rows.len) return;
        const r = self.ports.rows[row];
        if (!edit.validType(r[0])) return;
        // The ports column can hold several; remove them one by one with the first, then reload.
        var it = std.mem.tokenizeAny(u8, r[2], ", ");
        const first = it.next() orelse return;
        self.runArgs("Remove an SELinux port label", &.{ "semanage", "port", "-d", "-t", r[0], "-p", r[1], first }, "");
    }

    fn onChanged(self: *Page, outcome: common.elevate.Outcome, message: []const u8) void {
        if (outcome == .failed) {
            var b: [400]u8 = undefined;
            common.dialogs.showError(self.window, t("The change could not be made"), std.fmt.bufPrintSentinel(&b, "{s}", .{message[0..@min(message.len, 390)]}, 0) catch null);
        }
        if (outcome == .ok) self.load();
    }
};
