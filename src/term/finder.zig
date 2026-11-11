//! Find in the terminal's scrollback: plain text or a regular expression,
//! with or without matching case and whole words. Every match is found at
//! once (so all can be highlighted and counted, "3 of 12"), as in GNOME
//! Terminal and Konsole. The screen's text comes from libghostty-vt with a
//! map from each byte back to its cell, and GLib's PCRE2 does the matching.

const std = @import("std");
const glib = @import("glib2");
const vt = @import("ghostty-vt");

pub const Options = struct {
    case_sensitive: bool = false,
    whole_word: bool = false,
    regex: bool = false,
};

/// A match, from its first to its last cell, in screen rows (counted from
/// the top of the scrollback) and columns.
pub const Match = struct {
    start_y: u32,
    start_x: u16,
    end_y: u32,
    end_x: u16,

    fn covers(self: Match, y: u32, x: u16) bool {
        if (y < self.start_y or y > self.end_y) return false;
        if (y == self.start_y and x < self.start_x) return false;
        if (y == self.end_y and x > self.end_x) return false;
        return true;
    }
};

pub const max_matches = 20_000;

pub const Finder = struct {
    matches: std.ArrayList(Match) = .empty,
    /// The match that is selected, if any.
    current: ?usize = null,
    /// Why the pattern is not valid, when it is not.
    error_text: [160]u8 = undefined,
    error_len: usize = 0,

    pub fn deinit(self: *Finder, gpa: std.mem.Allocator) void {
        self.matches.deinit(gpa);
    }

    pub fn clear(self: *Finder) void {
        self.matches.clearRetainingCapacity();
        self.current = null;
        self.error_len = 0;
    }

    pub fn errorText(self: *const Finder) ?[]const u8 {
        return if (self.error_len > 0) self.error_text[0..self.error_len] else null;
    }

    /// Finds every match of `needle` on `screen`. The current match is kept
    /// when it is still there.
    pub fn run(self: *Finder, gpa: std.mem.Allocator, screen: *vt.Screen, needle: []const u8, opts: Options) !void {
        const previous: ?Match = if (self.current) |i| (if (i < self.matches.items.len) self.matches.items[i] else null) else null;
        self.clear();
        if (needle.len == 0) return;
        const re = compile(needle, opts, &self.error_text, &self.error_len) orelse return;
        defer re.unref();

        const tl = screen.pages.getTopLeft(.screen);
        const br = screen.pages.getBottomRight(.screen) orelse return;
        const map = try screen.selectionStringMap(gpa, .{ .sel = vt.Selection.init(tl, br, false), .trim = false });
        defer map.deinit(gpa);
        const text = map.string;

        var info: *glib.MatchInfo = undefined;
        _ = re.matchFull(text.ptr, @intCast(text.len), 0, .{}, &info, null);
        defer info.free();
        while (info.matches() != 0) {
            var s: c_int = 0;
            var e: c_int = 0;
            if (info.fetchPos(0, &s, &e) == 0) break;
            if (e > s) blk: {
                const ps = map.map.get(@intCast(s)) orelse break :blk;
                const pe = map.map.get(@intCast(e - 1)) orelse break :blk;
                const a = screen.pages.pointFromPin(.screen, ps) orelse break :blk;
                const b = screen.pages.pointFromPin(.screen, pe) orelse break :blk;
                try self.matches.append(gpa, .{ .start_y = a.screen.y, .start_x = a.screen.x, .end_y = b.screen.y, .end_x = b.screen.x });
                if (self.matches.items.len >= max_matches) break;
            }
            if (info.next(null) == 0) break;
        }
        if (previous) |p| {
            for (self.matches.items, 0..) |m, i| if (std.meta.eql(m, p)) {
                self.current = i;
            };
        }
    }

    /// Whether the cell at screen row `y`, column `x` is part of a match.
    pub fn covers(self: *const Finder, y: u32, x: u16) bool {
        // Matches are in order: find the last that starts at or before y.
        const items = self.matches.items;
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (items[mid].start_y <= y) lo = mid + 1 else hi = mid;
        }
        var i = lo;
        while (i > 0) {
            i -= 1;
            const m = items[i];
            if (m.covers(y, x)) return true;
            if (m.end_y < y) break;
        }
        return false;
    }

    /// The next match going up (older) or down from the current one; the
    /// first step from nothing goes to the newest match.
    pub fn step(self: *Finder, older: bool) ?Match {
        const n = self.matches.items.len;
        if (n == 0) return null;
        const i: usize = if (self.current) |c|
            (if (older) (c + n - 1) % n else (c + 1) % n)
        else
            n - 1;
        self.current = i;
        return self.matches.items[i];
    }
};

/// The pattern for `needle`; null when it is invalid (the reason is copied
/// to `why`).
pub fn compile(needle: []const u8, opts: Options, why: []u8, why_len: *usize) ?*glib.Regex {
    const gpa = std.heap.c_allocator;
    const needle_z = gpa.dupeSentinel(u8, needle, 0) catch return null;
    defer gpa.free(needle_z);
    const escaped: [*:0]u8 = if (opts.regex) needle_z.ptr else glib.Regex.escapeString(needle_z.ptr, @intCast(needle.len));
    defer if (!opts.regex) glib.free(escaped);
    const pattern = (if (opts.whole_word)
        std.fmt.allocPrintSentinel(gpa, "\\b(?:{s})\\b", .{std.mem.span(escaped)}, 0)
    else
        gpa.dupeSentinel(u8, std.mem.span(escaped), 0)) catch return null;
    defer gpa.free(pattern);
    var err: ?*glib.Error = null;
    return glib.Regex.new(pattern, .{ .caseless = !opts.case_sensitive, .multiline = true, .optimize = true }, .{}, &err) orelse {
        if (err) |e| {
            const msg = std.mem.span(e.f_message orelse "invalid");
            const n = @min(msg.len, why.len);
            @memcpy(why[0..n], msg[0..n]);
            why_len.* = n;
            e.free();
        }
        return null;
    };
}

test "matches are covered and stepped through" {
    var f: Finder = .{};
    defer f.deinit(std.testing.allocator);
    try f.matches.append(std.testing.allocator, .{ .start_y = 2, .start_x = 5, .end_y = 2, .end_x = 8 });
    try f.matches.append(std.testing.allocator, .{ .start_y = 4, .start_x = 70, .end_y = 5, .end_x = 3 });
    try std.testing.expect(f.covers(2, 5));
    try std.testing.expect(!f.covers(2, 9));
    try std.testing.expect(f.covers(5, 0));
    try std.testing.expect(!f.covers(4, 69));
    try std.testing.expectEqual(@as(u32, 4), f.step(true).?.start_y);
    try std.testing.expectEqual(@as(u32, 2), f.step(true).?.start_y);
    try std.testing.expectEqual(@as(u32, 4), f.step(true).?.start_y);
    var why: [100]u8 = undefined;
    var why_len: usize = 0;
    try std.testing.expect(compile("(", .{ .regex = true }, &why, &why_len) == null);
    try std.testing.expect(why_len > 0);
}
