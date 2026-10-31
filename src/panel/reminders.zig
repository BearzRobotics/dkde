//! Calendar reminders (SPEC.md 5.6). dkde-calendar stores its events in
//! `calendar.conf`; the panel is always running, so it keeps one timer set for
//! the next reminder and sends a desktop notification when it falls due. No
//! cron or init-system timer is involved, and nothing wakes while no reminder
//! is pending.

const std = @import("std");
const glib = @import("glib2");
const common = @import("common");

const events = common.events;
const civil = common.civil;
const log = std.log.scoped(.reminders);

/// The longest the timer sleeps. Timers do not count time spent suspended, so
/// waking now and then and comparing with the wall clock catches up after a resume.
const max_sleep_seconds: i64 = 300;

/// A reminder that fell due this long ago or less is still worth showing.
const grace_minutes: i64 = 12 * 60;

pub const Reminders = struct {
    allocator: std.mem.Allocator,
    config: common.Config,
    list: events.List,
    timer: c_uint = 0,
    /// Everything due up to this minute has been sent.
    checked: i64,

    pub fn create(allocator: std.mem.Allocator) !*Reminders {
        const self = try allocator.create(Reminders);
        errdefer allocator.destroy(self);
        var config = try common.Config.load(allocator, "calendar.conf");
        errdefer config.deinit();
        const list = try events.load(allocator, &config);
        self.* = .{ .allocator = allocator, .config = config, .list = list, .checked = nowMinutes().minute };
        self.config.watch(Reminders, onFileChanged, self) catch |err|
            log.warn("calendar not watched: {s}", .{@errorName(err)});
        self.arm();
        return self;
    }

    pub fn destroy(self: *Reminders) void {
        if (self.timer != 0) _ = glib.Source.remove(self.timer);
        self.list.deinit();
        self.config.deinit();
        self.allocator.destroy(self);
    }

    const Now = struct { minute: i64, second: i64 };

    fn nowMinutes() Now {
        const dt = glib.DateTime.newNowLocal() orelse return .{ .minute = 0, .second = 0 };
        defer dt.unref();
        const days = civil.daysFromCivil(dt.getYear(), @intCast(dt.getMonth()), @intCast(dt.getDayOfMonth()));
        return .{ .minute = days * 1440 + dt.getHour() * 60 + dt.getMinute(), .second = dt.getSecond() };
    }

    /// The calendar app changed the file (config has reloaded already).
    fn onFileChanged(self: *Reminders) void {
        const fresh = events.load(self.allocator, &self.config) catch |err| {
            log.warn("cannot read the events: {s}", .{@errorName(err)});
            return;
        };
        self.list.deinit();
        self.list = fresh;
        self.arm();
    }

    fn arm(self: *Reminders) void {
        if (self.timer != 0) {
            _ = glib.Source.remove(self.timer);
            self.timer = 0;
        }
        const next = events.nextFire(self.list.items, self.checked, 400) orelse return;
        const now = nowMinutes();
        var wait = (next - now.minute) * 60 - now.second + 1;
        wait = std.math.clamp(wait, 1, max_sleep_seconds);
        self.timer = glib.timeoutAddSeconds(@intCast(wait), onTimer, self);
    }

    fn onTimer(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Reminders = @ptrCast(@alignCast(data.?));
        self.timer = 0; // returning false removes this source
        self.fireDue();
        self.arm();
        return 0;
    }

    fn fireDue(self: *Reminders) void {
        const now = nowMinutes().minute;
        const from = @max(self.checked, now - grace_minutes);
        const fires = events.firesBetween(self.allocator, self.list.items, from, now) catch return;
        defer self.allocator.free(fires);
        for (fires) |f| send(&self.list.items[f.event], f.start, now);
        self.checked = now;
    }

    fn send(ev: *const events.Event, start: events.Date, now_minute: i64) void {
        var title_buf: [256]u8 = undefined;
        const title = std.fmt.bufPrintSentinel(&title_buf, "{s}", .{if (ev.title.len > 0) ev.title else "Calendar event"}, 0) catch "Calendar event";

        var when_buf: [64]u8 = undefined;
        var tb: [8]u8 = undefined;
        const today = @divFloor(now_minute, 1440);
        const day_word: []const u8 = switch (start.days() - today) {
            0 => "Today",
            1 => "Tomorrow",
            else => "",
        };
        var db: [16]u8 = undefined;
        const when: []const u8 = if (day_word.len > 0) day_word else events.formatDate(&db, start);
        const when_text = if (ev.all_day)
            std.fmt.bufPrint(&when_buf, "{s}, all day", .{when}) catch ""
        else
            std.fmt.bufPrint(&when_buf, "{s} at {s}", .{ when, events.formatTime(&tb, ev.start) }) catch "";

        var body_buf: [512]u8 = undefined;
        const body = if (ev.location.len > 0)
            std.fmt.bufPrintSentinel(&body_buf, "{s}\n{s}", .{ when_text, ev.location }, 0) catch ""
        else
            std.fmt.bufPrintSentinel(&body_buf, "{s}", .{when_text}, 0) catch "";
        common.notify.send(title, body, "x-office-calendar");
    }
};
