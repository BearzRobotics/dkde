//! Makes Kaitai `.ksy` text digestible for the vendored YAML parser, which
//! lacks block scalars (`doc: |`) and trailing comments. Block scalar bodies
//! are documentation in practice, so they are replaced by an empty string.

const std = @import("std");
const Allocator = std.mem.Allocator;

fn indentOf(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and line[n] == ' ') n += 1;
    return n;
}

/// Returns `line` without a trailing comment (a `#` outside quotes that starts
/// the line or follows a space). `open` is set when a quoted string is still
/// unterminated at the end, i.e. the value continues on the next line.
fn stripComment(line: []const u8, open: *bool) []const u8 {
    var quote: u8 = 0;
    open.* = false;
    for (line, 0..) |c, i| {
        if (quote != 0) {
            if (c == quote and !(quote == '"' and i > 0 and line[i - 1] == '\\')) quote = 0;
        } else if (c == '"' or c == '\'') {
            // A quote only opens a string at the start of a value.
            if (i == 0 or line[i - 1] == ' ' or line[i - 1] == '[' or line[i - 1] == ',') quote = c;
        } else if (c == '#' and (i == 0 or line[i - 1] == ' ')) {
            return std.mem.trimEnd(u8, line[0..i], " \t\r");
        }
    }
    open.* = quote != 0;
    return std.mem.trimEnd(u8, line, " \t\r");
}

fn isBlockIndicator(rest: []const u8) bool {
    if (rest.len == 0 or (rest[0] != '|' and rest[0] != '>')) return false;
    for (rest[1..]) |c| if (c != '-' and c != '+' and !std.ascii.isDigit(c)) return false;
    return true;
}

/// Caller owns the result.
pub fn prepare(gpa: Allocator, source: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.splitScalar(u8, source, '\n');
    var skip_above: ?usize = null; // inside a block scalar whose key is at this indent
    var last_indent: usize = 0;
    var last_value = false; // the previous line ended in a quoted scalar
    var pending: std.ArrayList(u8) = .empty; // a quoted value continuing over lines
    defer pending.deinit(gpa);
    while (lines.next()) |raw| {
        var line = std.mem.trimEnd(u8, raw, "\r");
        if (pending.items.len > 0) {
            try pending.appendSlice(gpa, std.mem.trimStart(u8, line, " \t"));
            line = pending.items;
        }
        if (skip_above) |ind| {
            if (std.mem.trim(u8, line, " \t").len == 0 or indentOf(line) > ind) continue;
            skip_above = null;
        }
        var open: bool = undefined;
        const code = stripComment(line, &open);
        if (open) {
            if (pending.items.len == 0) try pending.appendSlice(gpa, line);
            try pending.append(gpa, ' ');
            continue;
        }
        defer pending.clearRetainingCapacity();
        if (std.mem.trim(u8, code, " ").len == 0) continue;
        // `key: |`, `- key: >-` and `- |`
        if (std.mem.lastIndexOfScalar(u8, code, ' ')) |sp| {
            if (isBlockIndicator(code[sp + 1 ..])) {
                var ind = indentOf(code);
                var body = code[ind..];
                if (std.mem.startsWith(u8, body, "- ")) {
                    ind += 2;
                    body = body[2..];
                }
                try out.appendSlice(gpa, code[0..sp]);
                try out.appendSlice(gpa, " \"\"\n");
                skip_above = ind;
                continue;
            }
        }
        const ind = indentOf(code);
        const bare = isBareScalar(code);
        if (bare and last_value and ind > last_indent and out.items.len >= 2 and out.items[out.items.len - 2] == '\'') {
            // Continuation of a plain multi-line value: fold it into the previous line.
            out.items.len -= 2;
            try out.append(gpa, ' ');
            for (std.mem.trim(u8, code, " ")) |c| {
                if (c == '\'') try out.append(gpa, '\'');
                try out.append(gpa, c);
            }
            try out.appendSlice(gpa, "'\n");
            continue;
        }
        const before = out.items.len;
        skip_above = try appendNormalised(gpa, &out, code);
        try out.append(gpa, '\n');
        last_indent = ind;
        last_value = out.items.len - before >= 3 and out.items[out.items.len - 2] == '\'';
    }
    return out.toOwnedSlice(gpa);
}

/// Keys that only carry prose or tool hints; their values are dropped.
fn isNoise(key: []const u8) bool {
    for ([_][]const u8{ "doc", "doc-ref", "-webide-representation", "-orig-id", "-affected-by" }) |k| {
        if (std.mem.eql(u8, key, k)) return true;
    }
    return false;
}

/// Keys are made of `[A-Za-z0-9_.-]` after this; anything else becomes `%XX`.
/// `unescapeKey` undoes it.
fn appendKey(gpa: Allocator, out: *std.ArrayList(u8), key: []const u8) Allocator.Error!void {
    for (key) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '-') {
            try out.append(gpa, c);
        } else {
            try out.print(gpa, "%{X:0>2}", .{c});
        }
    }
}

pub fn unescapeKey(gpa: Allocator, key: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < key.len) : (i += 1) {
        if (key[i] == '%' and i + 2 < key.len) {
            if (std.fmt.parseInt(u8, key[i + 1 .. i + 3], 16)) |b| {
                try out.append(gpa, b);
                i += 2;
                continue;
            } else |_| {}
        }
        try out.append(gpa, key[i]);
    }
    return out.toOwnedSlice(gpa);
}

fn appendScalar(gpa: Allocator, out: *std.ArrayList(u8), v: []const u8) Allocator.Error!void {
    // Flow collections and strings with escapes are handed over as raw text in
    // single quotes; the interpreter reads `[0x89, "PNG"]` itself.
    var text = v;
    if (v.len == 0) return;
    if (v[0] == '\'' or (v[0] == '"' and std.mem.indexOfScalar(u8, v, '\\') == null)) {
        try out.appendSlice(gpa, v);
        return;
    }
    if (v[0] == '"' and v.len >= 2 and v[v.len - 1] == '"') text = v[1 .. v.len - 1];
    try out.append(gpa, '\'');
    for (text) |c| {
        if (c == '\'') try out.append(gpa, '\'');
        try out.append(gpa, c);
    }
    try out.append(gpa, '\'');
}

/// One logical line: indentation, any number of `- ` markers, then a `key: value`
/// pair or a bare scalar. Keys are escaped and plain scalars quoted so that
/// characters like `&`, `*`, `::` and `[` cannot upset the parser.
fn appendNormalised(gpa: Allocator, out: *std.ArrayList(u8), code: []const u8) Allocator.Error!?usize {
    var i = indentOf(code);
    try out.appendSlice(gpa, code[0..i]);
    while (std.mem.startsWith(u8, code[i..], "- ")) {
        try out.appendSlice(gpa, "- ");
        i += 2;
        while (i < code.len and code[i] == ' ') i += 1;
    }
    const rest = code[i..];
    if (rest.len == 0) return null;
    if (std.mem.eql(u8, rest, "-")) {
        try out.appendSlice(gpa, rest);
        return null;
    }
    var key_end: ?usize = null; // index in rest of the ':' after the key
    var key_text: []const u8 = "";
    if (rest[0] == '"' or rest[0] == '\'') {
        if (std.mem.indexOfScalarPos(u8, rest, 1, rest[0])) |close| {
            var after = close + 1;
            while (after < rest.len and rest[after] == ' ') after += 1;
            if (after < rest.len and rest[after] == ':') {
                key_end = after;
                key_text = rest[1..close];
            }
        }
    } else if (rest[0] != '[' and rest[0] != '{') {
        var j: usize = 0;
        while (j < rest.len) : (j += 1) {
            if (rest[j] == ':' and (j + 1 == rest.len or rest[j + 1] == ' ')) {
                key_end = j;
                key_text = rest[0..j];
                break;
            }
        }
    }
    if (key_end) |ke| {
        try appendKey(gpa, out, key_text);
        try out.append(gpa, ':');
        const value = std.mem.trim(u8, rest[ke + 1 ..], " ");
        if (isNoise(key_text)) {
            try out.appendSlice(gpa, " \"\"");
            return indentOf(code);
        } else if (value.len > 0) {
            try out.append(gpa, ' ');
            try appendScalar(gpa, out, value);
        }
    } else {
        try appendScalar(gpa, out, rest);
    }
    return null;
}

/// A line that is just a scalar: no `key:` and no `- ` marker.
fn isBareScalar(code: []const u8) bool {
    const rest = std.mem.trimStart(u8, code, " ");
    if (rest.len == 0 or rest[0] == '-' and (rest.len == 1 or rest[1] == ' ')) return false;
    if (rest[0] == '"' or rest[0] == '\'') {
        if (std.mem.indexOfScalarPos(u8, rest, 1, rest[0])) |c| {
            return std.mem.trimStart(u8, rest[c + 1 ..], " ").len == 0 or rest[c + 1 ..][0] != ':';
        }
    }
    var j: usize = 0;
    while (j < rest.len) : (j += 1) {
        if (rest[j] == ':' and (j + 1 == rest.len or rest[j + 1] == ' ')) return false;
    }
    return true;
}

test "block scalars and comments are removed" {
    const a = std.testing.allocator;
    const out = try prepare(a, "meta:\n  id: x # name\ndoc: |\n  free text\n  more\n\nseq:\n  - id: a\n    doc: >-\n      folded\n    type: u1\n");
    defer a.free(out);
    try std.testing.expectEqualStrings("meta:\n  id: 'x'\ndoc: \"\"\nseq:\n  - id: 'a'\n    doc: \"\"\n    type: 'u1'\n", out);
}

test "hash inside quotes is kept" {
    const a = std.testing.allocator;
    const out = try prepare(a, "a: \"x # y\"\nb: 'p#q'\nc: z#w\n");
    defer a.free(out);
    try std.testing.expectEqualStrings("a: \"x # y\"\nb: 'p#q'\nc: 'z#w'\n", out);
}

test "odd keys and values are made safe" {
    const a = std.testing.allocator;
    const out = try prepare(a, "cases:\n  'codes::big': big\n  1: a & b\n  - x*y\n");
    defer a.free(out);
    try std.testing.expectEqualStrings("cases:\n  codes%3A%3Abig: 'big'\n  1: 'a & b'\n  - 'x*y'\n", out);
    const k = try unescapeKey(a, "codes%3A%3Abig");
    defer a.free(k);
    try std.testing.expectEqualStrings("codes::big", k);
}
