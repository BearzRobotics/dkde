//! The desktop cube, with no wlroots in it so the geometry can be tested: each workspace is a face of a
//! prism (a cube with four workspaces), seen from outside by a camera in front of it. At rest the front
//! face fills the screen exactly, so entering and leaving the cube has no jump.

const std = @import("std");

pub const Vertex = struct {
    /// Clip-space position for a perspective-correct texture: (ndc_x * w, ndc_y * w, 0, w).
    x: f32,
    y: f32,
    w: f32,
    /// Texture coordinates.
    u: f32,
    v: f32,
};

pub const Face = struct {
    /// Which workspace this face shows.
    index: usize,
    /// Corners in the order top-left, top-right, bottom-left, bottom-right (as the texture is laid out).
    corners: [4]Vertex,
    /// 1 for the face looking straight at the camera, less as it turns away.
    light: f32,
};

/// The position (in workspaces, may be fractional) that animates from `from` to `to` by `p` (0..1),
/// going the short way around.
pub fn position(from: usize, to: usize, count: usize, p: f32) f32 {
    const n: i64 = @intCast(count);
    var delta: i64 = @as(i64, @intCast(to)) - @as(i64, @intCast(from));
    delta = @mod(delta + @divTrunc(n, 2) + (if (@mod(n, 2) == 0) @as(i64, 0) else 0), n) - @divTrunc(n, 2);
    if (@mod(n, 2) == 0 and delta == -@divTrunc(n, 2)) delta = @divTrunc(n, 2); // halfway round: always forward
    return @as(f32, @floatFromInt(from)) + @as(f32, @floatFromInt(delta)) * p;
}

/// The faces to draw for a cube of `count` workspaces turned to `pos`, on a screen of w by h pixels, back to front.
/// `out` needs room for `count` faces; returns how many are visible.
pub fn faces(count: usize, pos: f32, w: f32, h: f32, out: []Face) usize {
    std.debug.assert(out.len >= count and count >= 3);
    const n: f32 = @floatFromInt(count);
    const tau: f32 = 2 * std.math.pi;
    // The prism's radius to the middle of a face, the camera's distance from the centre, and the focal
    // length that makes the front face exactly screen-sized.
    const r = (w / 2) / @tan(std.math.pi / n);
    const d = r + w * 0.9;
    const focal = d - r;
    var shown: usize = 0;
    for (0..count) |i| {
        const phi = tau * (@as(f32, @floatFromInt(i)) - pos) / n;
        const cosp = @cos(phi);
        // Faces turned away from the camera are not drawn.
        if (cosp <= r / d + 0.001) continue;
        const sinp = @sin(phi);
        const cx = r * sinp;
        const cz = r * cosp;
        const tx = cosp;
        const tz = -sinp;
        const half_w = w / 2;
        const half_h = h / 2;
        var f: Face = .{ .index = i, .corners = undefined, .light = 0.55 + 0.45 * cosp };
        const spec = [4][3]f32{ .{ -1, 1, 0 }, .{ 1, 1, 0 }, .{ -1, -1, 0 }, .{ 1, -1, 0 } };
        const uvs = [4][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 } };
        for (spec, 0..) |sp, q| {
            const px = cx + tx * half_w * sp[0];
            const pz = cz + tz * half_w * sp[0];
            const py = half_h * sp[1];
            const wc = (d - pz) / focal;
            const sx = px / wc;
            const sy = py / wc;
            f.corners[q] = .{ .x = sx * 2 / w * wc, .y = -sy * 2 / h * wc, .w = wc, .u = uvs[q][0], .v = uvs[q][1] };
        }
        out[shown] = f;
        shown += 1;
    }
    // Back to front: the face nearest the camera is last.
    std.mem.sort(Face, out[0..shown], {}, struct {
        fn lt(_: void, a: Face, b: Face) bool {
            return a.light < b.light;
        }
    }.lt);
    return shown;
}

test "at rest the front face fills the screen" {
    var out: [8]Face = undefined;
    const n = faces(4, 0, 1600, 900, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(usize, 0), out[0].index);
    const tl = out[0].corners[0];
    try std.testing.expectApproxEqAbs(@as(f32, -1), tl.x / tl.w, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, -1), tl.y / tl.w, 1e-3);
    const br = out[0].corners[3];
    try std.testing.expectApproxEqAbs(@as(f32, 1), br.x / br.w, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 1), br.y / br.w, 1e-3);
}

test "halfway between two workspaces both are visible and symmetric" {
    var out: [8]Face = undefined;
    const n = faces(4, 0.5, 1600, 900, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    // Face 0 is to the left, face 1 to the right.
    var left: ?Face = null;
    var right: ?Face = null;
    for (out[0..n]) |f| {
        if (f.index == 0) left = f else right = f;
    }
    try std.testing.expect(left.?.corners[0].x / left.?.corners[0].w < right.?.corners[0].x / right.?.corners[0].w);
    try std.testing.expectApproxEqAbs(left.?.light, right.?.light, 1e-3);
}

test "other cube sizes work" {
    var out: [9]Face = undefined;
    for ([_]usize{ 3, 5, 6, 9 }) |count| {
        const n = faces(count, 0, 1280, 720, &out);
        try std.testing.expect(n >= 1);
        try std.testing.expectEqual(@as(usize, 0), out[n - 1].index);
    }
}

test "the short way round" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), position(0, 1, 4, 0.5), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 3.5), position(3, 0, 4, 0.5), 1e-6); // forward over the seam
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), position(1, 0, 4, 0.5), 1e-6); // back
    try std.testing.expectApproxEqAbs(@as(f32, 1), position(0, 2, 4, 0.5), 1e-6); // halfway round goes forward
}
