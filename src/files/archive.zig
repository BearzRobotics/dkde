//! Archives in the file manager (SPEC.md 5.4): which files are archives, and
//! the shell commands that unpack or pack them. The commands take their
//! arguments as positional parameters, never as script text, so odd file names
//! are safe. Pure, so it is unit tested.

const std = @import("std");

pub const Kind = enum { zip, tar, tar_gz, tar_xz, tar_bz2, tar_zst, sevenz, rar };

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

/// The program an archive of this kind needs, for telling the user when it is missing.
pub fn extractTool(kind: Kind) [:0]const u8 {
    return switch (kind) {
        .zip => "unzip",
        .tar, .tar_gz, .tar_xz, .tar_bz2, .tar_zst => "tar",
        .sevenz => "7z",
        .rar => "unrar",
    };
}

/// A `sh -c` script: $1 is the archive and $2 the folder to extract into.
pub fn extractScript(kind: Kind) []const u8 {
    return switch (kind) {
        .zip => "mkdir -p \"$2\" && unzip -o -q \"$1\" -d \"$2\"",
        .tar, .tar_gz, .tar_xz, .tar_bz2, .tar_zst => "mkdir -p \"$2\" && tar -xf \"$1\" -C \"$2\"",
        .sevenz => "mkdir -p \"$2\" && 7z x -y -o\"$2\" \"$1\" >/dev/null",
        .rar => "mkdir -p \"$2\" && unrar x -o+ -inul \"$1\" \"$2/\"",
    };
}

pub const Pack = enum { zip, tar_gz };

pub fn packTool(p: Pack) [:0]const u8 {
    return switch (p) {
        .zip => "zip",
        .tar_gz => "tar",
    };
}

pub fn packExtension(p: Pack) []const u8 {
    return switch (p) {
        .zip => ".zip",
        .tar_gz => ".tar.gz",
    };
}

/// A `sh -c` script: $1 is the folder holding the items, $2 the archive name
/// to create there, and the rest are the item names inside that folder.
pub fn packScript(p: Pack) []const u8 {
    return switch (p) {
        .zip => "cd \"$1\" || exit 1; out=$2; shift 2; zip -r -q \"$out\" -- \"$@\"",
        .tar_gz => "cd \"$1\" || exit 1; out=$2; shift 2; tar -czf \"$out\" -- \"$@\"",
    };
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

test "scripts take names as parameters" {
    // Nothing in the scripts is built from file names.
    try std.testing.expect(std.mem.indexOf(u8, packScript(.zip), "$@") != null);
    try std.testing.expect(std.mem.indexOf(u8, extractScript(.tar_gz), "\"$1\"") != null);
}
