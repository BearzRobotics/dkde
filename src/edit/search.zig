//! Find and replace in a text buffer: plain text or a regular expression,
//! with or without matching case and whole words. Every match is found at
//! once, highlighted with a tag and counted ("3 of 12"), as in gedit and
//! GNOME Text Editor. Plain text is searched as an escaped regular
//! expression, so all modes share one path (GLib's PCRE2).

const std = @import("std");
const glib = @import("glib2");
const gtk = @import("gtk4");

pub const Options = struct {
    case_sensitive: bool = false,
    whole_word: bool = false,
    regex: bool = false,
};

/// Beyond this many matches the rest are not highlighted or counted.
pub const max_matches = 100_000;

/// A match, as character offsets in the buffer.
pub const Match = struct { start: u32, end: u32 };

pub const tag_name = "dkde-search-match";

/// Builds the pattern for `needle`; null when it is empty. An invalid
/// regular expression gives `error.BadPattern` (and its message in `why`).
pub fn compile(needle: []const u8, opts: Options, why: *[200]u8, why_len: *usize) error{ BadPattern, OutOfMemory }!?*glib.Regex {
    why_len.* = 0;
    if (needle.len == 0) return null;
    const gpa = std.heap.c_allocator;
    const needle_z = try gpa.dupeSentinel(u8, needle, 0);
    defer gpa.free(needle_z);
    const escaped: [*:0]u8 = if (opts.regex) needle_z.ptr else glib.Regex.escapeString(needle_z.ptr, @intCast(needle.len));
    defer if (!opts.regex) glib.free(escaped);
    const pattern = if (opts.whole_word)
        try std.fmt.allocPrintSentinel(gpa, "\\b(?:{s})\\b", .{std.mem.span(escaped)}, 0)
    else
        try gpa.dupeSentinel(u8, std.mem.span(escaped), 0);
    defer gpa.free(pattern);
    var err: ?*glib.Error = null;
    const re = glib.Regex.new(pattern, .{ .caseless = !opts.case_sensitive, .multiline = true, .optimize = true }, .{}, &err) orelse {
        if (err) |e| {
            const msg = std.mem.span(e.f_message orelse "invalid");
            const n = @min(msg.len, why.len);
            @memcpy(why[0..n], msg[0..n]);
            why_len.* = n;
            e.free();
        }
        return error.BadPattern;
    };
    return re;
}

/// The whole text of `buffer` (caller frees with glib.free).
fn bufferText(buffer: *gtk.TextBuffer) [*:0]u8 {
    var start: gtk.TextIter = undefined;
    var end: gtk.TextIter = undefined;
    buffer.getBounds(&start, &end);
    return buffer.getText(&start, &end, 1);
}

/// Turns byte offsets into character offsets, walking forward only.
const CharCounter = struct {
    text: []const u8,
    byte: usize = 0,
    chars: u32 = 0,

    fn at(self: *CharCounter, byte: usize) u32 {
        while (self.byte < byte and self.byte < self.text.len) {
            const len = std.unicode.utf8ByteSequenceLength(self.text[self.byte]) catch 1;
            self.byte += len;
            self.chars += 1;
        }
        return self.chars;
    }
};

/// Every match of `re` in `buffer`, in order (at most `max_matches`).
pub fn findAll(gpa: std.mem.Allocator, buffer: *gtk.TextBuffer, re: *glib.Regex, out: *std.ArrayList(Match)) !void {
    out.clearRetainingCapacity();
    const raw = bufferText(buffer);
    defer glib.free(raw);
    const text = std.mem.span(raw);
    var counter: CharCounter = .{ .text = text };
    var info: *glib.MatchInfo = undefined;
    _ = re.matchFull(@ptrCast(text.ptr), @intCast(text.len), 0, .{}, &info, null);
    defer info.free();
    while (info.matches() != 0) {
        var s: c_int = 0;
        var e: c_int = 0;
        if (info.fetchPos(0, &s, &e) == 0) break;
        // An empty match (as from "^") is skipped: it cannot be shown.
        if (e > s) {
            const cs = counter.at(@intCast(s));
            const ce = counter.at(@intCast(e));
            try out.append(gpa, .{ .start = cs, .end = ce });
            if (out.items.len >= max_matches) break;
        }
        if (info.next(null) == 0) break;
    }
}

/// Puts the highlight tag on `matches` (and takes it off everything else).
pub fn highlight(buffer: *gtk.TextBuffer, matches: []const Match) void {
    const table = buffer.getTagTable();
    const tag = table.lookup(tag_name) orelse return;
    var start: gtk.TextIter = undefined;
    var end: gtk.TextIter = undefined;
    buffer.getBounds(&start, &end);
    buffer.removeTag(tag, &start, &end);
    for (matches) |m| {
        buffer.getIterAtOffset(&start, @intCast(m.start));
        buffer.getIterAtOffset(&end, @intCast(m.end));
        buffer.applyTag(tag, &start, &end);
    }
}

/// The match to go to from character `offset`: the first at or after it
/// (going forward) or the last before it (going back), wrapping around.
pub fn pick(matches: []const Match, offset: u32, forward: bool) ?usize {
    if (matches.len == 0) return null;
    if (forward) {
        for (matches, 0..) |m, i| if (m.start >= offset) return i;
        return 0;
    }
    var i = matches.len;
    while (i > 0) {
        i -= 1;
        if (matches[i].end <= offset) return i;
    }
    return matches.len - 1;
}

/// The text that replaces `matched`: with "\1"-style references filled in
/// for a regular expression, as it is otherwise.
pub fn replacementFor(gpa: std.mem.Allocator, re: *glib.Regex, matched: []const u8, replacement: []const u8, opts: Options) ![]u8 {
    if (!opts.regex) return gpa.dupe(u8, replacement);
    const repl_z = try gpa.dupeSentinel(u8, replacement, 0);
    defer gpa.free(repl_z);
    var info: *glib.MatchInfo = undefined;
    _ = re.matchFull(@ptrCast(matched.ptr), @intCast(matched.len), 0, .{ .anchored = true }, &info, null);
    defer info.free();
    if (info.matches() == 0) return gpa.dupe(u8, replacement);
    const expanded = info.expandReferences(repl_z, null) orelse return gpa.dupe(u8, replacement);
    defer glib.free(expanded);
    return gpa.dupe(u8, std.mem.span(expanded));
}

/// Replaces every match in one undoable step; returns how many.
pub fn replaceAll(gpa: std.mem.Allocator, buffer: *gtk.TextBuffer, re: *glib.Regex, replacement: []const u8, opts: Options) !usize {
    var matches: std.ArrayList(Match) = .empty;
    defer matches.deinit(gpa);
    try findAll(gpa, buffer, re, &matches);
    if (matches.items.len == 0) return 0;
    buffer.beginUserAction();
    defer buffer.endUserAction();
    // From the end, so earlier offsets stay right.
    var i = matches.items.len;
    while (i > 0) {
        i -= 1;
        const m = matches.items[i];
        var start: gtk.TextIter = undefined;
        var end: gtk.TextIter = undefined;
        buffer.getIterAtOffset(&start, @intCast(m.start));
        buffer.getIterAtOffset(&end, @intCast(m.end));
        const old = buffer.getText(&start, &end, 1);
        defer glib.free(old);
        const new = try replacementFor(gpa, re, std.mem.span(old), replacement, opts);
        defer gpa.free(new);
        buffer.delete(&start, &end);
        buffer.insert(&start, @ptrCast(new.ptr), @intCast(new.len));
    }
    return matches.items.len;
}

test "patterns follow the options" {
    var why: [200]u8 = undefined;
    var why_len: usize = 0;
    try std.testing.expect((try compile("", .{}, &why, &why_len)) == null);
    try std.testing.expectError(error.BadPattern, compile("(", .{ .regex = true }, &why, &why_len));
    try std.testing.expect(why_len > 0);
    // "(" is literal text when it is not a regular expression.
    const re = (try compile("(", .{}, &why, &why_len)).?;
    re.unref();
}

test "matches are picked forward and back, wrapping" {
    const ms = [_]Match{ .{ .start = 2, .end = 4 }, .{ .start = 10, .end = 12 } };
    try std.testing.expectEqual(@as(?usize, 0), pick(&ms, 0, true));
    try std.testing.expectEqual(@as(?usize, 1), pick(&ms, 5, true));
    try std.testing.expectEqual(@as(?usize, 0), pick(&ms, 13, true));
    try std.testing.expectEqual(@as(?usize, 1), pick(&ms, 13, false));
    try std.testing.expectEqual(@as(?usize, 1), pick(&ms, 2, false));
    try std.testing.expectEqual(@as(?usize, null), pick(&.{}, 0, true));
}
