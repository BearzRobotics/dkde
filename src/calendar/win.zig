//! The standalone Windows calendar: one .exe, no GTK, no installer, no data
//! files (the glyph font is inside it). It draws with plain Win32 and GDI and
//! shares the calendar rules with dkde-calendar (calsys.zig, lunar.zig,
//! rosstamp.zig, common/rosquin.zig). It has the month grid in the six calendar
//! systems, the Rosquin glyphs, day codes, moon phases (Lake Odessa, Michigan,
//! Eastern time) and Go to. Events, notes and the liturgical calendars are not in
//! this build. The liturgical calendars (Novus Ordo, 1962, Russian Orthodox) are
//! compiled in, as are their tables.
//!
//! It is the whole calendar, not only a viewer: events (a dialog to add, change
//! and delete them, with repeats and reminders), a note for each day,
//! import and export of .ics files and a file to keep in sync, and settings in a
//! TOML file in %APPDATA%\\dkde\\calendar.toml (the same file and the same keys
//! as the Linux calendar, so one can be copied to the other). Reminders are
//! shown while the program is open.
//!
//! Test hooks (environment): ROSQUIN_SHOT=file.bmp writes the first painted frame
//! and exits; ROSQUIN_SYS=0..9 picks the system; ROSQUIN_DATE=YYYY-MM-DD the day;
//! ROSQUIN_NATIVE=1 shows the native names; ROSQUIN_SHOW=1..7 turns on the liturgical calendars (bits: Novus Ordo, 1962, Russian).

const std = @import("std");
const common = @import("common");
const civil = common.civil;
const rosquin = common.rosquin;
const calsys = @import("calsys.zig");
const lunar = @import("lunar.zig");
const rosstamp = @import("rosstamp.zig");
const liturgy = @import("liturgy.zig");
const native = @import("native.zig");
const events = common.events;
const ics = common.ics;
const fsio = common.fsio;

const gpa = std.heap.page_allocator;

/// What the first run writes to %APPDATA%\\dkde\\calendar.toml.
const default_config = @embedFile("calendar-defaults");

const Date = civil.Date;

// ---- Win32 ---------------------------------------------------------------------------------

const HANDLE = ?*anyopaque;
const HWND = ?*anyopaque;
const HDC = ?*anyopaque;
const HGDI = ?*anyopaque;
const WPARAM = usize;
const LPARAM = isize;
const LRESULT = isize;
const WNDPROC = *const fn (HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;

const RECT = extern struct { left: i32 = 0, top: i32 = 0, right: i32 = 0, bottom: i32 = 0 };
const POINT = extern struct { x: i32 = 0, y: i32 = 0 };
const MSG = extern struct { hwnd: HWND = null, message: u32 = 0, wParam: WPARAM = 0, lParam: LPARAM = 0, time: u32 = 0, pt: POINT = .{}, lPrivate: u32 = 0 };
const WNDCLASSEXW = extern struct {
    cbSize: u32 = @sizeOf(WNDCLASSEXW),
    style: u32 = 0,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: HANDLE = null,
    hIcon: HANDLE = null,
    hCursor: HANDLE = null,
    hbrBackground: HANDLE = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: [*:0]const u16,
    hIconSm: HANDLE = null,
};
const PAINTSTRUCT = extern struct { hdc: HDC = null, fErase: i32 = 0, rcPaint: RECT = .{}, fRestore: i32 = 0, fIncUpdate: i32 = 0, rgb: [32]u8 = undefined };
const SCROLLINFO = extern struct { size: u32 = @sizeOf(SCROLLINFO), mask: u32 = 0, min: i32 = 0, max: i32 = 0, page: u32 = 0, pos: i32 = 0, track: i32 = 0 };
const LOGFONTW = extern struct {
    height: i32 = -16,
    width: i32 = 0,
    escapement: i32 = 0,
    orientation: i32 = 0,
    weight: i32 = 400,
    italic: u8 = 0,
    underline: u8 = 0,
    strike: u8 = 0,
    charset: u8 = 1,
    out_precision: u8 = 0,
    clip_precision: u8 = 0,
    quality: u8 = 0,
    pitch_family: u8 = 0,
    face: [32]u16 = @splat(0),
};
const CHOOSEFONTW = extern struct {
    size: u32 = @sizeOf(CHOOSEFONTW),
    owner: HWND = null,
    dc: HDC = null,
    log_font: *LOGFONTW,
    point_size: i32 = 0,
    flags: u32 = 0,
    colors: u32 = 0,
    cust_data: isize = 0,
    hook: ?*anyopaque = null,
    template: ?[*:0]const u16 = null,
    instance: HANDLE = null,
    style: ?[*:0]u16 = null,
    font_type: u16 = 0,
    pad: u16 = 0,
    size_min: i32 = 0,
    size_max: i32 = 0,
};
const OPENFILENAMEW = extern struct {
    lStructSize: u32 = @sizeOf(OPENFILENAMEW),
    hwndOwner: HWND = null,
    hInstance: HANDLE = null,
    lpstrFilter: ?[*:0]const u16 = null,
    lpstrCustomFilter: ?[*]u16 = null,
    nMaxCustFilter: u32 = 0,
    nFilterIndex: u32 = 1,
    lpstrFile: [*]u16,
    nMaxFile: u32,
    lpstrFileTitle: ?[*]u16 = null,
    nMaxFileTitle: u32 = 0,
    lpstrInitialDir: ?[*:0]const u16 = null,
    lpstrTitle: ?[*:0]const u16 = null,
    Flags: u32 = 0,
    nFileOffset: u16 = 0,
    nFileExtension: u16 = 0,
    lpstrDefExt: ?[*:0]const u16 = null,
    lCustData: isize = 0,
    lpfnHook: ?*anyopaque = null,
    lpTemplateName: ?[*:0]const u16 = null,
    pvReserved: ?*anyopaque = null,
    dwReserved: u32 = 0,
    FlagsEx: u32 = 0,
};
const SYSTEMTIME = extern struct { year: u16, month: u16, dow: u16, day: u16, hour: u16, minute: u16, second: u16, ms: u16 };
const BITMAPINFOHEADER = extern struct { size: u32 = 40, width: i32 = 0, height: i32 = 0, planes: u16 = 1, bits: u16 = 32, compression: u32 = 0, image: u32 = 0, xppm: i32 = 0, yppm: i32 = 0, used: u32 = 0, important: u32 = 0 };

extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.winapi) u16;
extern "user32" fn CreateWindowExW(u32, [*:0]const u16, [*:0]const u16, u32, i32, i32, i32, i32, HWND, HANDLE, HANDLE, ?*anyopaque) callconv(.winapi) HWND;
extern "user32" fn DefWindowProcW(HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn ShowWindow(HWND, i32) callconv(.winapi) i32;
extern "user32" fn UpdateWindow(HWND) callconv(.winapi) i32;
extern "user32" fn GetMessageW(*MSG, HWND, u32, u32) callconv(.winapi) i32;
extern "user32" fn TranslateMessage(*const MSG) callconv(.winapi) i32;
extern "user32" fn DispatchMessageW(*const MSG) callconv(.winapi) LRESULT;
extern "user32" fn IsDialogMessageW(HWND, *MSG) callconv(.winapi) i32;
extern "user32" fn PostQuitMessage(i32) callconv(.winapi) void;
extern "user32" fn LoadCursorW(HANDLE, usize) callconv(.winapi) HANDLE;
extern "user32" fn BeginPaint(HWND, *PAINTSTRUCT) callconv(.winapi) HDC;
extern "user32" fn EndPaint(HWND, *const PAINTSTRUCT) callconv(.winapi) i32;
extern "user32" fn GetClientRect(HWND, *RECT) callconv(.winapi) i32;
extern "user32" fn InvalidateRect(HWND, ?*const RECT, i32) callconv(.winapi) i32;
extern "user32" fn FillRect(HDC, *const RECT, HGDI) callconv(.winapi) i32;
extern "user32" fn DrawTextW(HDC, [*]const u16, i32, *RECT, u32) callconv(.winapi) i32;
extern "user32" fn CreateMenu() callconv(.winapi) HANDLE;
extern "user32" fn CreatePopupMenu() callconv(.winapi) HANDLE;
extern "user32" fn AppendMenuW(HANDLE, u32, usize, ?[*:0]const u16) callconv(.winapi) i32;
extern "user32" fn SetMenu(HWND, HANDLE) callconv(.winapi) i32;
extern "user32" fn CheckMenuRadioItem(HANDLE, u32, u32, u32, u32) callconv(.winapi) i32;
extern "user32" fn GetWindowTextW(HWND, [*]u16, i32) callconv(.winapi) i32;
extern "user32" fn SetWindowTextW(HWND, [*:0]const u16) callconv(.winapi) i32;
extern "user32" fn DestroyWindow(HWND) callconv(.winapi) i32;
extern "user32" fn SetFocus(HWND) callconv(.winapi) HWND;
extern "user32" fn SendMessageW(HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn TrackPopupMenu(HANDLE, u32, i32, i32, i32, HWND, ?*const RECT) callconv(.winapi) i32;
extern "user32" fn ClientToScreen(HWND, *POINT) callconv(.winapi) i32;
extern "user32" fn SetScrollInfo(HWND, i32, *const SCROLLINFO, i32) callconv(.winapi) i32;
extern "user32" fn SystemParametersInfoW(u32, u32, ?*anyopaque, u32) callconv(.winapi) i32;
extern "user32" fn GetDlgItem(HWND, i32) callconv(.winapi) HWND;
extern "user32" fn GetKeyState(i32) callconv(.winapi) i16;
extern "user32" fn GetDC(HWND) callconv(.winapi) HDC;
extern "user32" fn ReleaseDC(HWND, HDC) callconv(.winapi) i32;

extern "gdi32" fn CreateFontW(i32, i32, i32, i32, i32, u32, u32, u32, u32, u32, u32, u32, u32, [*:0]const u16) callconv(.winapi) HGDI;
extern "gdi32" fn SelectObject(HDC, HGDI) callconv(.winapi) HGDI;
extern "gdi32" fn DeleteObject(HGDI) callconv(.winapi) i32;
extern "gdi32" fn SetBkMode(HDC, i32) callconv(.winapi) i32;
extern "gdi32" fn SetTextColor(HDC, u32) callconv(.winapi) u32;
extern "gdi32" fn TextOutW(HDC, i32, i32, [*]const u16, i32) callconv(.winapi) i32;
extern "gdi32" fn CreateSolidBrush(u32) callconv(.winapi) HGDI;
extern "gdi32" fn CreatePen(i32, i32, u32) callconv(.winapi) HGDI;
extern "gdi32" fn Rectangle(HDC, i32, i32, i32, i32) callconv(.winapi) i32;
extern "gdi32" fn Ellipse(HDC, i32, i32, i32, i32) callconv(.winapi) i32;
extern "gdi32" fn Pie(HDC, i32, i32, i32, i32, i32, i32, i32, i32) callconv(.winapi) i32;
extern "gdi32" fn CreateCompatibleDC(HDC) callconv(.winapi) HDC;
extern "gdi32" fn CreateCompatibleBitmap(HDC, i32, i32) callconv(.winapi) HGDI;
extern "gdi32" fn BitBlt(HDC, i32, i32, i32, i32, HDC, i32, i32, u32) callconv(.winapi) i32;
extern "gdi32" fn DeleteDC(HDC) callconv(.winapi) i32;
extern "gdi32" fn AddFontMemResourceEx(*const anyopaque, u32, ?*anyopaque, *u32) callconv(.winapi) HANDLE;
extern "gdi32" fn GetDIBits(HDC, HGDI, u32, u32, ?*anyopaque, *BITMAPINFOHEADER, u32) callconv(.winapi) i32;
extern "user32" fn MessageBoxW(HWND, [*:0]const u16, [*:0]const u16, u32) callconv(.winapi) i32;
extern "user32" fn SetTimer(HWND, usize, u32, ?*anyopaque) callconv(.winapi) usize;
extern "user32" fn KillTimer(HWND, usize) callconv(.winapi) i32;
extern "user32" fn MoveWindow(HWND, i32, i32, i32, i32, i32) callconv(.winapi) i32;
extern "user32" fn ShowWindowAsync(HWND, i32) callconv(.winapi) i32;
extern "user32" fn CheckMenuItem(HANDLE, u32, u32) callconv(.winapi) u32;
extern "comdlg32" fn GetOpenFileNameW(*OPENFILENAMEW) callconv(.winapi) i32;
extern "comdlg32" fn GetSaveFileNameW(*OPENFILENAMEW) callconv(.winapi) i32;
extern "kernel32" fn GetSystemTime(*SYSTEMTIME) callconv(.winapi) void;
extern "kernel32" fn SystemTimeToTzSpecificLocalTime(?*anyopaque, *const SYSTEMTIME, *SYSTEMTIME) callconv(.winapi) i32;
extern "gdi32" fn StretchDIBits(HDC, i32, i32, i32, i32, i32, i32, i32, i32, *const anyopaque, *const BITMAPINFOHEADER, u32, u32) callconv(.winapi) i32;
extern "gdi32" fn SetStretchBltMode(HDC, i32) callconv(.winapi) i32;
extern "user32" fn OpenClipboard(HWND) callconv(.winapi) i32;
extern "user32" fn EmptyClipboard() callconv(.winapi) i32;
extern "user32" fn SetClipboardData(u32, HANDLE) callconv(.winapi) HANDLE;
extern "user32" fn CloseClipboard() callconv(.winapi) i32;
extern "kernel32" fn GlobalAlloc(u32, usize) callconv(.winapi) HANDLE;
extern "kernel32" fn GlobalLock(HANDLE) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalUnlock(HANDLE) callconv(.winapi) i32;
extern "comdlg32" fn ChooseFontW(*CHOOSEFONTW) callconv(.winapi) i32;
extern "gdi32" fn GetGlyphIndicesW(HDC, [*]const u16, i32, [*]u16, u32) callconv(.winapi) u32;
extern "gdi32" fn ExtTextOutW(HDC, i32, i32, u32, ?*const RECT, [*]const u16, u32, ?[*]const i32) callconv(.winapi) i32;
extern "gdi32" fn IntersectClipRect(HDC, i32, i32, i32, i32) callconv(.winapi) i32;
extern "gdi32" fn SelectClipRgn(HDC, HGDI) callconv(.winapi) i32;
extern "gdi32" fn GetStockObject(i32) callconv(.winapi) HGDI;

extern "kernel32" fn GetModuleHandleW(?[*:0]const u16) callconv(.winapi) HANDLE;
extern "kernel32" fn GetLocalTime(*SYSTEMTIME) callconv(.winapi) void;
extern "kernel32" fn GetEnvironmentVariableW([*:0]const u16, ?[*]u16, u32) callconv(.winapi) u32;
extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*anyopaque, u32, u32, HANDLE) callconv(.winapi) HANDLE;
extern "kernel32" fn WriteFile(HANDLE, [*]const u8, u32, *u32, ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(HANDLE) callconv(.winapi) i32;
extern "kernel32" fn ExitProcess(u32) callconv(.winapi) noreturn;

const WM_DESTROY = 0x0002;
const WM_SIZE = 0x0005;
const WM_PAINT = 0x000F;
const WM_CLOSE = 0x0010;
const WM_ERASEBKGND = 0x0014;
const WM_KEYDOWN = 0x0100;
const WM_COMMAND = 0x0111;
const WM_LBUTTONDOWN = 0x0201;
const WM_MOUSEWHEEL = 0x020A;
const WM_VSCROLL = 0x0115;
const WM_TIMER = 0x0113;
const WS_CLIPCHILDREN = 0x02000000;
const ES_MULTILINE = 0x4;
const ES_AUTOVSCROLL = 0x40;
const ES_WANTRETURN = 0x1000;
const CBS_DROPDOWNLIST = 0x3;
const BS_AUTOCHECKBOX = 0x3;
const WM_HSCROLL = 0x0114;
const WS_VSCROLL = 0x00200000;
const WS_HSCROLL = 0x00100000;
const WM_SETFONT = 0x0030;
const WS_OVERLAPPEDWINDOW = 0x00CF0000;
const WS_CAPTION_SYSMENU = 0x00C00000 | 0x00080000;
const WS_CHILD = 0x40000000;
const WS_VISIBLE = 0x10000000;
const WS_TABSTOP = 0x00010000;
const WS_BORDER = 0x00800000;
const BS_DEFPUSHBUTTON = 0x1;
const MF_STRING = 0x0;
const MF_POPUP = 0x10;
const MF_SEPARATOR = 0x800;
const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));

// ---- strings -----------------------------------------------------------------------------------

fn lit(comptime s: []const u8) [*:0]const u16 {
    @setEvalBranchQuota(100000);
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

fn wide(buf: []u16, text: []const u8) []const u16 {
    const n = std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], text) catch 0;
    buf[n] = 0;
    return buf[0..n];
}

// ---- state ---------------------------------------------------------------------------------------

const rgb = struct {
    fn c(r: u32, g: u32, b: u32) u32 {
        return r | (g << 8) | (b << 16);
    }
};

const glyph_font_data = @embedFile("rosquin-font");
/// The branding picture, 128 by 128 pixels of BGRA, top row first.
const branding_bgra = @embedFile("branding");

const Cell = struct { x: i32, y: i32, w: i32, h: i32, date: Date };

const Btn = struct { x: i32, y: i32, w: i32, h: i32, id: u16 };

const kinds = [3]liturgy.Kind{ .novus_ordo, .tlm1962, .orthodox_ru };
const kind_names = [3][]const u8{ "Novus Ordo", "Traditional (1962)", "Russian Orthodox" };

const State = struct {
    hwnd: HWND = null,
    goto: HWND = null,
    goto_edit: HWND = null,
    goto_note: HWND = null,
    sys: calsys.System = .rosquin_months,
    year: i32 = 0,
    month: u8 = 1,
    selected: Date = .{ .year = 2026, .month = 1, .day = 1 },
    today: Date = .{ .year = 2026, .month = 1, .day = 1 },
    cells: [400]Cell = undefined,
    ncells: usize = 0,
    glyph_size: i32 = 0,
    glyph_font: HGDI = null,
    shot: [260]u16 = undefined,
    shot_len: usize = 0,
    menu: HANDLE = null,
    sys_menu: HANDLE = null,
    options_menu: HANDLE = null,
    // The settings file, the events in it, and the clock style.
    cfg: ?common.Config = null,
    list: ?events.List = null,
    twelve_hour: bool = true,
    // Native names beside the Latin ones, in the built-in fonts or one the user chose.
    native_on: bool = false,
    native_font: [64]u8 = undefined,
    native_font_len: usize = 0,
    fonts_added: u32 = 0,
    // The default view in the settings file; the view on screen is only saved by Save as default.
    saved_sys: calsys.System = .gregorian,
    saved_show: [3]bool = .{ false, false, false },
    saved_named: bool = true,
    // The note of the selected day (an EDIT control) and the event editor window.
    notes: HWND = null,
    note_loading: bool = false,
    note_dirty: bool = false,
    note_key: [11:0]u8 = @splat(0),
    editor: HWND = null,
    last_check: i64 = 0,
    gui_font: HGDI = null,
    // The liturgical calendars (built in), and which are shown.
    show: [3]bool = .{ false, false, false },
    tables: [3]?liturgy.Table = .{ null, null, null },
    named_only: bool = true,
    buttons: [96]Btn = undefined,
    nbuttons: usize = 0,
    // The grid scrolls when it does not fit: its size, the visible part, and the offset.
    content_w: i32 = 0,
    content_h: i32 = 0,
    view_w: i32 = 0,
    view_h: i32 = 0,
    ox: i32 = 0,
    oy: i32 = 0,
};

var st: State = .{};

/// UTC minutes since 1970 to the PC's local minutes (daylight saving included).
fn utcToLocal(utc_minutes: i64) i64 {
    const d = civil.civilFromDays(@divFloor(utc_minutes, 1440));
    const m: i64 = @mod(utc_minutes, 1440);
    const u: SYSTEMTIME = .{ .year = @intCast(d.year), .month = d.month, .dow = 0, .day = d.day, .hour = @intCast(@divFloor(m, 60)), .minute = @intCast(@mod(m, 60)), .second = 0, .ms = 0 };
    var l: SYSTEMTIME = undefined;
    if (SystemTimeToTzSpecificLocalTime(null, &u, &l) == 0) return utc_minutes;
    return civil.daysFromCivil(l.year, @intCast(l.month), @intCast(l.day)) * 1440 + @as(i64, l.hour) * 60 + l.minute;
}

/// The PC's offset from UTC at a Unix time, for the moon phases' local day.
fn systemOffset(utc_seconds: i64) i32 {
    const utc_min = @divFloor(utc_seconds, 60);
    return @intCast((utcToLocal(utc_min) - utc_min) * 60);
}

/// Local minutes since 1970 now.
fn nowMinutes() i64 {
    var now: SYSTEMTIME = undefined;
    GetLocalTime(&now);
    return civil.daysFromCivil(now.year, @intCast(now.month), @intCast(now.day)) * 1440 + @as(i64, now.hour) * 60 + now.minute;
}

fn easternOffset(utc: i64) i32 {
    const y = civil.civilFromDays(@divFloor(utc, 86400)).year;
    const mar1 = civil.daysFromCivil(y, 3, 1);
    const start = (mar1 + @mod(7 - @as(i64, civil.weekdayOfDays(mar1)), 7) + 7) * 86400 + 7 * 3600;
    const nov1 = civil.daysFromCivil(y, 11, 1);
    const end = (nov1 + @mod(7 - @as(i64, civil.weekdayOfDays(nov1)), 7)) * 86400 + 6 * 3600;
    return if (utc >= start and utc < end) -4 * 3600 else -5 * 3600;
}

// Lake Odessa, Michigan; the day a phase falls on is the PC's own local day.
const site: lunar.Site = .{ .latitude = 42.7889, .longitude = -85.1417, .offset_fn = &systemOffset };
comptime {
    _ = &easternOffset;
}

// ---- settings and events ----------------------------------------------------------------------

/// Loads %APPDATA%\\dkde\\calendar.toml, writing the defaults first if it is not there yet.
fn loadSettings() void {
    if (common.paths.userConfigFile(gpa, "calendar.toml")) |path| {
        defer gpa.free(path);
        if (!fsio.exists(path)) {
            if (std.fs.path.dirname(path)) |dir| fsio.makePath(dir) catch {};
            fsio.writeFileAtomic(path, default_config) catch {};
        }
    } else |_| {}
    st.cfg = common.Config.load(gpa, "calendar.toml") catch null;
    const c = &(st.cfg orelse return);
    if (c.getString(gpa, "view", "system", "gregorian")) |s| {
        defer gpa.free(s);
        st.sys = calsys.System.parse(s);
    } else |_| {}
    st.show = .{ c.getBool("view", "novus-ordo", false), c.getBool("view", "tlm-1962", false), c.getBool("view", "orthodox-ru", false) };
    st.named_only = c.getBool("view", "named-days-only", true);
    st.twelve_hour = c.getBool("view", "twelve-hour", true);
    st.native_on = c.getBool("view", "native-script", false);
    if (c.getString(gpa, "view", "native-font", "")) |nf| {
        defer gpa.free(nf);
        st.native_font_len = @min(nf.len, st.native_font.len);
        @memcpy(st.native_font[0..st.native_font_len], nf[0..st.native_font_len]);
    } else |_| {}
    st.list = events.load(gpa, c) catch null;
    st.saved_sys = st.sys;
    st.saved_show = st.show;
    st.saved_named = st.named_only;
    for (st.show, 0..) |on, i| if (on) {
        st.tables[i] = liturgy.Table.load(gpa, kinds[i]) catch null;
    };
}

fn viewDirty() bool {
    return st.sys != st.saved_sys or st.named_only != st.saved_named or !std.mem.eql(bool, &st.show, &st.saved_show);
}

/// Makes the calendar, the liturgical calendars and the named-days filter on screen the
/// ones the program opens with. Looking at another calendar does not do this by itself.
fn saveView() void {
    const c = &(st.cfg orelse return);
    c.setString("view", "system", st.sys.name()) catch {};
    c.setBool("view", "novus-ordo", st.show[0]) catch {};
    c.setBool("view", "tlm-1962", st.show[1]) catch {};
    c.setBool("view", "orthodox-ru", st.show[2]) catch {};
    c.setBool("view", "named-days-only", st.named_only) catch {};
    st.saved_sys = st.sys;
    st.saved_show = st.show;
    st.saved_named = st.named_only;
    _ = InvalidateRect(st.hwnd, null, 0);
}

fn saveBool(key: [:0]const u8, value: bool) void {
    if (st.cfg) |*c| c.setBool("view", key, value) catch {};
}

fn reloadEvents() void {
    const c = &(st.cfg orelse return);
    const fresh = events.load(gpa, c) catch return;
    if (st.list) |*old| old.deinit();
    st.list = fresh;
    _ = InvalidateRect(st.hwnd, null, 0);
}

fn eventColor(c: events.Color) u32 {
    return switch (c) {
        .default => rgb.c(70, 130, 215),
        .red => rgb.c(215, 80, 80),
        .orange => rgb.c(235, 140, 50),
        .yellow => rgb.c(225, 190, 40),
        .green => rgb.c(80, 170, 90),
        .teal => rgb.c(50, 165, 160),
        .blue => rgb.c(60, 100, 220),
        .purple => rgb.c(150, 90, 200),
        .pink => rgb.c(225, 110, 170),
        .gray => rgb.c(130, 130, 130),
    };
}

// ---- navigation ----------------------------------------------------------------------------------

fn select(date: Date) void {
    flushNote();
    st.selected = date;
    if (st.notes != null) loadNote(date);
    const v = calsys.fromCivil(st.sys, date);
    const page = calsys.pageOf(st.sys, v);
    if (v.year != st.year or page != st.month) {
        st.ox = 0;
        st.oy = 0;
    }
    st.year = v.year;
    st.month = page;
    _ = InvalidateRect(st.hwnd, null, 0);
}

fn shiftPage(delta: i32) void {
    var m: i32 = @as(i32, st.month) + delta;
    const count: i32 = calsys.monthsIn(st.sys, st.year);
    if (m < 1) {
        st.year -= 1;
        m = calsys.monthsIn(st.sys, st.year);
    } else if (m > count) {
        m = 1;
        st.year += 1;
    }
    st.month = @intCast(m);
    st.ox = 0;
    st.oy = 0;
    _ = InvalidateRect(st.hwnd, null, 0);
}

fn setSystem(index: usize) void {
    if (index > 9) return;
    st.sys = @enumFromInt(index);
    _ = CheckMenuRadioItem(st.sys_menu, 100, 109, @intCast(100 + index), 0);
    select(st.selected);
}

/// The next or previous Leap Day or Year-End Day from the selected day.
fn stepSpecial(day: u16, forward: bool) void {
    const here = st.selected.days();
    const year = rosquin.fromCivil(.weeks, st.selected).year;
    var best: ?Date = null;
    var y: i32 = year - 9;
    while (y <= year + 9) : (y += 1) {
        if (day == rosquin.leap_day and !rosquin.hasLeapDay(y)) continue;
        const date = rosquin.toCivil(.weeks, .{ .year = y, .month = 0, .day = day });
        const n = date.days();
        if (forward) {
            if (n > here and (best == null or n < best.?.days())) best = date;
        } else {
            if (n < here and (best == null or n > best.?.days())) best = date;
        }
    }
    if (best) |b| select(b);
}

// ---- notes ---------------------------------------------------------------------------------------

fn utf8Of(buf: []u8, text16: []const u16) []const u8 {
    const n = std.unicode.utf16LeToUtf8(buf, text16) catch 0;
    return buf[0..n];
}

fn noteKeyOf(date: Date) [11:0]u8 {
    var k: [11:0]u8 = @splat(0);
    _ = std.fmt.bufPrint(k[0..10], "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u32, @intCast(@max(date.year, 0))), date.month, date.day }) catch {};
    return k;
}

/// Saves the visible note if it changed.
fn flushNote() void {
    _ = KillTimer(st.hwnd, 2);
    if (!st.note_dirty or st.notes == null) return;
    st.note_dirty = false;
    var w16: [4096]u16 = undefined;
    const n: usize = @intCast(GetWindowTextW(st.notes, &w16, 4096));
    var u8b: [12288]u8 = undefined;
    const text = utf8Of(&u8b, w16[0..n]);
    u8b[text.len] = 0;
    if (st.cfg) |*c| c.setString("notes", &st.note_key, u8b[0..text.len :0]) catch {};
}

fn loadNote(date: Date) void {
    st.note_key = noteKeyOf(date);
    if (st.notes == null) return;
    st.note_dirty = false;
    st.note_loading = true;
    defer st.note_loading = false;
    var text16: [4096]u16 = undefined;
    var empty = true;
    if (st.cfg) |*c| {
        if (c.getString(gpa, "notes", &st.note_key, "")) |s| {
            defer gpa.free(s);
            if (s.len > 0) {
                const w = wide(&text16, s);
                _ = w;
                empty = false;
            }
        } else |_| {}
    }
    if (empty) text16[0] = 0;
    _ = SetWindowTextW(st.notes, @ptrCast(&text16));
}

fn layoutNotes(w: i32, h: i32) void {
    if (st.notes == null) return;
    if (w <= 760) {
        _ = ShowWindowAsync(st.notes, 0);
        return;
    }
    _ = ShowWindowAsync(st.notes, 5);
    _ = MoveWindow(st.notes, w - 330 + 4, h - 8 - 150, 330 - 20, 150, 1);
}

// ---- events: the editor ------------------------------------------------------------------------

const ID_TITLE = 10;
const ID_PLACE = 11;
const ID_DATE = 12;
const ID_END = 13;
const ID_ALLDAY = 14;
const ID_START = 15;
const ID_ENDT = 16;
const ID_REPEAT = 17;
const ID_REMIND = 18;
const ID_COLOR = 19;
const ID_NOTES = 20;

const remind_minutes = [_]i32{ -1, 0, 5, 10, 15, 30, 60, 120, 1440, 2880, 10080 };
const remind_labels = [_][*:0]const u16{ lit("No reminder"), lit("At the start"), lit("5 minutes before"), lit("10 minutes before"), lit("15 minutes before"), lit("30 minutes before"), lit("1 hour before"), lit("2 hours before"), lit("1 day before"), lit("2 days before"), lit("1 week before") };
const repeat_labels = [_][*:0]const u16{ lit("Does not repeat"), lit("Daily"), lit("Weekly"), lit("Monthly"), lit("Yearly") };
const color_labels = [_][*:0]const u16{ lit("Default"), lit("Red"), lit("Orange"), lit("Yellow"), lit("Green"), lit("Teal"), lit("Blue"), lit("Purple"), lit("Pink"), lit("Gray") };

/// The event being edited: its id and uid when it exists already.
var ed_id: [64]u8 = undefined;
var ed_id_len: usize = 0;
var ed_uid: [128]u8 = undefined;
var ed_uid_len: usize = 0;

fn child(parent: HWND, class: [*:0]const u16, title: [*:0]const u16, style: u32, x: i32, y: i32, w: i32, h: i32, id: usize) HWND {
    const inst = GetModuleHandleW(null);
    const c = CreateWindowExW(if (class[0] == 'E') 0x200 else 0, class, title, WS_CHILD | WS_VISIBLE | style, x, y, w, h, parent, @ptrFromInt(id), inst, null);
    if (st.gui_font != null) _ = SendMessageW(c, WM_SETFONT, @intFromPtr(st.gui_font), 1);
    return c;
}

fn caption(parent: HWND, text16: [*:0]const u16, x: i32, y: i32) void {
    _ = child(parent, lit("STATIC"), text16, 0, x, y + 3, 90, 20, 0);
}

fn dlgItem(parent: HWND, id: usize) HWND {
    return GetDlgItem(parent, @intCast(id));
}

fn setText8(parent: HWND, id: usize, s: []const u8) void {
    var b: [2048]u16 = undefined;
    const w = wide(&b, s);
    _ = w;
    _ = SetWindowTextW(dlgItem(parent, id), @ptrCast(&b));
}

fn getText8(parent: HWND, id: usize, out: []u8) []const u8 {
    var b: [2048]u16 = undefined;
    const n: usize = @intCast(GetWindowTextW(dlgItem(parent, id), &b, 2048));
    return utf8Of(out, b[0..n]);
}

fn combo(parent: HWND, id: usize, items: []const [*:0]const u16, x: i32, y: i32, w: i32, sel: usize) void {
    const c = child(parent, lit("COMBOBOX"), lit(""), CBS_DROPDOWNLIST | WS_TABSTOP | 0x200000, x, y, w, 240, id);
    for (items) |it| _ = SendMessageW(c, 0x143, 0, @bitCast(@intFromPtr(it)));
    _ = SendMessageW(c, 0x14E, sel, 0);
}

fn comboSel(parent: HWND, id: usize) usize {
    const v = SendMessageW(dlgItem(parent, id), 0x147, 0, 0);
    return if (v < 0) 0 else @intCast(v);
}

fn openEditor(existing: ?*const events.Event, date: Date) void {
    if (st.editor != null) {
        _ = SetFocus(st.editor);
        return;
    }
    const inst = GetModuleHandleW(null);
    const w = CreateWindowExW(0, lit("RosquinEvent"), if (existing != null) lit("Edit event") else lit("New event"), WS_CAPTION_SYSMENU | WS_VISIBLE, 160, 120, 500, 470, st.hwnd, null, inst, null);
    st.editor = w;
    var ev: events.Event = .{ .id = "", .title = "", .date = date, .end_date = date };
    if (existing) |e| ev = e.*;
    ed_id_len = 0;
    ed_uid_len = 0;
    if (existing) |e| {
        ed_id_len = @min(e.id.len, ed_id.len);
        @memcpy(ed_id[0..ed_id_len], e.id[0..ed_id_len]);
        ed_uid_len = @min(e.uid.len, ed_uid.len);
        @memcpy(ed_uid[0..ed_uid_len], e.uid[0..ed_uid_len]);
    }
    caption(w, lit("Title"), 12, 12);
    _ = child(w, lit("EDIT"), lit(""), WS_TABSTOP | WS_BORDER, 110, 12, 370, 24, ID_TITLE);
    caption(w, lit("Place"), 12, 46);
    _ = child(w, lit("EDIT"), lit(""), WS_TABSTOP | WS_BORDER, 110, 46, 370, 24, ID_PLACE);
    caption(w, lit("Date"), 12, 80);
    _ = child(w, lit("EDIT"), lit(""), WS_TABSTOP | WS_BORDER, 110, 80, 110, 24, ID_DATE);
    caption(w, lit("to"), 236, 80);
    _ = child(w, lit("EDIT"), lit(""), WS_TABSTOP | WS_BORDER, 262, 80, 110, 24, ID_END);
    _ = child(w, lit("BUTTON"), lit("All day"), BS_AUTOCHECKBOX | WS_TABSTOP, 110, 114, 90, 22, ID_ALLDAY);
    caption(w, lit("Start"), 212, 114);
    _ = child(w, lit("EDIT"), lit(""), WS_TABSTOP | WS_BORDER, 258, 112, 60, 24, ID_START);
    caption(w, lit("End"), 332, 114);
    _ = child(w, lit("EDIT"), lit(""), WS_TABSTOP | WS_BORDER, 366, 112, 60, 24, ID_ENDT);
    caption(w, lit("Repeat"), 12, 148);
    combo(w, ID_REPEAT, &repeat_labels, 110, 148, 200, @intFromEnum(ev.repeat));
    caption(w, lit("Reminder"), 12, 182);
    var rsel: usize = 0;
    for (remind_minutes, 0..) |m, i| if (m == ev.remind) {
        rsel = i;
    };
    combo(w, ID_REMIND, &remind_labels, 110, 182, 200, rsel);
    caption(w, lit("Colour"), 12, 216);
    combo(w, ID_COLOR, &color_labels, 110, 216, 200, @intFromEnum(ev.color));
    caption(w, lit("Notes"), 12, 250);
    _ = child(w, lit("EDIT"), lit(""), WS_TABSTOP | WS_BORDER | ES_MULTILINE | ES_AUTOVSCROLL | ES_WANTRETURN | WS_VSCROLL, 110, 250, 370, 120, ID_NOTES);
    _ = child(w, lit("BUTTON"), lit("Save"), WS_TABSTOP | BS_DEFPUSHBUTTON, 290, 390, 90, 28, 1);
    _ = child(w, lit("BUTTON"), lit("Cancel"), WS_TABSTOP, 390, 390, 90, 28, 2);
    if (existing != null) _ = child(w, lit("BUTTON"), lit("Delete"), WS_TABSTOP, 12, 390, 90, 28, 3);

    var db: [16]u8 = undefined;
    var tb: [8]u8 = undefined;
    setText8(w, ID_TITLE, ev.title);
    setText8(w, ID_PLACE, ev.location);
    setText8(w, ID_DATE, events.formatDate(&db, ev.date));
    setText8(w, ID_END, events.formatDate(&db, ev.end_date));
    setText8(w, ID_START, events.formatTime(&tb, ev.start));
    setText8(w, ID_ENDT, events.formatTime(&tb, ev.end));
    setText8(w, ID_NOTES, ev.notes);
    _ = SendMessageW(dlgItem(w, ID_ALLDAY), 0xF1, @intFromBool(ev.all_day), 0);
    _ = SetFocus(dlgItem(w, ID_TITLE));
}

fn saveEditor() void {
    const w = st.editor;
    const c = &(st.cfg orelse return);
    var b1: [512]u8 = undefined;
    var b2: [512]u8 = undefined;
    var b3: [4096]u8 = undefined;
    var b4: [32]u8 = undefined;
    var b5: [32]u8 = undefined;
    var b6: [32]u8 = undefined;
    var b7: [32]u8 = undefined;
    const title = std.mem.trim(u8, getText8(w, ID_TITLE, &b1), " \t");
    if (title.len == 0) {
        _ = MessageBoxW(w, lit("Please give the event a title."), lit("Event"), 0x30);
        return;
    }
    const date = events.parseDate(std.mem.trim(u8, getText8(w, ID_DATE, &b4), " ")) orelse {
        _ = MessageBoxW(w, lit("The date must look like 2026-11-06."), lit("Event"), 0x30);
        return;
    };
    const end_text = std.mem.trim(u8, getText8(w, ID_END, &b5), " ");
    const end_date = if (end_text.len == 0) date else (events.parseDate(end_text) orelse {
        _ = MessageBoxW(w, lit("The end date must look like 2026-11-06."), lit("Event"), 0x30);
        return;
    });
    if (end_date.days() < date.days()) {
        _ = MessageBoxW(w, lit("The event cannot end before it starts."), lit("Event"), 0x30);
        return;
    }
    const all_day = SendMessageW(dlgItem(w, ID_ALLDAY), 0xF0, 0, 0) == 1;
    const start = events.parseTime(std.mem.trim(u8, getText8(w, ID_START, &b6), " ")) orelse if (all_day) @as(u16, 540) else {
        _ = MessageBoxW(w, lit("The start time must look like 09:00."), lit("Event"), 0x30);
        return;
    };
    const end = events.parseTime(std.mem.trim(u8, getText8(w, ID_ENDT, &b7), " ")) orelse if (all_day) @as(u16, 600) else {
        _ = MessageBoxW(w, lit("The end time must look like 10:00."), lit("Event"), 0x30);
        return;
    };
    var idbuf: [32]u8 = undefined;
    var id: []const u8 = ed_id[0..ed_id_len];
    if (id.len == 0) {
        var now: SYSTEMTIME = undefined;
        GetSystemTime(&now);
        const secs = civil.daysFromCivil(now.year, @intCast(now.month), @intCast(now.day)) * 86400 + @as(i64, now.hour) * 3600 + @as(i64, now.minute) * 60 + now.second;
        id = events.newId(&idbuf, secs * 1000000 + @as(i64, now.ms) * 1000);
    }
    const ev: events.Event = .{
        .id = id,
        .uid = ed_uid[0..ed_uid_len],
        .title = title,
        .location = std.mem.trim(u8, getText8(w, ID_PLACE, &b2), " \t"),
        .notes = getText8(w, ID_NOTES, &b3),
        .date = date,
        .end_date = end_date,
        .all_day = all_day,
        .start = start,
        .end = end,
        .repeat = @enumFromInt(@min(comboSel(w, ID_REPEAT), 4)),
        .color = @enumFromInt(@min(comboSel(w, ID_COLOR), 9)),
        .remind = remind_minutes[@min(comboSel(w, ID_REMIND), remind_minutes.len - 1)],
    };
    events.save(gpa, c, ev) catch {
        _ = MessageBoxW(w, lit("The event could not be saved."), lit("Event"), 0x10);
        return;
    };
    reloadEvents();
    _ = DestroyWindow(w);
}

fn deleteEvent(id: []const u8) void {
    const c = &(st.cfg orelse return);
    if (MessageBoxW(st.hwnd, lit("Delete this event?"), lit("Delete"), 0x34) != 6) return; // YES/NO + warning
    events.remove(gpa, c, id) catch {};
    reloadEvents();
}

fn editorProc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) callconv(.winapi) LRESULT {
    switch (msg) {
        WM_COMMAND => {
            const id = wp & 0xFFFF;
            if (id == 1) saveEditor();
            if (id == 2) _ = DestroyWindow(hwnd);
            if (id == 3) {
                const keep = ed_id[0..ed_id_len];
                _ = DestroyWindow(hwnd);
                deleteEvent(keep);
            }
            return 0;
        },
        WM_CLOSE => {
            _ = DestroyWindow(hwnd);
            return 0;
        },
        WM_DESTROY => {
            st.editor = null;
            return 0;
        },
        else => return DefWindowProcW(hwnd, msg, wp, lp),
    }
}

// ---- import, export and sync -----------------------------------------------------------------

fn pickFile(save: bool, out: *[520]u16) ?[]const u8 {
    return pickFileOf(save, out, lit("iCalendar files (*.ics)\x00*.ics\x00All files\x00*.*\x00"), lit("ics"));
}

fn pickFileOf(save: bool, out: *[520]u16, filter: [*:0]const u16, ext: [*:0]const u16) ?[]const u8 {
    var ofn: OPENFILENAMEW = .{
        .hwndOwner = st.hwnd,
        .lpstrFilter = filter,
        .lpstrFile = out,
        .nMaxFile = 520,
        .lpstrDefExt = ext,
        .Flags = if (save) 0x2 | 0x800 | 0x8 else 0x1000 | 0x800 | 0x8,
    };
    const ok = if (save) GetSaveFileNameW(&ofn) else GetOpenFileNameW(&ofn);
    if (ok == 0) return null;
    var n: usize = 0;
    while (out[n] != 0) n += 1;
    var u8b: [1600]u8 = undefined;
    const text = utf8Of(&u8b, out[0..n]);
    return gpa.dupe(u8, text) catch null;
}

/// Merges the events of an iCalendar file in: an event with a UID already here
/// replaces that event, the others are added. Returns how many were read.
fn importFrom(path: []const u8) !usize {
    const c = &(st.cfg orelse return error.NoSettings);
    const text = (try fsio.readFile(gpa, path, 8 << 20)) orelse return error.ReadFailed;
    defer gpa.free(text);
    var parsed = try ics.parse(gpa, text, &utcToLocal);
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
        ev.id = try a.dupe(u8, ics.idForUid(&idbuf, uid));
    }
    try events.saveMany(gpa, c, parsed.events);
    reloadEvents();
    return parsed.events.len;
}

fn exportTo(path: []const u8) !void {
    const list = st.list orelse return;
    var now: SYSTEMTIME = undefined;
    GetSystemTime(&now);
    var stamp: [20]u8 = undefined;
    const s = std.fmt.bufPrint(&stamp, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{ now.year, now.month, now.day, now.hour, now.minute, now.second }) catch "19700101T000000Z";
    const text = try ics.write(gpa, list.items, s);
    defer gpa.free(text);
    try fsio.writeFileAtomic(path, text);
}

fn syncPath() ?[]u8 {
    const c = &(st.cfg orelse return null);
    const p = c.getString(gpa, "sync", "ics-file", "") catch return null;
    if (p.len == 0) {
        gpa.free(p);
        return null;
    }
    return p;
}

fn syncNow(show: bool) void {
    const path = syncPath() orelse {
        if (show) _ = MessageBoxW(st.hwnd, lit("Choose a file to keep in sync first (File, Choose sync file)."), lit("Sync"), 0x40);
        return;
    };
    defer gpa.free(path);
    var read: usize = 0;
    if (fsio.exists(path)) read = importFrom(path) catch 0;
    exportTo(path) catch {};
    if (show) {
        var mb: [96]u8 = undefined;
        var w16: [96]u16 = undefined;
        const msg = wide(&w16, std.fmt.bufPrint(&mb, "Synced: {d} events read.", .{read}) catch "Synced.");
        _ = msg;
        _ = MessageBoxW(st.hwnd, @ptrCast(&w16), lit("Sync"), 0x40);
    }
}

fn menuImport() void {
    var buf: [520]u16 = undefined;
    buf[0] = 0;
    const path = pickFile(false, &buf) orelse return;
    defer gpa.free(path);
    const n = importFrom(path) catch {
        _ = MessageBoxW(st.hwnd, lit("That file could not be read as a calendar."), lit("Import"), 0x10);
        return;
    };
    var mb: [96]u8 = undefined;
    var w16: [96]u16 = undefined;
    _ = wide(&w16, std.fmt.bufPrint(&mb, "{d} events read.", .{n}) catch "Imported.");
    _ = MessageBoxW(st.hwnd, @ptrCast(&w16), lit("Import"), 0x40);
}

fn menuExport() void {
    var buf: [520]u16 = undefined;
    buf[0] = 0;
    const name = lit("dkde-calendar.ics");
    var i: usize = 0;
    while (name[i] != 0) : (i += 1) buf[i] = name[i];
    buf[i] = 0;
    const path = pickFile(true, &buf) orelse return;
    defer gpa.free(path);
    exportTo(path) catch {
        _ = MessageBoxW(st.hwnd, lit("The file could not be written."), lit("Export"), 0x10);
    };
}

fn menuChooseSync() void {
    var buf: [520]u16 = undefined;
    buf[0] = 0;
    const path = pickFile(true, &buf) orelse return;
    defer gpa.free(path);
    const z = gpa.dupeSentinel(u8, path, 0) catch return;
    defer gpa.free(z);
    if (st.cfg) |*c| c.setString("sync", "ics-file", z) catch {};
    syncNow(true);
}

// ---- copying a date as text ------------------------------------------------------------------

const CopyKind = enum { text, code, glyph, both, iso };

fn clipboardSet(text16: []const u16) void {
    if (OpenClipboard(st.hwnd) == 0) return;
    defer _ = CloseClipboard();
    _ = EmptyClipboard();
    const mem = GlobalAlloc(0x2, (text16.len + 1) * 2) orelse return; // GMEM_MOVEABLE
    const ptr: [*]u16 = @ptrCast(@alignCast(GlobalLock(mem) orelse return));
    @memcpy(ptr[0..text16.len], text16);
    ptr[text16.len] = 0;
    _ = GlobalUnlock(mem);
    _ = SetClipboardData(13, mem); // CF_UNICODETEXT
}

/// Puts the selected date on the clipboard. The glyph forms are the Rosquin glyph as
/// characters of RosquinGlyphs.ttf: they show as the glyph only in a program where that
/// font is installed and used (File, Save the Rosquin font).
fn copyDate(kind: CopyKind) void {
    const date = st.selected;
    var iso: [16]u8 = undefined;
    const iso_text = events.formatDate(&iso, date);
    var out: [600]u8 = undefined;
    const text: []const u8 = blk: {
        if (!st.sys.isRosquin()) {
            var db: [200]u8 = undefined;
            break :blk switch (kind) {
                .iso => std.fmt.bufPrint(&out, "{s}", .{iso_text}) catch "",
                else => std.fmt.bufPrint(&out, "{s} ({s})", .{ calsys.describe(&db, st.sys, date), iso_text }) catch "",
            };
        }
        const line = rosquin.expand(gpa, "@D/@y  Yr @Y  @n @d  @N", date, st.sys.layout().?) catch break :blk "";
        defer gpa.free(line);
        var gb: [160]u8 = undefined;
        const glyph = rosstamp.glyphString(&gb, site, date);
        break :blk switch (kind) {
            .text => std.fmt.bufPrint(&out, "{s} ({s})", .{ line, iso_text }) catch "",
            .code => std.fmt.bufPrint(&out, "{d}", .{rosquin.dayCode(date)}) catch "",
            .glyph => std.fmt.bufPrint(&out, "{s}", .{glyph}) catch "",
            .both => std.fmt.bufPrint(&out, "{s}  {s}", .{ glyph, line }) catch "",
            .iso => std.fmt.bufPrint(&out, "{s}", .{iso_text}) catch "",
        };
    };
    var w16: [700]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&w16, text) catch return;
    clipboardSet(w16[0..n]);
}

/// The copy menu, at a screen position (a right click, or the Copy date button).
fn showCopyMenu(x: i32, y: i32) void {
    const m = CreatePopupMenu();
    _ = AppendMenuW(m, MF_STRING, 400, lit("Copy date as text\tCtrl+C"));
    if (st.sys.isRosquin()) {
        _ = AppendMenuW(m, MF_STRING, 401, lit("Copy day code"));
        _ = AppendMenuW(m, MF_STRING, 402, lit("Copy glyph (needs the Rosquin font)"));
        _ = AppendMenuW(m, MF_STRING, 403, lit("Copy glyph and text"));
    }
    _ = AppendMenuW(m, MF_STRING, 404, lit("Copy date as 2026-11-06"));
    _ = TrackPopupMenu(m, 0, x, y, 0, st.hwnd, null);
}

fn menuSaveFont() void {
    var buf: [520]u16 = undefined;
    const name = lit("RosquinGlyphs.ttf");
    var i: usize = 0;
    while (name[i] != 0) : (i += 1) buf[i] = name[i];
    buf[i] = 0;
    const path = pickFileOf(true, &buf, lit("TrueType fonts (*.ttf)\x00*.ttf\x00"), lit("ttf")) orelse return;
    defer gpa.free(path);
    fsio.writeFileAtomic(path, glyph_font_data) catch {
        _ = MessageBoxW(st.hwnd, lit("The font could not be written."), lit("Rosquin font"), 0x10);
        return;
    };
    _ = MessageBoxW(st.hwnd, lit("Saved. Right-click the file and choose Install (or Install for all users), then pick the font \"Rosquin Glyphs\" in the program where you paste a copied glyph."), lit("Rosquin font"), 0x40);
}

// ---- reminders -----------------------------------------------------------------------------------

/// Called every few seconds: shows the reminders that came due since the last look.
fn checkReminders() void {
    const list = st.list orelse return;
    const now = nowMinutes();
    if (st.last_check == 0) st.last_check = now - 1;
    if (now <= st.last_check) return;
    const fires = events.firesBetween(gpa, list.items, st.last_check, now) catch return;
    defer gpa.free(fires);
    st.last_check = now;
    if (fires.len == 0) return;
    var msg: [1500]u8 = undefined;
    var used: usize = 0;
    for (fires) |f| {
        const ev = &list.items[f.event];
        var db: [16]u8 = undefined;
        var tb: [24]u8 = undefined;
        const line = std.fmt.bufPrint(msg[used..], "{s}{s}  ({s}{s}{s})", .{
            if (used > 0) "\n" else "",
            ev.title,
            events.formatDate(&db, f.start),
            if (ev.all_day) "" else " ",
            if (ev.all_day) "" else events.formatClock(&tb, ev.start, st.twelve_hour),
        }) catch break;
        used += line.len;
    }
    var w16: [1500]u16 = undefined;
    _ = wide(&w16, msg[0..used]);
    _ = MessageBoxW(st.hwnd, @ptrCast(&w16), lit("Reminder"), 0x40 | 0x10000 | 0x40000);
}

// ---- go to -------------------------------------------------------------------------------------

/// "2028-02-29", "18789" (a day code) or "51 366" (Rosquin year and day of the year).
fn parseGoto(text: []const u8) ?Date {
    var nums: [3]i64 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] < '0' or text[i] > '9') {
            i += 1;
            continue;
        }
        var v: i64 = 0;
        while (i < text.len and text[i] >= '0' and text[i] <= '9') : (i += 1) v = v * 10 + (text[i] - '0');
        if (n == 3) return null;
        nums[n] = v;
        n += 1;
    }
    switch (n) {
        1 => return Date.fromDays(nums[0] - 1 + civil.daysFromCivil(rosquin.epoch_year, 9, 21)),
        2 => {
            const year: i32 = @intCast(nums[0]);
            const doy = nums[1];
            if (doy == 365) return rosquin.toCivil(.weeks, .{ .year = year, .month = 0, .day = rosquin.year_end_day });
            if (doy == 366) {
                if (!rosquin.hasLeapDay(year)) return null;
                return rosquin.toCivil(.weeks, .{ .year = year, .month = 0, .day = rosquin.leap_day });
            }
            if (doy < 1 or doy > 364) return null;
            return rosquin.toCivil(.weeks, .{ .year = year, .month = 1, .day = @intCast(doy) });
        },
        3 => {
            if (nums[1] < 1 or nums[1] > 12 or nums[2] < 1 or nums[2] > 31) return null;
            const y: i32 = @intCast(nums[0]);
            const m: u8 = @intCast(nums[1]);
            if (nums[2] > civil.daysInMonth(y, m)) return null;
            return .{ .year = y, .month = m, .day = @intCast(nums[2]) };
        },
        else => return null,
    }
}

fn gotoGo() void {
    var buf: [64]u16 = undefined;
    const len: usize = @intCast(GetWindowTextW(st.goto_edit, &buf, 64));
    var u8buf: [200]u8 = undefined;
    const n = std.unicode.utf16LeToUtf8(&u8buf, buf[0..len]) catch 0;
    if (parseGoto(u8buf[0..n])) |d| {
        select(d);
        _ = DestroyWindow(st.goto);
    } else {
        _ = SetWindowTextW(st.goto_note, lit("Not a date. Try 2028-02-29, a day code like 18789, or \"51 366\"."));
    }
}

fn gotoProc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) callconv(.winapi) LRESULT {
    switch (msg) {
        WM_COMMAND => {
            const id = wp & 0xFFFF;
            if (id == 1) gotoGo();
            if (id == 2) _ = DestroyWindow(hwnd);
            return 0;
        },
        WM_CLOSE => {
            _ = DestroyWindow(hwnd);
            return 0;
        },
        WM_DESTROY => {
            st.goto = null;
            return 0;
        },
        else => return DefWindowProcW(hwnd, msg, wp, lp),
    }
}

fn openGoto() void {
    if (st.goto != null) {
        _ = SetFocus(st.goto_edit);
        return;
    }
    const inst = GetModuleHandleW(null);
    const w = CreateWindowExW(0, lit("RosquinGoto"), lit("Go to date"), WS_CAPTION_SYSMENU | WS_VISIBLE, 200, 200, 420, 150, st.hwnd, null, inst, null);
    st.goto = w;
    const gui_font = CreateFontW(-16, 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 4, 0, lit("Segoe UI"));
    const note = CreateWindowExW(0, lit("STATIC"), lit("Date (2028-02-29), day code (18789) or year and day of year (51 366)"), WS_CHILD | WS_VISIBLE, 12, 10, 390, 22, w, null, inst, null);
    st.goto_note = note;
    const edit = CreateWindowExW(0x200, lit("EDIT"), lit(""), WS_CHILD | WS_VISIBLE | WS_TABSTOP | WS_BORDER, 12, 40, 390, 26, w, null, inst, null);
    st.goto_edit = edit;
    const ok = CreateWindowExW(0, lit("BUTTON"), lit("Go"), WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_DEFPUSHBUTTON, 232, 76, 80, 28, w, @ptrFromInt(1), inst, null);
    const cancel = CreateWindowExW(0, lit("BUTTON"), lit("Cancel"), WS_CHILD | WS_VISIBLE | WS_TABSTOP, 322, 76, 80, 28, w, @ptrFromInt(2), inst, null);
    inline for (.{ note, edit, ok, cancel }) |c| _ = SendMessageW(c, WM_SETFONT, @intFromPtr(gui_font), 1);
    _ = SetFocus(edit);
}

// ---- drawing ---------------------------------------------------------------------------------------

fn uiFont(size: i32, weight: i32) HGDI {
    return CreateFontW(-size, 0, 0, 0, weight, 0, 0, 0, 1, 0, 0, 4, 0, lit("Segoe UI"));
}

fn glyphFont(size: i32) HGDI {
    if (st.glyph_font != null and st.glyph_size == size) return st.glyph_font;
    if (st.glyph_font != null) _ = DeleteObject(st.glyph_font);
    st.glyph_size = size;
    st.glyph_font = CreateFontW(-size, 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 4, 0, lit("Rosquin Glyphs"));
    return st.glyph_font;
}

fn drawText(hdc: HDC, x: i32, y: i32, s: []const u8, color: u32) void {
    var buf: [256]u16 = undefined;
    const w = wide(&buf, s);
    _ = SetTextColor(hdc, color);
    _ = TextOutW(hdc, x, y, w.ptr, @intCast(w.len));
}

fn textWidth(hdc: HDC, s: []const u8) i32 {
    var buf: [256]u16 = undefined;
    const w = wide(&buf, s);
    var r: RECT = .{};
    _ = DrawTextW(hdc, w.ptr, @intCast(w.len), &r, 0x400 | 0x20 | 0x100); // DT_CALCRECT | DT_SINGLELINE | DT_NOPREFIX
    return r.right;
}

fn paragraph(hdc: HDC, r: *RECT, s: []const u8, color: u32) i32 {
    var buf: [1024]u16 = undefined;
    const w = wide(&buf, s);
    _ = SetTextColor(hdc, color);
    var calc = r.*;
    _ = DrawTextW(hdc, w.ptr, @intCast(w.len), &calc, 0x400 | 0x10 | 0x100); // DT_CALCRECT | DT_WORDBREAK | DT_NOPREFIX
    _ = DrawTextW(hdc, w.ptr, @intCast(w.len), r, 0x10 | 0x100);
    return calc.bottom - calc.top;
}

fn moon(hdc: HDC, phase: lunar.Phase, x: i32, y: i32, d: i32) void {
    const dark = CreateSolidBrush(rgb.c(40, 50, 70));
    const light = CreateSolidBrush(rgb.c(250, 245, 215));
    const pen = CreatePen(0, 1, rgb.c(40, 50, 70));
    const old_pen = SelectObject(hdc, pen);
    const old = SelectObject(hdc, if (phase == .new) dark else light);
    _ = Ellipse(hdc, x, y, x + d, y + d);
    if (phase == .first_quarter or phase == .last_quarter) {
        _ = SelectObject(hdc, dark);
        const cx = x + @divTrunc(d, 2);
        if (phase == .first_quarter) {
            _ = Pie(hdc, x, y, x + d, y + d, cx, y, cx, y + d); // left half
        } else {
            _ = Pie(hdc, x, y, x + d, y + d, cx, y + d, cx, y); // right half
        }
    }
    _ = SelectObject(hdc, old);
    _ = SelectObject(hdc, old_pen);
    _ = DeleteObject(dark);
    _ = DeleteObject(light);
    _ = DeleteObject(pen);
}

fn addCell(x: i32, y: i32, w: i32, h: i32, date: Date) void {
    if (st.ncells >= st.cells.len) return;
    st.cells[st.ncells] = .{ .x = x, .y = y, .w = w, .h = h, .date = date };
    st.ncells += 1;
}

/// The fonts to try for the native names of a system, after one the user chose: the
/// built-in one, then the fonts Windows has for the script.
fn candidatesFor(sys: calsys.System) []const []const u8 {
    return switch (sys) {
        .chinese => &.{ "Droid Sans Fallback", "Microsoft YaHei UI", "Microsoft YaHei", "SimSun", "MingLiU", "Segoe UI" },
        .hebrew => &.{ "Noto Sans Hebrew", "Segoe UI", "Arial", "David" },
        .coptic => &.{ "Noto Sans Coptic", "Segoe UI Historic", "Segoe UI Symbol", "Arial Unicode MS" },
        .ethiopian => &.{ "Noto Sans Ethiopic", "Nyala", "Ebrima", "Segoe UI Historic" },
        else => &.{"Segoe UI"},
    };
}

fn fontNamed(family: []const u8, size: i32) HGDI {
    var name: [64]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(name[0..63], family) catch 0;
    name[n] = 0;
    return CreateFontW(-size, 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 4, 0, @ptrCast(&name));
}

/// Whether `font` has a glyph for every character of `text16` beyond plain ASCII.
fn fontCovers(hdc: HDC, font_handle: HGDI, text16: []const u16) bool {
    var wanted: [256]u16 = undefined;
    var n: usize = 0;
    for (text16) |ch| if (ch > 0x7F and n < wanted.len) {
        wanted[n] = ch;
        n += 1;
    };
    if (n == 0) return true;
    const old = SelectObject(hdc, font_handle);
    defer _ = SelectObject(hdc, old);
    var idx: [256]u16 = undefined;
    if (GetGlyphIndicesW(hdc, &wanted, @intCast(n), &idx, 1) == 0xFFFFFFFF) return false; // GDI_ERROR
    for (idx[0..n]) |g| if (g == 0xFFFF) return false;
    return true;
}

/// A GDI font that has all the characters of `text16`: the user's chosen font, then the
/// built-in one, then Windows' own. If none has them all, the first one is used. Delete it
/// after use.
fn pickNativeFont(hdc: HDC, sys: calsys.System, size: i32, text16: []const u16) HGDI {
    if (st.native_font_len > 0) {
        const f = fontNamed(st.native_font[0..st.native_font_len], size);
        if (fontCovers(hdc, f, text16)) return f;
        _ = DeleteObject(f);
    }
    for (candidatesFor(sys)) |name| {
        const f = fontNamed(name, size);
        if (fontCovers(hdc, f, text16)) return f;
        _ = DeleteObject(f);
    }
    return fontNamed(if (st.native_font_len > 0) st.native_font[0..st.native_font_len] else candidatesFor(sys)[0], size);
}

fn drawNativeText(hdc: HDC, x: i32, y: i32, s: []const u8, color: u32, sys: calsys.System, size: i32) void {
    if (s.len == 0) return;
    var w16: [512]u16 = undefined;
    const w = wide(&w16, s);
    const f = pickNativeFont(hdc, sys, size, w);
    const old = SelectObject(hdc, f);
    _ = SetTextColor(hdc, color);
    // Hebrew reads from right to left.
    _ = ExtTextOutW(hdc, x, y, if (sys == .hebrew) 0x80 else 0, null, w.ptr, @intCast(w.len), null);
    _ = SelectObject(hdc, old);
    _ = DeleteObject(f);
}

/// One line of native text in the side panel; returns its height.
fn nativeLine(hdc: HDC, r: *const RECT, sys: calsys.System, s: []const u8, color: u32, size: i32) i32 {
    drawNativeText(hdc, r.left, r.top, s, color, sys, size);
    return size + 8;
}

fn toggleNative() void {
    st.native_on = !st.native_on;
    saveBool("native-script", st.native_on);
    syncOptionChecks();
    _ = InvalidateRect(st.hwnd, null, 0);
}

/// Options, Native font check: which font each script is drawn in on this PC.
fn nativeFontReport() void {
    const hdc = GetDC(st.hwnd);
    defer _ = ReleaseDC(st.hwnd, hdc);
    var msg: [1800]u8 = undefined;
    var used: usize = 0;
    const head = std.fmt.bufPrint(msg[used..], "Built-in native fonts registered: {d} of 4.\n\n", .{st.fonts_added}) catch "";
    used += head.len;
    const today = st.today;
    inline for (.{ calsys.System.chinese, calsys.System.hebrew, calsys.System.coptic, calsys.System.ethiopian }) |sys| {
        var nb: [160]u8 = undefined;
        var w16: [256]u16 = undefined;
        const w = wide(&w16, native.dateLine(&nb, sys, today));
        var chosen: []const u8 = "no font that has all the characters";
        if (st.native_font_len > 0) {
            const f = fontNamed(st.native_font[0..st.native_font_len], 16);
            if (fontCovers(hdc, f, w)) chosen = st.native_font[0..st.native_font_len];
            _ = DeleteObject(f);
        }
        if (std.mem.startsWith(u8, chosen, "no font")) {
            for (candidatesFor(sys)) |name| {
                const f = fontNamed(name, 16);
                const ok = fontCovers(hdc, f, w);
                _ = DeleteObject(f);
                if (ok) {
                    chosen = name;
                    break;
                }
            }
        }
        const line = std.fmt.bufPrint(msg[used..], "{s}: {s}\n", .{ sys.label(), chosen }) catch "";
        used += line.len;
    }
    var w16: [1800]u16 = undefined;
    _ = wide(&w16, msg[0..used]);
    _ = MessageBoxW(st.hwnd, @ptrCast(&w16), lit("Native fonts"), 0x40);
}

fn chooseNativeFont() void {
    var lf: LOGFONTW = .{};
    var cf: CHOOSEFONTW = .{ .owner = st.hwnd, .log_font = &lf, .flags = 0x1 | 0x40 | 0x10000 | 0x200000 };
    if (ChooseFontW(&cf) == 0) return;
    var n: usize = 0;
    while (n < 32 and lf.face[n] != 0) n += 1;
    var u8b: [128]u8 = undefined;
    const name = utf8Of(&u8b, lf.face[0..n]);
    st.native_font_len = @min(name.len, st.native_font.len);
    @memcpy(st.native_font[0..st.native_font_len], name[0..st.native_font_len]);
    if (st.cfg) |*c| {
        const z = gpa.dupeSentinel(u8, name[0..st.native_font_len], 0) catch return;
        defer gpa.free(z);
        c.setString("view", "native-font", z) catch {};
    }
    _ = InvalidateRect(st.hwnd, null, 0);
}

fn resetNativeFont() void {
    st.native_font_len = 0;
    if (st.cfg) |*c| c.setString("view", "native-font", "") catch {};
    _ = InvalidateRect(st.hwnd, null, 0);
}

fn addButton(x: i32, y: i32, w: i32, h: i32, id: u16) void {
    if (st.nbuttons >= st.buttons.len) return;
    st.buttons[st.nbuttons] = .{ .x = x, .y = y, .w = w, .h = h, .id = id };
    st.nbuttons += 1;
}

fn toggleKind(i: usize) void {
    st.show[i] = !st.show[i];
    if (st.show[i] and st.tables[i] == null) st.tables[i] = liturgy.Table.load(std.heap.page_allocator, kinds[i]) catch null;
    _ = InvalidateRect(st.hwnd, null, 0);
}

fn litColor(c: liturgy.Color) u32 {
    return switch (c) {
        .white => rgb.c(232, 232, 232),
        .red => rgb.c(235, 175, 175),
        .green => rgb.c(175, 220, 175),
        .violet => rgb.c(205, 178, 230),
        .rose => rgb.c(242, 195, 215),
        .black => rgb.c(150, 150, 150),
        .blue => rgb.c(175, 195, 235),
        .gold => rgb.c(238, 218, 140),
    };
}

/// One line of a liturgical calendar in a cell: its colour, a fast emoji, the name.
fn litLine(hdc: HDC, x: i32, y: i32, w: i32, day: *const liturgy.Day, hide_name: bool) void {
    const band = CreateSolidBrush(litColor(day.color));
    const rc: RECT = .{ .left = x, .top = y, .right = x + w, .bottom = y + 15 };
    if (!hide_name) _ = FillRect(hdc, &rc, band);
    _ = DeleteObject(band);
    var tx = x + 3;
    if (day.fast_emoji.len > 0) {
        const emoji = CreateFontW(-12, 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 4, 0, lit("Segoe UI Emoji"));
        const old = SelectObject(hdc, emoji);
        var eb: [32]u16 = undefined;
        const ew = wide(&eb, day.fast_emoji);
        _ = SetTextColor(hdc, rgb.c(30, 30, 30));
        _ = TextOutW(hdc, tx, y, ew.ptr, @intCast(ew.len));
        _ = SelectObject(hdc, old);
        _ = DeleteObject(emoji);
        tx += 17;
    }
    if (!hide_name) {
        var nb: [256]u16 = undefined;
        const nw = wide(&nb, day.name);
        var r2: RECT = .{ .left = tx, .top = y, .right = x + w - 2, .bottom = y + 15 };
        _ = SetTextColor(hdc, rgb.c(30, 30, 30));
        _ = DrawTextW(hdc, nw.ptr, @intCast(nw.len), &r2, 0x8000 | 0x20 | 0x100 | 0x4); // END_ELLIPSIS | SINGLELINE | NOPREFIX | VCENTER
    }
}

fn drawCell(hdc: HDC, c: Cell, in_page: bool) void {
    const date = c.date;
    const v = calsys.fromCivil(st.sys, date);
    const is_sel = date.eql(st.selected);
    const is_today = date.eql(st.today);
    // Day 13 of the Rosquin week, the Ankh, has a very light orange ground.
    const ankh = st.sys.isRosquin() and rosquin.dayOfWeek(date) == 13;
    const fill = CreateSolidBrush(if (is_sel) rgb.c(205, 222, 250) else if (is_today) rgb.c(255, 240, 200) else if (ankh) rgb.c(255, 243, 224) else rgb.c(255, 255, 255));
    const edge = CreatePen(0, if (is_sel) 2 else 1, if (is_sel) rgb.c(40, 110, 220) else rgb.c(205, 205, 205));
    const old_b = SelectObject(hdc, fill);
    const old_p = SelectObject(hdc, edge);
    _ = Rectangle(hdc, c.x, c.y, c.x + c.w, c.y + c.h);
    _ = SelectObject(hdc, old_b);
    _ = SelectObject(hdc, old_p);
    _ = DeleteObject(fill);
    _ = DeleteObject(edge);

    const ink = if (in_page) rgb.c(30, 30, 30) else rgb.c(150, 150, 150);
    const dim = rgb.c(120, 120, 120);
    var buf: [96]u8 = undefined;
    const small = uiFont(11, 400);
    const bold = uiFont(14, 700);
    defer {
        _ = DeleteObject(small);
        _ = DeleteObject(bold);
    }
    if (st.sys.isRosquin()) {
        const size = @max(10, @min(c.w - 16, c.h - 20)); // the strip at the right is for the moon
        const stamp = rosstamp.stamp(site, date);
        const gf = glyphFont(size);
        const old = SelectObject(hdc, gf);
        _ = SetTextColor(hdc, ink);
        for (stamp.slice()) |ch| {
            const one = [1]u16{@intCast(ch)};
            _ = TextOutW(hdc, c.x + 2, c.y + 2, &one, 1);
        }
        _ = SelectObject(hdc, old);
        _ = SelectObject(hdc, small);
        const label = std.fmt.bufPrint(&buf, "{d} \u{b7} {d}", .{ rosquin.dayCode(date), rosquin.dayOfYear(date) }) catch "";
        drawText(hdc, c.x + 3, c.y + c.h - 16, label, ink);
        if (c.w > 70) {
            const civil_label = std.fmt.bufPrint(&buf, "{d}/{d}", .{ date.month, date.day }) catch "";
            drawText(hdc, c.x + c.w - textWidth(hdc, civil_label) - 4, c.y + 3, civil_label, dim);
        }
    } else {
        _ = SelectObject(hdc, bold);
        const label = if (calsys.isSpecial(st.sys, v)) calsys.specialName(v) else (std.fmt.bufPrint(&buf, "{d}", .{v.day}) catch "");
        drawText(hdc, c.x + 5, c.y + 4, label, ink);
        if (st.native_on and native.has(st.sys) and !calsys.isSpecial(st.sys, v)) {
            var nb: [32]u8 = undefined;
            drawNativeText(hdc, c.x + 32, c.y + 5, native.day(&nb, st.sys, v.day), rgb.c(110, 110, 110), st.sys, 13);
        }
        if (st.sys != .gregorian) {
            _ = SelectObject(hdc, small);
            const civil_label = std.fmt.bufPrint(&buf, "{d}/{d}", .{ date.month, date.day }) catch "";
            drawText(hdc, c.x + c.w - textWidth(hdc, civil_label) - 5, c.y + 6, civil_label, dim);
        }
    }
    // The liturgical calendars that are on.
    var lit_y = c.y + 24;
    var bar_x = c.x + 1;
    for (kinds, 0..) |_, k| {
        if (!st.show[k]) continue;
        const table = &(st.tables[k] orelse continue);
        var day: liturgy.Day = undefined;
        liturgy.compute(table, date, &day);
        const hide_name = st.named_only and day.plain;
        if (hide_name and day.fast_emoji.len == 0) continue;
        if (st.sys.isRosquin()) {
            // The cell is the glyph: a colour strip along the bottom, one part for each calendar.
            const seg = @divTrunc(c.w - 2, 3);
            const strip = CreateSolidBrush(litColor(day.color));
            const rc: RECT = .{ .left = bar_x, .top = c.y + c.h - 5, .right = bar_x + seg - 1, .bottom = c.y + c.h - 1 };
            if (!hide_name) _ = FillRect(hdc, &rc, strip);
            _ = DeleteObject(strip);
            bar_x += seg;
        } else if (lit_y + 15 <= c.y + c.h - 2) {
            litLine(hdc, c.x + 2, lit_y, c.w - 4, &day, hide_name);
            lit_y += 16;
        }
    }
    // Events.
    if (st.list) |list| {
        var shown: i32 = 0;
        var total: i32 = 0;
        for (list.items) |*ev| {
            if (!events.occursOn(ev, date)) continue;
            total += 1;
            if (st.sys.isRosquin()) {
                if (shown < 4 and c.w > 40) {
                    const sq = CreateSolidBrush(eventColor(ev.color));
                    const y0 = c.y + 36 + shown * 9;
                    const rc: RECT = .{ .left = c.x + c.w - 12, .top = y0, .right = c.x + c.w - 5, .bottom = y0 + 7 };
                    _ = FillRect(hdc, &rc, sq);
                    _ = DeleteObject(sq);
                    shown += 1;
                }
            } else if (shown < 2 and lit_y + 15 <= c.y + c.h - 2) {
                const pill = CreateSolidBrush(eventColor(ev.color));
                const rc: RECT = .{ .left = c.x + 2, .top = lit_y, .right = c.x + c.w - 2, .bottom = lit_y + 15 };
                _ = FillRect(hdc, &rc, pill);
                _ = DeleteObject(pill);
                var eb: [200]u8 = undefined;
                var tb2: [24]u8 = undefined;
                const label = if (ev.all_day) (std.fmt.bufPrint(&eb, "{s}", .{ev.title}) catch "") else (std.fmt.bufPrint(&eb, "{s} {s}", .{ events.formatClock(&tb2, ev.start, st.twelve_hour), ev.title }) catch "");
                var wbuf: [200]u16 = undefined;
                const ww = wide(&wbuf, label);
                var rt: RECT = .{ .left = c.x + 5, .top = lit_y, .right = c.x + c.w - 4, .bottom = lit_y + 15 };
                _ = SetTextColor(hdc, rgb.c(255, 255, 255));
                _ = DrawTextW(hdc, ww.ptr, @intCast(ww.len), &rt, 0x8000 | 0x20 | 0x100 | 0x4);
                lit_y += 16;
                shown += 1;
            }
        }
        if (!st.sys.isRosquin() and total > shown and lit_y + 15 <= c.y + c.h - 2) {
            var mb: [24]u8 = undefined;
            drawText(hdc, c.x + 5, lit_y, std.fmt.bufPrint(&mb, "+{d} more", .{total - shown}) catch "", rgb.c(110, 110, 110));
        }
    }
    if (lunar.phaseOn(site, date)) |p| moon(hdc, p, c.x + c.w - 14, c.y + (if (st.sys.isRosquin() and c.w > 70) @as(i32, 20) else if (st.sys.isRosquin()) @as(i32, 4) else c.h - 15), 11);
}

fn clampScroll() void {
    st.ox = std.math.clamp(st.ox, 0, @max(0, st.content_w - st.view_w));
    st.oy = std.math.clamp(st.oy, 0, @max(0, st.content_h - st.view_h));
}

/// Fits the scroll bars to the grid. They are always there, and idle when it fits.
fn updateScrollBars(w: i32, h: i32) void {
    _ = w;
    _ = h;
    clampScroll();
    const horz: SCROLLINFO = .{ .mask = 0x7, .max = @max(st.content_w, st.view_w) - 1, .page = @intCast(st.view_w), .pos = st.ox };
    const vert: SCROLLINFO = .{ .mask = 0x7, .max = @max(st.content_h, st.view_h) - 1, .page = @intCast(st.view_h), .pos = st.oy };
    _ = SetScrollInfo(st.hwnd, 0, &horz, 1);
    _ = SetScrollInfo(st.hwnd, 1, &vert, 1);
}

fn scrollTo(bar: i32, pos: i32) void {
    if (bar == 0) st.ox = pos else st.oy = pos;
    clampScroll();
    _ = InvalidateRect(st.hwnd, null, 0);
}

fn onScroll(bar: i32, wp: WPARAM) void {
    const code = wp & 0xFFFF;
    const cur = if (bar == 0) st.ox else st.oy;
    const page = if (bar == 0) st.view_w else st.view_h;
    switch (code) {
        0 => scrollTo(bar, cur - 40), // SB_LINEUP / LEFT
        1 => scrollTo(bar, cur + 40),
        2 => scrollTo(bar, cur - page),
        3 => scrollTo(bar, cur + page),
        4, 5 => scrollTo(bar, @intCast((wp >> 16) & 0xFFFF)), // THUMBPOSITION / THUMBTRACK
        6 => scrollTo(bar, 0),
        7 => scrollTo(bar, 1 << 20),
        else => {},
    }
}

fn paint(hdc: HDC, w: i32, h: i32) void {
    const bg = CreateSolidBrush(rgb.c(250, 250, 250));
    var all: RECT = .{ .right = w, .bottom = h };
    _ = FillRect(hdc, &all, bg);
    _ = DeleteObject(bg);
    _ = SetBkMode(hdc, 1);
    st.ncells = 0;

    const sys = st.sys;
    const title = uiFont(22, 700);
    const small = uiFont(12, 400);
    const ui = uiFont(14, 400);
    defer {
        _ = DeleteObject(ui);
        _ = DeleteObject(title);
        _ = DeleteObject(small);
    }

    // Header, first row: the page buttons and the title.
    st.nbuttons = 0;
    _ = SelectObject(hdc, title);
    var tb: [96]u8 = undefined;
    const title_text = if (sys == .rosquin_weeks)
        std.fmt.bufPrint(&tb, "Yr {d} \u{b7} 28 weeks", .{st.year}) catch ""
    else if (sys.isRosquin())
        std.fmt.bufPrint(&tb, "{s} {d} \u{b7} Yr {d}", .{ calsys.monthName(sys, st.month), st.month, st.year }) catch ""
    else blk: {
        var mb: [48]u8 = undefined;
        var yb: [64]u8 = undefined;
        break :blk std.fmt.bufPrint(&tb, "{s} {s}{s}", .{ calsys.monthLabel(&mb, sys, st.year, st.month), calsys.yearLabel(&yb, sys, st.year), if (sys == .julian) " (Julian)" else "" }) catch "";
    };
    drawText(hdc, 140, 8, title_text, rgb.c(20, 20, 20));
    if (st.native_on and native.has(sys)) {
        var pb: [160]u8 = undefined;
        drawNativeText(hdc, 140 + textWidth(hdc, title_text) + 18, 10, native.pageLine(&pb, sys, st.year, st.month), rgb.c(60, 60, 60), sys, 20);
    }
    _ = SelectObject(hdc, small);
    const btn = CreateSolidBrush(rgb.c(232, 232, 232));
    defer _ = DeleteObject(btn);
    const row1 = [_]struct { l: []const u8, x: i32, w: i32, id: u16 }{
        .{ .l = "<", .x = 8, .w = 32, .id = 1 },
        .{ .l = ">", .x = 44, .w = 32, .id = 2 },
        .{ .l = "Today", .x = 80, .w = 50, .id = 3 },
    };
    for (row1) |b1| {
        const rb: RECT = .{ .left = b1.x, .top = 8, .right = b1.x + b1.w, .bottom = 34 };
        _ = FillRect(hdc, &rb, btn);
        drawText(hdc, b1.x + 8, 13, b1.l, rgb.c(20, 20, 20));
        addButton(b1.x, 8, b1.w, 26, b1.id);
    }
    // New event, at the right end of the grid.
    {
        const nx = @max(300, w - 330 - 16 - 110);
        const accent = CreateSolidBrush(rgb.c(60, 120, 215));
        const rn: RECT = .{ .left = nx, .top = 8, .right = nx + 104, .bottom = 34 };
        _ = FillRect(hdc, &rn, accent);
        _ = DeleteObject(accent);
        drawText(hdc, nx + 14, 13, "New event", rgb.c(255, 255, 255));
        addButton(nx, 8, 104, 26, 20);
    }
    // Second row: the calendar selector, Go to, and the liturgical calendars.
    const sel_w: i32 = 250;
    const rs: RECT = .{ .left = 8, .top = 42, .right = 8 + sel_w, .bottom = 70 };
    _ = FillRect(hdc, &rs, btn);
    var sb: [96]u8 = undefined;
    drawText(hdc, 14, 48, std.fmt.bufPrint(&sb, "{s}", .{sys.label()}) catch "", rgb.c(20, 20, 20));
    const marlett = CreateFontW(-14, 0, 0, 0, 400, 0, 0, 0, 2, 0, 0, 4, 0, lit("Marlett")); // SYMBOL_CHARSET; "6" is a down arrow
    const old_font = SelectObject(hdc, marlett);
    drawText(hdc, 8 + sel_w - 22, 47, "6", rgb.c(20, 20, 20));
    _ = SelectObject(hdc, old_font);
    _ = DeleteObject(marlett);
    addButton(8, 42, sel_w, 28, 5);
    const dirty = viewDirty();
    const rsv: RECT = .{ .left = 266, .top = 42, .right = 376, .bottom = 70 };
    _ = FillRect(hdc, &rsv, btn);
    drawText(hdc, 274, 48, "Save as default", if (dirty) rgb.c(20, 20, 20) else rgb.c(150, 150, 150));
    addButton(266, 42, 110, 28, 22);
    const rg: RECT = .{ .left = 384, .top = 42, .right = 458, .bottom = 70 };
    _ = FillRect(hdc, &rg, btn);
    drawText(hdc, 394, 48, "Go to\u{2026}", rgb.c(20, 20, 20));
    addButton(384, 42, 74, 28, 4);
    const rc2: RECT = .{ .left = 466, .top = 42, .right = 546, .bottom = 70 };
    _ = FillRect(hdc, &rc2, btn);
    drawText(hdc, 476, 48, "Copy date", rgb.c(20, 20, 20));
    addButton(466, 42, 80, 28, 21);
    // What to show: the liturgical calendars, named days only and native script, in one
    // drop-down so they never run out of room.
    const rshow: RECT = .{ .left = 562, .top = 42, .right = 662, .bottom = 70 };
    _ = FillRect(hdc, &rshow, btn);
    drawText(hdc, 572, 48, "Show", rgb.c(20, 20, 20));
    {
        const marlett2 = CreateFontW(-14, 0, 0, 0, 400, 0, 0, 0, 2, 0, 0, 4, 0, lit("Marlett"));
        const old2 = SelectObject(hdc, marlett2);
        drawText(hdc, 562 + 100 - 22, 47, "6", rgb.c(20, 20, 20));
        _ = SelectObject(hdc, old2);
        _ = DeleteObject(marlett2);
    }
    addButton(562, 42, 100, 28, 23);

    // The grid. It never makes the window bigger: when it does not fit, it keeps a
    // readable cell size and the window scrolls it.
    const panel_w: i32 = if (w > 760) 330 else 0;
    const gx: i32 = 8;
    const gw = w - panel_w - 16;
    const top: i32 = 104;
    const gh = h - top - 8;
    const rosq = sys.isRosquin();
    // Rosquin: the 13 days of the week, then a 14th column for the inter-calendar
    // days, which are in no week.
    const cols: i32 = if (rosq) 14 else 7;
    const cw = @max(@divTrunc(gw, cols), @as(i32, if (rosq) 54 else 80));
    var rows: i32 = 6;
    var ch: i32 = 0;
    if (rosq) {
        rows = @divTrunc(@as(i32, sys.layout().?.monthLen()) + 12, 13);
        ch = @max(@divTrunc(gh, rows), 70);
    } else if (sys == .fixed) {
        rows = 5;
        ch = @max(@divTrunc(gh, rows), 56);
    } else {
        ch = @max(@divTrunc(gh, rows), 56);
    }
    st.view_w = gw;
    st.view_h = gh;
    st.content_w = cw * cols;
    st.content_h = ch * rows;
    updateScrollBars(w, h);
    const ox = st.ox;
    const oy = st.oy;
    const gy = top - oy;
    const gx0 = gx - ox;

    // Day headings (they scroll sideways with the grid).
    _ = SelectObject(hdc, small);
    const symbols = CreateFontW(-12, 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 4, 0, lit("Segoe UI Symbol"));
    defer _ = DeleteObject(symbols);
    _ = IntersectClipRect(hdc, gx, 78, gx + gw, top);
    var i: i32 = 0;
    while (i < cols) : (i += 1) {
        var hb: [24]u8 = undefined;
        const head: []const u8 = if (rosq)
            (if (i == 13) "Inter" else if (i == 12) "\u{2625}" else std.fmt.bufPrint(&hb, "{d}", .{i + 1}) catch "")
        else
            calsys.weekday_names[@intCast(i)][0..3];
        const sym = rosq and i == 12;
        const old_head = if (sym) SelectObject(hdc, symbols) else null;
        drawText(hdc, gx0 + i * cw + @divTrunc(cw, 2) - 8, 82, head, rgb.c(90, 90, 90));
        if (sym) _ = SelectObject(hdc, old_head);
    }
    _ = SelectClipRgn(hdc, null);
    _ = IntersectClipRect(hdc, gx, top, gx + gw, top + gh);

    var branding_h: i32 = 0;
    if (rosq) {
        const layout = sys.layout().?;
        const len: i32 = layout.monthLen();
        var k: i32 = 0;
        while (k < len) : (k += 1) {
            const date = calsys.toCivil(sys, .{ .year = st.year, .month = st.month, .day = @intCast(k + 1) });
            addCell(gx0 + @mod(k, 13) * cw, gy + @divTrunc(k, 13) * ch, cw, ch, date);
        }
        // Year-End Day (week 8) and Leap Day (week 13) stand in the 14th column, in
        // the row of the week they fall in, on the page that holds that week.
        inline for (.{ rosquin.year_end_day, rosquin.leap_day }) |day| {
            if (rosquin.pageNear(layout, day) == st.month and (day == rosquin.year_end_day or rosquin.hasLeapDay(st.year))) {
                const row: i32 = rosquin.rowNear(layout, day);
                // In the first row the branding picture takes the top of the cell.
                const shared: i32 = if (row == 0) 44 else 0;
                if (row == 0) branding_h = shared;
                addCell(gx0 + 13 * cw, gy + row * ch + shared, cw, ch - shared, calsys.toCivil(sys, .{ .year = st.year, .month = 0, .day = day }));
            }
        }
    } else if (sys == .fixed) {
        const days = calsys.monthDays(sys, st.year, st.month);
        const first = calsys.toCivil(sys, .{ .year = st.year, .month = st.month, .day = 1 });
        var k: i32 = 0;
        while (k < 28) : (k += 1) addCell(gx0 + @mod(k, 7) * cw, gy + @divTrunc(k, 7) * ch, cw, ch, first.addDays(k));
        if (days == 29) addCell(gx0, gy + 4 * ch, cw * 7, ch, first.addDays(28));
    } else {
        const first = calsys.toCivil(sys, .{ .year = st.year, .month = st.month, .day = 1 });
        const lead: i64 = first.weekday();
        var k: i32 = 0;
        while (k < 42) : (k += 1) addCell(gx0 + @mod(k, 7) * cw, gy + @divTrunc(k, 7) * ch, cw, ch, first.addDays(@as(i64, k) - lead));
    }
    for (st.cells[0..st.ncells]) |c| {
        if (c.x + c.w < gx or c.x > gx + gw or c.y + c.h < top or c.y > top + gh) continue;
        const v = calsys.fromCivil(sys, c.date);
        const in_page = calsys.isSpecial(sys, v) or (v.month == st.month and v.year == st.year);
        drawCell(hdc, c, in_page);
    }
    // The branding picture: the first row of the 14th column, on every page.
    if (rosq) {
        const area: i32 = if (branding_h > 0) branding_h else ch;
        const side = @min(cw, area) - 8;
        if (side > 8) {
            const info: BITMAPINFOHEADER = .{ .width = 128, .height = -128, .planes = 1, .bits = 32 };
            _ = SetStretchBltMode(hdc, 4); // HALFTONE
            _ = StretchDIBits(hdc, gx0 + 13 * cw + @divTrunc(cw - side, 2), gy + @divTrunc(area - side, 2), side, side, 0, 0, 128, 128, branding_bgra.ptr, &info, 0, 0x00CC0020);
        }
    }
    _ = SelectClipRgn(hdc, null);

    // The side panel: the selected day in every system.
    const px = w - panel_w;
    var r: RECT = .{ .left = px, .top = 8, .right = w - 12, .bottom = h - 8 };
    var db: [256]u8 = undefined;
    _ = SelectObject(hdc, title);
    var used = paragraph(hdc, &r, calsys.describe(&db, sys, st.selected), rgb.c(20, 20, 20));
    if (st.native_on and native.has(sys)) {
        var nb: [160]u8 = undefined;
        r.top += used;
        used = nativeLine(hdc, &r, sys, native.dateLine(&nb, sys, st.selected), rgb.c(60, 60, 60), 17);
    }
    r.top += used + 10;
    _ = SelectObject(hdc, small);
    const systems = [_]calsys.System{ .julian, .gregorian, .fixed, .rosquin_weeks, .rosquin_months, .rosquin_quarters, .chinese, .hebrew, .coptic, .ethiopian };
    for (systems) |other| {
        if (other == sys) continue;
        var ob: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&ob, "{s}: {s}", .{ other.label(), calsys.describe(&db, other, st.selected) }) catch "";
        used = paragraph(hdc, &r, line, rgb.c(100, 100, 100));
        if (st.native_on and native.has(other)) {
            var nb: [160]u8 = undefined;
            r.top += used;
            used = nativeLine(hdc, &r, other, native.dateLine(&nb, other, st.selected), rgb.c(100, 100, 100), 14);
        }
        r.top += used + 6;
    }
    if (lunar.phaseOn(site, st.selected)) |p| {
        var mb: [64]u8 = undefined;
        used = paragraph(hdc, &r, std.fmt.bufPrint(&mb, "Moon: {s}", .{p.label()}) catch "", rgb.c(40, 50, 70));
        r.top += used + 6;
    }
    for (kinds, 0..) |_, k| {
        if (!st.show[k]) continue;
        const table = &(st.tables[k] orelse continue);
        var day: liturgy.Day = undefined;
        liturgy.compute(table, st.selected, &day);
        r.top += 6;
        _ = SelectObject(hdc, small);
        used = paragraph(hdc, &r, kind_names[k], rgb.c(120, 120, 120));
        r.top += used + 1;
        const swatch = CreateSolidBrush(litColor(day.color));
        const sw: RECT = .{ .left = r.left, .top = r.top + 2, .right = r.left + 10, .bottom = r.top + 14 };
        _ = FillRect(hdc, &sw, swatch);
        _ = DeleteObject(swatch);
        var nr = r;
        nr.left += 16;
        _ = SelectObject(hdc, ui);
        used = paragraph(hdc, &nr, day.name, rgb.c(20, 20, 20));
        r.top += @max(used, 16) + 2;
        _ = SelectObject(hdc, small);
        var lb: [320]u8 = undefined;
        const detail = std.fmt.bufPrint(&lb, "{s}{s}{s}{s}{s}", .{ day.rank, if (day.season.len > 0) " \u{b7} " else "", day.season, if (day.cycle.len > 0) " \u{b7} " else "", day.cycle }) catch "";
        used = paragraph(hdc, &r, detail, rgb.c(100, 100, 100));
        r.top += used + 2;
        if (day.fast_text.len > 0) {
            used = paragraph(hdc, &r, day.fast_text, rgb.c(100, 100, 100));
            r.top += used + 2;
        }
        for (day.alsoLines()) |line| {
            var ab: [320]u8 = undefined;
            used = paragraph(hdc, &r, std.fmt.bufPrint(&ab, "{s}: {s}", .{ line.label, line.text }) catch "", rgb.c(100, 100, 100));
            r.top += used + 2;
        }
    }
    // The events of the day, each with Edit and Delete.
    r.top += 8;
    _ = SelectObject(hdc, small);
    used = paragraph(hdc, &r, "Events", rgb.c(120, 120, 120));
    r.top += used + 2;
    var any = false;
    if (st.list) |list| {
        for (list.items, 0..) |*ev, idx| {
            if (!events.occursOn(ev, st.selected) or idx >= 850) continue;
            any = true;
            const sw = CreateSolidBrush(eventColor(ev.color));
            const rc: RECT = .{ .left = r.left, .top = r.top + 2, .right = r.left + 8, .bottom = r.top + 16 };
            _ = FillRect(hdc, &rc, sw);
            _ = DeleteObject(sw);
            var eb: [300]u8 = undefined;
            var tb2: [24]u8 = undefined;
            const text_line = if (ev.all_day) (std.fmt.bufPrint(&eb, "{s}", .{ev.title}) catch "") else (std.fmt.bufPrint(&eb, "{s}  {s}", .{ events.formatClock(&tb2, ev.start, st.twelve_hour), ev.title }) catch "");
            var er = r;
            er.left += 14;
            er.right -= 66;
            _ = SelectObject(hdc, small);
            const eh = paragraph(hdc, &er, text_line, rgb.c(30, 30, 30));
            const small_btn = CreateSolidBrush(rgb.c(232, 232, 232));
            const bx = r.right - 62;
            const be: RECT = .{ .left = bx, .top = r.top, .right = bx + 30, .bottom = r.top + 16 };
            const bd: RECT = .{ .left = bx + 32, .top = r.top, .right = bx + 62, .bottom = r.top + 16 };
            _ = FillRect(hdc, &be, small_btn);
            _ = FillRect(hdc, &bd, small_btn);
            _ = DeleteObject(small_btn);
            drawText(hdc, bx + 3, r.top, "Edit", rgb.c(30, 30, 30));
            drawText(hdc, bx + 36, r.top, "Del", rgb.c(160, 40, 40));
            addButton(bx, r.top, 30, 16, @intCast(300 + idx * 2));
            addButton(bx + 32, r.top, 30, 16, @intCast(301 + idx * 2));
            if (ev.location.len > 0) {
                var lr = r;
                lr.top += @max(eh, 16);
                lr.left += 14;
                const lh = paragraph(hdc, &lr, ev.location, rgb.c(120, 120, 120));
                r.top += lh;
            }
            r.top += @max(eh, 16) + 4;
        }
    }
    if (!any) {
        used = paragraph(hdc, &r, "Nothing planned.", rgb.c(140, 140, 140));
        r.top += used + 4;
    }
    if (px > 0) {
        _ = SelectObject(hdc, small);
        drawText(hdc, px + 4, h - 8 - 150 - 18, "Notes", rgb.c(120, 120, 120));
    }
    r.top += 8;
    _ = paragraph(hdc, &r, "Arrows move a day, PgUp/PgDn a page, Home is today, Ctrl+G is Go to.", rgb.c(130, 130, 130));
}

// ---- the window ----------------------------------------------------------------------------------

fn saveShot(mem: HDC, bmp: HGDI, w: i32, h: i32) void {
    var info: BITMAPINFOHEADER = .{ .width = w, .height = -h };
    const bytes: usize = @intCast(w * h * 4);
    const pixels = std.heap.page_allocator.alloc(u8, bytes) catch return;
    defer std.heap.page_allocator.free(pixels);
    _ = GetDIBits(mem, bmp, 0, @intCast(h), pixels.ptr, &info, 0);
    const f = CreateFileW(@ptrCast(&st.shot), 0x40000000, 0, null, 2, 0, null);
    var header: [54]u8 = @splat(0);
    header[0] = 'B';
    header[1] = 'M';
    std.mem.writeInt(u32, header[2..6], @intCast(54 + bytes), .little);
    std.mem.writeInt(u32, header[10..14], 54, .little);
    @memcpy(header[14..54], std.mem.asBytes(&info)[0..40]);
    var written: u32 = 0;
    _ = WriteFile(f, &header, 54, &written, null);
    _ = WriteFile(f, pixels.ptr, @intCast(bytes), &written, null);
    _ = CloseHandle(f);
    ExitProcess(0);
}

fn onPaint(hwnd: HWND) void {
    var ps: PAINTSTRUCT = .{};
    const hdc = BeginPaint(hwnd, &ps);
    var rc: RECT = .{};
    _ = GetClientRect(hwnd, &rc);
    const w = rc.right;
    const h = rc.bottom;
    const mem = CreateCompatibleDC(hdc);
    const bmp = CreateCompatibleBitmap(hdc, w, h);
    const old = SelectObject(mem, bmp);
    paint(mem, w, h);
    _ = BitBlt(hdc, 0, 0, w, h, mem, 0, 0, 0x00CC0020);
    _ = SelectObject(mem, old);
    if (st.shot_len > 0) saveShot(mem, bmp, w, h);
    _ = DeleteObject(bmp);
    _ = DeleteDC(mem);
    _ = EndPaint(hwnd, &ps);
}

fn onKey(vk: usize) void {
    const ctrl = GetKeyState(0x11) < 0;
    const cols: i64 = if (st.sys.isRosquin()) 13 else 7;
    switch (vk) {
        0x25 => select(st.selected.addDays(-1)),
        0x27 => select(st.selected.addDays(1)),
        0x26 => select(st.selected.addDays(-cols)),
        0x28 => select(st.selected.addDays(cols)),
        0x21 => shiftPage(-1),
        0x22 => shiftPage(1),
        0x24 => select(st.today),
        'G' => if (ctrl) openGoto(),
        'N' => if (ctrl) openEditor(null, st.selected),
        'C' => if (ctrl) copyDate(.text),
        else => {},
    }
}

fn onClick(x: i32, y: i32) void {
    for (st.buttons[0..st.nbuttons]) |b| {
        if (x < b.x or x >= b.x + b.w or y < b.y or y >= b.y + b.h) continue;
        switch (b.id) {
            1 => shiftPage(-1),
            2 => shiftPage(1),
            3 => select(st.today),
            4 => openGoto(),
            5 => {
                var pt: POINT = .{ .x = b.x, .y = b.y + b.h };
                _ = ClientToScreen(st.hwnd, &pt);
                _ = TrackPopupMenu(st.sys_menu, 0, pt.x, pt.y, 0, st.hwnd, null);
            },
            6, 7, 8 => toggleKind(b.id - 6),
            9 => {
                st.named_only = !st.named_only;
                syncOptionChecks();
                _ = InvalidateRect(st.hwnd, null, 0);
            },
            23 => {
                const m = CreatePopupMenu();
                inline for (kind_names, 0..) |name, k| {
                    _ = AppendMenuW(m, MF_STRING | (if (st.show[k]) @as(u32, 8) else 0), 230 + k, lit(name));
                }
                _ = AppendMenuW(m, MF_SEPARATOR, 0, null);
                _ = AppendMenuW(m, MF_STRING | (if (st.named_only) @as(u32, 8) else 0), 233, lit("Named days only"));
                _ = AppendMenuW(m, MF_STRING | (if (st.native_on) @as(u32, 8) else 0), 234, lit("Native script"));
                var pt: POINT = .{ .x = b.x, .y = b.y + b.h };
                _ = ClientToScreen(st.hwnd, &pt);
                _ = TrackPopupMenu(m, 0, pt.x, pt.y, 0, st.hwnd, null);
            },
            20 => openEditor(null, st.selected),
            22 => saveView(),
            21 => {
                var pt: POINT = .{ .x = b.x, .y = b.y + b.h };
                _ = ClientToScreen(st.hwnd, &pt);
                showCopyMenu(pt.x, pt.y);
            },
            300...2000 => {
                const list = st.list orelse return;
                const idx = (b.id - 300) / 2;
                if (idx < list.items.len) {
                    if ((b.id - 300) % 2 == 0) openEditor(&list.items[idx], st.selected) else deleteEvent(list.items[idx].id);
                }
            },
            else => {},
        }
        return;
    }
    if (x < 8 or x > 8 + st.view_w or y < 104 or y > 104 + st.view_h) return;
    for (st.cells[0..st.ncells]) |c| {
        if (x >= c.x and x < c.x + c.w and y >= c.y and y < c.y + c.h) return select(c.date);
    }
}

fn onCommand(id: usize) void {
    switch (id) {
        100...109 => setSystem(id - 100),
        206 => saveView(),
        110 => shiftPage(-1),
        111 => shiftPage(1),
        112 => select(st.today),
        113 => openGoto(),
        120 => stepSpecial(rosquin.leap_day, false),
        121 => stepSpecial(rosquin.leap_day, true),
        122 => stepSpecial(rosquin.year_end_day, false),
        123 => stepSpecial(rosquin.year_end_day, true),
        130 => PostQuitMessage(0),
        200 => openEditor(null, st.selected),
        201 => menuImport(),
        202 => menuExport(),
        203 => menuChooseSync(),
        204 => syncNow(true),
        210 => {
            st.twelve_hour = !st.twelve_hour;
            saveBool("twelve-hour", st.twelve_hour);
            syncOptionChecks();
            _ = InvalidateRect(st.hwnd, null, 0);
        },
        211 => {
            st.named_only = !st.named_only;
            syncOptionChecks();
            _ = InvalidateRect(st.hwnd, null, 0);
        },
        212 => showSettingsPath(),
        213 => toggleNative(),
        230, 231, 232 => toggleKind(id - 230),
        233 => {
            st.named_only = !st.named_only;
            syncOptionChecks();
            _ = InvalidateRect(st.hwnd, null, 0);
        },
        234 => toggleNative(),
        216 => nativeFontReport(),
        214 => chooseNativeFont(),
        215 => resetNativeFont(),
        205 => menuSaveFont(),
        400 => copyDate(.text),
        401 => copyDate(.code),
        402 => copyDate(.glyph),
        403 => copyDate(.both),
        404 => copyDate(.iso),
        else => {},
    }
}

fn mainProc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) callconv(.winapi) LRESULT {
    switch (msg) {
        WM_PAINT => {
            onPaint(hwnd);
            return 0;
        },
        WM_ERASEBKGND => return 1,
        WM_SIZE => {
            var rc: RECT = .{};
            _ = GetClientRect(hwnd, &rc);
            layoutNotes(rc.right, rc.bottom);
            _ = InvalidateRect(hwnd, null, 0);
            return 0;
        },
        WM_TIMER => {
            if (wp == 2) flushNote();
            if (wp == 1) checkReminders();
            return 0;
        },
        WM_KEYDOWN => {
            onKey(wp);
            return 0;
        },
        0x0204 => { // WM_RBUTTONDOWN: select the day and offer the copy menu
            const x: i32 = @as(i16, @truncate(lp));
            const y: i32 = @as(i16, @truncate(lp >> 16));
            for (st.cells[0..st.ncells]) |c| {
                if (x >= c.x and x < c.x + c.w and y >= c.y and y < c.y + c.h and y >= 104 and y <= 104 + st.view_h) {
                    select(c.date);
                    var pt: POINT = .{ .x = x, .y = y };
                    _ = ClientToScreen(hwnd, &pt);
                    showCopyMenu(pt.x, pt.y);
                    break;
                }
            }
            return 0;
        },
        WM_LBUTTONDOWN => {
            onClick(@as(i16, @truncate(lp)), @as(i16, @truncate(lp >> 16)));
            return 0;
        },
        WM_MOUSEWHEEL => {
            const delta: i16 = @truncate(@as(isize, @bitCast(wp)) >> 16);
            if (st.content_h > st.view_h and GetKeyState(0x11) >= 0) {
                scrollTo(1, st.oy - @divTrunc(@as(i32, delta), 3)); // a notch is 120: 40 pixels
            } else shiftPage(if (delta > 0) -1 else 1);
            return 0;
        },
        WM_VSCROLL => {
            onScroll(1, wp);
            return 0;
        },
        WM_HSCROLL => {
            onScroll(0, wp);
            return 0;
        },
        WM_COMMAND => {
            if ((wp & 0xFFFF) == 40) { // the note's EDIT control
                if ((wp >> 16) == 0x300 and !st.note_loading) {
                    st.note_dirty = true;
                    _ = SetTimer(hwnd, 2, 600, null);
                }
                return 0;
            }
            onCommand(wp & 0xFFFF);
            return 0;
        },
        WM_DESTROY => {
            flushNote();
            PostQuitMessage(0);
            return 0;
        },
        else => return DefWindowProcW(hwnd, msg, wp, lp),
    }
}

fn buildMenu() HANDLE {
    const bar = CreateMenu();
    const file = CreatePopupMenu();
    _ = AppendMenuW(file, MF_STRING, 200, lit("New event\tCtrl+N"));
    _ = AppendMenuW(file, MF_SEPARATOR, 0, null);
    _ = AppendMenuW(file, MF_STRING, 201, lit("Import calendar file\u{2026}"));
    _ = AppendMenuW(file, MF_STRING, 202, lit("Export calendar\u{2026}"));
    _ = AppendMenuW(file, MF_STRING, 203, lit("Choose sync file\u{2026}"));
    _ = AppendMenuW(file, MF_STRING, 204, lit("Sync now"));
    _ = AppendMenuW(file, MF_SEPARATOR, 0, null);
    _ = AppendMenuW(file, MF_STRING, 206, lit("Save this view as the default"));
    _ = AppendMenuW(file, MF_STRING, 205, lit("Save the Rosquin font\u{2026}"));
    _ = AppendMenuW(file, MF_SEPARATOR, 0, null);
    _ = AppendMenuW(file, MF_STRING, 130, lit("Exit"));
    _ = AppendMenuW(bar, MF_POPUP, @intFromPtr(file), lit("File"));
    const edit = CreatePopupMenu();
    _ = AppendMenuW(edit, MF_STRING, 400, lit("Copy date as text\tCtrl+C"));
    _ = AppendMenuW(edit, MF_STRING, 401, lit("Copy day code"));
    _ = AppendMenuW(edit, MF_STRING, 402, lit("Copy glyph (needs the Rosquin font)"));
    _ = AppendMenuW(edit, MF_STRING, 403, lit("Copy glyph and text"));
    _ = AppendMenuW(edit, MF_STRING, 404, lit("Copy date as 2026-11-06"));
    _ = AppendMenuW(bar, MF_POPUP, @intFromPtr(edit), lit("Edit"));
    const cal = CreatePopupMenu();
    const items = [_][*:0]const u16{
        lit("Julian"),                 lit("Gregorian"),               lit("Fixed (13 months)"),
        lit("R\u{25b}\u{b0}C\u{1d00}\u{29f}\u{2014}28.w\u{47b}"),
        lit("R\u{25b}\u{b0}C\u{1d00}\u{29f}\u{2014}7\u{1d0d}\u{1ecd}/4.w\u{47b}"),
        lit("R\u{25b}\u{b0}C\u{1d00}\u{29f}\u{2014}4\u{1d0d}\u{1ecd}/7.w\u{47b}"),
        lit("Chinese"), lit("Hebrew (Jewish)"), lit("Coptic"), lit("Ethiopian"),
    };
    for (items, 0..) |item, i| _ = AppendMenuW(cal, MF_STRING, 100 + @as(usize, i), item);
    st.sys_menu = cal;
    _ = AppendMenuW(bar, MF_POPUP, @intFromPtr(cal), lit("Calendar"));
    const go = CreatePopupMenu();
    _ = AppendMenuW(go, MF_STRING, 112, lit("Today\tHome"));
    _ = AppendMenuW(go, MF_STRING, 113, lit("Go to date\u{2026}\tCtrl+G"));
    _ = AppendMenuW(go, MF_SEPARATOR, 0, null);
    _ = AppendMenuW(go, MF_STRING, 120, lit("Previous Leap Day"));
    _ = AppendMenuW(go, MF_STRING, 121, lit("Next Leap Day"));
    _ = AppendMenuW(go, MF_STRING, 122, lit("Previous Year-End Day"));
    _ = AppendMenuW(go, MF_STRING, 123, lit("Next Year-End Day"));
    _ = AppendMenuW(bar, MF_POPUP, @intFromPtr(go), lit("Go"));
    const opt = CreatePopupMenu();
    _ = AppendMenuW(opt, MF_STRING, 210, lit("12-hour clock"));
    _ = AppendMenuW(opt, MF_STRING, 211, lit("Named days only"));
    _ = AppendMenuW(opt, MF_STRING, 213, lit("Show native script"));
    _ = AppendMenuW(opt, MF_STRING, 214, lit("Native font\u{2026}"));
    _ = AppendMenuW(opt, MF_STRING, 215, lit("Use the built-in native fonts"));
    _ = AppendMenuW(opt, MF_STRING, 216, lit("Native font check\u{2026}"));
    _ = AppendMenuW(opt, MF_SEPARATOR, 0, null);
    _ = AppendMenuW(opt, MF_STRING, 212, lit("Where are my settings?"));
    st.options_menu = opt;
    _ = AppendMenuW(bar, MF_POPUP, @intFromPtr(opt), lit("Options"));
    return bar;
}

fn syncOptionChecks() void {
    _ = CheckMenuItem(st.options_menu, 210, if (st.twelve_hour) 8 else 0);
    _ = CheckMenuItem(st.options_menu, 211, if (st.named_only) 8 else 0);
    _ = CheckMenuItem(st.options_menu, 213, if (st.native_on) 8 else 0);
}

fn showSettingsPath() void {
    const path = common.paths.userConfigFile(gpa, "calendar.toml") catch return;
    defer gpa.free(path);
    var msg: [700]u8 = undefined;
    var w16: [700]u16 = undefined;
    _ = wide(&w16, std.fmt.bufPrint(&msg, "Settings, events and notes are kept in\n{s}\n\nIt is a plain TOML file; it is made on the first run.", .{path}) catch "");
    _ = MessageBoxW(st.hwnd, @ptrCast(&w16), lit("Settings"), 0x40);
}

fn envNumber(name: [*:0]const u16) ?usize {
    var buf: [16]u16 = undefined;
    const n = GetEnvironmentVariableW(name, &buf, 16);
    if (n == 0 or n >= 16) return null;
    return std.fmt.parseInt(usize, std.unicode.utf16LeToUtf8Alloc(std.heap.page_allocator, buf[0..n]) catch return null, 10) catch null;
}

pub fn main() void {
    var fonts: u32 = 0;
    _ = AddFontMemResourceEx(glyph_font_data.ptr, glyph_font_data.len, null, &fonts);
    inline for (.{ @embedFile("font-cjk"), @embedFile("font-he"), @embedFile("font-et"), @embedFile("font-cop") }) |data| {
        if (AddFontMemResourceEx(data.ptr, data.len, null, &fonts) != null) st.fonts_added += 1;
    }

    st.gui_font = CreateFontW(-14, 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 4, 0, lit("Segoe UI"));
    loadSettings();

    var now: SYSTEMTIME = undefined;
    GetLocalTime(&now);
    st.today = .{ .year = now.year, .month = @intCast(now.month), .day = @intCast(now.day) };
    st.selected = st.today;

    const n = GetEnvironmentVariableW(lit("ROSQUIN_SHOT"), &st.shot, 259);
    st.shot_len = n;
    if (envNumber(lit("ROSQUIN_SYS"))) |i| if (i <= 9) {
        st.sys = @enumFromInt(i);
    };
    if (envNumber(lit("ROSQUIN_NATIVE"))) |_| st.native_on = true;
    if (envNumber(lit("ROSQUIN_SHOW"))) |mask| {
        var k: usize = 0;
        while (k < 3) : (k += 1) if (mask & (@as(usize, 1) << @intCast(k)) != 0) toggleKind(k);
    }
    var datebuf: [16]u16 = undefined;
    const dn = GetEnvironmentVariableW(lit("ROSQUIN_DATE"), &datebuf, 16);
    if (dn > 0 and dn < 16) {
        var u8buf: [32]u8 = undefined;
        const k = std.unicode.utf16LeToUtf8(&u8buf, datebuf[0..dn]) catch 0;
        if (parseGoto(u8buf[0..k])) |d| st.selected = d;
    }
    const v = calsys.fromCivil(st.sys, st.selected);
    st.year = v.year;
    st.month = calsys.pageOf(st.sys, v);

    const inst = GetModuleHandleW(null);
    const arrow = LoadCursorW(null, 32512);
    const white = GetStockObject(0);
    _ = RegisterClassExW(&.{ .lpfnWndProc = &mainProc, .hInstance = inst, .hCursor = arrow, .hbrBackground = white, .lpszClassName = lit("RosquinCalendar") });
    _ = RegisterClassExW(&.{ .lpfnWndProc = &editorProc, .hInstance = inst, .hCursor = arrow, .hbrBackground = @ptrFromInt(16), .lpszClassName = lit("RosquinEvent") });
    _ = RegisterClassExW(&.{ .lpfnWndProc = &gotoProc, .hInstance = inst, .hCursor = arrow, .hbrBackground = @ptrFromInt(16), .lpszClassName = lit("RosquinGoto") });

    st.menu = buildMenu();
    // Never bigger than the usable part of the screen: the grid scrolls instead.
    var work: RECT = .{ .left = 0, .top = 0, .right = 1280, .bottom = 720 };
    _ = SystemParametersInfoW(0x30, 0, &work, 0);
    const ww = @min(1500, work.right - work.left - 20);
    const wh = @min(860, work.bottom - work.top - 20);
    const wx = work.left + @divTrunc(work.right - work.left - ww, 2);
    const wy = work.top + @divTrunc(work.bottom - work.top - wh, 2);
    const hwnd = CreateWindowExW(0, lit("RosquinCalendar"), lit("R\u{25b}\u{b0}C\u{1d00}\u{29f}"), WS_OVERLAPPEDWINDOW | WS_VISIBLE | WS_VSCROLL | WS_HSCROLL | WS_CLIPCHILDREN, wx, wy, ww, wh, null, null, inst, null);
    st.hwnd = hwnd;
    _ = SetMenu(hwnd, st.menu);
    st.notes = CreateWindowExW(0x200, lit("EDIT"), lit(""), WS_CHILD | WS_VISIBLE | WS_BORDER | WS_VSCROLL | ES_MULTILINE | ES_AUTOVSCROLL | ES_WANTRETURN, 0, 0, 10, 10, hwnd, @ptrFromInt(40), inst, null);
    _ = SendMessageW(st.notes, WM_SETFONT, @intFromPtr(st.gui_font), 1);
    {
        var crc: RECT = .{};
        _ = GetClientRect(hwnd, &crc);
        layoutNotes(crc.right, crc.bottom);
    }
    loadNote(st.selected);
    syncOptionChecks();
    _ = SetTimer(hwnd, 1, 15000, null);
    _ = CheckMenuRadioItem(st.sys_menu, 100, 109, 100 + @as(u32, @intFromEnum(st.sys)), 0);
    _ = ShowWindow(hwnd, 1);
    _ = UpdateWindow(hwnd);

    var msg: MSG = .{};
    while (GetMessageW(&msg, null, 0, 0) > 0) {
        if (st.goto != null and IsDialogMessageW(st.goto, &msg) != 0) continue;
        if (st.editor != null and IsDialogMessageW(st.editor, &msg) != 0) continue;
        _ = TranslateMessage(&msg);
        _ = DispatchMessageW(&msg);
    }
}

test "the shared layer builds for Windows" {
    _ = common.events;
    _ = common.Config;
}
