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
const devsearch = @import("devsearch.zig");
const image = @import("image.zig");
const analyze = @import("analyze.zig");
const bookmarks_mod = @import("bookmarks.zig");
const cairo = @import("cairo1");
const ksy_model = @import("ksy/model.zig");
const hexpat = @import("hexpat/eval.zig");

pub const std_options: std.Options = .{ .logFn = common.log.logFn, .log_level = .debug };

/// Files larger than this are refused: the whole file is held in memory.
const max_file_bytes: u64 = 1 << 30;

/// The whole file is held in memory, so on a small machine the limit follows
/// the memory that is free rather than a fixed 1 GiB.
fn fileLimit() u64 {
    const avail = availableMemory() orelse return max_file_bytes;
    return @min(max_file_bytes, avail / 2);
}

fn availableMemory() ?u64 {
    var buf: [2048]u8 = undefined;
    const f = std.c.fopen("/proc/meminfo", "r") orelse return null;
    defer _ = std.c.fclose(f);
    const n = std.c.fread(&buf, 1, buf.len, f);
    const text = buf[0..n];
    const key = "MemAvailable:";
    const at = std.mem.indexOf(u8, text, key) orelse return null;
    var it = std.mem.tokenizeAny(u8, text[at + key.len ..], " \n");
    const kb = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
    return kb * 1024;
}

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
        const host = Host.create(self.allocator, app) catch |err| {
            std.log.err("cannot create the window: {s}", .{@errorName(err)});
            return;
        };
        const editor = host.addTab() orelse return;
        if (self.file) |path| editor.openPath(path);
        host.window.as(gtk.Window).present();
        if (self.device) |dev| editor.openDevice(dev) else editor.autoDetect();
    }
};

/// The window: menu bar and a notebook with one `HexEditor` per tab. Menu
/// actions go to the tab being shown.
const Host = struct {
    allocator: std.mem.Allocator,
    window: *gtk.ApplicationWindow,
    notebook: *gtk.Notebook,
    tabs: std.ArrayList(*HexEditor) = .empty,

    fn create(allocator: std.mem.Allocator, app: *gtk.Application) !*Host {
        const self = try allocator.create(Host);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .window = gtk.ApplicationWindow.new(app),
            .notebook = gtk.Notebook.new(),
        };
        const window = self.window.as(gtk.Window);
        window.setTitle(common.tr("Hex Editor"));
        window.setDefaultSize(1160, 640);
        self.window.as(gtk.Widget).addCssClass("dkde");
        _ = common.header.create(window, "accessories-text-editor", true);

        const mb = common.menubar;
        const menus = [_]mb.Menu{
            .{ .label = "_File", .entries = &.{
                mb.item("_New tab", "new", "<Control>n"),
                mb.item("_Open…", "open", "<Control>o"),
                mb.item("_Save", "save", "<Control>s"),
                mb.item("Save _As…", "save-as", "<Control><Shift>s"),
                mb.item("_Revert", "revert", null),
                mb.item("_Close tab", "close-tab", "<Control>w"),
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
                .separator,
                mb.item("Copy as _C array", "copy-c", null),
                mb.item("Copy as _Python bytes", "copy-py", null),
                mb.item("Copy as _Base64", "copy-b64", null),
                mb.item("Copy as escaped _string", "copy-esc", null),
                .separator,
                mb.item("_Fill selection…", "fill", null),
                mb.item("_XOR selection…", "xor", null),
                mb.item("Re_verse selection", "reverse", null),
                mb.item("Swap _16-bit units", "swap2", null),
                mb.item("Swap _32-bit units", "swap4", null),
                mb.item("Swap _64-bit units", "swap8", null),
            } },
            .{ .label = "_Analyze", .entries = &.{
                mb.item("_Checksums…", "checksums", null),
                mb.item("_Entropy and histogram…", "entropy", null),
                .separator,
                mb.item("C_ompare with file…", "compare", null),
                mb.item("_Next difference", "diff-next", "F7"),
                mb.item("_Previous difference", "diff-prev", "<Shift>F7"),
                mb.item("C_lear comparison", "diff-clear", null),
                .separator,
                mb.item("_Disassemble selection…", "disasm", null),
                mb.item("Find _strings…", "strings", null),
                .separator,
                mb.item("_Follow value as offset", "follow", "<Control>j"),
                mb.item("_Back", "back", "<Alt>Left"),
                .separator,
                mb.item("Add _bookmark…", "bookmark-add", "<Control>b"),
                mb.item("_Bookmarks…", "bookmarks", null),
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
                mb.item("Open _process memory…", "open-process", null),
                mb.item("Go to _sector…", "goto-sector", null),
                mb.item("_Previous window", "disk-prev", "<Alt>Page_Up"),
                mb.item("_Next window", "disk-next", "<Alt>Page_Down"),
                .separator,
                mb.check("_Enable writing", "disk-writing", false),
                mb.item("_Write changes…", "disk-write", null),
                .separator,
                mb.item("Save as _image…", "disk-image", null),
                mb.item("C_lone to another disk…", "disk-clone", null),
                mb.item("Cancel _imaging", "disk-image-cancel", null),
                .separator,
                mb.item("_Close disk or process", "disk-close", null),
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
        const menu_bar = mb.build(app, self.window, &menus, Host, onAction, self);

        self.notebook.setScrollable(1);
        self.notebook.as(gtk.Widget).setVexpand(1);
        const root = gtk.Box.new(.vertical, 0);
        root.append(menu_bar.as(gtk.Widget));
        root.append(self.notebook.as(gtk.Widget));
        window.setChild(root.as(gtk.Widget));
        _ = gtk.Notebook.signals.switch_page.connect(self.notebook, *Host, &onSwitchPage, self, .{});
        _ = gtk.Window.signals.close_request.connect(window, *Host, &onCloseRequest, self, .{});
        _ = gtk.Widget.signals.destroy.connect(self.window, *Host, &onDestroy, self, .{});
        return self;
    }

    fn onDestroy(_: *gtk.ApplicationWindow, self: *Host) callconv(.c) void {
        self.tabs.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn active(self: *Host) ?*HexEditor {
        const i = self.notebook.getCurrentPage();
        if (i < 0 or i >= self.tabs.items.len) return null;
        return self.tabs.items[@intCast(i)];
    }

    fn addTab(self: *Host) ?*HexEditor {
        const editor = HexEditor.create(self.allocator, self) catch |err| {
            std.log.err("cannot create a tab: {s}", .{@errorName(err)});
            return null;
        };
        self.tabs.append(self.allocator, editor) catch return null;
        const head = gtk.Box.new(.horizontal, 6);
        head.append(editor.tab_label.as(gtk.Widget));
        const close = gtk.Button.newWithLabel("\u{00D7}");
        close.as(gtk.Button).setHasFrame(0);
        close.as(gtk.Widget).setTooltipText(common.tr("Close tab"));
        head.append(close.as(gtk.Widget));
        _ = gtk.Button.signals.clicked.connect(close, *HexEditor, &onTabClose, editor, .{});
        const n = self.notebook.appendPage(editor.page.as(gtk.Widget), head.as(gtk.Widget));
        self.notebook.setCurrentPage(n);
        editor.updateAll();
        editor.view.grabFocus();
        return editor;
    }

    /// The tab a newly opened thing should go into: `current` if it is empty,
    /// otherwise a new one.
    fn tabFor(self: *Host, current: *HexEditor) *HexEditor {
        if (current.isPristine()) {
            const n = self.notebook.pageNum(current.page.as(gtk.Widget));
            if (n >= 0) self.notebook.setCurrentPage(n);
            return current;
        }
        return self.addTab() orelse current;
    }

    fn closeTab(self: *Host, tab: *HexEditor) void {
        if (self.tabs.items.len <= 1) return self.window.as(gtk.Window).close();
        for (self.tabs.items, 0..) |t, i| if (t == tab) {
            _ = self.tabs.orderedRemove(i);
            self.notebook.removePage(@intCast(i));
            break;
        };
        if (self.active()) |a| {
            a.updateAll();
            a.view.grabFocus();
        }
    }

    fn onTabClose(_: *gtk.Button, tab: *HexEditor) callconv(.c) void {
        tab.confirmDiscard(.close);
    }

    fn onSwitchPage(_: *gtk.Notebook, _: *gtk.Widget, num: c_uint, self: *Host) callconv(.c) void {
        if (num >= self.tabs.items.len) return;
        const tab = self.tabs.items[num];
        tab.updateTitle();
        const writing = if (tab.disk) |d| d.writing else false;
        common.menubar.setChecked(self.window, "disk-writing", writing);
    }

    /// Asks about each tab with unsaved changes, one at a time; each answer
    /// closes the window again until none is left.
    fn onCloseRequest(_: *gtk.Window, self: *Host) callconv(.c) c_int {
        for (self.tabs.items, 0..) |t, i| if (t.buffer.isModified()) {
            self.notebook.setCurrentPage(@intCast(i));
            t.confirmDiscard(.quit);
            return 1;
        };
        return 0;
    }

    fn onAction(self: *Host, action: []const u8) void {
        const eql = std.mem.eql;
        if (eql(u8, action, "new")) {
            _ = self.addTab();
            return;
        }
        if (eql(u8, action, "close")) return self.window.as(gtk.Window).close();
        const tab = self.active() orelse return;
        if (eql(u8, action, "close-tab")) return tab.confirmDiscard(.close);
        if (eql(u8, action, "open")) return tab.proceed(.open);
        tab.onMenubarAction(action);
    }
};

const inspector_rows = 12;

const HexEditor = struct {
    allocator: std.mem.Allocator,
    window: *gtk.ApplicationWindow,
    host: *Host,
    /// What the notebook shows for this tab, and its title label.
    page: *gtk.Box = undefined,
    tab_label: *gtk.Label = undefined,
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
    /// A search through the whole device, running one chunk per idle tick.
    scan: ?devsearch.Scan = null,
    scan_source: c_uint = 0,
    /// Copying the whole device into an image file.
    copier: ?image.Copier = null,
    copier_source: c_uint = 0,
    /// The disk a clone will overwrite, held while the confirmation is open.
    clone_target: ?[:0]u8 = null,
    /// True while a click in the structure panel moves the view, so the view
    /// does not answer by re-selecting in the panel.
    picking: bool = false,
    disk: ?DiskState = null,
    /// A second file to compare with, and the differences found.
    other: ?[]u8 = null,
    diffs: []analyze.Diff = &.{},
    diff_view: []view_mod.Range = &.{},
    compared_revision: u64 = 0,
    /// Offsets to return to (Alt+Left after a jump).
    back_stack: std.ArrayList(usize) = .empty,
    bookmarks: bookmarks_mod.List = .{},
    mark_view: []view_mod.Range = &.{},
    /// Last search pattern (text, hex with wildcards, or a number).
    pattern: ?analyze.Pattern = null,
    disasm_dir: ?[]u8 = null,
    pending_device: ?[]u8 = null,
    folder_kind: structure.Kind = .ksy,
    proc_guard: *common.proc.Guard(HexEditor) = undefined,

    const Pending = enum { open, close, quit, revert, new };

    fn create(allocator: std.mem.Allocator, host: *Host) !*HexEditor {
        const self = try allocator.create(HexEditor);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .window = host.window,
            .host = host,
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

        const page = gtk.Box.new(.vertical, 0);
        body.as(gtk.Widget).setVexpand(1);
        page.append(body.as(gtk.Widget));
        page.append(self.status.as(gtk.Widget));
        self.page = page;
        self.tab_label = gtk.Label.new(common.tr("Untitled"));
        _ = gtk.Widget.signals.destroy.connect(page, *HexEditor, &onDestroy, self, .{});
        self.updateAll();
        return self;
    }

    /// Nothing open and nothing changed: a new file can take this tab over.
    fn isPristine(self: *const HexEditor) bool {
        return self.path == null and self.disk == null and !self.buffer.isModified() and self.buffer.len() == 0;
    }

    fn onDestroy(_: *gtk.Box, self: *HexEditor) callconv(.c) void {
        if (self.reparse_source != 0) _ = glib.Source.remove(self.reparse_source);
        self.cancelScan();
        self.stopImaging();
        self.closeDisk();
        if (self.pending_device) |p| self.allocator.free(p);
        if (self.clone_target) |t| self.allocator.free(t);
        self.proc_guard.kill();
        self.panel.destroy();
        self.allocator.free(self.ranges);
        if (self.library) |l| l.deinit();
        self.config.deinit();
        self.buffer.deinit();
        if (self.path) |p| self.allocator.free(p);
        if (self.needle) |n| self.allocator.free(n);
        if (self.pattern) |p| p.deinit(self.allocator);
        if (self.other) |o| self.allocator.free(o);
        self.allocator.free(self.diffs);
        self.allocator.free(self.diff_view);
        self.back_stack.deinit(self.allocator);
        self.bookmarks.deinit(self.allocator);
        self.allocator.free(self.mark_view);
        if (self.disasm_dir) |d| self.allocator.free(d);
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
        const name: []const u8 = if (self.disk) |d| (if (d.process) |pn| pn else std.fs.path.basename(d.path)) else if (self.path) |p| std.fs.path.basename(p) else "Untitled";
        const text = std.fmt.bufPrintSentinel(&buf, "{s}{s} \u{2014} Hex Editor", .{ if (self.buffer.isModified()) "*" else "", name }, 0) catch return;
        const tab = std.fmt.bufPrintSentinel(buf[256..], "{s}{s}", .{ if (self.buffer.isModified()) "*" else "", name }, 0) catch return;
        self.tab_label.setText(tab);
        if (self.host.active() == self) self.window.as(gtk.Window).setTitle(text);
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
            if (d.process) |name| {
                const text = std.fmt.bufPrintSentinel(&buf, "{s}   Address 0x{X}{s}   Region 0x{X}\u{2013}0x{X} ({d} bytes)   read-only   {s}", .{
                    name,
                    d.origin + abs,
                    selection,
                    d.origin,
                    d.origin + d.handle.size,
                    d.handle.size,
                    field,
                }, 0) catch return;
                return self.status.setText(text);
            }
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
            if (@as(u64, @intCast(info.getSize())) > fileLimit()) {
                return common.dialogs.showError(self.window.as(gtk.Window), common.tr("The file is too large"), common.tr("dkde-hex holds the whole file in memory and opens files up to 1 GiB, fewer when memory is short."));
            }
        } else if (err) |e| {
            defer e.free();
            return self.fail(common.tr("Cannot open the file"), e);
        }
        // Read straight into the buffer: no second copy of a large file.
        const stream = file.read(null, &err) orelse {
            if (err) |e| {
                defer e.free();
                return self.fail(common.tr("Cannot open the file"), e);
            }
            return;
        };
        defer stream.as(gobject.Object).unref();
        const info = file.queryInfo("standard::size", .{}, null, null) orelse return;
        defer info.as(gobject.Object).unref();
        const size: usize = @intCast(info.getSize());
        const dest = self.buffer.beginLoad(size) catch {
            return common.dialogs.showError(self.window.as(gtk.Window), common.tr("The file is too large"), common.tr("There is not enough memory to hold this file."));
        };
        var got: usize = 0;
        if (stream.as(gio.InputStream).readAll(dest.ptr, dest.len, &got, null, &err) == 0) {
            self.buffer.endLoad(got);
            if (err) |e| {
                defer e.free();
                return self.fail(common.tr("Cannot open the file"), e);
            }
            return;
        }
        self.buffer.endLoad(got);
        const owned = self.allocator.dupeSentinel(u8, path_z, 0) catch return;
        if (self.path) |old| self.allocator.free(old);
        self.path = owned;
        self.view.cursor = 0;
        self.view.adjustment.setValue(0);
        self.clearStructure();
        self.view.refresh();
        self.loadBookmarks();
        self.clearComparison();
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
        const tab = self.host.tabFor(self);
        tab.loadFile(file);
        tab.autoDetect();
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
                self.host.closeTab(self);
            },
            .quit => {
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

    // ---- find and go to --------------------------------------------------------------------

    pub const Ask = struct {
        editor: *HexEditor,
        dialog: *gtk.Window,
        entry: *gtk.Entry,
        mode: ?*gtk.DropDown,
        num_kind: ?*gtk.DropDown,
        big: ?*gtk.CheckButton,
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
        var mode: ?*gtk.DropDown = null;
        var num_kind: ?*gtk.DropDown = null;
        var big: ?*gtk.CheckButton = null;
        if (kind == .find) {
            mode = gtk.DropDown.newFromStrings(@ptrCast(&[_]?[*:0]const u8{ "Text", "Hex bytes (de ad ?? ef, ?? is any byte)", "Number", null }));
            box.append(mode.?.as(gtk.Widget));
            const kinds = [_]?[*:0]const u8{ "u8", "u16", "u32", "u64", "i8", "i16", "i32", "i64", "float (f32)", "double (f64)", null };
            num_kind = gtk.DropDown.newFromStrings(@ptrCast(&kinds));
            num_kind.?.setSelected(2);
            box.append(num_kind.?.as(gtk.Widget));
            big = gtk.CheckButton.newWithLabel(common.tr("Big-endian number"));
            box.append(big.?.as(gtk.Widget));
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
        ctx.* = .{ .editor = self, .dialog = dialog, .entry = entry, .mode = mode, .num_kind = num_kind, .big = big, .kind = kind };
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
        if (d.process != null) return false;
        const lba = parseOffset(text) orelse return false;
        if (@as(u64, lba) * d.sector >= d.handle.size) return false;
        self.diskGoto(@as(u64, lba) * d.sector);
        return true;
    }

    /// `mode`: 0 text, 1 hex with `??` wildcards, 2 a number of `num_kind` (`big` for big-endian).
    fn startSearch(self: *HexEditor, text: []const u8, mode: u32, num_kind: u32, big: bool) bool {
        var pattern: analyze.Pattern = undefined;
        switch (mode) {
            1 => pattern = (analyze.parsePattern(self.allocator, text) catch null) orelse return false,
            2 => {
                const kinds = @typeInfo(analyze.NumberKind).@"enum".field_names;
                if (num_kind >= kinds.len) return false;
                const kind: analyze.NumberKind = @fromBackingInt(@intCast(num_kind));
                const bytes = (analyze.numberBytes(self.allocator, text, kind, big) catch null) orelse return false;
                const care = self.allocator.alloc(bool, bytes.len) catch {
                    self.allocator.free(bytes);
                    return false;
                };
                @memset(care, true);
                pattern = .{ .bytes = bytes, .care = care };
            },
            else => {
                if (text.len == 0) return false;
                const bytes = self.allocator.dupe(u8, text) catch return false;
                const care = self.allocator.alloc(bool, bytes.len) catch {
                    self.allocator.free(bytes);
                    return false;
                };
                @memset(care, true);
                pattern = .{ .bytes = bytes, .care = care };
            },
        }
        self.cancelScan(); // it borrows the old pattern
        if (self.pattern) |old| old.deinit(self.allocator);
        self.pattern = pattern;
        if (self.needle) |old| self.allocator.free(old);
        self.needle = if (mode == 0) self.allocator.dupe(u8, text) catch null else null;
        self.findNext(true);
        return true;
    }

    fn findNext(self: *HexEditor, forward: bool) void {
        const pattern = self.pattern orelse return self.ask(.find);
        const sel = self.view.selection();
        const from = if (forward) (if (sel) |s| s[0] + 1 else self.view.cursor + 1) else (if (sel) |s| s[0] else self.view.cursor);
        // A disk is bigger than the window, so search all of it (unless edits are pending,
        // which exist only in the window).
        if (self.disk != null and !self.buffer.isModified()) return self.startScan(pattern, from, forward);
        if (analyze.find(self.buffer.slice(), pattern, from, forward)) |at| {
            self.view.select(at, pattern.bytes.len);
        } else {
            self.status.setText(common.tr("Not found."));
        }
    }

    // ---- imaging ------------------------------------------------------------------------------

    fn stopImaging(self: *HexEditor) void {
        if (self.copier_source != 0) _ = glib.Source.remove(self.copier_source);
        self.copier_source = 0;
        if (self.copier) |*c| c.deinit(self.allocator);
        self.copier = null;
    }

    fn imageDialog(self: *HexEditor) void {
        if (self.disk == null) return self.status.setText(common.tr("Open a disk, partition or process first."));
        if (self.copier != null) return self.status.setText(common.tr("An image is already being written."));
        const dialog = gtk.FileDialog.new();
        defer dialog.as(gobject.Object).unref();
        dialog.setTitle(common.tr("Save image as"));
        dialog.save(self.window.as(gtk.Window), null, onImageChosen, self);
    }

    fn onImageChosen(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *HexEditor = @ptrCast(@alignCast(data.?));
        const dialog: *gtk.FileDialog = @ptrCast(@alignCast(source.?));
        var err: ?*glib.Error = null;
        const file = dialog.saveFinish(result, &err) orelse {
            if (err) |e| e.free();
            return;
        };
        defer file.as(gobject.Object).unref();
        const d = self.disk orelse return;
        const path = file.getPath() orelse return;
        defer glib.free(path);
        const dest = disk_mod.Handle.createFile(std.mem.span(path), d.handle) catch |e| {
            return common.dialogs.showError(self.window.as(gtk.Window), common.tr("Cannot write the image"), switch (e) {
                error.SameFile => common.tr("That is the file being read. Choose another name."),
                error.NotAFile => common.tr("An image can only be written to a regular file, never to a device."),
                error.AccessDenied => common.tr("You may not write there."),
                error.Failed => common.tr("The file could not be created."),
            });
        };
        self.stopImaging();
        self.copier = image.Copier.init(self.allocator, d.handle, d.origin, dest) catch {
            var dd = dest;
            dd.closeHandle();
            return;
        };
        self.copier_source = glib.idleAdd(onImageTick, self);
    }

    fn onImageTick(data: ?*anyopaque) callconv(.c) c_int {
        const self: *HexEditor = @ptrCast(@alignCast(data.?));
        var c = &(self.copier orelse return 0);
        var buf: [160]u8 = undefined;
        switch (c.step()) {
            .more => {
                self.status.setText(std.fmt.bufPrintSentinel(&buf, "Copying\u{2026} {d}%  (Disk \u{25B8} Cancel imaging to stop)", .{c.percent()}, 0) catch "");
                return 1;
            },
            .done => {
                const bad = c.unreadable;
                const total = c.total;
                self.copier_source = 0;
                self.stopImaging();
                self.status.setText(std.fmt.bufPrintSentinel(&buf, "Copy finished: {d} bytes, {d} unreadable (written as zeros).", .{ total, bad }, 0) catch "");
            },
            .write_failed => {
                self.copier_source = 0;
                self.stopImaging();
                common.dialogs.showError(self.window.as(gtk.Window), common.tr("Image not finished"), common.tr("Writing failed, probably because the disk is full."));
            },
        }
        return 0;
    }

    fn cancelScan(self: *HexEditor) void {
        if (self.scan_source != 0) _ = glib.Source.remove(self.scan_source);
        self.scan_source = 0;
        if (self.scan) |*sc| sc.deinit(self.allocator);
        self.scan = null;
    }

    /// Searches the whole device from window offset `from`; the result arrives from `onScanTick`.
    fn startScan(self: *HexEditor, pattern: analyze.Pattern, from: usize, forward: bool) void {
        const d = self.disk orelse return;
        self.cancelScan();
        const start = d.window_start + from;
        self.scan = devsearch.Scan.init(self.allocator, d.handle, d.origin, pattern, start, forward) catch return;
        self.scan_source = glib.idleAdd(onScanTick, self);
    }

    fn onScanTick(data: ?*anyopaque) callconv(.c) c_int {
        const self: *HexEditor = @ptrCast(@alignCast(data.?));
        var sc = &(self.scan orelse return 0);
        switch (sc.step()) {
            .more => {
                var buf: [64]u8 = undefined;
                self.status.setText(std.fmt.bufPrintSentinel(&buf, "Searching the whole device\u{2026} {d}%", .{sc.percent()}, 0) catch "");
                return 1;
            },
            .found => |at| {
                const len = sc.pattern.bytes.len;
                self.scan_source = 0;
                self.cancelScan();
                const d = self.disk orelse return 0;
                self.diskGoto(d.origin + at);
                if (self.disk) |nd| {
                    if (at >= nd.window_start) self.view.select(@intCast(at - nd.window_start), len);
                }
            },
            .none => {
                self.scan_source = 0;
                self.cancelScan();
                self.status.setText(common.tr("Not found."));
            },
        }
        return 0;
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
        const entry = lib.detect(self.buffer.slice(), if (self.path) |p| p else null) orelse {
            // Say what was looked at, so a missing match can be told from a missing library.
            var ksy_n: usize = 0;
            var pat_n: usize = 0;
            for (lib.entries.items) |e| {
                if (e.kind == .ksy) ksy_n += 1 else pat_n += 1;
            }
            var buf: [160]u8 = undefined;
            self.status.setText(std.fmt.bufPrintSentinel(&buf, "No format matched this file ({d} Kaitai formats, {d} ImHex patterns loaded). Try Structure \u{25B8} Choose format.", .{ ksy_n, pat_n }, 0) catch "");
            return;
        };
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
            const text = std.fmt.bufPrintSentinel(&buf, "{s}{s}  \u{2014}  {s}   [{s}]", .{ if (suggested) "\u{2605} " else "", e.title, e.id, if (e.kind == .ksy) "Kaitai" else "ImHex" }, 0) catch return;
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
        {
            var ksy_n: usize = 0;
            var pat_n: usize = 0;
            for (lib.?.entries.items) |e| {
                if (e.kind == .ksy) ksy_n += 1 else pat_n += 1;
            }
            var cb: [160]u8 = undefined;
            const counts = gtk.Label.new(std.fmt.bufPrintSentinel(&cb, "{d} Kaitai formats and {d} ImHex patterns loaded", .{ ksy_n, pat_n }, 0) catch "");
            counts.setXalign(0);
            counts.as(gtk.Widget).addCssClass("dim-label");
            box.append(counts.as(gtk.Widget));
        }
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

    /// How much of a device is held in memory at once: `[hex] disk-window-mib`
    /// (1 to 512, default 4).
    fn windowBytes(self: *const HexEditor) u64 {
        const mib = std.math.clamp(self.config.getInt("hex", "disk-window-mib", 4), 1, 512);
        return @as(u64, @intCast(mib)) << 20;
    }

    const DiskState = struct {
        handle: disk_mod.Handle,
        path: [:0]u8,
        sector: u32,
        window_start: u64 = 0,
        /// What the window held when it was read, to find the changed sectors.
        original: []u8 = &.{},
        writing: bool = false,
        /// Process memory: the address of byte 0 of the region shown, and
        /// the process name. Zero and null for a disk.
        origin: u64 = 0,
        process: ?[:0]u8 = null,
    };

    /// The address of the first byte held in the buffer.
    fn diskBase(self: *const HexEditor) u64 {
        const d = self.disk orelse return 0;
        return d.origin + d.window_start;
    }

    fn inDiskMode(self: *const HexEditor) bool {
        return self.disk != null;
    }

    fn closeDisk(self: *HexEditor) void {
        self.cancelScan();
        self.stopImaging();
        const d = self.disk orelse return;
        var h = d.handle;
        h.closeHandle();
        self.allocator.free(d.path);
        self.allocator.free(d.original);
        if (d.process) |p| self.allocator.free(p);
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
        self.loadBookmarks();
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
        const window_bytes = self.windowBytes();
        const start = (@min(at, d.handle.size -| 1) / window_bytes) * window_bytes;
        const len: usize = @intCast(@min(window_bytes, d.handle.size - start));
        const bytes = self.allocator.alloc(u8, len) catch return;
        defer self.allocator.free(bytes);
        const got = d.handle.readAt(d.origin + start, bytes) catch {
            return common.dialogs.showError(self.window.as(gtk.Window), common.tr("Cannot read the disk"), common.tr("Reading failed at that position."));
        };
        self.buffer.load(bytes[0..got]) catch return;
        self.allocator.free(d.original);
        d.original = self.allocator.dupe(u8, bytes[0..got]) catch &.{};
        d.window_start = start;
        self.view.base_offset = d.origin + start;
        self.view.cursor = 0;
        self.view.adjustment.setValue(0);
        self.clearStructure();
        self.view.refresh();
    }

    /// Moves to absolute byte `abs` of the device, loading another window if needed.
    fn diskGoto(self: *HexEditor, abs: u64) void {
        const d = self.disk orelse return;
        if (abs < d.origin) return;
        const rel = abs - d.origin;
        if (rel < d.window_start or rel >= d.window_start + self.buffer.len()) {
            self.loadWindow(rel);
            if (self.disk.?.window_start > rel) return;
        }
        const win = self.disk.?.window_start;
        if (rel >= win) self.view.moveTo(@intCast(rel - win), false);
    }

    fn diskStep(self: *HexEditor, forward: bool) void {
        const d = self.disk orelse return;
        const window_bytes = self.windowBytes();
        if (forward) {
            if (d.window_start + window_bytes < d.handle.size) self.loadWindow(d.window_start + window_bytes);
        } else if (d.window_start >= window_bytes) {
            self.loadWindow(d.window_start - window_bytes);
        }
    }

    fn enableWriting(self: *HexEditor) void {
        const d = &(self.disk orelse return);
        if (d.process != null) {
            common.menubar.setChecked(self.window, "disk-writing", false);
            return self.status.setText(common.tr("Process memory is read-only."));
        }
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
        clone: bool = false,
    };

    fn chooseDisk(self: *HexEditor) void {
        self.showDiskPicker(false);
    }

    fn chooseCloneTarget(self: *HexEditor) void {
        const d = self.disk orelse return self.status.setText(common.tr("Open the disk to copy from first."));
        if (d.process != null) return self.status.setText(common.tr("Process memory can be saved as an image, not cloned onto a disk."));
        if (self.copier != null) return self.status.setText(common.tr("An image is already being written."));
        self.showDiskPicker(true);
    }

    fn showDiskPicker(self: *HexEditor, clone: bool) void {
        const infos = disk_mod.list(self.allocator) catch return;
        const dlg = self.allocator.create(DiskPicker) catch {
            disk_mod.freeInfos(self.allocator, infos);
            return;
        };
        const window = gtk.Window.new();
        window.setTitle(if (clone) common.tr("Clone to which disk?") else common.tr("Open a disk"));
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
        const intro = gtk.Label.new(if (clone) common.tr("Double-click the disk or partition to OVERWRITE with a copy of the open disk. Everything on it is lost. Mounted disks and the source itself are refused.") else common.tr("Double-click a disk or partition. It opens read-only; writing is a separate step."));
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
        dlg.* = .{ .editor = self, .window = window, .infos = infos, .clone = clone };
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
        const size = dlg.infos[@intCast(i)].size_bytes;
        const clone = dlg.clone;
        dlg.window.destroy();
        if (clone) return editor.askClone(path, size);
        editor.host.tabFor(editor).openDevice(path);
    }

    // ---- cloning ------------------------------------------------------------------------------

    /// Checks the chosen target and asks for confirmation. Nothing is written yet.
    fn askClone(self: *HexEditor, target: []const u8, target_size: u64) void {
        const d = self.disk orelse return;
        const win = self.window.as(gtk.Window);
        if (self.buffer.isModified()) {
            return common.dialogs.showError(win, common.tr("Unsaved changes"), common.tr("Write or discard your changes first; a clone copies what is on the disk."));
        }
        if (disk_mod.sameDisk(target, d.path)) {
            return common.dialogs.showError(win, common.tr("Cannot clone onto the source"), common.tr("That is the disk being copied, or a partition of it (or the other way round)."));
        }
        if (target_size < d.handle.size) {
            return common.dialogs.showError(win, common.tr("Target too small"), common.tr("The target is smaller than the disk being copied."));
        }
        if (disk_mod.list(self.allocator)) |infos| {
            defer disk_mod.freeInfos(self.allocator, infos);
            if (disk_mod.anyMounted(infos, target)) {
                return common.dialogs.showError(win, common.tr("Target is mounted"), common.tr("The target, or one of its partitions, is in use. Unmount it first."));
            }
        } else |_| {
            return common.dialogs.showError(win, common.tr("Cannot check the target"), common.tr("The list of disks could not be read, so mounted disks cannot be ruled out."));
        }
        const owned = self.allocator.dupeSentinel(u8, target, 0) catch return;
        if (self.clone_target) |old| self.allocator.free(old);
        self.clone_target = owned;
        var buf: [640]u8 = undefined;
        const text = std.fmt.bufPrintSentinel(&buf, "Everything on {s} ({d} bytes) will be replaced by a copy of {s} ({d} bytes). This cannot be undone. The copy starts as soon as you confirm.", .{ target, target_size, d.path, d.handle.size }, 0) catch return;
        // The destructive button is second and the default is Cancel.
        common.dialogs.choose(win, common.tr("Overwrite this disk?"), text, &.{ "Cancel", "Overwrite" }, 0, HexEditor, onCloneAnswer, self);
    }

    fn onCloneAnswer(self: *HexEditor, index: c_int) void {
        const target = self.clone_target orelse return;
        defer {
            self.allocator.free(target);
            self.clone_target = null;
        }
        if (index != 1) return;
        const d = self.disk orelse return;
        const win = self.window.as(gtk.Window);
        const dest = disk_mod.Handle.openPath(target, true) catch |err| {
            return common.dialogs.showError(win, common.tr("Cannot write to the target"), if (err == error.AccessDenied)
                common.tr("Writing to a disk needs administrator rights. Start dkde-hex as administrator and try again.")
            else
                common.tr("The target could not be opened."));
        };
        if (dest.size < d.handle.size) {
            var h = dest;
            h.closeHandle();
            return common.dialogs.showError(win, common.tr("Target too small"), common.tr("The target is smaller than the disk being copied."));
        }
        self.stopImaging();
        self.copier = image.Copier.init(self.allocator, d.handle, d.origin, dest) catch {
            var h = dest;
            h.closeHandle();
            return;
        };
        self.copier_source = glib.idleAdd(onImageTick, self);
    }

    fn onDiskPickerDestroy(_: *gtk.Window, dlg: *DiskPicker) callconv(.c) void {
        disk_mod.freeInfos(dlg.editor.allocator, dlg.infos);
        dlg.editor.allocator.destroy(dlg);
    }

    // ---- process memory -----------------------------------------------------------------------

    /// Shows the memory region [start, end) of process `pid`, read-only.
    fn openProcessRegion(self: *HexEditor, pid: u32, name: []const u8, start: u64, end: u64) void {
        if (self.buffer.isModified()) {
            return common.dialogs.showError(self.window.as(gtk.Window), common.tr("Unsaved changes"), common.tr("Write or discard your changes before opening process memory."));
        }
        var pbuf: [64]u8 = undefined;
        const mem_path = std.fmt.bufPrintSentinel(&pbuf, "/proc/{d}/mem", .{pid}, 0) catch return;
        const handle = disk_mod.Handle.openMem(mem_path, end - start) catch |err| {
            if (err == error.AccessDenied) {
                return common.dialogs.showError(self.window.as(gtk.Window), common.tr("Cannot read this process"), common.tr("The system does not allow reading it. Processes of other users need dkde-hex started as administrator, and some systems (ptrace_scope) restrict even your own."));
            }
            return common.dialogs.showError(self.window.as(gtk.Window), common.tr("Cannot read this process"), common.tr("It may have exited."));
        };
        const label = std.fmt.allocPrintSentinel(self.allocator, "{s} (pid {d})", .{ name, pid }, 0) catch {
            var h = handle;
            h.closeHandle();
            return;
        };
        const key = std.fmt.allocPrintSentinel(self.allocator, "process:{s}:{X}", .{ name, start }, 0) catch {
            self.allocator.free(label);
            var h = handle;
            h.closeHandle();
            return;
        };
        self.closeDisk();
        self.disk = .{ .handle = handle, .path = key, .sector = 512, .origin = start, .process = label };
        self.view.fixed_size = true;
        self.view.insert_mode = false;
        self.view.offset_digits = 12;
        self.clearStructure();
        if (self.path) |p| self.allocator.free(p);
        self.path = null;
        self.loadWindow(0);
        self.loadBookmarks();
    }

    const ProcPicker = struct {
        editor: *HexEditor,
        window: *gtk.Window,
        list: *gtk.ListBox,
        title: *gtk.Label,
        back: *gtk.Button,
        procs: []disk_mod.Process,
        regions: []disk_mod.Region = &.{},
        /// The chosen process while regions are shown.
        chosen: ?usize = null,
    };

    fn chooseProcess(self: *HexEditor) void {
        const procs = disk_mod.listProcesses(self.allocator) catch return;
        const dlg = self.allocator.create(ProcPicker) catch {
            disk_mod.freeProcesses(self.allocator, procs);
            return;
        };
        const window = gtk.Window.new();
        window.setTitle(common.tr("Open process memory"));
        window.setTransientFor(self.window.as(gtk.Window));
        window.setModal(1);
        window.setDefaultSize(640, 460);
        window.as(gtk.Widget).addCssClass("dkde");
        const box = gtk.Box.new(.vertical, 8);
        box.as(gtk.Widget).setMarginTop(12);
        box.as(gtk.Widget).setMarginBottom(12);
        box.as(gtk.Widget).setMarginStart(12);
        box.as(gtk.Widget).setMarginEnd(12);
        window.setChild(box.as(gtk.Widget));
        const head = gtk.Box.new(.horizontal, 8);
        const back = gtk.Button.newWithLabel(common.tr("Back"));
        back.as(gtk.Widget).setVisible(0);
        const title = gtk.Label.new("");
        title.setXalign(0);
        title.setWrap(1);
        title.as(gtk.Widget).setHexpand(1);
        head.append(back.as(gtk.Widget));
        head.append(title.as(gtk.Widget));
        box.append(head.as(gtk.Widget));
        const list = gtk.ListBox.new();
        list.setActivateOnSingleClick(0);
        const scroller = gtk.ScrolledWindow.new();
        scroller.setChild(list.as(gtk.Widget));
        scroller.as(gtk.Widget).setVexpand(1);
        box.append(scroller.as(gtk.Widget));
        dlg.* = .{ .editor = self, .window = window, .list = list, .title = title, .back = back, .procs = procs };
        fillProcesses(dlg);
        _ = gtk.ListBox.signals.row_activated.connect(list, *ProcPicker, &onProcPicked, dlg, .{});
        _ = gtk.Button.signals.clicked.connect(back, *ProcPicker, &onProcBack, dlg, .{});
        _ = gtk.Widget.signals.destroy.connect(window, *ProcPicker, &onProcDestroy, dlg, .{});
        window.present();
    }

    fn addRow(list: *gtk.ListBox, text: [:0]const u8) void {
        const label = gtk.Label.new(text);
        label.setXalign(0);
        label.as(gtk.Widget).setMarginTop(3);
        label.as(gtk.Widget).setMarginBottom(3);
        label.as(gtk.Widget).setMarginStart(6);
        label.as(gtk.Widget).addCssClass("monospace");
        list.append(label.as(gtk.Widget));
    }

    fn clearRows(list: *gtk.ListBox) void {
        while (list.getRowAtIndex(0)) |row| list.remove(row.as(gtk.Widget));
    }

    fn fillProcesses(dlg: *ProcPicker) void {
        clearRows(dlg.list);
        dlg.chosen = null;
        dlg.back.as(gtk.Widget).setVisible(0);
        dlg.title.setText(common.tr("Double-click a process. Its memory opens read-only."));
        for (dlg.procs) |p| {
            var buf: [160]u8 = undefined;
            addRow(dlg.list, std.fmt.bufPrintSentinel(&buf, "{d: >8}   {s}", .{ p.pid, p.name }, 0) catch continue);
        }
    }

    fn fillRegions(dlg: *ProcPicker, index: usize) void {
        const p = dlg.procs[index];
        const regions = disk_mod.regionsOf(dlg.editor.allocator, p.pid) catch return;
        disk_mod.freeRegions(dlg.editor.allocator, dlg.regions);
        dlg.regions = regions;
        dlg.chosen = index;
        clearRows(dlg.list);
        dlg.back.as(gtk.Widget).setVisible(1);
        var tbuf: [160]u8 = undefined;
        dlg.title.setText(if (regions.len == 0)
            std.fmt.bufPrintSentinel(&tbuf, "{s} (pid {d}): no readable regions. It belongs to another user (start dkde-hex as administrator) or has exited.", .{ p.name, p.pid }, 0) catch ""
        else
            std.fmt.bufPrintSentinel(&tbuf, "{s} (pid {d}): {d} readable regions. Double-click one.", .{ p.name, p.pid, regions.len }, 0) catch "");
        for (regions) |r| {
            var buf: [400]u8 = undefined;
            addRow(dlg.list, std.fmt.bufPrintSentinel(&buf, "{X:0>12}-{X:0>12}  {s}  {d: >10} KiB  {s}", .{ r.start, r.end, r.perms, (r.end - r.start) / 1024, r.name }, 0) catch continue);
        }
    }

    fn onProcPicked(_: *gtk.ListBox, row: *gtk.ListBoxRow, dlg: *ProcPicker) callconv(.c) void {
        const i = row.getIndex();
        if (i < 0) return;
        const idx: usize = @intCast(i);
        if (dlg.chosen) |c| {
            if (idx >= dlg.regions.len) return;
            const r = dlg.regions[idx];
            const p = dlg.procs[c];
            const editor = dlg.editor;
            const name = editor.allocator.dupe(u8, p.name) catch return;
            defer editor.allocator.free(name);
            const pid = p.pid;
            dlg.window.destroy();
            return editor.host.tabFor(editor).openProcessRegion(pid, name, r.start, r.end);
        }
        if (idx < dlg.procs.len) fillRegions(dlg, idx);
    }

    fn onProcBack(_: *gtk.Button, dlg: *ProcPicker) callconv(.c) void {
        fillProcesses(dlg);
    }

    fn onProcDestroy(_: *gtk.Window, dlg: *ProcPicker) callconv(.c) void {
        const a = dlg.editor.allocator;
        disk_mod.freeProcesses(a, dlg.procs);
        disk_mod.freeRegions(a, dlg.regions);
        a.destroy(dlg);
    }

    // ---- reverse-engineering tools -------------------------------------------------------------

    /// The selected bytes, or the whole buffer when nothing is selected.
    fn selectedOrAll(self: *HexEditor) []const u8 {
        const all = self.buffer.slice();
        if (self.view.selection()) |s| return all[s[0]..@min(s[1], all.len)];
        return all;
    }

    /// A read-only text window with a Copy button.
    fn showText(self: *HexEditor, title: [:0]const u8, text: []const u8) void {
        const z = self.allocator.dupeSentinel(u8, text, 0) catch return;
        defer self.allocator.free(z);
        const window = gtk.Window.new();
        window.setTitle(title);
        window.setTransientFor(self.window.as(gtk.Window));
        window.setDefaultSize(640, 420);
        window.as(gtk.Widget).addCssClass("dkde");
        const box = gtk.Box.new(.vertical, 8);
        box.as(gtk.Widget).setMarginTop(12);
        box.as(gtk.Widget).setMarginBottom(12);
        box.as(gtk.Widget).setMarginStart(12);
        box.as(gtk.Widget).setMarginEnd(12);
        window.setChild(box.as(gtk.Widget));
        const label = gtk.Label.new(z);
        label.setSelectable(1);
        label.setXalign(0);
        label.setYalign(0);
        label.as(gtk.Widget).addCssClass("monospace");
        const scroller = gtk.ScrolledWindow.new();
        scroller.setChild(label.as(gtk.Widget));
        scroller.as(gtk.Widget).setVexpand(1);
        box.append(scroller.as(gtk.Widget));
        const copy = gtk.Button.newWithLabel(common.tr("Copy"));
        copy.as(gtk.Widget).setHalign(.end);
        box.append(copy.as(gtk.Widget));
        const ctx = self.allocator.create(TextWindow) catch return;
        ctx.* = .{ .editor = self, .text = self.allocator.dupeSentinel(u8, text, 0) catch {
            self.allocator.destroy(ctx);
            return;
        } };
        _ = gtk.Button.signals.clicked.connect(copy, *TextWindow, &onTextCopy, ctx, .{});
        _ = gtk.Widget.signals.destroy.connect(window, *TextWindow, &onTextDestroy, ctx, .{});
        window.present();
    }

    const TextWindow = struct { editor: *HexEditor, text: [:0]u8 };

    fn onTextCopy(_: *gtk.Button, ctx: *TextWindow) callconv(.c) void {
        ctx.editor.window.as(gtk.Widget).getClipboard().setText(ctx.text);
    }

    fn onTextDestroy(_: *gtk.Window, ctx: *TextWindow) callconv(.c) void {
        ctx.editor.allocator.free(ctx.text);
        ctx.editor.allocator.destroy(ctx);
    }

    // Checksums.

    fn showChecksums(self: *HexEditor) void {
        const data = self.selectedOrAll();
        const s = analyze.sums(data);
        var buf: [600]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{s} ({d} bytes)\n\nMD5     {s}\nSHA-1   {s}\nSHA-256 {s}\nCRC-32  {s}\n", .{
            if (self.view.selection() != null) "Selection" else "Whole file",
            data.len,
            s.md5,
            s.sha1,
            s.sha256,
            s.crc32,
        }) catch return;
        self.showText(common.tr("Checksums"), text);
    }

    // Entropy and histogram.

    const GraphCtx = struct {
        editor: *HexEditor,
        window: *gtk.Window,
        area: *gtk.DrawingArea,
        values: []f64,
        block: usize,
        histogram: [256]u64,
        max_count: u64,
    };

    fn showEntropy(self: *HexEditor) void {
        const data = self.buffer.slice();
        if (data.len == 0) return;
        const map = analyze.entropyMap(self.allocator, data, 640) catch return;
        const ctx = self.allocator.create(GraphCtx) catch {
            self.allocator.free(map.values);
            return;
        };
        const window = gtk.Window.new();
        window.setTitle(common.tr("Entropy and byte histogram"));
        window.setTransientFor(self.window.as(gtk.Window));
        window.setDefaultSize(720, 460);
        window.as(gtk.Widget).addCssClass("dkde");
        const box = gtk.Box.new(.vertical, 6);
        box.as(gtk.Widget).setMarginTop(12);
        box.as(gtk.Widget).setMarginBottom(12);
        box.as(gtk.Widget).setMarginStart(12);
        box.as(gtk.Widget).setMarginEnd(12);
        window.setChild(box.as(gtk.Widget));
        var nb: [200]u8 = undefined;
        const note = gtk.Label.new(std.fmt.bufPrintSentinel(&nb, "Top: entropy per {d}-byte block (0 to 8 bits per byte; near 8 is compressed or encrypted). Click to go there. Bottom: how often each byte value occurs.", .{map.block}, 0) catch "");
        note.setWrap(1);
        note.setXalign(0);
        note.as(gtk.Widget).addCssClass("dim-label");
        box.append(note.as(gtk.Widget));
        const area = gtk.DrawingArea.new();
        area.as(gtk.Widget).setVexpand(1);
        area.as(gtk.Widget).setHexpand(1);
        box.append(area.as(gtk.Widget));
        const hist = analyze.histogram(data);
        var max_count: u64 = 1;
        for (hist) |c| max_count = @max(max_count, c);
        ctx.* = .{ .editor = self, .window = window, .area = area, .values = map.values, .block = map.block, .histogram = hist, .max_count = max_count };
        area.setDrawFunc(onGraphDraw, ctx, null);
        const click = gtk.GestureClick.new();
        _ = gtk.GestureClick.signals.pressed.connect(click, *GraphCtx, &onGraphClick, ctx, .{});
        area.as(gtk.Widget).addController(click.as(gtk.EventController));
        _ = gtk.Widget.signals.destroy.connect(window, *GraphCtx, &onGraphDestroy, ctx, .{});
        window.present();
    }

    fn onGraphDraw(_: *gtk.DrawingArea, cr: *cairo.Context, width: c_int, height: c_int, data: ?*anyopaque) callconv(.c) void {
        const ctx: *GraphCtx = @ptrCast(@alignCast(data.?));
        const w: f64 = @floatFromInt(width);
        const h: f64 = @floatFromInt(height);
        const accent = common.style.accentOf(ctx.editor.view.probe);
        const split = h * 0.58;
        // Entropy.
        cr.setSourceRgba(0.5, 0.5, 0.5, 0.15);
        cr.rectangle(0, 0, w, split - 6);
        cr.fill();
        const n: f64 = @floatFromInt(ctx.values.len);
        cr.setSourceRgba(accent.f_red, accent.f_green, accent.f_blue, 0.9);
        for (ctx.values, 0..) |v, i| {
            const x = @as(f64, @floatFromInt(i)) / n * w;
            const bh = v / 8.0 * (split - 6);
            cr.rectangle(x, split - 6 - bh, @max(1.0, w / n), bh);
            cr.fill();
        }
        // Histogram.
        const top = split + 6;
        const bar_w = w / 256.0;
        for (ctx.histogram, 0..) |c, i| {
            const bh = @as(f64, @floatFromInt(c)) / @as(f64, @floatFromInt(ctx.max_count)) * (h - top);
            cr.setSourceRgba(0.35, 0.6, 0.9, 0.9);
            cr.rectangle(@as(f64, @floatFromInt(i)) * bar_w, h - bh, @max(1.0, bar_w - 0.5), bh);
            cr.fill();
        }
    }

    fn onGraphClick(_: *gtk.GestureClick, _: c_int, x: f64, y: f64, ctx: *GraphCtx) callconv(.c) void {
        const w: f64 = @floatFromInt(ctx.area.as(gtk.Widget).getWidth());
        const h: f64 = @floatFromInt(ctx.area.as(gtk.Widget).getHeight());
        if (y > h * 0.58 or w <= 0) return;
        const index: usize = @intFromFloat(@min(x / w * @as(f64, @floatFromInt(ctx.values.len)), @as(f64, @floatFromInt(ctx.values.len - 1))));
        ctx.editor.pushBack();
        ctx.editor.view.moveTo(index * ctx.block, false);
    }

    fn onGraphDestroy(_: *gtk.Window, ctx: *GraphCtx) callconv(.c) void {
        ctx.editor.allocator.free(ctx.values);
        ctx.editor.allocator.destroy(ctx);
    }

    // Comparing with another file.

    fn compareDialog(self: *HexEditor) void {
        const dialog = gtk.FileDialog.new();
        defer dialog.as(gobject.Object).unref();
        dialog.setTitle(common.tr("Compare with"));
        dialog.open(self.window.as(gtk.Window), null, onCompareChosen, self);
    }

    fn onCompareChosen(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
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
        var contents: [*]u8 = undefined;
        var length: usize = 0;
        if (glib.fileGetContents(path, &contents, &length, &err) == 0) {
            if (err) |e| e.free();
            return;
        }
        defer glib.free(contents);
        if (length > 256 << 20) return self.status.setText(common.tr("That file is too large to compare."));
        if (self.other) |o| self.allocator.free(o);
        self.other = self.allocator.dupe(u8, contents[0..length]) catch return;
        self.recompare();
        self.nextDifference(true);
    }

    /// Recomputes the differences against the other file.
    fn recompare(self: *HexEditor) void {
        self.allocator.free(self.diff_view);
        self.diff_view = &.{};
        self.allocator.free(self.diffs);
        self.diffs = &.{};
        const other = self.other orelse return self.view.setOverlay(&.{});
        const diffs = analyze.compare(self.allocator, self.buffer.slice(), other, 2) catch return;
        self.diffs = diffs;
        const ranges = self.allocator.alloc(view_mod.Range, diffs.len) catch return;
        for (diffs, ranges) |d, *r| r.* = .{ .start = d.start, .len = d.len, .color = 0 };
        self.diff_view = ranges;
        self.view.setOverlay(ranges);
        self.compared_revision = self.buffer.revision;
        var buf: [96]u8 = undefined;
        self.status.setText(std.fmt.bufPrintSentinel(&buf, "{d} difference{s} (F7 next, Shift+F7 previous)", .{ diffs.len, if (diffs.len == 1) "" else "s" }, 0) catch "");
    }

    fn nextDifference(self: *HexEditor, forward: bool) void {
        if (self.other == null) return self.compareDialog();
        if (self.compared_revision != self.buffer.revision) self.recompare();
        if (self.diffs.len == 0) return self.status.setText(common.tr("The files are identical."));
        const at = if (self.view.selection()) |s| s[0] else self.view.cursor;
        var pick: ?analyze.Diff = null;
        if (forward) {
            for (self.diffs) |d| if (d.start > at) {
                pick = d;
                break;
            };
            if (pick == null) pick = self.diffs[0];
        } else {
            var i = self.diffs.len;
            while (i > 0) {
                i -= 1;
                if (self.diffs[i].start < at) {
                    pick = self.diffs[i];
                    break;
                }
            }
            if (pick == null) pick = self.diffs[self.diffs.len - 1];
        }
        const d = pick.?;
        self.view.select(d.start, @min(d.len, self.buffer.len() - d.start));
    }

    fn clearComparison(self: *HexEditor) void {
        if (self.other) |o| self.allocator.free(o);
        self.other = null;
        self.recompare();
    }

    // Copy as, transforms, following values.

    fn copyAsKind(self: *HexEditor, kind: analyze.CopyAs) void {
        const bytes = self.selectedOrAll();
        if (bytes.len == 0) return;
        const text = analyze.copyAs(self.allocator, bytes, kind) catch return;
        defer self.allocator.free(text);
        const z = self.allocator.dupeSentinel(u8, text, 0) catch return;
        defer self.allocator.free(z);
        self.window.as(gtk.Widget).getClipboard().setText(z);
        self.status.setText(common.tr("Copied."));
    }

    /// Replaces the selection with `new` (same length).
    fn replaceSelection(self: *HexEditor, new: []const u8) void {
        const s = self.view.selection() orelse return;
        self.buffer.replace(s[0], s[1] - s[0], new, false) catch return;
        self.view.refresh();
        self.view.select(s[0], s[1] - s[0]);
    }

    const Transform = enum { reverse, swap2, swap4, swap8 };

    fn transformSelection(self: *HexEditor, t: Transform) void {
        const s = self.view.selection() orelse return self.status.setText(common.tr("Select some bytes first."));
        const copy = self.allocator.dupe(u8, self.buffer.slice()[s[0]..s[1]]) catch return;
        defer self.allocator.free(copy);
        switch (t) {
            .reverse => analyze.reverse(copy),
            .swap2 => analyze.swapUnits(copy, 2),
            .swap4 => analyze.swapUnits(copy, 4),
            .swap8 => analyze.swapUnits(copy, 8),
        }
        self.replaceSelection(copy);
    }

    const FillKind = enum { fill, xor };

    fn fillDialog(self: *HexEditor, kind: FillKind) void {
        if (self.view.selection() == null) return self.status.setText(common.tr("Select some bytes first."));
        const dlg = self.allocator.create(FillCtx) catch return;
        const window = gtk.Window.new();
        window.setTitle(if (kind == .fill) common.tr("Fill selection") else common.tr("XOR selection"));
        window.setTransientFor(self.window.as(gtk.Window));
        window.setModal(1);
        window.setDefaultSize(380, -1);
        window.as(gtk.Widget).addCssClass("dkde");
        const box = gtk.Box.new(.vertical, 8);
        box.as(gtk.Widget).setMarginTop(16);
        box.as(gtk.Widget).setMarginBottom(16);
        box.as(gtk.Widget).setMarginStart(16);
        box.as(gtk.Widget).setMarginEnd(16);
        window.setChild(box.as(gtk.Widget));
        const label = gtk.Label.new(if (kind == .fill) common.tr("Bytes to repeat, in hex (for example 00 or de ad):") else common.tr("Key bytes in hex; they repeat over the selection (for example 5a or de ad be ef):"));
        label.setWrap(1);
        label.setXalign(0);
        box.append(label.as(gtk.Widget));
        const entry = gtk.Entry.new();
        entry.as(gtk.Editable).setText("00");
        box.append(entry.as(gtk.Widget));
        const buttons = gtk.Box.new(.horizontal, 8);
        buttons.as(gtk.Widget).setHalign(.end);
        const cancel = gtk.Button.newWithLabel(common.tr("Cancel"));
        const ok = gtk.Button.newWithLabel(common.tr("Apply"));
        ok.as(gtk.Widget).addCssClass("suggested-action");
        buttons.append(cancel.as(gtk.Widget));
        buttons.append(ok.as(gtk.Widget));
        box.append(buttons.as(gtk.Widget));
        dlg.* = .{ .editor = self, .window = window, .entry = entry, .kind = kind };
        _ = gtk.Button.signals.clicked.connect(cancel, *FillCtx, &onFillCancel, dlg, .{});
        _ = gtk.Button.signals.clicked.connect(ok, *FillCtx, &onFillOk, dlg, .{});
        _ = gtk.Widget.signals.destroy.connect(window, *FillCtx, &onFillDestroy, dlg, .{});
        window.present();
    }

    const FillCtx = struct { editor: *HexEditor, window: *gtk.Window, entry: *gtk.Entry, kind: FillKind };

    fn onFillCancel(_: *gtk.Button, ctx: *FillCtx) callconv(.c) void {
        ctx.window.destroy();
    }

    fn onFillDestroy(_: *gtk.Window, ctx: *FillCtx) callconv(.c) void {
        ctx.editor.allocator.destroy(ctx);
    }

    fn onFillOk(_: *gtk.Button, ctx: *FillCtx) callconv(.c) void {
        const self = ctx.editor;
        defer ctx.window.destroy();
        const key = (buffer_mod.parseHex(self.allocator, std.mem.span(ctx.entry.as(gtk.Editable).getText())) catch null) orelse return;
        defer self.allocator.free(key);
        if (key.len == 0) return;
        const s = self.view.selection() orelse return;
        const copy = self.allocator.dupe(u8, self.buffer.slice()[s[0]..s[1]]) catch return;
        defer self.allocator.free(copy);
        if (ctx.kind == .fill) {
            for (copy, 0..) |*b, i| b.* = key[i % key.len];
        } else analyze.xorWith(copy, key);
        self.replaceSelection(copy);
    }

    // Following a value as an offset, and going back.

    fn pushBack(self: *HexEditor) void {
        self.back_stack.append(self.allocator, self.view.cursor) catch return;
        if (self.back_stack.items.len > 64) _ = self.back_stack.orderedRemove(0);
    }

    fn goBack(self: *HexEditor) void {
        const at = self.back_stack.pop() orelse return;
        self.view.moveTo(at, false);
    }

    /// Reads the number at the cursor (4 bytes, or 8 if the selection is 8) in
    /// the inspector's byte order and jumps to that offset.
    fn followValue(self: *HexEditor) void {
        const bytes = self.buffer.slice();
        const at = if (self.view.selection()) |s| s[0] else self.view.cursor;
        var width: usize = 4;
        if (self.view.selection()) |s| if (s[1] - s[0] == 8 or s[1] - s[0] == 2) {
            width = s[1] - s[0];
        };
        if (at + width > bytes.len) return self.status.setText(common.tr("Not enough bytes here."));
        var v: u64 = 0;
        for (0..width) |i| {
            const b: u64 = if (self.endian == .little) bytes[at + width - 1 - i] else bytes[at + i];
            v = (v << 8) | b;
        }
        const target: u64 = v;
        if (self.disk != null) {
            self.pushBack();
            return self.diskGoto(target);
        }
        if (target >= bytes.len) {
            var buf: [96]u8 = undefined;
            return self.status.setText(std.fmt.bufPrintSentinel(&buf, "0x{X} is past the end of the file.", .{target}, 0) catch "");
        }
        self.pushBack();
        self.view.moveTo(@intCast(target), false);
    }

    // Disassembly through objdump, when it is installed.

    const arches = [_][:0]const u8{ "i386:x86-64", "i386", "arm", "aarch64", "mips", "riscv:rv64", "powerpc" };

    fn disassembleDialog(self: *HexEditor) void {
        if (!common.proc.hasProgram("objdump")) return common.dialogs.showError(self.window.as(gtk.Window), common.tr("objdump is not installed"), common.tr("Install binutils (objdump) to disassemble. For other processors, binutils-multiarch."));
        if (self.view.selection() == null) return self.status.setText(common.tr("Select the bytes to disassemble first."));
        const dlg = self.allocator.create(DisasmCtx) catch return;
        const window = gtk.Window.new();
        window.setTitle(common.tr("Disassemble selection"));
        window.setTransientFor(self.window.as(gtk.Window));
        window.setModal(1);
        window.setDefaultSize(360, -1);
        window.as(gtk.Widget).addCssClass("dkde");
        const box = gtk.Box.new(.vertical, 8);
        box.as(gtk.Widget).setMarginTop(16);
        box.as(gtk.Widget).setMarginBottom(16);
        box.as(gtk.Widget).setMarginStart(16);
        box.as(gtk.Widget).setMarginEnd(16);
        window.setChild(box.as(gtk.Widget));
        box.append(gtk.Label.new(common.tr("Processor")).as(gtk.Widget));
        var names: [arches.len + 1]?[*:0]const u8 = @splat(null);
        for (arches, 0..) |a, i| names[i] = a.ptr;
        const dd = gtk.DropDown.newFromStrings(@ptrCast(&names));
        box.append(dd.as(gtk.Widget));
        const buttons = gtk.Box.new(.horizontal, 8);
        buttons.as(gtk.Widget).setHalign(.end);
        const cancel = gtk.Button.newWithLabel(common.tr("Cancel"));
        const ok = gtk.Button.newWithLabel(common.tr("Disassemble"));
        ok.as(gtk.Widget).addCssClass("suggested-action");
        buttons.append(cancel.as(gtk.Widget));
        buttons.append(ok.as(gtk.Widget));
        box.append(buttons.as(gtk.Widget));
        dlg.* = .{ .editor = self, .window = window, .dropdown = dd };
        _ = gtk.Button.signals.clicked.connect(cancel, *DisasmCtx, &onDisasmCancel, dlg, .{});
        _ = gtk.Button.signals.clicked.connect(ok, *DisasmCtx, &onDisasmOk, dlg, .{});
        _ = gtk.Widget.signals.destroy.connect(window, *DisasmCtx, &onDisasmDestroy, dlg, .{});
        window.present();
    }

    const DisasmCtx = struct { editor: *HexEditor, window: *gtk.Window, dropdown: *gtk.DropDown };

    fn onDisasmCancel(_: *gtk.Button, ctx: *DisasmCtx) callconv(.c) void {
        ctx.window.destroy();
    }

    fn onDisasmDestroy(_: *gtk.Window, ctx: *DisasmCtx) callconv(.c) void {
        ctx.editor.allocator.destroy(ctx);
    }

    fn onDisasmOk(_: *gtk.Button, ctx: *DisasmCtx) callconv(.c) void {
        const self = ctx.editor;
        defer ctx.window.destroy();
        const s = self.view.selection() orelse return;
        const idx: usize = @intCast(ctx.dropdown.getSelected());
        if (idx >= arches.len) return;
        // objdump reads a file: write the bytes to a temporary one.
        const tmp_dir = glib.Dir.makeTmp("dkde-hex-XXXXXX", null) orelse return;
        defer glib.free(tmp_dir);
        const path = std.fmt.allocPrintSentinel(self.allocator, "{s}/code.bin", .{std.mem.span(tmp_dir)}, 0) catch return;
        defer self.allocator.free(path);
        const bytes = self.buffer.slice()[s[0]..s[1]];
        if (glib.fileSetContents(path, bytes.ptr, @intCast(bytes.len), null) == 0) return;
        const base = s[0] + @as(usize, @intCast(self.diskBase()));
        const vma = std.fmt.allocPrint(self.allocator, "--adjust-vma=0x{X}", .{base}) catch return;
        defer self.allocator.free(vma);
        if (self.disasm_dir) |old| self.allocator.free(old);
        self.disasm_dir = self.allocator.dupe(u8, std.mem.span(tmp_dir)) catch null;
        common.proc.run(HexEditor, self.proc_guard, &.{ "objdump", "-D", "-b", "binary", "-m", arches[idx], vma, path }, onDisasmDone);
    }

    fn onDisasmDone(self: *HexEditor, ok: bool, out: []const u8) void {
        if (self.disasm_dir) |dir| {
            // Remove the temporary file and folder.
            const file = std.fmt.allocPrintSentinel(self.allocator, "{s}/code.bin", .{dir}, 0) catch null;
            if (file) |f| {
                _ = std.c.unlink(f);
                self.allocator.free(f);
            }
            const dz = self.allocator.dupeSentinel(u8, dir, 0) catch null;
            if (dz) |d| {
                _ = std.c.rmdir(d);
                self.allocator.free(d);
            }
            self.allocator.free(dir);
            self.disasm_dir = null;
        }
        if (!ok) return common.dialogs.showError(self.window.as(gtk.Window), common.tr("Disassembly failed"), common.tr("objdump could not read this as code for that processor."));
        self.showText(common.tr("Disassembly"), out);
    }

    // Bookmarks.

    fn bookmarkFile(self: *HexEditor) ?[:0]u8 {
        const key_path: []const u8 = if (self.disk) |d| d.path else (self.path orelse return null);
        var kb: [32]u8 = undefined;
        const key = bookmarks_mod.fileKey(&kb, key_path);
        var rel: [64]u8 = undefined;
        const rel_path = std.fmt.bufPrint(&rel, "hex-bookmarks/{s}", .{key}) catch return null;
        return common.paths.userStateFile(self.allocator, rel_path) catch null;
    }

    fn loadBookmarks(self: *HexEditor) void {
        self.bookmarks.deinit(self.allocator);
        self.bookmarks = .{};
        if (self.bookmarkFile()) |path| {
            defer self.allocator.free(path);
            var contents: [*]u8 = undefined;
            var length: usize = 0;
            if (glib.fileGetContents(path, &contents, &length, null) != 0) {
                defer glib.free(contents);
                if (bookmarks_mod.fromJson(self.allocator, contents[0..length])) |l| self.bookmarks = l else |_| {}
            }
        }
        self.refreshMarks();
    }

    /// Written only when a bookmark is added, edited or removed.
    fn saveBookmarks(self: *HexEditor) void {
        const path = self.bookmarkFile() orelse return;
        defer self.allocator.free(path);
        const dir = glib.pathGetDirname(path);
        defer glib.free(dir);
        _ = glib.mkdirWithParents(dir, 0o755);
        if (self.bookmarks.items.items.len == 0) {
            _ = std.c.unlink(path);
            return;
        }
        const json = bookmarks_mod.toJson(self.allocator, &self.bookmarks) catch return;
        defer self.allocator.free(json);
        _ = glib.fileSetContents(path, json.ptr, @intCast(json.len), null);
    }

    fn refreshMarks(self: *HexEditor) void {
        self.allocator.free(self.mark_view);
        self.mark_view = &.{};
        const base: u64 = self.diskBase();
        var list: std.ArrayList(view_mod.Range) = .empty;
        for (self.bookmarks.items.items) |b| {
            if (b.start + b.len <= base or b.start >= base + self.buffer.len()) continue;
            const start = if (b.start > base) b.start - base else 0;
            list.append(self.allocator, .{ .start = @intCast(start), .len = @intCast(@max(b.len, 1)), .color = 0 }) catch {};
        }
        self.mark_view = list.toOwnedSlice(self.allocator) catch &.{};
        self.view.setMarks(self.mark_view);
    }

    const BookmarkDlg = struct {
        editor: *HexEditor,
        window: *gtk.Window,
        name: *gtk.Entry,
        comment: *gtk.Entry,
        start: u64,
        len: u64,
        /// Index being edited, else a new bookmark.
        edit: ?usize,
    };

    fn bookmarkDialog(self: *HexEditor, edit: ?usize) void {
        const base: u64 = self.diskBase();
        var start: u64 = base + self.view.cursor;
        var len: u64 = 1;
        if (self.view.selection()) |s| {
            start = base + s[0];
            len = s[1] - s[0];
        }
        var name_text: []const u8 = "";
        var comment_text: []const u8 = "";
        if (edit) |i| {
            const b = self.bookmarks.items.items[i];
            start = b.start;
            len = b.len;
            name_text = b.name;
            comment_text = b.comment;
        } else if (self.bookmarks.at(start)) |i| return self.bookmarkDialog(i);
        const dlg = self.allocator.create(BookmarkDlg) catch return;
        const window = gtk.Window.new();
        window.setTitle(common.tr("Bookmark"));
        window.setTransientFor(self.window.as(gtk.Window));
        window.setModal(1);
        window.setDefaultSize(400, -1);
        window.as(gtk.Widget).addCssClass("dkde");
        const box = gtk.Box.new(.vertical, 8);
        box.as(gtk.Widget).setMarginTop(16);
        box.as(gtk.Widget).setMarginBottom(16);
        box.as(gtk.Widget).setMarginStart(16);
        box.as(gtk.Widget).setMarginEnd(16);
        window.setChild(box.as(gtk.Widget));
        var rb: [96]u8 = undefined;
        const range = gtk.Label.new(std.fmt.bufPrintSentinel(&rb, "0x{X}, {d} byte{s}", .{ start, len, if (len == 1) "" else "s" }, 0) catch "");
        range.setXalign(0);
        box.append(range.as(gtk.Widget));
        const name = gtk.Entry.new();
        name.setPlaceholderText(common.tr("Name"));
        if (self.allocator.dupeSentinel(u8, name_text, 0)) |z| {
            defer self.allocator.free(z);
            name.as(gtk.Editable).setText(z);
        } else |_| {}
        box.append(name.as(gtk.Widget));
        const comment = gtk.Entry.new();
        comment.setPlaceholderText(common.tr("Comment (optional)"));
        if (self.allocator.dupeSentinel(u8, comment_text, 0)) |z| {
            defer self.allocator.free(z);
            comment.as(gtk.Editable).setText(z);
        } else |_| {}
        box.append(comment.as(gtk.Widget));
        const buttons = gtk.Box.new(.horizontal, 8);
        buttons.as(gtk.Widget).setHalign(.end);
        const cancel = gtk.Button.newWithLabel(common.tr("Cancel"));
        const ok = gtk.Button.newWithLabel(common.tr("Save"));
        ok.as(gtk.Widget).addCssClass("suggested-action");
        buttons.append(cancel.as(gtk.Widget));
        buttons.append(ok.as(gtk.Widget));
        box.append(buttons.as(gtk.Widget));
        dlg.* = .{ .editor = self, .window = window, .name = name, .comment = comment, .start = start, .len = len, .edit = edit };
        _ = gtk.Button.signals.clicked.connect(cancel, *BookmarkDlg, &onBookmarkCancel, dlg, .{});
        _ = gtk.Button.signals.clicked.connect(ok, *BookmarkDlg, &onBookmarkOk, dlg, .{});
        _ = gtk.Widget.signals.destroy.connect(window, *BookmarkDlg, &onBookmarkDestroy, dlg, .{});
        window.present();
    }

    fn onBookmarkCancel(_: *gtk.Button, ctx: *BookmarkDlg) callconv(.c) void {
        ctx.window.destroy();
    }

    fn onBookmarkDestroy(_: *gtk.Window, ctx: *BookmarkDlg) callconv(.c) void {
        ctx.editor.allocator.destroy(ctx);
    }

    fn onBookmarkOk(_: *gtk.Button, ctx: *BookmarkDlg) callconv(.c) void {
        const self = ctx.editor;
        defer ctx.window.destroy();
        const name = std.mem.span(ctx.name.as(gtk.Editable).getText());
        const comment = std.mem.span(ctx.comment.as(gtk.Editable).getText());
        var fallback: [32]u8 = undefined;
        const shown = if (name.len > 0) name else (std.fmt.bufPrint(&fallback, "0x{X}", .{ctx.start}) catch "bookmark");
        if (ctx.edit) |i| {
            self.bookmarks.edit(self.allocator, i, shown, comment) catch return;
        } else self.bookmarks.add(self.allocator, ctx.start, ctx.len, shown, comment) catch return;
        self.saveBookmarks();
        self.refreshMarks();
    }

    const BookmarkList = struct {
        editor: *HexEditor,
        window: *gtk.Window,
        list: *gtk.ListBox,

        fn fill(self: *BookmarkList) void {
            self.list.removeAll();
            for (self.editor.bookmarks.items.items) |b| {
                var buf: [400]u8 = undefined;
                const text = std.fmt.bufPrintSentinel(&buf, "0x{X:0>8}  {d:>6} B   {s}{s}{s}", .{ b.start, b.len, b.name, if (b.comment.len > 0) "  \u{2014}  " else "", b.comment }, 0) catch continue;
                const label = gtk.Label.new(text);
                label.setXalign(0);
                label.setEllipsize(.end);
                label.as(gtk.Widget).addCssClass("monospace");
                label.as(gtk.Widget).setMarginTop(4);
                label.as(gtk.Widget).setMarginBottom(4);
                label.as(gtk.Widget).setMarginStart(6);
                self.list.append(label.as(gtk.Widget));
            }
        }
    };

    fn showBookmarks(self: *HexEditor) void {
        const dlg = self.allocator.create(BookmarkList) catch return;
        const window = gtk.Window.new();
        window.setTitle(common.tr("Bookmarks"));
        window.setTransientFor(self.window.as(gtk.Window));
        window.setDefaultSize(520, 400);
        window.as(gtk.Widget).addCssClass("dkde");
        const box = gtk.Box.new(.vertical, 8);
        box.as(gtk.Widget).setMarginTop(12);
        box.as(gtk.Widget).setMarginBottom(12);
        box.as(gtk.Widget).setMarginStart(12);
        box.as(gtk.Widget).setMarginEnd(12);
        window.setChild(box.as(gtk.Widget));
        const list = gtk.ListBox.new();
        list.setActivateOnSingleClick(0);
        const scroller = gtk.ScrolledWindow.new();
        scroller.setChild(list.as(gtk.Widget));
        scroller.as(gtk.Widget).setVexpand(1);
        box.append(scroller.as(gtk.Widget));
        const buttons = gtk.Box.new(.horizontal, 8);
        buttons.as(gtk.Widget).setHalign(.end);
        const edit = gtk.Button.newWithLabel(common.tr("Edit\u{2026}"));
        const del = gtk.Button.newWithLabel(common.tr("Delete"));
        buttons.append(edit.as(gtk.Widget));
        buttons.append(del.as(gtk.Widget));
        box.append(buttons.as(gtk.Widget));
        dlg.* = .{ .editor = self, .window = window, .list = list };
        dlg.fill();
        _ = gtk.ListBox.signals.row_activated.connect(list, *BookmarkList, &onBookmarkJump, dlg, .{});
        _ = gtk.Button.signals.clicked.connect(edit, *BookmarkList, &onBookmarkEdit, dlg, .{});
        _ = gtk.Button.signals.clicked.connect(del, *BookmarkList, &onBookmarkDelete, dlg, .{});
        _ = gtk.Widget.signals.destroy.connect(window, *BookmarkList, &onBookmarkListDestroy, dlg, .{});
        window.present();
    }

    fn onBookmarkListDestroy(_: *gtk.Window, ctx: *BookmarkList) callconv(.c) void {
        ctx.editor.allocator.destroy(ctx);
    }

    fn onBookmarkJump(_: *gtk.ListBox, row: *gtk.ListBoxRow, ctx: *BookmarkList) callconv(.c) void {
        const i: usize = @intCast(row.getIndex());
        const items = ctx.editor.bookmarks.items.items;
        if (i >= items.len) return;
        const b = items[i];
        ctx.editor.pushBack();
        if (ctx.editor.disk != null) {
            ctx.editor.diskGoto(b.start);
        } else ctx.editor.view.select(@intCast(b.start), @intCast(@max(b.len, 1)));
    }

    fn onBookmarkEdit(_: *gtk.Button, ctx: *BookmarkList) callconv(.c) void {
        const row = ctx.list.getSelectedRow() orelse return;
        ctx.editor.bookmarkDialog(@intCast(row.getIndex()));
        ctx.window.destroy();
    }

    fn onBookmarkDelete(_: *gtk.Button, ctx: *BookmarkList) callconv(.c) void {
        const row = ctx.list.getSelectedRow() orelse return;
        const i: usize = @intCast(row.getIndex());
        if (i >= ctx.editor.bookmarks.items.items.len) return;
        ctx.editor.bookmarks.remove(ctx.editor.allocator, i);
        ctx.editor.saveBookmarks();
        ctx.editor.refreshMarks();
        ctx.fill();
    }

    // ---- menu --------------------------------------------------------------------------------

    fn onMenubarAction(self: *HexEditor, action: []const u8) void {
        const eql = std.mem.eql;
        if (eql(u8, action, "save")) return self.save();
        if (eql(u8, action, "save-as")) return self.saveAsDialog();
        if (eql(u8, action, "revert")) return if (self.path != null) self.confirmDiscard(.revert);
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
        if (eql(u8, action, "open-process")) return self.chooseProcess();
        if (eql(u8, action, "goto-sector")) return self.ask(.sector);
        if (eql(u8, action, "disk-prev")) return self.diskStep(false);
        if (eql(u8, action, "disk-next")) return self.diskStep(true);
        if (eql(u8, action, "disk-writing")) return self.enableWriting();
        if (eql(u8, action, "disk-write")) return self.diskWrite();
        if (eql(u8, action, "disk-image")) return self.imageDialog();
        if (eql(u8, action, "disk-clone")) return self.chooseCloneTarget();
        if (eql(u8, action, "disk-image-cancel")) {
            if (self.copier == null) return;
            self.stopImaging();
            return self.status.setText(common.tr("Copy cancelled. What was already written stays; a half-cloned disk is not usable."));
        }
        if (eql(u8, action, "disk-close")) {
            self.closeDisk();
            self.buffer.load("") catch return;
            self.view.refresh();
            return self.updateAll();
        }
        if (eql(u8, action, "strings")) return self.showStrings();
        if (eql(u8, action, "copy-c")) return self.copyAsKind(.c_array);
        if (eql(u8, action, "copy-py")) return self.copyAsKind(.python);
        if (eql(u8, action, "copy-b64")) return self.copyAsKind(.base64);
        if (eql(u8, action, "copy-esc")) return self.copyAsKind(.escaped);
        if (eql(u8, action, "fill")) return self.fillDialog(.fill);
        if (eql(u8, action, "xor")) return self.fillDialog(.xor);
        if (eql(u8, action, "reverse")) return self.transformSelection(.reverse);
        if (eql(u8, action, "swap2")) return self.transformSelection(.swap2);
        if (eql(u8, action, "swap4")) return self.transformSelection(.swap4);
        if (eql(u8, action, "swap8")) return self.transformSelection(.swap8);
        if (eql(u8, action, "checksums")) return self.showChecksums();
        if (eql(u8, action, "entropy")) return self.showEntropy();
        if (eql(u8, action, "compare")) return self.compareDialog();
        if (eql(u8, action, "diff-next")) return self.nextDifference(true);
        if (eql(u8, action, "diff-prev")) return self.nextDifference(false);
        if (eql(u8, action, "diff-clear")) return self.clearComparison();
        if (eql(u8, action, "disasm")) return self.disassembleDialog();
        if (eql(u8, action, "follow")) return self.followValue();
        if (eql(u8, action, "back")) return self.goBack();
        if (eql(u8, action, "bookmark-add")) return self.bookmarkDialog(null);
        if (eql(u8, action, "bookmarks")) return self.showBookmarks();
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
        .find => editor.startSearch(text, if (ctx.mode) |m| m.getSelected() else 0, if (ctx.num_kind) |k| k.getSelected() else 0, if (ctx.big) |b| b.getActive() != 0 else false),
        .goto => editor.gotoOffset(text),
        .sector => editor.gotoSector(text),
    };
    if (ok) ctx.dialog.destroy() else editor.status.setText(common.tr("That is not valid here."));
}

pub fn main(init: std.process.Init.Minimal) !void {
    common.perf.init();
    var debug_allocator: common.perf.Gpa = .{};
    defer debug_allocator.deinit();
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
    _ = @import("fuzz_test.zig");
    _ = @import("devsearch.zig");
    _ = @import("image.zig");
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
    _ = @import("analyze.zig");
    _ = @import("bookmarks.zig");
    _ = @import("structure.zig");
    _ = @import("strings.zig");
    _ = @import("disk.zig");
    _ = @import("analyze.zig");
    _ = @import("bookmarks.zig");
    _ = @import("buffer.zig");
    _ = @import("inspect.zig");
}

test "go-to offsets" {
    try std.testing.expectEqual(@as(?usize, 255), HexEditor.parseOffset("0xFF"));
    try std.testing.expectEqual(@as(?usize, 42), HexEditor.parseOffset(" 42 "));
    try std.testing.expect(HexEditor.parseOffset("zz") == null);
    try std.testing.expect(HexEditor.parseOffset("") == null);
}
