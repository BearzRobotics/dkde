// SPDX-License-Identifier: GPL-2.0-or-later
//! Wobbly windows, with no wlroots in them so they can be tested: a small mesh of nodes joined by springs.
//! The window's real rectangle moves where the compositor puts it; each node is pulled toward its place in
//! that rectangle by a spring and toward its neighbours by others, and loses speed to friction, so the window
//! stretches and swings behind a drag and settles. The node under the pointer is held to the pointer.

const std = @import("std");
const anim = @import("anim.zig");

pub const N = anim.Warp.n;

pub const Params = struct {
    /// Pull toward the node's place in the window, between neighbours, and friction.
    spring: f32 = 110,
    neighbour: f32 = 70,
    friction: f32 = 7.5,
    /// How far a node may be from its place (keeps a hard shove from tearing the window apart).
    max_stretch: f32 = 240,
};

pub const Wobble = struct {
    rx: f32,
    ry: f32,
    rw: f32,
    rh: f32,
    pos: [N * N][2]f32,
    vel: [N * N][2]f32 = std.mem.zeroes([N * N][2]f32),
    /// The held point, as a fraction of the window, while the pointer drags it.
    held: ?[2]f32 = null,
    warp: anim.Warp = .{},
    params: Params = .{},

    fn restOf(self: *const Wobble, i: usize) [2]f32 {
        const gx: f32 = @floatFromInt(i % N);
        const gy: f32 = @floatFromInt(i / N);
        const d: f32 = @floatFromInt(N - 1);
        return .{ self.rx + gx / d * self.rw, self.ry + gy / d * self.rh };
    }

    pub fn init(x: f32, y: f32, w: f32, h: f32) Wobble {
        var wob: Wobble = .{ .rx = x, .ry = y, .rw = w, .rh = h, .pos = undefined };
        for (0..N * N) |i| wob.pos[i] = wob.restOf(i);
        wob.updateWarp();
        return wob;
    }

    /// Where the window really is now. The nodes stay where they are and are pulled after it.
    pub fn setRest(self: *Wobble, x: f32, y: f32, w: f32, h: f32) void {
        self.rx = x;
        self.ry = y;
        self.rw = w;
        self.rh = h;
    }

    fn heldNode(self: *const Wobble) ?usize {
        const h = self.held orelse return null;
        const d: f32 = @floatFromInt(N - 1);
        const gx: usize = @intFromFloat(@round(std.math.clamp(h[0], 0, 1) * d));
        const gy: usize = @intFromFloat(@round(std.math.clamp(h[1], 0, 1) * d));
        return gy * N + gx;
    }

    pub fn step(self: *Wobble, dt_seconds: f32) void {
        // Small fixed steps keep the springs stable however long a frame took.
        var left = @min(dt_seconds, 0.1);
        const h: f32 = 1.0 / 240.0;
        while (left > 0) : (left -= h) {
            self.substep(@min(h, left));
        }
        self.updateWarp();
    }

    fn substep(self: *Wobble, dt: f32) void {
        const p = self.params;
        const pinned = self.heldNode();
        var force: [N * N][2]f32 = undefined;
        for (0..N * N) |i| {
            const r = self.restOf(i);
            var fx = -p.spring * (self.pos[i][0] - r[0]);
            var fy = -p.spring * (self.pos[i][1] - r[1]);
            const gx = i % N;
            const gy = i / N;
            const neighbours = [4]?usize{
                if (gx > 0) i - 1 else null,
                if (gx + 1 < N) i + 1 else null,
                if (gy > 0) i - N else null,
                if (gy + 1 < N) i + N else null,
            };
            for (neighbours) |maybe| {
                const j = maybe orelse continue;
                const rj = self.restOf(j);
                fx -= p.neighbour * ((self.pos[i][0] - self.pos[j][0]) - (r[0] - rj[0]));
                fy -= p.neighbour * ((self.pos[i][1] - self.pos[j][1]) - (r[1] - rj[1]));
            }
            fx -= p.friction * self.vel[i][0];
            fy -= p.friction * self.vel[i][1];
            force[i] = .{ fx, fy };
        }
        for (0..N * N) |i| {
            if (pinned != null and pinned.? == i) {
                self.pos[i] = self.restOf(i);
                self.vel[i] = .{ 0, 0 };
                continue;
            }
            self.vel[i][0] += force[i][0] * dt;
            self.vel[i][1] += force[i][1] * dt;
            self.pos[i][0] += self.vel[i][0] * dt;
            self.pos[i][1] += self.vel[i][1] * dt;
            const r = self.restOf(i);
            self.pos[i][0] = std.math.clamp(self.pos[i][0], r[0] - p.max_stretch, r[0] + p.max_stretch);
            self.pos[i][1] = std.math.clamp(self.pos[i][1], r[1] - p.max_stretch, r[1] + p.max_stretch);
        }
    }

    /// Fills `warp` with each node's distance from its place.
    fn updateWarp(self: *Wobble) void {
        self.warp.x = self.rx;
        self.warp.y = self.ry;
        self.warp.w = self.rw;
        self.warp.h = self.rh;
        for (0..N * N) |i| {
            const r = self.restOf(i);
            self.warp.dx[i] = self.pos[i][0] - r[0];
            self.warp.dy[i] = self.pos[i][1] - r[1];
        }
    }

    /// At rest, and not held: nothing left to animate.
    pub fn settled(self: *const Wobble) bool {
        if (self.held != null) return false;
        for (0..N * N) |i| {
            const r = self.restOf(i);
            if (@abs(self.pos[i][0] - r[0]) > 0.3 or @abs(self.pos[i][1] - r[1]) > 0.3) return false;
            if (@abs(self.vel[i][0]) > 2 or @abs(self.vel[i][1]) > 2) return false;
        }
        return true;
    }
};

test "a window that is where it should be is settled" {
    var w = Wobble.init(10, 20, 400, 300);
    try std.testing.expect(w.settled());
    w.step(0.1);
    try std.testing.expect(w.settled());
}

test "moving the window makes the mesh lag, then it settles" {
    var w = Wobble.init(0, 0, 400, 300);
    w.setRest(300, 0, 400, 300);
    w.step(1.0 / 60.0);
    try std.testing.expect(!w.settled());
    // Right after the jump every node is behind its place (negative distance in x).
    try std.testing.expect(w.warp.dx[0] < -50);
    var t: f32 = 0;
    while (t < 6 and !w.settled()) : (t += 1.0 / 60.0) w.step(1.0 / 60.0);
    try std.testing.expect(w.settled());
}

test "the held node stays on the pointer while the rest trail" {
    var w = Wobble.init(0, 0, 400, 300);
    w.held = .{ 0.0, 0.0 };
    var x: f32 = 0;
    for (0..30) |_| {
        x += 20;
        w.setRest(x, 0, 400, 300);
        w.step(1.0 / 60.0);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0), w.warp.dx[0], 0.01);
    // The far corner trails behind the drag.
    try std.testing.expect(w.warp.dx[N * N - 1] < -10);
    w.held = null;
    var t: f32 = 0;
    while (t < 8 and !w.settled()) : (t += 1.0 / 60.0) w.step(1.0 / 60.0);
    try std.testing.expect(w.settled());
}

test "a hard shove is limited" {
    var w = Wobble.init(0, 0, 200, 200);
    w.setRest(5000, 0, 200, 200);
    w.step(0.05);
    for (w.warp.dx) |d| try std.testing.expect(d >= -w.params.max_stretch - 0.01);
}
