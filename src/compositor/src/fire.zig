//! Flames for the pointer, with no wlroots in them so they can be tested: a particle system that
//! throws sparks up from a point, which shrink and fade as they rise.

const std = @import("std");

pub const max_particles = 320;

pub const Particle = struct {
    x: f32,
    y: f32,
    vx: f32,
    vy: f32,
    /// Seconds lived, and how long it lives.
    age: f32,
    life: f32,
    size: f32,
};

pub const Fire = struct {
    particles: [max_particles]Particle = undefined,
    count: usize = 0,
    rng: std.Random.DefaultPrng,
    carry: f32 = 0,

    pub fn init(seed: u64) Fire {
        return .{ .rng = std.Random.DefaultPrng.init(seed) };
    }

    /// Moves everything on by `dt`, and when `emit` is set throws about 150 new sparks a second from (x, y).
    pub fn step(self: *Fire, dt: f32, emit: bool, x: f32, y: f32) void {
        const d = @min(dt, 0.1);
        var i: usize = 0;
        while (i < self.count) {
            var p = &self.particles[i];
            p.age += d;
            if (p.age >= p.life) {
                self.count -= 1;
                self.particles[i] = self.particles[self.count];
                continue;
            }
            p.x += p.vx * d;
            p.y += p.vy * d;
            p.vy -= 40 * d; // heat: they accelerate upward (y is down)
            i += 1;
        }
        if (!emit) {
            self.carry = 0;
            return;
        }
        self.carry += 150 * d;
        const r = self.rng.random();
        while (self.carry >= 1 and self.count < max_particles) : (self.carry -= 1) {
            self.particles[self.count] = .{
                .x = x + (r.float(f32) - 0.5) * 14,
                .y = y + (r.float(f32) - 0.5) * 6,
                .vx = (r.float(f32) - 0.5) * 50,
                .vy = -(60 + r.float(f32) * 90),
                .age = 0,
                .life = 0.5 + r.float(f32) * 0.6,
                .size = 10 + r.float(f32) * 12,
            };
            self.count += 1;
        }
        if (self.carry > 4) self.carry = 0;
    }

    /// 0 at birth, 1 at the end of its life.
    pub fn progress(p: Particle) f32 {
        return std.math.clamp(p.age / @max(p.life, 0.001), 0, 1);
    }
};

test "sparks rise, fade and are cleaned up" {
    var f = Fire.init(3);
    for (0..30) |_| f.step(1.0 / 60.0, true, 100, 200);
    try std.testing.expect(f.count > 20);
    for (f.particles[0..f.count]) |p| try std.testing.expect(p.y < 205);
    for (0..300) |_| f.step(1.0 / 60.0, false, 0, 0);
    try std.testing.expectEqual(@as(usize, 0), f.count);
}

test "the number of sparks is limited" {
    var f = Fire.init(1);
    for (0..500) |_| f.step(0.05, true, 0, 0);
    try std.testing.expect(f.count <= max_particles);
}
