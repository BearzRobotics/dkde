//! dkde-calendar: a month calendar with a note for any day (SPEC.md 5.6). Notes
//! are saved as you type in `~/.config/dkde/calendar.conf`, one key per date.

const std = @import("std");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

pub const std_options: std.Options = .{ .logFn = common.log.logFn, .log_level = .debug };

/// "2026-10-31", the key a day's note is stored under.
pub fn dateKey(buf: []u8, year: i32, month: u32, day: u32) []const u8 {
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u32, @intCast(year)), month, day }) catch "";
}

const CalendarApp = struct {
    allocator: std.mem.Allocator,
    window: *gtk.ApplicationWindow,
    calendar: *gtk.Calendar,
    notes: common.Config,
    text: *gtk.TextView,
    heading: *gtk.Label,
    /// The key of the note being edited; empty before the first selection.
    key: [16]u8 = undefined,
    key_len: usize = 0,
    loading: bool = false,
    save_source: c_uint = 0,

    pub fn create(allocator: std.mem.Allocator, app: *gtk.Application) !*CalendarApp {
        const self = try allocator.create(CalendarApp);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .window = gtk.ApplicationWindow.new(app),
            .calendar = gtk.Calendar.new(),
            .notes = try common.Config.load(allocator, "calendar.conf"),
            .text = gtk.TextView.new(),
            .heading = gtk.Label.new(""),
        };
        const window = self.window.as(gtk.Window);
        window.setTitle(common.tr("Calendar"));
        window.setDefaultSize(720, 420);
        self.window.as(gtk.Widget).addCssClass("dkde");
        _ = common.header.create(window, "x-office-calendar", true);

        self.calendar.setShowWeekNumbers(1);
        self.calendar.as(gtk.Widget).setVexpand(1);
        _ = gtk.Calendar.signals.day_selected.connect(self.calendar, *CalendarApp, &onDay, self, .{});
        _ = gtk.Calendar.signals.next_month.connect(self.calendar, *CalendarApp, &onMonth, self, .{});
        _ = gtk.Calendar.signals.prev_month.connect(self.calendar, *CalendarApp, &onMonth, self, .{});
        _ = gtk.Calendar.signals.next_year.connect(self.calendar, *CalendarApp, &onMonth, self, .{});
        _ = gtk.Calendar.signals.prev_year.connect(self.calendar, *CalendarApp, &onMonth, self, .{});

        self.heading.setXalign(0);
        self.heading.as(gtk.Widget).addCssClass("heading");
        self.text.setWrapMode(.word_char);
        self.text.as(gtk.Widget).setVexpand(1);
        self.text.as(gtk.Widget).addCssClass("dkde-calendar-notes");
        self.text.setLeftMargin(8);
        self.text.setTopMargin(8);
        _ = gtk.TextBuffer.signals.changed.connect(self.text.getBuffer(), *CalendarApp, &onEdited, self, .{});
        const scroller = gtk.ScrolledWindow.new();
        scroller.setChild(self.text.as(gtk.Widget));
        scroller.as(gtk.Widget).setVexpand(1);

        const right = gtk.Box.new(.vertical, 6);
        right.as(gtk.Widget).setHexpand(1);
        right.append(self.heading.as(gtk.Widget));
        right.append(scroller.as(gtk.Widget));
        const today = gtk.Button.newWithLabel(common.tr("Today"));
        today.as(gtk.Widget).setHalign(.start);
        _ = gtk.Button.signals.clicked.connect(today, *CalendarApp, &onToday, self, .{});

        const left = gtk.Box.new(.vertical, 6);
        left.append(self.calendar.as(gtk.Widget));
        left.append(today.as(gtk.Widget));

        const body = gtk.Box.new(.horizontal, 16);
        body.as(gtk.Widget).setMarginTop(12);
        body.as(gtk.Widget).setMarginBottom(12);
        body.as(gtk.Widget).setMarginStart(12);
        body.as(gtk.Widget).setMarginEnd(12);
        body.append(left.as(gtk.Widget));
        body.append(right.as(gtk.Widget));
        window.setChild(body.as(gtk.Widget));

        _ = gtk.Widget.signals.destroy.connect(self.window, *CalendarApp, &onDestroy, self, .{});
        self.markNoteDays();
        self.showDay();
        return self;
    }

    pub fn present(self: *CalendarApp) void {
        self.window.as(gtk.Window).present();
    }

    fn onDestroy(_: *gtk.ApplicationWindow, self: *CalendarApp) callconv(.c) void {
        self.flush();
        self.notes.deinit();
        self.allocator.destroy(self);
    }

    fn selectedKey(self: *CalendarApp, buf: []u8) []const u8 {
        const date = self.calendar.getDate();
        defer date.unref();
        return dateKey(buf, date.getYear(), @intCast(date.getMonth()), @intCast(date.getDayOfMonth()));
    }

    fn onToday(_: *gtk.Button, self: *CalendarApp) callconv(.c) void {
        const now = glib.DateTime.newNowLocal() orelse return;
        defer now.unref();
        self.calendar.selectDay(now);
    }

    fn onMonth(_: *gtk.Calendar, self: *CalendarApp) callconv(.c) void {
        self.markNoteDays();
    }

    fn onDay(_: *gtk.Calendar, self: *CalendarApp) callconv(.c) void {
        self.flush();
        self.showDay();
    }

    fn markNoteDays(self: *CalendarApp) void {
        self.calendar.clearMarks();
        const date = self.calendar.getDate();
        defer date.unref();
        var day: u32 = 1;
        while (day <= 31) : (day += 1) {
            var buf: [16]u8 = undefined;
            var key_z: [17]u8 = undefined;
            const key = dateKey(&buf, date.getYear(), @intCast(date.getMonth()), day);
            @memcpy(key_z[0..key.len], key);
            key_z[key.len] = 0;
            const note = self.notes.getString(self.allocator, "notes", @ptrCast(key_z[0..key.len :0]), "") catch continue;
            defer self.allocator.free(note);
            if (note.len > 0) self.calendar.markDay(day);
        }
    }

    fn showDay(self: *CalendarApp) void {
        var buf: [16]u8 = undefined;
        const key = self.selectedKey(&buf);
        @memcpy(self.key[0..key.len], key);
        self.key_len = key.len;
        var key_z: [17]u8 = undefined;
        @memcpy(key_z[0..key.len], key);
        key_z[key.len] = 0;
        const note = self.notes.getString(self.allocator, "notes", @ptrCast(key_z[0..key.len :0]), "") catch return;
        defer self.allocator.free(note);

        const date = self.calendar.getDate();
        defer date.unref();
        if (date.format("%A, %-d %B %Y")) |title| {
            defer glib.free(title);
            self.heading.setText(title);
        }
        self.loading = true;
        defer self.loading = false;
        const z = self.allocator.dupeSentinel(u8, note, 0) catch return;
        defer self.allocator.free(z);
        self.text.getBuffer().setText(z, @intCast(z.len));
    }

    fn onEdited(_: *gtk.TextBuffer, self: *CalendarApp) callconv(.c) void {
        if (self.loading) return;
        if (self.save_source == 0) self.save_source = glib.timeoutAdd(600, onSaveTimer, self);
    }

    fn onSaveTimer(data: ?*anyopaque) callconv(.c) c_int {
        const self: *CalendarApp = @ptrCast(@alignCast(data.?));
        self.save_source = 0;
        self.flush();
        return 0;
    }

    /// Writes the visible note if it has not been saved.
    fn flush(self: *CalendarApp) void {
        if (self.save_source != 0) {
            _ = glib.Source.remove(self.save_source);
            self.save_source = 0;
        }
        if (self.key_len == 0) return;
        const buffer = self.text.getBuffer();
        var start: gtk.TextIter = undefined;
        var end: gtk.TextIter = undefined;
        buffer.getBounds(&start, &end);
        const text = buffer.getText(&start, &end, 0);
        defer glib.free(text);
        var key_z: [17]u8 = undefined;
        @memcpy(key_z[0..self.key_len], self.key[0..self.key_len]);
        key_z[self.key_len] = 0;
        self.notes.setString("notes", @ptrCast(key_z[0..self.key_len :0]), std.mem.span(text)) catch {};
        self.markNoteDays();
    }
};

pub fn main(init: std.process.Init.Minimal) !void {
    try common.runapp.run("org.dkde.calendar", CalendarApp, init);
}

test "date keys" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("2026-10-31", dateKey(&buf, 2026, 10, 31));
    try std.testing.expectEqualStrings("0999-01-05", dateKey(&buf, 999, 1, 5));
}
