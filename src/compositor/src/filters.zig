//! Colour filters for the whole screen, with no wlroots in them so they can be tested: matrices applied
//! to every pixel by the GL composer (negative, grayscale, sepia, stronger contrast, and simulations of
//! the common kinds of colour blindness for people who design for them).

const std = @import("std");

pub const Filter = enum {
    none,
    negative,
    grayscale,
    sepia,
    high_contrast,
    /// Simulations (how the screen looks to someone with the condition), not corrections.
    protanopia,
    deuteranopia,
    tritanopia,

    pub fn next(self: Filter) Filter {
        const all = std.enums.values(Filter);
        return all[(@as(usize, @intFromEnum(self)) + 1) % all.len];
    }
};

/// A 3x3 matrix by rows and an offset: rgb' = M * rgb + offset.
pub const Matrix = struct { rows: [9]f32, off: [3]f32 = .{ 0, 0, 0 } };

pub fn matrixFor(f: Filter) Matrix {
    return switch (f) {
        .none => .{ .rows = .{ 1, 0, 0, 0, 1, 0, 0, 0, 1 } },
        .negative => .{ .rows = .{ -1, 0, 0, 0, -1, 0, 0, 0, -1 }, .off = .{ 1, 1, 1 } },
        .grayscale => .{ .rows = .{ 0.2126, 0.7152, 0.0722, 0.2126, 0.7152, 0.0722, 0.2126, 0.7152, 0.0722 } },
        .sepia => .{ .rows = .{ 0.393, 0.769, 0.189, 0.349, 0.686, 0.168, 0.272, 0.534, 0.131 } },
        .high_contrast => .{ .rows = .{ 1.6, 0, 0, 0, 1.6, 0, 0, 0, 1.6 }, .off = .{ -0.3, -0.3, -0.3 } },
        // Machado, Oliveira and Fernandes (2009), severity 1.0.
        .protanopia => .{ .rows = .{ 0.152286, 1.052583, -0.204868, 0.114503, 0.786281, 0.099216, -0.003882, -0.048116, 1.051998 } },
        .deuteranopia => .{ .rows = .{ 0.367322, 0.860646, -0.227968, 0.280085, 0.672501, 0.047413, -0.011820, 0.042940, 0.968881 } },
        .tritanopia => .{ .rows = .{ 1.255528, -0.076749, -0.178779, -0.078411, 0.930809, 0.147602, 0.004733, 0.691367, 0.303900 } },
    };
}

pub fn apply(m: Matrix, rgb: [3]f32) [3]f32 {
    var out: [3]f32 = undefined;
    for (0..3) |i| {
        const v = m.rows[i * 3] * rgb[0] + m.rows[i * 3 + 1] * rgb[1] + m.rows[i * 3 + 2] * rgb[2] + m.off[i];
        out[i] = std.math.clamp(v, 0, 1);
    }
    return out;
}

test "negative turns white to black and back" {
    const m = matrixFor(.negative);
    const black = apply(m, .{ 1, 1, 1 });
    try std.testing.expectEqual([3]f32{ 0, 0, 0 }, black);
    const white = apply(m, .{ 0, 0, 0 });
    try std.testing.expectEqual([3]f32{ 1, 1, 1 }, white);
    const red = apply(m, .{ 1, 0, 0 });
    try std.testing.expectEqual([3]f32{ 0, 1, 1 }, red);
}

test "grayscale gives equal channels and keeps white white" {
    const m = matrixFor(.grayscale);
    const g = apply(m, .{ 0.2, 0.6, 0.9 });
    try std.testing.expectApproxEqAbs(g[0], g[1], 1e-6);
    try std.testing.expectApproxEqAbs(g[1], g[2], 1e-6);
    const w = apply(m, .{ 1, 1, 1 });
    try std.testing.expectApproxEqAbs(@as(f32, 1), w[0], 1e-4);
}

test "colour-blindness simulations keep white and black" {
    for ([_]Filter{ .protanopia, .deuteranopia, .tritanopia }) |f| {
        const m = matrixFor(f);
        const w = apply(m, .{ 1, 1, 1 });
        for (w) |v| try std.testing.expectApproxEqAbs(@as(f32, 1), v, 0.02);
        const k = apply(m, .{ 0, 0, 0 });
        for (k) |v| try std.testing.expectEqual(@as(f32, 0), v);
    }
}

test "high contrast darkens darks and lightens lights" {
    const m = matrixFor(.high_contrast);
    try std.testing.expect(apply(m, .{ 0.4, 0.4, 0.4 })[0] < 0.4);
    try std.testing.expect(apply(m, .{ 0.8, 0.8, 0.8 })[0] > 0.8);
}

test "next cycles through every filter" {
    var f = Filter.none;
    var seen: usize = 0;
    while (true) {
        f = f.next();
        seen += 1;
        if (f == .none) break;
    }
    try std.testing.expectEqual(std.enums.values(Filter).len, seen);
}
