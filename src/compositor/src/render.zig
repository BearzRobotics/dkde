//! Our own frame composer: draws the scene graph with a render pass so that a window can be scaled,
//! shifted and faded (animations, the overview). It reads the same scene graph wlr_scene keeps, so hit
//! testing, popups and subsurfaces stay as they are. It is used only while something is transformed;
//! otherwise the normal scene output path runs, with its damage tracking and direct scanout.
//! Outputs are assumed not to be rotated.

const std = @import("std");
const c = @import("c");
const anim = @import("anim.zig");

pub const Xf = anim.Xf;

/// Asks for the transform of a scene node that is the tree of a window (null for everything else).
pub const Lookup = *const fn (node: *c.wlr_scene_node) ?Xf;

const Frame = struct {
    pass: *c.wlr_render_pass,
    /// The output's place in the layout, and its scale.
    ox: f32,
    oy: f32,
    scale: f32,
    lookup: Lookup,
};

fn nodeOf(link: *c.wl_list) *c.wlr_scene_node {
    return @fieldParentPtr("link", link);
}

fn applyX(v: f32, a: f32, xf: Xf) f32 {
    return a + (v - a) * xf.scale + xf.tx;
}

fn applyY(v: f32, a: f32, xf: Xf) f32 {
    return a + (v - a) * xf.scale + xf.ty;
}

/// A box in layout coordinates, transformed and turned into the output's pixels.
fn deviceBox(f: *const Frame, x: f32, y: f32, w: f32, h: f32, xf: ?Xf) c.wlr_box {
    var x0 = x;
    var y0 = y;
    var x1 = x + w;
    var y1 = y + h;
    if (xf) |t| {
        x0 = applyX(x0, t.ax, t);
        x1 = applyX(x1, t.ax, t);
        y0 = applyY(y0, t.ay, t);
        y1 = applyY(y1, t.ay, t);
    }
    const dx0: i32 = @intFromFloat(@floor((x0 - f.ox) * f.scale));
    const dy0: i32 = @intFromFloat(@floor((y0 - f.oy) * f.scale));
    const dx1: i32 = @intFromFloat(@ceil((x1 - f.ox) * f.scale));
    const dy1: i32 = @intFromFloat(@ceil((y1 - f.oy) * f.scale));
    return .{ .x = dx0, .y = dy0, .width = @max(dx1 - dx0, 0), .height = @max(dy1 - dy0, 0) };
}

fn drawNode(f: *const Frame, node: *c.wlr_scene_node, px: f32, py: f32, inherited: ?Xf) void {
    if (!node.enabled) return;
    const x = px + @as(f32, @floatFromInt(node.x));
    const y = py + @as(f32, @floatFromInt(node.y));
    var xf = inherited;
    if (xf == null and node.type == c.WLR_SCENE_NODE_TREE) xf = f.lookup(node);
    switch (node.type) {
        c.WLR_SCENE_NODE_TREE => {
            const tree: *c.wlr_scene_tree = @fieldParentPtr("node", node);
            var link = tree.children.next;
            while (link != &tree.children) : (link = link.*.next) {
                drawNode(f, nodeOf(link), x, y, xf);
            }
        },
        c.WLR_SCENE_NODE_RECT => {
            const rect: *c.wlr_scene_rect = @fieldParentPtr("node", node);
            const alpha: f32 = if (xf) |t| t.alpha else 1;
            const box = deviceBox(f, x, y, @floatFromInt(rect.width), @floatFromInt(rect.height), xf);
            if (box.width == 0 or box.height == 0) return;
            var opts = std.mem.zeroes(c.wlr_render_rect_options);
            opts.box = box;
            opts.color = .{ .r = rect.color[0] * alpha, .g = rect.color[1] * alpha, .b = rect.color[2] * alpha, .a = rect.color[3] * alpha };
            c.wlr_render_pass_add_rect(f.pass, &opts);
        },
        c.WLR_SCENE_NODE_BUFFER => {
            const sb: *c.wlr_scene_buffer = @fieldParentPtr("node", node);
            const surface = c.wlr_scene_surface_try_from_buffer(sb) orelse return;
            const texture = c.wlr_surface_get_texture(surface.*.surface) orelse return;
            const w: f32 = @floatFromInt(if (sb.dst_width > 0) sb.dst_width else @as(c_int, @intCast(texture.*.width)));
            const h: f32 = @floatFromInt(if (sb.dst_height > 0) sb.dst_height else @as(c_int, @intCast(texture.*.height)));
            const box = deviceBox(f, x, y, w, h, xf);
            if (box.width == 0 or box.height == 0) return;
            var alpha: f32 = sb.opacity * (if (xf) |t| t.alpha else 1);
            var opts = std.mem.zeroes(c.wlr_render_texture_options);
            opts.texture = texture;
            opts.src_box = sb.src_box;
            opts.dst_box = box;
            opts.alpha = &alpha;
            opts.transform = sb.transform;
            opts.filter_mode = sb.filter_mode;
            c.wlr_render_pass_add_texture(f.pass, &opts);
        },
        else => {},
    }
}

/// Draws the whole scene onto the output and commits it. False when anything failed (the caller then
/// falls back to the scene output).
pub fn compose(output: *c.wlr_output, layout: *c.wlr_output_layout, root: *c.wlr_scene_tree, lookup: Lookup) bool {
    var state: c.wlr_output_state = undefined;
    c.wlr_output_state_init(&state);
    defer c.wlr_output_state_finish(&state);
    const pass = c.wlr_output_begin_render_pass(output, &state, null) orelse return false;

    var box: c.wlr_box = std.mem.zeroes(c.wlr_box);
    c.wlr_output_layout_get_box(layout, output, &box);
    var width: c_int = 0;
    var height: c_int = 0;
    c.wlr_output_effective_resolution(output, &width, &height);
    const f: Frame = .{
        .pass = pass,
        .ox = @floatFromInt(box.x),
        .oy = @floatFromInt(box.y),
        .scale = output.*.scale,
        .lookup = lookup,
    };

    var clear = std.mem.zeroes(c.wlr_render_rect_options);
    clear.box = .{ .x = 0, .y = 0, .width = output.*.width, .height = output.*.height };
    clear.color = .{ .r = 0, .g = 0, .b = 0, .a = 1 };
    clear.blend_mode = c.WLR_RENDER_BLEND_MODE_NONE;
    c.wlr_render_pass_add_rect(pass, &clear);

    drawNode(&f, &root.node, 0, 0, null);

    var full: c.pixman_region32_t = undefined;
    c.pixman_region32_init_rect(&full, 0, 0, @intCast(output.*.width), @intCast(output.*.height));
    defer c.pixman_region32_fini(&full);
    c.wlr_output_add_software_cursors_to_render_pass(output, pass, &full);

    if (!c.wlr_render_pass_submit(pass)) return false;
    return c.wlr_output_commit_state(output, &state);
}
