//! Unicode blocks the character map offers, and small helpers. Pure.

const std = @import("std");

pub const Block = struct { name: [:0]const u8, first: u21, last: u21 };

pub const blocks = [_]Block{
    .{ .name = "Basic Latin", .first = 0x0020, .last = 0x007E },
    .{ .name = "Latin-1 Supplement", .first = 0x00A0, .last = 0x00FF },
    .{ .name = "Latin Extended-A", .first = 0x0100, .last = 0x017F },
    .{ .name = "Greek and Coptic", .first = 0x0370, .last = 0x03FF },
    .{ .name = "Cyrillic", .first = 0x0400, .last = 0x04FF },
    .{ .name = "Hebrew", .first = 0x0590, .last = 0x05FF },
    .{ .name = "Arabic", .first = 0x0600, .last = 0x06FF },
    .{ .name = "General Punctuation", .first = 0x2000, .last = 0x206F },
    .{ .name = "Currency Symbols", .first = 0x20A0, .last = 0x20CF },
    .{ .name = "Letterlike Symbols", .first = 0x2100, .last = 0x214F },
    .{ .name = "Number Forms", .first = 0x2150, .last = 0x218F },
    .{ .name = "Arrows", .first = 0x2190, .last = 0x21FF },
    .{ .name = "Mathematical Operators", .first = 0x2200, .last = 0x22FF },
    .{ .name = "Miscellaneous Technical", .first = 0x2300, .last = 0x23FF },
    .{ .name = "Box Drawing", .first = 0x2500, .last = 0x257F },
    .{ .name = "Block Elements", .first = 0x2580, .last = 0x259F },
    .{ .name = "Geometric Shapes", .first = 0x25A0, .last = 0x25FF },
    .{ .name = "Miscellaneous Symbols", .first = 0x2600, .last = 0x26FF },
    .{ .name = "Dingbats", .first = 0x2700, .last = 0x27BF },
    .{ .name = "Braille Patterns", .first = 0x2800, .last = 0x28FF },
    .{ .name = "Hiragana", .first = 0x3040, .last = 0x309F },
    .{ .name = "Katakana", .first = 0x30A0, .last = 0x30FF },
    .{ .name = "Emoticons", .first = 0x1F600, .last = 0x1F64F },
    .{ .name = "Pictographs: weather, food, places", .first = 0x1F300, .last = 0x1F3FF },
    .{ .name = "Pictographs: animals, people", .first = 0x1F400, .last = 0x1F4FF },
    .{ .name = "Pictographs: objects, symbols", .first = 0x1F500, .last = 0x1F5FF },
};

pub fn count(b: Block) usize {
    return @as(usize, b.last - b.first) + 1;
}

/// The character `index` places into the block, UTF-8 encoded into `buf`.
pub fn utf8At(b: Block, index: usize, buf: *[4]u8) ?[]const u8 {
    const cp: u21 = b.first + @as(u21, @intCast(index));
    if (cp > b.last) return null;
    const n = std.unicode.utf8Encode(cp, buf) catch return null;
    return buf[0..n];
}

/// "U+00E9  UTF-8: C3 A9".
pub fn describe(cp: u21, out: []u8) []const u8 {
    var enc: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &enc) catch return "";
    var w: std.Io.Writer = .fixed(out);
    w.print("U+{X:0>4}   UTF-8:", .{cp}) catch return "";
    for (enc[0..n]) |b| w.print(" {X:0>2}", .{b}) catch return "";
    return w.buffered();
}

test "blocks are well formed" {
    var buf: [4]u8 = undefined;
    for (blocks) |b| {
        try std.testing.expect(b.first <= b.last);
        try std.testing.expect(count(b) <= 256);
        try std.testing.expect(utf8At(b, 0, &buf) != null);
    }
}

test "characters and descriptions" {
    var buf: [4]u8 = undefined;
    const latin1 = blocks[1];
    try std.testing.expectEqualStrings("\u{00e9}", utf8At(latin1, 0xE9 - 0xA0, &buf).?);
    try std.testing.expect(utf8At(latin1, 1000, &buf) == null);
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings("U+00E9   UTF-8: C3 A9", describe(0xE9, &out));
    try std.testing.expectEqualStrings("U+1F600   UTF-8: F0 9F 98 80", describe(0x1F600, &out));
}
