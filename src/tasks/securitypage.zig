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

const security = @import("security.zig");
const simplelist = @import("simplelist.zig");
const services = @import("services.zig");

const t = common.tr;

/// Which security module this machine runs, from the kernel's own files.
pub fn detect() security.Kind {
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
        root.append(services.scrolled(bar));

        self.status.setXalign(0);
        self.status.setWrap(1);
        self.status.as(gtk.Widget).setMarginStart(12);
        self.status.as(gtk.Widget).setMarginTop(6);
        self.status.as(gtk.Widget).setMarginBottom(4);
        self.status.setText(t("Choose Load… to read the current state. Reading it needs the administrator password."));
        root.append(self.status.as(gtk.Widget));

        _ = self.stack.addTitled(self.first_list.widget, "first", if (apparmor) t("Profiles") else t("Settings"));
        _ = self.stack.addTitled(self.denial_list.widget, "denials", t("Recent refusals"));
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

    pub fn destroy(self: *Page) void {
        self.guard.kill();
        self.first_list.destroy();
        self.denial_list.destroy();
        self.data.deinit();
        self.gpa.destroy(self);
    }

    /// Called when the page is shown: reads what needs no password.
    pub fn reload(self: *Page) void {
        if (glib.getenv("DKDE_DEBUG_SECURITY") != null and !self.loaded) return self.load();
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
        if (self.denial_list.selectedRow()) |r| {
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

    fn onChanged(self: *Page, outcome: common.elevate.Outcome, message: []const u8) void {
        if (outcome == .failed) {
            var b: [400]u8 = undefined;
            common.dialogs.showError(self.window, t("The change could not be made"), std.fmt.bufPrintSentinel(&b, "{s}", .{message[0..@min(message.len, 390)]}, 0) catch null);
        }
        if (outcome == .ok) self.load();
    }
};
