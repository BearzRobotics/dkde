//! The Network page when NetworkManager is running (an optional backend: dkde works without it,
//! see hwpages.NetworkPage). Everything goes through `nmcli`, so there is no D-Bus code here and
//! no password is kept: a Wi-Fi password is handed to NetworkManager, which stores it.
//!
//! One page: the devices, the Wi-Fi radio and the networks in range, and the saved connections
//! (Wi-Fi and wired) with a details form for each: automatic or fixed IPv4 and IPv6 addresses,
//! gateway and DNS servers, and whether to connect automatically.
//!
//! Changing a connection is `nmcli connection modify`; the connection is brought up again so
//! the change takes effect only if it was already connected. Nothing is changed until Save.

const std = @import("std");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gio = @import("gio2");
const gtk = @import("gtk4");
const common = @import("common");

const hw = @import("hardware.zig");
const hp = @import("hwpages.zig");
const win = @import("window.zig");
const np = @import("netparse.zig");
const SettingsWindow = win.SettingsWindow;

const gpa = std.heap.c_allocator;

/// True when NetworkManager is installed and running (asked once, when the page is built; the
/// answer comes back in a few milliseconds).
pub fn available() bool {
    if (!hw.hasProgram("nmcli")) return false;
    var err: ?*glib.Error = null;
    const argv = [_]?[*:0]const u8{ "nmcli", "-t", "-f", "RUNNING", "general", null };
    const proc = gio.Subprocess.newv(@ptrCast(&argv), .{ .stdout_pipe = true, .stderr_silence = true }, &err) orelse {
        if (err) |e| e.free();
        return false;
    };
    defer proc.as(gobject.Object).unref();
    var out: [*:0]u8 = undefined;
    if (proc.communicateUtf8(null, null, &out, null, &err) == 0) {
        if (err) |e| e.free();
        return false;
    }
    defer glib.free(out);
    return std.mem.startsWith(u8, std.mem.span(out), "running");
}

const methods = [_][:0]const u8{ "auto", "manual", "disabled" };
const method_names = [_]?[*:0]const u8{ "Automatic (DHCP)", "Fixed address", "Off", null };

pub const NmPage = struct {
    window: *SettingsWindow,
    guard: *hw.Guard(NmPage) = undefined,
    status: *gtk.Label,
    wifi_switch: *gtk.Switch,
    syncing: bool = false,
    wifi_box: *gtk.Box,
    saved_box: *gtk.Box,
    wifi_arena: std.heap.ArenaAllocator,
    saved_arena: std.heap.ArenaAllocator,
    dev_arena: std.heap.ArenaAllocator,
    /// The Wi-Fi interface (for Disconnect), from the device list.
    wifi_device: ?[]const u8 = null,
    pending_ssid: ?[]u8 = null,
    /// The connection whose details are being fetched or saved.
    edit_uuid: ?[]u8 = null,
    edit_active: bool = false,

    pub fn build(window: *SettingsWindow) *gtk.Box {
        const page = win.SettingsWindow.newPage(common.tr("Network"));
        const self = gpa.create(NmPage) catch @panic("OOM");
        self.* = .{
            .window = window,
            .status = gtk.Label.new(""),
            .wifi_switch = gtk.Switch.new(),
            .wifi_box = gtk.Box.new(.vertical, 8),
            .saved_box = gtk.Box.new(.vertical, 8),
            .wifi_arena = std.heap.ArenaAllocator.init(gpa),
            .saved_arena = std.heap.ArenaAllocator.init(gpa),
            .dev_arena = std.heap.ArenaAllocator.init(gpa),
        };
        self.guard = hw.Guard(NmPage).create(self);
        self.status.setXalign(0);
        self.status.setWrap(1);
        self.status.as(gtk.Widget).addCssClass("dim-label");
        page.append(self.status.as(gtk.Widget));
        _ = gtk.Switch.signals.state_set.connect(self.wifi_switch, *NmPage, &onWifiSwitch, self, .{});
        win.SettingsWindow.addRow(page, common.tr("Wi-Fi"), self.wifi_switch.as(gtk.Widget));
        const rescan = hp.button(NmPage, self, common.tr("Refresh networks"), onRescan, "", "");
        rescan.as(gtk.Widget).setHalign(.start);
        page.append(rescan.as(gtk.Widget));
        page.append(heading(common.tr("Wi-Fi networks")).as(gtk.Widget));
        page.append(self.wifi_box.as(gtk.Widget));
        page.append(heading(common.tr("Saved connections")).as(gtk.Widget));
        const hint = gtk.Label.new(common.tr("Edit a connection to give it a fixed address, gateway or DNS servers. Forget removes it, with its saved password."));
        hint.setXalign(0);
        hint.setWrap(1);
        hint.as(gtk.Widget).addCssClass("dim-label");
        page.append(hint.as(gtk.Widget));
        page.append(self.saved_box.as(gtk.Widget));
        _ = gtk.Widget.signals.destroy.connect(page, *NmPage, &onDestroy, self, .{});
        _ = gtk.Widget.signals.map.connect(page, *NmPage, &onMap, self, .{});
        return page;
    }

    fn heading(text: [:0]const u8) *gtk.Label {
        const l = gtk.Label.new(text);
        l.setXalign(0);
        l.as(gtk.Widget).addCssClass("title-4");
        l.as(gtk.Widget).setMarginTop(14);
        return l;
    }

    fn onDestroy(_: *gtk.Box, self: *NmPage) callconv(.c) void {
        self.guard.kill();
        self.wifi_arena.deinit();
        self.saved_arena.deinit();
        self.dev_arena.deinit();
        if (self.pending_ssid) |s| gpa.free(s);
        if (self.edit_uuid) |s| gpa.free(s);
        gpa.destroy(self);
    }

    fn onMap(_: *gtk.Box, self: *NmPage) callconv(.c) void {
        self.refresh();
    }

    fn say(self: *NmPage, text: []const u8) void {
        var buf: [400]u8 = undefined;
        self.status.setText(std.fmt.bufPrintSentinel(&buf, "{s}", .{text}, 0) catch "");
    }

    fn refresh(self: *NmPage) void {
        hw.run(NmPage, self.guard, &.{ "nmcli", "-t", "-f", "DEVICE,TYPE,STATE,CONNECTION", "device", "status" }, onDevices);
        hw.run(NmPage, self.guard, &.{ "nmcli", "radio", "wifi" }, onRadio);
        hw.run(NmPage, self.guard, &.{ "nmcli", "-t", "-f", "IN-USE,SSID,SIGNAL,SECURITY", "device", "wifi", "list", "--rescan", "no" }, onWifi);
        hw.run(NmPage, self.guard, &.{ "nmcli", "-t", "-f", "NAME,UUID,TYPE,DEVICE", "connection", "show" }, onSaved);
    }

    fn onRescan(self: *NmPage, _: []const u8, _: []const u8) void {
        hw.run(NmPage, self.guard, &.{ "nmcli", "device", "wifi", "rescan" }, onChanged);
    }

    /// After any command that changes something: look again.
    fn onChanged(self: *NmPage, ok: bool, _: []const u8) void {
        if (!ok) self.say(common.tr("NetworkManager refused that (it may need permission, or the device is busy)."));
        self.refresh();
    }

    fn onDevices(self: *NmPage, ok: bool, out: []const u8) void {
        if (!ok) return self.say(common.tr("Cannot reach NetworkManager."));
        _ = self.dev_arena.reset(.retain_capacity);
        const a = self.dev_arena.allocator();
        const devs = np.parseDevices(a, out) catch return;
        self.wifi_device = null;
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(gpa);
        for (devs) |d| {
            if (std.mem.eql(u8, d.kind, "wifi") and self.wifi_device == null) self.wifi_device = d.name;
            text.print(gpa, "{s} ({s}): {s}{s}{s}\n", .{ d.name, np.kindName(d.kind), d.state, if (d.connection.len > 0) " \u{2014} " else "", d.connection }) catch return;
        }
        self.say(std.mem.trim(u8, text.items, "\n"));
    }

    fn onRadio(self: *NmPage, ok: bool, out: []const u8) void {
        if (!ok) return;
        self.syncing = true;
        self.wifi_switch.setActive(@intFromBool(std.mem.startsWith(u8, std.mem.trim(u8, out, " \n"), "enabled")));
        self.syncing = false;
    }

    fn onWifiSwitch(_: *gtk.Switch, state: c_int, self: *NmPage) callconv(.c) c_int {
        if (self.syncing) return 0;
        hw.run(NmPage, self.guard, &.{ "nmcli", "radio", "wifi", if (state != 0) "on" else "off" }, onChanged);
        return 0;
    }

    // ---- Wi-Fi networks --------------------------------------------------------------------

    fn onWifi(self: *NmPage, ok: bool, out: []const u8) void {
        hp.clear(self.wifi_box);
        _ = self.wifi_arena.reset(.retain_capacity);
        if (!ok) return;
        const nets = np.parseWifi(self.wifi_arena.allocator(), out) catch return;
        if (nets.len == 0) _ = hp.note(self.wifi_box, common.tr("No Wi-Fi networks found."));
        for (nets) |n| {
            var title_buf: [160]u8 = undefined;
            const title = std.fmt.bufPrintSentinel(&title_buf, "{s}", .{n.ssid}, 0) catch continue;
            var desc_buf: [64]u8 = undefined;
            const secured = np.isSecured(n.security);
            const desc = std.fmt.bufPrintSentinel(&desc_buf, "Signal {d}%{s}{s}", .{ n.signal, if (secured) ", secured" else ", open", if (n.in_use) ", connected" else "" }, 0) catch continue;
            const btn = if (n.in_use)
                hp.button(NmPage, self, common.tr("Disconnect"), onDisconnect, n.ssid, "")
            else
                hp.button(NmPage, self, common.tr("Connect"), onConnect, n.ssid, if (secured) "secured" else "");
            win.SettingsWindow.addRowDesc(self.wifi_box, title, desc, btn.as(gtk.Widget));
        }
    }

    fn onDisconnect(self: *NmPage, _: []const u8, _: []const u8) void {
        const dev = self.wifi_device orelse return;
        hw.run(NmPage, self.guard, &.{ "nmcli", "device", "disconnect", dev }, onChanged);
    }

    /// A saved profile (or an open network) is tried first; the password is asked for only when
    /// that fails on a secured network.
    fn onConnect(self: *NmPage, ssid: []const u8, secured: []const u8) void {
        if (self.pending_ssid) |s| gpa.free(s);
        self.pending_ssid = gpa.dupe(u8, ssid) catch return;
        self.say(common.tr("Connecting\u{2026}"));
        hw.run(NmPage, self.guard, &.{ "nmcli", "device", "wifi", "connect", ssid }, if (secured.len > 0) onTriedSecured else onTriedOpen);
    }

    fn onTriedOpen(self: *NmPage, ok: bool, _: []const u8) void {
        if (!ok) self.say(common.tr("Could not connect to that network."));
        self.refresh();
    }

    fn onTriedSecured(self: *NmPage, ok: bool, _: []const u8) void {
        if (ok) return self.refresh();
        hp.openForm(NmPage, self.window.window.as(gtk.Window), self, common.tr("Wi-Fi password"), common.tr("Connect"), &.{.{ .label = common.tr("Password"), .secret = true }}, onPassword);
    }

    /// nmcli takes the password as an argument, so other local users could see it in the process
    /// list for the moment the command runs; NetworkManager then stores it itself.
    fn onPassword(self: *NmPage, values: []const []const u8) void {
        const ssid = self.pending_ssid orelse return;
        self.say(common.tr("Connecting\u{2026}"));
        hw.run(NmPage, self.guard, &.{ "nmcli", "device", "wifi", "connect", ssid, "password", values[0] }, onPasswordTried);
    }

    fn onPasswordTried(self: *NmPage, ok: bool, _: []const u8) void {
        if (!ok) self.say(common.tr("Could not connect. Check the password."));
        self.refresh();
    }

    // ---- saved connections -----------------------------------------------------------------

    fn onSaved(self: *NmPage, ok: bool, out: []const u8) void {
        hp.clear(self.saved_box);
        _ = self.saved_arena.reset(.retain_capacity);
        if (!ok) return;
        const conns = np.parseConnections(self.saved_arena.allocator(), out) catch return;
        if (conns.len == 0) _ = hp.note(self.saved_box, common.tr("No saved connections."));
        for (conns) |c| {
            var title_buf: [200]u8 = undefined;
            const title = std.fmt.bufPrintSentinel(&title_buf, "{s}", .{c.name}, 0) catch continue;
            var desc_buf: [96]u8 = undefined;
            const desc = std.fmt.bufPrintSentinel(&desc_buf, "{s}{s}{s}", .{ np.kindName(c.kind), if (c.device.len > 0) " \u{00b7} connected on " else " \u{00b7} not connected", c.device }, 0) catch continue;
            const edit = hp.button(NmPage, self, common.tr("Edit\u{2026}"), onEdit, c.uuid, if (c.device.len > 0) "active" else "");
            const toggle = if (c.device.len > 0)
                hp.button(NmPage, self, common.tr("Disconnect"), onDown, c.uuid, "")
            else
                hp.button(NmPage, self, common.tr("Connect"), onUp, c.uuid, "");
            const forget = hp.button(NmPage, self, common.tr("Forget"), onForget, c.uuid, c.name);
            forget.as(gtk.Widget).addCssClass("destructive-action");
            win.SettingsWindow.addRowDesc(self.saved_box, title, desc, hp.buttonRow(&.{ edit, toggle, forget }).as(gtk.Widget));
        }
    }

    fn onUp(self: *NmPage, uuid: []const u8, _: []const u8) void {
        self.say(common.tr("Connecting\u{2026}"));
        hw.run(NmPage, self.guard, &.{ "nmcli", "connection", "up", uuid }, onChanged);
    }

    fn onDown(self: *NmPage, uuid: []const u8, _: []const u8) void {
        hw.run(NmPage, self.guard, &.{ "nmcli", "connection", "down", uuid }, onChanged);
    }

    fn onForget(self: *NmPage, uuid: []const u8, name: []const u8) void {
        const Ask = struct {
            page: *NmPage,
            guard: *hw.Guard(NmPage),
            uuid: [:0]u8,
            fn answered(ask: *@This(), index: c_int) void {
                defer gpa.destroy(ask);
                defer gpa.free(ask.uuid);
                if (index != 1 or ask.guard.dead) return;
                hw.run(NmPage, ask.guard, &.{ "nmcli", "connection", "delete", ask.uuid }, onChanged);
            }
        };
        const ask = gpa.create(Ask) catch return;
        ask.* = .{ .page = self, .guard = self.guard, .uuid = gpa.dupeSentinel(u8, uuid, 0) catch {
            gpa.destroy(ask);
            return;
        } };
        const name_z = gpa.dupeSentinel(u8, name, 0) catch return;
        defer gpa.free(name_z);
        common.dialogs.choose(self.window.window.as(gtk.Window), common.tr("Forget this connection?"), name_z, &.{ "Cancel", "Forget" }, 0, Ask, Ask.answered, ask);
    }

    // ---- the details form ------------------------------------------------------------------

    fn onEdit(self: *NmPage, uuid: []const u8, active: []const u8) void {
        if (self.edit_uuid) |s| gpa.free(s);
        self.edit_uuid = gpa.dupe(u8, uuid) catch return;
        self.edit_active = active.len > 0;
        hw.run(NmPage, self.guard, &.{ "nmcli", "-t", "-f", "connection.id,connection.autoconnect,ipv4.method,ipv4.addresses,ipv4.gateway,ipv4.dns,ipv6.method,ipv6.addresses,ipv6.gateway,ipv6.dns", "connection", "show", uuid }, onSettings);
    }

    fn onSettings(self: *NmPage, ok: bool, out: []const u8) void {
        if (!ok) return self.say(common.tr("Could not read that connection."));
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const s = np.parseSettings(arena.allocator(), out) catch return;
        EditForm.open(self, s);
    }

    const EditForm = struct {
        page: *NmPage,
        guard: *hw.Guard(NmPage),
        dialog: *gtk.Window,
        autoconnect: *gtk.Switch,
        method: [2]*gtk.DropDown,
        address: [2]*gtk.Entry,
        gateway: [2]*gtk.Entry,
        dns: [2]*gtk.Entry,
        message: *gtk.Label,

        fn open(page: *NmPage, s: np.Settings) void {
            const self = gpa.create(EditForm) catch return;
            const dialog = gtk.Window.new();
            var title_buf: [200]u8 = undefined;
            dialog.setTitle(std.fmt.bufPrintSentinel(&title_buf, "{s}", .{if (s.name.len > 0) s.name else "Connection"}, 0) catch "Connection");
            dialog.setTransientFor(page.window.window.as(gtk.Window));
            dialog.setModal(1);
            dialog.setDefaultSize(440, -1);
            dialog.as(gtk.Widget).addCssClass("dkde");
            const box = gtk.Box.new(.vertical, 8);
            for ([_]*const fn (*gtk.Widget, c_int) callconv(.c) void{ gtk.Widget.setMarginTop, gtk.Widget.setMarginBottom, gtk.Widget.setMarginStart, gtk.Widget.setMarginEnd }) |f| f(box.as(gtk.Widget), 16);
            dialog.setChild(box.as(gtk.Widget));
            self.* = .{
                .page = page,
                .guard = page.guard,
                .dialog = dialog,
                .autoconnect = gtk.Switch.new(),
                .method = .{ gtk.DropDown.newFromStrings(@ptrCast(&method_names)), gtk.DropDown.newFromStrings(@ptrCast(&method_names)) },
                .address = .{ gtk.Entry.new(), gtk.Entry.new() },
                .gateway = .{ gtk.Entry.new(), gtk.Entry.new() },
                .dns = .{ gtk.Entry.new(), gtk.Entry.new() },
                .message = gtk.Label.new(""),
            };
            self.autoconnect.setActive(@intFromBool(s.autoconnect));
            const ac_row = gtk.Box.new(.horizontal, 12);
            const ac_label = gtk.Label.new(common.tr("Connect automatically"));
            ac_label.as(gtk.Widget).setHexpand(1);
            ac_label.setXalign(0);
            ac_row.append(ac_label.as(gtk.Widget));
            ac_row.append(self.autoconnect.as(gtk.Widget));
            box.append(ac_row.as(gtk.Widget));

            const fams = [2]struct { title: [:0]const u8, ip: np.Ip, example: [:0]const u8 }{
                .{ .title = common.tr("IPv4"), .ip = s.v4, .example = "192.168.1.20/24" },
                .{ .title = common.tr("IPv6"), .ip = s.v6, .example = "fd00::20/64" },
            };
            for (fams, 0..) |fam, i| {
                const h = gtk.Label.new(fam.title);
                h.setXalign(0);
                h.as(gtk.Widget).addCssClass("title-4");
                h.as(gtk.Widget).setMarginTop(8);
                box.append(h.as(gtk.Widget));
                var sel: u32 = 0;
                for (methods, 0..) |m, mi| if (std.mem.eql(u8, m, fam.ip.method) or (mi == 2 and (std.mem.eql(u8, fam.ip.method, "ignore")))) {
                    sel = @intCast(mi);
                };
                self.method[i].setSelected(sel);
                box.append(self.method[i].as(gtk.Widget));
                self.address[i].setPlaceholderText(fam.example);
                self.address[i].as(gtk.Editable).setText(std.fmt.bufPrintSentinel(&title_buf, "{s}", .{fam.ip.address}, 0) catch "");
                box.append(labelled(common.tr("Address with prefix (fixed address only)"), self.address[i].as(gtk.Widget)).as(gtk.Widget));
                self.gateway[i].as(gtk.Editable).setText(std.fmt.bufPrintSentinel(&title_buf, "{s}", .{fam.ip.gateway}, 0) catch "");
                box.append(labelled(common.tr("Gateway (fixed address only)"), self.gateway[i].as(gtk.Widget)).as(gtk.Widget));
                self.dns[i].setPlaceholderText(if (i == 0) "1.1.1.1 9.9.9.9" else "2606:4700:4700::1111");
                self.dns[i].as(gtk.Editable).setText(std.fmt.bufPrintSentinel(&title_buf, "{s}", .{fam.ip.dns}, 0) catch "");
                box.append(labelled(common.tr("DNS servers, separated by spaces (leave empty to use the network's)"), self.dns[i].as(gtk.Widget)).as(gtk.Widget));
            }
            self.message.setXalign(0);
            self.message.setWrap(1);
            self.message.as(gtk.Widget).addCssClass("error");
            box.append(self.message.as(gtk.Widget));
            const buttons = gtk.Box.new(.horizontal, 8);
            buttons.as(gtk.Widget).setHalign(.end);
            const cancel = gtk.Button.newWithLabel(common.tr("Cancel"));
            const save = gtk.Button.newWithLabel(common.tr("Save"));
            save.as(gtk.Widget).addCssClass("suggested-action");
            buttons.append(cancel.as(gtk.Widget));
            buttons.append(save.as(gtk.Widget));
            box.append(buttons.as(gtk.Widget));
            _ = gtk.Button.signals.clicked.connect(cancel, *EditForm, &onCancel, self, .{});
            _ = gtk.Button.signals.clicked.connect(save, *EditForm, &onSave, self, .{});
            _ = gtk.Widget.signals.destroy.connect(dialog, *EditForm, &onFormDestroy, self, .{});
            dialog.present();
        }

        fn labelled(text: [:0]const u8, w: *gtk.Widget) *gtk.Box {
            const b = gtk.Box.new(.vertical, 2);
            const l = gtk.Label.new(text);
            l.setXalign(0);
            l.as(gtk.Widget).addCssClass("dim-label");
            b.append(l.as(gtk.Widget));
            b.append(w);
            return b;
        }

        fn onCancel(_: *gtk.Button, self: *EditForm) callconv(.c) void {
            self.dialog.destroy();
        }

        fn onFormDestroy(_: *gtk.Window, self: *EditForm) callconv(.c) void {
            gpa.destroy(self);
        }

        fn ipOf(self: *EditForm, i: usize) np.Ip {
            const sel = self.method[i].getSelected();
            return .{
                .method = methods[@min(sel, methods.len - 1)],
                .address = std.mem.trim(u8, std.mem.span(self.address[i].as(gtk.Editable).getText()), " "),
                .gateway = std.mem.trim(u8, std.mem.span(self.gateway[i].as(gtk.Editable).getText()), " "),
                .dns = std.mem.trim(u8, std.mem.span(self.dns[i].as(gtk.Editable).getText()), " "),
            };
        }

        fn onSave(_: *gtk.Button, self: *EditForm) callconv(.c) void {
            const v4 = self.ipOf(0);
            const v6 = self.ipOf(1);
            np.checkIp(v4, false) catch |e| return self.fail("IPv4: ", e);
            np.checkIp(v6, true) catch |e| return self.fail("IPv6: ", e);
            const page = self.page;
            const uuid = page.edit_uuid orelse return;
            // One argument list, every value its own argument (never joined into a shell line).
            var args: std.ArrayList([]const u8) = .empty;
            defer args.deinit(gpa);
            var owned: std.ArrayList([]u8) = .empty;
            defer {
                for (owned.items) |o| gpa.free(o);
                owned.deinit(gpa);
            }
            args.appendSlice(gpa, &.{ "nmcli", "connection", "modify", uuid, "connection.autoconnect", if (self.autoconnect.getActive() != 0) "yes" else "no" }) catch return;
            const keys = [2][]const u8{ "ipv4", "ipv6" };
            const ips = [2]np.Ip{ v4, v6 };
            for (keys, ips) |k, ip| {
                const manual = std.mem.eql(u8, ip.method, "manual");
                const dns_clean = gpa.dupe(u8, ip.dns) catch return;
                owned.append(gpa, dns_clean) catch return;
                for (dns_clean) |*c| if (c.* == ',') {
                    c.* = ' ';
                };
                for ([_][]const u8{ "method", ip.method, "addresses", if (manual) ip.address else "", "gateway", if (manual) ip.gateway else "", "dns", dns_clean, "ignore-auto-dns", if (dns_clean.len > 0) "yes" else "no" }, 0..) |part, n| {
                    if (n % 2 == 0) {
                        const key = std.fmt.allocPrint(gpa, "{s}.{s}", .{ k, part }) catch return;
                        owned.append(gpa, key) catch return;
                        args.append(gpa, key) catch return;
                    } else args.append(gpa, part) catch return;
                }
            }
            page.say(common.tr("Saving\u{2026}"));
            hw.run(NmPage, self.guard, args.items, onModified);
            self.dialog.destroy();
        }

        fn fail(self: *EditForm, prefix: []const u8, e: np.CheckError) void {
            var buf: [300]u8 = undefined;
            self.message.setText(std.fmt.bufPrintSentinel(&buf, "{s}{s}", .{ prefix, np.describeCheck(e) }, 0) catch "");
        }
    };

    fn onModified(self: *NmPage, ok: bool, _: []const u8) void {
        if (!ok) {
            self.say(common.tr("NetworkManager did not accept those settings."));
            return self.refresh();
        }
        // Already connected: reconnect so the change applies now.
        if (self.edit_active) if (self.edit_uuid) |u| {
            self.say(common.tr("Saved. Reconnecting\u{2026}"));
            return hw.run(NmPage, self.guard, &.{ "nmcli", "connection", "up", u }, onChanged);
        };
        self.say(common.tr("Saved."));
        self.refresh();
    }
};
