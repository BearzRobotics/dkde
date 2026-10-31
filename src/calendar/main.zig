//! dkde-calendar: a month calendar with events (place, date, time frame,
//! repeat, reminder), a note for any day, and optional liturgical calendars
//! laid over the days (SPEC.md 5.6). Everything is saved in
//! `~/.config/dkde/calendar.conf`. Reminders are sent by dkde-panel, which is
//! always running; this program only stores the events.

const std = @import("std");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gio = @import("gio2");
const gtk = @import("gtk4");
const common = @import("common");
const liturgy = @import("liturgy.zig");
const editor = @import("editor.zig");
const calsys = @import("calsys.zig");

const events = common.events;
const civil = common.civil;
const Date = civil.Date;

pub const std_options: std.Options = .{ .logFn = common.log.logFn, .log_level = .debug };

/// "2026-10-31", the key a day's note is stored under.
pub fn dateKey(buf: []u8, year: i32, month: u32, day: u32) []const u8 {
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u32, @intCast(year)), month, day }) catch "";
}

const Cell = struct { app: *CalendarApp, date: Date };

pub const CalendarApp = struct {
    allocator: std.mem.Allocator,
    window: *gtk.ApplicationWindow,
    cfg: common.Config,
    list: events.List,

    // What is shown. `year` and `month` are in the calendar system `sys`.
    sys: calsys.System,
    year: i32,
    month: u8,
    selected: Date,
    today: Date,
    show_no: bool = false,
    show_tlm: bool = false,
    table_no: ?liturgy.Table = null,
    table_tlm: ?liturgy.Table = null,

    // Widgets.
    grid: *gtk.Grid,
    month_label: *gtk.Label,
    heading: *gtk.Label,
    alt_label: *gtk.Label,
    lit_box: *gtk.Box,
    events_box: *gtk.Box,
    text: *gtk.TextView,
    cells: [42]Cell = undefined,

    // The note being edited.
    key: [16]u8 = undefined,
    key_len: usize = 0,
    loading: bool = false,
    save_source: c_uint = 0,

    pub fn create(allocator: std.mem.Allocator, app: *gtk.Application) !*CalendarApp {
        const self = try allocator.create(CalendarApp);
        errdefer allocator.destroy(self);
        var cfg = try common.Config.load(allocator, "calendar.conf");
        errdefer cfg.deinit();
        var list = try events.load(allocator, &cfg);
        errdefer list.deinit();

        const now = glib.DateTime.newNowLocal() orelse return error.NoClock;
        defer now.unref();
        const today: Date = .{ .year = now.getYear(), .month = @intCast(now.getMonth()), .day = @intCast(now.getDayOfMonth()) };

        const sys_text = try cfg.getString(allocator, "view", "system", "julian");
        defer allocator.free(sys_text);
        const sys = calsys.System.parse(sys_text);
        const here = calsys.fromCivil(sys, today);

        self.* = .{
            .allocator = allocator,
            .window = gtk.ApplicationWindow.new(app),
            .cfg = cfg,
            .list = list,
            .sys = sys,
            .year = here.year,
            .month = here.month,
            .selected = today,
            .today = today,
            .grid = gtk.Grid.new(),
            .month_label = gtk.Label.new(""),
            .heading = gtk.Label.new(""),
            .alt_label = gtk.Label.new(""),
            .lit_box = gtk.Box.new(.vertical, 6),
            .events_box = gtk.Box.new(.vertical, 4),
            .text = gtk.TextView.new(),
        };
        self.show_no = self.cfg.getBool("view", "novus-ordo", false);
        self.show_tlm = self.cfg.getBool("view", "tlm-1962", false);
        self.ensureTables();

        const window = self.window.as(gtk.Window);
        window.setTitle(common.tr("Calendar"));
        window.setDefaultSize(1060, 700);
        self.window.as(gtk.Widget).addCssClass("dkde");
        _ = common.header.create(window, "x-office-calendar", true);

        // ---- toolbar -------------------------------------------------------------------
        const prev = gtk.Button.newFromIconName("go-previous-symbolic");
        const next = gtk.Button.newFromIconName("go-next-symbolic");
        const today_button = gtk.Button.newWithLabel(common.tr("Today"));
        _ = gtk.Button.signals.clicked.connect(prev, *CalendarApp, &onPrev, self, .{});
        _ = gtk.Button.signals.clicked.connect(next, *CalendarApp, &onNext, self, .{});
        _ = gtk.Button.signals.clicked.connect(today_button, *CalendarApp, &onToday, self, .{});
        var terminated = [_]?[*:0]const u8{ common.tr("Julian (Old Calendar)").ptr, common.tr("Gregorian").ptr, common.tr("Fixed (13 months)").ptr, null };
        const system_menu = gtk.DropDown.newFromStrings(@ptrCast(&terminated));
        system_menu.setSelected(@backingInt(self.sys));
        system_menu.as(gtk.Widget).setTooltipText(common.tr("Calendar system"));
        _ = gobject.Object.signals.notify.connect(system_menu, *CalendarApp, &onSystem, self, .{ .detail = "selected" });
        self.month_label.as(gtk.Widget).addCssClass("title-3");
        self.month_label.as(gtk.Widget).setMarginStart(8);
        self.month_label.as(gtk.Widget).setMarginEnd(8);

        const no_check = gtk.CheckButton.newWithLabel(common.tr("Novus Ordo"));
        no_check.setActive(@intFromBool(self.show_no));
        no_check.as(gtk.Widget).setTooltipText(common.tr("Show the liturgical calendar of the Roman Rite as it is now"));
        _ = gtk.CheckButton.signals.toggled.connect(no_check, *CalendarApp, &onToggleNo, self, .{});
        const tlm_check = gtk.CheckButton.newWithLabel(common.tr("Traditional (1962)"));
        tlm_check.setActive(@intFromBool(self.show_tlm));
        tlm_check.as(gtk.Widget).setTooltipText(common.tr("Show the liturgical calendar of the 1962 Roman Missal"));
        _ = gtk.CheckButton.signals.toggled.connect(tlm_check, *CalendarApp, &onToggleTlm, self, .{});

        const add = gtk.Button.newWithLabel(common.tr("New event"));
        add.as(gtk.Widget).addCssClass("suggested-action");
        _ = gtk.Button.signals.clicked.connect(add, *CalendarApp, &onAdd, self, .{});

        const spacer = gtk.Box.new(.horizontal, 0);
        spacer.as(gtk.Widget).setHexpand(1);
        const bar = gtk.Box.new(.horizontal, 6);
        bar.append(prev.as(gtk.Widget));
        bar.append(next.as(gtk.Widget));
        bar.append(self.month_label.as(gtk.Widget));
        bar.append(today_button.as(gtk.Widget));
        bar.append(system_menu.as(gtk.Widget));
        bar.append(spacer.as(gtk.Widget));
        bar.append(no_check.as(gtk.Widget));
        bar.append(tlm_check.as(gtk.Widget));
        bar.append(add.as(gtk.Widget));

        // ---- month grid ----------------------------------------------------------------
        self.grid.setColumnHomogeneous(1);
        self.grid.setRowHomogeneous(0);
        self.grid.as(gtk.Widget).setHexpand(1);
        self.grid.as(gtk.Widget).setVexpand(1);
        const month_box = gtk.Box.new(.vertical, 4);
        month_box.as(gtk.Widget).setHexpand(1);
        month_box.append(bar.as(gtk.Widget));
        month_box.append(self.grid.as(gtk.Widget));

        // ---- the day panel -------------------------------------------------------------
        self.heading.setXalign(0);
        self.heading.setWrap(1);
        self.heading.as(gtk.Widget).addCssClass("title-4");
        self.text.setWrapMode(.word_char);
        self.text.as(gtk.Widget).setVexpand(1);
        self.text.as(gtk.Widget).addCssClass("dkde-calendar-notes");
        self.text.setLeftMargin(8);
        self.text.setTopMargin(8);
        _ = gtk.TextBuffer.signals.changed.connect(self.text.getBuffer(), *CalendarApp, &onEdited, self, .{});
        const notes_scroller = gtk.ScrolledWindow.new();
        notes_scroller.setChild(self.text.as(gtk.Widget));
        notes_scroller.as(gtk.Widget).setVexpand(1);
        notes_scroller.setMinContentHeight(90);

        const notes_label = gtk.Label.new(common.tr("Notes"));
        notes_label.setXalign(0);
        notes_label.as(gtk.Widget).addCssClass("heading");
        const events_label = gtk.Label.new(common.tr("Events"));
        events_label.setXalign(0);
        events_label.as(gtk.Widget).addCssClass("heading");

        const day_scroller = gtk.ScrolledWindow.new();
        const day_content = gtk.Box.new(.vertical, 8);
        day_content.append(self.lit_box.as(gtk.Widget));
        day_content.append(events_label.as(gtk.Widget));
        day_content.append(self.events_box.as(gtk.Widget));
        day_scroller.setChild(day_content.as(gtk.Widget));
        day_scroller.as(gtk.Widget).setVexpand(1);
        day_scroller.setPolicy(.never, .automatic);

        const right = gtk.Box.new(.vertical, 6);
        right.as(gtk.Widget).setSizeRequest(320, -1);
        self.alt_label.setXalign(0);
        self.alt_label.setWrap(1);
        self.alt_label.as(gtk.Widget).addCssClass("dim-label");
        right.append(self.heading.as(gtk.Widget));
        right.append(self.alt_label.as(gtk.Widget));
        right.append(day_scroller.as(gtk.Widget));
        right.append(notes_label.as(gtk.Widget));
        right.append(notes_scroller.as(gtk.Widget));

        const body = gtk.Box.new(.horizontal, 16);
        body.as(gtk.Widget).setMarginTop(12);
        body.as(gtk.Widget).setMarginBottom(12);
        body.as(gtk.Widget).setMarginStart(12);
        body.as(gtk.Widget).setMarginEnd(12);
        body.append(month_box.as(gtk.Widget));
        body.append(right.as(gtk.Widget));
        window.setChild(body.as(gtk.Widget));

        _ = gtk.Widget.signals.destroy.connect(self.window, *CalendarApp, &onDestroy, self, .{});
        self.rebuildGrid();
        self.showDay();
        return self;
    }

    pub fn present(self: *CalendarApp) void {
        self.window.as(gtk.Window).present();
    }

    fn onDestroy(_: *gtk.ApplicationWindow, self: *CalendarApp) callconv(.c) void {
        self.flush();
        if (self.table_no) |*t| t.deinit();
        if (self.table_tlm) |*t| t.deinit();
        self.list.deinit();
        self.cfg.deinit();
        self.allocator.destroy(self);
    }

    // ---- liturgical overlays ---------------------------------------------------------------

    /// Loads the tables for the overlays that are on and frees the others, so
    /// a hidden overlay costs no memory.
    fn ensureTables(self: *CalendarApp) void {
        self.table_no = self.syncTable(self.table_no, self.show_no, .novus_ordo);
        self.table_tlm = self.syncTable(self.table_tlm, self.show_tlm, .tlm1962);
    }

    fn syncTable(self: *CalendarApp, current: ?liturgy.Table, want: bool, kind: liturgy.Kind) ?liturgy.Table {
        if (want) {
            if (current != null) return current;
            return liturgy.Table.load(self.allocator, kind) catch |err| {
                std.log.warn("liturgical calendar not loaded: {s}", .{@errorName(err)});
                return null;
            };
        }
        if (current) |c| {
            var copy = c;
            copy.deinit();
        }
        return null;
    }

    fn onToggleNo(button: *gtk.CheckButton, self: *CalendarApp) callconv(.c) void {
        self.show_no = button.getActive() != 0;
        self.cfg.setBool("view", "novus-ordo", self.show_no) catch {};
        self.overlaysChanged();
    }

    fn onToggleTlm(button: *gtk.CheckButton, self: *CalendarApp) callconv(.c) void {
        self.show_tlm = button.getActive() != 0;
        self.cfg.setBool("view", "tlm-1962", self.show_tlm) catch {};
        self.overlaysChanged();
    }

    fn overlaysChanged(self: *CalendarApp) void {
        self.ensureTables();
        self.rebuildGrid();
        self.showLiturgy();
    }

    // ---- month navigation ------------------------------------------------------------------

    fn onPrev(_: *gtk.Button, self: *CalendarApp) callconv(.c) void {
        self.shiftMonth(-1);
    }

    fn onNext(_: *gtk.Button, self: *CalendarApp) callconv(.c) void {
        self.shiftMonth(1);
    }

    fn shiftMonth(self: *CalendarApp, delta: i32) void {
        var m: i32 = @as(i32, self.month) + delta;
        var y = self.year;
        const count: i32 = self.sys.monthCount();
        if (m < 1) {
            m = count;
            y -= 1;
        } else if (m > count) {
            m = 1;
            y += 1;
        }
        self.year = y;
        self.month = @intCast(m);
        self.rebuildGrid();
    }

    fn onSystem(menu: *gtk.DropDown, _: *gobject.ParamSpec, self: *CalendarApp) callconv(.c) void {
        const index = menu.getSelected();
        if (index > 2) return;
        self.sys = @fromBackingInt(@intCast(index));
        self.cfg.setString("view", "system", self.sys.name()) catch {};
        // Show the month that holds the selected day in the new system.
        const v = calsys.fromCivil(self.sys, self.selected);
        self.year = v.year;
        self.month = v.month;
        self.rebuildGrid();
        self.showDay();
    }

    fn onToday(_: *gtk.Button, self: *CalendarApp) callconv(.c) void {
        self.selectDate(self.today);
    }

    /// Selects a day, showing its month if it is not the one on screen.
    fn selectDate(self: *CalendarApp, date: Date) void {
        self.flush();
        self.selected = date;
        const v = calsys.fromCivil(self.sys, date);
        self.year = v.year;
        self.month = v.month;
        self.rebuildGrid();
        self.showDay();
    }

    fn onCell(_: *gtk.Button, cell: *Cell) callconv(.c) void {
        cell.app.selectDate(cell.date);
    }

    // ---- the grid --------------------------------------------------------------------------

    fn clearGrid(grid: *gtk.Grid) void {
        while (grid.as(gtk.Widget).getFirstChild()) |child| grid.remove(child);
    }

    fn clearBox(box: *gtk.Box) void {
        while (box.as(gtk.Widget).getFirstChild()) |child| box.remove(child);
    }

    fn rebuildGrid(self: *CalendarApp) void {
        clearGrid(self.grid);
        const sys = self.sys;

        var title: [64]u8 = undefined;
        self.month_label.setText(bufZ(&title, "{s} {d}{s}", .{
            calsys.monthName(sys, self.month),
            self.year,
            if (sys == .julian) " (Julian)" else "",
        }) catch "");

        const heads = .{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
        inline for (heads, 0..) |n, col| {
            const l = gtk.Label.new(common.tr(n));
            l.as(gtk.Widget).addCssClass("dkde-cal-weekday");
            self.grid.attach(l.as(gtk.Widget), @intCast(col), 0, 1, 1);
        }

        const first = calsys.toCivil(sys, .{ .year = self.year, .month = self.month, .day = 1 });
        const days = calsys.monthDays(sys, self.year, self.month);
        if (sys == .fixed) {
            // Every month is four whole weeks; Leap Day and Year Day get a row of their own.
            var i: usize = 0;
            while (i < 28) : (i += 1) self.placeCell(i, first.addDays(@intCast(i)), @intCast(i % 7), @intCast(i / 7 + 1), 1);
            if (days == 29) self.placeCell(28, first.addDays(28), 0, 5, 7);
            return;
        }
        const lead: i64 = first.weekday();
        var i: usize = 0;
        while (i < 42) : (i += 1) {
            const date = first.addDays(@as(i64, @intCast(i)) - lead);
            self.placeCell(i, date, @intCast(i % 7), @intCast(i / 7 + 1), 1);
        }
    }

    fn placeCell(self: *CalendarApp, index: usize, date: Date, col: c_int, row: c_int, span: c_int) void {
        self.cells[index] = .{ .app = self, .date = date };
        const button = self.makeCell(date);
        _ = gtk.Button.signals.clicked.connect(button, *Cell, &onCell, &self.cells[index], .{});
        self.grid.attach(button.as(gtk.Widget), col, row, span, 1);
    }

    fn makeCell(self: *CalendarApp, date: Date) *gtk.Button {
        const button = gtk.Button.new();
        const w = button.as(gtk.Widget);
        w.addCssClass("flat");
        w.addCssClass("dkde-cal-cell");
        w.setHexpand(1);
        w.setVexpand(1);
        w.setSizeRequest(96, 74);
        const v = calsys.fromCivil(self.sys, date);
        if (v.month != self.month or v.year != self.year) w.addCssClass("outside");
        if (date.eql(self.today)) w.addCssClass("today");
        if (date.eql(self.selected)) w.addCssClass("selected");

        const box = gtk.Box.new(.vertical, 1);
        var nb: [24]u8 = undefined;
        const num = gtk.Label.new(if (calsys.isSpecial(self.sys, v)) zstr(calsys.specialName(v)) else (bufZ(&nb, "{d}", .{v.day}) catch ""));
        num.setXalign(0);
        num.as(gtk.Widget).addCssClass("dkde-cal-num");
        num.as(gtk.Widget).setHalign(.start);
        const top = gtk.Box.new(.horizontal, 4);
        top.append(num.as(gtk.Widget));
        if (self.sys != .gregorian) {
            // The civil date, small, at the right.
            var cb: [16]u8 = undefined;
            const civil_label = gtk.Label.new(bufZ(&cb, "{d}/{d}", .{ date.month, date.day }) catch "");
            civil_label.as(gtk.Widget).setHexpand(1);
            civil_label.setXalign(1);
            civil_label.as(gtk.Widget).addCssClass("dim-label");
            civil_label.as(gtk.Widget).addCssClass("dkde-cal-civil");
            top.append(civil_label.as(gtk.Widget));
        }
        box.append(top.as(gtk.Widget));

        var day: liturgy.Day = undefined;
        if (self.table_no) |*t| self.addLitLine(box, t, date, &day);
        if (self.table_tlm) |*t| self.addLitLine(box, t, date, &day);

        var shown: usize = 0;
        var total: usize = 0;
        for (self.list.items) |*ev| {
            if (!events.occursOn(ev, date)) continue;
            total += 1;
            if (shown >= 2) continue;
            shown += 1;
            var tb: [8]u8 = undefined;
            var line: [160]u8 = undefined;
            const text = if (ev.all_day)
                bufZ(&line, "{s}", .{ev.title}) catch ""
            else
                bufZ(&line, "{s} {s}", .{ events.formatTime(&tb, ev.start), ev.title }) catch "";
            const l = gtk.Label.new(text);
            l.setXalign(0);
            l.setEllipsize(.end);
            l.setWidthChars(4);
            l.as(gtk.Widget).addCssClass("dkde-cal-event");
            box.append(l.as(gtk.Widget));
        }
        if (total > shown) {
            var mb: [24]u8 = undefined;
            const more = gtk.Label.new(bufZ(&mb, "+{d} more", .{total - shown}) catch "");
            more.setXalign(0);
            more.as(gtk.Widget).addCssClass("dim-label");
            box.append(more.as(gtk.Widget));
        }
        button.setChild(box.as(gtk.Widget));
        return button;
    }

    fn addLitLine(self: *CalendarApp, box: *gtk.Box, table: *const liturgy.Table, date: Date, day: *liturgy.Day) void {
        _ = self;
        liturgy.compute(table, date, day);
        var buf: [256]u8 = undefined;
        const l = gtk.Label.new(bufZ(&buf, "{s}", .{day.name}) catch "");
        l.setXalign(0);
        l.setEllipsize(.end);
        l.setWidthChars(4);
        l.as(gtk.Widget).addCssClass("dkde-cal-lit");
        l.as(gtk.Widget).addCssClass(zstr(day.color.cssClass()));
        l.as(gtk.Widget).setTooltipText(zstr(day.name));
        box.append(l.as(gtk.Widget));
    }

    // ---- the day panel ---------------------------------------------------------------------

    fn showDay(self: *CalendarApp) void {
        var buf: [16]u8 = undefined;
        const key = dateKey(&buf, self.selected.year, self.selected.month, self.selected.day);
        @memcpy(self.key[0..key.len], key);
        self.key_len = key.len;

        // The heading is in the chosen system; the others follow in small type.
        var hb: [96]u8 = undefined;
        self.heading.setText(zstr(calsys.describe(&hb, self.sys, self.selected)));
        var ab: [320]u8 = undefined;
        var used: usize = 0;
        inline for (.{ calsys.System.julian, calsys.System.gregorian, calsys.System.fixed }) |other| {
            if (other != self.sys) {
                var tb: [96]u8 = undefined;
                const text = calsys.describe(&tb, other, self.selected);
                const line = std.fmt.bufPrint(ab[used..], "{s}{s}: {s}", .{ if (used > 0) "\n" else "", other.label(), text }) catch "";
                used += line.len;
            }
        }
        ab[used] = 0;
        self.alt_label.setText(ab[0..used :0]);
        self.showLiturgy();
        self.showEvents();

        var key_z: [17]u8 = undefined;
        @memcpy(key_z[0..key.len], key);
        key_z[key.len] = 0;
        const note = self.cfg.getString(self.allocator, "notes", @ptrCast(key_z[0..key.len :0]), "") catch return;
        defer self.allocator.free(note);
        self.loading = true;
        defer self.loading = false;
        const z = self.allocator.dupeSentinel(u8, note, 0) catch return;
        defer self.allocator.free(z);
        self.text.getBuffer().setText(z, @intCast(z.len));
    }

    fn showLiturgy(self: *CalendarApp) void {
        clearBox(self.lit_box);
        var day: liturgy.Day = undefined;
        if (self.table_no) |*t| self.litBlock("Novus Ordo", t, &day);
        if (self.table_tlm) |*t| self.litBlock("Traditional (1962)", t, &day);
    }

    fn litBlock(self: *CalendarApp, comptime title: [:0]const u8, table: *const liturgy.Table, day: *liturgy.Day) void {
        liturgy.compute(table, self.selected, day);
        const card = gtk.Box.new(.vertical, 2);
        const head = gtk.Label.new(common.tr(title));
        head.setXalign(0);
        head.as(gtk.Widget).addCssClass("caption-heading");
        head.as(gtk.Widget).addCssClass("dim-label");
        card.append(head.as(gtk.Widget));

        const row = gtk.Box.new(.horizontal, 8);
        const dot = gtk.Box.new(.horizontal, 0);
        dot.as(gtk.Widget).addCssClass("dkde-lit-dot");
        dot.as(gtk.Widget).addCssClass(zstr(day.color.cssClass()));
        dot.as(gtk.Widget).setValign(.center);
        dot.as(gtk.Widget).setTooltipText(zstr(day.color.label()));
        row.append(dot.as(gtk.Widget));
        const name = gtk.Label.new(zstr(day.name));
        name.setXalign(0);
        name.setWrap(1);
        name.as(gtk.Widget).setHexpand(1);
        name.as(gtk.Widget).addCssClass("heading");
        row.append(name.as(gtk.Widget));
        card.append(row.as(gtk.Widget));

        var buf: [256]u8 = undefined;
        const detail = bufZ(&buf, "{s} · {s}{s}{s}", .{
            day.rank,
            day.season,
            if (day.cycle.len > 0) " · " else "",
            day.cycle,
        }) catch "";
        const info = gtk.Label.new(detail);
        info.setXalign(0);
        info.setWrap(1);
        info.as(gtk.Widget).addCssClass("dim-label");
        card.append(info.as(gtk.Widget));

        for (day.alsoLines()) |line| {
            var lb: [256]u8 = undefined;
            const l = gtk.Label.new(bufZ(&lb, "{s}: {s}", .{ line.label, line.text }) catch "");
            l.setXalign(0);
            l.setWrap(1);
            card.append(l.as(gtk.Widget));
        }
        self.lit_box.append(card.as(gtk.Widget));
    }

    fn showEvents(self: *CalendarApp) void {
        clearBox(self.events_box);
        var any = false;
        for (self.list.items) |*ev| {
            if (!events.occursOn(ev, self.selected)) continue;
            any = true;
            self.events_box.append(self.eventRow(ev).as(gtk.Widget));
        }
        if (!any) {
            const none = gtk.Label.new(common.tr("Nothing planned."));
            none.setXalign(0);
            none.as(gtk.Widget).addCssClass("dim-label");
            self.events_box.append(none.as(gtk.Widget));
        }
    }

    fn eventRow(self: *CalendarApp, ev: *const events.Event) *gtk.Box {
        const row = gtk.Box.new(.horizontal, 6);
        const text = gtk.Box.new(.vertical, 0);
        text.as(gtk.Widget).setHexpand(1);

        const title = gtk.Label.new(zstr(if (ev.title.len > 0) ev.title else "(No title)"));
        title.setXalign(0);
        title.setWrap(1);
        title.as(gtk.Widget).addCssClass("heading");
        text.append(title.as(gtk.Widget));

        var a: [8]u8 = undefined;
        var b: [8]u8 = undefined;
        var da: [16]u8 = undefined;
        var db: [16]u8 = undefined;
        var when: [160]u8 = undefined;
        const multi = !ev.date.eql(ev.end_date);
        const when_text = if (ev.all_day and multi)
            bufZ(&when, "{s} to {s}, all day", .{ events.formatDate(&da, ev.date), events.formatDate(&db, ev.end_date) }) catch ""
        else if (ev.all_day)
            "All day"
        else if (multi)
            bufZ(&when, "{s} {s} to {s} {s}", .{ events.formatDate(&da, ev.date), events.formatTime(&a, ev.start), events.formatDate(&db, ev.end_date), events.formatTime(&b, ev.end) }) catch ""
        else
            bufZ(&when, "{s} to {s}", .{ events.formatTime(&a, ev.start), events.formatTime(&b, ev.end) }) catch "";
        const when_label = gtk.Label.new(when_text);
        when_label.setXalign(0);
        text.append(when_label.as(gtk.Widget));

        if (ev.location.len > 0) {
            const loc = gtk.Label.new(zstr(ev.location));
            loc.setXalign(0);
            loc.setWrap(1);
            loc.as(gtk.Widget).addCssClass("dim-label");
            text.append(loc.as(gtk.Widget));
        }
        if (ev.repeat != .none or ev.remind >= 0) {
            var extra: [96]u8 = undefined;
            const t = bufZ(&extra, "{s}{s}{s}", .{
                if (ev.repeat != .none) "Repeats " else "",
                if (ev.repeat != .none) ev.repeat.name() else "",
                if (ev.remind >= 0) " · Reminder" else "",
            }) catch "";
            const l = gtk.Label.new(t);
            l.setXalign(0);
            l.as(gtk.Widget).addCssClass("dim-label");
            text.append(l.as(gtk.Widget));
        }
        row.append(text.as(gtk.Widget));

        const id = self.allocator.dupeSentinel(u8, ev.id, 0) catch return row;
        const edit = gtk.Button.newFromIconName("document-edit-symbolic");
        edit.as(gtk.Widget).addCssClass("flat");
        edit.as(gtk.Widget).setValign(.start);
        edit.as(gtk.Widget).setTooltipText(common.tr("Edit"));
        const del = gtk.Button.newFromIconName("user-trash-symbolic");
        del.as(gtk.Widget).addCssClass("flat");
        del.as(gtk.Widget).setValign(.start);
        del.as(gtk.Widget).setTooltipText(common.tr("Delete"));
        const ctx = self.allocator.create(RowCtx) catch return row;
        ctx.* = .{ .app = self, .id = id };
        _ = gtk.Button.signals.clicked.connect(edit, *RowCtx, &onRowEdit, ctx, .{});
        _ = gtk.Button.signals.clicked.connect(del, *RowCtx, &onRowDelete, ctx, .{});
        // The row owns the context; it goes when the row does.
        _ = gtk.Widget.signals.destroy.connect(row, *RowCtx, &onRowDestroy, ctx, .{});
        row.append(edit.as(gtk.Widget));
        row.append(del.as(gtk.Widget));
        return row;
    }

    const RowCtx = struct { app: *CalendarApp, id: [:0]u8 };

    fn onRowDestroy(_: *gtk.Box, ctx: *RowCtx) callconv(.c) void {
        ctx.app.allocator.free(ctx.id);
        ctx.app.allocator.destroy(ctx);
    }

    fn onRowEdit(_: *gtk.Button, ctx: *RowCtx) callconv(.c) void {
        const app = ctx.app;
        if (app.list.find(ctx.id)) |ev| editor.open(app, ev, app.selected);
    }

    fn onRowDelete(_: *gtk.Button, ctx: *RowCtx) callconv(.c) void {
        const app = ctx.app;
        const ev = app.list.find(ctx.id) orelse return;
        const Ask = struct {
            app: *CalendarApp,
            id: [:0]u8,

            fn answered(self: *@This(), index: c_int) void {
                defer self.app.allocator.destroy(self);
                defer self.app.allocator.free(self.id);
                if (index != 1) return;
                events.remove(self.app.allocator, &self.app.cfg, self.id) catch return;
                self.app.eventsChanged();
            }
        };
        const ask = app.allocator.create(Ask) catch return;
        ask.* = .{ .app = app, .id = app.allocator.dupeSentinel(u8, ev.id, 0) catch {
            app.allocator.destroy(ask);
            return;
        } };
        const title = zstr(ev.title);
        common.dialogs.choose(app.window.as(gtk.Window), common.tr("Delete this event?"), title, &.{ "Cancel", "Delete" }, 0, Ask, Ask.answered, ask);
    }

    fn onAdd(_: *gtk.Button, self: *CalendarApp) callconv(.c) void {
        editor.open(self, null, self.selected);
    }

    /// Re-reads the events after the editor or a delete changed them.
    pub fn eventsChanged(self: *CalendarApp) void {
        const fresh = events.load(self.allocator, &self.cfg) catch return;
        self.list.deinit();
        self.list = fresh;
        self.rebuildGrid();
        self.showEvents();
    }

    // ---- notes -----------------------------------------------------------------------------

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
        self.cfg.setString("notes", @ptrCast(key_z[0..self.key_len :0]), std.mem.span(text)) catch {};
    }
};

fn bufZ(buf: []u8, comptime fmt: []const u8, args: anytype) error{NoSpaceLeft}![:0]u8 {
    return std.fmt.bufPrintSentinel(buf, fmt, args, 0);
}

/// A NUL-terminated copy in a rotating static buffer, for short strings handed
/// straight to GTK (which copies them).
fn zstr(text: []const u8) [:0]const u8 {
    const Ring = struct {
        var bufs: [8][512]u8 = undefined;
        var next: usize = 0;
    };
    const buf = &Ring.bufs[Ring.next];
    Ring.next = (Ring.next + 1) % Ring.bufs.len;
    const n = @min(text.len, buf.len - 1);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    return buf[0..n :0];
}

pub fn main(init: std.process.Init.Minimal) !void {
    try common.runapp.run("org.dkde.calendar", CalendarApp, init);
}

test "date keys" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("2026-10-31", dateKey(&buf, 2026, 10, 31));
    try std.testing.expectEqualStrings("0999-01-05", dateKey(&buf, 999, 1, 5));
}

test {
    _ = @import("liturgy.zig");
    _ = @import("calsys.zig");
}
