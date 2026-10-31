//! dkde-idle: runs the lock, screen-off and sleep actions after the keyboard and
//! pointer have been quiet for the configured time (SPEC.md 5.1). It uses
//! `ext-idle-notify-v1` and reads `[power]` and `[menu]` of panel.conf, which it
//! watches, so changes in Settings apply at once.
//!
//!   [power] lock-after, screen-off-after, sleep-after   minutes; 0 = never
//!   [power] lock-before-sleep                           default true
//!   [menu]  lock-command, sleep-command                 empty = detect

const std = @import("std");
const glib = @import("glib2");
const wayland = @import("wayland");
const common = @import("common");

const wl = wayland.client.wl;
const ext = wayland.client.ext;

pub const std_options: std.Options = .{ .logFn = common.log.logFn, .log_level = .debug };

const log = std.log.scoped(.idle);

extern fn system(command: [*:0]const u8) c_int;

const Kind = enum { lock, screen_off, sleep };

const Idle = struct {
    allocator: std.mem.Allocator,
    config: common.Config,
    display: *wl.Display,
    notifier: ?*ext.IdleNotifierV1 = null,
    seat: ?*wl.Seat = null,
    registry: *wl.Registry,
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
        _ = self.display.flush();
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
        const found = common.power.detectLock(common.power.system_probe) orelse return null;
        return self.allocator.dupe(u8, found) catch null;
    }

    fn sleepCommand(self: *Idle) ?[]u8 {
        const configured = self.config.getString(self.allocator, "menu", "sleep-command", "") catch return null;
        if (configured.len > 0) return configured;
        self.allocator.free(configured);
        const found = common.power.detectSleep(common.power.system_probe) orelse return null;
        return self.allocator.dupe(u8, found) catch null;
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
                var buf: [256]u8 = undefined;
                const script = std.fmt.bufPrint(&buf, "for o in $(wlr-randr | awk '/^[^ ]/ {{print $1}}'); do wlr-randr --output \"$o\" {s}; done", .{if (idled) "--off" else "--on"}) catch return;
                log.info("screen {s}", .{if (idled) "off" else "on"});
                self.shell(script);
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
        if (self.display.dispatch() != .SUCCESS) {
            log.err("lost the connection to the compositor", .{});
            std.process.exit(1);
        }
        return 1;
    }

    fn onConfigChanged(self: *Idle) void {
        self.arm();
    }
};

pub fn main(_: std.process.Init.Minimal) !void {
    common.perf.init();
    var debug_allocator: common.perf.Gpa = .{};
    defer debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    const display = wl.Display.connect(null) catch {
        log.err("cannot connect to the compositor", .{});
        std.process.exit(1);
    };
    var idle: Idle = .{
        .allocator = allocator,
        .config = try common.Config.load(allocator, "panel.conf"),
        .display = display,
        .registry = try display.getRegistry(),
        .fast = glib.getenv("DKDE_IDLE_SECONDS") != null,
    };
    defer idle.config.deinit();
    idle.registry.setListener(*Idle, Idle.registryEvent, &idle);
    if (display.roundtrip() != .SUCCESS) std.process.exit(1);
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
    _ = @import("common");
}
