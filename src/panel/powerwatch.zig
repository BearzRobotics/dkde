//! Low-battery warnings (SPEC.md 5.1). The panel is always running, so it
//! watches the battery itself: no daemon, no init-system timer. On the way down
//! it warns at the low level, warns again at the critical level, and, unless
//! plugged in within a short grace period, runs the configured action
//! (sleep by default). Nothing runs on a desktop without a battery.

const std = @import("std");
const glib = @import("glib2");
const common = @import("common");

const log = std.log.scoped(.powerwatch);

pub const Limits = struct {
    /// Percent at or below which the first warning is shown; 0 turns warnings off.
    low: u32 = 15,
    /// Percent at or below which the second warning is shown and the action runs.
    critical: u32 = 5,
    action: Action = .sleep,
};

pub const Action = enum {
    /// Warn only.
    none,
    sleep,
    poweroff,

    pub fn parse(text: []const u8) Action {
        if (std.ascii.eqlIgnoreCase(text, "none")) return .none;
        if (std.ascii.eqlIgnoreCase(text, "poweroff")) return .poweroff;
        return .sleep;
    }
};

pub const Reading = struct {
    percent: u32,
    /// Running on the battery: "Discharging". Charging, full and "not
    /// charging" (plugged in, held at a limit) are all on mains power.
    discharging: bool,
};

pub fn parseReading(capacity: []const u8, status: []const u8) ?Reading {
    const percent = std.fmt.parseInt(u32, std.mem.trim(u8, capacity, " \n\r"), 10) catch return null;
    return .{ .percent = @min(percent, 100), .discharging = std.mem.eql(u8, std.mem.trim(u8, status, " \n\r"), "Discharging") };
}

/// What the watcher remembers between readings.
pub const State = struct {
    warned_low: bool = false,
    warned_critical: bool = false,
    /// The action has run for this discharge; it does not run again until the
    /// machine has been on mains power.
    acted: bool = false,
};

pub const Event = enum {
    none,
    /// Show the low-battery warning.
    low,
    /// Show the critical warning and start the grace period.
    critical,
};

/// Decides what a reading means. Pure, so the rules are tested.
pub fn decide(state: *State, r: ?Reading, limits: Limits) Event {
    const reading = r orelse return .none;
    if (!reading.discharging) {
        state.* = .{};
        return .none;
    }
    if (limits.low == 0) return .none;
    // A little hysteresis: a level that wobbles around the limit warns once.
    if (reading.percent > limits.low + 3) {
        state.warned_low = false;
        state.warned_critical = false;
    }
    if (limits.critical > 0 and reading.percent <= limits.critical) {
        if (!state.warned_critical) {
            state.warned_critical = true;
            state.warned_low = true;
            return .critical;
        }
        return .none;
    }
    if (reading.percent <= limits.low and !state.warned_low) {
        state.warned_low = true;
        return .low;
    }
    return .none;
}

/// Whether the action should run now, when the grace period ends: still on the
/// battery and still at or below the critical level.
pub fn shouldAct(state: *State, r: ?Reading, limits: Limits) bool {
    const reading = r orelse return false;
    if (state.acted or limits.action == .none or limits.critical == 0) return false;
    if (!reading.discharging or reading.percent > limits.critical) return false;
    state.acted = true;
    return true;
}

/// Seconds between readings: often enough to catch the critical level, rarely
/// enough not to matter. Closer to a limit, more often.
pub fn pollSeconds(r: ?Reading, limits: Limits) c_uint {
    const reading = r orelse return 120;
    if (!reading.discharging) return 120;
    if (reading.percent <= limits.low + 5) return 15;
    return 60;
}

/// Seconds between the critical warning and the action.
const grace_seconds: c_uint = 30;

fn sysfsRoot() []const u8 {
    return if (glib.getenv("DKDE_SYSFS_ROOT")) |r| std.mem.span(r) else "/sys";
}

fn readSmall(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    const z = allocator.dupeSentinel(u8, path, 0) catch return null;
    defer allocator.free(z);
    var contents: [*]u8 = undefined;
    var len: usize = 0;
    if (glib.fileGetContents(z, &contents, &len, null) == 0) return null;
    defer glib.free(contents);
    return allocator.dupe(u8, contents[0..len]) catch null;
}

/// The first battery that reports a level.
fn readBattery(allocator: std.mem.Allocator) ?Reading {
    var n: u8 = 0;
    while (n < 4) : (n += 1) {
        var cp: [192]u8 = undefined;
        var sp: [192]u8 = undefined;
        const cap = readSmall(allocator, std.fmt.bufPrint(&cp, "{s}/class/power_supply/BAT{d}/capacity", .{ sysfsRoot(), n }) catch continue) orelse continue;
        defer allocator.free(cap);
        const status = readSmall(allocator, std.fmt.bufPrint(&sp, "{s}/class/power_supply/BAT{d}/status", .{ sysfsRoot(), n }) catch continue);
        defer if (status) |st| allocator.free(st);
        return parseReading(cap, status orelse "");
    }
    return null;
}

pub const PowerWatch = struct {
    allocator: std.mem.Allocator,
    config: *common.Config,
    state: State = .{},
    timer: c_uint = 0,
    grace_timer: c_uint = 0,

    pub fn create(allocator: std.mem.Allocator, config: *common.Config) ?*PowerWatch {
        // No battery, no watcher: a desktop machine never wakes this up.
        if (readBattery(allocator) == null) {
            log.debug("no battery; low-battery warnings are off", .{});
            return null;
        }
        const self = allocator.create(PowerWatch) catch return null;
        self.* = .{ .allocator = allocator, .config = config };
        self.check();
        return self;
    }

    pub fn destroy(self: *PowerWatch) void {
        if (self.timer != 0) _ = glib.Source.remove(self.timer);
        if (self.grace_timer != 0) _ = glib.Source.remove(self.grace_timer);
        self.allocator.destroy(self);
    }

    fn limits(self: *PowerWatch) Limits {
        const a = self.allocator;
        const text = self.config.getString(a, "power", "critical-battery-action", "sleep") catch return .{};
        defer a.free(text);
        return .{
            .low = @intCast(std.math.clamp(self.config.getInt("power", "low-battery", 15), 0, 100)),
            .critical = @intCast(std.math.clamp(self.config.getInt("power", "critical-battery", 5), 0, 100)),
            .action = Action.parse(text),
        };
    }

    fn onTimer(data: ?*anyopaque) callconv(.c) c_int {
        const self: *PowerWatch = @ptrCast(@alignCast(data.?));
        self.timer = 0;
        self.check();
        return 0; // one-shot: check() sets the next one from the level
    }

    fn onGrace(data: ?*anyopaque) callconv(.c) c_int {
        const self: *PowerWatch = @ptrCast(@alignCast(data.?));
        self.grace_timer = 0;
        const l = self.limits();
        if (shouldAct(&self.state, readBattery(self.allocator), l)) self.act(l.action);
        return 0;
    }

    fn check(self: *PowerWatch) void {
        const l = self.limits();
        const reading = readBattery(self.allocator);
        switch (decide(&self.state, reading, l)) {
            .none => {},
            .low => {
                var buf: [96]u8 = undefined;
                const body = std.fmt.bufPrintSentinel(&buf, "{d}% left. Plug in the charger.", .{reading.?.percent}, 0) catch "Plug in the charger.";
                log.info("battery low: {d}%", .{reading.?.percent});
                common.notify.send("Battery low", body, "battery-caution");
            },
            .critical => {
                var buf: [160]u8 = undefined;
                const what = switch (l.action) {
                    .none => "Save your work now.",
                    .sleep => "Save your work. The computer goes to sleep in 30 seconds unless you plug in.",
                    .poweroff => "Save your work. The computer shuts down in 30 seconds unless you plug in.",
                };
                const body = std.fmt.bufPrintSentinel(&buf, "{d}% left. {s}", .{ reading.?.percent, what }, 0) catch "Save your work.";
                log.warn("battery critical: {d}%; action {s}", .{ reading.?.percent, @tagName(l.action) });
                // Stays until dismissed: the user may be looking away.
                common.notify.sendTimed("Battery critically low", body, "battery-empty", 0);
                if (l.action != .none and self.grace_timer == 0) self.grace_timer = glib.timeoutAddSeconds(grace_seconds, onGrace, self);
            },
        }
        self.timer = glib.timeoutAddSeconds(pollSeconds(reading, l), onTimer, self);
    }

    fn act(self: *PowerWatch, action: Action) void {
        log.warn("battery still critical; running the action: {s}", .{@tagName(action)});
        switch (action) {
            .none => {},
            .sleep => if (!common.power.run(self.allocator, self.config, "sleep-command", common.power.detectSleep))
                log.warn("no sleep command found; set [menu] sleep-command", .{}),
            .poweroff => _ = common.power.run(self.allocator, self.config, "shutdown-command", struct {
                fn d(_: common.power.Probe) ?[]const u8 {
                    return "poweroff";
                }
            }.d),
        }
    }
};

test "parse a reading" {
    const r = parseReading("14\n", "Discharging\n").?;
    try std.testing.expectEqual(@as(u32, 14), r.percent);
    try std.testing.expect(r.discharging);
    try std.testing.expect(!parseReading("50", "Charging").?.discharging);
    try std.testing.expect(!parseReading("80", "Not charging").?.discharging);
    try std.testing.expect(parseReading("x", "Discharging") == null);
}

test "warns once at low, once at critical" {
    var s: State = .{};
    const l: Limits = .{};
    try std.testing.expectEqual(Event.none, decide(&s, .{ .percent = 40, .discharging = true }, l));
    try std.testing.expectEqual(Event.low, decide(&s, .{ .percent = 15, .discharging = true }, l));
    try std.testing.expectEqual(Event.none, decide(&s, .{ .percent = 14, .discharging = true }, l));
    try std.testing.expectEqual(Event.critical, decide(&s, .{ .percent = 5, .discharging = true }, l));
    try std.testing.expectEqual(Event.none, decide(&s, .{ .percent = 4, .discharging = true }, l));
}

test "dropping straight to critical skips the low warning" {
    var s: State = .{};
    try std.testing.expectEqual(Event.critical, decide(&s, .{ .percent = 4, .discharging = true }, .{}));
    try std.testing.expectEqual(Event.none, decide(&s, .{ .percent = 4, .discharging = true }, .{}));
}

test "plugging in resets, and a wobble around the limit warns once" {
    var s: State = .{};
    const l: Limits = .{};
    try std.testing.expectEqual(Event.low, decide(&s, .{ .percent = 15, .discharging = true }, l));
    // 16, 17: still within the hysteresis band, no second warning.
    try std.testing.expectEqual(Event.none, decide(&s, .{ .percent = 17, .discharging = true }, l));
    try std.testing.expectEqual(Event.none, decide(&s, .{ .percent = 15, .discharging = true }, l));
    // Plugged in, then unplugged at 15 again: a new discharge, a new warning.
    try std.testing.expectEqual(Event.none, decide(&s, .{ .percent = 16, .discharging = false }, l));
    try std.testing.expectEqual(Event.low, decide(&s, .{ .percent = 15, .discharging = true }, l));
}

test "no battery, or warnings off" {
    var s: State = .{};
    try std.testing.expectEqual(Event.none, decide(&s, null, .{}));
    try std.testing.expectEqual(Event.none, decide(&s, .{ .percent = 3, .discharging = true }, .{ .low = 0 }));
}

test "the action runs once, only if still critical and on the battery" {
    var s: State = .{};
    const l: Limits = .{};
    try std.testing.expect(!shouldAct(&s, .{ .percent = 4, .discharging = false }, l)); // plugged in during the grace period
    try std.testing.expect(!shouldAct(&s, .{ .percent = 9, .discharging = true }, l)); // charged a little
    try std.testing.expect(shouldAct(&s, .{ .percent = 4, .discharging = true }, l));
    try std.testing.expect(!shouldAct(&s, .{ .percent = 3, .discharging = true }, l)); // not twice
    // Back on mains power clears it.
    _ = decide(&s, .{ .percent = 10, .discharging = false }, l);
    try std.testing.expect(shouldAct(&s, .{ .percent = 4, .discharging = true }, l));
    try std.testing.expect(!shouldAct(&s, .{ .percent = 4, .discharging = true }, .{ .action = .none }));
}

test "poll faster near the limit" {
    try std.testing.expectEqual(@as(c_uint, 120), pollSeconds(null, .{}));
    try std.testing.expectEqual(@as(c_uint, 120), pollSeconds(.{ .percent = 50, .discharging = false }, .{}));
    try std.testing.expectEqual(@as(c_uint, 60), pollSeconds(.{ .percent = 50, .discharging = true }, .{}));
    try std.testing.expectEqual(@as(c_uint, 15), pollSeconds(.{ .percent = 19, .discharging = true }, .{}));
}

test "Action.parse" {
    try std.testing.expectEqual(Action.none, Action.parse("none"));
    try std.testing.expectEqual(Action.poweroff, Action.parse("PowerOff"));
    try std.testing.expectEqual(Action.sleep, Action.parse("anything else"));
}
