//! Byte-level analysis for dkde-hex's reverse-engineering tools (SPEC.md 5.6):
//! checksums, entropy, histograms, searching with wildcards and for numbers,
//! comparing two buffers, copy-as text, and simple selection transforms.
//! No GTK here, so all of it is tested.

const std = @import("std");
const Allocator = std.mem.Allocator;

// -- checksums ---------------------------------------------------------------------------

pub const Sums = struct {
    md5: [32]u8,
    sha1: [40]u8,
    sha256: [64]u8,
    crc32: [8]u8,
};

fn hex(out: []u8, bytes: []const u8) void {
    const digits = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = digits[b >> 4];
        out[i * 2 + 1] = digits[b & 15];
    }
}

pub fn sums(data: []const u8) Sums {
    var s: Sums = undefined;
    var md5: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(data, &md5, .{});
    hex(&s.md5, &md5);
    var sha1: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(data, &sha1, .{});
    hex(&s.sha1, &sha1);
    var sha256: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &sha256, .{});
    hex(&s.sha256, &sha256);
    const crc = std.hash.Crc32.hash(data);
    var crc_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_bytes, crc, .big);
    hex(&s.crc32, &crc_bytes);
    return s;
}

// -- entropy and histogram -----------------------------------------------------------------

/// Shannon entropy of `data` in bits per byte, 0 to 8.
pub fn entropy(data: []const u8) f64 {
    if (data.len == 0) return 0;
    var counts: [256]u32 = @splat(0);
    for (data) |b| counts[b] += 1;
    const n: f64 = @floatFromInt(data.len);
    var h: f64 = 0;
    for (counts) |c| {
        if (c == 0) continue;
        const p = @as(f64, @floatFromInt(c)) / n;
        h -= p * @log2(p);
    }
    return h;
}

/// Entropy of each `block`-byte block (the last may be shorter), at most `max` blocks;
/// when there are more, blocks grow so that the whole file is covered.
pub fn entropyMap(allocator: Allocator, data: []const u8, max: usize) Allocator.Error!struct { values: []f64, block: usize } {
    var block: usize = 256;
    while (data.len / block > max) block *= 2;
    const n = (data.len + block - 1) / block;
    const out = try allocator.alloc(f64, n);
    for (out, 0..) |*v, i| v.* = entropy(data[i * block ..][0..@min(block, data.len - i * block)]);
    return .{ .values = out, .block = block };
}

pub fn histogram(data: []const u8) [256]u64 {
    var h: [256]u64 = @splat(0);
    for (data) |b| h[b] += 1;
    return h;
}

// -- searching -----------------------------------------------------------------------------

/// A search pattern in which some bytes may be anything.
pub const Pattern = struct {
    bytes: []u8,
    /// true where the byte must match.
    care: []bool,

    pub fn deinit(self: Pattern, a: Allocator) void {
        a.free(self.bytes);
        a.free(self.care);
    }
};

/// `de ad ?? ef` (also `DEAD??EF`, `0xDE`): `??` or `?` stands for any byte.
pub fn parsePattern(a: Allocator, text: []const u8) Allocator.Error!?Pattern {
    var bytes: std.ArrayList(u8) = .empty;
    var care: std.ArrayList(bool) = .empty;
    errdefer {
        bytes.deinit(a);
        care.deinit(a);
    }
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == ' ' or c == ',' or c == '\t') {
            i += 1;
            continue;
        }
        if (c == '0' and i + 1 < text.len and (text[i + 1] == 'x' or text[i + 1] == 'X')) {
            i += 2;
            continue;
        }
        if (c == '?') {
            i += if (i + 1 < text.len and text[i + 1] == '?') 2 else 1;
            try bytes.append(a, 0);
            try care.append(a, false);
            continue;
        }
        if (i + 1 >= text.len) return null;
        const hi = std.fmt.charToDigit(c, 16) catch return null;
        const lo = std.fmt.charToDigit(text[i + 1], 16) catch return null;
        try bytes.append(a, @intCast(hi * 16 + lo));
        try care.append(a, true);
        i += 2;
    }
    if (bytes.items.len == 0) return null;
    return .{ .bytes = try bytes.toOwnedSlice(a), .care = try care.toOwnedSlice(a) };
}

fn matchesAt(data: []const u8, at: usize, p: Pattern) bool {
    if (at + p.bytes.len > data.len) return false;
    for (p.bytes, p.care, 0..) |b, c, k| {
        if (c and data[at + k] != b) return false;
    }
    return true;
}

/// First match at or after `from` (forward) or before `from` (backward), wrapping.
pub fn find(data: []const u8, p: Pattern, from: usize, forward: bool) ?usize {
    if (p.bytes.len == 0 or p.bytes.len > data.len) return null;
    const last = data.len - p.bytes.len;
    if (forward) {
        var i = @min(from, last + 1);
        while (i <= last) : (i += 1) if (matchesAt(data, i, p)) return i;
        i = 0;
        while (i < @min(from, last + 1)) : (i += 1) if (matchesAt(data, i, p)) return i;
    } else {
        var i: usize = @min(from, last + 1);
        while (i > 0) {
            i -= 1;
            if (i <= last and matchesAt(data, i, p)) return i;
        }
        i = last + 1;
        while (i > @min(from, last + 1)) {
            i -= 1;
            if (matchesAt(data, i, p)) return i;
        }
    }
    return null;
}

pub const NumberKind = enum { u8, u16, u32, u64, i8, i16, i32, i64, f32, f64 };

/// The bytes of `text` written as `kind` in the given order; null if it is not a number of that kind.
pub fn numberBytes(a: Allocator, text: []const u8, kind: NumberKind, big: bool) Allocator.Error!?[]u8 {
    const t = std.mem.trim(u8, text, " ");
    var buf: [8]u8 = undefined;
    var size: usize = 0;
    switch (kind) {
        .f32 => {
            const f = std.fmt.parseFloat(f32, t) catch return null;
            std.mem.writeInt(u32, buf[0..4], @bitCast(f), if (big) .big else .little);
            size = 4;
        },
        .f64 => {
            const f = std.fmt.parseFloat(f64, t) catch return null;
            std.mem.writeInt(u64, buf[0..8], @bitCast(f), if (big) .big else .little);
            size = 8;
        },
        else => {
            const signed = switch (kind) {
                .i8, .i16, .i32, .i64 => true,
                else => false,
            };
            size = switch (kind) {
                .u8, .i8 => 1,
                .u16, .i16 => 2,
                .u32, .i32 => 4,
                else => 8,
            };
            const base: u8 = if (std.mem.startsWith(u8, t, "0x") or std.mem.startsWith(u8, t, "-0x")) 16 else 10;
            const digits = if (base == 16) std.mem.replaceOwned(u8, a, t, "0x", "") catch return error.OutOfMemory else try a.dupe(u8, t);
            defer a.free(digits);
            const value: u64 = if (signed) blk: {
                const v = std.fmt.parseInt(i64, digits, base) catch return null;
                const bits: u7 = @intCast(size * 8);
                if (bits < 64) {
                    const lim: i64 = @as(i64, 1) << @intCast(bits - 1);
                    if (v < -lim or v >= lim) return null;
                }
                break :blk @bitCast(v);
            } else blk: {
                const v = std.fmt.parseInt(u64, digits, base) catch return null;
                if (size < 8 and v >= (@as(u64, 1) << @intCast(size * 8))) return null;
                break :blk v;
            };
            var i: usize = 0;
            while (i < size) : (i += 1) {
                const shift: u6 = @intCast(if (big) (size - 1 - i) * 8 else i * 8);
                buf[i] = @truncate(value >> shift);
            }
        },
    }
    return try a.dupe(u8, buf[0..size]);
}

// -- comparing -----------------------------------------------------------------------------

pub const Diff = struct { start: usize, len: usize };

/// Stretches where `a` and `b` differ byte for byte, and the tail of the longer
/// one. Stretches closer than `gap` bytes are joined.
pub fn compare(allocator: Allocator, a: []const u8, b: []const u8, gap: usize) Allocator.Error![]Diff {
    var out: std.ArrayList(Diff) = .empty;
    errdefer out.deinit(allocator);
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (a[i] == b[i]) continue;
        if (out.items.len > 0) {
            const last = &out.items[out.items.len - 1];
            if (i - (last.start + last.len) <= gap) {
                last.len = i + 1 - last.start;
                continue;
            }
        }
        try out.append(allocator, .{ .start = i, .len = 1 });
    }
    if (a.len != b.len) try out.append(allocator, .{ .start = n, .len = @max(a.len, b.len) - n });
    return out.toOwnedSlice(allocator);
}

// -- copy as -------------------------------------------------------------------------------

pub const CopyAs = enum { hex, c_array, python, base64, escaped };

pub fn copyAs(a: Allocator, bytes: []const u8, kind: CopyAs) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    switch (kind) {
        .hex => for (bytes, 0..) |b, i| {
            if (i > 0) try out.append(a, ' ');
            try out.print(a, "{X:0>2}", .{b});
        },
        .c_array => {
            try out.print(a, "unsigned char data[{d}] = {{", .{bytes.len});
            for (bytes, 0..) |b, i| {
                if (i % 12 == 0) try out.appendSlice(a, "\n    ");
                try out.print(a, "0x{X:0>2}{s}", .{ b, if (i + 1 < bytes.len) ", " else "" });
            }
            try out.appendSlice(a, "\n};");
        },
        .python => {
            try out.appendSlice(a, "b\"");
            for (bytes) |b| try out.print(a, "\\x{x:0>2}", .{b});
            try out.append(a, '"');
        },
        .escaped => for (bytes) |b| {
            if (b >= 0x20 and b < 0x7f and b != '\\' and b != '"') try out.append(a, b) else try out.print(a, "\\x{x:0>2}", .{b});
        },
        .base64 => {
            const enc = std.base64.standard.Encoder;
            try out.resize(a, enc.calcSize(bytes.len));
            _ = enc.encode(out.items, bytes);
        },
    }
    return out.toOwnedSlice(a);
}

// -- transforms ----------------------------------------------------------------------------

/// XORs `data` in place with the repeating `key`.
pub fn xorWith(data: []u8, key: []const u8) void {
    if (key.len == 0) return;
    for (data, 0..) |*b, i| b.* ^= key[i % key.len];
}

pub fn reverse(data: []u8) void {
    std.mem.reverse(u8, data);
}

/// Swaps the bytes inside each `width`-byte unit (a trailing partial unit is left).
pub fn swapUnits(data: []u8, width: usize) void {
    if (width < 2) return;
    var i: usize = 0;
    while (i + width <= data.len) : (i += width) std.mem.reverse(u8, data[i .. i + width]);
}

// -- tests ---------------------------------------------------------------------------------

test "checksums of a known string" {
    const s = sums("abc");
    try std.testing.expectEqualStrings("900150983cd24fb0d6963f7d28e17f72", &s.md5);
    try std.testing.expectEqualStrings("a9993e364706816aba3e25717850c26c9cd0d89d", &s.sha1);
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", &s.sha256);
    try std.testing.expectEqualStrings("352441c2", &s.crc32);
}

test "entropy ranges from 0 to 8" {
    try std.testing.expectEqual(@as(f64, 0), entropy(&@as([64]u8, @splat(7))));
    var all: [256]u8 = undefined;
    for (&all, 0..) |*b, i| b.* = @intCast(i);
    try std.testing.expectApproxEqAbs(@as(f64, 8), entropy(&all), 1e-9);
    const a = std.testing.allocator;
    const m = try entropyMap(a, &all, 10);
    defer a.free(m.values);
    try std.testing.expectEqual(@as(usize, 1), m.values.len);
    const h = histogram("aab");
    try std.testing.expectEqual(@as(u64, 2), h['a']);
}

test "wildcard search finds, wraps and goes backwards" {
    const a = std.testing.allocator;
    const p = (try parsePattern(a, "de ?? ef")).?;
    defer p.deinit(a);
    const data = "xx\xde\x01\xefyy\xde\xff\xefzz";
    try std.testing.expectEqual(@as(?usize, 2), find(data, p, 0, true));
    try std.testing.expectEqual(@as(?usize, 7), find(data, p, 3, true));
    try std.testing.expectEqual(@as(?usize, 2), find(data, p, 8, true)); // wraps
    try std.testing.expectEqual(@as(?usize, 2), find(data, p, 7, false));
    try std.testing.expect((try parsePattern(a, "zz")) == null);
    try std.testing.expect((try parsePattern(a, "")) == null);
}

test "numbers become bytes in either order" {
    const a = std.testing.allocator;
    const le = (try numberBytes(a, "0x12345678", .u32, false)).?;
    defer a.free(le);
    try std.testing.expectEqualSlices(u8, &.{ 0x78, 0x56, 0x34, 0x12 }, le);
    const be = (try numberBytes(a, "258", .u16, true)).?;
    defer a.free(be);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, be);
    const neg = (try numberBytes(a, "-2", .i16, false)).?;
    defer a.free(neg);
    try std.testing.expectEqualSlices(u8, &.{ 0xFE, 0xFF }, neg);
    try std.testing.expect((try numberBytes(a, "300", .u8, false)) == null);
    try std.testing.expect((try numberBytes(a, "x", .u32, false)) == null);
    const f = (try numberBytes(a, "1.5", .f32, false)).?;
    defer a.free(f);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0xC0, 0x3F }, f);
}

test "comparison joins nearby differences and reports a longer tail" {
    const a = std.testing.allocator;
    const d = try compare(a, "abcdefghij", "aXcdeYghij!!", 1);
    defer a.free(d);
    try std.testing.expectEqual(@as(usize, 3), d.len);
    try std.testing.expectEqual(@as(usize, 1), d[0].start);
    try std.testing.expectEqual(@as(usize, 5), d[1].start);
    try std.testing.expectEqual(@as(usize, 10), d[2].start);
    try std.testing.expectEqual(@as(usize, 2), d[2].len);
    const joined = try compare(a, "abcdef", "aXcYef", 1);
    defer a.free(joined);
    try std.testing.expectEqual(@as(usize, 1), joined.len);
    try std.testing.expectEqual(@as(usize, 3), joined[0].len);
}

test "copy as" {
    const a = std.testing.allocator;
    const h = try copyAs(a, "\x01\xAB", .hex);
    defer a.free(h);
    try std.testing.expectEqualStrings("01 AB", h);
    const p = try copyAs(a, "A\x00", .python);
    defer a.free(p);
    try std.testing.expectEqualStrings("b\"\\x41\\x00\"", p);
    const c = try copyAs(a, "\x01\x02", .c_array);
    defer a.free(c);
    try std.testing.expect(std.mem.indexOf(u8, c, "data[2]") != null and std.mem.indexOf(u8, c, "0x02") != null);
    const b = try copyAs(a, "hello", .base64);
    defer a.free(b);
    try std.testing.expectEqualStrings("aGVsbG8=", b);
    const e = try copyAs(a, "a\"\n", .escaped);
    defer a.free(e);
    try std.testing.expectEqualStrings("a\\x22\\x0a", e);
}

test "transforms" {
    var d = [_]u8{ 1, 2, 3, 4 };
    xorWith(&d, &.{ 0xFF, 0x00 });
    try std.testing.expectEqualSlices(u8, &.{ 0xFE, 2, 0xFC, 4 }, &d);
    var e = [_]u8{ 1, 2, 3, 4, 5 };
    swapUnits(&e, 2);
    try std.testing.expectEqualSlices(u8, &.{ 2, 1, 4, 3, 5 }, &e);
    reverse(&e);
    try std.testing.expectEqual(@as(u8, 5), e[0]);
}
