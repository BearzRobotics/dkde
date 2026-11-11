//! A PDF open for viewing and editing, without any GTK: the document, the text
//! layout of its pages, and every edit (highlights, notes, filled form fields).
//!
//! Edits are incremental updates (pdf-zig's `write.Update`): each one appends to
//! the file's bytes, and the document is opened again from the longer bytes, so
//! what the viewer draws is exactly what a saved file would show. Because an
//! edit only appends, undoing one is cutting the bytes back to the length they
//! had before it.

const std = @import("std");
const pdf = @import("pdf");
const render = @import("pdfrender");

const Allocator = std.mem.Allocator;

pub const max_undo = 50;

pub const Error = render.Document.OpenError || pdf.write.Error || pdf.annot.Error || pdf.form.Error || pdf.outline.EditError || error{ NoSuchPage, NothingToUndo, CannotEdit };

pub const Session = struct {
    gpa: Allocator,
    doc: *render.Document,
    /// Text layouts of pages, made when first asked for and dropped when the file changes.
    layouts: std.AutoHashMapUnmanaged(usize, pdf.text.Layout) = .empty,
    text_renderer: pdf.Renderer,
    /// Byte lengths of the file before each edit, oldest first.
    history: std.ArrayList(usize) = .empty,
    /// `history.items.len` when the file was last saved or opened.
    saved_at: usize = 0,
    /// Bumped whenever the document is replaced; lets callers drop caches.
    generation: u32 = 0,

    pub fn open(gpa: Allocator, path: [:0]const u8, password: []const u8) !*Session {
        const doc = try render.Document.openWithPassword(gpa, path, password);
        return fromDocument(gpa, doc);
    }

    pub fn openBytes(gpa: Allocator, file_bytes: []const u8) !*Session {
        return fromDocument(gpa, try render.Document.openFromMemory(gpa, file_bytes));
    }

    fn fromDocument(gpa: Allocator, doc: *render.Document) !*Session {
        errdefer doc.close();
        const self = try gpa.create(Session);
        self.* = .{ .gpa = gpa, .doc = doc, .text_renderer = pdf.Renderer.init(&doc.doc, .{ .graphics = false }) };
        return self;
    }

    pub fn close(self: *Session) void {
        self.dropCaches();
        self.layouts.deinit(self.gpa);
        self.text_renderer.deinit();
        self.history.deinit(self.gpa);
        self.doc.close();
        self.gpa.destroy(self);
    }

    /// The file as it would be saved now.
    pub fn bytes(self: *const Session) []const u8 {
        return self.doc.bytes;
    }

    pub fn pageCount(self: *const Session) usize {
        return self.doc.pageCount();
    }

    pub fn dirty(self: *const Session) bool {
        return self.history.items.len != self.saved_at;
    }

    pub fn markSaved(self: *Session) void {
        self.saved_at = self.history.items.len;
    }

    /// False for files that cannot be extended in place: encrypted ones, and
    /// ones whose cross-reference data was damaged and rebuilt.
    pub fn canEdit(self: *const Session) bool {
        return self.doc.doc.crypt == null and !self.doc.doc.repaired;
    }

    pub fn canUndo(self: *const Session) bool {
        return self.history.items.len > 0;
    }

    fn dropCaches(self: *Session) void {
        var it = self.layouts.valueIterator();
        while (it.next()) |l| l.deinit(self.gpa);
        self.layouts.clearRetainingCapacity();
    }

    /// Replaces the document with one opened from `new_bytes`.
    fn reopen(self: *Session, new_bytes: []const u8) Error!void {
        const fresh = try render.Document.openFromMemory(self.gpa, new_bytes);
        self.dropCaches();
        self.text_renderer.deinit();
        self.doc.close();
        self.doc = fresh;
        self.text_renderer = pdf.Renderer.init(&fresh.doc, .{ .graphics = false });
        self.generation +%= 1;
    }

    fn page(self: *Session, index: usize) Error!pdf.pages.Page {
        return pdf.pages.page(&self.doc.doc, self.doc.pages, index) orelse error.NoSuchPage;
    }

    /// Applies the update `upd` (built on this session's document) and reopens the file.
    fn commit(self: *Session, upd: *pdf.write.Update) Error!void {
        var out: std.Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();
        try upd.write(self.gpa, &out.writer);
        const old_len = self.doc.bytes.len;
        try self.history.append(self.gpa, old_len);
        errdefer _ = self.history.pop();
        try self.reopen(out.written());
        // Keep the undo list bounded; the oldest edits become permanent.
        if (self.history.items.len > max_undo) {
            _ = self.history.orderedRemove(0);
            self.saved_at -|= 1;
        }
    }

    fn begin(self: *Session) Error!pdf.write.Update {
        if (!self.canEdit()) return error.CannotEdit;
        return pdf.write.Update.init(self.gpa, &self.doc.doc);
    }

    /// Cuts the last edit.
    pub fn undo(self: *Session) Error!void {
        const len = self.history.pop() orelse return error.NothingToUndo;
        const keep = try self.gpa.dupe(u8, self.doc.bytes[0..len]);
        defer self.gpa.free(keep);
        self.reopen(keep) catch |e| {
            self.history.append(self.gpa, len) catch {};
            return e;
        };
    }

    // ---- reading ----------------------------------------------------------------------

    /// The text of page `index` with the position of every glyph, valid until the file changes.
    pub fn layout(self: *Session, index: usize) Error!*const pdf.text.Layout {
        if (self.layouts.getPtr(index)) |l| return l;
        const p = try self.page(index);
        var dl = self.text_renderer.render(self.gpa, p) catch return error.OutOfMemory;
        defer dl.deinit();
        var lay = try pdf.text.layout(self.gpa, &dl);
        errdefer lay.deinit(self.gpa);
        try self.layouts.put(self.gpa, index, lay);
        return self.layouts.getPtr(index).?;
    }

    /// The annotations of a page; allocated from `arena`.
    pub fn annotations(self: *Session, arena: Allocator, index: usize) Error![]pdf.annot.Annotation {
        return pdf.annot.list(arena, &self.doc.doc, try self.page(index));
    }

    /// The bookmarks of the document; allocated from `arena`.
    pub fn outline(self: *Session, arena: Allocator) Allocator.Error![]const pdf.outline.Item {
        return pdf.outline.read(arena, &self.doc.doc, self.doc.pages);
    }

    /// The form fields of the document; allocated from `arena`.
    pub fn fields(self: *Session, arena: Allocator) Allocator.Error![]pdf.form.Field {
        return pdf.form.fields(arena, &self.doc.doc, self.doc.pages);
    }

    // ---- editing ----------------------------------------------------------------------

    /// Adds a text markup annotation over `rects` (displayed-page rectangles).
    pub fn markup(self: *Session, index: usize, kind: pdf.annot.Kind, rects: []const pdf.text.Rect, meta: pdf.annot.Meta) Error!void {
        var upd = try self.begin();
        defer upd.deinit();
        _ = try pdf.annot.addMarkup(&upd, try self.page(index), kind, rects, meta);
        try self.commit(&upd);
    }

    pub fn addNote(self: *Session, index: usize, x: f64, y: f64, meta: pdf.annot.Meta) Error!void {
        var upd = try self.begin();
        defer upd.deinit();
        _ = try pdf.annot.addNote(&upd, try self.page(index), x, y, meta);
        try self.commit(&upd);
    }

    /// Adds free-hand ink: strokes of displayed-page points.
    pub fn addInk(self: *Session, index: usize, strokes: []const []const pdf.display.Point, width: f64, meta: pdf.annot.Meta) Error!void {
        var upd = try self.begin();
        defer upd.deinit();
        _ = try pdf.annot.addInk(&upd, try self.page(index), strokes, width, meta);
        try self.commit(&upd);
    }

    /// Adds a text box at (`x`, `y`), `w` by `h`, on the displayed page.
    pub fn addFreeText(self: *Session, index: usize, x: f64, y: f64, w: f64, h: f64, size: f64, meta: pdf.annot.Meta) Error!void {
        var upd = try self.begin();
        defer upd.deinit();
        _ = try pdf.annot.addFreeText(&upd, try self.page(index), x, y, w, h, size, meta);
        try self.commit(&upd);
    }

    pub fn setNoteText(self: *Session, num: u32, contents: []const u8, date: ?[]const u8) Error!void {
        var upd = try self.begin();
        defer upd.deinit();
        try pdf.annot.setContents(&upd, num, contents, date);
        try self.commit(&upd);
    }

    pub fn removeAnnotation(self: *Session, index: usize, num: u32) Error!void {
        var upd = try self.begin();
        defer upd.deinit();
        try pdf.annot.remove(&upd, try self.page(index), num);
        try self.commit(&upd);
    }

    /// Adds a bookmark that goes to page `index`, `top` points from the top of the page when given.
    pub fn addBookmark(self: *Session, index: usize, title: []const u8, top_from_page_top: ?f64) Error!void {
        var upd = try self.begin();
        defer upd.deinit();
        const p = try self.page(index);
        // The destination is in user space (y up): the page's top is crop_box.y1 (pages are unrotated here).
        const top: ?f64 = if (top_from_page_top) |t| p.crop_box.y1 - t else null;
        _ = try pdf.outline.add(&upd, p.num, title, top);
        try self.commit(&upd);
    }

    pub fn removeBookmark(self: *Session, num: u32) Error!void {
        var upd = try self.begin();
        defer upd.deinit();
        try pdf.outline.remove(&upd, num);
        try self.commit(&upd);
    }

    pub fn fillText(self: *Session, field: pdf.form.Field, value: []const u8) Error!void {
        var upd = try self.begin();
        defer upd.deinit();
        try pdf.form.setText(&upd, field, value);
        try self.commit(&upd);
    }

    pub fn fillChecked(self: *Session, field: pdf.form.Field, widget: usize, on: bool) Error!void {
        var upd = try self.begin();
        defer upd.deinit();
        try pdf.form.setChecked(&upd, field, widget, on);
        try self.commit(&upd);
    }

    pub fn fillChoice(self: *Session, field: pdf.form.Field, choice: []const u8) Error!void {
        var upd = try self.begin();
        defer upd.deinit();
        try pdf.form.setChoice(&upd, field, choice);
        try self.commit(&upd);
    }
};

/// The current time as a PDF date string, `D:YYYYMMDDHHmmSSZ` (UTC), written into `buf`.
pub fn pdfDate(buf: *[20]u8, unix_seconds: i64) []const u8 {
    const secs: u64 = @intCast(@max(0, unix_seconds));
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = es.getEpochDay();
    const ymd = day.calculateYearDay();
    const md = ymd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "D:{d:0>4}{d:0>2}{d:0>2}{d:0>2}{d:0>2}{d:0>2}Z", .{
        ymd.year,                   md.month.numeric(),         md.day_index + 1,
        ds.getHoursIntoDay(),       ds.getMinutesIntoHour(),    ds.getSecondsIntoMinute(),
    }) catch "";
}

// ---- tests -------------------------------------------------------------------------------------

const testing = std.testing;

fn testPdf(aa: Allocator) ![]u8 {
    const content = "BT /F1 12 Tf 10 50 Td (Hello world) Tj ET";
    const bodies = [_][]const u8{
        "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [6 0 R] /DA (/Helv 0 Tf 0 g) >> >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> /Annots [6 0 R] >>",
        try std.fmt.allocPrint(aa, "<< /Length {d} >>\nstream\n{s}\nendstream", .{ content.len, content }),
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        "<< /Type /Annot /Subtype /Widget /FT /Tx /T (name) /Rect [10 10 120 30] /P 3 0 R >>",
    };
    var file: std.ArrayList(u8) = .empty;
    try file.appendSlice(aa, "%PDF-1.7\n");
    var offs: [bodies.len]usize = undefined;
    for (bodies, 0..) |b, i| {
        offs[i] = file.items.len;
        try file.print(aa, "{d} 0 obj\n{s}\nendobj\n", .{ i + 1, b });
    }
    const xpos = file.items.len;
    try file.print(aa, "xref\n0 {d}\n0000000000 65535 f \n", .{bodies.len + 1});
    for (offs) |o| try file.print(aa, "{d:0>10} 00000 n \n", .{o});
    try file.print(aa, "trailer\n<< /Size {d} /Root 1 0 R >>\nstartxref\n{d}\n%%EOF\n", .{ bodies.len + 1, xpos });
    return file.items;
}

test "edits append, undo cuts them, and the dirty flag follows" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const original = try testPdf(aa);
    const s = try Session.openBytes(testing.allocator, original);
    defer s.close();
    try testing.expect(s.canEdit());
    try testing.expect(!s.dirty());

    const lay = try s.layout(0);
    var found: std.ArrayList([2]u32) = .empty;
    defer found.deinit(testing.allocator);
    try lay.find(testing.allocator, "world", &found);
    try testing.expectEqual(@as(usize, 1), found.items.len);
    var rects: std.ArrayList(pdf.text.Rect) = .empty;
    defer rects.deinit(testing.allocator);
    try lay.rectsFor(testing.allocator, found.items[0][0], found.items[0][1], &rects);

    const gen = s.generation;
    try s.markup(0, .highlight, rects.items, .{ .contents = "hi" });
    try testing.expect(s.dirty());
    try testing.expect(s.generation != gen);
    try testing.expect(std.mem.startsWith(u8, s.bytes(), original));
    const annots = try s.annotations(aa, 0);
    // The widget and the highlight.
    try testing.expectEqual(@as(usize, 2), annots.len);
    try testing.expectEqual(pdf.annot.Kind.highlight, annots[1].kind);

    try s.addNote(0, 100, 20, .{ .contents = "remember" });
    try testing.expectEqual(@as(usize, 3), (try s.annotations(aa, 0)).len);

    try s.undo();
    try testing.expectEqual(@as(usize, 2), (try s.annotations(aa, 0)).len);
    try s.undo();
    try testing.expectEqualSlices(u8, original, s.bytes());
    try testing.expect(!s.dirty());
    try testing.expectError(error.NothingToUndo, s.undo());
}

test "form fields can be filled and the value survives an undo of a later edit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const s = try Session.openBytes(testing.allocator, try testPdf(aa));
    defer s.close();
    var all = try s.fields(aa);
    try testing.expectEqual(@as(usize, 1), all.len);
    try s.fillText(all[0], "Dakota");
    all = try s.fields(aa);
    try testing.expectEqualStrings("Dakota", all[0].value);
    try s.addNote(0, 10, 10, .{ .contents = "x" });
    try s.undo();
    try testing.expectEqualStrings("Dakota", (try s.fields(aa))[0].value);
    // The filled value is part of the page's text now.
    const lay = try s.layout(0);
    try testing.expect(std.mem.indexOf(u8, lay.text, "Dakota") != null);
}

test "bookmarks are added and removed as edits" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const s = try Session.openBytes(testing.allocator, try testPdf(aa));
    defer s.close();
    try testing.expectEqual(@as(usize, 0), (try s.outline(aa)).len);
    try s.addBookmark(0, "Start", 10);
    const items = try s.outline(aa);
    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expectEqual(@as(?f64, 90), items[0].dest.?.y); // 100 high, 10 down from the top
    try s.removeBookmark(items[0].num);
    try testing.expectEqual(@as(usize, 0), (try s.outline(aa)).len);
    try s.undo();
    try testing.expectEqual(@as(usize, 1), (try s.outline(aa)).len);
}

test "the date is in PDF form" {
    var buf: [20]u8 = undefined;
    try testing.expectEqualStrings("D:20261107121530Z", pdfDate(&buf, 1794053730));
}
