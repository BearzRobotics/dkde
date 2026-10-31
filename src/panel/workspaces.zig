//! Virtual desktops (SPEC.md 5.1), from `ext-workspace-v1`, which labwc offers.
//! The panel lists the workspaces and asks the compositor to switch; the
//! number of desktops is labwc's `<desktops><number>` setting.

const std = @import("std");
const gdk = @import("gdk4");
const gdkwayland = @import("gdkwayland4");
const gobject = @import("gobject2");
const wayland = @import("wayland");

const surface = @import("surface.zig");

const wl = wayland.client.wl;
const ext = wayland.client.ext;

const log = std.log.scoped(.workspaces);

pub const Workspace = struct {
    handle: *ext.WorkspaceHandleV1,
    owner: *Workspaces,
    name: []u8 = &.{},
    active: bool = false,
    urgent: bool = false,
    removed: bool = false,
};

pub const Workspaces = struct {
    allocator: std.mem.Allocator,
    manager: ?*ext.WorkspaceManagerV1 = null,
    registry: ?*wl.Registry = null,
    list: std.ArrayList(*Workspace) = .empty,
    on_change: *const fn (*anyopaque) void,
    on_change_data: *anyopaque,

    /// Null when not on Wayland or when the compositor has no workspaces.
    pub fn create(allocator: std.mem.Allocator, on_change: *const fn (*anyopaque) void, data: *anyopaque) ?*Workspaces {
        if (surface.isX11()) return null;
        const display = gdk.Display.getDefault() orelse return null;
        if (gobject.typeCheckInstanceIsA(@ptrCast(@alignCast(display)), gdkwayland.WaylandDisplay.getGObjectType()) == 0) return null;
        const wl_display: *wl.Display = @ptrCast(gdkwayland.WaylandDisplay.getWlDisplay(@ptrCast(display)) orelse return null);

        const self = allocator.create(Workspaces) catch return null;
        self.* = .{ .allocator = allocator, .on_change = on_change, .on_change_data = data };
        self.registry = wl_display.getRegistry() catch {
            allocator.destroy(self);
            return null;
        };
        self.registry.?.setListener(*Workspaces, registryEvent, self);
        return self;
    }

    pub fn destroy(self: *Workspaces) void {
        for (self.list.items) |w| self.free(w);
        self.list.deinit(self.allocator);
        if (self.manager) |m| m.destroy();
        if (self.registry) |r| r.destroy();
        self.allocator.destroy(self);
    }

    /// Switches to the workspace at `index` (in the compositor's order).
    pub fn activate(self: *Workspaces, index: usize) void {
        const manager = self.manager orelse return;
        if (index >= self.list.items.len) return;
        self.list.items[index].handle.activate();
        manager.commit();
    }

    pub fn activeIndex(self: *const Workspaces) ?usize {
        for (self.list.items, 0..) |w, i| if (w.active) return i;
        return null;
    }

    fn registryEvent(registry: *wl.Registry, event: wl.Registry.Event, self: *Workspaces) void {
        switch (event) {
            .global => |global| {
                if (std.mem.orderZ(u8, global.interface, ext.WorkspaceManagerV1.interface.name) != .eq) return;
                const manager = registry.bind(global.name, ext.WorkspaceManagerV1, 1) catch |err| {
                    log.warn("cannot bind the workspace manager: {s}", .{@errorName(err)});
                    return;
                };
                self.manager = manager;
                manager.setListener(*Workspaces, managerEvent, self);
            },
            .global_remove => {},
        }
    }

    fn managerEvent(_: *ext.WorkspaceManagerV1, event: ext.WorkspaceManagerV1.Event, self: *Workspaces) void {
        switch (event) {
            .workspace => |e| {
                const w = self.allocator.create(Workspace) catch return;
                w.* = .{ .handle = e.workspace, .owner = self };
                self.list.append(self.allocator, w) catch {
                    self.allocator.destroy(w);
                    return;
                };
                e.workspace.setListener(*Workspace, workspaceEvent, w);
            },
            .workspace_group => {},
            // Batched changes take effect on `done`.
            .done => {
                var i: usize = 0;
                while (i < self.list.items.len) {
                    if (self.list.items[i].removed) {
                        self.free(self.list.orderedRemove(i));
                    } else i += 1;
                }
                self.on_change(self.on_change_data);
            },
            .finished => {},
        }
    }

    fn workspaceEvent(_: *ext.WorkspaceHandleV1, event: ext.WorkspaceHandleV1.Event, w: *Workspace) void {
        switch (event) {
            .name => |e| {
                const copy = w.owner.allocator.dupe(u8, std.mem.span(e.name)) catch return;
                w.owner.allocator.free(w.name);
                w.name = copy;
            },
            .state => |e| {
                w.active = e.state.active;
                w.urgent = e.state.urgent;
            },
            .removed => w.removed = true,
            .id, .coordinates, .capabilities => {},
        }
    }

    fn free(self: *Workspaces, w: *Workspace) void {
        w.handle.destroy();
        self.allocator.free(w.name);
        self.allocator.destroy(w);
    }
};
