//! Putting AppImages in the applications menu, with their own name and
//! icon, as AppImageLauncher and Gear Lever do.
//!
//! An AppImage is a program and a squashfs image glued together; the image
//! holds a `.desktop` entry and an icon (`.DirIcon`). They are read with
//! `unsquashfs` from the image's offset, so the AppImage itself is never run.
//! The entry is written to `~/.local/share/applications/dkde-appimage-*.desktop`
//! with an `Exec` that starts the AppImage file, and only the fields that
//! describe the app are taken from inside it (never its own commands).
//! Without `unsquashfs`, the entry gets the file's name and a generic icon.

const std = @import("std");
const glib = @import("glib2");
const fsio = @import("fsio.zig");

const log = std.log.scoped(.appimage);

/// The binding's return type cannot be null, but the end of a folder is.
extern fn g_dir_read_name(dir: *glib.Dir) ?[*:0]const u8;

/// Folders whose AppImages are added to the menu by themselves (the places
/// AppImage tools and users conventionally keep them).
pub const watched = [_][]const u8{ "Applications", "AppImages", ".local/bin" };

/// The entry files written here start with this, so they are never confused
/// with entries made by something else.
pub const prefix = "dkde-appimage-";

pub const Kind = enum { none, type1, type2 };

/// What the first bytes of a file say: an AppImage of type 1 (ISO 9660) or
/// type 2 (squashfs), or neither.
pub fn kindOf(header: []const u8) Kind {
    if (header.len < 11 or !std.mem.eql(u8, header[0..4], "\x7fELF")) return .none;
    if (header[8] == 'A' and header[9] == 'I') return switch (header[10]) {
        1 => .type1,
        2 => .type2,
        else => .none,
    };
    return .none;
}

/// Where the squashfs image of a type 2 AppImage starts: right after the
/// ELF section headers.
pub fn squashfsOffset(header: []const u8) ?u64 {
    if (header.len < 64 or kindOf(header) == .none) return null;
    const little = header[5] == 1;
    const endian: std.builtin.Endian = if (little) .little else .big;
    switch (header[4]) {
        2 => {
            const shoff = std.mem.readInt(u64, header[0x28..0x30], endian);
            const shentsize = std.mem.readInt(u16, header[0x3A..0x3C], endian);
            const shnum = std.mem.readInt(u16, header[0x3C..0x3E], endian);
            return shoff + @as(u64, shentsize) * shnum;
        },
        1 => {
            const shoff = std.mem.readInt(u32, header[0x20..0x24], endian);
            const shentsize = std.mem.readInt(u16, header[0x2E..0x30], endian);
            const shnum = std.mem.readInt(u16, header[0x30..0x32], endian);
            return @as(u64, shoff) + @as(u64, shentsize) * shnum;
        },
        else => return null,
    }
}

fn readHeader(path: [:0]const u8, buf: *[64]u8) []const u8 {
    const f = std.c.fopen(path.ptr, "rb") orelse return buf[0..0];
    defer _ = std.c.fclose(f);
    const n = std.c.fread(buf, 1, buf.len, f);
    return buf[0..n];
}

pub fn isAppImage(path: [:0]const u8) bool {
    var buf: [64]u8 = undefined;
    return kindOf(readHeader(path, &buf)) != .none;
}

/// "Inkscape-1.4.4-x86_64.AppImage" → "inkscape-1.4.4-x86_64", then a short
/// hash of the full path, so two copies in different folders differ.
pub fn idFor(buf: []u8, path: []const u8) []const u8 {
    var stem = std.fs.path.basename(path);
    if (std.ascii.endsWithIgnoreCase(stem, ".appimage")) stem = stem[0 .. stem.len - ".appimage".len];
    var n: usize = 0;
    for (stem) |c| {
        if (n + 10 >= buf.len) break;
        const ok = std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.';
        buf[n] = if (ok) std.ascii.toLower(c) else '-';
        n += 1;
    }
    const hash: u32 = @truncate(std.hash.Wyhash.hash(0, path));
    const tail = std.fmt.bufPrint(buf[n..], "-{x:0>8}", .{hash}) catch return buf[0..n];
    return buf[0 .. n + tail.len];
}

/// `path` as one argument of a desktop entry's `Exec` (quoted, with the
/// characters the specification reserves escaped, then escaped again as a
/// desktop entry string).
pub fn execArg(w: *std.Io.Writer, path: []const u8) !void {
    try w.writeByte('"');
    for (path) |c| switch (c) {
        // \" \` \$ \\ inside the quotes; every backslash doubled again for the file.
        '"', '`', '$' => {
            try w.writeAll("\\\\");
            try w.writeByte(c);
        },
        '\\' => try w.writeAll("\\\\\\\\"),
        '%' => try w.writeAll("%%"),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

/// The keys taken from the AppImage's own entry: what it is called and how
/// it is filed, never what it runs.
const kept = [_][]const u8{ "Name", "GenericName", "Comment", "Keywords", "Categories", "StartupWMClass", "Terminal", "NoDisplay" };

fn keepKey(key: []const u8) bool {
    const base = if (std.mem.indexOfScalar(u8, key, '[')) |i| key[0..i] else key;
    for (kept) |k| if (std.mem.eql(u8, k, base)) return true;
    return false;
}

/// The menu entry for the AppImage at `path`, from its embedded entry
/// (may be empty) and the icon (a path, or a theme icon name).
pub fn entryFor(gpa: std.mem.Allocator, embedded: []const u8, path: []const u8, icon: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("[Desktop Entry]\nType=Application\n");
    var has_name = false;
    var in_main = false;
    var lines = std.mem.splitScalar(u8, embedded, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len > 0 and line[0] == '[') {
            in_main = std.mem.eql(u8, line, "[Desktop Entry]");
            continue;
        }
        if (!in_main) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " ");
        if (!keepKey(key)) continue;
        if (std.mem.eql(u8, key, "Name")) has_name = true;
        try w.print("{s}={s}\n", .{ key, std.mem.trim(u8, line[eq + 1 ..], " ") });
    }
    if (!has_name) {
        var stem = std.fs.path.basename(path);
        if (std.ascii.endsWithIgnoreCase(stem, ".appimage")) stem = stem[0 .. stem.len - ".appimage".len];
        try w.print("Name={s}\n", .{stem});
    }
    try w.writeAll("Exec=");
    try execArg(w, path);
    try w.writeAll(" %U\nTryExec=");
    // TryExec is a plain string: only backslashes need escaping.
    for (path) |c| if (c == '\\') try w.writeAll("\\\\") else try w.writeByte(c);
    try w.print("\nIcon={s}\nX-DKDE-AppImage={s}\n", .{ icon, path });
    return out.toOwnedSlice();
}

// ---- files -------------------------------------------------------------------

fn dataHome(gpa: std.mem.Allocator, sub: []const u8) ![:0]u8 {
    return std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ std.mem.span(glib.getUserDataDir()), sub }, 0);
}

/// The menu entry file for the AppImage at `path`.
pub fn entryPath(gpa: std.mem.Allocator, path: []const u8) ![:0]u8 {
    var buf: [200]u8 = undefined;
    const id = idFor(&buf, path);
    return std.fmt.allocPrintSentinel(gpa, "{s}/applications/{s}{s}.desktop", .{ std.mem.span(glib.getUserDataDir()), prefix, id }, 0);
}

pub fn isIntegrated(gpa: std.mem.Allocator, path: []const u8) bool {
    const p = entryPath(gpa, path) catch return false;
    defer gpa.free(p);
    return fsio.exists(p);
}

/// Runs `argv` and waits; true when it exited normally with 0.
fn runQuiet(argv: []const []const u8) bool {
    const a = std.heap.c_allocator;
    const z = a.alloc(?[*:0]u8, argv.len + 1) catch return false;
    defer a.free(z);
    var made: usize = 0;
    defer for (z[0..made]) |p| a.free(std.mem.span(p.?));
    for (argv, 0..) |arg, i| {
        z[i] = (a.dupeSentinel(u8, arg, 0) catch return false).ptr;
        made += 1;
    }
    z[argv.len] = null;
    var status: c_int = 0;
    if (glib.spawnSync(null, @ptrCast(z.ptr), null, .{ .search_path = true, .stdout_to_dev_null = true, .stderr_to_dev_null = true }, null, null, null, null, &status, null) == 0) return false;
    return glib.spawnCheckWaitStatus(status, null) != 0;
}

/// Extracts `inner` paths from the image into `dir`.
fn extract(path: []const u8, offset: u64, dir: []const u8, inner: []const []const u8) bool {
    var off_buf: [24]u8 = undefined;
    const off = std.fmt.bufPrint(&off_buf, "{d}", .{offset}) catch return false;
    var argv: [16][]const u8 = undefined;
    const fixed = [_][]const u8{ "unsquashfs", "-q", "-n", "-f", "-o", off, "-d", dir, path };
    @memcpy(argv[0..fixed.len], &fixed);
    const n = @min(inner.len, argv.len - fixed.len);
    @memcpy(argv[fixed.len..][0..n], inner[0..n]);
    // unsquashfs reports files it did not find but still extracts the rest.
    _ = runQuiet(argv[0 .. fixed.len + n]);
    return true;
}

fn iconExtension(bytes: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, bytes, "\x89PNG")) return "png";
    const head = bytes[0..@min(bytes.len, 1024)];
    if (std.mem.indexOf(u8, head, "<svg") != null) return "svg";
    return null;
}

/// Adds the AppImage at `path` to the applications menu. Makes the file
/// executable for its owner (an AppImage cannot start otherwise).
pub fn integrate(gpa: std.mem.Allocator, path: [:0]const u8) !void {
    var header_buf: [64]u8 = undefined;
    const header = readHeader(path, &header_buf);
    const kind = kindOf(header);
    if (kind == .none) return error.NotAnAppImage;

    var embedded: []u8 = try gpa.dupe(u8, "");
    defer gpa.free(embedded);
    var icon: []u8 = try gpa.dupe(u8, "application-x-executable");
    defer gpa.free(icon);

    var id_buf: [200]u8 = undefined;
    const id = idFor(&id_buf, path);
    const have_unsquashfs = if (glib.findProgramInPath("unsquashfs")) |p| blk: {
        glib.free(p);
        break :blk true;
    } else false;
    if (kind == .type2 and have_unsquashfs) blk: {
        const offset = squashfsOffset(header) orelse break :blk;
        var err: ?*glib.Error = null;
        const tmp_c = glib.Dir.makeTmp("dkde-appimage-XXXXXX", &err) orelse {
            if (err) |e| e.free();
            break :blk;
        };
        defer glib.free(tmp_c);
        const tmp = std.mem.span(tmp_c);
        defer std.Io.Dir.cwd().deleteTree(fsio.io(), tmp) catch {};
        const out_dir = try std.fmt.allocPrint(gpa, "{s}/x", .{tmp});
        defer gpa.free(out_dir);
        _ = extract(path, offset, out_dir, &.{ ".DirIcon", "*.desktop" });

        // The entry: the first .desktop file at the top of the image.
        if (glib.Dir.open(@ptrCast(out_dir.ptr), 0, null)) |dir| {
            defer dir.close();
            while (g_dir_read_name(dir)) |name_c| {
                const name = std.mem.span(name_c);
                if (!std.mem.endsWith(u8, name, ".desktop")) continue;
                const p = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ out_dir, name });
                defer gpa.free(p);
                if (fsio.readFile(gpa, p, 64 << 10) catch null) |text| {
                    gpa.free(embedded);
                    embedded = text;
                }
                break;
            }
        }

        // The icon: .DirIcon, often a link to a file elsewhere in the image.
        var rel: []u8 = try gpa.dupe(u8, ".DirIcon");
        defer gpa.free(rel);
        var hops: usize = 0;
        while (hops < 4) : (hops += 1) {
            const p = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ out_dir, rel }, 0);
            defer gpa.free(p);
            if (glib.fileTest(p, .{ .is_symlink = true }) == 0) break;
            const target_c = glib.fileReadLink(p, null) orelse break;
            defer glib.free(target_c);
            const target = std.mem.span(target_c);
            // Inside the image only: an absolute or escaping link is not followed.
            if (target.len == 0 or target[0] == '/' or std.mem.indexOf(u8, target, "..") != null) break;
            const dir = std.fs.path.dirname(rel) orelse "";
            const next = if (dir.len > 0) try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, target }) else try gpa.dupe(u8, target);
            gpa.free(rel);
            rel = next;
            _ = extract(path, offset, out_dir, &.{rel});
        }
        const icon_src = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ out_dir, rel });
        defer gpa.free(icon_src);
        if (fsio.readFile(gpa, icon_src, 8 << 20) catch null) |bytes| {
            defer gpa.free(bytes);
            if (iconExtension(bytes)) |ext| {
                const icons_dir = try dataHome(gpa, "icons/dkde-appimage");
                defer gpa.free(icons_dir);
                fsio.makePath(icons_dir) catch {};
                const dest = try std.fmt.allocPrint(gpa, "{s}/{s}.{s}", .{ icons_dir, id, ext });
                if (fsio.writeFileAtomic(dest, bytes)) {
                    gpa.free(icon);
                    icon = dest;
                } else |_| gpa.free(dest);
            }
        }
    }

    const entry = try entryFor(gpa, embedded, path, icon);
    defer gpa.free(entry);
    const apps_dir = try dataHome(gpa, "applications");
    defer gpa.free(apps_dir);
    try fsio.makePath(apps_dir);
    const dest = try entryPath(gpa, path);
    defer gpa.free(dest);
    try fsio.writeFileAtomic(dest, entry);

    // Executable for its owner, as integration tools do.
    const st = std.Io.Dir.cwd().statFile(fsio.io(), path, .{}) catch return;
    const mode = st.permissions.toMode();
    if (mode & 0o100 == 0) std.Io.Dir.cwd().setFilePermissions(fsio.io(), path, .fromMode(mode | 0o100), .{}) catch {};
}

/// Takes the AppImage at `path` out of the menu (the file stays).
pub fn remove(gpa: std.mem.Allocator, path: []const u8) void {
    const entry = entryPath(gpa, path) catch return;
    defer gpa.free(entry);
    removeEntry(gpa, entry);
}

fn removeEntry(gpa: std.mem.Allocator, entry: []const u8) void {
    // Its icon, when it is one this file made.
    if (fsio.readFile(gpa, entry, 64 << 10) catch null) |text| {
        defer gpa.free(text);
        if (field(text, "Icon")) |icon| {
            if (std.mem.indexOf(u8, icon, "/icons/dkde-appimage/") != null) std.Io.Dir.cwd().deleteFile(fsio.io(), icon) catch {};
        }
    }
    std.Io.Dir.cwd().deleteFile(fsio.io(), entry) catch {};
}

fn field(text: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len > key.len and std.mem.startsWith(u8, line, key) and line[key.len] == '=') return std.mem.trimEnd(u8, line[key.len + 1 ..], "\r");
    }
    return null;
}

/// Removes the menu entries of AppImages that were deleted or moved, and
/// adds the AppImages in the watched folders that are not in the menu yet.
pub fn sync(gpa: std.mem.Allocator) void {
    const apps_dir = dataHome(gpa, "applications") catch return;
    defer gpa.free(apps_dir);
    if (glib.Dir.open(apps_dir, 0, null)) |dir| {
        defer dir.close();
        while (g_dir_read_name(dir)) |name_c| {
            const name = std.mem.span(name_c);
            if (!std.mem.startsWith(u8, name, prefix)) continue;
            const p = std.fmt.allocPrint(gpa, "{s}/{s}", .{ apps_dir, name }) catch continue;
            defer gpa.free(p);
            const text = (fsio.readFile(gpa, p, 64 << 10) catch null) orelse continue;
            defer gpa.free(text);
            const target = field(text, "X-DKDE-AppImage") orelse continue;
            if (!fsio.exists(target)) {
                log.info("{s} is gone; removing it from the menu", .{target});
                removeEntry(gpa, p);
            }
        }
    }
    const home = std.mem.span(glib.getHomeDir());
    for (watched) |sub| {
        const folder = std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ home, sub }, 0) catch continue;
        defer gpa.free(folder);
        const dir = glib.Dir.open(folder, 0, null) orelse continue;
        defer dir.close();
        while (g_dir_read_name(dir)) |name_c| {
            const name = std.mem.span(name_c);
            if (!std.ascii.endsWithIgnoreCase(name, ".appimage")) continue;
            const p = std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ folder, name }, 0) catch continue;
            defer gpa.free(p);
            if (isIntegrated(gpa, p) or !isAppImage(p)) continue;
            integrate(gpa, p) catch |e| log.warn("cannot add {s} to the menu: {s}", .{ p, @errorName(e) });
        }
    }
}

test "AppImage headers and the squashfs offset" {
    var h: [64]u8 = @splat(0);
    @memcpy(h[0..4], "\x7fELF");
    h[4] = 2; // 64-bit
    h[5] = 1; // little-endian
    try std.testing.expectEqual(Kind.none, kindOf(&h));
    h[8] = 'A';
    h[9] = 'I';
    h[10] = 2;
    std.mem.writeInt(u64, h[0x28..0x30], 0x1000, .little);
    std.mem.writeInt(u16, h[0x3A..0x3C], 64, .little);
    std.mem.writeInt(u16, h[0x3C..0x3E], 30, .little);
    try std.testing.expectEqual(Kind.type2, kindOf(&h));
    try std.testing.expectEqual(@as(?u64, 0x1000 + 64 * 30), squashfsOffset(&h));
    try std.testing.expectEqual(Kind.none, kindOf("#!/bin/sh"));
}

test "ids are tidy and differ by folder" {
    var a: [200]u8 = undefined;
    var b: [200]u8 = undefined;
    const x = idFor(&a, "/home/u/Inkscape-1.4.4 (x86_64).AppImage");
    const y = idFor(&b, "/home/u/Downloads/Inkscape-1.4.4 (x86_64).AppImage");
    try std.testing.expect(std.mem.startsWith(u8, x, "inkscape-1.4.4--x86_64--"));
    try std.testing.expect(!std.mem.eql(u8, x, y));
}

test "the entry keeps what describes the app and runs only the AppImage" {
    const gpa = std.testing.allocator;
    const embedded =
        \\[Desktop Entry]
        \\Name=Inkscape
        \\Name[fr]=Inkscape FR
        \\Exec=AppRun --evil %F
        \\Icon=org.inkscape.Inkscape
        \\Categories=Graphics;
        \\MimeType=image/svg+xml;
        \\StartupWMClass=org.inkscape.Inkscape
        \\
        \\[Desktop Action new]
        \\Name=New
        \\Exec=AppRun --new
    ;
    const e = try entryFor(gpa, embedded, "/home/u/My $App \"x\".AppImage", "/icons/i.png");
    defer gpa.free(e);
    try std.testing.expect(std.mem.indexOf(u8, e, "Name=Inkscape\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, e, "Name[fr]=Inkscape FR\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, e, "Categories=Graphics;\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, e, "StartupWMClass=org.inkscape.Inkscape\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, e, "AppRun") == null);
    try std.testing.expect(std.mem.indexOf(u8, e, "MimeType") == null);
    try std.testing.expect(std.mem.indexOf(u8, e, "Name=New") == null);
    try std.testing.expect(std.mem.indexOf(u8, e, "Exec=\"/home/u/My \\\\$App \\\\\"x\\\\\".AppImage\" %U\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, e, "Icon=/icons/i.png\n") != null);

    // No entry inside: the file's name.
    const f = try entryFor(gpa, "", "/a/Tool-2.AppImage", "application-x-executable");
    defer gpa.free(f);
    try std.testing.expect(std.mem.indexOf(u8, f, "Name=Tool-2\n") != null);
}
