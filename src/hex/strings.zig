//! Finds runs of printable text in a buffer, like strings(1): the first thing
//! to do with an unknown binary.

const std = @import("std");

pub const Hit = struct { offset: usize, len: usize, wide: bool };

fn printable(c: u8) bool {
    return (c >= 0x20 and c < 0x7f) or c == '\t';
}

/// ASCII runs and UTF-16LE runs (ASCII characters followed by a zero byte) of
/// at least `min_len` characters, in file order, at most `max_hits` of them.
pub fn extract(allocator: std.mem.Allocator, data: []const u8, min_len: usize, max_hits: usize) ![]Hit {
    var out: std.ArrayList(Hit) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < data.len and out.items.len < max_hits) {
        // ASCII.
        var j = i;
        while (j < data.len and printable(data[j])) j += 1;
        if (j - i >= min_len) {
            try out.append(allocator, .{ .offset = i, .len = j - i, .wide = false });
            i = j;
            continue;
        }
        // UTF-16LE.
        var k = i;
        while (k + 1 < data.len and printable(data[k]) and data[k + 1] == 0) k += 2;
        if ((k - i) / 2 >= min_len) {
            try out.append(allocator, .{ .offset = i, .len = k - i, .wide = true });
            i = k;
            continue;
        }
        i += 1;
    }
    std.mem.sort(Hit, out.items, {}, struct {
        fn less(_: void, a: Hit, b: Hit) bool {
            return a.offset < b.offset;
        }
    }.less);
    return out.toOwnedSlice(allocator);
}

/// The text of a hit, wide ones narrowed to ASCII, written into `buf`.
pub fn text(data: []const u8, hit: Hit, buf: []u8) []const u8 {
    var n: usize = 0;
    if (hit.wide) {
        var k: usize = 0;
        while (k < hit.len and n < buf.len) : (k += 2) {
            buf[n] = data[hit.offset + k];
            n += 1;
        }
    } else {
        n = @min(hit.len, buf.len);
        @memcpy(buf[0..n], data[hit.offset..][0..n]);
    }
    return buf[0..n];
}

test "finds ascii and wide strings" {
    const a = std.testing.allocator;
    const data = "\x00\x01hello world\x00\xff\x02A\x00B\x00C\x00D\x00E\x00\x00ab\x00";
    const hits = try extract(a, data, 4, 100);
    defer a.free(hits);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    try std.testing.expectEqual(@as(usize, 2), hits[0].offset);
    try std.testing.expectEqual(@as(usize, 11), hits[0].len);
    try std.testing.expect(!hits[0].wide);
    try std.testing.expect(hits[1].wide);
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("ABCDE", text(data, hits[1], &buf));
}

test "short runs are ignored" {
    const a = std.testing.allocator;
    const hits = try extract(a, "ab\x00cd\x00efg", 4, 10);
    defer a.free(hits);
    try std.testing.expectEqual(@as(usize, 0), hits.len);
}
