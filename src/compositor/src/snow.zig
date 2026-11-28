// SPDX-License-Identifier: GPL-2.0-or-later
//! Falling snow for the desktop, with no wlroots in it so it can be tested: a fixed number of flakes
//! that drift down the screen and come back at the top.

const std = @import("std");

pub const max_flakes = 240;

pub const Flake = struct {
    x: f32,
    y: f32,
    /// Fall speed and sideways drift, in pixels per second.
    vy: f32,
    vx: f32,
    /// Radius in pixels, and the phase of its sway.
    r: f32,
    phase: f32,
};

pub const Snow = struct {
    flakes: [max_flakes]Flake = undefined,
    count: usize = 0,
    time: f32 = 0,
    rng: std.Random.DefaultPrng,

    pub fn init(w: f32, h: f32, count: usize, seed: u64) Snow {
        var s: Snow = .{ .rng = std.Random.DefaultPrng.init(seed) };
        s.count = @min(count, max_flakes);
        for (0..s.count) |i| {
            s.flakes[i] = s.make(w, h, true);
        }
        return s;
    }

    fn make(self: *Snow, w: f32, h: f32, anywhere: bool) Flake {
        const r = self.rng.random();
        const size = 1.5 + r.float(f32) * 3.5;
        return .{
            .x = r.float(f32) * w,
            .y = if (anywhere) r.float(f32) * h else -size * 2,
            // Bigger flakes are nearer: they fall faster.
            .vy = 30 + size * 14 + r.float(f32) * 25,
            .vx = (r.float(f32) - 0.5) * 24,
            .r = size,
            .phase = r.float(f32) * 6.28,
        };
    }

    pub fn step(self: *Snow, dt: f32, w: f32, h: f32) void {
        const d = @min(dt, 0.1);
        self.time += d;
        for (0..self.count) |i| {
            var f = &self.flakes[i];
            f.y += f.vy * d;
            f.x += (f.vx + @sin(self.time * 0.9 + f.phase) * 14) * d;
            if (f.x < -10) f.x += w + 20;
            if (f.x > w + 10) f.x -= w + 20;
            if (f.y > h + f.r * 2) f.* = self.make(w, h, false);
        }
    }
};

test "flakes stay on the screen's columns and keep falling" {
    var s = Snow.init(1280, 720, 100, 7);
    try std.testing.expectEqual(@as(usize, 100), s.count);
    for (0..600) |_| s.step(1.0 / 60.0, 1280, 720);
    for (s.flakes[0..s.count]) |f| {
        try std.testing.expect(f.x >= -12 and f.x <= 1292);
        try std.testing.expect(f.y >= -20 and f.y <= 740);
    }
}

test "a flake that falls off the bottom comes back at the top" {
    var s = Snow.init(100, 100, 1, 1);
    s.flakes[0].y = 99;
    s.flakes[0].vy = 5000;
    s.step(0.1, 100, 100);
    try std.testing.expect(s.flakes[0].y < 0);
}

test "the count is limited" {
    const s = Snow.init(100, 100, 100000, 1);
    try std.testing.expectEqual(@as(usize, max_flakes), s.count);
}
