// SPDX-License-Identifier: GPL-2.0-or-later
//! The Organise Pages window: the pages of a new PDF as a list to reorder,
//! rotate, delete and add to (from other files), with a picture of the one
//! that is selected. What it saves is always a new file (see `pageops.zig`).

const std = @import("std");
const common = @import("common");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const cairo = @import("cairo1");
const render = @import("pdfrender");
const pageops = @import("pageops.zig");

const Allocator = std.mem.Allocator;

/// Shows a saved file: `open(context, path)`.
pub const Open = struct {
    context: *anyopaque,
    open: *const fn (*anyopaque, [:0]const u8) void,
};

/// More pages than this are not listed: each is a row of its own.
const max_pages = 5000;

const Source = struct {
    doc: *render.Document,
    /// As given, or null for the open document as it is now.
    path: ?[:0]u8,
    name: []u8,
};

const What = enum { all, selected, parts };

const Organiser = struct {
    allocator: Allocator,
    window: *gtk.Window,
    list: *gtk.ListBox,
    preview: *gtk.DrawingArea,
    status: *gtk.Label,
    part_size: *gtk.SpinButton,
    opener: Open,
    sources: std.ArrayList(Source) = .empty,
    items: std.ArrayList(pageops.Item) = .empty,
    diag: render.Diag,
    /// What the file dialog that is up will save.
    saving: What = .all,
    /// File dialogs still to answer: the window's memory waits for them.
    waiting: u32 = 0,
    closed: bool = false,
    /// Set while the list is being rebuilt, so its signals are ignored.
    filling: bool = false,

    fn destroy(self: *Organiser) void {
        for (self.sources.items) |source| {
            source.doc.close();
            if (source.path) |p| self.allocator.free(p);
            self.allocator.free(source.name);
        }
        self.sources.deinit(self.allocator);
        self.items.deinit(self.allocator);
        self.diag.deinit();
        self.allocator.destroy(self);
    }

    fn onDestroy(_: *gtk.Window, self: *Organiser) callconv(.c) void {
        self.closed = true;
        if (self.waiting == 0) self.destroy();
    }

    /// A file dialog has answered; false when the window has gone meanwhile.
    fn answered(self: *Organiser) bool {
        self.waiting -= 1;
        if (!self.closed) return true;
        if (self.waiting == 0) self.destroy();
        return false;
    }

    fn say(self: *Organiser, comptime fmt: []const u8, args: anytype) void {
        var buf: [320]u8 = undefined;
        self.status.setText(std.fmt.bufPrintSentinel(&buf, fmt, args, 0) catch "");
    }

    /// Adds the pages of `doc` (now owned here) to the end of the list.
    fn addSource(self: *Organiser, doc: *render.Document, path: ?[]const u8, name: []const u8) !void {
        var owned = true;
        errdefer if (owned) doc.close();
        if (doc.doc.crypt != null) return error.Encrypted;
        if (self.items.items.len + doc.pageCount() > max_pages) return error.TooManyPages;
        const kept_path: ?[:0]u8 = if (path) |p| try self.allocator.dupeSentinel(u8, p, 0) else null;
        errdefer if (owned) if (kept_path) |p| self.allocator.free(p);
        const kept_name = try self.allocator.dupe(u8, name);
        errdefer if (owned) self.allocator.free(kept_name);
        try self.sources.append(self.allocator, .{ .doc = doc, .path = kept_path, .name = kept_name });
        owned = false;
        const source = self.sources.items.len - 1;
        for (0..doc.pageCount()) |page| try self.items.append(self.allocator, .{ .source = source, .page = page });
    }

    // ---- the list -----------------------------------------------------------------------------

    /// One mark per item: whether its row is selected. Null when out of memory.
    fn marks(self: *Organiser) ?[]bool {
        const marked = self.allocator.alloc(bool, self.items.items.len) catch return null;
        for (marked, 0..) |*m, i| {
            m.* = if (self.list.getRowAtIndex(@intCast(i))) |row| row.isSelected() != 0 else false;
        }
        return marked;
    }

    /// Makes the rows again, selecting those that `marked` names.
    fn fill(self: *Organiser, marked: ?[]const bool) void {
        self.filling = true;
        while (self.list.as(gtk.Widget).getFirstChild()) |child| self.list.remove(child);
        for (self.items.items, 0..) |item, i| {
            var buf: [320]u8 = undefined;
            const turned: []const u8 = switch (item.turn) {
                0 => "",
                1 => "  \u{21bb} 90\u{b0}",
                2 => "  \u{21bb} 180\u{b0}",
                3 => "  \u{21bb} 270\u{b0}",
            };
            const name = self.sources.items[item.source].name;
            const text = std.fmt.bufPrintSentinel(&buf, "{d}.   page {d} of {s}{s}", .{ i + 1, item.page + 1, name[0..utf8Prefix(name, 200)], turned }, 0) catch "?";
            const label = gtk.Label.new(text);
            label.setXalign(0);
            label.setEllipsize(.middle);
            label.as(gtk.Widget).setMarginStart(8);
            label.as(gtk.Widget).setMarginEnd(8);
            self.list.append(label.as(gtk.Widget));
        }
        if (marked) |m| for (m, 0..) |is_marked, i| {
            if (!is_marked) continue;
            if (self.list.getRowAtIndex(@intCast(i))) |row| self.list.selectRow(row);
        };
        self.filling = false;
        self.say("{d} pages", .{self.items.items.len});
        self.preview.as(gtk.Widget).queueDraw();
    }

    fn onSelectionChanged(_: *gtk.ListBox, self: *Organiser) callconv(.c) void {
        if (!self.filling) self.preview.as(gtk.Widget).queueDraw();
    }

    /// The first selected page, drawn to fit.
    fn onDraw(_: *gtk.DrawingArea, cr: *cairo.Context, width: c_int, height: c_int, data: ?*anyopaque) callconv(.c) void {
        const self: *Organiser = @ptrCast(@alignCast(data.?));
        if (self.filling) return;
        const marked = self.marks() orelse return;
        defer self.allocator.free(marked);
        const index = std.mem.indexOfScalar(bool, marked, true) orelse return;
        const item = self.items.items[index];
        const doc = self.sources.items[item.source].doc;
        const size = render.pageSize(doc, item.page) orelse return;
        const sideways = item.turn % 2 == 1;
        const w: f64 = if (sideways) size.h else size.w;
        const h: f64 = if (sideways) size.w else size.h;
        const room_w = @as(f64, @floatFromInt(width)) - 16;
        const room_h = @as(f64, @floatFromInt(height)) - 16;
        if (w <= 0 or h <= 0 or room_w <= 0 or room_h <= 0) return;
        const scale = @min(room_w / w, room_h / h);
        cr.save();
        defer cr.restore();
        cr.translate((@as(f64, @floatFromInt(width)) - w * scale) / 2, (@as(f64, @floatFromInt(height)) - h * scale) / 2);
        cr.rectangle(0, 0, w * scale, h * scale);
        cr.setSourceRgb(1, 1, 1);
        cr.fillPreserve();
        cr.clip();
        switch (item.turn) {
            0 => {},
            1 => cr.translate(size.h * scale, 0),
            2 => cr.translate(size.w * scale, size.h * scale),
            3 => cr.translate(0, size.w * scale),
        }
        cr.rotate(@as(f64, @floatFromInt(item.turn)) * std.math.pi / 2.0);
        render.renderPage(self.allocator, doc, item.page, cr, scale, &self.diag) catch {};
    }

    // ---- changing the list --------------------------------------------------------------------

    const Change = enum { earlier, later, left, right, delete };

    fn change(self: *Organiser, what: Change) void {
        const marked = self.marks() orelse return;
        defer self.allocator.free(marked);
        if (std.mem.indexOfScalar(bool, marked, true) == null) return self.say("{s}", .{"Select one or more pages first."});
        switch (what) {
            .earlier => pageops.moveEarlier(self.items.items, marked),
            .later => pageops.moveLater(self.items.items, marked),
            .left => for (self.items.items, marked) |*item, m| {
                if (m) item.turn +%= 3;
            },
            .right => for (self.items.items, marked) |*item, m| {
                if (m) item.turn +%= 1;
            },
            .delete => {
                var kept: usize = 0;
                for (self.items.items, marked) |item, m| {
                    if (m) continue;
                    self.items.items[kept] = item;
                    kept += 1;
                }
                self.items.shrinkRetainingCapacity(kept);
                return self.fill(null);
            },
        }
        self.fill(marked);
    }

    fn onEarlier(_: *gtk.Button, self: *Organiser) callconv(.c) void {
        self.change(.earlier);
    }
    fn onLater(_: *gtk.Button, self: *Organiser) callconv(.c) void {
        self.change(.later);
    }
    fn onLeft(_: *gtk.Button, self: *Organiser) callconv(.c) void {
        self.change(.left);
    }
    fn onRight(_: *gtk.Button, self: *Organiser) callconv(.c) void {
        self.change(.right);
    }
    fn onDelete(_: *gtk.Button, self: *Organiser) callconv(.c) void {
        self.change(.delete);
    }

    // ---- adding a file ------------------------------------------------------------------------

    fn onAdd(_: *gtk.Button, self: *Organiser) callconv(.c) void {
        const dialog = gtk.FileDialog.new();
        defer dialog.as(gobject.Object).unref();
        self.waiting += 1;
        dialog.open(self.window, null, onAddChosen, self);
    }

    fn onAddChosen(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Organiser = @ptrCast(@alignCast(data.?));
        const dialog: *gtk.FileDialog = @ptrCast(@alignCast(source.?));
        var err: ?*glib.Error = null;
        const chosen = dialog.openFinish(result, &err);
        if (err) |e| e.free();
        if (!self.answered()) {
            if (chosen) |file| file.as(gobject.Object).unref();
            return;
        }
        const file = chosen orelse return;
        defer file.as(gobject.Object).unref();
        const raw = file.getPath() orelse return;
        defer glib.free(raw);
        const path: [:0]const u8 = std.mem.span(raw);
        self.addFile(path) catch |e| {
            const why: [:0]const u8 = switch (e) {
                error.PasswordRequired, error.Encrypted => common.tr("Encrypted files cannot be added: the new file would not be protected."),
                error.NotPdf => common.tr("This is not a PDF document, or it is damaged."),
                error.TooManyPages => common.tr("That would be more pages than this window can handle."),
                else => common.tr("The file cannot be read."),
            };
            common.dialogs.showError(self.window, common.tr("Cannot add the file"), why);
        };
    }

    fn addFile(self: *Organiser, path: [:0]const u8) !void {
        const marked = self.marks() orelse return error.OutOfMemory;
        defer self.allocator.free(marked);
        const before = self.items.items.len;
        const doc = try render.Document.open(self.allocator, path);
        try self.addSource(doc, path, std.fs.path.basename(path));
        const all = try self.allocator.alloc(bool, self.items.items.len);
        defer self.allocator.free(all);
        @memset(all, false);
        // The pages that arrived are selected, ready to be moved into place.
        @memset(all[before..], true);
        self.fill(all);
    }

    // ---- saving -------------------------------------------------------------------------------

    fn askSave(self: *Organiser, what: What) void {
        if (self.items.items.len == 0) return self.say("{s}", .{"There are no pages to save."});
        if (what == .selected) {
            const marked = self.marks() orelse return;
            defer self.allocator.free(marked);
            if (std.mem.indexOfScalar(bool, marked, true) == null) return self.say("{s}", .{"Select one or more pages first."});
        }
        self.saving = what;
        const dialog = gtk.FileDialog.new();
        defer dialog.as(gobject.Object).unref();
        dialog.setTitle(if (what == .parts) common.tr("Name for the parts (a number is added)") else common.tr("Save as a new PDF"));
        dialog.setInitialName("pages.pdf");
        self.waiting += 1;
        dialog.save(self.window, null, onSaveChosen, self);
    }

    fn onSaveAll(_: *gtk.Button, self: *Organiser) callconv(.c) void {
        self.askSave(.all);
    }
    fn onSaveSelected(_: *gtk.Button, self: *Organiser) callconv(.c) void {
        self.askSave(.selected);
    }
    fn onSaveParts(_: *gtk.Button, self: *Organiser) callconv(.c) void {
        self.askSave(.parts);
    }

    fn onSaveChosen(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Organiser = @ptrCast(@alignCast(data.?));
        const dialog: *gtk.FileDialog = @ptrCast(@alignCast(source.?));
        var err: ?*glib.Error = null;
        const chosen = dialog.saveFinish(result, &err);
        if (err) |e| e.free();
        if (!self.answered()) {
            if (chosen) |file| file.as(gobject.Object).unref();
            return;
        }
        const file = chosen orelse return;
        defer file.as(gobject.Object).unref();
        const raw = file.getPath() orelse return;
        defer glib.free(raw);
        self.saveTo(std.mem.span(raw));
    }

    fn saveTo(self: *Organiser, path: [:0]const u8) void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        if (self.write(arena.allocator(), path)) {
            if (self.saving != .all) return;
            // Done with: show the new file. The window goes last, with `self`.
            self.opener.open(self.opener.context, path);
            self.window.destroy();
        } else |e| {
            const why: [:0]const u8 = switch (e) {
                error.WouldReplaceSource => common.tr("That file is one the pages come from. Choose another name: the new file does not carry everything the old one has."),
                error.PathAlreadyExists => common.tr("A file with the name of one of the parts exists already. Nothing was written; choose another name."),
                error.Encrypted => common.tr("Encrypted files cannot be used: the new file would not be protected."),
                else => common.tr("The new file could not be made."),
            };
            common.dialogs.showError(self.window, common.tr("Cannot save the pages"), why);
        }
    }

    fn compose(self: *Organiser, a: Allocator, items: []const pageops.Item) ![]u8 {
        const docs = try a.alloc(*render.Document, self.sources.items.len);
        for (docs, self.sources.items) |*doc, s| doc.* = s.doc;
        return pageops.compose(self.allocator, docs, items);
    }

    fn isSource(self: *Organiser, path: [:0]const u8) bool {
        for (self.sources.items) |s| {
            if (s.path) |p| if (pageops.sameFile(common.fsio.io(), p, path)) return true;
        }
        return false;
    }

    fn write(self: *Organiser, a: Allocator, path: [:0]const u8) !void {
        switch (self.saving) {
            .all, .selected => {
                if (self.isSource(path)) return error.WouldReplaceSource;
                var items = self.items.items;
                if (self.saving == .selected) {
                    const marked = self.marks() orelse return error.OutOfMemory;
                    defer self.allocator.free(marked);
                    var chosen: std.ArrayList(pageops.Item) = .empty;
                    for (self.items.items, marked) |item, m| if (m) try chosen.append(a, item);
                    items = chosen.items;
                }
                const bytes = try self.compose(a, items);
                defer self.allocator.free(bytes);
                try common.fsio.writeFileAtomic(path, bytes);
                self.say("Saved {d} pages.", .{items.len});
            },
            .parts => {
                const size: usize = @intCast(@max(1, self.part_size.getValueAsInt()));
                const count = (self.items.items.len + size - 1) / size;
                const io = common.fsio.io();
                const cwd = std.Io.Dir.cwd();
                // No part may replace a file: check them all before writing any.
                for (0..count) |i| {
                    const name = try pageops.partPath(a, path, i + 1, count);
                    if (cwd.statFile(io, name, .{})) |_| return error.PathAlreadyExists else |e| if (e != error.FileNotFound) return e;
                }
                for (0..count) |i| {
                    const name = try pageops.partPath(a, path, i + 1, count);
                    const part = self.items.items[i * size .. @min((i + 1) * size, self.items.items.len)];
                    const bytes = try self.compose(a, part);
                    defer self.allocator.free(bytes);
                    var file = try cwd.createFile(io, name, .{ .exclusive = true });
                    defer file.close(io);
                    try file.writeStreamingAll(io, bytes);
                }
                self.say("Saved {d} files.", .{count});
            },
        }
    }
};

fn utf8Prefix(text: []const u8, max: usize) usize {
    if (text.len <= max) return text.len;
    var n = max;
    while (n > 0 and text[n] & 0xC0 == 0x80) n -= 1;
    return n;
}

fn button(box: *gtk.Box, label: [:0]const u8, self: *Organiser, comptime handler: fn (*gtk.Button, *Organiser) callconv(.c) void) void {
    const b = gtk.Button.newWithLabel(label);
    _ = gtk.Button.signals.clicked.connect(b, *Organiser, handler, self, .{});
    box.append(b.as(gtk.Widget));
}

pub const ShowError = error{ Encrypted, NotPdf, TooManyPages, FileUnreadable, PasswordRequired, Unsupported, OutOfMemory };

/// Opens the window over `parent` for a document whose current bytes are
/// `bytes` (copied), saved or not, at `path`.
pub fn show(allocator: Allocator, parent: *gtk.Window, bytes: []const u8, path: []const u8, opener: Open) ShowError!void {
    const doc = try render.Document.openFromMemory(allocator, bytes);
    const self = allocator.create(Organiser) catch |e| {
        doc.close();
        return e;
    };
    const window = gtk.Window.new();
    self.* = .{
        .allocator = allocator,
        .window = window,
        .list = gtk.ListBox.new(),
        .preview = gtk.DrawingArea.new(),
        .status = gtk.Label.new(""),
        .part_size = gtk.SpinButton.newWithRange(1, max_pages, 1),
        .opener = opener,
        .diag = render.Diag.init(allocator),
    };
    // The open file counts as a source: it is not to be written over.
    self.addSource(doc, path, std.fs.path.basename(path)) catch |e| {
        window.destroy();
        self.destroy();
        return e;
    };

    window.setTitle(common.tr("Organise Pages"));
    window.setTransientFor(parent);
    window.setModal(1);
    window.setDestroyWithParent(1);
    window.setDefaultSize(760, 520);
    common.dialogs.closeOnEscape(window);
    _ = gtk.Widget.signals.destroy.connect(window, *Organiser, &Organiser.onDestroy, self, .{});

    const outer = gtk.Box.new(.vertical, 8);
    const widget = outer.as(gtk.Widget);
    widget.setMarginStart(10);
    widget.setMarginEnd(10);
    widget.setMarginTop(10);
    widget.setMarginBottom(10);

    const tools = gtk.Box.new(.horizontal, 6);
    button(tools, common.tr("Move Up"), self, Organiser.onEarlier);
    button(tools, common.tr("Move Down"), self, Organiser.onLater);
    button(tools, common.tr("Rotate Left"), self, Organiser.onLeft);
    button(tools, common.tr("Rotate Right"), self, Organiser.onRight);
    button(tools, common.tr("Delete"), self, Organiser.onDelete);
    button(tools, common.tr("Add PDF\u{2026}"), self, Organiser.onAdd);
    outer.append(tools.as(gtk.Widget));

    self.list.setSelectionMode(.multiple);
    _ = gtk.ListBox.signals.selected_rows_changed.connect(self.list, *Organiser, &Organiser.onSelectionChanged, self, .{});
    const scroller = gtk.ScrolledWindow.new();
    scroller.setChild(self.list.as(gtk.Widget));
    scroller.as(gtk.Widget).setSizeRequest(340, -1);
    self.preview.as(gtk.Widget).setHexpand(1);
    self.preview.setDrawFunc(Organiser.onDraw, self, null);
    const middle = gtk.Box.new(.horizontal, 8);
    middle.as(gtk.Widget).setVexpand(1);
    middle.append(scroller.as(gtk.Widget));
    middle.append(self.preview.as(gtk.Widget));
    outer.append(middle.as(gtk.Widget));

    const note = gtk.Label.new(common.tr("Ctrl or Shift selects several pages. The result is a new file: document properties, page labels, attachments, scripts, signatures and links to other files are not copied. Leaving a page out is not redaction."));
    note.setWrap(1);
    note.setXalign(0);
    outer.append(note.as(gtk.Widget));

    const saves = gtk.Box.new(.horizontal, 6);
    self.status.setXalign(0);
    self.status.as(gtk.Widget).setHexpand(1);
    saves.append(self.status.as(gtk.Widget));
    saves.append(gtk.Label.new(common.tr("Pages per part:")).as(gtk.Widget));
    saves.append(self.part_size.as(gtk.Widget));
    button(saves, common.tr("Split\u{2026}"), self, Organiser.onSaveParts);
    button(saves, common.tr("Save Selected\u{2026}"), self, Organiser.onSaveSelected);
    button(saves, common.tr("Save All\u{2026}"), self, Organiser.onSaveAll);
    outer.append(saves.as(gtk.Widget));

    window.setChild(outer.as(gtk.Widget));
    self.fill(null);
    if (self.list.getRowAtIndex(0)) |row| self.list.selectRow(row);
    window.present();
}
