//! "Go to": a small window to jump to any date, past or future, by civil date,
//! by Rosquin day code, or by Rosquin year and day of the year, and to step to
//! the next or previous Leap Day or Year-End Day.

const std = @import("std");
const glib = @import("glib2");
const gtk = @import("gtk4");
const common = @import("common");
const main = @import("main.zig");

const rosquin = common.rosquin;
const civil = common.civil;
const Date = civil.Date;
const App = main.CalendarApp;

const Dialog = struct {
    app: *App,
    window: *gtk.Window,
    calendar: *gtk.Calendar,
    code: *gtk.SpinButton,
    year: *gtk.SpinButton,
    doy: *gtk.SpinButton,
    status: *gtk.Label,

    fn say(self: *Dialog, comptime fmt: []const u8, args: anytype) void {
        var buf: [200]u8 = undefined;
        const text = std.fmt.bufPrintSentinel(&buf, fmt, args, 0) catch return;
        self.status.setText(text.ptr);
    }

    fn go(self: *Dialog, date: Date) void {
        self.app.selectDate(date);
        self.syncFields(date);
    }

    /// Shows `date` in the other fields, without those fields jumping again.
    fn syncFields(self: *Dialog, date: Date) void {
        self.code.setValue(@floatFromInt(rosquin.dayCode(date)));
        self.year.setValue(@floatFromInt(rosquin.fromCivil(.weeks, date).year));
        self.doy.setValue(@floatFromInt(rosquin.dayOfYear(date)));
        var buf: [160]u8 = undefined;
        const text = std.fmt.bufPrintSentinel(&buf, "{d}-{d:0>2}-{d:0>2}: day code {d}, day {d} of Year {d}", .{
            date.year, date.month, date.day, rosquin.dayCode(date), rosquin.dayOfYear(date), rosquin.fromCivil(.weeks, date).year,
        }, 0) catch return;
        self.status.setText(text.ptr);
    }
};

fn onDay(cal: *gtk.Calendar, d: *Dialog) callconv(.c) void {
    const dt = cal.getDate();
    defer dt.unref();
    d.go(.{ .year = dt.getYear(), .month = @intCast(dt.getMonth()), .day = @intCast(dt.getDayOfMonth()) });
}

fn onCode(_: *gtk.Button, d: *Dialog) callconv(.c) void {
    const code: i64 = d.code.getValueAsInt();
    d.go(Date.fromDays(code - 1 + civil.daysFromCivil(rosquin.epoch_year, 9, 21)));
}

fn onYear(_: *gtk.Button, d: *Dialog) callconv(.c) void {
    const year: i32 = d.year.getValueAsInt();
    const doy: u16 = @intCast(d.doy.getValueAsInt());
    if (doy == 365) return d.go(rosquin.toCivil(.weeks, .{ .year = year, .month = 0, .day = rosquin.year_end_day }));
    if (doy == 366) {
        if (!rosquin.hasLeapDay(year)) return d.say("Year {d} has no Leap Day (it has 365 days).", .{year});
        return d.go(rosquin.toCivil(.weeks, .{ .year = year, .month = 0, .day = rosquin.leap_day }));
    }
    d.go(rosquin.toCivil(.weeks, .{ .year = year, .month = 1, .day = doy }));
}

/// The first Leap Day or Year-End Day after (or before) the selected day.
fn step(d: *Dialog, day: u16, forward: bool) void {
    const here = d.app.selected;
    const year = rosquin.fromCivil(.weeks, here).year;
    var best: ?Date = null;
    var y: i32 = year - 9;
    while (y <= year + 9) : (y += 1) {
        if (day == rosquin.leap_day and !rosquin.hasLeapDay(y)) continue;
        const date = rosquin.toCivil(.weeks, .{ .year = y, .month = 0, .day = day });
        const n = date.days();
        if (forward) {
            if (n > here.days() and (best == null or n < best.?.days())) best = date;
        } else {
            if (n < here.days() and (best == null or n > best.?.days())) best = date;
        }
    }
    if (best) |b| d.go(b);
}

fn onNextLeap(_: *gtk.Button, d: *Dialog) callconv(.c) void {
    step(d, rosquin.leap_day, true);
}
fn onPrevLeap(_: *gtk.Button, d: *Dialog) callconv(.c) void {
    step(d, rosquin.leap_day, false);
}
fn onNextEnd(_: *gtk.Button, d: *Dialog) callconv(.c) void {
    step(d, rosquin.year_end_day, true);
}
fn onPrevEnd(_: *gtk.Button, d: *Dialog) callconv(.c) void {
    step(d, rosquin.year_end_day, false);
}

fn onDestroy(_: *gtk.Window, d: *Dialog) callconv(.c) void {
    d.app.allocator.destroy(d);
}

fn row(label: [:0]const u8, widget: *gtk.Widget, button: ?*gtk.Button) *gtk.Box {
    const box = gtk.Box.new(.horizontal, 8);
    const l = gtk.Label.new(label.ptr);
    l.setXalign(0);
    l.as(gtk.Widget).setSizeRequest(130, -1);
    box.append(l.as(gtk.Widget));
    widget.setHexpand(1);
    box.append(widget);
    if (button) |b| box.append(b.as(gtk.Widget));
    return box;
}

pub fn open(app: *App) void {
    const d = app.allocator.create(Dialog) catch return;
    const sel = app.selected;
    d.* = .{
        .app = app,
        .window = gtk.Window.new(),
        .calendar = gtk.Calendar.new(),
        .code = gtk.SpinButton.newWithRange(1, 999999, 1),
        .year = gtk.SpinButton.newWithRange(0, 9999, 1),
        .doy = gtk.SpinButton.newWithRange(1, 366, 1),
        .status = gtk.Label.new(""),
    };
    const w = d.window;
    w.setTitle(common.tr("Go to date"));
    w.setModal(0);
    w.setTransientFor(app.window.as(gtk.Window));
    w.setResizable(0);
    _ = gtk.Widget.signals.destroy.connect(w, *Dialog, &onDestroy, d, .{});

    const box = gtk.Box.new(.vertical, 8);
    box.as(gtk.Widget).setMarginTop(12);
    box.as(gtk.Widget).setMarginBottom(12);
    box.as(gtk.Widget).setMarginStart(12);
    box.as(gtk.Widget).setMarginEnd(12);

    // The civil date: the calendar has year buttons, so far dates are a few clicks.
    if (glib.DateTime.newLocal(sel.year, sel.month, sel.day, 0, 0, 0)) |dt| {
        defer dt.unref();
        d.calendar.selectDay(dt);
    }
    d.syncFields(sel);
    _ = gtk.Calendar.signals.day_selected.connect(d.calendar, *Dialog, &onDay, d, .{});
    box.append(d.calendar.as(gtk.Widget));

    const code_go = gtk.Button.newWithLabel(common.tr("Go"));
    _ = gtk.Button.signals.clicked.connect(code_go, *Dialog, &onCode, d, .{});
    box.append(row("Rosquin day code", d.code.as(gtk.Widget), code_go).as(gtk.Widget));

    const year_go = gtk.Button.newWithLabel(common.tr("Go"));
    _ = gtk.Button.signals.clicked.connect(year_go, *Dialog, &onYear, d, .{});
    box.append(row("Rosquin year", d.year.as(gtk.Widget), null).as(gtk.Widget));
    box.append(row("Day of the year", d.doy.as(gtk.Widget), year_go).as(gtk.Widget));

    const leaps = gtk.Box.new(.horizontal, 8);
    const prev_leap = gtk.Button.newWithLabel(common.tr("\u{2190} Leap Day"));
    const next_leap = gtk.Button.newWithLabel(common.tr("Leap Day \u{2192}"));
    const prev_end = gtk.Button.newWithLabel(common.tr("\u{2190} Year-End Day"));
    const next_end = gtk.Button.newWithLabel(common.tr("Year-End Day \u{2192}"));
    _ = gtk.Button.signals.clicked.connect(prev_leap, *Dialog, &onPrevLeap, d, .{});
    _ = gtk.Button.signals.clicked.connect(next_leap, *Dialog, &onNextLeap, d, .{});
    _ = gtk.Button.signals.clicked.connect(prev_end, *Dialog, &onPrevEnd, d, .{});
    _ = gtk.Button.signals.clicked.connect(next_end, *Dialog, &onNextEnd, d, .{});
    inline for (.{ prev_leap, next_leap, prev_end, next_end }) |b| {
        b.as(gtk.Widget).setHexpand(1);
        leaps.append(b.as(gtk.Widget));
    }
    box.append(leaps.as(gtk.Widget));

    d.status.setXalign(0);
    d.status.setWrap(1);
    d.status.as(gtk.Widget).addCssClass("dim-label");
    box.append(d.status.as(gtk.Widget));

    w.setChild(box.as(gtk.Widget));
    w.present();
}
