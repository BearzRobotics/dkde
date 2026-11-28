// SPDX-License-Identifier: GPL-2.0-or-later
//! Screen capture through `wlr-screencopy-unstable-v1` (spec 6.4). Only whole
//! outputs: the protocol has no per-window capture, so that capability is not
//! claimed.

const std = @import("std");
const wayland = @import("wayland");
const core = @import("core");

const desktop = core.desktop;
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const log = std.log.scoped(.capture);

extern fn memfd_create(name: [*:0]const u8, flags: c_uint) c_int;
extern fn ftruncate(fd: c_int, length: c_long) c_int;
extern fn mmap(addr: ?*anyopaque, length: usize, prot: c_int, flags: c_int, fd: c_int, offset: c_long) ?*anyopaque;
extern fn munmap(addr: *anyopaque, length: usize) c_int;
extern fn close(fd: c_int) c_int;
const PROT_READ_WRITE = 3;
const MAP_SHARED = 1;

const OutputRef = struct {
    output: *wl.Output,
    name: []u8 = &.{},
};

pub const Capturer = struct {
    allocator: std.mem.Allocator,
    manager: ?*zwlr.ScreencopyManagerV1 = null,
    shm: ?*wl.Shm = null,
    outputs: std.ArrayList(*OutputRef) = .empty,

    pub fn create(allocator: std.mem.Allocator) !*Capturer {
        const self = try allocator.create(Capturer);
        self.* = .{ .allocator = allocator };
        return self;
    }

    pub fn destroy(self: *Capturer) void {
        for (self.outputs.items) |o| {
            o.output.release();
            self.allocator.free(o.name);
            self.allocator.destroy(o);
        }
        self.outputs.deinit(self.allocator);
        if (self.manager) |m| m.destroy();
        self.allocator.destroy(self);
    }

    /// Whether the compositor can capture (needs the manager and shm).
    pub fn available(self: *const Capturer) bool {
        return self.manager != null and self.shm != null and self.outputs.items.len > 0;
    }

    pub fn onGlobal(self: *Capturer, registry: *wl.Registry, g: anytype) void {
        const name = std.mem.span(g.interface);
        if (std.mem.eql(u8, name, std.mem.span(zwlr.ScreencopyManagerV1.interface.name))) {
            self.manager = registry.bind(g.name, zwlr.ScreencopyManagerV1, @min(g.version, 3)) catch null;
        } else if (std.mem.eql(u8, name, std.mem.span(wl.Shm.interface.name))) {
            self.shm = registry.bind(g.name, wl.Shm, 1) catch null;
        } else if (std.mem.eql(u8, name, std.mem.span(wl.Output.interface.name))) {
            const ref = self.allocator.create(OutputRef) catch return;
            // Version 4 announces the connector name, which is how outputs
            // from output management are matched with these.
            const out = registry.bind(g.name, wl.Output, @min(g.version, 4)) catch {
                self.allocator.destroy(ref);
                return;
            };
            ref.* = .{ .output = out };
            self.outputs.append(self.allocator, ref) catch {
                out.release();
                self.allocator.destroy(ref);
                return;
            };
            out.setListener(*OutputRef, outputEvent, ref);
        }
    }

    fn outputEvent(_: *wl.Output, event: wl.Output.Event, ref: *OutputRef) void {
        switch (event) {
            .name => |e| {
                // Called on the registry's own allocator-free path: keep a copy.
                const a = std.heap.c_allocator;
                const copy = a.dupe(u8, std.mem.span(e.name)) catch return;
                a.free(ref.name);
                ref.name = copy;
            },
            else => {},
        }
    }

    fn find(self: *Capturer, name: ?[]const u8) ?*wl.Output {
        if (self.outputs.items.len == 0) return null;
        const n = name orelse return self.outputs.items[0].output;
        for (self.outputs.items) |o| if (std.mem.eql(u8, o.name, n)) return o.output;
        return null;
    }

    /// Starts a capture of the output called `name` (the first when null).
    pub fn start(self: *Capturer, allocator: std.mem.Allocator, name: ?[]const u8, done: desktop.CaptureDone, ctx: ?*anyopaque) void {
        const manager = self.manager orelse return done(ctx, error.Unsupported);
        if (self.shm == null) return done(ctx, error.Unsupported);
        const output = self.find(name) orelse return done(ctx, error.CaptureFailed);
        const frame = manager.captureOutput(0, output) catch return done(ctx, error.CaptureFailed);
        const cap = allocator.create(Frame) catch {
            frame.destroy();
            return done(ctx, error.OutOfMemory);
        };
        cap.* = .{ .capturer = self, .allocator = allocator, .frame = frame, .done = done, .ctx = ctx };
        frame.setListener(*Frame, Frame.onEvent, cap);
    }
};

/// One screencopy request in flight.
const Frame = struct {
    capturer: *Capturer,
    allocator: std.mem.Allocator,
    frame: *zwlr.ScreencopyFrameV1,
    done: desktop.CaptureDone,
    ctx: ?*anyopaque,
    format: wl.Shm.Format = .argb8888,
    width: u32 = 0,
    height: u32 = 0,
    stride: u32 = 0,
    y_invert: bool = false,
    map: ?[*]u8 = null,
    size: usize = 0,
    buffer: ?*wl.Buffer = null,

    fn onEvent(_: *zwlr.ScreencopyFrameV1, event: zwlr.ScreencopyFrameV1.Event, self: *Frame) void {
        switch (event) {
            .buffer => |b| {
                self.format = b.format;
                self.width = b.width;
                self.height = b.height;
                self.stride = b.stride;
            },
            .flags => |f| self.y_invert = f.flags.y_invert,
            // Version 3 announces every buffer type, then says it is done.
            .buffer_done => self.copy(),
            .ready => self.ready(),
            .failed => self.finish(error.CaptureFailed),
            .damage, .linux_dmabuf => {},
        }
    }

    fn copy(self: *Frame) void {
        self.size = @as(usize, self.stride) * self.height;
        const fd = memfd_create("dkde-capture", 0);
        if (fd < 0 or ftruncate(fd, @intCast(self.size)) != 0) {
            if (fd >= 0) _ = close(fd);
            return self.finish(error.CaptureFailed);
        }
        defer _ = close(fd);
        const mapped = mmap(null, self.size, PROT_READ_WRITE, MAP_SHARED, fd, 0) orelse return self.finish(error.CaptureFailed);
        if (@intFromPtr(mapped) == std.math.maxInt(usize)) return self.finish(error.CaptureFailed);
        self.map = @ptrCast(mapped);

        const pool = self.capturer.shm.?.createPool(fd, @intCast(self.size)) catch return self.finish(error.CaptureFailed);
        defer pool.destroy();
        self.buffer = pool.createBuffer(0, @intCast(self.width), @intCast(self.height), @intCast(self.stride), self.format) catch return self.finish(error.CaptureFailed);
        self.frame.copy(self.buffer.?);
    }

    fn ready(self: *Frame) void {
        const layout: core.pixels.Layout = switch (self.format) {
            .argb8888, .xrgb8888 => .bgra,
            .abgr8888, .xbgr8888 => .rgba,
            else => {
                log.warn("unsupported pixel format {s}", .{@tagName(self.format)});
                return self.finish(error.BadFormat);
            },
        };
        const w: usize = self.width;
        const h: usize = self.height;
        const rgba = self.allocator.alloc(u8, w * h * 4) catch return self.finish(error.OutOfMemory);
        core.pixels.toRgba(rgba, self.map.?[0..self.size], w, h, self.stride, layout, self.y_invert);
        self.finish(.{ .width = self.width, .height = self.height, .rgba = rgba });
    }

    /// Reports the result once and frees the request.
    fn finish(self: *Frame, result: desktop.Error!desktop.Image) void {
        const done = self.done;
        const ctx = self.ctx;
        if (self.buffer) |b| b.destroy();
        if (self.map) |m| _ = munmap(@ptrCast(m), self.size);
        self.frame.destroy();
        self.allocator.destroy(self);
        done(ctx, result);
    }
};
