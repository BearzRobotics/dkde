//! Turns an `md.Document` into plain text plus a list of styled ranges, which
//! `main.zig` applies to a GtkTextBuffer. Keeping this free of GTK makes it
//! testable: every range is in characters (code points), as GtkTextBuffer
//! counts them, not in bytes.
//!
//! One renderer serves every source: Markdown, man(7) and mdoc(7) pages all
//! arrive as an `md.Document` (dkman.render.parse).

const std = @import("std");
const md = @import("dkman").md;
const Allocator = std.mem.Allocator;

pub const Style = enum {
    h1,
    h2,
    h3,
    bold,
    italic,
    code,
    code_block,
    quote,
    link,
    strike,
    term,
};

pub const Error = Allocator.Error;

const rule = "\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}";

pub const Span = struct { start: u32, end: u32, style: Style };

pub const Rendered = struct {
    text: []u8,
    spans: []Span,

    pub fn deinit(self: Rendered, gpa: Allocator) void {
        gpa.free(self.text);
        gpa.free(self.spans);
    }
};

const Builder = struct {
    gpa: Allocator,
    text: std.ArrayList(u8) = .empty,
    spans: std.ArrayList(Span) = .empty,
    /// Characters written so far.
    chars: u32 = 0,

    fn put(self: *Builder, s: []const u8) Allocator.Error!void {
        try self.text.appendSlice(self.gpa, s);
        // Invalid UTF-8 cannot come from the parsers, but count bytes then
        // rather than fail: GTK would reject the text first.
        self.chars += @intCast(std.unicode.utf8CountCodepoints(s) catch s.len);
    }

    fn span(self: *Builder, start: u32, style: Style) Allocator.Error!void {
        if (self.chars > start) try self.spans.append(self.gpa, .{ .start = start, .end = self.chars, .style = style });
    }

    /// Ends a block with a blank line, without stacking blank lines.
    fn blankLine(self: *Builder) Allocator.Error!void {
        const t = self.text.items;
        if (t.len == 0) return;
        if (!std.mem.endsWith(u8, t, "\n")) try self.put("\n");
        if (!std.mem.endsWith(u8, self.text.items, "\n\n")) try self.put("\n");
    }

    fn lineBreak(self: *Builder) Allocator.Error!void {
        if (self.text.items.len > 0 and !std.mem.endsWith(u8, self.text.items, "\n")) try self.put("\n");
    }
};

fn depth(node: *const md.Node, kind: md.Kind) usize {
    var n: usize = 0;
    var p = node.parent;
    while (p) |q| : (p = q.parent) {
        if (q.kind == kind) n += 1;
    }
    return n;
}

/// The document as text and styled ranges. The caller frees the result.
pub fn render(gpa: Allocator, doc: *const md.Document) Allocator.Error!Rendered {
    var b: Builder = .{ .gpa = gpa };
    errdefer b.text.deinit(gpa);
    errdefer b.spans.deinit(gpa);

    // Start offsets of the containers being walked, innermost last.
    var starts: std.ArrayList(u32) = .empty;
    defer starts.deinit(gpa);

    var walker = md.Walker.init(doc.root);
    while (walker.next()) |ev| {
        const node = ev.node;
        if (ev.entering) {
            switch (node.kind) {
                .heading, .emph, .strong, .strikethrough, .link, .block_quote, .deflist_term, .deflist_def => try starts.append(gpa, b.chars),
                .item => {
                    try starts.append(gpa, b.chars);
                    try b.lineBreak();
                    const indent = depth(node, .list) -| 1;
                    for (0..indent) |_| try b.put("    ");
                    const list = node.parent.?;
                    if (node.task != .none) {
                        try b.put(if (node.task == .checked) "\u{2611} " else "\u{2610} ");
                    } else if (list.list.kind == .ordered) {
                        var n: u32 = list.list.start;
                        var p = node.prev;
                        while (p) |q| : (p = q.prev) n += 1;
                        var buf: [16]u8 = undefined;
                        try b.put(std.fmt.bufPrint(&buf, "{d}. ", .{n}) catch "");
                    } else {
                        try b.put("\u{2022} ");
                    }
                },
                .text => try b.put(node.literal),
                .softbreak => try b.put(" "),
                .linebreak => try b.put("\n"),
                .code => {
                    const s = b.chars;
                    try b.put(node.literal);
                    try b.span(s, .code);
                },
                .code_block => {
                    try b.lineBreak();
                    const s = b.chars;
                    try b.put(node.literal);
                    try b.span(s, .code_block);
                    try b.blankLine();
                },
                .thematic_break => {
                    try b.lineBreak();
                    try b.put(rule);
                    try b.blankLine();
                },
                .table_cell => {
                    if (node.prev != null) try b.put(" \u{2502} ");
                },
                // Raw HTML and front matter are not shown.
                .html_block, .html_inline, .front_matter => {},
                else => {},
            }
        } else {
            switch (node.kind) {
                .heading => {
                    const s = starts.pop().?;
                    try b.span(s, switch (node.level) {
                        1 => .h1,
                        2 => .h2,
                        else => .h3,
                    });
                    try b.blankLine();
                },
                .emph => try b.span(starts.pop().?, .italic),
                .strong => try b.span(starts.pop().?, .bold),
                .strikethrough => try b.span(starts.pop().?, .strike),
                .link => try b.span(starts.pop().?, .link),
                .block_quote, .deflist_def => {
                    try b.span(starts.pop().?, .quote);
                },
                .deflist_term => {
                    try b.span(starts.pop().?, .term);
                    try b.lineBreak();
                },
                .item => {
                    _ = starts.pop();
                    try b.lineBreak();
                },
                .paragraph => {
                    // A paragraph in a tight list item ends with a single newline.
                    const tight = if (node.parent) |p| (p.kind == .item and p.parent.?.list.tight) else false;
                    if (tight) try b.lineBreak() else try b.blankLine();
                },
                .list => if (node.parent == null or node.parent.?.kind != .item) try b.blankLine(),
                .table_row => try b.lineBreak(),
                .table => try b.blankLine(),
                else => {},
            }
        }
    }

    // Trailing blank lines are noise at the end of the page.
    while (b.text.items.len > 1 and std.mem.endsWith(u8, b.text.items, "\n\n")) {
        _ = b.text.pop();
        b.chars -= 1;
    }
    for (b.spans.items) |*s| s.end = @min(s.end, b.chars);

    const text = try b.text.toOwnedSlice(gpa);
    errdefer gpa.free(text);
    return .{ .text = text, .spans = try b.spans.toOwnedSlice(gpa) };
}

fn parseForTest(gpa: Allocator, source: []const u8) !md.Document {
    return md.Document.parse(gpa, source, .{ .extensions = md.Extensions.all });
}

fn hasSpan(r: Rendered, style: Style, want: []const u8) bool {
    for (r.spans) |s| {
        if (s.style != style) continue;
        // ASCII test input: characters are bytes.
        if (std.mem.eql(u8, r.text[s.start..s.end], want)) return true;
    }
    return false;
}

test "headings, emphasis and code get ranges" {
    const t = std.testing;
    var doc = try parseForTest(t.allocator, "# Title\n\nSome *slanted* and **heavy** and `mono` text.\n");
    defer doc.deinit();
    const r = try render(t.allocator, &doc);
    defer r.deinit(t.allocator);
    try t.expectEqualStrings("Title\n\nSome slanted and heavy and mono text.\n", r.text);
    try t.expect(hasSpan(r, .h1, "Title"));
    try t.expect(hasSpan(r, .italic, "slanted"));
    try t.expect(hasSpan(r, .bold, "heavy"));
    try t.expect(hasSpan(r, .code, "mono"));
}

test "lists are numbered and nested" {
    const t = std.testing;
    var doc = try parseForTest(t.allocator, "1. one\n2. two\n   - inner\n\n- dot\n");
    defer doc.deinit();
    const r = try render(t.allocator, &doc);
    defer r.deinit(t.allocator);
    try t.expect(std.mem.indexOf(u8, r.text, "1. one\n") != null);
    try t.expect(std.mem.indexOf(u8, r.text, "2. two\n") != null);
    try t.expect(std.mem.indexOf(u8, r.text, "    \u{2022} inner\n") != null);
    try t.expect(std.mem.indexOf(u8, r.text, "\u{2022} dot") != null);
}

test "ranges count characters, not bytes" {
    const t = std.testing;
    var doc = try parseForTest(t.allocator, "caf\u{e9} **bold**\n");
    defer doc.deinit();
    const r = try render(t.allocator, &doc);
    defer r.deinit(t.allocator);
    const bold = for (r.spans) |s| {
        if (s.style == .bold) break s;
    } else return error.TestUnexpectedResult;
    try t.expectEqual(@as(u32, 5), bold.start);
    try t.expectEqual(@as(u32, 9), bold.end);
}

test "man pages render through the same path" {
    const t = std.testing;
    var doc = try @import("dkman").render.parse(t.allocator, .man, ".TH A 1\n.SH NAME\na \\- a thing\n");
    defer doc.deinit();
    const r = try render(t.allocator, &doc);
    defer r.deinit(t.allocator);
    try t.expect(std.mem.indexOf(u8, r.text, "a - a thing") != null);
}

test "empty and plain documents give empty text" {
    const t = std.testing;
    var doc = try @import("dkman").render.parse(t.allocator, .plain, "x");
    defer doc.deinit();
    const r = try render(t.allocator, &doc);
    defer r.deinit(t.allocator);
    try t.expectEqual(@as(usize, 0), r.text.len);
}
