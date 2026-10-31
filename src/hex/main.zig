//! dkde-hex: a hex editor (SPEC.md 5.6). It edits a file in memory with
//! undo and redo, and shows a data inspector for the bytes at the cursor.

const std = @import("std");
const gdk = @import("gdk4");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

const buffer_mod = @import("buffer.zig");
const inspect = @import("inspect.zig");
const View = @import("view.zig").View;

pub const std_options: std.Options = .{ .logFn = common.log.logFn, .log_level = .debug };

/// Files larger than this are refused: the whole file is held in memory.
const max_file_bytes: u64 = 1 << 30;

const App = struct {
    allocator: std.mem.Allocator,
    appearance: ?*common.style.Appearance = null,
    file: ?[:0]const u8,

    fn activate(app: *gtk.Application, self: *App) callconv(.c) void {
        common.style.load(self.allocator) catch |err|
            std.log.warn("stylesheet not loaded: {s}", .{@errorName(err)});
        self.appearance = common.style.Appearance.create(self.allocator) catch null;
        const editor = HexEditor.create(self.allocator, app) catch |err| {
            std.log.err("cannot create the window: {s}", .{@errorName(err)});
            return;
        };
        if (self.file) |path| editor.openPath(path);
        editor.window.as(gtk.Window).present();
    }
};

const inspector_rows = 12;

const HexEditor = struct {
    allocator: std.mem.Allocator,
    window: *gtk.ApplicationWindow,
    buffer: buffer_mod.Buffer,
    view: *View,
    path: ?[:0]u8 = null,
    status: *gtk.Label,
    inspector: *gtk.Box,
    names: [inspector_rows]*gtk.Label = undefined,
    values: [inspector_rows]*gtk.Label = undefined,
    endian: inspect.Endian = .little,
    /// The last search, so Find Next has something to look for.
    needle: ?[]u8 = null,
    closing_after_save: bool = false,
    pending: ?Pending = null,

    const Pending = enum { open, close, revert, new };

    fn create(allocator: std.mem.Allocator, app: *gtk.Application) !*HexEditor {
        const self = try allocator.create(HexEditor);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .window = gtk.ApplicationWindow.new(app),
            .buffer = buffer_mod.Buffer.init(allocator),
            .view = undefined,
            .status = gtk.Label.new(""),
            .inspector = gtk.Box.new(.vertical, 2),
        };
        self.view = try View.create(allocator, &self.buffer, onViewChanged, self);

        const window = self.window.as(gtk.Window);
        window.setTitle(common.tr("Hex Editor"));
        window.setDefaultSize(960, 620);
        self.window.as(gtk.Widget).addCssClass("dkde");
        _ = common.header.create(window, "accessories-text-editor", true);

        const mb = common.menubar;
        const menus = [_]mb.Menu{
            .{ .label = "_File", .entries = &.{
                mb.item("_New", "new", "<Control>n"),
                mb.item("_Open…", "open", "<Control>o"),
                mb.item("_Save", "save", "<Control>s"),
                mb.item("Save _As…", "save-as", "<Control><Shift>s"),
                mb.item("_Revert", "revert", null),
                .separator,
                mb.item("E_xit", "close", "<Control>q"),
            } },
            .{ .label = "_Edit", .entries = &.{
                mb.item("_Undo        Ctrl+Z", "undo", null),
                mb.item("_Redo        Ctrl+Y", "redo", null),
                .separator,
                mb.item("Cu_t          Ctrl+X", "cut", null),
                mb.item("_Copy hex   Ctrl+C", "copy", null),
                mb.item("Copy as te_xt   Ctrl+Shift+C", "copy-text", null),
                mb.item("_Paste        Ctrl+V", "paste", null),
                .separator,
                mb.item("Select _All  Ctrl+A", "select-all", null),
                .separator,
                mb.item("_Find…", "find", "<Control>f"),
                mb.item("Find _Next", "find-next", "F3"),
                mb.item("Find _Previous", "find-prev", "<Shift>F3"),
                mb.item("_Go to…", "goto", "<Control>g"),
            } },
            .{ .label = "_View", .entries = &.{
                mb.item("_8 bytes per row", "bpr-8", null),
                mb.item("_16 bytes per row", "bpr-16", null),
                mb.item("_32 bytes per row", "bpr-32", null),
                .separator,
                mb.check("_Uppercase hex", "uppercase", true),
                mb.check("_Insert mode  Insert", "insert", false),
                .separator,
                mb.check("Data _inspector", "inspector", true),
                mb.check("_Big-endian values", "big-endian", false),
            } },
        };
        const menu_bar = mb.build(app, self.window, &menus, HexEditor, onMenubarAction, self);

        // Data inspector on the right.
        self.inspector.as(gtk.Widget).addCssClass("dkde-hex-inspector");
        self.inspector.as(gtk.Widget).setSizeRequest(230, -1);
        self.inspector.as(gtk.Widget).setHexpand(0);
        self.inspector.as(gtk.Widget).setMarginStart(8);
        self.inspector.as(gtk.Widget).setMarginEnd(8);
        self.inspector.as(gtk.Widget).setMarginTop(8);
        const heading = gtk.Label.new(common.tr("Data inspector"));
        heading.setXalign(0);
        heading.as(gtk.Widget).addCssClass("heading");
        self.inspector.append(heading.as(gtk.Widget));
        for (0..inspector_rows) |i| {
            const row = gtk.Box.new(.horizontal, 8);
            const name = gtk.Label.new("");
            name.setXalign(0);
            name.as(gtk.Widget).setSizeRequest(64, -1);
            name.as(gtk.Widget).addCssClass("dim-label");
            const value = gtk.Label.new("");
            value.setXalign(0);
            value.setSelectable(1);
            value.setEllipsize(.end);
            value.setMaxWidthChars(22);
            row.append(name.as(gtk.Widget));
            row.append(value.as(gtk.Widget));
            self.inspector.append(row.as(gtk.Widget));
            self.names[i] = name;
            self.values[i] = value;
        }

        const body = gtk.Box.new(.horizontal, 0);
        self.view.widget().setHexpand(1);
        body.append(self.view.widget());
        body.append(gtk.Separator.new(.vertical).as(gtk.Widget));
        body.append(self.inspector.as(gtk.Widget));

        self.status.setXalign(0);
        self.status.as(gtk.Widget).setMarginStart(8);
        self.status.as(gtk.Widget).setMarginTop(3);
        self.status.as(gtk.Widget).setMarginBottom(3);
        self.status.as(gtk.Widget).addCssClass("dkde-files-status");

        const root = gtk.Box.new(.vertical, 0);
        root.append(menu_bar.as(gtk.Widget));
        body.as(gtk.Widget).setVexpand(1);
        root.append(body.as(gtk.Widget));
        root.append(self.status.as(gtk.Widget));
        window.setChild(root.as(gtk.Widget));

        _ = gtk.Window.signals.close_request.connect(window, *HexEditor, &onCloseRequest, self, .{});
        _ = gtk.Widget.signals.destroy.connect(self.window, *HexEditor, &onDestroy, self, .{});
        self.updateAll();
        self.view.grabFocus();
        return self;
    }

    fn onDestroy(_: *gtk.ApplicationWindow, self: *HexEditor) callconv(.c) void {
        self.buffer.deinit();
        if (self.path) |p| self.allocator.free(p);
        if (self.needle) |n| self.allocator.free(n);
        self.allocator.destroy(self);
    }

    // ---- display ------------------------------------------------------------------------

    fn onViewChanged(data: *anyopaque) void {
        const self: *HexEditor = @ptrCast(@alignCast(data));
        self.updateAll();
    }

    fn updateAll(self: *HexEditor) void {
        self.updateTitle();
        self.updateStatus();
        self.updateInspector();
    }

    fn updateTitle(self: *HexEditor) void {
        var buf: [512]u8 = undefined;
        const name: []const u8 = if (self.path) |p| std.fs.path.basename(p) else "Untitled";
        const text = std.fmt.bufPrintSentinel(&buf, "{s}{s} \u{2014} Hex Editor", .{ if (self.buffer.isModified()) "*" else "", name }, 0) catch return;
        self.window.as(gtk.Window).setTitle(text);
    }

    fn updateStatus(self: *HexEditor) void {
        var buf: [256]u8 = undefined;
        const v = self.view;
        var sel_text: [48]u8 = undefined;
        const selection = if (v.selection()) |s|
            std.fmt.bufPrint(&sel_text, "   Selected {d} bytes", .{s[1] - s[0]}) catch ""
        else
            "";
        const text = std.fmt.bufPrintSentinel(&buf, "Offset 0x{X:0>8} ({d}){s}   Size {d} bytes   {s}   {s}", .{
            v.cursor,
            v.cursor,
            selection,
            self.buffer.len(),
            if (v.insert_mode) "INS" else "OVR",
            if (v.pane == .hex) "hex" else "text",
        }, 0) catch return;
        self.status.setText(text);
    }

    fn updateInspector(self: *HexEditor) void {
        const bytes = self.buffer.slice();
        const at = @min(self.view.cursor, bytes.len);
        const end = @min(bytes.len, at + 8);
        var storage: [768]u8 = undefined;
        var rows: [inspector_rows]inspect.Row = undefined;
        const n = inspect.inspect(bytes[at..end], self.endian, &storage, &rows);
        for (0..inspector_rows) |i| {
            if (i < n) {
                var name_buf: [32]u8 = undefined;
                var value_buf: [96]u8 = undefined;
                self.names[i].setText(std.fmt.bufPrintSentinel(&name_buf, "{s}", .{rows[i].label}, 0) catch "");
                self.values[i].setText(std.fmt.bufPrintSentinel(&value_buf, "{s}", .{rows[i].text}, 0) catch "");
            } else {
                self.names[i].setText("");
                self.values[i].setText("");
            }
        }
    }

    // ---- files -------------------------------------------------------------------------------

    pub fn openPath(self: *HexEditor, path: [:0]const u8) void {
        const file = gio.File.newForPath(path);
        defer file.as(gobject.Object).unref();
        self.loadFile(file);
    }

    fn loadFile(self: *HexEditor, file: *gio.File) void {
        const path = file.getPath() orelse return;
        defer glib.free(path);
        const path_z = std.mem.span(path);
        var err: ?*glib.Error = null;
        if (file.queryInfo("standard::size", .{}, null, &err)) |info| {
            defer info.as(gobject.Object).unref();
            if (@as(u64, @intCast(info.getSize())) > max_file_bytes) {
                return common.dialogs.showError(self.window.as(gtk.Window), common.tr("The file is too large"), common.tr("dkde-hex holds the whole file in memory and opens files up to 1 GiB."));
            }
        } else if (err) |e| {
            defer e.free();
            return self.fail(common.tr("Cannot open the file"), e);
        }
        var contents: [*]u8 = undefined;
        var length: usize = 0;
        if (glib.fileGetContents(path_z, &contents, &length, &err) == 0) {
            if (err) |e| {
                defer e.free();
                return self.fail(common.tr("Cannot open the file"), e);
            }
            return;
        }
        defer glib.free(contents);
        self.buffer.load(contents[0..length]) catch return;
        const owned = self.allocator.dupeSentinel(u8, path_z, 0) catch return;
        if (self.path) |old| self.allocator.free(old);
        self.path = owned;
        self.view.cursor = 0;
        self.view.adjustment.setValue(0);
        self.view.refresh();
    }

    fn fail(self: *HexEditor, message: [:0]const u8, e: *glib.Error) void {
        common.dialogs.showError(self.window.as(gtk.Window), message, std.mem.span(e.f_message orelse "unknown error"));
    }

    fn save(self: *HexEditor) void {
        const path = self.path orelse return self.saveAsDialog();
        self.writeTo(path);
    }

    fn writeTo(self: *HexEditor, path: [:0]const u8) void {
        var err: ?*glib.Error = null;
        const bytes = self.buffer.slice();
        // An empty file still needs a valid pointer for GLib.
        const ptr: [*]const u8 = if (bytes.len > 0) bytes.ptr else "";
        if (glib.fileSetContents(path, ptr, @intCast(bytes.len), &err) == 0) {
            self.closing_after_save = false;
            if (err) |e| {
                defer e.free();
                self.fail(common.tr("Cannot save the file"), e);
            }
            return;
        }
        self.buffer.markSaved();
        self.updateAll();
        if (self.closing_after_save) {
            self.closing_after_save = false;
            self.proceed(self.pending orelse .close);
        }
    }

    fn saveAsDialog(self: *HexEditor) void {
        const dialog = gtk.FileDialog.new();
        defer dialog.as(gobject.Object).unref();
        dialog.save(self.window.as(gtk.Window), null, onSaveChosen, self);
    }

    fn onSaveChosen(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *HexEditor = @ptrCast(@alignCast(data.?));
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
        if (self.path) |old| self.allocator.free(old);
        self.path = owned;
        self.writeTo(owned);
    }

    fn onOpenChosen(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *HexEditor = @ptrCast(@alignCast(data.?));
        const dialog: *gtk.FileDialog = @ptrCast(@alignCast(source.?));
        var err: ?*glib.Error = null;
        const file = dialog.openFinish(result, &err) orelse {
            if (err) |e| e.free();
            return;
        };
        defer file.as(gobject.Object).unref();
        self.loadFile(file);
    }

    // ---- unsaved changes -------------------------------------------------------------------

    /// Runs `what` once any unsaved changes are saved or given up.
    fn confirmDiscard(self: *HexEditor, what: Pending) void {
        if (!self.buffer.isModified()) return self.proceed(what);
        self.pending = what;
        common.dialogs.choose(
            self.window.as(gtk.Window),
            common.tr("Save changes?"),
            common.tr("Your changes will be lost if you don't save them."),
            &.{ "Cancel", "Discard", "Save" },
            0,
            HexEditor,
            onDiscardAnswer,
            self,
        );
    }

    fn onDiscardAnswer(self: *HexEditor, index: c_int) void {
        const what = self.pending orelse return;
        switch (index) {
            1 => self.proceed(what),
            2 => {
                self.closing_after_save = true;
                self.save();
            },
            else => self.pending = null,
        }
    }

    fn proceed(self: *HexEditor, what: Pending) void {
        self.pending = null;
        switch (what) {
            .open => {
                const dialog = gtk.FileDialog.new();
                defer dialog.as(gobject.Object).unref();
                dialog.open(self.window.as(gtk.Window), null, onOpenChosen, self);
            },
            .close => {
                // The changes are saved or dropped: mark it clean so closing does not ask again.
                self.buffer.markSaved();
                self.window.as(gtk.Window).close();
            },
            .revert => if (self.path) |p| {
                const copy = self.allocator.dupeSentinel(u8, p, 0) catch return;
                defer self.allocator.free(copy);
                self.openPath(copy);
            },
            .new => {
                self.buffer.load("") catch return;
                if (self.path) |p| self.allocator.free(p);
                self.path = null;
                self.view.refresh();
            },
        }
    }

    fn onCloseRequest(_: *gtk.Window, self: *HexEditor) callconv(.c) c_int {
        if (!self.buffer.isModified()) return 0;
        self.confirmDiscard(.close);
        return 1;
    }

    // ---- find and go to --------------------------------------------------------------------

    pub const Ask = struct {
        editor: *HexEditor,
        dialog: *gtk.Window,
        entry: *gtk.Entry,
        hex: ?*gtk.CheckButton,
        kind: enum { find, goto },

        fn submit(self: *Ask) void {
            submitAsk(self);
        }
    };

    fn ask(self: *HexEditor, kind: @FieldType(Ask, "kind")) void {
        const dialog = gtk.Window.new();
        dialog.setTitle(if (kind == .find) common.tr("Find") else common.tr("Go to offset"));
        dialog.setTransientFor(self.window.as(gtk.Window));
        dialog.setModal(1);
        dialog.setDefaultSize(360, -1);
        dialog.as(gtk.Widget).addCssClass("dkde");
        const box = gtk.Box.new(.vertical, 8);
        box.as(gtk.Widget).setMarginTop(16);
        box.as(gtk.Widget).setMarginBottom(16);
        box.as(gtk.Widget).setMarginStart(16);
        box.as(gtk.Widget).setMarginEnd(16);
        dialog.setChild(box.as(gtk.Widget));

        const label = gtk.Label.new(if (kind == .find) common.tr("Search for") else common.tr("Offset (decimal, or hex with 0x)"));
        label.setXalign(0);
        box.append(label.as(gtk.Widget));
        const entry = gtk.Entry.new();
        entry.as(gtk.Widget).setHexpand(1);
        if (kind == .find) if (self.needle) |n| {
            var tmp: [256]u8 = undefined;
            const shown = std.fmt.bufPrintSentinel(&tmp, "{s}", .{n[0..@min(n.len, 200)]}, 0) catch "";
            if (std.unicode.utf8ValidateSlice(shown)) entry.as(gtk.Editable).setText(shown);
        };
        box.append(entry.as(gtk.Widget));
        var hex: ?*gtk.CheckButton = null;
        if (kind == .find) {
            hex = gtk.CheckButton.newWithLabel(common.tr("Hex bytes (for example de ad be ef)"));
            box.append(hex.?.as(gtk.Widget));
        }
        const buttons = gtk.Box.new(.horizontal, 8);
        buttons.as(gtk.Widget).setHalign(.end);
        const cancel = gtk.Button.newWithLabel(common.tr("Cancel"));
        const ok = gtk.Button.newWithLabel(if (kind == .find) common.tr("Find") else common.tr("Go"));
        ok.as(gtk.Widget).addCssClass("suggested-action");
        buttons.append(cancel.as(gtk.Widget));
        buttons.append(ok.as(gtk.Widget));
        box.append(buttons.as(gtk.Widget));

        const ctx = self.allocator.create(Ask) catch return;
        ctx.* = .{ .editor = self, .dialog = dialog, .entry = entry, .hex = hex, .kind = kind };
        _ = gtk.Button.signals.clicked.connect(cancel, *Ask, &onAskCancel, ctx, .{});
        _ = gtk.Button.signals.clicked.connect(ok, *Ask, &onAskOk, ctx, .{});
        _ = gtk.Entry.signals.activate.connect(entry, *Ask, &onAskActivate, ctx, .{});
        _ = gtk.Widget.signals.destroy.connect(dialog, *Ask, &onAskDestroy, ctx, .{});
        dialog.present();
        _ = entry.as(gtk.Widget).grabFocus();
    }

    fn onAskCancel(_: *gtk.Button, ctx: *Ask) callconv(.c) void {
        ctx.dialog.destroy();
    }

    fn onAskDestroy(_: *gtk.Window, ctx: *Ask) callconv(.c) void {
        ctx.editor.allocator.destroy(ctx);
    }

    fn onAskActivate(_: *gtk.Entry, ctx: *Ask) callconv(.c) void {
        ctx.submit();
    }

    fn onAskOk(_: *gtk.Button, ctx: *Ask) callconv(.c) void {
        ctx.submit();
    }

    pub fn parseOffset(text: []const u8) ?usize {
        const t = std.mem.trim(u8, text, " \t");
        if (t.len == 0) return null;
        if (std.mem.startsWith(u8, t, "0x") or std.mem.startsWith(u8, t, "0X")) return std.fmt.parseInt(usize, t[2..], 16) catch null;
        return std.fmt.parseInt(usize, t, 10) catch null;
    }

    fn gotoOffset(self: *HexEditor, text: []const u8) bool {
        const offset = parseOffset(text) orelse return false;
        self.view.moveTo(offset, false);
        return true;
    }

    fn startSearch(self: *HexEditor, text: []const u8, as_hex: bool) bool {
        const needle: []u8 = if (as_hex)
            ((buffer_mod.parseHex(self.allocator, text) catch null) orelse return false)
        else
            (self.allocator.dupe(u8, text) catch return false);
        if (needle.len == 0) {
            self.allocator.free(needle);
            return false;
        }
        if (self.needle) |old| self.allocator.free(old);
        self.needle = needle;
        self.findNext(true);
        return true;
    }

    fn findNext(self: *HexEditor, forward: bool) void {
        const needle = self.needle orelse return self.ask(.find);
        const sel = self.view.selection();
        const from = if (forward) (if (sel) |s| s[0] + 1 else self.view.cursor + 1) else (if (sel) |s| s[0] else self.view.cursor);
        if (self.buffer.find(needle, from, forward)) |at| {
            self.view.select(at, needle.len);
        } else {
            self.status.setText(common.tr("Not found."));
        }
    }

    // ---- menu --------------------------------------------------------------------------------

    fn onMenubarAction(self: *HexEditor, action: []const u8) void {
        const eql = std.mem.eql;
        if (eql(u8, action, "new")) return self.confirmDiscard(.new);
        if (eql(u8, action, "open")) return self.confirmDiscard(.open);
        if (eql(u8, action, "save")) return self.save();
        if (eql(u8, action, "save-as")) return self.saveAsDialog();
        if (eql(u8, action, "revert")) return if (self.path != null) self.confirmDiscard(.revert);
        if (eql(u8, action, "close")) return self.window.as(gtk.Window).close();
        if (eql(u8, action, "undo")) return self.view.undo();
        if (eql(u8, action, "redo")) return self.view.redo();
        if (eql(u8, action, "copy")) return self.view.copy(false);
        if (eql(u8, action, "copy-text")) return self.view.copy(true);
        if (eql(u8, action, "cut")) return self.view.cutSelection();
        if (eql(u8, action, "paste")) return self.view.pasteClipboard();
        if (eql(u8, action, "select-all")) return self.view.selectAll();
        if (eql(u8, action, "find")) return self.ask(.find);
        if (eql(u8, action, "find-next")) return self.findNext(true);
        if (eql(u8, action, "find-prev")) return self.findNext(false);
        if (eql(u8, action, "goto")) return self.ask(.goto);
        if (eql(u8, action, "bpr-8")) return self.view.setBytesPerRow(8);
        if (eql(u8, action, "bpr-16")) return self.view.setBytesPerRow(16);
        if (eql(u8, action, "bpr-32")) return self.view.setBytesPerRow(32);
        if (eql(u8, action, "uppercase")) return self.view.setUppercase(!self.view.uppercase);
        if (eql(u8, action, "insert")) return self.view.setInsertMode(!self.view.insert_mode);
        if (eql(u8, action, "inspector")) {
            const w = self.inspector.as(gtk.Widget);
            return w.setVisible(@intFromBool(w.getVisible() == 0));
        }
        if (eql(u8, action, "big-endian")) {
            self.endian = if (self.endian == .little) .big else .little;
            return self.updateInspector();
        }
    }
};

fn submitAsk(ctx: *HexEditor.Ask) void {
    const editor = ctx.editor;
    const text = std.mem.span(ctx.entry.as(gtk.Editable).getText());
    const ok = switch (ctx.kind) {
        .find => editor.startSearch(text, if (ctx.hex) |h| h.getActive() != 0 else false),
        .goto => editor.gotoOffset(text),
    };
    if (ok) ctx.dialog.destroy() else editor.status.setText(common.tr("That is not valid here."));
}

pub fn main(init: std.process.Init.Minimal) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var app: App = .{ .allocator = allocator, .file = null };
    defer if (app.appearance) |a| a.destroy();
    // One optional file name; GTK sees only the program name.
    if (init.args.vector.len > 1) app.file = std.mem.span(init.args.vector[1]);

    const gtk_app = gtk.Application.new("org.dkde.hex", .{ .non_unique = true });
    defer gtk_app.as(gobject.Object).unref();
    _ = gio.Application.signals.activate.connect(gtk_app, *App, &App.activate, &app, .{});
    var argv = [_]?[*:0]const u8{ init.args.vector[0], null };
    const status = gio.Application.run(gtk_app.as(gio.Application), 1, @ptrCast(&argv));
    if (status != 0) std.process.exit(@intCast(status));
}

test {
    _ = @import("buffer.zig");
    _ = @import("inspect.zig");
}

test "go-to offsets" {
    try std.testing.expectEqual(@as(?usize, 255), HexEditor.parseOffset("0xFF"));
    try std.testing.expectEqual(@as(?usize, 42), HexEditor.parseOffset(" 42 "));
    try std.testing.expect(HexEditor.parseOffset("zz") == null);
    try std.testing.expect(HexEditor.parseOffset("") == null);
}
