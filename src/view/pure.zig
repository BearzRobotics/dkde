//! Pure helpers for the image viewer: which files are images, the order
//! they are shown in, zoom and pan arithmetic, orientation bookkeeping and
//! the Trash's records.

const std = @import("std");

const extensions = [_][]const u8{
    ".jpg",  ".jpeg", ".jpe", ".jfif", ".png", ".apng", ".gif", ".bmp", ".dib", ".webp",
    ".tif",  ".tiff", ".svg", ".svgz", ".ico", ".cur",  ".avif", ".heic", ".heif", ".jxl",
    ".qoi",  ".tga",  ".pcx", ".pbm",  ".pgm", ".ppm",  ".pnm", ".pam", ".xpm", ".xbm",
};

/// Whether a file name looks like an image the viewer may be able to load.
pub fn isImageName(name: []const u8) bool {
    for (extensions) |ext| if (std.ascii.endsWithIgnoreCase(name, ext)) return true;
    return false;
}

/// Names compared as people expect: case does not matter and runs of
/// digits compare as numbers, so "img2" comes before "img10".
pub fn naturalLess(a: []const u8, b: []const u8) bool {
    return naturalOrder(a, b) == .lt;
}

pub fn naturalOrder(a: []const u8, b: []const u8) std.math.Order {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        if (std.ascii.isDigit(a[i]) and std.ascii.isDigit(b[j])) {
            // Skip leading zeros, then the longer number is larger.
            var ie = i;
            while (ie < a.len and std.ascii.isDigit(a[ie])) ie += 1;
            var je = j;
            while (je < b.len and std.ascii.isDigit(b[je])) je += 1;
            var ia = i;
            while (ia + 1 < ie and a[ia] == '0') ia += 1;
            var jb = j;
            while (jb + 1 < je and b[jb] == '0') jb += 1;
            const la = ie - ia;
            const lb = je - jb;
            if (la != lb) return std.math.order(la, lb);
            const o = std.mem.order(u8, a[ia..ie], b[jb..je]);
            if (o != .eq) return o;
            i = ie;
            j = je;
            continue;
        }
        const ca = std.ascii.toLower(a[i]);
        const cb = std.ascii.toLower(b[j]);
        if (ca != cb) return std.math.order(ca, cb);
        i += 1;
        j += 1;
    }
    const o = std.math.order(a.len - i, b.len - j);
    // Equal but for case: keep a stable, total order.
    return if (o == .eq) std.mem.order(u8, a, b) else o;
}

pub const Sort = enum {
    name,
    date,
    size,

    pub fn parse(text: []const u8) Sort {
        return std.meta.stringToEnum(Sort, text) orelse .name;
    }
};

pub const Entry = struct { name: []const u8, mtime: i64, size: u64 };

pub fn entryLess(sort: Sort, reverse: bool, a: Entry, b: Entry) bool {
    const o: std.math.Order = switch (sort) {
        .name => naturalOrder(a.name, b.name),
        .date => if (a.mtime == b.mtime) naturalOrder(a.name, b.name) else std.math.order(a.mtime, b.mtime),
        .size => if (a.size == b.size) naturalOrder(a.name, b.name) else std.math.order(a.size, b.size),
    };
    return if (reverse) o == .gt else o == .lt;
}

// ---- zoom and pan -----------------------------------------------------------------

pub const zoom_min = 0.02;
pub const zoom_max = 32.0;

pub fn clampZoom(zoom: f64) f64 {
    return std.math.clamp(zoom, zoom_min, zoom_max);
}

const steps = [_]f64{ 0.02, 0.03, 0.05, 0.0625, 0.08, 0.1, 0.125, 0.15, 0.2, 0.25, 0.3, 0.33, 0.4, 0.5, 0.6, 0.67, 0.75, 0.85, 1, 1.25, 1.5, 2, 3, 4, 5, 6, 8, 10, 12, 16, 20, 24, 32 };

/// The next zoom step up or down from `zoom`, so zooming in from any level
/// lands on round percentages (as in Eye of GNOME).
pub fn stepZoom(zoom: f64, in: bool) f64 {
    if (in) {
        for (steps) |s| if (s > zoom * 1.001) return s;
        return zoom_max;
    }
    var i: usize = steps.len;
    while (i > 0) {
        i -= 1;
        if (steps[i] < zoom * 0.999) return steps[i];
    }
    return zoom_min;
}

pub const Fit = enum { best, width, fixed };

/// The zoom at which an image of `iw`×`ih` fits a view of `vw`×`vh`. Small
/// images are not enlarged unless `upscale`.
pub fn fitZoom(fit: Fit, iw: f64, ih: f64, vw: f64, vh: f64, upscale: bool) f64 {
    if (iw <= 0 or ih <= 0 or vw <= 0 or vh <= 0) return 1;
    const z = switch (fit) {
        .width => vw / iw,
        else => @min(vw / iw, vh / ih),
    };
    return clampZoom(if (upscale) z else @min(z, 1));
}

/// Where the image's left (or top) edge goes so that point `p` of the view
/// keeps showing the same spot of the image when the zoom goes from `z0` to `z1`.
pub fn zoomAround(offset: f64, p: f64, z0: f64, z1: f64) f64 {
    return p - (p - offset) * (z1 / z0);
}

/// Keeps the image in view along one axis: centred when it is smaller than
/// the view, otherwise with no gap at either edge.
pub fn clampOffset(offset: f64, image: f64, view: f64) f64 {
    if (image <= view) return @round((view - image) / 2);
    return std.math.clamp(offset, view - image, 0);
}

/// The rectangle between two points in image coordinates, inside a `w`×`h`
/// image, at least one pixel each way.
pub const Rect = struct { x: u32, y: u32, w: u32, h: u32 };

pub fn selection(x0: f64, y0: f64, x1: f64, y1: f64, w: u32, h: u32) ?Rect {
    const fw: f64 = @floatFromInt(w);
    const fh: f64 = @floatFromInt(h);
    const left = std.math.clamp(@floor(@min(x0, x1)), 0, fw);
    const top = std.math.clamp(@floor(@min(y0, y1)), 0, fh);
    const right = std.math.clamp(@ceil(@max(x0, x1)), 0, fw);
    const bottom = std.math.clamp(@ceil(@max(y0, y1)), 0, fh);
    if (right - left < 1 or bottom - top < 1) return null;
    return .{ .x = @intFromFloat(left), .y = @intFromFloat(top), .w = @intFromFloat(right - left), .h = @intFromFloat(bottom - top) };
}

/// The other side of a size when the proportions are kept.
pub fn keepRatio(changed: u32, from: u32, other: u32) u32 {
    if (from == 0) return other;
    const v = @as(f64, @floatFromInt(changed)) * @as(f64, @floatFromInt(other)) / @as(f64, @floatFromInt(from));
    return @max(1, @as(u32, @intFromFloat(@round(v))));
}

// ---- orientation -----------------------------------------------------------------

/// A turn of the picture: first mirrored left to right (when `flip`), then
/// turned `quarter` times clockwise. The eight EXIF orientations are these.
pub const Turn = struct {
    flip: bool = false,
    quarter: u2 = 0,

    pub fn fromExif(o: u8) Turn {
        return switch (o) {
            2 => .{ .flip = true },
            3 => .{ .quarter = 2 },
            4 => .{ .flip = true, .quarter = 2 },
            5 => .{ .flip = true, .quarter = 3 },
            6 => .{ .quarter = 1 },
            7 => .{ .flip = true, .quarter = 1 },
            8 => .{ .quarter = 3 },
            else => .{},
        };
    }

    pub fn toExif(t: Turn) u8 {
        const table = [2][4]u8{ .{ 1, 6, 3, 8 }, .{ 2, 7, 4, 5 } };
        return table[@intFromBool(t.flip)][t.quarter];
    }

    pub fn clockwise(t: Turn) Turn {
        return .{ .flip = t.flip, .quarter = t.quarter +% 1 };
    }

    pub fn counterClockwise(t: Turn) Turn {
        return .{ .flip = t.flip, .quarter = t.quarter -% 1 };
    }

    /// Mirrored left to right after `t`: a mirror after a turn is the
    /// opposite turn after a mirror.
    pub fn mirrored(t: Turn) Turn {
        return .{ .flip = !t.flip, .quarter = 0 -% t.quarter };
    }

    /// Mirrored top to bottom after `t` (a left-right mirror and a half turn).
    pub fn flippedVertically(t: Turn) Turn {
        const m = t.mirrored();
        return .{ .flip = m.flip, .quarter = m.quarter +% 2 };
    }

    pub fn isIdentity(t: Turn) bool {
        return !t.flip and t.quarter == 0;
    }
};

// ---- the Trash --------------------------------------------------------------------

/// The original path in a `.trashinfo` file (its `Path=` line, %-decoded).
pub fn trashInfoPath(gpa: std.mem.Allocator, text: []const u8) !?[]u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (!std.mem.startsWith(u8, line, "Path=")) continue;
        const v = line["Path=".len..];
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        var i: usize = 0;
        while (i < v.len) : (i += 1) {
            if (v[i] == '%' and i + 2 < v.len) {
                if (std.fmt.parseInt(u8, v[i + 1 .. i + 3], 16)) |c| {
                    try out.append(gpa, c);
                    i += 2;
                    continue;
                } else |_| {}
            }
            try out.append(gpa, v[i]);
        }
        return try out.toOwnedSlice(gpa);
    }
    return null;
}

// ---- words -----------------------------------------------------------------------

/// A file size as people read it: "812 bytes", "4.2 MB".
pub fn humanSize(buf: []u8, bytes: u64) []const u8 {
    if (bytes < 1000) return std.fmt.bufPrint(buf, "{d} bytes", .{bytes}) catch "";
    const units = [_][]const u8{ "kB", "MB", "GB", "TB" };
    var v: f64 = @floatFromInt(bytes);
    var u: usize = 0;
    v /= 1000;
    while (v >= 1000 and u + 1 < units.len) : (u += 1) v /= 1000;
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ v, units[u] }) catch "";
}

/// Index of the neighbour of `current` in a list of `len`; at either end it
/// wraps when `wrap`, otherwise stays.
pub fn neighbour(current: usize, len: usize, forward: bool, wrap: bool) usize {
    if (len == 0) return 0;
    if (forward) {
        if (current + 1 < len) return current + 1;
        return if (wrap) 0 else current;
    }
    if (current > 0) return current - 1;
    return if (wrap) len - 1 else current;
}

/// The writer gdk-pixbuf uses for a file name, by its extension.
pub fn saveType(name: []const u8) ?[:0]const u8 {
    const pairs = .{
        .{ ".png", "png" },   .{ ".jpg", "jpeg" }, .{ ".jpeg", "jpeg" }, .{ ".jpe", "jpeg" },
        .{ ".jfif", "jpeg" }, .{ ".bmp", "bmp" },  .{ ".tif", "tiff" },  .{ ".tiff", "tiff" },
        .{ ".ico", "ico" },   .{ ".webp", "webp" }, .{ ".avif", "avif" }, .{ ".heic", "heif" },
        .{ ".heif", "heif" }, .{ ".jxl", "jxl" },
    };
    inline for (pairs) |p| if (std.ascii.endsWithIgnoreCase(name, p[0])) return p[1];
    return null;
}

/// The kind of image in `bytes`, by its first bytes.
pub fn formatName(bytes: []const u8) [:0]const u8 {
    const starts = std.mem.startsWith;
    if (starts(u8, bytes, "\x89PNG")) return "PNG";
    if (starts(u8, bytes, "\xff\xd8")) return "JPEG";
    if (starts(u8, bytes, "GIF8")) return "GIF";
    if (starts(u8, bytes, "BM")) return "BMP";
    if (starts(u8, bytes, "II*\x00") or starts(u8, bytes, "MM\x00*")) return "TIFF";
    if (starts(u8, bytes, "qoif")) return "QOI";
    if (bytes.len >= 12 and starts(u8, bytes, "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return "WebP";
    if (bytes.len >= 2 and bytes[0] == 'P' and bytes[1] >= '1' and bytes[1] <= '7') return "Netpbm";
    if (bytes.len >= 1 and bytes[0] == 0x0A) return "PCX";
    return "Image";
}

test "image names" {
    try std.testing.expect(isImageName("a.PNG"));
    try std.testing.expect(isImageName("x.jpeg"));
    try std.testing.expect(isImageName("scan.HEIC"));
    try std.testing.expect(!isImageName("x.txt"));
}

test "natural order" {
    try std.testing.expect(naturalLess("img2.png", "img10.png"));
    try std.testing.expect(naturalLess("IMG_009", "img_10"));
    try std.testing.expect(naturalLess("a", "B"));
    try std.testing.expect(!naturalLess("img10", "img2"));
    try std.testing.expect(naturalLess("x007", "x8"));
    try std.testing.expect(naturalLess("a", "a1"));
    try std.testing.expectEqual(std.math.Order.eq, naturalOrder("same", "same"));
}

test "sorting by date and size" {
    const a: Entry = .{ .name = "b", .mtime = 1, .size = 9 };
    const b: Entry = .{ .name = "a", .mtime = 2, .size = 3 };
    try std.testing.expect(entryLess(.date, false, a, b));
    try std.testing.expect(entryLess(.size, false, b, a));
    try std.testing.expect(entryLess(.name, true, a, b));
    try std.testing.expectEqual(Sort.date, Sort.parse("date"));
    try std.testing.expectEqual(Sort.name, Sort.parse("bogus"));
}

test "zoom steps land on round values" {
    try std.testing.expectEqual(@as(f64, 1.25), stepZoom(1, true));
    try std.testing.expectEqual(@as(f64, 0.85), stepZoom(1, false));
    try std.testing.expectEqual(@as(f64, 0.5), stepZoom(0.43, true));
    try std.testing.expectEqual(@as(f64, zoom_max), stepZoom(zoom_max, true));
    try std.testing.expectEqual(@as(f64, zoom_min), stepZoom(zoom_min, false));
}

test "fitting" {
    try std.testing.expectEqual(@as(f64, 0.5), fitZoom(.best, 2000, 1000, 1000, 800, false));
    // A small picture is not enlarged unless asked.
    try std.testing.expectEqual(@as(f64, 1), fitZoom(.best, 100, 100, 1000, 800, false));
    try std.testing.expectEqual(@as(f64, 8), fitZoom(.best, 100, 100, 1000, 800, true));
    try std.testing.expectEqual(@as(f64, 0.25), fitZoom(.width, 4000, 100, 1000, 800, false));
}

test "zooming keeps the point under the pointer" {
    // Image starts at 0; the pointer at 100 shows image x 100 at zoom 1.
    const o = zoomAround(0, 100, 1, 2);
    try std.testing.expectEqual(@as(f64, -100), o);
    // At zoom 2 view x 100 is image x (100 - o) / 2 = 100.
    try std.testing.expectEqual(@as(f64, 100), (100 - o) / 2);
    try std.testing.expectEqual(@as(f64, 50), clampOffset(-5, 100, 200));
    try std.testing.expectEqual(@as(f64, -100), clampOffset(-300, 300, 200));
    try std.testing.expectEqual(@as(f64, 0), clampOffset(20, 300, 200));
}

test "selections" {
    const r = selection(10.4, 50, 2, 20.2, 100, 40).?;
    try std.testing.expectEqual(Rect{ .x = 2, .y = 20, .w = 9, .h = 20 }, r);
    try std.testing.expect(selection(5, 5, 5, 9, 100, 100) == null);
    try std.testing.expectEqual(@as(u32, 300), keepRatio(600, 800, 400));
}

test "turns compose like EXIF orientations" {
    var t: Turn = .{};
    for (1..9) |o| try std.testing.expectEqual(@as(u8, @intCast(o)), Turn.fromExif(@intCast(o)).toExif());
    t = t.clockwise();
    try std.testing.expectEqual(@as(u8, 6), t.toExif());
    t = t.clockwise().clockwise().clockwise();
    try std.testing.expect(t.isIdentity());
    // Mirror then mirror again is nothing; mirror of a quarter turn is a transverse.
    try std.testing.expect(Turn.fromExif(2).mirrored().isIdentity());
    try std.testing.expectEqual(@as(u8, 5), Turn.fromExif(6).mirrored().toExif());
    try std.testing.expectEqual(@as(u8, 4), (Turn{}).flippedVertically().toExif());
    try std.testing.expectEqual(@as(u8, 8), Turn.fromExif(6).flippedVertically().flippedVertically().counterClockwise().counterClockwise().toExif());
}

test "trash records" {
    const gpa = std.testing.allocator;
    const p = (try trashInfoPath(gpa, "[Trash Info]\nPath=/home/u/My%20Pics/a.jpg\nDeletionDate=2026-01-01T00:00:00\n")).?;
    defer gpa.free(p);
    try std.testing.expectEqualStrings("/home/u/My Pics/a.jpg", p);
    try std.testing.expect((try trashInfoPath(gpa, "nothing")) == null);
}

test "words" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("812 bytes", humanSize(&buf, 812));
    try std.testing.expectEqualStrings("4.2 MB", humanSize(&buf, 4_200_000));
    try std.testing.expectEqual(@as(usize, 0), neighbour(2, 3, true, true));
    try std.testing.expectEqual(@as(usize, 2), neighbour(2, 3, true, false));
    try std.testing.expectEqual(@as(usize, 2), neighbour(0, 3, false, true));
    try std.testing.expectEqualStrings("jpeg", saveType("A.JPG").?);
    try std.testing.expect(saveType("a.gif") == null);
    try std.testing.expectEqualStrings("PNG", formatName("\x89PNG\r\n"));
}
