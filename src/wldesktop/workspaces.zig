// SPDX-License-Identifier: GPL-2.0-or-later
//! Virtual desktops (SPEC.md 5.1), from `ext-workspace-v1`, which labwc offers.
//! The panel lists the workspaces and asks the compositor to switch; the
//! number of desktops is labwc's `<desktops><number>` setting.

const std = @import("std");
const wayland = @import("wayland");

const desktop = @import("core").desktop;

const wl = wayland.client.wl;
const ext = wayland.client.ext;

const log = std.log.scoped(.workspaces);

pub const Workspace = struct {
    handle: *ext.WorkspaceHandleV1,
    owner: *Workspaces,
    info: desktop.Workspace = .{},
    name_buf: []u8 = &.{},
    removed: bool = false,
};

pub const Workspaces = struct {
    allocator: std.mem.Allocator,
    manager: ?*ext.WorkspaceManagerV1 = null,
    list: std.ArrayList(*Workspace) = .empty,
    /// `list` as the neutral API sees it, rebuilt on every `done`.
    infos: std.ArrayList(*const desktop.Workspace) = .empty,
    on_change: *const fn (*anyopaque) void,
    on_change_data: *anyopaque,

    pub fn create(allocator: std.mem.Allocator, on_change: *const fn (*anyopaque) void, data: *anyopaque) ?*Workspaces {
        const self = allocator.create(Workspaces) catch return null;
        self.* = .{ .allocator = allocator, .on_change = on_change, .on_change_data = data };
        return self;
    }

    pub fn destroy(self: *Workspaces) void {
        for (self.list.items) |w| self.free(w);
        self.list.deinit(self.allocator);
        self.infos.deinit(self.allocator);
        if (self.manager) |m| m.destroy();
        self.allocator.destroy(self);
    }

    /// Switches to the workspace at `index` (in the compositor's order).
    pub fn activate(self: *Workspaces, index: usize) void {
        const manager = self.manager orelse return;
        if (index >= self.list.items.len) return;
        self.list.items[index].handle.activate();
        manager.commit();
    }

    pub fn onGlobal(self: *Workspaces, registry: *wl.Registry, global: anytype) void {
        if (std.mem.orderZ(u8, global.interface, ext.WorkspaceManagerV1.interface.name) != .eq) return;
        const manager = registry.bind(global.name, ext.WorkspaceManagerV1, 1) catch |err| {
            log.warn("cannot bind the workspace manager: {s}", .{@errorName(err)});
            return;
        };
        self.manager = manager;
        manager.setListener(*Workspaces, managerEvent, self);
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
                self.infos.clearRetainingCapacity();
                for (self.list.items) |w| self.infos.append(self.allocator, &w.info) catch {};
                self.on_change(self.on_change_data);
            },
            .finished => {},
        }
    }

    fn workspaceEvent(_: *ext.WorkspaceHandleV1, event: ext.WorkspaceHandleV1.Event, w: *Workspace) void {
        switch (event) {
            .name => |e| {
                const copy = w.owner.allocator.dupe(u8, std.mem.span(e.name)) catch return;
                w.owner.allocator.free(w.name_buf);
                w.name_buf = copy;
                w.info.name = copy;
            },
            .state => |e| {
                w.info.active = e.state.active;
                w.info.urgent = e.state.urgent;
            },
            .removed => w.removed = true,
            .id, .coordinates, .capabilities => {},
        }
    }

    fn free(self: *Workspaces, w: *Workspace) void {
        w.handle.destroy();
        self.allocator.free(w.name_buf);
        self.allocator.destroy(w);
    }
};
