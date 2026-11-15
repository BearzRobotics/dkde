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
const keys = @import("keys.zig");

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
    idle: *c.wlr_idle_notifier_v1,
    output_manager: *c.wlr_output_manager_v1,
    session_lock: *c.wlr_session_lock_manager_v1,
    /// True from the moment a lock client takes the screen until it unlocks it. A lock client that dies
    /// leaves the screen locked (a new lock client may take over).
    locked: bool = false,
    lock: ?*Lock = null,
    lock_tree: ?*c.wlr_scene_tree = null,
    outputs: std.ArrayList(*Output) = .empty,
    pointers: std.ArrayList(*c.wlr_input_device) = .empty,
    cursor: *c.wlr_cursor,
    cursor_mgr: *c.wlr_xcursor_manager,
    seat: *c.wlr_seat,

    toplevels: std.ArrayList(*Toplevel) = .empty, // focus order, back to front: the last is on top
    managed: std.ArrayList(*Toplevel) = .empty, // mapped windows in the order they appeared (tiling order)
    ws: workspaces.Workspaces = .{ .on_activate = switchWorkspace },
    bindings: std.ArrayList(Binding) = .empty,
    /// A Super key went down and nothing else has been pressed since (a tap opens the Start menu).
    super_pending: bool = false,
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
    new_lock: c.wl_listener = std.mem.zeroes(c.wl_listener),
    new_x_surface: c.wl_listener = std.mem.zeroes(c.wl_listener),
    output_apply: c.wl_listener = std.mem.zeroes(c.wl_listener),
    output_test: c.wl_listener = std.mem.zeroes(c.wl_listener),
    new_decoration: c.wl_listener = std.mem.zeroes(c.wl_listener),
    new_virtual_keyboard: c.wl_listener = std.mem.zeroes(c.wl_listener),
    new_virtual_pointer: c.wl_listener = std.mem.zeroes(c.wl_listener),
    request_set_primary: c.wl_listener = std.mem.zeroes(c.wl_listener),
    request_set_shape: c.wl_listener = std.mem.zeroes(c.wl_listener),
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
    // A listener that was never added (or already removed) has no links.
    if (listener.link.next == null or listener.link.prev == null) return;
    c.wl_list_remove(&listener.link);
    listener.link.next = null;
    listener.link.prev = null;
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
        for (server.outputs.items, 0..) |o, i| {
            if (o == self) {
                _ = server.outputs.orderedRemove(i);
                break;
            }
        }
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

    server.outputs.append(gpa, out) catch {};
    const layout_output = c.wlr_output_layout_add_auto(server.output_layout, output);
    const scene_output = c.wlr_scene_output_create(server.scene, output);
    c.wlr_scene_output_layout_add_output(server.scene_layout, layout_output, scene_output);
    publishOutputs();
}

// ---- output management (wlr-randr, Settings > Display, screen off) ---------------------------------------------

/// Tells output-management clients how the outputs are set up now.
fn publishOutputs() void {
    const cfg = c.wlr_output_configuration_v1_create() orelse return;
    for (server.outputs.items) |o| {
        const head = c.wlr_output_configuration_head_v1_create(cfg, o.output) orelse continue;
        if (c.wlr_output_layout_get(server.output_layout, o.output)) |l| {
            head.*.state.x = l.*.x;
            head.*.state.y = l.*.y;
        }
    }
    c.wlr_output_manager_v1_set_configuration(server.output_manager, cfg);
}

/// Applies (or only tests) what a client asked for. True when every output accepted it.
fn applyOutputConfig(cfg: *c.wlr_output_configuration_v1, test_only: bool) bool {
    var ok = true;
    var node: *c.struct_wl_list = @ptrCast(cfg.heads.next);
    while (node != &cfg.heads) : (node = @ptrCast(node.next)) {
        const head: *c.wlr_output_configuration_head_v1 = @fieldParentPtr("link", node);
        const output = head.state.output;
        var state: c.wlr_output_state = undefined;
        c.wlr_output_state_init(&state);
        c.wlr_output_head_v1_state_apply(&head.state, &state);
        const accepted = if (test_only) c.wlr_output_test_state(output, &state) else c.wlr_output_commit_state(output, &state);
        c.wlr_output_state_finish(&state);
        if (!accepted) ok = false;
    }
    if (ok and !test_only) {
        node = @ptrCast(cfg.heads.next);
        while (node != &cfg.heads) : (node = @ptrCast(node.next)) {
            const head: *c.wlr_output_configuration_head_v1 = @fieldParentPtr("link", node);
            if (head.state.enabled) {
                _ = c.wlr_output_layout_add(server.output_layout, head.state.output, head.state.x, head.state.y);
            } else {
                c.wlr_output_layout_remove(server.output_layout, head.state.output);
            }
        }
    }
    return ok;
}

fn onOutputApply(_: ?*c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const cfg: *c.wlr_output_configuration_v1 = @ptrCast(@alignCast(data));
    if (applyOutputConfig(cfg, false)) c.wlr_output_configuration_v1_send_succeeded(cfg) else c.wlr_output_configuration_v1_send_failed(cfg);
    c.wlr_output_configuration_v1_destroy(cfg);
    publishOutputs();
}

fn onOutputTest(_: ?*c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const cfg: *c.wlr_output_configuration_v1 = @ptrCast(@alignCast(data));
    if (applyOutputConfig(cfg, true)) c.wlr_output_configuration_v1_send_succeeded(cfg) else c.wlr_output_configuration_v1_send_failed(cfg);
    c.wlr_output_configuration_v1_destroy(cfg);
}

// ---- windows -------------------------------------------------------------------------------------------------

const Toplevel = struct {
    /// A window is either an xdg-shell toplevel or an X11 window (through Xwayland).
    xdg: ?*c.wlr_xdg_toplevel = null,
    xs: ?*c.wlr_xwayland_surface = null,
    tree: *c.wlr_scene_tree,
    /// The surface drawn for an X11 window (it exists while the window is associated with a wl_surface).
    x_scene: ?*c.wlr_scene_surface = null,
    x_associate: c.wl_listener = std.mem.zeroes(c.wl_listener),
    x_dissociate: c.wl_listener = std.mem.zeroes(c.wl_listener),
    x_request_configure: c.wl_listener = std.mem.zeroes(c.wl_listener),
    /// Kept out of the tiling (a dialog, or a window the user floated).
    floating: bool = false,
    /// Where it was before tiling took it, to put it back.
    saved: ?layout.Rect = null,
    minimized: bool = false,
    maximized: bool = false,
    fullscreen: bool = false,
    /// Where it was before it was maximized or made fullscreen.
    before: ?layout.Rect = null,
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


    fn surf(self: *const Toplevel) ?*c.wlr_surface {
        if (self.xdg) |x| return x.base.*.surface;
        if (self.xs) |x| return x.surface;
        return null;
    }

    fn title(self: *const Toplevel) [*c]const u8 {
        if (self.xdg) |x| return if (x.title != null) x.title else "";
        if (self.xs) |x| return if (x.title != null) x.title else "";
        return "";
    }

    fn appId(self: *const Toplevel) [*c]const u8 {
        if (self.xdg) |x| return if (x.app_id != null) x.app_id else "";
        if (self.xs) |x| return if (x.class != null) x.class else "";
        return "";
    }

    fn sendClose(self: *Toplevel) void {
        if (self.xdg) |x| c.wlr_xdg_toplevel_send_close(x);
        if (self.xs) |x| c.wlr_xwayland_surface_close(x);
    }

    fn activate(self: *Toplevel, on: bool) void {
        if (self.xdg) |x| _ = c.wlr_xdg_toplevel_set_activated(x, on);
        if (self.xs) |x| c.wlr_xwayland_surface_activate(x, on);
    }

    fn setTiledEdges(self: *Toplevel, edges: u32) void {
        if (self.xdg) |x| _ = c.wlr_xdg_toplevel_set_tiled(x, edges);
    }

    fn setMaxFlag(self: *Toplevel, on: bool) void {
        if (self.xdg) |x| _ = c.wlr_xdg_toplevel_set_maximized(x, on);
        if (self.xs) |x| c.wlr_xwayland_surface_set_maximized(x, on, on);
    }

    fn setFullFlag(self: *Toplevel, on: bool) void {
        if (self.xdg) |x| _ = c.wlr_xdg_toplevel_set_fullscreen(x, on);
        if (self.xs) |x| c.wlr_xwayland_surface_set_fullscreen(x, on);
    }

    /// Ready for configure requests (an X11 window always is).
    fn ready(self: *const Toplevel) bool {
        if (self.xdg) |x| return x.base.*.initialized;
        return true;
    }

    fn reconfigure(self: *Toplevel) void {
        if (self.xdg) |x| _ = c.wlr_xdg_surface_schedule_configure(x.base);
    }

    fn hasParent(self: *const Toplevel) bool {
        if (self.xdg) |x| return x.parent != null;
        if (self.xs) |x| return x.parent != null;
        return false;
    }

    /// An X11 menu or tooltip: placed where it asks, never tiled, never focused.
    fn unmanaged(self: *const Toplevel) bool {
        if (self.xs) |x| return x.override_redirect;
        return false;
    }

    /// The window's content size.
    fn contentSize(self: *const Toplevel) struct { w: i32, h: i32 } {
        if (self.xdg) |x| return .{ .w = x.base.*.geometry.width, .h = x.base.*.geometry.height };
        if (self.xs) |x| return .{ .w = x.width, .h = x.height };
        return .{ .w = 0, .h = 0 };
    }

    fn wantsMaximized(self: *const Toplevel) bool {
        if (self.xdg) |x| return x.requested.maximized;
        if (self.xs) |x| return x.maximized_vert and x.maximized_horz;
        return false;
    }

    fn wantsFullscreen(self: *const Toplevel) bool {
        if (self.xdg) |x| return x.requested.fullscreen;
        if (self.xs) |x| return x.fullscreen;
        return false;
    }

    fn onMap(listener: ?*c.wl_listener, _: ?*anyopaque) callconv(.c) void {
        const self: *Toplevel = @fieldParentPtr("map", listener.?);
        c._wlr_log(c.WLR_INFO, "window mapped: %s", self.title());
        if (self.unmanaged()) {
            // A menu or tooltip of an X11 program: where it asks, above the windows, not in any list.
            c.wlr_scene_node_set_position(&self.tree.*.node, self.xs.?.x, self.xs.?.y);
            return;
        }
        server.toplevels.append(gpa, self) catch return;
        server.managed.append(gpa, self) catch {};
        // A window with a parent (a dialog) or a fixed size is not tiled.
        if (self.hasParent() or (self.xs != null and self.xs.?.override_redirect)) self.floating = true;
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
        if (self.unmanaged()) return;
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
        if (self.xdg) |x| {
            if (x.base.*.initial_commit) {
                // Let the client pick its own size.
                _ = c.wlr_xdg_toplevel_set_size(x, 0, 0);
            }
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

    fn onRequestMaximize(listener: ?*c.wl_listener, _: ?*anyopaque) callconv(.c) void {
        const self: *Toplevel = @fieldParentPtr("request_maximize", listener.?);
        setMaximized(self, self.wantsMaximized());
    }

    fn onRequestFullscreen(listener: ?*c.wl_listener, _: ?*anyopaque) callconv(.c) void {
        const self: *Toplevel = @fieldParentPtr("request_fullscreen", listener.?);
        setFullscreen(self, self.wantsFullscreen());
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
    c.wlr_foreign_toplevel_handle_v1_set_title(h, t.title());
    c.wlr_foreign_toplevel_handle_v1_set_app_id(h, t.appId());
    if (c.wlr_output_layout_get_center_output(server.output_layout)) |output| c.wlr_foreign_toplevel_handle_v1_output_enter(h, output);
    listen(&h.*.events.request_activate, &t.handle_activate, onHandleActivate);
    listen(&h.*.events.request_close, &t.handle_close, onHandleClose);
    listen(&h.*.events.request_minimize, &t.handle_minimize, onHandleMinimize);
    if (t.xdg) |x| {
        listen(&x.events.set_title, &t.set_title, onSetTitle);
        listen(&x.events.set_app_id, &t.set_app_id, onSetAppId);
    }
    if (t.xs) |x| {
        listen(&x.events.set_title, &t.set_title, onSetTitle);
        listen(&x.events.set_class, &t.set_app_id, onSetAppId);
    }
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
    if (t.handle) |h| c.wlr_foreign_toplevel_handle_v1_set_title(h, t.title());
}

fn onSetAppId(listener: ?*c.wl_listener, _: ?*anyopaque) callconv(.c) void {
    const t: *Toplevel = @fieldParentPtr("set_app_id", listener.?);
    if (t.handle) |h| c.wlr_foreign_toplevel_handle_v1_set_app_id(h, t.appId());
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
    t.sendClose();
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

// ---- maximize and fullscreen -----------------------------------------------------------------------------------

/// The whole screen (panels included), for fullscreen windows.
fn screenArea() layout.Rect {
    var box: c.wlr_box = std.mem.zeroes(c.wlr_box);
    c.wlr_output_layout_get_box(server.output_layout, null, &box);
    if (box.width <= 0 or box.height <= 0) return .{ .x = 0, .y = 0, .w = 1280, .h = 720 };
    return .{ .x = box.x, .y = box.y, .w = box.width, .h = box.height };
}

fn setMaximized(t: *Toplevel, on: bool) void {
    if (!t.ready()) return;
    if (on == t.maximized) {
        t.reconfigure();
        return;
    }
    t.maximized = on;
    t.setMaxFlag(on);
    if (on) {
        if (t.before == null) t.before = geometryOf(t);
        place(t, workArea());
    } else if (!t.fullscreen) {
        leaveBig(t);
    }
    arrange();
}

fn setFullscreen(t: *Toplevel, on: bool) void {
    if (!t.ready()) return;
    if (on == t.fullscreen) {
        t.reconfigure();
        return;
    }
    t.fullscreen = on;
    t.setFullFlag(on);
    if (on) {
        if (t.before == null) t.before = geometryOf(t);
        place(t, screenArea());
        c.wlr_scene_node_reparent(&t.tree.*.node, server.trees[4]);
    } else {
        c.wlr_scene_node_reparent(&t.tree.*.node, server.trees[2]);
        if (t.maximized) place(t, workArea()) else leaveBig(t);
    }
    arrange();
}

/// Back to the place and size from before maximizing or fullscreen.
fn leaveBig(t: *Toplevel) void {
    if (t.before) |r| {
        place(t, r);
        t.before = null;
    }
}

// ---- screen lock (ext-session-lock-v1: swaylock, gtklock …) ---------------------------------------------------

const Lock = struct {
    lock: *c.wlr_session_lock_v1,
    new_surface: c.wl_listener = std.mem.zeroes(c.wl_listener),
    unlock: c.wl_listener = std.mem.zeroes(c.wl_listener),
    destroy: c.wl_listener = std.mem.zeroes(c.wl_listener),

    const onNewSurface = Lock_onNewSurface;
    const onUnlock = Lock_onUnlock;
    const onDestroy = Lock_onDestroy;
};

fn onNewLock(_: ?*c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const lock: *c.wlr_session_lock_v1 = @ptrCast(@alignCast(data));
    // One lock client at a time; but when the last one died without unlocking, another may take over.
    if (server.lock != null) {
        c.wlr_session_lock_v1_destroy(lock);
        return;
    }
    const self = gpa.create(Lock) catch {
        c.wlr_session_lock_v1_destroy(lock);
        return;
    };
    self.* = .{ .lock = lock };

    // A black cover over every output, above everything, before the lock is reported done.
    if (server.lock_tree == null) {
        const tree = c.wlr_scene_tree_create(&server.scene.*.tree) orelse {
            gpa.destroy(self);
            c.wlr_session_lock_v1_destroy(lock);
            return;
        };
        for (server.outputs.items) |o| {
            var box: c.wlr_box = std.mem.zeroes(c.wlr_box);
            c.wlr_output_layout_get_box(server.output_layout, o.output, &box);
            const black = [4]f32{ 0, 0, 0, 1 };
            if (c.wlr_scene_rect_create(tree, box.width, box.height, &black)) |rect| {
                c.wlr_scene_node_set_position(&rect.*.node, box.x, box.y);
            }
        }
        c.wlr_scene_node_raise_to_top(&tree.*.node);
        server.lock_tree = tree;
    }
    server.locked = true;
    server.lock = self;
    // Nothing keeps the keyboard while locked until the lock surface takes it.
    c.wlr_seat_keyboard_clear_focus(server.seat);
    c.wlr_seat_pointer_clear_focus(server.seat);
    listen(&lock.events.new_surface, &self.new_surface, Lock.onNewSurface);
    listen(&lock.events.unlock, &self.unlock, Lock.onUnlock);
    listen(&lock.events.destroy, &self.destroy, Lock.onDestroy);
    c.wlr_session_lock_v1_send_locked(lock);
}

fn lockSurfaceFor(surface: *c.wlr_session_lock_surface_v1) void {
    const tree = server.lock_tree orelse return;
    const output = surface.output orelse return;
    var box: c.wlr_box = std.mem.zeroes(c.wlr_box);
    c.wlr_output_layout_get_box(server.output_layout, output, &box);
    _ = c.wlr_session_lock_surface_v1_configure(surface, @intCast(box.width), @intCast(box.height));
    if (c.wlr_scene_subsurface_tree_create(tree, surface.surface)) |sub| {
        c.wlr_scene_node_set_position(&sub.*.node, box.x, box.y);
    }
    if (c.wlr_seat_get_keyboard(server.seat)) |kb| {
        c.wlr_seat_keyboard_notify_enter(server.seat, surface.surface, kb.*.keycodes[0..].ptr, kb.*.num_keycodes, &kb.*.modifiers);
    }
}

fn Lock_onNewSurface(listener: ?*c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = listener;
    const surface: *c.wlr_session_lock_surface_v1 = @ptrCast(@alignCast(data));
    lockSurfaceFor(surface);
}

fn Lock_onUnlock(listener: ?*c.wl_listener, _: ?*anyopaque) callconv(.c) void {
    _ = listener;
    server.locked = false;
    if (server.lock_tree) |tree| c.wlr_scene_node_destroy(&tree.*.node);
    server.lock_tree = null;
    c.wlr_seat_keyboard_clear_focus(server.seat);
    if (topWindow()) |t| focus(t);
}

fn Lock_onDestroy(listener: ?*c.wl_listener, _: ?*anyopaque) callconv(.c) void {
    const self: *Lock = @fieldParentPtr("destroy", listener.?);
    unlisten(&self.new_surface);
    unlisten(&self.unlock);
    unlisten(&self.destroy);
    // Destroyed without unlocking: the screen stays locked (the cover stays), and a new lock client may start.
    server.lock = null;
    gpa.destroy(self);
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
    const size = t.contentSize();
    return .{ .x = t.tree.*.node.x, .y = t.tree.*.node.y, .w = size.w, .h = size.h };
}

fn place(t: *Toplevel, r: layout.Rect) void {
    c.wlr_scene_node_set_position(&t.tree.*.node, r.x, r.y);
    if (t.xdg) |x| _ = c.wlr_xdg_toplevel_set_size(x, r.w, r.h);
    if (t.xs) |x| c.wlr_xwayland_surface_configure(x, @intCast(r.x), @intCast(r.y), @intCast(@max(r.w, 1)), @intCast(@max(r.h, 1)));
}

/// Places a window in a tiling cell and tells it so (clients then draw square, shadowless windows).
fn placeTiled(t: *Toplevel, r: layout.Rect) void {
    t.cell = r;
    t.setTiledEdges(c.WLR_EDGE_TOP | c.WLR_EDGE_BOTTOM | c.WLR_EDGE_LEFT | c.WLR_EDGE_RIGHT);
    place(t, r);
}

/// Puts every window where the policy says. Floating windows stay put.
fn arrange() void {
    if (server.policy != .tiling) return;
    var tiled: std.ArrayList(*Toplevel) = .empty;
    defer tiled.deinit(gpa);
    for (server.managed.items) |t| {
        if (!t.floating and !t.minimized and !t.maximized and !t.fullscreen and t.workspace == server.ws.active) tiled.append(gpa, t) catch return;
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
    t.setTiledEdges(0);
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
    publishOutputs();
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

// ---- X11 programs (Xwayland) -----------------------------------------------------------------------------------

fn onNewXSurface(_: ?*c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const xs: *c.wlr_xwayland_surface = @ptrCast(@alignCast(data));
    const t = gpa.create(Toplevel) catch return;
    const tree = c.wlr_scene_tree_create(server.trees[2]) orelse {
        gpa.destroy(t);
        return;
    };
    t.* = .{ .xs = xs, .tree = tree };
    tree.*.node.data = t;
    listen(&xs.events.associate, &t.x_associate, onXAssociate);
    listen(&xs.events.dissociate, &t.x_dissociate, onXDissociate);
    listen(&xs.events.destroy, &t.destroy, Toplevel.onDestroy);
    listen(&xs.events.request_configure, &t.x_request_configure, onXRequestConfigure);
    listen(&xs.events.request_maximize, &t.request_maximize, Toplevel.onRequestMaximize);
    listen(&xs.events.request_fullscreen, &t.request_fullscreen, Toplevel.onRequestFullscreen);
    // Already associated with a surface (it can happen before we hear of it)?
    if (xs.surface != null) onXAssociate(&t.x_associate, null);
}

/// The window now has a wl_surface: draw it, and follow its map and unmap.
fn onXAssociate(listener: ?*c.wl_listener, _: ?*anyopaque) callconv(.c) void {
    const t: *Toplevel = @fieldParentPtr("x_associate", listener.?);
    const xs = t.xs.?;
    const surface = xs.surface orelse return;
    t.x_scene = c.wlr_scene_surface_create(t.tree, surface);
    listen(&surface.*.events.map, &t.map, Toplevel.onMap);
    listen(&surface.*.events.unmap, &t.unmap, Toplevel.onUnmap);
}

fn onXDissociate(listener: ?*c.wl_listener, _: ?*anyopaque) callconv(.c) void {
    const t: *Toplevel = @fieldParentPtr("x_dissociate", listener.?);
    unlisten(&t.map);
    unlisten(&t.unmap);
    if (t.x_scene) |scene| c.wlr_scene_node_destroy(&scene.*.buffer.*.node);
    t.x_scene = null;
}

/// The program asks to move or resize itself. Floating windows may; a tiled one is put back in its cell.
fn onXRequestConfigure(listener: ?*c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const t: *Toplevel = @fieldParentPtr("x_request_configure", listener.?);
    const ev: *c.wlr_xwayland_surface_configure_event = @ptrCast(@alignCast(data));
    const xs = t.xs.?;
    if (t.cell) |cell| {
        c.wlr_xwayland_surface_configure(xs, @intCast(cell.x), @intCast(cell.y), @intCast(@max(cell.w, 1)), @intCast(@max(cell.h, 1)));
        return;
    }
    if (t.maximized or t.fullscreen) {
        c.wlr_xwayland_surface_configure(xs, xs.x, xs.y, xs.width, xs.height);
        return;
    }
    c.wlr_xwayland_surface_configure(xs, ev.x, ev.y, ev.width, ev.height);
    if (!t.unmanaged() and t.handle != null) c.wlr_scene_node_set_position(&t.tree.*.node, ev.x, ev.y);
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
    if (server.locked or t.unmanaged()) return;
    const seat = server.seat;
    const surface = t.surf() orelse return;
    const previous = seat.*.keyboard_state.focused_surface;
    if (previous == surface) return;
    if (previous) |prev| {
        for (server.toplevels.items) |other| {
            if (other.surf() == prev) other.activate(false);
        }
    }
    c.wlr_scene_node_raise_to_top(&t.tree.*.node);
    removeFromList(t);
    server.toplevels.append(gpa, t) catch {};
    t.activate(true);
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
        // The lock screen: the pointer reaches it, nothing else.
        if (server.lock_tree != null and t == server.lock_tree.?) {
            return .{ .toplevel = null, .layer = null, .surface = scene_surface.*.surface, .sx = sx, .sy = sy };
        }
        const data = t.node.data orelse continue;
        const parent = t.node.parent orelse return null;
        if (parent == server.trees[2] or parent == server.trees[4]) {
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
            const surface = top.surf() orelse return;
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
    if (focused == null or t.surf() == null or t.surf().? != c.wlr_surface_get_root_surface(focused)) return;
    server.grabbed = t;
    server.cursor_mode = mode;
    const cursor = server.cursor;
    if (mode == .move) {
        server.grab_x = cursor.*.x - @as(f64, @floatFromInt(t.tree.*.node.x));
        server.grab_y = cursor.*.y - @as(f64, @floatFromInt(t.tree.*.node.y));
    } else {
        const geo = t.contentSize();
        const border_x = @as(f64, @floatFromInt(t.tree.*.node.x)) + (if (edges & c.WLR_EDGE_RIGHT != 0) @as(f64, @floatFromInt(geo.w)) else 0);
        const border_y = @as(f64, @floatFromInt(t.tree.*.node.y)) + (if (edges & c.WLR_EDGE_BOTTOM != 0) @as(f64, @floatFromInt(geo.h)) else 0);
        server.grab_x = cursor.*.x - border_x;
        server.grab_y = cursor.*.y - border_y;
        server.grab_box = .{ .x = 0, .y = 0, .width = geo.w, .height = geo.h };
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
                if (t.xdg) |x| _ = c.wlr_xdg_toplevel_set_size(x, new_right - new_left, new_bottom - new_top);
                if (t.xs) |x| c.wlr_xwayland_surface_configure(x, @intCast(new_left), @intCast(new_top), @intCast(@max(new_right - new_left, 1)), @intCast(@max(new_bottom - new_top, 1)));
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
    noteActivity();
    const event: *c.wlr_pointer_motion_event = @ptrCast(@alignCast(data));
    c.wlr_cursor_move(server.cursor, &event.pointer.*.base, event.delta_x, event.delta_y);
    processCursorMotion(event.time_msec);
}

fn onCursorMotionAbsolute(_: ?*c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    noteActivity();
    const event: *c.wlr_pointer_motion_absolute_event = @ptrCast(@alignCast(data));
    c.wlr_cursor_warp_absolute(server.cursor, &event.pointer.*.base, event.x, event.y);
    processCursorMotion(event.time_msec);
}

/// Is Alt down on any keyboard? (A machine can have several; the seat tracks only the last one used.)
fn altHeld() bool {
    for (server.keyboards.items) |k| {
        if (c.wlr_keyboard_get_modifiers(k.keyboard) & c.WLR_MODIFIER_ALT != 0) return true;
    }
    return false;
}

fn onCursorButton(_: ?*c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const event: *c.wlr_pointer_button_event = @ptrCast(@alignCast(data));
    noteActivity();
    c._wlr_log(c.WLR_DEBUG, "button %u state %d alt=%d keyboards=%d", event.button, @as(c_int, @intCast(event.state)), @as(c_int, @intFromBool(altHeld())), @as(c_int, @intCast(server.keyboards.items.len)));
    // Alt + left button drags the window under the pointer, Alt + right button resizes it from the nearest corner;
    // the client never sees these clicks.
    if (event.state == c.WL_POINTER_BUTTON_STATE_PRESSED and altHeld()) {
        const BTN_LEFT = 0x110;
        const BTN_RIGHT = 0x111;
        if (windowAt(server.cursor.*.x, server.cursor.*.y)) |hit| {
            if (hit.toplevel) |t| {
                if (event.button == BTN_LEFT or event.button == BTN_RIGHT) {
                    focus(t);
                    // Moving or resizing a tiled window takes it out of the tiling.
                    if (server.policy == .tiling and !t.floating) {
                        t.floating = true;
                        restore(t);
                        arrange();
                    }
                    if (event.button == BTN_LEFT) {
                        beginGrab(t, .move, 0);
                    } else {
                        const box = geometryOf(t);
                        const mid_x = @as(f64, @floatFromInt(box.x)) + @as(f64, @floatFromInt(box.w)) / 2;
                        const mid_y = @as(f64, @floatFromInt(box.y)) + @as(f64, @floatFromInt(box.h)) / 2;
                        var edges: u32 = if (server.cursor.*.x < mid_x) c.WLR_EDGE_LEFT else c.WLR_EDGE_RIGHT;
                        edges |= if (server.cursor.*.y < mid_y) c.WLR_EDGE_TOP else c.WLR_EDGE_BOTTOM;
                        beginGrab(t, .resize, edges);
                    }
                    if (server.cursor_mode != .passthrough) return;
                }
            }
        }
    }
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
    /// A virtual keyboard (an on-screen keyboard, wtype) brings its own keymap.
    virtual: bool = false,
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
        noteActivity();

        // Translate the evdev keycode to an xkb one and look up what the key is without Shift
        // (level 0), so "S-1" matches the 1 key whatever the layout makes of Shift.
        const keycode: u32 = event.keycode + 8;
        const mods = modsOf(c.wlr_keyboard_get_modifiers(self.keyboard));
        const layout_index = c.xkb_state_key_get_layout(self.keyboard.*.xkb_state, keycode);
        var syms: [*c]const c.xkb_keysym_t = null;
        const count = c.xkb_keymap_key_get_syms_by_level(self.keyboard.*.keymap, keycode, layout_index, 0, &syms);
        var handled = false;
        const pressed = event.state == c.WL_KEYBOARD_KEY_STATE_PRESSED;
        // While the screen is locked no shortcut works: every key goes to the lock screen.
        if (server.locked) {
            c.wlr_seat_set_keyboard(server.seat, self.keyboard);
            c.wlr_seat_keyboard_notify_key(server.seat, event.time_msec, event.keycode, event.state);
            return;
        }
        var i: usize = 0;
        while (i < @as(usize, @intCast(@max(count, 0)))) : (i += 1) {
            const sym = syms[i];
            if (pressed) {
                if (isSuper(sym)) {
                    // A bare Super tap acts when the key comes up, if nothing else was pressed meanwhile.
                    server.super_pending = true;
                    handled = true;
                    continue;
                }
                server.super_pending = false;
                if (runBinding(mods, sym)) handled = true;
            } else if (isSuper(sym)) {
                if (server.super_pending) {
                    server.super_pending = false;
                    _ = runBinding(0, c.XKB_KEY_Super_L);
                }
            }
        }
        // The Super key itself is also sent on, so clients see a normal key press (some use it).
        if (count > 0 and isSuper(syms[0])) handled = false;
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

// ---- shortcuts -----------------------------------------------------------------------------------------------

const Binding = struct {
    mods: u8,
    sym: c.xkb_keysym_t,
    action: keys.Action,
};

fn modsOf(raw: u32) u8 {
    var m: u8 = 0;
    if (raw & c.WLR_MODIFIER_SHIFT != 0) m |= keys.Mod.shift;
    if (raw & c.WLR_MODIFIER_CTRL != 0) m |= keys.Mod.ctrl;
    if (raw & c.WLR_MODIFIER_ALT != 0) m |= keys.Mod.alt;
    if (raw & c.WLR_MODIFIER_LOGO != 0) m |= keys.Mod.logo;
    return m;
}

fn keysymNamed(name: []const u8) ?c.xkb_keysym_t {
    const z = gpa.dupeSentinel(u8, name, 0) catch return null;
    defer gpa.free(z);
    var sym = c.xkb_keysym_from_name(z.ptr, c.XKB_KEYSYM_NO_FLAGS);
    if (sym == c.XKB_KEY_NoSymbol) sym = c.xkb_keysym_from_name(z.ptr, c.XKB_KEYSYM_CASE_INSENSITIVE);
    return if (sym == c.XKB_KEY_NoSymbol) null else sym;
}

fn clearBindings() void {
    for (server.bindings.items) |b| {
        switch (b.action) {
            .exec => |cmd| gpa.free(cmd),
            else => {},
        }
    }
    server.bindings.clearRetainingCapacity();
}

fn addBinding(key_text: []const u8, action_text: []const u8) void {
    const pk = keys.parseKey(key_text) orelse return;
    const sym = keysymNamed(pk.name) orelse {
        c._wlr_log(c.WLR_ERROR, "unknown key name in a shortcut: %.*s", @as(c_int, @intCast(pk.name.len)), pk.name.ptr);
        return;
    };
    var action = keys.parseAction(action_text) orelse return;
    // Whatever this key did before is replaced.
    var i: usize = 0;
    while (i < server.bindings.items.len) {
        const b = server.bindings.items[i];
        if (b.mods == pk.mods and b.sym == sym) {
            switch (b.action) {
                .exec => |cmd| gpa.free(cmd),
                else => {},
            }
            _ = server.bindings.orderedRemove(i);
        } else i += 1;
    }
    if (action == .none) return;
    if (action == .exec) action = .{ .exec = gpa.dupe(u8, action.exec) catch return };
    server.bindings.append(gpa, .{ .mods = pk.mods, .sym = sym, .action = action }) catch {};
}

/// The built-in shortcuts, then the user's from compositor.toml on top.
fn buildBindings(user: []const keys.Entry) void {
    clearBindings();
    for (keys.defaults) |d| addBinding(d.key, d.action);
    for (user) |e| addBinding(e.key, e.action);
}

fn runBinding(mods: u8, sym: c.xkb_keysym_t) bool {
    for (server.bindings.items) |b| {
        if (b.mods == mods and b.sym == sym) {
            perform(b.action);
            return true;
        }
    }
    return false;
}

fn isSuper(sym: c.xkb_keysym_t) bool {
    return sym == c.XKB_KEY_Super_L or sym == c.XKB_KEY_Super_R;
}

/// Runs a shell command in the background, without waiting for it.
fn runCommand(cmd: []const u8) void {
    const line = std.fmt.allocPrintSentinel(gpa, "{s} &", .{cmd}, 0) catch return;
    defer gpa.free(line);
    _ = c.system(line.ptr);
}

fn perform(action: keys.Action) void {
    switch (action) {
        .none => {},
        .quit => c.wl_display_terminate(server.display),
        .close => if (topWindow()) |t| t.sendClose(),
        .next_window => {
            // The window at the bottom of this workspace comes to the top.
            for (server.toplevels.items) |t| {
                if (!t.minimized and t.workspace == server.ws.active) {
                    focus(t);
                    break;
                }
            }
        },
        .prev_window => {
            var seen: usize = 0;
            var i = server.toplevels.items.len;
            while (i > 0) : (i -= 1) {
                const t = server.toplevels.items[i - 1];
                if (t.minimized or t.workspace != server.ws.active) continue;
                seen += 1;
                if (seen == 2) {
                    focus(t);
                    break;
                }
            }
        },
        .maximize => if (topWindow()) |t| setMaximized(t, !t.maximized),
        .fullscreen => if (topWindow()) |t| setFullscreen(t, !t.fullscreen),
        .float => toggleWindowFloating(),
        .toggle_layout => togglePolicy(),
        .workspace => |n| switchWorkspace(n),
        .workspace_prev => switchWorkspace((server.ws.active + server.ws.count - 1) % server.ws.count),
        .workspace_next => switchWorkspace((server.ws.active + 1) % server.ws.count),
        .move_to_workspace => |n| moveWindowToWorkspace(n),
        .move_to_prev => moveWindowToWorkspace((server.ws.active + server.ws.count - 1) % server.ws.count),
        .move_to_next => moveWindowToWorkspace((server.ws.active + 1) % server.ws.count),
        .snap => |region| if (topWindow()) |t| snapTo(t, region),
        .exec => |cmd| runCommand(cmd),
    }
}

/// Puts a window in a part of the screen and keeps it out of the tiling.
fn snapTo(t: *Toplevel, region: keys.Region) void {
    if (t.maximized) {
        t.maximized = false;
        t.setMaxFlag(false);
    }
    t.floating = true;
    t.cell = null;
    t.saved = null;
    t.setTiledEdges(0);
    place(t, layout.regionRect(workArea(), region));
    arrange();
}

// ---- input settings --------------------------------------------------------------------------------------------

/// The `[input]` settings, kept as C strings for xkb.
var xkb_layout: ?[:0]u8 = null;
var xkb_variant: ?[:0]u8 = null;
var xkb_options: ?[:0]u8 = null;
var input_settings: config.Input = .{};

fn replaceString(slot: *?[:0]u8, value: ?[]const u8) void {
    if (slot.*) |old| gpa.free(old);
    slot.* = if (value) |v| gpa.dupeSentinel(u8, v, 0) catch null else null;
}

fn applyKeymap(keyboard: *c.wlr_keyboard) void {
    // Null names fall back to XKB_DEFAULT_LAYOUT and friends, which labwc's environment file may set.
    var names = std.mem.zeroes(c.xkb_rule_names);
    if (xkb_layout) |v| names.layout = v.ptr;
    if (xkb_variant) |v| names.variant = v.ptr;
    if (xkb_options) |v| names.options = v.ptr;
    const context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS);
    defer c.xkb_context_unref(context);
    const keymap = c.xkb_keymap_new_from_names(context, &names, c.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse {
        c._wlr_log(c.WLR_ERROR, "the keyboard layout in compositor.toml is not valid; keeping the current one");
        return;
    };
    defer c.xkb_keymap_unref(keymap);
    _ = c.wlr_keyboard_set_keymap(keyboard, keymap);
    c.wlr_keyboard_set_repeat_info(keyboard, input_settings.repeat_rate, input_settings.repeat_delay);
}

fn configurePointer(device: *c.wlr_input_device) void {
    if (!c.wlr_input_device_is_libinput(device)) return;
    const li = c.wlr_libinput_get_device_handle(device) orelse return;
    if (input_settings.natural_scrolling) |v| {
        if (c.libinput_device_config_scroll_has_natural_scroll(li) != 0) _ = c.libinput_device_config_scroll_set_natural_scroll_enabled(li, @intFromBool(v));
    }
    if (input_settings.tap_to_click) |v| {
        if (c.libinput_device_config_tap_get_finger_count(li) > 0) {
            _ = c.libinput_device_config_tap_set_enabled(li, if (v) c.LIBINPUT_CONFIG_TAP_ENABLED else c.LIBINPUT_CONFIG_TAP_DISABLED);
        }
    }
    if (input_settings.pointer_speed) |v| {
        if (c.libinput_device_config_accel_is_available(li) != 0) _ = c.libinput_device_config_accel_set_speed(li, v);
    }
}

/// Puts the `[input]` settings on every device already plugged in.
fn applyInput() void {
    for (server.keyboards.items) |k| {
        if (!k.virtual) applyKeymap(k.keyboard);
    }
    for (server.pointers.items) |d| configurePointer(d);
}

/// labwc's `~/.config/labwc/environment` (KEY=VALUE lines; Settings > Keyboard writes XKB_DEFAULT_* there):
/// each variable not already set is set, so the layout chosen in Settings applies here too.
fn loadEnvironmentFile() void {
    var path_buf: [1024]u8 = undefined;
    const path = blk: {
        if (std.c.getenv("XDG_CONFIG_HOME")) |d| break :blk std.fmt.bufPrintSentinel(&path_buf, "{s}/labwc/environment", .{std.mem.span(d)}, 0) catch return;
        const home = std.c.getenv("HOME") orelse return;
        break :blk std.fmt.bufPrintSentinel(&path_buf, "{s}/.config/labwc/environment", .{std.mem.span(home)}, 0) catch return;
    };
    const text = readFile(path) orelse return;
    defer gpa.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        const kz = gpa.dupeSentinel(u8, key, 0) catch continue;
        defer gpa.free(kz);
        const vz = gpa.dupeSentinel(u8, value, 0) catch continue;
        defer gpa.free(vz);
        _ = c.setenv(kz.ptr, vz.ptr, 0);
    }
}

fn addKeyboard(device: *c.wlr_input_device, set_keymap: bool) void {
    const keyboard = c.wlr_keyboard_from_input_device(device);
    const k = gpa.create(Keyboard) catch return;
    k.* = .{ .keyboard = keyboard, .virtual = !set_keymap };

    // A virtual keyboard brings its own keymap; a real one gets ours.
    if (set_keymap) applyKeymap(keyboard);

    listen(&keyboard.*.events.modifiers, &k.modifiers, Keyboard.onModifiers);
    listen(&keyboard.*.events.key, &k.key, Keyboard.onKey);
    listen(&device.events.destroy, &k.destroy, Keyboard.onDestroy);
    c.wlr_seat_set_keyboard(server.seat, keyboard);
    server.keyboards.append(gpa, k) catch {};
}

fn onNewInput(_: ?*c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const device: *c.wlr_input_device = @ptrCast(@alignCast(data));
    switch (device.type) {
        c.WLR_INPUT_DEVICE_KEYBOARD => addKeyboard(device, true),
        c.WLR_INPUT_DEVICE_POINTER => {
            c.wlr_cursor_attach_input_device(server.cursor, device);
            server.pointers.append(gpa, device) catch {};
            configurePointer(device);
        },
        else => {},
    }
    var caps: u32 = c.WL_SEAT_CAPABILITY_POINTER;
    if (server.keyboards.items.len > 0) caps |= c.WL_SEAT_CAPABILITY_KEYBOARD;
    c.wlr_seat_set_capabilities(server.seat, caps);
}

/// Clients that ask for server-side decorations get client-side ones: the windows draw their own title bars.
const Decoration = struct {
    deco: *c.wlr_xdg_toplevel_decoration_v1,
    request_mode: c.wl_listener = std.mem.zeroes(c.wl_listener),
    destroy: c.wl_listener = std.mem.zeroes(c.wl_listener),

    fn apply(self: *Decoration) void {
        _ = c.wlr_xdg_toplevel_decoration_v1_set_mode(self.deco, c.WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE);
    }

    fn onRequestMode(listener: ?*c.wl_listener, _: ?*anyopaque) callconv(.c) void {
        const self: *Decoration = @fieldParentPtr("request_mode", listener.?);
        if (self.deco.toplevel.*.base.*.initialized) self.apply();
    }

    fn onDestroy(listener: ?*c.wl_listener, _: ?*anyopaque) callconv(.c) void {
        const self: *Decoration = @fieldParentPtr("destroy", listener.?);
        unlisten(&self.request_mode);
        unlisten(&self.destroy);
        gpa.destroy(self);
    }
};

fn onNewDecoration(_: ?*c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const deco: *c.wlr_xdg_toplevel_decoration_v1 = @ptrCast(@alignCast(data));
    const d = gpa.create(Decoration) catch return;
    d.* = .{ .deco = deco };
    listen(&deco.events.request_mode, &d.request_mode, Decoration.onRequestMode);
    listen(&deco.events.destroy, &d.destroy, Decoration.onDestroy);
    if (deco.toplevel.*.base.*.initialized) d.apply();
}

/// Tools that type and click for the user (on-screen keyboards, wtype, dkde-pointer, dkde-snap).
fn onNewVirtualKeyboard(_: ?*c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const vk: *c.wlr_virtual_keyboard_v1 = @ptrCast(@alignCast(data));
    addKeyboard(&vk.keyboard.base, false);
    var caps: u32 = c.WL_SEAT_CAPABILITY_POINTER | c.WL_SEAT_CAPABILITY_KEYBOARD;
    caps |= 0;
    c.wlr_seat_set_capabilities(server.seat, caps);
}

fn onNewVirtualPointer(_: ?*c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const event: *c.wlr_virtual_pointer_v1_new_pointer_event = @ptrCast(@alignCast(data));
    c.wlr_cursor_attach_input_device(server.cursor, &event.new_pointer.*.pointer.base);
}

fn onRequestSetPrimary(_: ?*c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const event: *c.wlr_seat_request_set_primary_selection_event = @ptrCast(@alignCast(data));
    c.wlr_seat_set_primary_selection(server.seat, event.source, event.serial);
}

/// wp-cursor-shape: the client names a shape ("pointer", "text") instead of sending an image.
fn onRequestSetShape(_: ?*c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const event: *c.wlr_cursor_shape_manager_v1_request_set_shape_event = @ptrCast(@alignCast(data));
    if (server.seat.*.pointer_state.focused_client != event.seat_client) return;
    c.wlr_cursor_set_xcursor(server.cursor, server.cursor_mgr, c.wlr_cursor_shape_v1_name(event.shape));
}

/// Anything the user does counts as activity for the idle timers (screen lock, blanking).
fn noteActivity() void {
    c.wlr_idle_notifier_v1_notify_activity(server.idle, server.seat);
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
    buildBindings(cfg.keys);
    input_settings = cfg.input;
    replaceString(&xkb_layout, cfg.input.layout);
    replaceString(&xkb_variant, cfg.input.variant);
    replaceString(&xkb_options, cfg.input.options);
    input_settings.layout = null;
    input_settings.variant = null;
    input_settings.options = null;
    config.free(gpa, cfg);
    cfg.keys = &.{};
    const was = server.policy;
    applyInput();
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

/// Settings (and the person's editor) rewrite compositor.toml; apply it as soon as it changes, without a signal.
var config_watch_fd: c_int = -1;
var config_name_buf: [256]u8 = undefined;
var config_name: []const u8 = "compositor.toml";

fn onConfigFileChanged(fd: c_int, _: u32, _: ?*anyopaque) callconv(.c) c_int {
    var buf: [4096]u8 align(@alignOf(c.struct_inotify_event)) = undefined;
    var changed = false;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n <= 0) break;
        var off: usize = 0;
        while (off < @as(usize, @intCast(n))) {
            const ev: *const c.struct_inotify_event = @ptrCast(@alignCast(&buf[off]));
            const name_ptr: [*]const u8 = @ptrCast(&buf[off + @sizeOf(c.struct_inotify_event)]);
            if (ev.len > 0 and std.mem.eql(u8, std.mem.sliceTo(name_ptr[0..ev.len], 0), config_name)) changed = true;
            off += @sizeOf(c.struct_inotify_event) + ev.len;
        }
    }
    if (changed) {
        c._wlr_log(c.WLR_INFO, "compositor.toml changed; reloading the settings");
        loadConfig();
    }
    return 0;
}

fn watchConfigFile(display: *c.wl_display) void {
    var path_buf: [1024]u8 = undefined;
    const path = configPath(&path_buf) orelse return;
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
    var dir_buf: [1024]u8 = undefined;
    const dir = std.fmt.bufPrintSentinel(&dir_buf, "{s}", .{path[0..slash]}, 0) catch return;
    _ = c.mkdir(dir.ptr, 0o755);
    const base = path[slash + 1 ..];
    if (base.len > config_name_buf.len) return;
    @memcpy(config_name_buf[0..base.len], base);
    config_name = config_name_buf[0..base.len];
    const fd = c.inotify_init1(c.IN_NONBLOCK | c.IN_CLOEXEC);
    if (fd < 0) return;
    if (c.inotify_add_watch(fd, dir.ptr, c.IN_CLOSE_WRITE | c.IN_MOVED_TO) < 0) {
        _ = c.close(fd);
        return;
    }
    config_watch_fd = fd;
    _ = c.wl_event_loop_add_fd(c.wl_display_get_event_loop(display), fd, c.WL_EVENT_READABLE, onConfigFileChanged, null);
}

/// SIGTERM or SIGINT: end the session (Settings' "Log Off" sends SIGTERM).
fn onTerminate(_: c_int, data: ?*anyopaque) callconv(.c) c_int {
    c.wl_display_terminate(@ptrCast(@alignCast(data)));
    return 0;
}

// ---- autostart -----------------------------------------------------------------------------------------------

/// What a session needs running beside the compositor: the same as dkde's labwc autostart. A user's own
/// `~/.config/dkde/autostart` (a shell script) replaces it. Set DKDE_NO_AUTOSTART to start nothing (tests).
const default_autostart =
    "(while [ -S \"$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY\" ]; do dkde-panel; sleep 1; done) &\n" ++
    "[ -f \"${XDG_CONFIG_HOME:-$HOME/.config}/dkde/display.sh\" ] && sh \"${XDG_CONFIG_HOME:-$HOME/.config}/dkde/display.sh\" &\n" ++
    "dkde-idle &\n" ++
    "command -v pkexec >/dev/null 2>&1 && dkde-polkit &\n";

fn runAutostart() void {
    if (std.c.getenv("DKDE_NO_AUTOSTART") != null) return;
    var path_buf: [1024]u8 = undefined;
    const user_script: ?[:0]const u8 = blk: {
        if (std.c.getenv("XDG_CONFIG_HOME")) |d| break :blk std.fmt.bufPrintSentinel(&path_buf, "{s}/dkde/autostart", .{std.mem.span(d)}, 0) catch null;
        const home = std.c.getenv("HOME") orelse break :blk null;
        break :blk std.fmt.bufPrintSentinel(&path_buf, "{s}/.config/dkde/autostart", .{std.mem.span(home)}, 0) catch null;
    };
    if (user_script) |path| {
        if (c.access(path.ptr, c.R_OK) == 0) {
            runCommand(std.fmt.allocPrint(gpa, "sh \"{s}\"", .{path}) catch return);
            return;
        }
    }
    // Written to a file first: the script has quotes of its own.
    const script_path = std.fmt.bufPrintSentinel(&path_buf, "{s}/dkde-compositor-autostart.sh", .{if (std.c.getenv("XDG_RUNTIME_DIR")) |r| std.mem.span(r) else "/tmp"}, 0) catch return;
    const file = c.fopen(script_path.ptr, "wb") orelse return;
    _ = c.fwrite(default_autostart.ptr, 1, default_autostart.len, file);
    _ = c.fclose(file);
    var cmd_buf: [1100]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "sh {s}", .{script_path}) catch return;
    runCommand(cmd);
}

// ---- start ---------------------------------------------------------------------------------------------------

const version = "0.3.0";

const help_text =
    "dkde-compositor - DKDE's own Wayland compositor (experimental)\n\n" ++
    "Usage: dkde-compositor\n\n" ++
    "  -h, --help     show this help and exit\n" ++
    "  -V, --version  show the version and exit\n\n" ++
    "Settings: ~/.config/dkde/compositor.toml (see dkde-compositor(1)).\n";

pub fn main(init: std.process.Init.Minimal) !void {
    // The command-line contract every dkde program follows: --help and --version exit 0; an unknown option exits 2.
    for (init.args.vector[1..]) |arg_z| {
        const arg = std.mem.span(arg_z);
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            _ = std.c.write(1, help_text.ptr, help_text.len);
            return;
        }
        if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
            const text = "dkde-compositor " ++ version ++ "\n";
            _ = std.c.write(1, text.ptr, text.len);
            return;
        }
        if (arg.len > 0 and arg[0] == '-') {
            const text = "dkde-compositor: unknown option\nTry 'dkde-compositor --help'.\n";
            _ = std.c.write(2, text.ptr, text.len);
            std.process.exit(2);
        }
    }
    loadEnvironmentFile();
    c.wlr_log_init(if (std.c.getenv("DKDE_DEBUG") != null) c.WLR_DEBUG else c.WLR_INFO, null);

    const display = c.wl_display_create() orelse return error.NoDisplay;
    const backend = c.wlr_backend_autocreate(c.wl_display_get_event_loop(display), null) orelse return error.NoBackend;
    const renderer = c.wlr_renderer_autocreate(backend) orelse return error.NoRenderer;
    _ = c.wlr_renderer_init_wl_display(renderer, display);
    const allocator = c.wlr_allocator_autocreate(backend, renderer) orelse return error.NoAllocator;

    // The protocols every client expects.
    const compositor = c.wlr_compositor_create(display, 5, renderer) orelse return error.NoProtocol;
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
    const decoration_manager = c.wlr_xdg_decoration_manager_v1_create(display) orelse return error.NoProtocol;
    const virtual_keyboard = c.wlr_virtual_keyboard_manager_v1_create(display) orelse return error.NoProtocol;
    const virtual_pointer = c.wlr_virtual_pointer_manager_v1_create(display) orelse return error.NoProtocol;
    _ = c.wlr_primary_selection_v1_device_manager_create(display);
    _ = c.wlr_viewporter_create(display);
    _ = c.wlr_fractional_scale_manager_v1_create(display, 1);
    const shape_manager = c.wlr_cursor_shape_manager_v1_create(display, 1) orelse return error.NoProtocol;
    const idle = c.wlr_idle_notifier_v1_create(display) orelse return error.NoProtocol;
    const output_manager = c.wlr_output_manager_v1_create(display) orelse return error.NoProtocol;
    const session_lock = c.wlr_session_lock_manager_v1_create(display) orelse return error.NoProtocol;
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
        .idle = idle,
        .output_manager = output_manager,
        .session_lock = session_lock,
        .cursor = cursor,
        .cursor_mgr = cursor_mgr,
        .seat = seat,
    };

    workspaces.init(display, &server.ws);
    loadConfig();
    _ = c.wl_event_loop_add_signal(c.wl_display_get_event_loop(display), c.SIGHUP, onReload, null);
    _ = c.wl_event_loop_add_signal(c.wl_display_get_event_loop(display), c.SIGTERM, onTerminate, display);
    _ = c.wl_event_loop_add_signal(c.wl_display_get_event_loop(display), c.SIGINT, onTerminate, display);
    watchConfigFile(display);
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
    listen(&session_lock.*.events.new_lock, &server.new_lock, onNewLock);
    listen(&output_manager.*.events.apply, &server.output_apply, onOutputApply);
    listen(&output_manager.*.events.@"test", &server.output_test, onOutputTest);
    listen(&decoration_manager.*.events.new_toplevel_decoration, &server.new_decoration, onNewDecoration);
    listen(&virtual_keyboard.*.events.new_virtual_keyboard, &server.new_virtual_keyboard, onNewVirtualKeyboard);
    listen(&virtual_pointer.*.events.new_virtual_pointer, &server.new_virtual_pointer, onNewVirtualPointer);
    listen(&shape_manager.*.events.request_set_shape, &server.request_set_shape, onRequestSetShape);
    listen(&seat.*.events.request_set_primary_selection, &server.request_set_primary, onRequestSetPrimary);
    listen(&seat.*.events.request_set_cursor, &server.request_cursor, onRequestCursor);
    listen(&seat.*.pointer_state.events.focus_change, &server.pointer_focus_change, onPointerFocusChange);
    listen(&seat.*.events.request_set_selection, &server.request_set_selection, onRequestSetSelection);

    // X11 programs: Xwayland starts when the first one connects.
    var xwayland: ?*c.wlr_xwayland = null;
    if (std.c.getenv("DKDE_NO_XWAYLAND") == null) {
        xwayland = c.wlr_xwayland_create(display, compositor, true);
        if (xwayland) |xw| {
            listen(&xw.events.new_surface, &server.new_x_surface, onNewXSurface);
            c.wlr_xwayland_set_seat(xw, seat);
            _ = c.setenv("DISPLAY", xw.display_name, 1);
        }
    }

    const socket = c.wl_display_add_socket_auto(display) orelse return error.NoSocket;
    if (!c.wlr_backend_start(backend)) return error.BackendStart;
    _ = c.setenv("WAYLAND_DISPLAY", socket, 1);
    c._wlr_log(c.WLR_INFO, "dkde-compositor running on WAYLAND_DISPLAY=%s", socket);
    // Programs started by the session (Settings, the panel) learn who runs it, to find its config and to end it.
    _ = c.setenv("DKDE_SESSION_COMPOSITOR", "dkde-compositor", 1);
    var pid_buf: [24]u8 = undefined;
    if (std.fmt.bufPrintSentinel(&pid_buf, "{d}", .{c.getpid()}, 0)) |pid| _ = c.setenv("DKDE_SESSION_PID", pid.ptr, 1) else |_| {}
    runAutostart();

    c.wl_display_run(display);

    workspaces.deinit();
    if (xwayland) |xw| {
        unlisten(&server.new_x_surface);
        c.wlr_xwayland_destroy(xw);
    }
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
    unlisten(&server.new_lock);
    unlisten(&server.output_apply);
    unlisten(&server.output_test);
    unlisten(&server.new_decoration);
    unlisten(&server.new_virtual_keyboard);
    unlisten(&server.new_virtual_pointer);
    unlisten(&server.request_set_shape);
    unlisten(&server.request_set_primary);
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
