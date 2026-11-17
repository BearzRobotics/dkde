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
pub const Step = struct { text: []const u8, ops: []const Op = &.{} };

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
