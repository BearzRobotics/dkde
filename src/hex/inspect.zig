//! The data inspector of dkde-hex: what the bytes at the cursor mean as
//! numbers, text and bits. Pure, so it is unit tested.

const std = @import("std");

pub const Endian = enum { little, big };

pub const Row = struct { label: []const u8, text: []const u8 };

/// Fills `rows` (at most `max_rows`) from `bytes`, the bytes starting at the
/// cursor. Each text is written into `storage`; rows reference it.
pub fn inspect(bytes: []const u8, endian: Endian, storage: []u8, rows: []Row) usize {
    var used: usize = 0;
    var n: usize = 0;

    const Add = struct {
        fn add(rs: []Row, count: *usize, store: []u8, at: *usize, label: []const u8, comptime fmt: []const u8, args: anytype) void {
            if (count.* >= rs.len) return;
            const text = std.fmt.bufPrint(store[at.*..], fmt, args) catch return;
            rs[count.*] = .{ .label = label, .text = text };
            at.* += text.len;
            count.* += 1;
        }
    };

    if (bytes.len >= 1) {
        const v = bytes[0];
        Add.add(rows, &n, storage, &used, "uint8", "{d}", .{v});
        Add.add(rows, &n, storage, &used, "int8", "{d}", .{@as(i8, @bitCast(v))});
        Add.add(rows, &n, storage, &used, "binary", "{b:0>8}", .{v});
        if (v >= 0x20 and v < 0x7f) Add.add(rows, &n, storage, &used, "char", "'{c}'", .{v});
    }
    if (bytes.len >= 2) {
        const v = std.mem.readInt(u16, bytes[0..2], if (endian == .little) .little else .big);
        Add.add(rows, &n, storage, &used, "uint16", "{d}", .{v});
        Add.add(rows, &n, storage, &used, "int16", "{d}", .{@as(i16, @bitCast(v))});
    }
    if (bytes.len >= 4) {
        const e: std.builtin.Endian = if (endian == .little) .little else .big;
        const v = std.mem.readInt(u32, bytes[0..4], e);
        Add.add(rows, &n, storage, &used, "uint32", "{d}", .{v});
        Add.add(rows, &n, storage, &used, "int32", "{d}", .{@as(i32, @bitCast(v))});
        Add.add(rows, &n, storage, &used, "float32", "{e}", .{@as(f32, @bitCast(v))});
    }
    if (bytes.len >= 8) {
        const e: std.builtin.Endian = if (endian == .little) .little else .big;
        const v = std.mem.readInt(u64, bytes[0..8], e);
        Add.add(rows, &n, storage, &used, "uint64", "{d}", .{v});
        Add.add(rows, &n, storage, &used, "int64", "{d}", .{@as(i64, @bitCast(v))});
        Add.add(rows, &n, storage, &used, "float64", "{e}", .{@as(f64, @bitCast(v))});
    }
    return n;
}

test "inspector reads both byte orders" {
    var storage: [512]u8 = undefined;
    var rows: [16]Row = undefined;
    const bytes = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0, 0, 0, 0 };
    const n = inspect(&bytes, .little, &storage, &rows);
    try std.testing.expect(n >= 10);
    var found16 = false;
    var found32 = false;
    for (rows[0..n]) |r| {
        if (std.mem.eql(u8, r.label, "uint16")) {
            found16 = true;
            try std.testing.expectEqualStrings("513", r.text);
        }
        if (std.mem.eql(u8, r.label, "uint32")) {
            found32 = true;
            try std.testing.expectEqualStrings("67305985", r.text);
        }
    }
    try std.testing.expect(found16 and found32);
    const m = inspect(&bytes, .big, &storage, &rows);
    for (rows[0..m]) |r| {
        if (std.mem.eql(u8, r.label, "uint16")) try std.testing.expectEqualStrings("258", r.text);
    }
}

test "short input gives fewer rows" {
    var storage: [128]u8 = undefined;
    var rows: [16]Row = undefined;
    try std.testing.expectEqual(@as(usize, 0), inspect(&.{}, .little, &storage, &rows));
    const one = inspect(&[_]u8{'A'}, .little, &storage, &rows);
    try std.testing.expectEqual(@as(usize, 4), one);
    try std.testing.expectEqualStrings("'A'", rows[3].text);
}
