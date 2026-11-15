//! dkde-compositor, milestone 0: a minimal floating Wayland compositor on
//! wlroots (through Zig's C interop), in the shape of wlroots' `tinywl`.
//!
//! What it does: runs nested in another Wayland session (or headless, with
//! WLR_BACKENDS=headless), shows xdg-shell windows, gives them keyboard and
//! pointer focus, and lets Alt+left-drag move and Alt+right-drag resize them.
//! Alt+Escape quits; Alt+F1 raises the next window; Alt+T switches between
//! floating and tiling; Alt+Shift+Space floats or tiles the focused window.
//!
//! The window layout is a policy (see `layout.zig`): floating now, tiling next.

const std = @import("std");
const c = @import("c");
const layout = @import("layout.zig");
const config = @import("config.zig");
const workspaces = @import("workspaces.zig");

const gpa = std.heap.c_allocator;

const CursorMode = enum { passthrough, move, resize };

const Server = struct {
    display: *c.wl_display,
    backend: *c.wlr_backend,
    renderer: *c.wlr_renderer,
    allocator: *c.wlr_allocator,
    scene: *c.wlr_scene,
    scene_layout: *c.wlr_scene_output_layout,
    output_layout: *c.wlr_output_layout,
    xdg_shell: *c.wlr_xdg_shell,
    layer_shell: *c.wlr_layer_shell_v1,
    foreign: *c.wlr_foreign_toplevel_manager_v1,
    /// Scene layers, bottom to top: background, bottom, windows, top, overlay.
    trees: [5]*c.wlr_scene_tree,
    layer_surfaces: std.ArrayList(*LayerSurface) = .empty,
    /// What the layer surfaces (panels) leave free for windows.
    usable: ?layout.Rect = null,
    cursor: *c.wlr_cursor,
    cursor_mgr: *c.wlr_xcursor_manager,
    seat: *c.wlr_seat,

    toplevels: std.ArrayList(*Toplevel) = .empty, // focus order, back to front: the last is on top
    managed: std.ArrayList(*Toplevel) = .empty, // mapped windows in the order they appeared (tiling order)
    ws: workspaces.Workspaces = .{ .on_activate = switchWorkspace },
    policy: layout.Policy = .floating,
    layout_options: layout.Options = .{},
    opened: usize = 0, // windows opened so far, for cascading
    keyboards: std.ArrayList(*Keyboard) = .empty,

    cursor_mode: CursorMode = .passthrough,
    grabbed: ?*Toplevel = null,
    grab_x: f64 = 0,
    grab_y: f64 = 0,
    grab_box: c.wlr_box = std.mem.zeroes(c.wlr_box),
    resize_edges: u32 = 0,

    layout_change: c.wl_listener = std.mem.zeroes(c.wl_listener),
    new_output: c.wl_listener = std.mem.zeroes(c.wl_listener),
    new_xdg_toplevel: c.wl_listener = std.mem.zeroes(c.wl_listener),
    new_xdg_popup: c.wl_listener = std.mem.zeroes(c.wl_listener),
    new_layer_surface: c.wl_listener = std.mem.zeroes(c.wl_listener),
    cursor_motion: c.wl_listener = std.mem.zeroes(c.wl_listener),
    cursor_motion_absolute: c.wl_listener = std.mem.zeroes(c.wl_listener),
    cursor_button: c.wl_listener = std.mem.zeroes(c.wl_listener),
    cursor_axis: c.wl_listener = std.mem.zeroes(c.wl_listener),
    cursor_frame: c.wl_listener = std.mem.zeroes(c.wl_listener),
    new_input: c.wl_listener = std.mem.zeroes(c.wl_listener),
    request_cursor: c.wl_listener = std.mem.zeroes(c.wl_listener),
    pointer_focus_change: c.wl_listener = std.mem.zeroes(c.wl_listener),
    request_set_selection: c.wl_listener = std.mem.zeroes(c.wl_listener),
};

var server: Server = undefined;

fn listen(signal: *c.wl_signal, listener: *c.wl_listener, notify: c.wl_notify_func_t) void {
    listener.notify = notify;
    c.wl_signal_add(signal, listener);
}

fn unlisten(listener: *c.wl_listener) void {
    c.wl_list_remove(&listener.link);
}

// ---- outputs -------------------------------------------------------------------------------------------------

const Output = struct {
    output: *c.wlr_output,
    frame: c.wl_listener = std.mem.zeroes(c.wl_listener),
    request_state: c.wl_listener = std.mem.zeroes(c.wl_listener),
    destroy: c.wl_listener = std.mem.zeroes(c.wl_listener),

    fn onFrame(listener: ?*c.wl_listener, _: ?*anyopaque) callconv(.c) void {
        const self: *Output = @fieldParentPtr("frame", listener.?);
        const scene_output = c.wlr_scene_get_scene_output(server.scene, self.output) orelse return;
        _ = c.wlr_scene_output_commit(scene_output, null);
        // std's timespec rather than the C one: musl's is an opaque type to translate-c.
        var now: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &now);
        c.wlr_scene_output_send_frame_done(scene_output, @ptrCast(&now));
    }

    fn onRequestState(listener: ?*c.wl_listener, data: ?*anyopaque) callconv(.c) void {
        const self: *Output = @fieldParentPtr("request_state", listener.?);
        const event: *c.wlr_output_event_request_state = @ptrCast(@alignCast(data));
        _ = c.wlr_output_commit_state(self.output, event.state);
    }

    fn onDestroy(listener: ?*c.wl_listener, _: ?*anyopaque) callconv(.c) void {
        const self: *Output = @fieldParentPtr("destroy", listener.?);
        unlisten(&self.frame);
        unlisten(&self.request_state);
        unlisten(&self.destroy);
        gpa.destroy(self);
    }
};

fn onNewOutput(_: ?*c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const output: *c.wlr_output = @ptrCast(@alignCast(data));
    _ = c.wlr_output_init_render(output, server.allocator, server.renderer);

    var state: c.wlr_output_state = undefined;
    c.wlr_output_state_init(&state);
    c.wlr_output_state_set_enabled(&state, true);
    if (c.wlr_output_preferred_mode(output)) |mode| c.wlr_output_state_set_mode(&state, mode);
    _ = c.wlr_output_commit_state(output, &state);
    c.wlr_output_state_finish(&state);

    const out = gpa.create(Output) catch return;
    out.* = .{ .output = output };
    listen(&output.events.frame, &out.frame, Output.onFrame);
    listen(&output.events.request_state, &out.request_state, Output.onRequestState);
    listen(&output.events.destroy, &out.destroy, Output.onDestroy);

    const layout_output = c.wlr_output_layout_add_auto(server.output_layout, output);
    const scene_output = c.wlr_scene_output_create(server.scene, output);
    c.wlr_scene_output_layout_add_output(server.scene_layout, layout_output, scene_output);
}

// ---- windows -------------------------------------------------------------------------------------------------

const Toplevel = struct {
    xdg: *c.wlr_xdg_toplevel,
    tree: *c.wlr_scene_tree,
    /// Kept out of the tiling (a dialog, or a window the user floated).
    floating: bool = false,
    /// Where it was before tiling took it, to put it back.
    saved: ?layout.Rect = null,
    minimized: bool = false,
    /// The workspace it is on.
    workspace: usize = 0,
    /// Where tiling wants the window's content; kept so it can be moved again when the client changes its own margins.
    cell: ?layout.Rect = null,
    /// What the taskbar sees of this window.
    handle: ?*c.wlr_foreign_toplevel_handle_v1 = null,
    handle_activate: c.wl_listener = std.mem.zeroes(c.wl_listener),
    handle_close: c.wl_listener = std.mem.zeroes(c.wl_listener),
    handle_minimize: c.wl_listener = std.mem.zeroes(c.wl_listener),
    set_title: c.wl_listener = std.mem.zeroes(c.wl_listener),
    set_app_id: c.wl_listener = std.mem.zeroes(c.wl_listener),

    map: c.wl_listener = std.mem.zeroes(c.wl_listener),
    unmap: c.wl_listener = std.mem.zeroes(c.wl_listener),
    commit: c.wl_listener = std.mem.zeroes(c.wl_listener),
    destroy: c.wl_listener = std.mem.zeroes(c.wl_listener),
    request_move: c.wl_listener = std.mem.zeroes(c.wl_listener),
    request_resize: c.wl_listener = std.mem.zeroes(c.wl_listener),
    request_maximize: c.wl_listener = std.mem.zeroes(c.wl_listener),
    request_fullscreen: c.wl_listener = std.mem.zeroes(c.wl_listener),

    fn onMap(listener: ?*c.wl_listener, _: ?*anyopaque) callconv(.c) void {
        const self: *Toplevel = @fieldParentPtr("map", listener.?);
        c._wlr_log(c.WLR_INFO, "window mapped: %s", self.xdg.title);
        server.toplevels.append(gpa, self) catch return;
        server.managed.append(gpa, self) catch {};
        // A window with a parent (a dialog) or a fixed size is not tiled.
        if (self.xdg.parent != null) self.floating = true;
        self.workspace = server.ws.active;
        // Every window starts at a cascade spot, so the place it goes back to when tiling is switched off is a good one.
        const spot = layout.cascade(workArea(), server.opened);
        c.wlr_scene_node_set_position(&self.tree.*.node, spot.x, spot.y);
        server.opened += 1;
        addHandle(self);
        focus(self);
        arrange();
    }

    fn onUnmap(listener: ?*c.wl_listener, _: ?*anyopaque) callconv(.c) void {
        const self: *Toplevel = @fieldParentPtr("unmap", listener.?);
        if (server.grabbed == self) resetCursorMode();
        dropHandle(self);
        removeFromList(self);
        removeManaged(self);
        // Give the focus to the window now on top.
        if (server.toplevels.items.len > 0) focus(server.toplevels.items[server.toplevels.items.len - 1]);
        arrange();
    }

    fn onCommit(listener: ?*c.wl_listener, _: ?*anyopaque) callconv(.c) void {
        const self: *Toplevel = @fieldParentPtr("commit", listener.?);
        if (self.xdg.base.*.initial_commit) {
            // Let the client pick its own size.
            _ = c.wlr_xdg_toplevel_set_size(self.xdg, 0, 0);
        }
    }

    fn onDestroy(listener: ?*c.wl_listener, _: ?*anyopaque) callconv(.c) void {
        const self: *Toplevel = @fieldParentPtr("destroy", listener.?);
        unlisten(&self.map);
        unlisten(&self.unmap);
        unlisten(&self.commit);
        unlisten(&self.destroy);
        unlisten(&self.request_move);
        unlisten(&self.request_resize);
        unlisten(&self.request_maximize);
        unlisten(&self.request_fullscreen);
        dropHandle(self);
        gpa.destroy(self);
    }

    fn onRequestMove(listener: ?*c.wl_listener, _: ?*anyopaque) callconv(.c) void {
        const self: *Toplevel = @fieldParentPtr("request_move", listener.?);
        beginGrab(self, .move, 0);
    }

    fn onRequestResize(listener: ?*c.wl_listener, data: ?*anyopaque) callconv(.c) void {
        const self: *Toplevel = @fieldParentPtr("request_resize", listener.?);
        const event: *c.wlr_xdg_toplevel_resize_event = @ptrCast(@alignCast(data));
        beginGrab(self, .resize, event.edges);
    }

    // Maximize and fullscreen are not done yet; the client is told its state is unchanged.
    fn onRequestMaximize(listener: ?*c.wl_listener, _: ?*anyopaque) callconv(.c) void {
        const self: *Toplevel = @fieldParentPtr("request_maximize", listener.?);
        if (self.xdg.base.*.initialized) _ = c.wlr_xdg_surface_schedule_configure(self.xdg.base);
    }

    fn onRequestFullscreen(listener: ?*c.wl_listener, _: ?*anyopaque) callconv(.c) void {
        const self: *Toplevel = @fieldParentPtr("request_fullscreen", listener.?);
        if (self.xdg.base.*.initialized) _ = c.wlr_xdg_surface_schedule_configure(self.xdg.base);
    }
};

fn removeFromList(t: *Toplevel) void {
    for (server.toplevels.items, 0..) |item, i| {
        if (item == t) {
            _ = server.toplevels.orderedRemove(i);
            return;
        }
    }
}

// ---- the taskbar's view of the windows (wlr-foreign-toplevel-management) -----------------------------------

fn addHandle(t: *Toplevel) void {
    const h = c.wlr_foreign_toplevel_handle_v1_create(server.foreign) orelse return;
    t.handle = h;
    c.wlr_foreign_toplevel_handle_v1_set_title(h, t.xdg.title orelse "");
    c.wlr_foreign_toplevel_handle_v1_set_app_id(h, t.xdg.app_id orelse "");
    if (c.wlr_output_layout_get_center_output(server.output_layout)) |output| c.wlr_foreign_toplevel_handle_v1_output_enter(h, output);
    listen(&h.*.events.request_activate, &t.handle_activate, onHandleActivate);
    listen(&h.*.events.request_close, &t.handle_close, onHandleClose);
    listen(&h.*.events.request_minimize, &t.handle_minimize, onHandleMinimize);
    listen(&t.xdg.events.set_title, &t.set_title, onSetTitle);
    listen(&t.xdg.events.set_app_id, &t.set_app_id, onSetAppId);
}

fn dropHandle(t: *Toplevel) void {
    const h = t.handle orelse return;
    unlisten(&t.handle_activate);
    unlisten(&t.handle_close);
    unlisten(&t.handle_minimize);
    unlisten(&t.set_title);
    unlisten(&t.set_app_id);
    c.wlr_foreign_toplevel_handle_v1_destroy(h);
    t.handle = null;
}

fn onSetTitle(listener: ?*c.wl_listener, _: ?*anyopaque) callconv(.c) void {
    const t: *Toplevel = @fieldParentPtr("set_title", listener.?);
    if (t.handle) |h| c.wlr_foreign_toplevel_handle_v1_set_title(h, t.xdg.title orelse "");
}

fn onSetAppId(listener: ?*c.wl_listener, _: ?*anyopaque) callconv(.c) void {
    const t: *Toplevel = @fieldParentPtr("set_app_id", listener.?);
    if (t.handle) |h| c.wlr_foreign_toplevel_handle_v1_set_app_id(h, t.xdg.app_id orelse "");
}

fn onHandleActivate(listener: ?*c.wl_listener, _: ?*anyopaque) callconv(.c) void {
    const t: *Toplevel = @fieldParentPtr("handle_activate", listener.?);
    // Asking for a window on another workspace goes there first.
    if (t.workspace != server.ws.active) switchWorkspace(t.workspace);
    setMinimized(t, false);
    focus(t);
}

fn onHandleClose(listener: ?*c.wl_listener, _: ?*anyopaque) callconv(.c) void {
    const t: *Toplevel = @fieldParentPtr("handle_close", listener.?);
    c.wlr_xdg_toplevel_send_close(t.xdg);
}

fn onHandleMinimize(listener: ?*c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const t: *Toplevel = @fieldParentPtr("handle_minimize", listener.?);
    const event: *c.wlr_foreign_toplevel_handle_v1_minimized_event = @ptrCast(@alignCast(data));
    setMinimized(t, event.minimized);
}

/// Hides a window (the taskbar shows it as minimized) or brings it back.
fn setMinimized(t: *Toplevel, minimized: bool) void {
    if (t.minimized == minimized) return;
    t.minimized = minimized;
    showIfVisible(t);
    if (t.handle) |h| c.wlr_foreign_toplevel_handle_v1_set_minimized(h, minimized);
    if (minimized) {
        // The window now on top (not minimized) gets the keyboard.
        var i = server.toplevels.items.len;
        while (i > 0) : (i -= 1) {
            const other = server.toplevels.items[i - 1];
            if (other != t and !other.minimized) {
                focus(other);
                break;
            }
        }
    }
    arrange();
}

// ---- workspaces ----------------------------------------------------------------------------------------------

/// A window is drawn when it is on the current workspace and not minimized.
fn showIfVisible(t: *Toplevel) void {
    c.wlr_scene_node_set_enabled(&t.tree.*.node, !t.minimized and t.workspace == server.ws.active);
}

/// The window on top among those on the current workspace, if any.
fn topWindow() ?*Toplevel {
    var i = server.toplevels.items.len;
    while (i > 0) : (i -= 1) {
        const t = server.toplevels.items[i - 1];
        if (!t.minimized and t.workspace == server.ws.active) return t;
    }
    return null;
}

fn switchWorkspace(index: usize) void {
    if (index >= server.ws.count or index == server.ws.active) return;
    server.ws.active = index;
    for (server.toplevels.items) |t| showIfVisible(t);
    if (topWindow()) |t| {
        // focus() does nothing for the window that already has it, so clear first.
        c.wlr_seat_keyboard_clear_focus(server.seat);
        focus(t);
    } else {
        c.wlr_seat_keyboard_clear_focus(server.seat);
        for (server.toplevels.items) |t| {
            if (t.handle) |h| c.wlr_foreign_toplevel_handle_v1_set_activated(h, false);
        }
    }
    arrange();
    workspaces.refresh();
}

/// Alt+Shift+number: sends the focused window to another workspace.
fn moveWindowToWorkspace(index: usize) void {
    if (index >= server.ws.count) return;
    const t = topWindow() orelse return;
    t.workspace = index;
    showIfVisible(t);
    if (topWindow()) |next| {
        c.wlr_seat_keyboard_clear_focus(server.seat);
        focus(next);
    }
    arrange();
}

fn removeManaged(t: *Toplevel) void {
    for (server.managed.items, 0..) |item, i| {
        if (item == t) {
            _ = server.managed.orderedRemove(i);
            return;
        }
    }
}

/// The part of the screen windows may use (the whole output layout for now;
/// panels will reserve their strips from it).
fn workArea() layout.Rect {
    if (server.usable) |u| return u;
    var box: c.wlr_box = std.mem.zeroes(c.wlr_box);
    c.wlr_output_layout_get_box(server.output_layout, null, &box);
    if (box.width <= 0 or box.height <= 0) return .{ .x = 0, .y = 0, .w = 1280, .h = 720 };
    return .{ .x = box.x, .y = box.y, .w = box.width, .h = box.height };
}

fn geometryOf(t: *Toplevel) layout.Rect {
    // The scene puts the window's geometry (its content, without shadows) at the tree's position.
    const geo = t.xdg.base.*.geometry;
    return .{ .x = t.tree.*.node.x, .y = t.tree.*.node.y, .w = geo.width, .h = geo.height };
}

fn place(t: *Toplevel, r: layout.Rect) void {
    c.wlr_scene_node_set_position(&t.tree.*.node, r.x, r.y);
    _ = c.wlr_xdg_toplevel_set_size(t.xdg, r.w, r.h);
}

/// Places a window in a tiling cell and tells it so (clients then draw square, shadowless windows).
fn placeTiled(t: *Toplevel, r: layout.Rect) void {
    t.cell = r;
    _ = c.wlr_xdg_toplevel_set_tiled(t.xdg, c.WLR_EDGE_TOP | c.WLR_EDGE_BOTTOM | c.WLR_EDGE_LEFT | c.WLR_EDGE_RIGHT);
    place(t, r);
}

/// Puts every window where the policy says. Floating windows stay put.
fn arrange() void {
    if (server.policy != .tiling) return;
    var tiled: std.ArrayList(*Toplevel) = .empty;
    defer tiled.deinit(gpa);
    for (server.managed.items) |t| {
        if (!t.floating and !t.minimized and t.workspace == server.ws.active) tiled.append(gpa, t) catch return;
    }
    const cells = gpa.alloc(layout.Rect, tiled.items.len) catch return;
    defer gpa.free(cells);
    layout.tile(workArea(), tiled.items.len, server.layout_options, cells);
    for (tiled.items, cells) |t, cell| {
        if (t.saved == null) t.saved = geometryOf(t);
        placeTiled(t, cell);
    }
}

/// Floating <-> tiling for the whole screen.
fn togglePolicy() void {
    server.policy = server.policy.toggled();
    if (server.policy == .tiling) {
        arrange();
    } else {
        for (server.managed.items) |t| restore(t);
    }
}

/// Gives a window back the place and size it had before tiling.
fn restore(t: *Toplevel) void {
    t.cell = null;
    _ = c.wlr_xdg_toplevel_set_tiled(t.xdg, 0);
    if (t.saved) |r| {
        place(t, r);
        t.saved = null;
    }
}

/// Alt+Shift+Space: keeps the focused window out of the tiling, or puts it back in.
fn toggleWindowFloating() void {
    if (server.toplevels.items.len == 0) return;
    const t = server.toplevels.items[server.toplevels.items.len - 1];
    t.floating = !t.floating;
    if (t.floating) restore(t);
    arrange();
}

fn onLayoutChange(_: ?*c.wl_listener, _: ?*anyopaque) callconv(.c) void {
    arrange();
}

fn onNewToplevel(_: ?*c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const xdg: *c.wlr_xdg_toplevel = @ptrCast(@alignCast(data));
    c._wlr_log(c.WLR_INFO, "new window");
    const t = gpa.create(Toplevel) catch return;
    const tree = c.wlr_scene_xdg_surface_create(server.trees[2], xdg.base) orelse {
        gpa.destroy(t);
        return;
    };
    t.* = .{ .xdg = xdg, .tree = tree };
    tree.*.node.data = t;
    xdg.base.*.data = tree;

    const surface = xdg.base.*.surface;
    listen(&surface.*.events.map, &t.map, Toplevel.onMap);
    listen(&surface.*.events.unmap, &t.unmap, Toplevel.onUnmap);
    listen(&surface.*.events.commit, &t.commit, Toplevel.onCommit);
    listen(&xdg.events.destroy, &t.destroy, Toplevel.onDestroy);
    listen(&xdg.events.request_move, &t.request_move, Toplevel.onRequestMove);
    listen(&xdg.events.request_resize, &t.request_resize, Toplevel.onRequestResize);
    listen(&xdg.events.request_maximize, &t.request_maximize, Toplevel.onRequestMaximize);
    listen(&xdg.events.request_fullscreen, &t.request_fullscreen, Toplevel.onRequestFullscreen);
}

const Popup = struct {
    xdg: *c.wlr_xdg_popup,
    commit: c.wl_listener = std.mem.zeroes(c.wl_listener),
    destroy: c.wl_listener = std.mem.zeroes(c.wl_listener),

    fn onCommit(listener: ?*c.wl_listener, _: ?*anyopaque) callconv(.c) void {
        const self: *Popup = @fieldParentPtr("commit", listener.?);
        if (self.xdg.base.*.initial_commit) _ = c.wlr_xdg_surface_schedule_configure(self.xdg.base);
    }

    fn onDestroy(listener: ?*c.wl_listener, _: ?*anyopaque) callconv(.c) void {
        const self: *Popup = @fieldParentPtr("destroy", listener.?);
        unlisten(&self.commit);
        unlisten(&self.destroy);
        gpa.destroy(self);
    }
};

fn onNewPopup(_: ?*c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const xdg: *c.wlr_xdg_popup = @ptrCast(@alignCast(data));
    // A popup of a layer surface has no xdg parent; the layer surface announces it itself.
    const parent_surface = xdg.parent orelse return;
    const parent = c.wlr_xdg_surface_try_from_wlr_surface(parent_surface) orelse return;
    const parent_tree: *c.wlr_scene_tree = @ptrCast(@alignCast(parent.*.data orelse return));
    addPopup(xdg, parent_tree);
}

fn addPopup(xdg: *c.wlr_xdg_popup, parent_tree: *c.wlr_scene_tree) void {
    const popup = gpa.create(Popup) catch return;
    popup.* = .{ .xdg = xdg };
    xdg.base.*.data = c.wlr_scene_xdg_surface_create(parent_tree, xdg.base);
    listen(&xdg.base.*.surface.*.events.commit, &popup.commit, Popup.onCommit);
    listen(&xdg.events.destroy, &popup.destroy, Popup.onDestroy);
}

/// Gives the keyboard focus to `t` and raises it.
fn focus(t: *Toplevel) void {
    const seat = server.seat;
    const surface = t.xdg.base.*.surface;
    const previous = seat.*.keyboard_state.focused_surface;
    if (previous == surface) return;
    if (previous) |prev| {
        if (c.wlr_xdg_toplevel_try_from_wlr_surface(prev)) |prev_top| _ = c.wlr_xdg_toplevel_set_activated(prev_top, false);
    }
    c.wlr_scene_node_raise_to_top(&t.tree.*.node);
    removeFromList(t);
    server.toplevels.append(gpa, t) catch {};
    _ = c.wlr_xdg_toplevel_set_activated(t.xdg, true);
    for (server.toplevels.items) |other| {
        if (other.handle) |h| c.wlr_foreign_toplevel_handle_v1_set_activated(h, other == t);
    }
    if (c.wlr_seat_get_keyboard(seat)) |keyboard| {
        c.wlr_seat_keyboard_notify_enter(seat, surface, keyboard.*.keycodes[0..].ptr, keyboard.*.num_keycodes, &keyboard.*.modifiers);
    }
}

const Hit = struct { toplevel: ?*Toplevel, layer: ?*LayerSurface, surface: *c.wlr_surface, sx: f64, sy: f64 };

/// The window and surface under layout position (lx, ly), if any.
fn windowAt(lx: f64, ly: f64) ?Hit {
    var sx: f64 = 0;
    var sy: f64 = 0;
    const node = c.wlr_scene_node_at(&server.scene.*.tree.node, lx, ly, &sx, &sy) orelse return null;
    if (node.*.type != c.WLR_SCENE_NODE_BUFFER) return null;
    const buffer = c.wlr_scene_buffer_from_node(node);
    const scene_surface = c.wlr_scene_surface_try_from_buffer(buffer) orelse return null;
    // Walk up to the tree that stands for a window or a layer surface; its parent says which.
    var tree: ?*c.wlr_scene_tree = node.*.parent;
    while (tree) |t| : (tree = t.node.parent) {
        const data = t.node.data orelse continue;
        const parent = t.node.parent orelse return null;
        if (parent == server.trees[2]) {
            return .{ .toplevel = @ptrCast(@alignCast(data)), .layer = null, .surface = scene_surface.*.surface, .sx = sx, .sy = sy };
        }
        return .{ .toplevel = null, .layer = @ptrCast(@alignCast(data)), .surface = scene_surface.*.surface, .sx = sx, .sy = sy };
    }
    return null;
}

// ---- layer surfaces: panels, launchers, the desktop background -------------------------------------------

const LayerSurface = struct {
    surface: *c.wlr_layer_surface_v1,
    scene: *c.wlr_scene_layer_surface_v1,
    map: c.wl_listener = std.mem.zeroes(c.wl_listener),
    unmap: c.wl_listener = std.mem.zeroes(c.wl_listener),
    commit: c.wl_listener = std.mem.zeroes(c.wl_listener),
    destroy: c.wl_listener = std.mem.zeroes(c.wl_listener),
    new_popup: c.wl_listener = std.mem.zeroes(c.wl_listener),

    fn onMap(listener: ?*c.wl_listener, _: ?*anyopaque) callconv(.c) void {
        const self: *LayerSurface = @fieldParentPtr("map", listener.?);
        arrangeLayers();
        focusLayer(self);
    }

    fn onUnmap(listener: ?*c.wl_listener, _: ?*anyopaque) callconv(.c) void {
        const self: *LayerSurface = @fieldParentPtr("unmap", listener.?);
        // A layer surface that held the keyboard gives it to the window on top.
        if (server.seat.*.keyboard_state.focused_surface == self.surface.*.surface and server.toplevels.items.len > 0) {
            const top = server.toplevels.items[server.toplevels.items.len - 1];
            c.wlr_seat_keyboard_clear_focus(server.seat);
            const surface = top.xdg.base.*.surface;
            if (c.wlr_seat_get_keyboard(server.seat)) |kb| {
                c.wlr_seat_keyboard_notify_enter(server.seat, surface, kb.*.keycodes[0..].ptr, kb.*.num_keycodes, &kb.*.modifiers);
            }
        }
        arrangeLayers();
    }

    fn onCommit(listener: ?*c.wl_listener, _: ?*anyopaque) callconv(.c) void {
        const self: *LayerSurface = @fieldParentPtr("commit", listener.?);
        _ = self;
        arrangeLayers();
    }

    fn onNewPopup(listener: ?*c.wl_listener, data: ?*anyopaque) callconv(.c) void {
        const self: *LayerSurface = @fieldParentPtr("new_popup", listener.?);
        const popup: *c.wlr_xdg_popup = @ptrCast(@alignCast(data));
        addPopup(popup, self.scene.*.tree);
    }

    fn onDestroy(listener: ?*c.wl_listener, _: ?*anyopaque) callconv(.c) void {
        const self: *LayerSurface = @fieldParentPtr("destroy", listener.?);
        unlisten(&self.map);
        unlisten(&self.unmap);
        unlisten(&self.commit);
        unlisten(&self.destroy);
        unlisten(&self.new_popup);
        for (server.layer_surfaces.items, 0..) |item, i| {
            if (item == self) {
                _ = server.layer_surfaces.orderedRemove(i);
                break;
            }
        }
        gpa.destroy(self);
        arrangeLayers();
    }
};

fn onNewLayerSurface(_: ?*c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const surface: *c.wlr_layer_surface_v1 = @ptrCast(@alignCast(data));
    // A client that names no output gets the primary one.
    if (surface.output == null) {
        surface.output = c.wlr_output_layout_get_center_output(server.output_layout);
        if (surface.output == null) {
            c.wlr_layer_surface_v1_destroy(surface);
            return;
        }
    }
    const layer: usize = surface.pending.layer;
    const parent = server.trees[if (layer >= 2) layer + 1 else layer];
    const scene = c.wlr_scene_layer_surface_v1_create(parent, surface) orelse return;
    const self = gpa.create(LayerSurface) catch return;
    self.* = .{ .surface = surface, .scene = scene };
    scene.*.tree.*.node.data = self;
    server.layer_surfaces.append(gpa, self) catch {};
    listen(&surface.*.surface.*.events.map, &self.map, LayerSurface.onMap);
    listen(&surface.*.surface.*.events.unmap, &self.unmap, LayerSurface.onUnmap);
    listen(&surface.*.surface.*.events.commit, &self.commit, LayerSurface.onCommit);
    listen(&surface.*.events.destroy, &self.destroy, LayerSurface.onDestroy);
    listen(&surface.*.events.new_popup, &self.new_popup, LayerSurface.onNewPopup);
}

/// Gives a layer surface the keyboard when it asks for it (a launcher), unless it asked not to have it.
fn focusLayer(ls: *LayerSurface) void {
    const mode = ls.surface.*.current.keyboard_interactive;
    if (mode == c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE) return;
    if (!ls.surface.*.surface.*.mapped) return;
    if (c.wlr_seat_get_keyboard(server.seat)) |kb| {
        c.wlr_seat_keyboard_notify_enter(server.seat, ls.surface.*.surface, kb.*.keycodes[0..].ptr, kb.*.num_keycodes, &kb.*.modifiers);
    }
}

/// Lays out every layer surface on the primary output and works out what is left for windows.
fn arrangeLayers() void {
    const output = c.wlr_output_layout_get_center_output(server.output_layout) orelse return;
    var full: c.wlr_box = std.mem.zeroes(c.wlr_box);
    c.wlr_output_layout_get_box(server.output_layout, output, &full);
    var usable = full;
    // Surfaces that reserve space first, so the others lay out in what remains.
    var pass: u8 = 0;
    while (pass < 2) : (pass += 1) {
        var layer: i32 = 3;
        while (layer >= 0) : (layer -= 1) {
            for (server.layer_surfaces.items) |ls| {
                if (ls.surface.*.current.layer != layer) continue;
                const exclusive = ls.surface.*.current.exclusive_zone > 0;
                if ((pass == 0) != exclusive) continue;
                c.wlr_scene_layer_surface_v1_configure(ls.scene, &full, &usable);
            }
        }
    }
    const area = layout.Rect{ .x = usable.x, .y = usable.y, .w = usable.width, .h = usable.height };
    const changed = if (server.usable) |old| !std.meta.eql(old, area) else true;
    server.usable = area;
    if (changed) arrange();
}

// ---- pointer -------------------------------------------------------------------------------------------------

fn resetCursorMode() void {
    server.cursor_mode = .passthrough;
    server.grabbed = null;
}

fn beginGrab(t: *Toplevel, mode: CursorMode, edges: u32) void {
    // Only the window that has the pointer may start a grab.
    const focused = server.seat.*.pointer_state.focused_surface;
    if (focused == null or t.xdg.base.*.surface != c.wlr_surface_get_root_surface(focused)) return;
    server.grabbed = t;
    server.cursor_mode = mode;
    const cursor = server.cursor;
    if (mode == .move) {
        server.grab_x = cursor.*.x - @as(f64, @floatFromInt(t.tree.*.node.x));
        server.grab_y = cursor.*.y - @as(f64, @floatFromInt(t.tree.*.node.y));
    } else {
        const geo = t.xdg.base.*.geometry;
        const border_x = @as(f64, @floatFromInt(t.tree.*.node.x)) + (if (edges & c.WLR_EDGE_RIGHT != 0) @as(f64, @floatFromInt(geo.width)) else 0);
        const border_y = @as(f64, @floatFromInt(t.tree.*.node.y)) + (if (edges & c.WLR_EDGE_BOTTOM != 0) @as(f64, @floatFromInt(geo.height)) else 0);
        server.grab_x = cursor.*.x - border_x;
        server.grab_y = cursor.*.y - border_y;
        server.grab_box = geo;
        server.grab_box.x = t.tree.*.node.x;
        server.grab_box.y = t.tree.*.node.y;
        server.resize_edges = edges;
    }
}

fn processCursorMotion(time: u32) void {
    const cursor = server.cursor;
    switch (server.cursor_mode) {
        .move => {
            if (server.grabbed) |t| {
                c.wlr_scene_node_set_position(&t.tree.*.node, @intFromFloat(cursor.*.x - server.grab_x), @intFromFloat(cursor.*.y - server.grab_y));
            }
            return;
        },
        .resize => {
            if (server.grabbed) |t| {
                const border_x: i32 = @intFromFloat(cursor.*.x - server.grab_x);
                const border_y: i32 = @intFromFloat(cursor.*.y - server.grab_y);
                var new_left = server.grab_box.x;
                var new_right = server.grab_box.x + server.grab_box.width;
                var new_top = server.grab_box.y;
                var new_bottom = server.grab_box.y + server.grab_box.height;
                if (server.resize_edges & c.WLR_EDGE_TOP != 0) {
                    new_top = border_y;
                    if (new_top >= new_bottom) new_top = new_bottom - 1;
                } else if (server.resize_edges & c.WLR_EDGE_BOTTOM != 0) {
                    new_bottom = border_y;
                    if (new_bottom <= new_top) new_bottom = new_top + 1;
                }
                if (server.resize_edges & c.WLR_EDGE_LEFT != 0) {
                    new_left = border_x;
                    if (new_left >= new_right) new_left = new_right - 1;
                } else if (server.resize_edges & c.WLR_EDGE_RIGHT != 0) {
                    new_right = border_x;
                    if (new_right <= new_left) new_right = new_left + 1;
                }
                c.wlr_scene_node_set_position(&t.tree.*.node, new_left, new_top);
                _ = c.wlr_xdg_toplevel_set_size(t.xdg, new_right - new_left, new_bottom - new_top);
            }
            return;
        },
        .passthrough => {},
    }

    if (windowAt(cursor.*.x, cursor.*.y)) |hit| {
        c.wlr_seat_pointer_notify_enter(server.seat, hit.surface, hit.sx, hit.sy);
        c.wlr_seat_pointer_notify_motion(server.seat, time, hit.sx, hit.sy);
    } else {
        c.wlr_cursor_set_xcursor(cursor, server.cursor_mgr, "default");
        c.wlr_seat_pointer_clear_focus(server.seat);
    }
}

fn onCursorMotion(_: ?*c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const event: *c.wlr_pointer_motion_event = @ptrCast(@alignCast(data));
    c.wlr_cursor_move(server.cursor, &event.pointer.*.base, event.delta_x, event.delta_y);
    processCursorMotion(event.time_msec);
}

fn onCursorMotionAbsolute(_: ?*c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const event: *c.wlr_pointer_motion_absolute_event = @ptrCast(@alignCast(data));
    c.wlr_cursor_warp_absolute(server.cursor, &event.pointer.*.base, event.x, event.y);
    processCursorMotion(event.time_msec);
}

fn onCursorButton(_: ?*c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const event: *c.wlr_pointer_button_event = @ptrCast(@alignCast(data));
    _ = c.wlr_seat_pointer_notify_button(server.seat, event.time_msec, event.button, event.state);
    if (event.state == c.WL_POINTER_BUTTON_STATE_RELEASED) {
        resetCursorMode();
    } else if (windowAt(server.cursor.*.x, server.cursor.*.y)) |hit| {
        if (hit.toplevel) |t| focus(t);
        if (hit.layer) |ls| focusLayer(ls);
    }
}

fn onCursorAxis(_: ?*c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const event: *c.wlr_pointer_axis_event = @ptrCast(@alignCast(data));
    c.wlr_seat_pointer_notify_axis(server.seat, event.time_msec, event.orientation, event.delta, event.delta_discrete, event.source, event.relative_direction);
}

fn onCursorFrame(_: ?*c.wl_listener, _: ?*anyopaque) callconv(.c) void {
    c.wlr_seat_pointer_notify_frame(server.seat);
}

// ---- keyboards -----------------------------------------------------------------------------------------------

const Keyboard = struct {
    keyboard: *c.wlr_keyboard,
    modifiers: c.wl_listener = std.mem.zeroes(c.wl_listener),
    key: c.wl_listener = std.mem.zeroes(c.wl_listener),
    destroy: c.wl_listener = std.mem.zeroes(c.wl_listener),

    fn onModifiers(listener: ?*c.wl_listener, _: ?*anyopaque) callconv(.c) void {
        const self: *Keyboard = @fieldParentPtr("modifiers", listener.?);
        c.wlr_seat_set_keyboard(server.seat, self.keyboard);
        c.wlr_seat_keyboard_notify_modifiers(server.seat, &self.keyboard.*.modifiers);
    }

    fn onKey(listener: ?*c.wl_listener, data: ?*anyopaque) callconv(.c) void {
        const self: *Keyboard = @fieldParentPtr("key", listener.?);
        const event: *c.wlr_keyboard_key_event = @ptrCast(@alignCast(data));

        // Translate the evdev keycode to an xkb one and look up what it types.
        const keycode: u32 = event.keycode + 8;
        var syms: [*c]const c.xkb_keysym_t = null;
        const count = c.xkb_state_key_get_syms(self.keyboard.*.xkb_state, keycode, &syms);
        var handled = false;
        if (c.wlr_keyboard_get_modifiers(self.keyboard) & c.WLR_MODIFIER_ALT != 0 and event.state == c.WL_KEYBOARD_KEY_STATE_PRESSED) {
            var i: usize = 0;
            const shift = c.wlr_keyboard_get_modifiers(self.keyboard) & c.WLR_MODIFIER_SHIFT != 0;
            while (i < @as(usize, @intCast(count))) : (i += 1) handled = keybinding(syms[i], shift) or handled;
        }
        if (!handled) {
            c.wlr_seat_set_keyboard(server.seat, self.keyboard);
            c.wlr_seat_keyboard_notify_key(server.seat, event.time_msec, event.keycode, event.state);
        }
    }

    fn onDestroy(listener: ?*c.wl_listener, _: ?*anyopaque) callconv(.c) void {
        const self: *Keyboard = @fieldParentPtr("destroy", listener.?);
        unlisten(&self.modifiers);
        unlisten(&self.key);
        unlisten(&self.destroy);
        for (server.keyboards.items, 0..) |item, i| {
            if (item == self) {
                _ = server.keyboards.orderedRemove(i);
                break;
            }
        }
        gpa.destroy(self);
    }
};

/// Compositor shortcuts (with Alt held). True when the key was one of them.
fn keybinding(sym: c.xkb_keysym_t, shift: bool) bool {
    c._wlr_log(c.WLR_DEBUG, "Alt+key %u", sym);
    // Alt+1…9 switches workspace; with Shift (which turns the digit into ! @ # …) it moves the window.
    const shifted = [_]c.xkb_keysym_t{ c.XKB_KEY_exclam, c.XKB_KEY_at, c.XKB_KEY_numbersign, c.XKB_KEY_dollar, c.XKB_KEY_percent, c.XKB_KEY_asciicircum, c.XKB_KEY_ampersand, c.XKB_KEY_asterisk, c.XKB_KEY_parenleft };
    if (sym >= c.XKB_KEY_1 and sym <= c.XKB_KEY_9) {
        switchWorkspace(sym - c.XKB_KEY_1);
        return true;
    }
    for (shifted, 0..) |k, i| {
        if (sym == k) {
            moveWindowToWorkspace(i);
            return true;
        }
    }
    switch (sym) {
        c.XKB_KEY_t, c.XKB_KEY_T => togglePolicy(),
        c.XKB_KEY_space => if (shift) toggleWindowFloating() else return false,
        c.XKB_KEY_Escape => c.wl_display_terminate(server.display),
        c.XKB_KEY_F1 => {
            if (server.toplevels.items.len >= 2) focus(server.toplevels.items[0]);
        },
        else => return false,
    }
    return true;
}

fn addKeyboard(device: *c.wlr_input_device) void {
    const keyboard = c.wlr_keyboard_from_input_device(device);
    const k = gpa.create(Keyboard) catch return;
    k.* = .{ .keyboard = keyboard };

    const context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS);
    const keymap = c.xkb_keymap_new_from_names(context, null, c.XKB_KEYMAP_COMPILE_NO_FLAGS);
    _ = c.wlr_keyboard_set_keymap(keyboard, keymap);
    c.xkb_keymap_unref(keymap);
    c.xkb_context_unref(context);
    c.wlr_keyboard_set_repeat_info(keyboard, 25, 600);

    listen(&keyboard.*.events.modifiers, &k.modifiers, Keyboard.onModifiers);
    listen(&keyboard.*.events.key, &k.key, Keyboard.onKey);
    listen(&device.events.destroy, &k.destroy, Keyboard.onDestroy);
    c.wlr_seat_set_keyboard(server.seat, keyboard);
    server.keyboards.append(gpa, k) catch {};
}

fn onNewInput(_: ?*c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const device: *c.wlr_input_device = @ptrCast(@alignCast(data));
    switch (device.type) {
        c.WLR_INPUT_DEVICE_KEYBOARD => addKeyboard(device),
        c.WLR_INPUT_DEVICE_POINTER => c.wlr_cursor_attach_input_device(server.cursor, device),
        else => {},
    }
    var caps: u32 = c.WL_SEAT_CAPABILITY_POINTER;
    if (server.keyboards.items.len > 0) caps |= c.WL_SEAT_CAPABILITY_KEYBOARD;
    c.wlr_seat_set_capabilities(server.seat, caps);
}

fn onRequestCursor(_: ?*c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const event: *c.wlr_seat_pointer_request_set_cursor_event = @ptrCast(@alignCast(data));
    // Only the client with the pointer may set the cursor image.
    if (server.seat.*.pointer_state.focused_client == event.seat_client) {
        c.wlr_cursor_set_surface(server.cursor, event.surface, event.hotspot_x, event.hotspot_y);
    }
}

fn onPointerFocusChange(_: ?*c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const event: *c.wlr_seat_pointer_focus_change_event = @ptrCast(@alignCast(data));
    if (event.new_surface == null) c.wlr_cursor_set_xcursor(server.cursor, server.cursor_mgr, "default");
}

fn onRequestSetSelection(_: ?*c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const event: *c.wlr_seat_request_set_selection_event = @ptrCast(@alignCast(data));
    c.wlr_seat_set_selection(server.seat, event.source, event.serial);
}

// ---- settings ------------------------------------------------------------------------------------------------

/// Where the settings file is: DKDE_COMPOSITOR_CONFIG, or ~/.config/dkde/compositor.toml.
fn configPath(buf: []u8) ?[:0]const u8 {
    if (std.c.getenv("DKDE_COMPOSITOR_CONFIG")) |p| return std.fmt.bufPrintSentinel(buf, "{s}", .{std.mem.span(p)}, 0) catch null;
    if (std.c.getenv("XDG_CONFIG_HOME")) |d| return std.fmt.bufPrintSentinel(buf, "{s}/dkde/compositor.toml", .{std.mem.span(d)}, 0) catch null;
    const home = std.c.getenv("HOME") orelse return null;
    return std.fmt.bufPrintSentinel(buf, "{s}/.config/dkde/compositor.toml", .{std.mem.span(home)}, 0) catch null;
}

/// Reads the settings file (a missing one is fine) and applies it.
fn loadConfig() void {
    var path_buf: [1024]u8 = undefined;
    var cfg: config.Config = .{};
    if (configPath(&path_buf)) |path| {
        if (readFile(path)) |text| {
            defer gpa.free(text);
            var warnings: std.ArrayList([]const u8) = .empty;
            defer {
                for (warnings.items) |w| gpa.free(w);
                warnings.deinit(gpa);
            }
            cfg = config.parse(gpa, text, &warnings) catch cfg;
            for (warnings.items) |w| c._wlr_log(c.WLR_ERROR, "%s: %.*s", path.ptr, @as(c_int, @intCast(w.len)), w.ptr);
        }
    }
    const was = server.policy;
    server.ws.count = cfg.workspaces;
    if (server.ws.active >= server.ws.count) switchWorkspace(server.ws.count - 1);
    workspaces.refresh();
    server.policy = cfg.policy;
    server.layout_options = cfg.options;
    // The policy changed: put windows where it says (or back where they were).
    if (was != cfg.policy) {
        if (cfg.policy == .floating) {
            for (server.managed.items) |t| restore(t);
        }
    }
    arrange();
}

fn readFile(path: [:0]const u8) ?[]u8 {
    const file = c.fopen(path.ptr, "rb") orelse return null;
    defer _ = c.fclose(file);
    var list: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.fread(&buf, 1, buf.len, file);
        if (n == 0) break;
        list.appendSlice(gpa, buf[0..n]) catch {
            list.deinit(gpa);
            return null;
        };
    }
    return list.toOwnedSlice(gpa) catch null;
}

/// SIGHUP: read the settings again.
fn onReload(_: c_int, _: ?*anyopaque) callconv(.c) c_int {
    c._wlr_log(c.WLR_INFO, "reloading the settings");
    loadConfig();
    return 0;
}

// ---- start ---------------------------------------------------------------------------------------------------

pub fn main() !void {
    c.wlr_log_init(if (std.c.getenv("DKDE_DEBUG") != null) c.WLR_DEBUG else c.WLR_INFO, null);

    const display = c.wl_display_create() orelse return error.NoDisplay;
    const backend = c.wlr_backend_autocreate(c.wl_display_get_event_loop(display), null) orelse return error.NoBackend;
    const renderer = c.wlr_renderer_autocreate(backend) orelse return error.NoRenderer;
    _ = c.wlr_renderer_init_wl_display(renderer, display);
    const allocator = c.wlr_allocator_autocreate(backend, renderer) orelse return error.NoAllocator;

    // The protocols every client expects.
    _ = c.wlr_compositor_create(display, 5, renderer);
    _ = c.wlr_subcompositor_create(display);
    _ = c.wlr_data_device_manager_create(display);
    _ = c.wlr_screencopy_manager_v1_create(display);

    const output_layout = c.wlr_output_layout_create(display) orelse return error.NoLayout;
    _ = c.wlr_xdg_output_manager_v1_create(display, output_layout);
    const scene = c.wlr_scene_create() orelse return error.NoScene;
    const scene_layout = c.wlr_scene_attach_output_layout(scene, output_layout) orelse return error.NoScene;
    const xdg_shell = c.wlr_xdg_shell_create(display, 3) orelse return error.NoXdgShell;
    const layer_shell = c.wlr_layer_shell_v1_create(display, 4) orelse return error.NoLayerShell;
    const foreign = c.wlr_foreign_toplevel_manager_v1_create(display) orelse return error.NoForeignToplevel;
    var trees: [5]*c.wlr_scene_tree = undefined;
    for (&trees) |*t| t.* = c.wlr_scene_tree_create(&scene.*.tree) orelse return error.NoScene;
    const cursor = c.wlr_cursor_create() orelse return error.NoCursor;
    c.wlr_cursor_attach_output_layout(cursor, output_layout);
    const cursor_mgr = c.wlr_xcursor_manager_create(null, 24) orelse return error.NoCursor;
    const seat = c.wlr_seat_create(display, "seat0") orelse return error.NoSeat;

    server = .{
        .display = display,
        .backend = backend,
        .renderer = renderer,
        .allocator = allocator,
        .scene = scene,
        .scene_layout = scene_layout,
        .output_layout = output_layout,
        .xdg_shell = xdg_shell,
        .layer_shell = layer_shell,
        .foreign = foreign,
        .trees = trees,
        .cursor = cursor,
        .cursor_mgr = cursor_mgr,
        .seat = seat,
    };

    workspaces.init(display, &server.ws);
    loadConfig();
    _ = c.wl_event_loop_add_signal(c.wl_display_get_event_loop(display), c.SIGHUP, onReload, null);
    listen(&output_layout.*.events.change, &server.layout_change, onLayoutChange);
    listen(&backend.*.events.new_output, &server.new_output, onNewOutput);
    listen(&xdg_shell.*.events.new_toplevel, &server.new_xdg_toplevel, onNewToplevel);
    listen(&xdg_shell.*.events.new_popup, &server.new_xdg_popup, onNewPopup);
    listen(&layer_shell.*.events.new_surface, &server.new_layer_surface, onNewLayerSurface);
    listen(&cursor.*.events.motion, &server.cursor_motion, onCursorMotion);
    listen(&cursor.*.events.motion_absolute, &server.cursor_motion_absolute, onCursorMotionAbsolute);
    listen(&cursor.*.events.button, &server.cursor_button, onCursorButton);
    listen(&cursor.*.events.axis, &server.cursor_axis, onCursorAxis);
    listen(&cursor.*.events.frame, &server.cursor_frame, onCursorFrame);
    listen(&backend.*.events.new_input, &server.new_input, onNewInput);
    listen(&seat.*.events.request_set_cursor, &server.request_cursor, onRequestCursor);
    listen(&seat.*.pointer_state.events.focus_change, &server.pointer_focus_change, onPointerFocusChange);
    listen(&seat.*.events.request_set_selection, &server.request_set_selection, onRequestSetSelection);

    const socket = c.wl_display_add_socket_auto(display) orelse return error.NoSocket;
    if (!c.wlr_backend_start(backend)) return error.BackendStart;
    _ = c.setenv("WAYLAND_DISPLAY", socket, 1);
    c._wlr_log(c.WLR_INFO, "dkde-compositor running on WAYLAND_DISPLAY=%s", socket);

    c.wl_display_run(display);

    workspaces.deinit();
    // Detach the listeners first: wlroots asserts that none are left when it frees an object.
    unlisten(&server.new_output);
    unlisten(&server.layout_change);
    unlisten(&server.new_xdg_toplevel);
    unlisten(&server.new_xdg_popup);
    unlisten(&server.new_layer_surface);
    unlisten(&server.cursor_motion);
    unlisten(&server.cursor_motion_absolute);
    unlisten(&server.cursor_button);
    unlisten(&server.cursor_axis);
    unlisten(&server.cursor_frame);
    unlisten(&server.new_input);
    unlisten(&server.request_cursor);
    unlisten(&server.pointer_focus_change);
    unlisten(&server.request_set_selection);
    // Shut down in the order wlroots wants: clients, then the scene, then the rest.
    c.wl_display_destroy_clients(display);
    c.wlr_scene_node_destroy(&scene.*.tree.node);
    c.wlr_xcursor_manager_destroy(cursor_mgr);
    c.wlr_cursor_destroy(cursor);
    c.wlr_allocator_destroy(allocator);
    c.wlr_renderer_destroy(renderer);
    c.wlr_backend_destroy(backend);
    c.wl_display_destroy(display);
}
