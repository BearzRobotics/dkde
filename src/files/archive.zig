//! Archives in the file manager (SPEC.md 5.4): which files are archives, and
//! names for the results. The unpacking and packing itself is arc.zig
//! (libarchive). Pure, so it is unit tested.

const std = @import("std");

pub const Kind = enum { zip, tar, tar_gz, tar_xz, tar_bz2, tar_zst, sevenz, rar, iso, cpio, deb, rpm };

const Suffix = struct { text: []const u8, kind: Kind };
const suffixes = [_]Suffix{
    .{ .text = ".tar.gz", .kind = .tar_gz },
    .{ .text = ".tgz", .kind = .tar_gz },
    .{ .text = ".tar.xz", .kind = .tar_xz },
    .{ .text = ".txz", .kind = .tar_xz },
    .{ .text = ".tar.bz2", .kind = .tar_bz2 },
    .{ .text = ".tbz2", .kind = .tar_bz2 },
    .{ .text = ".tar.zst", .kind = .tar_zst },
    .{ .text = ".tar", .kind = .tar },
    .{ .text = ".zip", .kind = .zip },
    .{ .text = ".7z", .kind = .sevenz },
    .{ .text = ".rar", .kind = .rar },
    .{ .text = ".iso", .kind = .iso },
    .{ .text = ".cpio", .kind = .cpio },
    .{ .text = ".deb", .kind = .deb },
    .{ .text = ".rpm", .kind = .rpm },
};

pub fn kindOf(name: []const u8) ?Kind {
    for (suffixes) |s| if (std.ascii.endsWithIgnoreCase(name, s.text)) return s.kind;
    return null;
}

/// The name without its archive suffix: "photos.tar.gz" gives "photos".
pub fn stem(name: []const u8) []const u8 {
    for (suffixes) |s| if (std.ascii.endsWithIgnoreCase(name, s.text)) return name[0 .. name.len - s.text.len];
    return name;
}

/// `base` if it is free, else "base (2)", "base (3)", ... `exists` says what is taken.
pub fn uniqueName(buf: []u8, base: []const u8, ext: []const u8, ctx: anytype, comptime exists: fn (@TypeOf(ctx), []const u8) bool) []const u8 {
    var n: usize = 1;
    while (n < 1000) : (n += 1) {
        const name = if (n == 1)
            std.fmt.bufPrint(buf, "{s}{s}", .{ base, ext }) catch return base
        else
            std.fmt.bufPrint(buf, "{s} ({d}){s}", .{ base, n, ext }) catch return base;
        if (!exists(ctx, name)) return name;
    }
    return base;
}

test "archive kinds by name" {
    try std.testing.expectEqual(Kind.tar_gz, kindOf("a.tar.gz").?);
    try std.testing.expectEqual(Kind.tar_gz, kindOf("A.TGZ").?);
    try std.testing.expectEqual(Kind.zip, kindOf("x.zip").?);
    try std.testing.expectEqual(Kind.tar, kindOf("x.tar").?);
    try std.testing.expect(kindOf("notes.txt") == null);
    try std.testing.expect(kindOf("zip") == null);
}

test "stem strips the whole suffix" {
    try std.testing.expectEqualStrings("photos", stem("photos.tar.gz"));
    try std.testing.expectEqualStrings("a.b", stem("a.b.zip"));
    try std.testing.expectEqualStrings("plain", stem("plain"));
}

test "unique names" {
    const taken = [_][]const u8{ "docs.zip", "docs (2).zip" };
    const Ctx = struct {
        fn exists(c: []const []const u8, name: []const u8) bool {
            for (c) |t| if (std.mem.eql(u8, t, name)) return true;
            return false;
        }
    };
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("docs (3).zip", uniqueName(&buf, "docs", ".zip", @as([]const []const u8, &taken), Ctx.exists));
    try std.testing.expectEqualStrings("new.zip", uniqueName(&buf, "new", ".zip", @as([]const []const u8, &taken), Ctx.exists));
}

test "more kinds libarchive reads" {
    try std.testing.expectEqual(Kind.iso, kindOf("disc.ISO").?);
    try std.testing.expectEqual(Kind.deb, kindOf("pkg_1.0_amd64.deb").?);
    try std.testing.expect(kindOf("report.docx") == null);
}
