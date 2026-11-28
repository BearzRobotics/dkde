// SPDX-License-Identifier: GPL-2.0-or-later
//! Making a new PDF from pages of others: delete, reorder, rotate, merge,
//! extract and split. pdf-zig's `compose.Builder` writes a complete new file,
//! which does not carry document information, page labels, attachments,
//! scripts, signatures or links to other files, so the result is always saved
//! as a new file and never replaces the one it came from.
//! Leaving a page out is not redaction (see `dkde-pdf(1)`).

const std = @import("std");
const pdf = @import("pdf");
const render = @import("pdfrender");

const Allocator = std.mem.Allocator;

/// One page of the new document.
pub const Item = struct {
    /// Which of the source documents, and which of its pages.
    source: usize,
    page: usize,
    /// Quarter turns clockwise, added to the page's own rotation.
    turn: u2 = 0,
    /// Set for a new empty page of this width and height in points; `source`
    /// and `page` then mean nothing.
    blank: ?[2]f64 = null,
};

pub const Error = pdf.compose.Error || error{ WriteFailed, NoSuchSource };

/// The new file made of `items`, in order; the caller frees it. Pages that
/// come one after another from the same source are copied together, which
/// keeps the links among them and copies what they share once.
pub fn compose(gpa: Allocator, sources: []const *render.Document, items: []const Item) Error![]u8 {
    if (items.len == 0) return error.NoPages;
    var builder = pdf.compose.Builder.init(gpa, .{});
    defer builder.deinit();
    var run: std.ArrayList(usize) = .empty;
    defer run.deinit(gpa);
    var in_run: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer in_run.deinit(gpa);

    var start: usize = 0;
    while (start < items.len) {
        if (items[start].blank) |size| {
            try builder.addBlankPage(size[0], size[1]);
            if (items[start].turn != 0) try builder.setRotation(start, @as(i32, items[start].turn) * 90);
            start += 1;
            continue;
        }
        const source = items[start].source;
        if (source >= sources.len) return error.NoSuchSource;
        run.clearRetainingCapacity();
        in_run.clearRetainingCapacity();
        var end = start;
        // One call may not name a page twice.
        while (end < items.len and items[end].blank == null and items[end].source == source and !in_run.contains(items[end].page)) : (end += 1) {
            try run.append(gpa, items[end].page);
            try in_run.put(gpa, items[end].page, {});
        }
        const doc = sources[source];
        try builder.importPages(&doc.doc, run.items, .{});
        for (items[start..end], start..) |item, at| {
            if (item.turn == 0) continue;
            const page = pdf.pages.page(&doc.doc, doc.pages, item.page) orelse return error.NoSuchPage;
            try builder.setRotation(at, @mod(@as(i32, page.rotate) + @as(i32, item.turn) * 90, 360));
        }
        start = end;
    }

    // The first source gives the new file its title and the rest of its description.
    if (sources.len > 0) {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        try builder.setInfo(try describe(arena.allocator(), sources[0]));
    }

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try builder.write(&out.writer);
    return out.toOwnedSlice();
}

/// The title, author, subject and keywords `doc` gives for itself.
fn describe(a: Allocator, doc: *render.Document) Allocator.Error!pdf.compose.Builder.Info {
    var info: pdf.compose.Builder.Info = .{};
    const entry = doc.doc.get(doc.doc.trailer, "Info") orelse return info;
    const dict = entry.asDict() orelse return info;
    inline for (.{ .{ "Title", "title" }, .{ "Author", "author" }, .{ "Subject", "subject" }, .{ "Keywords", "keywords" } }) |pair| {
        if (doc.doc.get(dict, pair[0])) |value| {
            if (value == .string) @field(info, pair[1]) = try pdf.write.textToUtf8(a, value.string);
        }
    }
    return info;
}

// ---- editing the list ------------------------------------------------------------------------

/// Moves the marked items one place towards the front; a block of them that is
/// already at the front stays. The marks move with their items.
pub fn moveEarlier(items: []Item, marked: []bool) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        if (marked[i] and !marked[i - 1]) {
            std.mem.swap(Item, &items[i], &items[i - 1]);
            std.mem.swap(bool, &marked[i], &marked[i - 1]);
        }
    }
}

/// `moveEarlier`, towards the end.
pub fn moveLater(items: []Item, marked: []bool) void {
    std.mem.reverse(Item, items);
    std.mem.reverse(bool, marked);
    moveEarlier(items, marked);
    std.mem.reverse(Item, items);
    std.mem.reverse(bool, marked);
}

/// The file name of part `number` (from 1) of `parts` when splitting to
/// `path`: `book.pdf` gives `book-01.pdf`, with as many digits as `parts` has.
pub fn partPath(a: Allocator, path: []const u8, number: usize, parts: usize) Allocator.Error![:0]u8 {
    const has_suffix = std.ascii.endsWithIgnoreCase(path, ".pdf");
    const stem = if (has_suffix) path[0 .. path.len - 4] else path;
    var digits: usize = 1;
    var left = parts;
    while (left >= 10) : (left /= 10) digits += 1;
    var buf: [24]u8 = undefined;
    const plain = std.fmt.bufPrint(&buf, "{d}", .{number}) catch unreachable;
    const zeros = "00000000000000000000";
    return std.fmt.allocPrintSentinel(a, "{s}-{s}{s}.pdf", .{ stem, zeros[0..digits -| plain.len], plain }, 0);
}

/// Whether two paths name one file, through symbolic and hard links too.
pub fn sameFile(io: std.Io, a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    const cwd = std.Io.Dir.cwd();
    const first = cwd.statFile(io, a, .{}) catch return false;
    const second = cwd.statFile(io, b, .{}) catch return false;
    if (first.inode != second.inode or first.size != second.size) return false;
    // There is no device number to go with the inode, so the real path or the
    // time of the last change must agree too (hard links share the latter).
    var one: [std.fs.max_path_bytes]u8 = undefined;
    var two: [std.fs.max_path_bytes]u8 = undefined;
    const n = cwd.realPathFile(io, a, &one) catch return false;
    const m = cwd.realPathFile(io, b, &two) catch return false;
    return std.mem.eql(u8, one[0..n], two[0..m]) or first.mtime.nanoseconds == second.mtime.nanoseconds;
}

// ---- tests -----------------------------------------------------------------------------------

const testing = std.testing;

/// A file with one page for each of `words`, each page showing its word.
fn wordPdf(a: Allocator, words: []const []const u8) ![]u8 {
    var bodies: std.ArrayList([]const u8) = .empty;
    try bodies.append(a, "<< /Type /Catalog /Pages 2 0 R >>");
    var kids: std.ArrayList(u8) = .empty;
    for (words, 0..) |_, i| try kids.print(a, "{d} 0 R ", .{4 + 2 * i});
    try bodies.append(a, try std.fmt.allocPrint(a, "<< /Type /Pages /Kids [{s}] /Count {d} >>", .{ kids.items, words.len }));
    try bodies.append(a, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>");
    for (words, 0..) |word, i| {
        try bodies.append(a, try std.fmt.allocPrint(a, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Contents {d} 0 R /Resources << /Font << /F1 3 0 R >> >> >>", .{5 + 2 * i}));
        const content = try std.fmt.allocPrint(a, "BT /F1 12 Tf 10 50 Td ({s}) Tj ET", .{word});
        try bodies.append(a, try std.fmt.allocPrint(a, "<< /Length {d} >>\nstream\n{s}\nendstream", .{ content.len, content }));
    }
    var file: std.ArrayList(u8) = .empty;
    try file.appendSlice(a, "%PDF-1.7\n");
    const offsets = try a.alloc(usize, bodies.items.len);
    for (bodies.items, 0..) |body, i| {
        offsets[i] = file.items.len;
        try file.print(a, "{d} 0 obj\n{s}\nendobj\n", .{ i + 1, body });
    }
    const xref = file.items.len;
    try file.print(a, "xref\n0 {d}\n0000000000 65535 f \n", .{bodies.items.len + 1});
    for (offsets) |o| try file.print(a, "{d:0>10} 00000 n \n", .{o});
    try file.print(a, "trailer\n<< /Size {d} /Root 1 0 R >>\nstartxref\n{d}\n%%EOF\n", .{ bodies.items.len + 1, xref });
    return file.items;
}

fn expectPages(bytes: []const u8, words: []const []const u8) !void {
    const doc = try render.Document.openFromMemory(testing.allocator, bytes);
    defer doc.close();
    try testing.expectEqual(words.len, doc.pageCount());
    for (words, 0..) |word, i| {
        const text = try render.pageText(testing.allocator, doc, i);
        defer testing.allocator.free(text);
        try testing.expectEqualStrings(word, std.mem.trim(u8, text, " \n\x0c"));
    }
}

test "pages are merged, reordered, repeated, left out and turned" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = try render.Document.openFromMemory(testing.allocator, try wordPdf(a, &.{ "one", "two", "three" }));
    defer first.close();
    const second = try render.Document.openFromMemory(testing.allocator, try wordPdf(a, &.{ "red", "blue" }));
    defer second.close();

    const bytes = try compose(testing.allocator, &.{ first, second }, &.{
        .{ .source = 0, .page = 2 },
        .{ .source = 1, .page = 1, .turn = 1 },
        .{ .source = 0, .page = 0 },
        .{ .source = 0, .page = 0 },
    });
    defer testing.allocator.free(bytes);
    try expectPages(bytes, &.{ "three", "blue", "one", "one" });

    const made = try render.Document.openFromMemory(testing.allocator, bytes);
    defer made.close();
    // The turned page is now taller than wide.
    const turned = render.pageSize(made, 1).?;
    try testing.expect(turned.h > turned.w);
    const straight = render.pageSize(made, 0).?;
    try testing.expect(straight.w > straight.h);

    try testing.expectError(error.NoPages, compose(testing.allocator, &.{first}, &.{}));
    try testing.expectError(error.NoSuchPage, compose(testing.allocator, &.{first}, &.{.{ .source = 0, .page = 9 }}));
}

test "blank pages go between others, and the title comes along" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var file = try wordPdf(a, &.{ "one", "two" });
    // Give the file a title through the trailer.
    const titled = try std.mem.replaceOwned(u8, a, file, "/Root 1 0 R >>", "/Root 1 0 R /Info << /Title (My Report) /Author (Ada) >> >>");
    file = titled;
    const source = try render.Document.openFromMemory(testing.allocator, file);
    defer source.close();
    const bytes = try compose(testing.allocator, &.{source}, &.{
        .{ .source = 0, .page = 0 },
        .{ .source = 0, .page = 0, .blank = .{ 300, 500 } },
        .{ .source = 0, .page = 1 },
    });
    defer testing.allocator.free(bytes);
    try expectPages(bytes, &.{ "one", "", "two" });
    const made = try render.Document.openFromMemory(testing.allocator, bytes);
    defer made.close();
    try testing.expectEqual(@as(f64, 500), render.pageSize(made, 1).?.h);
    const info = try describe(a, made);
    try testing.expectEqualStrings("My Report", info.title);
    try testing.expectEqualStrings("Ada", info.author);
}

test "marked items move one place and stop at the ends" {
    var items = [_]Item{ .{ .source = 0, .page = 0 }, .{ .source = 0, .page = 1 }, .{ .source = 0, .page = 2 }, .{ .source = 0, .page = 3 } };
    var marked = [_]bool{ true, false, true, true };
    moveEarlier(&items, &marked);
    for ([_]usize{ 0, 2, 3, 1 }, items) |page, item| try testing.expectEqual(page, item.page);
    try testing.expectEqualSlices(bool, &.{ true, true, true, false }, &marked);
    moveLater(&items, &marked);
    for ([_]usize{ 1, 0, 2, 3 }, items) |page, item| try testing.expectEqual(page, item.page);
    try testing.expectEqualSlices(bool, &.{ false, true, true, true }, &marked);
}

test "part names are numbered with leading zeros" {
    const a = testing.allocator;
    for ([_]struct { path: []const u8, n: usize, of: usize, want: []const u8 }{
        .{ .path = "/x/book.pdf", .n = 1, .of = 9, .want = "/x/book-1.pdf" },
        .{ .path = "/x/book.PDF", .n = 7, .of = 120, .want = "/x/book-007.pdf" },
        .{ .path = "notes", .n = 10, .of = 10, .want = "notes-10.pdf" },
    }) |case| {
        const got = try partPath(a, case.path, case.n, case.of);
        defer a.free(got);
        try testing.expectEqualStrings(case.want, got);
    }
}

test "links to a file count as that file" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    try tmp.dir.writeFile(io, .{ .sub_path = "one.pdf", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "two.pdf", .data = "x" });
    try tmp.dir.symLink(io, "one.pdf", "soft.pdf", .{});
    try std.Io.Dir.hardLink(tmp.dir, "one.pdf", tmp.dir, "hard.pdf", io, .{});
    const path = struct {
        fn of(al: Allocator, d: []const u8, name: []const u8) ![]u8 {
            return std.fmt.allocPrint(al, "{s}/{s}", .{ d, name });
        }
    };
    const one = try path.of(a, dir, "one.pdf");
    try testing.expect(sameFile(io, one, one));
    try testing.expect(sameFile(io, one, try path.of(a, dir, "soft.pdf")));
    try testing.expect(sameFile(io, one, try path.of(a, dir, "hard.pdf")));
    try testing.expect(sameFile(io, one, try path.of(a, dir, "./one.pdf")));
    try testing.expect(!sameFile(io, one, try path.of(a, dir, "two.pdf")));
    try testing.expect(!sameFile(io, one, try path.of(a, dir, "missing.pdf")));
}
