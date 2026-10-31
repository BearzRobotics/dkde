//! dkde-clock: stopwatch, countdown timer and alarms (SPEC.md 5.6). Timers and
//! alarms run only while the app is open; there is no background service.

const std = @import("std");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

const pure = @import("pure.zig");

pub const std_options: std.Options = .{ .logFn = common.log.logFn, .log_level = .debug };

fn nowMs() u64 {
    return @intCast(@divTrunc(glib.getMonotonicTime(), 1000));
}

const Clock = struct {
    allocator: std.mem.Allocator,
    window: *gtk.ApplicationWindow,

    // stopwatch
    sw_label: *gtk.Label,
    sw_start_button: *gtk.Button,
    sw_laps: *gtk.Box,
    sw_running: bool = false,
    sw_started_at: u64 = 0,
    sw_accumulated: u64 = 0,
    sw_last_lap: u64 = 0,
    sw_laps_count: usize = 0,

    // timer
    tm_label: *gtk.Label,
    tm_minutes: *gtk.SpinButton,
    tm_seconds: *gtk.SpinButton,
    tm_button: *gtk.Button,
    tm_running: bool = false,
    tm_end_at: u64 = 0,

    // alarm
    al_hour: *gtk.SpinButton,
    al_minute: *gtk.SpinButton,
    al_name: *gtk.Entry,
    al_status: *gtk.Label,
    al_source: c_uint = 0,

    tick_source: c_uint = 0,

    pub fn create(allocator: std.mem.Allocator, app: *gtk.Application) !*Clock {
        const self = try allocator.create(Clock);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .window = gtk.ApplicationWindow.new(app),
            .sw_label = gtk.Label.new("00:00.00"),
            .sw_start_button = gtk.Button.newWithLabel(common.tr("Start")),
            .sw_laps = gtk.Box.new(.vertical, 2),
            .tm_label = gtk.Label.new("05:00"),
            .tm_minutes = gtk.SpinButton.newWithRange(0, 999, 1),
            .tm_seconds = gtk.SpinButton.newWithRange(0, 59, 1),
            .tm_button = gtk.Button.newWithLabel(common.tr("Start")),
            .al_hour = gtk.SpinButton.newWithRange(0, 23, 1),
            .al_minute = gtk.SpinButton.newWithRange(0, 59, 1),
            .al_name = gtk.Entry.new(),
            .al_status = gtk.Label.new(""),
        };
        const window = self.window.as(gtk.Window);
        window.setTitle(common.tr("Clock"));
        window.setDefaultSize(440, 440);
        self.window.as(gtk.Widget).addCssClass("dkde");
        _ = common.header.create(window, "preferences-system-time", true);

        const notebook = gtk.Notebook.new();
        _ = notebook.appendPage(self.stopwatchPage().as(gtk.Widget), gtk.Label.new(common.tr("Stopwatch")).as(gtk.Widget));
        _ = notebook.appendPage(self.timerPage().as(gtk.Widget), gtk.Label.new(common.tr("Timer")).as(gtk.Widget));
        _ = notebook.appendPage(self.alarmPage().as(gtk.Widget), gtk.Label.new(common.tr("Alarm")).as(gtk.Widget));
        window.setChild(notebook.as(gtk.Widget));

        _ = gtk.Widget.signals.destroy.connect(self.window, *Clock, &onDestroy, self, .{});
        return self;
    }

    pub fn present(self: *Clock) void {
        self.window.as(gtk.Window).present();
    }

    fn onDestroy(_: *gtk.ApplicationWindow, self: *Clock) callconv(.c) void {
        if (self.tick_source != 0) _ = glib.Source.remove(self.tick_source);
        if (self.al_source != 0) _ = glib.Source.remove(self.al_source);
        self.allocator.destroy(self);
    }

    fn page() *gtk.Box {
        const box = gtk.Box.new(.vertical, 12);
        box.as(gtk.Widget).setMarginTop(20);
        box.as(gtk.Widget).setMarginBottom(20);
        box.as(gtk.Widget).setMarginStart(20);
        box.as(gtk.Widget).setMarginEnd(20);
        return box;
    }

    fn bigLabel(label: *gtk.Label) void {
        label.as(gtk.Widget).addCssClass("dkde-clock-big");
        label.as(gtk.Widget).setMarginTop(12);
        label.as(gtk.Widget).setMarginBottom(12);
    }

    // ---- stopwatch ------------------------------------------------------------------------

    fn stopwatchPage(self: *Clock) *gtk.Box {
        const box = page();
        bigLabel(self.sw_label);
        box.append(self.sw_label.as(gtk.Widget));
        const buttons = gtk.Box.new(.horizontal, 8);
        buttons.as(gtk.Widget).setHalign(.center);
        self.sw_start_button.as(gtk.Widget).addCssClass("suggested-action");
        _ = gtk.Button.signals.clicked.connect(self.sw_start_button, *Clock, &onSwStart, self, .{});
        const lap = gtk.Button.newWithLabel(common.tr("Lap"));
        _ = gtk.Button.signals.clicked.connect(lap, *Clock, &onSwLap, self, .{});
        const reset = gtk.Button.newWithLabel(common.tr("Reset"));
        _ = gtk.Button.signals.clicked.connect(reset, *Clock, &onSwReset, self, .{});
        buttons.append(self.sw_start_button.as(gtk.Widget));
        buttons.append(lap.as(gtk.Widget));
        buttons.append(reset.as(gtk.Widget));
        box.append(buttons.as(gtk.Widget));
        const scroller = gtk.ScrolledWindow.new();
        scroller.setChild(self.sw_laps.as(gtk.Widget));
        scroller.as(gtk.Widget).setVexpand(1);
        box.append(scroller.as(gtk.Widget));
        return box;
    }

    /// The 50 ms display tick runs only while the stopwatch or timer is running,
    /// so an idle window does not wake the CPU.
    fn ensureTick(self: *Clock) void {
        if (self.tick_source == 0) self.tick_source = glib.timeoutAdd(50, onTick, self);
    }

    fn swElapsed(self: *const Clock) u64 {
        return self.sw_accumulated + if (self.sw_running) nowMs() - self.sw_started_at else 0;
    }

    fn onSwStart(_: *gtk.Button, self: *Clock) callconv(.c) void {
        if (self.sw_running) {
            self.sw_accumulated += nowMs() - self.sw_started_at;
            self.sw_running = false;
            self.sw_start_button.setLabel(common.tr("Start"));
        } else {
            self.sw_started_at = nowMs();
            self.sw_running = true;
            self.ensureTick();
            self.sw_start_button.setLabel(common.tr("Stop"));
        }
    }

    fn onSwLap(_: *gtk.Button, self: *Clock) callconv(.c) void {
        if (!self.sw_running) return;
        const total = self.swElapsed();
        var a: [32]u8 = undefined;
        var b: [32]u8 = undefined;
        var line: [96]u8 = undefined;
        self.sw_laps_count += 1;
        const text = std.fmt.bufPrintSentinel(&line, "Lap {d}     {s}     ({s})", .{
            self.sw_laps_count,
            pure.formatElapsed(&a, total - self.sw_last_lap),
            pure.formatElapsed(&b, total),
        }, 0) catch return;
        self.sw_last_lap = total;
        const label = gtk.Label.new(text);
        label.setXalign(0);
        self.sw_laps.prepend(label.as(gtk.Widget));
    }

    fn onSwReset(_: *gtk.Button, self: *Clock) callconv(.c) void {
        self.sw_running = false;
        self.sw_accumulated = 0;
        self.sw_last_lap = 0;
        self.sw_laps_count = 0;
        self.sw_start_button.setLabel(common.tr("Start"));
        while (self.sw_laps.as(gtk.Widget).getFirstChild()) |child| self.sw_laps.remove(child);
    }

    // ---- timer -------------------------------------------------------------------------------

    fn timerPage(self: *Clock) *gtk.Box {
        const box = page();
        bigLabel(self.tm_label);
        box.append(self.tm_label.as(gtk.Widget));
        self.tm_minutes.setValue(5);
        const row = gtk.Box.new(.horizontal, 8);
        row.as(gtk.Widget).setHalign(.center);
        row.append(self.tm_minutes.as(gtk.Widget));
        row.append(gtk.Label.new(common.tr("min")).as(gtk.Widget));
        row.append(self.tm_seconds.as(gtk.Widget));
        row.append(gtk.Label.new(common.tr("sec")).as(gtk.Widget));
        box.append(row.as(gtk.Widget));
        _ = gtk.SpinButton.signals.value_changed.connect(self.tm_minutes, *Clock, &onTimerSet, self, .{});
        _ = gtk.SpinButton.signals.value_changed.connect(self.tm_seconds, *Clock, &onTimerSet, self, .{});
        self.tm_button.as(gtk.Widget).addCssClass("suggested-action");
        self.tm_button.as(gtk.Widget).setHalign(.center);
        _ = gtk.Button.signals.clicked.connect(self.tm_button, *Clock, &onTimerButton, self, .{});
        box.append(self.tm_button.as(gtk.Widget));
        return box;
    }

    fn timerTotalMs(self: *const Clock) u64 {
        const m: u64 = @intCast(self.tm_minutes.getValueAsInt());
        const s: u64 = @intCast(self.tm_seconds.getValueAsInt());
        return (m * 60 + s) * 1000;
    }

    fn onTimerSet(_: *gtk.SpinButton, self: *Clock) callconv(.c) void {
        if (self.tm_running) return;
        var buf: [32]u8 = undefined;
        var z: [40]u8 = undefined;
        self.tm_label.setText(std.fmt.bufPrintSentinel(&z, "{s}", .{pure.formatCountdown(&buf, self.timerTotalMs())}, 0) catch "");
    }

    fn onTimerButton(_: *gtk.Button, self: *Clock) callconv(.c) void {
        if (self.tm_running) {
            self.tm_running = false;
            self.tm_button.setLabel(common.tr("Start"));
            return onTimerSet(self.tm_minutes, self);
        }
        if (self.timerTotalMs() == 0) return;
        self.tm_end_at = nowMs() + self.timerTotalMs();
        self.tm_running = true;
        self.ensureTick();
        self.tm_button.setLabel(common.tr("Cancel"));
    }

    fn timerFinished(self: *Clock) void {
        self.tm_running = false;
        self.tm_button.setLabel(common.tr("Start"));
        onTimerSet(self.tm_minutes, self);
        common.notify.send("Timer finished", "The countdown has ended.", "alarm-symbolic");
        self.window.as(gtk.Widget).getDisplay().beep();
        self.window.as(gtk.Window).present();
    }

    // ---- alarm ------------------------------------------------------------------------------

    fn alarmPage(self: *Clock) *gtk.Box {
        const box = page();
        const label = gtk.Label.new(common.tr("Alarm at"));
        label.setXalign(0);
        box.append(label.as(gtk.Widget));
        self.al_hour.setValue(7);
        const row = gtk.Box.new(.horizontal, 8);
        row.append(self.al_hour.as(gtk.Widget));
        row.append(gtk.Label.new(":").as(gtk.Widget));
        row.append(self.al_minute.as(gtk.Widget));
        box.append(row.as(gtk.Widget));
        self.al_name.setPlaceholderText(common.tr("Label (optional)"));
        box.append(self.al_name.as(gtk.Widget));
        const set = gtk.Button.newWithLabel(common.tr("Set alarm"));
        set.as(gtk.Widget).addCssClass("suggested-action");
        set.as(gtk.Widget).setHalign(.start);
        _ = gtk.Button.signals.clicked.connect(set, *Clock, &onAlarmSet, self, .{});
        box.append(set.as(gtk.Widget));
        self.al_status.setXalign(0);
        self.al_status.setWrap(1);
        self.al_status.as(gtk.Widget).addCssClass("dim-label");
        box.append(self.al_status.as(gtk.Widget));
        const note = gtk.Label.new(common.tr("Alarms only ring while this window is open."));
        note.setXalign(0);
        note.as(gtk.Widget).addCssClass("dim-label");
        box.append(note.as(gtk.Widget));
        return box;
    }

    fn onAlarmSet(_: *gtk.Button, self: *Clock) callconv(.c) void {
        if (self.al_source != 0) {
            _ = glib.Source.remove(self.al_source);
            self.al_source = 0;
        }
        const now = glib.DateTime.newNowLocal() orelse return;
        defer now.unref();
        const now_s: u32 = @intCast(now.getHour() * 3600 + now.getMinute() * 60 + now.getSecond());
        const target: u32 = @intCast(self.al_hour.getValueAsInt() * 3600 + self.al_minute.getValueAsInt() * 60);
        const wait = pure.secondsUntil(now_s, target);
        self.al_source = glib.timeoutAddSeconds(wait, onAlarmRings, self);
        var buf: [96]u8 = undefined;
        self.al_status.setText(std.fmt.bufPrintSentinel(&buf, "Alarm set for {d:0>2}:{d:0>2}, in {d} h {d} min.", .{
            @as(u32, @intCast(self.al_hour.getValueAsInt())),
            @as(u32, @intCast(self.al_minute.getValueAsInt())),
            wait / 3600,
            wait % 3600 / 60,
        }, 0) catch "");
    }

    fn onAlarmRings(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Clock = @ptrCast(@alignCast(data.?));
        self.al_source = 0;
        const text = std.mem.span(self.al_name.as(gtk.Editable).getText());
        var buf: [160]u8 = undefined;
        const body = std.fmt.bufPrintSentinel(&buf, "{s}", .{if (text.len > 0) text else "Time is up."}, 0) catch "Time is up.";
        common.notify.send("Alarm", body, "alarm-symbolic");
        self.window.as(gtk.Widget).getDisplay().beep();
        self.window.as(gtk.Window).present();
        self.al_status.setText(common.tr("The alarm rang."));
        return 0;
    }

    // ---- ticking -----------------------------------------------------------------------------

    fn onTick(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Clock = @ptrCast(@alignCast(data.?));
        var buf: [32]u8 = undefined;
        var z: [40]u8 = undefined;
        if (self.sw_running) {
            self.sw_label.setText(std.fmt.bufPrintSentinel(&z, "{s}", .{pure.formatElapsed(&buf, self.swElapsed())}, 0) catch "");
        }
        if (self.tm_running) {
            const now = nowMs();
            if (now >= self.tm_end_at) {
                self.timerFinished();
            } else {
                self.tm_label.setText(std.fmt.bufPrintSentinel(&z, "{s}", .{pure.formatCountdown(&buf, self.tm_end_at - now)}, 0) catch "");
            }
        }
        if (!self.sw_running and !self.tm_running) {
            self.tick_source = 0;
            return 0;
        }
        return 1;
    }
};

pub fn main(init: std.process.Init.Minimal) !void {
    try common.runapp.run("org.dkde.clock", Clock, init);
}

test {
    _ = @import("pure.zig");
}
