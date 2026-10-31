//! Window list from `wlr-foreign-toplevel-management-unstable-v1` (SPEC.md 5.1).
//!
//! The protocol runs on the `wl_display` GDK already owns, so GDK's event
//! loop dispatches it. Windows that existed before the panel started are
//! announced by the compositor as soon as the manager is bound.

const std = @import("std");
const gdk = @import("gdk4");
const gdkwayland = @import("gdkwayland4");
const gobject = @import("gobject2");
const wayland = @import("wayland");
const glib = @import("glib2");
const build_options = @import("build_options");

const x11 = if (build_options.x11) @import("x11.zig") else struct {};
const surface = @import("surface.zig");

const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const log = std.log.scoped(.toplevels);

pub const Toplevel = struct {
    handle: *zwlr.ForeignToplevelHandleV1,
    manager: *Manager,
    title: []u8 = &.{},
    app_id: []u8 = &.{},
    maximized: bool = false,
    minimized: bool = false,
    activated: bool = false,
    /// Set by the first `done`; before it the window is not shown.
    ready: bool = false,
    /// The X window id when this entry comes from X11 (then `handle` is unused).
    x11_id: c_ulong = 0,

    pub fn activate(self: *Toplevel) void {
        if (build_options.x11 and self.x11_id != 0) return x11.activate(self.x11_id);
        if (self.minimized) self.handle.unsetMinimized();
        if (self.manager.seat) |seat| self.handle.activate(seat);
    }

    pub fn setMinimized(self: *Toplevel, minimized: bool) void {
        if (build_options.x11 and self.x11_id != 0) return x11.setMinimized(self.x11_id, minimized);
        if (minimized) self.handle.setMinimized() else self.handle.unsetMinimized();
    }

    pub fn setMaximized(self: *Toplevel, maximized: bool) void {
        if (build_options.x11 and self.x11_id != 0) return x11.setMaximized(self.x11_id, maximized);
        if (maximized) self.handle.setMaximized() else self.handle.unsetMaximized();
    }

    pub fn close(self: *Toplevel) void {
        if (build_options.x11 and self.x11_id != 0) return x11.close(self.x11_id);
        self.handle.close();
    }
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    registry: ?*wl.Registry = null,
    /// X11 only: polls the window manager's client list.
    x11_timer: c_uint = 0,
    seat: ?*wl.Seat = null,
    toplevels: std.ArrayList(*Toplevel) = .empty,
    /// Called after any change to the list or to a toplevel.
    on_change: *const fn (*anyopaque) void,
    on_change_data: *anyopaque,

    /// Connects to the compositor. Returns null (and logs) when the
    /// compositor lacks the protocol.
    pub fn create(allocator: std.mem.Allocator, on_change: *const fn (*anyopaque) void, data: *anyopaque) !?*Manager {
        if (surface.isX11()) return createX11(allocator, on_change, data);
        const display = gdk.Display.getDefault() orelse return null;
        if (gobject.typeCheckInstanceIsA(@ptrCast(@alignCast(display)), gdkwayland.WaylandDisplay.getGObjectType()) == 0) {
            log.warn("not running on Wayland; no taskbar", .{});
            return null;
        }
        const wl_display: *wl.Display = @ptrCast(gdkwayland.WaylandDisplay.getWlDisplay(@ptrCast(display)) orelse return null);

        const self = try allocator.create(Manager);
        self.* = .{
            .allocator = allocator,
            .registry = try wl_display.getRegistry(),
            .on_change = on_change,
            .on_change_data = data,
        };

        if (display.getDefaultSeat()) |seat| {
            self.seat = @ptrCast(@alignCast(gdkwayland.WaylandSeat.getWlSeat(@ptrCast(seat))));
        }
        self.registry.?.setListener(*Manager, registryEvent, self);
        return self;
    }

    pub fn destroy(self: *Manager) void {
        for (self.toplevels.items) |t| self.free(t);
        self.toplevels.deinit(self.allocator);
        if (self.x11_timer != 0) _ = glib.Source.remove(self.x11_timer);
        if (self.registry) |r| r.destroy();
        self.allocator.destroy(self);
    }

    fn registryEvent(registry: *wl.Registry, event: wl.Registry.Event, self: *Manager) void {
        switch (event) {
            .global => |global| {
                if (std.mem.orderZ(u8, global.interface, zwlr.ForeignToplevelManagerV1.interface.name) != .eq) return;
                const manager = registry.bind(global.name, zwlr.ForeignToplevelManagerV1, @min(global.version, 3)) catch |err| {
                    log.warn("cannot bind foreign-toplevel manager: {s}", .{@errorName(err)});
                    return;
                };
                manager.setListener(*Manager, managerEvent, self);
            },
            .global_remove => {},
        }
    }

    fn managerEvent(_: *zwlr.ForeignToplevelManagerV1, event: zwlr.ForeignToplevelManagerV1.Event, self: *Manager) void {
        switch (event) {
            .toplevel => |e| {
                const t = self.allocator.create(Toplevel) catch return;
                t.* = .{ .handle = e.toplevel, .manager = self };
                self.toplevels.append(self.allocator, t) catch {
                    self.allocator.destroy(t);
                    return;
                };
                e.toplevel.setListener(*Toplevel, toplevelEvent, t);
            },
            .finished => {},
        }
    }

    fn toplevelEvent(_: *zwlr.ForeignToplevelHandleV1, event: zwlr.ForeignToplevelHandleV1.Event, t: *Toplevel) void {
        const self = t.manager;
        switch (event) {
            .title => |e| replace(self.allocator, &t.title, std.mem.span(e.title)),
            .app_id => |e| replace(self.allocator, &t.app_id, std.mem.span(e.app_id)),
            .state => |e| {
                t.maximized = false;
                t.minimized = false;
                t.activated = false;
                for (std.mem.bytesAsSlice(u32, e.state.slice(u8))) |state| {
                    switch (@as(zwlr.ForeignToplevelHandleV1.State, @fromBackingInt(@intCast(state)))) {
                        .maximized => t.maximized = true,
                        .minimized => t.minimized = true,
                        .activated => t.activated = true,
                        else => {},
                    }
                }
            },
            // Batched changes take effect on `done`.
            .done => {
                t.ready = true;
                self.on_change(self.on_change_data);
            },
            .closed => {
                for (self.toplevels.items, 0..) |item, i| {
                    if (item == t) {
                        _ = self.toplevels.orderedRemove(i);
                        break;
                    }
                }
                self.free(t);
                self.on_change(self.on_change_data);
            },
            .output_enter, .output_leave, .parent => {},
        }
    }

    fn free(self: *Manager, t: *Toplevel) void {
        if (t.x11_id == 0) t.handle.destroy();
        self.allocator.free(t.title);
        self.allocator.free(t.app_id);
        self.allocator.destroy(t);
    }
};

fn replace(allocator: std.mem.Allocator, field: *[]u8, value: []const u8) void {
    const copy = allocator.dupe(u8, value) catch return;
    allocator.free(field.*);
    field.* = copy;
}

// ---- X11: the same list, read from the window manager --------------------------

fn createX11(allocator: std.mem.Allocator, on_change: *const fn (*anyopaque) void, data: *anyopaque) !?*Manager {
    if (!build_options.x11) return null;
    const self = try allocator.create(Manager);
    self.* = .{ .allocator = allocator, .on_change = on_change, .on_change_data = data };
    syncX11(self);
    // Polling keeps the X code simple; a few hundred ms is imperceptible here.
    self.x11_timer = glib.timeoutAdd(400, onX11Tick, self);
    return self;
}

fn onX11Tick(data: ?*anyopaque) callconv(.c) c_int {
    const self: *Manager = @ptrCast(@alignCast(data.?));
    syncX11(self);
    return 1;
}

fn differs(a: []const u8, b: []const u8) bool {
    return !std.mem.eql(u8, a, b);
}

pub fn syncX11(self: *Manager) void {
    if (!build_options.x11) return;
    const infos = x11.snapshot(self.allocator) catch return;
    defer x11.freeInfos(self.allocator, infos);
    var changed = false;

    for (infos) |info| {
        var found: ?*Toplevel = null;
        for (self.toplevels.items) |t| if (t.x11_id == info.id) {
            found = t;
            break;
        };
        const t = found orelse blk: {
            const created = self.allocator.create(Toplevel) catch continue;
            created.* = .{ .handle = undefined, .manager = self, .x11_id = info.id, .ready = true };
            self.toplevels.append(self.allocator, created) catch {
                self.allocator.destroy(created);
                continue;
            };
            changed = true;
            break :blk created;
        };
        if (differs(t.title, info.title)) {
            replace(self.allocator, &t.title, info.title);
            changed = true;
        }
        if (differs(t.app_id, info.app_id)) {
            replace(self.allocator, &t.app_id, info.app_id);
            changed = true;
        }
        if (t.maximized != info.maximized or t.minimized != info.minimized or t.activated != info.activated) changed = true;
        t.maximized = info.maximized;
        t.minimized = info.minimized;
        t.activated = info.activated;
    }

    // Windows the manager no longer lists have closed.
    var i = self.toplevels.items.len;
    while (i > 0) {
        i -= 1;
        const t = self.toplevels.items[i];
        if (t.x11_id == 0) continue;
        var alive = false;
        for (infos) |info| if (info.id == t.x11_id) {
            alive = true;
            break;
        };
        if (alive) continue;
        _ = self.toplevels.orderedRemove(i);
        self.free(t);
        changed = true;
    }
    if (changed) self.on_change(self.on_change_data);
}
