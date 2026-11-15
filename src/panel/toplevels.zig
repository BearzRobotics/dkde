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
const common = @import("common");
const desktop = common.desktop;

const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const log = std.log.scoped(.toplevels);

/// One window announced by the compositor. `win` is what the rest of the
/// panel sees; the protocol handle stays here.
pub const Toplevel = struct {
    win: desktop.Window = .{ .ops = &ops },
    handle: *zwlr.ForeignToplevelHandleV1,
    manager: *Manager,
    title_buf: []u8 = &.{},
    app_id_buf: []u8 = &.{},

    const ops: desktop.WindowOps = .{
        .activate = opActivate,
        .set_minimized = opMinimized,
        .set_maximized = opMaximized,
        .close = opClose,
    };

    fn of(w: *desktop.Window) *Toplevel {
        return @fieldParentPtr("win", w);
    }
    fn opActivate(w: *desktop.Window) void {
        const t = of(w);
        if (t.manager.seat) |seat| t.handle.activate(seat);
    }
    fn opMinimized(w: *desktop.Window, minimized: bool) void {
        if (minimized) of(w).handle.setMinimized() else of(w).handle.unsetMinimized();
    }
    fn opMaximized(w: *desktop.Window, maximized: bool) void {
        if (maximized) of(w).handle.setMaximized() else of(w).handle.unsetMaximized();
    }
    fn opClose(w: *desktop.Window) void {
        of(w).handle.close();
    }
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    registry: ?*wl.Registry = null,
    seat: ?*wl.Seat = null,
    /// The windows in the order announced; what `desktop.Window` consumers see.
    windows: std.ArrayList(*desktop.Window) = .empty,
    /// Called after any change to the list or to a toplevel.
    on_change: *const fn (*anyopaque) void,
    on_change_data: *anyopaque,

    /// Connects to the compositor. Returns null (and logs) when the
    /// compositor lacks the protocol.
    pub fn create(allocator: std.mem.Allocator, on_change: *const fn (*anyopaque) void, data: *anyopaque) !?*Manager {
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
        for (self.windows.items) |w| self.free(Toplevel.of(w));
        self.windows.deinit(self.allocator);
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
                self.windows.append(self.allocator, &t.win) catch {
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
            .title => |e| {
                replace(self.allocator, &t.title_buf, std.mem.span(e.title));
                t.win.title = t.title_buf;
            },
            .app_id => |e| {
                replace(self.allocator, &t.app_id_buf, std.mem.span(e.app_id));
                t.win.app_id = t.app_id_buf;
            },
            .state => |e| {
                t.win.maximized = false;
                t.win.minimized = false;
                t.win.activated = false;
                t.win.fullscreen = false;
                for (std.mem.bytesAsSlice(u32, e.state.slice(u8))) |state| {
                    switch (@as(zwlr.ForeignToplevelHandleV1.State, @fromBackingInt(@intCast(state)))) {
                        .maximized => t.win.maximized = true,
                        .minimized => t.win.minimized = true,
                        .activated => t.win.activated = true,
                        .fullscreen => t.win.fullscreen = true,
                        else => {},
                    }
                }
            },
            // Batched changes take effect on `done`.
            .done => {
                t.win.ready = true;
                self.on_change(self.on_change_data);
            },
            .closed => {
                for (self.windows.items, 0..) |item, i| {
                    if (item == &t.win) {
                        _ = self.windows.orderedRemove(i);
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
        t.handle.destroy();
        self.allocator.free(t.title_buf);
        self.allocator.free(t.app_id_buf);
        self.allocator.destroy(t);
    }
};

fn replace(allocator: std.mem.Allocator, field: *[]u8, value: []const u8) void {
    const copy = allocator.dupe(u8, value) catch return;
    allocator.free(field.*);
    field.* = copy;
}
