//! dkde-edit: a plain text editor in the style of Notepad (SPEC.md 5.6).

const std = @import("std");
const gdk = @import("gdk4");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const pango = @import("pango1");
const common = @import("common");

const App = struct {
    allocator: std.mem.Allocator,
    config: common.Config,
    appearance: ?*common.style.Appearance = null,
    /// Files to open, one tab each, from the command line.
    files: []const [:0]const u8,

    fn activate(app: *gtk.Application, self: *App) callconv(.c) void {
        common.style.load(self.allocator) catch |err|
            std.log.warn("stylesheet not loaded: {s}", .{@errorName(err)});
        self.appearance = common.style.Appearance.create(self.allocator) catch null;
        const editor = Editor.create(self.allocator, app, &self.config) catch |err| {
            std.log.err("cannot create the window: {s}", .{@errorName(err)});
            return;
        };
        for (self.files) |path| editor.openPath(path);
        editor.window.as(gtk.Window).present();
    }
};

/// One open file, shown in one tab.
const Doc = struct {
    editor: *Editor,
    buffer: *gtk.TextBuffer,
    view: *gtk.TextView,
    scroller: *gtk.ScrolledWindow,
    label: *gtk.Label,
    /// Path of the file, or null for an untitled document.
    path: ?[:0]u8 = null,
};

const Editor = struct {
    allocator: std.mem.Allocator,
    config: *common.Config,
    window: *gtk.ApplicationWindow,
    notebook: *gtk.Notebook,
    docs: std.ArrayList(*Doc) = .empty,
    /// The document in the visible tab; all actions work on it.
    cur: *Doc = undefined,
    wrap: bool = true,
    status: *gtk.Label,
    search_bar: *gtk.SearchBar,
    find_entry: *gtk.SearchEntry,
    replace_entry: *gtk.Entry,
    css: *gtk.CssProvider,
    /// Close was requested and the user chose to save first.
    closing_after_save: bool = false,

    fn create(allocator: std.mem.Allocator, app: *gtk.Application, config: *common.Config) !*Editor {
        const self = try allocator.create(Editor);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .config = config,
            .window = gtk.ApplicationWindow.new(app),
            .notebook = gtk.Notebook.new(),
            .status = gtk.Label.new(""),
            .search_bar = gtk.SearchBar.new(),
            .find_entry = gtk.SearchEntry.new(),
            .replace_entry = gtk.Entry.new(),
            .css = gtk.CssProvider.new(),
        };

        const window = self.window;
        window.as(gtk.Window).setDefaultSize(760, 560);
        window.as(gtk.Widget).addCssClass("dkde");

        _ = common.header.create(window.as(gtk.Window), "accessories-text-editor", true);

        // Remembered view options.
        const word_wrap = config.getBool("edit", "word-wrap", true);
        const font_name = config.getString(allocator, "edit", "font", "Monospace 11") catch null;
        defer if (font_name) |f| allocator.free(f);
        if (allocator.dupeSentinel(u8, font_name orelse "Monospace 11", 0)) |z| {
            defer allocator.free(z);
            const desc = pango.FontDescription.fromString(z);
            self.applyFont(desc);
            desc.free();
        } else |_| {}

        // Classic menu bar.
        const mb = common.menubar;
        const menus = [_]mb.Menu{
            .{ .label = "_File", .entries = &.{
                mb.item("New _Tab", "new", "<Control>t"),
                mb.item("_Open…", "open", "<Control>o"),
                mb.item("_Save", "save", "<Control>s"),
                mb.item("Save _As…", "save-as", "<Control><Shift>s"),
                .separator,
                mb.item("_Close Tab", "close-tab", "<Control>w"),
                mb.item("E_xit", "close", "<Control>q"),
            } },
            .{ .label = "_Edit", .entries = &.{
                mb.item("_Undo", "undo", "<Control>z"),
                mb.item("_Redo", "redo", "<Control>y"),
                .separator,
                mb.item("Cu_t", "cut", "<Control>x"),
                mb.item("_Copy", "copy", "<Control>c"),
                mb.item("_Paste", "paste", "<Control>v"),
                mb.item("Select _All", "select-all", "<Control>a"),
                .separator,
                mb.item("_Find and Replace…", "find", "<Control>f"),
            } },
            .{ .label = "F_ormat", .entries = &.{
                mb.check("_Word Wrap", "word-wrap", word_wrap),
                mb.item("_Font…", "font", null),
            } },
        };
        const menu_bar = mb.build(app, window, &menus, Editor, onMenuAction, self);

        // Find / replace bar.
        const find_box = gtk.Box.new(.horizontal, 6);
        self.find_entry.setPlaceholderText(common.tr("Find"));
        self.replace_entry.setPlaceholderText(common.tr("Replace with"));
        const next = gtk.Button.newWithLabel(common.tr("Next"));
        const prev = gtk.Button.newWithLabel(common.tr("Previous"));
        const replace = gtk.Button.newWithLabel(common.tr("Replace"));
        const replace_all = gtk.Button.newWithLabel(common.tr("Replace All"));
        for ([_]*gtk.Widget{ self.find_entry.as(gtk.Widget), self.replace_entry.as(gtk.Widget), next.as(gtk.Widget), prev.as(gtk.Widget), replace.as(gtk.Widget), replace_all.as(gtk.Widget) }) |w| find_box.append(w);
        self.search_bar.setChild(find_box.as(gtk.Widget));
        self.search_bar.connectEntry(self.find_entry.as(gtk.Editable));
        _ = gtk.SearchEntry.signals.activate.connect(self.find_entry, *Editor, &onFindActivate, self, .{});
        _ = gtk.SearchEntry.signals.next_match.connect(self.find_entry, *Editor, &onFindActivate, self, .{});
        _ = gtk.Button.signals.clicked.connect(next, *Editor, &onNextClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(prev, *Editor, &onPrevClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(replace, *Editor, &onReplaceClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(replace_all, *Editor, &onReplaceAllClicked, self, .{});

        // Tabs: one document each.
        self.wrap = word_wrap;
        self.notebook.setScrollable(1);
        self.notebook.as(gtk.Widget).setVexpand(1);
        _ = gtk.Notebook.signals.switch_page.connect(self.notebook, *Editor, &onSwitchPage, self, .{});

        self.status.setXalign(0);
        self.status.as(gtk.Widget).setMarginStart(8);
        self.status.as(gtk.Widget).addCssClass("dim-label");

        const root = gtk.Box.new(.vertical, 0);
        root.append(menu_bar.as(gtk.Widget));
        root.append(self.search_bar.as(gtk.Widget));
        root.append(self.notebook.as(gtk.Widget));
        root.append(self.status.as(gtk.Widget));
        window.as(gtk.Window).setChild(root.as(gtk.Widget));

        _ = self.addDoc() catch return error.OutOfMemory;
        _ = gtk.Window.signals.close_request.connect(window.as(gtk.Window), *Editor, &onCloseRequest, self, .{});
        _ = gtk.Widget.signals.destroy.connect(window, *Editor, &onDestroy, self, .{});
        self.installShortcuts();
        self.updateTitle();
        self.updateStatus();
        return self;
    }

    fn onDestroy(_: *gtk.ApplicationWindow, self: *Editor) callconv(.c) void {
        for (self.docs.items) |doc| {
            if (doc.path) |p| self.allocator.free(p);
            self.allocator.destroy(doc);
        }
        self.docs.deinit(self.allocator);
        self.css.as(gobject.Object).unref();
        self.allocator.destroy(self);
    }

    // ---- actions -----------------------------------------------------------

    fn perform(self: *Editor, action: []const u8) void {
        const eql = std.mem.eql;
        if (eql(u8, action, "new")) return self.newDocument();
        if (eql(u8, action, "open")) return self.openDialog();
        if (eql(u8, action, "save")) return self.save();
        if (eql(u8, action, "save-as")) return self.saveAsDialog();
        if (eql(u8, action, "undo")) return self.cur.buffer.undo();
        if (eql(u8, action, "redo")) return self.cur.buffer.redo();
        if (eql(u8, action, "cut")) return self.cur.buffer.cutClipboard(self.cur.view.as(gtk.Widget).getClipboard(), 1);
        if (eql(u8, action, "copy")) return self.cur.buffer.copyClipboard(self.cur.view.as(gtk.Widget).getClipboard());
        if (eql(u8, action, "paste")) return self.cur.buffer.pasteClipboard(self.cur.view.as(gtk.Widget).getClipboard(), null, 1);
        if (eql(u8, action, "select-all")) {
            var start: gtk.TextIter = undefined;
            var end: gtk.TextIter = undefined;
            self.cur.buffer.getBounds(&start, &end);
            return self.cur.buffer.selectRange(&start, &end);
        }
        if (eql(u8, action, "word-wrap")) {
            const on = !self.wrap;
            self.applyWrap(on);
            self.config.setBool("edit", "word-wrap", on) catch {};
            return;
        }
        if (eql(u8, action, "font")) return self.chooseFont();
        if (eql(u8, action, "find")) {
            self.search_bar.setSearchMode(1);
            _ = self.find_entry.as(gtk.Widget).grabFocus();
        }
        if (eql(u8, action, "close-tab")) return self.confirmDiscard(.close_tab);
        if (eql(u8, action, "close")) self.window.as(gtk.Window).close();
    }

    const Shortcut = struct { trigger: [:0]const u8, action: []const u8 };
    const shortcuts = [_]Shortcut{
        .{ .trigger = "<Control>n", .action = "new" },
        .{ .trigger = "<Control>t", .action = "new" },
        .{ .trigger = "<Control>o", .action = "open" },
        .{ .trigger = "<Control>s", .action = "save" },
        .{ .trigger = "<Control><Shift>s", .action = "save-as" },
        .{ .trigger = "<Control>f", .action = "find" },
        .{ .trigger = "<Control>h", .action = "find" },
        .{ .trigger = "<Control>w", .action = "close-tab" },
        .{ .trigger = "<Control>q", .action = "close" },
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
        self.perform(shortcut.action);
        return 1;
    }

    // ---- files -------------------------------------------------------------

    pub fn openPath(self: *Editor, path: [:0]const u8) void {
        const file = gio.File.newForCommandlineArg(path);
        defer file.as(gobject.Object).unref();
        self.loadFile(file);
    }

    fn loadFile(self: *Editor, file: *gio.File) void {
        var contents: [*]u8 = undefined;
        var length: usize = 0;
        var err: ?*glib.Error = null;
        if (file.loadContents(null, &contents, &length, null, &err) == 0) {
            const message = if (err) |e| e.f_message orelse "unknown error" else "unknown error";
            common.dialogs.showError(self.window.as(gtk.Window), common.tr("Cannot open the file"), std.mem.span(message));
            if (err) |e| e.free();
            return;
        }
        defer glib.free(contents);
        if (glib.utf8Validate(@ptrCast(contents), @intCast(length), null) == 0) {
            common.dialogs.showError(self.window.as(gtk.Window), common.tr("Cannot open the file"), common.tr("It is not UTF-8 text."));
            return;
        }
        // An untouched empty tab is reused; otherwise the file gets its own tab.
        const doc = self.targetForOpen() catch return;
        doc.buffer.setText(@ptrCast(contents), @intCast(length));
        doc.buffer.setModified(0);
        // Opening starts a fresh undo history.
        doc.buffer.setEnableUndo(0);
        doc.buffer.setEnableUndo(1);

        if (doc.path) |p| self.allocator.free(p);
        doc.path = null;
        if (file.getPath()) |p| {
            defer glib.free(p);
            doc.path = self.allocator.dupeSentinel(u8, std.mem.span(p), 0) catch null;
        }
        self.refreshTab(doc);
        self.updateTitle();
    }

    fn targetForOpen(self: *Editor) !*Doc {
        const doc = self.cur;
        if (doc.path == null and doc.buffer.getModified() == 0 and doc.buffer.getCharCount() == 0) return doc;
        return self.addDoc();
    }

    fn newDocument(self: *Editor) void {
        _ = self.addDoc() catch {};
    }

    fn openDialog(self: *Editor) void {
        self.proceed(.open_file);
    }

    const Pending = enum { open_file, close_window, close_tab };

    /// Runs `pending` once unsaved changes are saved or discarded.
    fn confirmDiscard(self: *Editor, pending: Pending) void {
        if (self.cur.buffer.getModified() == 0) return self.proceed(pending);
        const ctx = std.heap.c_allocator.create(DiscardCtx) catch return;
        ctx.* = .{ .editor = self, .pending = pending };
        common.dialogs.choose(
            self.window.as(gtk.Window),
            common.tr("Save changes?"),
            common.tr("Your changes will be lost if you don't save them."),
            &.{ "Cancel", "Discard", "Save" },
            0,
            DiscardCtx,
            onDiscardAnswer,
            ctx,
        );
    }

    const DiscardCtx = struct { editor: *Editor, pending: Pending };

    fn onDiscardAnswer(ctx: *DiscardCtx, index: c_int) void {
        defer std.heap.c_allocator.destroy(ctx);
        const self = ctx.editor;
        switch (index) {
            1 => self.proceed(ctx.pending),
            2 => {
                self.save();
                if (self.cur.buffer.getModified() == 0) self.proceed(ctx.pending);
            },
            else => {},
        }
    }

    fn proceed(self: *Editor, pending: Pending) void {
        switch (pending) {
            .open_file => {
                const dialog = gtk.FileDialog.new();
                defer dialog.as(gobject.Object).unref();
                dialog.open(self.window.as(gtk.Window), null, onOpenChosen, self);
            },
            .close_window => {
                for (self.docs.items) |doc| doc.buffer.setModified(0);
                self.window.as(gtk.Window).close();
            },
            .close_tab => {
                if (self.docs.items.len == 1) {
                    self.cur.buffer.setModified(0);
                    self.window.as(gtk.Window).close();
                } else self.removeDoc(self.cur);
            },
        }
    }

    fn onOpenChosen(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Editor = @ptrCast(@alignCast(data.?));
        const dialog: *gtk.FileDialog = @ptrCast(@alignCast(source.?));
        var err: ?*glib.Error = null;
        const file = dialog.openFinish(result, &err) orelse {
            if (err) |e| e.free();
            return;
        };
        defer file.as(gobject.Object).unref();
        self.loadFile(file);
    }

    fn save(self: *Editor) void {
        const path = self.cur.path orelse return self.saveAsDialog();
        self.writeTo(path);
    }

    fn saveAsDialog(self: *Editor) void {
        const dialog = gtk.FileDialog.new();
        defer dialog.as(gobject.Object).unref();
        dialog.save(self.window.as(gtk.Window), null, onSaveChosen, self);
    }

    fn onSaveChosen(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Editor = @ptrCast(@alignCast(data.?));
        const dialog: *gtk.FileDialog = @ptrCast(@alignCast(source.?));
        var err: ?*glib.Error = null;
        const file = dialog.saveFinish(result, &err) orelse {
            if (err) |e| e.free();
            self.closing_after_save = false;
            return;
        };
        defer file.as(gobject.Object).unref();
        const path = file.getPath() orelse return;
        defer glib.free(path);
        const owned = self.allocator.dupeSentinel(u8, std.mem.span(path), 0) catch return;
        if (self.cur.path) |old| self.allocator.free(old);
        self.cur.path = owned;
        self.writeTo(owned);
    }

    fn writeTo(self: *Editor, path: [:0]const u8) void {
        var start: gtk.TextIter = undefined;
        var end: gtk.TextIter = undefined;
        self.cur.buffer.getBounds(&start, &end);
        const text = self.cur.buffer.getText(&start, &end, 1);
        defer glib.free(text);
        const bytes = std.mem.span(text);
        var err: ?*glib.Error = null;
        if (glib.fileSetContents(path, bytes.ptr, @intCast(bytes.len), &err) == 0) {
            const message = if (err) |e| e.f_message orelse "unknown error" else "unknown error";
            common.dialogs.showError(self.window.as(gtk.Window), common.tr("Cannot save the file"), std.mem.span(message));
            if (err) |e| e.free();
            return;
        }
        self.cur.buffer.setModified(0);
        self.updateTitle();
    }

    fn anyModified(self: *const Editor) bool {
        for (self.docs.items) |doc| if (doc.buffer.getModified() != 0) return true;
        return false;
    }

    fn onCloseRequest(_: *gtk.Window, self: *Editor) callconv(.c) c_int {
        if (!self.anyModified()) return 0;
        const ctx = std.heap.c_allocator.create(DiscardCtx) catch return 0;
        ctx.* = .{ .editor = self, .pending = .close_window };
        common.dialogs.choose(
            self.window.as(gtk.Window),
            common.tr("Discard unsaved changes?"),
            common.tr("Some tabs have changes that are not saved. Save them first, or they will be lost."),
            &.{ "Cancel", "Discard" },
            0,
            DiscardCtx,
            onCloseAnswer,
            ctx,
        );
        return 1; // the dialog decides
    }

    fn onCloseAnswer(ctx: *DiscardCtx, index: c_int) void {
        defer std.heap.c_allocator.destroy(ctx);
        if (index == 1) ctx.editor.proceed(.close_window);
    }

    // ---- find and replace ------------------------------------------------------

    fn findNext(self: *Editor, forward: bool) bool {
        const needle = std.mem.span(self.find_entry.as(gtk.Editable).getText());
        if (needle.len == 0) return false;
        var cursor: gtk.TextIter = undefined;
        const insert = self.cur.buffer.getInsert();
        self.cur.buffer.getIterAtMark(&cursor, insert);
        var match_start: gtk.TextIter = undefined;
        var match_end: gtk.TextIter = undefined;
        const flags: gtk.TextSearchFlags = .{ .text_only = true, .case_insensitive = true };

        var found = if (forward) cursor.forwardSearch(needle.ptr, flags, &match_start, &match_end, null) != 0 else cursor.backwardSearch(needle.ptr, flags, &match_start, &match_end, null) != 0;
        if (!found) {
            // Wrap around.
            var wrap: gtk.TextIter = undefined;
            if (forward) self.cur.buffer.getStartIter(&wrap) else self.cur.buffer.getEndIter(&wrap);
            found = if (forward) wrap.forwardSearch(needle.ptr, flags, &match_start, &match_end, null) != 0 else wrap.backwardSearch(needle.ptr, flags, &match_start, &match_end, null) != 0;
        }
        if (!found) return false;
        self.cur.buffer.selectRange(&match_start, &match_end);
        self.cur.view.scrollToMark(self.cur.buffer.getInsert(), 0.1, 0, 0, 0);
        return true;
    }

    fn replaceCurrent(self: *Editor) void {
        var start: gtk.TextIter = undefined;
        var end: gtk.TextIter = undefined;
        if (self.cur.buffer.getSelectionBounds(&start, &end) == 0) {
            _ = self.findNext(true);
            return;
        }
        // Only replace a selection that is the search text.
        const selected = self.cur.buffer.getText(&start, &end, 0);
        defer glib.free(selected);
        const needle = std.mem.span(self.find_entry.as(gtk.Editable).getText());
        if (!std.ascii.eqlIgnoreCase(std.mem.span(selected), needle)) {
            _ = self.findNext(true);
            return;
        }
        self.cur.buffer.delete(&start, &end);
        const replacement = std.mem.span(self.replace_entry.as(gtk.Editable).getText());
        self.cur.buffer.insert(&start, replacement.ptr, @intCast(replacement.len));
        _ = self.findNext(true);
    }

    fn replaceAll(self: *Editor) void {
        const needle = std.mem.span(self.find_entry.as(gtk.Editable).getText());
        if (needle.len == 0) return;
        const replacement = std.mem.span(self.replace_entry.as(gtk.Editable).getText());
        const flags: gtk.TextSearchFlags = .{ .text_only = true, .case_insensitive = true };
        self.cur.buffer.beginUserAction();
        defer self.cur.buffer.endUserAction();
        var cursor: gtk.TextIter = undefined;
        self.cur.buffer.getStartIter(&cursor);
        var count: usize = 0;
        var match_start: gtk.TextIter = undefined;
        var match_end: gtk.TextIter = undefined;
        while (cursor.forwardSearch(needle.ptr, flags, &match_start, &match_end, null) != 0) : (count += 1) {
            self.cur.buffer.delete(&match_start, &match_end);
            self.cur.buffer.insert(&match_start, replacement.ptr, @intCast(replacement.len));
            cursor = match_start;
        }
        var buf: [64]u8 = undefined;
        self.status.setText(std.fmt.bufPrintSentinel(&buf, "{d} replaced", .{count}, 0) catch "");
    }

    fn onFindActivate(_: *gtk.SearchEntry, self: *Editor) callconv(.c) void {
        _ = self.findNext(true);
    }

    fn onNextClicked(_: *gtk.Button, self: *Editor) callconv(.c) void {
        _ = self.findNext(true);
    }

    fn onPrevClicked(_: *gtk.Button, self: *Editor) callconv(.c) void {
        _ = self.findNext(false);
    }

    fn onReplaceClicked(_: *gtk.Button, self: *Editor) callconv(.c) void {
        self.replaceCurrent();
    }

    fn onReplaceAllClicked(_: *gtk.Button, self: *Editor) callconv(.c) void {
        self.replaceAll();
    }

    fn onMenuAction(self: *Editor, action: []const u8) void {
        self.perform(action);
    }

    fn chooseFont(self: *Editor) void {
        const dialog = gtk.FontDialog.new();
        defer dialog.as(gobject.Object).unref();
        dialog.chooseFont(self.window.as(gtk.Window), null, null, onFontChosen, self);
    }

    fn onFontChosen(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Editor = @ptrCast(@alignCast(data.?));
        const dialog: *gtk.FontDialog = @ptrCast(@alignCast(source.?));
        var err: ?*glib.Error = null;
        const desc = dialog.chooseFontFinish(result, &err) orelse {
            if (err) |e| e.free();
            return;
        };
        self.applyFont(desc);
        const text = desc.toString();
        defer glib.free(text);
        self.config.setString("edit", "font", std.mem.span(text)) catch {};
        desc.free();
    }

    // ---- view options ---------------------------------------------------------

    fn applyWrap(self: *Editor, wrap: bool) void {
        self.wrap = wrap;
        for (self.docs.items) |doc| doc.view.setWrapMode(if (wrap) .word_char else .none);
    }

    fn applyFont(self: *Editor, desc: *pango.FontDescription) void {
        const family = desc.getFamily() orelse "Monospace";
        const size = desc.getSize();
        var buf: [256]u8 = undefined;
        const css = std.fmt.bufPrintSentinel(&buf, "textview {{ font-family: \"{s}\"; font-size: {d}pt; }}", .{ std.mem.span(family), @divTrunc(size, pango.SCALE) }, 0) catch return;
        self.css.loadFromString(css);
        if (gdk.Display.getDefault()) |display|
            gtk.StyleContext.addProviderForDisplay(display, self.css.as(gtk.StyleProvider), gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 5);
    }

    // ---- status ------------------------------------------------------------------

    /// Opens a new empty tab and shows it.
    fn addDoc(self: *Editor) !*Doc {
        const doc = try self.allocator.create(Doc);
        errdefer self.allocator.destroy(doc);

        const buffer = gtk.TextBuffer.new(null);
        buffer.setEnableUndo(1);
        const view = gtk.TextView.newWithBuffer(buffer);
        view.setMonospace(1);
        view.as(gtk.Widget).setMarginStart(4);
        view.setLeftMargin(6);
        view.setTopMargin(4);
        view.setWrapMode(if (self.wrap) .word_char else .none);
        const scroller = gtk.ScrolledWindow.new();
        scroller.setChild(view.as(gtk.Widget));
        scroller.as(gtk.Widget).setVexpand(1);

        const label = gtk.Label.new("Untitled");
        label.setEllipsize(.end);
        label.setWidthChars(10);
        label.setMaxWidthChars(22);
        const close = gtk.Button.newFromIconName("window-close-symbolic");
        close.setHasFrame(0);
        close.as(gtk.Widget).setTooltipText(common.tr("Close tab"));
        const tab = gtk.Box.new(.horizontal, 6);
        tab.append(label.as(gtk.Widget));
        tab.append(close.as(gtk.Widget));

        doc.* = .{ .editor = self, .buffer = buffer, .view = view, .scroller = scroller, .label = label };
        try self.docs.append(self.allocator, doc);
        _ = gtk.TextBuffer.signals.changed.connect(buffer, *Doc, &onBufferChanged, doc, .{});
        _ = gtk.TextBuffer.signals.mark_set.connect(buffer, *Doc, &onMarkSet, doc, .{});
        _ = gtk.Button.signals.clicked.connect(close, *Doc, &onTabClose, doc, .{});

        const index = self.notebook.appendPage(scroller.as(gtk.Widget), tab.as(gtk.Widget));
        self.notebook.setTabReorderable(scroller.as(gtk.Widget), 1);
        self.cur = doc;
        self.notebook.setCurrentPage(index);
        _ = view.as(gtk.Widget).grabFocus();
        self.updateTitle();
        self.updateStatus();
        return doc;
    }

    fn removeDoc(self: *Editor, doc: *Doc) void {
        const index = std.mem.indexOfScalar(*Doc, self.docs.items, doc) orelse return;
        const page = self.notebook.pageNum(doc.scroller.as(gtk.Widget));
        _ = self.docs.orderedRemove(index);
        self.notebook.removePage(page);
        if (doc.path) |p| self.allocator.free(p);
        self.allocator.destroy(doc);
        // GTK moves to a neighbouring tab; follow it.
        const now = self.notebook.getCurrentPage();
        if (now >= 0) {
            if (self.notebook.getNthPage(now)) |widget| {
                for (self.docs.items) |d| {
                    if (d.scroller.as(gtk.Widget) == widget) self.cur = d;
                }
            }
        }
        self.updateTitle();
        self.updateStatus();
    }

    fn onSwitchPage(_: *gtk.Notebook, page: *gtk.Widget, _: c_uint, self: *Editor) callconv(.c) void {
        for (self.docs.items) |d| if (d.scroller.as(gtk.Widget) == page) {
            self.cur = d;
            self.updateTitle();
            self.updateStatus();
            return;
        };
    }

    fn onTabClose(_: *gtk.Button, doc: *Doc) callconv(.c) void {
        const self = doc.editor;
        // Work on the tab being closed, so "Save" saves the right one.
        const page = self.notebook.pageNum(doc.scroller.as(gtk.Widget));
        self.notebook.setCurrentPage(page);
        self.cur = doc;
        self.confirmDiscard(.close_tab);
    }

    /// The tab's title: the file name, with * while it has unsaved changes.
    fn refreshTab(self: *Editor, doc: *Doc) void {
        _ = self;
        var buf: [300]u8 = undefined;
        const name = if (doc.path) |p| std.fs.path.basename(p) else "Untitled";
        const text = std.fmt.bufPrintSentinel(&buf, "{s}{s}", .{ if (doc.buffer.getModified() != 0) "*" else "", name }, 0) catch return;
        doc.label.setText(text);
    }

    fn updateTitle(self: *Editor) void {
        var buf: [512]u8 = undefined;
        const name = if (self.cur.path) |p| std.fs.path.basename(p) else "Untitled";
        const modified = self.cur.buffer.getModified() != 0;
        const title = std.fmt.bufPrintSentinel(&buf, "{s}{s} - Editor", .{ if (modified) "*" else "", name }, 0) catch return;
        self.window.as(gtk.Window).setTitle(title);
        self.refreshTab(self.cur);
    }

    fn updateStatus(self: *Editor) void {
        var iter: gtk.TextIter = undefined;
        self.cur.buffer.getIterAtMark(&iter, self.cur.buffer.getInsert());
        var buf: [96]u8 = undefined;
        const text = std.fmt.bufPrintSentinel(&buf, "Ln {d}, Col {d}   {d} lines", .{ iter.getLine() + 1, iter.getLineOffset() + 1, self.cur.buffer.getLineCount() }, 0) catch return;
        self.status.setText(text);
    }

    fn onBufferChanged(_: *gtk.TextBuffer, doc: *Doc) callconv(.c) void {
        const self = doc.editor;
        self.refreshTab(doc);
        if (doc == self.cur) {
            self.updateTitle();
            self.updateStatus();
        }
    }

    fn onMarkSet(_: *gtk.TextBuffer, _: *gtk.TextIter, mark: *gtk.TextMark, doc: *Doc) callconv(.c) void {
        const self = doc.editor;
        if (doc == self.cur and mark == doc.buffer.getInsert()) self.updateStatus();
    }
};

pub const std_options: std.Options = .{ .logFn = common.log.logFn, .log_level = .debug };

pub fn main(init: std.process.Init.Minimal) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var files: std.ArrayList([:0]const u8) = .empty;
    defer files.deinit(allocator);
    for (init.args.vector[1..]) |arg| try files.append(allocator, std.mem.span(arg));

    var app: App = .{
        .allocator = allocator,
        .config = try common.Config.load(allocator, "edit.conf"),
        .files = files.items,
    };
    defer app.config.deinit();
    defer if (app.appearance) |a| a.destroy();

    const gtk_app = gtk.Application.new("org.dkde.edit", .{ .non_unique = true });
    defer gtk_app.as(gobject.Object).unref();
    _ = gio.Application.signals.activate.connect(gtk_app, *App, &App.activate, &app, .{});

    // GApplication only gets the program name; the file argument is ours.
    var argv = [_]?[*:0]const u8{ init.args.vector[0], null };
    const status = gio.Application.run(gtk_app.as(gio.Application), 1, @ptrCast(&argv));
    if (status != 0) std.process.exit(@intCast(status));
}
