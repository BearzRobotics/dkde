//! The arithmetic of the geometry pane: distances, angles, areas and the like, on plain points.
//! No toolkit in here, so it is tested on its own.

const std = @import("std");

pub const Pt = struct { x: f64, y: f64 };

pub fn dist(a: Pt, b: Pt) f64 {
    return std.math.hypot(b.x - a.x, b.y - a.y);
}

pub fn midpoint(a: Pt, b: Pt) Pt {
    return .{ .x = (a.x + b.x) / 2, .y = (a.y + b.y) / 2 };
}

/// The angle at `v` between the arms towards `a` and `c`, in degrees (0 to 180). NaN when an arm has no length.
pub fn angleDeg(a: Pt, v: Pt, c: Pt) f64 {
    const ux = a.x - v.x;
    const uy = a.y - v.y;
    const wx = c.x - v.x;
    const wy = c.y - v.y;
    const lu = std.math.hypot(ux, uy);
    const lw = std.math.hypot(wx, wy);
    if (lu == 0 or lw == 0) return std.math.nan(f64);
    const cos = std.math.clamp((ux * wx + uy * wy) / (lu * lw), -1.0, 1.0);
    return std.math.acos(cos) * 180.0 / std.math.pi;
}

/// The direction of the arm from `v` to `p`, in radians (counter-clockwise from the x axis, y up).
pub fn heading(v: Pt, p: Pt) f64 {
    return std.math.atan2(p.y - v.y, p.x - v.x);
}

/// The area of a simple polygon (the shoelace formula), always positive.
pub fn polygonArea(pts: []const Pt) f64 {
    if (pts.len < 3) return 0;
    var sum: f64 = 0;
    for (pts, 0..) |p, i| {
        const q = pts[(i + 1) % pts.len];
        sum += p.x * q.y - q.x * p.y;
    }
    return @abs(sum) / 2;
}

pub fn perimeter(pts: []const Pt) f64 {
    if (pts.len < 2) return 0;
    var sum: f64 = 0;
    for (pts, 0..) |p, i| sum += dist(p, pts[(i + 1) % pts.len]);
    return sum;
}

/// The slope of the line through two points; null for a vertical one.
pub fn slope(a: Pt, b: Pt) ?f64 {
    if (a.x == b.x) return null;
    return (b.y - a.y) / (b.x - a.x);
}

/// Distance from `p` to the segment `a`-`b`.
pub fn distToSegment(p: Pt, a: Pt, b: Pt) f64 {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const len2 = dx * dx + dy * dy;
    if (len2 == 0) return dist(p, a);
    const t = std.math.clamp(((p.x - a.x) * dx + (p.y - a.y) * dy) / len2, 0.0, 1.0);
    return dist(p, .{ .x = a.x + t * dx, .y = a.y + t * dy });
}

/// Distance from `p` to the infinite line through `a` and `b`.
pub fn distToLine(p: Pt, a: Pt, b: Pt) f64 {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const len = std.math.hypot(dx, dy);
    if (len == 0) return dist(p, a);
    return @abs((p.x - a.x) * dy - (p.y - a.y) * dx) / len;
}

/// Where the lines `a1`-`a2` and `b1`-`b2` cross; null when they are parallel.
pub fn intersect(a1: Pt, a2: Pt, b1: Pt, b2: Pt) ?Pt {
    const d1x = a2.x - a1.x;
    const d1y = a2.y - a1.y;
    const d2x = b2.x - b1.x;
    const d2y = b2.y - b1.y;
    const den = d1x * d2y - d1y * d2x;
    if (@abs(den) < 1e-12) return null;
    const t = ((b1.x - a1.x) * d2y - (b1.y - a1.y) * d2x) / den;
    return .{ .x = a1.x + t * d1x, .y = a1.y + t * d1y };
}

/// The classification of a triangle by its sides, for the measurements list.
pub fn triangleKind(a: Pt, b: Pt, c: Pt) []const u8 {
    const x = dist(b, c);
    const y = dist(a, c);
    const z = dist(a, b);
    const eps = 1e-6 * @max(x, @max(y, z));
    const eq = struct {
        fn f(p: f64, q: f64, e: f64) bool {
            return @abs(p - q) <= e;
        }
    }.f;
    var sides = [3]f64{ x, y, z };
    std.mem.sort(f64, &sides, {}, std.sort.asc(f64));
    const right = eq(sides[0] * sides[0] + sides[1] * sides[1], sides[2] * sides[2], eps * sides[2] * 2);
    const name: []const u8 = if (eq(x, y, eps) and eq(y, z, eps)) "equilateral" else if (eq(x, y, eps) or eq(y, z, eps) or eq(x, z, eps)) "isosceles" else "scalene";
    if (right) return if (eq(sides[0], sides[1], eps)) "right isosceles" else "right";
    return name;
}

/// Up to two crossings of the line through `a` and `b` with a circle (centre `c`, radius `r`).
pub fn lineCircle(a: Pt, b: Pt, c: Pt, r: f64) [2]?Pt {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const len2 = dx * dx + dy * dy;
    if (len2 == 0) return .{ null, null };
    const fx = a.x - c.x;
    const fy = a.y - c.y;
    const qa = len2;
    const qb = 2 * (fx * dx + fy * dy);
    const qc = fx * fx + fy * fy - r * r;
    const disc = qb * qb - 4 * qa * qc;
    if (disc < -1e-9 * qa) return .{ null, null };
    const root = @sqrt(@max(disc, 0));
    const t1 = (-qb - root) / (2 * qa);
    const t2 = (-qb + root) / (2 * qa);
    const p1: Pt = .{ .x = a.x + t1 * dx, .y = a.y + t1 * dy };
    if (root < 1e-12) return .{ p1, null };
    return .{ p1, .{ .x = a.x + t2 * dx, .y = a.y + t2 * dy } };
}

/// Up to two crossings of two circles.
pub fn circleCircle(c1: Pt, r1: f64, c2: Pt, r2: f64) [2]?Pt {
    const d = dist(c1, c2);
    if (d == 0 or d > r1 + r2 + 1e-9 or d < @abs(r1 - r2) - 1e-9) return .{ null, null };
    const a = (r1 * r1 - r2 * r2 + d * d) / (2 * d);
    const h2 = r1 * r1 - a * a;
    const h = if (h2 > 0) @sqrt(h2) else 0;
    const mx = c1.x + a * (c2.x - c1.x) / d;
    const my = c1.y + a * (c2.y - c1.y) / d;
    const ox = h * (c2.y - c1.y) / d;
    const oy = h * (c2.x - c1.x) / d;
    const p1: Pt = .{ .x = mx + ox, .y = my - oy };
    if (h < 1e-12) return .{ p1, null };
    return .{ p1, .{ .x = mx - ox, .y = my + oy } };
}

test "circles and lines cross where Euclid says" {
    // Two unit circles a unit apart meet at the apex of the equilateral triangle on that line (I.1).
    const hit = circleCircle(.{ .x = 0, .y = 0 }, 1, .{ .x = 1, .y = 0 }, 1);
    try std.testing.expectApproxEqAbs(0.5, hit[0].?.x, 1e-12);
    try std.testing.expectApproxEqAbs(@sqrt(3.0) / 2.0, @abs(hit[0].?.y), 1e-12);
    try std.testing.expect(hit[1] != null);
    try std.testing.expect(circleCircle(.{ .x = 0, .y = 0 }, 1, .{ .x = 5, .y = 0 }, 1)[0] == null);
    const lc = lineCircle(.{ .x = -2, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 0, .y = 0 }, 1);
    try std.testing.expectApproxEqAbs(-1.0, lc[0].?.x, 1e-12);
    try std.testing.expectApproxEqAbs(1.0, lc[1].?.x, 1e-12);
    try std.testing.expect(lineCircle(.{ .x = -2, .y = 3 }, .{ .x = 2, .y = 3 }, .{ .x = 0, .y = 0 }, 1)[0] == null);
}

test "distance, midpoint, angle" {
    try std.testing.expectApproxEqAbs(5.0, dist(.{ .x = 0, .y = 0 }, .{ .x = 3, .y = 4 }), 1e-12);
    const m = midpoint(.{ .x = 0, .y = 0 }, .{ .x = 4, .y = 2 });
    try std.testing.expectApproxEqAbs(2.0, m.x, 1e-12);
    try std.testing.expectApproxEqAbs(1.0, m.y, 1e-12);
    try std.testing.expectApproxEqAbs(90.0, angleDeg(.{ .x = 1, .y = 0 }, .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 1 }), 1e-9);
    try std.testing.expectApproxEqAbs(45.0, angleDeg(.{ .x = 1, .y = 0 }, .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 1 }), 1e-9);
    try std.testing.expect(std.math.isNan(angleDeg(.{ .x = 0, .y = 0 }, .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 1 })));
}

test "area and perimeter" {
    const square = [_]Pt{ .{ .x = 0, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 2, .y = 2 }, .{ .x = 0, .y = 2 } };
    try std.testing.expectApproxEqAbs(4.0, polygonArea(&square), 1e-12);
    try std.testing.expectApproxEqAbs(8.0, perimeter(&square), 1e-12);
    const tri = [_]Pt{ .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 0 }, .{ .x = 0, .y = 3 } };
    try std.testing.expectApproxEqAbs(6.0, polygonArea(&tri), 1e-12);
    try std.testing.expectApproxEqAbs(12.0, perimeter(&tri), 1e-12);
    try std.testing.expectEqualStrings("right", triangleKind(tri[0], tri[1], tri[2]));
}

test "intersections and distances to lines" {
    const p = intersect(.{ .x = 0, .y = 0 }, .{ .x = 2, .y = 2 }, .{ .x = 0, .y = 2 }, .{ .x = 2, .y = 0 }).?;
    try std.testing.expectApproxEqAbs(1.0, p.x, 1e-12);
    try std.testing.expectApproxEqAbs(1.0, p.y, 1e-12);
    try std.testing.expect(intersect(.{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 }) == null);
    try std.testing.expectApproxEqAbs(std.math.sqrt2, distToSegment(.{ .x = 5, .y = 1 }, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 0 }), 1e-12);
    try std.testing.expectApproxEqAbs(1.0, distToLine(.{ .x = 5, .y = 1 }, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 0 }), 1e-12);
    try std.testing.expect(slope(.{ .x = 1, .y = 0 }, .{ .x = 1, .y = 5 }) == null);
    try std.testing.expectApproxEqAbs(2.0, slope(.{ .x = 0, .y = 0 }, .{ .x = 1, .y = 2 }).?, 1e-12);
}
