//! Known-answer checks for the calculator. `probe` (run only when CALC_PROBE
//! names a file of entries, one per line, `rad:` or `grad:` in front for that
//! angle unit) prints what the calculator answers, for comparing with values
//! worked out some other way.

const std = @import("std");
const num = @import("num.zig");
const eval = @import("eval.zig");
const rich = @import("rich.zig");

fn show(a: std.mem.Allocator, o: eval.Outcome) ![]const u8 {
    return switch (o) {
        .value => |v| num.format(a, v, .{ .decimals = 12 }),
        .assigned => |s| num.format(a, s.value, .{ .decimals = 12 }),
        .defined => |d| d,
        .truth => |t| if (t) "true" else "false",
        .simplified => |x| x,
        .rich => |v| try rich.format(a, v, .{ .decimals = 12 }),
        .system => |sy| try std.fmt.allocPrint(a, "{d} unknowns", .{sy.names.len}),
        .rich_assigned => |s| try rich.format(a, s.value, .{ .decimals = 12 }),
        .complex => |cx| try std.fmt.allocPrint(a, "{d} complex", .{cx.re.len}),
        .solved => |s| blk: {
            var parts: std.ArrayList(u8) = .empty;
            for (s.roots, 0..) |r, i| {
                if (i > 0) try parts.appendSlice(a, "; ");
                try parts.appendSlice(a, try num.format(a, r, .{ .decimals = 12 }));
            }
            break :blk parts.items;
        },
    };
}

test "probe" {
    const path_c = std.c.getenv("CALC_PROBE") orelse return error.SkipZigTest;
    var io_threaded: std.Io.Threaded = .init_single_threaded;
    const io = io_threaded.io();
    const text = try std.Io.Dir.cwd().readFileAlloc(io, std.mem.span(path_c), std.testing.allocator, .limited(1 << 22));
    defer std.testing.allocator.free(text);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var session: eval.Session = .{ .gpa = std.testing.allocator };
    defer session.deinit();
    var lines = std.mem.splitScalar(u8, text, '\n');
    var out: std.ArrayList(u8) = .empty;
    while (lines.next()) |raw| {
        var line = raw;
        if (line.len == 0) continue;
        var mode: eval.Mode = .{};
        if (std.mem.startsWith(u8, line, "rad:")) {
            mode.angle = .radians;
            line = line[4..];
        } else if (std.mem.startsWith(u8, line, "solve:")) {
            mode.solve_only = true;
            line = line[6..];
        } else if (std.mem.startsWith(u8, line, "grad:")) {
            mode.angle = .gradians;
            line = line[5..];
        }
        if (std.c.getenv("CALC_PROBE_TRACE") != null) std.debug.print("> {s}\n", .{raw});
        var p: eval.Problem = .{};
        const res: []const u8 = if (eval.run(a, &session, line, mode, &p)) |o| (show(a, o) catch "ERR:fmt") else |e| try std.fmt.allocPrint(a, "ERR:{s}", .{@errorName(e)});
        try out.print(a, "{s}\t=> {s}\n", .{ raw, res });
    }
    const dest_c = std.c.getenv("CALC_PROBE_OUT") orelse return;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = std.mem.span(dest_c), .data = out.items });
}

fn expectShows(session: *eval.Session, want: []const u8, text: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var p: eval.Problem = .{};
    const o = try eval.run(a, session, text, .{}, &p);
    const got = switch (o) {
        .value => |v| try num.format(a, v, .{}),
        else => return error.TestUnexpectedResult,
    };
    std.testing.expectEqualStrings(want, got) catch |e| {
        std.debug.print("for {s}\n", .{text});
        return e;
    };
}

test "numbers too big for a float are shown from their exact digits" {
    var s: eval.Session = .{ .gpa = std.testing.allocator };
    defer s.deinit();
    // These used to abort the program when displayed.
    try expectShows(&s, "1.0715086072×10^301", "2^1000");
    try expectShows(&s, "7.8865786736×10^374", "200!");
    try expectShows(&s, "-1.0715086072×10^301", "-(2^1000)");
    try expectShows(&s, "1×10^400", "10^400");
    try expectShows(&s, "9.999999999×10^399", "10^400 - 10^390");
    try expectShows(&s, "1×10^-400", "10^-400");
}

test "a small result is never shown as zero" {
    var s: eval.Session = .{ .gpa = std.testing.allocator };
    defer s.deinit();
    try expectShows(&s, "1×10^-12", "1/10^12");
    try expectShows(&s, "0.000000002", "2/10^9");
    try expectShows(&s, "0.1", "1/10");
    try expectShows(&s, "-2.5×10^-10", "-25/10^11");
}

test "choosing more than there are is zero ways" {
    var s: eval.Session = .{ .gpa = std.testing.allocator };
    defer s.deinit();
    try expectShows(&s, "0", "nCr(7, 8)");
    try expectShows(&s, "0", "nPr(7, 8)");
    try expectShows(&s, "1", "nCr(7, 0)");
}

fn runShows(session: *eval.Session, want: []const u8, text: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var p: eval.Problem = .{};
    const o = try eval.run(a, session, text, .{}, &p);
    const got = try show(a, o);
    std.testing.expectEqualStrings(want, got) catch |e| {
        std.debug.print("for {s}\n", .{text});
        return e;
    };
}

test "comparisons are true or false" {
    var s: eval.Session = .{ .gpa = std.testing.allocator };
    defer s.deinit();
    try runShows(&s, "true", "5 > 3");
    try runShows(&s, "false", "5 < 3");
    try runShows(&s, "true", "3 <= 3");
    try runShows(&s, "true", "2 >= 1+1");
    try runShows(&s, "true", "1/3 != 0.3333");
    try runShows(&s, "false", "0.1+0.2 != 0.3");
    try runShows(&s, "true", "5 ≥ 5 and 2 ≠ 3");
    try runShows(&s, "true", "1 < 2 or 5 < 3");
    try runShows(&s, "120", "5!");
    try runShows(&s, "true", "5!=3");
}

test "round with digits, double factorial, percent of" {
    var s: eval.Session = .{ .gpa = std.testing.allocator };
    defer s.deinit();
    try runShows(&s, "2.57", "round(2.567, 2)");
    try runShows(&s, "1200", "round(1234.5678, -2)");
    try runShows(&s, "3", "round(2.5)");
    try runShows(&s, "105", "7!!");
    try runShows(&s, "48", "6!!");
    try runShows(&s, "10", "20% of 50");
    try runShows(&s, "20", "10% of 200");
    try runShows(&s, "55", "50 + 10%");
}

test "statements in a row, solve and simplify" {
    var s: eval.Session = .{ .gpa = std.testing.allocator };
    defer s.deinit();
    try runShows(&s, "10", "x = 5; x * 2");
    try runShows(&s, "9", "f(x) = x^2; f(3)");
    try runShows(&s, "6", "a = 2; b = 3; a * b");
    var t: eval.Session = .{ .gpa = std.testing.allocator };
    defer t.deinit();
    try runShows(&t, "-2; 2", "solve(x^2 = 4, x)");
    try runShows(&t, "-2; 2", "solve(x^2 - 4)");
    try runShows(&t, "5x", "simplify(2x + 3x)");
}
