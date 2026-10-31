//! dkde-panel: taskbar, start menu, clock and wallpaper (SPEC.md 5.1, 5.2).

const std = @import("std");
const gdk = @import("gdk4");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

const Bar = @import("bar.zig").Bar;
const taskbar_mod = @import("taskbar.zig");
const taskbar_pins = @import("taskbar_pins.zig");
const Position = @import("position.zig").Position;
const Wallpaper = @import("wallpaper.zig").Wallpaper;
const Notifications = @import("notifications.zig").Notifications;
const Tray = @import("tray.zig").Tray;
const Quick = @import("quick.zig").Quick;
const Osd = @import("osd.zig").Osd;
const Workspaces = @import("workspaces.zig").Workspaces;
const ipc = @import("ipc.zig");
const slideshow = @import("slideshow.zig");
const StartMenu = @import("startmenu.zig").StartMenu;
const toplevels = @import("toplevels.zig");

const default_height = 40;
const default_clock_format = "%-I:%M %p\n%-m/%-d/%Y";
const default_wallpaper_color = "#3a6ea5";

const App = struct {
    allocator: std.mem.Allocator,
    config: common.Config,
    bars: std.ArrayList(*Bar) = .empty,
    /// What the current bars were built with; a change rebuilds them.
    built_position: Position = .bottom,
    built_autohide: bool = false,
    wallpapers: std.ArrayList(Wallpaper) = .empty,
    /// Colours the wallpaper windows; reloaded when the config changes.
    wallpaper_css: *gtk.CssProvider,
    clock_source: c_uint = 0,
    notifications: ?*Notifications = null,
    tray: ?*Tray = null,
    quick: ?*Quick = null,
    osd: ?*Osd = null,
    workspaces: ?*Workspaces = null,
    manager: ?*toplevels.Manager = null,
    menu: ?*StartMenu = null,
    slide_files: std.ArrayList([:0]u8) = .empty,
    slide_index: usize = 0,
    slide_source: c_uint = 0,
    appearance: ?*common.style.Appearance = null,
    ipc_server: ?*ipc.Server = null,

    fn activate(app: *gtk.Application, self: *App) callconv(.c) void {
        common.style.load(self.allocator) catch |err|
            std.log.warn("stylesheet not loaded: {s}", .{@errorName(err)});

        self.appearance = common.style.Appearance.create(self.allocator) catch null;

        const display = gdk.Display.getDefault() orelse {
            std.log.err("no display", .{});
            return;
        };
        gtk.StyleContext.addProviderForDisplay(
            display,
            self.wallpaper_css.as(gtk.StyleProvider),
            gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 2,
        );

        // Keeps the process alive: layer surfaces do not count as windows
        // the application tracks until they are added to it.
        _ = gio.Application.hold(app.as(gio.Application));

        _ = gio.ListModel.signals.items_changed.connect(display.getMonitors(), *App, &onMonitorsChanged, self, .{});
        self.config.watch(App, onConfigChanged, self) catch |err|
            std.log.warn("config not watched: {s}", .{@errorName(err)});

        // The tray exists before the bars so they can show its icons at once.
        self.tray = Tray.create(self.allocator);
        self.quick = Quick.create(self.allocator, &self.config);
        self.osd = Osd.create(self.allocator);
        if (self.quick) |q| q.osd = self.osd;
        self.workspaces = Workspaces.create(self.allocator, onWorkspacesChanged, self);
        if (glib.getenv("DKDE_DEBUG_QUICK") != null) _ = glib.timeoutAdd(4000, debugQuick, self);
        self.rebuildSurfaces();
        self.updateClock();
        self.notifications = Notifications.create(self.allocator);
        self.ipc_server = ipc.Server.start(self.allocator, onCommand, self) catch |err| blk: {
            std.log.warn("IPC unavailable: {s}", .{@errorName(err)});
            break :blk null;
        };
        self.manager = toplevels.Manager.create(self.allocator, onToplevelsChanged, self) catch |err| blk: {
            std.log.warn("no taskbar: {s}", .{@errorName(err)});
            break :blk null;
        };
        // Pinned apps show even before the first window event.
        self.syncTaskbars();
    }

    /// Handles one IPC command and returns the reply line.
    fn onCommand(data: *anyopaque, command: []const u8) []const u8 {
        const self: *App = @ptrCast(@alignCast(data));
        if (std.mem.eql(u8, command, "toggle-menu")) {
            self.toggleMenu();
            return "ok";
        }
        // The keyboard's volume and brightness keys (see the labwc keybindings).
        if (self.quick) |q| {
            if (std.mem.eql(u8, command, "volume-up")) return reply(q.nudgeVolume(5));
            if (std.mem.eql(u8, command, "volume-down")) return reply(q.nudgeVolume(-5));
            if (std.mem.eql(u8, command, "volume-mute")) return reply(q.toggleMute());
            if (std.mem.eql(u8, command, "brightness-up")) return reply(q.nudgeBrightness(10));
            if (std.mem.eql(u8, command, "brightness-down")) return reply(q.nudgeBrightness(-10));
        }
        // Bound to Ctrl+Alt+L, and used by anything that wants to lock.
        if (std.mem.eql(u8, command, "lock")) {
            if (!common.power.run(self.allocator, &self.config, "lock-command", common.power.detectLock)) return "error: no lock command";
            return "ok";
        }
        if (std.mem.eql(u8, command, "sleep")) {
            if (!common.power.run(self.allocator, &self.config, "sleep-command", common.power.detectSleep)) return "error: no sleep command";
            return "ok";
        }
        if (std.mem.eql(u8, command, "reload")) {
            self.config.reload() catch return "error: reload failed";
            onConfigChanged(self);
            return "ok";
        }
        return "error: unknown command";
    }

    fn reply(_: void) []const u8 {
        return "ok";
    }

    fn toggleMenu(self: *App) void {
        if (self.menu) |menu| {
            menu.close();
            return;
        }
        const display = gdk.Display.getDefault() orelse return;
        const monitors = display.getMonitors();
        const item = monitors.getItem(0) orelse return;
        const monitor: *gdk.Monitor = @ptrCast(@alignCast(item));
        defer monitor.as(gobject.Object).unref();
        for (self.bars.items) |bar| bar.keep_open = true;
        self.menu = StartMenu.open(self.allocator, &self.config, monitor, self.barHeight(), self.panelPosition(), onMenuClosed, self) catch |err| {
            std.log.err("cannot open start menu: {s}", .{@errorName(err)});
            return;
        };
    }

    fn onMenuClosed(data: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(data));
        self.menu = null;
        for (self.bars.items) |bar| bar.menuClosed();
    }

    fn onStartClicked(data: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(data));
        self.toggleMenu();
    }

    fn onToplevelsChanged(data: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(data));
        self.syncTaskbars();
    }

    fn syncTaskbars(self: *App) void {
        const manager = self.manager orelse return;
        const pinned = taskbar_pins.ids(self.allocator) catch &.{};
        defer common.config.freeStringList(self.allocator, @constCast(pinned));
        const opts: taskbar_mod.Options = .{
            .pinned = @ptrCast(pinned),
            .group = self.config.getBool("panel", "group-windows", true),
            // A side panel is too narrow for titles.
            .labels = self.config.getBool("panel", "show-labels", true) and !self.panelPosition().isVertical(),
        };
        for (self.bars.items) |bar| bar.taskbar.sync(manager.toplevels.items, opts);
    }

    fn onMonitorsChanged(_: *gio.ListModel, _: c_uint, _: c_uint, _: c_uint, self: *App) callconv(.c) void {
        self.rebuildSurfaces();
        self.updateClock();
        self.syncTaskbars();
    }

    fn debugQuick(data: ?*anyopaque) callconv(.c) c_int {
        const self: *App = @ptrCast(@alignCast(data.?));
        if (self.quick) |q| q.debugOpen();
        return 0;
    }

    fn onWorkspacesChanged(data: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(data));
        // Dev aid: ask for the third desktop once, to check switching in screenshots.
        if (!debug_switched and glib.getenv("DKDE_DEBUG_DESKTOP") != null) {
            if (self.workspaces) |w| if (w.list.items.len > 2) {
                debug_switched = true;
                w.activate(2);
            };
        }
        for (self.bars.items) |bar| bar.setWorkspaces(self.workspaces);
    }

    var debug_switched = false;

    fn onConfigChanged(self: *App) void {
        if (self.quick) |q| q.reload();
        self.applyWallpaperStyle();
        if (self.panelPosition() != self.built_position or self.panelAutohide() != self.built_autohide) {
            self.rebuildSurfaces();
        } else {
            const height = self.barHeight();
            for (self.bars.items) |bar| bar.setThickness(height);
        }
        self.loadSlideshow();
        self.applyWallpaperImage();
        self.updateClock();
        self.syncTaskbars();
    }

    fn panelPosition(self: *const App) Position {
        const name = self.config.getString(self.allocator, "panel", "position", "bottom") catch return .bottom;
        defer self.allocator.free(name);
        return Position.fromName(name);
    }

    fn panelAutohide(self: *const App) bool {
        return self.config.getBool("panel", "autohide", false);
    }

    fn barHeight(self: *const App) c_int {
        const h = self.config.getInt("panel", "height", default_height);
        return if (h > 0) h else default_height;
    }

    fn wallpaperFit(self: *const App) gtk.ContentFit {
        const name = self.config.getString(self.allocator, "wallpaper", "fit", "cover") catch return .cover;
        defer self.allocator.free(name);
        return slideshow.fitFromName(name);
    }

    fn applyWallpaperImage(self: *App) void {
        const image = self.wallpaperImage();
        defer if (image) |i| self.allocator.free(i);
        const fit = self.wallpaperFit();
        for (self.wallpapers.items) |*wallpaper| wallpaper.setImage(image, fit);
    }

    /// (Re)reads the slideshow folder and restarts its timer.
    fn loadSlideshow(self: *App) void {
        if (self.slide_source != 0) _ = glib.Source.remove(self.slide_source);
        self.slide_source = 0;
        for (self.slide_files.items) |f| self.allocator.free(f);
        self.slide_files.clearRetainingCapacity();
        self.slide_index = 0;

        const dir_text = self.config.getString(self.allocator, "wallpaper", "slideshow-dir", "") catch return;
        defer self.allocator.free(dir_text);
        if (dir_text.len == 0) return;
        const dir_z = self.allocator.dupeSentinel(u8, dir_text, 0) catch return;
        defer self.allocator.free(dir_z);

        const dir = gio.File.newForPath(dir_z);
        defer dir.as(gobject.Object).unref();
        const children = dir.enumerateChildren("standard::name", .{}, null, null) orelse return;
        defer children.as(gobject.Object).unref();
        while (children.nextFile(null, null)) |info| {
            defer info.as(gobject.Object).unref();
            const name = std.mem.span(info.getName());
            if (!slideshow.isImageName(name)) continue;
            const full = std.fmt.allocPrintSentinel(self.allocator, "{s}/{s}", .{ dir_text, name }, 0) catch continue;
            self.slide_files.append(self.allocator, full) catch self.allocator.free(full);
        }
        std.mem.sort([:0]u8, self.slide_files.items, {}, struct {
            fn less(_: void, a: [:0]u8, b: [:0]u8) bool {
                return std.ascii.lessThanIgnoreCase(a, b);
            }
        }.less);

        const minutes = self.config.getInt("wallpaper", "slideshow-minutes", 10);
        if (minutes > 0 and self.slide_files.items.len > 1)
            self.slide_source = glib.timeoutAddSeconds(@intCast(minutes * 60), onSlide, self);
    }

    fn onSlide(data: ?*anyopaque) callconv(.c) c_int {
        const self: *App = @ptrCast(@alignCast(data.?));
        if (self.slide_files.items.len == 0) return 0;
        self.slide_index = (self.slide_index + 1) % self.slide_files.items.len;
        self.applyWallpaperImage();
        return 1;
    }

    /// Owned by the caller; null when no image is configured.
    fn wallpaperImage(self: *const App) ?[:0]u8 {
        if (self.slide_files.items.len > 0) return self.allocator.dupeSentinel(u8, self.slide_files.items[self.slide_index], 0) catch null;
        const path = self.config.getString(self.allocator, "wallpaper", "image", "") catch return null;
        defer self.allocator.free(path);
        if (path.len == 0) return null;
        return self.allocator.dupeSentinel(u8, path, 0) catch null;
    }

    fn applyWallpaperStyle(self: *App) void {
        const color = self.config.getString(self.allocator, "wallpaper", "color", default_wallpaper_color) catch return;
        defer self.allocator.free(color);
        const colorz = self.allocator.dupeSentinel(u8, color, 0) catch return;
        defer self.allocator.free(colorz);

        var rgba: gdk.RGBA = undefined;
        const valid = if (rgba.parse(colorz) != 0) colorz else blk: {
            std.log.warn("panel.conf: invalid wallpaper color '{s}'; using default", .{color});
            break :blk default_wallpaper_color;
        };
        const css = std.fmt.allocPrintSentinel(self.allocator, ".dkde-wallpaper {{ background-color: {s}; }}", .{valid}, 0) catch return;
        defer self.allocator.free(css);
        self.wallpaper_css.loadFromString(css);
    }

    /// One bar and one wallpaper per output (SPEC.md 5.1).
    fn rebuildSurfaces(self: *App) void {
        for (self.bars.items) |bar| bar.destroy();
        for (self.wallpapers.items) |*wallpaper| wallpaper.destroy();
        self.bars.clearRetainingCapacity();
        self.built_position = self.panelPosition();
        self.built_autohide = self.panelAutohide();
        self.wallpapers.clearRetainingCapacity();

        self.applyWallpaperStyle();
        if (self.slide_files.items.len == 0) self.loadSlideshow();
        const display = gdk.Display.getDefault() orelse return;
        const monitors = display.getMonitors();
        const image = self.wallpaperImage();
        defer if (image) |i| self.allocator.free(i);

        var i: c_uint = 0;
        while (i < monitors.getNItems()) : (i += 1) {
            const item = monitors.getItem(i) orelse continue;
            const monitor: *gdk.Monitor = @ptrCast(@alignCast(item));
            defer monitor.as(gobject.Object).unref();

            self.wallpapers.append(self.allocator, Wallpaper.create(monitor, image, self.wallpaperFit(), if (self.wallpapers.items.len == 0 and self.config.getBool("desktop", "icons", true)) &self.config else null)) catch return;
            const bar = Bar.create(self.allocator, monitor, self.barHeight(), self.panelPosition(), self.panelAutohide(), onStartClicked, self, self.tray, self.quick) catch |err| {
                std.log.err("cannot create bar: {s}", .{@errorName(err)});
                return;
            };
            self.bars.append(self.allocator, bar) catch return;
            bar.setWorkspaces(self.workspaces);
        }
    }

    /// Redraws the clock and re-arms the timer for the next minute boundary,
    /// so the panel wakes once a minute rather than polling.
    fn updateClock(self: *App) void {
        if (self.clock_source != 0) _ = glib.Source.remove(self.clock_source);

        const now = glib.DateTime.newNowLocal() orelse return;
        defer now.unref();

        const format = self.config.getString(self.allocator, "panel", "clock-format", default_clock_format) catch return;
        defer self.allocator.free(format);
        const formatz = self.allocator.dupeSentinel(u8, format, 0) catch return;
        defer self.allocator.free(formatz);

        if (now.format(formatz)) |text| {
            defer glib.free(text);
            for (self.bars.items) |bar| bar.setClockText(std.mem.span(text));
        }

        const into_minute_ms: c_uint = @intCast(now.getSecond() * 1000 + @divTrunc(now.getMicrosecond(), 1000));
        self.clock_source = glib.timeoutAdd(60_000 - into_minute_ms + 1, onClockTick, self);
    }

    fn onClockTick(data: ?*anyopaque) callconv(.c) c_int {
        const self: *App = @ptrCast(@alignCast(data.?));
        self.clock_source = 0; // returning false removes this source
        self.updateClock();
        return 0;
    }

    fn deinit(self: *App) void {
        if (self.appearance) |a| a.destroy();
        if (self.slide_source != 0) _ = glib.Source.remove(self.slide_source);
        for (self.slide_files.items) |f| self.allocator.free(f);
        self.slide_files.deinit(self.allocator);
        if (self.menu) |menu| menu.close();
        if (self.ipc_server) |server| server.stop();
        for (self.bars.items) |bar| bar.destroy();
        if (self.manager) |m| m.destroy();
        if (self.clock_source != 0) _ = glib.Source.remove(self.clock_source);
        if (self.notifications) |n| n.destroy();
        if (self.tray) |tray| tray.destroy();
        if (self.quick) |q| q.destroy();
        if (self.osd) |o| o.destroy();
        if (self.workspaces) |w| w.destroy();
        self.bars.deinit(self.allocator);
        self.wallpapers.deinit(self.allocator);
        self.wallpaper_css.as(gobject.Object).unref();
        self.config.deinit();
    }
};

pub const std_options: std.Options = .{ .logFn = common.log.logFn, .log_level = .debug };

pub fn main(init: std.process.Init.Minimal) !void {
    common.perf.init();
    // `dkde-panel msg <command>` talks to the running panel and exits.
    if (init.args.vector.len >= 2 and std.mem.eql(u8, std.mem.span(init.args.vector[1]), "msg")) {
        return sendMessage(init);
    }

    var debug_allocator: common.perf.Gpa = .{};
    defer debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var app: App = .{
        .allocator = allocator,
        .config = try common.Config.load(allocator, "panel.conf"),
        .wallpaper_css = gtk.CssProvider.new(),
    };
    defer app.deinit();

    // Uniqueness needs a session D-Bus, which dkde does not have.
    const gtk_app = gtk.Application.new("org.dkde.panel", .{ .non_unique = true });
    defer gtk_app.as(gobject.Object).unref();
    _ = gio.Application.signals.activate.connect(gtk_app, *App, &App.activate, &app, .{});

    const status = gio.Application.run(gtk_app.as(gio.Application), @intCast(init.args.vector.len), @ptrCast(@constCast(init.args.vector.ptr)));
    if (status != 0) std.process.exit(@intCast(status));
}

fn sendMessage(init: std.process.Init.Minimal) !void {
    if (init.args.vector.len != 3) {
        std.log.err("usage: dkde-panel msg <toggle-menu|reload>", .{});
        std.process.exit(2);
    }
    const reply = ipc.send(std.heap.c_allocator, std.mem.span(init.args.vector[2])) catch |err| {
        std.log.err("cannot reach the panel: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    defer std.heap.c_allocator.free(reply);
    if (!std.mem.eql(u8, reply, "ok")) {
        std.log.err("{s}", .{reply});
        std.process.exit(1);
    }
}

test {
    _ = @import("slideshow.zig");
}

test {
    _ = @import("position.zig");
}

test {
    _ = @import("notifications.zig");
}

test {
    _ = @import("tray.zig");
}

test {
    _ = @import("quick.zig");
}
