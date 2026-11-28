// SPDX-License-Identifier: GPL-2.0-or-later
//! Outputs from `wlr-output-management-unstable-v1`: what is connected, its
//! modes, and requests to change mode, scale or power (spec 6.5). Heads are
//! announced and updated by the compositor; a change is applied as one
//! configuration that names every head.

const std = @import("std");
const wayland = @import("wayland");
const desktop = @import("core").desktop;

const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const log = std.log.scoped(.outputs);

const Mode = struct {
    handle: *zwlr.OutputModeV1,
    info: desktop.Mode = .{ .width = 0, .height = 0 },
};

const Head = struct {
    handle: *zwlr.OutputHeadV1,
    owner: *Outputs,
    name_buf: []u8 = &.{},
    desc_buf: []u8 = &.{},
    modes: std.ArrayList(*Mode) = .empty,
    current: ?*Mode = null,
    enabled: bool = false,
    x: i32 = 0,
    y: i32 = 0,
    scale: f64 = 1,
    finished: bool = false,
};

pub const Outputs = struct {
    allocator: std.mem.Allocator,
    manager: ?*zwlr.OutputManagerV1 = null,
    heads: std.ArrayList(*Head) = .empty,
    /// `heads` as the neutral API sees it, rebuilt on every `done`.
    list: std.ArrayList(desktop.Output) = .empty,
    mode_store: std.ArrayList(desktop.Mode) = .empty,
    serial: u32 = 0,
    on_change: *const fn (*anyopaque) void,
    on_change_data: *anyopaque,

    pub fn create(allocator: std.mem.Allocator, on_change: *const fn (*anyopaque) void, data: *anyopaque) ?*Outputs {
        const self = allocator.create(Outputs) catch return null;
        self.* = .{ .allocator = allocator, .on_change = on_change, .on_change_data = data };
        return self;
    }

    pub fn destroy(self: *Outputs) void {
        for (self.heads.items) |h| self.freeHead(h);
        self.heads.deinit(self.allocator);
        self.list.deinit(self.allocator);
        self.mode_store.deinit(self.allocator);
        if (self.manager) |m| m.destroy();
        self.allocator.destroy(self);
    }

    pub fn onGlobal(self: *Outputs, registry: *wl.Registry, global: anytype) void {
        if (std.mem.orderZ(u8, global.interface, zwlr.OutputManagerV1.interface.name) != .eq) return;
        const manager = registry.bind(global.name, zwlr.OutputManagerV1, @min(global.version, 4)) catch |err| {
            log.warn("cannot bind the output manager: {s}", .{@errorName(err)});
            return;
        };
        self.manager = manager;
        manager.setListener(*Outputs, managerEvent, self);
    }

    /// The name of the output with this id, for matching a capture.
    pub fn nameOf(self: *const Outputs, id: u64) ?[]const u8 {
        for (self.list.items) |o| if (o.id == id) return o.name;
        return null;
    }

    fn managerEvent(_: *zwlr.OutputManagerV1, event: zwlr.OutputManagerV1.Event, self: *Outputs) void {
        switch (event) {
            .head => |e| {
                const h = self.allocator.create(Head) catch return;
                h.* = .{ .handle = e.head, .owner = self };
                self.heads.append(self.allocator, h) catch {
                    self.allocator.destroy(h);
                    return;
                };
                e.head.setListener(*Head, headEvent, h);
            },
            .done => |e| {
                self.serial = e.serial;
                self.rebuild();
                self.on_change(self.on_change_data);
            },
            .finished => {},
        }
    }

    fn headEvent(_: *zwlr.OutputHeadV1, event: zwlr.OutputHeadV1.Event, h: *Head) void {
        const a = h.owner.allocator;
        switch (event) {
            .name => |e| replace(a, &h.name_buf, std.mem.span(e.name)),
            .description => |e| replace(a, &h.desc_buf, std.mem.span(e.description)),
            .mode => |e| {
                const m = a.create(Mode) catch return;
                m.* = .{ .handle = e.mode };
                h.modes.append(a, m) catch {
                    a.destroy(m);
                    return;
                };
                e.mode.setListener(*Mode, modeEvent, m);
            },
            .enabled => |e| h.enabled = e.enabled != 0,
            .current_mode => |e| {
                h.current = null;
                for (h.modes.items) |m| if (m.handle == e.mode) {
                    h.current = m;
                };
            },
            .position => |e| {
                h.x = e.x;
                h.y = e.y;
            },
            .scale => |e| h.scale = e.scale.toDouble(),
            .finished => h.finished = true,
            else => {},
        }
    }

    fn modeEvent(_: *zwlr.OutputModeV1, event: zwlr.OutputModeV1.Event, m: *Mode) void {
        switch (event) {
            .size => |e| {
                m.info.width = @intCast(@max(e.width, 0));
                m.info.height = @intCast(@max(e.height, 0));
            },
            .refresh => |e| m.info.refresh_mhz = @intCast(@max(e.refresh, 0)),
            .preferred => m.info.preferred = true,
            .finished => {},
        }
    }

    /// Drops finished heads and rebuilds the neutral list.
    fn rebuild(self: *Outputs) void {
        var i: usize = 0;
        while (i < self.heads.items.len) {
            if (self.heads.items[i].finished) self.freeHead(self.heads.orderedRemove(i)) else i += 1;
        }
        self.list.clearRetainingCapacity();
        self.mode_store.clearRetainingCapacity();
        // The mode store must not move while slices into it are handed out,
        // so size it first.
        var total: usize = 0;
        for (self.heads.items) |h| total += h.modes.items.len;
        self.mode_store.ensureTotalCapacity(self.allocator, total) catch return;
        for (self.heads.items) |h| {
            const start = self.mode_store.items.len;
            for (h.modes.items) |m| {
                var info = m.info;
                info.current = h.current == m;
                self.mode_store.appendAssumeCapacity(info);
            }
            const cur = if (h.current) |c| c.info else desktop.Mode{ .width = 0, .height = 0 };
            self.list.append(self.allocator, .{
                .id = @intFromPtr(h),
                .name = h.name_buf,
                .description = h.desc_buf,
                .width = if (h.enabled) cur.width else 0,
                .height = if (h.enabled) cur.height else 0,
                .refresh_mhz = if (h.enabled) cur.refresh_mhz else 0,
                .scale = @floatCast(h.scale),
                .enabled = h.enabled,
                .x = h.x,
                .y = h.y,
                .modes = self.mode_store.items[start..][0..h.modes.items.len],
            }) catch return;
        }
    }

    fn freeHead(self: *Outputs, h: *Head) void {
        const a = self.allocator;
        for (h.modes.items) |m| {
            m.handle.release();
            a.destroy(m);
        }
        h.modes.deinit(a);
        h.handle.release();
        a.free(h.name_buf);
        a.free(h.desc_buf);
        a.destroy(h);
    }

    const Pending = struct {
        outputs: *Outputs,
        config: *zwlr.OutputConfigurationV1,
        done: desktop.ConfigDone,
        ctx: ?*anyopaque,
    };

    /// Applies the edits as one configuration; heads not named keep their state.
    pub fn configure(self: *Outputs, edits: []const desktop.OutputEdit, done: desktop.ConfigDone, ctx: ?*anyopaque) void {
        const manager = self.manager orelse return done(ctx, false);
        for (edits) |e| if (self.headById(e.id) == null) return done(ctx, false);

        const config = manager.createConfiguration(self.serial) catch return done(ctx, false);
        const pending = self.allocator.create(Pending) catch {
            config.destroy();
            return done(ctx, false);
        };
        pending.* = .{ .outputs = self, .config = config, .done = done, .ctx = ctx };

        for (self.heads.items) |h| {
            var change: desktop.OutputChange = .{};
            for (edits) |e| if (e.id == @intFromPtr(h)) {
                change = e.change;
            };
            const enabled = change.enabled orelse h.enabled;
            if (!enabled) {
                config.disableHead(h.handle);
                continue;
            }
            const ch = config.enableHead(h.handle) catch return fail(pending);
            if (change.mode) |want| {
                if (findMode(h, want)) |m| ch.setMode(m.handle) else return fail(pending);
            }
            if (change.scale) |sc| ch.setScale(wl.Fixed.fromDouble(sc));
            if (change.x != null or change.y != null) ch.setPosition(change.x orelse h.x, change.y orelse h.y);
        }
        config.setListener(*Pending, configEvent, pending);
        config.apply();
    }

    fn headById(self: *Outputs, id: u64) ?*Head {
        for (self.heads.items) |h| if (@intFromPtr(h) == id) return h;
        return null;
    }

    fn fail(p: *Pending) void {
        p.config.destroy();
        const done = p.done;
        const ctx = p.ctx;
        p.outputs.allocator.destroy(p);
        done(ctx, false);
    }

    fn findMode(h: *Head, want: desktop.Mode) ?*Mode {
        // Exact refresh when given, otherwise the best refresh at that size.
        var best: ?*Mode = null;
        for (h.modes.items) |m| {
            if (m.info.width != want.width or m.info.height != want.height) continue;
            if (want.refresh_mhz != 0 and m.info.refresh_mhz == want.refresh_mhz) return m;
            if (best == null or m.info.refresh_mhz > best.?.info.refresh_mhz) best = m;
        }
        return if (want.refresh_mhz == 0) best else null;
    }

    fn configEvent(_: *zwlr.OutputConfigurationV1, event: zwlr.OutputConfigurationV1.Event, p: *Pending) void {
        const ok = event == .succeeded;
        p.config.destroy();
        const done = p.done;
        const ctx = p.ctx;
        p.outputs.allocator.destroy(p);
        done(ctx, ok);
    }
};

fn replace(allocator: std.mem.Allocator, field: *[]u8, value: []const u8) void {
    const copy = allocator.dupe(u8, value) catch return;
    allocator.free(field.*);
    field.* = copy;
}
