// SPDX-License-Identifier: GPL-2.0-or-later
//! dkde-snap: snap layouts, like Windows 11's. Super+Z shows the usual arrangements (halves, thirds,
//! quarters…) over the screen; clicking a zone puts the active window there. Super+Z again, Escape or a
//! click outside the card closes it.
//!
//! labwc has no way for a client to move another client's window, so a zone is one of the regions
//! written into rc.xml (see `common.labwc.snap_regions`), and the choice is made by pressing that
//! region's own key chord (through dkde-pointer's virtual keyboard) once the overlay is gone.

const std = @import("std");
const cli = @import("cli");
const common = @import("common");
const gdk = @import("gdk4");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const gdkwayland = @import("gdkwayland4");
const gdkx11 = @import("gdkx114");
const wayland = @import("wayland");
const wldesktop = @import("wldesktop");
const x11desktop = @import("x11desktop");

const wl = wayland.client.wl;

const labwc = common.labwc;
const t = common.tr;
pub const std_options: std.Options = .{ .logFn = common.log.logFn, .log_level = .debug };

const log = std.log.scoped(.snap);
const gpa = std.heap.c_allocator;

extern fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;
extern fn readlink(path: [*:0]const u8, buf: [*]u8, size: usize) isize;
extern fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
const RTLD_DEFAULT: ?*anyopaque = null;
const layer_lib = "libgtk4-layer-shell.so.0";

/// The arrangements offered: each is a list of regions (names from `labwc.snap_regions`).
const layouts = [_][]const []const u8{
    &.{ "left-half", "right-half" },
    &.{ "left-two-thirds", "right-third" },
    &.{ "left-third", "right-two-thirds" },
    &.{ "left-third", "middle-third", "right-third" },
    &.{ "top-left", "top-right", "bottom-left", "bottom-right" },
    &.{ "left-half", "top-right", "bottom-right" },
    &.{ "top-left", "bottom-left", "right-half" },
    &.{ "top-half", "bottom-half" },
};

const card_w = 168;
const card_h = 104;

const style =
    \\.dkde-snap-overlay { background: rgba(0, 0, 0, 0.38); }
    \\.dkde-snap-card { background: rgba(247, 247, 247, 0.98); border-radius: 14px; padding: 18px; }
    \\.dkde-snap-title { color: #222; font-weight: bold; }
    \\.dkde-snap-hint { color: #666; }
    \\.dkde-snap-assist { background: rgba(247, 247, 247, 0.96); border-radius: 12px; padding: 12px; border: 2px solid rgba(60, 120, 220, 0.8); }
    \\.dkde-snap-layout { background: rgba(0, 0, 0, 0.07); border-radius: 8px; }
    \\.dkde-snap-zone { background: rgba(60, 120, 220, 0.30); border: 1px solid rgba(60, 120, 220, 0.8); border-radius: 4px; min-width: 0; min-height: 0; padding: 0; }
    \\.dkde-snap-zone:hover { background: rgba(60, 120, 220, 0.9); }
;

const App = struct {
    window: ?*gtk.Window = null,
    assist: ?*Assist = null,
    assist_spec: ?[]const u8 = null,
    app: *gtk.Application,
    zones: [layouts.len * 4]Zone = undefined,
};

const Zone = struct { app: *App = undefined, region: usize = 0 };

fn regionIndex(name: []const u8) ?usize {
    for (labwc.snap_regions, 0..) |r, i| if (std.mem.eql(u8, r.name, name)) return i;
    return null;
}

/// "W-C-A-S-a" as the words dkde-pointer takes: "super+ctrl+alt+shift+a".
fn chordOf(buf: []u8, key: []const u8) ?[]const u8 {
    var out: std.ArrayList(u8) = .initBuffer(buf);
    var parts = std.mem.splitScalar(u8, key, '-');
    var first = true;
    while (parts.next()) |p| {
        const word: []const u8 = if (std.mem.eql(u8, p, "W")) "super" else if (std.mem.eql(u8, p, "C")) "ctrl" else if (std.mem.eql(u8, p, "A")) "alt" else if (std.mem.eql(u8, p, "S")) "shift" else p;
        if (!first) out.appendBounded('+') catch return null;
        out.appendSliceBounded(word) catch return null;
        first = false;
    }
    return out.items;
}

/// The key bound to the region in rc.xml (the user may have changed it), or the default.
fn keyFor(buf: []u8, region: usize) []const u8 {
    const name = labwc.snap_regions[region].name;
    for (labwc.dkde_keybinds) |k| {
        if (!std.mem.eql(u8, k.action, "SnapToRegion") or !std.mem.eql(u8, k.to, name)) continue;
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&path_buf, "{s}/labwc/rc.xml", .{std.mem.span(glib.getUserConfigDir())}, 0) catch return k.key;
        var contents: [*]u8 = undefined;
        var length: usize = 0;
        if (glib.fileGetContents(path, &contents, &length, null) == 0) return k.key;
        defer glib.free(contents);
        const current = labwc.currentKey(contents[0..length], k) orelse return k.key;
        const n = @min(current.len, buf.len);
        @memcpy(buf[0..n], current[0..n]);
        return buf[0..n];
    }
    return "";
}

fn onZone(_: *gtk.Button, zone: *Zone) callconv(.c) void {
    var key_buf: [64]u8 = undefined;
    const key = keyFor(&key_buf, zone.region);
    var chord_buf: [96]u8 = undefined;
    if (chordOf(&chord_buf, key)) |chord| {
        // After the overlay has gone, so the keys go to the window that is to be moved.
        var cmd: [256]u8 = undefined;
        const line = std.fmt.bufPrintSentinel(&cmd, "sh -c 'sleep 0.3; dkde-pointer chord {s}'", .{chord}, 0) catch return;
        var err: ?*glib.Error = null;
        if (glib.spawnCommandLineAsync(line, &err) == 0) {
            if (err) |e| {
                log.err("cannot snap: {s}", .{e.f_message orelse "unknown error"});
                e.free();
            }
        }
    }
    zone.app.app.as(gio.Application).quit();
}

fn onKey(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, _: gdk.ModifierType, self: *App) callconv(.c) c_int {
    if (keyval == gdk.KEY_Escape) {
        self.app.as(gio.Application).quit();
        return 1;
    }
    return 0;
}

fn onBackdrop(gesture: *gtk.GestureClick, _: c_int, x: f64, y: f64, self: *App) callconv(.c) void {
    const backdrop = gesture.as(gtk.EventController).getWidget() orelse return;
    const hit = backdrop.pick(x, y, .{});
    // Only a click on the dimmed background (not on the card) closes it.
    if (hit != null and hit.? == backdrop) self.app.as(gio.Application).quit();
}

fn buildLayout(self: *App, index: usize) *gtk.Widget {
    const fixed = gtk.Fixed.new();
    const w = fixed.as(gtk.Widget);
    w.setSizeRequest(card_w, card_h);
    w.addCssClass("dkde-snap-layout");
    const gap = 3;
    for (layouts[index], 0..) |name, zi| {
        const r_index = regionIndex(name) orelse continue;
        const r = labwc.snap_regions[r_index];
        const x: c_int = @divTrunc(@as(c_int, r.x) * card_w, 100) + gap;
        const y: c_int = @divTrunc(@as(c_int, r.y) * card_h, 100) + gap;
        const zw: c_int = @divTrunc(@as(c_int, r.w) * card_w, 100) - 2 * gap;
        const zh: c_int = @divTrunc(@as(c_int, r.h) * card_h, 100) - 2 * gap;
        const button = gtk.Button.new();
        button.as(gtk.Widget).addCssClass("dkde-snap-zone");
        button.as(gtk.Widget).setSizeRequest(zw, zh);
        const slot = &self.zones[index * 4 + zi];
        slot.* = .{ .app = self, .region = r_index };
        _ = gtk.Button.signals.clicked.connect(button, *Zone, &onZone, slot, .{});
        fixed.put(button.as(gtk.Widget), @floatFromInt(x), @floatFromInt(y));
    }
    return w;
}

// ---- snap assist ------------------------------------------------------------------------------------
//
// After a window is dropped on a zone of a layout (the card at the top of the screen), the zones still empty
// each list the other open windows; choosing one puts it there (it is made the active window, and the zone's
// key chord is pressed, as the layout picker does). The overlay closes when every zone is filled.

const Assist = struct {
    app: *App,
    desktop: common.desktop.Desktop = .{},
    /// The work area, relative to the output the overlay covers.
    area: struct { x: i32, y: i32, w: i32, h: i32 },
    zones: [4]AssistZone = undefined,
    count: usize = 0,
    free: usize = 0,
    /// The window that was just snapped (the active one when the list first arrives), and the ones placed since.
    excluded: ?*common.desktop.Window = null,
    placed: std.ArrayList(*common.desktop.Window) = .empty,
    fixed: *gtk.Fixed,
    /// What the lists were last built from; they are rebuilt only when it changes, so a click is never lost to a
    /// button that was just replaced.
    signature: u64 = 0,

    const AssistZone = struct { assist: *Assist, region: usize, card: *gtk.Box, list: *gtk.Box, filled: bool };
    const WindowChoice = struct { assist: *Assist, zone: *AssistZone, window: *common.desktop.Window };

    fn build(app: *App, spec: []const u8) ?*gtk.Widget {
        var parts = std.mem.splitScalar(u8, spec, ',');
        var v: [6]i32 = undefined;
        for (&v) |*slot| slot.* = std.fmt.parseInt(i32, parts.next() orelse return null, 10) catch return null;
        const layout_index: usize = @intCast(@max(v[0], 0));
        const taken: usize = @intCast(@max(v[1], 0));
        if (layout_index >= layouts.len or taken >= layouts[layout_index].len) return null;
        const self = gpa.create(Assist) catch return null;
        self.* = .{ .app = app, .area = .{ .x = v[2], .y = v[3], .w = v[4], .h = v[5] }, .fixed = gtk.Fixed.new() };
        app.assist = self;
        for (layouts[layout_index], 0..) |name, zi| {
            if (zi == taken) continue;
            const r_index = regionIndex(name) orelse continue;
            const r = labwc.snap_regions[r_index];
            const card = gtk.Box.new(.vertical, 8);
            card.as(gtk.Widget).addCssClass("dkde-snap-assist");
            const heading = gtk.Label.new(t("Choose a window for this space"));
            heading.as(gtk.Widget).addCssClass("dkde-snap-title");
            heading.setXalign(0);
            card.append(heading.as(gtk.Widget));
            const list = gtk.Box.new(.vertical, 6);
            const scroll = gtk.ScrolledWindow.new();
            scroll.setChild(list.as(gtk.Widget));
            scroll.as(gtk.Widget).setVexpand(1);
            scroll.setPolicy(.never, .automatic);
            card.append(scroll.as(gtk.Widget));
            const margin = 10;
            const x = self.area.x + @divTrunc(self.area.w * r.x, 100) + margin;
            const y = self.area.y + @divTrunc(self.area.h * r.y, 100) + margin;
            const w = @divTrunc(self.area.w * r.w, 100) - 2 * margin;
            const h = @divTrunc(self.area.h * r.h, 100) - 2 * margin;
            card.as(gtk.Widget).setSizeRequest(@max(w, 120), @max(h, 80));
            self.fixed.put(card.as(gtk.Widget), @floatFromInt(x), @floatFromInt(y));
            self.zones[self.count] = .{ .assist = self, .region = r_index, .card = card, .list = list, .filled = false };
            self.count += 1;
        }
        self.free = self.count;
        if (self.count == 0) return null;
        self.fixed.as(gtk.Widget).setHexpand(1);
        self.fixed.as(gtk.Widget).setVexpand(1);
        self.startDesktop();
        self.refill();
        // The window list arrives a moment after the connection is made; look again a few times.
        _ = glib.timeoutAdd(300, onRetry, self);
        return self.fixed.as(gtk.Widget);
    }

    fn startDesktop(self: *Assist) void {
        const display = gdk.Display.getDefault() orelse return;
        if (gobject.typeCheckInstanceIsA(@ptrCast(@alignCast(display)), gdkwayland.WaylandDisplay.getGObjectType()) != 0) {
            const wl_display: *wl.Display = @ptrCast(gdkwayland.WaylandDisplay.getWlDisplay(@ptrCast(display)) orelse return);
            self.desktop = wldesktop.Wayland.create(gpa, wl_display, .{ .outputs = false, .capture = false, .workspaces = false }, .{ .data = self, .on_windows = onWindows });
        } else if (gobject.typeCheckInstanceIsA(@ptrCast(@alignCast(display)), gdkx11.X11Display.getGObjectType()) != 0) {
            self.desktop = x11desktop.X11.create(gpa, onWindows, ignore, self, null);
        }
    }

    fn ignore(_: *anyopaque) void {}

    var retries: u32 = 0;

    fn onRetry(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Assist = @ptrCast(@alignCast(data.?));
        self.refill();
        retries += 1;
        return if (retries < 6 and self.excluded == null) 1 else 0;
    }

    fn onWindows(data: *anyopaque) void {
        const self: *Assist = @ptrCast(@alignCast(data));
        self.refill();
    }

    fn isPlaced(self: *Assist, w: *common.desktop.Window) bool {
        if (self.excluded == w) return true;
        for (self.placed.items) |p| if (p == w) return true;
        return false;
    }

    /// Fills every empty zone's list with the windows still free to place.
    fn refill(self: *Assist) void {
        const wins = self.desktop.windows();
        if (self.excluded == null) {
            for (wins) |w| if (w.activated and w.ready) {
                self.excluded = w;
                break;
            };
        }
        var hasher = std.hash.Wyhash.init(self.free);
        for (wins) |w| {
            if (!w.ready or self.isPlaced(w)) continue;
            hasher.update(std.mem.asBytes(&@intFromPtr(w)));
            hasher.update(w.title);
        }
        const signature = hasher.final();
        if (signature == self.signature) return;
        self.signature = signature;
        for (self.zones[0..self.count]) |*z| {
            if (z.filled) continue;
            while (z.list.as(gtk.Widget).getFirstChild()) |child| z.list.remove(child);
            var any = false;
            for (wins) |w| {
                if (!w.ready or self.isPlaced(w) or w.title.len == 0 or std.mem.eql(u8, w.title, "dkde-snap")) continue;
                any = true;
                const title = gpa.dupeSentinel(u8, w.title, 0) catch continue;
                defer gpa.free(title);
                const button = gtk.Button.new();
                const row = gtk.Box.new(.horizontal, 8);
                var icon_name_buf: [96]u8 = undefined;
                const icon_name = std.fmt.bufPrintSentinel(&icon_name_buf, "{s}", .{if (w.app_id.len > 0) w.app_id else "application-x-executable"}, 0) catch "application-x-executable";
                const icon = gtk.Image.newFromIconName(icon_name);
                icon.setPixelSize(24);
                row.append(icon.as(gtk.Widget));
                const label = gtk.Label.new(title);
                label.setEllipsize(.end);
                label.setXalign(0);
                label.as(gtk.Widget).setHexpand(1);
                row.append(label.as(gtk.Widget));
                button.setChild(row.as(gtk.Widget));
                const choice = gpa.create(WindowChoice) catch continue;
                choice.* = .{ .assist = self, .zone = z, .window = w };
                _ = gtk.Button.signals.clicked.connect(button, *WindowChoice, &onChoose, choice, .{});
                z.list.append(button.as(gtk.Widget));
            }
            if (!any) {
                const none = gtk.Label.new(t("No other windows are open."));
                none.as(gtk.Widget).addCssClass("dkde-snap-hint");
                z.list.append(none.as(gtk.Widget));
            }
        }
    }

    fn onChoose(_: *gtk.Button, choice: *WindowChoice) callconv(.c) void {
        const self = choice.assist;
        const zone = choice.zone;
        log.info("assist: chose \"{s}\" for zone {d}", .{ choice.window.title, zone.region });
        if (zone.filled) return;
        choice.window.activate();
        self.placed.append(gpa, choice.window) catch {};
        zone.filled = true;
        self.free -= 1;
        self.fixed.remove(zone.card.as(gtk.Widget));
        // Give the compositor or window manager a moment to focus the chosen window, then put it in the zone.
        if (self.onX11()) {
            const delay = gpa.create(X11Snap) catch return;
            delay.* = .{ .index = @intCast(zone.region), .assist = self };
            _ = glib.timeoutAdd(400, onX11Snap, delay);
            if (self.free == 0) _ = glib.timeoutAdd(900, onAllDone, self.app) else self.refill();
            return;
        }
        var key_buf: [64]u8 = undefined;
        const key = keyFor(&key_buf, zone.region);
        var chord_buf: [96]u8 = undefined;
        if (chordOf(&chord_buf, key)) |chord| {
            var cmd: [256]u8 = undefined;
            const line = std.fmt.bufPrintSentinel(&cmd, "sh -c 'sleep 0.4; dkde-pointer chord {s}'", .{chord}, 0) catch return;
            var err: ?*glib.Error = null;
            if (glib.spawnCommandLineAsync(line, &err) == 0) {
                if (err) |e| {
                    log.err("cannot snap: {s}", .{e.f_message orelse "unknown error"});
                    e.free();
                }
            }
        }
        if (self.free == 0) {
            // Let the chord go out before the overlay (and this program) ends.
            _ = glib.timeoutAdd(900, onAllDone, self.app);
        } else self.refill();
    }

    const X11Snap = struct { index: u32, assist: *Assist };

    fn onX11Snap(data: ?*anyopaque) callconv(.c) c_int {
        const delay: *X11Snap = @ptrCast(@alignCast(data.?));
        _ = x11desktop.pointer.snapRegion(delay.index);
        gpa.destroy(delay);
        return 0;
    }

    fn onX11(_: *Assist) bool {
        const display = gdk.Display.getDefault() orelse return false;
        return gobject.typeCheckInstanceIsA(@ptrCast(@alignCast(display)), gdkx11.X11Display.getGObjectType()) != 0;
    }

    fn onAllDone(data: ?*anyopaque) callconv(.c) c_int {
        const app: *App = @ptrCast(@alignCast(data.?));
        app.app.as(gio.Application).quit();
        return 0;
    }
};

// ---- layer shell (gtk4-layer-shell, loaded when present) ----------------------------------------

const Layer = struct {
    init_for_window: *const fn (*gtk.Window) callconv(.c) void,
    set_layer: *const fn (*gtk.Window, c_int) callconv(.c) void,
    set_anchor: *const fn (*gtk.Window, c_int, c_int) callconv(.c) void,
    set_keyboard_mode: *const fn (*gtk.Window, c_int) callconv(.c) void,
    set_namespace: *const fn (*gtk.Window, [*:0]const u8) callconv(.c) void,
    set_exclusive_zone: *const fn (*gtk.Window, c_int) callconv(.c) void,
    is_supported: *const fn () callconv(.c) c_int,
};

fn layerShell() ?Layer {
    const display = gdk.Display.getDefault() orelse return null;
    const wl_type = gobject.typeFromName("GdkWaylandDisplay");
    if (wl_type == 0 or gobject.typeCheckInstanceIsA(@ptrCast(@alignCast(display)), wl_type) == 0) return null;
    var l: Layer = undefined;
    inline for (.{
        .{ "init_for_window", "gtk_layer_init_for_window" },
        .{ "set_layer", "gtk_layer_set_layer" },
        .{ "set_anchor", "gtk_layer_set_anchor" },
        .{ "set_keyboard_mode", "gtk_layer_set_keyboard_mode" },
        .{ "set_namespace", "gtk_layer_set_namespace" },
        .{ "set_exclusive_zone", "gtk_layer_set_exclusive_zone" },
        .{ "is_supported", "gtk_layer_is_supported" },
    }) |f| {
        const sym = dlsym(RTLD_DEFAULT, f[1]) orelse return null;
        @field(l, f[0]) = @ptrCast(@alignCast(sym));
    }
    if (l.is_supported() == 0) return null;
    return l;
}

/// Starts this program again with gtk4-layer-shell preloaded, unless it already is.
fn reexecWithLayerShell(argv: []const [*:0]const u8) void {
    if (glib.getenv("DKDE_SNAP_CHILD") != null) return;
    var found = false;
    for ([_][]const u8{ "/usr/lib/x86_64-linux-gnu", "/usr/lib64", "/usr/lib", "/usr/local/lib", "/usr/lib/aarch64-linux-gnu" }) |dir| {
        var pbuf: [256]u8 = undefined;
        const p = std.fmt.bufPrintSentinel(&pbuf, "{s}/{s}", .{ dir, layer_lib }, 0) catch continue;
        if (std.c.access(p.ptr, std.c.F_OK) == 0) found = true;
    }
    if (!found) return;
    var pre: [1024]u8 = undefined;
    const old = if (glib.getenv("LD_PRELOAD")) |v| std.mem.span(v) else "";
    const value = (if (old.len > 0) std.fmt.bufPrintSentinel(&pre, "{s} {s}", .{ layer_lib, old }, 0) else std.fmt.bufPrintSentinel(&pre, "{s}", .{layer_lib}, 0)) catch return;
    _ = setenv("LD_PRELOAD", value.ptr, 1);
    _ = setenv("DKDE_SNAP_CHILD", "1", 1);
    var exe: [4096]u8 = undefined;
    const len = readlink("/proc/self/exe", &exe, exe.len - 1);
    if (len <= 0) return;
    const n = exe[0..@intCast(len)];
    exe[n.len] = 0;
    var args: [64:null]?[*:0]const u8 = @splat(null);
    for (argv[0..@min(argv.len, 63)], 0..) |a, i| args[i] = a;
    _ = execv(@ptrCast(exe[0..n.len :0].ptr), &args);
}

// ---- the window ----------------------------------------------------------------------------------

fn activate(_: *gtk.Application, self: *App) callconv(.c) void {
    // A second Super+Z closes it again.
    if (self.window != null) {
        self.app.as(gio.Application).quit();
        return;
    }
    const provider = gtk.CssProvider.new();
    provider.loadFromString(style);
    if (gdk.Display.getDefault()) |display| gtk.StyleContext.addProviderForDisplay(display, provider.as(gtk.StyleProvider), gtk.STYLE_PROVIDER_PRIORITY_USER);

    const window = gtk.Window.new();
    self.window = window;
    self.app.addWindow(window);
    window.setDecorated(0);
    window.setTitle("dkde-snap");
    window.as(gtk.Widget).addCssClass("dkde-snap-overlay");
    if (layerShell()) |l| {
        l.init_for_window(window);
        l.set_namespace(window, "dkde-snap");
        l.set_layer(window, 3); // overlay: above the panel too
        for ([_]c_int{ 0, 1, 2, 3 }) |edge| l.set_anchor(window, edge, 1);
        l.set_exclusive_zone(window, -1);
        l.set_keyboard_mode(window, 2); // on demand
    } else {
        window.setDefaultSize(900, 560);
    }

    if (self.assist_spec) |spec| {
        window.setChild(Assist.build(self, spec) orelse {
            self.app.as(gio.Application).quit();
            return;
        });
        const keys = gtk.EventControllerKey.new();
        _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *App, &onKey, self, .{});
        window.as(gtk.Widget).addController(keys.as(gtk.EventController));
        // Without layer-shell (X11) there is no overlay surface: an ordinary undecorated window the size of the work area.
        if (layerShell() == null) if (self.assist) |a| window.setDefaultSize(a.area.w, a.area.h);
        window.present();
        return;
    }

    const backdrop = gtk.Box.new(.vertical, 0);
    backdrop.as(gtk.Widget).setHexpand(1);
    backdrop.as(gtk.Widget).setVexpand(1);
    const click = gtk.GestureClick.new();
    _ = gtk.GestureClick.signals.pressed.connect(click, *App, &onBackdrop, self, .{});
    backdrop.as(gtk.Widget).addController(click.as(gtk.EventController));

    const card = gtk.Box.new(.vertical, 12);
    card.as(gtk.Widget).addCssClass("dkde-snap-card");
    card.as(gtk.Widget).setHalign(.center);
    card.as(gtk.Widget).setValign(.center);
    card.as(gtk.Widget).setHexpand(1);
    card.as(gtk.Widget).setVexpand(1);
    const title = gtk.Label.new(t("Snap layouts"));
    title.as(gtk.Widget).addCssClass("dkde-snap-title");
    card.append(title.as(gtk.Widget));
    const grid = gtk.Grid.new();
    grid.setColumnSpacing(14);
    grid.setRowSpacing(14);
    for (0..layouts.len) |i| grid.attach(buildLayout(self, i), @intCast(i % 4), @intCast(i / 4), 1, 1);
    card.append(grid.as(gtk.Widget));
    const hint = gtk.Label.new(t("Click a zone to put the active window there. Esc closes."));
    hint.as(gtk.Widget).addCssClass("dkde-snap-hint");
    card.append(hint.as(gtk.Widget));
    backdrop.append(card.as(gtk.Widget));
    window.setChild(backdrop.as(gtk.Widget));

    const keys = gtk.EventControllerKey.new();
    _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *App, &onKey, self, .{});
    window.as(gtk.Widget).addController(keys.as(gtk.EventController));
    window.present();
}

pub fn main(init: std.process.Init.Minimal) !void {
    cli.handle(init.args, .{ .name = "dkde-snap", .summary = "Snap layouts: choose where the active window goes", .usage = "[--assist LAYOUT,ZONE,X,Y,W,H]", .value_options = &.{"--assist"} });
    var argv: [8]?[*:0]const u8 = @splat(null);
    var count: usize = 0;
    for (init.args.vector[0..@min(init.args.vector.len, 7)]) |a| {
        argv[count] = a;
        count += 1;
    }
    var plain: [8][*:0]const u8 = undefined;
    for (argv[0..count], 0..) |a, i| plain[i] = a.?;
    reexecWithLayerShell(plain[0..count]);

    const gtk_app = gtk.Application.new("org.dkde.snap", .{});
    var app: App = .{ .app = gtk_app };
    // `--assist L,J,X,Y,W,H`: a window was just dropped in zone J of layout L; offer the other windows for the rest.
    var arg_at: usize = 0;
    while (arg_at + 1 < count) : (arg_at += 1) {
        if (std.mem.eql(u8, std.mem.span(plain[arg_at]), "--assist")) app.assist_spec = std.mem.span(plain[arg_at + 1]);
    }
    _ = gio.Application.signals.activate.connect(gtk_app, *App, &activate, &app, .{});
    // Only the program name goes to GApplication, which would reject --assist (read above) as an unknown option.
    var c_argv: [2]?[*:0]u8 = .{ @constCast(argv[0]), null };
    _ = gio.Application.run(gtk_app.as(gio.Application), 1, @ptrCast(&c_argv));
}
