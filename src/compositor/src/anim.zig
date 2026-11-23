//! Window animation timing, with no wlroots in it so it can be tested: easing, and the transform
//! (scale, shift, opacity) a window has at a moment of an open, restore or minimize animation.

const std = @import("std");

/// A window drawn through a small mesh: where each node is off its place (wobbly windows). The mesh covers
/// the window's rectangle (x, y, w, h, in layout coordinates); the displacement is interpolated between nodes.
pub const Warp = struct {
    /// Nodes along each side.
    pub const n = 4;
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 1,
    h: f32 = 1,
    dx: [n * n]f32 = std.mem.zeroes([n * n]f32),
    dy: [n * n]f32 = std.mem.zeroes([n * n]f32),

    /// How far the point (px, py) moves; points outside the rectangle use the nearest edge's displacement.
    pub fn at(self: Warp, px: f32, py: f32) [2]f32 {
        const u = std.math.clamp((px - self.x) / @max(self.w, 1), 0, 1) * @as(f32, @floatFromInt(n - 1));
        const v = std.math.clamp((py - self.y) / @max(self.h, 1), 0, 1) * @as(f32, @floatFromInt(n - 1));
        const iu: usize = @min(@as(usize, @intFromFloat(u)), n - 2);
        const iv: usize = @min(@as(usize, @intFromFloat(v)), n - 2);
        const fu = u - @as(f32, @floatFromInt(iu));
        const fv = v - @as(f32, @floatFromInt(iv));
        const q00 = iv * n + iu;
        const q10 = q00 + 1;
        const q01 = q00 + n;
        const q11 = q01 + 1;
        const bx = (self.dx[q00] * (1 - fu) + self.dx[q10] * fu) * (1 - fv) + (self.dx[q01] * (1 - fu) + self.dx[q11] * fu) * fv;
        const by = (self.dy[q00] * (1 - fu) + self.dy[q10] * fu) * (1 - fv) + (self.dy[q01] * (1 - fu) + self.dy[q11] * fu) * fv;
        return .{ bx, by };
    }
};

/// What is drawn of a window: scaled about an anchor point (in layout coordinates), shifted, and
/// made translucent. The identity leaves the window as it is.
pub const Xf = struct {
    scale: f32 = 1,
    /// The point the scale is about (usually the window's centre).
    ax: f32 = 0,
    ay: f32 = 0,
    tx: f32 = 0,
    ty: f32 = 0,
    alpha: f32 = 1,
    /// Draw the window even though it is hidden (Expo shows windows of the other workspaces).
    force: bool = false,
    /// Wobbly windows: draw the window through this mesh (only the GLES composer does).
    warp: ?*const Warp = null,
    /// Blur what is behind the window (it is translucent).
    blur: bool = false,
};

pub const Kind = enum { open, restore, minimize };

pub const Anim = struct {
    kind: Kind,
    start_ms: u32,
    duration_ms: u32,
    /// Where a minimized window shrinks to, relative to its centre.
    to_x: f32 = 0,
    to_y: f32 = 0,
};

/// Slow at the end.
pub fn easeOut(t: f32) f32 {
    const u = 1 - std.math.clamp(t, 0, 1);
    return 1 - u * u * u;
}

/// How far along the animation is, 0 to 1 (not eased).
pub fn fraction(a: Anim, now_ms: u32) f32 {
    if (a.duration_ms == 0) return 1;
    const elapsed: f32 = @floatFromInt(now_ms -% a.start_ms);
    return std.math.clamp(elapsed / @as(f32, @floatFromInt(a.duration_ms)), 0, 1);
}

pub fn done(a: Anim, now_ms: u32) bool {
    return fraction(a, now_ms) >= 1;
}

/// The transform at `now_ms`, for a window whose centre is (cx, cy).
pub fn at(a: Anim, now_ms: u32, cx: f32, cy: f32) Xf {
    const p = easeOut(fraction(a, now_ms));
    var xf: Xf = .{ .ax = cx, .ay = cy };
    switch (a.kind) {
        .open, .restore => {
            xf.scale = 0.85 + 0.15 * p;
            xf.alpha = p;
        },
        .minimize => {
            xf.scale = 1 - 0.7 * p;
            xf.alpha = 1 - p;
            xf.tx = a.to_x * p;
            xf.ty = a.to_y * p;
        },
    }
    return xf;
}

test "easing runs from 0 to 1" {
    try std.testing.expectEqual(@as(f32, 0), easeOut(0));
    try std.testing.expectEqual(@as(f32, 1), easeOut(1));
    try std.testing.expect(easeOut(0.5) > 0.5);
    try std.testing.expectEqual(@as(f32, 1), easeOut(7));
}

test "an open animation fades and grows" {
    const a = Anim{ .kind = .open, .start_ms = 1000, .duration_ms = 200 };
    const start = at(a, 1000, 50, 60);
    try std.testing.expectApproxEqAbs(@as(f32, 0.85), start.scale, 0.001);
    try std.testing.expectEqual(@as(f32, 0), start.alpha);
    try std.testing.expectEqual(@as(f32, 50), start.ax);
    const end = at(a, 1200, 50, 60);
    try std.testing.expectEqual(@as(f32, 1), end.scale);
    try std.testing.expectEqual(@as(f32, 1), end.alpha);
    try std.testing.expect(done(a, 1200));
    try std.testing.expect(!done(a, 1100));
}

test "a minimize animation shrinks toward its target" {
    const a = Anim{ .kind = .minimize, .start_ms = 0, .duration_ms = 100, .to_x = 10, .to_y = 400 };
    const end = at(a, 100, 0, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), end.scale, 0.001);
    try std.testing.expectEqual(@as(f32, 0), end.alpha);
    try std.testing.expectEqual(@as(f32, 400), end.ty);
}

test "the clock may wrap" {
    const a = Anim{ .kind = .open, .start_ms = std.math.maxInt(u32) - 10, .duration_ms = 100 };
    try std.testing.expect(fraction(a, 40) > 0.4 and fraction(a, 40) < 0.6);
}

test "a warp interpolates between its nodes" {
    var w = Warp{ .x = 0, .y = 0, .w = 300, .h = 300 };
    for (0..Warp.n * Warp.n) |i| w.dx[i] = @floatFromInt(i % Warp.n); // 0, 1, 2, 3 across
    try std.testing.expectApproxEqAbs(@as(f32, 0), w.at(0, 100)[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 3), w.at(300, 100)[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), w.at(150, 40)[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 3), w.at(900, 40)[0], 0.001); // outside: the edge's value
}
