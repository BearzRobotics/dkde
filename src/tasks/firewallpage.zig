//! The Firewall page: ufw or firewalld (nftables by hand is shown, not edited). Rules are read as
//! plain sentences and changed through the administrator prompt; firewall.zig parses what the
//! tools print and builds their arguments, so nothing a person types is ever shell text.

const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

pub const firewall = @import("firewall.zig");
const nft = @import("nft.zig");
const iptables = @import("iptables.zig");
const simplelist = @import("simplelist.zig");
const services = @import("services.zig");

const t = common.tr;

fn exists(path: [:0]const u8) bool {
    return glib.fileTest(path, .{ .exists = true }) != 0;
}

fn hasProgram(name: [:0]const u8) bool {
    const found = glib.findProgramInPath(name) orelse return false;
    glib.free(found);
    return true;
}

/// Set from Task Manager's settings: use this backend instead of the detected one (`.none` hides the page).
pub var forced: ?firewall.Backend = null;

pub fn detect() firewall.Backend {
    if (forced) |f| return f;
    if (glib.getenv("DKDE_DEBUG_FIREWALL") != null) {
        // Sample data for trying the page: DKDE_DEBUG_FIREWALL_BACKEND = ufw (default), nft or iptables.
        const which = if (glib.getenv("DKDE_DEBUG_FIREWALL_BACKEND")) |w| std.mem.span(w) else "ufw";
        if (std.mem.eql(u8, which, "nft")) return .nft;
        if (std.mem.eql(u8, which, "iptables")) return .iptables;
        return .ufw;
    }
    const ufw_active = blk: {
        var contents: [*]u8 = undefined;
        var length: usize = 0;
        if (glib.fileGetContents("/etc/ufw/ufw.conf", &contents, &length, null) == 0) break :blk false;
        defer glib.free(contents);
        break :blk std.mem.indexOf(u8, contents[0..length], "ENABLED=yes") != null;
    };
    return firewall.choose(hasProgram("ufw"), hasProgram("firewall-cmd"), hasProgram("nft"), hasProgram("iptables"), exists("/run/firewalld"), ufw_active);
}

const ufw_specs = [_]simplelist.ColumnSpec{
    .{ .title = "#", .right = true, .width = 50 },
    .{ .title = "Rule", .expand = true },
    .{ .title = "To", .width = 150 },
    .{ .title = "Action", .width = 110 },
    .{ .title = "From", .width = 160 },
};
const netfilter_specs = [_]simplelist.ColumnSpec{
    .{ .title = "Chain", .width = 230 },
    .{ .title = "Rule", .expand = true },
    .{ .title = "#", .right = true, .width = 70 },
};
const zone_specs = [_]simplelist.ColumnSpec{
    .{ .title = "Kind", .width = 90 },
    .{ .title = "Name", .width = 200 },
    .{ .title = "Meaning", .expand = true },
};

pub const Page = struct {
    gpa: std.mem.Allocator,
    window: *gtk.Window,
    backend: firewall.Backend,
    widget: *gtk.Widget,
    guard: *common.proc.Guard(Page),
    stack: *gtk.Stack,
    status: *gtk.Label,
    detail: *gtk.Label,
    list: *simplelist.SimpleList,
    raw: *gtk.TextView,
    power_button: *gtk.Button,
    add_button: *gtk.Button,
    remove_button: *gtk.Button,
    in_drop: *gtk.DropDown,
    out_drop: *gtk.DropDown,
    data: std.heap.ArenaAllocator,
    ufw: firewall.UfwStatus = .{},
    zone: firewall.Zone = .{},
    /// firewalld: every zone, the one shown, and the service names it knows (for the add dialog).
    zones: []firewall.Zone = &.{},
    zone_drop: *gtk.DropDown,
    service_names: std.ArrayList([]u8) = .empty,
    running: bool = true,
    /// nftables and iptables: chains and their rules, in order.
    rows: []nft.Row = &.{},
    policy_accept: *gtk.Button,
    policy_drop: *gtk.Button,
    save_button: *gtk.Button,
    /// A firewalld change is two commands (permanent, then reload): what to run after the first.
    reloading: bool = false,
    syncing: bool = false,

    const policies = [_]?[*:0]const u8{ "allow", "deny", "reject", null };

    pub fn create(gpa: std.mem.Allocator, window: *gtk.Window, backend: firewall.Backend) *Page {
        const self = gpa.create(Page) catch @panic("OOM");
        self.* = .{
            .gpa = gpa,
            .window = window,
            .backend = backend,
            .widget = undefined,
            .guard = undefined,
            .stack = gtk.Stack.new(),
            .status = gtk.Label.new(""),
            .detail = gtk.Label.new(""),
            .list = undefined,
            .raw = gtk.TextView.new(),
            .power_button = gtk.Button.newWithLabel(t("Turn on")),
            .add_button = gtk.Button.newWithLabel(t("Add rule…")),
            .remove_button = gtk.Button.newWithLabel(t("Remove")),
            .policy_accept = gtk.Button.newWithLabel(t("Policy: allow")),
            .policy_drop = gtk.Button.newWithLabel(t("Policy: drop")),
            .save_button = gtk.Button.newWithLabel(t("Save for restart")),
            .in_drop = gtk.DropDown.newFromStrings(@ptrCast(&policies)),
            .out_drop = gtk.DropDown.newFromStrings(@ptrCast(&policies)),
            .zone_drop = gtk.DropDown.newFromStrings(@ptrCast(&[_]?[*:0]const u8{ "public", null })),
            .data = .init(gpa),
        };
        self.guard = common.proc.Guard(Page).create(self);
        const is_ufw = backend == .ufw;
        const is_nf = backend == .nft or backend == .iptables;
        self.list = simplelist.SimpleList.create(gpa, if (is_ufw) &ufw_specs else if (is_nf) &netfilter_specs else &zone_specs, .{
            .owner = self,
            .text = text,
            .less = less,
            .key = key,
            .selection_changed = onSelection,
        });

        const root = gtk.Box.new(.vertical, 0);
        const bar = services.commandBar(switch (backend) {
            .ufw => t("Firewall (ufw)"),
            .firewalld => t("Firewall (firewalld)"),
            .iptables => t("Firewall (iptables)"),
            else => t("Firewall (nftables)"),
        });
        const switcher = gtk.StackSwitcher.new();
        switcher.setStack(self.stack);
        bar.append(switcher.as(gtk.Widget));
        bar.append(common.elevate.padlock(window).as(gtk.Widget));
        common.elevate.onChange(onLockChanged, self);
        const load_button = gtk.Button.newWithLabel(t("Load…"));
        load_button.as(gtk.Widget).setTooltipText(t("Read the firewall's rules; needs the administrator password"));
        _ = gtk.Button.signals.clicked.connect(load_button, *Page, &onLoad, self, .{});
        bar.append(load_button.as(gtk.Widget));
        if (!is_nf) {
            self.power_button.as(gtk.Widget).setSensitive(0);
            _ = gtk.Button.signals.clicked.connect(self.power_button, *Page, &onPower, self, .{});
            bar.append(self.power_button.as(gtk.Widget));
        }
        self.add_button.as(gtk.Widget).setSensitive(0);
        _ = gtk.Button.signals.clicked.connect(self.add_button, *Page, &onAdd, self, .{});
        bar.append(self.add_button.as(gtk.Widget));
        self.remove_button.as(gtk.Widget).setSensitive(0);
        _ = gtk.Button.signals.clicked.connect(self.remove_button, *Page, &onRemove, self, .{});
        bar.append(self.remove_button.as(gtk.Widget));
        if (is_nf) {
            // What a base chain does with traffic none of its rules covers, and keeping the rules across a restart.
            self.policy_accept.as(gtk.Widget).setSensitive(0);
            self.policy_accept.as(gtk.Widget).setTooltipText(t("Let through whatever no rule of the selected base chain covers"));
            _ = gtk.Button.signals.clicked.connect(self.policy_accept, *Page, &onPolicyAccept, self, .{});
            bar.append(self.policy_accept.as(gtk.Widget));
            self.policy_drop.as(gtk.Widget).setSensitive(0);
            self.policy_drop.as(gtk.Widget).setTooltipText(t("Block whatever no rule of the selected base chain covers"));
            _ = gtk.Button.signals.clicked.connect(self.policy_drop, *Page, &onPolicyDrop, self, .{});
            bar.append(self.policy_drop.as(gtk.Widget));
            self.save_button.as(gtk.Widget).setSensitive(0);
            self.save_button.as(gtk.Widget).setTooltipText(t("Write the rules to the system's configuration so they are loaded at start-up"));
            _ = gtk.Button.signals.clicked.connect(self.save_button, *Page, &onSave, self, .{});
            bar.append(self.save_button.as(gtk.Widget));
        }
        root.append(services.scrolled(bar));

        self.status.setXalign(0);
        self.status.setWrap(1);
        self.status.as(gtk.Widget).setMarginStart(12);
        self.status.as(gtk.Widget).setMarginTop(6);
        self.status.setText(t("Unlock with the padlock (once, instead of for each action), or choose Load… to read the firewall. Reading it needs the administrator password."));
        root.append(self.status.as(gtk.Widget));

        if (is_ufw) {
            // What happens to traffic no rule mentions.
            const row = gtk.Box.new(.horizontal, 8);
            row.as(gtk.Widget).setMarginStart(12);
            row.as(gtk.Widget).setMarginTop(4);
            row.as(gtk.Widget).setMarginBottom(4);
            row.append(gtk.Label.new(t("Incoming traffic that no rule covers:")).as(gtk.Widget));
            row.append(self.in_drop.as(gtk.Widget));
            row.append(gtk.Label.new(t("Outgoing:")).as(gtk.Widget));
            row.append(self.out_drop.as(gtk.Widget));
            self.in_drop.as(gtk.Widget).setSensitive(0);
            self.out_drop.as(gtk.Widget).setSensitive(0);
            _ = gobject.Object.signals.notify.connect(self.in_drop, *Page, &onInDefault, self, .{ .detail = "selected" });
            _ = gobject.Object.signals.notify.connect(self.out_drop, *Page, &onOutDefault, self, .{ .detail = "selected" });
            root.append(row.as(gtk.Widget));
        }

        if (backend == .firewalld) {
            const row = gtk.Box.new(.horizontal, 8);
            row.as(gtk.Widget).setMarginStart(12);
            row.as(gtk.Widget).setMarginTop(4);
            row.as(gtk.Widget).setMarginBottom(4);
            row.append(gtk.Label.new(t("Zone:")).as(gtk.Widget));
            row.append(self.zone_drop.as(gtk.Widget));
            const hint = gtk.Label.new(t("A zone is a set of rules for a kind of network. The default zone applies to networks nothing else claims."));
            hint.as(gtk.Widget).addCssClass("dim-label");
            hint.setWrap(1);
            row.append(hint.as(gtk.Widget));
            _ = gobject.Object.signals.notify.connect(self.zone_drop, *Page, &onZonePicked, self, .{ .detail = "selected" });
            root.append(row.as(gtk.Widget));
        }
        _ = self.stack.addTitled(self.list.widget, "rules", t("Rules"));
        self.raw.setEditable(0);
        self.raw.setMonospace(1);
        const raw_scroll = gtk.ScrolledWindow.new();
        raw_scroll.setChild(self.raw.as(gtk.Widget));
        _ = self.stack.addTitled(raw_scroll.as(gtk.Widget), "raw", t("Raw ruleset"));
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

    /// The padlock opened: read the rules, without a password to type.
    fn onLockChanged(data: ?*anyopaque) void {
        const self: *Page = @ptrCast(@alignCast(data.?));
        if (common.elevate.isUnlocked() and self.widget.getMapped() != 0) self.load();
    }

    pub fn destroy(self: *Page) void {
        common.elevate.removeListener(onLockChanged, self);
        self.guard.kill();
        self.list.destroy();
        for (self.service_names.items) |n| self.gpa.free(n);
        self.service_names.deinit(self.gpa);
        self.data.deinit();
        self.gpa.destroy(self);
    }

    pub fn reload(self: *Page) void {
        if (glib.getenv("DKDE_DEBUG_FIREWALL") != null and self.ufw.rules.len == 0 and self.rows.len == 0) self.load();
        if (common.elevate.isUnlocked()) self.load();
    }

    // ---- reading -------------------------------------------------------------------------

    fn onLoad(_: *gtk.Button, self: *Page) callconv(.c) void {
        self.load();
    }

    /// Dev aid: DKDE_DEBUG_FIREWALL=<folder> reads ufw-numbered.txt and ufw-verbose.txt from there.
    fn loadDebug(self: *Page, dir: []const u8) void {
        if (self.netfilter()) {
            var p: [512]u8 = undefined;
            const name: []const u8 = if (self.backend == .nft) "nft.json" else "iptables.txt";
            const path = std.fmt.bufPrintSentinel(&p, "{s}/{s}", .{ dir, name }, 0) catch return;
            var contents: [*]u8 = undefined;
            var length: usize = 0;
            if (glib.fileGetContents(path, &contents, &length, null) == 0) return;
            defer glib.free(contents);
            return self.onNetfilterRead(.ok, contents[0..length]);
        }
        var path: [512]u8 = undefined;
        var texts: [2][]u8 = .{ &.{}, &.{} };
        for ([_][]const u8{ "ufw-verbose.txt", "ufw-numbered.txt" }, 0..) |name, i| {
            const p = std.fmt.bufPrintSentinel(&path, "{s}/{s}", .{ dir, name }, 0) catch continue;
            var contents: [*]u8 = undefined;
            var length: usize = 0;
            if (glib.fileGetContents(p, &contents, &length, null) == 0) continue;
            texts[i] = self.gpa.dupe(u8, contents[0..length]) catch &.{};
            glib.free(contents);
        }
        defer for (texts) |x| if (x.len > 0) self.gpa.free(x);
        var joined: std.ArrayList(u8) = .empty;
        defer joined.deinit(self.gpa);
        joined.print(self.gpa, "{s}\n====\n{s}", .{ texts[0], texts[1] }) catch return;
        self.onUfwRead(.ok, joined.items);
    }

    fn load(self: *Page) void {
        if (glib.getenv("DKDE_DEBUG_FIREWALL")) |dir| return self.loadDebug(std.mem.span(dir));
        switch (self.backend) {
            // One command, one password: the verbose status, a separator, the numbered rules.
            .ufw => common.elevate.runCapture(self.window, "Read the firewall's rules", &.{ "sh", "-c", "ufw status verbose; echo ====; ufw status numbered" }, Page, onUfwRead, self),
            // firewalld lets anyone read its settings, so no password is asked to look.
            .firewalld => {
                common.proc.run(Page, self.guard, &.{ "firewall-cmd", "--list-all-zones" }, onZonesRead);
                if (self.service_names.items.len == 0) common.proc.run(Page, self.guard, &.{ "firewall-cmd", "--get-services" }, onServicesRead);
            },
            // One command, one password: the rules as data, a separator, the same as text for the Raw tab.
            .nft => return common.elevate.runCapture(self.window, "Read the firewall's rules", &.{ "sh", "-c", "nft -j list ruleset; echo; echo ====; nft list ruleset" }, Page, onNetfilterRead, self),
            .iptables => return common.elevate.runCapture(self.window, "Read the firewall's rules", &.{ "sh", "-c", "iptables -S; echo ====; iptables -L -n -v --line-numbers" }, Page, onNetfilterRead, self),
            .none => {},
        }
        common.elevate.runCapture(self.window, "Read the firewall's rules", &.{ "nft", "list", "ruleset" }, Page, onRaw, self);
    }

    fn onUfwRead(self: *Page, outcome: common.elevate.Outcome, out: []const u8) void {
        if (outcome != .ok) {
            if (outcome == .failed) self.status.setText(t("Could not read the firewall. Is ufw installed?"));
            return;
        }
        const sep = std.mem.indexOf(u8, out, "\n====\n") orelse out.len;
        const verbose = out[0..sep];
        const numbered = if (sep + 6 <= out.len) out[sep + 6 ..] else "";
        _ = self.data.reset(.retain_capacity);
        self.ufw = firewall.parseUfw(self.data.allocator(), numbered, verbose) catch {
            self.status.setText(t("ufw gave output this page cannot read."));
            return;
        };
        var buf: [320]u8 = undefined;
        if (self.ufw.active) {
            self.status.setText(std.fmt.bufPrintSentinel(&buf, "The firewall is on. Incoming traffic that no rule covers is {s}ed; logging {s}.", .{ if (self.ufw.default_in.len > 0) self.ufw.default_in else "block", if (self.ufw.logging.len > 0) self.ufw.logging else "off" }, 0) catch "");
        } else self.status.setText(t("The firewall is off: every connection is allowed. Turn it on to use the rules below."));
        self.power_button.setLabel(if (self.ufw.active) t("Turn off") else t("Turn on"));
        self.power_button.as(gtk.Widget).setSensitive(1);
        self.add_button.as(gtk.Widget).setSensitive(1);
        self.syncing = true;
        self.in_drop.setSelected(policyIndex(self.ufw.default_in));
        self.out_drop.setSelected(policyIndex(self.ufw.default_out));
        self.syncing = false;
        self.in_drop.as(gtk.Widget).setSensitive(1);
        self.out_drop.as(gtk.Widget).setSensitive(1);
        self.list.update(self.ufw.rules.len);
        onSelection(self);
    }

    fn policyIndex(name: []const u8) c_uint {
        if (std.mem.eql(u8, name, "allow")) return 0;
        if (std.mem.eql(u8, name, "reject")) return 2;
        return 1;
    }

    fn onServicesRead(self: *Page, ok: bool, out: []const u8) void {
        if (!ok) return;
        var it = std.mem.tokenizeAny(u8, out, " \n");
        while (it.next()) |name| {
            const copy = self.gpa.dupe(u8, name) catch break;
            self.service_names.append(self.gpa, copy) catch self.gpa.free(copy);
        }
    }

    fn onZonesRead(self: *Page, ok: bool, out: []const u8) void {
        if (!ok) {
            // The daemon is not running (or refused): say so and offer to start it.
            self.running = false;
            self.status.setText(t("firewalld is not running, so nothing is being filtered by it. Turn it on to read and change its rules."));
            self.power_button.setLabel(t("Turn on"));
            self.power_button.as(gtk.Widget).setSensitive(1);
            self.add_button.as(gtk.Widget).setSensitive(0);
            self.list.update(0);
            return;
        }
        self.running = true;
        const previous: ?[]u8 = if (self.zone.name.len > 0) self.gpa.dupe(u8, self.zone.name) catch null else null;
        defer if (previous) |pz| self.gpa.free(pz);
        _ = self.data.reset(.retain_capacity);
        self.zones = firewall.parseZones(self.data.allocator(), out) catch return;
        if (self.zones.len == 0) return;
        // The zone list in the picker; the default zone (or the one shown before) is selected.
        var names: std.ArrayList(?[*:0]const u8) = .empty;
        defer names.deinit(self.gpa);
        var pick: usize = 0;
        var labels: std.ArrayList([:0]u8) = .empty;
        defer {
            for (labels.items) |l| self.gpa.free(l);
            labels.deinit(self.gpa);
        }
        for (self.zones, 0..) |z, i| {
            const label = std.fmt.allocPrintSentinel(self.gpa, "{s}{s}", .{ z.name, if (z.is_default) " (default)" else if (z.active) " (in use)" else "" }, 0) catch continue;
            labels.append(self.gpa, label) catch continue;
            names.append(self.gpa, label.ptr) catch continue;
            if (previous) |pz| {
                if (std.mem.eql(u8, pz, z.name)) pick = i;
            } else if (z.is_default) pick = i;
        }
        names.append(self.gpa, null) catch return;
        const model = gtk.StringList.new(@ptrCast(names.items.ptr));
        self.syncing = true;
        self.zone_drop.setModel(model.as(gio.ListModel));
        self.zone_drop.setSelected(@intCast(pick));
        self.syncing = false;
        self.showZone(pick);
    }

    fn showZone(self: *Page, index: usize) void {
        if (index >= self.zones.len) return;
        self.zone = self.zones[index];
        var buf: [320]u8 = undefined;
        self.status.setText(std.fmt.bufPrintSentinel(&buf, "firewalld is running. Zone \"{s}\"{s}: interfaces {s}; {d} open services, ports and rules.", .{
            self.zone.name,
            if (self.zone.is_default) " (the default)" else "",
            if (self.zone.interfaces.len > 0) self.zone.interfaces else "none",
            self.zone.items.len,
        }, 0) catch "");
        self.power_button.setLabel(t("Turn off"));
        self.power_button.as(gtk.Widget).setSensitive(1);
        self.add_button.as(gtk.Widget).setSensitive(1);
        self.list.update(self.zone.items.len);
        onSelection(self);
        // Two managers at once fight over the same rules.
        if (ufwEnabled()) self.detail.setText(t("ufw is also switched on. ufw and firewalld both manage the same rules and can undo each other: use one of them."));
    }

    fn onZonePicked(drop: *gtk.DropDown, _: *gobject.ParamSpec, self: *Page) callconv(.c) void {
        if (self.syncing) return;
        self.showZone(drop.getSelected());
    }

    fn ufwEnabled() bool {
        var contents: [*]u8 = undefined;
        var length: usize = 0;
        if (glib.fileGetContents("/etc/ufw/ufw.conf", &contents, &length, null) == 0) return false;
        defer glib.free(contents);
        return std.mem.indexOf(u8, contents[0..length], "ENABLED=yes") != null;
    }

    fn onNetfilterRead(self: *Page, outcome: common.elevate.Outcome, out: []const u8) void {
        if (outcome != .ok) {
            if (outcome == .failed) self.status.setText(t("Could not read the firewall. Is nft (or iptables) installed?"));
            return;
        }
        const sep = std.mem.indexOf(u8, out, "\n====\n") orelse out.len;
        const data = out[0..sep];
        const raw = if (sep + 6 <= out.len) out[sep + 6 ..] else "";
        _ = self.data.reset(.retain_capacity);
        const a = self.data.allocator();
        self.rows = (if (self.backend == .nft) nft.parse(a, data) else iptables.parse(a, data)) catch {
            self.status.setText(t("The firewall's output could not be read."));
            self.rows = &.{};
            return;
        };
        var chains: usize = 0;
        var rules: usize = 0;
        var drops = false;
        for (self.rows) |r| {
            if (r.kind == .chain) chains += 1 else rules += 1;
            if (r.kind == .chain and std.mem.eql(u8, r.policy, "drop")) drops = true;
        }
        var buf: [320]u8 = undefined;
        self.status.setText(std.fmt.bufPrintSentinel(&buf, "{d} chains, {d} rules.{s} Changes apply at once; use Save for restart to keep them after a reboot.", .{ chains, rules, if (drops) " Some chains drop traffic no rule allows." else "" }, 0) catch "");
        self.add_button.as(gtk.Widget).setSensitive(@intFromBool(chains > 0));
        self.save_button.as(gtk.Widget).setSensitive(1);
        self.list.update(self.rows.len);
        onSelection(self);
        if (raw.len > 0) self.onRaw(.ok, raw);
    }

    fn onRaw(self: *Page, outcome: common.elevate.Outcome, out: []const u8) void {
        if (outcome != .ok) return;
        const z = self.gpa.dupeSentinel(u8, out, 0) catch return;
        defer self.gpa.free(z);
        self.raw.getBuffer().setText(z.ptr, @intCast(out.len));
    }

    // ---- the list ------------------------------------------------------------------------

    fn page(owner: *anyopaque) *Page {
        return @ptrCast(@alignCast(owner));
    }

    fn count(self: *const Page) usize {
        if (self.netfilter()) return self.rows.len;
        return if (self.backend == .ufw) self.ufw.rules.len else self.zone.items.len;
    }

    fn netfilter(self: *const Page) bool {
        return self.backend == .nft or self.backend == .iptables;
    }

    fn rowChain(r: nft.Row, buf: []u8) []const u8 {
        // Rules sit under their chain; the chain's own row carries its name.
        if (r.kind == .rule) return "";
        return std.fmt.bufPrint(buf, "{s} {s} {s}", .{ r.family, r.table, r.chain }) catch r.chain;
    }

    fn text(owner: *anyopaque, row: usize, col: usize, buf: []u8) []const u8 {
        const self = page(owner);
        if (self.netfilter()) {
            const r = self.rows[row];
            return switch (col) {
                0 => if (r.kind == .chain) rowChain(r, buf) else "",
                1 => if (r.kind == .rule) r.text else r.text,
                else => if (r.kind == .rule) (std.fmt.bufPrint(buf, "{d}", .{r.handle}) catch "") else "",
            };
        }
        if (self.backend == .ufw) {
            const r = self.ufw.rules[row];
            return switch (col) {
                0 => std.fmt.bufPrint(buf, "{d}", .{r.number}) catch "",
                1 => firewall.explainUfw(buf, r),
                2 => r.to,
                3 => r.action,
                else => r.from,
            };
        }
        const it = self.zone.items[row];
        return switch (col) {
            0 => switch (it.kind) {
                .service => "Service",
                .port => "Port",
                .protocol => "Protocol",
                .rich => "Custom rule",
            },
            1 => it.name,
            else => firewall.explainZoneItem(buf, it),
        };
    }

    fn less(owner: *anyopaque, a: usize, b: usize, col: usize) bool {
        const self = page(owner);
        // The ruleset is a tree in reading order; sorting it would separate rules from their chains.
        if (self.netfilter()) return a < b;
        if (self.backend == .ufw) {
            const x = self.ufw.rules[a];
            const y = self.ufw.rules[b];
            return switch (col) {
                0 => x.number < y.number,
                2 => std.ascii.lessThanIgnoreCase(x.to, y.to),
                3 => std.ascii.lessThanIgnoreCase(x.action, y.action),
                4 => std.ascii.lessThanIgnoreCase(x.from, y.from),
                else => x.number < y.number,
            };
        }
        const x = self.zone.items[a];
        const y = self.zone.items[b];
        return if (col == 0) @intFromEnum(x.kind) < @intFromEnum(y.kind) else std.ascii.lessThanIgnoreCase(x.name, y.name);
    }

    fn key(owner: *anyopaque, row: usize) u64 {
        const self = page(owner);
        if (self.netfilter()) {
            const r = self.rows[row];
            var h = std.hash.Wyhash.init(0);
            h.update(r.family);
            h.update(r.table);
            h.update(r.chain);
            h.update(r.text);
            h.update(std.mem.asBytes(&r.handle));
            return h.final();
        }
        if (self.backend == .ufw) {
            const r = self.ufw.rules[row];
            var h = std.hash.Wyhash.init(0);
            h.update(r.to);
            h.update(r.action);
            h.update(r.from);
            h.update(if (r.v6) "6" else "4");
            return h.final();
        }
        return std.hash.Wyhash.hash(0, self.zone.items[row].name);
    }

    fn onSelection(owner: *anyopaque) void {
        const self = page(owner);
        const row = self.list.selectedRow();
        self.remove_button.as(gtk.Widget).setSensitive(@intFromBool(row != null));
        const r = row orelse {
            self.policy_accept.as(gtk.Widget).setSensitive(0);
            self.policy_drop.as(gtk.Widget).setSensitive(0);
            return;
        };
        var buf: [320]u8 = undefined;
        if (self.netfilter() and r < self.rows.len) {
            const nr = self.rows[r];
            const can_edit = !nr.managed;
            self.remove_button.as(gtk.Widget).setSensitive(@intFromBool(nr.kind == .rule and can_edit));
            const base_chain = nr.kind == .chain and nr.policy.len > 0 and can_edit;
            self.policy_accept.as(gtk.Widget).setSensitive(@intFromBool(base_chain));
            self.policy_drop.as(gtk.Widget).setSensitive(@intFromBool(base_chain));
            var out: [520]u8 = undefined;
            self.detail.setText(std.fmt.bufPrintSentinel(&out, "{s}{s}", .{
                nr.text,
                if (nr.managed) ". This belongs to the firewall manager that created it (firewalld or ufw); it would put it back, so it is read-only here." else "",
            }, 0) catch "");
            return;
        }
        if (self.backend == .ufw and r < self.ufw.rules.len) {
            const rule = self.ufw.rules[r];
            var out: [460]u8 = undefined;
            self.detail.setText(std.fmt.bufPrintSentinel(&out, "{s}.{s}", .{ firewall.explainUfw(&buf, rule), if (rule.v6) "" else " An IPv6 twin of this rule, if there is one, is listed separately; remove both." }, 0) catch "");
        }
    }

    // ---- changes -------------------------------------------------------------------------

    fn fail(self: *Page, message: []const u8) void {
        var b: [400]u8 = undefined;
        common.dialogs.showError(self.window, t("The firewall could not be changed"), std.fmt.bufPrintSentinel(&b, "{s}", .{message[0..@min(message.len, 390)]}, 0) catch null);
    }

    fn onChanged(self: *Page, outcome: common.elevate.Outcome, message: []const u8) void {
        if (outcome == .failed) return self.fail(message);
        if (outcome == .ok) self.load();
    }

    fn onPower(_: *gtk.Button, self: *Page) callconv(.c) void {
        if (self.backend == .ufw) {
            common.elevate.run(self.window, "Turn the firewall on or off", &.{ "ufw", "--force", if (self.ufw.active) "disable" else "enable" }, "", Page, onChanged, self);
        } else {
            const verb: []const u8 = if (self.running) "stop" else "start";
            if (@import("initsys.zig").systemInit() == .dinit) {
                common.elevate.run(self.window, "Turn the firewall on or off", &.{ "dinitctl", "--system", verb, "firewalld" }, "", Page, onChanged, self);
            } else {
                common.elevate.run(self.window, "Turn the firewall on or off", &.{ "systemctl", verb, "firewalld" }, "", Page, onChanged, self);
            }
        }
    }

    fn onInDefault(drop: *gtk.DropDown, _: *gobject.ParamSpec, self: *Page) callconv(.c) void {
        self.setDefault("incoming", drop.getSelected());
    }
    fn onOutDefault(drop: *gtk.DropDown, _: *gobject.ParamSpec, self: *Page) callconv(.c) void {
        self.setDefault("outgoing", drop.getSelected());
    }

    fn setDefault(self: *Page, direction: [:0]const u8, index: c_uint) void {
        if (self.syncing or index > 2) return;
        const names = [_][:0]const u8{ "allow", "deny", "reject" };
        common.elevate.run(self.window, "Change what the firewall does with traffic no rule covers", &.{ "ufw", "default", names[index], direction }, "", Page, onChanged, self);
    }

    fn onRemove(_: *gtk.Button, self: *Page) callconv(.c) void {
        const row = self.list.selectedRow() orelse return;
        if (self.netfilter()) return self.removeNetfilter(row);
        if (self.backend == .ufw) {
            var buf: [16]u8 = undefined;
            const n = std.fmt.bufPrint(&buf, "{d}", .{self.ufw.rules[row].number}) catch return;
            common.elevate.run(self.window, "Remove a firewall rule", &.{ "ufw", "--force", "delete", n }, "", Page, onChanged, self);
        } else {
            const it = self.zone.items[row];
            var arg: [400]u8 = undefined;
            const kind_word: []const u8 = switch (it.kind) {
                .service => "service",
                .port => "port",
                .protocol => "protocol",
                .rich => "rich-rule",
            };
            // A rich rule is removed by its exact text, quoted as one argument.
            const flag = if (it.kind == .rich)
                std.fmt.bufPrint(&arg, "--remove-rich-rule={s}", .{it.name}) catch return
            else
                std.fmt.bufPrint(&arg, "--remove-{s}={s}", .{ kind_word, it.name }) catch return;
            self.zoneChange(flag);
        }
    }

    /// firewalld: change the permanent configuration, then reload so the running firewall has it too.
    fn zoneChange(self: *Page, flag: []const u8) void {
        const a = self.data.allocator();
        const copy = a.dupe(u8, flag) catch return;
        const zone_flag = std.fmt.allocPrint(a, "--zone={s}", .{self.zone.name}) catch return;
        common.elevate.run(self.window, "Change the firewall", &.{ "firewall-cmd", "--permanent", zone_flag, copy }, "", Page, onZoneChanged, self);
    }

    fn onZoneChanged(self: *Page, outcome: common.elevate.Outcome, message: []const u8) void {
        if (outcome == .failed) return self.fail(message);
        if (outcome != .ok) return;
        common.elevate.run(self.window, "Apply the firewall change", &.{ "firewall-cmd", "--reload" }, "", Page, onChanged, self);
    }

    // ---- nftables and iptables ---------------------------------------------------------------

    fn runArgs(self: *Page, reason: []const u8, argv: []const []const u8) void {
        const a = self.data.allocator();
        const owned = a.alloc([]const u8, argv.len) catch return;
        for (argv, 0..) |arg, i| owned[i] = a.dupe(u8, arg) catch return;
        common.elevate.run(self.window, reason, owned, "", Page, onChanged, self);
    }

    fn removeNetfilter(self: *Page, row: usize) void {
        if (row >= self.rows.len) return;
        const r = self.rows[row];
        if (r.managed) return self.fail("This rule belongs to another firewall manager and would be put back.");
        const a = self.data.allocator();
        if (self.backend == .nft) {
            var argv: [8][]const u8 = undefined;
            const n = nft.deleteArgs(a, r, &argv) catch return self.fail("This is not a rule that can be removed.");
            self.runArgs("Remove a firewall rule", argv[0..n]);
        } else {
            var argv: [5][]const u8 = undefined;
            const n = iptables.deleteArgs(a, r, &argv) catch return self.fail("This is not a rule that can be removed.");
            self.runArgs("Remove a firewall rule", argv[0..n]);
        }
    }

    fn setPolicy(self: *Page, accept: bool) void {
        const row = self.list.selectedRow() orelse return;
        if (row >= self.rows.len) return;
        const r = self.rows[row];
        if (self.backend == .nft) {
            var argv: [8][]const u8 = undefined;
            const n = nft.policyArgs(r, accept, &argv) catch return self.fail("Only a base chain has a policy.");
            self.runArgs("Change what a firewall chain does with traffic no rule covers", argv[0..n]);
        } else {
            var argv: [5][]const u8 = undefined;
            const n = iptables.policyArgs(r, accept, &argv) catch return self.fail("Only a built-in chain has a policy.");
            self.runArgs("Change what a firewall chain does with traffic no rule covers", argv[0..n]);
        }
    }

    fn onPolicyAccept(_: *gtk.Button, self: *Page) callconv(.c) void {
        self.setPolicy(true);
    }
    fn onPolicyDrop(_: *gtk.Button, self: *Page) callconv(.c) void {
        self.setPolicy(false);
    }

    fn onSave(_: *gtk.Button, self: *Page) callconv(.c) void {
        const script = if (self.backend == .nft) nft.save_script else iptables.save_script;
        common.elevate.run(self.window, "Save the firewall rules so they are loaded at start-up", &.{ "sh", "-c", script }, "", Page, onSaved, self);
    }

    fn onSaved(self: *Page, outcome: common.elevate.Outcome, message: []const u8) void {
        if (outcome == .failed) return self.fail(message);
        if (outcome == .ok) self.detail.setText(t("Saved. The rules in use now will be loaded at start-up (a copy of the old file was kept the first time, as a .dkde-backup)."));
    }

    /// The add dialog's answer for nftables and iptables.
    fn addNetfilter(self: *Page, d: *Dialog, port_in: []const u8, from: []const u8) void {
        const chain_index = d.chain.getSelected();
        const chains = self.chainRows();
        if (chain_index >= chains.len) return self.fail("Choose a chain.");
        const chain = chains[chain_index];
        const verdict: nft.Verdict = @enumFromInt(@min(d.verdict.getSelected(), 2));
        const proto: nft.Proto = @enumFromInt(@min(d.proto.getSelected(), 2));
        const a = self.data.allocator();
        // Ranges are written with a dash by nft and with a colon by iptables.
        const port = a.dupe(u8, port_in) catch return;
        for (port) |*ch| {
            if (self.backend == .nft and ch.* == ':') ch.* = '-';
            if (self.backend == .iptables and ch.* == '-') ch.* = ':';
        }
        const message: ?[]const u8 = blk: {
            if (self.backend == .nft) {
                var argv: [24][]const u8 = undefined;
                const n = nft.addRuleArgs(a, .{ .family = chain.family, .table = chain.table, .chain = chain.chain, .verdict = verdict, .proto = proto, .port = port, .saddr = from }, &argv) catch |err| break :blk specMessage(err);
                d.window.destroy();
                self.runArgs("Add a firewall rule", argv[0..n]);
            } else {
                var argv: [20][]const u8 = undefined;
                const n = iptables.addRuleArgs(.{ .chain = chain.chain, .verdict = verdict, .proto = proto, .port = port, .saddr = from }, &argv) catch |err| break :blk specMessage(err);
                d.window.destroy();
                self.runArgs("Add a firewall rule", argv[0..n]);
            }
            break :blk null;
        };
        if (message) |m| self.fail(m);
    }

    fn specMessage(err: anyerror) []const u8 {
        return switch (err) {
            error.BadPort => "The port must be a number from 1 to 65535, a list such as 80,443 or a range such as 8000-8100.",
            error.BadAddress => "The address must be an IPv4 or IPv6 address, optionally with /prefix.",
            error.ProtoNeedsPort => "TCP or UDP needs a port. Choose Either to cover all traffic from an address.",
            error.Empty => "Give a port, an address, or both.",
            else => "The rule could not be built from what was entered.",
        };
    }

    /// The chains rules can be added to: not the ones another manager owns.
    fn chainRows(self: *Page) []nft.Row {
        const a = self.data.allocator();
        var list: std.ArrayList(nft.Row) = .empty;
        for (self.rows) |r| if (r.kind == .chain and !r.managed) list.append(a, r) catch break;
        return list.items;
    }

    // ---- adding a rule ---------------------------------------------------------------------

    const Dialog = struct {
        page: *Page,
        window: *gtk.Window,
        action: *gtk.DropDown,
        direction: *gtk.DropDown,
        proto: *gtk.DropDown,
        port: *gtk.Entry,
        from: *gtk.Entry,
        chain: *gtk.DropDown,
        verdict: *gtk.DropDown,
    };

    fn onAdd(_: *gtk.Button, self: *Page) callconv(.c) void {
        const d = heap.create(Dialog) catch return;
        const dialog = gtk.Window.new();
        dialog.setTitle(t("Add a firewall rule"));
        dialog.setTransientFor(self.window);
        dialog.setModal(1);
        common.dialogs.closeOnEscape(dialog);
        dialog.setDefaultSize(420, -1);
        dialog.as(gtk.Widget).addCssClass("dkde");
        const grid = gtk.Grid.new();
        grid.setRowSpacing(10);
        grid.setColumnSpacing(12);
        grid.as(gtk.Widget).setMarginTop(18);
        grid.as(gtk.Widget).setMarginBottom(18);
        grid.as(gtk.Widget).setMarginStart(18);
        grid.as(gtk.Widget).setMarginEnd(18);
        dialog.setChild(grid.as(gtk.Widget));

        d.* = .{
            .page = self,
            .window = dialog,
            .action = gtk.DropDown.newFromStrings(@ptrCast(&[_]?[*:0]const u8{ "Allow", "Block", "Reject", "Rate-limit", null })),
            .direction = gtk.DropDown.newFromStrings(@ptrCast(&[_]?[*:0]const u8{ "Incoming", "Outgoing", null })),
            .proto = gtk.DropDown.newFromStrings(@ptrCast(&[_]?[*:0]const u8{ "TCP", "UDP", "Either", null })),
            .port = gtk.Entry.new(),
            .from = gtk.Entry.new(),
            .chain = gtk.DropDown.newFromStrings(@ptrCast(&[_]?[*:0]const u8{ "input", null })),
            .verdict = gtk.DropDown.newFromStrings(@ptrCast(&[_]?[*:0]const u8{ "Allow", "Drop", "Reject", null })),
        };
        const is_netfilter = self.netfilter();
        if (is_netfilter) {
            // The chains to choose from, by name.
            var labels: std.ArrayList([:0]u8) = .empty;
            defer {
                for (labels.items) |l| gpa_alloc.free(l);
                labels.deinit(gpa_alloc);
            }
            var ptrs: std.ArrayList(?[*:0]const u8) = .empty;
            defer ptrs.deinit(gpa_alloc);
            for (self.chainRows()) |c| {
                const label = std.fmt.allocPrintSentinel(gpa_alloc, "{s} {s} {s}", .{ c.family, c.table, c.chain }, 0) catch continue;
                labels.append(gpa_alloc, label) catch continue;
                ptrs.append(gpa_alloc, label.ptr) catch continue;
            }
            ptrs.append(gpa_alloc, null) catch {};
            const model = gtk.StringList.new(@ptrCast(ptrs.items.ptr));
            d.chain.setModel(model.as(gio.ListModel));
        }
        const is_ufw = self.backend == .ufw or is_netfilter;
        if (!is_ufw) d.proto = gtk.DropDown.newFromStrings(@ptrCast(&[_]?[*:0]const u8{ "TCP", "UDP", null }));
        var row: c_int = 0;
        if (is_netfilter) {
            addRow(grid, &row, t("Chain"), d.chain.as(gtk.Widget));
            addRow(grid, &row, t("What to do"), d.verdict.as(gtk.Widget));
        } else if (is_ufw) {
            addRow(grid, &row, t("What to do"), d.action.as(gtk.Widget));
            addRow(grid, &row, t("Direction"), d.direction.as(gtk.Widget));
        }
        addRow(grid, &row, t("Protocol"), d.proto.as(gtk.Widget));
        d.port.setPlaceholderText(if (is_ufw) t("22, 80,443 or 8000:8100") else t("80 or 8000-8100, or a service name such as ssh"));
        addRow(grid, &row, if (is_ufw) t("Port (empty = any)") else t("Port or service"), d.port.as(gtk.Widget));
        if (is_ufw) {
            d.from.setPlaceholderText(t("An address or network, e.g. 192.168.1.0/24 (empty = anywhere)"));
            addRow(grid, &row, t("From"), d.from.as(gtk.Widget));
        }
        const add = gtk.Button.newWithLabel(t("Add rule"));
        add.as(gtk.Widget).addCssClass("suggested-action");
        add.as(gtk.Widget).setHalign(.end);
        _ = gtk.Button.signals.clicked.connect(add, *Dialog, &onDialogAdd, d, .{});
        grid.attach(add.as(gtk.Widget), 0, row, 2, 1);
        _ = gtk.Widget.signals.destroy.connect(dialog, *Dialog, &onDialogDestroy, d, .{});
        dialog.present();
    }

    const heap = std.heap.c_allocator;
    const gpa_alloc = std.heap.c_allocator;

    fn addRow(grid: *gtk.Grid, row: *c_int, label: [:0]const u8, widget: *gtk.Widget) void {
        const l = gtk.Label.new(label);
        l.setXalign(0);
        grid.attach(l.as(gtk.Widget), 0, row.*, 1, 1);
        widget.setHexpand(1);
        grid.attach(widget, 1, row.*, 1, 1);
        row.* += 1;
    }

    fn onDialogDestroy(_: *gtk.Window, d: *Dialog) callconv(.c) void {
        heap.destroy(d);
    }

    fn onDialogAdd(_: *gtk.Button, d: *Dialog) callconv(.c) void {
        const self = d.page;
        const port = std.mem.trim(u8, std.mem.span(d.port.as(gtk.Editable).getText()), " ");
        const from = std.mem.trim(u8, std.mem.span(d.from.as(gtk.Editable).getText()), " ");
        if (self.netfilter()) return self.addNetfilter(d, port, from);
        if (self.backend == .ufw) {
            const spec: firewall.RuleSpec = .{
                .action = @enumFromInt(@min(d.action.getSelected(), 3)),
                .direction = @enumFromInt(@min(d.direction.getSelected(), 1)),
                .proto = @enumFromInt(@min(d.proto.getSelected(), 2)),
                .port = port,
                .from = from,
            };
            var argv: [16][]const u8 = undefined;
            var buf: [8]u8 = undefined;
            const n = firewall.ufwArgs(spec, &argv, &buf) catch |err| {
                self.fail(switch (err) {
                    error.BadPort => "The port must be a number from 1 to 65535, a list such as 80,443 or a range such as 8000:8100.",
                    error.BadAddress => "The address must be an IPv4 or IPv6 address, optionally with /prefix.",
                    error.NeedsPortOrAddress => "Give a port, an address, or both.",
                    error.ProtoNeedsPort => "TCP or UDP needs a port. Choose Either to cover all traffic from an address.",
                });
                return;
            };
            // The arguments point at the dialog's strings, so copy them before it closes.
            const a = self.data.allocator();
            const owned = a.alloc([]const u8, n) catch return;
            for (argv[0..n], 0..) |arg, i| owned[i] = a.dupe(u8, arg) catch return;
            d.window.destroy();
            common.elevate.run(self.window, "Add a firewall rule", owned, "", Page, onChanged, self);
        } else {
            // A word is a service name; digits (with a range dash) are a port.
            const looks_numeric = port.len > 0 and (port[0] >= '0' and port[0] <= '9');
            var flag: [160]u8 = undefined;
            const text_flag = if (looks_numeric) blk: {
                if (!validDash(port) and !firewall.validPort(port)) return self.fail("The port must be a number or a range such as 8000-8100.");
                break :blk std.fmt.bufPrint(&flag, "--add-port={s}/{s}", .{ port, if (d.proto.getSelected() == 1) "udp" else "tcp" }) catch return;
            } else blk: {
                if (!validServiceName(port)) return self.fail("A service name has letters, digits and dashes only.");
                break :blk std.fmt.bufPrint(&flag, "--add-service={s}", .{port}) catch return;
            };
            d.window.destroy();
            self.zoneChange(text_flag);
        }
    }

    fn validDash(text_in: []const u8) bool {
        const dash = std.mem.indexOfScalar(u8, text_in, '-') orelse return false;
        const a = std.fmt.parseInt(u32, text_in[0..dash], 10) catch return false;
        const b = std.fmt.parseInt(u32, text_in[dash + 1 ..], 10) catch return false;
        return a >= 1 and b <= 65535 and a < b;
    }

    fn validServiceName(name: []const u8) bool {
        if (name.len == 0 or name.len > 40) return false;
        for (name) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_')) return false;
        return true;
    }
};
