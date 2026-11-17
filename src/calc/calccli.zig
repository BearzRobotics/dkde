//! dkde-calc on the command line: the same engine and the same figure drawing as the window, with no
//! window. It is how lessons are checked and how their figures are looked at.
//!
//!   dkde-calc eval [-v] [--decimals N] [--rad|--grad] EXPR...      work entries out (one session)
//!   dkde-calc steps EXPR                                          the written-out solution
//!   dkde-calc render LESSON.toml [--step N | --each] [--size WxH] -o OUT.png|OUT.svg
//!   dkde-calc check-lessons [DIR...]                              load every lesson, run every step
//!
//! `check-lessons` exits with 1 when a lesson file does not read, a step draws from a point that does not
//! exist yet, a construction has no crossing, or a calculator line fails.

const std = @import("std");
const cairo = @import("cairo1");
const common = @import("common");

const num = @import("num.zig");
const eval = @import("eval.zig");
const rich = @import("rich.zig");
const steps_mod = @import("steps.zig");
const figure = @import("figure.zig");
const lessonfile = @import("lessonfile.zig");
const scene_mod = @import("scene.zig");
const learn = @import("learn.zig");

extern fn cairo_svg_surface_create(filename: [*:0]const u8, width: f64, height: f64) ?*cairo.Surface;

const subcommands = [_][]const u8{ "eval", "steps", "render", "check-lessons" };

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.c.write(1, text.ptr, text.len);
}

fn err(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.c.write(2, text.ptr, text.len);
}

/// If the first operand names a subcommand, runs it and returns the exit status; null for the window.
pub fn dispatch(args: std.process.Args) ?u8 {
    const argv = args.vector;
    if (argv.len < 2) return null;
    const first = std.mem.span(argv[1]);
    for (subcommands) |name| if (std.mem.eql(u8, first, name)) {
        var list: std.ArrayList([]const u8) = .empty;
        defer list.deinit(std.heap.c_allocator);
        for (argv[2..]) |a| list.append(std.heap.c_allocator, std.mem.span(a)) catch return 1;
        return run(first, list.items);
    };
    return null;
}

fn run(name: []const u8, args: []const []const u8) u8 {
    if (std.mem.eql(u8, name, "eval")) return cmdEval(args);
    if (std.mem.eql(u8, name, "steps")) return cmdSteps(args);
    if (std.mem.eql(u8, name, "render")) return cmdRender(args);
    return cmdCheck(args);
}

// ---- eval and steps ------------------------------------------------------------------------------

fn show(a: std.mem.Allocator, o: eval.Outcome, decimals: u8) ![]const u8 {
    return switch (o) {
        .value => |v| num.format(a, v, .{ .decimals = decimals }),
        .assigned => |s| num.format(a, s.value, .{ .decimals = decimals }),
        .defined => |d| d,
        .truth => |t| if (t) "true" else "false",
        .uncertain => |u| u.text,
        .symbolic => |sy| try std.fmt.allocPrint(a, "{s} ~ {s}", .{ sy.text, try num.format(a, sy.value, .{ .decimals = decimals }) }),
        .simplified => |x| x,
        .rich => |v| try rich.format(a, v, .{ .decimals = decimals }),
        .system => |sy| try std.fmt.allocPrint(a, "{d} unknowns", .{sy.names.len}),
        .rich_assigned => |s| try rich.format(a, s.value, .{ .decimals = decimals }),
        .complex => |cx| try std.fmt.allocPrint(a, "{d} complex", .{cx.re.len}),
        .solved => |s| blk: {
            var parts: std.ArrayList(u8) = .empty;
            for (s.roots, 0..) |r, i| {
                if (i > 0) try parts.appendSlice(a, "; ");
                try parts.appendSlice(a, try num.format(a, r, .{ .decimals = decimals }));
            }
            break :blk parts.items;
        },
    };
}

fn cmdEval(args: []const []const u8) u8 {
    var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mode: eval.Mode = .{};
    var decimals: u8 = 10;
    var verbose = false;
    var session: eval.Session = .{ .gpa = std.heap.c_allocator };
    defer session.deinit();
    var status: u8 = 0;
    var i: usize = 0;
    var any = false;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-v")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--rad")) {
            mode.angle = .radians;
        } else if (std.mem.eql(u8, arg, "--grad")) {
            mode.angle = .gradians;
        } else if (std.mem.eql(u8, arg, "--decimals") and i + 1 < args.len) {
            i += 1;
            decimals = std.fmt.parseInt(u8, args[i], 10) catch 10;
        } else {
            any = true;
            var p: eval.Problem = .{};
            if (eval.run(a, &session, arg, mode, &p)) |o| {
                const text = show(a, o, decimals) catch "?";
                if (verbose) out("{s}\t= {s}\n", .{ arg, text }) else out("{s}\n", .{text});
            } else |e| {
                err("{s}: {s}\n", .{ arg, @errorName(e) });
                status = 1;
            }
        }
    }
    if (!any) {
        err("usage: dkde-calc eval [-v] [--decimals N] [--rad|--grad] EXPR...\n", .{});
        return 2;
    }
    return status;
}

fn cmdSteps(args: []const []const u8) u8 {
    if (args.len == 0) {
        err("usage: dkde-calc steps EXPR\n", .{});
        return 2;
    }
    var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var session: eval.Session = .{ .gpa = std.heap.c_allocator };
    defer session.deinit();
    const result = steps_mod.explain(.{ .a = a, .session = &session, .mode = .{} }, args[0]) catch |e| {
        err("{s}\n", .{@errorName(e)});
        return 1;
    };
    const list = result orelse {
        err("no written-out steps for that entry\n", .{});
        return 1;
    };
    for (list, 0..) |s, n| out("{d}. {s}\n     {s}\n", .{ n + 1, s.note, s.math });
    return 0;
}

// ---- render ----------------------------------------------------------------------------------------

fn readFile(gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(common.fsio.io(), path, gpa, .limited(1 << 20)) catch null;
}

fn parseSize(text: []const u8) ?[2]c_int {
    const x = std.mem.indexOfScalar(u8, text, 'x') orelse return null;
    const w = std.fmt.parseInt(c_int, text[0..x], 10) catch return null;
    const h = std.fmt.parseInt(c_int, text[x + 1 ..], 10) catch return null;
    return .{ w, h };
}

fn cmdRender(args: []const []const u8) u8 {
    var file: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var step: ?usize = null;
    var each = false;
    var size: [2]c_int = .{ 640, 480 };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-o") and i + 1 < args.len) {
            i += 1;
            output = args[i];
        } else if (std.mem.eql(u8, arg, "--step") and i + 1 < args.len) {
            i += 1;
            step = std.fmt.parseInt(usize, args[i], 10) catch null;
        } else if (std.mem.eql(u8, arg, "--each")) {
            each = true;
        } else if (std.mem.eql(u8, arg, "--size") and i + 1 < args.len) {
            i += 1;
            size = parseSize(args[i]) orelse size;
        } else file = arg;
    }
    const path = file orelse {
        err("usage: dkde-calc render LESSON.toml [--step N | --each] [--size WxH] -o OUT.png|OUT.svg\n", .{});
        return 2;
    };
    const dest = output orelse {
        err("render: -o OUT.png (or .svg) is needed\n", .{});
        return 2;
    };
    var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = readFile(a, path) orelse {
        err("render: cannot read {s}\n", .{path});
        return 1;
    };
    var problems: std.ArrayList([]const u8) = .empty;
    const parsed = lessonfile.parseLesson(a, text, path, &problems) orelse {
        for (problems.items) |p| err("{s}\n", .{p});
        return 1;
    };
    for (problems.items) |p| err("{s}\n", .{p});
    const lesson = parsed.lesson;
    if (each) {
        var n: usize = 1;
        while (n <= lesson.steps.len) : (n += 1) {
            var name_buf: [512]u8 = undefined;
            const dot = std.mem.lastIndexOfScalar(u8, dest, '.') orelse dest.len;
            const name = std.fmt.bufPrint(&name_buf, "{s}-{d}{s}", .{ dest[0..dot], n, dest[dot..] }) catch continue;
            if (!renderStep(a, lesson, n, name, size)) return 1;
        }
        return 0;
    }
    const upto = @min(step orelse lesson.steps.len, lesson.steps.len);
    return if (renderStep(a, lesson, upto, dest, size)) 0 else 1;
}

fn renderStep(a: std.mem.Allocator, lesson: figure.Lesson, upto: usize, dest: []const u8, size: [2]c_int) bool {
    var scene = scene_mod.Scene.init(std.heap.c_allocator);
    defer scene.deinit();
    scene.numbers = false;
    scene.width = @floatFromInt(size[0]);
    scene.height = @floatFromInt(size[1]);
    for (lesson.steps[0..upto]) |step| scene.runOps(step.ops);
    scene.fitToFigure();
    const dest_z = a.dupeSentinel(u8, dest, 0) catch return false;
    const svg = std.mem.endsWith(u8, dest, ".svg");
    const surface = if (svg) (cairo_svg_surface_create(dest_z.ptr, @floatFromInt(size[0]), @floatFromInt(size[1])) orelse return false) else cairo.Surface.imageCreate(.argb32, size[0], size[1]);
    const cr = cairo.Context.create(surface);
    cr.setSourceRgb(1, 1, 1);
    cr.paint();
    scene.draw(cr, @floatFromInt(size[0]), @floatFromInt(size[1]), .{ 0.12, 0.12, 0.12, 1 }, .{});
    cr.destroy();
    var ok = true;
    if (!svg) ok = surface.writeToPng(dest_z.ptr) == .success;
    surface.finish();
    surface.destroy();
    if (ok) out("{s}\n", .{dest}) else err("render: could not write {s}\n", .{dest});
    return ok;
}

// ---- check-lessons -----------------------------------------------------------------------------

fn cmdCheck(args: []const []const u8) u8 {
    const gpa = std.heap.c_allocator;
    var dirs: std.ArrayList([]const u8) = .empty;
    defer {
        if (args.len == 0) for (dirs.items) |d| gpa.free(d);
        dirs.deinit(gpa);
    }
    if (args.len == 0) learn.Learn.lessonDirs(gpa, &dirs) else for (args) |d| dirs.append(gpa, d) catch {};
    var loaded = lessonfile.load(gpa, common.fsio.io(), dirs.items);
    defer loaded.deinit();
    var problems: usize = 0;
    for (loaded.problems) |p| {
        err("{s}\n", .{p});
        problems += 1;
    }
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for (loaded.lessons) |lesson| {
        var scene = scene_mod.Scene.init(gpa);
        defer scene.deinit();
        var session: eval.Session = .{ .gpa = gpa };
        defer session.deinit();
        for (lesson.steps, 0..) |step, si| {
            for (step.ops) |op| {
                if (op == .clear) {
                    scene.runOp(op);
                    continue;
                }
                var used: [8][]const u8 = undefined;
                const n = figure.uses(op, &used);
                for (used[0..n]) |name| {
                    if (scene.findPoint(name) == null) {
                        err("{s} step {d}: the point {s} is used before it is drawn\n", .{ lesson.id, si + 1, name });
                        problems += 1;
                    }
                }
                scene.runOp(op);
                if (figure.defines(op)) |name| {
                    if (scene.findPoint(name) == null) {
                        err("{s} step {d}: no point {s} (the shapes do not cross)\n", .{ lesson.id, si + 1, name });
                        problems += 1;
                    }
                }
            }
            for (step.work) |line| {
                _ = arena.reset(.retain_capacity);
                const got = steps_mod.explain(.{ .a = arena.allocator(), .session = &session, .mode = .{} }, line) catch null;
                if (got == null) {
                    err("{s} step {d}: work \"{s}\": no written-out steps\n", .{ lesson.id, si + 1, line });
                    problems += 1;
                }
            }
            if (step.mode.len > 0 and !std.mem.eql(u8, step.mode, "standard") and !std.mem.eql(u8, step.mode, "scientific") and !std.mem.eql(u8, step.mode, "programmer")) {
                err("{s} step {d}: mode \"{s}\" is not standard, scientific or programmer\n", .{ lesson.id, si + 1, step.mode });
                problems += 1;
            }
            if (step.base != 0 and step.base != 2 and step.base != 8 and step.base != 10 and step.base != 16) {
                err("{s} step {d}: base {d} is not 2, 8, 10 or 16\n", .{ lesson.id, si + 1, step.base });
                problems += 1;
            }
            if (step.bits != 0 and step.bits != 8 and step.bits != 16 and step.bits != 32 and step.bits != 64) {
                err("{s} step {d}: bits {d} is not 8, 16, 32 or 64\n", .{ lesson.id, si + 1, step.bits });
                problems += 1;
            }
            for (step.graph) |line| {
                _ = arena.reset(.retain_capacity);
                var p: eval.Problem = .{};
                _ = eval.run(arena.allocator(), &session, "x = 1", .{}, &p) catch {};
                _ = eval.run(arena.allocator(), &session, line, .{}, &p) catch |e| {
                    err("{s} step {d}: graph \"{s}\": {s}\n", .{ lesson.id, si + 1, line, @errorName(e) });
                    problems += 1;
                };
            }
            for (step.calc) |line| {
                _ = arena.reset(.retain_capacity);
                var p: eval.Problem = .{};
                _ = eval.run(arena.allocator(), &session, line, .{}, &p) catch |e| {
                    err("{s} step {d}: calc \"{s}\": {s}\n", .{ lesson.id, si + 1, line, @errorName(e) });
                    problems += 1;
                };
            }
        }
    }
    for (loaded.lessons) |lesson| {
        var session: eval.Session = .{ .gpa = gpa };
        defer session.deinit();
        for (lesson.exercises, 0..) |ex, ei| {
            _ = arena.reset(.retain_capacity);
            var p: eval.Problem = .{};
            const got = eval.run(arena.allocator(), &session, ex.answer, .{}, &p) catch |e| {
                err("{s} exercise {d}: answer \"{s}\": {s}\n", .{ lesson.id, ei + 1, ex.answer, @errorName(e) });
                problems += 1;
                continue;
            };
            if (eval.plainValue(got) == null) {
                err("{s} exercise {d}: answer \"{s}\" is not a single number\n", .{ lesson.id, ei + 1, ex.answer });
                problems += 1;
            }
        }
    }
    out("{d} lessons, {d} problems\n", .{ loaded.lessons.len, problems });
    return if (problems == 0) 0 else 1;
}
