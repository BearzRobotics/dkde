//! The list of things the help viewer can show: DKDE's own documents
//! (Markdown installed under share/dkde/help) and the system's manual pages,
//! found the way man(1) finds them. Finding, reading and parsing are dkman's;
//! this file only joins the two sources, filters and loads.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const dkman = @import("dkman");
const render = @import("render.zig");

pub const Source = enum { dkde, system };

pub const Entry = struct {
    /// Page or document name, e.g. `dkde-calendar` or `printf`.
    name: []const u8,
    /// Manual section (`1`, `3p`), empty for a document without one.
    section: []const u8,
    path: []const u8,
    source: Source,

    /// "name(1)", or just the name when there is no section.
    pub fn label(self: Entry, buf: []u8) []const u8 {
        if (self.section.len == 0) return self.name;
        return std.fmt.bufPrint(buf, "{s}({s})", .{ self.name, self.section }) catch self.name;
    }
};

/// Splits a file name from the help directory: `dkde-calc.1.md` is the page
/// `dkde-calc` in section 1; `guide.md` is a document without a section.
pub fn entryFromFileName(file_name: []const u8) ?struct { name: []const u8, section: []const u8 } {
    if (!std.mem.endsWith(u8, file_name, ".md")) return null;
    if (dkman.paths.splitFileName(file_name)) |p| return .{ .name = p.name, .section = p.section };
    return .{ .name = file_name[0 .. file_name.len - 3], .section = "" };
}

/// Documents in `dir_path`. A directory that cannot be read gives none: an
/// install without DKDE's documents still has the system pages.
pub fn dkdeEntries(arena: Allocator, io: Io, dir_path: []const u8) Allocator.Error![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return out.items;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |f| {
        if (f.kind != .file and f.kind != .sym_link) continue;
        // The template for authors is not documentation.
        if (std.mem.eql(u8, f.name, "template.md")) continue;
        const parts = entryFromFileName(f.name) orelse continue;
        try out.append(arena, .{
            .name = try arena.dupe(u8, parts.name),
            .section = try arena.dupe(u8, parts.section),
            .path = try std.fs.path.join(arena, &.{ dir_path, f.name }),
            .source = .dkde,
        });
    }
    return out.items;
}

/// Pages under the manual directories named by `manpath` (null: defaults).
pub fn systemEntries(arena: Allocator, io: Io, manpath: ?[]const u8) Allocator.Error![]Entry {
    const dirs = try dkman.paths.searchDirs(arena, manpath, &dkman.paths.default_dirs);
    const pages = try dkman.paths.scan(arena, io, dirs, null, null, false);
    const out = try arena.alloc(Entry, pages.len);
    for (pages, out) |p, *e| e.* = .{ .name = p.name, .section = p.section, .path = p.path, .source = .system };
    return out;
}

fn lessThan(_: void, a: Entry, b: Entry) bool {
    // DKDE's own documents first, then alphabetical by name, then section.
    if (a.source != b.source) return a.source == .dkde;
    const order = std.ascii.orderIgnoreCase(a.name, b.name);
    if (order != .eq) return order == .lt;
    return std.mem.lessThan(u8, a.section, b.section);
}

/// All entries from both sources, sorted.
pub fn all(arena: Allocator, io: Io, help_dir: ?[]const u8, manpath: ?[]const u8) Allocator.Error![]Entry {
    const own = if (help_dir) |d| try dkdeEntries(arena, io, d) else &[_]Entry{};
    const system = try systemEntries(arena, io, manpath);
    const out = try arena.alloc(Entry, own.len + system.len);
    @memcpy(out[0..own.len], own);
    @memcpy(out[own.len..], system);
    std.mem.sort(Entry, out, {}, lessThan);
    return out;
}

/// Indexes of the entries whose name contains `query` (case-insensitive), or
/// whose `name(section)` label does. An empty query matches all. The caller
/// frees the result.
pub fn filter(gpa: Allocator, entries: []const Entry, query: []const u8) Allocator.Error![]u32 {
    var out: std.ArrayList(u32) = .empty;
    errdefer out.deinit(gpa);
    const q = std.mem.trim(u8, query, " \t");
    for (entries, 0..) |e, i| {
        if (q.len == 0 or std.ascii.findIgnoreCase(e.name, q) != null) try out.append(gpa, @intCast(i));
    }
    return out.toOwnedSlice(gpa);
}

// ---- grouping --------------------------------------------------------------------------
//
// The list is shown in groups that open and close: by topic (DKDE's own
// documents first, by kind, then the manual sections by name), by section
// number, by the folder the pages are installed in, or by first letter.

pub const Grouping = enum {
    topic,
    section,
    folder,
    letter,

    pub fn label(self: Grouping) [:0]const u8 {
        return switch (self) {
            .topic => "By Topic",
            .section => "By Section",
            .folder => "By Folder",
            .letter => "A to Z",
        };
    }
};

pub const Group = struct {
    title: []const u8,
    /// Indexes into the entries, in their (sorted) order.
    members: []u32,
};

/// What a manual section holds, as man(7) names them.
pub fn sectionName(section: []const u8) []const u8 {
    if (section.len == 0) return "Documents";
    return switch (section[0]) {
        '1' => "User Commands",
        '2' => "System Calls",
        '3' => "Library Functions",
        '4' => "Devices and Special Files",
        '5' => "File Formats and Configuration",
        '6' => "Games",
        '7' => "Overviews, Conventions and Miscellany",
        '8' => "System Administration",
        '9' => "Kernel Routines",
        'n' => "Tcl/Tk",
        'l' => "Local",
        else => "Other",
    };
}

/// DKDE programs that are part of the desktop itself rather than applications.
const desktop_parts = [_][]const u8{ "dkde-panel", "dkde-notify", "dkde-idle", "dkde-polkit", "dkde-polkit-ui", "dkde-greeter", "dkde-setup", "dkde-pointer", "dkde-pdfcheck" };

fn dkdeTopic(e: Entry) []const u8 {
    if (e.section.len == 0 or e.section[0] == '7' or std.mem.indexOf(u8, e.name, "guide") != null) return "DKDE Guides";
    for (desktop_parts) |d| if (std.mem.eql(u8, e.name, d)) return "DKDE Desktop and System";
    return "DKDE Applications";
}

/// The manual tree a page is installed in: "/usr/share/man" for
/// "/usr/share/man/man1/ls.1.gz".
fn folderOf(path: []const u8) []const u8 {
    var i: usize = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] != '/') continue;
        const rest = path[i + 1 ..];
        if (std.mem.startsWith(u8, rest, "man") and rest.len > 3 and rest[3] != '/' and std.mem.lastIndexOfScalar(u8, rest, '/') != null) {
            // path[0..i] is ".../man" when this component is "manN".
            return path[0..i];
        }
    }
    return std.fs.path.dirname(path) orelse path;
}

fn keyOf(e: Entry, by: Grouping, letter_buf: *[2]u8) []const u8 {
    return switch (by) {
        .topic => if (e.source == .dkde) dkdeTopic(e) else sectionName(e.section),
        .section => sectionName(e.section),
        .folder => if (e.source == .dkde) "DKDE help" else folderOf(e.path),
        .letter => blk: {
            const c = if (e.name.len > 0) std.ascii.toUpper(e.name[0]) else '#';
            letter_buf[0] = if (std.ascii.isAlphabetic(c)) c else '#';
            break :blk letter_buf[0..1];
        },
    };
}

/// The order groups are shown in for a grouping.
fn rank(by: Grouping, title: []const u8) u8 {
    if (by == .topic) {
        const order = [_][]const u8{ "DKDE Applications", "DKDE Desktop and System", "DKDE Guides" };
        for (order, 0..) |o, i| if (std.mem.eql(u8, o, title)) return @intCast(i);
        return 10;
    }
    if (by == .folder and std.mem.eql(u8, title, "DKDE help")) return 0;
    return 10;
}

/// The entries in groups. Titles and members live in `arena`.
pub fn group(arena: Allocator, entries: []const Entry, by: Grouping) Allocator.Error![]Group {
    var titles: std.ArrayList([]const u8) = .empty;
    var members: std.ArrayList(std.ArrayList(u32)) = .empty;
    for (entries, 0..) |e, i| {
        var lb: [2]u8 = undefined;
        const key = keyOf(e, by, &lb);
        const at = for (titles.items, 0..) |tl, j| {
            if (std.mem.eql(u8, tl, key)) break j;
        } else blk: {
            try titles.append(arena, try arena.dupe(u8, key));
            try members.append(arena, .empty);
            break :blk titles.items.len - 1;
        };
        try members.items[at].append(arena, @intCast(i));
    }
    var out = try arena.alloc(Group, titles.items.len);
    for (titles.items, members.items, 0..) |tl, m, i| out[i] = .{ .title = tl, .members = m.items };
    const Ctx = struct { by: Grouping };
    std.mem.sort(Group, out, Ctx{ .by = by }, struct {
        fn less(c: Ctx, x: Group, y: Group) bool {
            const rx = rank(c.by, x.title);
            const ry = rank(c.by, y.title);
            if (rx != ry) return rx < ry;
            // Sections in their numeric order; folders and letters alphabetically.
            if (c.by == .topic or c.by == .section) {
                const sx = sectionOrder(x.title);
                const sy = sectionOrder(y.title);
                if (sx != sy) return sx < sy;
            }
            return std.ascii.orderIgnoreCase(x.title, y.title) == .lt;
        }
    }.less);
    return out;
}

fn sectionOrder(title: []const u8) u8 {
    const names = [_][]const u8{ "Documents", "User Commands", "System Calls", "Library Functions", "Devices and Special Files", "File Formats and Configuration", "Games", "Overviews, Conventions and Miscellany", "System Administration", "Kernel Routines", "Tcl/Tk", "Local", "Other" };
    for (names, 0..) |n, i| if (std.mem.eql(u8, n, title)) return @intCast(i);
    return 50;
}

pub const LoadError = dkman.source.Error || dkman.render.Error;

/// Reads, detects and renders the file at `path`. A page that is only a
/// `.so` redirect is followed once. Plain text comes back without ranges.
/// `dirs` are the manual directories for resolving redirects.
pub fn load(gpa: Allocator, io: Io, path: []const u8, dirs: []const []const u8) LoadError!render.Rendered {
    var content = try dkman.source.load(gpa, io, path);
    defer gpa.free(content);
    var shown = path;

    if (dkman.paths.soTarget(content)) |target| {
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        if (try dkman.paths.resolveSo(arena_state.allocator(), io, dirs, target)) |real| {
            const redirected = try dkman.source.load(gpa, io, real);
            gpa.free(content);
            content = redirected;
            shown = real;
        }
    }

    const fmt = dkman.format.detect(shown, content);
    if (fmt == .plain) {
        return .{ .text = try gpa.dupe(u8, content), .spans = try gpa.alloc(render.Span, 0) };
    }
    var doc = try dkman.render.parse(gpa, fmt, content);
    defer doc.deinit();
    return render.render(gpa, &doc);
}

test "file names become entries" {
    const t = std.testing;
    const a = entryFromFileName("dkde-calc.1.md").?;
    try t.expectEqualStrings("dkde-calc", a.name);
    try t.expectEqualStrings("1", a.section);
    const b = entryFromFileName("guide.md").?;
    try t.expectEqualStrings("guide", b.name);
    try t.expectEqualStrings("", b.section);
    try t.expect(entryFromFileName("notes.txt") == null);
}

test "filter ignores case and matches any part of the name" {
    const t = std.testing;
    const entries = [_]Entry{
        .{ .name = "printf", .section = "1", .path = "", .source = .system },
        .{ .name = "dkde-calc", .section = "1", .path = "", .source = .dkde },
        .{ .name = "Printf", .section = "3", .path = "", .source = .system },
    };
    const hits = try filter(t.allocator, &entries, " PRINT ");
    defer t.allocator.free(hits);
    try t.expectEqualSlices(u32, &.{ 0, 2 }, hits);
    const everything = try filter(t.allocator, &entries, "");
    defer t.allocator.free(everything);
    try t.expectEqual(@as(usize, 3), everything.len);
}

test "DKDE documents sort before system pages" {
    const t = std.testing;
    var list = [_]Entry{
        .{ .name = "a", .section = "1", .path = "", .source = .system },
        .{ .name = "z", .section = "1", .path = "", .source = .dkde },
        .{ .name = "a", .section = "3", .path = "", .source = .system },
    };
    std.mem.sort(Entry, &list, {}, lessThan);
    try t.expectEqualStrings("z", list[0].name);
    try t.expectEqualStrings("1", list[1].section);
    try t.expectEqualStrings("3", list[2].section);
}

test "labels" {
    var buf: [32]u8 = undefined;
    const e: Entry = .{ .name = "ls", .section = "1", .path = "", .source = .system };
    try std.testing.expectEqualStrings("ls(1)", e.label(&buf));
    const d: Entry = .{ .name = "guide", .section = "", .path = "", .source = .dkde };
    try std.testing.expectEqualStrings("guide", d.label(&buf));
}

test "groups by topic, section, folder and letter" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = [_]Entry{
        .{ .name = "dkde-calc", .section = "1", .path = "/h/dkde-calc.1.md", .source = .dkde },
        .{ .name = "dkde-calc-guide", .section = "7", .path = "/h/dkde-calc-guide.7.md", .source = .dkde },
        .{ .name = "dkde-panel", .section = "1", .path = "/h/dkde-panel.1.md", .source = .dkde },
        .{ .name = "ls", .section = "1", .path = "/usr/share/man/man1/ls.1.gz", .source = .system },
        .{ .name = "printf", .section = "3", .path = "/usr/share/man/man3/printf.3.gz", .source = .system },
        .{ .name = "zsh", .section = "1", .path = "/usr/local/share/man/man1/zsh.1", .source = .system },
    };
    const topic = try group(a, &entries, .topic);
    try t.expectEqualStrings("DKDE Applications", topic[0].title);
    try t.expectEqualStrings("DKDE Desktop and System", topic[1].title);
    try t.expectEqualStrings("DKDE Guides", topic[2].title);
    try t.expectEqualStrings("User Commands", topic[3].title);
    try t.expectEqual(@as(usize, 2), topic[3].members.len);
    try t.expectEqualStrings("Library Functions", topic[4].title);
    const section = try group(a, &entries, .section);
    try t.expectEqualStrings("User Commands", section[0].title);
    try t.expectEqual(@as(usize, 4), section[0].members.len);
    const folder = try group(a, &entries, .folder);
    try t.expectEqualStrings("DKDE help", folder[0].title);
    try t.expectEqualStrings("/usr/local/share/man", folder[1].title);
    try t.expectEqualStrings("/usr/share/man", folder[2].title);
    const letter = try group(a, &entries, .letter);
    try t.expectEqualStrings("D", letter[0].title);
    try t.expectEqual(@as(usize, 3), letter[0].members.len);
}
