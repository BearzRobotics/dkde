//! Reading a photo's EXIF data (camera, exposure, date, place) for the
//! Properties pane, and changing a JPEG's orientation tag in place so a
//! rotation can be saved without recompressing the picture.
//!
//! EXIF is a TIFF structure; it is found in a JPEG's APP1 segment, a PNG's
//! eXIf chunk, a WebP's EXIF chunk or at the start of a TIFF file.

const std = @import("std");

/// The TIFF block holding the EXIF data of `bytes`, if any.
pub fn find(bytes: []const u8) ?[]const u8 {
    if (bytes.len >= 4 and (std.mem.startsWith(u8, bytes, "II*\x00") or std.mem.startsWith(u8, bytes, "MM\x00*"))) return bytes;
    if (bytes.len >= 4 and bytes[0] == 0xFF and bytes[1] == 0xD8) {
        const seg = jpegExifSegment(bytes) orelse return null;
        return bytes[seg.start + 10 .. seg.end];
    }
    if (std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) {
        var i: usize = 8;
        while (i + 12 <= bytes.len) {
            const len = std.mem.readInt(u32, bytes[i..][0..4], .big);
            const kind = bytes[i + 4 .. i + 8];
            if (i + 12 + len > bytes.len) return null;
            if (std.mem.eql(u8, kind, "eXIf")) return bytes[i + 8 .. i + 8 + len];
            if (std.mem.eql(u8, kind, "IDAT") or std.mem.eql(u8, kind, "IEND")) return null;
            i += 12 + len;
        }
        return null;
    }
    if (bytes.len >= 12 and std.mem.startsWith(u8, bytes, "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) {
        var i: usize = 12;
        while (i + 8 <= bytes.len) {
            const len = std.mem.readInt(u32, bytes[i + 4 ..][0..4], .little);
            if (i + 8 + len > bytes.len) return null;
            if (std.mem.eql(u8, bytes[i .. i + 4], "EXIF")) {
                const body = bytes[i + 8 .. i + 8 + len];
                return if (std.mem.startsWith(u8, body, "Exif\x00\x00")) body[6..] else body;
            }
            i += 8 + len + (len & 1);
        }
    }
    return null;
}

const Segment = struct { start: usize, end: usize };

/// The JPEG's APP1 "Exif" segment: `start` is its 0xFF marker, `end` one past it.
fn jpegExifSegment(bytes: []const u8) ?Segment {
    var i: usize = 2;
    while (i + 4 <= bytes.len) {
        if (bytes[i] != 0xFF) return null;
        const marker = bytes[i + 1];
        if (marker == 0xFF) {
            i += 1;
            continue;
        }
        if (marker == 0xDA or marker == 0xD9) return null;
        const len = (@as(usize, bytes[i + 2]) << 8) | bytes[i + 3];
        if (len < 2 or i + 2 + len > bytes.len) return null;
        if (marker == 0xE1 and len >= 16 and std.mem.eql(u8, bytes[i + 4 .. i + 10], "Exif\x00\x00")) return .{ .start = i, .end = i + 2 + len };
        i += 2 + len;
    }
    return null;
}

const Tiff = struct {
    t: []const u8,
    big: bool,

    fn u16At(self: Tiff, off: usize) ?u16 {
        if (off + 2 > self.t.len) return null;
        return std.mem.readInt(u16, self.t[off..][0..2], if (self.big) .big else .little);
    }

    fn u32At(self: Tiff, off: usize) ?u32 {
        if (off + 4 > self.t.len) return null;
        return std.mem.readInt(u32, self.t[off..][0..4], if (self.big) .big else .little);
    }

    const Field = struct { tag: u16, kind: u16, count: u32, entry: usize };

    /// Calls `f` for every entry of the directory at `ifd`.
    fn entries(self: Tiff, ifd: usize, out: []Field) []Field {
        const n = self.u16At(ifd) orelse return out[0..0];
        var k: usize = 0;
        while (k < n and k < out.len) : (k += 1) {
            const e = ifd + 2 + k * 12;
            out[k] = .{
                .tag = self.u16At(e) orelse break,
                .kind = self.u16At(e + 2) orelse break,
                .count = self.u32At(e + 4) orelse break,
                .entry = e,
            };
        }
        return out[0..k];
    }

    fn typeSize(kind: u16) usize {
        return switch (kind) {
            1, 2, 6, 7 => 1,
            3, 8 => 2,
            4, 9, 11 => 4,
            5, 10, 12 => 8,
            else => 0,
        };
    }

    /// Where a field's value is: inside the entry when it fits in four bytes.
    fn valueAt(self: Tiff, f: Field) ?usize {
        const size = typeSize(f.kind) * f.count;
        if (size == 0) return null;
        const at = if (size <= 4) f.entry + 8 else (self.u32At(f.entry + 8) orelse return null);
        if (at + size > self.t.len) return null;
        return at;
    }

    fn text(self: Tiff, f: Field) ?[]const u8 {
        if (f.kind != 2) return null;
        const at = self.valueAt(f) orelse return null;
        const s = std.mem.trim(u8, std.mem.sliceTo(self.t[at .. at + f.count], 0), " \t");
        return if (s.len == 0) null else s;
    }

    fn int(self: Tiff, f: Field) ?u32 {
        const at = self.valueAt(f) orelse return null;
        return switch (f.kind) {
            1 => self.t[at],
            3 => if (self.u16At(at)) |v| v else null,
            4 => self.u32At(at),
            else => null,
        };
    }

    fn rational(self: Tiff, f: Field, index: usize) ?f64 {
        // Some writers store a fraction as two integers.
        if ((f.kind == 3 or f.kind == 4) and f.count == 2 and index == 0) {
            const at = self.valueAt(f) orelse return null;
            const short = f.kind == 3;
            const n: f64 = @floatFromInt(if (short) (self.u16At(at) orelse return null) else (self.u32At(at) orelse return null));
            const d: f64 = @floatFromInt(if (short) (self.u16At(at + 2) orelse return null) else (self.u32At(at + 4) orelse return null));
            return if (d == 0) null else n / d;
        }
        if (f.kind != 5 and f.kind != 10) return null;
        if (index >= f.count) return null;
        const at = (self.valueAt(f) orelse return null) + index * 8;
        const n = self.u32At(at) orelse return null;
        const d = self.u32At(at + 4) orelse return null;
        if (d == 0) return null;
        if (f.kind == 10) return @as(f64, @floatFromInt(@as(i32, @bitCast(n)))) / @as(f64, @floatFromInt(@as(i32, @bitCast(d))));
        return @as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(d));
    }
};

pub const Info = struct {
    make: ?[]const u8 = null,
    model: ?[]const u8 = null,
    lens: ?[]const u8 = null,
    software: ?[]const u8 = null,
    artist: ?[]const u8 = null,
    copyright: ?[]const u8 = null,
    description: ?[]const u8 = null,
    /// "YYYY:MM:DD HH:MM:SS", when the picture was taken (or else last changed).
    taken: ?[]const u8 = null,
    orientation: u8 = 1,
    exposure: ?f64 = null,
    f_number: ?f64 = null,
    iso: ?u32 = null,
    focal_length: ?f64 = null,
    focal_35mm: ?u32 = null,
    flash: ?u32 = null,
    latitude: ?f64 = null,
    longitude: ?f64 = null,
    altitude: ?f64 = null,

    pub fn any(self: Info) bool {
        inline for (@typeInfo(Info).@"struct".field_names) |name| {
            if (comptime std.mem.eql(u8, name, "orientation")) continue;
            if (@field(self, name) != null) return true;
        }
        return false;
    }
};

/// Reads the fields the Properties pane shows; the strings point into `block`.
pub fn parse(block: []const u8) Info {
    var info: Info = .{};
    if (block.len < 8) return info;
    const big = block[0] == 'M';
    if (!big and block[0] != 'I') return info;
    const tiff: Tiff = .{ .t = block, .big = big };
    var buf: [128]Tiff.Field = undefined;
    const ifd0 = tiff.u32At(4) orelse return info;
    var exif_ifd: ?u32 = null;
    var gps_ifd: ?u32 = null;
    var date: ?[]const u8 = null;
    for (tiff.entries(ifd0, &buf)) |f| switch (f.tag) {
        0x010E => info.description = tiff.text(f),
        0x010F => info.make = tiff.text(f),
        0x0110 => info.model = tiff.text(f),
        0x0112 => if (tiff.int(f)) |o| {
            if (o >= 1 and o <= 8) info.orientation = @intCast(o);
        },
        0x0131 => info.software = tiff.text(f),
        0x0132 => date = tiff.text(f),
        0x013B => info.artist = tiff.text(f),
        0x8298 => info.copyright = tiff.text(f),
        0x8769 => exif_ifd = tiff.int(f),
        0x8825 => gps_ifd = tiff.int(f),
        else => {},
    };
    if (exif_ifd) |ifd| for (tiff.entries(ifd, &buf)) |f| switch (f.tag) {
        0x829A => info.exposure = tiff.rational(f, 0),
        0x829D => info.f_number = tiff.rational(f, 0),
        0x8827 => info.iso = tiff.int(f),
        0x9003 => info.taken = tiff.text(f),
        0x9209 => info.flash = tiff.int(f),
        0x920A => info.focal_length = tiff.rational(f, 0),
        0xA405 => info.focal_35mm = tiff.int(f),
        0xA434 => info.lens = tiff.text(f),
        else => {},
    };
    if (info.taken == null) info.taken = date;
    if (gps_ifd) |ifd| {
        var lat_ref: u8 = 'N';
        var lon_ref: u8 = 'E';
        var below_sea = false;
        for (tiff.entries(ifd, &buf)) |f| switch (f.tag) {
            1 => if (tiff.text(f)) |t| {
                lat_ref = t[0];
            },
            2 => info.latitude = degrees(tiff, f),
            3 => if (tiff.text(f)) |t| {
                lon_ref = t[0];
            },
            4 => info.longitude = degrees(tiff, f),
            5 => if (tiff.int(f)) |v| {
                below_sea = v == 1;
            },
            6 => info.altitude = tiff.rational(f, 0),
            else => {},
        };
        if (info.latitude) |*v| if (lat_ref == 'S') {
            v.* = -v.*;
        };
        if (info.longitude) |*v| if (lon_ref == 'W') {
            v.* = -v.*;
        };
        if (info.altitude) |*v| if (below_sea) {
            v.* = -v.*;
        };
    }
    return info;
}

fn degrees(tiff: Tiff, f: Tiff.Field) ?f64 {
    const d = tiff.rational(f, 0) orelse return null;
    const m = tiff.rational(f, 1) orelse 0;
    const s = tiff.rational(f, 2) orelse 0;
    return d + m / 60 + s / 3600;
}

// ---- writing the orientation ---------------------------------------------------------

/// A copy of the JPEG `bytes` showing orientation `o` (1 to 8): the tag is
/// changed in place, or a small EXIF segment is added when there is none.
/// Null when the file has EXIF data without an orientation tag (the caller
/// then saves the turned pixels instead).
pub fn withOrientation(gpa: std.mem.Allocator, bytes: []const u8, o: u8) !?[]u8 {
    if (bytes.len < 4 or bytes[0] != 0xFF or bytes[1] != 0xD8) return null;
    if (jpegExifSegment(bytes)) |seg| {
        const block = bytes[seg.start + 10 .. seg.end];
        const at = orientationValueAt(block) orelse return null;
        const out = try gpa.dupe(u8, bytes);
        const big = block[0] == 'M';
        std.mem.writeInt(u16, out[seg.start + 10 + at ..][0..2], o, if (big) .big else .little);
        return out;
    }
    // SOI, then APP1 "Exif" with a little-endian TIFF holding only the orientation.
    const app1 = [_]u8{ 0xFF, 0xE1, 0x00, 0x22, 'E', 'x', 'i', 'f', 0, 0, 'I', 'I', 0x2A, 0, 8, 0, 0, 0, 1, 0, 0x12, 0x01, 3, 0, 1, 0, 0, 0, o, 0, 0, 0, 0, 0, 0, 0 };
    const out = try gpa.alloc(u8, bytes.len + app1.len);
    @memcpy(out[0..2], bytes[0..2]);
    @memcpy(out[2 .. 2 + app1.len], &app1);
    @memcpy(out[2 + app1.len ..], bytes[2..]);
    return out;
}

/// Where, in the TIFF block, the orientation's two bytes are.
fn orientationValueAt(block: []const u8) ?usize {
    if (block.len < 8) return null;
    const tiff: Tiff = .{ .t = block, .big = block[0] == 'M' };
    var buf: [128]Tiff.Field = undefined;
    const ifd0 = tiff.u32At(4) orelse return null;
    for (tiff.entries(ifd0, &buf)) |f| {
        if (f.tag == 0x0112 and f.kind == 3 and f.count == 1) return f.entry + 8;
    }
    return null;
}

/// The EXIF segment of `original` (with its orientation set to 1, since the
/// pixels are now upright) put into the freshly written JPEG `fresh`, so a
/// re-saved photo keeps its camera data. Null when there is nothing to keep.
pub fn carryOver(gpa: std.mem.Allocator, original: []const u8, fresh: []const u8) !?[]u8 {
    if (original.len < 4 or original[0] != 0xFF or original[1] != 0xD8) return null;
    if (fresh.len < 4 or fresh[0] != 0xFF or fresh[1] != 0xD8) return null;
    const seg = jpegExifSegment(original) orelse return null;
    const app1 = original[seg.start..seg.end];
    // After SOI and any JFIF APP0 of the fresh file.
    var at: usize = 2;
    if (fresh.len > 6 and fresh[2] == 0xFF and fresh[3] == 0xE0) {
        const len = (@as(usize, fresh[4]) << 8) | fresh[5];
        if (4 + len <= fresh.len) at = 4 + len;
    }
    const out = try gpa.alloc(u8, fresh.len + app1.len);
    @memcpy(out[0..at], fresh[0..at]);
    @memcpy(out[at .. at + app1.len], app1);
    @memcpy(out[at + app1.len ..], fresh[at..]);
    if (orientationValueAt(out[at + 10 .. at + app1.len])) |v| {
        const big = out[at + 10] == 'M';
        std.mem.writeInt(u16, out[at + 10 + v ..][0..2], 1, if (big) .big else .little);
    }
    return out;
}

// ---- words ------------------------------------------------------------------------

/// "1/250 s", "2.5 s".
pub fn exposureText(buf: []u8, seconds: f64) []const u8 {
    if (seconds <= 0) return "";
    if (seconds < 0.5) return std.fmt.bufPrint(buf, "1/{d:.0} s", .{1 / seconds}) catch "";
    return std.fmt.bufPrint(buf, "{d:.1} s", .{seconds}) catch "";
}

/// "Fired", "Did not fire".
pub fn flashText(v: u32) []const u8 {
    return if (v & 1 != 0) "Fired" else "Did not fire";
}

/// "2024:07:19 18:03:11" as "2024-07-19 18:03".
pub fn dateText(buf: []u8, raw: []const u8) []const u8 {
    if (raw.len < 16) return raw;
    return std.fmt.bufPrint(buf, "{s}-{s}-{s} {s}", .{ raw[0..4], raw[5..7], raw[8..10], raw[11..16] }) catch raw;
}

const sample_be = "MM\x00*\x00\x00\x00\x08" ++
    // IFD0: 4 entries
    "\x00\x04" ++
    "\x01\x0F\x00\x02\x00\x00\x00\x06\x00\x00\x00\x3E" ++ // Make -> 62
    "\x01\x12\x00\x03\x00\x00\x00\x01\x00\x06\x00\x00" ++ // Orientation 6
    "\x87\x69\x00\x04\x00\x00\x00\x01\x00\x00\x00\x44" ++ // Exif IFD -> 68
    "\x88\x25\x00\x04\x00\x00\x00\x01\x00\x00\x00\x6E" ++ // GPS IFD -> 110
    "\x00\x00\x00\x00" ++ // next IFD
    "Canon\x00" ++ // 62..67
    // Exif IFD at 68: 3 entries
    "\x00\x03" ++
    "\x82\x9A\x00\x05\x00\x00\x00\x01\x00\x00\x00\x9C" ++ // Exposure -> 156
    "\x88\x27\x00\x03\x00\x00\x00\x01\x01\x90\x00\x00" ++ // ISO 400
    "\x92\x09\x00\x03\x00\x00\x00\x01\x00\x01\x00\x00" ++ // Flash fired
    "\x00\x00\x00\x00" ++
    // GPS IFD at 110: 2 entries
    "\x00\x02" ++
    "\x00\x01\x00\x02\x00\x00\x00\x02S\x00\x00\x00" ++ // LatRef S
    "\x00\x02\x00\x05\x00\x00\x00\x03\x00\x00\x00\xA4" ++ // Lat -> 164
    "\x00\x00\x00\x00" ++
    // pad to 156
    "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" ++
    "\x00\x00\x00\x01\x00\x00\x00\xFA" ++ // 1/250 at 156
    "\x00\x00\x00\x21\x00\x00\x00\x01" ++ // 33 deg at 164
    "\x00\x00\x00\x1E\x00\x00\x00\x01" ++ // 30 min
    "\x00\x00\x00\x00\x00\x00\x00\x01"; // 0 s

test "camera data is read" {
    const info = parse(sample_be);
    try std.testing.expectEqualStrings("Canon", info.make.?);
    try std.testing.expectEqual(@as(u8, 6), info.orientation);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 250.0), info.exposure.?, 1e-9);
    try std.testing.expectEqual(@as(u32, 400), info.iso.?);
    try std.testing.expectEqualStrings("Fired", flashText(info.flash.?));
    try std.testing.expectApproxEqAbs(@as(f64, -33.5), info.latitude.?, 1e-9);
    try std.testing.expect(info.any());
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1/250 s", exposureText(&buf, info.exposure.?));
    try std.testing.expectEqualStrings("2024-07-19 18:03", dateText(&buf, "2024:07:19 18:03:11"));
}

test "broken data is not trusted" {
    try std.testing.expect(!parse("MM\x00*\xff\xff\xff\xff").any());
    try std.testing.expect(!parse("").any());
    var cut = sample_be[0..100].*;
    _ = parse(&cut);
}

test "the orientation is rewritten in place or added" {
    const gpa = std.testing.allocator;
    const app_len = 2 + 6 + sample_be.len;
    const jpeg = "\xFF\xD8\xFF\xE1" ++ &[_]u8{ app_len >> 8, app_len & 0xFF } ++ "Exif\x00\x00" ++ sample_be ++ "\xFF\xD9";
    const turned = (try withOrientation(gpa, jpeg, 3)).?;
    defer gpa.free(turned);
    try std.testing.expectEqual(@as(u8, 3), parse(find(turned).?).orientation);
    try std.testing.expectEqualStrings("Canon", parse(find(turned).?).make.?);

    const bare = "\xFF\xD8\xFF\xDB\x00\x02\xFF\xD9";
    const added = (try withOrientation(gpa, bare, 8)).?;
    defer gpa.free(added);
    try std.testing.expectEqual(@as(u8, 8), parse(find(added).?).orientation);

    const kept = (try carryOver(gpa, jpeg, bare)).?;
    defer gpa.free(kept);
    const info = parse(find(kept).?);
    try std.testing.expectEqual(@as(u8, 1), info.orientation);
    try std.testing.expectEqualStrings("Canon", info.make.?);
}

test "PNG and WebP carry EXIF too" {
    const png = "\x89PNG\r\n\x1a\n" ++ "\x00\x00\x00\x08eXIf" ++ "II*\x00\x08\x00\x00\x00" ++ "CRC!";
    try std.testing.expectEqualStrings("II*\x00\x08\x00\x00\x00", find(png).?);
    const webp = "RIFF\x00\x00\x00\x00WEBP" ++ "EXIF\x0E\x00\x00\x00" ++ "Exif\x00\x00II*\x00\x08\x00\x00\x00";
    try std.testing.expectEqualStrings("II*\x00\x08\x00\x00\x00", find(webp).?);
}
