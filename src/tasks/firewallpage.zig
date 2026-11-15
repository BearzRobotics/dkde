//! The Firewall page: ufw or firewalld (nftables by hand is shown, not edited). Rules are read as
//! plain sentences and changed through the administrator prompt; firewall.zig parses what the
//! tools print and builds their arguments, so nothing a person types is ever shell text.

const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

const firewall = @import("firewall.zig");
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

pub fn detect() firewall.Backend {
    if (glib.getenv("DKDE_DEBUG_FIREWALL") != null) return .ufw;
    const ufw_active = blk: {
        var contents: [*]u8 = undefined;
        var length: usize = 0;
        if (glib.fileGetContents("/etc/ufw/ufw.conf", &contents, &length, null) == 0) break :blk false;
        defer glib.free(contents);
        break :blk std.mem.indexOf(u8, contents[0..length], "ENABLED=yes") != null;
    };
    return firewall.choose(hasProgram("ufw"), hasProgram("firewall-cmd"), hasProgram("nft"), exists("/run/firewalld"), ufw_active);
}

const ufw_specs = [_]simplelist.ColumnSpec{
    .{ .title = "#", .right = true, .width = 50 },
    .{ .title = "Rule", .expand = true },
    .{ .title = "To", .width = 150 },
    .{ .title = "Action", .width = 110 },
    .{ .title = "From", .width = 160 },
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
            .in_drop = gtk.DropDown.newFromStrings(@ptrCast(&policies)),
            .out_drop = gtk.DropDown.newFromStrings(@ptrCast(&policies)),
            .zone_drop = gtk.DropDown.newFromStrings(@ptrCast(&[_]?[*:0]const u8{ "public", null })),
            .data = .init(gpa),
        };
        self.guard = common.proc.Guard(Page).create(self);
        const is_ufw = backend == .ufw;
        self.list = simplelist.SimpleList.create(gpa, if (is_ufw) &ufw_specs else &zone_specs, .{
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
            else => t("Firewall (nftables)"),
        });
        const switcher = gtk.StackSwitcher.new();
        switcher.setStack(self.stack);
        bar.append(switcher.as(gtk.Widget));
        const load_button = gtk.Button.newWithLabel(t("Load…"));
        load_button.as(gtk.Widget).setTooltipText(t("Read the firewall's rules; needs the administrator password"));
        _ = gtk.Button.signals.clicked.connect(load_button, *Page, &onLoad, self, .{});
        bar.append(load_button.as(gtk.Widget));
        if (backend != .nft) {
            self.power_button.as(gtk.Widget).setSensitive(0);
            _ = gtk.Button.signals.clicked.connect(self.power_button, *Page, &onPower, self, .{});
            bar.append(self.power_button.as(gtk.Widget));
            self.add_button.as(gtk.Widget).setSensitive(0);
            _ = gtk.Button.signals.clicked.connect(self.add_button, *Page, &onAdd, self, .{});
            bar.append(self.add_button.as(gtk.Widget));
            self.remove_button.as(gtk.Widget).setSensitive(0);
            _ = gtk.Button.signals.clicked.connect(self.remove_button, *Page, &onRemove, self, .{});
            bar.append(self.remove_button.as(gtk.Widget));
        }
        root.append(services.scrolled(bar));

        self.status.setXalign(0);
        self.status.setWrap(1);
        self.status.as(gtk.Widget).setMarginStart(12);
        self.status.as(gtk.Widget).setMarginTop(6);
        self.status.setText(t("Choose Load… to read the firewall. Reading it needs the administrator password."));
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
        if (backend != .nft) _ = self.stack.addTitled(self.list.widget, "rules", t("Rules"));
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

    pub fn destroy(self: *Page) void {
        self.guard.kill();
        self.list.destroy();
        for (self.service_names.items) |n| self.gpa.free(n);
        self.service_names.deinit(self.gpa);
        self.data.deinit();
        self.gpa.destroy(self);
    }

    pub fn reload(self: *Page) void {
        if (glib.getenv("DKDE_DEBUG_FIREWALL") != null and self.ufw.rules.len == 0) self.load();
    }

    // ---- reading -------------------------------------------------------------------------

    fn onLoad(_: *gtk.Button, self: *Page) callconv(.c) void {
        self.load();
    }

    /// Dev aid: DKDE_DEBUG_FIREWALL=<folder> reads ufw-numbered.txt and ufw-verbose.txt from there.
    fn loadDebug(self: *Page, dir: []const u8) void {
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
            .nft => {},
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
        return if (self.backend == .ufw) self.ufw.rules.len else self.zone.items.len;
    }

    fn text(owner: *anyopaque, row: usize, col: usize, buf: []u8) []const u8 {
        const self = page(owner);
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
        const r = row orelse return;
        var buf: [320]u8 = undefined;
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
            common.elevate.run(self.window, "Turn the firewall on or off", &.{ "systemctl", if (self.running) "stop" else "start", "firewalld" }, "", Page, onChanged, self);
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

    // ---- adding a rule ---------------------------------------------------------------------

    const Dialog = struct {
        page: *Page,
        window: *gtk.Window,
        action: *gtk.DropDown,
        direction: *gtk.DropDown,
        proto: *gtk.DropDown,
        port: *gtk.Entry,
        from: *gtk.Entry,
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
        };
        const is_ufw = self.backend == .ufw;
        if (!is_ufw) d.proto = gtk.DropDown.newFromStrings(@ptrCast(&[_]?[*:0]const u8{ "TCP", "UDP", null }));
        var row: c_int = 0;
        if (is_ufw) {
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
