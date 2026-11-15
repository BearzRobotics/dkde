//! dkde-idle: runs the lock, screen-off and sleep actions after the keyboard and
//! pointer have been quiet for the configured time (SPEC.md 5.1). It uses
//! `ext-idle-notify-v1` and reads `[power]` and `[menu]` of panel.toml, which it
//! watches, so changes in Settings apply at once.
//!
//!   [power] lock-after, screen-off-after, sleep-after   minutes; 0 = never
//!   [power] lock-before-sleep                           default true
//!   [menu]  lock-command, sleep-command                 empty = detect

const std = @import("std");
const cli = @import("cli");
const glib = @import("glib2");
const wayland = @import("wayland");
const core = @import("core");
const wldesktop = @import("wldesktop");
const x11desktop = @import("x11desktop");

const wl = wayland.client.wl;
const ext = wayland.client.ext;

pub const std_options: std.Options = .{ .logFn = core.log.logFn, .log_level = .debug };

const log = std.log.scoped(.idle);

extern fn system(command: [*:0]const u8) c_int;

const Kind = enum { lock, screen_off, sleep };

const Idle = struct {
    allocator: std.mem.Allocator,
    config: core.Config,
    /// Wayland: the connection and the idle notifier. On X11 these stay null and `x11` is used.
    display: ?*wl.Display = null,
    x11: ?x11desktop.idle.Idle = null,
    /// X11: which actions have fired since the last input.
    fired: [3]bool = .{ false, false, false },
    notifier: ?*ext.IdleNotifierV1 = null,
    seat: ?*wl.Seat = null,
    registry: ?*wl.Registry = null,
    desktop: core.desktop.Desktop = .{},
    notifications: std.ArrayList(*Watch) = .empty,
    /// Minutes are treated as seconds when set, so a test does not wait an hour.
    fast: bool = false,

    const Watch = struct { owner: *Idle, kind: Kind, handle: *ext.IdleNotificationV1 };

    fn registryEvent(registry: *wl.Registry, event: wl.Registry.Event, self: *Idle) void {
        switch (event) {
            .global => |g| {
                const name = std.mem.span(g.interface);
                if (std.mem.eql(u8, name, std.mem.span(ext.IdleNotifierV1.interface.name))) {
                    self.notifier = registry.bind(g.name, ext.IdleNotifierV1, 1) catch null;
                } else if (std.mem.eql(u8, name, std.mem.span(wl.Seat.interface.name))) {
                    if (self.seat == null) self.seat = registry.bind(g.name, wl.Seat, 1) catch null;
                }
            },
            .global_remove => {},
        }
    }

    fn minutes(self: *Idle, key: [:0]const u8) u32 {
        return @intCast(@max(0, self.config.getInt("power", key, 0)));
    }

    fn clearWatches(self: *Idle) void {
        for (self.notifications.items) |w| {
            w.handle.destroy();
            self.allocator.destroy(w);
        }
        self.notifications.clearRetainingCapacity();
    }

    /// (Re)creates one notification per configured timeout.
    fn arm(self: *Idle) void {
        self.fired = .{ false, false, false };
        if (self.x11 != null) return;
        self.clearWatches();
        const notifier = self.notifier orelse return;
        const seat = self.seat orelse return;
        const scale: u32 = if (self.fast) 1000 else 60_000;
        const wanted = [_]struct { key: [:0]const u8, kind: Kind }{
            .{ .key = "lock-after", .kind = .lock },
            .{ .key = "screen-off-after", .kind = .screen_off },
            .{ .key = "sleep-after", .kind = .sleep },
        };
        for (wanted) |w| {
            const m = self.minutes(w.key);
            if (m == 0) continue;
            const handle = notifier.getIdleNotification(m * scale, seat) catch continue;
            const watch = self.allocator.create(Watch) catch continue;
            watch.* = .{ .owner = self, .kind = w.kind, .handle = handle };
            handle.setListener(*Watch, onNotification, watch);
            self.notifications.append(self.allocator, watch) catch {};
            log.info("{s} after {d} {s}", .{ @tagName(w.kind), m, if (self.fast) "seconds" else "minutes" });
        }
        _ = self.display.?.flush();
    }

    fn onNotification(_: *ext.IdleNotificationV1, event: ext.IdleNotificationV1.Event, w: *Watch) void {
        const self = w.owner;
        switch (event) {
            .idled => self.run(w.kind, true),
            .resumed => self.run(w.kind, false),
        }
    }

    fn lockCommand(self: *Idle) ?[]u8 {
        const configured = self.config.getString(self.allocator, "menu", "lock-command", "") catch return null;
        if (configured.len > 0) return configured;
        self.allocator.free(configured);
        const found = core.power.detectLock(core.power.system_probe) orelse return null;
        return self.allocator.dupe(u8, found) catch null;
    }

    fn sleepCommand(self: *Idle) ?[]u8 {
        const configured = self.config.getString(self.allocator, "menu", "sleep-command", "") catch return null;
        if (configured.len > 0) return configured;
        self.allocator.free(configured);
        const found = core.power.detectSleep(core.power.system_probe) orelse return null;
        return self.allocator.dupe(u8, found) catch null;
    }

    fn onScreens(_: ?*anyopaque, ok: bool) void {
        log.debug("switching the screens: {s}", .{if (ok) "done" else "refused"});
    }

    fn shell(self: *Idle, command: []const u8) void {
        // Run in the background so the wait for the next event never blocks.
        const line = std.fmt.allocPrintSentinel(self.allocator, "{s} >/dev/null 2>&1 &", .{command}, 0) catch return;
        defer self.allocator.free(line);
        _ = system(line);
    }

    fn run(self: *Idle, kind: Kind, idled: bool) void {
        switch (kind) {
            .lock => if (idled) {
                const cmd = self.lockCommand() orelse return log.warn("no lock command: install swaylock or set [menu] lock-command", .{});
                defer self.allocator.free(cmd);
                log.info("locking", .{});
                self.shell(cmd);
            },
            .screen_off => {
                log.info("screen {s}", .{if (idled) "off" else "on"});
                if (self.x11) |x| {
                    if (idled) {
                        if (!x.screenOff()) log.warn("the X server has no DPMS; cannot switch the screen off", .{});
                    } else x.screenOn();
                    return;
                }
                var edits: [16]core.desktop.OutputEdit = undefined;
                var n: usize = 0;
                for (self.desktop.outputs()) |o| {
                    if (n == edits.len) break;
                    edits[n] = .{ .id = o.id, .change = .{ .enabled = !idled } };
                    n += 1;
                }
                if (n == 0) return log.warn("no outputs to switch (the compositor lacks wlr-output-management)", .{});
                self.desktop.configureOutputs(edits[0..n], onScreens, self);
                _ = self.display.?.flush();
            },
            .sleep => if (idled) {
                const cmd = self.sleepCommand() orelse return log.warn("no sleep command found: set [menu] sleep-command", .{});
                defer self.allocator.free(cmd);
                // Lock first (unless told not to), so the machine wakes locked.
                if (self.config.getBool("power", "lock-before-sleep", true)) {
                    if (self.lockCommand()) |lock| {
                        defer self.allocator.free(lock);
                        self.shell(lock);
                    }
                }
                log.info("sleeping", .{});
                self.shell(cmd);
            },
        }
    }

    fn onWaylandReadable(_: *glib.IOChannel, _: glib.IOCondition, data: ?*anyopaque) callconv(.c) c_int {
        const self: *Idle = @ptrCast(@alignCast(data.?));
        if (self.display.?.dispatch() != .SUCCESS) {
            log.err("lost the connection to the compositor", .{});
            std.process.exit(1);
        }
        return 1;
    }

    /// X11 has no idle notifications to subscribe to, so the time since the last input is read once a second
    /// and each action fires when it passes its limit, and ends when input comes back.
    fn onX11Tick(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Idle = @ptrCast(@alignCast(data.?));
        const x = self.x11 orelse return 0;
        x.drain();
        const idle_ms = x.idleMs() orelse return 1;
        const scale: u32 = if (self.fast) 1000 else 60_000;
        const wanted = [_]struct { key: [:0]const u8, kind: Kind }{
            .{ .key = "lock-after", .kind = .lock },
            .{ .key = "screen-off-after", .kind = .screen_off },
            .{ .key = "sleep-after", .kind = .sleep },
        };
        for (wanted, 0..) |w, i| {
            const m = self.minutes(w.key);
            if (m == 0) continue;
            const over = idle_ms >= m * scale;
            if (over and !self.fired[i]) {
                self.fired[i] = true;
                self.run(w.kind, true);
            } else if (!over and self.fired[i]) {
                self.fired[i] = false;
                self.run(w.kind, false);
            }
        }
        return 1;
    }

    fn onConfigChanged(self: *Idle) void {
        self.arm();
    }
};

pub fn main(init: std.process.Init.Minimal) !void {
    cli.handle(init.args, .{ .name = "dkde-idle", .summary = "Idle and screen-lock daemon" });
    core.perf.init();
    var debug_allocator: core.perf.Gpa = .{};
    defer debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var idle: Idle = .{
        .allocator = allocator,
        .config = try core.Config.load(allocator, "panel.toml"),
        .fast = glib.getenv("DKDE_IDLE_SECONDS") != null,
    };
    defer idle.config.deinit();

    // Under a Wayland compositor the idle notifier does the work; without one, on X11, the time since the
    // last input is polled.
    if (glib.getenv("WAYLAND_DISPLAY") == null and glib.getenv("DISPLAY") != null) {
        idle.x11 = x11desktop.idle.Idle.open() orelse {
            log.err("cannot connect to the X server, or it has no MIT-SCREEN-SAVER extension", .{});
            std.process.exit(1);
        };
        log.info("X11: polling the idle time", .{});
        idle.arm();
        idle.config.watch(Idle, Idle.onConfigChanged, &idle) catch |err| log.warn("config not watched: {s}", .{@errorName(err)});
        _ = glib.timeoutAdd(1000, Idle.onX11Tick, &idle);
        glib.MainLoop.new(null, 0).run();
        return;
    }

    const display = wl.Display.connect(null) catch {
        log.err("cannot connect to the compositor", .{});
        std.process.exit(1);
    };
    idle.display = display;
    idle.registry = try display.getRegistry();
    idle.registry.?.setListener(*Idle, Idle.registryEvent, &idle);
    if (display.roundtrip() != .SUCCESS) std.process.exit(1);
    idle.desktop = wldesktop.Wayland.create(allocator, display, .{ .windows = false, .workspaces = false, .capture = false }, .{ .data = &idle });
    defer idle.desktop.destroy();
    if (idle.notifier == null) {
        log.err("the compositor does not offer ext-idle-notify-v1", .{});
        std.process.exit(1);
    }
    idle.arm();
    idle.config.watch(Idle, Idle.onConfigChanged, &idle) catch |err| log.warn("config not watched: {s}", .{@errorName(err)});

    const channel = glib.IOChannel.unixNew(display.getFd());
    _ = glib.ioAddWatch(channel, .{ .in = true, .hup = true, .err = true }, Idle.onWaylandReadable, &idle);
    const loop = glib.MainLoop.new(null, 0);
    loop.run();
}

test {
    _ = @import("core");
}
