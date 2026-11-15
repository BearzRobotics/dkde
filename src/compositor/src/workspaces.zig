//! Virtual desktops, served to clients as `ext-workspace-v1` (wlroots 0.19 has
//! no helper for it, so the protocol is implemented here on libwayland).
//!
//! The compositor owns the state (how many workspaces, which one is active);
//! this file tells every bound client and passes their requests back through
//! `on_activate`. There is one group (all the workspaces) for now.

const std = @import("std");
const c = @import("c");

const gpa = std.heap.c_allocator;
pub const max_workspaces = 9;

pub const Workspaces = struct {
    count: usize = 4,
    active: usize = 0,
    /// Called when a client asks to switch to workspace `index`.
    on_activate: *const fn (index: usize) void,
    clients: std.ArrayList(*Client) = .empty,
    global: ?*c.wl_global = null,
};

const Client = struct {
    manager: *c.wl_resource,
    group: ?*c.wl_resource = null,
    handles: [max_workspaces]?*c.wl_resource = @splat(null),
    /// A workspace the client asked for; applied at `commit`.
    pending: ?usize = null,
};

var state: *Workspaces = undefined;

pub fn init(display: *c.wl_display, ws: *Workspaces) void {
    state = ws;
    ws.global = c.wl_global_create(display, &c.ext_workspace_manager_v1_interface, 1, null, onBind);
}

pub fn deinit() void {
    if (state.global) |g| c.wl_global_destroy(g);
    state.global = null;
}

/// Sends the current states (and a count change) to every client.
pub fn refresh() void {
    for (state.clients.items) |cl| {
        sendAll(cl);
    }
}

fn nameOf(index: usize, buf: []u8) [:0]const u8 {
    return std.fmt.bufPrintSentinel(buf, "{d}", .{index + 1}, 0) catch "?";
}

fn stateOf(index: usize) u32 {
    return if (index == state.active) c.EXT_WORKSPACE_HANDLE_V1_STATE_ACTIVE else 0;
}

/// Makes the client's handles match the compositor's workspaces, then says "done".
fn sendAll(cl: *Client) void {
    const client = c.wl_resource_get_client(cl.manager);
    const version: c_int = c.wl_resource_get_version(cl.manager);
    const group = cl.group orelse return;
    var buf: [16]u8 = undefined;
    for (0..max_workspaces) |i| {
        if (i < state.count) {
            if (cl.handles[i] == null) {
                const h = c.wl_resource_create(client, &c.ext_workspace_handle_v1_interface, version, 0) orelse continue;
                c.wl_resource_set_implementation(h, &handle_impl, @ptrFromInt(i + 1), null);
                cl.handles[i] = h;
                c.ext_workspace_manager_v1_send_workspace(cl.manager, h);
                const name = nameOf(i, &buf);
                c.ext_workspace_handle_v1_send_id(h, name.ptr);
                c.ext_workspace_handle_v1_send_name(h, name.ptr);
                var coords: c.wl_array = undefined;
                c.wl_array_init(&coords);
                c.ext_workspace_handle_v1_send_coordinates(h, &coords);
                c.wl_array_release(&coords);
                c.ext_workspace_handle_v1_send_capabilities(h, c.EXT_WORKSPACE_HANDLE_V1_WORKSPACE_CAPABILITIES_ACTIVATE);
                c.ext_workspace_group_handle_v1_send_workspace_enter(group, h);
            }
            c.ext_workspace_handle_v1_send_state(cl.handles[i].?, stateOf(i));
        } else if (cl.handles[i]) |h| {
            c.ext_workspace_group_handle_v1_send_workspace_leave(group, h);
            c.ext_workspace_handle_v1_send_removed(h);
            cl.handles[i] = null;
        }
    }
    c.ext_workspace_manager_v1_send_done(cl.manager);
}

fn onBind(client: ?*c.wl_client, _: ?*anyopaque, version: u32, id: u32) callconv(.c) void {
    const manager = c.wl_resource_create(client, &c.ext_workspace_manager_v1_interface, @intCast(version), id) orelse return;
    const cl = gpa.create(Client) catch return;
    cl.* = .{ .manager = manager };
    c.wl_resource_set_implementation(manager, &manager_impl, cl, onManagerDestroy);
    state.clients.append(gpa, cl) catch {};

    const group = c.wl_resource_create(client, &c.ext_workspace_group_handle_v1_interface, @intCast(version), 0) orelse return;
    c.wl_resource_set_implementation(group, &group_impl, cl, null);
    cl.group = group;
    c.ext_workspace_manager_v1_send_workspace_group(manager, group);
    c.ext_workspace_group_handle_v1_send_capabilities(group, 0);
    sendAll(cl);
}

fn onManagerDestroy(resource: ?*c.wl_resource) callconv(.c) void {
    const cl: *Client = @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
    for (state.clients.items, 0..) |item, i| {
        if (item == cl) {
            _ = state.clients.orderedRemove(i);
            break;
        }
    }
    gpa.destroy(cl);
}

// ---- requests ------------------------------------------------------------------------------------------------

fn managerCommit(_: ?*c.wl_client, resource: ?*c.wl_resource) callconv(.c) void {
    const cl: *Client = @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
    if (cl.pending) |index| {
        cl.pending = null;
        if (index < state.count) state.on_activate(index);
    }
}

fn managerStop(_: ?*c.wl_client, resource: ?*c.wl_resource) callconv(.c) void {
    c.ext_workspace_manager_v1_send_finished(resource);
    c.wl_resource_destroy(resource);
}

fn destroyResource(_: ?*c.wl_client, resource: ?*c.wl_resource) callconv(.c) void {
    c.wl_resource_destroy(resource);
}

fn groupCreateWorkspace(_: ?*c.wl_client, _: ?*c.wl_resource, _: [*c]const u8) callconv(.c) void {}

fn handleActivate(_: ?*c.wl_client, resource: ?*c.wl_resource) callconv(.c) void {
    // The handle's user data is its index + 1; the client it belongs to is found through the manager list.
    const index = @intFromPtr(c.wl_resource_get_user_data(resource)) - 1;
    const client = c.wl_resource_get_client(resource);
    for (state.clients.items) |cl| {
        if (c.wl_resource_get_client(cl.manager) == client) cl.pending = index;
    }
}

fn handleNoop(_: ?*c.wl_client, _: ?*c.wl_resource) callconv(.c) void {}

fn handleAssign(_: ?*c.wl_client, _: ?*c.wl_resource, _: ?*c.wl_resource) callconv(.c) void {}

const manager_impl: c.struct_ext_workspace_manager_v1_interface = .{ .commit = managerCommit, .stop = managerStop };
const group_impl: c.struct_ext_workspace_group_handle_v1_interface = .{ .create_workspace = groupCreateWorkspace, .destroy = destroyResource };
const handle_impl: c.struct_ext_workspace_handle_v1_interface = .{
    .destroy = destroyResource,
    .activate = handleActivate,
    .deactivate = handleNoop,
    .assign = handleAssign,
    .remove = handleNoop,
};
