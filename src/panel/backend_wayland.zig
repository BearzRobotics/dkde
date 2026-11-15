//! The Wayland implementation of the shared desktop API (common.desktop):
//! windows from `wlr-foreign-toplevel-management`, workspaces from
//! `ext-workspace-v1`. Output management and screenshots go through other
//! programs today, so those capabilities are not claimed here yet.

const std = @import("std");
const common = @import("common");
const toplevels = @import("toplevels.zig");
const workspaces = @import("workspaces.zig");

const desktop = common.desktop;

pub const Wayland = struct {
    allocator: std.mem.Allocator,
    windows: ?*toplevels.Manager = null,
    workspaces: ?*workspaces.Workspaces = null,

    const vtable: desktop.VTable = .{
        .capabilities = capabilities,
        .windows = windowList,
        .workspaces = workspaceList,
        .activate_workspace = activateWorkspace,
        .destroy = destroy,
    };

    /// `on_windows` and `on_workspaces` run after any change. Returns an
    /// empty Desktop when not on Wayland.
    pub fn create(
        allocator: std.mem.Allocator,
        on_windows: *const fn (*anyopaque) void,
        on_workspaces: *const fn (*anyopaque) void,
        data: *anyopaque,
    ) desktop.Desktop {
        const self = allocator.create(Wayland) catch return .{};
        self.* = .{ .allocator = allocator };
        self.workspaces = workspaces.Workspaces.create(allocator, on_workspaces, data);
        self.windows = toplevels.Manager.create(allocator, on_windows, data) catch |err| blk: {
            std.log.warn("no taskbar: {s}", .{@errorName(err)});
            break :blk null;
        };
        if (self.windows == null and self.workspaces == null) {
            allocator.destroy(self);
            return .{};
        }
        return .{ .backend = .{ .kind = .wayland, .ptr = self, .vtable = &vtable } };
    }

    fn of(p: *anyopaque) *Wayland {
        return @ptrCast(@alignCast(p));
    }

    fn capabilities(p: *anyopaque) desktop.Capabilities {
        const self = of(p);
        var caps = desktop.Capabilities.empty;
        if (self.windows != null) for ([_]desktop.Capability{ .window_list, .window_activate, .window_minimize, .window_maximize, .window_close }) |c| caps.insert(c);
        // A compositor without ext-workspace-v1 never gives us a manager.
        if (self.workspaces) |w| {
            if (w.manager != null) {
                caps.insert(.workspaces);
                caps.insert(.workspace_switch);
            }
        }
        return caps;
    }

    fn windowList(p: *anyopaque) []const *desktop.Window {
        return if (of(p).windows) |m| m.windows.items else &.{};
    }

    fn workspaceList(p: *anyopaque) []const *const desktop.Workspace {
        return if (of(p).workspaces) |w| w.infos.items else &.{};
    }

    fn activateWorkspace(p: *anyopaque, index: usize) void {
        if (of(p).workspaces) |w| w.activate(index);
    }

    fn destroy(p: *anyopaque) void {
        const self = of(p);
        if (self.windows) |m| m.destroy();
        if (self.workspaces) |w| w.destroy();
        self.allocator.destroy(self);
    }
};
