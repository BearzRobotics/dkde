//! The drawing language of the lessons: a step of a lesson is a few of these operations, which the
//! Geometry pane carries out (a point here, a circle there, a crossing worked out from two circles).
//! Points are named, so a step can say "the circle with centre A through B".

pub const Colour = u8; // an index into geometry.palette

pub const Cross = enum { circle_circle, line_circle, line_line };

pub const Op = union(enum) {
    /// Start from an empty canvas.
    clear,
    pt: struct { n: []const u8, x: f64, y: f64 },
    seg: struct { a: []const u8, b: []const u8, colour: Colour = 7 },
    line: struct { a: []const u8, b: []const u8, colour: Colour = 7 },
    /// The circle with the centre `c`, through the point `t`.
    circle: struct { c: []const u8, t: []const u8, colour: Colour = 0, fill: bool = false },
    poly: struct { names: []const []const u8, colour: Colour = 0, fill: bool = false },
    angle: struct { a: []const u8, v: []const u8, c: []const u8, colour: Colour = 1, fill: bool = false },
    /// A new point where two shapes cross. circle_circle: the circles (a0 through a1) and (b0 through b1);
    /// line_circle: the line a0-a1 and the circle (b0 through b1); line_line: the lines a0-a1 and b0-b1.
    /// `which` picks one of the two crossings.
    cross: struct { n: []const u8, kind: Cross, a0: []const u8, a1: []const u8, b0: []const u8, b1: []const u8, which: u1 = 0 },
};

// Short constructors, so the lessons read like the figure they draw.

pub fn P(n: []const u8, x: f64, y: f64) Op {
    return .{ .pt = .{ .n = n, .x = x, .y = y } };
}

pub fn S(a: []const u8, b: []const u8, colour: Colour) Op {
    return .{ .seg = .{ .a = a, .b = b, .colour = colour } };
}

pub fn L(a: []const u8, b: []const u8, colour: Colour) Op {
    return .{ .line = .{ .a = a, .b = b, .colour = colour } };
}

pub fn C(c: []const u8, t: []const u8, colour: Colour, fill: bool) Op {
    return .{ .circle = .{ .c = c, .t = t, .colour = colour, .fill = fill } };
}

pub fn T(names: []const []const u8, colour: Colour, fill: bool) Op {
    return .{ .poly = .{ .names = names, .colour = colour, .fill = fill } };
}

pub fn A(a: []const u8, v: []const u8, c: []const u8, colour: Colour, fill: bool) Op {
    return .{ .angle = .{ .a = a, .v = v, .c = c, .colour = colour, .fill = fill } };
}

/// Two circles (centre a0 through a1, centre b0 through b1) meet at a new point `n`.
pub fn XCC(n: []const u8, a0: []const u8, a1: []const u8, b0: []const u8, b1: []const u8, which: u1) Op {
    return .{ .cross = .{ .n = n, .kind = .circle_circle, .a0 = a0, .a1 = a1, .b0 = b0, .b1 = b1, .which = which } };
}

/// The line a0-a1 meets the circle (centre b0 through b1) at a new point `n`.
pub fn XLC(n: []const u8, a0: []const u8, a1: []const u8, b0: []const u8, b1: []const u8, which: u1) Op {
    return .{ .cross = .{ .n = n, .kind = .line_circle, .a0 = a0, .a1 = a1, .b0 = b0, .b1 = b1, .which = which } };
}

pub fn XLL(n: []const u8, a0: []const u8, a1: []const u8, b0: []const u8, b1: []const u8) Op {
    return .{ .cross = .{ .n = n, .kind = .line_line, .a0 = a0, .a1 = a1, .b0 = b0, .b1 = b1 } };
}

pub const clear: Op = .clear;

/// One step of a lesson: what to say, and what to draw.
pub const Step = struct {
    text: []const u8,
    ops: []const Op = &.{},
    /// Calculator lines to try (shown under the step; a click puts one in the entry).
    calc: []const []const u8 = &.{},
};

pub const Kind = enum { definition, postulate, notion, proposition };

/// One lesson: a group of definitions, the postulates, or one proposition.
pub const Lesson = struct {
    /// "I.1", "Postulates"...
    id: []const u8,
    /// 0 for the foundations, else the book (1 to 13).
    book: u8,
    title: []const u8,
    /// What is to be shown or done, in Euclid's words (Heath's translation).
    statement: []const u8,
    steps: []const Step,
    /// The proof (or the reason the construction works), in plain words.
    proof: []const u8 = "",
};

// ---- the text form ---------------------------------------------------------------------------
//
// In a lesson file a step's drawing is a list of lines, one operation each:
//
//   clear
//   point A -2.5 -1.5
//   segment A B [colour]
//   line A B [colour]
//   circle C T [colour] [fill]        centre C, through T
//   polygon A B C ... [colour] [fill]
//   angle A V C [colour] [fill]       the angle at V between the arms to A and C
//   cross N cc A0 A1 B0 B1 [0|1]     two circles (A0 through A1, B0 through B1) meet at N
//   cross N lc A0 A1 B0 B1 [0|1]     the line A0 A1 meets the circle (B0 through B1)
//   cross N ll A0 A1 B0 B1           two lines meet
//
// Colours are blue red green orange purple teal yellow black (so a point is never named like one).

const std = @import("std");

pub const colour_names = [_][]const u8{ "blue", "red", "green", "orange", "purple", "teal", "yellow", "black" };

pub fn colourIndex(word: []const u8) ?Colour {
    for (colour_names, 0..) |name, i| if (std.mem.eql(u8, name, word)) return @intCast(i);
    return null;
}

pub const ParseError = error{ UnknownCommand, MissingWord, BadNumber, BadColour, OutOfMemory };

/// Reads one line of drawing text. The words are copied into `arena`.
pub fn parseOp(arena: std.mem.Allocator, line: []const u8) ParseError!Op {
    var words: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, line, " \t");
    while (it.next()) |w| try words.append(arena, try arena.dupe(u8, w));
    const w = words.items;
    if (w.len == 0) return error.MissingWord;
    const cmd = w[0];
    const args = w[1..];
    if (std.mem.eql(u8, cmd, "clear")) return .clear;
    if (std.mem.eql(u8, cmd, "point")) {
        if (args.len != 3) return error.MissingWord;
        return .{ .pt = .{ .n = args[0], .x = std.fmt.parseFloat(f64, args[1]) catch return error.BadNumber, .y = std.fmt.parseFloat(f64, args[2]) catch return error.BadNumber } };
    }
    if (std.mem.eql(u8, cmd, "segment") or std.mem.eql(u8, cmd, "line")) {
        if (args.len < 2 or args.len > 3) return error.MissingWord;
        const colour = if (args.len == 3) colourIndex(args[2]) orelse return error.BadColour else 7;
        if (cmd[0] == 's') return .{ .seg = .{ .a = args[0], .b = args[1], .colour = colour } };
        return .{ .line = .{ .a = args[0], .b = args[1], .colour = colour } };
    }
    if (std.mem.eql(u8, cmd, "circle")) {
        if (args.len < 2) return error.MissingWord;
        var colour: Colour = 0;
        var fill = false;
        for (args[2..]) |extra| {
            if (std.mem.eql(u8, extra, "fill")) fill = true else colour = colourIndex(extra) orelse return error.BadColour;
        }
        return .{ .circle = .{ .c = args[0], .t = args[1], .colour = colour, .fill = fill } };
    }
    if (std.mem.eql(u8, cmd, "polygon")) {
        var colour: Colour = 0;
        var fill = false;
        var names: std.ArrayList([]const u8) = .empty;
        for (args) |word| {
            if (std.mem.eql(u8, word, "fill")) {
                fill = true;
            } else if (colourIndex(word)) |c| {
                colour = c;
            } else try names.append(arena, word);
        }
        if (names.items.len < 3) return error.MissingWord;
        return .{ .poly = .{ .names = try names.toOwnedSlice(arena), .colour = colour, .fill = fill } };
    }
    if (std.mem.eql(u8, cmd, "angle")) {
        if (args.len < 3) return error.MissingWord;
        var colour: Colour = 1;
        var fill = false;
        for (args[3..]) |extra| {
            if (std.mem.eql(u8, extra, "fill")) fill = true else colour = colourIndex(extra) orelse return error.BadColour;
        }
        return .{ .angle = .{ .a = args[0], .v = args[1], .c = args[2], .colour = colour, .fill = fill } };
    }
    if (std.mem.eql(u8, cmd, "cross")) {
        if (args.len < 6) return error.MissingWord;
        const kind: Cross = if (std.mem.eql(u8, args[1], "cc")) .circle_circle else if (std.mem.eql(u8, args[1], "lc")) .line_circle else if (std.mem.eql(u8, args[1], "ll")) .line_line else return error.UnknownCommand;
        var which: u1 = 0;
        if (args.len > 6) which = if (std.mem.eql(u8, args[6], "1")) 1 else 0;
        return .{ .cross = .{ .n = args[0], .kind = kind, .a0 = args[2], .a1 = args[3], .b0 = args[4], .b1 = args[5], .which = which } };
    }
    return error.UnknownCommand;
}

test "drawing lines are read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try parseOp(a, "point A -2.5 1");
    try std.testing.expectEqualStrings("A", p.pt.n);
    try std.testing.expectEqual(@as(f64, -2.5), p.pt.x);
    const c = try parseOp(a, "circle A B red fill");
    try std.testing.expectEqual(@as(Colour, 1), c.circle.colour);
    try std.testing.expect(c.circle.fill);
    const t = try parseOp(a, "polygon A B C green fill");
    try std.testing.expectEqual(@as(usize, 3), t.poly.names.len);
    try std.testing.expectEqual(@as(Colour, 2), t.poly.colour);
    const x = try parseOp(a, "cross C cc A B B A 1");
    try std.testing.expectEqual(@as(u1, 1), x.cross.which);
    try std.testing.expectEqual(Cross.circle_circle, x.cross.kind);
    try std.testing.expectError(error.UnknownCommand, parseOp(a, "blorp A"));
    try std.testing.expectError(error.BadColour, parseOp(a, "segment A B mauve"));
    try std.testing.expectError(error.BadNumber, parseOp(a, "point A x 1"));
}

/// The point names an operation needs to exist already (the ones it only refers to).
pub fn uses(op: Op, out: *[8][]const u8) usize {
    var n: usize = 0;
    switch (op) {
        .clear, .pt => {},
        .seg => |o| {
            out[0] = o.a;
            out[1] = o.b;
            n = 2;
        },
        .line => |o| {
            out[0] = o.a;
            out[1] = o.b;
            n = 2;
        },
        .circle => |o| {
            out[0] = o.c;
            out[1] = o.t;
            n = 2;
        },
        .poly => |o| {
            for (o.names) |name| {
                if (n == out.len) break;
                out[n] = name;
                n += 1;
            }
        },
        .angle => |o| {
            out[0] = o.a;
            out[1] = o.v;
            out[2] = o.c;
            n = 3;
        },
        .cross => |o| {
            out[0] = o.a0;
            out[1] = o.a1;
            out[2] = o.b0;
            out[3] = o.b1;
            n = 4;
        },
    }
    return n;
}

/// The point an operation makes, if it makes one.
pub fn defines(op: Op) ?[]const u8 {
    return switch (op) {
        .pt => |o| o.n,
        .cross => |o| o.n,
        else => null,
    };
}
