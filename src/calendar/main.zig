//! dkde-calendar: a month calendar with events (place, date, time frame,
//! repeat, reminder), a note for any day, and optional liturgical calendars
//! laid over the days (SPEC.md 5.6). Everything is saved in
//! `~/.config/dkde/calendar.toml`. Reminders are sent by dkde-panel, which is
//! always running; this program only stores the events.

const std = @import("std");
const cli = @import("cli");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gio = @import("gio2");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const common = @import("common");
const liturgy = @import("liturgy.zig");
const editor = @import("editor.zig");
const feeds = common.feeds;
const goto = @import("goto.zig");
const calsys = @import("calsys.zig");
const lunar = @import("lunar.zig");
const rosstamp = @import("rosstamp.zig");
const native = @import("native.zig");
const pango = @import("pango1");
const rosquin = common.rosquin;
extern fn FcConfigAppFontAddFile(config: ?*anyopaque, file: [*:0]const u8) c_int;

/// The clock of the lunar site, for `lunar.Site.offset_fn` (which takes no context).
var site_zone: ?*glib.TimeZone = null;

fn siteOffset(utc_seconds: i64) i32 {
    const tz = site_zone orelse return 0;
    return tz.getOffset(@intCast(tz.findInterval(.universal, utc_seconds)));
}

/// The glyph font is part of the program, so it works wherever the program is run
/// from. It is written to the user's cache directory and registered with
/// fontconfig for this process only.
const glyph_font = @embedFile("rosquin-font");

/// Must run before GTK starts: Pango reads its font list once, when it is first used.
fn loadGlyphFont(allocator: std.mem.Allocator) void {
    const cache = std.mem.span(glib.getUserCacheDir());
    const dir = std.fmt.allocPrintSentinel(allocator, "{s}/dkde", .{cache}, 0) catch return;
    defer allocator.free(dir);
    const path = std.fmt.allocPrintSentinel(allocator, "{s}/RosquinGlyphs.ttf", .{dir}, 0) catch return;
    defer allocator.free(path);
    _ = glib.mkdirWithParents(dir, 0o755);
    var err: ?*glib.Error = null;
    if (glib.fileSetContents(path, glyph_font.ptr, glyph_font.len, &err) == 0) {
        if (err) |e| e.free();
        std.log.warn("cannot write {s}; Rosquin days will show as boxes", .{path});
        return;
    }
    if (FcConfigAppFontAddFile(null, path.ptr) == 0) std.log.warn("cannot load {s}", .{path});

    // The fonts for the native names of the other calendars, the same way.
    inline for (.{
        .{ "NativeCJK.ttf", @embedFile("font-cjk") },
        .{ "NativeHebrew.ttf", @embedFile("font-he") },
        .{ "NativeEthiopic.ttf", @embedFile("font-et") },
        .{ "NativeCoptic.ttf", @embedFile("font-cop") },
    }) |item| {
        const fpath = std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ dir, item[0] }, 0) catch return;
        defer allocator.free(fpath);
        var ferr: ?*glib.Error = null;
        if (glib.fileSetContents(fpath, item[1].ptr, item[1].len, &ferr) != 0) {
            _ = FcConfigAppFontAddFile(null, fpath.ptr);
        } else if (ferr) |e| e.free();
    }
}

/// `text` with the characters that matter in Pango markup escaped.
fn escapeInto(out: []u8, n: *usize, text: []const u8) void {
    for (text) |ch| {
        const rep: []const u8 = switch (ch) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            else => &[_]u8{ch},
        };
        if (n.* + rep.len > out.len) return;
        @memcpy(out[n.*..][0..rep.len], rep);
        n.* += rep.len;
    }
}

const branding_png = @embedFile("branding");
var branding_texture: ?*gdk.Texture = null;

/// The calendar's branding picture (on a white ground), for the first row of the 14th column. Null if it cannot be made.
fn brandingPicture(size: c_int) ?*gtk.Picture {
    if (branding_texture == null) {
        const bytes = glib.Bytes.new(branding_png.ptr, branding_png.len);
        defer bytes.unref();
        var err: ?*glib.Error = null;
        branding_texture = gdk.Texture.newFromBytes(bytes, &err);
        if (err) |e| e.free();
    }
    const texture = branding_texture orelse return null;
    const picture = gtk.Picture.newForPaintable(texture.as(gdk.Paintable));
    picture.setContentFit(.contain);
    picture.as(gtk.Widget).setSizeRequest(size, size);
    picture.as(gtk.Widget).setMarginTop(4);
    picture.as(gtk.Widget).setMarginBottom(4);
    return picture;
}

/// The look of the glyph stamp, set here so it does not depend on style.css being found.
fn installGlyphStyle() void {
    const display = gdk.Display.getDefault() orelse return;
    const provider = gtk.CssProvider.new();
    defer provider.as(gobject.Object).unref();
    provider.loadFromString(
        \\.dkde-rosglyph { font-family: "Rosquin Glyphs"; font-size: 88px; padding: 0; margin: 0; }
        \\.dkde-rosglyph.compact { font-size: 64px; }
        \\button.dkde-cal-cell.dkde-cal-ankh:not(.selected):not(.today) { background-color: #fff3e0; }
    );
    gtk.StyleContext.addProviderForDisplay(display, provider.as(gtk.StyleProvider), gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
}

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
    /// dkde.toml, where the optional online calendars are set up (in Settings).
    shared: common.Config,
    accounts: feeds.Accounts,
    /// An online refresh is running on a worker thread.
    feed_busy: bool = false,
    /// The window closed during a refresh; the refresh's callback frees the rest.
    closing: bool = false,

    // What is shown. `year` and `month` are in the calendar system `sys`.
    sys: calsys.System,
    // Where the moon phases are seen from (the [location] group of calendar.toml).
    site: lunar.Site,
    year: i32,
    month: u8,
    selected: Date,
    today: Date,
    // What the settings file holds as the default view; changing the view on screen
    // does not change it until Save as default.
    saved_sys: calsys.System = .gregorian,
    saved_no: bool = false,
    saved_tlm: bool = false,
    saved_ru: bool = false,
    saved_named: bool = true,
    save_button: ?*gtk.Button = null,
    // Show the native names (Chinese characters, Hebrew letters ...) beside the Latin ones, in
    // the built-in open-source fonts or the one the user chose.
    native_on: bool = false,
    native_font: [96]u8 = undefined,
    native_font_len: usize = 0,
    show_no: bool = false,
    show_tlm: bool = false,
    show_ru: bool = false,
    named_only: bool = true,
    twelve_hour: bool = true,
    sync_status: ?*gtk.Label = null,
    /// One per file button in the Options popover. The popover is not destroyed with the
    /// window, so a button's data cannot be freed by its destroy signal: it lives here.
    file_ctx: [3]FileCtx = undefined,
    table_no: ?liturgy.Table = null,
    table_tlm: ?liturgy.Table = null,
    table_ru: ?liturgy.Table = null,

    // Widgets.
    grid: *gtk.Grid,
    month_label: *gtk.Label,
    heading: *gtk.Label,
    alt_box: *gtk.Box,
    lit_box: *gtk.Box,
    events_box: *gtk.Box,
    text: *gtk.TextView,
    cells: [368]Cell = undefined,

    // The note being edited.
    key: [16]u8 = undefined,
    key_len: usize = 0,
    loading: bool = false,
    save_source: c_uint = 0,

    pub fn create(allocator: std.mem.Allocator, app: *gtk.Application) !*CalendarApp {
        const self = try allocator.create(CalendarApp);
        errdefer allocator.destroy(self);
        var cfg = try common.Config.load(allocator, "calendar.toml");
        errdefer cfg.deinit();
        var shared = try common.Config.load(allocator, "dkde.toml");
        errdefer shared.deinit();
        var accounts = try feeds.loadAccounts(allocator, &shared);
        errdefer accounts.deinit();
        var list = try feeds.loadAll(allocator, &cfg, accounts.items, utcToLocal);
        errdefer list.deinit();

        const now = glib.DateTime.newNowLocal() orelse return error.NoClock;
        defer now.unref();
        const today: Date = .{ .year = now.getYear(), .month = @intCast(now.getMonth()), .day = @intCast(now.getDayOfMonth()) };

        installGlyphStyle();
        const sys_text = try cfg.getString(allocator, "view", "system", "gregorian");
        defer allocator.free(sys_text);
        const sys = calsys.System.parse(sys_text);

        const zone_name = try cfg.getString(allocator, "location", "timezone", "America/Detroit");
        defer allocator.free(zone_name);
        var site: lunar.Site = .{
            .latitude = cfg.getFloat("location", "latitude", lunar.lake_odessa.latitude),
            .longitude = cfg.getFloat("location", "longitude", lunar.lake_odessa.longitude),
        };
        if (zone_name.len > 0) {
            const zone_z = try std.fmt.allocPrintSentinel(allocator, "{s}", .{zone_name}, 0);
            defer allocator.free(zone_z);
            site_zone = glib.TimeZone.new(zone_z.ptr);
            site.offset_fn = &siteOffset;
        }

        const here = calsys.fromCivil(sys, today);

        self.* = .{
            .allocator = allocator,
            .window = gtk.ApplicationWindow.new(app),
            .cfg = cfg,
            .list = list,
            .shared = shared,
            .accounts = accounts,
            .sys = sys,
            .site = site,
            .year = here.year,
            .month = calsys.pageOf(sys, here),
            .selected = today,
            .today = today,
            .grid = gtk.Grid.new(),
            .month_label = gtk.Label.new(""),
            .heading = gtk.Label.new(""),
            .alt_box = gtk.Box.new(.vertical, 6),
            .lit_box = gtk.Box.new(.vertical, 6),
            .events_box = gtk.Box.new(.vertical, 4),
            .text = gtk.TextView.new(),
        };
        self.show_no = self.cfg.getBool("view", "novus-ordo", false);
        self.show_tlm = self.cfg.getBool("view", "tlm-1962", false);
        self.show_ru = self.cfg.getBool("view", "orthodox-ru", false);
        self.named_only = self.cfg.getBool("view", "named-days-only", true);
        self.twelve_hour = self.cfg.getBool("view", "twelve-hour", true);
        self.native_on = self.cfg.getBool("view", "native-script", false);
        if (self.cfg.getString(allocator, "view", "native-font", "")) |nf| {
            defer allocator.free(nf);
            self.native_font_len = @min(nf.len, self.native_font.len);
            @memcpy(self.native_font[0..self.native_font_len], nf[0..self.native_font_len]);
        } else |_| {}
        self.saved_sys = sys;
        self.saved_no = self.show_no;
        self.saved_tlm = self.show_tlm;
        self.saved_ru = self.show_ru;
        self.saved_named = self.named_only;
        self.ensureTables();

        const window = self.window.as(gtk.Window);
        window.setTitle(common.tr("Calendar"));
        // No bigger than the first monitor, so the window always fits.
        var want_w: c_int = 1060;
        var want_h: c_int = 700;
        if (gdk.Display.getDefault()) |display| {
            const monitors = display.getMonitors();
            if (monitors.getItem(0)) |item| {
                const monitor: *gdk.Monitor = @ptrCast(@alignCast(item));
                var geometry: gdk.Rectangle = undefined;
                monitor.getGeometry(&geometry);
                if (geometry.f_width > 0) want_w = @min(want_w, geometry.f_width - 40);
                if (geometry.f_height > 0) want_h = @min(want_h, geometry.f_height - 80);
            }
        }
        window.setDefaultSize(want_w, want_h);
        self.window.as(gtk.Widget).addCssClass("dkde");
        _ = common.header.create(window, "x-office-calendar", true);

        // ---- toolbar -------------------------------------------------------------------
        const prev = gtk.Button.newFromIconName("go-previous-symbolic");
        const next = gtk.Button.newFromIconName("go-next-symbolic");
        const today_button = gtk.Button.newWithLabel(common.tr("Today"));
        const goto_button = gtk.Button.newWithLabel(common.tr("Go to\u{2026}"));
        goto_button.as(gtk.Widget).setTooltipText(common.tr("Jump to any date, past or future, by date, day code or Rosquin year"));
        _ = gtk.Button.signals.clicked.connect(goto_button, *CalendarApp, &onGoto, self, .{});
        _ = gtk.Button.signals.clicked.connect(prev, *CalendarApp, &onPrev, self, .{});
        _ = gtk.Button.signals.clicked.connect(next, *CalendarApp, &onNext, self, .{});
        _ = gtk.Button.signals.clicked.connect(today_button, *CalendarApp, &onToday, self, .{});
        var terminated = [_]?[*:0]const u8{ common.tr("Julian").ptr, common.tr("Gregorian").ptr, common.tr("Fixed (13 months)").ptr, common.tr(calsys.System.rosquin_weeks.label()).ptr, common.tr(calsys.System.rosquin_months.label()).ptr, common.tr(calsys.System.rosquin_quarters.label()).ptr, common.tr(calsys.System.chinese.label()).ptr, common.tr(calsys.System.hebrew.label()).ptr, common.tr(calsys.System.coptic.label()).ptr, common.tr(calsys.System.ethiopian.label()).ptr, null };
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

        const ru_check = gtk.CheckButton.newWithLabel(common.tr("Russian Orthodox"));
        ru_check.setActive(@intFromBool(self.show_ru));
        ru_check.as(gtk.Widget).setTooltipText(common.tr("Show the Russian Orthodox calendar (Old Calendar, Julian Pascha) and its fasts"));
        _ = gtk.CheckButton.signals.toggled.connect(ru_check, *CalendarApp, &onToggleRu, self, .{});

        const named_check = gtk.CheckButton.newWithLabel(common.tr("Named days only"));
        named_check.setActive(@intFromBool(self.named_only));
        named_check.as(gtk.Widget).setTooltipText(common.tr("In the month grid, show only Sundays, feasts, memorials and other special days, not every plain weekday"));
        _ = gtk.CheckButton.signals.toggled.connect(named_check, *CalendarApp, &onToggleNamed, self, .{});

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
        const copy_button = gtk.Button.newWithLabel(common.tr("Copy date"));
        copy_button.as(gtk.Widget).setTooltipText(common.tr("Copy the selected date as text, or its Rosquin glyph (right-click a day does the same)"));
        _ = gtk.Button.signals.clicked.connect(copy_button, *CalendarApp, &onCopyButton, self, .{});
        bar.append(goto_button.as(gtk.Widget));
        bar.append(copy_button.as(gtk.Widget));
        const save_button = gtk.Button.newWithLabel(common.tr("Save as default"));
        save_button.as(gtk.Widget).setTooltipText(common.tr("Make the calendar and the liturgical calendars shown now the ones the program opens with. Changing the view to look at something does not change the default."));
        _ = gtk.Button.signals.clicked.connect(save_button, *CalendarApp, &onSaveView, self, .{});
        self.save_button = save_button;
        // Second row, as in the Windows build: the calendar selector and everything after it.
        const bar2 = gtk.Box.new(.horizontal, 6);
        bar2.append(system_menu.as(gtk.Widget));
        bar2.append(save_button.as(gtk.Widget));
        bar2.append(spacer.as(gtk.Widget));
        // The liturgical calendars in one drop-down, so the bar never runs out of room.
        const lit_box = gtk.Box.new(.vertical, 6);
        lit_box.append(no_check.as(gtk.Widget));
        lit_box.append(tlm_check.as(gtk.Widget));
        lit_box.append(ru_check.as(gtk.Widget));
        const lit_popover = gtk.Popover.new();
        lit_popover.setChild(lit_box.as(gtk.Widget));
        const lit_menu = gtk.MenuButton.new();
        lit_menu.setLabel(common.tr("Liturgical"));
        lit_menu.as(gtk.Widget).setTooltipText(common.tr("Lay the Novus Ordo, 1962 or Russian Orthodox liturgical calendar over the days"));
        lit_menu.setPopover(lit_popover);
        bar2.append(lit_menu.as(gtk.Widget));
        const clock_check = gtk.CheckButton.newWithLabel(common.tr("12-hour clock (AM/PM)"));
        clock_check.setActive(@intFromBool(self.twelve_hour));
        _ = gtk.CheckButton.signals.toggled.connect(clock_check, *CalendarApp, &onToggleClock, self, .{});
        const native_check = gtk.CheckButton.newWithLabel(common.tr("Show native script"));
        native_check.setActive(@intFromBool(self.native_on));
        native_check.as(gtk.Widget).setTooltipText(common.tr("In the Chinese, Hebrew, Coptic and Ethiopian calendars, write the month, day and year in their own script beside the Latin names"));
        _ = gtk.CheckButton.signals.toggled.connect(native_check, *CalendarApp, &onToggleNative, self, .{});
        const font_row = gtk.Box.new(.horizontal, 6);
        const font_caption = gtk.Label.new(common.tr("Native font"));
        font_row.append(font_caption.as(gtk.Widget));
        const font_button = gtk.FontButton.new();
        font_button.as(gtk.Widget).setTooltipText(common.tr("A font of your own for the native names. Without one, the program uses the open-source fonts it carries (Noto Sans Hebrew, Ethiopic and Coptic, Droid Sans Fallback)"));
        if (self.native_font_len > 0) font_button.as(gtk.FontChooser).setFont(zstr(self.native_font[0..self.native_font_len]));
        _ = gtk.FontButton.signals.font_set.connect(font_button, *CalendarApp, &onNativeFont, self, .{});
        font_row.append(font_button.as(gtk.Widget));
        const font_reset = gtk.Button.newWithLabel(common.tr("Built-in"));
        font_reset.as(gtk.Widget).setTooltipText(common.tr("Go back to the fonts the program carries"));
        _ = gtk.Button.signals.clicked.connect(font_reset, *CalendarApp, &onNativeFontReset, self, .{});
        font_row.append(font_reset.as(gtk.Widget));
        const options_box = gtk.Box.new(.vertical, 6);
        options_box.append(named_check.as(gtk.Widget));
        options_box.append(clock_check.as(gtk.Widget));
        options_box.append(native_check.as(gtk.Widget));
        options_box.append(font_row.as(gtk.Widget));
        options_box.append(gtk.Separator.new(.horizontal).as(gtk.Widget));
        inline for (.{
            .{ "Import calendar file…", FileMode.load_file },
            .{ "Export calendar file…", FileMode.save_file },
            .{ "Choose sync file…", FileMode.set_sync },
        }, 0..) |item, ci| {
            const b = gtk.Button.newWithLabel(common.tr(item[0]));
            b.as(gtk.Widget).addCssClass("flat");
            self.file_ctx[ci] = .{ .app = self, .mode = item[1] };
            _ = gtk.Button.signals.clicked.connect(b, *FileCtx, &onFileButton, &self.file_ctx[ci], .{});
            options_box.append(b.as(gtk.Widget));
        }
        const sync_now = gtk.Button.newWithLabel(common.tr("Sync now"));
        sync_now.as(gtk.Widget).addCssClass("flat");
        _ = gtk.Button.signals.clicked.connect(sync_now, *CalendarApp, &onSyncNow, self, .{});
        options_box.append(sync_now.as(gtk.Widget));
        const online = gtk.Button.newWithLabel(common.tr("Online calendars…"));
        online.as(gtk.Widget).addCssClass("flat");
        online.as(gtk.Widget).setTooltipText(common.tr("Add or remove calendars from the internet, in Settings"));
        _ = gtk.Button.signals.clicked.connect(online, *CalendarApp, &onOnlineAccounts, self, .{});
        options_box.append(online.as(gtk.Widget));
        const status = gtk.Label.new("");
        status.setXalign(0);
        status.setWrap(1);
        status.setWrapMode(.word_char);
        status.setMaxWidthChars(20);
        status.setMaxWidthChars(32);
        status.as(gtk.Widget).addCssClass("dim-label");
        self.sync_status = status;
        options_box.append(status.as(gtk.Widget));
        const options_popover = gtk.Popover.new();
        options_popover.setChild(options_box.as(gtk.Widget));
        const options = gtk.MenuButton.new();
        options.setLabel(common.tr("Options"));
        options.setPopover(options_popover);
        bar2.append(options.as(gtk.Widget));
        bar2.append(add.as(gtk.Widget));

        // ---- month grid ----------------------------------------------------------------
        self.grid.setColumnHomogeneous(1);
        self.grid.setRowHomogeneous(0);
        self.grid.as(gtk.Widget).setHexpand(1);
        self.grid.as(gtk.Widget).setVexpand(1);
        const month_box = gtk.Box.new(.vertical, 4);
        month_box.as(gtk.Widget).setHexpand(1);
        month_box.append(bar.as(gtk.Widget));
        month_box.append(bar2.as(gtk.Widget));
        // The grid scrolls when it does not fit, so it never makes the window bigger
        // than the screen.
        const grid_scroll = gtk.ScrolledWindow.new();
        grid_scroll.setChild(self.grid.as(gtk.Widget));
        grid_scroll.setPolicy(.automatic, .automatic);
        // Room for the seven columns of an ordinary month, so the side panel (whose long date
        // lines would otherwise take the width) never hides Saturday. Wider layouts scroll.
        grid_scroll.setMinContentWidth(690);
        grid_scroll.as(gtk.Widget).setHexpand(1);
        grid_scroll.as(gtk.Widget).setVexpand(1);
        month_box.append(grid_scroll.as(gtk.Widget));

        // ---- the day panel -------------------------------------------------------------
        self.heading.setXalign(0);
        self.heading.setWrap(1);
        self.heading.as(gtk.Widget).addCssClass("title-4");
        self.heading.setWrap(1);
        self.heading.setWrapMode(.word_char);
        self.heading.setMaxWidthChars(20);
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
        // The other calendars' dates above can be tall; the events below must stay readable.
        day_scroller.setMinContentHeight(150);

        const right = gtk.Box.new(.vertical, 6);
        right.as(gtk.Widget).setSizeRequest(180, -1);
        right.as(gtk.Widget).setHexpand(0);
        right.append(self.heading.as(gtk.Widget));
        right.append(self.alt_box.as(gtk.Widget));
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

        _ = gtk.Window.signals.close_request.connect(self.window.as(gtk.Window), *CalendarApp, &onCloseRequest, self, .{});
        _ = gtk.Widget.signals.destroy.connect(self.window, *CalendarApp, &onDestroy, self, .{});
        self.syncNow(false);
        // Online calendars the user set to update on start, if their copy is old enough.
        _ = self.refreshFeeds(true);
        self.rebuildGrid();
        self.showDay();
        self.showSyncStatus();
        self.refreshSave();
        return self;
    }

    pub fn present(self: *CalendarApp) void {
        self.window.as(gtk.Window).present();
    }

    /// The note is written while the window and its text view still exist: by
    /// the time `destroy` runs, GTK has already taken the widgets apart.
    fn onCloseRequest(_: *gtk.Window, self: *CalendarApp) callconv(.c) c_int {
        self.flush();
        return 0;
    }

    fn onDestroy(_: *gtk.ApplicationWindow, self: *CalendarApp) callconv(.c) void {
        if (self.save_source != 0) {
            _ = glib.Source.remove(self.save_source);
            self.save_source = 0;
        }
        if (self.table_no) |*t| t.deinit();
        if (self.table_tlm) |*t| t.deinit();
        if (self.table_ru) |*t| t.deinit();
        if (self.feed_busy) {
            self.closing = true; // the refresh in progress frees the app when it is done
            return;
        }
        self.freeAll();
    }

    fn freeAll(self: *CalendarApp) void {
        self.list.deinit();
        self.accounts.deinit();
        self.shared.deinit();
        self.cfg.deinit();
        self.allocator.destroy(self);
    }

    // ---- liturgical overlays ---------------------------------------------------------------

    /// Loads the tables for the overlays that are on and frees the others, so
    /// a hidden overlay costs no memory.
    fn ensureTables(self: *CalendarApp) void {
        self.table_no = self.syncTable(self.table_no, self.show_no, .novus_ordo);
        self.table_tlm = self.syncTable(self.table_tlm, self.show_tlm, .tlm1962);
        self.table_ru = self.syncTable(self.table_ru, self.show_ru, .orthodox_ru);
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
        self.overlaysChanged();
    }

    fn onToggleTlm(button: *gtk.CheckButton, self: *CalendarApp) callconv(.c) void {
        self.show_tlm = button.getActive() != 0;
        self.overlaysChanged();
    }

    fn onToggleRu(button: *gtk.CheckButton, self: *CalendarApp) callconv(.c) void {
        self.show_ru = button.getActive() != 0;
        self.overlaysChanged();
    }

    fn onToggleNamed(button: *gtk.CheckButton, self: *CalendarApp) callconv(.c) void {
        self.named_only = button.getActive() != 0;
        self.rebuildGrid();
        self.refreshSave();
    }

    fn onToggleClock(button: *gtk.CheckButton, self: *CalendarApp) callconv(.c) void {
        self.twelve_hour = button.getActive() != 0;
        self.cfg.setBool("view", "twelve-hour", self.twelve_hour) catch {};
        self.rebuildGrid();
        self.showEvents();
    }

    /// Whether the view on screen differs from the saved default.
    fn viewIsDirty(self: *const CalendarApp) bool {
        return self.sys != self.saved_sys or self.show_no != self.saved_no or self.show_tlm != self.saved_tlm or
            self.show_ru != self.saved_ru or self.named_only != self.saved_named;
    }

    fn refreshSave(self: *CalendarApp) void {
        if (self.save_button) |b| b.as(gtk.Widget).setSensitive(@intFromBool(self.viewIsDirty()));
    }

    fn onSaveView(_: *gtk.Button, self: *CalendarApp) callconv(.c) void {
        self.cfg.setString("view", "system", self.sys.name()) catch {};
        self.cfg.setBool("view", "novus-ordo", self.show_no) catch {};
        self.cfg.setBool("view", "tlm-1962", self.show_tlm) catch {};
        self.cfg.setBool("view", "orthodox-ru", self.show_ru) catch {};
        self.cfg.setBool("view", "named-days-only", self.named_only) catch {};
        self.saved_sys = self.sys;
        self.saved_no = self.show_no;
        self.saved_tlm = self.show_tlm;
        self.saved_ru = self.show_ru;
        self.saved_named = self.named_only;
        self.refreshSave();
    }

    fn overlaysChanged(self: *CalendarApp) void {
        self.refreshSave();
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
        const count: i32 = calsys.monthsIn(self.sys, y);
        if (m < 1) {
            y -= 1;
            m = calsys.monthsIn(self.sys, y);
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
        if (index > 9) return;
        self.sys = @fromBackingInt(@intCast(index));
        // Show the month that holds the selected day in the new system.
        const v = calsys.fromCivil(self.sys, self.selected);
        self.year = v.year;
        self.month = calsys.pageOf(self.sys, v);
        self.rebuildGrid();
        self.showDay();
        self.refreshSave();
    }

    fn onGoto(_: *gtk.Button, self: *CalendarApp) callconv(.c) void {
        goto.open(self);
    }

    fn onToday(_: *gtk.Button, self: *CalendarApp) callconv(.c) void {
        self.selectDate(self.today);
    }

    /// Selects a day, showing its month if it is not the one on screen.
    pub fn selectDate(self: *CalendarApp, date: Date) void {
        self.flush();
        self.selected = date;
        const v = calsys.fromCivil(self.sys, date);
        self.year = v.year;
        self.month = calsys.pageOf(self.sys, v);
        self.rebuildGrid();
        self.showDay();
    }

    // ---- copying a date as text --------------------------------------------------------------

    const CopyKind = enum { text, code, glyph, both, iso };
    const CopyJob = struct { app: *CalendarApp, date: Date, kind: CopyKind, popover: *gtk.Popover };

    /// What a copy puts on the clipboard. The glyph forms are the Rosquin glyph as
    /// characters of the font RosquinGlyphs.ttf, so they only show as the glyph in a
    /// program where that font is installed and used.
    fn copyString(self: *CalendarApp, kind: CopyKind, date: Date, out: []u8) []const u8 {
        var iso: [16]u8 = undefined;
        const iso_text = events.formatDate(&iso, date);
        if (!self.sys.isRosquin()) {
            var db: [160]u8 = undefined;
            return switch (kind) {
                .iso => std.fmt.bufPrint(out, "{s}", .{iso_text}) catch "",
                else => std.fmt.bufPrint(out, "{s} ({s})", .{ calsys.describe(&db, self.sys, date), iso_text }) catch "",
            };
        }
        const layout = self.sys.layout().?;
        const line = rosquin.expand(self.allocator, "@D/@y  Yr @Y  @n @d  @N", date, layout) catch return "";
        defer self.allocator.free(line);
        var gb: [160]u8 = undefined;
        const glyph = rosstamp.glyphString(&gb, self.site, date);
        return switch (kind) {
            .text => std.fmt.bufPrint(out, "{s} ({s})", .{ line, iso_text }) catch "",
            .code => std.fmt.bufPrint(out, "{d}", .{rosquin.dayCode(date)}) catch "",
            .glyph => std.fmt.bufPrint(out, "{s}", .{glyph}) catch "",
            .both => std.fmt.bufPrint(out, "{s}  {s}", .{ glyph, line }) catch "",
            .iso => std.fmt.bufPrint(out, "{s}", .{iso_text}) catch "",
        };
    }

    fn onCopyPick(_: *gtk.Button, job: *CopyJob) callconv(.c) void {
        var buf: [512]u8 = undefined;
        const text = job.app.copyString(job.kind, job.date, &buf);
        job.app.window.as(gtk.Widget).getClipboard().setText(zstr(text));
        job.popover.popdown();
    }

    fn onCopyClosed(_: *gtk.Popover, popover: *gtk.Popover) callconv(.c) void {
        popover.as(gtk.Widget).unparent();
    }

    /// A small menu of ways to copy `date`, next to `anchor`.
    fn showCopyMenu(self: *CalendarApp, anchor: *gtk.Widget, date: Date) void {
        const popover = gtk.Popover.new();
        const box = gtk.Box.new(.vertical, 2);
        const rosq = self.sys.isRosquin();
        const items = [_]struct { kind: CopyKind, label: [:0]const u8, only_rosquin: bool }{
            .{ .kind = .text, .label = "Copy date as text", .only_rosquin = false },
            .{ .kind = .code, .label = "Copy day code", .only_rosquin = true },
            .{ .kind = .glyph, .label = "Copy glyph (needs the Rosquin font)", .only_rosquin = true },
            .{ .kind = .both, .label = "Copy glyph and text", .only_rosquin = true },
            .{ .kind = .iso, .label = "Copy date as 2026-11-06", .only_rosquin = false },
        };
        inline for (items) |item| {
            if (!item.only_rosquin or rosq) {
            const job = self.allocator.create(CopyJob) catch return;
            job.* = .{ .app = self, .date = date, .kind = item.kind, .popover = popover };
            const b = gtk.Button.newWithLabel(common.tr(item.label));
            b.as(gtk.Widget).addCssClass("flat");
            _ = gtk.Button.signals.clicked.connect(b, *CopyJob, &onCopyPick, job, .{});
            box.append(b.as(gtk.Widget));
            }
        }
        popover.setChild(box.as(gtk.Widget));
        popover.as(gtk.Widget).setParent(anchor);
        _ = gtk.Popover.signals.closed.connect(popover, *gtk.Popover, &onCopyClosed, popover, .{});
        popover.popup();
    }

    fn onCellRight(gesture: *gtk.GestureClick, _: c_int, _: f64, _: f64, cell: *Cell) callconv(.c) void {
        cell.app.selectDate(cell.date);
        const widget = gesture.as(gtk.EventController).getWidget() orelse return;
        cell.app.showCopyMenu(widget, cell.date);
    }

    fn onCopyButton(button: *gtk.Button, self: *CalendarApp) callconv(.c) void {
        self.showCopyMenu(button.as(gtk.Widget), self.selected);
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

        var title: [128]u8 = undefined;
        if (sys == .rosquin_weeks) {
            self.month_label.setText(bufZ(&title, "Yr {d} \u{b7} 28 weeks", .{self.year}) catch "");
        } else if (sys.isRosquin()) {
            self.month_label.setText(bufZ(&title, "{s} {d} \u{b7} Yr {d}", .{ calsys.monthName(sys, self.month), self.month, self.year }) catch "");
        } else {
            var mb: [48]u8 = undefined;
            var yb: [64]u8 = undefined;
            self.month_label.setText(bufZ(&title, "{s} {s}{s}", .{
                calsys.monthLabel(&mb, sys, self.year, self.month),
                calsys.yearLabel(&yb, sys, self.year),
                if (sys == .julian) " (Julian)" else "",
            }) catch "");
        }

        if (self.native_on and native.has(sys)) {
            var pb: [160]u8 = undefined;
            var mk: [640]u8 = undefined;
            const latin = std.mem.span(self.month_label.getText());
            self.month_label.setMarkup(self.withNative(&mk, latin, sys, native.pageLine(&pb, sys, self.year, self.month), "  "));
        }

        if (sys.isRosquin()) {
            // A 13-day week: days 1 to 12, then the Ankh; a 14th column holds the
            // inter-calendar days, which are in no week.
            var col: usize = 0;
            while (col < 14) : (col += 1) {
                var hb: [8]u8 = undefined;
                const l = gtk.Label.new(if (col == 13) common.tr("Inter") else if (col == 12) "\u{2625}" else (bufZ(&hb, "{d}", .{col + 1}) catch ""));
                l.as(gtk.Widget).addCssClass("dkde-cal-weekday");
                self.grid.attach(l.as(gtk.Widget), @intCast(col), 0, 1, 1);
            }
        } else {
            const heads = .{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
            inline for (heads, 0..) |n, col| {
                const l = gtk.Label.new(common.tr(n));
                l.as(gtk.Widget).addCssClass("dkde-cal-weekday");
                self.grid.attach(l.as(gtk.Widget), @intCast(col), 0, 1, 1);
            }
        }

        const first = calsys.toCivil(sys, .{ .year = self.year, .month = self.month, .day = 1 });
        const days = calsys.monthDays(sys, self.year, self.month);
        if (sys.isRosquin()) {
            // 13 columns, one row per week; Year-End Day and Leap Day get a row of their own.
            const layout = sys.layout().?;
            const len: usize = layout.monthLen();
            var i: usize = 0;
            while (i < len) : (i += 1) {
                const date = calsys.toCivil(sys, .{ .year = self.year, .month = self.month, .day = @intCast(i + 1) });
                self.placeCell(i, date, @intCast(i % 13), @intCast(i / 13 + 1), 1);
            }
            // The first row of the 14th column always carries the calendar's branding picture.
            // Where a special day falls in that row (Leap Day in month 4 of the 7-month
            // layout, Year-End Day in month 2 of the 4-month layout) it shares the cell.
            var branding_shared = false;
            // Year-End Day (week 8) and Leap Day (week 13) belong to no week and no month.
            // They stand in the 14th column, in the row of the week they fall in, on the
            // page that holds that week.
            inline for (.{ rosquin.year_end_day, rosquin.leap_day }) |day| {
                if (rosquin.pageNear(layout, day) == self.month and (day == rosquin.year_end_day or rosquin.hasLeapDay(self.year))) {
                    const date = calsys.toCivil(sys, .{ .year = self.year, .month = 0, .day = day });
                    const idx = len + (if (day == rosquin.year_end_day) @as(usize, 0) else 1);
                    if (rosquin.rowNear(layout, day) == 0) {
                        branding_shared = true;
                        const stack = gtk.Box.new(.vertical, 2);
                        if (brandingPicture(40)) |picture| stack.append(picture.as(gtk.Widget));
                        stack.append(self.cellButton(idx, date).as(gtk.Widget));
                        self.grid.attach(stack.as(gtk.Widget), 13, 1, 1, 1);
                    } else self.placeCell(idx, date, 13, @as(c_int, rosquin.rowNear(layout, day)) + 1, 1);
                }
            }
            if (!branding_shared) if (brandingPicture(72)) |picture| self.grid.attach(picture.as(gtk.Widget), 13, 1, 1, 1);
            return;
        }
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
        self.grid.attach(self.cellButton(index, date).as(gtk.Widget), col, row, span, 1);
    }

    fn cellButton(self: *CalendarApp, index: usize, date: Date) *gtk.Button {
        self.cells[index] = .{ .app = self, .date = date };
        const button = self.makeCell(date);
        _ = gtk.Button.signals.clicked.connect(button, *Cell, &onCell, &self.cells[index], .{});
        // Right click: copy this date as text.
        const right = gtk.GestureClick.new();
        right.as(gtk.GestureSingle).setButton(3);
        _ = gtk.GestureClick.signals.pressed.connect(right, *Cell, &onCellRight, &self.cells[index], .{});
        button.as(gtk.Widget).addController(right.as(gtk.EventController));
        return button;
    }

    /// The Rosquin glyph of a day: every component printed over the same box.
    fn stampWidget(self: *CalendarApp, date: Date) *gtk.Widget {
        // One label: the font's glyphs have no width, so all of them land on the same spot,
        // exactly as they do when the text is pasted into another program.
        var buf: [160]u8 = undefined;
        const l = gtk.Label.new(zstr(rosstamp.glyphString(&buf, self.site, date)));
        l.as(gtk.Widget).setHalign(.start);
        l.as(gtk.Widget).addCssClass("dkde-rosglyph");
        if (self.sys == .rosquin_weeks) l.as(gtk.Widget).addCssClass("compact"); // 28 rows: a smaller stamp keeps the page short
        return l.as(gtk.Widget);
    }

    fn makeCell(self: *CalendarApp, date: Date) *gtk.Button {
        const button = gtk.Button.new();
        const w = button.as(gtk.Widget);
        w.addCssClass("flat");
        w.addCssClass("dkde-cal-cell");
        w.setHexpand(1);
        w.setVexpand(1);
        w.setSizeRequest(if (self.sys.isRosquin()) 96 else 96, if (self.sys == .rosquin_weeks) 104 else if (self.sys.isRosquin()) 140 else 74);
        const v = calsys.fromCivil(self.sys, date);
        if (!calsys.isSpecial(self.sys, v) and (v.month != self.month or v.year != self.year)) w.addCssClass("outside");
        // Day 13 of the Rosquin week, the Ankh, has a very light orange ground.
        if (self.sys.isRosquin() and rosquin.dayOfWeek(date) == 13) w.addCssClass("dkde-cal-ankh");
        if (date.eql(self.today)) w.addCssClass("today");
        if (date.eql(self.selected)) w.addCssClass("selected");

        const box = gtk.Box.new(.vertical, 1);
        var nb: [24]u8 = undefined;
        const num = gtk.Label.new(if (calsys.isSpecial(self.sys, v)) zstr(calsys.specialName(v)) else (bufZ(&nb, "{d}", .{v.day}) catch ""));
        num.setXalign(0);
        num.as(gtk.Widget).addCssClass("dkde-cal-num");
        num.as(gtk.Widget).setHalign(.start);
        const top = gtk.Box.new(.horizontal, 4);
        if (self.sys.isRosquin()) {
            top.append(self.stampWidget(date));
            var db: [160]u8 = undefined;
            button.as(gtk.Widget).setTooltipText(zstr(calsys.describe(&db, self.sys, date)));
        } else {
            top.append(num.as(gtk.Widget));
            if (self.native_on and native.has(self.sys) and !calsys.isSpecial(self.sys, v)) {
                var db2: [32]u8 = undefined;
                const numeral = native.day(&db2, self.sys, v.day);
                if (numeral.len > 0) {
                    var mk: [320]u8 = undefined;
                    var n: usize = 0;
                    self.nativeSpan(mk[0 .. mk.len - 1], &n, self.sys, numeral);
                    mk[n] = 0;
                    const nat = gtk.Label.new(null);
                    nat.setMarkup(mk[0..n :0]);
                    nat.as(gtk.Widget).addCssClass("dim-label");
                    top.append(nat.as(gtk.Widget));
                }
            }
        }
        if (self.sys != .gregorian and !self.sys.isRosquin()) {
            // The civil date, small, at the right.
            var cb: [16]u8 = undefined;
            const civil_label = gtk.Label.new(bufZ(&cb, "{d}/{d}", .{ date.month, date.day }) catch "");
            civil_label.as(gtk.Widget).setHexpand(1);
            civil_label.setXalign(1);
            civil_label.as(gtk.Widget).addCssClass("dim-label");
            civil_label.as(gtk.Widget).addCssClass("dkde-cal-civil");
            top.append(civil_label.as(gtk.Widget));
        }
        if (self.sys.isRosquin()) {
            if (lunar.phaseOn(self.site, date)) |phase| {
                const moon = gtk.Label.new(zstr(phase.symbol()));
                moon.as(gtk.Widget).setTooltipText(zstr(phase.label()));
                top.append(moon.as(gtk.Widget));
            }
        }
        if (self.sys.isRosquin()) {
            // The day code (2026-11-06 is 18309) and the day of the year (47), which starts over on September 21.
            var kb: [24]u8 = undefined;
            const code = gtk.Label.new(bufZ(&kb, "{d} \u{b7} {d}", .{ rosquin.dayCode(date), rosquin.dayOfYear(date) }) catch "");
            code.setXalign(0);
            code.as(gtk.Widget).addCssClass("dkde-cal-num");
            // The civil date shares the line, so a cell is no wider than its glyph.
            var cb2: [16]u8 = undefined;
            const civil_small = gtk.Label.new(bufZ(&cb2, "{d}/{d}", .{ date.month, date.day }) catch "");
            civil_small.as(gtk.Widget).setHexpand(1);
            civil_small.setXalign(1);
            civil_small.as(gtk.Widget).addCssClass("dim-label");
            civil_small.as(gtk.Widget).addCssClass("dkde-cal-civil");
            const code_row = gtk.Box.new(.horizontal, 4);
            code_row.append(code.as(gtk.Widget));
            code_row.append(civil_small.as(gtk.Widget));
            box.append(code_row.as(gtk.Widget));
        }

        // The glyph hangs below the civil date line: its font draws well outside its own box,
        // so above that line it landed on the date.
        box.append(top.as(gtk.Widget));

        var day: liturgy.Day = undefined;
        if (self.table_no) |*t| self.addLitLine(box, t, date, &day);
        if (self.table_tlm) |*t| self.addLitLine(box, t, date, &day);
        if (self.table_ru) |*t| self.addLitLine(box, t, date, &day);

        var shown: usize = 0;
        var total: usize = 0;
        for (self.list.items) |*ev| {
            if (!events.occursOn(ev, date)) continue;
            total += 1;
            if (shown >= 2) continue;
            shown += 1;
            var tb: [12]u8 = undefined;
            var line: [160]u8 = undefined;
            const text = if (ev.all_day)
                bufZ(&line, "{s}", .{ev.title}) catch ""
            else
                bufZ(&line, "{s} {s}", .{ events.formatClock(&tb, ev.start, self.twelve_hour), ev.title }) catch "";
            const l = gtk.Label.new(text);
            l.setXalign(0);
            l.setEllipsize(.end);
            l.setWidthChars(4);
            l.as(gtk.Widget).addCssClass("dkde-cal-event");
            l.as(gtk.Widget).addCssClass(zstr(ev.color.cssClass()));
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
        liturgy.compute(table, date, day);
        const hide_name = self.named_only and day.plain;
        // A plain weekday keeps only its fast emoji, if it has one.
        if (hide_name and day.fast_emoji.len == 0) return;
        var buf: [256]u8 = undefined;
        const l = gtk.Label.new(if (hide_name)
            (bufZ(&buf, "{s}", .{day.fast_emoji}) catch "")
        else
            (bufZ(&buf, "{s}{s}{s}", .{ day.fast_emoji, if (day.fast_emoji.len > 0) " " else "", day.name }) catch ""));
        l.setXalign(0);
        l.setEllipsize(.end);
        l.setWidthChars(4);
        l.as(gtk.Widget).addCssClass("dkde-cal-lit");
        if (!hide_name) l.as(gtk.Widget).addCssClass(zstr(day.color.cssClass()));
        l.as(gtk.Widget).setTooltipText(zstr(if (hide_name) day.fast_text else day.name));
        box.append(l.as(gtk.Widget));
    }

    // ---- the day panel ---------------------------------------------------------------------

    // ---- native names ------------------------------------------------------------------------

    fn rawInto(out: []u8, n: *usize, s: []const u8) void {
        if (n.* + s.len > out.len) return;
        @memcpy(out[n.*..][0..s.len], s);
        n.* += s.len;
    }

    /// Markup for `text` in the font of the system's script: the user's own font first, if
    /// one was chosen, then the built-in one.
    fn nativeSpan(self: *const CalendarApp, out: []u8, n: *usize, sys: calsys.System, text: []const u8) void {
        if (text.len == 0) return;
        rawInto(out, n, "<span font_family=\"");
        if (self.native_font_len > 0) {
            for (self.native_font[0..self.native_font_len]) |ch| if (ch != '"' and ch != '<' and ch != '&') rawInto(out, n, &[_]u8{ch});
            rawInto(out, n, ",");
        }
        rawInto(out, n, native.family(sys));
        rawInto(out, n, "\">");
        escapeInto(out, n, text);
        rawInto(out, n, "</span>");
    }

    /// `latin`, then in the system's script `native_text` when that is on and there is some.
    fn withNative(self: *const CalendarApp, out: []u8, latin: []const u8, sys: calsys.System, native_text: []const u8, sep: []const u8) [:0]const u8 {
        var n: usize = 0;
        escapeInto(out[0 .. out.len - 1], &n, latin);
        if (self.native_on and native.has(sys) and native_text.len > 0) {
            rawInto(out[0 .. out.len - 1], &n, sep);
            self.nativeSpan(out[0 .. out.len - 1], &n, sys, native_text);
        }
        out[n] = 0;
        return out[0..n :0];
    }

    fn onToggleNative(button: *gtk.CheckButton, self: *CalendarApp) callconv(.c) void {
        self.native_on = button.getActive() != 0;
        self.cfg.setBool("view", "native-script", self.native_on) catch {};
        self.rebuildGrid();
        self.showDay();
    }

    fn onNativeFont(button: *gtk.FontButton, self: *CalendarApp) callconv(.c) void {
        const name = button.as(gtk.FontChooser).getFont() orelse return;
        defer glib.free(name);
        const desc = pango.FontDescription.fromString(name);
        defer desc.free();
        const fam = desc.getFamily() orelse return;
        const fam_text = std.mem.span(fam);
        self.native_font_len = @min(fam_text.len, self.native_font.len);
        @memcpy(self.native_font[0..self.native_font_len], fam_text[0..self.native_font_len]);
        self.cfg.setString("view", "native-font", zstr(fam_text)) catch {};
        self.rebuildGrid();
        self.showDay();
    }

    fn onNativeFontReset(_: *gtk.Button, self: *CalendarApp) callconv(.c) void {
        self.native_font_len = 0;
        self.cfg.setString("view", "native-font", "") catch {};
        self.rebuildGrid();
        self.showDay();
    }

    fn showDay(self: *CalendarApp) void {
        var buf: [16]u8 = undefined;
        const key = dateKey(&buf, self.selected.year, self.selected.month, self.selected.day);
        @memcpy(self.key[0..key.len], key);
        self.key_len = key.len;

        // The heading is in the chosen system; the others follow in small type.
        var hb: [96]u8 = undefined;
        {
            var nb: [160]u8 = undefined;
            var mb: [640]u8 = undefined;
            self.heading.setMarkup(self.withNative(&mb, calsys.describe(&hb, self.sys, self.selected), self.sys, native.dateLine(&nb, self.sys, self.selected), "\n"));
        }
        // The same day in the other calendars: each system's name stands out above its date.
        clearBox(self.alt_box);
        inline for (.{ calsys.System.julian, calsys.System.gregorian, calsys.System.fixed, calsys.System.rosquin_weeks, calsys.System.rosquin_months, calsys.System.rosquin_quarters, calsys.System.chinese, calsys.System.hebrew, calsys.System.coptic, calsys.System.ethiopian }) |other| {
            if (other != self.sys) {
                var tb: [96]u8 = undefined;
                const text = calsys.describe(&tb, other, self.selected);
                var nb: [160]u8 = undefined;
                var lb: [640]u8 = undefined;
                const marked = self.withNative(&lb, text, other, native.dateLine(&nb, other, self.selected), " \u{b7} ");
                const row = gtk.Box.new(.vertical, 0);
                const name = gtk.Label.new(zstr(other.label()));
                name.setXalign(0);
                name.as(gtk.Widget).addCssClass("dkde-cal-sysname");
                row.append(name.as(gtk.Widget));
                const date_label = gtk.Label.new(null);
                date_label.setMarkup(marked);
                date_label.setXalign(0);
                date_label.setWrap(1);
                date_label.setWrapMode(.word_char);
                date_label.setMaxWidthChars(20);
                row.append(date_label.as(gtk.Widget));
                self.alt_box.append(row.as(gtk.Widget));
            }
        }
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
        if (self.table_ru) |*t| self.litBlock("Russian Orthodox", t, &day);
    }

    fn litBlock(self: *CalendarApp, comptime title: [:0]const u8, table: *const liturgy.Table, day: *liturgy.Day) void {
        liturgy.compute(table, self.selected, day);
        const card = gtk.Box.new(.vertical, 2);
        const head = gtk.Label.new(common.tr(title));
        head.setXalign(0);
        head.as(gtk.Widget).addCssClass("dkde-cal-sysname");
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
        name.setWrapMode(.word_char);
        name.setMaxWidthChars(20);
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
        info.setWrapMode(.word_char);
        info.setMaxWidthChars(20);
        info.as(gtk.Widget).addCssClass("dim-label");
        card.append(info.as(gtk.Widget));

        if (day.fast_emoji.len > 0) {
            var fb: [256]u8 = undefined;
            const f = gtk.Label.new(bufZ(&fb, "{s}  {s}", .{ day.fast_emoji, day.fast_text }) catch "");
            f.setXalign(0);
            f.setWrap(1);
            f.setWrapMode(.word_char);
            f.setMaxWidthChars(20);
            card.append(f.as(gtk.Widget));
        }
        for (day.alsoLines()) |line| {
            var lb: [256]u8 = undefined;
            const l = gtk.Label.new(bufZ(&lb, "{s}: {s}", .{ line.label, line.text }) catch "");
            l.setXalign(0);
            l.setWrap(1);
            l.setWrapMode(.word_char);
            l.setMaxWidthChars(20);
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
        const dot = gtk.Box.new(.horizontal, 0);
        dot.as(gtk.Widget).addCssClass("dkde-ev-dot");
        dot.as(gtk.Widget).addCssClass(zstr(ev.color.cssClass()));
        dot.as(gtk.Widget).setValign(.start);
        dot.as(gtk.Widget).setMarginTop(5);
        row.append(dot.as(gtk.Widget));
        const text = gtk.Box.new(.vertical, 0);
        text.as(gtk.Widget).setHexpand(1);

        const title = gtk.Label.new(zstr(if (ev.title.len > 0) ev.title else "(No title)"));
        title.setXalign(0);
        title.setWrap(1);
        title.setWrapMode(.word_char);
        title.setMaxWidthChars(20);
        title.as(gtk.Widget).addCssClass("heading");
        text.append(title.as(gtk.Widget));

        var a: [12]u8 = undefined;
        var b: [12]u8 = undefined;
        var da: [16]u8 = undefined;
        var db: [16]u8 = undefined;
        var when: [160]u8 = undefined;
        const multi = !ev.date.eql(ev.end_date);
        const when_text = if (ev.all_day and multi)
            bufZ(&when, "{s} to {s}, all day", .{ events.formatDate(&da, ev.date), events.formatDate(&db, ev.end_date) }) catch ""
        else if (ev.all_day)
            "All day"
        else if (multi)
            bufZ(&when, "{s} {s} to {s} {s}", .{ events.formatDate(&da, ev.date), events.formatClock(&a, ev.start, self.twelve_hour), events.formatDate(&db, ev.end_date), events.formatClock(&b, ev.end, self.twelve_hour) }) catch ""
        else
            bufZ(&when, "{s} to {s}", .{ events.formatClock(&a, ev.start, self.twelve_hour), events.formatClock(&b, ev.end, self.twelve_hour) }) catch "";
        const when_label = gtk.Label.new(when_text);
        when_label.setXalign(0);
        text.append(when_label.as(gtk.Widget));

        if (ev.location.len > 0) {
            const loc = gtk.Label.new(zstr(ev.location));
            loc.setXalign(0);
            loc.setWrap(1);
            loc.setWrapMode(.word_char);
            loc.setMaxWidthChars(20);
            loc.as(gtk.Widget).addCssClass("dim-label");
            text.append(loc.as(gtk.Widget));
        }
        if (ev.source.len > 0) {
            var from: [96]u8 = undefined;
            const l = gtk.Label.new(bufZ(&from, "From {s}", .{self.accountName(ev.source)}) catch "Online calendar");
            l.setXalign(0);
            l.as(gtk.Widget).addCssClass("dim-label");
            text.append(l.as(gtk.Widget));
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
        // An event from an online calendar is read-only: the next update would undo an edit.
        if (ev.source.len > 0) {
            row.as(gtk.Widget).setTooltipText(common.tr("From an online calendar; change it there"));
            return row;
        }

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
        self.reloadEvents();
        self.exportToSyncFile();
        self.rebuildGrid();
        self.showEvents();
    }

    // ---- iCalendar import, export and the sync file ----------------------------------------

    const FileMode = enum { load_file, save_file, set_sync };
    const FileCtx = struct { app: *CalendarApp, mode: FileMode };

    fn onFileButton(_: *gtk.Button, ctx: *FileCtx) callconv(.c) void {
        const app = ctx.app;
        const dialog = gtk.FileDialog.new();
        defer dialog.as(gobject.Object).unref();
        switch (ctx.mode) {
            .load_file => dialog.setTitle(common.tr("Import a calendar file")),
            .save_file => dialog.setTitle(common.tr("Export the calendar")),
            .set_sync => dialog.setTitle(common.tr("Choose the file to keep in sync")),
        }
        if (ctx.mode != .load_file) dialog.setInitialName("dkde-calendar.ics");
        if (ctx.mode == .load_file) {
            dialog.open(app.window.as(gtk.Window), null, onFileChosen, ctx);
        } else {
            dialog.save(app.window.as(gtk.Window), null, onFileChosen, ctx);
        }
    }

    fn onFileChosen(source: ?*gobject.Object, result: *gio.AsyncResult, raw: ?*anyopaque) callconv(.c) void {
        const ctx: *FileCtx = @ptrCast(@alignCast(raw.?));
        const dialog: *gtk.FileDialog = @ptrCast(@alignCast(source.?));
        var err: ?*glib.Error = null;
        const file = (if (ctx.mode == .load_file) dialog.openFinish(result, &err) else dialog.saveFinish(result, &err)) orelse {
            if (err) |e| e.free(); // cancelled
            return;
        };
        defer file.as(gobject.Object).unref();
        const path = file.getPath() orelse return;
        defer glib.free(path);
        const app = ctx.app;
        const p = std.mem.span(path);
        switch (ctx.mode) {
            .load_file => {
                const n = app.importFrom(p) catch {
                    app.say("The file could not be read as a calendar.");
                    return;
                };
                var b: [64]u8 = undefined;
                app.say(bufZ(&b, "Imported {d} events.", .{n}) catch "Imported.");
            },
            .save_file => {
                app.exportTo(p) catch {
                    app.say("The calendar could not be written.");
                    return;
                };
                app.say("Calendar exported.");
            },
            .set_sync => {
                const z = app.allocator.dupeSentinel(u8, p, 0) catch return;
                defer app.allocator.free(z);
                app.cfg.setString("sync", "ics-file", z) catch {};
                app.syncNow(true);
                app.showSyncStatus();
            },
        }
    }

    fn say(self: *CalendarApp, text: []const u8) void {
        if (self.sync_status) |l| l.setText(zstr(text));
    }

    fn showSyncStatus(self: *CalendarApp) void {
        const path = self.syncPath() orelse return self.say("");
        defer self.allocator.free(path);
        var b: [400]u8 = undefined;
        self.say(bufZ(&b, "Syncing with {s}", .{path}) catch "");
    }

    fn onSyncNow(_: *gtk.Button, self: *CalendarApp) callconv(.c) void {
        const started = self.refreshFeeds(false);
        if (self.syncPath()) |p| {
            self.allocator.free(p);
            self.syncNow(true);
        } else if (!started and !self.feed_busy) {
            self.say("Nothing to sync. Choose a file, or add an online calendar in Settings.");
        }
    }

    fn onOnlineAccounts(_: *gtk.Button, _: *CalendarApp) callconv(.c) void {
        common.appinfo.spawn(std.heap.c_allocator, &.{ "dkde-settings", "--page", "online" });
    }

    /// The name the user gave an online calendar, for an account id.
    fn accountName(self: *CalendarApp, id: []const u8) []const u8 {
        for (self.accounts.items) |a| if (std.mem.eql(u8, a.id, id)) return a.name;
        return "an online calendar";
    }

    /// Updates the online calendars on a worker thread, if there are any that should be
    /// (with `only_due`, only those whose interval has passed). Returns whether a refresh
    /// started. With no accounts nothing happens at all.
    fn refreshFeeds(self: *CalendarApp, only_due: bool) bool {
        if (self.feed_busy) return false;
        self.shared.reload() catch {};
        const fresh = feeds.loadAccounts(self.allocator, &self.shared) catch return false;
        self.accounts.deinit();
        self.accounts = fresh;
        const started = feeds.Job.start(std.heap.c_allocator, self.accounts.items, only_due, &feedsDone, self) catch false;
        if (!started) {
            // The account list may have changed (one removed in Settings): show what is left.
            // At start-up the window is drawn right after, so there is nothing to redo.
            if (!only_due) {
                self.reloadEvents();
                self.rebuildGrid();
                self.showEvents();
            }
            return false;
        }
        self.feed_busy = true;
        if (!only_due) self.say("Updating online calendars…");
        return true;
    }

    fn feedsDone(job: *const feeds.Job, user: ?*anyopaque) void {
        const self: *CalendarApp = @ptrCast(@alignCast(user.?));
        self.feed_busy = false;
        if (self.closing) return self.freeAll();
        var failed: ?[]const u8 = null;
        var failed_name: []const u8 = "";
        var events_read: usize = 0;
        for (job.accounts, job.results) |acct, res| {
            if (!res.ran) continue;
            if (res.err) |e| {
                failed = feeds.describe(e);
                failed_name = acct.name;
            } else events_read += res.count;
        }
        var b: [300]u8 = undefined;
        if (failed) |why| {
            self.say(bufZ(&b, "{s}: {s}", .{ failed_name, why }) catch "An online calendar could not be updated.");
        } else self.say(bufZ(&b, "Online calendars updated: {d} events.", .{events_read}) catch "Updated.");
        // Tell the panel, which watches this file, to read the new copies for its reminders.
        if (events_read > 0 or failed == null) self.markFeedsUpdated();
        self.reloadEvents();
        self.rebuildGrid();
        self.showEvents();
    }

    fn markFeedsUpdated(self: *CalendarApp) void {
        var b: [24]u8 = undefined;
        const stamp = std.fmt.bufPrintSentinel(&b, "{d}", .{@divFloor(glib.getRealTime(), std.time.us_per_s)}, 0) catch return;
        self.cfg.setString("sync", "feeds-updated", stamp) catch {};
    }

    /// The sync file's path (owned), or null when none is set.
    fn syncPath(self: *CalendarApp) ?[]u8 {
        const p = self.cfg.getString(self.allocator, "sync", "ics-file", "") catch return null;
        if (p.len == 0) {
            self.allocator.free(p);
            return null;
        }
        return p;
    }

    fn utcToLocal(utc_minutes: i64) i64 {
        const utc = glib.DateTime.newFromUnixUtc(utc_minutes * 60) orelse return utc_minutes;
        defer utc.unref();
        const local = utc.toLocal() orelse return utc_minutes;
        defer local.unref();
        const days = civil.daysFromCivil(local.getYear(), @intCast(local.getMonth()), @intCast(local.getDayOfMonth()));
        return days * 1440 + local.getHour() * 60 + local.getMinute();
    }

    fn exportTo(self: *CalendarApp, path: []const u8) !void {
        const now = glib.DateTime.newNowUtc() orelse return error.NoClock;
        defer now.unref();
        const stamp = now.format("%Y%m%dT%H%M%SZ") orelse return error.NoClock;
        defer glib.free(stamp);
        // Events from online calendars belong to their server, not to this file.
        var own: std.ArrayList(events.Event) = .empty;
        defer own.deinit(self.allocator);
        for (self.list.items) |ev| if (ev.source.len == 0) try own.append(self.allocator, ev);
        const text = try common.ics.write(self.allocator, own.items, std.mem.span(stamp));
        defer self.allocator.free(text);
        const z = try self.allocator.dupeSentinel(u8, path, 0);
        defer self.allocator.free(z);
        var err: ?*glib.Error = null;
        if (glib.fileSetContents(z, text.ptr, @intCast(text.len), &err) == 0) {
            if (err) |e| e.free();
            return error.WriteFailed;
        }
    }

    /// Merges the events of an iCalendar file in. An event with a UID already
    /// here replaces that event; the rest are added. Returns how many were read.
    fn importFrom(self: *CalendarApp, path: []const u8) !usize {
        const z = try self.allocator.dupeSentinel(u8, path, 0);
        defer self.allocator.free(z);
        var contents: [*]u8 = undefined;
        var len: usize = 0;
        var err: ?*glib.Error = null;
        if (glib.fileGetContents(z, &contents, &len, &err) == 0) {
            if (err) |e| e.free();
            return error.ReadFailed;
        }
        defer glib.free(contents);
        var parsed = try common.ics.parse(self.allocator, contents[0..len], utcToLocal);
        defer parsed.deinit();
        const a = parsed.arena.allocator();
        for (parsed.events) |*ev| {
            var idbuf: [32]u8 = undefined;
            var uid = ev.uid;
            if (uid.len == 0) {
                var gen: [96]u8 = undefined;
                var db: [16]u8 = undefined;
                uid = try a.dupe(u8, std.fmt.bufPrint(&gen, "{s}-{s}-{d}", .{ ev.title, events.formatDate(&db, ev.date), ev.start }) catch "x");
                ev.uid = uid;
            }
            ev.id = try a.dupe(u8, common.ics.idForUid(&idbuf, uid));
        }
        try events.saveMany(self.allocator, &self.cfg, parsed.events);
        self.reloadEvents();
        return parsed.events.len;
    }

    fn reloadEvents(self: *CalendarApp) void {
        const fresh = feeds.loadAll(self.allocator, &self.cfg, self.accounts.items, utcToLocal) catch return;
        self.list.deinit();
        self.list = fresh;
    }

    fn exportToSyncFile(self: *CalendarApp) void {
        const path = self.syncPath() orelse return;
        defer self.allocator.free(path);
        self.exportTo(path) catch |err| {
            std.log.warn("sync file not written: {s}", .{@errorName(err)});
            self.say("The sync file could not be written.");
        };
    }

    /// Brings in what changed in the sync file (a phone may have edited it),
    /// then writes the merged calendar back.
    fn syncNow(self: *CalendarApp, show: bool) void {
        const path = self.syncPath() orelse return;
        defer self.allocator.free(path);
        const z = self.allocator.dupeSentinel(u8, path, 0) catch return;
        defer self.allocator.free(z);
        if (glib.fileTest(z, .{ .exists = true }) != 0) {
            const n = self.importFrom(path) catch 0;
            if (show) {
                var b: [64]u8 = undefined;
                self.say(bufZ(&b, "Synced: {d} events read.", .{n}) catch "Synced.");
            }
        }
        self.exportToSyncFile();
        if (show) {
            self.rebuildGrid();
            self.showEvents();
        }
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
    // Before GTK starts: Pango reads its font list once, when it is first used.
    loadGlyphFont(std.heap.page_allocator);
    cli.handle(init.args, .{ .name = "dkde-calendar", .summary = "Calendar" });
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
    _ = @import("lunar.zig");
    _ = @import("worldcal.zig");
    _ = @import("native.zig");
    _ = @import("goto.zig");
    _ = @import("rosstamp.zig");
    _ = @import("orthodox.zig");
    _ = @import("fasting.zig");
}
