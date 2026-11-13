//! The editor's side panels, as in Kate and gedit: a folder tree on the
//! left (F9) and the results of Find in Files at the bottom.

const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

const Editor = @import("editor.zig").Editor;

const attributes = "standard::name,standard::display-name,standard::type,standard::icon,standard::is-hidden";

fn fileOf(info: *gio.FileInfo) ?*gio.File {
    const obj = info.getAttributeObject("standard::file") orelse return null;
    return @ptrCast(@alignCast(obj));
}

// ---- folder tree -------------------------------------------------------------

pub const FilePanel = struct {
    editor: *Editor,
    box: *gtk.Box,
    title: *gtk.Label,
    list: *gtk.ListView,
    tree: ?*gtk.TreeListModel = null,
    root: ?*gio.File = null,

    pub fn create(editor: *Editor) !*FilePanel {
        const self = try editor.allocator.create(FilePanel);
        self.* = .{
            .editor = editor,
            .box = gtk.Box.new(.vertical, 0),
            .title = gtk.Label.new(""),
            .list = gtk.ListView.new(null, null),
        };
        const head = gtk.Box.new(.horizontal, 2);
        head.as(gtk.Widget).setMarginStart(6);
        head.as(gtk.Widget).setMarginEnd(4);
        head.as(gtk.Widget).setMarginTop(4);
        head.as(gtk.Widget).setMarginBottom(4);
        self.title.setEllipsize(.start);
        self.title.setXalign(0);
        self.title.as(gtk.Widget).setHexpand(1);
        self.title.as(gtk.Widget).addCssClass("heading");
        head.append(self.title.as(gtk.Widget));
        head.append(self.headButton("go-up-symbolic", "Parent folder", onUp));
        head.append(self.headButton("go-home-symbolic", "Home folder", onHome));
        head.append(self.headButton("go-jump-symbolic", "The open file's folder", onActiveFolder));

        const factory = gtk.SignalListItemFactory.new();
        _ = gtk.SignalListItemFactory.signals.setup.connect(factory, ?*anyopaque, &onSetup, null, .{});
        _ = gtk.SignalListItemFactory.signals.bind.connect(factory, ?*anyopaque, &onBind, null, .{});
        self.list.setFactory(factory.as(gtk.ListItemFactory));
        factory.as(gobject.Object).unref();
        _ = gtk.ListView.signals.activate.connect(self.list, *FilePanel, &onActivate, self, .{});
        self.list.as(gtk.Widget).addCssClass("navigation-sidebar");

        const scroller = gtk.ScrolledWindow.new();
        scroller.setChild(self.list.as(gtk.Widget));
        scroller.setPolicy(.never, .automatic);
        scroller.as(gtk.Widget).setVexpand(1);
        self.box.append(head.as(gtk.Widget));
        self.box.append(scroller.as(gtk.Widget));
        self.box.as(gtk.Widget).setSizeRequest(200, -1);
        self.box.as(gtk.Widget).setVisible(0);
        return self;
    }

    fn headButton(self: *FilePanel, icon: [:0]const u8, comptime tip: [:0]const u8, comptime handler: fn (*gtk.Button, *FilePanel) callconv(.c) void) *gtk.Widget {
        const button = gtk.Button.newFromIconName(icon);
        button.setHasFrame(0);
        button.as(gtk.Widget).setTooltipText(common.tr(tip));
        _ = gtk.Button.signals.clicked.connect(button, *FilePanel, &handler, self, .{});
        return button.as(gtk.Widget);
    }

    pub fn destroy(self: *FilePanel) void {
        if (self.root) |r| r.as(gobject.Object).unref();
        self.editor.allocator.destroy(self);
    }

    pub fn widget(self: *FilePanel) *gtk.Widget {
        return self.box.as(gtk.Widget);
    }

    /// Shows the folder `path` at the top of the tree.
    pub fn setRoot(self: *FilePanel, path: []const u8) void {
        var buf: [4096]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{path}, 0) catch return;
        const file = gio.File.newForPath(z);
        if (self.root) |r| r.as(gobject.Object).unref();
        self.root = file;
        const model = folderModel(file);
        const tree = gtk.TreeListModel.new(model, 0, 0, &childModel, null, null);
        const sel = gtk.SingleSelection.new(tree.as(gio.ListModel));
        self.list.setModel(sel.as(gtk.SelectionModel));
        sel.as(gobject.Object).unref();
        self.tree = tree;
        const base = std.fs.path.basename(path);
        self.title.setText(std.fmt.bufPrintSentinel(&buf, "{s}", .{if (base.len > 0) base else path}, 0) catch "");
        self.title.as(gtk.Widget).setTooltipText(z);
    }

    pub fn rootPath(self: *FilePanel, buf: *[4096]u8) ?[]const u8 {
        const r = self.root orelse return null;
        const p = r.getPath() orelse return null;
        defer glib.free(p);
        const s = std.mem.span(p);
        if (s.len > buf.len) return null;
        @memcpy(buf[0..s.len], s);
        return buf[0..s.len];
    }

    /// A folder's entries: hidden ones left out, folders first, by name.
    fn folderModel(file: *gio.File) *gio.ListModel {
        const dir = gtk.DirectoryList.new(attributes, file);
        const filter = gtk.CustomFilter.new(&keep, null, null);
        const filtered = gtk.FilterListModel.new(dir.as(gio.ListModel), filter.as(gtk.Filter));
        const sorter = gtk.CustomSorter.new(&order, null, null);
        const sorted = gtk.SortListModel.new(filtered.as(gio.ListModel), sorter.as(gtk.Sorter));
        return sorted.as(gio.ListModel);
    }

    fn keep(item: *gobject.Object, _: ?*anyopaque) callconv(.c) c_int {
        const info: *gio.FileInfo = @ptrCast(@alignCast(item));
        return @intFromBool(info.getIsHidden() == 0);
    }

    fn order(a: ?*const anyopaque, b: ?*const anyopaque, _: ?*anyopaque) callconv(.c) c_int {
        const ia: *gio.FileInfo = @ptrCast(@alignCast(@constCast(a.?)));
        const ib: *gio.FileInfo = @ptrCast(@alignCast(@constCast(b.?)));
        const da = ia.getFileType() == .directory;
        const db = ib.getFileType() == .directory;
        if (da != db) return if (da) -1 else 1;
        const r = glib.utf8Collate(ia.getDisplayName(), ib.getDisplayName());
        return if (r < 0) -1 else if (r > 0) @as(c_int, 1) else 0;
    }

    fn childModel(item: *gobject.Object, _: ?*anyopaque) callconv(.c) ?*gio.ListModel {
        const info: *gio.FileInfo = @ptrCast(@alignCast(item));
        if (info.getFileType() != .directory) return null;
        const file = fileOf(info) orelse return null;
        return folderModel(file);
    }

    fn onSetup(_: *gtk.SignalListItemFactory, obj: *gobject.Object, _: ?*anyopaque) callconv(.c) void {
        const li: *gtk.ListItem = @ptrCast(@alignCast(obj));
        const expander = gtk.TreeExpander.new();
        const row = gtk.Box.new(.horizontal, 6);
        row.append(gtk.Image.new().as(gtk.Widget));
        const label = gtk.Label.new("");
        label.setXalign(0);
        label.setEllipsize(.end);
        row.append(label.as(gtk.Widget));
        expander.setChild(row.as(gtk.Widget));
        li.setChild(expander.as(gtk.Widget));
    }

    fn onBind(_: *gtk.SignalListItemFactory, obj: *gobject.Object, _: ?*anyopaque) callconv(.c) void {
        const li: *gtk.ListItem = @ptrCast(@alignCast(obj));
        const row: *gtk.TreeListRow = @ptrCast(@alignCast(li.getItem() orelse return));
        const expander: *gtk.TreeExpander = @ptrCast(@alignCast(li.getChild() orelse return));
        expander.setListRow(row);
        const item = row.getItem() orelse return;
        defer item.unref();
        const info: *gio.FileInfo = @ptrCast(@alignCast(item));
        const box = expander.getChild() orelse return;
        const image: *gtk.Image = @ptrCast(@alignCast(box.getFirstChild() orelse return));
        const label: *gtk.Label = @ptrCast(@alignCast(image.as(gtk.Widget).getNextSibling() orelse return));
        if (info.getIcon()) |icon| image.setFromGicon(icon);
        label.setText(info.getDisplayName());
    }

    fn onActivate(_: *gtk.ListView, position: c_uint, self: *FilePanel) callconv(.c) void {
        const tree = self.tree orelse return;
        const row = tree.getRow(position) orelse return;
        defer row.as(gobject.Object).unref();
        const item = row.getItem() orelse return;
        defer item.unref();
        const info: *gio.FileInfo = @ptrCast(@alignCast(item));
        if (info.getFileType() == .directory) {
            row.setExpanded(@intFromBool(row.getExpanded() == 0));
            return;
        }
        const file = fileOf(info) orelse return;
        self.editor.openFile(file, null);
    }

    fn onUp(_: *gtk.Button, self: *FilePanel) callconv(.c) void {
        var buf: [4096]u8 = undefined;
        const p = self.rootPath(&buf) orelse return;
        if (std.fs.path.dirname(p)) |parent| self.setRoot(parent);
    }

    fn onHome(_: *gtk.Button, self: *FilePanel) callconv(.c) void {
        self.setRoot(std.mem.span(glib.getHomeDir()));
    }

    fn onActiveFolder(_: *gtk.Button, self: *FilePanel) callconv(.c) void {
        const path = self.editor.cur.path orelse return;
        if (std.fs.path.dirname(path)) |dir| self.setRoot(dir);
    }
};

// ---- find in files -------------------------------------------------------------

pub const GrepPanel = struct {
    editor: *Editor,
    box: *gtk.Box,
    entry: *gtk.SearchEntry,
    folder_button: *gtk.Button,
    folder_label: *gtk.Label,
    case_check: *gtk.CheckButton,
    word_check: *gtk.CheckButton,
    regex_check: *gtk.CheckButton,
    status: *gtk.Label,
    list: *gtk.ListBox,
    folder: ?[:0]u8 = null,
    results: std.ArrayList(Hit) = .empty,
    job: ?*Job = null,

    const Hit = struct { path: [:0]u8, line: u32 };
    const max_hits = 2000;

    /// One run of grep; outlives the panel's interest in it when cancelled.
    const Job = struct {
        panel: ?*GrepPanel,
        sub: *gio.Subprocess,
        stream: *gio.DataInputStream,
        cancellable: *gio.Cancellable,
    };

    pub fn create(editor: *Editor) !*GrepPanel {
        const self = try editor.allocator.create(GrepPanel);
        self.* = .{
            .editor = editor,
            .box = gtk.Box.new(.vertical, 4),
            .entry = gtk.SearchEntry.new(),
            .folder_button = gtk.Button.new(),
            .folder_label = gtk.Label.new(""),
            .case_check = gtk.CheckButton.newWithMnemonic(common.tr("Match _Case")),
            .word_check = gtk.CheckButton.newWithMnemonic(common.tr("_Whole Words")),
            .regex_check = gtk.CheckButton.newWithMnemonic(common.tr("Regular E_xpression")),
            .status = gtk.Label.new(""),
            .list = gtk.ListBox.new(),
        };
        const bar = gtk.Box.new(.horizontal, 6);
        bar.as(gtk.Widget).setMarginStart(6);
        bar.as(gtk.Widget).setMarginEnd(6);
        bar.as(gtk.Widget).setMarginTop(4);
        self.entry.setPlaceholderText(common.tr("Find in files"));
        self.entry.as(gtk.Widget).setSizeRequest(200, -1);
        // A long folder shows its end; the window must not grow for it.
        self.folder_label.setEllipsize(.start);
        self.folder_label.setMaxWidthChars(28);
        self.folder_button.setChild(self.folder_label.as(gtk.Widget));
        self.folder_button.as(gtk.Widget).setTooltipText(common.tr("The folder to search"));
        const close = gtk.Button.newFromIconName("window-close-symbolic");
        close.setHasFrame(0);
        close.as(gtk.Widget).setTooltipText(common.tr("Close"));
        self.status.as(gtk.Widget).addCssClass("dim-label");
        self.status.as(gtk.Widget).setHexpand(1);
        self.status.setXalign(1);
        self.status.setEllipsize(.end);
        bar.append(self.entry.as(gtk.Widget));
        bar.append(gtk.Label.new(common.tr("in")).as(gtk.Widget));
        bar.append(self.folder_button.as(gtk.Widget));
        bar.append(self.case_check.as(gtk.Widget));
        bar.append(self.word_check.as(gtk.Widget));
        bar.append(self.regex_check.as(gtk.Widget));
        bar.append(self.status.as(gtk.Widget));
        bar.append(close.as(gtk.Widget));
        _ = gtk.SearchEntry.signals.activate.connect(self.entry, *GrepPanel, &onRun, self, .{});
        _ = gtk.Button.signals.clicked.connect(self.folder_button, *GrepPanel, &onPickFolder, self, .{});
        _ = gtk.Button.signals.clicked.connect(close, *GrepPanel, &onClose, self, .{});
        _ = gtk.ListBox.signals.row_activated.connect(self.list, *GrepPanel, &onRow, self, .{});
        self.list.as(gtk.Widget).addCssClass("dkde-edit-grep");

        const scroller = gtk.ScrolledWindow.new();
        scroller.setChild(self.list.as(gtk.Widget));
        scroller.as(gtk.Widget).setVexpand(1);
        self.box.append(bar.as(gtk.Widget));
        self.box.append(scroller.as(gtk.Widget));
        self.box.as(gtk.Widget).setSizeRequest(-1, 180);
        self.box.as(gtk.Widget).setVisible(0);
        return self;
    }

    pub fn destroy(self: *GrepPanel) void {
        self.stop();
        // The list widget is already gone when the window is destroyed: only free the results.
        for (self.results.items) |h| self.editor.allocator.free(h.path);
        self.results.deinit(self.editor.allocator);
        if (self.folder) |f| self.editor.allocator.free(f);
        self.editor.allocator.destroy(self);
    }

    pub fn widget(self: *GrepPanel) *gtk.Widget {
        return self.box.as(gtk.Widget);
    }

    pub fn open(self: *GrepPanel, folder: []const u8, needle: ?[]const u8) void {
        self.setFolder(folder);
        if (needle) |n| if (n.len > 0 and n.len < 200 and std.mem.indexOfScalar(u8, n, '\n') == null) {
            var buf: [256]u8 = undefined;
            self.entry.as(gtk.Editable).setText(std.fmt.bufPrintSentinel(&buf, "{s}", .{n}, 0) catch "");
        };
        self.box.as(gtk.Widget).setVisible(1);
        _ = self.entry.as(gtk.Widget).grabFocus();
    }

    fn setFolder(self: *GrepPanel, folder: []const u8) void {
        const gpa = self.editor.allocator;
        const z = gpa.dupeSentinel(u8, folder, 0) catch return;
        if (self.folder) |f| gpa.free(f);
        self.folder = z;
        var buf: [300]u8 = undefined;
        const home = std.mem.span(glib.getHomeDir());
        const shown = if (std.mem.startsWith(u8, folder, home) and home.len > 1)
            std.fmt.bufPrintSentinel(&buf, "~{s}", .{folder[home.len..]}, 0) catch ""
        else
            std.fmt.bufPrintSentinel(&buf, "{s}", .{folder}, 0) catch "";
        self.folder_label.setText(shown);
        self.folder_button.as(gtk.Widget).setTooltipText(z);
    }

    fn clear(self: *GrepPanel) void {
        self.list.removeAll();
        for (self.results.items) |h| self.editor.allocator.free(h.path);
        self.results.clearRetainingCapacity();
    }

    fn stop(self: *GrepPanel) void {
        if (self.job) |job| {
            job.panel = null;
            job.cancellable.cancel();
            job.sub.forceExit();
            self.job = null;
        }
    }

    fn onClose(_: *gtk.Button, self: *GrepPanel) callconv(.c) void {
        self.stop();
        self.box.as(gtk.Widget).setVisible(0);
        _ = self.editor.cur.focused.as(gtk.Widget).grabFocus();
    }

    fn onPickFolder(_: *gtk.Button, self: *GrepPanel) callconv(.c) void {
        const dialog = gtk.FileDialog.new();
        defer dialog.as(gobject.Object).unref();
        if (self.folder) |f| {
            const file = gio.File.newForPath(f);
            defer file.as(gobject.Object).unref();
            dialog.setInitialFolder(file);
        }
        dialog.selectFolder(self.editor.window.as(gtk.Window), null, onFolderChosen, self);
    }

    fn onFolderChosen(source_obj: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *GrepPanel = @ptrCast(@alignCast(data.?));
        const dialog: *gtk.FileDialog = @ptrCast(@alignCast(source_obj.?));
        const file = dialog.selectFolderFinish(result, null) orelse return;
        defer file.as(gobject.Object).unref();
        const p = file.getPath() orelse return;
        defer glib.free(p);
        self.setFolder(std.mem.span(p));
    }

    fn onRun(_: *gtk.SearchEntry, self: *GrepPanel) callconv(.c) void {
        self.run();
    }

    fn run(self: *GrepPanel) void {
        self.stop();
        self.clear();
        const needle = std.mem.span(self.entry.as(gtk.Editable).getText());
        const folder = self.folder orelse return;
        if (needle.len == 0) return self.status.setText("");
        var argv: std.ArrayList(?[*:0]const u8) = .empty;
        defer argv.deinit(self.editor.allocator);
        const gpa = self.editor.allocator;
        argv.appendSlice(gpa, &.{ "grep", "-rnIZ", "--color=never" }) catch return;
        if (self.case_check.getActive() == 0) argv.append(gpa, "-i") catch return;
        if (self.word_check.getActive() != 0) argv.append(gpa, "-w") catch return;
        argv.append(gpa, if (self.regex_check.getActive() != 0) "-E" else "-F") catch return;
        for ([_][*:0]const u8{ ".git", ".hg", ".svn", "node_modules", ".zig-cache", "zig-out", "zig-pkg", "__pycache__", "target", ".cache" }) |d| {
            const opt = std.fmt.allocPrintSentinel(std.heap.c_allocator, "--exclude-dir={s}", .{d}, 0) catch return;
            argv.append(gpa, opt) catch return;
        }
        const needle_z = gpa.dupeSentinel(u8, needle, 0) catch return;
        defer gpa.free(needle_z);
        argv.appendSlice(gpa, &.{ "-e", needle_z, "--", folder, null }) catch return;
        defer for (argv.items[3..]) |a| {
            if (a) |p| if (std.mem.startsWith(u8, std.mem.span(p), "--exclude-dir=")) std.heap.c_allocator.free(std.mem.span(p));
        };

        var err: ?*glib.Error = null;
        const sub = gio.Subprocess.newv(@ptrCast(argv.items.ptr), .{ .stdout_pipe = true, .stderr_silence = true }, &err) orelse {
            if (err) |e| e.free();
            self.status.setText(common.tr("grep could not be started."));
            return;
        };
        const job = std.heap.c_allocator.create(Job) catch return;
        job.* = .{
            .panel = self,
            .sub = sub,
            .stream = gio.DataInputStream.new(sub.getStdoutPipe().?),
            .cancellable = gio.Cancellable.new(),
        };
        self.job = job;
        self.status.setText(common.tr("Searching\u{2026}"));
        job.stream.readLineAsync(glib.PRIORITY_DEFAULT, job.cancellable, onLine, job);
    }

    fn onLine(source_obj: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const job: *Job = @ptrCast(@alignCast(data.?));
        const stream: *gio.DataInputStream = @ptrCast(@alignCast(source_obj.?));
        var len: usize = 0;
        const line = stream.readLineFinish(result, &len, null);
        const self = job.panel orelse return finishJob(job);
        if (line == null) {
            self.job = null;
            finishJob(job);
            return self.showCount(false);
        }
        defer glib.free(line);
        self.addHit(line.?[0..len]);
        if (self.results.items.len >= max_hits) {
            self.stop();
            return self.showCount(true);
        }
        job.stream.readLineAsync(glib.PRIORITY_DEFAULT, job.cancellable, onLine, job);
    }

    fn finishJob(job: *Job) void {
        job.stream.as(gobject.Object).unref();
        job.sub.as(gobject.Object).unref();
        job.cancellable.as(gobject.Object).unref();
        std.heap.c_allocator.destroy(job);
    }

    fn showCount(self: *GrepPanel, capped: bool) void {
        var buf: [96]u8 = undefined;
        const n = self.results.items.len;
        self.status.setText(if (n == 0) common.tr("Nothing found.") else std.fmt.bufPrintSentinel(&buf, "{d}{s} match{s}", .{ n, if (capped) "+" else "", if (n == 1) "" else "es" }, 0) catch "");
    }

    /// One line of `grep -nZ`: "path\0line:text".
    fn addHit(self: *GrepPanel, raw: []const u8) void {
        const gpa = self.editor.allocator;
        const nul = std.mem.indexOfScalar(u8, raw, 0) orelse return;
        const path = raw[0..nul];
        const rest = raw[nul + 1 ..];
        const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return;
        const line = std.fmt.parseInt(u32, rest[0..colon], 10) catch return;
        const content = std.mem.trim(u8, rest[colon + 1 ..], " \t\r");
        const folder = self.folder orelse "";
        var rel = path;
        if (std.mem.startsWith(u8, path, folder) and path.len > folder.len) rel = std.mem.trimStart(u8, path[folder.len..], "/");
        const owned = gpa.dupeSentinel(u8, path, 0) catch return;
        self.results.append(gpa, .{ .path = owned, .line = line }) catch return gpa.free(owned);
        var buf: [600]u8 = undefined;
        const shown = std.fmt.bufPrintSentinel(&buf, "{s}:{d}:  {s}", .{ rel, line, content[0..@min(content.len, 400)] }, 0) catch return;
        // Text that is not UTF-8 is shown without its odd bytes.
        const label = gtk.Label.new(if (std.unicode.utf8ValidateSlice(shown)) shown.ptr else "(binary text)");
        label.setXalign(0);
        label.setEllipsize(.end);
        label.as(gtk.Widget).addCssClass("monospace");
        self.list.append(label.as(gtk.Widget));
    }

    fn onRow(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *GrepPanel) callconv(.c) void {
        const i: usize = @intCast(@max(0, row.getIndex()));
        if (i >= self.results.items.len) return;
        const hit = self.results.items[i];
        const file = gio.File.newForPath(hit.path);
        defer file.as(gobject.Object).unref();
        self.editor.openFile(file, .{ .line = hit.line -| 1, .column = 0 });
    }
};
