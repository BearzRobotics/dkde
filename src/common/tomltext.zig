//! Editing a TOML file as text, so that comments, blank lines, ordering and
//! formatting survive a change. The TOML library parses to a document that does
//! not keep comments; these functions change only the lines they must.
//!
//! They understand the files dkde writes: `[group]` tables (the name may be
//! quoted) holding `key = value` lines, where a value may span lines (arrays,
//! multi-line strings) and may be followed by a `# comment`. Anything else
//! (arrays of tables, dotted keys) makes a function return `error.Unsupported`
//! and the caller falls back to rewriting the file from the parsed document.

const std = @import("std");

pub const Error = error{ OutOfMemory, Unsupported };

const Entry = struct {
    key: []const u8,
    /// First line of the comment block directly above the key (== `start` when none).
    comment: usize,
    /// Lines `start..end` hold the key and its value.
    start: usize,
    end: usize,
    /// `# ...` after the value on its last line, if any.
    trailing: ?[]const u8,
};

const Section = struct {
    /// Table name; "" for lines before the first header.
    name: []const u8,
    /// Line of the header, or null for the lines before the first header.
    header: ?usize,
    /// First line of the comment block directly above the header.
    comment: usize,
    entries: std.ArrayList(Entry) = .empty,
    /// One past the section's last key (or its header when it has no keys).
    end: usize,
    array_table: bool = false,
};

const Layout = struct {
    a: std.mem.Allocator,
    lines: std.ArrayList([]const u8) = .empty,
    sections: std.ArrayList(Section) = .empty,
    /// Names that had to be unquoted live here.
    names: std.ArrayList([]u8) = .empty,

    fn deinit(self: *Layout) void {
        for (self.sections.items) |*s| s.entries.deinit(self.a);
        self.sections.deinit(self.a);
        self.lines.deinit(self.a);
        for (self.names.items) |n| self.a.free(n);
        self.names.deinit(self.a);
    }

    fn find(self: *const Layout, group: []const u8) ?*Section {
        for (self.sections.items) |*s| {
            if (s.header != null and !s.array_table and std.mem.eql(u8, s.name, group)) return s;
        }
        return null;
    }
};

fn isBlankOrComment(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t\r");
    return t.len == 0 or t[0] == '#';
}

fn isComment(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t\r");
    return t.len > 0 and t[0] == '#';
}

/// The comment block directly above line `i` (no blank line between).
fn commentStart(lines: []const []const u8, i: usize) usize {
    var s = i;
    while (s > 0 and isComment(lines[s - 1])) s -= 1;
    return s;
}

/// Splits a (possibly quoted) key or table name at its start. Returns the name
/// and the rest of the text after it.
fn takeName(l: *Layout, text: []const u8) Error!struct { name: []const u8, rest: []const u8 } {
    const t = std.mem.trimStart(u8, text, " \t");
    if (t.len == 0) return error.Unsupported;
    if (t[0] == '"' or t[0] == '\'') {
        const q = t[0];
        var i: usize = 1;
        while (i < t.len and t[i] != q) : (i += 1) {
            if (q == '"' and t[i] == '\\') return error.Unsupported; // escapes: let the library handle it
        }
        if (i >= t.len) return error.Unsupported;
        return .{ .name = t[1..i], .rest = t[i + 1 ..] };
    }
    var i: usize = 0;
    while (i < t.len and (std.ascii.isAlphanumeric(t[i]) or t[i] == '_' or t[i] == '-' or t[i] == '.')) : (i += 1) {}
    if (i == 0) return error.Unsupported;
    _ = l;
    return .{ .name = t[0..i], .rest = t[i..] };
}

const ValueEnd = struct { line: usize, trailing: ?[]const u8 };

/// Finds where the value that starts at `text` (on line `first`) ends.
fn valueEnd(lines: []const []const u8, first: usize, text: []const u8) Error!ValueEnd {
    const Str = enum { none, basic, literal, multi_basic, multi_literal };
    var str: Str = .none;
    var depth: usize = 0;
    var i = first;
    var cur = text;
    while (true) {
        var c: usize = 0;
        var trailing: ?[]const u8 = null;
        while (c < cur.len) : (c += 1) {
            const ch = cur[c];
            switch (str) {
                .none => switch (ch) {
                    '#' => {
                        trailing = cur[c..];
                        break;
                    },
                    '"' => if (std.mem.startsWith(u8, cur[c..], "\"\"\"")) {
                        str = .multi_basic;
                        c += 2;
                    } else {
                        str = .basic;
                    },
                    '\'' => if (std.mem.startsWith(u8, cur[c..], "'''")) {
                        str = .multi_literal;
                        c += 2;
                    } else {
                        str = .literal;
                    },
                    '[', '{' => depth += 1,
                    ']', '}' => depth = std.math.sub(usize, depth, 1) catch return error.Unsupported,
                    else => {},
                },
                .basic => switch (ch) {
                    '\\' => c += 1,
                    '"' => str = .none,
                    else => {},
                },
                .literal => if (ch == '\'') {
                    str = .none;
                },
                .multi_basic => switch (ch) {
                    '\\' => c += 1,
                    '"' => if (std.mem.startsWith(u8, cur[c..], "\"\"\"")) {
                        str = .none;
                        c += 2;
                    },
                    else => {},
                },
                .multi_literal => if (ch == '\'' and std.mem.startsWith(u8, cur[c..], "'''")) {
                    str = .none;
                    c += 2;
                },
            }
        }
        // A single-line string left open is a syntax error.
        if (str == .basic or str == .literal) return error.Unsupported;
        if (depth == 0 and str == .none) {
            if (trailing) |t| {
                // Keep the space before the comment out; callers add one.
                return .{ .line = i + 1, .trailing = t };
            }
            return .{ .line = i + 1, .trailing = null };
        }
        i += 1;
        if (i >= lines.len) return error.Unsupported;
        cur = lines[i];
    }
}

fn parse(a: std.mem.Allocator, text: []const u8) Error!Layout {
    var l: Layout = .{ .a = a };
    errdefer l.deinit();
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| try l.lines.append(a, line);
    // A trailing newline yields one empty last "line"; drop it so line counts
    // match the file's real lines. `join` puts the newline back.
    if (l.lines.items.len > 0 and l.lines.items[l.lines.items.len - 1].len == 0) _ = l.lines.pop();

    try l.sections.append(a, .{ .name = "", .header = null, .comment = 0, .end = 0 });
    var i: usize = 0;
    while (i < l.lines.items.len) {
        const line = l.lines.items[i];
        if (isBlankOrComment(line)) {
            i += 1;
            continue;
        }
        const t = std.mem.trim(u8, line, " \t\r");
        if (t[0] == '[') {
            const arr = std.mem.startsWith(u8, t, "[[");
            const inner_start: usize = if (arr) 2 else 1;
            const nm = try takeName(&l, t[inner_start..]);
            const close = std.mem.trimStart(u8, nm.rest, " \t");
            const want: []const u8 = if (arr) "]]" else "]";
            if (!std.mem.startsWith(u8, close, want)) return error.Unsupported;
            const after = std.mem.trim(u8, close[want.len..], " \t\r");
            if (after.len > 0 and after[0] != '#') return error.Unsupported;
            try l.sections.append(a, .{
                .name = nm.name,
                .header = i,
                .comment = commentStart(l.lines.items, i),
                .end = i + 1,
                .array_table = arr,
            });
            i += 1;
            continue;
        }
        // key = value
        const nm = try takeName(&l, line);
        const rest = std.mem.trimStart(u8, nm.rest, " \t");
        if (rest.len == 0 or rest[0] != '=') return error.Unsupported;
        const ve = try valueEnd(l.lines.items, i, rest[1..]);
        const sec = &l.sections.items[l.sections.items.len - 1];
        try sec.entries.append(a, .{
            .key = nm.name,
            .comment = commentStart(l.lines.items, i),
            .start = i,
            .end = ve.line,
            .trailing = ve.trailing,
        });
        sec.end = ve.line;
        i = ve.line;
    }
    return l;
}

/// Joins lines back into text, each followed by a newline.
fn join(a: std.mem.Allocator, lines: []const []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for (lines) |line| {
        try out.appendSlice(a, line);
        try out.append(a, '\n');
    }
    return out.toOwnedSlice(a);
}

/// Splits `text` (a rendered value, no trailing newline) into lines.
fn splitInto(a: std.mem.Allocator, list: *std.ArrayList([]const u8), text: []const u8) Error!void {
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    while (it.next()) |line| try list.append(a, line);
}

/// A table name as it must appear in a header.
pub fn headerFor(a: std.mem.Allocator, group: []const u8) Error![]u8 {
    var bare = group.len > 0;
    for (group) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) bare = false;
    }
    if (bare) return std.fmt.allocPrint(a, "[{s}]", .{group});
    for (group) |c| if (c == '"' or c == '\\' or c < 0x20) return error.Unsupported;
    return std.fmt.allocPrint(a, "[\"{s}\"]", .{group});
}

/// Sets `key` in `[group]`. `rendered` is the whole `key = value` text (it may
/// span lines, without a trailing newline). The key's place, a comment after
/// its value and every other line stay as they are.
pub fn setKey(a: std.mem.Allocator, text: []const u8, group: []const u8, key: []const u8, rendered: []const u8) Error![]u8 {
    var l = try parse(a, text);
    defer l.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(a);
    var extra: std.ArrayList([]u8) = .empty;
    defer {
        for (extra.items) |e| a.free(e);
        extra.deinit(a);
    }

    const lines = l.lines.items;
    if (l.find(group)) |sec| {
        for (sec.entries.items) |e| {
            if (!std.mem.eql(u8, e.key, key)) continue;
            try out.appendSlice(a, lines[0..e.start]);
            const first = out.items.len;
            try splitInto(a, &out, rendered);
            if (e.trailing) |tr| {
                const last = out.items.len - 1;
                const joined = try std.fmt.allocPrint(a, "{s} {s}", .{ out.items[last], tr });
                try extra.append(a, joined);
                out.items[last] = joined;
            }
            _ = first;
            try out.appendSlice(a, lines[e.end..]);
            return join(a, out.items);
        }
        // New key: after the section's last key, or right after its header.
        const at = sec.end;
        try out.appendSlice(a, lines[0..at]);
        try splitInto(a, &out, rendered);
        try out.appendSlice(a, lines[at..]);
        return join(a, out.items);
    }

    // New table at the end of the file.
    const header = try headerFor(a, group);
    try extra.append(a, header);
    try out.appendSlice(a, lines);
    if (lines.len > 0 and !isBlankLast(lines)) try out.append(a, "");
    try out.append(a, header);
    try splitInto(a, &out, rendered);
    return join(a, out.items);
}

fn isBlankLast(lines: []const []const u8) bool {
    return std.mem.trim(u8, lines[lines.len - 1], " \t\r").len == 0;
}

/// Removes `key` from `[group]`; a missing key is not an error.
pub fn removeKey(a: std.mem.Allocator, text: []const u8, group: []const u8, key: []const u8) Error![]u8 {
    var l = try parse(a, text);
    defer l.deinit();
    const sec = l.find(group) orelse return a.dupe(u8, text);
    for (sec.entries.items) |e| {
        if (!std.mem.eql(u8, e.key, key)) continue;
        var out: std.ArrayList([]const u8) = .empty;
        defer out.deinit(a);
        try out.appendSlice(a, l.lines.items[0..e.start]);
        try out.appendSlice(a, l.lines.items[e.end..]);
        return join(a, out.items);
    }
    return a.dupe(u8, text);
}

/// Removes the whole `[group]` table (its header and keys, not the comment above).
pub fn removeGroup(a: std.mem.Allocator, text: []const u8, group: []const u8) Error![]u8 {
    var l = try parse(a, text);
    defer l.deinit();
    const sec = l.find(group) orelse return a.dupe(u8, text);
    var end = sec.end;
    if (end < l.lines.items.len and !isComment(l.lines.items[end]) and std.mem.trim(u8, l.lines.items[end], " \t\r").len == 0) end += 1;
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(a);
    try out.appendSlice(a, l.lines.items[0..sec.header.?]);
    try out.appendSlice(a, l.lines.items[end..]);
    return join(a, out.items);
}

/// Adds to `text` every table and key that `defaults` has and `text` lacks,
/// with the comments above them, and changes nothing else.
pub fn addMissing(a: std.mem.Allocator, text: []const u8, defaults: []const u8) Error![]u8 {
    var want = try parse(a, defaults);
    defer want.deinit();
    var current = try a.dupe(u8, text);
    errdefer a.free(current);

    for (want.sections.items) |ws| {
        const header = ws.header orelse continue;
        if (ws.array_table) continue;
        var have = try parse(a, current);
        defer have.deinit();
        const wl = want.lines.items;
        var out: std.ArrayList([]const u8) = .empty;
        defer out.deinit(a);
        if (have.find(ws.name)) |hs| {
            // Missing keys go after the section's last key, each with its comments.
            var added = false;
            var at = hs.end;
            _ = &at;
            try out.appendSlice(a, have.lines.items[0..hs.end]);
            for (ws.entries.items) |we| {
                var present = false;
                for (hs.entries.items) |he| {
                    if (std.mem.eql(u8, he.key, we.key)) present = true;
                }
                if (present) continue;
                try out.appendSlice(a, wl[we.comment..we.end]);
                added = true;
            }
            if (!added) continue;
            try out.appendSlice(a, have.lines.items[hs.end..]);
        } else {
            try out.appendSlice(a, have.lines.items);
            if (have.lines.items.len > 0 and !isBlankLast(have.lines.items)) try out.append(a, "");
            try out.appendSlice(a, wl[ws.comment..ws.end]);
            _ = header;
        }
        const next = try join(a, out.items);
        a.free(current);
        current = next;
    }
    return current;
}

// ---- tests ---------------------------------------------------------------------------------

fn expectText(expected: []const u8, actual: []u8) !void {
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "setting a key keeps comments, order and trailing comments" {
    const a = std.testing.allocator;
    const src =
        \\# top
        \\[panel]
        \\# height of the bar
        \\height = 40 # pixels
        \\
        \\# where
        \\position = "bottom"
        \\
        \\[other]
        \\x = 1
        \\
    ;
    try expectText(
        \\# top
        \\[panel]
        \\# height of the bar
        \\height = 64 # pixels
        \\
        \\# where
        \\position = "bottom"
        \\
        \\[other]
        \\x = 1
        \\
    , try setKey(a, src, "panel", "height", "height = 64"));
}

test "a new key lands after the last key of its table; a new table at the end" {
    const a = std.testing.allocator;
    const src = "[panel]\nheight = 40\n\n[other]\nx = 1\n";
    try expectText("[panel]\nheight = 40\nwidth = 5\n\n[other]\nx = 1\n", try setKey(a, src, "panel", "width", "width = 5"));
    try expectText("[panel]\nheight = 40\n\n[other]\nx = 1\n\n[\"profile:A b\"]\nk = true\n", try setKey(a, src, "profile:A b", "k", "k = true"));
}

test "multi-line values are replaced whole" {
    const a = std.testing.allocator;
    const src = "[g]\nlist = [\n  \"a\", # first\n  \"b\",\n]\nafter = 1\n";
    try expectText("[g]\nlist = [\"c\"]\nafter = 1\n", try setKey(a, src, "g", "list", "list = [\"c\"]"));
}

test "remove a key and a table" {
    const a = std.testing.allocator;
    const src = "# c\n[a]\nx = 1\ny = 2\n\n[b]\nz = 3\n";
    try expectText("# c\n[a]\ny = 2\n\n[b]\nz = 3\n", try removeKey(a, src, "a", "x"));
    try expectText("# c\n[a]\nx = 1\ny = 2\n\n", try removeGroup(a, src, "b"));
}

test "missing keys come in with their comments" {
    const a = std.testing.allocator;
    const defaults = "[a]\n# the x\nx = 1\n# the y\ny = 2\n\n# table b\n[b]\n# z!\nz = 3\n";
    try expectText(
        "[a]\nx = 9 # mine\n# the y\ny = 2\n\n# table b\n[b]\n# z!\nz = 3\n",
        try addMissing(a, "[a]\nx = 9 # mine\n", defaults),
    );
    const full = try addMissing(a, defaults, defaults);
    try expectText(defaults, full);
}

test "unsupported layouts are reported, not mangled" {
    try std.testing.expectError(error.Unsupported, setKey(std.testing.allocator, "[[t]]\nk = 1\n[t2]\nx\n", "t2", "x", "x = 1"));
}
