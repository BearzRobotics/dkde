//! One open file in the editor: its buffer and views, how it is stored on
//! disk, the warning shown when the file changes behind the editor's back,
//! the second view of a split, and the extra cursors.

const std = @import("std");
const cairo = @import("cairo1");
const gdk = @import("gdk4");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

const source = @import("source.zig");
const textfile = @import("textfile.zig");
const search = @import("search.zig");
const Editor = @import("editor.zig").Editor;

/// What the file on disk looked like when it was last read or written.
pub const DiskState = struct { mtime: i96, size: u64 };

pub const Banner = enum { none, changed, deleted };

pub const Doc = struct {
    editor: *Editor,
    buffer: *gtk.TextBuffer,
    view: *gtk.TextView,
    /// The second view of a split, on the same buffer.
    view2: ?*gtk.TextView = null,
    /// The view that had the focus last; editing commands act on it.
    focused: *gtk.TextView,
    /// What the notebook shows: the banner above the text.
    page: *gtk.Box,
    banner: *gtk.Box,
    banner_label: *gtk.Label,
    banner_reload: *gtk.Button,
    banner_kind: Banner = .none,
    /// Holds the text (one view, or the split) and the overview map.
    views_box: *gtk.Box,
    overlay: *gtk.Overlay,
    scroller: *gtk.ScrolledWindow,
    scroller2: ?*gtk.ScrolledWindow = null,
    split: ?*gtk.Paned = null,
    map: ?*gtk.Widget = null,
    /// Draws the extra cursors above the first view.
    cursor_area: *gtk.DrawingArea,
    label: *gtk.Label,
    path: ?[:0]u8 = null,
    format: textfile.Format = .{},
    disk: ?DiskState = null,
    monitor: ?*gio.FileMonitor = null,
    check_source: c_uint = 0,
    /// The draft that keeps this tab's unsaved text (see memory.zig).
    draft: ?[]u8 = null,
    readonly: bool = false,
    /// The view should show the cursor once it is on screen and laid out.
    scroll_pending: bool = false,
    scroll_source: c_uint = 0,
    /// Extra cursors (Ctrl+Alt+Up/Down, Alt+click); typing goes to all.
    extra: std.ArrayList(*gtk.TextMark) = .empty,

    pub fn create(editor: *Editor) !*Doc {
        const gpa = editor.allocator;
        const doc = try gpa.create(Doc);
        errdefer gpa.destroy(doc);
        const buffer = source.newBuffer();
        buffer.setEnableUndo(1);
        const tag = gtk.TextTag.new(search.tag_name);
        tag.as(gobject.Object).set("background", "rgba(246,211,45,0.55)", @as(?*anyopaque, null));
        _ = buffer.getTagTable().add(tag);
        tag.as(gobject.Object).unref();

        const label = gtk.Label.new("Untitled");
        label.setEllipsize(.end);
        label.setWidthChars(10);
        label.setMaxWidthChars(22);

        doc.* = .{
            .editor = editor,
            .buffer = buffer,
            .view = undefined,
            .focused = undefined,
            .page = gtk.Box.new(.vertical, 0),
            .banner = gtk.Box.new(.horizontal, 8),
            .banner_label = gtk.Label.new(""),
            .banner_reload = gtk.Button.newWithLabel(common.tr("Reload")),
            .views_box = gtk.Box.new(.horizontal, 0),
            .overlay = gtk.Overlay.new(),
            .scroller = gtk.ScrolledWindow.new(),
            .cursor_area = gtk.DrawingArea.new(),
            .label = label,
        };
        doc.view = editor.makeView(doc);
        doc.focused = doc.view;

        // The banner: the file changed or went away on disk.
        doc.banner.as(gtk.Widget).addCssClass("dkde-edit-banner");
        doc.banner.as(gtk.Widget).setVisible(0);
        doc.banner_label.setWrap(1);
        doc.banner_label.setXalign(0);
        doc.banner_label.as(gtk.Widget).setHexpand(1);
        const keep = gtk.Button.newWithLabel(common.tr("Keep Mine"));
        keep.as(gtk.Widget).setTooltipText(common.tr("Keep the text as it is here; saving will overwrite the file"));
        doc.banner.append(doc.banner_label.as(gtk.Widget));
        doc.banner.append(doc.banner_reload.as(gtk.Widget));
        doc.banner.append(keep.as(gtk.Widget));
        _ = gtk.Button.signals.clicked.connect(doc.banner_reload, *Doc, &onBannerReload, doc, .{});
        _ = gtk.Button.signals.clicked.connect(keep, *Doc, &onBannerKeep, doc, .{});

        doc.scroller.setChild(doc.view.as(gtk.Widget));
        doc.scroller.as(gtk.Widget).setVexpand(1);
        doc.scroller.as(gtk.Widget).setHexpand(1);
        doc.overlay.setChild(doc.scroller.as(gtk.Widget));
        doc.cursor_area.as(gtk.Widget).setCanTarget(0);
        doc.cursor_area.setDrawFunc(onDrawCursors, doc, null);
        doc.overlay.addOverlay(doc.cursor_area.as(gtk.Widget));
        doc.overlay.as(gtk.Widget).setHexpand(1);
        doc.views_box.append(doc.overlay.as(gtk.Widget));
        doc.views_box.as(gtk.Widget).setVexpand(1);
        doc.page.append(doc.banner.as(gtk.Widget));
        doc.page.append(doc.views_box.as(gtk.Widget));

        _ = gtk.Adjustment.signals.value_changed.connect(doc.scroller.getVadjustment(), *Doc, &onScrolled, doc, .{});
        _ = gtk.Widget.signals.map.connect(doc.view, *Doc, &onViewMapped, doc, .{});
        _ = gtk.Adjustment.signals.value_changed.connect(doc.scroller.getHadjustment(), *Doc, &onScrolled, doc, .{});

        // Extra cursors: keys and Alt+click on the first view.
        const keys = gtk.EventControllerKey.new();
        keys.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *Doc, &onCursorKey, doc, .{});
        doc.view.as(gtk.Widget).addController(keys.as(gtk.EventController));
        const click = gtk.GestureClick.new();
        click.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.GestureClick.signals.pressed.connect(click, *Doc, &onCursorClick, doc, .{});
        doc.view.as(gtk.Widget).addController(click.as(gtk.EventController));
        return doc;
    }

    /// Frees what the tab owns; its widgets go with the notebook page.
    pub fn destroy(doc: *Doc) void {
        const gpa = doc.editor.allocator;
        doc.stopWatching();
        if (doc.check_source != 0) _ = glib.Source.remove(doc.check_source);
        if (doc.scroll_source != 0) _ = glib.Source.remove(doc.scroll_source);
        doc.clearCursors();
        doc.extra.deinit(gpa);
        if (doc.path) |p| gpa.free(p);
        if (doc.draft) |d| gpa.free(d);
        doc.buffer.as(gobject.Object).unref();
        gpa.destroy(doc);
    }

    /// Brings the cursor into view: now if the view is showing, otherwise
    /// when its tab is first shown (a view that is not laid out yet cannot
    /// scroll).
    pub fn scrollToCursorSoon(doc: *Doc) void {
        doc.scroll_pending = true;
        if (doc.view.as(gtk.Widget).getMapped() != 0 and doc.scroll_source == 0)
            doc.scroll_source = glib.idleAdd(onScrollIdle, doc);
    }

    fn onViewMapped(_: *gtk.TextView, doc: *Doc) callconv(.c) void {
        if (doc.scroll_pending and doc.scroll_source == 0) doc.scroll_source = glib.idleAdd(onScrollIdle, doc);
    }

    fn onScrollIdle(data: ?*anyopaque) callconv(.c) c_int {
        const doc: *Doc = @ptrCast(@alignCast(data.?));
        doc.scroll_source = 0;
        doc.scroll_pending = false;
        doc.view.scrollToMark(doc.buffer.getInsert(), 0.1, 1, 0, 0.3);
        return 0;
    }

    pub fn name(doc: *const Doc) []const u8 {
        return if (doc.path) |p| std.fs.path.basename(p) else "Untitled";
    }

    pub fn modified(doc: *const Doc) bool {
        return doc.buffer.getModified() != 0;
    }

    /// True for an untitled, empty, untouched tab (a file opens into it).
    pub fn isBlank(doc: *const Doc) bool {
        return doc.path == null and !doc.modified() and doc.buffer.getCharCount() == 0;
    }

    /// The whole text, owned by the caller.
    pub fn text(doc: *const Doc, gpa: std.mem.Allocator) ![]u8 {
        var start: gtk.TextIter = undefined;
        var end: gtk.TextIter = undefined;
        doc.buffer.getBounds(&start, &end);
        const raw = doc.buffer.getText(&start, &end, 1);
        defer glib.free(raw);
        return gpa.dupe(u8, std.mem.span(raw));
    }

    pub fn setPath(doc: *Doc, path: ?[]const u8) void {
        const gpa = doc.editor.allocator;
        const owned: ?[:0]u8 = if (path) |p| gpa.dupeSentinel(u8, p, 0) catch null else null;
        if (doc.path) |old| gpa.free(old);
        doc.path = owned;
        doc.readonly = if (owned) |p| !writable(p) else false;
    }

    /// Replaces the text with `text_utf8` as one step that cannot be undone,
    /// and marks it unchanged.
    pub fn setText(doc: *Doc, text_utf8: []const u8) void {
        doc.clearCursors();
        doc.buffer.beginIrreversibleAction();
        doc.buffer.setText(@ptrCast(text_utf8.ptr), @intCast(text_utf8.len));
        doc.buffer.endIrreversibleAction();
        var start: gtk.TextIter = undefined;
        doc.buffer.getStartIter(&start);
        doc.buffer.placeCursor(&start);
        doc.buffer.setModified(0);
    }

    /// Picks the syntax colouring from the file name and contents.
    pub fn guessLanguage(doc: *Doc, sample: []const u8) void {
        if (!source.available()) return;
        const path = doc.path orelse return source.setLanguage(doc.buffer, null);
        const base = std.fs.path.basename(path);
        var name_buf: [256]u8 = undefined;
        const base_z = std.fmt.bufPrintSentinel(&name_buf, "{s}", .{base}, 0) catch return;
        const ct = gio.contentTypeGuess(base_z, sample.ptr, @min(sample.len, 4096), null);
        defer glib.free(ct);
        source.setLanguage(doc.buffer, source.guessLanguage(base_z, std.mem.span(ct)));
    }

    // ---- the file on disk ------------------------------------------------------

    pub fn statDisk(path: []const u8) ?DiskState {
        const st = std.Io.Dir.cwd().statFile(common.fsio.io(), path, .{}) catch return null;
        return .{ .mtime = st.mtime.nanoseconds, .size = st.size };
    }

    /// The file that saving writes: a symbolic link's target, so the link stays.
    pub fn saveTarget(path: [:0]const u8, buf: *[4096]u8) [:0]const u8 {
        const real = std.c.realpath(path.ptr, buf) orelse return path;
        return std.mem.span(real);
    }

    fn writable(path: [:0]const u8) bool {
        if (std.c.access(path.ptr, std.c.W_OK) == 0) return true;
        // A file that does not exist yet needs a writable folder.
        if (std.c.access(path.ptr, std.c.F_OK) != 0) {
            const dir = std.fs.path.dirname(path) orelse return true;
            var buf: [4096]u8 = undefined;
            const dir_z = std.fmt.bufPrintSentinel(&buf, "{s}", .{dir}, 0) catch return true;
            return std.c.access(dir_z.ptr, std.c.W_OK) == 0;
        }
        return false;
    }

    pub fn refreshWritable(doc: *Doc) void {
        doc.readonly = if (doc.path) |p| !writable(p) else false;
    }

    /// Watches the file for changes made by other programs.
    pub fn watch(doc: *Doc) void {
        doc.stopWatching();
        const path = doc.path orelse return;
        const file = gio.File.newForPath(path);
        defer file.as(gobject.Object).unref();
        var err: ?*glib.Error = null;
        const mon = file.monitorFile(.{ .watch_moves = true }, null, &err) orelse {
            if (err) |e| e.free();
            return;
        };
        _ = gio.FileMonitor.signals.changed.connect(mon, *Doc, &onFileChanged, doc, .{});
        doc.monitor = mon;
    }

    pub fn stopWatching(doc: *Doc) void {
        if (doc.monitor) |m| {
            _ = m.cancel();
            _ = gobject.signalHandlersDisconnectMatched(m.as(gobject.Object), .{ .data = true }, 0, 0, null, null, doc);
            m.as(gobject.Object).unref();
            doc.monitor = null;
        }
    }

    fn onFileChanged(_: *gio.FileMonitor, _: *gio.File, _: ?*gio.File, _: gio.FileMonitorEvent, doc: *Doc) callconv(.c) void {
        // Several events come for one save: look once they have settled.
        if (doc.check_source != 0) _ = glib.Source.remove(doc.check_source);
        if (doc.scroll_source != 0) _ = glib.Source.remove(doc.scroll_source);
        doc.check_source = glib.timeoutAdd(300, onCheckDisk, doc);
    }

    fn onCheckDisk(data: ?*anyopaque) callconv(.c) c_int {
        const doc: *Doc = @ptrCast(@alignCast(data.?));
        doc.check_source = 0;
        doc.checkDisk();
        return 0;
    }

    /// Compares the file on disk with what was read or written last, and
    /// shows the banner when they differ.
    pub fn checkDisk(doc: *Doc) void {
        const path = doc.path orelse return;
        const known = doc.disk orelse return;
        const now = statDisk(path);
        if (now == null) return doc.showBanner(.deleted);
        if (now.?.mtime != known.mtime or now.?.size != known.size) return doc.showBanner(.changed);
        if (doc.banner_kind != .none) doc.showBanner(.none);
    }

    pub fn showBanner(doc: *Doc, kind: Banner) void {
        doc.banner_kind = kind;
        switch (kind) {
            .none => doc.banner.as(gtk.Widget).setVisible(0),
            .changed => {
                doc.banner_label.setText(if (doc.modified())
                    common.tr("The file was changed by another program. Reloading it loses your changes here.")
                else
                    common.tr("The file was changed by another program."));
                doc.banner_reload.as(gtk.Widget).setVisible(1);
                doc.banner.as(gtk.Widget).setVisible(1);
            },
            .deleted => {
                doc.banner_label.setText(common.tr("The file was deleted or moved. Save to keep this text."));
                doc.banner_reload.as(gtk.Widget).setVisible(0);
                doc.banner.as(gtk.Widget).setVisible(1);
            },
        }
    }

    fn onBannerReload(_: *gtk.Button, doc: *Doc) callconv(.c) void {
        doc.editor.reloadDoc(doc, null);
    }

    fn onBannerKeep(_: *gtk.Button, doc: *Doc) callconv(.c) void {
        // Take the file as it is now as the known state; saving overwrites it.
        if (doc.path) |p| doc.disk = statDisk(p);
        if (doc.banner_kind == .deleted) doc.disk = null;
        doc.buffer.setModified(1);
        doc.showBanner(.none);
    }

    // ---- split view ------------------------------------------------------------

    pub fn setSplit(doc: *Doc, on: bool) void {
        if (on == (doc.split != null)) return;
        const editor = doc.editor;
        if (on) {
            const view2 = editor.makeView(doc);
            const sc = gtk.ScrolledWindow.new();
            sc.setChild(view2.as(gtk.Widget));
            const paned = gtk.Paned.new(.vertical);
            paned.as(gtk.Widget).setHexpand(1);
            paned.as(gtk.Widget).setVexpand(1);
            _ = doc.overlay.as(gobject.Object).ref();
            doc.views_box.remove(doc.overlay.as(gtk.Widget));
            paned.setStartChild(doc.overlay.as(gtk.Widget));
            doc.overlay.as(gobject.Object).unref();
            paned.setEndChild(sc.as(gtk.Widget));
            doc.views_box.prepend(paned.as(gtk.Widget));
            // Half and half, once the height is known.
            const h = doc.views_box.as(gtk.Widget).getHeight();
            if (h > 0) paned.setPosition(@divTrunc(h, 2));
            doc.split = paned;
            doc.view2 = view2;
            doc.scroller2 = sc;
        } else {
            const paned = doc.split.?;
            _ = doc.overlay.as(gobject.Object).ref();
            paned.setStartChild(null);
            doc.views_box.remove(paned.as(gtk.Widget));
            doc.views_box.prepend(doc.overlay.as(gtk.Widget));
            doc.overlay.as(gobject.Object).unref();
            doc.split = null;
            doc.view2 = null;
            doc.scroller2 = null;
            doc.focused = doc.view;
        }
    }

    pub fn setMap(doc: *Doc, on: bool) void {
        if (on == (doc.map != null)) return;
        if (on) {
            const map = source.newMap(doc.view) orelse return;
            map.setSizeRequest(110, -1);
            doc.views_box.append(map);
            doc.map = map;
        } else {
            doc.views_box.remove(doc.map.?);
            doc.map = null;
        }
    }

    // ---- extra cursors ---------------------------------------------------------

    pub fn hasCursors(doc: *const Doc) bool {
        return doc.extra.items.len > 0;
    }

    pub fn clearCursors(doc: *Doc) void {
        for (doc.extra.items) |m| doc.buffer.deleteMark(m);
        doc.extra.clearRetainingCapacity();
        doc.cursor_area.as(gtk.Widget).queueDraw();
    }

    fn addCursorAt(doc: *Doc, iter: *const gtk.TextIter) void {
        // Not twice in one place, and not on the main cursor.
        var main: gtk.TextIter = undefined;
        doc.buffer.getIterAtMark(&main, doc.buffer.getInsert());
        if (main.equal(iter) != 0) return;
        for (doc.extra.items) |m| {
            var it: gtk.TextIter = undefined;
            doc.buffer.getIterAtMark(&it, m);
            if (it.equal(iter) != 0) return;
        }
        const mark = doc.buffer.createMark(null, iter, 0);
        doc.extra.append(doc.editor.allocator, mark) catch return;
        doc.cursor_area.as(gtk.Widget).queueDraw();
    }

    /// Adds a cursor on the line above or below the outermost one, in the same column.
    pub fn addCursorVertical(doc: *Doc, up: bool) void {
        var from: gtk.TextIter = undefined;
        doc.buffer.getIterAtMark(&from, doc.buffer.getInsert());
        for (doc.extra.items) |m| {
            var it: gtk.TextIter = undefined;
            doc.buffer.getIterAtMark(&it, m);
            if ((up and it.getLine() < from.getLine()) or (!up and it.getLine() > from.getLine())) from = it;
        }
        const line = from.getLine() + @as(c_int, if (up) -1 else 1);
        if (line < 0 or line >= doc.buffer.getLineCount()) return;
        // The column of the main cursor, or the line's end if it is shorter.
        var main: gtk.TextIter = undefined;
        doc.buffer.getIterAtMark(&main, doc.buffer.getInsert());
        const col = main.getLineOffset();
        var it: gtk.TextIter = undefined;
        _ = doc.buffer.getIterAtLine(&it, line);
        if ((it.endsLine() == 0)) _ = it.forwardToLineEnd();
        if (it.getLineOffset() > col) _ = doc.buffer.getIterAtLineOffset(&it, line, col);
        doc.addCursorAt(&it);
    }

    /// Every cursor position, the main one first, as fresh iterators.
    fn cursorIters(doc: *Doc, out: []gtk.TextIter) usize {
        var n: usize = 0;
        doc.buffer.getIterAtMark(&out[0], doc.buffer.getInsert());
        n = 1;
        for (doc.extra.items) |m| {
            if (n >= out.len) break;
            doc.buffer.getIterAtMark(&out[n], m);
            n += 1;
        }
        return n;
    }

    /// Inserts `s` at every cursor, as one undoable step.
    pub fn insertAtCursors(doc: *Doc, s: []const u8) void {
        doc.buffer.beginUserAction();
        defer doc.buffer.endUserAction();
        _ = doc.buffer.deleteSelection(1, 1);
        // Marks move with the text, so each place is looked up afresh.
        var marks: std.ArrayList(*gtk.TextMark) = .empty;
        defer marks.deinit(doc.editor.allocator);
        marks.append(doc.editor.allocator, doc.buffer.getInsert()) catch return;
        marks.appendSlice(doc.editor.allocator, doc.extra.items) catch return;
        for (marks.items) |m| {
            var it: gtk.TextIter = undefined;
            doc.buffer.getIterAtMark(&it, m);
            doc.buffer.insert(&it, @ptrCast(s.ptr), @intCast(s.len));
        }
    }

    /// Deletes one character before (or after) every cursor.
    fn deleteAtCursors(doc: *Doc, before: bool) void {
        doc.buffer.beginUserAction();
        defer doc.buffer.endUserAction();
        if (doc.buffer.deleteSelection(1, 1) != 0) return;
        var marks: std.ArrayList(*gtk.TextMark) = .empty;
        defer marks.deinit(doc.editor.allocator);
        marks.append(doc.editor.allocator, doc.buffer.getInsert()) catch return;
        marks.appendSlice(doc.editor.allocator, doc.extra.items) catch return;
        for (marks.items) |m| {
            var a: gtk.TextIter = undefined;
            doc.buffer.getIterAtMark(&a, m);
            var b = a;
            if (before) {
                if (b.backwardChar() == 0) continue;
            } else if (b.forwardChar() == 0) continue;
            doc.buffer.delete(&a, &b);
        }
    }

    /// Moves the extra cursors as the main one is about to move.
    fn moveCursors(doc: *Doc, keyval: c_uint) void {
        for (doc.extra.items) |m| {
            var it: gtk.TextIter = undefined;
            doc.buffer.getIterAtMark(&it, m);
            switch (keyval) {
                gdk.KEY_Left => _ = it.backwardChar(),
                gdk.KEY_Right => _ = it.forwardChar(),
                gdk.KEY_Home => it.setLineOffset(0),
                gdk.KEY_End => if ((it.endsLine() == 0)) {
                    _ = it.forwardToLineEnd();
                },
                gdk.KEY_Up, gdk.KEY_Down => {
                    const col = it.getLineOffset();
                    const line = it.getLine() + @as(c_int, if (keyval == gdk.KEY_Up) -1 else 1);
                    if (line < 0 or line >= doc.buffer.getLineCount()) continue;
                    _ = doc.buffer.getIterAtLine(&it, line);
                    if ((it.endsLine() == 0)) _ = it.forwardToLineEnd();
                    if (it.getLineOffset() > col) _ = doc.buffer.getIterAtLineOffset(&it, line, col);
                },
                else => {},
            }
            doc.buffer.moveMark(m, &it);
        }
        doc.cursor_area.as(gtk.Widget).queueDraw();
    }

    fn onCursorKey(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, state: gdk.ModifierType, doc: *Doc) callconv(.c) c_int {
        if (!doc.hasCursors()) return 0;
        const ctrl = state.control_mask;
        const alt = state.alt_mask;
        switch (keyval) {
            gdk.KEY_Escape => {
                doc.clearCursors();
                return 1;
            },
            gdk.KEY_BackSpace => {
                doc.deleteAtCursors(true);
                return 1;
            },
            gdk.KEY_Delete, gdk.KEY_KP_Delete => {
                doc.deleteAtCursors(false);
                return 1;
            },
            gdk.KEY_Return, gdk.KEY_KP_Enter => {
                doc.insertAtCursors("\n");
                return 1;
            },
            gdk.KEY_Tab => {
                doc.insertAtCursors(if (doc.editor.opts.spaces) "    "[0..@min(4, doc.editor.opts.tab_width)] else "\t");
                return 1;
            },
            gdk.KEY_Left, gdk.KEY_Right, gdk.KEY_Home, gdk.KEY_End, gdk.KEY_Up, gdk.KEY_Down => {
                if (ctrl or state.shift_mask) {
                    // Ctrl+Alt+Up/Down add cursors (the window handles them);
                    // other moves with modifiers leave the extra cursors.
                    if (!(ctrl and alt)) doc.clearCursors();
                    return 0;
                }
                doc.moveCursors(keyval);
                return 0;
            },
            else => {},
        }
        if (ctrl and (keyval == gdk.KEY_v or keyval == gdk.KEY_V)) {
            doc.pasteAtCursors();
            return 1;
        }
        if (ctrl or alt) return 0;
        const ch = gdk.keyvalToUnicode(keyval);
        if (ch == 0 or ch < 0x20) return 0;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(ch), &buf) catch return 0;
        doc.insertAtCursors(buf[0..n]);
        return 1;
    }

    pub fn pasteAtCursors(doc: *Doc) void {
        doc.view.as(gtk.Widget).getClipboard().readTextAsync(null, onPasteText, doc);
    }

    fn onPasteText(source_obj: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const doc: *Doc = @ptrCast(@alignCast(data.?));
        const clip: *gdk.Clipboard = @ptrCast(@alignCast(source_obj.?));
        const t = clip.readTextFinish(result, null) orelse return;
        defer glib.free(t);
        doc.insertAtCursors(std.mem.span(t));
    }

    fn onCursorClick(gesture: *gtk.GestureClick, _: c_int, x: f64, y: f64, doc: *Doc) callconv(.c) void {
        const state = gesture.as(gtk.EventController).getCurrentEventState();
        if (!state.alt_mask) {
            if (doc.hasCursors()) doc.clearCursors();
            return;
        }
        // Alt+click adds a cursor where it lands.
        var bx: c_int = 0;
        var by: c_int = 0;
        doc.view.windowToBufferCoords(.widget, @intFromFloat(x), @intFromFloat(y), &bx, &by);
        var it: gtk.TextIter = undefined;
        _ = doc.view.getIterAtLocation(&it, bx, by);
        doc.addCursorAt(&it);
        _ = gesture.as(gtk.Gesture).setState(.claimed);
    }

    fn onScrolled(_: *gtk.Adjustment, doc: *Doc) callconv(.c) void {
        if (doc.hasCursors()) doc.cursor_area.as(gtk.Widget).queueDraw();
    }

    pub fn cursorsMoved(doc: *Doc) void {
        if (doc.hasCursors()) doc.cursor_area.as(gtk.Widget).queueDraw();
    }

    fn onDrawCursors(_: *gtk.DrawingArea, cr: *cairo.Context, _: c_int, _: c_int, data: ?*anyopaque) callconv(.c) void {
        const doc: *Doc = @ptrCast(@alignCast(data.?));
        if (!doc.hasCursors()) return;
        const accent = common.style.accentOf(doc.view.as(gtk.Widget));
        cr.setSourceRgb(accent.f_red, accent.f_green, accent.f_blue);
        for (doc.extra.items) |m| {
            var it: gtk.TextIter = undefined;
            doc.buffer.getIterAtMark(&it, m);
            var rect: gdk.Rectangle = undefined;
            doc.view.getIterLocation(&it, &rect);
            var wx: c_int = 0;
            var wy: c_int = 0;
            doc.view.bufferToWindowCoords(.widget, rect.f_x, rect.f_y, &wx, &wy);
            cr.rectangle(@floatFromInt(wx), @floatFromInt(wy), 2, @floatFromInt(@max(rect.f_height, 12)));
            cr.fill();
        }
    }
};
