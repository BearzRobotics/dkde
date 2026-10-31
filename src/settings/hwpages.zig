//! The hardware pages of the Settings app (SPEC.md 5.5): Display, Network,
//! Bluetooth and Printers, plus the device pickers and speaker test on the
//! Sound page. Each page drives a command-line tool (see hardware.zig) and
//! says which package to install when the tool is missing. Pages are built on
//! first visit and refreshed when shown again.

const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

const hw = @import("hardware.zig");
const win = @import("window.zig");
const SettingsWindow = win.SettingsWindow;

const gpa = std.heap.c_allocator;

// ---- shared widgets --------------------------------------------------------------------

fn clear(box: *gtk.Box) void {
    while (box.as(gtk.Widget).getFirstChild()) |child| box.remove(child);
}

fn note(box: *gtk.Box, text: [:0]const u8) *gtk.Label {
    const label = gtk.Label.new(text);
    label.setXalign(0);
    label.setWrap(1);
    label.as(gtk.Widget).addCssClass("dim-label");
    box.append(label.as(gtk.Widget));
    return label;
}

fn missingTool(page: *gtk.Box, text: [:0]const u8) *gtk.Box {
    _ = note(page, text);
    return page;
}

fn Action(comptime Page: type) type {
    return struct {
        page: *Page,
        callback: *const fn (*Page, []const u8, []const u8) void,
        a: []u8,
        b: []u8,
    };
}

/// A button that calls `callback(page, a, b)` with copies of two strings.
fn button(
    comptime Page: type,
    page: *Page,
    label: [:0]const u8,
    callback: *const fn (*Page, []const u8, []const u8) void,
    a: []const u8,
    b: []const u8,
) *gtk.Button {
    const A = Action(Page);
    const Handlers = struct {
        fn clicked(_: *gtk.Button, act: *A) callconv(.c) void {
            act.callback(act.page, act.a, act.b);
        }
        fn destroyed(_: *gtk.Button, act: *A) callconv(.c) void {
            gpa.free(act.a);
            gpa.free(act.b);
            gpa.destroy(act);
        }
    };
    const act = gpa.create(A) catch @panic("OOM");
    act.* = .{ .page = page, .callback = callback, .a = gpa.dupe(u8, a) catch @panic("OOM"), .b = gpa.dupe(u8, b) catch @panic("OOM") };
    const b_widget = gtk.Button.newWithLabel(label);
    _ = gtk.Button.signals.clicked.connect(b_widget, *A, &Handlers.clicked, act, .{});
    _ = gtk.Widget.signals.destroy.connect(b_widget, *A, &Handlers.destroyed, act, .{});
    return b_widget;
}

fn buttonRow(items: []const *gtk.Button) *gtk.Box {
    const box = gtk.Box.new(.horizontal, 6);
    for (items) |b| box.append(b.as(gtk.Widget));
    return box;
}

fn showError(parent: *gtk.Window, heading: [:0]const u8, detail: []const u8) void {
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrintSentinel(&buf, "{s}", .{detail}, 0) catch "";
    common.dialogs.showError(parent, heading, text);
}

const Field = struct { label: [:0]const u8, secret: bool = false };

/// A small modal form with up to three text fields.
fn Form(comptime Page: type) type {
    return struct {
        page: *Page,
        dialog: *gtk.Window,
        entries: [3]*gtk.Editable = undefined,
        count: usize = 0,
        callback: *const fn (*Page, []const []const u8) void,

        const Self = @This();

        fn onOk(_: *gtk.Button, self: *Self) callconv(.c) void {
            var values: [3][]const u8 = undefined;
            for (0..self.count) |i| values[i] = std.mem.span(self.entries[i].getText());
            self.callback(self.page, values[0..self.count]);
            self.dialog.destroy();
        }
        fn onCancel(_: *gtk.Button, self: *Self) callconv(.c) void {
            self.dialog.destroy();
        }
        fn onDestroy(_: *gtk.Window, self: *Self) callconv(.c) void {
            // Passwords sit in the entry's own memory; GTK clears that on destroy.
            gpa.destroy(self);
        }
    };
}

fn openForm(
    comptime Page: type,
    parent: *gtk.Window,
    page: *Page,
    title: [:0]const u8,
    ok_label: [:0]const u8,
    fields: []const Field,
    callback: *const fn (*Page, []const []const u8) void,
) void {
    const F = Form(Page);
    const dialog = gtk.Window.new();
    dialog.setTitle(title);
    dialog.setTransientFor(parent);
    dialog.setModal(1);
    dialog.setDefaultSize(380, -1);
    dialog.as(gtk.Widget).addCssClass("dkde");
    const box = gtk.Box.new(.vertical, 8);
    box.as(gtk.Widget).setMarginTop(16);
    box.as(gtk.Widget).setMarginBottom(16);
    box.as(gtk.Widget).setMarginStart(16);
    box.as(gtk.Widget).setMarginEnd(16);
    dialog.setChild(box.as(gtk.Widget));

    const form = gpa.create(F) catch return;
    form.* = .{ .page = page, .dialog = dialog, .callback = callback };
    for (fields) |f| {
        if (form.count >= form.entries.len) break;
        const label = gtk.Label.new(f.label);
        label.setXalign(0);
        box.append(label.as(gtk.Widget));
        if (f.secret) {
            const e = gtk.PasswordEntry.new();
            e.setShowPeekIcon(1);
            box.append(e.as(gtk.Widget));
            form.entries[form.count] = e.as(gtk.Editable);
        } else {
            const e = gtk.Entry.new();
            box.append(e.as(gtk.Widget));
            form.entries[form.count] = e.as(gtk.Editable);
        }
        form.count += 1;
    }
    const buttons = gtk.Box.new(.horizontal, 8);
    buttons.as(gtk.Widget).setHalign(.end);
    const cancel = gtk.Button.newWithLabel(common.tr("Cancel"));
    const ok = gtk.Button.newWithLabel(ok_label);
    ok.as(gtk.Widget).addCssClass("suggested-action");
    buttons.append(cancel.as(gtk.Widget));
    buttons.append(ok.as(gtk.Widget));
    box.append(buttons.as(gtk.Widget));
    _ = gtk.Button.signals.clicked.connect(cancel, *F, &F.onCancel, form, .{});
    _ = gtk.Button.signals.clicked.connect(ok, *F, &F.onOk, form, .{});
    _ = gtk.Widget.signals.destroy.connect(dialog, *F, &F.onDestroy, form, .{});
    dialog.present();
}

fn dropdownOf(items: []const []const u8) *gtk.DropDown {
    const strings = gtk.StringList.new(null);
    for (items) |item| {
        const z = gpa.dupeSentinel(u8, item, 0) catch continue;
        defer gpa.free(z);
        strings.append(z);
    }
    return gtk.DropDown.new(strings.as(gio.ListModel), null);
}

// ============================================================================================
// Display
// ============================================================================================

pub const DisplayPage = struct {
    window: *SettingsWindow,
    guard: *hw.Guard(DisplayPage) = undefined,
    content: *gtk.Box,
    parsed: ?std.json.Parsed([]hw.Output) = null,
    status: *gtk.Label,
    /// The settings a pending change replaced, so "Revert" can put them back.
    revert_name: ?[]u8 = null,
    revert_mode: ?[]u8 = null,
    revert_scale: f64 = 1,
    revert_left: u32 = 0,
    revert_source: c_uint = 0,
    revert_label: ?*gtk.Label = null,

    const scales = [_]f64{ 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0 };
    const scale_names = [_][]const u8{ "100%", "125%", "150%", "175%", "200%", "250%", "300%" };

    pub fn build(window: *SettingsWindow) *gtk.Box {
        const page = win.SettingsWindow.newPage(common.tr("Display"));
        if (!hw.hasProgram("wlr-randr")) {
            _ = note(page, common.tr("Display settings need the wlr-randr tool. Install the package wlr-randr."));
            return page;
        }
        const self = gpa.create(DisplayPage) catch @panic("OOM");
        self.* = .{ .window = window, .content = gtk.Box.new(.vertical, 12), .status = gtk.Label.new("") };
        self.guard = hw.Guard(DisplayPage).create(self);
        self.status.setXalign(0);
        self.status.as(gtk.Widget).addCssClass("dim-label");
        page.append(self.status.as(gtk.Widget));
        page.append(self.content.as(gtk.Widget));
        _ = gtk.Widget.signals.destroy.connect(page, *DisplayPage, &onDestroy, self, .{});
        _ = gtk.Widget.signals.map.connect(page, *DisplayPage, &onMap, self, .{});
        return page;
    }

    fn onDestroy(_: *gtk.Box, self: *DisplayPage) callconv(.c) void {
        if (self.revert_source != 0) _ = glib.Source.remove(self.revert_source);
        self.guard.kill();
        if (self.parsed) |*p| p.deinit();
        if (self.revert_name) |n| gpa.free(n);
        if (self.revert_mode) |m| gpa.free(m);
        gpa.destroy(self);
    }

    fn onMap(_: *gtk.Box, self: *DisplayPage) callconv(.c) void {
        self.refresh();
    }

    fn refresh(self: *DisplayPage) void {
        hw.run(DisplayPage, self.guard, &.{ "wlr-randr", "--json" }, onList);
    }

    fn onList(self: *DisplayPage, ok: bool, out: []const u8) void {
        clear(self.content);
        if (self.parsed) |*p| p.deinit();
        self.parsed = null;
        if (!ok) {
            _ = note(self.content, common.tr("Could not read the displays. wlr-randr needs a compositor that supports wlr-output-management (labwc does) and a version with --json (0.4 or newer)."));
            return;
        }
        self.parsed = hw.parseOutputs(gpa, out) catch {
            _ = note(self.content, common.tr("wlr-randr gave output this page cannot read."));
            return;
        };
        for (self.parsed.?.value) |output| self.addOutput(output);
    }

    fn modeText(m: hw.Mode) [:0]u8 {
        return std.fmt.allocPrintSentinel(gpa, "{d} \u{00d7} {d} @ {d:.0} Hz{s}", .{ m.width, m.height, m.refresh, if (m.preferred) " (recommended)" else "" }, 0) catch @panic("OOM");
    }

    const Row = struct {
        page: *DisplayPage,
        output: []u8,
        modes: []hw.Mode,
        mode_drop: *gtk.DropDown,
        scale_drop: *gtk.DropDown,
    };

    fn onRowDestroy(_: *gtk.Box, row: *Row) callconv(.c) void {
        gpa.free(row.output);
        gpa.free(row.modes);
        gpa.destroy(row);
    }

    fn addOutput(self: *DisplayPage, output: hw.Output) void {
        const card = gtk.Box.new(.vertical, 8);
        card.as(gtk.Widget).addCssClass("dkde-setting-row");
        var title_buf: [256]u8 = undefined;
        const title = std.fmt.bufPrintSentinel(&title_buf, "{s}{s}{s}", .{ output.name, if (output.description != null) " \u{2014} " else "", output.description orelse "" }, 0) catch "Display";
        const heading = gtk.Label.new(title);
        heading.setXalign(0);
        heading.as(gtk.Widget).addCssClass("heading");
        card.append(heading.as(gtk.Widget));

        const row = gpa.create(Row) catch return;
        row.page = self;
        row.output = gpa.dupe(u8, output.name) catch return;
        row.modes = gpa.dupe(hw.Mode, output.modes) catch return;

        var names: std.ArrayList([]const u8) = .empty;
        defer {
            for (names.items) |n| gpa.free(n);
            names.deinit(gpa);
        }
        var current: u32 = 0;
        for (output.modes, 0..) |m, i| {
            names.append(gpa, modeText(m)) catch return;
            if (m.current) current = @intCast(i);
        }
        row.mode_drop = dropdownOf(names.items);
        row.mode_drop.setSelected(current);
        win.SettingsWindow.addRowDesc(card, common.tr("Resolution and refresh rate"), null, row.mode_drop.as(gtk.Widget));

        row.scale_drop = dropdownOf(&scale_names);
        var best: u32 = 0;
        for (scales, 0..) |s, i| {
            if (@abs(s - output.scale) < @abs(scales[best] - output.scale)) best = @intCast(i);
        }
        row.scale_drop.setSelected(best);
        win.SettingsWindow.addRowDesc(card, common.tr("Scale"), common.tr("Makes text and apps larger or smaller."), row.scale_drop.as(gtk.Widget));

        const apply = gtk.Button.newWithLabel(common.tr("Apply"));
        apply.as(gtk.Widget).addCssClass("suggested-action");
        apply.as(gtk.Widget).setHalign(.end);
        _ = gtk.Button.signals.clicked.connect(apply, *Row, &onApply, row, .{});
        card.append(apply.as(gtk.Widget));
        _ = gtk.Widget.signals.destroy.connect(card, *Row, &onRowDestroyAny, row, .{});
        self.content.append(card.as(gtk.Widget));
    }

    fn onRowDestroyAny(_: *gtk.Box, row: *Row) callconv(.c) void {
        gpa.free(row.output);
        gpa.free(row.modes);
        gpa.destroy(row);
    }

    fn modeArg(buf: []u8, m: hw.Mode) []const u8 {
        return std.fmt.bufPrint(buf, "{d}x{d}@{d:.3}Hz", .{ m.width, m.height, m.refresh }) catch "";
    }

    fn onApply(_: *gtk.Button, row: *Row) callconv(.c) void {
        const self = row.page;
        const index = row.mode_drop.getSelected();
        if (index >= row.modes.len) return;
        const mode = row.modes[index];
        const scale = scales[@min(row.scale_drop.getSelected(), scales.len - 1)];

        // Remember what was there for the "keep changes?" safety net.
        if (self.revert_name) |n| gpa.free(n);
        if (self.revert_mode) |m| gpa.free(m);
        self.revert_name = gpa.dupe(u8, row.output) catch null;
        self.revert_mode = null;
        self.revert_scale = 1;
        if (self.parsed) |p| for (p.value) |o| {
            if (!std.mem.eql(u8, o.name, row.output)) continue;
            if (hw.currentMode(o)) |cur| {
                var buf: [64]u8 = undefined;
                self.revert_mode = gpa.dupe(u8, modeArg(&buf, cur)) catch null;
            }
            self.revert_scale = o.scale;
        };

        var mode_buf: [64]u8 = undefined;
        var scale_buf: [16]u8 = undefined;
        const scale_text = std.fmt.bufPrint(&scale_buf, "{d:.2}", .{scale}) catch return;
        hw.run(DisplayPage, self.guard, &.{ "wlr-randr", "--output", row.output, "--mode", modeArg(&mode_buf, mode), "--scale", scale_text }, onApplied);
    }

    fn onApplied(self: *DisplayPage, ok: bool, _: []const u8) void {
        if (!ok) {
            self.status.setText(common.tr("The display refused that setting."));
            self.refresh();
            return;
        }
        self.refresh();
        self.askKeep();
    }

    /// A changed mode can leave a screen black, so it reverts by itself
    /// unless confirmed, like Windows.
    fn askKeep(self: *DisplayPage) void {
        if (self.revert_source != 0) _ = glib.Source.remove(self.revert_source);
        self.revert_left = 15;
        self.updateCountdown();
        self.revert_source = glib.timeoutAdd(1000, onTick, self);
        const bar = gtk.Box.new(.horizontal, 8);
        bar.as(gtk.Widget).addCssClass("dkde-setting-row");
        const label = gtk.Label.new("");
        label.setXalign(0);
        label.as(gtk.Widget).setHexpand(1);
        self.revert_label = label;
        bar.append(label.as(gtk.Widget));
        const keep = button(DisplayPage, self, common.tr("Keep changes"), onKeep, "", "");
        keep.as(gtk.Widget).addCssClass("suggested-action");
        bar.append(keep.as(gtk.Widget));
        bar.append(button(DisplayPage, self, common.tr("Revert"), onRevert, "", "").as(gtk.Widget));
        self.content.prepend(bar.as(gtk.Widget));
        self.updateCountdown();
    }

    fn updateCountdown(self: *DisplayPage) void {
        const label = self.revert_label orelse return;
        var buf: [96]u8 = undefined;
        const text = std.fmt.bufPrintSentinel(&buf, "Keep these display settings? Reverting in {d} s.", .{self.revert_left}, 0) catch return;
        label.setText(text);
    }

    fn onTick(data: ?*anyopaque) callconv(.c) c_int {
        const self: *DisplayPage = @ptrCast(@alignCast(data.?));
        if (self.revert_left > 0) self.revert_left -= 1;
        if (self.revert_left == 0) {
            self.revert_source = 0;
            self.revert();
            return 0;
        }
        self.updateCountdown();
        return 1;
    }

    fn stopCountdown(self: *DisplayPage) void {
        if (self.revert_source != 0) _ = glib.Source.remove(self.revert_source);
        self.revert_source = 0;
        self.revert_label = null;
    }

    fn onKeep(self: *DisplayPage, _: []const u8, _: []const u8) void {
        self.stopCountdown();
        // Remember the layout so it comes back at the next login.
        hw.run(DisplayPage, self.guard, &.{ "wlr-randr", "--json" }, onSave);
        self.refresh();
    }

    fn onRevert(self: *DisplayPage, _: []const u8, _: []const u8) void {
        self.stopCountdown();
        self.revert();
    }

    fn revert(self: *DisplayPage) void {
        const name = self.revert_name orelse return self.refresh();
        const mode = self.revert_mode orelse return self.refresh();
        var scale_buf: [16]u8 = undefined;
        const scale_text = std.fmt.bufPrint(&scale_buf, "{d:.2}", .{self.revert_scale}) catch return;
        hw.run(DisplayPage, self.guard, &.{ "wlr-randr", "--output", name, "--mode", mode, "--scale", scale_text }, onReverted);
    }

    fn onReverted(self: *DisplayPage, _: bool, _: []const u8) void {
        self.status.setText(common.tr("Reverted to the previous display settings."));
        self.refresh();
    }

    /// Writes `display.sh`, which the labwc autostart runs to restore the layout.
    fn onSave(self: *DisplayPage, ok: bool, out: []const u8) void {
        if (!ok) return;
        var parsed = hw.parseOutputs(gpa, out) catch return;
        defer parsed.deinit();
        var script: std.ArrayList(u8) = .empty;
        defer script.deinit(gpa);
        script.appendSlice(gpa, "#!/bin/sh\n# Written by dkde-settings (Display). The labwc autostart runs this.\n") catch return;
        for (parsed.value) |o| {
            const line = if (!o.enabled)
                std.fmt.allocPrint(gpa, "wlr-randr --output '{s}' --off\n", .{o.name}) catch return
            else blk: {
                const m = hw.currentMode(o) orelse continue;
                break :blk std.fmt.allocPrint(gpa, "wlr-randr --output '{s}' --on --mode {d}x{d}@{d:.3}Hz --scale {d:.2}\n", .{ o.name, m.width, m.height, m.refresh, o.scale }) catch return;
            };
            defer gpa.free(line);
            script.appendSlice(gpa, line) catch return;
        }
        const dir = std.fmt.allocPrintSentinel(gpa, "{s}/dkde", .{std.mem.span(glib.getUserConfigDir())}, 0) catch return;
        defer gpa.free(dir);
        _ = glib.mkdirWithParents(dir, 0o755);
        const path = std.fmt.allocPrintSentinel(gpa, "{s}/display.sh", .{dir}, 0) catch return;
        defer gpa.free(path);
        if (glib.fileSetContents(path, script.items.ptr, @intCast(script.items.len), null) == 0) {
            self.status.setText(common.tr("Could not save the display layout."));
        } else {
            self.status.setText(common.tr("Saved. The layout is restored at login (the labwc autostart runs display.sh)."));
        }
    }
};

// ============================================================================================
// Network
// ============================================================================================

pub const NetworkPage = struct {
    window: *SettingsWindow,
    guard: *hw.Guard(NetworkPage) = undefined,
    content: *gtk.Box,
    status: *gtk.Label,
    wifi_switch: *gtk.Switch,
    /// Set while the page updates the switch itself, so that does not toggle the radio.
    syncing: bool = false,
    arena: std.heap.ArenaAllocator,
    /// The network a password was asked for.
    pending_ssid: ?[]u8 = null,
    pending_secured: bool = false,

    pub fn build(window: *SettingsWindow) *gtk.Box {
        const page = win.SettingsWindow.newPage(common.tr("Network"));
        if (!hw.hasProgram("nmcli")) {
            _ = note(page, common.tr("Network settings need NetworkManager. Install the packages network-manager (provides nmcli) and start its service."));
            return page;
        }
        const self = gpa.create(NetworkPage) catch @panic("OOM");
        self.* = .{
            .window = window,
            .content = gtk.Box.new(.vertical, 8),
            .status = gtk.Label.new(""),
            .wifi_switch = gtk.Switch.new(),
            .arena = std.heap.ArenaAllocator.init(gpa),
        };
        self.guard = hw.Guard(NetworkPage).create(self);
        self.status.setXalign(0);
        self.status.setWrap(1);
        self.status.as(gtk.Widget).addCssClass("dim-label");
        page.append(self.status.as(gtk.Widget));
        _ = gtk.Switch.signals.state_set.connect(self.wifi_switch, *NetworkPage, &onWifiSwitch, self, .{});
        win.SettingsWindow.addRow(page, common.tr("Wi-Fi"), self.wifi_switch.as(gtk.Widget));
        const rescan = button(NetworkPage, self, common.tr("Refresh networks"), onRescan, "", "");
        rescan.as(gtk.Widget).setHalign(.start);
        page.append(rescan.as(gtk.Widget));
        page.append(self.content.as(gtk.Widget));
        _ = gtk.Widget.signals.destroy.connect(page, *NetworkPage, &onDestroy, self, .{});
        _ = gtk.Widget.signals.map.connect(page, *NetworkPage, &onMap, self, .{});
        return page;
    }

    fn onDestroy(_: *gtk.Box, self: *NetworkPage) callconv(.c) void {
        self.guard.kill();
        self.arena.deinit();
        if (self.pending_ssid) |s| gpa.free(s);
        gpa.destroy(self);
    }

    fn onMap(_: *gtk.Box, self: *NetworkPage) callconv(.c) void {
        self.refresh();
    }

    fn onRescan(self: *NetworkPage, _: []const u8, _: []const u8) void {
        hw.run(NetworkPage, self.guard, &.{ "nmcli", "dev", "wifi", "rescan" }, onRescanned);
    }

    fn onRescanned(self: *NetworkPage, _: bool, _: []const u8) void {
        self.refresh();
    }

    fn refresh(self: *NetworkPage) void {
        hw.run(NetworkPage, self.guard, &.{ "nmcli", "-t", "-f", "TYPE,STATE,CONNECTION", "dev" }, onDevices);
        hw.run(NetworkPage, self.guard, &.{ "nmcli", "radio", "wifi" }, onRadio);
        hw.run(NetworkPage, self.guard, &.{ "nmcli", "-t", "-f", "IN-USE,SSID,SIGNAL,SECURITY", "dev", "wifi", "list" }, onWifi);
    }

    fn onDevices(self: *NetworkPage, ok: bool, out: []const u8) void {
        if (!ok) {
            self.status.setText(common.tr("Cannot reach NetworkManager. Is it running?"));
            return;
        }
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(gpa);
        var lines = std.mem.splitScalar(u8, out, '\n');
        while (lines.next()) |line| {
            var scratch: [256]u8 = undefined;
            var f: [3][]const u8 = undefined;
            if (hw.splitTerse(line, &scratch, &f) < 3) continue;
            if (std.mem.eql(u8, f[0], "loopback") or std.mem.eql(u8, f[0], "bridge")) continue;
            const entry = std.fmt.allocPrint(gpa, "{s}: {s}{s}{s}\n", .{ f[0], f[1], if (f[2].len > 0) " \u{2014} " else "", f[2] }) catch return;
            defer gpa.free(entry);
            text.appendSlice(gpa, entry) catch return;
        }
        const z = gpa.dupeSentinel(u8, std.mem.trim(u8, text.items, "\n"), 0) catch return;
        defer gpa.free(z);
        self.status.setText(z);
    }

    fn onRadio(self: *NetworkPage, ok: bool, out: []const u8) void {
        if (!ok) return;
        self.syncing = true;
        self.wifi_switch.setActive(@intFromBool(std.mem.startsWith(u8, std.mem.trim(u8, out, " \n"), "enabled")));
        self.syncing = false;
    }

    fn onWifiSwitch(_: *gtk.Switch, state: c_int, self: *NetworkPage) callconv(.c) c_int {
        if (self.syncing) return 0;
        hw.run(NetworkPage, self.guard, &.{ "nmcli", "radio", "wifi", if (state != 0) "on" else "off" }, onRescanned);
        return 0;
    }

    fn onWifi(self: *NetworkPage, ok: bool, out: []const u8) void {
        clear(self.content);
        _ = self.arena.reset(.retain_capacity);
        if (!ok) return;
        const nets = hw.parseWifi(self.arena.allocator(), out) catch return;
        if (nets.len == 0) _ = note(self.content, common.tr("No Wi-Fi networks found."));
        for (nets) |n| {
            var title_buf: [160]u8 = undefined;
            const title = std.fmt.bufPrintSentinel(&title_buf, "{s}", .{n.ssid}, 0) catch continue;
            var desc_buf: [64]u8 = undefined;
            const desc = std.fmt.bufPrintSentinel(&desc_buf, "Signal {d}%{s}{s}", .{ n.signal, if (n.secured) ", secured" else ", open", if (n.in_use) ", connected" else "" }, 0) catch continue;
            const btn = if (n.in_use)
                button(NetworkPage, self, common.tr("Disconnect"), onDisconnect, n.ssid, "")
            else
                button(NetworkPage, self, common.tr("Connect"), onConnect, n.ssid, if (n.secured) "secured" else "");
            win.SettingsWindow.addRowDesc(self.content, title, desc, btn.as(gtk.Widget));
        }
    }

    fn onDisconnect(self: *NetworkPage, ssid: []const u8, _: []const u8) void {
        hw.run(NetworkPage, self.guard, &.{ "nmcli", "con", "down", "id", ssid }, onRescanned);
    }

    /// Tries a saved profile (or an open network) first; asks for a password
    /// only when that fails on a secured network.
    fn onConnect(self: *NetworkPage, ssid: []const u8, secured: []const u8) void {
        if (self.pending_ssid) |s| gpa.free(s);
        self.pending_ssid = gpa.dupe(u8, ssid) catch return;
        self.pending_secured = secured.len > 0;
        hw.run(NetworkPage, self.guard, &.{ "nmcli", "dev", "wifi", "connect", ssid }, onConnectTried);
    }

    fn onConnectTried(self: *NetworkPage, ok: bool, _: []const u8) void {
        if (ok) return self.refresh();
        if (!self.pending_secured) {
            self.status.setText(common.tr("Could not connect to that network."));
            return;
        }
        openForm(NetworkPage, self.window.window.as(gtk.Window), self, common.tr("Wi-Fi password"), common.tr("Connect"), &.{.{ .label = common.tr("Password"), .secret = true }}, onPassword);
    }

    /// nmcli takes the password as an argument, so it is visible to other
    /// local users in the process list for the moment the command runs.
    fn onPassword(self: *NetworkPage, values: []const []const u8) void {
        const ssid = self.pending_ssid orelse return;
        hw.run(NetworkPage, self.guard, &.{ "nmcli", "dev", "wifi", "connect", ssid, "password", values[0] }, onPasswordTried);
    }

    fn onPasswordTried(self: *NetworkPage, ok: bool, _: []const u8) void {
        if (!ok) self.status.setText(common.tr("Could not connect. Check the password."));
        self.refresh();
    }
};

// ============================================================================================
// Bluetooth
// ============================================================================================

pub const BluetoothPage = struct {
    window: *SettingsWindow,
    guard: *hw.Guard(BluetoothPage) = undefined,
    content: *gtk.Box,
    status: *gtk.Label,
    power_switch: *gtk.Switch,
    syncing: bool = false,
    arena: std.heap.ArenaAllocator,
    all: []hw.BtDevice = &.{},
    paired: []hw.BtDevice = &.{},
    scanning: bool = false,
    /// The three listings arrive separately; the list is drawn when all are in.
    waiting: u8 = 0,
    outputs: [3]?[]u8 = .{ null, null, null },

    pub fn build(window: *SettingsWindow) *gtk.Box {
        const page = win.SettingsWindow.newPage(common.tr("Bluetooth"));
        if (!hw.hasProgram("bluetoothctl")) {
            _ = note(page, common.tr("Bluetooth settings need BlueZ. Install the package bluez (provides bluetoothctl), start bluetoothd and make sure it can reach the system bus."));
            return page;
        }
        const self = gpa.create(BluetoothPage) catch @panic("OOM");
        self.* = .{
            .window = window,
            .content = gtk.Box.new(.vertical, 8),
            .status = gtk.Label.new(""),
            .power_switch = gtk.Switch.new(),
            .arena = std.heap.ArenaAllocator.init(gpa),
        };
        self.guard = hw.Guard(BluetoothPage).create(self);
        self.status.setXalign(0);
        self.status.setWrap(1);
        self.status.as(gtk.Widget).addCssClass("dim-label");
        page.append(self.status.as(gtk.Widget));
        _ = gtk.Switch.signals.state_set.connect(self.power_switch, *BluetoothPage, &onPower, self, .{});
        win.SettingsWindow.addRow(page, common.tr("Bluetooth"), self.power_switch.as(gtk.Widget));
        const scan = button(BluetoothPage, self, common.tr("Scan for devices"), onScan, "", "");
        scan.as(gtk.Widget).setHalign(.start);
        page.append(scan.as(gtk.Widget));
        page.append(self.content.as(gtk.Widget));
        _ = gtk.Widget.signals.destroy.connect(page, *BluetoothPage, &onDestroy, self, .{});
        _ = gtk.Widget.signals.map.connect(page, *BluetoothPage, &onMap, self, .{});
        return page;
    }

    fn onDestroy(_: *gtk.Box, self: *BluetoothPage) callconv(.c) void {
        self.guard.kill();
        self.freeOutputs();
        self.arena.deinit();
        gpa.destroy(self);
    }

    fn freeOutputs(self: *BluetoothPage) void {
        for (&self.outputs) |*o| {
            if (o.*) |text| gpa.free(text);
            o.* = null;
        }
    }

    fn onMap(_: *gtk.Box, self: *BluetoothPage) callconv(.c) void {
        self.refresh();
    }

    fn refresh(self: *BluetoothPage) void {
        self.freeOutputs();
        self.waiting = 4;
        hw.run(BluetoothPage, self.guard, &.{ "bluetoothctl", "show" }, onShow);
        hw.run(BluetoothPage, self.guard, &.{ "bluetoothctl", "devices" }, onAll);
        hw.run(BluetoothPage, self.guard, &.{ "bluetoothctl", "devices", "Paired" }, onPaired);
        hw.run(BluetoothPage, self.guard, &.{ "bluetoothctl", "devices", "Connected" }, onConnected);
    }

    fn keep(self: *BluetoothPage, slot: usize, out: []const u8) void {
        self.outputs[slot] = gpa.dupe(u8, out) catch null;
        self.waiting -= 1;
        if (self.waiting == 0) self.draw();
    }

    fn onShow(self: *BluetoothPage, ok: bool, out: []const u8) void {
        if (!ok) {
            self.status.setText(common.tr("No Bluetooth adapter found, or bluetoothd is not running."));
        } else {
            self.status.setText("");
            self.syncing = true;
            self.power_switch.setActive(@intFromBool(hw.parseBtPowered(out)));
            self.syncing = false;
        }
        self.waiting -= 1;
        if (self.waiting == 0) self.draw();
    }
    fn onAll(self: *BluetoothPage, _: bool, out: []const u8) void {
        self.keep(0, out);
    }
    fn onPaired(self: *BluetoothPage, _: bool, out: []const u8) void {
        self.keep(1, out);
    }
    fn onConnected(self: *BluetoothPage, _: bool, out: []const u8) void {
        self.keep(2, out);
    }

    fn draw(self: *BluetoothPage) void {
        clear(self.content);
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();
        const all = hw.parseBtDevices(a, self.outputs[0] orelse "") catch return;
        const paired = hw.parseBtDevices(a, self.outputs[1] orelse "") catch return;
        const connected = hw.parseBtDevices(a, self.outputs[2] orelse "") catch return;
        if (all.len == 0) _ = note(self.content, common.tr("No devices yet. Put a device in pairing mode and choose Scan for devices."));
        for (all) |d| {
            const name = a.dupeSentinel(u8, d.name, 0) catch continue;
            const is_connected = hw.btContains(connected, d.address);
            const is_paired = hw.btContains(paired, d.address);
            const desc = a.dupeSentinel(u8, if (is_connected) "Connected" else if (is_paired) "Paired" else "Not paired", 0) catch continue;
            const main = if (is_connected)
                button(BluetoothPage, self, common.tr("Disconnect"), onDisconnect, d.address, "")
            else if (is_paired)
                button(BluetoothPage, self, common.tr("Connect"), onConnect, d.address, "")
            else
                button(BluetoothPage, self, common.tr("Pair"), onPair, d.address, "");
            const forget = button(BluetoothPage, self, common.tr("Remove"), onRemove, d.address, "");
            win.SettingsWindow.addRowDesc(self.content, name, desc, buttonRow(&.{ main, forget }).as(gtk.Widget));
        }
    }

    fn onPower(_: *gtk.Switch, state: c_int, self: *BluetoothPage) callconv(.c) c_int {
        if (self.syncing) return 0;
        hw.run(BluetoothPage, self.guard, &.{ "bluetoothctl", "power", if (state != 0) "on" else "off" }, onDone);
        return 0;
    }

    fn onDone(self: *BluetoothPage, _: bool, _: []const u8) void {
        self.refresh();
    }

    fn onScan(self: *BluetoothPage, _: []const u8, _: []const u8) void {
        if (self.scanning) return;
        self.scanning = true;
        self.status.setText(common.tr("Scanning for 10 seconds\u{2026}"));
        hw.run(BluetoothPage, self.guard, &.{ "bluetoothctl", "--timeout", "10", "scan", "on" }, onScanned);
    }

    fn onScanned(self: *BluetoothPage, _: bool, _: []const u8) void {
        self.scanning = false;
        self.status.setText("");
        self.refresh();
    }

    fn onConnect(self: *BluetoothPage, address: []const u8, _: []const u8) void {
        hw.run(BluetoothPage, self.guard, &.{ "bluetoothctl", "connect", address }, onDone);
    }

    fn onDisconnect(self: *BluetoothPage, address: []const u8, _: []const u8) void {
        hw.run(BluetoothPage, self.guard, &.{ "bluetoothctl", "disconnect", address }, onDone);
    }

    fn onRemove(self: *BluetoothPage, address: []const u8, _: []const u8) void {
        hw.run(BluetoothPage, self.guard, &.{ "bluetoothctl", "remove", address }, onDone);
    }

    var last_address: [32]u8 = undefined;
    var last_len: usize = 0;

    /// Pairs, then trusts and connects. A one-shot bluetoothctl has no agent
    /// of its own, so one that needs no input is registered for the call; this
    /// covers headphones, mice and keyboards that do not ask for a PIN.
    fn onPair(self: *BluetoothPage, address: []const u8, _: []const u8) void {
        last_len = @min(address.len, last_address.len);
        @memcpy(last_address[0..last_len], address[0..last_len]);
        self.status.setText(common.tr("Pairing\u{2026}"));
        hw.run(BluetoothPage, self.guard, &.{ "bluetoothctl", "--agent", "NoInputNoOutput", "pair", address }, onPaired2);
    }

    fn onPaired2(self: *BluetoothPage, ok: bool, _: []const u8) void {
        if (!ok) {
            self.status.setText(common.tr("Pairing failed. The device may need a PIN, which this page does not support yet."));
            return self.refresh();
        }
        self.status.setText("");
        const address = last_address[0..last_len];
        hw.run(BluetoothPage, self.guard, &.{ "bluetoothctl", "trust", address }, onTrusted);
    }

    fn onTrusted(self: *BluetoothPage, _: bool, _: []const u8) void {
        hw.run(BluetoothPage, self.guard, &.{ "bluetoothctl", "connect", last_address[0..last_len] }, onDone);
    }
};

// ============================================================================================
// Printers
// ============================================================================================

pub const PrintersPage = struct {
    window: *SettingsWindow,
    guard: *hw.Guard(PrintersPage) = undefined,
    content: *gtk.Box,
    status: *gtk.Label,
    arena: std.heap.ArenaAllocator,
    list_out: ?[]u8 = null,

    pub fn build(window: *SettingsWindow) *gtk.Box {
        const page = win.SettingsWindow.newPage(common.tr("Printers"));
        if (!hw.hasProgram("lpstat")) {
            _ = note(page, common.tr("Printer settings need CUPS. Install the package cups (and cups-client) and start cupsd."));
            return page;
        }
        const self = gpa.create(PrintersPage) catch @panic("OOM");
        self.* = .{
            .window = window,
            .content = gtk.Box.new(.vertical, 8),
            .status = gtk.Label.new(""),
            .arena = std.heap.ArenaAllocator.init(gpa),
        };
        self.guard = hw.Guard(PrintersPage).create(self);
        self.status.setXalign(0);
        self.status.setWrap(1);
        self.status.as(gtk.Widget).addCssClass("dim-label");
        page.append(self.status.as(gtk.Widget));
        const add = button(PrintersPage, self, common.tr("Add a printer\u{2026}"), onAdd, "", "");
        add.as(gtk.Widget).setHalign(.start);
        page.append(add.as(gtk.Widget));
        page.append(self.content.as(gtk.Widget));
        _ = gtk.Widget.signals.destroy.connect(page, *PrintersPage, &onDestroy, self, .{});
        _ = gtk.Widget.signals.map.connect(page, *PrintersPage, &onMap, self, .{});
        return page;
    }

    fn onDestroy(_: *gtk.Box, self: *PrintersPage) callconv(.c) void {
        self.guard.kill();
        if (self.list_out) |o| gpa.free(o);
        self.arena.deinit();
        gpa.destroy(self);
    }

    fn onMap(_: *gtk.Box, self: *PrintersPage) callconv(.c) void {
        self.refresh();
    }

    fn refresh(self: *PrintersPage) void {
        hw.run(PrintersPage, self.guard, &.{ "lpstat", "-p" }, onList);
    }

    fn onList(self: *PrintersPage, ok: bool, out: []const u8) void {
        if (self.list_out) |o| gpa.free(o);
        self.list_out = if (ok) gpa.dupe(u8, out) catch null else null;
        if (!ok and out.len == 0) {
            // lpstat exits non-zero both for "no printers" and "no server".
            self.status.setText(common.tr("No printers are set up, or the CUPS service (cupsd) is not running."));
        } else {
            self.status.setText("");
        }
        hw.run(PrintersPage, self.guard, &.{ "lpstat", "-d" }, onDefault);
    }

    fn onDefault(self: *PrintersPage, _: bool, out: []const u8) void {
        clear(self.content);
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();
        const text = self.list_out orelse return;
        const printers = hw.parsePrinters(a, text) catch return;
        const default_name = hw.parseDefaultPrinter(out);
        for (printers) |p| {
            const is_default = default_name != null and std.mem.eql(u8, default_name.?, p.name);
            const name = a.dupeSentinel(u8, p.name, 0) catch continue;
            const desc = std.fmt.allocPrintSentinel(a, "{s}{s}", .{ p.status, if (is_default) " \u{2014} default" else "" }, 0) catch continue;
            const set_default = button(PrintersPage, self, common.tr("Set as default"), onSetDefault, p.name, "");
            set_default.as(gtk.Widget).setSensitive(@intFromBool(!is_default));
            const test_page = button(PrintersPage, self, common.tr("Print test page"), onTestPage, p.name, "");
            const remove = button(PrintersPage, self, common.tr("Remove"), onRemove, p.name, "");
            win.SettingsWindow.addRowDesc(self.content, name, desc, buttonRow(&.{ set_default, test_page, remove }).as(gtk.Widget));
        }
    }

    fn onSetDefault(self: *PrintersPage, name: []const u8, _: []const u8) void {
        hw.run(PrintersPage, self.guard, &.{ "lpoptions", "-d", name }, onChanged);
    }

    fn onChanged(self: *PrintersPage, _: bool, _: []const u8) void {
        self.refresh();
    }

    const test_text = "dkde printer test page\n\nIf you can read this, the printer works.\n\nABCDEFGHIJKLMNOPQRSTUVWXYZ\nabcdefghijklmnopqrstuvwxyz\n0123456789\n";

    fn onTestPage(self: *PrintersPage, name: []const u8, _: []const u8) void {
        const path = std.fmt.allocPrintSentinel(gpa, "{s}/dkde-test-page.txt", .{std.mem.span(glib.getUserCacheDir())}, 0) catch return;
        defer gpa.free(path);
        _ = glib.mkdirWithParents(std.mem.span(glib.getUserCacheDir()), 0o755);
        if (glib.fileSetContents(path, test_text.ptr, test_text.len, null) == 0) return;
        hw.run(PrintersPage, self.guard, &.{ "lp", "-d", name, path }, onTestSent);
    }

    fn onTestSent(self: *PrintersPage, ok: bool, _: []const u8) void {
        self.status.setText(if (ok) common.tr("Test page sent to the printer.") else common.tr("The test page could not be sent."));
    }

    fn onRemove(self: *PrintersPage, name: []const u8, _: []const u8) void {
        common.elevate.run(self.window.window.as(gtk.Window), common.tr("Remove this printer."), &.{ "lpadmin", "-x", name }, "", PrintersPage, onElevated, self);
    }

    fn onElevated(self: *PrintersPage, outcome: common.elevate.Outcome, message: []const u8) void {
        if (outcome == .failed) showError(self.window.window.as(gtk.Window), common.tr("The printer could not be changed"), message);
        self.refresh();
    }

    fn onAdd(self: *PrintersPage, _: []const u8, _: []const u8) void {
        openForm(PrintersPage, self.window.window.as(gtk.Window), self, common.tr("Add a printer"), common.tr("Add"), &.{
            .{ .label = common.tr("Name (letters, digits and underscores)") },
            .{ .label = common.tr("Address, for example ipp://192.168.1.20/ipp/print") },
        }, onAddValues);
    }

    fn onAddValues(self: *PrintersPage, values: []const []const u8) void {
        if (values.len < 2 or values[0].len == 0 or values[1].len == 0) return;
        for (values[0]) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') {
            showError(self.window.window.as(gtk.Window), common.tr("The printer was not added"), "The name may only contain letters, digits and underscores.");
            return;
        };
        // "everywhere" is driverless IPP, which most network printers speak.
        common.elevate.run(self.window.window.as(gtk.Window), common.tr("Add a printer."), &.{ "lpadmin", "-p", values[0], "-E", "-v", values[1], "-m", "everywhere" }, "", PrintersPage, onElevated, self);
    }
};

// ============================================================================================
// Sound devices and speaker test
// ============================================================================================

pub const SoundDevices = struct {
    window: *SettingsWindow,
    backend: common.audio.Backend,
    sinks: []hw.Node,
    sources: []hw.Node,
    /// Owns the node names the slices above point into.
    text: []u8,
    sink_drop: *gtk.DropDown,
    source_drop: *gtk.DropDown,
    status: *gtk.Label,
    left_wav: ?[:0]u8 = null,
    right_wav: ?[:0]u8 = null,
    both_wav: ?[:0]u8 = null,

    /// Adds the output and input pickers and the speaker test to `page`.
    pub fn add(window: *SettingsWindow, page: *gtk.Box, backend: common.audio.Backend) void {
        const self = gpa.create(SoundDevices) catch return;
        self.* = .{ .window = window, .backend = backend, .sinks = &.{}, .sources = &.{}, .text = &.{}, .sink_drop = undefined, .source_drop = undefined, .status = gtk.Label.new("") };
        self.load();
        self.sink_drop = self.picker(self.sinks);
        self.source_drop = self.picker(self.sources);
        win.SettingsWindow.addRowDesc(page, common.tr("Output device"), common.tr("Where sound plays."), self.sink_drop.as(gtk.Widget));
        win.SettingsWindow.addRowDesc(page, common.tr("Input device"), common.tr("Which microphone is used."), self.source_drop.as(gtk.Widget));
        _ = gobject.Object.signals.notify.connect(self.sink_drop, *SoundDevices, &onSinkPicked, self, .{ .detail = "selected" });
        _ = gobject.Object.signals.notify.connect(self.source_drop, *SoundDevices, &onSourcePicked, self, .{ .detail = "selected" });

        const left = gtk.Button.newWithLabel(common.tr("Left"));
        const right = gtk.Button.newWithLabel(common.tr("Right"));
        const both = gtk.Button.newWithLabel(common.tr("Both"));
        _ = gtk.Button.signals.clicked.connect(left, *SoundDevices, &onTestLeft, self, .{});
        _ = gtk.Button.signals.clicked.connect(right, *SoundDevices, &onTestRight, self, .{});
        _ = gtk.Button.signals.clicked.connect(both, *SoundDevices, &onTestBoth, self, .{});
        win.SettingsWindow.addRowDesc(page, common.tr("Test speakers"), common.tr("Plays a short tone on the selected output."), buttonRow(&.{ left, right, both }).as(gtk.Widget));
        self.status.setXalign(0);
        self.status.as(gtk.Widget).addCssClass("dim-label");
        page.append(self.status.as(gtk.Widget));
        _ = gtk.Widget.signals.destroy.connect(page, *SoundDevices, &onDestroy, self, .{});
    }

    fn onDestroy(_: *gtk.Box, self: *SoundDevices) callconv(.c) void {
        gpa.free(self.sinks);
        gpa.free(self.sources);
        gpa.free(self.text);
        for ([_]?[:0]u8{ self.left_wav, self.right_wav, self.both_wav }) |w| if (w) |path| gpa.free(path);
        gpa.destroy(self);
    }

    fn capture(argv: []const []const u8) ?[]u8 {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(gpa);
        for (argv, 0..) |arg, i| {
            if (i > 0) line.append(gpa, ' ') catch return null;
            line.appendSlice(gpa, arg) catch return null;
        }
        const z = gpa.dupeSentinel(u8, line.items, 0) catch return null;
        defer gpa.free(z);
        var stdout: [*:0]u8 = undefined;
        if (glib.spawnCommandLineSync(z, &stdout, null, null, null) == 0) return null;
        defer glib.free(stdout);
        return gpa.dupe(u8, std.mem.span(stdout)) catch null;
    }

    fn load(self: *SoundDevices) void {
        switch (self.backend) {
            .wpctl => {
                const text = capture(&.{ "wpctl", "status" }) orelse return;
                self.text = text;
                self.sinks = hw.parseWpctlNodes(gpa, text, "Sinks") catch &.{};
                self.sources = hw.parseWpctlNodes(gpa, text, "Sources") catch &.{};
            },
            .pactl => {
                const sinks = capture(&.{ "pactl", "list", "short", "sinks" }) orelse return;
                const sources = capture(&.{ "pactl", "list", "short", "sources" }) orelse "";
                const dsink = capture(&.{ "pactl", "get-default-sink" }) orelse "";
                const dsource = capture(&.{ "pactl", "get-default-source" }) orelse "";
                // One buffer keeps every name alive: sinks, then sources.
                var all: std.ArrayList(u8) = .empty;
                all.appendSlice(gpa, sinks) catch return;
                const split = all.items.len;
                all.appendSlice(gpa, sources) catch return;
                self.text = all.toOwnedSlice(gpa) catch return;
                self.sinks = hw.parsePactlShort(gpa, self.text[0..split], dsink) catch &.{};
                self.sources = hw.parsePactlShort(gpa, self.text[split..], dsource) catch &.{};
            },
        }
    }

    fn picker(self: *SoundDevices, nodes: []const hw.Node) *gtk.DropDown {
        _ = self;
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(gpa);
        for (nodes) |n| names.append(gpa, n.name) catch {};
        if (nodes.len == 0) names.append(gpa, common.tr("(none found)")) catch {};
        const dropdown = dropdownOf(names.items);
        for (nodes, 0..) |n, i| if (n.default) dropdown.setSelected(@intCast(i));
        return dropdown;
    }

    fn setDefault(self: *SoundDevices, node: hw.Node, is_sink: bool) void {
        switch (self.backend) {
            .wpctl => {
                var buf: [16]u8 = undefined;
                const id = std.fmt.bufPrint(&buf, "{d}", .{node.id}) catch return;
                common.appinfo.spawn(gpa, &.{ "wpctl", "set-default", id });
            },
            .pactl => common.appinfo.spawn(gpa, &.{ "pactl", if (is_sink) "set-default-sink" else "set-default-source", node.name }),
        }
    }

    fn onSinkPicked(dd: *gtk.DropDown, _: *gobject.ParamSpec, self: *SoundDevices) callconv(.c) void {
        const i = dd.getSelected();
        if (i < self.sinks.len) self.setDefault(self.sinks[i], true);
    }

    fn onSourcePicked(dd: *gtk.DropDown, _: *gobject.ParamSpec, self: *SoundDevices) callconv(.c) void {
        const i = dd.getSelected();
        if (i < self.sources.len) self.setDefault(self.sources[i], false);
    }

    fn wavPath(self: *SoundDevices, slot: *?[:0]u8, name: []const u8, left: bool, right: bool) ?[:0]const u8 {
        _ = self;
        if (slot.*) |p| return p;
        const cache = std.mem.span(glib.getUserCacheDir());
        const dir = std.fmt.allocPrintSentinel(gpa, "{s}/dkde", .{cache}, 0) catch return null;
        defer gpa.free(dir);
        _ = glib.mkdirWithParents(dir, 0o755);
        const path = std.fmt.allocPrintSentinel(gpa, "{s}/tone-{s}.wav", .{ dir, name }, 0) catch return null;
        const bytes = hw.toneWav(gpa, left, right) catch {
            gpa.free(path);
            return null;
        };
        defer gpa.free(bytes);
        if (glib.fileSetContents(path, bytes.ptr, @intCast(bytes.len), null) == 0) {
            gpa.free(path);
            return null;
        }
        slot.* = path;
        return path;
    }

    fn play(self: *SoundDevices, path: ?[:0]const u8) void {
        const file = path orelse {
            self.status.setText(common.tr("Could not write the test tone."));
            return;
        };
        // PipeWire's player first (it follows the default device), then the
        // PulseAudio one, which also works on WSL.
        const player: []const u8 = if (hw.hasProgram("pw-play") and self.backend == .wpctl) "pw-play" else if (hw.hasProgram("paplay")) "paplay" else if (hw.hasProgram("pw-play")) "pw-play" else {
            self.status.setText(common.tr("No player found. Install pipewire-bin (pw-play) or pulseaudio-utils (paplay)."));
            return;
        };
        self.status.setText("");
        common.appinfo.spawn(gpa, &.{ player, file });
    }

    fn onTestLeft(_: *gtk.Button, self: *SoundDevices) callconv(.c) void {
        self.play(self.wavPath(&self.left_wav, "left", true, false));
    }
    fn onTestRight(_: *gtk.Button, self: *SoundDevices) callconv(.c) void {
        self.play(self.wavPath(&self.right_wav, "right", false, true));
    }
    fn onTestBoth(_: *gtk.Button, self: *SoundDevices) callconv(.c) void {
        self.play(self.wavPath(&self.both_wav, "both", true, true));
    }
};

// ============================================================================================
// Date & time
// ============================================================================================

pub const DateTimePage = struct {
    const Preset = struct { label: [:0]const u8, format: []const u8 };
    const presets = [_]Preset{
        .{ .label = "12-hour, time and date", .format = "%-I:%M %p\n%-m/%-d/%Y" },
        .{ .label = "12-hour, time only", .format = "%-I:%M %p" },
        .{ .label = "24-hour, time and date", .format = "%H:%M\n%Y-%m-%d" },
        .{ .label = "24-hour, time only", .format = "%H:%M" },
        .{ .label = "Weekday, 12-hour time", .format = "%a %-I:%M %p" },
        .{ .label = "Custom", .format = "" },
    };

    const State = struct {
        window: *SettingsWindow,
        dropdown: *gtk.DropDown,
        entry: *gtk.Entry,
        zones: [][]u8,
        zone_text: []u8,
        status: *gtk.Label,
    };

    pub fn build(window: *SettingsWindow) *gtk.Box {
        const page = win.SettingsWindow.newPage(common.tr("Date & time"));
        const st = gpa.create(State) catch @panic("OOM");
        st.* = .{ .window = window, .dropdown = undefined, .entry = undefined, .zones = &.{}, .zone_text = &.{}, .status = gtk.Label.new("") };

        // Clock format: a preset, or any strftime pattern.
        const current = window.panel.getString(gpa, "panel", "clock-format", presets[0].format) catch null;
        defer if (current) |c| gpa.free(c);
        var names: [presets.len][]const u8 = undefined;
        var selected: u32 = presets.len - 1;
        for (presets, 0..) |p, i| {
            names[i] = p.label;
            if (current != null and p.format.len > 0 and std.mem.eql(u8, p.format, current.?)) selected = @intCast(i);
        }
        st.dropdown = dropdownOf(&names);
        st.dropdown.setSelected(selected);
        win.SettingsWindow.addRowDesc(page, common.tr("Clock style"), common.tr("What the taskbar clock shows."), st.dropdown.as(gtk.Widget));
        // The format can hold a line break; the box shows it as \\n and writes the real one.
        st.entry = gtk.Entry.new();
        st.entry.as(gtk.Widget).setHexpand(1);
        const shown = escapeBreaks(gpa, current orelse presets[0].format) catch null;
        defer if (shown) |t| gpa.free(t);
        if (shown) |t| st.entry.as(gtk.Editable).setText(t);
        _ = gtk.Editable.signals.changed.connect(st.entry.as(gtk.Editable), *State, &onFormatEdited, st, .{});
        win.SettingsWindow.addRowDesc(page, common.tr("Custom format"), common.tr("strftime codes, for example %a %d %b %H:%M. Write \\n for a second line."), st.entry.as(gtk.Widget));
        _ = gobject.Object.signals.notify.connect(st.dropdown, *State, &onPreset, st, .{ .detail = "selected" });

        // Time zone.
        loadZones(st);
        if (st.zones.len > 0) {
            const zone_drop = dropdownOf(@ptrCast(st.zones));
            const now = currentZone();
            defer if (now) |n| gpa.free(n);
            if (now) |n| for (st.zones, 0..) |z, i| if (std.mem.eql(u8, z, n)) zone_drop.setSelected(@intCast(i));
            _ = gobject.Object.signals.notify.connect(zone_drop, *State, &onZone, st, .{ .detail = "selected" });
            win.SettingsWindow.addRowDesc(page, common.tr("Time zone"), common.tr("Changing it asks for the administrator password."), zone_drop.as(gtk.Widget));
        }

        const set = gtk.Button.newWithLabel(common.tr("Change\u{2026}"));
        _ = gtk.Button.signals.clicked.connect(set, *State, &onSetTime, st, .{});
        win.SettingsWindow.addRowDesc(page, common.tr("Set date and time"), common.tr("Sets the system clock. Without a time service the clock is not corrected automatically."), set.as(gtk.Widget));

        st.status.setXalign(0);
        st.status.setWrap(1);
        st.status.as(gtk.Widget).addCssClass("dim-label");
        page.append(st.status.as(gtk.Widget));
        _ = gtk.Widget.signals.destroy.connect(page, *State, &onDestroy, st, .{});
        return page;
    }

    fn onDestroy(_: *gtk.Box, st: *State) callconv(.c) void {
        for (st.zones) |z| gpa.free(z);
        gpa.free(st.zones);
        gpa.destroy(st);
    }

    fn onPreset(dd: *gtk.DropDown, _: *gobject.ParamSpec, st: *State) callconv(.c) void {
        const i = dd.getSelected();
        if (i >= presets.len or presets[i].format.len == 0) return;
        const shown = escapeBreaks(gpa, presets[i].format) catch return;
        defer gpa.free(shown);
        st.entry.as(gtk.Editable).setText(shown);
    }

    fn onFormatEdited(entry: *gtk.Editable, st: *State) callconv(.c) void {
        const text = std.mem.span(entry.getText());
        const real = unescapeBreaks(gpa, text) catch return;
        defer gpa.free(real);
        st.window.panel.setString("panel", "clock-format", real) catch {};
    }

    /// A line break as the two characters \\n, for showing in a one-line box.
    fn escapeBreaks(allocator: std.mem.Allocator, text: []const u8) ![:0]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        for (text) |c| {
            if (c == '\n') try out.appendSlice(allocator, "\\n") else try out.append(allocator, c);
        }
        return out.toOwnedSliceSentinel(allocator, 0);
    }

    fn unescapeBreaks(allocator: std.mem.Allocator, text: []const u8) ![:0]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] == '\\' and i + 1 < text.len and text[i + 1] == 'n') {
                try out.append(allocator, '\n');
                i += 1;
            } else try out.append(allocator, text[i]);
        }
        return out.toOwnedSliceSentinel(allocator, 0);
    }

    /// Zone names from the tz database's own index.
    fn loadZones(st: *State) void {
        var contents: [*]u8 = undefined;
        var len: usize = 0;
        if (glib.fileGetContents("/usr/share/zoneinfo/zone1970.tab", &contents, &len, null) == 0) return;
        defer glib.free(contents);
        var list: std.ArrayList([]u8) = .empty;
        var lines = std.mem.splitScalar(u8, contents[0..len], '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            var cols = std.mem.splitScalar(u8, line, '\t');
            _ = cols.next();
            _ = cols.next();
            const zone = cols.next() orelse continue;
            list.append(gpa, gpa.dupe(u8, zone) catch continue) catch continue;
        }
        std.mem.sort([]u8, list.items, {}, struct {
            fn less(_: void, a: []u8, b: []u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.less);
        st.zones = list.toOwnedSlice(gpa) catch &.{};
    }

    fn currentZone() ?[]u8 {
        var contents: [*]u8 = undefined;
        var len: usize = 0;
        if (glib.fileGetContents("/etc/timezone", &contents, &len, null) == 0) return null;
        defer glib.free(contents);
        return gpa.dupe(u8, std.mem.trim(u8, contents[0..len], " \r\n")) catch null;
    }

    fn done(window: *SettingsWindow, outcome: common.elevate.Outcome, message: []const u8) void {
        if (outcome == .failed) showError(window.window.as(gtk.Window), common.tr("The change could not be made"), message);
    }

    fn onZone(dd: *gtk.DropDown, _: *gobject.ParamSpec, st: *State) callconv(.c) void {
        const i = dd.getSelected();
        if (i >= st.zones.len) return;
        // The zone is a positional parameter, never part of the script.
        common.elevate.run(st.window.window.as(gtk.Window), common.tr("Change the time zone."), &.{
            "sh", "-c", "ln -sf \"/usr/share/zoneinfo/$1\" /etc/localtime && echo \"$1\" > /etc/timezone", "sh", st.zones[i],
        }, "", SettingsWindow, done, st.window);
    }

    fn onSetTime(_: *gtk.Button, st: *State) callconv(.c) void {
        openForm(State, st.window.window.as(gtk.Window), st, common.tr("Set date and time"), common.tr("Set"), &.{
            .{ .label = common.tr("Date and time as YYYY-MM-DD HH:MM") },
        }, onTimeValue);
    }

    fn validStamp(text: []const u8) bool {
        if (text.len != 16) return false;
        for (text, 0..) |c, i| switch (i) {
            4, 7 => if (c != '-') return false,
            10 => if (c != ' ') return false,
            13 => if (c != ':') return false,
            else => if (!std.ascii.isDigit(c)) return false,
        };
        return true;
    }

    fn onTimeValue(st: *State, values: []const []const u8) void {
        if (values.len < 1 or !validStamp(values[0])) {
            showError(st.window.window.as(gtk.Window), common.tr("The time was not changed"), "Use the form 2026-10-31 14:30.");
            return;
        }
        common.elevate.run(st.window.window.as(gtk.Window), common.tr("Set the system clock."), &.{
            "sh", "-c", "date -s \"$1\" && { hwclock -w 2>/dev/null || true; }", "sh", values[0],
        }, "", SettingsWindow, done, st.window);
    }
};

test "date stamp check" {
    try std.testing.expect(DateTimePage.validStamp("2026-10-31 14:30"));
    try std.testing.expect(!DateTimePage.validStamp("2026-10-31T14:30"));
    try std.testing.expect(!DateTimePage.validStamp("2026-10-31 14:3x"));
    try std.testing.expect(!DateTimePage.validStamp("now"));
}

// ============================================================================================
// Quick settings (Taskbar page)
// ============================================================================================

pub const QuickRows = struct {
    const names = [_][:0]const u8{ "network", "bluetooth", "airplane", "sound", "brightness", "battery" };
    const labels = [_][:0]const u8{ "Network (Wi-Fi)", "Bluetooth", "Airplane mode", "Sound", "Brightness", "Battery" };

    const State = struct {
        window: *SettingsWindow,
        switches: [names.len]*gtk.Switch = undefined,
        /// Set while the switches are being initialised.
        loading: bool = true,
    };

    /// One switch per quick-settings item, writing `[panel] quick-settings`.
    pub fn add(window: *SettingsWindow, page: *gtk.Box) void {
        const st = gpa.create(State) catch return;
        st.* = .{ .window = window };
        const current = window.panel.getStringList(gpa, "panel", "quick-settings") catch null;
        defer if (current) |list| {
            for (list) |n| gpa.free(n);
            gpa.free(list);
        };
        inline for (names, 0..) |name, i| {
            var on = current == null; // unset means everything
            if (current) |list| for (list) |n| if (std.mem.eql(u8, std.mem.trim(u8, n, " "), name)) {
                on = true;
            };
            const sw = gtk.Switch.new();
            sw.setActive(@intFromBool(on));
            st.switches[i] = sw;
            _ = gtk.Switch.signals.state_set.connect(sw, *State, &onSwitch, st, .{});
            win.SettingsWindow.addRowDesc(page, common.tr(labels[i]), if (i == 0) common.tr("Quick settings icons and the flyout next to the clock") else null, sw.as(gtk.Widget));
        }
        _ = gtk.Widget.signals.destroy.connect(page, *State, &onDestroy, st, .{});
        st.loading = false;
    }

    fn onDestroy(_: *gtk.Box, st: *State) callconv(.c) void {
        gpa.destroy(st);
    }

    fn onSwitch(sw: *gtk.Switch, state: c_int, st: *State) callconv(.c) c_int {
        if (st.loading) return 0;
        var chosen: [names.len][]const u8 = undefined;
        var n: usize = 0;
        for (names, 0..) |name, i| {
            // The switch being changed has not updated its own state yet.
            const on = if (st.switches[i] == sw) state != 0 else st.switches[i].getActive() != 0;
            if (on) {
                chosen[n] = name;
                n += 1;
            }
        }
        st.window.panel.setStringList("panel", "quick-settings", chosen[0..n]) catch {};
        return 0;
    }
};

test "line breaks in the format box" {
    const a = std.testing.allocator;
    const shown = try DateTimePage.escapeBreaks(a, "%-I:%M %p\n%Y");
    defer a.free(shown);
    try std.testing.expectEqualStrings("%-I:%M %p\\n%Y", shown);
    const back = try DateTimePage.unescapeBreaks(a, shown);
    defer a.free(back);
    try std.testing.expectEqualStrings("%-I:%M %p\n%Y", back);
}
