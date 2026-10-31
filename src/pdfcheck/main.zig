//! dkde-pdfcheck: draws every page of many PDF files with the dkde renderer
//! and reports what it could not draw, so a large collection can be used to
//! find the gaps. It needs no display.
//!
//!     dkde-pdfcheck [options] PATH...        files, or folders searched for *.pdf
//!
//!     --pages N        draw at most the first N pages of each file (default 3; 0 = all)
//!     --scale S        points to pixels (default 1.0 = 72 dpi; pages are capped at 3000 px)
//!     --out DIR        also save each drawn page as DIR/<file name>-pN.png
//!     --report FILE    one JSON line per file (default: standard output)
//!     --trail FILE     progress trail; lets a re-run skip files and name the one that crashed
//!     --resume         with --trail: skip files already begun in an earlier run
//!     --shard I/N      only every Nth file, starting at I (0-based), to run N copies side by side
//!     --max-mb N       skip files bigger than N MiB (default 0 = no limit)
//!     -v               log every event as it happens (also DKDE_PDF_LOG=1)
//!
//! A crash inside the renderer kills the process, so each file is written to
//! the trail *before* it is drawn: after a crash the last "BEGIN" without an
//! "END" is the culprit, and `--resume` carries on past it.

const std = @import("std");
const cairo = @import("cairo1");
const glib = @import("glib2");
const zpdf = @import("zpdf");
const render = @import("pdfrender");

const Diag = render.Diag;

/// Events are logged at debug level, so they show only with -v.
pub const std_options: std.Options = .{ .log_level = .warn };

extern fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern fn close(fd: c_int) c_int;

const O_WRONLY: c_int = 1;
const O_CREAT: c_int = 0o100;
const O_APPEND: c_int = 0o2000;
const O_TRUNC: c_int = 0o1000;

const Options = struct {
    pages: usize = 3,
    scale: f64 = 1.0,
    out_dir: ?[:0]const u8 = null,
    report: ?[:0]const u8 = null,
    trail: ?[:0]const u8 = null,
    resuming: bool = false,
    shard: usize = 0,
    shards: usize = 1,
    max_bytes: u64 = 0,
    verbose: bool = false,
};

const Run = struct {
    allocator: std.mem.Allocator,
    opt: Options,
    report_fd: c_int = 1,
    trail_fd: c_int = -1,
    /// Paths already begun in an earlier run (with --resume).
    done: std.StringHashMapUnmanaged(void) = .empty,
    seen: usize = 0,
    files: usize = 0,
    skipped: usize = 0,
    failed: usize = 0,
    with_notes: usize = 0,
    pages: usize = 0,
    micros: i64 = 0,
    /// Event kind -> total events, and the number of files that had any.
    totals: Diag,
    files_with: std.StringHashMapUnmanaged(u32) = .empty,
    errors: std.StringHashMapUnmanaged(u32) = .empty,
};

fn writeAll(fd: c_int, bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = write(fd, rest.ptr, rest.len);
        if (n <= 0) return;
        rest = rest[@intCast(n)..];
    }
}

fn say(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    writeAll(2, std.fmt.bufPrint(&buf, fmt, args) catch return);
}

fn jsonString(list: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    try list.append(a, '"');
    for (s) |ch| switch (ch) {
        '"' => try list.appendSlice(a, "\\\""),
        '\\' => try list.appendSlice(a, "\\\\"),
        0...0x1f => try list.print(a, "\\u{x:0>4}", .{ch}),
        else => try list.append(a, ch),
    };
    try list.append(a, '"');
}

fn trail(run: *Run, tag: []const u8, path: []const u8) void {
    if (run.trail_fd < 0) return;
    var buf: [4200]u8 = undefined;
    writeAll(run.trail_fd, std.fmt.bufPrint(&buf, "{s}\t{s}\n", .{ tag, path }) catch return);
}

fn baseName(path: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[i + 1 ..] else path;
}

fn bump(a: std.mem.Allocator, map: *std.StringHashMapUnmanaged(u32), key: []const u8) void {
    const gop = map.getOrPut(a, key) catch return;
    if (!gop.found_existing) {
        gop.key_ptr.* = a.dupe(u8, key) catch {
            _ = map.remove(key);
            return;
        };
        gop.value_ptr.* = 0;
    }
    gop.value_ptr.* += 1;
}

fn checkFile(run: *Run, path: [:0]const u8) void {
    const a = run.allocator;
    run.files += 1;
    trail(run, "BEGIN", path);
    const t0 = glib.getMonotonicTime();

    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(a);
    var file_diag = Diag.init(a);
    file_diag.verbose = run.opt.verbose or file_diag.verbose;
    defer file_diag.deinit();
    var err_name: ?[]const u8 = null;
    var page_count: usize = 0;
    var drawn: usize = 0;
    var size: u64 = 0;

    blk: {
        const doc = zpdf.Document.open(a, path) catch |e| {
            err_name = @errorName(e);
            break :blk;
        };
        defer doc.close();
        size = doc.data.len;
        page_count = doc.pageCount();
        if (page_count == 0) {
            err_name = "NoPages";
            break :blk;
        }
        if (doc.isEncrypted()) {
            file_diag.note("encrypted", path);
            break :blk;
        }
        const limit = if (run.opt.pages == 0) page_count else @min(run.opt.pages, page_count);
        for (0..limit) |i| {
            const ps = render.pageSize(doc, i) orelse continue;
            if (!(ps.w > 0 and ps.h > 0) or ps.w > 100000 or ps.h > 100000) {
                file_diag.note("page-size-bad", "");
                continue;
            }
            // Keep every page within a sane number of pixels.
            const s = @min(run.opt.scale, 3000.0 / @max(ps.w, ps.h));
            const w: c_int = @intFromFloat(@ceil(ps.w * s));
            const h: c_int = @intFromFloat(@ceil(ps.h * s));
            const surface = cairo.Surface.imageCreate(.argb32, w, h);
            defer surface.destroy();
            const cr = cairo.Context.create(surface);
            defer cr.destroy();
            cr.setSourceRgb(1, 1, 1);
            cr.paint();
            render.renderPage(a, doc, i, cr, s, &file_diag) catch |e| {
                err_name = @errorName(e);
                break;
            };
            drawn += 1;
            if (run.opt.out_dir) |dir| {
                surface.flush();
                var nb: [1024]u8 = undefined;
                if (std.fmt.bufPrintSentinel(&nb, "{s}/{s}-p{d}.png", .{ dir, baseName(path), i + 1 }, 0)) |png| _ = surface.writeToPng(png) else |_| {}
            }
        }
    }

    const ms = @divTrunc(glib.getMonotonicTime() - t0, 1000);
    run.pages += drawn;
    run.micros += glib.getMonotonicTime() - t0;
    if (err_name) |e| {
        run.failed += 1;
        bump(a, &run.errors, e);
    }
    if (file_diag.total() > 0) {
        run.with_notes += 1;
        var it = file_diag.counts.iterator();
        while (it.next()) |e| bump(a, &run.files_with, e.key_ptr.*);
    }
    file_diag.mergeInto(&run.totals);

    // The report line.
    line.appendSlice(a, "{\"path\":") catch return;
    jsonString(&line, a, path) catch return;
    line.print(a, ",\"bytes\":{d},\"pages\":{d},\"drawn\":{d},\"ms\":{d},\"error\":", .{ size, page_count, drawn, ms }) catch return;
    if (err_name) |e| jsonString(&line, a, e) catch return else line.appendSlice(a, "null") catch return;
    line.appendSlice(a, ",\"notes\":{") catch return;
    var first = true;
    var it = file_diag.counts.iterator();
    while (it.next()) |e| {
        if (!first) line.append(a, ',') catch return;
        first = false;
        jsonString(&line, a, e.key_ptr.*) catch return;
        line.print(a, ":{d}", .{e.value_ptr.*}) catch return;
    }
    line.appendSlice(a, "}}\n") catch return;
    writeAll(run.report_fd, line.items);
    trail(run, "END", path);
}

fn isPdf(name: []const u8) bool {
    return name.len > 4 and std.ascii.eqlIgnoreCase(name[name.len - 4 ..], ".pdf");
}

fn considerFile(run: *Run, path: [:0]const u8) void {
    const index = run.seen;
    run.seen += 1;
    if (index % run.opt.shards != run.opt.shard) return;
    if (run.opt.resuming and run.done.contains(path)) {
        run.skipped += 1;
        return;
    }
    if (run.opt.max_bytes > 0) {
        // Size from the file system without reading it.
        const f = open(path, 0);
        if (f >= 0) {
            defer _ = close(f);
            const end = lseek(f, 0, 2);
            if (end > 0 and @as(u64, @intCast(end)) > run.opt.max_bytes) {
                run.skipped += 1;
                return;
            }
        }
    }
    checkFile(run, path);
}

extern fn lseek(fd: c_int, offset: i64, whence: c_int) i64;

fn walk(run: *Run, path: [:0]const u8, depth: u32) void {
    const a = run.allocator;
    if (glib.fileTest(path, .{ .is_dir = true }) == 0) {
        if (glib.fileTest(path, .{ .is_regular = true }) != 0) considerFile(run, path);
        return;
    }
    if (depth > 64) return;
    const dir = glib.Dir.open(path, 0, null) orelse return;
    defer dir.close();
    // Sorted, so a run is repeatable and --shard splits the same way every time.
    var names: std.ArrayList([:0]u8) = .empty;
    defer {
        for (names.items) |n| a.free(n);
        names.deinit(a);
    }
    while (@as(?[*:0]const u8, @ptrCast(dir.readName()))) |n| {
        const name = std.mem.span(n);
        if (name.len == 0 or name[0] == '.') continue;
        const full = std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ std.mem.trimEnd(u8, path, "/"), name }, 0) catch continue;
        names.append(a, full) catch a.free(full);
    }
    std.mem.sort([:0]u8, names.items, {}, struct {
        fn less(_: void, x: [:0]u8, y: [:0]u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    for (names.items) |full| {
        if (glib.fileTest(full, .{ .is_dir = true }) != 0) {
            walk(run, full, depth + 1);
        } else if (isPdf(full)) considerFile(run, full);
    }
}

fn loadTrail(run: *Run, path: [:0]const u8) void {
    const a = run.allocator;
    var contents: [*]u8 = undefined;
    var len: usize = 0;
    if (glib.fileGetContents(path, &contents, &len, null) == 0) return;
    defer glib.free(contents);
    const text = contents[0..len];
    var begun: std.StringHashMapUnmanaged(void) = .empty;
    defer begun.deinit(a);
    var ended: std.StringHashMapUnmanaged(void) = .empty;
    defer ended.deinit(a);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        const tab = std.mem.indexOfScalar(u8, l, '\t') orelse continue;
        const p = a.dupe(u8, l[tab + 1 ..]) catch continue;
        if (std.mem.eql(u8, l[0..tab], "BEGIN")) {
            begun.put(a, p, {}) catch {};
            run.done.put(a, p, {}) catch {};
        } else {
            ended.put(a, p, {}) catch {};
        }
    }
    var it = begun.keyIterator();
    while (it.next()) |k| if (!ended.contains(k.*)) say("previous run did not finish: {s}\n", .{k.*});
}

pub fn main(init: std.process.Init.Minimal) !void {
    const a = std.heap.c_allocator;
    var opt: Options = .{};
    var paths: std.ArrayList([:0]const u8) = .empty;
    defer paths.deinit(a);

    const argv = init.args.vector;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg: [:0]const u8 = std.mem.span(argv[i]);
        const eql = std.mem.eql;
        const next: ?[:0]const u8 = if (i + 1 < argv.len) std.mem.span(argv[i + 1]) else null;
        if (eql(u8, arg, "--pages")) {
            opt.pages = std.fmt.parseInt(usize, next orelse return usage(), 10) catch return usage();
            i += 1;
        } else if (eql(u8, arg, "--scale")) {
            opt.scale = std.fmt.parseFloat(f64, next orelse return usage()) catch return usage();
            i += 1;
        } else if (eql(u8, arg, "--out")) {
            opt.out_dir = next orelse return usage();
            i += 1;
        } else if (eql(u8, arg, "--report")) {
            opt.report = next orelse return usage();
            i += 1;
        } else if (eql(u8, arg, "--trail")) {
            opt.trail = next orelse return usage();
            i += 1;
        } else if (eql(u8, arg, "--resume")) {
            opt.resuming = true;
        } else if (eql(u8, arg, "--shard")) {
            const v = next orelse return usage();
            const slash = std.mem.indexOfScalar(u8, v, '/') orelse return usage();
            opt.shard = std.fmt.parseInt(usize, v[0..slash], 10) catch return usage();
            opt.shards = std.fmt.parseInt(usize, v[slash + 1 ..], 10) catch return usage();
            if (opt.shards == 0 or opt.shard >= opt.shards) return usage();
            i += 1;
        } else if (eql(u8, arg, "--max-mb")) {
            opt.max_bytes = (std.fmt.parseInt(u64, next orelse return usage(), 10) catch return usage()) << 20;
            i += 1;
        } else if (eql(u8, arg, "-v")) {
            opt.verbose = true;
        } else if (eql(u8, arg, "-h") or eql(u8, arg, "--help")) {
            return usage();
        } else if (arg.len > 0 and arg[0] == '-') {
            say("unknown option {s}\n", .{arg});
            return usage();
        } else paths.append(a, arg) catch return;
    }
    if (paths.items.len == 0) return usage();

    var run: Run = .{ .allocator = a, .opt = opt, .totals = Diag.init(a) };
    run.totals.verbose = false;
    if (opt.out_dir) |d| _ = glib.mkdirWithParents(d, 0o755);
    if (opt.report) |r| {
        run.report_fd = open(r, O_WRONLY | O_CREAT | O_APPEND, @as(c_uint, 0o644));
        if (run.report_fd < 0) {
            say("cannot write {s}\n", .{r});
            return;
        }
    }
    if (opt.trail) |t| {
        if (opt.resuming) loadTrail(&run, t);
        run.trail_fd = open(t, O_WRONLY | O_CREAT | O_APPEND, @as(c_uint, 0o644));
    }

    for (paths.items) |p| walk(&run, p, 0);

    // Summary.
    say("\n{d} files ({d} skipped), {d} pages drawn, {d} failed, {d} with unsupported features, {d:.1} s\n", .{ run.files, run.skipped, run.pages, run.failed, run.with_notes, @as(f64, @floatFromInt(run.micros)) / 1e6 });
    const Row = struct { key: []const u8, events: u32, files: u32 };
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(a);
    var it = run.totals.counts.iterator();
    while (it.next()) |e| rows.append(a, .{ .key = e.key_ptr.*, .events = e.value_ptr.*, .files = run.files_with.get(e.key_ptr.*) orelse 0 }) catch {};
    std.mem.sort(Row, rows.items, {}, struct {
        fn less(_: void, x: Row, y: Row) bool {
            return x.files > y.files;
        }
    }.less);
    if (rows.items.len > 0) say("\nwhat was not drawn, by number of files:\n  {s:<34} {s:>8} {s:>9}\n", .{ "event", "files", "events" });
    for (rows.items) |r| say("  {s:<34} {d:>8} {d:>9}\n", .{ r.key, r.files, r.events });
    var eit = run.errors.iterator();
    var any_err = false;
    while (eit.next()) |e| {
        if (!any_err) say("\nerrors:\n", .{});
        any_err = true;
        say("  {s:<34} {d:>8}\n", .{ e.key_ptr.*, e.value_ptr.* });
    }
}

fn usage() void {
    say(
        \\usage: dkde-pdfcheck [options] PATH...
        \\  --pages N     pages per file to draw (default 3, 0 = all)
        \\  --scale S     points to pixels (default 1.0)
        \\  --out DIR     save each drawn page as a PNG in DIR
        \\  --report FILE one JSON line per file (default: standard output)
        \\  --trail FILE  progress trail, so a crash names the file that caused it
        \\  --resume      skip files already in the trail
        \\  --shard I/N   run only every Nth file starting at I
        \\  --max-mb N    skip files bigger than N MiB
        \\  -v            log each event (or set DKDE_PDF_LOG=1)
        \\
    , .{});
}
