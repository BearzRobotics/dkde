//! Quick settings (SPEC.md 5.1): status icons in the bar for network, sound,
//! battery and airplane mode, and a flyout with the controls: Wi-Fi,
//! Bluetooth and Airplane mode toggles, volume and brightness sliders, and
//! the battery level. `[panel] quick-settings` lists which are shown.
//!
//! Everything goes through small tools or sysfs and is optional: a control
//! whose tool or hardware is missing (no battery, no `nmcli`, no backlight)
//! simply does not appear. See also hardware.zig in the Settings app.

const std = @import("std");
const gdk = @import("gdk4");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");

const common = @import("common");
const proc = common.proc;
const audio = common.audio;
const Osd = @import("osd.zig").Osd;

pub const Kind = enum { network, bluetooth, airplane, sound, brightness, battery };
pub const kinds = std.enums.values(Kind);

pub fn kindName(kind: Kind) []const u8 {
    return @tagName(kind);
}

// ---- parsers (pure) ------------------------------------------------------------------

pub const Net = struct { wifi: bool = false, wired: bool = false };

/// `nmcli -t -f TYPE,STATE dev`: "wifi:connected", "ethernet:unavailable", ...
pub fn parseNet(text: []const u8) Net {
    var net: Net = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const state = std.mem.trim(u8, line[colon + 1 ..], " \r");
        if (!std.mem.eql(u8, state, "connected")) continue;
        const kind = line[0..colon];
        if (std.mem.eql(u8, kind, "wifi")) net.wifi = true;
        if (std.mem.eql(u8, kind, "ethernet")) net.wired = true;
    }
    return net;
}

/// `rfkill list`: true when every radio is soft-blocked, false when any is
/// on, null when there are no radios at all.
pub fn parseRfkill(text: []const u8) ?bool {
    var seen = false;
    var all_blocked = true;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const key = "Soft blocked:";
        if (!std.mem.startsWith(u8, line, key)) continue;
        seen = true;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[key.len..], " "), "yes")) all_blocked = false;
    }
    return if (seen) all_blocked else null;
}

pub const Battery = struct { percent: u32, charging: bool };

pub fn parseBattery(capacity: []const u8, status: []const u8) ?Battery {
    const percent = std.fmt.parseInt(u32, std.mem.trim(u8, capacity, " \r\n"), 10) catch return null;
    return .{ .percent = @min(percent, 100), .charging = std.mem.eql(u8, std.mem.trim(u8, status, " \r\n"), "Charging") };
}

pub fn batteryIcon(buf: []u8, b: Battery) []const u8 {
    const level = (b.percent + 5) / 10 * 10;
    return std.fmt.bufPrint(buf, "battery-level-{d}{s}-symbolic", .{ @min(level, 100), if (b.charging) "-charging" else "" }) catch "battery-symbolic";
}

pub fn volumeIcon(state: audio.State) [:0]const u8 {
    if (state.muted or state.volume_percent == 0) return "audio-volume-muted-symbolic";
    if (state.volume_percent < 34) return "audio-volume-low-symbolic";
    if (state.volume_percent < 67) return "audio-volume-medium-symbolic";
    return "audio-volume-high-symbolic";
}

pub fn brightnessPercent(current: u32, max: u32) u32 {
    if (max == 0) return 0;
    return @min(100, (current * 100 + max / 2) / max);
}

test "network state" {
    const n = parseNet("ethernet:connected\nwifi:disconnected\nloopback:unmanaged\n");
    try std.testing.expect(n.wired and !n.wifi);
    try std.testing.expect(parseNet("wifi:connected\n").wifi);
    try std.testing.expect(!parseNet("").wifi);
}

test "rfkill" {
    try std.testing.expectEqual(@as(?bool, true), parseRfkill("0: phy0: Wireless LAN\n\tSoft blocked: yes\n\tHard blocked: no\n1: hci0: Bluetooth\n\tSoft blocked: yes\n"));
    try std.testing.expectEqual(@as(?bool, false), parseRfkill("0: phy0: Wireless LAN\n\tSoft blocked: yes\n1: hci0: Bluetooth\n\tSoft blocked: no\n"));
    try std.testing.expectEqual(@as(?bool, null), parseRfkill(""));
}

test "battery" {
    const b = parseBattery("78\n", "Charging\n").?;
    try std.testing.expectEqual(@as(u32, 78), b.percent);
    try std.testing.expect(b.charging);
    var buf: [48]u8 = undefined;
    try std.testing.expectEqualStrings("battery-level-80-charging-symbolic", batteryIcon(&buf, b));
    try std.testing.expectEqualStrings("battery-level-100-symbolic", batteryIcon(&buf, .{ .percent = 99, .charging = false }));
    try std.testing.expectEqualStrings("battery-level-0-symbolic", batteryIcon(&buf, .{ .percent = 3, .charging = false }));
    try std.testing.expect(parseBattery("x", "Full") == null);
}

test "sound icon and brightness" {
    try std.testing.expectEqualStrings("audio-volume-muted-symbolic", volumeIcon(.{ .volume_percent = 50, .muted = true }));
    try std.testing.expectEqualStrings("audio-volume-high-symbolic", volumeIcon(.{ .volume_percent = 90, .muted = false }));
    try std.testing.expectEqual(@as(u32, 50), brightnessPercent(128, 255));
    try std.testing.expectEqual(@as(u32, 0), brightnessPercent(5, 0));
}

// ---- sysfs ----------------------------------------------------------------------------

fn readSmall(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    const z = allocator.dupeSentinel(u8, path, 0) catch return null;
    defer allocator.free(z);
    var contents: [*]u8 = undefined;
    var len: usize = 0;
    if (glib.fileGetContents(z, &contents, &len, null) == 0) return null;
    defer glib.free(contents);
    return allocator.dupe(u8, contents[0..len]) catch null;
}

/// Where sysfs is mounted; tests point this at a fake tree.
fn sysfsRoot() []const u8 {
    return if (glib.getenv("DKDE_SYSFS_ROOT")) |r| std.mem.span(r) else "/sys";
}

/// The first `BAT*` supply that reports a level.
fn readBattery(allocator: std.mem.Allocator) ?Battery {
    var n: u8 = 0;
    while (n < 4) : (n += 1) {
        var capacity_path: [192]u8 = undefined;
        var status_path: [192]u8 = undefined;
        const cap = readSmall(allocator, std.fmt.bufPrint(&capacity_path, "{s}/class/power_supply/BAT{d}/capacity", .{ sysfsRoot(), n }) catch continue) orelse continue;
        defer allocator.free(cap);
        const status = readSmall(allocator, std.fmt.bufPrint(&status_path, "{s}/class/power_supply/BAT{d}/status", .{ sysfsRoot(), n }) catch continue) orelse "";
        defer if (status.len > 0) allocator.free(status);
        return parseBattery(cap, status);
    }
    return null;
}

extern fn g_dir_read_name(dir: *glib.Dir) ?[*:0]const u8;

fn readDirName(dir: *glib.Dir) ?[*:0]const u8 {
    return g_dir_read_name(dir);
}

const Backlight = struct { dir: []u8, percent: u32 };

fn readBacklight(allocator: std.mem.Allocator) ?Backlight {
    const base = std.fmt.allocPrintSentinel(allocator, "{s}/class/backlight", .{sysfsRoot()}, 0) catch return null;
    defer allocator.free(base);
    const dir_z = glib.Dir.open(base, 0, null) orelse return null;
    defer dir_z.close();
    while (readDirName(dir_z)) |name| {
        const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, std.mem.span(name) }) catch return null;
        const cur_path = std.fmt.allocPrint(allocator, "{s}/brightness", .{path}) catch return null;
        defer allocator.free(cur_path);
        const max_path = std.fmt.allocPrint(allocator, "{s}/max_brightness", .{path}) catch return null;
        defer allocator.free(max_path);
        const cur = readSmall(allocator, cur_path) orelse {
            allocator.free(path);
            continue;
        };
        defer allocator.free(cur);
        const max = readSmall(allocator, max_path) orelse {
            allocator.free(path);
            continue;
        };
        defer allocator.free(max);
        const c = std.fmt.parseInt(u32, std.mem.trim(u8, cur, " \r\n"), 10) catch {
            allocator.free(path);
            continue;
        };
        const m = std.fmt.parseInt(u32, std.mem.trim(u8, max, " \r\n"), 10) catch {
            allocator.free(path);
            continue;
        };
        return .{ .dir = path, .percent = brightnessPercent(c, m) };
    }
    return null;
}

// ---- the bar icons and shared state ------------------------------------------------------

const BarIcons = struct {
    box: *gtk.Box,
    network: *gtk.Image,
    sound: *gtk.Image,
    battery: *gtk.Image,
    airplane: *gtk.Image,
};

pub const Quick = struct {
    allocator: std.mem.Allocator,
    config: *const common.Config,
    guard: *proc.Guard(Quick) = undefined,
    enabled: [kinds.len]bool = @splat(true),
    bars: std.ArrayList(*BarIcons) = .empty,
    poll_source: c_uint = 0,

    net: Net = .{},
    airplane: ?bool = null,
    volume: ?audio.State = null,
    battery: ?Battery = null,
    backend: ?audio.Backend = null,
    /// Partial pactl answer while its two commands are in flight.
    pactl_volume: ?u32 = null,
    /// Shows level changes made with the keyboard; null where there is no layer-shell.
    osd: ?*Osd = null,

    pub fn create(allocator: std.mem.Allocator, config: *const common.Config) *Quick {
        const self = allocator.create(Quick) catch @panic("OOM");
        self.* = .{ .allocator = allocator, .config = config };
        self.guard = proc.Guard(Quick).create(self);
        self.reload();
        self.poll_source = glib.timeoutAdd(20_000, onPoll, self);
        return self;
    }

    pub fn destroy(self: *Quick) void {
        if (self.poll_source != 0) _ = glib.Source.remove(self.poll_source);
        self.guard.kill();
        for (self.bars.items) |bar| self.allocator.destroy(bar);
        self.bars.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn isEnabled(self: *const Quick, kind: Kind) bool {
        return self.enabled[@backingInt(kind)];
    }

    /// Reads `[panel] quick-settings` (default: all) and redraws the bars.
    pub fn reload(self: *Quick) void {
        self.enabled = @splat(false);
        const list = self.config.getStringList(self.allocator, "panel", "quick-settings") catch null;
        if (list) |names| {
            defer {
                for (names) |n| self.allocator.free(n);
                self.allocator.free(names);
            }
            for (names) |name| for (kinds) |k| {
                if (std.mem.eql(u8, std.mem.trim(u8, name, " "), kindName(k))) self.enabled[@backingInt(k)] = true;
            };
        } else self.enabled = @splat(true);
        self.poll();
        for (self.bars.items) |bar| self.updateBar(bar);
    }

    // ---- polling ------------------------------------------------------------------------

    fn onPoll(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Quick = @ptrCast(@alignCast(data.?));
        self.poll();
        return 1;
    }

    pub fn poll(self: *Quick) void {
        self.battery = if (self.isEnabled(.battery)) readBattery(self.allocator) else null;
        if (self.isEnabled(.network) and proc.hasProgram("nmcli")) {
            proc.run(Quick, self.guard, &.{ "nmcli", "-t", "-f", "TYPE,STATE", "dev" }, onNet);
        }
        if (self.isEnabled(.airplane) and proc.hasProgram("rfkill")) {
            proc.run(Quick, self.guard, &.{ "rfkill", "list" }, onRfkill);
        }
        if (self.isEnabled(.sound)) self.fetchSound();
        for (self.bars.items) |bar| self.updateBar(bar);
    }

    fn onNet(self: *Quick, ok: bool, out: []const u8) void {
        if (ok) self.net = parseNet(out);
        for (self.bars.items) |bar| self.updateBar(bar);
    }

    fn onRfkill(self: *Quick, ok: bool, out: []const u8) void {
        if (ok) self.airplane = parseRfkill(out);
        for (self.bars.items) |bar| self.updateBar(bar);
    }

    fn soundBackend() ?audio.Backend {
        if (proc.hasProgram("wpctl")) return .wpctl;
        if (proc.hasProgram("pactl")) return .pactl;
        return null;
    }

    fn setSink(self: *Quick, backend: audio.Backend, percent: u32, muted: ?bool) void {
        var arg_buf: [16]u8 = undefined;
        const arg = audio.volumeArg(&arg_buf, backend, percent);
        switch (backend) {
            .wpctl => common.appinfo.spawn(self.allocator, &.{ "wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", arg }),
            .pactl => common.appinfo.spawn(self.allocator, &.{ "pactl", "set-sink-volume", "@DEFAULT_SINK@", arg }),
        }
        if (muted) |m| {
            const flag: []const u8 = if (m) "1" else "0";
            switch (backend) {
                .wpctl => common.appinfo.spawn(self.allocator, &.{ "wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", flag }),
                .pactl => common.appinfo.spawn(self.allocator, &.{ "pactl", "set-sink-mute", "@DEFAULT_SINK@", flag }),
            }
        }
    }

    /// The volume keys: change the default output by `delta` percent points.
    pub fn nudgeVolume(self: *Quick, delta: i32) void {
        const backend = soundBackend() orelse return;
        self.backend = backend;
        const cur = self.volume orelse audio.State{ .volume_percent = 50, .muted = false };
        const next: u32 = @intCast(std.math.clamp(@as(i32, @intCast(cur.volume_percent)) + delta, 0, 100));
        // Raising the volume of a muted output unmutes it, as on other desktops.
        const unmute: ?bool = if (delta > 0 and cur.muted) false else null;
        self.setSink(backend, next, unmute);
        self.volume = .{ .volume_percent = next, .muted = if (unmute != null) false else cur.muted };
        for (self.bars.items) |bar| self.updateBar(bar);
        if (self.osd) |o| {
            var buf: [8]u8 = undefined;
            o.show(volumeIcon(self.volume.?), @as(f64, @floatFromInt(next)) / 100.0, std.fmt.bufPrint(&buf, "{d}%", .{next}) catch "");
        }
    }

    pub fn toggleMute(self: *Quick) void {
        const backend = soundBackend() orelse return;
        self.backend = backend;
        const cur = self.volume orelse audio.State{ .volume_percent = 50, .muted = false };
        const muted = !cur.muted;
        self.setSink(backend, cur.volume_percent, muted);
        self.volume = .{ .volume_percent = cur.volume_percent, .muted = muted };
        for (self.bars.items) |bar| self.updateBar(bar);
        if (self.osd) |o| o.show(volumeIcon(self.volume.?), if (muted) 0 else @as(f64, @floatFromInt(cur.volume_percent)) / 100.0, if (muted) "Muted" else "On");
    }

    /// The brightness keys; does nothing on a machine with no backlight.
    pub fn nudgeBrightness(self: *Quick, delta: i32) void {
        const light = readBacklight(self.allocator) orelse return;
        defer self.allocator.free(light.dir);
        const next: u32 = @intCast(std.math.clamp(@as(i32, @intCast(light.percent)) + delta, 1, 100));
        if (!setBacklight(self.allocator, light.dir, next)) return;
        if (self.osd) |o| {
            var buf: [8]u8 = undefined;
            o.show("display-brightness-symbolic", @as(f64, @floatFromInt(next)) / 100.0, std.fmt.bufPrint(&buf, "{d}%", .{next}) catch "");
        }
    }

    pub fn fetchSound(self: *Quick) void {
        if (proc.hasProgram("wpctl")) {
            self.backend = .wpctl;
            proc.run(Quick, self.guard, &.{ "wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@" }, onWpctl);
        } else if (proc.hasProgram("pactl")) {
            self.backend = .pactl;
            self.pactl_volume = null;
            proc.run(Quick, self.guard, &.{ "pactl", "get-sink-volume", "@DEFAULT_SINK@" }, onPactlVolume);
        }
    }

    fn onWpctl(self: *Quick, ok: bool, out: []const u8) void {
        if (ok) self.volume = audio.parseWpctl(out);
        for (self.bars.items) |bar| self.updateBar(bar);
    }

    fn onPactlVolume(self: *Quick, ok: bool, out: []const u8) void {
        if (!ok) return;
        self.pactl_volume = audio.parsePactlVolume(out);
        proc.run(Quick, self.guard, &.{ "pactl", "get-sink-mute", "@DEFAULT_SINK@" }, onPactlMute);
    }

    fn onPactlMute(self: *Quick, ok: bool, out: []const u8) void {
        if (!ok) return;
        if (self.pactl_volume) |v| self.volume = .{ .volume_percent = v, .muted = audio.parsePactlMute(out) orelse false };
        for (self.bars.items) |bar| self.updateBar(bar);
    }

    // ---- the bar -------------------------------------------------------------------------

    /// Adds this bar's quick-settings button to `box`.
    pub fn addBox(self: *Quick, box: *gtk.Box) void {
        const icons = self.allocator.create(BarIcons) catch return;
        const holder = gtk.Box.new(.horizontal, 8);
        icons.* = .{
            .box = box,
            .network = gtk.Image.new(),
            .sound = gtk.Image.new(),
            .battery = gtk.Image.new(),
            .airplane = gtk.Image.new(),
        };
        for ([_]*gtk.Image{ icons.airplane, icons.network, icons.sound, icons.battery }) |image| {
            image.setPixelSize(16);
            holder.append(image.as(gtk.Widget));
        }
        const button = gtk.Button.new();
        button.as(gtk.Widget).addCssClass("dkde-quick-button");
        button.setChild(holder.as(gtk.Widget));
        button.setHasFrame(0);
        _ = gtk.Button.signals.clicked.connect(button, *Quick, &onButton, self, .{});
        box.append(button.as(gtk.Widget));
        self.bars.append(self.allocator, icons) catch {};
        self.updateBar(icons);
    }

    pub fn removeBox(self: *Quick, box: *gtk.Box) void {
        for (self.bars.items, 0..) |bar, i| {
            if (bar.box == box) {
                self.allocator.destroy(bar);
                _ = self.bars.orderedRemove(i);
                return;
            }
        }
    }

    fn updateBar(self: *Quick, bar: *BarIcons) void {
        var buf: [48]u8 = undefined;

        // Network: wired wins over Wi-Fi in the icon; hidden when the widget is off.
        const net_on = self.isEnabled(.network) and proc.hasProgram("nmcli");
        bar.network.as(gtk.Widget).setVisible(@intFromBool(net_on));
        bar.network.setFromIconName(if (self.net.wired) "network-wired-symbolic" else if (self.net.wifi) "network-wireless-symbolic" else "network-offline-symbolic");

        const sound_on = self.isEnabled(.sound) and self.volume != null;
        bar.sound.as(gtk.Widget).setVisible(@intFromBool(sound_on));
        if (self.volume) |v| bar.sound.setFromIconName(@ptrCast(volumeIconZ(&buf, v)));

        const battery_on = self.isEnabled(.battery) and self.battery != null;
        bar.battery.as(gtk.Widget).setVisible(@intFromBool(battery_on));
        if (self.battery) |b| {
            const name = batteryIcon(buf[0..47], b);
            buf[name.len] = 0;
            bar.battery.setFromIconName(@ptrCast(buf[0..name.len :0]));
        }

        // Airplane mode only shows while it is on.
        const air_on = self.isEnabled(.airplane) and (self.airplane orelse false);
        bar.airplane.as(gtk.Widget).setVisible(@intFromBool(air_on));
        bar.airplane.setFromIconName("airplane-mode-symbolic");

        // With nothing to show there is no button at all.
        const any = net_on or sound_on or battery_on or air_on;
        if (bar.box.as(gtk.Widget).getFirstChild()) |button| button.setVisible(@intFromBool(any or self.anyFlyoutControl()));
    }

    fn volumeIconZ(buf: []u8, v: audio.State) [:0]const u8 {
        const name = volumeIcon(v);
        @memcpy(buf[0..name.len], name);
        buf[name.len] = 0;
        return buf[0..name.len :0];
    }

    fn anyFlyoutControl(self: *const Quick) bool {
        for (kinds) |k| if (self.isEnabled(k)) return true;
        return false;
    }

    // ---- the flyout -------------------------------------------------------------------------

    fn onButton(button: *gtk.Button, self: *Quick) callconv(.c) void {
        Flyout.open(self, button.as(gtk.Widget));
    }

    /// Dev aid for screenshots: open the flyout of the first bar by itself.
    pub fn debugOpen(self: *Quick) void {
        const bar = if (self.bars.items.len > 0) self.bars.items[0] else return;
        if (bar.box.as(gtk.Widget).getFirstChild()) |button| Flyout.open(self, button);
    }
};

const Flyout = struct {
    quick: *Quick,
    guard: *proc.Guard(Flyout) = undefined,
    popover: *gtk.Popover,
    wifi: ?*gtk.ToggleButton = null,
    bluetooth: ?*gtk.ToggleButton = null,
    airplane: ?*gtk.ToggleButton = null,
    volume: ?*gtk.Scale = null,
    mute: ?*gtk.ToggleButton = null,
    brightness: ?*gtk.Scale = null,
    battery: *gtk.Label,
    status: *gtk.Label,
    syncing: bool = false,
    backlight_dir: ?[]u8 = null,
    volume_source: c_uint = 0,
    brightness_source: c_uint = 0,

    fn open(quick: *Quick, parent: *gtk.Widget) void {
        const a = quick.allocator;
        const self = a.create(Flyout) catch return;
        const popover = gtk.Popover.new();
        popover.as(gtk.Widget).addCssClass("dkde-quick-flyout");
        popover.as(gtk.Widget).setParent(parent);
        self.* = .{ .quick = quick, .popover = popover, .battery = gtk.Label.new(""), .status = gtk.Label.new("") };
        self.guard = proc.Guard(Flyout).create(self);

        const box = gtk.Box.new(.vertical, 10);
        box.as(gtk.Widget).setMarginTop(12);
        box.as(gtk.Widget).setMarginBottom(12);
        box.as(gtk.Widget).setMarginStart(12);
        box.as(gtk.Widget).setMarginEnd(12);
        box.as(gtk.Widget).setSizeRequest(320, -1);
        popover.setChild(box.as(gtk.Widget));

        // Toggles in one row.
        const tiles = gtk.Box.new(.horizontal, 8);
        tiles.setHomogeneous(1);
        if (quick.isEnabled(.network) and proc.hasProgram("nmcli")) self.wifi = self.tile(tiles, "network-wireless-symbolic", common.tr("Wi-Fi"), onWifi);
        if (quick.isEnabled(.bluetooth) and proc.hasProgram("bluetoothctl")) self.bluetooth = self.tile(tiles, "bluetooth-symbolic", common.tr("Bluetooth"), onBluetooth);
        if (quick.isEnabled(.airplane) and proc.hasProgram("rfkill")) self.airplane = self.tile(tiles, "airplane-mode-symbolic", common.tr("Airplane mode"), onAirplane);
        if (tiles.as(gtk.Widget).getFirstChild() != null) box.append(tiles.as(gtk.Widget));

        if (quick.isEnabled(.sound) and quick.volume != null) {
            const row = gtk.Box.new(.horizontal, 8);
            const mute = gtk.ToggleButton.new();
            mute.as(gtk.Button).setIconName("audio-volume-high-symbolic");
            mute.as(gtk.Button).setHasFrame(0);
            _ = gtk.ToggleButton.signals.toggled.connect(mute, *Flyout, &onMute, self, .{});
            const scale = gtk.Scale.newWithRange(.horizontal, 0, 100, 1);
            scale.as(gtk.Widget).setHexpand(1);
            _ = gtk.Range.signals.value_changed.connect(scale.as(gtk.Range), *Flyout, &onVolume, self, .{});
            row.append(mute.as(gtk.Widget));
            row.append(scale.as(gtk.Widget));
            box.append(row.as(gtk.Widget));
            self.mute = mute;
            self.volume = scale;
        }

        if (quick.isEnabled(.brightness)) {
            if (readBacklight(a)) |light| {
                self.backlight_dir = light.dir;
                const row = gtk.Box.new(.horizontal, 8);
                const icon = gtk.Image.newFromIconName("display-brightness-symbolic");
                const scale = gtk.Scale.newWithRange(.horizontal, 1, 100, 1);
                scale.as(gtk.Widget).setHexpand(1);
                scale.as(gtk.Range).setValue(@floatFromInt(light.percent));
                _ = gtk.Range.signals.value_changed.connect(scale.as(gtk.Range), *Flyout, &onBrightness, self, .{});
                row.append(icon.as(gtk.Widget));
                row.append(scale.as(gtk.Widget));
                box.append(row.as(gtk.Widget));
                self.brightness = scale;
            }
        }

        if (quick.isEnabled(.battery) and quick.battery != null) {
            self.battery.setXalign(0);
            box.append(self.battery.as(gtk.Widget));
        }
        self.status.setXalign(0);
        self.status.setWrap(1);
        self.status.as(gtk.Widget).addCssClass("dim-label");
        box.append(self.status.as(gtk.Widget));

        const more = gtk.Button.newWithLabel(common.tr("All settings"));
        more.as(gtk.Widget).setHalign(.end);
        _ = gtk.Button.signals.clicked.connect(more, *Flyout, &onMore, self, .{});
        box.append(more.as(gtk.Widget));

        _ = gtk.Popover.signals.closed.connect(popover, *Flyout, &onClosed, self, .{});
        self.refresh();
        popover.popup();
    }

    fn tile(self: *Flyout, row: *gtk.Box, icon: [:0]const u8, label: [:0]const u8, comptime handler: fn (*gtk.ToggleButton, *Flyout) callconv(.c) void) *gtk.ToggleButton {
        const content = gtk.Box.new(.vertical, 4);
        content.append(gtk.Image.newFromIconName(icon).as(gtk.Widget));
        const text = gtk.Label.new(label);
        text.setWrap(1);
        text.setJustify(.center);
        content.append(text.as(gtk.Widget));
        const button = gtk.ToggleButton.new();
        button.as(gtk.Button).setChild(content.as(gtk.Widget));
        button.as(gtk.Widget).addCssClass("dkde-quick-tile");
        _ = gtk.ToggleButton.signals.toggled.connect(button, *Flyout, &handler, self, .{});
        row.append(button.as(gtk.Widget));
        return button;
    }

    /// The popover is thrown away when it closes; its state goes with it.
    fn onClosed(_: *gtk.Popover, self: *Flyout) callconv(.c) void {
        _ = glib.idleAdd(dispose, self);
    }

    fn dispose(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Flyout = @ptrCast(@alignCast(data.?));
        const a = self.quick.allocator;
        if (self.volume_source != 0) _ = glib.Source.remove(self.volume_source);
        if (self.brightness_source != 0) _ = glib.Source.remove(self.brightness_source);
        self.guard.kill();
        self.popover.as(gtk.Widget).unparent();
        if (self.backlight_dir) |d| a.free(d);
        a.destroy(self);
        return 0;
    }

    // ---- state ------------------------------------------------------------------------------

    fn refresh(self: *Flyout) void {
        self.syncing = true;
        defer self.syncing = false;
        const q = self.quick;
        if (self.wifi) |b| {
            proc.run(Flyout, self.guard, &.{ "nmcli", "radio", "wifi" }, onWifiState);
            b.as(gtk.Widget).setSensitive(1);
        }
        if (self.bluetooth != null) proc.run(Flyout, self.guard, &.{ "bluetoothctl", "show" }, onBluetoothState);
        if (self.airplane != null) proc.run(Flyout, self.guard, &.{ "rfkill", "list" }, onAirplaneState);
        if (self.volume) |scale| {
            if (q.volume) |v| {
                scale.as(gtk.Range).setValue(@floatFromInt(@min(v.volume_percent, 100)));
                self.mute.?.setActive(@intFromBool(v.muted));
                self.mute.?.as(gtk.Button).setIconName(@ptrCast(Quick.volumeIconZ(icon_storage[0..], v)));
            }
        }
        if (q.battery) |b| {
            var buf: [96]u8 = undefined;
            const text = std.fmt.bufPrintSentinel(&buf, "Battery {d}%{s}", .{ b.percent, if (b.charging) " \u{2014} charging" else "" }, 0) catch "";
            self.battery.setText(text);
        }
    }

    var icon_storage: [48]u8 = undefined;
    fn onWifiState(self: *Flyout, ok: bool, out: []const u8) void {
        if (!ok) return;
        self.setToggle(self.wifi, std.mem.startsWith(u8, std.mem.trim(u8, out, " \n"), "enabled"));
    }

    fn onBluetoothState(self: *Flyout, ok: bool, out: []const u8) void {
        const b = self.bluetooth orelse return;
        if (!ok) return b.as(gtk.Widget).setSensitive(0);
        self.setToggle(b, std.mem.indexOf(u8, out, "Powered: yes") != null);
    }

    fn onAirplaneState(self: *Flyout, ok: bool, out: []const u8) void {
        if (!ok) return;
        self.setToggle(self.airplane, parseRfkill(out) orelse false);
    }

    fn setToggle(self: *Flyout, button: ?*gtk.ToggleButton, on: bool) void {
        const b = button orelse return;
        self.syncing = true;
        b.setActive(@intFromBool(on));
        self.syncing = false;
    }

    // ---- actions ----------------------------------------------------------------------------------

    fn onWifi(button: *gtk.ToggleButton, self: *Flyout) callconv(.c) void {
        if (self.syncing) return;
        proc.run(Flyout, self.guard, &.{ "nmcli", "radio", "wifi", if (button.as(gtk.ToggleButton).getActive() != 0) "on" else "off" }, onAfterChange);
    }

    fn onBluetooth(button: *gtk.ToggleButton, self: *Flyout) callconv(.c) void {
        if (self.syncing) return;
        proc.run(Flyout, self.guard, &.{ "bluetoothctl", "power", if (button.getActive() != 0) "on" else "off" }, onAfterChange);
    }

    fn onAirplane(button: *gtk.ToggleButton, self: *Flyout) callconv(.c) void {
        if (self.syncing) return;
        proc.run(Flyout, self.guard, &.{ "rfkill", if (button.getActive() != 0) "block" else "unblock", "all" }, onAirplaneDone);
    }

    fn onAirplaneDone(self: *Flyout, ok: bool, _: []const u8) void {
        if (!ok) self.status.setText(common.tr("Airplane mode needs permission to use /dev/rfkill."));
        self.quick.poll();
        self.refresh();
    }

    fn onAfterChange(self: *Flyout, _: bool, _: []const u8) void {
        self.quick.poll();
        self.refresh();
    }

    fn onVolume(_: *gtk.Range, self: *Flyout) callconv(.c) void {
        if (self.syncing) return;
        if (self.volume_source == 0) self.volume_source = glib.timeoutAdd(120, applyVolume, self);
    }

    fn applyVolume(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Flyout = @ptrCast(@alignCast(data.?));
        self.volume_source = 0;
        const backend = self.quick.backend orelse return 0;
        const scale = self.volume orelse return 0;
        var arg_buf: [16]u8 = undefined;
        const arg = audio.volumeArg(&arg_buf, backend, @intFromFloat(@max(0, scale.as(gtk.Range).getValue())));
        switch (backend) {
            .wpctl => common.appinfo.spawn(self.quick.allocator, &.{ "wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", arg }),
            .pactl => common.appinfo.spawn(self.quick.allocator, &.{ "pactl", "set-sink-volume", "@DEFAULT_SINK@", arg }),
        }
        self.quick.volume = .{ .volume_percent = @intFromFloat(@max(0, scale.as(gtk.Range).getValue())), .muted = if (self.quick.volume) |v| v.muted else false };
        for (self.quick.bars.items) |bar| self.quick.updateBar(bar);
        return 0;
    }

    fn onMute(button: *gtk.ToggleButton, self: *Flyout) callconv(.c) void {
        if (self.syncing) return;
        const backend = self.quick.backend orelse return;
        const flag: []const u8 = if (button.getActive() != 0) "1" else "0";
        switch (backend) {
            .wpctl => common.appinfo.spawn(self.quick.allocator, &.{ "wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", flag }),
            .pactl => common.appinfo.spawn(self.quick.allocator, &.{ "pactl", "set-sink-mute", "@DEFAULT_SINK@", flag }),
        }
        if (self.quick.volume) |*v| v.muted = button.getActive() != 0;
        for (self.quick.bars.items) |bar| self.quick.updateBar(bar);
    }

    fn onBrightness(_: *gtk.Range, self: *Flyout) callconv(.c) void {
        if (self.syncing) return;
        if (self.brightness_source == 0) self.brightness_source = glib.timeoutAdd(120, applyBrightness, self);
    }

    fn applyBrightness(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Flyout = @ptrCast(@alignCast(data.?));
        self.brightness_source = 0;
        const scale = self.brightness orelse return 0;
        const percent: u32 = @intFromFloat(@max(1, scale.as(gtk.Range).getValue()));
        const dir = self.backlight_dir orelse return 0;
        if (!setBacklight(self.quick.allocator, dir, percent)) {
            self.status.setText(common.tr("Brightness needs brightnessctl, or permission to write the backlight."));
        }
        return 0;
    }

    fn onMore(_: *gtk.Button, self: *Flyout) callconv(.c) void {
        self.popover.popdown();
        common.appinfo.spawn(self.quick.allocator, &.{ "dkde-settings", "--page", "network" });
    }
};

/// Sets the backlight to `percent`: `brightnessctl` handles permissions (a udev
/// rule); plain sysfs only works when the user may write the file.
fn setBacklight(allocator: std.mem.Allocator, dir: []const u8, percent: u32) bool {
    var arg_buf: [16]u8 = undefined;
    if (proc.hasProgram("brightnessctl")) {
        const arg = std.fmt.bufPrint(&arg_buf, "{d}%", .{percent}) catch return false;
        common.appinfo.spawn(allocator, &.{ "brightnessctl", "set", arg });
        return true;
    }
    const max_path = std.fmt.allocPrint(allocator, "{s}/max_brightness", .{dir}) catch return false;
    defer allocator.free(max_path);
    const max_text = readSmall(allocator, max_path) orelse return false;
    defer allocator.free(max_text);
    const max = std.fmt.parseInt(u32, std.mem.trim(u8, max_text, " \r\n"), 10) catch return false;
    const path = std.fmt.allocPrintSentinel(allocator, "{s}/brightness", .{dir}, 0) catch return false;
    defer allocator.free(path);
    var text_buf: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buf, "{d}", .{@max(1, max * percent / 100)}) catch return false;
    return writeFile(path, text);
}

extern fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern fn close(fd: c_int) c_int;

/// Writes `text` into an existing file in place (sysfs does not allow the
/// rename that `g_file_set_contents` uses).
fn writeFile(path: [*:0]const u8, text: []const u8) bool {
    const fd = open(path, 1); // O_WRONLY
    if (fd < 0) return false;
    defer _ = close(fd);
    return write(fd, text.ptr, text.len) == @as(isize, @intCast(text.len));
}
