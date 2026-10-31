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
const view_mod = @import("view.zig");
const View = view_mod.View;
const structure = @import("structure.zig");
const ksy_interp = @import("ksy/interp.zig");
const strings = @import("strings.zig");
const disk_mod = @import("disk.zig");
const ksy_model = @import("ksy/model.zig");
const hexpat = @import("hexpat/eval.zig");

pub const std_options: std.Options = .{ .logFn = common.log.logFn, .log_level = .debug };

/// Files larger than this are refused: the whole file is held in memory.
const max_file_bytes: u64 = 1 << 30;

const App = struct {
    allocator: std.mem.Allocator,
    appearance: ?*common.style.Appearance = null,
    file: ?[:0]const u8,
    /// `--device PATH`: open a disk straight away.
    device: ?[:0]const u8 = null,

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
        if (self.device) |dev| editor.openDevice(dev) else editor.autoDetect();
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

    // Structure (Kaitai formats).
    config: common.Config,
    panel: *structure.Panel = undefined,
    library: ?*structure.Library = null,
    ranges: []view_mod.Range = &.{},
    show_colours: bool = true,
    /// The buffer revision the structure was parsed from.
    parsed_revision: u64 = 0,
    reparse_source: c_uint = 0,
    /// True while a click in the structure panel moves the view, so the view
    /// does not answer by re-selecting in the panel.
    picking: bool = false,
    disk: ?DiskState = null,
    pending_device: ?[]u8 = null,
    folder_kind: structure.Kind = .ksy,
    proc_guard: *common.proc.Guard(HexEditor) = undefined,

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
            .config = try common.Config.load(allocator, "hex.conf"),
        };
        errdefer self.config.deinit();
        self.view = try View.create(allocator, &self.buffer, onViewChanged, self);
        self.panel = try structure.Panel.create(allocator, onPanelPick, self);
        self.proc_guard = common.proc.Guard(HexEditor).create(self);

        const window = self.window.as(gtk.Window);
        window.setTitle(common.tr("Hex Editor"));
        window.setDefaultSize(1160, 640);
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
            .{ .label = "_Disk", .entries = &.{
                mb.item("_Open disk or partition…", "open-disk", null),
                mb.item("Go to _sector…", "goto-sector", null),
                mb.item("_Previous window", "disk-prev", "<Alt>Page_Up"),
                mb.item("_Next window", "disk-next", "<Alt>Page_Down"),
                .separator,
                mb.check("_Enable writing", "disk-writing", false),
                mb.item("_Write changes…", "disk-write", null),
                .separator,
                mb.item("_Close disk", "disk-close", null),
            } },
            .{ .label = "_Structure", .entries = &.{
                mb.item("_Choose format…", "choose-format", "<Control>t"),
                mb.item("_Load definition…", "load-ksy", null),
                mb.item("_Re-parse", "reparse", "F5"),
                mb.item("C_lear", "clear-structure", null),
                .separator,
                mb.check("Show _colours", "colours", true),
                mb.check("Structure _panel", "structure-panel", true),
                .separator,
                mb.item("_Get Kaitai formats…", "get-formats", null),
                mb.item("Get _ImHex patterns…", "get-patterns", null),
                mb.item("Kaitai formats _folder…", "formats-folder", null),
                mb.item("ImHex patterns f_older…", "patterns-folder", null),
                .separator,
                mb.item("Find _strings…", "strings", null),
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
        body.append(gtk.Separator.new(.vertical).as(gtk.Widget));
        body.append(self.panel.box.as(gtk.Widget));
        self.panel.box.as(gtk.Widget).setVisible(0);

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
        if (self.reparse_source != 0) _ = glib.Source.remove(self.reparse_source);
        self.closeDisk();
        if (self.pending_device) |p| self.allocator.free(p);
        self.proc_guard.kill();
        self.panel.destroy();
        self.allocator.free(self.ranges);
        if (self.library) |l| l.deinit();
        self.config.deinit();
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
        self.followStructure();
    }

    fn updateTitle(self: *HexEditor) void {
        var buf: [512]u8 = undefined;
        const name: []const u8 = if (self.disk) |d| std.fs.path.basename(d.path) else if (self.path) |p| std.fs.path.basename(p) else "Untitled";
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
        var path_buf: [160]u8 = undefined;
        var field: []const u8 = "";
        if (self.panel.result) |r| {
            const at = if (v.selection()) |sel| sel[0] else v.cursor;
            if (structure.nodeAt(r.root, at)) |n| field = structure.pathOf(n, &path_buf);
        }
        if (self.disk) |d| {
            const abs = d.window_start + v.cursor;
            const text = std.fmt.bufPrintSentinel(&buf, "{s}   Sector {d} +{d}   Offset 0x{X} ({d}){s}   Disk {d} bytes   {s}   {s}", .{
                std.fs.path.basename(d.path),
                abs / d.sector,
                abs % d.sector,
                abs,
                abs,
                selection,
                d.handle.size,
                if (d.writing) "WRITE ENABLED" else "read-only",
                field,
            }, 0) catch return;
            return self.status.setText(text);
        }
        const text = std.fmt.bufPrintSentinel(&buf, "Offset 0x{X:0>8} ({d}){s}   Size {d} bytes   {s}   {s}   {s}", .{
            v.cursor,
            v.cursor,
            selection,
            self.buffer.len(),
            if (v.insert_mode) "INS" else "OVR",
            if (v.pane == .hex) "hex" else "text",
            field,
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
        self.clearStructure();
        self.view.refresh();
    }

    fn fail(self: *HexEditor, message: [:0]const u8, e: *glib.Error) void {
        common.dialogs.showError(self.window.as(gtk.Window), message, std.mem.span(e.f_message orelse "unknown error"));
    }

    fn save(self: *HexEditor) void {
        if (self.disk != null) return self.diskWrite();
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
        self.autoDetect();
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
                self.autoDetect();
            },
            .new => {
                self.buffer.load("") catch return;
                self.clearStructure();
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
        kind: enum { find, goto, sector },

        fn submit(self: *Ask) void {
            submitAsk(self);
        }
    };

    fn ask(self: *HexEditor, kind: @FieldType(Ask, "kind")) void {
        const dialog = gtk.Window.new();
        dialog.setTitle(if (kind == .find) common.tr("Find") else if (kind == .sector) common.tr("Go to sector") else common.tr("Go to offset"));
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

        const label = gtk.Label.new(if (kind == .find) common.tr("Search for") else if (kind == .sector) common.tr("Sector number (LBA, decimal or hex with 0x)") else common.tr("Offset (decimal, or hex with 0x)"));
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
        if (self.disk != null) {
            self.diskGoto(offset);
            return true;
        }
        self.view.moveTo(offset, false);
        return true;
    }

    fn gotoSector(self: *HexEditor, text: []const u8) bool {
        const d = self.disk orelse return false;
        const lba = parseOffset(text) orelse return false;
        if (@as(u64, lba) * d.sector >= d.handle.size) return false;
        self.diskGoto(@as(u64, lba) * d.sector);
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

    // ---- structure ----------------------------------------------------------------------------

    /// The folder holding `.ksy` files: `[hex] formats-dir`, else
    /// `~/.local/share/dkde/formats`.
    fn formatsDir(self: *HexEditor) ![]u8 {
        const configured = try self.config.getString(self.allocator, "hex", "formats-dir", "");
        if (configured.len > 0) return configured;
        self.allocator.free(configured);
        return std.fmt.allocPrint(self.allocator, "{s}/dkde/formats", .{std.mem.span(glib.getUserDataDir())});
    }

    /// The ImHex-Patterns folder: `[hex] patterns-dir`, else
    /// `~/.local/share/dkde/patterns`.
    fn patternsDir(self: *HexEditor) ![]u8 {
        const configured = try self.config.getString(self.allocator, "hex", "patterns-dir", "");
        if (configured.len > 0) return configured;
        self.allocator.free(configured);
        return std.fmt.allocPrint(self.allocator, "{s}/dkde/patterns", .{std.mem.span(glib.getUserDataDir())});
    }

    /// Scans the formats folder the first time it is needed.
    fn ensureLibrary(self: *HexEditor) ?*structure.Library {
        if (self.library) |l| return l;
        const dir = self.formatsDir() catch return null;
        defer self.allocator.free(dir);
        const pdir = self.patternsDir() catch return null;
        defer self.allocator.free(pdir);
        self.library = structure.Library.scan(self.allocator, dir, pdir) catch null;
        return self.library;
    }

    fn rescanLibrary(self: *HexEditor) void {
        if (self.library) |l| l.deinit();
        self.library = null;
        _ = self.ensureLibrary();
    }

    /// After opening a file: use the format that matches its magic bytes.
    fn autoDetect(self: *HexEditor) void {
        if (self.buffer.len() == 0) return;
        const lib = self.ensureLibrary() orelse return;
        const entry = lib.detect(self.buffer.slice(), if (self.path) |p| p else null) orelse return;
        const copy = self.allocator.dupe(u8, entry.path) catch return;
        defer self.allocator.free(copy);
        self.applyPath(copy);
    }

    fn clearStructure(self: *HexEditor) void {
        self.panel.clear();
        self.panel.setHint(common.tr("No format applied. Use Structure \u{25B8} Choose format\u{2026} or Load definition\u{2026}"));
        self.allocator.free(self.ranges);
        self.ranges = &.{};
        self.view.setHighlights(&.{});
        self.panel.box.as(gtk.Widget).setVisible(0);
        self.updateStatus();
    }

    /// Loads the `.ksy` at `path` and shows what it finds in the buffer.
    fn applyPath(self: *HexEditor, path: []const u8) void {
        const lib = self.ensureLibrary() orelse blk: {
            self.library = structure.Library.scan(self.allocator, "", "") catch return;
            break :blk self.library.?;
        };
        if (std.mem.endsWith(u8, path, ".hexpat")) {
            var failure: ?hexpat.LoadFailure = null;
            const pattern = lib.loadPattern(path, &failure) catch null orelse {
                var buf: [768]u8 = undefined;
                const detail = if (failure) |fl| std.fmt.bufPrintSentinel(&buf, "Line {d}: {s}", .{ fl.line, fl.message }, 0) catch "" else "The file could not be read.";
                if (failure) |fl| self.allocator.free(fl.message);
                return common.dialogs.showError(self.window.as(gtk.Window), common.tr("Cannot use this pattern"), detail);
            };
            return self.showEngine(.{ .hexpat = pattern });
        }
        const format = lib.load(path) catch {
            return common.dialogs.showError(self.window.as(gtk.Window), common.tr("Cannot use this format"), common.tr("The file is not a readable Kaitai Struct description."));
        };
        self.showEngine(.{ .ksy = format });
    }

    /// Parses the buffer with `engine` (taking ownership of it) and shows the result.
    fn showEngine(self: *HexEditor, engine: structure.Engine) void {
        const result = engine.run(self.allocator, self.buffer.slice()) catch {
            engine.deinit();
            return;
        };
        self.panel.show(engine, result);
        self.parsed_revision = self.buffer.revision;
        self.panel.box.as(gtk.Widget).setVisible(1);
        self.applyHighlights();
        self.updateStatus();
    }

    fn applyHighlights(self: *HexEditor) void {
        self.allocator.free(self.ranges);
        self.ranges = &.{};
        if (self.show_colours) if (self.panel.result) |r| {
            self.ranges = structure.collectRanges(self.allocator, r.root) catch &.{};
        };
        self.view.setHighlights(self.ranges);
    }

    /// Parses again after edits (the buffer changed under the structure).
    fn reparse(self: *HexEditor) void {
        const engine = self.panel.engine orelse return;
        // The panel hands the engine back so it can be shown again with a new result.
        self.panel.engine = null;
        self.showEngine(engine);
    }

    fn onReparseTick(data: ?*anyopaque) callconv(.c) c_int {
        const self: *HexEditor = @ptrCast(@alignCast(data.?));
        self.reparse_source = 0;
        if (self.panel.engine != null and self.parsed_revision != self.buffer.revision) self.reparse();
        return 0;
    }

    /// Keeps the structure in step with the view: follows the cursor, and
    /// refreshes after edits once typing pauses.
    fn followStructure(self: *HexEditor) void {
        const r = self.panel.result orelse return;
        if (self.parsed_revision != self.buffer.revision and self.reparse_source == 0) {
            self.reparse_source = glib.timeoutAdd(400, onReparseTick, self);
        }
        if (self.picking or self.parsed_revision != self.buffer.revision) return;
        if (self.view.selection() != null) return;
        if (structure.nodeAt(r.root, self.view.cursor)) |n| self.panel.reveal(n);
    }

    fn onPanelPick(data: *anyopaque, node: *structure.Node) void {
        const self: *HexEditor = @ptrCast(@alignCast(data));
        if (node.len == 0) return;
        self.picking = true;
        defer self.picking = false;
        self.view.select(node.start, node.len);
    }

    fn loadDefinitionDialog(self: *HexEditor) void {
        const dialog = gtk.FileDialog.new();
        defer dialog.as(gobject.Object).unref();
        dialog.setTitle(common.tr("Load a Kaitai format or ImHex pattern"));
        // Start where the downloaded formats and patterns are, not in the home folder.
        if (self.definitionsFolder()) |dir| {
            defer self.allocator.free(dir);
            if (self.allocator.dupeSentinel(u8, dir, 0)) |z| {
                defer self.allocator.free(z);
                const folder = gio.File.newForPath(z);
                defer folder.as(gobject.Object).unref();
                dialog.setInitialFolder(folder);
            } else |_| {}
        }
        // Only the two kinds of file this takes.
        const filter = gtk.FileFilter.new();
        filter.setName(common.tr("Formats and patterns (*.ksy, *.hexpat)"));
        filter.addPattern("*.ksy");
        filter.addPattern("*.hexpat");
        const filters = gio.ListStore.new(gtk.FileFilter.getGObjectType());
        defer filters.as(gobject.Object).unref();
        filters.append(filter.as(gobject.Object));
        dialog.setFilters(filters.as(gio.ListModel));
        dialog.open(self.window.as(gtk.Window), null, onDefinitionChosen, self);
    }

    /// The folder to start Load definition in: the ImHex `patterns/` folder or
    /// the Kaitai formats folder, whichever has something in it.
    fn definitionsFolder(self: *HexEditor) ?[]u8 {
        const lib = self.ensureLibrary();
        const want: structure.Kind = blk: {
            if (lib) |l| {
                var ksy: usize = 0;
                var pat: usize = 0;
                for (l.entries.items) |e| {
                    if (e.kind == .ksy) ksy += 1 else pat += 1;
                }
                break :blk if (pat > ksy) .hexpat else .ksy;
            }
            break :blk .ksy;
        };
        const base = (if (want == .ksy) self.formatsDir() else self.patternsDir()) catch return null;
        if (want == .hexpat) {
            // A clone has its patterns in a subfolder.
            const inner = std.fs.path.join(self.allocator, &.{ base, "patterns" }) catch return base;
            const z = self.allocator.dupeSentinel(u8, inner, 0) catch return base;
            defer self.allocator.free(z);
            if (glib.fileTest(z, .{ .is_dir = true }) != 0) {
                self.allocator.free(base);
                return inner;
            }
            self.allocator.free(inner);
        }
        const bz = self.allocator.dupeSentinel(u8, base, 0) catch return base;
        defer self.allocator.free(bz);
        if (glib.fileTest(bz, .{ .is_dir = true }) != 0) return base;
        self.allocator.free(base);
        return null;
    }

    fn onDefinitionChosen(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *HexEditor = @ptrCast(@alignCast(data.?));
        const dialog: *gtk.FileDialog = @ptrCast(@alignCast(source.?));
        var err: ?*glib.Error = null;
        const file = dialog.openFinish(result, &err) orelse {
            if (err) |e| e.free();
            return;
        };
        defer file.as(gobject.Object).unref();
        const path = file.getPath() orelse return;
        defer glib.free(path);
        self.applyPath(std.mem.span(path));
    }

    fn formatsFolderDialog(self: *HexEditor, kind: structure.Kind) void {
        self.folder_kind = kind;
        const dialog = gtk.FileDialog.new();
        defer dialog.as(gobject.Object).unref();
        dialog.setTitle(if (kind == .ksy) common.tr("Folder of Kaitai .ksy files") else common.tr("ImHex-Patterns folder"));
        dialog.selectFolder(self.window.as(gtk.Window), null, onFolderChosen, self);
    }

    fn onFolderChosen(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *HexEditor = @ptrCast(@alignCast(data.?));
        const dialog: *gtk.FileDialog = @ptrCast(@alignCast(source.?));
        var err: ?*glib.Error = null;
        const file = dialog.selectFolderFinish(result, &err) orelse {
            if (err) |e| e.free();
            return;
        };
        defer file.as(gobject.Object).unref();
        const path = file.getPath() orelse return;
        defer glib.free(path);
        self.config.setString("hex", if (self.folder_kind == .ksy) "formats-dir" else "patterns-dir", std.mem.span(path)) catch {};
        self.rescanLibrary();
        const count = if (self.library) |l| l.entries.items.len else 0;
        var buf: [96]u8 = undefined;
        self.status.setText(std.fmt.bufPrintSentinel(&buf, "{d} formats found.", .{count}, 0) catch "");
        if (count > 0) self.chooseFormat();
    }

    // The format picker: a search box over the library, the best fit first.

    const Picker = struct {
        editor: *HexEditor,
        window: *gtk.Window,
        search: *gtk.SearchEntry,
        list: *gtk.ListBox,
        /// Library entries shown, by row.
        shown: std.ArrayList(usize) = .empty,

        fn matches(entry: *const structure.Entry, query: []const u8) bool {
            if (query.len == 0) return true;
            return std.ascii.findIgnoreCase(entry.title, query) != null or std.ascii.findIgnoreCase(entry.id, query) != null;
        }

        fn fill(self: *Picker, query: []const u8) void {
            const lib = self.editor.library orelse return;
            const a = self.editor.allocator;
            self.list.removeAll();
            self.shown.clearRetainingCapacity();
            const suggested = lib.detect(self.editor.buffer.slice(), self.editor.path);
            if (suggested) |e| if (query.len == 0) {
                const index = (@intFromPtr(e) - @intFromPtr(lib.entries.items.ptr)) / @sizeOf(structure.Entry);
                self.shown.append(a, index) catch return;
                self.appendLabel(e, true);
            };
            for (lib.entries.items, 0..) |*e, i| {
                if (self.shown.items.len >= 300) break;
                if (!matches(e, query)) continue;
                if (suggested != null and query.len == 0 and e == suggested.?) continue;
                self.shown.append(a, i) catch return;
                self.appendLabel(e, false);
            }
        }

        fn appendLabel(self: *Picker, e: *const structure.Entry, suggested: bool) void {
            var buf: [400]u8 = undefined;
            const text = std.fmt.bufPrintSentinel(&buf, "{s}{s}  \u{2014}  {s}", .{ if (suggested) "\u{2605} " else "", e.title, e.id }, 0) catch return;
            const label = gtk.Label.new(text);
            label.setXalign(0);
            label.setEllipsize(.end);
            label.as(gtk.Widget).setMarginTop(4);
            label.as(gtk.Widget).setMarginBottom(4);
            label.as(gtk.Widget).setMarginStart(6);
            self.list.append(label.as(gtk.Widget));
        }
    };

    fn chooseFormat(self: *HexEditor) void {
        const lib = self.ensureLibrary();
        if (lib == null or lib.?.entries.items.len == 0) {
            return self.getFormats(.ksy);
        }
        const picker = self.allocator.create(Picker) catch return;
        const window = gtk.Window.new();
        window.setTitle(common.tr("Choose a format"));
        window.setTransientFor(self.window.as(gtk.Window));
        window.setModal(1);
        window.setDefaultSize(460, 520);
        window.as(gtk.Widget).addCssClass("dkde");
        const box = gtk.Box.new(.vertical, 8);
        box.as(gtk.Widget).setMarginTop(12);
        box.as(gtk.Widget).setMarginBottom(12);
        box.as(gtk.Widget).setMarginStart(12);
        box.as(gtk.Widget).setMarginEnd(12);
        window.setChild(box.as(gtk.Widget));
        picker.* = .{ .editor = self, .window = window, .search = gtk.SearchEntry.new(), .list = gtk.ListBox.new() };
        picker.search.setPlaceholderText(common.tr("Search formats"));
        box.append(picker.search.as(gtk.Widget));
        const scroller = gtk.ScrolledWindow.new();
        scroller.setChild(picker.list.as(gtk.Widget));
        scroller.as(gtk.Widget).setVexpand(1);
        box.append(scroller.as(gtk.Widget));
        picker.list.setActivateOnSingleClick(0);
        _ = gtk.SearchEntry.signals.search_changed.connect(picker.search, *Picker, &onPickerSearch, picker, .{});
        _ = gtk.ListBox.signals.row_activated.connect(picker.list, *Picker, &onPickerActivated, picker, .{});
        _ = gtk.Widget.signals.destroy.connect(window, *Picker, &onPickerDestroy, picker, .{});
        picker.fill("");
        window.present();
        _ = picker.search.as(gtk.Widget).grabFocus();
    }

    fn onPickerSearch(entry: *gtk.SearchEntry, picker: *Picker) callconv(.c) void {
        picker.fill(std.mem.span(entry.as(gtk.Editable).getText()));
    }

    fn onPickerActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, picker: *Picker) callconv(.c) void {
        const i = row.getIndex();
        if (i < 0 or i >= picker.shown.items.len) return;
        const editor = picker.editor;
        const lib = editor.library orelse return;
        // Copy first: the window's destruction frees the picker.
        const copy = editor.allocator.dupe(u8, lib.entries.items[picker.shown.items[@intCast(i)]].path) catch return;
        defer editor.allocator.free(copy);
        picker.window.destroy();
        editor.applyPath(copy);
    }

    fn onPickerDestroy(_: *gtk.Window, picker: *Picker) callconv(.c) void {
        picker.shown.deinit(picker.editor.allocator);
        picker.editor.allocator.destroy(picker);
    }

    // ---- strings ------------------------------------------------------------------------------

    const strings_cap = 2000;

    const StringsDialog = struct {
        editor: *HexEditor,
        window: *gtk.Window,
        min_len: *gtk.SpinButton,
        list: *gtk.ListBox,
        note: *gtk.Label,
        hits: []strings.Hit = &.{},

        fn fill(self: *StringsDialog) void {
            const a = self.editor.allocator;
            a.free(self.hits);
            self.hits = &.{};
            self.list.removeAll();
            const data = self.editor.buffer.slice();
            const min: usize = @intCast(@max(2, self.min_len.getValueAsInt()));
            self.hits = strings.extract(a, data, min, strings_cap) catch return;
            for (self.hits) |hit| {
                var text_buf: [120]u8 = undefined;
                var line: [200]u8 = undefined;
                const shown = strings.text(data, hit, &text_buf);
                const label = gtk.Label.new(std.fmt.bufPrintSentinel(&line, "{X:0>8}  {s}{s}", .{ hit.offset, if (hit.wide) "[w] " else "", shown }, 0) catch "");
                label.setXalign(0);
                label.setEllipsize(.end);
                label.as(gtk.Widget).addCssClass("monospace");
                label.as(gtk.Widget).setMarginTop(2);
                label.as(gtk.Widget).setMarginBottom(2);
                label.as(gtk.Widget).setMarginStart(6);
                self.list.append(label.as(gtk.Widget));
            }
            var nb: [96]u8 = undefined;
            const capped = self.hits.len >= strings_cap;
            self.note.setText(std.fmt.bufPrintSentinel(&nb, "{d} strings{s}. Double-click one to select it.", .{ self.hits.len, if (capped) " (the first ones)" else "" }, 0) catch "");
        }
    };

    fn showStrings(self: *HexEditor) void {
        const dlg = self.allocator.create(StringsDialog) catch return;
        const window = gtk.Window.new();
        window.setTitle(common.tr("Strings"));
        window.setTransientFor(self.window.as(gtk.Window));
        window.setDefaultSize(520, 560);
        window.as(gtk.Widget).addCssClass("dkde");
        const box = gtk.Box.new(.vertical, 8);
        box.as(gtk.Widget).setMarginTop(12);
        box.as(gtk.Widget).setMarginBottom(12);
        box.as(gtk.Widget).setMarginStart(12);
        box.as(gtk.Widget).setMarginEnd(12);
        window.setChild(box.as(gtk.Widget));
        const top = gtk.Box.new(.horizontal, 8);
        top.append(gtk.Label.new(common.tr("Shortest string")).as(gtk.Widget));
        const spin = gtk.SpinButton.newWithRange(3, 64, 1);
        spin.setValue(4);
        top.append(spin.as(gtk.Widget));
        box.append(top.as(gtk.Widget));
        const note = gtk.Label.new("");
        note.setXalign(0);
        note.as(gtk.Widget).addCssClass("dim-label");
        box.append(note.as(gtk.Widget));
        const list = gtk.ListBox.new();
        list.setActivateOnSingleClick(0);
        const scroller = gtk.ScrolledWindow.new();
        scroller.setChild(list.as(gtk.Widget));
        scroller.as(gtk.Widget).setVexpand(1);
        box.append(scroller.as(gtk.Widget));
        dlg.* = .{ .editor = self, .window = window, .min_len = spin, .list = list, .note = note };
        _ = gtk.SpinButton.signals.value_changed.connect(spin, *StringsDialog, &onStringsMin, dlg, .{});
        _ = gtk.ListBox.signals.row_activated.connect(list, *StringsDialog, &onStringsActivated, dlg, .{});
        _ = gtk.Widget.signals.destroy.connect(window, *StringsDialog, &onStringsDestroy, dlg, .{});
        dlg.fill();
        window.present();
    }

    fn onStringsMin(_: *gtk.SpinButton, dlg: *StringsDialog) callconv(.c) void {
        dlg.fill();
    }

    fn onStringsActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, dlg: *StringsDialog) callconv(.c) void {
        const i = row.getIndex();
        if (i < 0 or i >= dlg.hits.len) return;
        const hit = dlg.hits[@intCast(i)];
        dlg.editor.view.select(hit.offset, hit.len);
    }

    fn onStringsDestroy(_: *gtk.Window, dlg: *StringsDialog) callconv(.c) void {
        dlg.editor.allocator.free(dlg.hits);
        dlg.editor.allocator.destroy(dlg);
    }

    // ---- getting formats ----------------------------------------------------------------------

    const Source = struct {
        url: [:0]const u8,
        git: []const u8,
        tarball: []const u8,
        intro: [:0]const u8,
        title: [:0]const u8,
    };

    fn sourceFor(kind: structure.Kind) Source {
        return switch (kind) {
            .ksy => .{
                .url = "https://github.com/kaitai-io/kaitai_struct_formats",
                .git = "https://github.com/kaitai-io/kaitai_struct_formats.git",
                .tarball = "https://github.com/kaitai-io/kaitai_struct_formats/archive/refs/heads/master.tar.gz",
                .intro = "Structure views need Kaitai Struct format files, which are free but not included with dkde. They come from this project (the formats have their own licences):",
                .title = "Get Kaitai formats",
            },
            .hexpat => .{
                .url = "https://github.com/WerWolv/ImHex-Patterns",
                .git = "https://github.com/WerWolv/ImHex-Patterns.git",
                .tarball = "https://github.com/WerWolv/ImHex-Patterns/archive/refs/heads/master.tar.gz",
                .intro = "ImHex pattern files (.hexpat) are free but not included with dkde. They come from this project, which is licensed under the GPL:",
                .title = "Get ImHex patterns",
            },
        };
    }

    const GetFormats = struct {
        kind: structure.Kind,
        editor: *HexEditor,
        window: *gtk.Window,
        note: *gtk.Label,
        download: *gtk.Button,
    };

    /// Which tool can fetch the formats, if any.
    fn downloadTool() enum { git, curl, wget, none } {
        if (common.proc.hasProgram("git")) return .git;
        if (common.proc.hasProgram("tar")) {
            if (common.proc.hasProgram("curl")) return .curl;
            if (common.proc.hasProgram("wget")) return .wget;
        }
        return .none;
    }

    fn getFormats(self: *HexEditor, kind: structure.Kind) void {
        const dir = (if (kind == .ksy) self.formatsDir() else self.patternsDir()) catch return;
        defer self.allocator.free(dir);
        const src = sourceFor(kind);
        const dlg = self.allocator.create(GetFormats) catch return;
        const window = gtk.Window.new();
        window.setTitle(src.title);
        window.setTransientFor(self.window.as(gtk.Window));
        window.setModal(1);
        window.setDefaultSize(480, -1);
        window.as(gtk.Widget).addCssClass("dkde");
        const box = gtk.Box.new(.vertical, 10);
        box.as(gtk.Widget).setMarginTop(16);
        box.as(gtk.Widget).setMarginBottom(16);
        box.as(gtk.Widget).setMarginStart(16);
        box.as(gtk.Widget).setMarginEnd(16);
        window.setChild(box.as(gtk.Widget));

        const intro = gtk.Label.new(src.intro);
        intro.setWrap(1);
        intro.setXalign(0);
        box.append(intro.as(gtk.Widget));
        const link = gtk.LinkButton.newWithLabel(src.url, src.url);
        link.as(gtk.Widget).setHalign(.start);
        box.append(link.as(gtk.Widget));

        const tool = downloadTool();
        var buf: [768]u8 = undefined;
        const where = std.fmt.bufPrintSentinel(&buf, "{s}{s}", .{
            switch (tool) {
                .git => "git is installed, so dkde can download them into: ",
                .curl => "curl and tar are installed, so dkde can download them into: ",
                .wget => "wget and tar are installed, so dkde can download them into: ",
                .none => "To download them from here, install git (or curl or wget, together with tar). Or download them yourself into: ",
            },
            dir,
        }, 0) catch "";
        const note = gtk.Label.new(where);
        note.setWrap(1);
        note.setXalign(0);
        note.setSelectable(1);
        box.append(note.as(gtk.Widget));

        const buttons = gtk.Box.new(.horizontal, 8);
        buttons.as(gtk.Widget).setHalign(.end);
        const folder = gtk.Button.newWithLabel(common.tr("Choose folder\u{2026}"));
        const close = gtk.Button.newWithLabel(common.tr("Close"));
        const download = gtk.Button.newWithLabel(common.tr("Download"));
        download.as(gtk.Widget).addCssClass("suggested-action");
        download.as(gtk.Widget).setSensitive(@intFromBool(tool != .none));
        buttons.append(folder.as(gtk.Widget));
        buttons.append(close.as(gtk.Widget));
        buttons.append(download.as(gtk.Widget));
        box.append(buttons.as(gtk.Widget));

        dlg.* = .{ .kind = kind, .editor = self, .window = window, .note = note, .download = download };
        _ = gtk.Button.signals.clicked.connect(folder, *GetFormats, &onGetFolder, dlg, .{});
        _ = gtk.Button.signals.clicked.connect(close, *GetFormats, &onGetClose, dlg, .{});
        _ = gtk.Button.signals.clicked.connect(download, *GetFormats, &onGetDownload, dlg, .{});
        _ = gtk.Widget.signals.destroy.connect(window, *GetFormats, &onGetDestroy, dlg, .{});
        window.present();
    }

    fn onGetFolder(_: *gtk.Button, dlg: *GetFormats) callconv(.c) void {
        dlg.window.destroy();
        dlg.editor.formatsFolderDialog(dlg.kind);
    }

    fn onGetClose(_: *gtk.Button, dlg: *GetFormats) callconv(.c) void {
        dlg.window.destroy();
    }

    fn onGetDestroy(_: *gtk.Window, dlg: *GetFormats) callconv(.c) void {
        // A download in flight reports to the editor's status line, not here.
        dlg.editor.allocator.destroy(dlg);
    }

    fn onGetDownload(_: *gtk.Button, dlg: *GetFormats) callconv(.c) void {
        const self = dlg.editor;
        const src = sourceFor(dlg.kind);
        const dir = (if (dlg.kind == .ksy) self.formatsDir() else self.patternsDir()) catch return;
        defer self.allocator.free(dir);
        // Refuse to mix into a folder that already has something in it.
        if (std.fs.path.dirname(dir)) |parent| {
            const z = self.allocator.dupeSentinel(u8, parent, 0) catch return;
            defer self.allocator.free(z);
            _ = glib.mkdirWithParents(z, 0o755);
        }
        if (self.library) |l| {
            var have: usize = 0;
            for (l.entries.items) |e| if (e.kind == dlg.kind) {
                have += 1;
            };
            if (have > 0) {
                dlg.note.setText(common.tr("There are already files in that folder. Remove it first, or choose another folder."));
                return;
            }
        }
        const argv: []const []const u8 = switch (downloadTool()) {
            .git => &.{ "git", "clone", "--depth", "1", src.git, dir },
            .curl => &.{ "sh", "-c", "mkdir -p \"$1\" && curl -fsSL \"$2\" | tar -xz -C \"$1\" --strip-components=1", "sh", dir, src.tarball },
            .wget => &.{ "sh", "-c", "mkdir -p \"$1\" && wget -qO- \"$2\" | tar -xz -C \"$1\" --strip-components=1", "sh", dir, src.tarball },
            .none => return,
        };
        self.status.setText(common.tr("Downloading\u{2026}"));
        common.proc.run(HexEditor, self.proc_guard, argv, onDownloadDone);
        dlg.window.destroy();
    }

    fn onDownloadDone(self: *HexEditor, ok: bool, _: []const u8) void {
        if (!ok) {
            self.status.setText("");
            return common.dialogs.showError(self.window.as(gtk.Window), common.tr("The download did not work"), common.tr("Check the network, and that the formats folder is empty or does not exist yet."));
        }
        self.rescanLibrary();
        const count = if (self.library) |l| l.entries.items.len else 0;
        var buf: [96]u8 = undefined;
        self.status.setText(std.fmt.bufPrintSentinel(&buf, "Downloaded: {d} formats and patterns found.", .{count}, 0) catch "");
        self.autoDetect();
    }

    // ---- disk mode ----------------------------------------------------------------------------

    const window_bytes: u64 = 4 << 20;

    const DiskState = struct {
        handle: disk_mod.Handle,
        path: [:0]u8,
        sector: u32,
        window_start: u64 = 0,
        /// What the window held when it was read, to find the changed sectors.
        original: []u8 = &.{},
        writing: bool = false,
    };

    fn inDiskMode(self: *const HexEditor) bool {
        return self.disk != null;
    }

    fn closeDisk(self: *HexEditor) void {
        const d = self.disk orelse return;
        var h = d.handle;
        h.closeHandle();
        self.allocator.free(d.path);
        self.allocator.free(d.original);
        self.disk = null;
        self.view.base_offset = 0;
        self.view.offset_digits = 8;
        self.view.fixed_size = false;
        common.menubar.setChecked(self.window, "disk-writing", false);
    }

    /// Opens a device (`/dev/sdb`, a partition, or any file) for reading.
    pub fn openDevice(self: *HexEditor, path: []const u8) void {
        if (self.buffer.isModified()) {
            return common.dialogs.showError(self.window.as(gtk.Window), common.tr("Unsaved changes"), common.tr("Write or discard your changes before opening another disk."));
        }
        const z = self.allocator.dupeSentinel(u8, path, 0) catch return;
        const handle = disk_mod.Handle.openPath(z, false) catch |err| {
            defer self.allocator.free(z);
            if (err == error.AccessDenied) {
                self.pending_device = self.allocator.dupe(u8, path) catch return;
                return common.dialogs.choose(
                    self.window.as(gtk.Window),
                    common.tr("Administrator rights needed"),
                    common.tr("Reading a disk needs administrator rights. dkde-hex can open it in a second window running as administrator; it asks for your password."),
                    &.{ "Cancel", "Open as administrator" },
                    0,
                    HexEditor,
                    onAdminChoice,
                    self,
                );
            }
            return common.dialogs.showError(self.window.as(gtk.Window), common.tr("Cannot open the disk"), common.tr("The device could not be opened."));
        };
        self.closeDisk();
        var sector: u32 = 512;
        if (disk_mod.list(self.allocator)) |infos| {
            defer disk_mod.freeInfos(self.allocator, infos);
            for (infos) |i| if (std.mem.eql(u8, i.path, path)) {
                sector = i.sector_size;
            };
        } else |_| {}
        self.disk = .{ .handle = handle, .path = z, .sector = sector };
        self.view.fixed_size = true;
        self.view.insert_mode = false;
        self.view.offset_digits = if (handle.size > 0xFFFF_FFFF) 12 else 8;
        self.clearStructure();
        if (self.path) |p| self.allocator.free(p);
        self.path = null;
        self.loadWindow(0);
    }

    fn onAdminChoice(self: *HexEditor, index: c_int) void {
        const path = self.pending_device orelse return;
        defer {
            self.allocator.free(path);
            self.pending_device = null;
        }
        if (index != 1) return;
        const a = std.heap.c_allocator;
        var argv: std.ArrayList([]u8) = .empty;
        defer {
            for (argv.items) |x| a.free(x);
            argv.deinit(a);
        }
        common.appinfo.displayEnvArgs(a, &argv) catch return;
        argv.append(a, a.dupe(u8, "dkde-hex") catch return) catch return;
        argv.append(a, a.dupe(u8, "--device") catch return) catch return;
        argv.append(a, a.dupe(u8, path) catch return) catch return;
        const view = a.alloc([]const u8, argv.items.len) catch return;
        defer a.free(view);
        for (argv.items, 0..) |x, i| view[i] = x;
        const done = a.create(AdminDone) catch return;
        done.* = .{ .editor = self };
        common.elevate.run(self.window.as(gtk.Window), "Open this disk with administrator rights", view, "", AdminDone, onAdminDone, done);
    }

    const AdminDone = struct { editor: *HexEditor };

    fn onAdminDone(done: *AdminDone, outcome: common.elevate.Outcome, message: []const u8) void {
        defer std.heap.c_allocator.destroy(done);
        if (outcome != .failed) return;
        var buf: [512]u8 = undefined;
        common.dialogs.showError(done.editor.window.as(gtk.Window), common.tr("Could not open as administrator"), std.fmt.bufPrintSentinel(&buf, "{s}", .{message}, 0) catch "");
    }

    /// Reads the window of the device that contains absolute offset `at`.
    fn loadWindow(self: *HexEditor, at: u64) void {
        var d = &(self.disk orelse return);
        if (self.buffer.isModified()) {
            return common.dialogs.showError(self.window.as(gtk.Window), common.tr("Unsaved changes"), common.tr("Write or discard your changes before moving to another part of the disk."));
        }
        const start = (@min(at, d.handle.size -| 1) / window_bytes) * window_bytes;
        const len: usize = @intCast(@min(window_bytes, d.handle.size - start));
        const bytes = self.allocator.alloc(u8, len) catch return;
        defer self.allocator.free(bytes);
        const got = d.handle.readAt(start, bytes) catch {
            return common.dialogs.showError(self.window.as(gtk.Window), common.tr("Cannot read the disk"), common.tr("Reading failed at that position."));
        };
        self.buffer.load(bytes[0..got]) catch return;
        self.allocator.free(d.original);
        d.original = self.allocator.dupe(u8, bytes[0..got]) catch &.{};
        d.window_start = start;
        self.view.base_offset = start;
        self.view.cursor = 0;
        self.view.adjustment.setValue(0);
        self.clearStructure();
        self.view.refresh();
    }

    /// Moves to absolute byte `abs` of the device, loading another window if needed.
    fn diskGoto(self: *HexEditor, abs: u64) void {
        const d = self.disk orelse return;
        if (abs < d.window_start or abs >= d.window_start + self.buffer.len()) {
            self.loadWindow(abs);
            if (self.disk.?.window_start > abs) return;
        }
        const win = self.disk.?.window_start;
        if (abs >= win) self.view.moveTo(@intCast(abs - win), false);
    }

    fn diskStep(self: *HexEditor, forward: bool) void {
        const d = self.disk orelse return;
        if (forward) {
            if (d.window_start + window_bytes < d.handle.size) self.loadWindow(d.window_start + window_bytes);
        } else if (d.window_start >= window_bytes) {
            self.loadWindow(d.window_start - window_bytes);
        }
    }

    fn enableWriting(self: *HexEditor) void {
        const d = &(self.disk orelse return);
        if (d.writing) {
            // Back to read-only.
            var h = d.handle;
            h.closeHandle();
            d.handle = disk_mod.Handle.openPath(d.path, false) catch return;
            d.writing = false;
            return self.updateStatus();
        }
        common.dialogs.choose(
            self.window.as(gtk.Window),
            common.tr("Enable writing to this disk?"),
            common.tr("Edits are written straight to the device when you choose Write changes. A wrong edit can make a disk or its files unreadable. Nothing is written until you confirm each write."),
            &.{ "Cancel", "Enable writing" },
            0,
            HexEditor,
            onEnableWritingAnswer,
            self,
        );
        // The menu toggled itself; it is set again once the answer is known.
        common.menubar.setChecked(self.window, "disk-writing", false);
    }

    fn onEnableWritingAnswer(self: *HexEditor, index: c_int) void {
        const d = &(self.disk orelse return);
        if (index != 1) return;
        var h = d.handle;
        const rw = disk_mod.Handle.openPath(d.path, true) catch {
            return common.dialogs.showError(self.window.as(gtk.Window), common.tr("Cannot write to this disk"), common.tr("Writing needs administrator rights. Open the disk as administrator (Disk \u{25B8} Open disk\u{2026}, then choose Open as administrator)."));
        };
        h.closeHandle();
        d.handle = rw;
        d.writing = true;
        common.menubar.setChecked(self.window, "disk-writing", true);
        self.updateStatus();
    }

    /// Asks, then writes the sectors that differ from what was read.
    fn diskWrite(self: *HexEditor) void {
        const d = self.disk orelse return;
        if (!d.writing) {
            self.closing_after_save = false;
            return common.dialogs.showError(self.window.as(gtk.Window), common.tr("Writing is off"), common.tr("Turn on Disk \u{25B8} Enable writing first."));
        }
        const changed = disk_mod.changedSectors(self.allocator, d.original, self.buffer.slice(), d.sector) catch return;
        defer self.allocator.free(changed);
        if (changed.len == 0) {
            self.closing_after_save = false;
            return self.status.setText(common.tr("Nothing has changed."));
        }
        var mounted = false;
        if (disk_mod.list(self.allocator)) |infos| {
            defer disk_mod.freeInfos(self.allocator, infos);
            mounted = disk_mod.anyMounted(infos, d.path);
        } else |_| {}
        const first = (d.window_start / d.sector) + changed[0] * (@as(u64, d.sector) / d.sector);
        var detail: [640]u8 = undefined;
        const text = std.fmt.bufPrintSentinel(&detail, "{d} sector{s} of {s} will be overwritten (first: sector {d}, {d} bytes each).{s}", .{
            changed.len,
            if (changed.len == 1) "" else "s",
            d.path,
            first,
            d.sector,
            if (mounted) " WARNING: this disk or one of its partitions is mounted. Writing under a mounted filesystem can corrupt it." else "",
        }, 0) catch return;
        common.dialogs.choose(self.window.as(gtk.Window), common.tr("Write changes to the disk?"), text, &.{ "Cancel", "Write" }, 0, HexEditor, onWriteAnswer, self);
    }

    fn onWriteAnswer(self: *HexEditor, index: c_int) void {
        const d = &(self.disk orelse return);
        if (index != 1) {
            self.closing_after_save = false;
            return;
        }
        const changed = disk_mod.changedSectors(self.allocator, d.original, self.buffer.slice(), d.sector) catch return;
        defer self.allocator.free(changed);
        const data = self.buffer.slice();
        for (changed) |s| {
            const lo = s * d.sector;
            const hi = @min(data.len, lo + d.sector);
            d.handle.writeAt(d.window_start + lo, data[lo..hi]) catch {
                self.closing_after_save = false;
                return common.dialogs.showError(self.window.as(gtk.Window), common.tr("The write failed"), common.tr("Part of the changes may have been written."));
            };
        }
        d.handle.flush();
        self.allocator.free(d.original);
        d.original = self.allocator.dupe(u8, data) catch &.{};
        self.buffer.markSaved();
        self.updateAll();
        self.status.setText(common.tr("Written."));
        if (self.closing_after_save) {
            self.closing_after_save = false;
            self.proceed(self.pending orelse .close);
        }
    }

    // The list of disks to choose from.

    const DiskPicker = struct {
        editor: *HexEditor,
        window: *gtk.Window,
        infos: []disk_mod.Info,
    };

    fn chooseDisk(self: *HexEditor) void {
        const infos = disk_mod.list(self.allocator) catch return;
        const dlg = self.allocator.create(DiskPicker) catch {
            disk_mod.freeInfos(self.allocator, infos);
            return;
        };
        const window = gtk.Window.new();
        window.setTitle(common.tr("Open a disk"));
        window.setTransientFor(self.window.as(gtk.Window));
        window.setModal(1);
        window.setDefaultSize(560, 420);
        window.as(gtk.Widget).addCssClass("dkde");
        const box = gtk.Box.new(.vertical, 8);
        box.as(gtk.Widget).setMarginTop(12);
        box.as(gtk.Widget).setMarginBottom(12);
        box.as(gtk.Widget).setMarginStart(12);
        box.as(gtk.Widget).setMarginEnd(12);
        window.setChild(box.as(gtk.Widget));
        const intro = gtk.Label.new(common.tr("Double-click a disk or partition. It opens read-only; writing is a separate step."));
        intro.setXalign(0);
        intro.setWrap(1);
        box.append(intro.as(gtk.Widget));
        const list = gtk.ListBox.new();
        list.setActivateOnSingleClick(0);
        for (infos) |i| {
            var buf: [320]u8 = undefined;
            const gib = @as(f64, @floatFromInt(i.size_bytes)) / (1024.0 * 1024.0 * 1024.0);
            const text = std.fmt.bufPrintSentinel(&buf, "{s}{s}   {d:.1} GiB   {s}{s}", .{
                if (i.is_partition) "      " else "",
                i.path,
                gib,
                i.model,
                if (i.mounted) "   [mounted]" else "",
            }, 0) catch continue;
            const label = gtk.Label.new(text);
            label.setXalign(0);
            label.as(gtk.Widget).setMarginTop(4);
            label.as(gtk.Widget).setMarginBottom(4);
            label.as(gtk.Widget).setMarginStart(6);
            label.as(gtk.Widget).addCssClass("monospace");
            list.append(label.as(gtk.Widget));
        }
        const scroller = gtk.ScrolledWindow.new();
        scroller.setChild(list.as(gtk.Widget));
        scroller.as(gtk.Widget).setVexpand(1);
        box.append(scroller.as(gtk.Widget));
        if (infos.len == 0) {
            const none = gtk.Label.new(common.tr("No disks were found. You can also start dkde-hex with --device /dev/sdX."));
            none.setWrap(1);
            box.append(none.as(gtk.Widget));
        }
        dlg.* = .{ .editor = self, .window = window, .infos = infos };
        _ = gtk.ListBox.signals.row_activated.connect(list, *DiskPicker, &onDiskPicked, dlg, .{});
        _ = gtk.Widget.signals.destroy.connect(window, *DiskPicker, &onDiskPickerDestroy, dlg, .{});
        window.present();
    }

    fn onDiskPicked(_: *gtk.ListBox, row: *gtk.ListBoxRow, dlg: *DiskPicker) callconv(.c) void {
        const i = row.getIndex();
        if (i < 0 or i >= dlg.infos.len) return;
        const editor = dlg.editor;
        const path = editor.allocator.dupe(u8, dlg.infos[@intCast(i)].path) catch return;
        defer editor.allocator.free(path);
        dlg.window.destroy();
        editor.openDevice(path);
    }

    fn onDiskPickerDestroy(_: *gtk.Window, dlg: *DiskPicker) callconv(.c) void {
        disk_mod.freeInfos(dlg.editor.allocator, dlg.infos);
        dlg.editor.allocator.destroy(dlg);
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
        if (eql(u8, action, "get-formats")) return self.getFormats(.ksy);
        if (eql(u8, action, "get-patterns")) return self.getFormats(.hexpat);
        if (eql(u8, action, "patterns-folder")) return self.formatsFolderDialog(.hexpat);
        if (eql(u8, action, "open-disk")) return self.chooseDisk();
        if (eql(u8, action, "goto-sector")) return self.ask(.sector);
        if (eql(u8, action, "disk-prev")) return self.diskStep(false);
        if (eql(u8, action, "disk-next")) return self.diskStep(true);
        if (eql(u8, action, "disk-writing")) return self.enableWriting();
        if (eql(u8, action, "disk-write")) return self.diskWrite();
        if (eql(u8, action, "disk-close")) {
            self.closeDisk();
            self.buffer.load("") catch return;
            self.view.refresh();
            return self.updateAll();
        }
        if (eql(u8, action, "strings")) return self.showStrings();
        if (eql(u8, action, "choose-format")) return self.chooseFormat();
        if (eql(u8, action, "load-ksy")) return self.loadDefinitionDialog();
        if (eql(u8, action, "reparse")) return self.reparse();
        if (eql(u8, action, "clear-structure")) return self.clearStructure();
        if (eql(u8, action, "formats-folder")) return self.formatsFolderDialog(.ksy);
        if (eql(u8, action, "colours")) {
            self.show_colours = !self.show_colours;
            return self.applyHighlights();
        }
        if (eql(u8, action, "structure-panel")) {
            const w = self.panel.box.as(gtk.Widget);
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
        .sector => editor.gotoSector(text),
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
    if (init.args.vector.len > 2 and std.mem.eql(u8, std.mem.span(init.args.vector[1]), "--device")) {
        app.device = std.mem.span(init.args.vector[2]);
    } else if (init.args.vector.len > 1) app.file = std.mem.span(init.args.vector[1]);

    const gtk_app = gtk.Application.new("org.dkde.hex", .{ .non_unique = true });
    defer gtk_app.as(gobject.Object).unref();
    _ = gio.Application.signals.activate.connect(gtk_app, *App, &App.activate, &app, .{});
    var argv = [_]?[*:0]const u8{ init.args.vector[0], null };
    const status = gio.Application.run(gtk_app.as(gio.Application), 1, @ptrCast(&argv));
    if (status != 0) std.process.exit(@intCast(status));
}

test {
    _ = @import("ksy/coverage_test.zig");
    _ = @import("ksy/prep.zig");
    _ = @import("ksy/expr.zig");
    _ = @import("ksy/model.zig");
    _ = @import("ksy/interp.zig");
    _ = @import("structure.zig");
    _ = @import("hexpat/parse.zig");
    _ = @import("hexpat/eval.zig");
    _ = @import("hexpat/coverage_test.zig");
    _ = @import("strings.zig");
    _ = @import("disk.zig");
    _ = @import("structure.zig");
    _ = @import("strings.zig");
    _ = @import("disk.zig");
    _ = @import("buffer.zig");
    _ = @import("inspect.zig");
}

test "go-to offsets" {
    try std.testing.expectEqual(@as(?usize, 255), HexEditor.parseOffset("0xFF"));
    try std.testing.expectEqual(@as(?usize, 42), HexEditor.parseOffset(" 42 "));
    try std.testing.expect(HexEditor.parseOffset("zz") == null);
    try std.testing.expect(HexEditor.parseOffset("") == null);
}
