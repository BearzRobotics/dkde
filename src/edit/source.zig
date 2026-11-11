//! GtkSourceView 5 (the editing component of gedit and GNOME Text Editor)
//! and libspelling, loaded with dlopen when they are installed.
//!
//! Both are optional: dkde builds without their headers, and without the
//! libraries the editor is a plain GtkTextView (no line numbers, syntax
//! colours or spell checking). GtkSourceView's buffer and view are subclasses
//! of GtkTextBuffer and GtkTextView, so the rest of the editor treats them as
//! those; only the extras below go through here.

const std = @import("std");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const gio = @import("gio2");

extern fn dlopen(name: [*:0]const u8, flags: c_int) ?*anyopaque;
extern fn dlsym(handle: *anyopaque, name: [*:0]const u8) ?*anyopaque;
const RTLD_NOW: c_int = 2;

pub const Language = opaque {};
pub const Scheme = opaque {};
const LanguageManager = opaque {};
const SchemeManager = opaque {};
const SpaceDrawer = opaque {};
const Completion = opaque {};
const Compositor = opaque {};
const Checker = opaque {};

pub const ChangeCase = enum(c_int) { lower = 0, upper = 1, toggle = 2, title = 3 };

/// GtkSourceSpaceTypeFlags and GtkSourceSpaceLocationFlags.
const space_all: c_int = 0x0F;
const location_all: c_int = 0x07;

const Fns = struct {
    gtk_source_init: *const fn () callconv(.c) void,
    gtk_source_buffer_new: *const fn (?*gtk.TextTagTable) callconv(.c) *gtk.TextBuffer,
    gtk_source_view_new_with_buffer: *const fn (*gtk.TextBuffer) callconv(.c) *gtk.Widget,
    gtk_source_buffer_set_language: *const fn (*gtk.TextBuffer, ?*Language) callconv(.c) void,
    gtk_source_buffer_get_language: *const fn (*gtk.TextBuffer) callconv(.c) ?*Language,
    gtk_source_buffer_set_style_scheme: *const fn (*gtk.TextBuffer, ?*Scheme) callconv(.c) void,
    gtk_source_buffer_sort_lines: *const fn (*gtk.TextBuffer, *gtk.TextIter, *gtk.TextIter, c_int, c_int) callconv(.c) void,
    gtk_source_buffer_change_case: *const fn (*gtk.TextBuffer, ChangeCase, *gtk.TextIter, *gtk.TextIter) callconv(.c) void,
    gtk_source_buffer_join_lines: *const fn (*gtk.TextBuffer, *gtk.TextIter, *gtk.TextIter) callconv(.c) void,
    gtk_source_language_manager_get_default: *const fn () callconv(.c) *LanguageManager,
    gtk_source_language_manager_guess_language: *const fn (*LanguageManager, ?[*:0]const u8, ?[*:0]const u8) callconv(.c) ?*Language,
    gtk_source_language_manager_get_language: *const fn (*LanguageManager, [*:0]const u8) callconv(.c) ?*Language,
    gtk_source_language_manager_get_language_ids: *const fn (*LanguageManager) callconv(.c) ?[*:null]const ?[*:0]const u8,
    gtk_source_language_get_name: *const fn (*Language) callconv(.c) [*:0]const u8,
    gtk_source_language_get_id: *const fn (*Language) callconv(.c) [*:0]const u8,
    gtk_source_language_get_metadata: *const fn (*Language, [*:0]const u8) callconv(.c) ?[*:0]const u8,
    gtk_source_style_scheme_manager_get_default: *const fn () callconv(.c) *SchemeManager,
    gtk_source_style_scheme_manager_get_scheme: *const fn (*SchemeManager, [*:0]const u8) callconv(.c) ?*Scheme,
    gtk_source_style_scheme_manager_get_scheme_ids: *const fn (*SchemeManager) callconv(.c) ?[*:null]const ?[*:0]const u8,
    gtk_source_style_scheme_get_name: *const fn (*Scheme) callconv(.c) [*:0]const u8,
    gtk_source_map_new: *const fn () callconv(.c) *gtk.Widget,
    gtk_source_map_set_view: *const fn (*gtk.Widget, *gtk.Widget) callconv(.c) void,
    gtk_source_view_get_space_drawer: *const fn (*gtk.Widget) callconv(.c) *SpaceDrawer,
    gtk_source_space_drawer_set_types_for_locations: *const fn (*SpaceDrawer, c_int, c_int) callconv(.c) void,
    gtk_source_space_drawer_set_enable_matrix: *const fn (*SpaceDrawer, c_int) callconv(.c) void,
    gtk_source_view_indent_lines: *const fn (*gtk.Widget, *gtk.TextIter, *gtk.TextIter) callconv(.c) void,
    gtk_source_view_unindent_lines: *const fn (*gtk.Widget, *gtk.TextIter, *gtk.TextIter) callconv(.c) void,
    gtk_source_view_get_completion: *const fn (*gtk.Widget) callconv(.c) *Completion,
    gtk_source_completion_words_new: *const fn (?[*:0]const u8) callconv(.c) *gobject.Object,
    gtk_source_completion_words_register: *const fn (*gobject.Object, *gtk.TextBuffer) callconv(.c) void,
    gtk_source_completion_add_provider: *const fn (*Completion, *gobject.Object) callconv(.c) void,
    gtk_source_print_compositor_new: *const fn (*gtk.TextBuffer) callconv(.c) *Compositor,
    gtk_source_print_compositor_paginate: *const fn (*Compositor, *gtk.PrintContext) callconv(.c) c_int,
    gtk_source_print_compositor_get_n_pages: *const fn (*Compositor) callconv(.c) c_int,
    gtk_source_print_compositor_draw_page: *const fn (*Compositor, *gtk.PrintContext, c_int) callconv(.c) void,
};

const SpellFns = struct {
    spelling_checker_get_default: *const fn () callconv(.c) *Checker,
    spelling_text_buffer_adapter_new: *const fn (*gtk.TextBuffer, *Checker) callconv(.c) *gobject.Object,
    spelling_text_buffer_adapter_set_enabled: *const fn (*gobject.Object, c_int) callconv(.c) void,
    spelling_text_buffer_adapter_get_menu_model: *const fn (*gobject.Object) callconv(.c) *gio.MenuModel,
};

var fns: Fns = undefined;
var spell: SpellFns = undefined;
var state: enum { untried, ok, missing } = .untried;
var spell_state: enum { untried, ok, missing } = .untried;

fn bind(comptime T: type, handle: *anyopaque, out: *T) bool {
    inline for (@typeInfo(T).@"struct".field_names) |name| {
        const sym = dlsym(handle, name) orelse return false;
        @field(out, name) = @ptrCast(@alignCast(sym));
    }
    return true;
}

/// True when GtkSourceView is installed (loads it the first time).
pub fn available() bool {
    if (state == .untried) {
        state = .missing;
        if (std.c.getenv("DKDE_EDIT_PLAIN") != null) return false;
        const handle = dlopen("libgtksourceview-5.so.0", RTLD_NOW) orelse return false;
        if (!bind(Fns, handle, &fns)) return false;
        fns.gtk_source_init();
        state = .ok;
    }
    return state == .ok;
}

/// True when libspelling is installed (it needs GtkSourceView's buffer).
pub fn spellAvailable() bool {
    if (spell_state == .untried) {
        spell_state = .missing;
        if (!available()) return false;
        const handle = dlopen("libspelling-1.so.2", RTLD_NOW) orelse return false;
        if (!bind(SpellFns, handle, &spell)) return false;
        spell_state = .ok;
    }
    return spell_state == .ok;
}

pub fn newBuffer() *gtk.TextBuffer {
    if (available()) return fns.gtk_source_buffer_new(null);
    return gtk.TextBuffer.new(null);
}

pub fn newView(buffer: *gtk.TextBuffer) *gtk.TextView {
    if (available()) return @ptrCast(@alignCast(fns.gtk_source_view_new_with_buffer(buffer)));
    return gtk.TextView.newWithBuffer(buffer);
}

fn setBool(obj: anytype, name: [:0]const u8, on: bool) void {
    obj.as(gobject.Object).set(name, @as(c_int, @intFromBool(on)), @as(?*anyopaque, null));
}

fn setInt(obj: anytype, name: [:0]const u8, value: c_uint) void {
    obj.as(gobject.Object).set(name, value, @as(?*anyopaque, null));
}

/// The view options the editor offers; each is a GtkSourceView property.
pub const ViewOptions = struct {
    line_numbers: bool = true,
    highlight_line: bool = true,
    right_margin: bool = false,
    margin_column: u32 = 80,
    tab_width: u32 = 4,
    spaces: bool = false,
    auto_indent: bool = true,
    show_whitespace: bool = false,
};

pub fn applyView(view: *gtk.TextView, o: ViewOptions) void {
    if (!available()) return;
    setBool(view, "show-line-numbers", o.line_numbers);
    setBool(view, "highlight-current-line", o.highlight_line);
    setBool(view, "show-right-margin", o.right_margin);
    setInt(view, "right-margin-position", o.margin_column);
    setInt(view, "tab-width", o.tab_width);
    setInt(view, "indent-width", @as(c_uint, @bitCast(@as(c_int, -1))));
    setBool(view, "insert-spaces-instead-of-tabs", o.spaces);
    setBool(view, "auto-indent", o.auto_indent);
    setBool(view, "indent-on-tab", true);
    setBool(view, "smart-backspace", true);
    view.as(gobject.Object).set("smart-home-end", @as(c_int, 1), @as(?*anyopaque, null)); // before
    const drawer = fns.gtk_source_view_get_space_drawer(view.as(gtk.Widget));
    fns.gtk_source_space_drawer_set_types_for_locations(drawer, location_all, if (o.show_whitespace) space_all else 0);
    fns.gtk_source_space_drawer_set_enable_matrix(drawer, @intFromBool(o.show_whitespace));
}

pub fn applyBuffer(buffer: *gtk.TextBuffer, syntax: bool) void {
    if (!available()) return;
    setBool(buffer, "highlight-matching-brackets", true);
    setBool(buffer, "highlight-syntax", syntax);
}

// ---- languages -------------------------------------------------------------

/// The language for a file, from its name and contents' type.
pub fn guessLanguage(filename: ?[:0]const u8, content_type: ?[:0]const u8) ?*Language {
    if (!available()) return null;
    const lm = fns.gtk_source_language_manager_get_default();
    return fns.gtk_source_language_manager_guess_language(lm, if (filename) |f| f.ptr else null, if (content_type) |c| c.ptr else null);
}

pub fn languageById(id: [:0]const u8) ?*Language {
    if (!available()) return null;
    return fns.gtk_source_language_manager_get_language(fns.gtk_source_language_manager_get_default(), id);
}

pub fn languageIds() []const ?[*:0]const u8 {
    if (!available()) return &.{};
    const ids = fns.gtk_source_language_manager_get_language_ids(fns.gtk_source_language_manager_get_default()) orelse return &.{};
    return std.mem.span(ids);
}

pub fn setLanguage(buffer: *gtk.TextBuffer, lang: ?*Language) void {
    if (available()) fns.gtk_source_buffer_set_language(buffer, lang);
}

pub fn language(buffer: *gtk.TextBuffer) ?*Language {
    if (!available()) return null;
    return fns.gtk_source_buffer_get_language(buffer);
}

pub fn languageName(lang: *Language) [:0]const u8 {
    return std.mem.span(fns.gtk_source_language_get_name(lang));
}

pub fn languageId(lang: *Language) [:0]const u8 {
    return std.mem.span(fns.gtk_source_language_get_id(lang));
}

/// A metadata value of the language, e.g. "line-comment-start".
pub fn languageMeta(lang: *Language, key: [:0]const u8) ?[:0]const u8 {
    const v = fns.gtk_source_language_get_metadata(lang, key) orelse return null;
    return std.mem.span(v);
}

// ---- colour schemes -------------------------------------------------------

pub fn schemeIds() []const ?[*:0]const u8 {
    if (!available()) return &.{};
    const ids = fns.gtk_source_style_scheme_manager_get_scheme_ids(fns.gtk_source_style_scheme_manager_get_default()) orelse return &.{};
    return std.mem.span(ids);
}

pub fn schemeName(id: [:0]const u8) ?[:0]const u8 {
    if (!available()) return null;
    const s = fns.gtk_source_style_scheme_manager_get_scheme(fns.gtk_source_style_scheme_manager_get_default(), id) orelse return null;
    return std.mem.span(fns.gtk_source_style_scheme_get_name(s));
}

/// Sets the colour scheme `id`; an empty id follows the light or dark look.
pub fn setScheme(buffer: *gtk.TextBuffer, id: []const u8, dark: bool) void {
    if (!available()) return;
    const sm = fns.gtk_source_style_scheme_manager_get_default();
    var buf: [128]u8 = undefined;
    var scheme: ?*Scheme = null;
    if (id.len > 0) {
        if (std.fmt.bufPrintSentinel(&buf, "{s}", .{id}, 0)) |z| scheme = fns.gtk_source_style_scheme_manager_get_scheme(sm, z) else |_| {}
    }
    if (scheme == null) {
        const fallbacks: []const [:0]const u8 = if (dark) &.{ "Adwaita-dark", "Yaru-dark", "oblivion", "classic-dark" } else &.{ "Adwaita", "Yaru", "classic" };
        for (fallbacks) |f| {
            scheme = fns.gtk_source_style_scheme_manager_get_scheme(sm, f);
            if (scheme != null) break;
        }
    }
    fns.gtk_source_buffer_set_style_scheme(buffer, scheme);
}

// ---- extras -----------------------------------------------------------------

/// The overview map for `view`, or null without GtkSourceView.
pub fn newMap(view: *gtk.TextView) ?*gtk.Widget {
    if (!available()) return null;
    const map = fns.gtk_source_map_new();
    fns.gtk_source_map_set_view(map, view.as(gtk.Widget));
    return map;
}

pub fn indent(view: *gtk.TextView, start: *gtk.TextIter, end: *gtk.TextIter, more: bool) bool {
    if (!available()) return false;
    if (more) fns.gtk_source_view_indent_lines(view.as(gtk.Widget), start, end) else fns.gtk_source_view_unindent_lines(view.as(gtk.Widget), start, end);
    return true;
}

pub fn sortLines(buffer: *gtk.TextBuffer, start: *gtk.TextIter, end: *gtk.TextIter, case_sensitive: bool, reverse: bool) bool {
    if (!available()) return false;
    var flags: c_int = 0;
    if (case_sensitive) flags |= 1;
    if (reverse) flags |= 2;
    fns.gtk_source_buffer_sort_lines(buffer, start, end, flags, 0);
    return true;
}

pub fn changeCase(buffer: *gtk.TextBuffer, how: ChangeCase, start: *gtk.TextIter, end: *gtk.TextIter) bool {
    if (!available()) return false;
    fns.gtk_source_buffer_change_case(buffer, how, start, end);
    return true;
}

pub fn joinLines(buffer: *gtk.TextBuffer, start: *gtk.TextIter, end: *gtk.TextIter) bool {
    if (!available()) return false;
    fns.gtk_source_buffer_join_lines(buffer, start, end);
    return true;
}

/// Offers words already in `buffer` as completions while typing in `view`.
pub fn addWordCompletion(view: *gtk.TextView, buffer: *gtk.TextBuffer) void {
    if (!available()) return;
    const words = fns.gtk_source_completion_words_new(null);
    fns.gtk_source_completion_words_register(words, buffer);
    fns.gtk_source_completion_add_provider(fns.gtk_source_view_get_completion(view.as(gtk.Widget)), words);
    words.unref();
}

/// Turns spell checking on or off for `view`, creating its adapter the first
/// time (kept on the view). False when libspelling is missing.
pub fn setSpellCheck(view: *gtk.TextView, buffer: *gtk.TextBuffer, on: bool) bool {
    if (!spellAvailable()) return false;
    const key = "dkde-spelling";
    const obj = view.as(gobject.Object);
    var adapter: ?*gobject.Object = if (obj.getData(key)) |d| @ptrCast(@alignCast(d)) else null;
    if (adapter == null) {
        if (!on) return true;
        const a = spell.spelling_text_buffer_adapter_new(buffer, spell.spelling_checker_get_default());
        obj.setDataFull(key, a, @ptrCast(&gobject.Object.unref));
        view.setExtraMenu(spell.spelling_text_buffer_adapter_get_menu_model(a));
        view.as(gtk.Widget).insertActionGroup("spelling", @ptrCast(@alignCast(a)));
        adapter = a;
    }
    spell.spelling_text_buffer_adapter_set_enabled(adapter.?, @intFromBool(on));
    return true;
}

/// Printing with syntax colours and line numbers.
pub const Printer = struct {
    compositor: *Compositor,

    pub fn create(buffer: *gtk.TextBuffer, font: [:0]const u8, line_numbers: bool, wrap: bool) ?Printer {
        if (!available()) return null;
        const c = fns.gtk_source_print_compositor_new(buffer);
        const obj: *gobject.Object = @ptrCast(@alignCast(c));
        obj.set("body-font-name", font.ptr, @as(?*anyopaque, null));
        obj.set("print-line-numbers", @as(c_uint, if (line_numbers) 1 else 0), @as(?*anyopaque, null));
        obj.set("wrap-mode", @as(c_int, if (wrap) @intFromEnum(gtk.WrapMode.word_char) else @intFromEnum(gtk.WrapMode.none)), @as(?*anyopaque, null));
        obj.set("print-header", @as(c_int, 0), @as(?*anyopaque, null));
        return .{ .compositor = c };
    }

    /// Lays out a slice of the pages; true when all are laid out.
    pub fn paginate(self: Printer, ctx: *gtk.PrintContext) bool {
        return fns.gtk_source_print_compositor_paginate(self.compositor, ctx) != 0;
    }

    pub fn pages(self: Printer) c_int {
        return fns.gtk_source_print_compositor_get_n_pages(self.compositor);
    }

    pub fn draw(self: Printer, ctx: *gtk.PrintContext, page: c_int) void {
        fns.gtk_source_print_compositor_draw_page(self.compositor, ctx, page);
    }

    pub fn deinit(self: Printer) void {
        const obj: *gobject.Object = @ptrCast(@alignCast(self.compositor));
        obj.unref();
    }
};
