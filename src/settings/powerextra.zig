// SPDX-License-Identifier: GPL-2.0-or-later
//! The lid and the power button, which systemd-logind (or elogind) handles, not dkde: a drop-in file in
//! logind.conf.d written with the administrator password (the padlock covers it) and read back by logind
//! when told to reload. Used by the Power & lock page.

const std = @import("std");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

const win = @import("window.zig");
const SettingsWindow = win.SettingsWindow;

const gpa = std.heap.c_allocator;
const t = common.tr;

pub const Action = enum { default, suspend_, hibernate, poweroff, ignore };

const action_words = [_][]const u8{ "", "suspend", "hibernate", "poweroff", "ignore" };

fn actionFromWord(word: []const u8) Action {
    for (action_words, 0..) |w, i| if (i > 0 and std.mem.eql(u8, w, word)) return @enumFromInt(i);
    return .default;
}

pub const Choices = struct { lid_battery: Action = .default, lid_power: Action = .default, power_key: Action = .default };

/// The drop-in's text; empty when every choice is the system default (then the file is removed).
pub fn buildDropIn(allocator: std.mem.Allocator, c: Choices) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    if (c.lid_battery == .default and c.lid_power == .default and c.power_key == .default) return out.toOwnedSlice(allocator);
    try out.appendSlice(allocator, "# Written by dkde Settings > Power & lock.\n[Login]\n");
    const lines = [_]struct { key: []const u8, action: Action }{
        .{ .key = "HandleLidSwitch", .action = c.lid_battery },
        .{ .key = "HandleLidSwitchExternalPower", .action = c.lid_power },
        .{ .key = "HandlePowerKey", .action = c.power_key },
    };
    for (lines) |l| if (l.action != .default) try out.print(allocator, "{s}={s}\n", .{ l.key, action_words[@intFromEnum(l.action)] });
    return out.toOwnedSlice(allocator);
}

pub fn parseDropIn(text: []const u8) Choices {
    var c: Choices = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const action = actionFromWord(std.mem.trim(u8, line[eq + 1 ..], " \t"));
        if (std.mem.eql(u8, key, "HandleLidSwitch")) c.lid_battery = action;
        if (std.mem.eql(u8, key, "HandleLidSwitchExternalPower")) c.lid_power = action;
        if (std.mem.eql(u8, key, "HandlePowerKey")) c.power_key = action;
    }
    return c;
}

test "drop-in round trip" {
    const a = std.testing.allocator;
    const text = try buildDropIn(a, .{ .lid_battery = .suspend_, .power_key = .ignore });
    defer a.free(text);
    const back = parseDropIn(text);
    try std.testing.expectEqual(Action.suspend_, back.lid_battery);
    try std.testing.expectEqual(Action.default, back.lid_power);
    try std.testing.expectEqual(Action.ignore, back.power_key);
    const none = try buildDropIn(a, .{});
    defer a.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

/// Where the drop-in goes: logind's folder, or elogind's. Null when neither is there.
fn dropInDir() ?[:0]const u8 {
    if (glib.fileTest("/run/systemd/seats", .{ .exists = true }) != 0) return "/etc/systemd/logind.conf.d";
    if (glib.fileTest("/etc/elogind", .{ .is_dir = true }) != 0) return "/etc/elogind/logind.conf.d";
    return null;
}

pub const Panel = struct {
    window: *SettingsWindow,
    dir: [:0]const u8,
    lid_battery: *gtk.DropDown,
    lid_power: *gtk.DropDown,
    power_key: *gtk.DropDown,
    status: *gtk.Label,

    const labels = [_]?[*:0]const u8{ "System default", "Sleep", "Hibernate", "Power off", "Do nothing", null };

    pub fn add(window: *SettingsWindow, page: *gtk.Box) void {
        const dir = dropInDir() orelse return;
        const self = gpa.create(Panel) catch return;
        self.* = .{
            .window = window,
            .dir = dir,
            .lid_battery = gtk.DropDown.newFromStrings(@ptrCast(&labels)),
            .lid_power = gtk.DropDown.newFromStrings(@ptrCast(&labels)),
            .power_key = gtk.DropDown.newFromStrings(@ptrCast(&labels)),
            .status = gtk.Label.new(""),
        };
        var path_buf: [200]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&path_buf, "{s}/50-dkde.conf", .{dir}, 0) catch return;
        var contents: [*]u8 = undefined;
        var length: usize = 0;
        if (glib.fileGetContents(path, &contents, &length, null) != 0) {
            defer glib.free(contents);
            const c = parseDropIn(contents[0..length]);
            self.lid_battery.setSelected(@intFromEnum(c.lid_battery));
            self.lid_power.setSelected(@intFromEnum(c.lid_power));
            self.power_key.setSelected(@intFromEnum(c.power_key));
        }
        const heading = gtk.Label.new(t("Lid and power button"));
        heading.setXalign(0);
        heading.as(gtk.Widget).addCssClass("heading");
        page.append(heading.as(gtk.Widget));
        SettingsWindow.addRowDesc(page, t("When the lid is closed, on battery"), t("Handled by the system's login manager, so changing it needs the administrator password."), self.lid_battery.as(gtk.Widget));
        SettingsWindow.addRowDesc(page, t("When the lid is closed, on mains power"), null, self.lid_power.as(gtk.Widget));
        SettingsWindow.addRowDesc(page, t("When the power button is pressed"), null, self.power_key.as(gtk.Widget));
        const apply = gtk.Button.newWithLabel(t("Apply lid and power button settings"));
        _ = gtk.Button.signals.clicked.connect(apply, *Panel, &onApply, self, .{});
        apply.as(gtk.Widget).setHalign(.start);
        page.append(apply.as(gtk.Widget));
        self.status.setXalign(0);
        self.status.setWrap(1);
        self.status.as(gtk.Widget).addCssClass("dim-label");
        page.append(self.status.as(gtk.Widget));
    }

    fn onApply(_: *gtk.Button, self: *Panel) callconv(.c) void {
        const choices: Choices = .{
            .lid_battery = @enumFromInt(self.lid_battery.getSelected()),
            .lid_power = @enumFromInt(self.lid_power.getSelected()),
            .power_key = @enumFromInt(self.power_key.getSelected()),
        };
        const text = buildDropIn(gpa, choices) catch return;
        defer gpa.free(text);
        var script_buf: [600]u8 = undefined;
        // With nothing chosen the file goes; otherwise it is written from stdin. Then logind is told to re-read its settings.
        const script = if (text.len == 0)
            std.fmt.bufPrint(&script_buf, "rm -f {s}/50-dkde.conf; systemctl kill -s HUP systemd-logind.service 2>/dev/null; true", .{self.dir}) catch return
        else
            std.fmt.bufPrint(&script_buf, "mkdir -p {s} && cat > {s}/50-dkde.conf && (systemctl kill -s HUP systemd-logind.service 2>/dev/null; true)", .{ self.dir, self.dir }) catch return;
        common.elevate.run(self.window.window.as(gtk.Window), t("Change what the lid and the power button do."), &.{ "sh", "-c", script }, text, Panel, onDone, self);
    }

    fn onDone(self: *Panel, outcome: common.elevate.Outcome, message: []const u8) void {
        var buf: [300]u8 = undefined;
        switch (outcome) {
            .ok => self.status.setText(t("Saved. The login manager was asked to read it; if a setting does not take effect, sign out or restart.")),
            .cancelled => {},
            .failed => self.status.setText(std.fmt.bufPrintSentinel(&buf, "Could not save: {s}", .{message}, 0) catch "Could not save."),
        }
    }
};
