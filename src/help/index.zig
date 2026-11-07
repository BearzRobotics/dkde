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
    const dirs = try dkman.paths.searchDirs(arena, manpath);
    const pages = try dkman.paths.scan(arena, io, dirs, null, null);
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

pub const LoadError = dkman.source.Error || render.Error;

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
