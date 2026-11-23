//! dkde-compositor, milestone 0: a minimal floating Wayland compositor on
//! wlroots (through Zig's C interop), in the shape of wlroots' `tinywl`.
//!
//! What it does: runs nested in another Wayland session (or headless, with
//! WLR_BACKENDS=headless), shows xdg-shell windows, gives them keyboard and
//! pointer focus, and lets Alt+left-drag move and Alt+right-drag resize them.
//! Super+Shift+Escape quits; Alt+F1 raises the next window; Super+T switches between
//! floating and tiling; Alt+Shift+Space floats or tiles the focused window.
//!
//! The window layout is a policy (see `layout.zig`): floating now, tiling next.

const std = @import("std");
const c = @import("c");
const layout = @import("layout.zig");
const config = @import("config.zig");
const workspaces = @import("workspaces.zig");
const keys = @import("keys.zig");
const developer = @import("developer.zig");
const place_mod = @import("place.zig");
const rules = @import("rules.zig");
const anim = @import("anim.zig");
const render = @import("render.zig");
const overview = @import("overview.zig");
const gfx = @import("gfx.zig");
const filters = @import("filters.zig");
const wobble_mod = @import("wobble.zig");
const cube_mod = @import("cube.zig");
const snow_mod = @import("snow.zig");
const fire_mod = @import("fire.zig");

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
    /// [windows] placement, snap-windows, inactive-opacity and the [[rules]].
    placement: config.Placement = .cascade,
    snap_windows: bool = true,
    inactive_opacity: f32 = 1.0,
    rules: []const rules.Rule = &.{},
    effects: config.Effects = .{},
    /// Windows with an animation running; while there are any, frames are composed by `render` instead of the scene output.
    animating: usize = 0,
    /// Whether the last frame was composed by `render` (the scene's damage then has to start over).
    custom_drawn: bool = false,
    /// Scale or Expo, while it is up.
    overview: ?*Overview = null,
    /// The GLES composer (null with another renderer: the effects that need shaders are then off).
    gfx: ?*gfx.Gfx = null,
    /// Screen magnification (1 = off): where it is going, and where it is now (it eases).
    zoom_target: f32 = 1,
    zoom_now: f32 = 1,
    zoom_ms: u32 = 0,
    wobble_ms: u32 = 0,
    /// The cube turning from one workspace to another, while it does.
    cube: ?CubeTurn = null,
    snow: ?snow_mod.Snow = null,
    snow_ms: u32 = 0,
    /// The pointer finder: when it started (0 = not showing).
    finder_ms: u32 = 0,
    sprite_list: std.ArrayList(gfx.Sprite) = .empty,
    /// Windows that have closed and are fading out, and the same for this frame in the form the composer takes.
    ghosts: std.ArrayList(GhostRec) = .empty,
    ghost_out: std.ArrayList(gfx.Ghost) = .empty,
    lens_on: bool = false,
    fire: ?fire_mod.Fire = null,
    fire_on: bool = false,
    fire_ms: u32 = 0,
    paint_on: bool = false,
    paint_down: bool = false,
    paint_pts: std.ArrayList([2]f32) = .empty,
    ripples: [gfx.Post.max_ripples]RippleRec = std.mem.zeroes([gfx.Post.max_ripples]RippleRec),
    ripple_last: [2]f64 = .{ -1000, -1000 },
    filter: filters.Filter = .none,
    layout_options: layout.Options = .{},
    /// Edge snapping while a window is dragged: on or off (compositor.toml), the zone under the pointer and its preview.
    edge_snap: bool = true,
    snap_target: ?layout.Target = null,
    /// The overlay zone the drop landed on (layout, zone), for snap assist.
    snap_hit: ?layout.ZoneIndex = null,
    snap_preview: ?*c.wlr_scene_rect = null,
    /// The layout card shown at the top of the screen while dragging (built from scene rectangles).
    overlay_on: bool = false,
    overlay_tree: ?*c.wlr_scene_tree = null,
    overlay_box: layout.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    overlay_zones: [layout.snap_layouts.len][4]?*c.wlr_scene_rect = std.mem.zeroes([layout.snap_layouts.len][4]?*c.wlr_scene_rect),
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

const CubeTurn = struct { from: usize, to: usize, start_ms: u32 };

/// A closed window's last picture, held (locked) until it has faded.
const GhostRec = struct { buf: *c.wlr_client_buffer, x: f32, y: f32, w: f32, h: f32, start_ms: u32 };

const RippleRec = struct { x: f32 = 0, y: f32 = 0, start_ms: u32 = 0, live: bool = false };

/// While the cube draws one workspace's face: that workspace (the scene then shows only its windows).
var face_filter: ?usize = null;

fn setFaceFilter(ws: ?usize) void {
    face_filter = ws;
}

const Output = struct {
    output: *c.wlr_output,
    frame: c.wl_listener = std.mem.zeroes(c.wl_listener),
    request_state: c.wl_listener = std.mem.zeroes(c.wl_listener),
    destroy: c.wl_listener = std.mem.zeroes(c.wl_listener),

    fn onFrame(listener: ?*c.wl_listener, _: ?*anyopaque) callconv(.c) void {
        const self: *Output = @fieldParentPtr("frame", listener.?);
        const scene_output = c.wlr_scene_get_scene_output(server.scene, self.output) orelse return;
        // std's timespec rather than the C one: musl's is an opaque type to translate-c.
        var now: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &now);
        tickAnimations(nowMs(&now));
        tickZoom(nowMs(&now));
        tickWobbles(nowMs(&now));
        const post = currentPost(self.output);
        const wobbling = anyWobble();
        const cube = currentCube(nowMs(&now));
        const sprites = currentSprites(nowMs(&now), self.output);
        const ghosts = currentGhosts(nowMs(&now));
        if (server.animating > 0 or server.overview != null or post.active() or wobbling or blurNeeded() or cube != null or sprites.len > 0 or ghosts.len > 0) {
            const drawn = if (server.gfx) |g|
                g.compose(self.output, server.output_layout, &server.scene.*.tree, xfOf, post, cube, sprites, ghosts)
            else
                render.compose(self.output, server.output_layout, &server.scene.*.tree, xfOf);
            if (drawn) {
                server.custom_drawn = true;
            } else {
                _ = c.wlr_scene_output_commit(scene_output, null);
            }
            if (server.animating > 0 or overviewMoving() or zoomMoving() or wobbling or cube != null or sprites.len > 0 or ghosts.len > 0 or post.ripple_count > 0) c.wlr_output_schedule_frame(self.output);
        } else {
            if (server.custom_drawn) {
                // The scene output does not know what was drawn behind its back.
                c.wlr_damage_ring_add_whole(&scene_output.*.damage_ring);
                server.custom_drawn = false;
            }
            _ = c.wlr_scene_output_commit(scene_output, null);
        }
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
    /// Visible on every workspace.
    sticky: bool = false,
    /// Kept above or below the other windows.
    above: bool = false,
    below: bool = false,
    /// The window's own opacity (1 = opaque); dimming for focus comes on top of it.
    opacity: f32 = 1.0,
    anim: ?anim.Anim = null,
    /// Wobbly windows: the spring mesh while the window swings, and where the window was last frame.
    wobble: ?*wobble_mod.Wobble = null,
    /// The window's latest picture (locked), kept so a close animation has something to draw, and where it was.
    snap: ?*c.wlr_client_buffer = null,
    snap_rect: [4]f32 = .{ 0, 0, 0, 0 },
    last_geom: ?layout.Rect = null,
    /// Minimized by Show Desktop, so that it can bring it back.
    hidden_by_desktop: bool = false,
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
        // The [[rules]] that match this window, then where it goes (a cascade spot unless asked otherwise, so
        // the place it goes back to when tiling is switched off is a good one).
        const rule = rules.resolve(server.rules, spanOrEmpty(self.appId()), spanOrEmpty(self.title()));
        applyRule(self, rule);
        placeNew(self, rule);
        server.opened += 1;
        addHandle(self);
        showIfVisible(self);
        if (onActiveWorkspace(self)) focus(self);
        updateStacking();
        applyOpacity(self);
        if (onActiveWorkspace(self)) startAnimation(self, .open);
        if (rule.maximized == true) setMaximized(self, true);
        if (rule.fullscreen == true) setFullscreen(self, true);
        arrange();
    }

    fn onUnmap(listener: ?*c.wl_listener, _: ?*anyopaque) callconv(.c) void {
        const self: *Toplevel = @fieldParentPtr("unmap", listener.?);
        if (self.unmanaged()) return;
        if (server.grabbed == self) resetCursorMode();
        overviewForget(self);
        freeWobble(self);
        startGhost(self);
        if (self.anim != null) {
            self.anim = null;
            if (server.animating > 0) server.animating -= 1;
        }
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
        // New surfaces of the window (menus, subsurfaces) start opaque.
        if (self.opacity != 1.0 or server.inactive_opacity != 1.0 or server.effects.trailfocus) applyOpacity(self);
        if (server.effects.animations and server.gfx != null) self.snapshot();
    }

    /// Keeps the window's current picture, so that closing it can fade it out.
    fn snapshot(self: *Toplevel) void {
        const surface = self.surf() orelse return;
        const buf = surface.*.buffer orelse return;
        if (self.snap != buf) {
            _ = c.wlr_buffer_lock(&buf.*.base);
            self.releaseSnap();
            self.snap = buf;
        }
        var gx: i32 = 0;
        var gy: i32 = 0;
        if (self.xdg) |x| {
            gx = x.base.*.geometry.x;
            gy = x.base.*.geometry.y;
        }
        self.snap_rect = .{
            @floatFromInt(self.tree.*.node.x - gx),
            @floatFromInt(self.tree.*.node.y - gy),
            @floatFromInt(surface.*.current.width),
            @floatFromInt(surface.*.current.height),
        };
    }

    fn releaseSnap(self: *Toplevel) void {
        if (self.snap) |b| c.wlr_buffer_unlock(&b.*.base);
        self.snap = null;
    }

    fn onDestroy(listener: ?*c.wl_listener, _: ?*anyopaque) callconv(.c) void {
        const self: *Toplevel = @fieldParentPtr("destroy", listener.?);
        self.releaseSnap();
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
    if (!onActiveWorkspace(t)) switchWorkspace(t.workspace);
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
    if (server.effects.animations and onActiveWorkspace(t)) {
        // Minimizing: the window stays drawn until the animation ends (finishAnimation hides it).
        // Restoring: it is shown now and grows back.
        if (minimized) {
            startAnimation(t, .minimize);
        } else {
            showIfVisible(t);
            startAnimation(t, .restore);
        }
    } else showIfVisible(t);
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
fn onActiveWorkspace(t: *const Toplevel) bool {
    return t.sticky or t.workspace == server.ws.active;
}

fn showIfVisible(t: *Toplevel) void {
    c.wlr_scene_node_set_enabled(&t.tree.*.node, !t.minimized and onActiveWorkspace(t));
}

/// The window on top among those on the current workspace, if any.
fn topWindow() ?*Toplevel {
    var i = server.toplevels.items.len;
    while (i > 0) : (i -= 1) {
        const t = server.toplevels.items[i - 1];
        if (!t.minimized and onActiveWorkspace(t)) return t;
    }
    return null;
}

fn switchWorkspace(index: usize) void {
    if (index >= server.ws.count or index == server.ws.active) return;
    if (server.effects.cube and server.gfx != null and server.ws.count >= 3 and server.overview == null) {
        server.cube = .{ .from = server.ws.active, .to = index, .start_ms = currentMs() };
        wakeOutputs();
    }
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
        if (!t.floating and !t.minimized and !t.maximized and !t.fullscreen and !t.sticky and t.workspace == server.ws.active) tiled.append(gpa, t) catch return;
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
// ---- Scale and Expo --------------------------------------------------------------------------------------------

const Entry = struct {
    t: *Toplevel,
    /// Where the window is, and how big (its content), when the overview opens.
    x: i32,
    y: i32,
    size: overview.Size,
    /// Where the overview puts it.
    target: overview.Place,
    /// Expo: the workspace tile it sits on.
    tile: usize = 0,
    /// Where the switcher last drew it (for clicks).
    shown: layout.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
};

const Overview = struct {
    expo: bool,
    start_ms: u32,
    closing: bool = false,
    entries: std.ArrayList(Entry) = .empty,
    screen: layout.Rect,
    tiles: overview.Tiles = undefined,
    bg: *c.wlr_scene_tree,
    tile_rects: std.ArrayList(*c.wlr_scene_rect) = .empty,
    highlight: ?*c.wlr_scene_rect = null,
    /// The entry and the workspace tile under the pointer.
    hover: ?usize = null,
    hover_tile: ?usize = null,
    /// A press on an entry: it is dragged to another tile (Expo) or picked on release.
    press: ?usize = null,
    /// The workspace that closing switches to (Expo).
    pick_ws: ?usize = null,
    /// The Alt+Tab switcher (a strip or a ring of previews): the chosen window, and the animated position between them.
    switcher: config.Switcher = .off,
    sel: usize = 0,
    pos_from: f32 = 0,
    pos_to: f32 = 0,
    pos_start: u32 = 0,

    fn duration() u32 {
        return if (server.effects.animations) server.effects.animation_ms else 0;
    }

    /// 0 = windows where they are, 1 = laid out in the overview.
    fn progress(self: *const Overview) f32 {
        const f = anim.fraction(.{ .kind = .open, .start_ms = self.start_ms, .duration_ms = duration() }, currentMs());
        const e = anim.easeOut(f);
        return if (self.closing) 1 - e else e;
    }

    /// The switcher's position, easing from one window to the next.
    fn posNow(self: *const Overview) f32 {
        const f = anim.fraction(.{ .kind = .open, .start_ms = self.pos_start, .duration_ms = duration() }, currentMs());
        return self.pos_from + (self.pos_to - self.pos_from) * anim.easeOut(f);
    }

    fn posMoving(self: *const Overview) bool {
        return self.switcher != .off and !anim.done(.{ .kind = .open, .start_ms = self.pos_start, .duration_ms = duration() }, currentMs());
    }

    fn finished(self: *const Overview) bool {
        return anim.done(.{ .kind = .open, .start_ms = self.start_ms, .duration_ms = duration() }, currentMs());
    }

    fn entryFor(self: *const Overview, t: *const Toplevel) ?usize {
        for (self.entries.items, 0..) |e, i| {
            if (e.t == t) return i;
        }
        return null;
    }

    fn xfFor(self: *Overview, t: *Toplevel) ?anim.Xf {
        const i = self.entryFor(t) orelse return null;
        const e = self.entries.items[i];
        var p = self.progress();
        var alpha: f32 = 1;
        if (self.switcher != .off) {
            const pos = self.posNow();
            const th = if (self.switcher == .ring)
                overview.ringThumb(self.screen, e.size, i, self.entries.items.len, pos)
            else
                overview.stripThumb(self.screen, e.size, i, pos);
            const w: f32 = @floatFromInt(e.size.w);
            const h: f32 = @floatFromInt(e.size.h);
            const left = th.cx - w * th.scale / 2;
            const top = th.cy - h * th.scale / 2;
            self.entries.items[i].shown = .{ .x = @intFromFloat(left), .y = @intFromFloat(top), .w = @intFromFloat(w * th.scale), .h = @intFromFloat(h * th.scale) };
            return .{
                .scale = 1 + (th.scale - 1) * p,
                .ax = @floatFromInt(e.x),
                .ay = @floatFromInt(e.y),
                .tx = (left - @as(f32, @floatFromInt(e.x))) * p,
                .ty = (top - @as(f32, @floatFromInt(e.y))) * p,
                .alpha = 1 + (th.alpha - 1) * p,
                .force = true,
            };
        }
        if (self.closing and self.expo) {
            // Windows of the other workspaces stay on their tile and fade; the picked workspace's grow back.
            if (self.pick_ws != null and e.tile != self.pick_ws.?) {
                alpha = p;
                p = 1;
            }
        }
        var tx = e.target.x;
        var ty = e.target.y;
        var scale = e.target.scale;
        if (self.press) |pi| {
            if (pi == i and self.expo and !self.closing) {
                // Dragged: the thumbnail follows the pointer.
                scale = self.tiles.scale(self.screen);
                tx = @as(i32, @intFromFloat(server.cursor.*.x)) - @as(i32, @intFromFloat(@as(f32, @floatFromInt(e.size.w)) * scale / 2));
                ty = @as(i32, @intFromFloat(server.cursor.*.y)) - @as(i32, @intFromFloat(@as(f32, @floatFromInt(e.size.h)) * scale / 2));
                p = 1;
            }
        }
        return .{
            .scale = 1 + (scale - 1) * p,
            .ax = @floatFromInt(e.x),
            .ay = @floatFromInt(e.y),
            .tx = @as(f32, @floatFromInt(tx - e.x)) * p,
            .ty = @as(f32, @floatFromInt(ty - e.y)) * p,
            .alpha = alpha,
            .force = true,
        };
    }

    /// The thumbnail rectangles in layout coordinates, for hit tests.
    fn thumb(e: Entry) layout.Rect {
        if (e.shown.w > 0) return e.shown;
        return .{ .x = e.target.x, .y = e.target.y, .w = @intFromFloat(@as(f32, @floatFromInt(e.size.w)) * e.target.scale), .h = @intFromFloat(@as(f32, @floatFromInt(e.size.h)) * e.target.scale) };
    }

    fn entryAt(self: *const Overview, px: i32, py: i32) ?usize {
        // Front to back: the entries are in stacking order.
        var i = self.entries.items.len;
        while (i > 0) : (i -= 1) {
            const r = thumb(self.entries.items[i - 1]);
            if (px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h) return i - 1;
        }
        return null;
    }
};

const overlay_dim = [4]f32{ 0, 0, 0, 0.55 };
const tile_fill = [4]f32{ 0.10, 0.11, 0.14, 1 };
const tile_hover = [4]f32{ 0.21, 0.52, 0.89, 1 };

fn overviewMoving() bool {
    const ov = server.overview orelse return false;
    return !ov.finished() or ov.posMoving();
}

fn openOverview(expo: bool) void {
    if (server.locked) return;
    if (server.overview) |ov| {
        // The same key again closes it.
        _ = ov;
        closeOverview(null);
        return;
    }
    if (expo and !server.effects.expo) return;
    if (!expo and !server.effects.scale) return;
    if (server.cursor_mode != .passthrough) return;
    const ov = gpa.create(Overview) catch return;
    const bg = c.wlr_scene_tree_create(server.trees[1]) orelse {
        gpa.destroy(ov);
        return;
    };
    ov.* = .{ .expo = expo, .start_ms = currentMs(), .screen = screenArea(), .bg = bg };
    server.overview = ov;
    c.wlr_seat_pointer_clear_focus(server.seat);

    var visible: std.ArrayList(*Toplevel) = .empty;
    defer visible.deinit(gpa);
    for (server.toplevels.items) |t| {
        if (t.minimized or t.unmanaged()) continue;
        if (!expo and !onActiveWorkspace(t)) continue;
        visible.append(gpa, t) catch {};
    }
    const screen = ov.screen;
    _ = sceneRect(bg, screen, overlay_dim);
    if (expo) {
        ov.highlight = sceneRect(bg, .{ .x = 0, .y = 0, .w = 10, .h = 10 }, tile_hover);
        ov.tiles = overview.expoTiles(screen, server.ws.count, @max(12, @divTrunc(screen.w, 60)));
        var i: usize = 0;
        while (i < server.ws.count) : (i += 1) {
            if (sceneRect(bg, ov.tiles.rect(i), tile_fill)) |r| ov.tile_rects.append(gpa, r) catch {};
        }
        for (visible.items) |t| {
            const g = geometryOf(t);
            const tile = if (t.sticky) server.ws.active else t.workspace;
            ov.entries.append(gpa, .{ .t = t, .x = g.x, .y = g.y, .size = .{ .w = g.w, .h = g.h }, .target = ov.tiles.place(screen, tile, g.x, g.y), .tile = tile }) catch {};
        }
        ov.hover_tile = server.ws.active;
    } else {
        const area = workArea();
        const sizes = gpa.alloc(overview.Size, visible.items.len) catch return;
        defer gpa.free(sizes);
        const places = gpa.alloc(overview.Place, visible.items.len) catch return;
        defer gpa.free(places);
        for (visible.items, 0..) |t, k| {
            const g = geometryOf(t);
            sizes[k] = .{ .w = g.w, .h = g.h };
        }
        overview.scaleCells(area, sizes, @max(16, @divTrunc(area.w, 50)), places);
        for (visible.items, 0..) |t, k| {
            const g = geometryOf(t);
            ov.entries.append(gpa, .{ .t = t, .x = g.x, .y = g.y, .size = sizes[k], .target = places[k] }) catch {};
        }
    }
    updateOverviewHover();
    wakeOutputs();
}

/// Closes the overview; `pick` is the window to focus, `ws` the workspace to go to (Expo).
fn closeOverview(pick: ?*Toplevel) void {
    const ov = server.overview orelse return;
    if (ov.closing) return;
    ov.closing = true;
    ov.start_ms = currentMs();
    ov.press = null;
    if (ov.expo) {
        const ws = if (pick) |t| (if (t.sticky) server.ws.active else t.workspace) else (ov.hover_tile orelse server.ws.active);
        ov.pick_ws = ws;
        if (ws != server.ws.active) switchWorkspace(ws);
    }
    if (pick) |t| {
        if (t.minimized) setMinimized(t, false);
        focus(t);
    }
    wakeOutputs();
}

fn destroyOverview() void {
    const ov = server.overview orelse return;
    c.wlr_scene_node_destroy(&ov.bg.*.node);
    ov.entries.deinit(gpa);
    ov.tile_rects.deinit(gpa);
    server.overview = null;
    gpa.destroy(ov);
    // The scene output redraws everything when the normal path takes over again.
    wakeOutputs();
}

/// A window went away while the overview was up.
fn overviewForget(t: *Toplevel) void {
    const ov = server.overview orelse return;
    const i = ov.entryFor(t) orelse return;
    _ = ov.entries.orderedRemove(i);
    ov.hover = null;
    ov.press = null;
}

fn updateOverviewHover() void {
    const ov = server.overview orelse return;
    const px: i32 = @intFromFloat(server.cursor.*.x);
    const py: i32 = @intFromFloat(server.cursor.*.y);
    ov.hover = ov.entryAt(px, py);
    if (ov.expo) {
        ov.hover_tile = ov.tiles.at(server.ws.count, px, py);
        // A frame shows behind the tile under the pointer.
        if (ov.highlight) |h| {
            if (ov.hover_tile) |ti| {
                const r = ov.tiles.rect(ti);
                const b: i32 = 3;
                c.wlr_scene_node_set_position(&h.*.node, r.x - b, r.y - b);
                c.wlr_scene_rect_set_size(h, r.w + 2 * b, r.h + 2 * b);
                c.wlr_scene_node_set_enabled(&h.*.node, true);
            } else c.wlr_scene_node_set_enabled(&h.*.node, false);
        }
    }
    wakeOutputs();
}

// ---- the Alt+Tab switcher ----------------------------------------------------------------------------------

/// Draws the windows back to front by their distance from the chosen one, so the nearest is on top.
fn restackSwitcher(ov: *Overview) void {
    const n = ov.entries.items.len;
    var dist: usize = n;
    while (dist > 0) : (dist -= 1) {
        for (ov.entries.items, 0..) |e, i| {
            const d: usize = if (i > ov.sel) i - ov.sel else ov.sel - i;
            const dd = if (ov.switcher == .ring) @min(d, n - d) else d;
            if (dd == dist - 1 and dd < n) c.wlr_scene_node_raise_to_top(&e.t.tree.*.node);
        }
    }
}

/// Alt+Tab (dir = 1) or Alt+Shift+Tab (-1): opens the switcher on the next window, or moves on within it.
fn switcherStep(dir: i32) void {
    if (server.locked) return;
    if (server.overview) |ov| {
        if (ov.switcher == .off or ov.closing) return;
        const n = ov.entries.items.len;
        if (n == 0) return;
        ov.pos_from = ov.posNow();
        ov.pos_start = currentMs();
        const ni: i64 = @as(i64, @intCast(ov.sel)) + dir;
        const wrapped: usize = @intCast(@mod(ni, @as(i64, @intCast(n))));
        if (ov.switcher == .ring) {
            ov.pos_to = std.math.round(ov.pos_from) + @as(f32, @floatFromInt(dir));
        } else ov.pos_to = @floatFromInt(wrapped);
        ov.sel = wrapped;
        restackSwitcher(ov);
        wakeOutputs();
        return;
    }
    const kind = server.effects.switcher;
    if (kind == .off or server.cursor_mode != .passthrough) return;
    const ov = gpa.create(Overview) catch return;
    const bg = c.wlr_scene_tree_create(server.trees[1]) orelse {
        gpa.destroy(ov);
        return;
    };
    ov.* = .{ .expo = false, .start_ms = currentMs(), .screen = screenArea(), .bg = bg, .switcher = kind };
    // Most recently used first.
    var i = server.toplevels.items.len;
    while (i > 0) : (i -= 1) {
        const t = server.toplevels.items[i - 1];
        if (t.unmanaged() or !onActiveWorkspace(t)) continue;
        const g = geometryOf(t);
        ov.entries.append(gpa, .{ .t = t, .x = g.x, .y = g.y, .size = .{ .w = g.w, .h = g.h }, .target = .{ .x = g.x, .y = g.y, .scale = 1 } }) catch {};
    }
    if (ov.entries.items.len == 0) {
        c.wlr_scene_node_destroy(&bg.*.node);
        ov.entries.deinit(gpa);
        gpa.destroy(ov);
        return;
    }
    _ = sceneRect(bg, ov.screen, overlay_dim);
    const n = ov.entries.items.len;
    ov.sel = if (n > 1) (if (dir > 0) 1 else n - 1) else 0;
    ov.pos_from = @floatFromInt(ov.sel);
    ov.pos_to = ov.pos_from;
    ov.pos_start = 0;
    server.overview = ov;
    c.wlr_seat_pointer_clear_focus(server.seat);
    restackSwitcher(ov);
    wakeOutputs();
}

/// The Alt key came up: go to the chosen window.
fn confirmSwitcher() void {
    const ov = server.overview orelse return;
    if (ov.switcher == .off or ov.closing) return;
    if (ov.sel < ov.entries.items.len) closeOverview(ov.entries.items[ov.sel].t) else closeOverview(null);
}

fn overviewMotion() void {
    c.wlr_cursor_set_xcursor(server.cursor, server.cursor_mgr, "default");
    updateOverviewHover();
}

/// A button press or release while the overview is up. Returns true: the client never sees it.
fn overviewButton(pressed: bool) bool {
    const ov = server.overview orelse return false;
    if (ov.closing) return true;
    const px: i32 = @intFromFloat(server.cursor.*.x);
    const py: i32 = @intFromFloat(server.cursor.*.y);
    if (pressed) {
        ov.press = ov.entryAt(px, py);
        if (ov.press == null and !ov.expo) closeOverview(null);
        if (ov.press == null and ov.expo and ov.tiles.at(server.ws.count, px, py) == null) closeOverview(null);
        wakeOutputs();
        return true;
    }
    const pressed_entry = ov.press;
    ov.press = null;
    if (ov.expo) {
        const tile = ov.tiles.at(server.ws.count, px, py);
        if (pressed_entry) |pi| {
            const e = &ov.entries.items[pi];
            if (tile != null and tile.? != e.tile) {
                // Dropped on another workspace: the window moves there and the overview stays up.
                const t = e.t;
                t.workspace = tile.?;
                t.sticky = false;
                e.tile = tile.?;
                e.target = ov.tiles.place(ov.screen, tile.?, e.x, e.y);
                showIfVisible(t);
                updateOverviewHover();
                return true;
            }
            closeOverview(e.t);
            return true;
        }
        if (tile) |ti| {
            ov.hover_tile = ti;
            closeOverview(null);
        }
        return true;
    }
    if (pressed_entry) |pi| closeOverview(ov.entries.items[pi].t);
    return true;
}

/// A key while the overview is up (Escape closes it, Return picks the window under the pointer).
fn overviewKey(sym: c.xkb_keysym_t) void {
    const ov = server.overview orelse return;
    if (sym == c.XKB_KEY_Escape) {
        closeOverview(null);
    } else if (sym == c.XKB_KEY_Return or sym == c.XKB_KEY_KP_Enter) {
        if (ov.hover) |i| closeOverview(ov.entries.items[i].t) else closeOverview(null);
    }
}

// ---- zoom and colour filters (GLES only) --------------------------------------------------------------------

fn zoomMoving() bool {
    return @abs(server.zoom_now - server.zoom_target) > 0.002;
}

/// Eases the zoom toward its target.
fn tickZoom(now: u32) void {
    if (!zoomMoving()) {
        server.zoom_now = server.zoom_target;
        return;
    }
    const dt: f32 = @floatFromInt(@min(now -% server.zoom_ms, 100));
    server.zoom_ms = now;
    // About a fifth of the way each frame at 60 Hz.
    const k = 1 - std.math.pow(f32, 0.8, dt / 16.0);
    server.zoom_now += (server.zoom_target - server.zoom_now) * k;
}

/// What is done to the finished frame: the zoom about the pointer and the colour filter.
fn currentPost(output: *c.wlr_output) gfx.Post {
    var p: gfx.Post = .{};
    if (server.gfx == null) return p;
    if (server.zoom_now > 1.001) {
        var box: c.wlr_box = std.mem.zeroes(c.wlr_box);
        c.wlr_output_layout_get_box(server.output_layout, output, &box);
        p.zoom = server.zoom_now;
        const fx = (server.cursor.*.x - @as(f64, @floatFromInt(box.x))) / @as(f64, @floatFromInt(@max(box.width, 1)));
        const fy = (server.cursor.*.y - @as(f64, @floatFromInt(box.y))) / @as(f64, @floatFromInt(@max(box.height, 1)));
        p.fx = @floatCast(std.math.clamp(fx, 0, 1));
        p.fy = @floatCast(std.math.clamp(fy, 0, 1));
    }
    if (server.lens_on and server.effects.lens) {
        var box: c.wlr_box = std.mem.zeroes(c.wlr_box);
        c.wlr_output_layout_get_box(server.output_layout, output, &box);
        const bw: f64 = @floatFromInt(@max(box.width, 1));
        const bh: f64 = @floatFromInt(@max(box.height, 1));
        p.lens_x = @floatCast(std.math.clamp((server.cursor.*.x - @as(f64, @floatFromInt(box.x))) / bw, 0, 1));
        p.lens_y = @floatCast(std.math.clamp((server.cursor.*.y - @as(f64, @floatFromInt(box.y))) / bh, 0, 1));
        p.lens_r = 0.2; // a fifth of the screen's height
        p.lens_zoom = 2.5;
    }
    if (server.effects.water or ripplesLive()) {
        var box: c.wlr_box = std.mem.zeroes(c.wlr_box);
        c.wlr_output_layout_get_box(server.output_layout, output, &box);
        const bw: f32 = @floatFromInt(@max(box.width, 1));
        const bh: f32 = @floatFromInt(@max(box.height, 1));
        const now = currentMs();
        for (&server.ripples) |*r| {
            if (!r.live) continue;
            const f = anim.fraction(.{ .kind = .open, .start_ms = r.start_ms, .duration_ms = 1700 }, now);
            if (f >= 1) {
                r.live = false;
                continue;
            }
            p.ripples[p.ripple_count] = .{ (r.x - @as(f32, @floatFromInt(box.x))) / bw, (r.y - @as(f32, @floatFromInt(box.y))) / bh, 0.01 + 0.4 * anim.easeOut(f), (1 - f) };
            p.ripple_count += 1;
        }
    }
    if (server.filter != .none) {
        const m = filters.matrixFor(server.filter);
        p.m = gfx.fromRows(m.rows);
        p.off = m.off;
    }
    return p;
}

fn zoomBy(factor: f32) void {
    if (server.gfx == null or !server.effects.zoom) return;
    server.zoom_target = std.math.clamp(server.zoom_target * factor, 1.0, 8.0);
    if (server.zoom_target < 1.05) server.zoom_target = 1.0;
    server.zoom_ms = currentMs();
    wakeOutputs();
}

fn nextFilter() void {
    if (server.gfx == null) return;
    server.filter = server.filter.next();
    wakeOutputs();
}

// ---- animations ------------------------------------------------------------------------------------------------

fn nowMs(ts: *const std.c.timespec) u32 {
    const ms: i64 = @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
    return @truncate(@as(u64, @bitCast(ms)));
}

fn currentMs() u32 {
    var now: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &now);
    return nowMs(&now);
}

/// The transform of a window tree while it is animated (the lookup `render` calls for each tree).
fn xfOf(node: *c.wlr_scene_node) ?anim.Xf {
    if (node.parent != server.trees[2]) return null;
    const t: *Toplevel = @ptrCast(@alignCast(node.data orelse return null));
    if (face_filter) |f| {
        // One face of the cube: this workspace's windows (and sticky ones), drawn plainly, and nothing else.
        if (t.minimized or !(t.sticky or t.workspace == f)) return .{ .hidden = true };
        return .{ .force = true };
    }
    var result: ?anim.Xf = null;
    if (server.overview) |ov| result = ov.xfFor(t);
    if (result == null) {
        if (t.anim) |a| {
            const size = t.contentSize();
            const cx: f32 = @floatFromInt(node.x + @divTrunc(size.w, 2));
            const cy: f32 = @floatFromInt(node.y + @divTrunc(size.h, 2));
            result = anim.at(a, currentMs(), cx, cy);
        }
    }
    if (t.wobble) |w| {
        var xf = result orelse anim.Xf{};
        xf.warp = &w.warp;
        result = xf;
    }
    // Translucent windows (their own opacity, or dimmed for not having the focus) lie on a blurred background.
    if (server.effects.blur and server.gfx != null and effectiveOpacity(t) < 1.0) {
        var xf = result orelse anim.Xf{};
        xf.blur = true;
        const g = geometryOf(t);
        xf.blur_rect = rectF(g);
        result = xf;
    }
    return result;
}

/// The cube for this frame while it turns; null when it is done or not in use.
fn currentCube(now: u32) ?gfx.Cube {
    const turn = server.cube orelse return null;
    const ms = @max(400, server.effects.animation_ms * 2);
    const f = anim.fraction(.{ .kind = .open, .start_ms = turn.start_ms, .duration_ms = ms }, now);
    if (f >= 1 or server.gfx == null or server.overview != null) {
        server.cube = null;
        return null;
    }
    return .{
        .pos = cube_mod.position(turn.from, turn.to, server.ws.count, anim.easeOut(f)),
        .count = server.ws.count,
        .filter = setFaceFilter,
    };
}

/// Snow, the pointer finder, flames and the paint strokes, as the sprites to draw this frame.
fn currentSprites(now: u32, output: *c.wlr_output) []const gfx.Sprite {
    server.sprite_list.clearRetainingCapacity();
    const list = &server.sprite_list;
    var box: c.wlr_box = std.mem.zeroes(c.wlr_box);
    c.wlr_output_layout_get_box(server.output_layout, output, &box);
    const w: f32 = @floatFromInt(@max(box.width, 1));
    const h: f32 = @floatFromInt(@max(box.height, 1));
    if (server.gfx == null) return list.items;
    if (server.effects.snow) {
        if (server.snow == null) server.snow = snow_mod.Snow.init(w, h, 160, @as(u64, now) | 1);
        const dt: f32 = @as(f32, @floatFromInt(@min(now -% server.snow_ms, 100))) / 1000.0;
        server.snow_ms = now;
        server.snow.?.step(dt, w, h);
        for (server.snow.?.flakes[0..server.snow.?.count]) |f| {
            list.append(gpa, .{ .x = f.x + @as(f32, @floatFromInt(box.x)), .y = f.y + @as(f32, @floatFromInt(box.y)), .radius = f.r * 1.8, .alpha = 0.5 + f.r * 0.1 }) catch break;
        }
    } else server.snow = null;
    if (server.finder_ms != 0) {
        const f = anim.fraction(.{ .kind = .open, .start_ms = server.finder_ms, .duration_ms = 900 }, now);
        if (f >= 1) {
            server.finder_ms = 0;
        } else {
            const e = anim.easeOut(f);
            list.append(gpa, .{ .x = @floatCast(server.cursor.*.x), .y = @floatCast(server.cursor.*.y), .radius = 30 + 160 * e, .alpha = 1 - f, .kind = .ring }) catch {};
        }
    }
    if (server.effects.fire and (server.fire_on or (server.fire != null and server.fire.?.count > 0))) {
        if (server.fire == null) server.fire = fire_mod.Fire.init(@as(u64, now) | 1);
        const dt: f32 = @as(f32, @floatFromInt(@min(now -% server.fire_ms, 100))) / 1000.0;
        server.fire_ms = now;
        server.fire.?.step(dt, server.fire_on, @floatCast(server.cursor.*.x), @floatCast(server.cursor.*.y));
        for (server.fire.?.particles[0..server.fire.?.count]) |p| {
            const pr = fire_mod.Fire.progress(p);
            list.append(gpa, .{ .x = p.x, .y = p.y, .radius = p.size * (1 - 0.65 * pr), .alpha = 1 - pr, .kind = .flame }) catch break;
        }
    } else if (!server.effects.fire) {
        server.fire = null;
        server.fire_on = false;
    }
    if (server.effects.paint) {
        for (server.paint_pts.items) |pt| {
            list.append(gpa, .{ .x = pt[0], .y = pt[1], .radius = 4.5, .alpha = 0.95, .tint = .{ 1.0, 0.18, 0.1 } }) catch break;
        }
    }
    return list.items;
}

/// A window that closes leaves its last picture to fade (the animations setting).
fn startGhost(t: *Toplevel) void {
    const buf = t.snap orelse return;
    if (!server.effects.animations or server.gfx == null or t.minimized or !onActiveWorkspace(t) or t.snap_rect[2] <= 0) {
        t.releaseSnap();
        return;
    }
    // The ghost takes over the lock.
    server.ghosts.append(gpa, .{ .buf = buf, .x = t.snap_rect[0], .y = t.snap_rect[1], .w = t.snap_rect[2], .h = t.snap_rect[3], .start_ms = currentMs() }) catch {
        t.releaseSnap();
        return;
    };
    t.snap = null;
    wakeOutputs();
}

/// The fading windows for this frame; the ones that have faded are let go.
fn currentGhosts(now: u32) []const gfx.Ghost {
    server.ghost_out.clearRetainingCapacity();
    var i: usize = 0;
    while (i < server.ghosts.items.len) {
        const gh = server.ghosts.items[i];
        const f = anim.fraction(.{ .kind = .open, .start_ms = gh.start_ms, .duration_ms = server.effects.animation_ms }, now);
        if (f >= 1 or server.gfx == null) {
            c.wlr_buffer_unlock(&gh.buf.*.base);
            _ = server.ghosts.orderedRemove(i);
            continue;
        }
        if (gh.buf.*.texture) |tex| {
            const e = anim.easeOut(f);
            server.ghost_out.append(gpa, .{ .texture = tex, .x = gh.x, .y = gh.y, .w = gh.w, .h = gh.h, .scale = 1 - 0.1 * e, .alpha = 1 - e }) catch {};
        }
        i += 1;
    }
    return server.ghost_out.items;
}

fn addRipple(now: u32) void {
    var slot: usize = 0;
    var oldest: u32 = 0;
    for (server.ripples, 0..) |r, i| {
        if (!r.live) {
            slot = i;
            oldest = std.math.maxInt(u32);
            break;
        }
        const age = now -% r.start_ms;
        if (age >= oldest) {
            oldest = age;
            slot = i;
        }
    }
    server.ripples[slot] = .{ .x = @floatCast(server.cursor.*.x), .y = @floatCast(server.cursor.*.y), .start_ms = now, .live = true };
}

fn ripplesLive() bool {
    for (server.ripples) |r| {
        if (r.live) return true;
    }
    return false;
}

fn toggleLens() void {
    if (server.gfx == null or !server.effects.lens) return;
    server.lens_on = !server.lens_on;
    wakeOutputs();
}

fn toggleFire() void {
    if (server.gfx == null or !server.effects.fire) return;
    server.fire_on = !server.fire_on;
    server.fire_ms = currentMs();
    wakeOutputs();
}

fn togglePaint() void {
    if (server.gfx == null or !server.effects.paint) return;
    server.paint_on = !server.paint_on;
    server.paint_down = false;
    if (server.paint_on) c.wlr_seat_pointer_clear_focus(server.seat);
    wakeOutputs();
}

fn clearPaint() void {
    server.paint_pts.clearRetainingCapacity();
    wakeOutputs();
}

/// Adds a point to the stroke being drawn, filling in the gap since the last one.
fn paintPoint() void {
    const x: f32 = @floatCast(server.cursor.*.x);
    const y: f32 = @floatCast(server.cursor.*.y);
    if (server.paint_pts.items.len > 20000) return;
    if (server.paint_pts.items.len > 0 and server.paint_down) {
        const last = server.paint_pts.items[server.paint_pts.items.len - 1];
        const dx = x - last[0];
        const dy = y - last[1];
        const dist = @sqrt(dx * dx + dy * dy);
        if (dist < 1.5) return;
        var k: f32 = 3;
        while (k < dist) : (k += 3) {
            server.paint_pts.append(gpa, .{ last[0] + dx * k / dist, last[1] + dy * k / dist }) catch return;
        }
    }
    server.paint_pts.append(gpa, .{ x, y }) catch {};
}

fn showPointer() void {
    if (server.gfx == null) return;
    server.finder_ms = currentMs();
    wakeOutputs();
}

/// With blur on, a frame that has a translucent window on it is composed by the GLES composer.
fn blurNeeded() bool {
    if (!server.effects.blur or server.gfx == null) return false;
    if (server.opened == 0) return false;
    for (server.toplevels.items) |t| {
        if (t.minimized or !onActiveWorkspace(t)) continue;
        if (effectiveOpacity(t) < 1.0) return true;
    }
    return false;
}

fn anyWobble() bool {
    for (server.toplevels.items) |t| {
        if (t.wobble != null) return true;
    }
    return false;
}

fn freeWobble(t: *Toplevel) void {
    if (t.wobble) |w| gpa.destroy(w);
    t.wobble = null;
}

fn rectF(r: layout.Rect) [4]f32 {
    return .{ @floatFromInt(r.x), @floatFromInt(r.y), @floatFromInt(r.w), @floatFromInt(r.h) };
}

/// Wobbly windows: follows each window's real rectangle with its spring mesh. A window that jumps (a snap,
/// maximize, a tiling change) starts a wobble from where it was; a drag holds the mesh at the pointer.
fn tickWobbles(now: u32) void {
    const dt: f32 = @as(f32, @floatFromInt(@min(now -% server.wobble_ms, 100))) / 1000.0;
    server.wobble_ms = now;
    const on = server.effects.wobbly and server.gfx != null;
    for (server.toplevels.items) |t| {
        if (!on) {
            freeWobble(t);
            continue;
        }
        const g = geometryOf(t);
        if (t.wobble) |w| {
            const r = rectF(g);
            w.setRest(r[0], r[1], r[2], r[3]);
            w.step(dt);
            if (w.settled()) freeWobble(t);
        } else if (t.last_geom) |old| {
            const moved = @abs(old.x - g.x) > 8 or @abs(old.y - g.y) > 8 or @abs(old.w - g.w) > 8 or @abs(old.h - g.h) > 8;
            if (moved and !t.minimized and server.overview == null and t.anim == null and g.w > 0 and g.h > 0) {
                const w = gpa.create(wobble_mod.Wobble) catch continue;
                const o = rectF(old);
                w.* = wobble_mod.Wobble.init(o[0], o[1], o[2], o[3]);
                const r = rectF(g);
                w.setRest(r[0], r[1], r[2], r[3]);
                w.step(dt);
                t.wobble = w;
            }
        }
        t.last_geom = g;
    }
}

fn wakeOutputs() void {
    for (server.outputs.items) |o| c.wlr_output_schedule_frame(o.output);
}

fn startAnimation(t: *Toplevel, kind: anim.Kind) void {
    if (!server.effects.animations) return;
    var a: anim.Anim = .{ .kind = kind, .start_ms = currentMs(), .duration_ms = server.effects.animation_ms };
    if (kind == .minimize) {
        // Shrink toward the bottom middle of the screen, where the taskbar usually is.
        const screen = screenArea();
        const size = t.contentSize();
        a.to_x = @as(f32, @floatFromInt(screen.x + @divTrunc(screen.w, 2))) - @as(f32, @floatFromInt(t.tree.*.node.x + @divTrunc(size.w, 2)));
        a.to_y = @as(f32, @floatFromInt(screen.y + screen.h)) - @as(f32, @floatFromInt(t.tree.*.node.y + @divTrunc(size.h, 2)));
    }
    if (t.anim == null) server.animating += 1;
    t.anim = a;
    wakeOutputs();
}

fn finishAnimation(t: *Toplevel) void {
    if (t.anim == null) return;
    t.anim = null;
    if (server.animating > 0) server.animating -= 1;
    showIfVisible(t);
}

/// Called before each frame: ends the animations that have run their course.
fn tickAnimations(now: u32) void {
    if (server.overview) |ov| {
        if (ov.closing and ov.finished()) destroyOverview();
    }
    if (server.animating == 0) return;
    for (server.toplevels.items) |t| {
        if (t.anim) |a| {
            if (anim.done(a, now)) finishAnimation(t);
        }
    }
}

// ---- rules, placement, stacking and opacity ---------------------------------------------------------------------

fn spanOrEmpty(p: [*c]const u8) []const u8 {
    return if (p == null) "" else std.mem.span(p);
}

/// What the window's `[[rules]]` say about it, apart from where it goes (see `placeNew`).
fn applyRule(t: *Toplevel, r: rules.Rule) void {
    if (r.floating) |f| t.floating = f;
    if (r.workspace) |w| {
        if (w < server.ws.count) t.workspace = w;
    }
    if (r.sticky) |v| t.sticky = v;
    if (r.above) |v| {
        t.above = v;
        if (v) t.below = false;
    }
    if (r.below) |v| {
        t.below = v;
        if (v) t.above = false;
    }
    if (r.opacity) |v| t.opacity = v;
}

/// The rectangles of the other windows on the screen (for smart placement and edge magnetism).
fn otherWindows(except: *const Toplevel, out: []layout.Rect) usize {
    var n: usize = 0;
    for (server.managed.items) |o| {
        if (o == except or o.minimized or !onActiveWorkspace(o) or n >= out.len) continue;
        out[n] = geometryOf(o);
        n += 1;
    }
    return n;
}

/// Puts a window that has just appeared where its rule or the `placement` setting says.
fn placeNew(t: *Toplevel, r: rules.Rule) void {
    const area = workArea();
    const size = t.contentSize();
    const w = r.width orelse (if (size.w > 0) size.w else 640);
    const h = r.height orelse (if (size.h > 0) size.h else 420);
    var rect = layout.Rect{ .x = area.x, .y = area.y, .w = w, .h = h };
    if (r.x != null or r.y != null) {
        rect.x = r.x orelse area.x;
        rect.y = r.y orelse area.y;
    } else if (r.position) |p| {
        rect = place_mod.put(area, w, h, p);
    } else switch (server.placement) {
        .cascade => {
            const spot = layout.cascade(area, server.opened);
            rect.x = spot.x;
            rect.y = spot.y;
        },
        .center => rect = place_mod.put(area, w, h, .center),
        .smart => {
            var others: [64]layout.Rect = undefined;
            const n = otherWindows(t, &others);
            const spot = place_mod.smart(area, w, h, others[0..n]);
            rect.x = spot.x;
            rect.y = spot.y;
        },
        .pointer => {
            rect.x = std.math.clamp(@as(i32, @intFromFloat(server.cursor.*.x)) - @divTrunc(w, 2), area.x, @max(area.x, area.x + area.w - w));
            rect.y = std.math.clamp(@as(i32, @intFromFloat(server.cursor.*.y)) - @divTrunc(h, 2), area.y, @max(area.y, area.y + area.h - h));
        },
    }
    c.wlr_scene_node_set_position(&t.tree.*.node, rect.x, rect.y);
    if (r.width != null or r.height != null) place(t, rect);
}

/// Windows kept above or below the rest go back to their layer after anything else was raised.
fn updateStacking() void {
    for (server.toplevels.items) |t| {
        if (t.below) c.wlr_scene_node_lower_to_bottom(&t.tree.*.node);
    }
    for (server.toplevels.items) |t| {
        if (t.above) c.wlr_scene_node_raise_to_top(&t.tree.*.node);
    }
}

fn setBufferOpacity(buffer: ?*c.wlr_scene_buffer, _: c_int, _: c_int, data: ?*anyopaque) callconv(.c) void {
    const v: *f32 = @ptrCast(@alignCast(data.?));
    c.wlr_scene_buffer_set_opacity(buffer, v.*);
}

fn isFocused(t: *const Toplevel) bool {
    const surface = t.surf() orelse return false;
    return server.seat.*.keyboard_state.focused_surface == surface;
}

/// The window's own opacity, times the dimming for windows that do not have the focus.
fn applyOpacity(t: *Toplevel) void {
    var v: f32 = effectiveOpacity(t);
    c.wlr_scene_node_for_each_buffer(&t.tree.*.node, setBufferOpacity, &v);
}

/// How far down the focus order a window is on its workspace (0 = the one on top).
fn focusRank(t: *const Toplevel) usize {
    var rank: usize = 0;
    var i = server.toplevels.items.len;
    while (i > 0) : (i -= 1) {
        const o = server.toplevels.items[i - 1];
        if (o == t) return rank;
        if (!o.minimized and onActiveWorkspace(o)) rank += 1;
    }
    return rank;
}

/// The window's own opacity, with dimming for not having the focus: one step, or (trailfocus) more the further back.
fn effectiveOpacity(t: *const Toplevel) f32 {
    var v: f32 = t.opacity;
    if (server.effects.trailfocus) {
        v *= @max(0.35, 1.0 - 0.17 * @as(f32, @floatFromInt(focusRank(t))));
    } else if (server.inactive_opacity < 1.0 and !isFocused(t)) {
        v *= server.inactive_opacity;
    }
    return v;
}

fn refreshOpacity() void {
    for (server.toplevels.items) |t| applyOpacity(t);
}

/// Put the window at a corner, an edge or the centre; it keeps its size and leaves the tiling.
fn putWindow(t: *Toplevel, pos: place_mod.Position) void {
    if (t.maximized) {
        t.maximized = false;
        t.setMaxFlag(false);
    }
    t.floating = true;
    t.cell = null;
    t.saved = null;
    t.setTiledEdges(0);
    const size = t.contentSize();
    const rect = place_mod.put(workArea(), size.w, size.h, pos);
    c.wlr_scene_node_set_position(&t.tree.*.node, rect.x, rect.y);
    arrange();
}

fn toggleSticky(t: *Toplevel) void {
    t.sticky = !t.sticky;
    if (!t.sticky) t.workspace = server.ws.active;
    showIfVisible(t);
    arrange();
}

fn toggleAbove(t: *Toplevel) void {
    t.above = !t.above;
    if (t.above) t.below = false;
    updateStacking();
}

fn toggleBelow(t: *Toplevel) void {
    t.below = !t.below;
    if (t.below) t.above = false;
    updateStacking();
}

fn changeOpacity(t: *Toplevel, delta: f32) void {
    t.opacity = std.math.clamp(t.opacity + delta, 0.2, 1.0);
    applyOpacity(t);
}

/// Minimizes every window of the workspace, or brings back the ones it hid.
fn showDesktop() void {
    var batch: [64]*Toplevel = undefined;
    var n: usize = 0;
    for (server.toplevels.items) |t| {
        if (!t.minimized and onActiveWorkspace(t) and n < batch.len) {
            batch[n] = t;
            n += 1;
        }
    }
    if (n > 0) {
        for (batch[0..n]) |t| t.hidden_by_desktop = true;
        for (batch[0..n]) |t| setMinimized(t, true);
        return;
    }
    for (server.toplevels.items) |t| {
        if (t.hidden_by_desktop and n < batch.len) {
            batch[n] = t;
            n += 1;
        }
    }
    for (batch[0..n]) |t| {
        t.hidden_by_desktop = false;
        setMinimized(t, false);
    }
}

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
    updateStacking();
    if (server.inactive_opacity < 1.0 or server.effects.trailfocus) refreshOpacity();
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
    if (server.grabbed) |t| {
        if (t.wobble) |w| w.held = null;
    }
    server.cursor_mode = .passthrough;
    server.grabbed = null;
    hideSnapPreview();
}

fn hideSnapPreview() void {
    server.snap_target = null;
    server.snap_hit = null;
    server.overlay_on = false;
    if (server.snap_preview) |r| c.wlr_scene_node_set_enabled(&r.*.node, false);
    if (server.overlay_tree) |t| c.wlr_scene_node_set_enabled(&t.node, false);
}

fn outputBoxAtCursor() layout.Rect {
    var box: c.wlr_box = std.mem.zeroes(c.wlr_box);
    const out = c.wlr_output_layout_output_at(server.output_layout, server.cursor.*.x, server.cursor.*.y);
    c.wlr_output_layout_get_box(server.output_layout, out, &box);
    return .{ .x = box.x, .y = box.y, .w = box.width, .h = box.height };
}

fn sceneRect(parent: *c.wlr_scene_tree, r: layout.Rect, color: [4]f32) ?*c.wlr_scene_rect {
    const rect = c.wlr_scene_rect_create(parent, r.w, r.h, &color) orelse return null;
    c.wlr_scene_node_set_position(&rect.*.node, r.x, r.y);
    return rect;
}

const zone_idle = [4]f32{ 0.55, 0.57, 0.62, 1 };
const zone_hover = [4]f32{ 0.21, 0.52, 0.89, 1 };

/// The card of layouts at the top of the screen, drawn from scene rectangles (built again when the output changes).
fn showOverlay(box: layout.Rect, hover: ?layout.ZoneIndex) void {
    if (server.overlay_tree != null and !std.meta.eql(server.overlay_box, box)) {
        c.wlr_scene_node_destroy(&server.overlay_tree.?.node);
        server.overlay_tree = null;
        server.overlay_zones = std.mem.zeroes([layout.snap_layouts.len][4]?*c.wlr_scene_rect);
    }
    if (server.overlay_tree == null) {
        const tree = c.wlr_scene_tree_create(server.trees[3]) orelse return;
        const card = layout.overlayCard(box);
        _ = sceneRect(tree, card, .{ 0.09, 0.09, 0.11, 0.95 });
        for (layout.snap_layouts, 0..) |l, i| {
            _ = sceneRect(tree, layout.overlayCell(card, i), .{ 0.16, 0.16, 0.19, 1 });
            for (l, 0..) |_, j| server.overlay_zones[i][j] = sceneRect(tree, layout.overlayZone(card, i, j), zone_idle);
        }
        server.overlay_tree = tree;
        server.overlay_box = box;
    }
    const tree = server.overlay_tree.?;
    c.wlr_scene_node_set_enabled(&tree.node, true);
    c.wlr_scene_node_raise_to_top(&tree.node);
    for (layout.snap_layouts, 0..) |l, i| {
        for (l, 0..) |_, j| {
            const rect = server.overlay_zones[i][j] orelse continue;
            const hot = if (hover) |h| h.i == i and h.j == j else false;
            c.wlr_scene_rect_set_color(rect, if (hot) &zone_hover else &zone_idle);
        }
    }
}

/// While a window is dragged: the layout card when the pointer is at the top of the screen, and the outline of
/// where the window would go if it were let go now (an edge, a corner, or the zone under the pointer).
fn updateSnapPreview() void {
    if (!server.edge_snap) return;
    const box = outputBoxAtCursor();
    const x: i32 = @intFromFloat(server.cursor.*.x);
    const y: i32 = @intFromFloat(server.cursor.*.y);
    const drop = layout.dropTarget(box, x, y, server.overlay_on);
    server.overlay_on = drop.overlay;
    server.snap_hit = if (drop.overlay) layout.overlayZoneAt(box, x, y) else null;
    if (drop.overlay) showOverlay(box, layout.overlayZoneAt(box, x, y)) else if (server.overlay_tree) |t| c.wlr_scene_node_set_enabled(&t.node, false);

    const target = drop.target orelse {
        server.snap_target = null;
        if (server.snap_preview) |r| c.wlr_scene_node_set_enabled(&r.*.node, false);
        return;
    };
    if (server.snap_target != null and std.meta.eql(server.snap_target.?, target)) {
        // The card stays above the outline.
        if (server.overlay_tree) |t| if (drop.overlay) c.wlr_scene_node_raise_to_top(&t.node);
        return;
    }
    server.snap_target = target;
    const area = workArea();
    const rect = switch (target) {
        .region => |r| layout.regionRect(area, r),
        .maximize => area,
    };
    if (server.snap_preview == null) {
        // Premultiplied: a 30% blue over whatever is below.
        const tint = [4]f32{ 0.063, 0.156, 0.267, 0.30 };
        server.snap_preview = c.wlr_scene_rect_create(server.trees[3], rect.w, rect.h, &tint);
    }
    const preview = server.snap_preview orelse return;
    c.wlr_scene_rect_set_size(preview, rect.w, rect.h);
    c.wlr_scene_node_set_position(&preview.*.node, rect.x, rect.y);
    c.wlr_scene_node_set_enabled(&preview.*.node, true);
    c.wlr_scene_node_raise_to_top(&preview.*.node);
    if (server.overlay_tree) |t| if (drop.overlay) c.wlr_scene_node_raise_to_top(&t.node);
}

/// The button was let go after a drag: a window dropped on a screen edge snaps there.
fn finishMove() void {
    if (server.cursor_mode != .move) return;
    const target = server.snap_target orelse return;
    const t = server.grabbed orelse return;
    switch (target) {
        .region => |region| snapTo(t, region),
        .maximize => setMaximized(t, true),
    }
    // Dropped on a zone of the layout card: the other windows are offered for the zones still empty.
    if (server.snap_hit) |hit| {
        const box = server.overlay_box;
        const area = workArea();
        var buf: [128]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "dkde-snap --assist {d},{d},{d},{d},{d},{d}", .{ hit.i, hit.j, area.x - box.x, area.y - box.y, area.w, area.h }) catch return;
        runCommand(line);
    }
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
        if (server.effects.wobbly and server.gfx != null) {
            const g = geometryOf(t);
            if (t.wobble == null) {
                if (gpa.create(wobble_mod.Wobble)) |w| {
                    const r = rectF(g);
                    w.* = wobble_mod.Wobble.init(r[0], r[1], r[2], r[3]);
                    t.wobble = w;
                } else |_| {}
            }
            if (t.wobble) |w| w.held = .{
                @floatCast(std.math.clamp(server.grab_x / @as(f64, @floatFromInt(@max(g.w, 1))), 0, 1)),
                @floatCast(std.math.clamp(server.grab_y / @as(f64, @floatFromInt(@max(g.h, 1))), 0, 1)),
            };
        }
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
    if (server.zoom_now > 1.001) wakeOutputs();
    if (server.overview != null) {
        overviewMotion();
        return;
    }
    if (server.paint_on) {
        c.wlr_cursor_set_xcursor(cursor, server.cursor_mgr, "crosshair");
        if (server.paint_down) paintPoint();
        wakeOutputs();
        return;
    }
    if (server.effects.water and server.gfx != null) {
        const dx = cursor.*.x - server.ripple_last[0];
        const dy = cursor.*.y - server.ripple_last[1];
        if (dx * dx + dy * dy > 30 * 30) {
            server.ripple_last = .{ cursor.*.x, cursor.*.y };
            addRipple(currentMs());
            wakeOutputs();
        }
    }
    switch (server.cursor_mode) {
        .move => {
            if (server.grabbed) |t| {
                var nx: i32 = @intFromFloat(cursor.*.x - server.grab_x);
                var ny: i32 = @intFromFloat(cursor.*.y - server.grab_y);
                if (server.snap_windows) {
                    var others: [64]layout.Rect = undefined;
                    const n = otherWindows(t, &others);
                    const size = t.contentSize();
                    const meet = place_mod.magnet(.{ .x = nx, .y = ny, .w = size.w, .h = size.h }, workArea(), others[0..n], 14);
                    nx = meet.x;
                    ny = meet.y;
                }
                c.wlr_scene_node_set_position(&t.tree.*.node, nx, ny);
                updateSnapPreview();
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
    if (server.overview != null) {
        _ = overviewButton(event.state == c.WL_POINTER_BUTTON_STATE_PRESSED);
        return;
    }
    if (server.paint_on) {
        server.paint_down = event.state == c.WL_POINTER_BUTTON_STATE_PRESSED;
        if (server.paint_down) paintPoint();
        wakeOutputs();
        return;
    }
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
        finishMove();
        resetCursorMode();
    } else if (windowAt(server.cursor.*.x, server.cursor.*.y)) |hit| {
        if (hit.toplevel) |t| focus(t);
        if (hit.layer) |ls| focusLayer(ls);
    }
}

fn onCursorAxis(_: ?*c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    if (server.overview != null or server.paint_on) return;
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
        // The switcher goes to the chosen window when Alt comes up (a key release, or a virtual keyboard
        // that only reports the modifier state).
        if (server.overview) |ov| {
            if (ov.switcher != .off and !ov.closing and modsOf(c.wlr_keyboard_get_modifiers(self.keyboard)) & keys.Mod.alt == 0) confirmSwitcher();
        }
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
        if (server.paint_on and pressed) {
            var k: usize = 0;
            while (k < @as(usize, @intCast(@max(count, 0)))) : (k += 1) {
                if (syms[k] == c.XKB_KEY_Escape) {
                    togglePaint();
                    return;
                }
            }
        }
        if (server.overview != null) {
            // Nothing reaches the programs while Scale or Expo is up; the shortcuts and Escape/Return still work.
            var k: usize = 0;
            while (k < @as(usize, @intCast(@max(count, 0)))) : (k += 1) {
                if (!pressed) {
                    if ((syms[k] == c.XKB_KEY_Alt_L or syms[k] == c.XKB_KEY_Alt_R) and server.overview != null and server.overview.?.switcher != .off) confirmSwitcher();
                    continue;
                }
                if (isSuper(syms[k])) continue;
                if (!runBinding(mods, syms[k])) overviewKey(syms[k]);
            }
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
            if (server.effects.switcher != .off) {
                switcherStep(1);
                return;
            }
            // The window at the bottom of this workspace comes to the top.
            for (server.toplevels.items) |t| {
                if (!t.minimized and onActiveWorkspace(t)) {
                    focus(t);
                    break;
                }
            }
        },
        .prev_window => {
            if (server.effects.switcher != .off) {
                switcherStep(-1);
                return;
            }
            var seen: usize = 0;
            var i = server.toplevels.items.len;
            while (i > 0) : (i -= 1) {
                const t = server.toplevels.items[i - 1];
                if (t.minimized or !onActiveWorkspace(t)) continue;
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
        .put => |pos| if (topWindow()) |t| putWindow(t, pos),
        .sticky => if (topWindow()) |t| toggleSticky(t),
        .above => if (topWindow()) |t| toggleAbove(t),
        .below => if (topWindow()) |t| toggleBelow(t),
        .show_desktop => showDesktop(),
        .zoom_in => zoomBy(1.25),
        .zoom_out => zoomBy(0.8),
        .zoom_reset => zoomBy(0.01),
        .next_filter => nextFilter(),
        .show_pointer => showPointer(),
        .lens => toggleLens(),
        .fire => toggleFire(),
        .paint => togglePaint(),
        .paint_clear => clearPaint(),
        .scale => openOverview(false),
        .expo => openOverview(true),
        .opacity_up => if (topWindow()) |t| changeOpacity(t, 0.1),
        .opacity_down => if (topWindow()) |t| changeOpacity(t, -0.1),
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
    // Unset means a little faster than libinput's 0, which feels slow.
    {
        const v = input_settings.pointer_speed orelse 0.4;
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
    c.wlr_seat_set_capabilities(server.seat, c.WL_SEAT_CAPABILITY_POINTER | c.WL_SEAT_CAPABILITY_KEYBOARD);
}

fn onNewVirtualPointer(_: ?*c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const event: *c.wlr_virtual_pointer_v1_new_pointer_event = @ptrCast(@alignCast(data));
    c.wlr_cursor_attach_input_device(server.cursor, &event.new_pointer.*.pointer.base);
    // A machine with no real pointer (a tablet, a test) still gets a wl_pointer once a tool brings a virtual one.
    // Programs see the new wl_pointer only after the focus is dropped, so the next motion enters them again.
    if (server.seat.*.capabilities & c.WL_SEAT_CAPABILITY_POINTER == 0) c.wlr_seat_pointer_clear_focus(server.seat);
    var caps: u32 = c.WL_SEAT_CAPABILITY_POINTER;
    if (server.keyboards.items.len > 0) caps |= c.WL_SEAT_CAPABILITY_KEYBOARD;
    c.wlr_seat_set_capabilities(server.seat, caps);
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
    rules.freeAll(gpa, server.rules);
    server.rules = cfg.rules;
    cfg.rules = &.{};
    server.placement = cfg.placement;
    server.snap_windows = cfg.snap_windows;
    const dimming_changed = server.inactive_opacity != cfg.inactive_opacity or server.effects.trailfocus != cfg.effects.trailfocus;
    server.inactive_opacity = cfg.inactive_opacity;
    server.effects = cfg.effects;
    server.filter = cfg.effects.filter;
    if (!cfg.effects.zoom) server.zoom_target = 1;
    if (server.overview != null and !(cfg.effects.scale or cfg.effects.expo or cfg.effects.switcher != .off)) closeOverview(null);
    config.free(gpa, cfg);
    cfg.keys = &.{};
    if (dimming_changed) refreshOpacity();
    const was = server.policy;
    applyInput();
    server.ws.count = cfg.workspaces;
    if (server.ws.active >= server.ws.count) switchWorkspace(server.ws.count - 1);
    workspaces.refresh();
    server.policy = cfg.policy;
    server.layout_options = cfg.options;
    server.edge_snap = cfg.edge_snap;
    if (!cfg.edge_snap) hideSnapPreview();
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

const version = "0.3.1";

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
    // Settings > For developers: the log level (wlroots has error, info and debug) and a log file.
    const dev = developer.read_file();
    developer.redirectStderr(dev, "dkde-compositor");
    c.wlr_log_init(if (dev.debug()) c.WLR_DEBUG else if (dev.level == .err or dev.level == .warn) c.WLR_ERROR else c.WLR_INFO, null);
    c._wlr_log(c.WLR_INFO, "dkde-compositor %s starting (log level %s)", version.ptr, @tagName(dev.level).ptr);

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
    server.gfx = gfx.Gfx.create(gpa, renderer);
    if (server.gfx == null) c._wlr_log(c.WLR_INFO, "effects: not using the GLES renderer; zoom and colour filters are off");
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
