//! The editor window: menus, tabs, find and replace, the status bar, the
//! side panels, saving and opening, and what is remembered between runs.

const std = @import("std");
const cairo = @import("cairo1");
const gdk = @import("gdk4");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const pango = @import("pango1");
const pangocairo = @import("pangocairo1");
const common = @import("common");
const termembed = @import("termembed");

const source = @import("source.zig");
const textfile = @import("textfile.zig");
const search = @import("search.zig");
const memory = @import("memory.zig");
const panels = @import("panels.zig");
const Doc = @import("doc.zig").Doc;

const tr = common.tr;

/// The most files under Open Recent.
const recent_shown = 12;

pub const Editor = struct {
    allocator: std.mem.Allocator,
    config: *common.Config,
    window: *gtk.ApplicationWindow,
    notebook: *gtk.Notebook,
    docs: std.ArrayList(*Doc) = .empty,
    /// The document in the visible tab; all actions work on it.
    cur: *Doc = undefined,

    // View and format options (remembered in edit.toml).
    opts: source.ViewOptions = .{},
    wrap: bool = true,
    syntax: bool = true,
    map_on: bool = false,
    spell: bool = false,
    completion: bool = true,
    restore_session: bool = true,
    scheme: [64]u8 = undefined,
    scheme_len: usize = 0,
    font_family: [128]u8 = undefined,
    font_family_len: usize = 0,
    font_size: f64 = 11,
    zoom: f64 = 1.0,
    css: *gtk.CssProvider,

    // Find and replace.
    search_bar: *gtk.SearchBar,
    find_entry: *gtk.SearchEntry,
    replace_entry: *gtk.Entry,
    replace_row: *gtk.Box,
    case_check: *gtk.CheckButton,
    word_check: *gtk.CheckButton,
    regex_check: *gtk.CheckButton,
    match_label: *gtk.Label,
    regex: ?*glib.Regex = null,
    matches: std.ArrayList(search.Match) = .empty,
    refind_source: c_uint = 0,

    // Status bar.
    pos_button: *gtk.MenuButton,
    goto_entry: *gtk.Entry,
    mode_label: *gtk.Label,
    lang_button: *gtk.MenuButton,
    lang_list: *gtk.ListBox,
    lang_search: *gtk.SearchEntry,
    lang_ids: std.ArrayList([:0]const u8) = .empty,
    indent_button: *gtk.MenuButton,
    eol_button: *gtk.MenuButton,
    enc_button: *gtk.MenuButton,
    syncing_status: bool = false,
    spaces_check: *gtk.CheckButton,
    width_buttons: [4]*gtk.CheckButton = undefined,

    // Panels.
    term_panel: *termembed.Panel,
    file_panel: *panels.FilePanel,
    grep_panel: *panels.GrepPanel,

    recent: std.ArrayList([:0]u8) = .empty,
    recent_handler: c_ulong = 0,
    dark_handler: c_ulong = 0,
    autosave_source: c_uint = 0,
    focus_source: c_uint = 0,
    draft_counter: u32 = 0,
    /// The window is closing for good: the session is written for the last time.
    finished: bool = false,
    /// After a Save As started from a close: what to do once it is saved.
    after_save: ?struct { doc: *Doc, pending: Pending } = null,

    const Pending = enum { open_file, close_window, close_tab };

    pub fn create(allocator: std.mem.Allocator, app: *gtk.Application, config: *common.Config) !*Editor {
        const self = try allocator.create(Editor);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .config = config,
            .window = gtk.ApplicationWindow.new(app),
            .notebook = gtk.Notebook.new(),
            .css = gtk.CssProvider.new(),
            .search_bar = gtk.SearchBar.new(),
            .find_entry = gtk.SearchEntry.new(),
            .replace_entry = gtk.Entry.new(),
            .replace_row = gtk.Box.new(.horizontal, 6),
            .case_check = gtk.CheckButton.newWithMnemonic(tr("Match _Case")),
            .word_check = gtk.CheckButton.newWithMnemonic(tr("_Whole Words")),
            .regex_check = gtk.CheckButton.newWithMnemonic(tr("Regular E_xpression")),
            .match_label = gtk.Label.new(""),
            .pos_button = gtk.MenuButton.new(),
            .goto_entry = gtk.Entry.new(),
            .mode_label = gtk.Label.new("INS"),
            .lang_button = gtk.MenuButton.new(),
            .lang_list = gtk.ListBox.new(),
            .lang_search = gtk.SearchEntry.new(),
            .indent_button = gtk.MenuButton.new(),
            .eol_button = gtk.MenuButton.new(),
            .enc_button = gtk.MenuButton.new(),
            .spaces_check = gtk.CheckButton.newWithLabel(tr("Use spaces")),
            .term_panel = try termembed.Panel.create(allocator),
            .file_panel = undefined,
            .grep_panel = undefined,
        };
        self.file_panel = try panels.FilePanel.create(self);
        self.grep_panel = try panels.GrepPanel.create(self);
        self.loadSettings();

        const window = self.window;
        window.as(gtk.Window).setDefaultSize(@max(400, config.getInt("edit", "width", 900)), @max(300, config.getInt("edit", "height", 640)));
        window.as(gtk.Widget).addCssClass("dkde");
        _ = common.header.create(window.as(gtk.Window), "accessories-text-editor", true);
        self.applyFont();
        if (gdk.Display.getDefault()) |display|
            gtk.StyleContext.addProviderForDisplay(display, self.css.as(gtk.StyleProvider), gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 5);

        const menu_bar = self.buildMenus(app);
        self.buildFindBar();
        const status = self.buildStatusBar();

        self.notebook.setScrollable(1);
        self.notebook.as(gtk.Widget).setVexpand(1);
        self.notebook.as(gtk.Widget).setHexpand(1);
        _ = gtk.Notebook.signals.switch_page.connect(self.notebook, *Editor, &onSwitchPage, self, .{});
        _ = gtk.Notebook.signals.page_reordered.connect(self.notebook, *Editor, &onReordered, self, .{});

        // Layout: menus, find bar; the folder tree beside the text; the
        // Find in Files results and the terminal below; the status bar.
        const text_area = gtk.Box.new(.vertical, 0);
        text_area.append(self.notebook.as(gtk.Widget));
        text_area.append(self.grep_panel.widget());
        const vertical = gtk.Paned.new(.vertical);
        vertical.setStartChild(text_area.as(gtk.Widget));
        vertical.setEndChild(self.term_panel.widget());
        vertical.setResizeStartChild(1);
        vertical.setResizeEndChild(0);
        vertical.setShrinkStartChild(0);
        vertical.setShrinkEndChild(0);
        const horizontal = gtk.Paned.new(.horizontal);
        horizontal.setStartChild(self.file_panel.widget());
        horizontal.setEndChild(vertical.as(gtk.Widget));
        horizontal.setResizeStartChild(0);
        horizontal.setShrinkStartChild(0);
        horizontal.setShrinkEndChild(0);
        horizontal.as(gtk.Widget).setVexpand(1);
        const root = gtk.Box.new(.vertical, 0);
        root.append(menu_bar.as(gtk.Widget));
        root.append(self.search_bar.as(gtk.Widget));
        root.append(horizontal.as(gtk.Widget));
        root.append(status.as(gtk.Widget));
        window.as(gtk.Window).setChild(root.as(gtk.Widget));

        // Files dropped on the window open in tabs.
        const drop = gtk.DropTarget.new(gdk.FileList.getGObjectType(), .{ .copy = true });
        _ = gtk.DropTarget.signals.drop.connect(drop, *Editor, &onDropFiles, self, .{});
        root.as(gtk.Widget).addController(drop.as(gtk.EventController));

        _ = self.addDoc() catch return error.OutOfMemory;
        if (config.getBool("edit", "file-panel", false)) self.setFilePanel(true);
        _ = gtk.Window.signals.close_request.connect(window.as(gtk.Window), *Editor, &onCloseRequest, self, .{});
        _ = gtk.Widget.signals.destroy.connect(window, *Editor, &onDestroy, self, .{});
        _ = gobject.Object.signals.notify.connect(window, *Editor, &onActiveChanged, self, .{ .detail = "is-active" });
        _ = gobject.Object.signals.notify.connect(window, *Editor, &onFocusWidgetChanged, self, .{ .detail = "focus-widget" });
        if (gtk.Settings.getDefault()) |settings|
            self.dark_handler = gobject.Object.signals.notify.connect(settings, *Editor, &onDarkChanged, self, .{ .detail = "gtk-application-prefer-dark-theme" });
        self.installShortcuts();
        if (std.c.getenv("DKDE_DEBUG_MINWIDTH") != null) {
            const parts = [_]struct { n: []const u8, w: *gtk.Widget }{
                .{ .n = "menu", .w = menu_bar.as(gtk.Widget) },
                .{ .n = "search_bar", .w = self.search_bar.as(gtk.Widget) },
                .{ .n = "horizontal", .w = horizontal.as(gtk.Widget) },
                .{ .n = "notebook", .w = self.notebook.as(gtk.Widget) },
                .{ .n = "file_panel", .w = self.file_panel.widget() },
                .{ .n = "term", .w = self.term_panel.widget() },
                .{ .n = "status", .w = status.as(gtk.Widget) },
                .{ .n = "root", .w = root.as(gtk.Widget) },
            };
            for (parts) |p| {
                var min: c_int = 0;
                var nat: c_int = 0;
                p.w.measure(.horizontal, -1, &min, &nat, null, null);
                std.debug.print("minwidth {s}: {d} (natural {d})\n", .{ p.n, min, nat });
            }
        }
        self.loadRecent();
        self.recent_handler = gtk.RecentManager.signals.changed.connect(gtk.RecentManager.getDefault(), *Editor, &onRecentChanged, self, .{});
        self.refresh();
        return self;
    }

    fn onDestroy(_: *gtk.ApplicationWindow, self: *Editor) callconv(.c) void {
        if (self.recent_handler != 0) gobject.signalHandlerDisconnect(gtk.RecentManager.getDefault().as(gobject.Object), self.recent_handler);
        if (self.dark_handler != 0) if (gtk.Settings.getDefault()) |s| gobject.signalHandlerDisconnect(s.as(gobject.Object), self.dark_handler);
        if (self.autosave_source != 0) _ = glib.Source.remove(self.autosave_source);
        if (self.refind_source != 0) _ = glib.Source.remove(self.refind_source);
        if (self.focus_source != 0) _ = glib.Source.remove(self.focus_source);
        for (self.docs.items) |doc| doc.destroy();
        self.docs.deinit(self.allocator);
        for (self.recent.items) |p| self.allocator.free(p);
        self.recent.deinit(self.allocator);
        self.lang_ids.deinit(self.allocator);
        self.matches.deinit(self.allocator);
        if (self.regex) |r| r.unref();
        self.term_panel.destroy();
        self.file_panel.destroy();
        self.grep_panel.destroy();
        self.css.as(gobject.Object).unref();
        self.allocator.destroy(self);
    }

    // ---- settings ----------------------------------------------------------------

    fn loadSettings(self: *Editor) void {
        const c = self.config;
        self.wrap = c.getBool("edit", "word-wrap", true);
        self.syntax = c.getBool("edit", "syntax-highlighting", true);
        self.map_on = c.getBool("edit", "overview-map", false);
        self.spell = c.getBool("edit", "spell-check", false);
        self.completion = c.getBool("edit", "word-completion", true);
        self.restore_session = c.getBool("edit", "restore-session", true);
        self.opts = .{
            .line_numbers = c.getBool("edit", "line-numbers", true),
            .highlight_line = c.getBool("edit", "highlight-current-line", true),
            .right_margin = c.getBool("edit", "right-margin", false),
            .margin_column = @intCast(std.math.clamp(c.getInt("edit", "right-margin-column", 80), 1, 1000)),
            .tab_width = @intCast(std.math.clamp(c.getInt("edit", "tab-width", 4), 1, 16)),
            .spaces = c.getBool("edit", "insert-spaces", false),
            .auto_indent = c.getBool("edit", "auto-indent", true),
            .show_whitespace = c.getBool("edit", "show-whitespace", false),
        };
        const scheme = c.getString(self.allocator, "edit", "color-scheme", "") catch null;
        defer if (scheme) |s| self.allocator.free(s);
        self.setSchemeName(scheme orelse "");
        const font = c.getString(self.allocator, "edit", "font", "Monospace 11") catch null;
        defer if (font) |f| self.allocator.free(f);
        self.setFontName(font orelse "Monospace 11");
    }

    fn setSchemeName(self: *Editor, id: []const u8) void {
        const n = @min(id.len, self.scheme.len);
        @memcpy(self.scheme[0..n], id[0..n]);
        self.scheme_len = n;
    }

    fn schemeName(self: *const Editor) []const u8 {
        return self.scheme[0..self.scheme_len];
    }

    fn setFontName(self: *Editor, name: []const u8) void {
        var buf: [160]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{name}, 0) catch return;
        const desc = pango.FontDescription.fromString(z);
        defer desc.free();
        const family = std.mem.span(desc.getFamily() orelse "Monospace");
        const n = @min(family.len, self.font_family.len);
        @memcpy(self.font_family[0..n], family[0..n]);
        self.font_family_len = n;
        const size = desc.getSize();
        self.font_size = if (size > 0) @as(f64, @floatFromInt(size)) / pango.SCALE else 11;
    }

    fn fontName(self: *const Editor, buf: []u8) [:0]const u8 {
        return std.fmt.bufPrintSentinel(buf, "{s} {d:.0}", .{ self.font_family[0..self.font_family_len], self.font_size }, 0) catch "Monospace 11";
    }

    fn applyFont(self: *Editor) void {
        var buf: [512]u8 = undefined;
        const css = std.fmt.bufPrintSentinel(&buf,
            \\textview.dkde-edit-text {{ font-family: "{s}"; font-size: {d:.1}pt; }}
            \\.dkde-edit-banner {{ padding: 6px 10px; background: alpha(@accent_bg_color, 0.18); border-bottom: 1px solid alpha(currentColor, 0.15); }}
        , .{ self.font_family[0..self.font_family_len], self.font_size * self.zoom }, 0) catch return;
        self.css.loadFromString(css);
    }

    fn saveBool(self: *Editor, key: [:0]const u8, value: bool) void {
        self.config.setBool("edit", key, value) catch {};
    }

    fn isDark() bool {
        const settings = gtk.Settings.getDefault() orelse return false;
        var value: c_int = 0;
        settings.as(gobject.Object).get("gtk-application-prefer-dark-theme", &value, @as(?*anyopaque, null));
        return value != 0;
    }

    fn onDarkChanged(_: *gtk.Settings, _: *gobject.ParamSpec, self: *Editor) callconv(.c) void {
        for (self.docs.items) |d| source.setScheme(d.buffer, self.schemeName(), isDark());
    }

    // ---- views -----------------------------------------------------------------

    /// A new view of `doc`'s buffer with the editor's options.
    pub fn makeView(self: *Editor, doc: *Doc) *gtk.TextView {
        const view = source.newView(doc.buffer);
        view.setMonospace(1);
        view.as(gtk.Widget).addCssClass("dkde-edit-text");
        view.setLeftMargin(if (source.available()) 4 else 8);
        view.setTopMargin(4);
        view.setBottomMargin(4);
        view.setWrapMode(if (self.wrap) .word_char else .none);
        source.applyView(view, self.opts);
        if (self.completion) source.addWordCompletion(view, doc.buffer);
        if (self.spell) _ = source.setSpellCheck(view, doc.buffer, true);
        const focus = gtk.EventControllerFocus.new();
        _ = gtk.EventControllerFocus.signals.enter.connect(focus, *Doc, &onViewFocus, doc, .{});
        view.as(gtk.Widget).addController(focus.as(gtk.EventController));
        _ = gobject.Object.signals.notify.connect(view, *Editor, &onOverwrite, self, .{ .detail = "overwrite" });
        return view;
    }

    fn onViewFocus(ctrl: *gtk.EventControllerFocus, doc: *Doc) callconv(.c) void {
        const w = ctrl.as(gtk.EventController).getWidget();
        doc.focused = @ptrCast(@alignCast(w));
    }

    fn eachView(self: *Editor, comptime f: fn (*Editor, *Doc, *gtk.TextView) void) void {
        for (self.docs.items) |d| {
            f(self, d, d.view);
            if (d.view2) |v| f(self, d, v);
        }
    }

    fn applyOptions(self: *Editor, _: *Doc, v: *gtk.TextView) void {
        source.applyView(v, self.opts);
        v.setWrapMode(if (self.wrap) .word_char else .none);
    }

    fn applySpell(self: *Editor, d: *Doc, v: *gtk.TextView) void {
        _ = source.setSpellCheck(v, d.buffer, self.spell);
    }

    fn refreshViews(self: *Editor) void {
        self.eachView(applyOptions);
        self.syncStatus();
    }

    // ---- menus and shortcuts ------------------------------------------------------

    fn buildMenus(self: *Editor, app: *gtk.Application) *gtk.PopoverMenuBar {
        const mb = common.menubar;
        const has_source = source.available();
        const menus = [_]mb.Menu{
            .{ .label = "_File", .entries = &.{
                mb.item("_New Tab", "new", "<Control>n"),
                mb.item("_Open…", "open", "<Control>o"),
                mb.dynamic("Open _Recent", "recent"),
                .separator,
                mb.item("_Save", "save", "<Control>s"),
                mb.item("Save _As…", "save-as", "<Control><Shift>s"),
                mb.item("Save A_ll", "save-all", "<Control><Alt>s"),
                mb.item("Re_load", "reload", null),
                .separator,
                mb.item("_Print…", "print", "<Control>p"),
                .separator,
                mb.item("_Close Tab", "close-tab", "<Control>w"),
                mb.item("E_xit", "close", "<Control>q"),
            } },
            .{ .label = "_Edit", .entries = &.{
                mb.item("_Undo", "undo", "<Control>z"),
                mb.item("_Redo", "redo", "<Control><Shift>z"),
                .separator,
                mb.item("Cu_t", "cut", "<Control>x"),
                mb.item("_Copy", "copy", "<Control>c"),
                mb.item("_Paste", "paste", "<Control>v"),
                mb.item("Select _All", "select-all", "<Control>a"),
                .separator,
                mb.item("_Duplicate Line", "dup-line", "<Control><Shift>d"),
                mb.item("D_elete Line", "del-line", "<Control><Shift>k"),
                mb.item("Move Line _Up", "line-up", "<Alt>Up"),
                mb.item("Move Line Do_wn", "line-down", "<Alt>Down"),
                mb.item("Toggle Co_mment", "comment", "<Control>slash"),
                mb.item("_Indent", "indent", "<Control>bracketright"),
                mb.item("Unin_dent", "unindent", "<Control>bracketleft"),
                .separator,
                mb.item("UPPER CASE", "upper", null),
                mb.item("lower case", "lower", null),
                mb.item("Title Case", "title", null),
                mb.item("_Sort Lines", "sort", null),
                mb.item("_Join Lines", "join", "<Control>j"),
                .separator,
                mb.item("Add Cursor A_bove", "cursor-up", "<Control><Alt>Up"),
                mb.item("Add Cursor Be_low", "cursor-down", "<Control><Alt>Down"),
            } },
            .{ .label = "_Search", .entries = &.{
                mb.item("_Find…", "find", "<Control>f"),
                mb.item("Find and _Replace…", "replace", "<Control>h"),
                mb.item("Find _Next", "find-next", "F3"),
                mb.item("Find _Previous", "find-prev", "<Shift>F3"),
                .separator,
                mb.item("_Go to Line…", "goto", "<Control>i"),
                mb.item("Find in F_iles…", "grep", "<Control><Shift>f"),
            } },
            .{ .label = "_View", .entries = &.{
                mb.checkKey("_File Panel", "file-panel", false, "F9"),
                mb.item("_Terminal", "toggle-terminal", "<Control>grave"),
                mb.item("Terminal: _Go to This File's Folder", "terminal-cd", null),
                mb.check("_Split View", "split", false),
                mb.check("_Overview Map", "map", self.map_on and has_source),
                .separator,
                mb.check("_Line Numbers", "line-numbers", self.opts.line_numbers),
                mb.check("_Highlight Current Line", "highlight-line", self.opts.highlight_line),
                mb.check("_Right Margin", "right-margin", self.opts.right_margin),
                mb.check("Show _Whitespace", "whitespace", self.opts.show_whitespace),
                mb.check("S_yntax Highlighting", "syntax", self.syntax),
                mb.dynamic("_Colour Scheme", "schemes"),
                .separator,
                mb.item("Zoom _In", "zoom-in", "<Control>plus"),
                mb.item("Zoom O_ut", "zoom-out", "<Control>minus"),
                mb.item("_Normal Size", "zoom-reset", "<Control>0"),
                .separator,
                mb.item("Ne_xt Tab", "next-tab", "<Control>Page_Down"),
                mb.item("Pre_vious Tab", "prev-tab", "<Control>Page_Up"),
            } },
            .{ .label = "F_ormat", .entries = &.{
                mb.check("_Word Wrap", "word-wrap", self.wrap),
                mb.check("_Auto Indent", "auto-indent", self.opts.auto_indent),
                mb.check("Insert _Spaces Instead of Tabs", "spaces", self.opts.spaces),
                mb.dynamic("_Tab Width", "tab-widths"),
                .separator,
                mb.item("_Font…", "font", null),
            } },
            .{ .label = "_Tools", .entries = &.{
                mb.check("Check _Spelling", "spell", self.spell and source.spellAvailable()),
                mb.check("_Word Completion", "completion", self.completion),
                mb.check("_Restore Tabs at Start", "restore-session", self.restore_session),
            } },
        };
        const bar = mb.build(app, self.window, &menus, Editor, onMenuAction, self);

        // Items that carry a value: a recent file, a scheme, a tab width.
        const string_type = glib.VariantType.new("s");
        defer string_type.free();
        self.valueAction("open-recent", string_type, onOpenRecent);
        self.valueAction("set-scheme", string_type, onSetScheme);
        self.valueAction("set-tab-width", string_type, onSetTabWidth);
        if (mb.submenu(self.window, "schemes")) |menu| {
            appendValueItem(menu, "Automatic (Light or Dark)", "win.set-scheme", "");
            for (source.schemeIds()) |id_opt| {
                const id = std.mem.span(id_opt orelse continue);
                appendValueItem(menu, source.schemeName(id) orelse id, "win.set-scheme", id);
            }
        }
        if (mb.submenu(self.window, "tab-widths")) |menu| {
            for ([_][:0]const u8{ "2", "3", "4", "8" }) |w| appendValueItem(menu, w, "win.set-tab-width", w);
        }
        // What needs GtkSourceView or libspelling is greyed out without them.
        if (!has_source) {
            for ([_][:0]const u8{ "map", "line-numbers", "highlight-line", "right-margin", "whitespace", "syntax", "auto-indent", "spaces", "completion" }) |a| mb.setEnabled(self.window, a, false);
        }
        if (!source.spellAvailable()) mb.setEnabled(self.window, "spell", false);
        return bar;
    }

    fn valueAction(self: *Editor, name: [:0]const u8, vt: *glib.VariantType, comptime handler: fn (*gio.SimpleAction, ?*glib.Variant, *Editor) callconv(.c) void) void {
        const action = gio.SimpleAction.new(name, vt);
        _ = gio.SimpleAction.signals.activate.connect(action, *Editor, &handler, self, .{});
        self.window.as(gio.ActionMap).addAction(action.as(gio.Action));
        action.as(gobject.Object).unref();
    }

    fn appendValueItem(menu: *gio.Menu, label: [:0]const u8, action: [:0]const u8, value: [:0]const u8) void {
        var buf: [160]u8 = undefined;
        // A "_" in a name would become a mnemonic: double it.
        var n: usize = 0;
        for (label) |c| {
            if (n + 3 >= buf.len) break;
            buf[n] = c;
            n += 1;
            if (c == '_') {
                buf[n] = '_';
                n += 1;
            }
        }
        buf[n] = 0;
        const it = gio.MenuItem.new(buf[0..n :0], null);
        defer it.as(gobject.Object).unref();
        it.setActionAndTargetValue(action, glib.Variant.newString(value));
        menu.appendItem(it);
    }

    const Shortcut = struct { trigger: [:0]const u8, action: []const u8 };
    /// Second keys for some actions, as other editors use them.
    const shortcuts = [_]Shortcut{
        .{ .trigger = "<Control>t", .action = "new" },
        .{ .trigger = "<Control>y", .action = "redo" },
        .{ .trigger = "<Control>l", .action = "goto" },
        .{ .trigger = "<Control>g", .action = "find-next" },
        .{ .trigger = "<Control><Shift>g", .action = "find-prev" },
        .{ .trigger = "<Control>equal", .action = "zoom-in" },
        .{ .trigger = "<Control><Alt>Page_Down", .action = "next-tab" },
        .{ .trigger = "<Control><Alt>Page_Up", .action = "prev-tab" },
        .{ .trigger = "<Control>KP_Add", .action = "zoom-in" },
        .{ .trigger = "<Control>KP_Subtract", .action = "zoom-out" },
    };

    fn installShortcuts(self: *Editor) void {
        const controller = gtk.ShortcutController.new();
        controller.as(gtk.EventController).setPropagationPhase(.capture);
        inline for (shortcuts) |s| {
            const action = gtk.CallbackAction.new(onShortcut, @ptrCast(@constCast(&s)), null);
            controller.addShortcut(gtk.Shortcut.new(gtk.ShortcutTrigger.parseString(s.trigger), @ptrCast(action)));
        }
        self.window.as(gtk.Widget).addController(controller.as(gtk.EventController));
        self.window.as(gobject.Object).setData("dkde-editor", self);
    }

    fn onShortcut(widget: *gtk.Widget, _: ?*glib.Variant, data: ?*anyopaque) callconv(.c) c_int {
        const shortcut: *const Shortcut = @ptrCast(@alignCast(data.?));
        const obj: *gobject.Object = @ptrCast(@alignCast(widget));
        const self: *Editor = @ptrCast(@alignCast(obj.getData("dkde-editor") orelse return 0));
        // In the terminal these keys belong to the shell (Ctrl+Y, Ctrl+L, Ctrl+G).
        if (self.terminalFocused() and terminalKeepsKey(shortcut.action)) return 0;
        self.perform(shortcut.action);
        return 1;
    }

    /// Does the keyboard focus sit in the terminal panel?
    fn terminalFocused(self: *Editor) bool {
        var w: ?*gtk.Widget = self.window.as(gtk.Window).getFocus();
        const panel = self.term_panel.widget();
        while (w) |x| : (w = x.getParent()) {
            if (x == panel) return true;
        }
        return false;
    }

    /// Editing commands whose keys a terminal program uses itself: Ctrl+C interrupts, Ctrl+Z
    /// suspends, Ctrl+X, Ctrl+A, Ctrl+L, Ctrl+Y, Ctrl+[ (Esc), Ctrl+H, Ctrl+J, Ctrl+I…
    const terminal_keys = [_][]const u8{
        "undo",     "redo",     "cut",      "copy",    "select-all", "dup-line",  "del-line", "line-up",
        "line-down", "comment", "indent",   "unindent", "join",       "replace",   "goto",     "cursor-up",
        "cursor-down", "find-next", "find-prev",
    };

    fn terminalKeepsKey(action: []const u8) bool {
        for (terminal_keys) |k| if (std.mem.eql(u8, k, action)) return true;
        return false;
    }

    /// With the terminal focused the editing actions are switched off, so that GTK hands their keys to
    /// the terminal instead of the text (Ctrl+C reaches the shell as an interrupt).
    fn onFocusWidgetChanged(_: *gtk.ApplicationWindow, _: *gobject.ParamSpec, self: *Editor) callconv(.c) void {
        const in_terminal = self.terminalFocused();
        const map = self.window.as(gio.ActionMap);
        for (terminal_keys) |name| {
            var buf: [32:0]u8 = undefined;
            const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{name}, 0) catch continue;
            const found = map.lookupAction(z) orelse continue;
            const simple: *gio.SimpleAction = @ptrCast(@alignCast(found));
            simple.setEnabled(@intFromBool(!in_terminal));
        }
    }

    fn onMenuAction(self: *Editor, action: []const u8) void {
        self.perform(action);
        // The menu gives the keyboard back to the text (an entry the action
        // opened keeps it).
        self.focusTextSoon();
    }

    fn checked(self: *Editor, action: [:0]const u8) bool {
        const found = self.window.as(gio.ActionMap).lookupAction(action) orelse return false;
        const state = found.getState() orelse return false;
        defer state.unref();
        return state.getBoolean() != 0;
    }

    fn perform(self: *Editor, action: []const u8) void {
        const eql = std.mem.eql;
        const doc = self.cur;
        const buffer = doc.buffer;
        // File.
        if (eql(u8, action, "new")) return self.newDocument();
        if (eql(u8, action, "open")) return self.proceed(.open_file);
        if (eql(u8, action, "save")) return self.save(doc);
        if (eql(u8, action, "save-as")) return self.saveAsDialog(doc);
        if (eql(u8, action, "save-all")) return self.saveAll();
        if (eql(u8, action, "reload")) return self.reloadDoc(doc, null);
        if (eql(u8, action, "print")) return self.print();
        if (eql(u8, action, "close-tab")) return self.confirmDiscard(doc, .close_tab);
        if (eql(u8, action, "close")) return self.window.as(gtk.Window).close();
        // Edit.
        if (eql(u8, action, "undo")) return buffer.undo();
        if (eql(u8, action, "redo")) return buffer.redo();
        if (eql(u8, action, "cut")) return buffer.cutClipboard(doc.focused.as(gtk.Widget).getClipboard(), 1);
        if (eql(u8, action, "copy")) return buffer.copyClipboard(doc.focused.as(gtk.Widget).getClipboard());
        if (eql(u8, action, "paste") and self.terminalFocused()) return self.term_panel.paste();
        if (eql(u8, action, "paste")) {
            if (doc.hasCursors()) return doc.pasteAtCursors();
            return buffer.pasteClipboard(doc.focused.as(gtk.Widget).getClipboard(), null, 1);
        }
        if (eql(u8, action, "select-all")) {
            var start: gtk.TextIter = undefined;
            var end: gtk.TextIter = undefined;
            buffer.getBounds(&start, &end);
            return buffer.selectRange(&start, &end);
        }
        if (eql(u8, action, "dup-line")) return self.duplicateLines(doc);
        if (eql(u8, action, "del-line")) return self.deleteLines(doc);
        if (eql(u8, action, "line-up")) return self.moveLines(doc, true);
        if (eql(u8, action, "line-down")) return self.moveLines(doc, false);
        if (eql(u8, action, "comment")) return self.toggleComment(doc);
        if (eql(u8, action, "indent")) return self.indentLines(doc, true);
        if (eql(u8, action, "unindent")) return self.indentLines(doc, false);
        if (eql(u8, action, "upper")) return self.changeCase(doc, .upper);
        if (eql(u8, action, "lower")) return self.changeCase(doc, .lower);
        if (eql(u8, action, "title")) return self.changeCase(doc, .title);
        if (eql(u8, action, "sort")) return self.sortLines(doc);
        if (eql(u8, action, "join")) return self.joinLines(doc);
        if (eql(u8, action, "cursor-up")) return doc.addCursorVertical(true);
        if (eql(u8, action, "cursor-down")) return doc.addCursorVertical(false);
        // Search.
        if (eql(u8, action, "find")) return self.openFind(false);
        if (eql(u8, action, "replace")) return self.openFind(true);
        if (eql(u8, action, "find-next")) return self.step(true);
        if (eql(u8, action, "find-prev")) return self.step(false);
        if (eql(u8, action, "goto")) {
            self.pos_button.popup();
            return;
        }
        if (eql(u8, action, "grep")) return self.openGrep();
        // View.
        if (eql(u8, action, "file-panel")) return self.setFilePanel(self.checked("file-panel"));
        if (eql(u8, action, "toggle-terminal") or eql(u8, action, "terminal-cd")) {
            const dir: ?[]const u8 = if (doc.path) |p| (std.fs.path.dirname(p) orelse null) else null;
            if (eql(u8, action, "toggle-terminal")) return self.term_panel.toggle(dir);
            self.term_panel.show(dir);
            if (dir) |d| self.term_panel.changeDirectory(d);
            return;
        }
        if (eql(u8, action, "split")) return doc.setSplit(self.checked("split"));
        if (eql(u8, action, "next-tab") or eql(u8, action, "prev-tab")) {
            const n = self.notebook.getNPages();
            if (n < 2) return;
            const at = self.notebook.getCurrentPage();
            return self.notebook.setCurrentPage(@mod(at + @as(c_int, if (eql(u8, action, "next-tab")) 1 else -1), n));
        }
        if (eql(u8, action, "map")) {
            self.map_on = self.checked("map");
            self.saveBool("overview-map", self.map_on);
            for (self.docs.items) |d| d.setMap(self.map_on);
            return;
        }
        const toggles = .{
            .{ "line-numbers", "line-numbers", "line_numbers" },
            .{ "highlight-line", "highlight-current-line", "highlight_line" },
            .{ "right-margin", "right-margin", "right_margin" },
            .{ "whitespace", "show-whitespace", "show_whitespace" },
            .{ "auto-indent", "auto-indent", "auto_indent" },
            .{ "spaces", "insert-spaces", "spaces" },
        };
        inline for (toggles) |t| if (eql(u8, action, t[0])) {
            @field(self.opts, t[2]) = self.checked(t[0]);
            self.saveBool(t[1], @field(self.opts, t[2]));
            return self.refreshViews();
        };
        if (eql(u8, action, "syntax")) {
            self.syntax = self.checked("syntax");
            self.saveBool("syntax-highlighting", self.syntax);
            for (self.docs.items) |d| source.applyBuffer(d.buffer, self.syntax);
            return;
        }
        if (eql(u8, action, "zoom-in")) return self.setZoom(self.zoom * 1.1);
        if (eql(u8, action, "zoom-out")) return self.setZoom(self.zoom / 1.1);
        if (eql(u8, action, "zoom-reset")) return self.setZoom(1.0);
        // Format.
        if (eql(u8, action, "word-wrap")) {
            self.wrap = self.checked("word-wrap");
            self.saveBool("word-wrap", self.wrap);
            return self.refreshViews();
        }
        if (eql(u8, action, "font")) return self.chooseFont();
        // Tools.
        if (eql(u8, action, "spell")) {
            self.spell = self.checked("spell");
            self.saveBool("spell-check", self.spell);
            return self.eachView(applySpell);
        }
        if (eql(u8, action, "completion")) {
            self.completion = self.checked("completion");
            self.saveBool("word-completion", self.completion);
            self.flash(tr("Word completion changes for tabs opened from now on."));
            return;
        }
        if (eql(u8, action, "restore-session")) {
            self.restore_session = self.checked("restore-session");
            self.saveBool("restore-session", self.restore_session);
            return;
        }
    }

    fn setZoom(self: *Editor, zoom: f64) void {
        self.zoom = std.math.clamp(zoom, 0.4, 4.0);
        self.applyFont();
        var buf: [32]u8 = undefined;
        self.flash(std.fmt.bufPrintSentinel(&buf, "Zoom {d:.0}%", .{self.zoom * 100}, 0) catch "");
    }

    fn setFilePanel(self: *Editor, on: bool) void {
        common.menubar.setChecked(self.window, "file-panel", on);
        self.saveBool("file-panel", on);
        if (on and self.file_panel.root == null) {
            const dir = if (self.cur.path) |p| std.fs.path.dirname(p) orelse "/" else std.mem.span(glib.getHomeDir());
            self.file_panel.setRoot(dir);
        }
        self.file_panel.widget().setVisible(@intFromBool(on));
    }

    fn openGrep(self: *Editor) void {
        var buf: [4096]u8 = undefined;
        const folder = self.file_panel.rootPath(&buf) orelse if (self.cur.path) |p| std.fs.path.dirname(p) orelse "/" else std.mem.span(glib.getHomeDir());
        // The selection, if any, is what to look for.
        var start: gtk.TextIter = undefined;
        var end: gtk.TextIter = undefined;
        var needle: ?[]const u8 = null;
        var sel: ?[*:0]u8 = null;
        if (self.cur.buffer.getSelectionBounds(&start, &end) != 0) {
            sel = self.cur.buffer.getText(&start, &end, 0);
            needle = std.mem.span(sel.?);
        }
        defer if (sel) |s| glib.free(s);
        self.grep_panel.open(folder, needle);
    }

    // ---- line editing ---------------------------------------------------------------

    /// The whole lines the selection (or the cursor) is on: from the start
    /// of the first to the start of the line after the last.
    fn lineRange(doc: *Doc, start: *gtk.TextIter, end: *gtk.TextIter) void {
        _ = doc.buffer.getSelectionBounds(start, end);
        if (start.compare(end) == 0) doc.buffer.getIterAtMark(start, doc.buffer.getInsert());
        if (start.compare(end) > 0) end.* = start.*;
        // A selection ending at the very start of a line does not take that line.
        if (end.startsLine() != 0 and end.compare(start) > 0) _ = end.backwardChar();
        start.setLineOffset(0);
        if (end.endsLine() == 0) _ = end.forwardToLineEnd();
        _ = end.forwardChar();
    }

    fn duplicateLines(self: *Editor, doc: *Doc) void {
        _ = self;
        var start: gtk.TextIter = undefined;
        var end: gtk.TextIter = undefined;
        lineRange(doc, &start, &end);
        const t = doc.buffer.getText(&start, &end, 1);
        defer glib.free(t);
        const s = std.mem.span(t);
        doc.buffer.beginUserAction();
        defer doc.buffer.endUserAction();
        // The last line of the file has no line end of its own.
        if (s.len == 0 or s[s.len - 1] != '\n') {
            doc.buffer.insert(&end, "\n", 1);
        }
        doc.buffer.insert(&end, @ptrCast(s.ptr), @intCast(s.len));
    }

    fn deleteLines(self: *Editor, doc: *Doc) void {
        _ = self;
        var start: gtk.TextIter = undefined;
        var end: gtk.TextIter = undefined;
        lineRange(doc, &start, &end);
        // The last line: take the line end before it instead.
        if (end.isEnd() != 0 and end.startsLine() == 0 and start.getLine() > 0) _ = start.backwardChar();
        doc.buffer.beginUserAction();
        doc.buffer.delete(&start, &end);
        doc.buffer.endUserAction();
    }

    fn moveLines(self: *Editor, doc: *Doc, up: bool) void {
        _ = self;
        const buffer = doc.buffer;
        var start: gtk.TextIter = undefined;
        var end: gtk.TextIter = undefined;
        lineRange(doc, &start, &end);
        const first = start.getLine();
        var last = end.getLine();
        if (end.startsLine() != 0 and end.compare(&start) > 0) last -= 1;
        if (up and first == 0) return;
        if (!up and last >= buffer.getLineCount() - 1) return;
        // Remember the selection as line and column, to put it back after.
        var sel_a: gtk.TextIter = undefined;
        var sel_b: gtk.TextIter = undefined;
        _ = buffer.getSelectionBounds(&sel_a, &sel_b);
        const a_line = sel_a.getLine();
        const a_col = sel_a.getLineOffset();
        const b_line = sel_b.getLine();
        const b_col = sel_b.getLineOffset();

        var block_start: gtk.TextIter = undefined;
        var block_end: gtk.TextIter = undefined;
        _ = buffer.getIterAtLine(&block_start, first);
        _ = buffer.getIterAtLine(&block_end, last);
        if (block_end.endsLine() == 0) _ = block_end.forwardToLineEnd();
        const block = buffer.getText(&block_start, &block_end, 1);
        defer glib.free(block);
        var other_start: gtk.TextIter = undefined;
        var other_end: gtk.TextIter = undefined;
        const other_line = if (up) first - 1 else last + 1;
        _ = buffer.getIterAtLine(&other_start, other_line);
        other_end = other_start;
        if (other_end.endsLine() == 0) _ = other_end.forwardToLineEnd();
        const other = buffer.getText(&other_start, &other_end, 1);
        defer glib.free(other);

        buffer.beginUserAction();
        defer buffer.endUserAction();
        var range_start: gtk.TextIter = undefined;
        var range_end: gtk.TextIter = undefined;
        _ = buffer.getIterAtLine(&range_start, if (up) other_line else first);
        _ = buffer.getIterAtLine(&range_end, if (up) last else other_line);
        if (range_end.endsLine() == 0) _ = range_end.forwardToLineEnd();
        buffer.delete(&range_start, &range_end);
        const b = std.mem.span(block);
        const o = std.mem.span(other);
        if (up) {
            buffer.insert(&range_start, @ptrCast(b.ptr), @intCast(b.len));
            buffer.insert(&range_start, "\n", 1);
            buffer.insert(&range_start, @ptrCast(o.ptr), @intCast(o.len));
        } else {
            buffer.insert(&range_start, @ptrCast(o.ptr), @intCast(o.len));
            buffer.insert(&range_start, "\n", 1);
            buffer.insert(&range_start, @ptrCast(b.ptr), @intCast(b.len));
        }
        const d: c_int = if (up) -1 else 1;
        var na: gtk.TextIter = undefined;
        var nb: gtk.TextIter = undefined;
        _ = buffer.getIterAtLineOffset(&na, a_line + d, a_col);
        _ = buffer.getIterAtLineOffset(&nb, b_line + d, b_col);
        buffer.selectRange(&na, &nb);
        doc.focused.scrollToMark(buffer.getInsert(), 0.05, 0, 0, 0);
    }

    /// The line comment of the document's language ("//", "#", ...).
    fn commentPrefix(doc: *Doc) ?[]const u8 {
        if (source.language(doc.buffer)) |lang| {
            if (source.languageMeta(lang, "line-comment-start")) |s| return s;
        }
        const path = doc.path orelse return null;
        const ext = std.fs.path.extension(path);
        const hash = [_][]const u8{ ".sh", ".py", ".rb", ".pl", ".toml", ".yaml", ".yml", ".conf", ".cfg", ".ini", ".mk", ".cmake", ".r" };
        for (hash) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return "#";
        const slashes = [_][]const u8{ ".c", ".h", ".cc", ".cpp", ".hpp", ".zig", ".js", ".ts", ".java", ".go", ".rs", ".cs", ".swift", ".kt", ".css", ".scss" };
        for (slashes) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return "//";
        if (std.ascii.eqlIgnoreCase(ext, ".sql") or std.ascii.eqlIgnoreCase(ext, ".lua")) return "--";
        const base = std.fs.path.basename(path);
        if (std.mem.eql(u8, base, "Makefile") or std.mem.startsWith(u8, base, ".")) return "#";
        return null;
    }

    /// Comments out the lines, or uncomments them when all are comments.
    fn toggleComment(self: *Editor, doc: *Doc) void {
        const prefix = commentPrefix(doc) orelse return self.flash(tr("This kind of file has no line comments."));
        const buffer = doc.buffer;
        var start: gtk.TextIter = undefined;
        var end: gtk.TextIter = undefined;
        lineRange(doc, &start, &end);
        const first = start.getLine();
        var last = end.getLine();
        if (end.startsLine() != 0 and end.compare(&start) > 0) last -= 1;
        // Commented already when every non-blank line starts with the prefix.
        var all = true;
        var line = first;
        while (line <= last) : (line += 1) {
            const t = lineText(buffer, line);
            defer glib.free(t.ptr);
            const trimmed = std.mem.trimStart(u8, t.text, " \t");
            if (trimmed.len == 0) continue;
            if (!std.mem.startsWith(u8, trimmed, prefix)) all = false;
        }
        buffer.beginUserAction();
        defer buffer.endUserAction();
        line = first;
        while (line <= last) : (line += 1) {
            const t = lineText(buffer, line);
            defer glib.free(t.ptr);
            const indent = t.text.len - std.mem.trimStart(u8, t.text, " \t").len;
            if (indent == t.text.len) continue;
            var at: gtk.TextIter = undefined;
            _ = buffer.getIterAtLineIndex(&at, line, @intCast(indent));
            if (all) {
                var to = at;
                var n = prefix.len;
                if (indent + n < t.text.len and t.text[indent + n] == ' ') n += 1;
                _ = to.forwardChars(@intCast(std.unicode.utf8CountCodepoints(t.text[indent .. indent + n]) catch n));
                buffer.delete(&at, &to);
            } else {
                buffer.insert(&at, @ptrCast(prefix.ptr), @intCast(prefix.len));
                buffer.insert(&at, " ", 1);
            }
        }
    }

    const LineText = struct { ptr: [*:0]u8, text: []const u8 };

    fn lineText(buffer: *gtk.TextBuffer, line: c_int) LineText {
        var a: gtk.TextIter = undefined;
        _ = buffer.getIterAtLine(&a, line);
        var b = a;
        if (b.endsLine() == 0) _ = b.forwardToLineEnd();
        const t = buffer.getText(&a, &b, 1);
        return .{ .ptr = t, .text = std.mem.span(t) };
    }

    fn indentLines(self: *Editor, doc: *Doc, more: bool) void {
        var start: gtk.TextIter = undefined;
        var end: gtk.TextIter = undefined;
        lineRange(doc, &start, &end);
        _ = end.backwardChar();
        if (source.indent(doc.focused, &start, &end, more)) return;
        // Without GtkSourceView: a tab more or less at each line's start.
        const buffer = doc.buffer;
        const first = start.getLine();
        const last = end.getLine();
        buffer.beginUserAction();
        defer buffer.endUserAction();
        var line = first;
        while (line <= last) : (line += 1) {
            var at: gtk.TextIter = undefined;
            _ = buffer.getIterAtLine(&at, line);
            if (more) {
                const unit: []const u8 = if (self.opts.spaces) "        "[0..@min(8, self.opts.tab_width)] else "\t";
                buffer.insert(&at, @ptrCast(unit.ptr), @intCast(unit.len));
            } else {
                var to = at;
                var n: u32 = 0;
                while (n < self.opts.tab_width and to.getChar() == ' ') : (n += 1) _ = to.forwardChar();
                if (n == 0 and to.getChar() == '\t') _ = to.forwardChar();
                buffer.delete(&at, &to);
            }
        }
    }

    const Case = enum { upper, lower, title };

    fn changeCase(self: *Editor, doc: *Doc, how: Case) void {
        const buffer = doc.buffer;
        var start: gtk.TextIter = undefined;
        var end: gtk.TextIter = undefined;
        if (buffer.getSelectionBounds(&start, &end) == 0) return self.flash(tr("Select some text first."));
        const t = buffer.getText(&start, &end, 1);
        defer glib.free(t);
        const len: isize = @intCast(std.mem.len(t));
        const out: [*:0]u8 = switch (how) {
            .upper => glib.utf8Strup(t, len),
            .lower => glib.utf8Strdown(t, len),
            .title => titleCase(t, len),
        };
        defer glib.free(out);
        self.replaceRange(doc, &start, &end, std.mem.span(out));
    }

    fn titleCase(t: [*:0]u8, len: isize) [*:0]u8 {
        const lower = glib.utf8Strdown(t, len);
        defer glib.free(lower);
        const s = std.mem.span(lower);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(std.heap.c_allocator);
        var start_of_word = true;
        var i: usize = 0;
        while (i < s.len) {
            const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
            const cp = std.unicode.utf8Decode(s[i..@min(s.len, i + n)]) catch s[i];
            const alnum = glib.unicharIsalnum(cp) != 0;
            if (start_of_word and alnum) {
                var buf: [8]u8 = undefined;
                const up = glib.unicharToupper(cp);
                const m = std.unicode.utf8Encode(@intCast(up), &buf) catch 0;
                out.appendSlice(std.heap.c_allocator, buf[0..m]) catch {};
            } else out.appendSlice(std.heap.c_allocator, s[i..@min(s.len, i + n)]) catch {};
            start_of_word = !alnum and cp != '\'';
            i += n;
        }
        return glib.strndup(@ptrCast(out.items.ptr), out.items.len).?;
    }

    /// Replaces `start`..`end` with `s` and selects the new text.
    fn replaceRange(self: *Editor, doc: *Doc, start: *gtk.TextIter, end: *gtk.TextIter, s: []const u8) void {
        _ = self;
        const buffer = doc.buffer;
        const from = start.getOffset();
        buffer.beginUserAction();
        buffer.delete(start, end);
        buffer.insert(start, @ptrCast(s.ptr), @intCast(s.len));
        buffer.endUserAction();
        var a: gtk.TextIter = undefined;
        buffer.getIterAtOffset(&a, from);
        buffer.selectRange(&a, start);
    }

    fn sortLines(self: *Editor, doc: *Doc) void {
        var start: gtk.TextIter = undefined;
        var end: gtk.TextIter = undefined;
        lineRange(doc, &start, &end);
        if (end.isEnd() == 0 or end.startsLine() != 0) _ = end.backwardChar();
        const t = doc.buffer.getText(&start, &end, 1);
        defer glib.free(t);
        const gpa = self.allocator;
        var lines: std.ArrayList([]const u8) = .empty;
        defer lines.deinit(gpa);
        var it = std.mem.splitScalar(u8, std.mem.span(t), '\n');
        while (it.next()) |l| lines.append(gpa, l) catch return;
        if (lines.items.len < 2) return self.flash(tr("Select the lines to sort."));
        std.mem.sort([]const u8, lines.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                const ka = glib.utf8CollateKey(@ptrCast(a.ptr), @intCast(a.len));
                defer glib.free(ka);
                const kb = glib.utf8CollateKey(@ptrCast(b.ptr), @intCast(b.len));
                defer glib.free(kb);
                return std.mem.orderZ(u8, ka, kb) == .lt;
            }
        }.less);
        const joined = std.mem.join(gpa, "\n", lines.items) catch return;
        defer gpa.free(joined);
        self.replaceRange(doc, &start, &end, joined);
    }

    fn joinLines(self: *Editor, doc: *Doc) void {
        const buffer = doc.buffer;
        var start: gtk.TextIter = undefined;
        var end: gtk.TextIter = undefined;
        if (buffer.getSelectionBounds(&start, &end) == 0) {
            // The cursor's line and the next.
            buffer.getIterAtMark(&start, buffer.getInsert());
            start.setLineOffset(0);
            end = start;
            if (end.forwardLine() == 0) return;
            if (end.endsLine() == 0) _ = end.forwardToLineEnd();
        }
        const t = buffer.getText(&start, &end, 1);
        defer glib.free(t);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);
        var it = std.mem.splitScalar(u8, std.mem.span(t), '\n');
        var first = true;
        while (it.next()) |l| {
            const piece = if (first) std.mem.trimEnd(u8, l, " \t") else std.mem.trim(u8, l, " \t");
            if (!first and piece.len > 0 and out.items.len > 0) out.append(self.allocator, ' ') catch return;
            out.appendSlice(self.allocator, piece) catch return;
            first = false;
        }
        self.replaceRange(doc, &start, &end, out.items);
    }

    // ---- files -------------------------------------------------------------------

    pub fn openPath(self: *Editor, arg: [:0]const u8) void {
        const file = gio.File.newForCommandlineArg(arg);
        defer file.as(gobject.Object).unref();
        self.openFile(file, null);
    }

    /// Opens `file` in a tab (or shows the tab that has it), at `place` or
    /// where it was left last time.
    pub fn openFile(self: *Editor, file: *gio.File, place: ?memory.Place) void {
        const path_c = file.getPath() orelse {
            common.dialogs.showError(self.window.as(gtk.Window), tr("Cannot open the file"), tr("Only files on this computer or on a mounted share can be opened."));
            return;
        };
        defer glib.free(path_c);
        const path = std.mem.span(path_c);
        for (self.docs.items) |d| if (d.path) |p| if (std.mem.eql(u8, p, path)) {
            self.showDoc(d);
            if (place) |pl| self.placeCursor(d, pl);
            return;
        };
        const doc = self.loadInto(null, path, null) orelse return;
        self.placeCursor(doc, place orelse self.rememberedPlace(path) orelse .{});
    }

    /// Reads `path` into `target` (or the blank tab, or a new tab), decoding
    /// it as `encoding` when given. Null when it could not be read.
    fn loadInto(self: *Editor, target: ?*Doc, path: []const u8, encoding: ?textfile.Encoding) ?*Doc {
        const win = self.window.as(gtk.Window);
        const cannot = tr("Cannot open the file");
        const bytes = (common.fsio.readFile(self.allocator, path, 512 << 20) catch |e| {
            var buf: [200]u8 = undefined;
            const msg = std.fmt.bufPrintSentinel(&buf, "{s}", .{switch (e) {
                error.AccessDenied, error.PermissionDenied => "You do not have permission to read it.",
                error.StreamTooLong => "It is larger than 512 MB.",
                error.IsDir => "It is a folder.",
                else => @errorName(e),
            }}, 0) catch "";
            common.dialogs.showError(win, cannot, msg);
            return null;
        }) orelse {
            // A file that does not exist yet: a new tab that saves there.
            const doc = target orelse self.blankOrNew() orelse return null;
            doc.setPath(path);
            doc.format = .{};
            doc.disk = null;
            doc.setText("");
            doc.guessLanguage("");
            self.afterLoad(doc);
            return doc;
        };
        defer self.allocator.free(bytes);
        const decoded = (if (encoding) |enc| decodeAs(self.allocator, bytes, enc) else textfile.decode(self.allocator, bytes)) catch |e| {
            common.dialogs.showError(win, cannot, switch (e) {
                error.Binary => tr("It is not a text file."),
                else => tr("It could not be read as text in that encoding."),
            });
            return null;
        };
        defer self.allocator.free(decoded.text);
        const doc = target orelse self.blankOrNew() orelse return null;
        doc.setPath(path);
        doc.format = decoded.format;
        doc.setText(decoded.text);
        doc.disk = Doc.statDisk(path);
        doc.guessLanguage(bytes[0..@min(bytes.len, 4096)]);
        self.afterLoad(doc);
        return doc;
    }

    fn decodeAs(gpa: std.mem.Allocator, bytes: []const u8, enc: textfile.Encoding) !textfile.Decoded {
        // Decoding in a chosen encoding: convert to UTF-8 first, then let
        // the usual reading find the line ends.
        if (enc == .utf8) return textfile.decode(gpa, bytes);
        var written: usize = 0;
        const out = glib.convert(@ptrCast(bytes.ptr), @intCast(bytes.len), "UTF-8", enc.codeset(), null, &written, null) orelse return error.Unrepresentable;
        defer glib.free(out);
        var d = try textfile.decode(gpa, out[0..written]);
        d.format.encoding = enc;
        return d;
    }

    fn afterLoad(self: *Editor, doc: *Doc) void {
        doc.watch();
        doc.showBanner(.none);
        source.applyBuffer(doc.buffer, self.syntax);
        source.setScheme(doc.buffer, self.schemeName(), isDark());
        if (doc.path) |p| self.noteRecent(p);
        self.refreshTab(doc);
        self.refresh();
        self.scheduleAutosave();
    }

    fn blankOrNew(self: *Editor) ?*Doc {
        if (self.cur.isBlank()) return self.cur;
        return self.addDoc() catch null;
    }

    fn placeCursor(self: *Editor, doc: *Doc, place: memory.Place) void {
        _ = self;
        var it: gtk.TextIter = undefined;
        const lines: u32 = @intCast(doc.buffer.getLineCount());
        _ = doc.buffer.getIterAtLine(&it, @intCast(@min(place.line, lines -| 1)));
        var end = it;
        if (end.endsLine() == 0) _ = end.forwardToLineEnd();
        if (place.column > 0) _ = doc.buffer.getIterAtLineOffset(&it, it.getLine(), @intCast(@min(place.column, @as(u32, @intCast(end.getLineOffset())))));
        doc.buffer.placeCursor(&it);
        doc.scrollToCursorSoon();
    }

    fn cursorPlace(doc: *Doc) memory.Place {
        var it: gtk.TextIter = undefined;
        doc.buffer.getIterAtMark(&it, doc.buffer.getInsert());
        return .{ .line = @intCast(it.getLine()), .column = @intCast(it.getLineOffset()) };
    }

    /// Reads the file again, dropping the text here.
    pub fn reloadDoc(self: *Editor, doc: *Doc, encoding: ?textfile.Encoding) void {
        const path = doc.path orelse return;
        const place = cursorPlace(doc);
        const copy = self.allocator.dupe(u8, path) catch return;
        defer self.allocator.free(copy);
        if (self.loadInto(doc, copy, encoding orelse doc.format.encoding)) |d| self.placeCursor(d, place);
    }

    fn newDocument(self: *Editor) void {
        _ = self.addDoc() catch {};
    }

    /// Runs `pending` for `doc` once its unsaved changes are saved or dropped.
    fn confirmDiscard(self: *Editor, doc: *Doc, pending: Pending) void {
        self.showDoc(doc);
        if (!doc.modified()) return self.proceed(pending);
        const ctx = std.heap.c_allocator.create(DiscardCtx) catch return;
        ctx.* = .{ .editor = self, .doc = doc, .pending = pending };
        var buf: [300]u8 = undefined;
        const title = std.fmt.bufPrintSentinel(&buf, "Save the changes to \u{201c}{s}\u{201d}?", .{doc.name()}, 0) catch "Save changes?";
        common.dialogs.choose(self.window.as(gtk.Window), title, tr("Your changes will be lost if you don't save them."), &.{ "Cancel", "Discard", "Save" }, 0, DiscardCtx, onDiscardAnswer, ctx);
    }

    const DiscardCtx = struct { editor: *Editor, doc: *Doc, pending: Pending };

    fn onDiscardAnswer(ctx: *DiscardCtx, index: c_int) void {
        defer std.heap.c_allocator.destroy(ctx);
        const self = ctx.editor;
        if (std.mem.indexOfScalar(*Doc, self.docs.items, ctx.doc) == null) return;
        switch (index) {
            1 => {
                ctx.doc.buffer.setModified(0);
                self.proceed(ctx.pending);
            },
            2 => {
                if (ctx.doc.path == null) {
                    // Untitled: continue once Save As has saved it.
                    self.after_save = .{ .doc = ctx.doc, .pending = ctx.pending };
                    return self.saveAsDialog(ctx.doc);
                }
                self.save(ctx.doc);
                if (!ctx.doc.modified()) self.proceed(ctx.pending);
            },
            else => {},
        }
    }

    fn proceed(self: *Editor, pending: Pending) void {
        switch (pending) {
            .open_file => {
                const dialog = gtk.FileDialog.new();
                defer dialog.as(gobject.Object).unref();
                if (self.cur.path) |p| if (std.fs.path.dirname(p)) |dir| {
                    var buf: [4096]u8 = undefined;
                    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{dir}, 0) catch "";
                    const folder = gio.File.newForPath(z);
                    defer folder.as(gobject.Object).unref();
                    dialog.setInitialFolder(folder);
                };
                dialog.openMultiple(self.window.as(gtk.Window), null, onOpenChosen, self);
            },
            .close_window => {
                for (self.docs.items) |doc| doc.buffer.setModified(0);
                self.window.as(gtk.Window).close();
            },
            .close_tab => {
                const doc = self.cur;
                self.rememberPlace(doc);
                if (self.docs.items.len == 1) {
                    // The last tab is emptied, not closed.
                    doc.setPath(null);
                    doc.stopWatching();
                    doc.setText("");
                    doc.disk = null;
                    doc.format = .{};
                    source.setLanguage(doc.buffer, null);
                    doc.showBanner(.none);
                    self.dropDraft(doc);
                    self.refreshTab(doc);
                    self.refresh();
                } else self.removeDoc(doc);
                self.scheduleAutosave();
            },
        }
    }

    fn onOpenChosen(source_obj: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Editor = @ptrCast(@alignCast(data.?));
        const dialog: *gtk.FileDialog = @ptrCast(@alignCast(source_obj.?));
        const files = dialog.openMultipleFinish(result, null) orelse return;
        defer files.as(gobject.Object).unref();
        var i: c_uint = 0;
        while (i < files.getNItems()) : (i += 1) {
            const obj: *gobject.Object = @ptrCast(@alignCast(files.getItem(i) orelse continue));
            defer obj.unref();
            self.openFile(@ptrCast(@alignCast(obj)), null);
        }
    }

    fn save(self: *Editor, doc: *Doc) void {
        const path = doc.path orelse return self.saveAsDialog(doc);
        // Changed by another program since it was read: ask first.
        if (doc.disk) |known| if (Doc.statDisk(path)) |now| if (now.mtime != known.mtime or now.size != known.size) {
            const ctx = std.heap.c_allocator.create(SaveCtx) catch return;
            ctx.* = .{ .editor = self, .doc = doc };
            common.dialogs.choose(self.window.as(gtk.Window), tr("The file was changed by another program"), tr("Saving replaces those changes with your text."), &.{ "Cancel", "Save Anyway" }, 0, SaveCtx, onOverwriteAnswer, ctx);
            return;
        };
        self.writeDoc(doc, path);
    }

    const SaveCtx = struct { editor: *Editor, doc: *Doc };

    fn onOverwriteAnswer(ctx: *SaveCtx, index: c_int) void {
        defer std.heap.c_allocator.destroy(ctx);
        if (index != 1) return;
        if (std.mem.indexOfScalar(*Doc, ctx.editor.docs.items, ctx.doc) == null) return;
        if (ctx.doc.path) |p| ctx.editor.writeDoc(ctx.doc, p);
    }

    fn saveAll(self: *Editor) void {
        var untitled = false;
        for (self.docs.items) |d| {
            if (!d.modified()) continue;
            if (d.path) |p| self.writeDoc(d, p) else untitled = true;
        }
        if (untitled) self.flash(tr("Untitled tabs need a name: save them one by one."));
    }

    fn saveAsDialog(self: *Editor, doc: *Doc) void {
        self.showDoc(doc);
        const dialog = gtk.FileDialog.new();
        defer dialog.as(gobject.Object).unref();
        if (doc.path) |p| {
            const file = gio.File.newForPath(p);
            defer file.as(gobject.Object).unref();
            dialog.setInitialFile(file);
        } else dialog.setInitialName("Untitled.txt");
        dialog.save(self.window.as(gtk.Window), null, onSaveChosen, self);
    }

    fn onSaveChosen(source_obj: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Editor = @ptrCast(@alignCast(data.?));
        const dialog: *gtk.FileDialog = @ptrCast(@alignCast(source_obj.?));
        const file = dialog.saveFinish(result, null) orelse {
            self.after_save = null;
            return;
        };
        defer file.as(gobject.Object).unref();
        const path = file.getPath() orelse return;
        defer glib.free(path);
        const doc = self.cur;
        doc.setPath(std.mem.span(path));
        doc.disk = null;
        doc.guessLanguage("");
        self.writeDoc(doc, doc.path.?);
        doc.watch();
        self.noteRecent(doc.path.?);
        if (self.after_save) |a| {
            self.after_save = null;
            if (a.doc == doc and !doc.modified()) self.proceed(a.pending);
        }
    }

    /// Encodes the text in the document's format and writes it to `path`
    /// (a link's target), keeping the file's permissions.
    fn writeDoc(self: *Editor, doc: *Doc, path: [:0]const u8) void {
        const win = self.window.as(gtk.Window);
        const text = doc.text(self.allocator) catch return;
        defer self.allocator.free(text);
        const bytes = textfile.encode(self.allocator, text, doc.format) catch |e| switch (e) {
            error.Unrepresentable => {
                const ctx = std.heap.c_allocator.create(SaveCtx) catch return;
                ctx.* = .{ .editor = self, .doc = doc };
                var buf: [300]u8 = undefined;
                const msg = std.fmt.bufPrintSentinel(&buf, "Some characters cannot be stored in {s}. Save the file as UTF-8 instead?", .{doc.format.encoding.label()}, 0) catch "";
                common.dialogs.choose(win, tr("Cannot save in this encoding"), msg, &.{ "Cancel", "Save as UTF-8" }, 0, SaveCtx, onUtf8Answer, ctx);
                return;
            },
            else => return,
        };
        defer self.allocator.free(bytes);
        var real_buf: [4096]u8 = undefined;
        const target = Doc.saveTarget(path, &real_buf);
        // A read-only file is not replaced behind its owner's back, even
        // where the folder would allow it.
        if (std.c.access(target.ptr, std.c.F_OK) == 0 and std.c.access(target.ptr, std.c.W_OK) != 0) return self.offerAdminSave(doc, target, bytes);
        common.fsio.writeFileAtomic(target, bytes) catch |e| switch (e) {
            error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => return self.offerAdminSave(doc, target, bytes),
            else => {
                var buf: [200]u8 = undefined;
                common.dialogs.showError(win, tr("Cannot save the file"), std.fmt.bufPrintSentinel(&buf, "{s}", .{@errorName(e)}, 0) catch "");
                return;
            },
        };
        self.saved(doc, target);
    }

    fn saved(self: *Editor, doc: *Doc, target: []const u8) void {
        doc.buffer.setModified(0);
        doc.disk = Doc.statDisk(target);
        doc.refreshWritable();
        doc.showBanner(.none);
        self.dropDraft(doc);
        self.refreshTab(doc);
        self.refresh();
        self.flash(tr("Saved."));
        self.scheduleAutosave();
    }

    fn onUtf8Answer(ctx: *SaveCtx, index: c_int) void {
        defer std.heap.c_allocator.destroy(ctx);
        if (index != 1) return;
        const self = ctx.editor;
        if (std.mem.indexOfScalar(*Doc, self.docs.items, ctx.doc) == null) return;
        ctx.doc.format.encoding = .utf8;
        ctx.doc.format.bom = false;
        if (ctx.doc.path) |p| self.writeDoc(ctx.doc, p);
    }

    const AdminCtx = struct { editor: *Editor, doc: *Doc, target: [:0]u8, bytes: []u8 };

    /// The file is not ours to write: offer to save it as administrator
    /// (the way Kate does), through dkde's password dialog and sudo.
    fn offerAdminSave(self: *Editor, doc: *Doc, target: []const u8, bytes: []const u8) void {
        const a = std.heap.c_allocator;
        const ctx = a.create(AdminCtx) catch return;
        ctx.* = .{ .editor = self, .doc = doc, .target = a.dupeSentinel(u8, target, 0) catch return, .bytes = a.dupe(u8, bytes) catch return };
        var buf: [300]u8 = undefined;
        const msg = std.fmt.bufPrintSentinel(&buf, "You do not have permission to change \u{201c}{s}\u{201d}.", .{std.fs.path.basename(target)}, 0) catch "";
        common.dialogs.choose(self.window.as(gtk.Window), tr("Cannot save the file"), msg, &.{ "Cancel", "Save As…", "Save as Administrator" }, 0, AdminCtx, onAdminAnswer, ctx);
    }

    fn freeAdmin(ctx: *AdminCtx) void {
        const a = std.heap.c_allocator;
        a.free(ctx.target);
        @memset(ctx.bytes, 0);
        a.free(ctx.bytes);
        a.destroy(ctx);
    }

    fn onAdminAnswer(ctx: *AdminCtx, index: c_int) void {
        const self = ctx.editor;
        if (std.mem.indexOfScalar(*Doc, self.docs.items, ctx.doc) == null or index == 0) return freeAdmin(ctx);
        if (index == 1) {
            self.saveAsDialog(ctx.doc);
            return freeAdmin(ctx);
        }
        // `cat > file` keeps the file's owner and permissions.
        var reason: [300]u8 = undefined;
        const why = std.fmt.bufPrint(&reason, "Save {s}", .{ctx.target}) catch "Save a file";
        common.elevate.run(self.window.as(gtk.Window), why, &.{ "sh", "-c", "cat > \"$1\"", "sh", ctx.target }, ctx.bytes, AdminCtx, onAdminDone, ctx);
    }

    fn onAdminDone(ctx: *AdminCtx, outcome: common.elevate.Outcome, message: []const u8) void {
        defer freeAdmin(ctx);
        const self = ctx.editor;
        if (std.mem.indexOfScalar(*Doc, self.docs.items, ctx.doc) == null) return;
        switch (outcome) {
            .ok => self.saved(ctx.doc, ctx.target),
            .cancelled => {},
            .failed => {
                var buf: [300]u8 = undefined;
                common.dialogs.showError(self.window.as(gtk.Window), tr("Cannot save the file"), std.fmt.bufPrintSentinel(&buf, "{s}", .{message[0..@min(message.len, 280)]}, 0) catch "");
            },
        }
    }

    fn anyModified(self: *const Editor) bool {
        for (self.docs.items) |doc| if (doc.modified()) return true;
        return false;
    }

    fn onCloseRequest(_: *gtk.Window, self: *Editor) callconv(.c) c_int {
        if (!self.anyModified()) {
            self.finish();
            return 0;
        }
        const ctx = std.heap.c_allocator.create(DiscardCtx) catch return 0;
        ctx.* = .{ .editor = self, .doc = self.cur, .pending = .close_window };
        common.dialogs.choose(self.window.as(gtk.Window), tr("Save your changes?"), tr("Some tabs have changes that are not saved."), &.{ "Cancel", "Discard", "Save All" }, 0, DiscardCtx, onCloseAnswer, ctx);
        return 1;
    }

    fn onCloseAnswer(ctx: *DiscardCtx, index: c_int) void {
        defer std.heap.c_allocator.destroy(ctx);
        const self = ctx.editor;
        switch (index) {
            1 => self.proceed(.close_window),
            2 => {
                self.saveAll();
                if (!self.anyModified()) self.window.as(gtk.Window).close();
            },
            else => {},
        }
    }

    /// The window is going: remember places and size, write the last session.
    fn finish(self: *Editor) void {
        if (self.finished) return;
        self.finished = true;
        for (self.docs.items) |d| self.rememberPlace(d);
        const w = self.window.as(gtk.Widget);
        if (self.window.as(gtk.Window).isMaximized() == 0 and w.getWidth() > 0) {
            self.config.setInt("edit", "width", w.getWidth()) catch {};
            self.config.setInt("edit", "height", w.getHeight()) catch {};
        }
        self.writeSession(true);
    }

    // ---- what is remembered ---------------------------------------------------------

    fn stateFile(self: *Editor, name: []const u8) ?[:0]u8 {
        return common.paths.userStateFile(self.allocator, name) catch null;
    }

    fn rememberedPlace(self: *Editor, path: []const u8) ?memory.Place {
        const file = self.stateFile("edit-places") orelse return null;
        defer self.allocator.free(file);
        const text = (common.fsio.readFile(self.allocator, file, 1 << 20) catch null) orelse return null;
        defer self.allocator.free(text);
        return memory.findPlace(text, path);
    }

    fn rememberPlace(self: *Editor, doc: *Doc) void {
        const path = doc.path orelse return;
        const file = self.stateFile("edit-places") orelse return;
        defer self.allocator.free(file);
        const old = (common.fsio.readFile(self.allocator, file, 1 << 20) catch null) orelse self.allocator.dupe(u8, "") catch return;
        defer self.allocator.free(old);
        const new = memory.putPlace(self.allocator, old, path, cursorPlace(doc)) catch return;
        defer self.allocator.free(new);
        if (std.fs.path.dirname(file)) |dir| common.fsio.makePath(dir) catch {};
        common.fsio.writeFileAtomic(file, new) catch {};
    }

    fn draftPath(self: *Editor, id: []const u8) ?[:0]u8 {
        var buf: [96]u8 = undefined;
        const rel = std.fmt.bufPrint(&buf, "edit-drafts/{s}", .{id}) catch return null;
        return self.stateFile(rel);
    }

    fn dropDraft(self: *Editor, doc: *Doc) void {
        const id = doc.draft orelse return;
        if (self.draftPath(id)) |p| {
            defer self.allocator.free(p);
            std.Io.Dir.cwd().deleteFile(common.fsio.io(), p) catch {};
        }
        self.allocator.free(id);
        doc.draft = null;
    }

    fn scheduleAutosave(self: *Editor) void {
        if (self.finished or self.autosave_source != 0) return;
        self.autosave_source = glib.timeoutAdd(1500, onAutosave, self);
    }

    fn onAutosave(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Editor = @ptrCast(@alignCast(data.?));
        self.autosave_source = 0;
        self.writeSession(false);
        return 0;
    }

    /// Keeps unsaved text in drafts and writes the list of tabs. At the end
    /// (`last`) no drafts are kept: by then every change was saved or dropped.
    fn writeSession(self: *Editor, last: bool) void {
        const gpa = self.allocator;
        var tabs: std.ArrayList(memory.Tab) = .empty;
        defer tabs.deinit(gpa);
        for (self.docs.items) |d| {
            if (!last and d.modified()) {
                if (d.draft == null) {
                    self.draft_counter += 1;
                    d.draft = std.fmt.allocPrint(gpa, "d-{d}-{d}", .{ std.c.getpid(), @as(u64, @intCast(glib.getRealTime())) + self.draft_counter }) catch null;
                }
                if (d.draft) |id| if (self.draftPath(id)) |p| {
                    defer gpa.free(p);
                    if (std.fs.path.dirname(p)) |dir| common.fsio.makePath(dir) catch {};
                    const text = d.text(gpa) catch continue;
                    defer gpa.free(text);
                    common.fsio.writeFileAtomic(p, text) catch {};
                    // Drafts are private, like the files they come from may be.
                    std.Io.Dir.cwd().setFilePermissions(common.fsio.io(), p, .fromMode(0o600), .{}) catch {};
                };
            } else if (d.draft != null) self.dropDraft(d);
            const keep_file = self.restore_session or (!last and d.draft != null);
            if (d.draft == null and (!keep_file or d.path == null)) continue;
            tabs.append(gpa, .{ .path = d.path orelse "", .draft = d.draft orelse "", .place = cursorPlace(d) }) catch {};
        }
        const active = std.mem.indexOfScalar(*Doc, self.docs.items, self.cur) orelse 0;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        memory.writeSession(&out.writer, .{ .tabs = tabs.items, .active = @min(active, tabs.items.len -| 1) }) catch return;
        const file = self.stateFile("edit-session") orelse return;
        defer gpa.free(file);
        if (std.fs.path.dirname(file)) |dir| common.fsio.makePath(dir) catch {};
        common.fsio.writeFileAtomic(file, out.written()) catch {};
    }

    /// Opens the tabs of the last session: unsaved text always comes back
    /// (after a crash), files only when no file was named on the command
    /// line and Restore Tabs is on.
    pub fn restoreSession(self: *Editor, files_given: bool) void {
        const gpa = self.allocator;
        const file = self.stateFile("edit-session") orelse return;
        defer gpa.free(file);
        const text = (common.fsio.readFile(gpa, file, 1 << 20) catch null) orelse return;
        defer gpa.free(text);
        var session = memory.parseSession(gpa, text) catch return;
        defer session.deinit(gpa);
        var active: ?*Doc = null;
        for (session.tabs, 0..) |t, i| {
            var doc: ?*Doc = null;
            if (t.draft.len > 0) {
                const p = self.draftPath(t.draft) orelse continue;
                defer gpa.free(p);
                const draft = (common.fsio.readFile(gpa, p, 512 << 20) catch null) orelse continue;
                defer gpa.free(draft);
                if (!std.unicode.utf8ValidateSlice(draft)) continue;
                // The file's own format and state, then the unsaved text.
                doc = if (t.path.len > 0) self.loadInto(null, t.path, null) else null;
                if (doc == null) doc = self.blankOrNew();
                const d = doc orelse continue;
                d.setText(draft);
                d.buffer.setModified(1);
                d.draft = gpa.dupe(u8, t.draft) catch null;
                self.refreshTab(d);
            } else {
                if (files_given or !self.restore_session) continue;
                if (!common.fsio.exists(t.path)) continue;
                var z_buf: [4096]u8 = undefined;
                const z = std.fmt.bufPrintSentinel(&z_buf, "{s}", .{t.path}, 0) catch continue;
                const f = gio.File.newForPath(z);
                defer f.as(gobject.Object).unref();
                self.openFile(f, t.place);
                doc = self.cur;
            }
            if (doc) |d| {
                self.placeCursor(d, t.place);
                if (i == session.active) active = d;
            }
        }
        if (active) |d| self.showDoc(d);
    }

    // ---- recent files ----------------------------------------------------------------

    fn loadRecent(self: *Editor) void {
        for (self.recent.items) |p| self.allocator.free(p);
        self.recent.clearRetainingCapacity();
        const Found = struct { path: [:0]u8, when: i64 };
        var found: std.ArrayList(Found) = .empty;
        defer found.deinit(self.allocator);
        var moved: usize = 0;
        defer for (found.items[moved..]) |f| self.allocator.free(f.path);
        const app_name = glib.getPrgname() orelse "dkde-edit";
        var node: ?*glib.List = gtk.RecentManager.getDefault().getItems();
        const head = node;
        while (node) |n| : (node = n.f_next) {
            const info: *gtk.RecentInfo = @ptrCast(@alignCast(n.f_data orelse continue));
            defer info.unref();
            if (info.hasApplication(app_name) == 0) continue;
            const file = gio.File.newForUri(info.getUri());
            defer file.as(gobject.Object).unref();
            const path = file.getPath() orelse continue;
            defer glib.free(path);
            if (!common.fsio.exists(std.mem.span(path))) continue;
            const owned = self.allocator.dupeSentinel(u8, std.mem.span(path), 0) catch continue;
            found.append(self.allocator, .{ .path = owned, .when = info.getModified().toUnix() }) catch self.allocator.free(owned);
        }
        if (head) |h| h.free();
        std.mem.sort(Found, found.items, {}, struct {
            fn newer(_: void, a: Found, b: Found) bool {
                return a.when > b.when;
            }
        }.newer);
        for (found.items) |f| {
            if (moved >= recent_shown) break;
            self.recent.append(self.allocator, f.path) catch break;
            moved += 1;
        }
        if (common.menubar.submenu(self.window, "recent")) |menu| {
            menu.removeAll();
            for (self.recent.items) |path| appendValueItem(menu, @ptrCast(std.fs.path.basename(path)), "win.open-recent", path);
        }
    }

    fn noteRecent(_: *Editor, path: []const u8) void {
        var buf: [4096]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{path}, 0) catch return;
        const file = gio.File.newForPath(z);
        defer file.as(gobject.Object).unref();
        const uri = file.getUri();
        defer glib.free(uri);
        _ = gtk.RecentManager.getDefault().addItem(uri);
    }

    fn onRecentChanged(_: *gtk.RecentManager, self: *Editor) callconv(.c) void {
        self.loadRecent();
    }

    fn onOpenRecent(_: *gio.SimpleAction, param: ?*glib.Variant, self: *Editor) callconv(.c) void {
        const v = param orelse return;
        var len: usize = 0;
        const path = v.getString(&len);
        const file = gio.File.newForPath(path);
        defer file.as(gobject.Object).unref();
        self.openFile(file, null);
    }

    fn onSetScheme(_: *gio.SimpleAction, param: ?*glib.Variant, self: *Editor) callconv(.c) void {
        const v = param orelse return;
        var len: usize = 0;
        const id = std.mem.span(v.getString(&len));
        self.setSchemeName(id);
        self.config.setString("edit", "color-scheme", @ptrCast(self.schemeName())) catch {};
        var buf: [80]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{id}, 0) catch return;
        self.config.setString("edit", "color-scheme", z) catch {};
        for (self.docs.items) |d| source.setScheme(d.buffer, id, isDark());
    }

    fn onSetTabWidth(_: *gio.SimpleAction, param: ?*glib.Variant, self: *Editor) callconv(.c) void {
        const v = param orelse return;
        var len: usize = 0;
        const w = std.fmt.parseInt(u32, std.mem.span(v.getString(&len)), 10) catch return;
        self.setTabWidth(w);
    }

    fn setTabWidth(self: *Editor, w: u32) void {
        self.opts.tab_width = std.math.clamp(w, 1, 16);
        self.config.setInt("edit", "tab-width", @intCast(self.opts.tab_width)) catch {};
        self.refreshViews();
    }

    fn onDropFiles(_: *gtk.DropTarget, value: *gobject.Value, _: f64, _: f64, self: *Editor) callconv(.c) c_int {
        const boxed = value.getBoxed() orelse return 0;
        const list: *gdk.FileList = @ptrCast(@alignCast(boxed));
        var opened = false;
        var node: ?*glib.SList = list.getFiles();
        const head = node;
        while (node) |n| : (node = n.f_next) {
            const f: *gio.File = @ptrCast(@alignCast(n.f_data orelse continue));
            self.openFile(f, null);
            opened = true;
        }
        if (head) |h| h.free();
        return @intFromBool(opened);
    }

    // ---- find and replace ------------------------------------------------------------

    fn buildFindBar(self: *Editor) void {
        const find_row = gtk.Box.new(.horizontal, 6);
        self.find_entry.setPlaceholderText(tr("Find"));
        self.find_entry.as(gtk.Widget).setSizeRequest(260, -1);
        const prev = gtk.Button.newFromIconName("go-up-symbolic");
        prev.as(gtk.Widget).setTooltipText(tr("Previous match (Shift+F3)"));
        const next = gtk.Button.newFromIconName("go-down-symbolic");
        next.as(gtk.Widget).setTooltipText(tr("Next match (F3)"));
        self.match_label.as(gtk.Widget).addCssClass("dim-label");
        self.match_label.setWidthChars(14);
        find_row.append(self.find_entry.as(gtk.Widget));
        find_row.append(prev.as(gtk.Widget));
        find_row.append(next.as(gtk.Widget));
        find_row.append(self.match_label.as(gtk.Widget));
        find_row.append(self.case_check.as(gtk.Widget));
        find_row.append(self.word_check.as(gtk.Widget));
        find_row.append(self.regex_check.as(gtk.Widget));

        self.replace_entry.setPlaceholderText(tr("Replace with"));
        self.replace_entry.as(gtk.Widget).setSizeRequest(260, -1);
        const replace = gtk.Button.newWithLabel(tr("Replace"));
        const replace_all = gtk.Button.newWithLabel(tr("Replace All"));
        self.replace_row.append(self.replace_entry.as(gtk.Widget));
        self.replace_row.append(replace.as(gtk.Widget));
        self.replace_row.append(replace_all.as(gtk.Widget));

        const rows = gtk.Box.new(.vertical, 4);
        rows.append(find_row.as(gtk.Widget));
        rows.append(self.replace_row.as(gtk.Widget));
        // The bar scrolls sideways when the window is narrow: its entries must not set the window's
        // least width (a window wider than half the screen cannot be snapped to a half).
        const bar_scroll = gtk.ScrolledWindow.new();
        bar_scroll.setPolicy(.automatic, .never);
        bar_scroll.setPropagateNaturalHeight(1);
        bar_scroll.setChild(rows.as(gtk.Widget));
        self.search_bar.setChild(bar_scroll.as(gtk.Widget));
        self.search_bar.connectEntry(self.find_entry.as(gtk.Editable));
        self.search_bar.setShowCloseButton(1);
        _ = gtk.SearchEntry.signals.search_changed.connect(self.find_entry, *Editor, &onFindChanged, self, .{});
        _ = gtk.SearchEntry.signals.activate.connect(self.find_entry, *Editor, &onFindActivate, self, .{});
        _ = gtk.SearchEntry.signals.next_match.connect(self.find_entry, *Editor, &onFindActivate, self, .{});
        _ = gtk.SearchEntry.signals.previous_match.connect(self.find_entry, *Editor, &onFindPrevSignal, self, .{});
        _ = gtk.SearchEntry.signals.stop_search.connect(self.find_entry, *Editor, &onStopSearch, self, .{});
        _ = gtk.Button.signals.clicked.connect(next, *Editor, &onNextClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(prev, *Editor, &onPrevClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(replace, *Editor, &onReplaceClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(replace_all, *Editor, &onReplaceAllClicked, self, .{});
        _ = gtk.Entry.signals.activate.connect(self.replace_entry, *Editor, &onReplaceActivate, self, .{});
        inline for (.{ self.case_check, self.word_check, self.regex_check }) |c|
            _ = gtk.CheckButton.signals.toggled.connect(c, *Editor, &onFindOption, self, .{});
        _ = gobject.Object.signals.notify.connect(self.search_bar, *Editor, &onSearchMode, self, .{ .detail = "search-mode-enabled" });
    }

    fn openFind(self: *Editor, with_replace: bool) void {
        self.replace_row.as(gtk.Widget).setVisible(@intFromBool(with_replace));
        // The selection (one line of it) is what to look for.
        var start: gtk.TextIter = undefined;
        var end: gtk.TextIter = undefined;
        if (self.cur.buffer.getSelectionBounds(&start, &end) != 0 and start.getLine() == end.getLine()) {
            const t = self.cur.buffer.getText(&start, &end, 0);
            defer glib.free(t);
            self.find_entry.as(gtk.Editable).setText(t);
        }
        self.search_bar.setSearchMode(1);
        _ = self.find_entry.as(gtk.Widget).grabFocus();
        self.find_entry.as(gtk.Editable).selectRegion(0, -1);
        self.refind(true);
    }

    fn options(self: *Editor) search.Options {
        return .{
            .case_sensitive = self.case_check.getActive() != 0,
            .whole_word = self.word_check.getActive() != 0,
            .regex = self.regex_check.getActive() != 0,
        };
    }

    /// Finds every match again; `jump` moves to the first one from the cursor.
    fn refind(self: *Editor, jump: bool) void {
        if (self.regex) |r| r.unref();
        self.regex = null;
        self.matches.clearRetainingCapacity();
        self.find_entry.as(gtk.Widget).removeCssClass("error");
        const needle = std.mem.span(self.find_entry.as(gtk.Editable).getText());
        var why: [200]u8 = undefined;
        var why_len: usize = 0;
        self.regex = search.compile(needle, self.options(), &why, &why_len) catch {
            self.find_entry.as(gtk.Widget).addCssClass("error");
            var buf: [220]u8 = undefined;
            self.match_label.setText(std.fmt.bufPrintSentinel(&buf, "{s}", .{why[0..why_len]}, 0) catch "");
            search.highlight(self.cur.buffer, &.{});
            return;
        };
        if (self.regex) |re| search.findAll(self.allocator, self.cur.buffer, re, &self.matches) catch {};
        search.highlight(self.cur.buffer, self.matches.items);
        if (jump and self.matches.items.len > 0) {
            var it: gtk.TextIter = undefined;
            var sel_end: gtk.TextIter = undefined;
            _ = self.cur.buffer.getSelectionBounds(&it, &sel_end);
            if (search.pick(self.matches.items, @intCast(it.getOffset()), true)) |i| self.selectMatch(i);
        }
        self.updateMatchLabel();
    }

    fn currentMatch(self: *Editor) ?usize {
        var a: gtk.TextIter = undefined;
        var b: gtk.TextIter = undefined;
        if (self.cur.buffer.getSelectionBounds(&a, &b) == 0) return null;
        const s: u32 = @intCast(a.getOffset());
        const e: u32 = @intCast(b.getOffset());
        for (self.matches.items, 0..) |m, i| if (m.start == s and m.end == e) return i;
        return null;
    }

    fn updateMatchLabel(self: *Editor) void {
        var buf: [64]u8 = undefined;
        const n = self.matches.items.len;
        const needle = std.mem.span(self.find_entry.as(gtk.Editable).getText());
        if (needle.len == 0) return self.match_label.setText("");
        if (n == 0) return self.match_label.setText(tr("No results"));
        const more: []const u8 = if (n >= search.max_matches) "+" else "";
        const text = if (self.currentMatch()) |i|
            std.fmt.bufPrintSentinel(&buf, "{d} of {d}{s}", .{ i + 1, n, more }, 0) catch ""
        else
            std.fmt.bufPrintSentinel(&buf, "{d}{s} found", .{ n, more }, 0) catch "";
        self.match_label.setText(text);
    }

    fn selectMatch(self: *Editor, i: usize) void {
        const m = self.matches.items[i];
        var a: gtk.TextIter = undefined;
        var b: gtk.TextIter = undefined;
        self.cur.buffer.getIterAtOffset(&a, @intCast(m.start));
        self.cur.buffer.getIterAtOffset(&b, @intCast(m.end));
        self.cur.buffer.selectRange(&a, &b);
        self.cur.focused.scrollToMark(self.cur.buffer.getInsert(), 0.15, 0, 0, 0);
        self.updateMatchLabel();
    }

    fn step(self: *Editor, forward: bool) void {
        if ((self.search_bar.getSearchMode() == 0)) {
            if (std.mem.span(self.find_entry.as(gtk.Editable).getText()).len == 0) return self.openFind(false);
            self.refind(false);
        }
        if (self.matches.items.len == 0) return;
        var a: gtk.TextIter = undefined;
        var b: gtk.TextIter = undefined;
        if (self.cur.buffer.getSelectionBounds(&a, &b) == 0) self.cur.buffer.getIterAtMark(&a, self.cur.buffer.getInsert());
        if (self.cur.buffer.getSelectionBounds(&a, &b) == 0) b = a;
        const from: u32 = @intCast(if (forward) b.getOffset() else a.getOffset());
        if (search.pick(self.matches.items, from, forward)) |i| self.selectMatch(i);
    }

    fn replaceCurrent(self: *Editor) void {
        const re = self.regex orelse return;
        const i = self.currentMatch() orelse return self.step(true);
        const m = self.matches.items[i];
        var a: gtk.TextIter = undefined;
        var b: gtk.TextIter = undefined;
        self.cur.buffer.getIterAtOffset(&a, @intCast(m.start));
        self.cur.buffer.getIterAtOffset(&b, @intCast(m.end));
        const old = self.cur.buffer.getText(&a, &b, 1);
        defer glib.free(old);
        const repl = std.mem.span(self.replace_entry.as(gtk.Editable).getText());
        const new = search.replacementFor(self.allocator, re, std.mem.span(old), repl, self.options()) catch return;
        defer self.allocator.free(new);
        self.cur.buffer.beginUserAction();
        self.cur.buffer.delete(&a, &b);
        self.cur.buffer.insert(&a, @ptrCast(new.ptr), @intCast(new.len));
        self.cur.buffer.endUserAction();
        self.cur.buffer.placeCursor(&a);
        self.refind(false);
        self.step(true);
    }

    fn replaceAll(self: *Editor) void {
        const re = self.regex orelse return;
        const repl = std.mem.span(self.replace_entry.as(gtk.Editable).getText());
        const n = search.replaceAll(self.allocator, self.cur.buffer, re, repl, self.options()) catch return;
        self.refind(false);
        var buf: [64]u8 = undefined;
        self.flash(std.fmt.bufPrintSentinel(&buf, "{d} replaced", .{n}, 0) catch "");
    }

    fn scheduleRefind(self: *Editor) void {
        if ((self.search_bar.getSearchMode() == 0) or self.refind_source != 0) return;
        self.refind_source = glib.timeoutAdd(200, onRefindTimer, self);
    }

    fn onRefindTimer(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Editor = @ptrCast(@alignCast(data.?));
        self.refind_source = 0;
        self.refind(false);
        return 0;
    }

    fn onFindChanged(_: *gtk.SearchEntry, self: *Editor) callconv(.c) void {
        self.refind(true);
    }

    fn onFindOption(_: *gtk.CheckButton, self: *Editor) callconv(.c) void {
        self.refind(true);
    }

    fn onFindActivate(_: *gtk.SearchEntry, self: *Editor) callconv(.c) void {
        self.step(true);
    }

    fn onFindPrevSignal(_: *gtk.SearchEntry, self: *Editor) callconv(.c) void {
        self.step(false);
    }

    fn onStopSearch(_: *gtk.SearchEntry, self: *Editor) callconv(.c) void {
        self.search_bar.setSearchMode(0);
    }

    fn onSearchMode(_: *gtk.SearchBar, _: *gobject.ParamSpec, self: *Editor) callconv(.c) void {
        if (self.search_bar.getSearchMode() != 0) return;
        // Closed: the highlights go, the text gets the keys again.
        search.highlight(self.cur.buffer, &.{});
        _ = self.cur.focused.as(gtk.Widget).grabFocus();
    }

    fn onNextClicked(_: *gtk.Button, self: *Editor) callconv(.c) void {
        self.step(true);
    }

    fn onPrevClicked(_: *gtk.Button, self: *Editor) callconv(.c) void {
        self.step(false);
    }

    fn onReplaceClicked(_: *gtk.Button, self: *Editor) callconv(.c) void {
        self.replaceCurrent();
    }

    fn onReplaceActivate(_: *gtk.Entry, self: *Editor) callconv(.c) void {
        self.replaceCurrent();
    }

    fn onReplaceAllClicked(_: *gtk.Button, self: *Editor) callconv(.c) void {
        self.replaceAll();
    }

    // ---- status bar ------------------------------------------------------------------

    fn statusButton(button: *gtk.MenuButton, tip: [:0]const u8, content: *gtk.Widget) void {
        button.setHasFrame(0);
        button.as(gtk.Widget).setTooltipText(tip);
        button.as(gtk.Widget).addCssClass("dkde-edit-status-button");
        const pop = gtk.Popover.new();
        pop.setChild(content);
        button.setPopover(pop);
    }

    fn buildStatusBar(self: *Editor) *gtk.Box {
        const bar = gtk.Box.new(.horizontal, 2);
        bar.as(gtk.Widget).addCssClass("dkde-edit-status");
        bar.as(gtk.Widget).setMarginStart(6);
        bar.as(gtk.Widget).setMarginEnd(6);
        const spacer = gtk.Box.new(.horizontal, 0);
        spacer.as(gtk.Widget).setHexpand(1);

        // Line and column; the popover goes to a line.
        const goto_box = gtk.Box.new(.vertical, 6);
        const goto_label = gtk.Label.new(tr("Go to line (line:column)"));
        goto_label.setXalign(0);
        goto_box.append(goto_label.as(gtk.Widget));
        goto_box.append(self.goto_entry.as(gtk.Widget));
        _ = gtk.Entry.signals.activate.connect(self.goto_entry, *Editor, &onGoto, self, .{});
        statusButton(self.pos_button, tr("Go to a line (Ctrl+I)"), goto_box.as(gtk.Widget));
        _ = gtk.Widget.signals.show.connect(self.pos_button.getPopover().?, *Editor, &onGotoShown, self, .{});

        // Language.
        const lang_box = gtk.Box.new(.vertical, 6);
        lang_box.append(self.lang_search.as(gtk.Widget));
        const lang_scroll = gtk.ScrolledWindow.new();
        lang_scroll.setChild(self.lang_list.as(gtk.Widget));
        lang_scroll.setPolicy(.never, .automatic);
        lang_scroll.setMinContentHeight(320);
        lang_scroll.setMinContentWidth(220);
        lang_box.append(lang_scroll.as(gtk.Widget));
        self.fillLanguages();
        _ = gtk.SearchEntry.signals.search_changed.connect(self.lang_search, *Editor, &onLangSearch, self, .{});
        _ = gtk.ListBox.signals.row_activated.connect(self.lang_list, *Editor, &onLangRow, self, .{});
        self.lang_list.setFilterFunc(&langFilter, self, null);
        statusButton(self.lang_button, tr("Syntax highlighting language"), lang_box.as(gtk.Widget));

        // Indentation.
        const ind_box = gtk.Box.new(.vertical, 4);
        ind_box.append(self.spaces_check.as(gtk.Widget));
        _ = gtk.CheckButton.signals.toggled.connect(self.spaces_check, *Editor, &onSpacesToggled, self, .{});
        const widths = [_]u32{ 2, 3, 4, 8 };
        for (widths, 0..) |w, i| {
            var buf: [32]u8 = undefined;
            const b = gtk.CheckButton.newWithLabel(std.fmt.bufPrintSentinel(&buf, "Width {d}", .{w}, 0) catch "");
            if (i > 0) b.setGroup(self.width_buttons[0]);
            self.width_buttons[i] = b;
            _ = gtk.CheckButton.signals.toggled.connect(b, *Editor, &onWidthToggled, self, .{});
            ind_box.append(b.as(gtk.Widget));
        }
        statusButton(self.indent_button, tr("Indentation"), ind_box.as(gtk.Widget));

        // Line ends.
        const eol_box = gtk.Box.new(.vertical, 2);
        inline for (.{ textfile.Newline.lf, textfile.Newline.crlf, textfile.Newline.cr }) |nl| {
            const b = gtk.Button.newWithLabel(nl.label());
            b.setHasFrame(0);
            _ = gtk.Button.signals.clicked.connect(b, *Editor, &struct {
                fn pick(_: *gtk.Button, ed: *Editor) callconv(.c) void {
                    ed.setNewline(nl);
                }
            }.pick, self, .{});
            eol_box.append(b.as(gtk.Widget));
        }
        statusButton(self.eol_button, tr("Line endings"), eol_box.as(gtk.Widget));

        // Encoding.
        const enc_box = gtk.Box.new(.vertical, 2);
        const enc_hint = gtk.Label.new(tr("An unchanged file is read again in the encoding you pick; otherwise it is saved in it."));
        enc_hint.setWrap(1);
        enc_hint.setMaxWidthChars(30);
        enc_hint.setXalign(0);
        enc_hint.as(gtk.Widget).addCssClass("dim-label");
        enc_box.append(enc_hint.as(gtk.Widget));
        inline for (.{ textfile.Encoding.utf8, textfile.Encoding.utf16le, textfile.Encoding.utf16be, textfile.Encoding.windows1252, textfile.Encoding.latin1 }) |enc| {
            const b = gtk.Button.newWithLabel(enc.label());
            b.setHasFrame(0);
            _ = gtk.Button.signals.clicked.connect(b, *Editor, &struct {
                fn pick(_: *gtk.Button, ed: *Editor) callconv(.c) void {
                    ed.setEncoding(enc);
                }
            }.pick, self, .{});
            enc_box.append(b.as(gtk.Widget));
        }
        statusButton(self.enc_button, tr("Character encoding"), enc_box.as(gtk.Widget));

        self.mode_label.as(gtk.Widget).setTooltipText(tr("Insert or overwrite (the Insert key)"));
        self.mode_label.as(gtk.Widget).setMarginStart(6);
        self.mode_label.as(gtk.Widget).setMarginEnd(6);
        self.mode_label.as(gtk.Widget).addCssClass("dim-label");
        bar.append(spacer.as(gtk.Widget));
        bar.append(self.pos_button.as(gtk.Widget));
        bar.append(self.mode_label.as(gtk.Widget));
        if (source.available()) {
            bar.append(self.lang_button.as(gtk.Widget));
            bar.append(self.indent_button.as(gtk.Widget));
        }
        bar.append(self.eol_button.as(gtk.Widget));
        bar.append(self.enc_button.as(gtk.Widget));
        return bar;
    }

    fn fillLanguages(self: *Editor) void {
        const Lang = struct { id: [:0]const u8, name: [:0]const u8 };
        var all: std.ArrayList(Lang) = .empty;
        defer all.deinit(self.allocator);
        for (source.languageIds()) |id_opt| {
            const id = std.mem.span(id_opt orelse continue);
            const lang = source.languageById(id) orelse continue;
            all.append(self.allocator, .{ .id = id, .name = source.languageName(lang) }) catch return;
        }
        std.mem.sort(Lang, all.items, {}, struct {
            fn less(_: void, a: Lang, b: Lang) bool {
                return std.ascii.lessThanIgnoreCase(a.name, b.name);
            }
        }.less);
        self.lang_ids.append(self.allocator, "") catch return;
        self.lang_list.append(gtk.Label.new(tr("Plain Text")).as(gtk.Widget));
        for (all.items) |l| {
            self.lang_ids.append(self.allocator, l.id) catch return;
            const label = gtk.Label.new(l.name);
            label.setXalign(0);
            self.lang_list.append(label.as(gtk.Widget));
        }
    }

    fn langFilter(row: *gtk.ListBoxRow, data: ?*anyopaque) callconv(.c) c_int {
        const self: *Editor = @ptrCast(@alignCast(data.?));
        const needle = std.mem.span(self.lang_search.as(gtk.Editable).getText());
        if (needle.len == 0) return 1;
        const label: *gtk.Label = @ptrCast(@alignCast(row.getChild() orelse return 1));
        const text = std.mem.span(label.getText());
        return @intFromBool(std.ascii.findIgnoreCase(text, needle) != null);
    }

    fn onLangSearch(_: *gtk.SearchEntry, self: *Editor) callconv(.c) void {
        self.lang_list.invalidateFilter();
    }

    fn onLangRow(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Editor) callconv(.c) void {
        const i: usize = @intCast(@max(0, row.getIndex()));
        if (i >= self.lang_ids.items.len) return;
        const id = self.lang_ids.items[i];
        source.setLanguage(self.cur.buffer, if (id.len == 0) null else source.languageById(id));
        self.lang_button.popdown();
        self.syncStatus();
    }

    fn onSpacesToggled(b: *gtk.CheckButton, self: *Editor) callconv(.c) void {
        if (self.syncing_status) return;
        self.opts.spaces = b.getActive() != 0;
        self.saveBool("insert-spaces", self.opts.spaces);
        common.menubar.setChecked(self.window, "spaces", self.opts.spaces);
        self.refreshViews();
    }

    fn onWidthToggled(b: *gtk.CheckButton, self: *Editor) callconv(.c) void {
        if (self.syncing_status or b.getActive() == 0) return;
        const widths = [_]u32{ 2, 3, 4, 8 };
        for (self.width_buttons, 0..) |wb, i| if (wb == b) self.setTabWidth(widths[i]);
    }

    fn setNewline(self: *Editor, nl: textfile.Newline) void {
        self.eol_button.popdown();
        if (self.cur.format.newline == nl) return;
        self.cur.format.newline = nl;
        // A different line ending is a change to save.
        self.cur.buffer.setModified(1);
        self.syncStatus();
    }

    fn setEncoding(self: *Editor, enc: textfile.Encoding) void {
        self.enc_button.popdown();
        const doc = self.cur;
        if (doc.path != null and !doc.modified()) return self.reloadDoc(doc, enc);
        if (doc.format.encoding == enc) return;
        doc.format.encoding = enc;
        doc.format.bom = enc == .utf16le or enc == .utf16be;
        doc.buffer.setModified(1);
        self.syncStatus();
    }

    fn onGotoShown(_: *gtk.Popover, self: *Editor) callconv(.c) void {
        var buf: [32]u8 = undefined;
        const p = cursorPlace(self.cur);
        self.goto_entry.as(gtk.Editable).setText(std.fmt.bufPrintSentinel(&buf, "{d}", .{p.line + 1}, 0) catch "");
        self.goto_entry.as(gtk.Editable).selectRegion(0, -1);
        _ = self.goto_entry.as(gtk.Widget).grabFocus();
    }

    fn onGoto(entry: *gtk.Entry, self: *Editor) callconv(.c) void {
        const text = std.mem.trim(u8, std.mem.span(entry.as(gtk.Editable).getText()), " ");
        var parts = std.mem.splitScalar(u8, text, ':');
        const line = std.fmt.parseInt(u32, parts.next() orelse "", 10) catch return;
        const col = std.fmt.parseInt(u32, parts.next() orelse "1", 10) catch 1;
        self.pos_button.popdown();
        self.placeCursor(self.cur, .{ .line = line -| 1, .column = col -| 1 });
        _ = self.cur.focused.as(gtk.Widget).grabFocus();
    }

    fn onOverwrite(view: *gtk.TextView, _: *gobject.ParamSpec, self: *Editor) callconv(.c) void {
        self.mode_label.setText(if (view.getOverwrite() != 0) "OVR" else "INS");
    }

    /// The status bar shows the current tab: position, language, format.
    fn syncStatus(self: *Editor) void {
        const doc = self.cur;
        var buf: [96]u8 = undefined;
        var it: gtk.TextIter = undefined;
        doc.buffer.getIterAtMark(&it, doc.buffer.getInsert());
        // The column counts a tab as reaching the next tab stop.
        var col: u32 = 0;
        var walk = it;
        walk.setLineOffset(0);
        while (walk.compare(&it) < 0) : (_ = walk.forwardChar()) {
            col = if (walk.getChar() == '\t') (col / self.opts.tab_width + 1) * self.opts.tab_width else col + 1;
        }
        var sel_a: gtk.TextIter = undefined;
        var sel_b: gtk.TextIter = undefined;
        const sel = if (doc.buffer.getSelectionBounds(&sel_a, &sel_b) != 0) sel_b.getOffset() - sel_a.getOffset() else 0;
        const pos = if (sel > 0)
            std.fmt.bufPrintSentinel(&buf, "Ln {d}, Col {d}  ({d} selected)", .{ it.getLine() + 1, col + 1, sel }, 0) catch ""
        else
            std.fmt.bufPrintSentinel(&buf, "Ln {d}, Col {d}", .{ it.getLine() + 1, col + 1 }, 0) catch "";
        self.pos_button.setLabel(pos);
        self.mode_label.setText(if (doc.focused.getOverwrite() != 0) "OVR" else "INS");
        self.lang_button.setLabel(if (source.language(doc.buffer)) |l| source.languageName(l) else "Plain Text");
        var ib: [48]u8 = undefined;
        self.indent_button.setLabel(std.fmt.bufPrintSentinel(&ib, "{s}: {d}", .{ if (self.opts.spaces) "Spaces" else "Tab Width", self.opts.tab_width }, 0) catch "");
        self.eol_button.setLabel(switch (doc.format.newline) {
            .lf => "LF",
            .crlf => "CRLF",
            .cr => "CR",
        });
        var eb: [48]u8 = undefined;
        self.enc_button.setLabel(std.fmt.bufPrintSentinel(&eb, "{s}{s}", .{ doc.format.encoding.label(), if (doc.format.bom and doc.format.encoding == .utf8) " (BOM)" else "" }, 0) catch "");
        self.syncing_status = true;
        defer self.syncing_status = false;
        self.spaces_check.setActive(@intFromBool(self.opts.spaces));
        const widths = [_]u32{ 2, 3, 4, 8 };
        for (widths, 0..) |w, i| if (w == self.opts.tab_width) self.width_buttons[i].setActive(1);
    }

    /// A short message in the status bar's place, for a few seconds.
    fn flash(self: *Editor, text: [:0]const u8) void {
        self.pos_button.setLabel(text);
        _ = glib.timeoutAddSeconds(3, onFlashOver, self);
    }

    fn onFlashOver(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Editor = @ptrCast(@alignCast(data.?));
        if (!self.finished) self.syncStatus();
        return 0;
    }

    // ---- fonts ---------------------------------------------------------------------

    fn chooseFont(self: *Editor) void {
        const dialog = gtk.FontDialog.new();
        defer dialog.as(gobject.Object).unref();
        var buf: [160]u8 = undefined;
        const initial = pango.FontDescription.fromString(self.fontName(&buf));
        defer initial.free();
        dialog.chooseFont(self.window.as(gtk.Window), initial, null, onFontChosen, self);
    }

    fn onFontChosen(source_obj: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Editor = @ptrCast(@alignCast(data.?));
        const dialog: *gtk.FontDialog = @ptrCast(@alignCast(source_obj.?));
        const desc = dialog.chooseFontFinish(result, null) orelse return;
        defer desc.free();
        const text = desc.toString();
        defer glib.free(text);
        self.setFontName(std.mem.span(text));
        self.zoom = 1.0;
        self.applyFont();
        var buf: [160]u8 = undefined;
        self.config.setString("edit", "font", self.fontName(&buf)) catch {};
    }

    // ---- printing --------------------------------------------------------------------

    const PrintJob = struct {
        editor: *Editor,
        printer: ?source.Printer = null,
        /// Without GtkSourceView: the text laid out, and where pages start.
        layout: ?*pango.Layout = null,
        page_starts: std.ArrayList(c_int) = .empty,
    };

    fn print(self: *Editor) void {
        const op = gtk.PrintOperation.new();
        defer op.as(gobject.Object).unref();
        const job = self.allocator.create(PrintJob) catch return;
        job.* = .{ .editor = self };
        var buf: [300]u8 = undefined;
        op.setJobName(std.fmt.bufPrintSentinel(&buf, "{s}", .{self.cur.name()}, 0) catch "Text");
        _ = gtk.PrintOperation.signals.begin_print.connect(op, *PrintJob, &onBeginPrint, job, .{});
        _ = gtk.PrintOperation.signals.paginate.connect(op, *PrintJob, &onPaginate, job, .{});
        _ = gtk.PrintOperation.signals.draw_page.connect(op, *PrintJob, &onDrawPage, job, .{});
        _ = gtk.PrintOperation.signals.end_print.connect(op, *PrintJob, &onEndPrint, job, .{});
        var err: ?*glib.Error = null;
        _ = op.run(.print_dialog, self.window.as(gtk.Window), &err);
        if (err) |e| {
            common.dialogs.showError(self.window.as(gtk.Window), tr("Cannot print"), std.mem.span(e.f_message orelse "unknown error"));
            e.free();
        }
    }

    fn onBeginPrint(_: *gtk.PrintOperation, ctx: *gtk.PrintContext, job: *PrintJob) callconv(.c) void {
        const self = job.editor;
        var buf: [160]u8 = undefined;
        const font = self.fontName(&buf);
        job.printer = source.Printer.create(self.cur.buffer, font, self.opts.line_numbers, self.wrap);
        if (job.printer != null) return;
        // Plain: one layout of all the text, cut into pages by line.
        const layout = ctx.createPangoLayout();
        const desc = pango.FontDescription.fromString(font);
        defer desc.free();
        layout.setFontDescription(desc);
        layout.setWidth(@intFromFloat(ctx.getWidth() * pango.SCALE));
        layout.setWrap(.word_char);
        const text = self.cur.text(self.allocator) catch return;
        defer self.allocator.free(text);
        layout.setText(@ptrCast(text.ptr), @intCast(text.len));
        job.layout = layout;
        const page_h = ctx.getHeight() * pango.SCALE;
        var y: f64 = 0;
        job.page_starts.append(self.allocator, 0) catch return;
        const n = layout.getLineCount();
        var i: c_int = 0;
        while (i < n) : (i += 1) {
            const line = layout.getLineReadonly(i) orelse continue;
            var ink: pango.Rectangle = undefined;
            var logical: pango.Rectangle = undefined;
            line.getExtents(&ink, &logical);
            if (y + @as(f64, @floatFromInt(logical.f_height)) > page_h and y > 0) {
                job.page_starts.append(self.allocator, i) catch return;
                y = 0;
            }
            y += @floatFromInt(logical.f_height);
        }
    }

    fn onPaginate(op: *gtk.PrintOperation, ctx: *gtk.PrintContext, job: *PrintJob) callconv(.c) c_int {
        if (job.printer) |p| {
            if (!p.paginate(ctx)) return 0;
            op.setNPages(p.pages());
            return 1;
        }
        op.setNPages(@intCast(@max(1, job.page_starts.items.len)));
        return 1;
    }

    fn onDrawPage(_: *gtk.PrintOperation, ctx: *gtk.PrintContext, page: c_int, job: *PrintJob) callconv(.c) void {
        if (job.printer) |p| return p.draw(ctx, page);
        const layout = job.layout orelse return;
        const cr = ctx.getCairoContext();
        const first = job.page_starts.items[@intCast(page)];
        const last = if (@as(usize, @intCast(page)) + 1 < job.page_starts.items.len) job.page_starts.items[@intCast(page + 1)] else layout.getLineCount();
        var y: f64 = 0;
        var i = first;
        while (i < last) : (i += 1) {
            const line = layout.getLineReadonly(i) orelse continue;
            var ink: pango.Rectangle = undefined;
            var logical: pango.Rectangle = undefined;
            line.getExtents(&ink, &logical);
            const baseline = y - @as(f64, @floatFromInt(logical.f_y)) / pango.SCALE;
            cr.moveTo(0, baseline);
            pangocairo.showLayoutLine(cr, line);
            y += @as(f64, @floatFromInt(logical.f_height)) / pango.SCALE;
        }
    }

    fn onEndPrint(_: *gtk.PrintOperation, _: *gtk.PrintContext, job: *PrintJob) callconv(.c) void {
        if (job.printer) |p| p.deinit();
        if (job.layout) |l| l.as(gobject.Object).unref();
        job.page_starts.deinit(job.editor.allocator);
        job.editor.allocator.destroy(job);
    }

    // ---- tabs ------------------------------------------------------------------------

    /// Opens a new empty tab and shows it.
    pub fn addDoc(self: *Editor) !*Doc {
        const doc = try Doc.create(self);
        errdefer doc.destroy();
        source.applyBuffer(doc.buffer, self.syntax);
        source.setScheme(doc.buffer, self.schemeName(), isDark());
        if (self.map_on) doc.setMap(true);

        const close = gtk.Button.newFromIconName("window-close-symbolic");
        close.setHasFrame(0);
        close.as(gtk.Widget).setTooltipText(tr("Close tab"));
        const tab = gtk.Box.new(.horizontal, 6);
        tab.append(doc.label.as(gtk.Widget));
        tab.append(close.as(gtk.Widget));

        try self.docs.append(self.allocator, doc);
        _ = gtk.TextBuffer.signals.changed.connect(doc.buffer, *Doc, &onBufferChanged, doc, .{});
        _ = gtk.TextBuffer.signals.modified_changed.connect(doc.buffer, *Doc, &onModifiedChanged, doc, .{});
        _ = gtk.TextBuffer.signals.mark_set.connect(doc.buffer, *Doc, &onMarkSet, doc, .{});
        _ = gobject.Object.signals.notify.connect(doc.buffer, *Doc, &onLanguageChanged, doc, .{ .detail = "language" });
        _ = gtk.Button.signals.clicked.connect(close, *Doc, &onTabClose, doc, .{});

        const index = self.notebook.appendPage(doc.page.as(gtk.Widget), tab.as(gtk.Widget));
        self.notebook.setTabReorderable(doc.page.as(gtk.Widget), 1);
        self.cur = doc;
        self.notebook.setCurrentPage(index);
        _ = doc.view.as(gtk.Widget).grabFocus();
        self.refreshTab(doc);
        self.refresh();
        return doc;
    }

    fn removeDoc(self: *Editor, doc: *Doc) void {
        const index = std.mem.indexOfScalar(*Doc, self.docs.items, doc) orelse return;
        const page = self.notebook.pageNum(doc.page.as(gtk.Widget));
        _ = self.docs.orderedRemove(index);
        self.dropDraft(doc);
        // The buffer outlives the page while its signals are disconnected.
        _ = gobject.signalHandlersDisconnectMatched(doc.buffer.as(gobject.Object), .{ .data = true }, 0, 0, null, null, doc);
        self.notebook.removePage(page);
        doc.destroy();
        const now = self.notebook.getCurrentPage();
        if (now >= 0) if (self.notebook.getNthPage(now)) |widget| {
            for (self.docs.items) |d| if (d.page.as(gtk.Widget) == widget) {
                self.cur = d;
            };
        };
        self.refresh();
    }

    pub fn showDoc(self: *Editor, doc: *Doc) void {
        const page = self.notebook.pageNum(doc.page.as(gtk.Widget));
        if (page >= 0) self.notebook.setCurrentPage(page);
        self.cur = doc;
    }

    fn onSwitchPage(_: *gtk.Notebook, page: *gtk.Widget, _: c_uint, self: *Editor) callconv(.c) void {
        for (self.docs.items) |d| if (d.page.as(gtk.Widget) == page) {
            if (self.search_bar.getSearchMode() != 0) search.highlight(self.cur.buffer, &.{});
            self.cur = d;
            common.menubar.setChecked(self.window, "split", d.split != null);
            self.refresh();
            if (self.search_bar.getSearchMode() != 0) self.refind(false);
            d.checkDisk();
            self.focusTextSoon();
            return;
        };
    }

    /// Puts the keyboard in the text, unless it is in an entry (the find
    /// bar, Find in Files): after switching tabs, and at the start.
    pub fn focusTextSoon(self: *Editor) void {
        if (self.focus_source == 0) self.focus_source = glib.idleAdd(onFocusIdle, self);
    }

    fn onFocusIdle(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Editor = @ptrCast(@alignCast(data.?));
        self.focus_source = 0;
        if (self.window.as(gtk.Window).getFocus()) |w| {
            if (gobject.typeCheckInstanceIsA(@ptrCast(w), gtk.Editable.getGObjectType()) != 0 and w != self.cur.focused.as(gtk.Widget)) return 0;
        }
        _ = self.cur.focused.as(gtk.Widget).grabFocus();
        return 0;
    }

    fn onReordered(_: *gtk.Notebook, _: *gtk.Widget, _: c_uint, self: *Editor) callconv(.c) void {
        // Keep the list in the notebook's order (for the session).
        var i: c_int = 0;
        while (i < self.notebook.getNPages()) : (i += 1) {
            const w = self.notebook.getNthPage(i) orelse continue;
            for (self.docs.items, 0..) |d, j| if (d.page.as(gtk.Widget) == w) {
                const tmp = self.docs.items[@intCast(i)];
                self.docs.items[@intCast(i)] = d;
                self.docs.items[j] = tmp;
                break;
            };
        }
        self.scheduleAutosave();
    }

    fn onTabClose(_: *gtk.Button, doc: *Doc) callconv(.c) void {
        doc.editor.confirmDiscard(doc, .close_tab);
    }

    fn onActiveChanged(_: *gtk.ApplicationWindow, _: *gobject.ParamSpec, self: *Editor) callconv(.c) void {
        // Coming back to the window: anything changed on disk meanwhile?
        if (self.window.as(gtk.Window).isActive() == 0) return;
        self.cur.checkDisk();
        self.cur.refreshWritable();
        self.refresh();
    }

    /// The tab's title: the file name, with * while it has unsaved changes.
    fn refreshTab(self: *Editor, doc: *Doc) void {
        _ = self;
        var buf: [300]u8 = undefined;
        const text = std.fmt.bufPrintSentinel(&buf, "{s}{s}", .{ if (doc.modified()) "*" else "", doc.name() }, 0) catch return;
        doc.label.setText(text);
        doc.label.as(gtk.Widget).setTooltipText(if (doc.path) |p| p else null);
    }

    /// Title and status bar for the current tab.
    fn refresh(self: *Editor) void {
        const doc = self.cur;
        var buf: [700]u8 = undefined;
        var dir_buf: [300]u8 = undefined;
        // The folder after the name, with the home folder as "~".
        const dir: []const u8 = if (doc.path) |p| blk: {
            const d = std.fs.path.dirname(p) orelse "/";
            const home = std.mem.span(glib.getHomeDir());
            break :blk if (home.len > 1 and std.mem.startsWith(u8, d, home)) std.fmt.bufPrint(&dir_buf, " (~{s})", .{d[home.len..]}) catch "" else std.fmt.bufPrint(&dir_buf, " ({s})", .{d}) catch "";
        } else "";
        const title = std.fmt.bufPrintSentinel(&buf, "{s}{s}{s}{s} - Editor", .{
            if (doc.modified()) "*" else "",
            doc.name(),
            if (doc.readonly) " [Read-Only]" else "",
            dir,
        }, 0) catch return;
        self.window.as(gtk.Window).setTitle(title);
        self.refreshTab(doc);
        self.syncStatus();
    }

    fn onBufferChanged(_: *gtk.TextBuffer, doc: *Doc) callconv(.c) void {
        const self = doc.editor;
        doc.cursorsMoved();
        if (doc == self.cur) {
            self.syncStatus();
            self.scheduleRefind();
        }
        self.scheduleAutosave();
    }

    fn onModifiedChanged(_: *gtk.TextBuffer, doc: *Doc) callconv(.c) void {
        const self = doc.editor;
        self.refreshTab(doc);
        if (doc == self.cur) self.refresh();
        self.scheduleAutosave();
    }

    fn onMarkSet(_: *gtk.TextBuffer, _: *gtk.TextIter, mark: *gtk.TextMark, doc: *Doc) callconv(.c) void {
        const self = doc.editor;
        if (doc != self.cur) return;
        if (mark == doc.buffer.getInsert() or mark == doc.buffer.getSelectionBound()) {
            self.syncStatus();
            if (self.search_bar.getSearchMode() != 0) self.updateMatchLabel();
        }
        doc.cursorsMoved();
    }

    fn onLanguageChanged(_: *gtk.TextBuffer, _: *gobject.ParamSpec, doc: *Doc) callconv(.c) void {
        if (doc == doc.editor.cur) doc.editor.syncStatus();
    }
};
