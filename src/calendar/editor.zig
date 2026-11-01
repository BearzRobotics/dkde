//! The event editor window: title, place, dates, times, repeat, reminder, notes.

const std = @import("std");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gio = @import("gio2");
const gtk = @import("gtk4");
const common = @import("common");
const main = @import("main.zig");

const events = common.events;
const Date = common.civil.Date;
const App = main.CalendarApp;

/// Choices for the reminder drop-down: label and minutes before (-1 for none).
const reminders = [_]struct { label: [:0]const u8, minutes: i32 }{
    .{ .label = "No reminder", .minutes = -1 },
    .{ .label = "At the start", .minutes = 0 },
    .{ .label = "5 minutes before", .minutes = 5 },
    .{ .label = "10 minutes before", .minutes = 10 },
    .{ .label = "15 minutes before", .minutes = 15 },
    .{ .label = "30 minutes before", .minutes = 30 },
    .{ .label = "1 hour before", .minutes = 60 },
    .{ .label = "2 hours before", .minutes = 120 },
    .{ .label = "1 day before", .minutes = 1440 },
    .{ .label = "2 days before", .minutes = 2880 },
    .{ .label = "1 week before", .minutes = 10080 },
};

const repeats = [_]struct { label: [:0]const u8, value: events.Repeat }{
    .{ .label = "Does not repeat", .value = .none },
    .{ .label = "Every day", .value = .daily },
    .{ .label = "Every week", .value = .weekly },
    .{ .label = "Every month", .value = .monthly },
    .{ .label = "Every year", .value = .yearly },
};

const colors = [_]struct { label: [:0]const u8, value: events.Color }{
    .{ .label = "Default", .value = .default },
    .{ .label = "Red", .value = .red },
    .{ .label = "Orange", .value = .orange },
    .{ .label = "Yellow", .value = .yellow },
    .{ .label = "Green", .value = .green },
    .{ .label = "Teal", .value = .teal },
    .{ .label = "Blue", .value = .blue },
    .{ .label = "Purple", .value = .purple },
    .{ .label = "Pink", .value = .pink },
    .{ .label = "Gray", .value = .gray },
};

const ampm = [_]struct { label: [:0]const u8, pm: bool }{
    .{ .label = "AM", .pm = false },
    .{ .label = "PM", .pm = true },
};

const Editor = struct {
    twelve: bool,
    start_ampm: *gtk.DropDown,
    end_ampm: *gtk.DropDown,
    app: *App,
    window: *gtk.Window,
    /// Empty for a new event.
    id: ?[:0]u8,
    title: *gtk.Entry,
    location: *gtk.Entry,
    all_day: *gtk.CheckButton,
    start_date: *gtk.Entry,
    end_date: *gtk.Entry,
    start_h: *gtk.SpinButton,
    start_m: *gtk.SpinButton,
    end_h: *gtk.SpinButton,
    end_m: *gtk.SpinButton,
    times: *gtk.Box,
    end_times: *gtk.Box,
    repeat: *gtk.DropDown,
    remind: *gtk.DropDown,
    color: *gtk.DropDown,
    notes: *gtk.TextView,
    error_label: *gtk.Label,
};

fn label(comptime text: [:0]const u8) *gtk.Widget {
    const l = gtk.Label.new(common.tr(text));
    l.setXalign(0);
    return l.as(gtk.Widget);
}

fn dropDown(comptime items: anytype) *gtk.DropDown {
    var names: [items.len + 1]?[*:0]const u8 = undefined;
    inline for (items, 0..) |item, i| names[i] = common.tr(item.label).ptr;
    names[items.len] = null;
    return gtk.DropDown.newFromStrings(@ptrCast(&names));
}

fn timeRow(h: *gtk.SpinButton, m: *gtk.SpinButton, half: *gtk.DropDown, twelve: bool) *gtk.Box {
    const row = gtk.Box.new(.horizontal, 4);
    row.append(h.as(gtk.Widget));
    row.append(gtk.Label.new(":").as(gtk.Widget));
    row.append(m.as(gtk.Widget));
    if (twelve) row.append(half.as(gtk.Widget));
    return row;
}

/// The minute of the day from the spin buttons (and AM/PM on the 12-hour clock).
fn minuteOf(self: *const Editor, h: *gtk.SpinButton, m: *gtk.SpinButton, half: *gtk.DropDown) u16 {
    var hour: i32 = h.getValueAsInt();
    if (self.twelve) {
        hour = @mod(hour, 12);
        if (ampm[@min(half.getSelected(), 1)].pm) hour += 12;
    }
    return @intCast(hour * 60 + m.getValueAsInt());
}

/// The hour spin button: 0-23, or 1-12 on the 12-hour clock.
fn hourSpin(twelve: bool, minute: u16) *gtk.SpinButton {
    const h24 = minute / 60;
    if (!twelve) return spin(0, 23, h24);
    return spin(1, 12, if (h24 % 12 == 0) 12 else h24 % 12);
}

fn spin(min: f64, max: f64, value: u16) *gtk.SpinButton {
    const s = gtk.SpinButton.newWithRange(min, max, 1);
    s.setValue(@floatFromInt(value));
    s.setWrap(1);
    s.setNumeric(1);
    return s;
}

/// Opens the editor for `existing`, or for a new event on `date`.
pub fn open(app: *App, existing: ?*const events.Event, date: Date) void {
    const a = app.allocator;
    const self = a.create(Editor) catch return;
    const ev: events.Event = if (existing) |e| e.* else .{
        .id = "",
        .title = "",
        .date = date,
        .end_date = date,
        .start = 9 * 60,
        .end = 10 * 60,
    };
    self.* = .{
        .app = app,
        .window = gtk.Window.new(),
        .id = if (existing) |e| a.dupeSentinel(u8, e.id, 0) catch null else null,
        .title = gtk.Entry.new(),
        .location = gtk.Entry.new(),
        .all_day = gtk.CheckButton.newWithLabel(common.tr("All day")),
        .start_date = gtk.Entry.new(),
        .end_date = gtk.Entry.new(),
        .twelve = app.twelve_hour,
        .start_ampm = dropDown(ampm),
        .end_ampm = dropDown(ampm),
        .start_h = hourSpin(app.twelve_hour, ev.start),
        .start_m = spin(0, 59, ev.start % 60),
        .end_h = hourSpin(app.twelve_hour, ev.end),
        .end_m = spin(0, 59, ev.end % 60),
        .times = gtk.Box.new(.vertical, 8),
        .end_times = gtk.Box.new(.vertical, 8),
        .repeat = dropDown(repeats),
        .remind = dropDown(reminders),
        .color = dropDown(colors),
        .notes = gtk.TextView.new(),
        .error_label = gtk.Label.new(""),
    };

    const w = self.window;
    w.setTitle(if (existing != null) common.tr("Edit event") else common.tr("New event"));
    w.setModal(1);
    w.setTransientFor(app.window.as(gtk.Window));
    w.setDefaultSize(440, -1);
    w.as(gtk.Widget).addCssClass("dkde");

    self.title.as(gtk.Editable).setText(zstr(ev.title));
    self.title.setPlaceholderText(common.tr("Title"));
    self.title.as(gtk.Widget).setHexpand(1);
    self.location.as(gtk.Editable).setText(zstr(ev.location));
    self.location.setPlaceholderText(common.tr("Place"));
    var db: [16]u8 = undefined;
    self.start_date.as(gtk.Editable).setText(zstr(events.formatDate(&db, ev.date)));
    self.end_date.as(gtk.Editable).setText(zstr(events.formatDate(&db, ev.end_date)));
    self.start_date.setPlaceholderText("YYYY-MM-DD");
    self.end_date.setPlaceholderText("YYYY-MM-DD");
    self.all_day.setActive(@intFromBool(ev.all_day));
    _ = gtk.CheckButton.signals.toggled.connect(self.all_day, *Editor, &onAllDay, self, .{});
    const hide_times = @intFromBool(!ev.all_day);

    for (repeats, 0..) |r, i| if (r.value == ev.repeat) self.repeat.setSelected(@intCast(i));
    self.start_ampm.setSelected(if (ev.start >= 12 * 60) 1 else 0);
    self.end_ampm.setSelected(if (ev.end >= 12 * 60) 1 else 0);
    for (colors, 0..) |c, i| if (c.value == ev.color) self.color.setSelected(@intCast(i));
    var pick: usize = 0;
    for (reminders, 0..) |r, i| if (r.minutes == ev.remind) {
        pick = i;
    };
    self.remind.setSelected(@intCast(pick));

    self.notes.setWrapMode(.word_char);
    self.notes.setLeftMargin(6);
    self.notes.setTopMargin(6);
    self.notes.getBuffer().setText(zstr(ev.notes), @intCast(ev.notes.len));
    const notes_scroll = gtk.ScrolledWindow.new();
    notes_scroll.setChild(self.notes.as(gtk.Widget));
    notes_scroll.setMinContentHeight(80);
    notes_scroll.as(gtk.Widget).addCssClass("frame");

    // Times: start and end on their own rows, hidden for an all-day event.
    const grid = gtk.Grid.new();
    grid.setRowSpacing(8);
    grid.setColumnSpacing(10);
    var row: c_int = 0;
    grid.attach(label("Title"), 0, row, 1, 1);
    grid.attach(self.title.as(gtk.Widget), 1, row, 1, 1);
    row += 1;
    grid.attach(label("Place"), 0, row, 1, 1);
    grid.attach(self.location.as(gtk.Widget), 1, row, 1, 1);
    row += 1;
    grid.attach(self.all_day.as(gtk.Widget), 1, row, 1, 1);
    row += 1;
    grid.attach(label("Starts"), 0, row, 1, 1);
    const starts = gtk.Box.new(.horizontal, 8);
    starts.append(self.start_date.as(gtk.Widget));
    starts.append(timeRowWrap(self, true));
    grid.attach(starts.as(gtk.Widget), 1, row, 1, 1);
    row += 1;
    grid.attach(label("Ends"), 0, row, 1, 1);
    const ends = gtk.Box.new(.horizontal, 8);
    ends.append(self.end_date.as(gtk.Widget));
    ends.append(timeRowWrap(self, false));
    grid.attach(ends.as(gtk.Widget), 1, row, 1, 1);
    row += 1;
    grid.attach(label("Repeat"), 0, row, 1, 1);
    grid.attach(self.repeat.as(gtk.Widget), 1, row, 1, 1);
    row += 1;
    grid.attach(label("Reminder"), 0, row, 1, 1);
    grid.attach(self.remind.as(gtk.Widget), 1, row, 1, 1);
    row += 1;
    grid.attach(label("Colour"), 0, row, 1, 1);
    grid.attach(self.color.as(gtk.Widget), 1, row, 1, 1);
    row += 1;
    grid.attach(label("Notes"), 0, row, 1, 1);
    grid.attach(notes_scroll.as(gtk.Widget), 1, row, 1, 1);

    self.error_label.setXalign(0);
    self.error_label.setWrap(1);
    self.error_label.as(gtk.Widget).addCssClass("error");

    const hint = gtk.Label.new(common.tr("Reminders are sent by the panel, so it has to be running."));
    hint.setXalign(0);
    hint.setWrap(1);
    hint.as(gtk.Widget).addCssClass("dim-label");
    hint.as(gtk.Widget).setVisible(@intFromBool(!panelRunning(a)));

    const cancel = gtk.Button.newWithLabel(common.tr("Cancel"));
    const save = gtk.Button.newWithLabel(common.tr("Save"));
    save.as(gtk.Widget).addCssClass("suggested-action");
    _ = gtk.Button.signals.clicked.connect(cancel, *Editor, &onCancel, self, .{});
    _ = gtk.Button.signals.clicked.connect(save, *Editor, &onSave, self, .{});
    const buttons = gtk.Box.new(.horizontal, 8);
    buttons.as(gtk.Widget).setHalign(.end);
    buttons.append(cancel.as(gtk.Widget));
    buttons.append(save.as(gtk.Widget));

    const box = gtk.Box.new(.vertical, 10);
    box.as(gtk.Widget).setMarginTop(14);
    box.as(gtk.Widget).setMarginBottom(14);
    box.as(gtk.Widget).setMarginStart(14);
    box.as(gtk.Widget).setMarginEnd(14);
    box.append(grid.as(gtk.Widget));
    box.append(self.error_label.as(gtk.Widget));
    box.append(hint.as(gtk.Widget));
    box.append(buttons.as(gtk.Widget));
    w.setChild(box.as(gtk.Widget));

    _ = gtk.Widget.signals.destroy.connect(w, *Editor, &onDestroy, self, .{});
    self.times.as(gtk.Widget).setVisible(hide_times);
    self.end_times.as(gtk.Widget).setVisible(hide_times);
    w.present();
}

/// The hour and minute spin buttons of the start or end time. The all-day
/// check hides both rows.
fn timeRowWrap(self: *Editor, start: bool) *gtk.Widget {
    const r = if (start) timeRow(self.start_h, self.start_m, self.start_ampm, self.twelve) else timeRow(self.end_h, self.end_m, self.end_ampm, self.twelve);
    if (start) self.times = r else self.end_times = r;
    return r.as(gtk.Widget);
}

fn onAllDay(button: *gtk.CheckButton, self: *Editor) callconv(.c) void {
    const visible = @intFromBool(button.getActive() == 0);
    self.times.as(gtk.Widget).setVisible(visible);
    self.end_times.as(gtk.Widget).setVisible(visible);
}

fn onCancel(_: *gtk.Button, self: *Editor) callconv(.c) void {
    self.window.destroy();
}

fn onDestroy(_: *gtk.Window, self: *Editor) callconv(.c) void {
    if (self.id) |id| self.app.allocator.free(id);
    self.app.allocator.destroy(self);
}

fn fail(self: *Editor, comptime message: [:0]const u8) void {
    self.error_label.setText(common.tr(message));
}

fn onSave(_: *gtk.Button, self: *Editor) callconv(.c) void {
    const a = self.app.allocator;
    const start_text = std.mem.span(self.start_date.as(gtk.Editable).getText());
    const end_text = std.mem.span(self.end_date.as(gtk.Editable).getText());
    const start_date = events.parseDate(std.mem.trim(u8, start_text, " ")) orelse return fail(self, "The start date must look like 2026-10-31.");
    const end_date = events.parseDate(std.mem.trim(u8, end_text, " ")) orelse return fail(self, "The end date must look like 2026-10-31.");
    if (end_date.days() < start_date.days()) return fail(self, "The event cannot end before it starts.");

    const all_day = self.all_day.getActive() != 0;
    const start = minuteOf(self, self.start_h, self.start_m, self.start_ampm);
    const end = minuteOf(self, self.end_h, self.end_m, self.end_ampm);
    if (!all_day and end_date.eql(start_date) and end < start) return fail(self, "The event cannot end before it starts.");

    const buffer = self.notes.getBuffer();
    var s: gtk.TextIter = undefined;
    var e: gtk.TextIter = undefined;
    buffer.getBounds(&s, &e);
    const notes = buffer.getText(&s, &e, 0);
    defer glib.free(notes);

    var idbuf: [24]u8 = undefined;
    const id: []const u8 = if (self.id) |existing| existing else events.newId(&idbuf, glib.getRealTime());
    const ev: events.Event = .{
        .id = id,
        .title = std.mem.trim(u8, std.mem.span(self.title.as(gtk.Editable).getText()), " "),
        .location = std.mem.trim(u8, std.mem.span(self.location.as(gtk.Editable).getText()), " "),
        .notes = std.mem.span(notes),
        .date = start_date,
        .end_date = end_date,
        .all_day = all_day,
        .start = start,
        .end = end,
        .repeat = repeats[@min(self.repeat.getSelected(), repeats.len - 1)].value,
        .color = colors[@min(self.color.getSelected(), colors.len - 1)].value,
        .remind = reminders[@min(self.remind.getSelected(), reminders.len - 1)].minutes,
    };
    events.save(a, &self.app.cfg, ev) catch return fail(self, "The event could not be saved.");
    self.app.eventsChanged();
    self.window.destroy();
}

/// Whether the panel (which sends the reminders) is up: its socket exists.
fn panelRunning(allocator: std.mem.Allocator) bool {
    const path = std.fmt.allocPrintSentinel(allocator, "{s}/dkde/panel.sock", .{std.mem.span(glib.getUserRuntimeDir())}, 0) catch return true;
    defer allocator.free(path);
    return glib.fileTest(path, .{ .exists = true }) != 0;
}

fn zstr(text: []const u8) [:0]const u8 {
    const Ring = struct {
        var bufs: [4][1024]u8 = undefined;
        var next: usize = 0;
    };
    const buf = &Ring.bufs[Ring.next];
    Ring.next = (Ring.next + 1) % Ring.bufs.len;
    const n = @min(text.len, buf.len - 1);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    return buf[0..n :0];
}
