//! Lessons as TOML files (data/learn/<course>/*.toml, and ~/.local/share/dkde/learn/ for your own).
//! One file is one lesson:
//!
//!   id = "I.1"
//!   course = "Euclid"                # the subject; Euclid when left out
//!   book = 1                         # the unit within the course (0 = the first/foundations)
//!   order = 4                        # sorts the lessons within a book
//!   title = "An equilateral triangle on a given line"
//!   statement = "..."
//!   proof = "..."                    # optional
//!
//!   [[step]]
//!   text = "Let AB be the given finite straight line."
//!   draw = ["point A -2.5 -1.5", "point B 2.5 -1.5", "segment A B black"]   # see figure.zig
//!   calc = ["3/4 + 1/6"]             # optional: lines to try in the calculator
//!   work = ["3/4 + 1/6"]             # optional: entries the solver writes out by hand
//!   graph = ["x^2 - 4"]              # optional: expressions in x to plot beside the lesson
//!   mode = "programmer"              # optional: put the calculator in this mode (standard, scientific, programmer)
//!   base = 16                        # optional, programmer mode: 2, 8, 10 or 16
//!   bits = 32                        # optional, programmer mode: word size 8, 16, 32 or 64
//!
//!   [[exercise]]                     # optional practice; the answer is an entry the engine works out
//!   prompt = "Work out 2/3 + 1/4."
//!   answer = "2/3 + 1/4"
//!   hint = "A common denominator is 12."
//!
//! A file that does not read is left out, and the reason (file, step, line) is kept in `problems`.

const std = @import("std");
const toml = @import("toml");
const common = @import("common");
const figure = @import("figure.zig");

const Allocator = std.mem.Allocator;

pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    lessons: []figure.Lesson = &.{},
    problems: []const []const u8 = &.{},
    /// The file of each lesson, and whether the lesson is read in full. Lessons from the index cache
    /// have only their id, course, book and title until `ensureFull` reads the file.
    paths: []const []const u8 = &.{},
    full: []bool = &.{},

    pub fn deinit(self: *Loaded) void {
        self.arena.deinit();
    }
};

fn problem(arena: Allocator, list: *std.ArrayList([]const u8), comptime fmt: []const u8, args: anytype) void {
    const text = std.fmt.allocPrint(arena, fmt, args) catch return;
    list.append(arena, text) catch {};
}

fn strings(arena: Allocator, array: *toml.Array, source: []const u8, what: []const u8, list: *std.ArrayList([]const u8)) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (array.items.items) |item| switch (item) {
        .string => |s| out.append(arena, arena.dupe(u8, s) catch continue) catch {},
        else => problem(arena, list, "{s}: {s} must be a list of strings", .{ source, what }),
    };
    return out.items;
}

/// Reads one lesson from TOML text. `source` names the file in problems. Null when it cannot be used.
pub fn parseLesson(arena: Allocator, text: []const u8, source: []const u8, problems: *std.ArrayList([]const u8)) ?struct { lesson: figure.Lesson, order: i64 } {
    var diag: toml.Diagnostic = .{};
    var doc = toml.Document.parse(std.heap.page_allocator, text, .{}, &diag) catch |e| {
        problem(arena, problems, "{s}: {f}: {s}", .{ source, diag, @errorName(e) });
        return null;
    };
    defer doc.deinit();
    const root = doc.root;
    const id = root.getString("id") orelse {
        problem(arena, problems, "{s}: no id", .{source});
        return null;
    };
    const title = root.getString("title") orelse "";
    const statement = root.getString("statement") orelse "";
    const book: u8 = @intCast(std.math.clamp(root.getInt("book") orelse 0, 0, 255));
    const order = root.getInt("order") orelse 0;
    const proof = root.getString("proof") orelse "";
    var steps: std.ArrayList(figure.Step) = .empty;
    if (root.getArray("step")) |array| {
        for (array.items.items, 0..) |item, n| {
            const table = switch (item) {
                .table => |t| t,
                else => continue,
            };
            const step_text = table.getString("text") orelse {
                problem(arena, problems, "{s}: step {d} has no text", .{ source, n + 1 });
                continue;
            };
            var ops: std.ArrayList(figure.Op) = .empty;
            if (table.getArray("draw")) |draw| {
                const lines = strings(arena, draw, source, "draw", problems);
                for (lines) |line| {
                    const op = figure.parseOp(arena, line) catch |e| {
                        problem(arena, problems, "{s}: step {d}: \"{s}\": {s}", .{ source, n + 1, line, @errorName(e) });
                        continue;
                    };
                    ops.append(arena, op) catch {};
                }
            }
            var calc: []const []const u8 = &.{};
            if (table.getArray("calc")) |c| calc = strings(arena, c, source, "calc", problems);
            var work: []const []const u8 = &.{};
            if (table.getArray("work")) |w| work = strings(arena, w, source, "work", problems);
            var graph: []const []const u8 = &.{};
            if (table.getArray("graph")) |g| graph = strings(arena, g, source, "graph", problems);
            steps.append(arena, .{
                .text = arena.dupe(u8, step_text) catch continue,
                .ops = ops.items,
                .calc = calc,
                .work = work,
                .graph = graph,
                .mode = arena.dupe(u8, table.getString("mode") orelse "") catch "",
                .base = @intCast(std.math.clamp(table.getInt("base") orelse 0, 0, 255)),
                .bits = @intCast(std.math.clamp(table.getInt("bits") orelse 0, 0, 255)),
            }) catch {};
        }
    }
    var exercises: std.ArrayList(figure.Exercise) = .empty;
    if (root.getArray("exercise")) |array| {
        for (array.items.items, 0..) |item, n| {
            const table = switch (item) {
                .table => |t| t,
                else => continue,
            };
            const prompt = table.getString("prompt");
            const answer = table.getString("answer");
            if (prompt == null or answer == null) {
                problem(arena, problems, "{s}: exercise {d} needs a prompt and an answer", .{ source, n + 1 });
                continue;
            }
            exercises.append(arena, .{
                .prompt = arena.dupe(u8, prompt.?) catch continue,
                .answer = arena.dupe(u8, answer.?) catch continue,
                .hint = arena.dupe(u8, table.getString("hint") orelse "") catch continue,
            }) catch {};
        }
    }
    if (steps.items.len == 0) {
        problem(arena, problems, "{s}: no steps", .{source});
        return null;
    }
    return .{
        .lesson = .{
            .id = arena.dupe(u8, id) catch return null,
            .book = book,
            .course = arena.dupe(u8, root.getString("course") orelse "Euclid") catch return null,
            .title = arena.dupe(u8, title) catch return null,
            .statement = arena.dupe(u8, statement) catch return null,
            .steps = steps.items,
            .exercises = exercises.items,
            .proof = arena.dupe(u8, proof) catch return null,
        },
        .order = order,
    };
}

const Entry = struct { lesson: figure.Lesson, order: i64, path: []const u8 = "" };

/// The order subjects are taught in; others follow alphabetically.
pub fn courseRank(name: []const u8) usize {
    const order = [_][]const u8{ "Arithmetic", "Euclid", "Algebra", "Trigonometry", "Calculus", "Linear Algebra", "Computing", "Computer Science", "Networking" };
    for (order, 0..) |n, i| if (std.mem.eql(u8, n, name)) return i;
    return order.len;
}

fn lessThan(_: void, a: Entry, b: Entry) bool {
    const ra = courseRank(a.lesson.course);
    const rb = courseRank(b.lesson.course);
    if (ra != rb) return ra < rb;
    if (ra == 9 and !std.mem.eql(u8, a.lesson.course, b.lesson.course)) return std.mem.lessThan(u8, a.lesson.course, b.lesson.course);
    if (a.lesson.book != b.lesson.book) return a.lesson.book < b.lesson.book;
    if (a.order != b.order) return a.order < b.order;
    return std.mem.lessThan(u8, a.lesson.id, b.lesson.id);
}

/// Loads every `*.toml` in the folders (and one level of sub-folders), sorted by book and order.
pub fn load(gpa: Allocator, io: std.Io, dirs: []const []const u8) Loaded {
    var out: Loaded = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    const arena = out.arena.allocator();
    var entries: std.ArrayList(Entry) = .empty;
    var problems: std.ArrayList([]const u8) = .empty;
    for (dirs) |dir| loadDir(arena, io, dir, 1, &entries, &problems);
    std.mem.sort(Entry, entries.items, {}, lessThan);
    const lessons = arena.alloc(figure.Lesson, entries.items.len) catch return out;
    const paths = arena.alloc([]const u8, entries.items.len) catch return out;
    const full = arena.alloc(bool, entries.items.len) catch return out;
    for (entries.items, 0..) |e, i| {
        lessons[i] = e.lesson;
        paths[i] = e.path;
        full[i] = true;
    }
    out.lessons = lessons;
    out.paths = paths;
    out.full = full;
    out.problems = problems.items;
    return out;
}

fn loadDir(arena: Allocator, io: std.Io, path: []const u8, depth: u8, entries: *std.ArrayList(Entry), problems: *std.ArrayList([]const u8)) void {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |item| {
        const full = std.fmt.allocPrint(arena, "{s}/{s}", .{ path, item.name }) catch continue;
        switch (item.kind) {
            .directory => if (depth > 0) loadDir(arena, io, full, depth - 1, entries, problems),
            .file => {
                if (!std.mem.endsWith(u8, item.name, ".toml")) continue;
                const text = dir.readFileAlloc(io, item.name, arena, .limited(1 << 20)) catch |e| {
                    problem(arena, problems, "{s}: {s}", .{ full, @errorName(e) });
                    continue;
                };
                if (parseLesson(arena, text, full, problems)) |r| entries.append(arena, .{ .lesson = r.lesson, .order = r.order, .path = full }) catch {};
            },
            else => {},
        }
    }
}

// ---- the index cache ----------------------------------------------------------------------------
//
// Reading every lesson file at each start is slow. The first time the lessons are read, a small index
// (file, id, course, book, title: one line each) is written to the cache folder; after that the index is
// read instead, and a lesson's file is read only when the lesson is opened. The index is tied to the
// program version, and "Refresh lessons" in the Learn view makes a new one (for lessons you added).

const index_magic = "dkde-learn-index 2";

fn clean(arena: Allocator, text: []const u8) []const u8 {
    const out = arena.dupe(u8, text) catch return text;
    for (out) |*c| if (c.* == '\t' or c.* == '\n' or c.* == '\r') {
        c.* = ' ';
    };
    return out;
}

/// The lessons of a written index, or null when it is missing, from another version, or unreadable.
pub fn loadIndex(gpa: Allocator, io: std.Io, cache_path: []const u8, version: []const u8) ?Loaded {
    var out: Loaded = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    const arena = out.arena.allocator();
    const text = std.Io.Dir.cwd().readFileAlloc(io, cache_path, arena, .limited(8 << 20)) catch {
        out.arena.deinit();
        return null;
    };
    var lines = std.mem.splitScalar(u8, text, '\n');
    const header = lines.next() orelse {
        out.arena.deinit();
        return null;
    };
    var want_buf: [128]u8 = undefined;
    const want = std.fmt.bufPrint(&want_buf, "{s} {s}", .{ index_magic, version }) catch {
        out.arena.deinit();
        return null;
    };
    if (!std.mem.eql(u8, header, want)) {
        out.arena.deinit();
        return null;
    }
    var lessons: std.ArrayList(figure.Lesson) = .empty;
    var paths: std.ArrayList([]const u8) = .empty;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var f = std.mem.splitScalar(u8, line, '\t');
        const path = f.next() orelse continue;
        const id = f.next() orelse continue;
        const course = f.next() orelse continue;
        const book = std.fmt.parseInt(u8, f.next() orelse continue, 10) catch continue;
        const title = f.next() orelse continue;
        const statement = f.next() orelse "";
        lessons.append(arena, .{ .id = id, .course = course, .book = book, .title = title, .statement = statement, .steps = &.{}, .exercises = &.{}, .proof = "" }) catch {
            out.arena.deinit();
            return null;
        };
        paths.append(arena, path) catch {
            out.arena.deinit();
            return null;
        };
    }
    if (lessons.items.len == 0) {
        out.arena.deinit();
        return null;
    }
    const full = arena.alloc(bool, lessons.items.len) catch {
        out.arena.deinit();
        return null;
    };
    @memset(full, false);
    out.lessons = lessons.items;
    out.paths = paths.items;
    out.full = full;
    return out;
}

/// Writes the index of loaded lessons (in their order) to `cache_path`.
pub fn writeIndex(gpa: Allocator, io: std.Io, cache_path: []const u8, version: []const u8, loaded: *const Loaded) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(u8) = .empty;
    out.print(arena, "{s} {s}\n", .{ index_magic, version }) catch return;
    for (loaded.lessons, 0..) |l, i| {
        if (i >= loaded.paths.len) break;
        out.print(arena, "{s}\t{s}\t{s}\t{d}\t{s}\t{s}\n", .{ clean(arena, loaded.paths[i]), clean(arena, l.id), clean(arena, l.course), l.book, clean(arena, l.title), clean(arena, l.statement) }) catch return;
    }
    _ = io;
    if (std.fs.path.dirname(cache_path)) |dir| common.fsio.makePath(dir) catch {};
    common.fsio.writeFileAtomic(cache_path, out.items) catch {};
}

/// Reads lesson `i` in full when it was loaded from the index. The lesson keeps its stub when the file is gone.
pub fn ensureFull(loaded: *Loaded, io: std.Io, i: usize) void {
    if (i >= loaded.lessons.len or i >= loaded.full.len or loaded.full[i]) return;
    loaded.full[i] = true;
    const arena = loaded.arena.allocator();
    const text = std.Io.Dir.cwd().readFileAlloc(io, loaded.paths[i], arena, .limited(1 << 20)) catch return;
    var problems: std.ArrayList([]const u8) = .empty;
    if (parseLesson(arena, text, loaded.paths[i], &problems)) |r| loaded.lessons[i] = r.lesson;
}

test "an index is written and read back, and a lesson is read in full on demand" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = common.fsio.io();
    const base = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    const lesson_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/a.toml", .{base});
    defer std.testing.allocator.free(lesson_path);
    try common.fsio.writeFileAtomic(lesson_path, "id = \"T.1\"\ncourse = \"Test\"\nbook = 2\ntitle = \"A test\"\nstatement = \"Do it.\"\n[[step]]\ntext = \"Start.\"\n");
    var first = load(std.testing.allocator, io, &.{base});
    defer first.deinit();
    try std.testing.expectEqual(@as(usize, 1), first.lessons.len);
    const index_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/index", .{base});
    defer std.testing.allocator.free(index_path);
    writeIndex(std.testing.allocator, io, index_path, "1.0", &first);
    try std.testing.expect(loadIndex(std.testing.allocator, io, index_path, "2.0") == null);
    var second = loadIndex(std.testing.allocator, io, index_path, "1.0").?;
    defer second.deinit();
    try std.testing.expectEqualStrings("A test", second.lessons[0].title);
    try std.testing.expectEqual(@as(usize, 0), second.lessons[0].steps.len);
    ensureFull(&second, io, 0);
    try std.testing.expectEqual(@as(usize, 1), second.lessons[0].steps.len);
}

test "a lesson file is read, and its drawing lines too" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var problems: std.ArrayList([]const u8) = .empty;
    const text =
        \\id = "T.1"
        \\book = 1
        \\title = "A test"
        \\statement = "Do it."
        \\[[step]]
        \\text = "Start."
        \\draw = ["point A 0 0", "point B 3 0", "segment A B red"]
        \\calc = ["3/4 + 1/6"]
        \\[[step]]
        \\text = "Bad line."
        \\draw = ["nonsense A"]
    ;
    const r = parseLesson(arena.allocator(), text, "t.toml", &problems).?;
    try std.testing.expectEqualStrings("T.1", r.lesson.id);
    try std.testing.expectEqual(@as(usize, 2), r.lesson.steps.len);
    try std.testing.expectEqual(@as(usize, 3), r.lesson.steps[0].ops.len);
    try std.testing.expectEqualStrings("3/4 + 1/6", r.lesson.steps[0].calc[0]);
    try std.testing.expectEqual(@as(usize, 1), problems.items.len);
}

test "a file with no steps is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var problems: std.ArrayList([]const u8) = .empty;
    try std.testing.expect(parseLesson(arena.allocator(), "id = \"X\"\n", "x.toml", &problems) == null);
    try std.testing.expect(problems.items.len == 1);
}
