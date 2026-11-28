// SPDX-License-Identifier: GPL-2.0-or-later
//! Unicode blocks, character names and search for the character map. Pure.
//! The data is `unidata.txt`, made by scripts/gen-charmap-data.py.

const std = @import("std");
const Allocator = std.mem.Allocator;

const raw = @embedFile("unidata.txt");

/// `private` blocks hold no assigned characters: fonts define them.
pub const Block = struct { name: []const u8, first: u21, last: u21, private: bool = false };
const Char = struct { cp: u21, mark: bool, name: []const u8 };
const Run = struct { first: u21, last: u21, prefix: []const u8 };

pub const Db = struct {
    blocks: []Block,
    chars: []Char,
    runs: []Run,

    pub fn load(allocator: Allocator) Allocator.Error!Db {
        var blocks: std.ArrayList(Block) = .empty;
        errdefer blocks.deinit(allocator);
        var chars: std.ArrayList(Char) = .empty;
        errdefer chars.deinit(allocator);
        var runs: std.ArrayList(Run) = .empty;
        errdefer runs.deinit(allocator);
        var lines = std.mem.splitScalar(u8, raw, '\n');
        while (lines.next()) |line| {
            if (line.len < 3 or line[1] != ' ') continue;
            const rest = line[2..];
            switch (line[0]) {
                'N', 'M' => {
                    const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse continue;
                    const cp = std.fmt.parseInt(u21, rest[0..sp], 16) catch continue;
                    try chars.append(allocator, .{ .cp = cp, .mark = line[0] == 'M', .name = rest[sp + 1 ..] });
                },
                'B', 'P', 'R' => {
                    var it = std.mem.splitScalar(u8, rest, ' ');
                    const a = std.fmt.parseInt(u21, it.next() orelse continue, 16) catch continue;
                    const b = std.fmt.parseInt(u21, it.next() orelse continue, 16) catch continue;
                    const label = it.rest();
                    if (line[0] != 'R') {
                        try blocks.append(allocator, .{ .name = label, .first = a, .last = b, .private = line[0] == 'P' });
                    } else {
                        try runs.append(allocator, .{ .first = a, .last = b, .prefix = label });
                    }
                },
                else => {},
            }
        }
        return .{
            .blocks = try blocks.toOwnedSlice(allocator),
            .chars = try chars.toOwnedSlice(allocator),
            .runs = try runs.toOwnedSlice(allocator),
        };
    }

    pub fn deinit(self: *Db, allocator: Allocator) void {
        allocator.free(self.blocks);
        allocator.free(self.chars);
        allocator.free(self.runs);
    }

    fn find(self: *const Db, cp: u21) ?usize {
        var lo: usize = 0;
        var hi: usize = self.chars.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.chars[mid].cp == cp) return mid;
            if (self.chars[mid].cp < cp) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    fn run(self: *const Db, cp: u21) ?Run {
        for (self.runs) |r| if (cp >= r.first and cp <= r.last) return r;
        return null;
    }

    pub fn isAssigned(self: *const Db, cp: u21) bool {
        return self.find(cp) != null or self.run(cp) != null;
    }

    pub fn isMark(self: *const Db, cp: u21) bool {
        const i = self.find(cp) orelse return false;
        return self.chars[i].mark;
    }

    /// The character's name, e.g. "LATIN SMALL LETTER E WITH ACUTE". `buf` holds
    /// the names of numbered runs ("CJK UNIFIED IDEOGRAPH-4E00").
    pub fn name(self: *const Db, cp: u21, buf: []u8) ?[]const u8 {
        if (self.find(cp)) |i| return self.chars[i].name;
        const r = self.run(cp) orelse return null;
        return std.fmt.bufPrint(buf, "{s}{X:0>4}", .{ r.prefix, cp }) catch null;
    }

    /// The assigned characters of `block`, appended to `out`.
    pub fn fillBlock(self: *const Db, allocator: Allocator, block: Block, out: *std.ArrayList(u21)) Allocator.Error!void {
        var cp = block.first;
        while (cp <= block.last) : (cp += 1) {
            if (self.isAssigned(cp)) try out.append(allocator, cp);
        }
    }

    /// Characters matching `query`: a character itself, a code point ("U+E9",
    /// "0xe9", "00e9"), or words that all appear in the name. At most `max`.
    pub fn search(self: *const Db, allocator: Allocator, query: []const u8, max: usize, out: *std.ArrayList(u21)) Allocator.Error!void {
        const q = std.mem.trim(u8, query, " \t");
        if (q.len == 0) return;
        if (std.unicode.utf8ValidateSlice(q)) {
            if (std.unicode.utf8CountCodepoints(q) catch 0 == 1) {
                const cp = std.unicode.utf8Decode(q) catch 0;
                if (self.isAssigned(cp)) try out.append(allocator, cp);
            }
        }
        var digits = q;
        const prefixed = std.ascii.startsWithIgnoreCase(q, "u+") or std.ascii.startsWithIgnoreCase(q, "0x");
        if (prefixed) digits = q[2..];
        if (digits.len > 0 and digits.len <= 6) {
            if (std.fmt.parseInt(u21, digits, 16)) |cp| {
                if (self.isAssigned(cp) and !contains(out.items, cp)) try out.append(allocator, cp);
            } else |_| {}
        }
        if (prefixed) return;

        var upper_buf: [128]u8 = undefined;
        if (q.len > upper_buf.len) return;
        const upper = std.ascii.upperString(&upper_buf, q);
        for (self.chars) |c| {
            if (out.items.len >= max) return;
            if (matchesWords(c.name, upper) and !contains(out.items, c.cp)) try out.append(allocator, c.cp);
        }
    }
};

fn contains(items: []const u21, cp: u21) bool {
    return std.mem.indexOfScalar(u21, items, cp) != null;
}

fn matchesWords(name: []const u8, upper_query: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, upper_query, " \t");
    while (words.next()) |w| {
        if (std.mem.indexOf(u8, name, w) == null) return false;
    }
    return true;
}

/// "U+00E9", "U+1F600".
pub fn codeLabel(cp: u21, out: []u8) []const u8 {
    return std.fmt.bufPrint(out, "U+{X:0>4}", .{cp}) catch "";
}

/// "C3 A9": the character's UTF-8 bytes in hex.
pub fn utf8Hex(cp: u21, out: []u8) []const u8 {
    var enc: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &enc) catch return "";
    var w: std.Io.Writer = .fixed(out);
    for (enc[0..n], 0..) |b, i| {
        if (i > 0) w.writeByte(' ') catch return "";
        w.print("{X:0>2}", .{b}) catch return "";
    }
    return w.buffered();
}

test "database loads and names characters" {
    const a = std.testing.allocator;
    var db = try Db.load(a);
    defer db.deinit(a);
    try std.testing.expect(db.blocks.len > 200);
    var buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings("LATIN SMALL LETTER E WITH ACUTE", db.name(0xE9, &buf).?);
    try std.testing.expectEqualStrings("CJK UNIFIED IDEOGRAPH-4E00", db.name(0x4E00, &buf).?);
    try std.testing.expectEqualStrings("GRINNING FACE", db.name(0x1F600, &buf).?);
    try std.testing.expect(db.name(0x378, &buf) == null);
    try std.testing.expect(db.isMark(0x301));
    try std.testing.expect(!db.isMark(0x41));
}

test "blocks list only assigned characters" {
    const a = std.testing.allocator;
    var db = try Db.load(a);
    defer db.deinit(a);
    var cells: std.ArrayList(u21) = .empty;
    defer cells.deinit(a);
    for (db.blocks) |b| {
        try std.testing.expect(b.first <= b.last);
        if (std.mem.eql(u8, b.name, "Greek and Coptic")) try db.fillBlock(a, b, &cells);
    }
    try std.testing.expect(cells.items.len > 100 and cells.items.len < 0x90);
    try std.testing.expect(!contains(cells.items, 0x378));
    try std.testing.expect(contains(cells.items, 0x3B1));
}

test "search by name, code point and character" {
    const a = std.testing.allocator;
    var db = try Db.load(a);
    defer db.deinit(a);
    var r: std.ArrayList(u21) = .empty;
    defer r.deinit(a);
    try db.search(a, "greek small alpha", 50, &r);
    try std.testing.expect(contains(r.items, 0x3B1));
    r.clearRetainingCapacity();
    try db.search(a, "u+e9", 50, &r);
    try std.testing.expectEqualSlices(u21, &.{0xE9}, r.items);
    r.clearRetainingCapacity();
    try db.search(a, "\u{e9}", 50, &r);
    try std.testing.expectEqual(@as(u21, 0xE9), r.items[0]);
    r.clearRetainingCapacity();
    try db.search(a, "snowman", 50, &r);
    try std.testing.expect(contains(r.items, 0x2603));
    r.clearRetainingCapacity();
    try db.search(a, "face", 5, &r);
    try std.testing.expect(r.items.len == 5);
}

test "private use blocks are listed but empty" {
    const a = std.testing.allocator;
    var db = try Db.load(a);
    defer db.deinit(a);
    var n: usize = 0;
    for (db.blocks) |b| {
        if (!b.private) continue;
        n += 1;
        try std.testing.expect(!db.isAssigned(b.first));
    }
    try std.testing.expectEqual(@as(usize, 3), n);
}

test "labels" {
    var out: [32]u8 = undefined;
    try std.testing.expectEqualStrings("U+00E9", codeLabel(0xE9, &out));
    try std.testing.expectEqualStrings("F0 9F 98 80", utf8Hex(0x1F600, &out));
}
