// SPDX-License-Identifier: GPL-2.0-or-later
//! Searching for files by name (SPEC.md 5.4).
//!
//! Plain text matches any part of a name. Text with `*` (any run of characters)
//! or `?` (any one character) is a pattern for the whole name: `*.pdf`,
//! `photo?.jpg`. Case is ignored in every script, and a letter typed as one
//! character matches the same letter stored as letter plus accent mark.

const std = @import("std");
const glib = @import("glib2");

const testing = std.testing;

/// `text` as it is compared: normalised, case folded, normalised again (folding
/// can pull composed characters apart). Null when it is not UTF-8. The caller
/// frees it with `glib.free`.
fn fold(text: [*:0]const u8) ?[*:0]u8 {
    const normal = glib.utf8Normalize(text, -1, .all_compose) orelse return null;
    defer glib.free(normal);
    const folded = glib.utf8Casefold(normal, -1);
    defer glib.free(folded);
    return glib.utf8Normalize(folded, -1, .all_compose);
}

/// A compiled search.
pub const Matcher = struct {
    needle: [*:0]u8,
    /// Set when the text has wildcards.
    pattern: ?*glib.PatternSpec,

    /// Null for empty text (everything matches), and for text that is not UTF-8.
    pub fn init(text: [*:0]const u8) ?Matcher {
        if (text[0] == 0) return null;
        const needle = fold(text) orelse return null;
        const wild = std.mem.indexOfAny(u8, std.mem.span(needle), "*?") != null;
        return .{ .needle = needle, .pattern = if (wild) glib.PatternSpec.new(needle) else null };
    }

    pub fn deinit(self: Matcher) void {
        if (self.pattern) |p| p.free();
        glib.free(self.needle);
    }

    pub fn matches(self: Matcher, name: [*:0]const u8) bool {
        const folded = fold(name) orelse return false;
        defer glib.free(folded);
        if (self.pattern) |p| return p.matchString(folded) != 0;
        return std.mem.indexOf(u8, std.mem.span(folded), std.mem.span(self.needle)) != null;
    }
};

// ---- tests -----------------------------------------------------------------

fn expectMatch(want: bool, query: [*:0]const u8, name: [*:0]const u8) !void {
    const matcher = Matcher.init(query) orelse return error.NoMatcher;
    defer matcher.deinit();
    testing.expectEqual(want, matcher.matches(name)) catch |e| {
        std.debug.print("'{s}' against '{s}'\n", .{ query, name });
        return e;
    };
}

test "plain text matches any part of a name" {
    try expectMatch(true, "port", "Report 2026.pdf");
    try expectMatch(true, ".PDF", "Report 2026.pdf");
    try expectMatch(false, "reports", "Report 2026.pdf");
    try expectMatch(true, "[1]", "notes [1].txt");
    try expectMatch(false, "[1]", "notes 1.txt");
}

test "wildcards match the whole name" {
    try expectMatch(true, "*.pdf", "Report.PDF");
    try expectMatch(false, "*.pdf", "Report.pdf.part");
    try expectMatch(false, "*.pdf", "pdf");
    try expectMatch(true, "photo?.jpg", "photo1.jpg");
    try expectMatch(true, "photo?.jpg", "Photo\u{e9}.JPG");
    try expectMatch(false, "photo?.jpg", "photo.jpg");
    try expectMatch(false, "photo?.jpg", "photo12.jpg");
    try expectMatch(false, "photo?.jpg", "my photo1.jpg");
    try expectMatch(true, "*photo*", "my photo12.jpg");
    try expectMatch(true, "IMG_*.j*g", "img_0001.jpeg");
    try expectMatch(false, "rep*", "my report");
    try expectMatch(true, "*", "anything");
}

test "case and accents compare alike in any script" {
    try expectMatch(true, "\u{e9}t\u{e9}", "\u{c9}T\u{c9}.txt"); // été / ÉTÉ
    try expectMatch(true, "\u{e9}", "e\u{301}.txt"); // one character against two
    try expectMatch(true, "E\u{301}", "\u{e9}.txt");
    try expectMatch(true, "\u{3b1}\u{3b8}\u{3ae}\u{3bd}\u{3b1}", "\u{391}\u{398}\u{389}\u{39d}\u{391}"); // Greek
    try expectMatch(true, "\u{43c}\u{438}\u{440}", "\u{41c}\u{418}\u{420}.doc"); // Cyrillic
    try expectMatch(true, "strasse", "Stra\u{df}e.txt");
    try expectMatch(false, "e", "\u{e9}.txt"); // an accent still counts
}

test "no search for empty or broken text, and no match for a broken name" {
    try testing.expect(Matcher.init("") == null);
    try testing.expect(Matcher.init("\xff\xfe") == null);
    try expectMatch(false, "a", "a\xff");
}
