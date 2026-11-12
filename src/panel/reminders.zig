//! Calendar reminders (SPEC.md 5.6). dkde-calendar stores its events in
//! `calendar.toml`; the panel is always running, so it keeps one timer set for
//! the next reminder and sends a desktop notification when it falls due. No
//! cron or init-system timer is involved, and nothing wakes while no reminder
//! is pending.

const std = @import("std");
const glib = @import("glib2");
const common = @import("common");

const events = common.events;
const feeds = common.feeds;
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
    /// dkde.toml: the optional online calendars (Settings, Online accounts).
    shared: common.Config,
    accounts: feeds.Accounts,
    list: events.List,
    timer: c_uint = 0,
    /// Everything due up to this minute has been sent.
    checked: i64,

    pub fn create(allocator: std.mem.Allocator) !*Reminders {
        const self = try allocator.create(Reminders);
        errdefer allocator.destroy(self);
        var config = try common.Config.load(allocator, "calendar.toml");
        errdefer config.deinit();
        var shared = try common.Config.load(allocator, "dkde.toml");
        errdefer shared.deinit();
        var accounts = try feeds.loadAccounts(allocator, &shared);
        errdefer accounts.deinit();
        const list = try feeds.loadAll(allocator, &config, accounts.items, null);
        self.* = .{ .allocator = allocator, .config = config, .shared = shared, .accounts = accounts, .list = list, .checked = nowMinutes().minute };
        self.config.watch(Reminders, onFileChanged, self) catch |err|
            log.warn("calendar not watched: {s}", .{@errorName(err)});
        // An account switched on or off in Settings changes the reminders too.
        self.shared.watch(Reminders, onFileChanged, self) catch |err|
            log.warn("accounts not watched: {s}", .{@errorName(err)});
        self.arm();
        return self;
    }

    pub fn destroy(self: *Reminders) void {
        if (self.timer != 0) _ = glib.Source.remove(self.timer);
        self.list.deinit();
        self.accounts.deinit();
        self.shared.deinit();
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

    /// The calendar app changed its file, or an online calendar was updated or
    /// switched (the files have reloaded already).
    fn onFileChanged(self: *Reminders) void {
        if (feeds.loadAccounts(self.allocator, &self.shared)) |accounts| {
            self.accounts.deinit();
            self.accounts = accounts;
        } else |_| {}
        const fresh = feeds.loadAll(self.allocator, &self.config, self.accounts.items, null) catch |err| {
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
        const twelve = self.config.getBool("view", "twelve-hour", true);
        for (fires) |f| send(&self.list.items[f.event], f.start, now, twelve);
        self.checked = now;
    }

    fn send(ev: *const events.Event, start: events.Date, now_minute: i64, twelve: bool) void {
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
            std.fmt.bufPrint(&when_buf, "{s} at {s}", .{ when, events.formatClock(&tb, ev.start, twelve) }) catch "";

        var body_buf: [512]u8 = undefined;
        const body = if (ev.location.len > 0)
            std.fmt.bufPrintSentinel(&body_buf, "{s}\n{s}", .{ when_text, ev.location }, 0) catch ""
        else
            std.fmt.bufPrintSentinel(&body_buf, "{s}", .{when_text}, 0) catch "";
        common.notify.send(title, body, "x-office-calendar");
    }
};
