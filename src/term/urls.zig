//! Finding web and file addresses in terminal output that programs did not
//! mark as links (OSC 8), so they can be underlined and opened as in GNOME
//! Terminal and Konsole.

const std = @import("std");

const schemes = [_][]const u8{ "https://", "http://", "ftp://", "ftps://", "sftp://", "ssh://", "file://", "mailto:", "www." };

fn isUrlChar(c: u8) bool {
    if (c >= 0x80) return true; // non-ASCII letters in paths and names
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9' => true,
        '-', '.', '_', '~', ':', '/', '?', '#', '[', ']', '@', '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=', '%' => true,
        else => false,
    };
}

/// Where an address starting at `start` ends: punctuation that usually
/// ends a sentence is left out, and a ')' only counts when it closes a '('.
fn urlEnd(line: []const u8, start: usize, prefix_len: usize) usize {
    var end = start + prefix_len;
    while (end < line.len and isUrlChar(line[end])) end += 1;
    while (end > start + prefix_len) {
        const c = line[end - 1];
        if (std.mem.indexOfScalar(u8, ".,;:!?'*", c) != null) {
            end -= 1;
            continue;
        }
        if (c == ')' or c == ']') {
            const open: u8 = if (c == ')') '(' else '[';
            const inside = line[start .. end - 1];
            if (std.mem.count(u8, inside, &.{open}) < std.mem.count(u8, inside, &.{c}) + 1) {
                end -= 1;
                continue;
            }
        }
        break;
    }
    return end;
}

fn startsAt(line: []const u8, i: usize) ?usize {
    for (schemes) |s| {
        if (i + s.len <= line.len and std.ascii.eqlIgnoreCase(line[i .. i + s.len], s)) {
            // "www." and "mailto:" only at the start of a word.
            if (i > 0 and isUrlChar(line[i - 1]) and line[i - 1] != '(' and line[i - 1] != '[') {
                if (std.mem.eql(u8, s, "www.") or std.mem.eql(u8, s, "mailto:")) continue;
            }
            return s.len;
        }
    }
    return null;
}

pub const Span = struct { start: usize, end: usize };

/// Every address in `line`, as byte ranges, in order.
pub fn all(line: []const u8, out: []Span) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < line.len and n < out.len) {
        if (startsAt(line, i)) |plen| {
            const end = urlEnd(line, i, plen);
            // "http://" alone is not an address.
            if (end > i + plen) {
                out[n] = .{ .start = i, .end = end };
                n += 1;
                i = end;
                continue;
            }
        }
        i += 1;
    }
    return n;
}

/// The address covering byte `at` of `line`, if any.
pub fn at(line: []const u8, byte: usize) ?Span {
    var spans: [32]Span = undefined;
    const n = all(line, &spans);
    for (spans[0..n]) |s| if (byte >= s.start and byte < s.end) return s;
    return null;
}

/// The address to open for `text`: "www." gets "http://" in front.
pub fn openable(buf: []u8, text: []const u8) []const u8 {
    if (std.ascii.startsWithIgnoreCase(text, "www.")) return std.fmt.bufPrint(buf, "http://{s}", .{text}) catch text;
    return text;
}

test "addresses are found and trailing punctuation left out" {
    const cases = .{
        .{ "see https://ziglang.org/learn.", "https://ziglang.org/learn" },
        .{ "(https://en.wikipedia.org/wiki/Zig_(language))", "https://en.wikipedia.org/wiki/Zig_(language)" },
        .{ "go to www.example.com, then", "www.example.com" },
        .{ "mail mailto:a@b.c!", "mailto:a@b.c" },
        .{ "file:///home/u/a%20b.txt", "file:///home/u/a%20b.txt" },
        .{ "url \"http://x.y/z?a=1&b=2\" end", "http://x.y/z?a=1&b=2" },
    };
    inline for (cases) |c| {
        var spans: [4]Span = undefined;
        const n = all(c[0], &spans);
        try std.testing.expectEqual(@as(usize, 1), n);
        try std.testing.expectEqualStrings(c[1], c[0][spans[0].start..spans[0].end]);
    }
}

test "not addresses" {
    var spans: [4]Span = undefined;
    try std.testing.expectEqual(@as(usize, 0), all("plain text http:// and swww.x", &spans));
    try std.testing.expect(at("x https://a.b y", 0) == null);
    try std.testing.expect(at("x https://a.b y", 5) != null);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("http://www.a.b", openable(&buf, "www.a.b"));
}
