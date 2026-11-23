//! The GLES frame composer: draws the scene graph with our own shaders, so a frame can be zoomed,
//! colour-filtered, and (later) have windows warped, blurred or placed in 3D. It needs wlroots' GLES2 renderer;
//! with another renderer `Gfx.create` returns null and the render-pass composer in render.zig is used.
//!
//! It shares the EGL context of the wlroots renderer: it makes it current, renders into the output's own
//! swapchain buffer through the renderer's framebuffer, waits for the GPU (glFinish), then lets a wlroots
//! render pass add the software cursor, and commits.

const std = @import("std");
const c = @import("c");
const render = @import("render.zig");
const anim = @import("anim.zig");

pub const Xf = anim.Xf;

/// What happens to the finished frame: a zoom about a point (which stays where it is) and a colour matrix.
pub const Post = struct {
    zoom: f32 = 1,
    /// The point that stays put, as a fraction of the output (0..1).
    fx: f32 = 0.5,
    fy: f32 = 0.5,
    /// Column-major 3x3 colour matrix and a per-channel offset (identity = no change).
    m: [9]f32 = identity,
    off: [3]f32 = .{ 0, 0, 0 },

    pub const identity = [9]f32{ 1, 0, 0, 0, 1, 0, 0, 0, 1 };

    pub fn active(self: Post) bool {
        return self.zoom != 1 or !std.mem.eql(f32, &self.m, &identity) or self.off[0] != 0 or self.off[1] != 0 or self.off[2] != 0;
    }
};

/// A colour matrix given by rows (as they are usually written); the result is column-major for GL.
pub fn fromRows(r: [9]f32) [9]f32 {
    return .{ r[0], r[3], r[6], r[1], r[4], r[7], r[2], r[5], r[8] };
}

const vertex_src =
    \\attribute vec2 a_pos;
    \\attribute vec2 a_uv;
    \\uniform vec2 u_size;
    \\varying vec2 v_uv;
    \\void main() {
    \\    v_uv = a_uv;
    \\    gl_Position = vec4(a_pos.x / u_size.x * 2.0 - 1.0, a_pos.y / u_size.y * 2.0 - 1.0, 0.0, 1.0);
    \\}
;

const frag_tex =
    \\precision mediump float;
    \\varying vec2 v_uv;
    \\uniform sampler2D u_tex;
    \\uniform float u_alpha;
    \\uniform float u_has_alpha;
    \\void main() {
    \\    vec4 t = texture2D(u_tex, v_uv);
    \\    if (u_has_alpha < 0.5) t.a = 1.0;
    \\    gl_FragColor = t * u_alpha;
    \\}
;

const frag_ext =
    \\#extension GL_OES_EGL_image_external : require
    \\precision mediump float;
    \\varying vec2 v_uv;
    \\uniform samplerExternalOES u_tex;
    \\uniform float u_alpha;
    \\uniform float u_has_alpha;
    \\void main() {
    \\    vec4 t = texture2D(u_tex, v_uv);
    \\    if (u_has_alpha < 0.5) t.a = 1.0;
    \\    gl_FragColor = t * u_alpha;
    \\}
;

const frag_solid =
    \\precision mediump float;
    \\varying vec2 v_uv;
    \\uniform vec4 u_color;
    \\void main() {
    \\    gl_FragColor = u_color;
    \\}
;

const frag_post =
    \\precision mediump float;
    \\varying vec2 v_uv;
    \\uniform sampler2D u_tex;
    \\uniform float u_zoom;
    \\uniform vec2 u_focus;
    \\uniform mat3 u_matrix;
    \\uniform vec3 u_offset;
    \\void main() {
    \\    vec2 uv = u_focus + (v_uv - u_focus) / u_zoom;
    \\    vec3 rgb = texture2D(u_tex, uv).rgb;
    \\    gl_FragColor = vec4(clamp(u_matrix * rgb + u_offset, 0.0, 1.0), 1.0);
    \\}
;

const Program = struct {
    id: c.GLuint = 0,
    size: c.GLint = -1,
    tex: c.GLint = -1,
    alpha: c.GLint = -1,
    has_alpha: c.GLint = -1,
    color: c.GLint = -1,
    zoom: c.GLint = -1,
    focus: c.GLint = -1,
    matrix: c.GLint = -1,
    offset: c.GLint = -1,
};

fn compile(kind: c.GLenum, source: [*:0]const u8) c.GLuint {
    const shader = c.glCreateShader(kind);
    const sources = [_][*c]const u8{source};
    c.glShaderSource(shader, 1, &sources, null);
    c.glCompileShader(shader);
    var ok: c.GLint = 0;
    c.glGetShaderiv(shader, c.GL_COMPILE_STATUS, &ok);
    if (ok == 0) {
        var log: [512]u8 = undefined;
        var len: c.GLsizei = 0;
        c.glGetShaderInfoLog(shader, log.len, &len, &log);
        c._wlr_log(c.WLR_ERROR, "shader: %.*s", @as(c_int, @intCast(len)), &log);
        c.glDeleteShader(shader);
        return 0;
    }
    return shader;
}

fn link(vertex: [*:0]const u8, fragment: [*:0]const u8) ?Program {
    const vs = compile(c.GL_VERTEX_SHADER, vertex);
    if (vs == 0) return null;
    const fs = compile(c.GL_FRAGMENT_SHADER, fragment);
    if (fs == 0) {
        c.glDeleteShader(vs);
        return null;
    }
    const id = c.glCreateProgram();
    c.glAttachShader(id, vs);
    c.glAttachShader(id, fs);
    c.glBindAttribLocation(id, 0, "a_pos");
    c.glBindAttribLocation(id, 1, "a_uv");
    c.glLinkProgram(id);
    c.glDeleteShader(vs);
    c.glDeleteShader(fs);
    var ok: c.GLint = 0;
    c.glGetProgramiv(id, c.GL_LINK_STATUS, &ok);
    if (ok == 0) {
        c._wlr_log(c.WLR_ERROR, "shader program does not link");
        c.glDeleteProgram(id);
        return null;
    }
    return .{
        .id = id,
        .size = c.glGetUniformLocation(id, "u_size"),
        .tex = c.glGetUniformLocation(id, "u_tex"),
        .alpha = c.glGetUniformLocation(id, "u_alpha"),
        .has_alpha = c.glGetUniformLocation(id, "u_has_alpha"),
        .color = c.glGetUniformLocation(id, "u_color"),
        .zoom = c.glGetUniformLocation(id, "u_zoom"),
        .focus = c.glGetUniformLocation(id, "u_focus"),
        .matrix = c.glGetUniformLocation(id, "u_matrix"),
        .offset = c.glGetUniformLocation(id, "u_offset"),
    };
}

const Vertex = extern struct { x: f32, y: f32, u: f32, v: f32 };

pub const Gfx = struct {
    renderer: *c.wlr_renderer,
    display: c.EGLDisplay,
    context: c.EGLContext,
    tex: Program,
    ext: ?Program,
    solid: Program,
    post: Program,
    scene_tex: c.GLuint = 0,
    scene_fbo: c.GLuint = 0,
    scene_w: i32 = 0,
    scene_h: i32 = 0,

    /// Null when the renderer is not GLES2 or a shader does not build.
    pub fn create(allocator: std.mem.Allocator, renderer: *c.wlr_renderer) ?*Gfx {
        if (!c.wlr_renderer_is_gles2(renderer)) return null;
        const egl = c.wlr_gles2_renderer_get_egl(renderer) orelse return null;
        const display = c.wlr_egl_get_display(egl);
        const context = c.wlr_egl_get_context(egl);
        if (c.eglMakeCurrent(display, c.EGL_NO_SURFACE, c.EGL_NO_SURFACE, context) == 0) {
            c._wlr_log(c.WLR_ERROR, "effects: cannot use the renderer's EGL context");
            return null;
        }
        defer _ = c.eglMakeCurrent(display, c.EGL_NO_SURFACE, c.EGL_NO_SURFACE, c.EGL_NO_CONTEXT);
        const tex = link(vertex_src, frag_tex) orelse return null;
        const solid = link(vertex_src, frag_solid) orelse return null;
        const post = link(vertex_src, frag_post) orelse return null;
        // The external-image variant exists only where the driver has the extension.
        const ext = if (c.wlr_gles2_renderer_check_ext(renderer, "GL_OES_EGL_image_external")) link(vertex_src, frag_ext) else null;
        const self = allocator.create(Gfx) catch return null;
        self.* = .{ .renderer = renderer, .display = display, .context = context, .tex = tex, .ext = ext, .solid = solid, .post = post };
        return self;
    }

    pub fn destroy(self: *Gfx, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }

    fn ensureScene(self: *Gfx, w: i32, h: i32) bool {
        if (self.scene_w == w and self.scene_h == h and self.scene_fbo != 0) return true;
        if (self.scene_tex != 0) c.glDeleteTextures(1, &self.scene_tex);
        if (self.scene_fbo != 0) c.glDeleteFramebuffers(1, &self.scene_fbo);
        c.glGenTextures(1, &self.scene_tex);
        c.glBindTexture(c.GL_TEXTURE_2D, self.scene_tex);
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA, w, h, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, null);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
        c.glGenFramebuffers(1, &self.scene_fbo);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.scene_fbo);
        c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, self.scene_tex, 0);
        const ok = c.glCheckFramebufferStatus(c.GL_FRAMEBUFFER) == c.GL_FRAMEBUFFER_COMPLETE;
        self.scene_w = w;
        self.scene_h = h;
        return ok;
    }

    /// Draws the whole scene onto the output and commits it. False when anything failed.
    pub fn compose(self: *Gfx, output: *c.wlr_output, layout: *c.wlr_output_layout, root: *c.wlr_scene_tree, lookup: render.Lookup, post: Post) bool {
        if (c.eglMakeCurrent(self.display, c.EGL_NO_SURFACE, c.EGL_NO_SURFACE, self.context) == 0) return false;
        defer _ = c.eglMakeCurrent(self.display, c.EGL_NO_SURFACE, c.EGL_NO_SURFACE, c.EGL_NO_CONTEXT);

        var state: c.wlr_output_state = undefined;
        c.wlr_output_state_init(&state);
        defer c.wlr_output_state_finish(&state);
        var swapchain: ?*c.wlr_swapchain = null;
        if (!c.wlr_output_configure_primary_swapchain(output, &state, &swapchain)) return false;
        const buffer = c.wlr_swapchain_acquire(swapchain.?) orelse return false;
        defer c.wlr_buffer_unlock(buffer);
        const out_fbo = c.wlr_gles2_renderer_get_buffer_fbo(self.renderer, buffer);
        if (out_fbo == 0) return false;
        const w: i32 = @intCast(buffer.*.width);
        const h: i32 = @intCast(buffer.*.height);

        var box: c.wlr_box = std.mem.zeroes(c.wlr_box);
        c.wlr_output_layout_get_box(layout, output, &box);
        const painter: Painter = .{
            .gfx = self,
            .w = @floatFromInt(w),
            .h = @floatFromInt(h),
            .ox = @floatFromInt(box.x),
            .oy = @floatFromInt(box.y),
            .scale = output.*.scale,
        };

        const use_scene = post.active();
        if (use_scene) {
            if (!self.ensureScene(w, h)) return false;
            c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.scene_fbo);
        } else {
            c.glBindFramebuffer(c.GL_FRAMEBUFFER, out_fbo);
        }
        c.glViewport(0, 0, w, h);
        c.glDisable(c.GL_SCISSOR_TEST);
        c.glClearColor(0, 0, 0, 1);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
        c.glEnable(c.GL_BLEND);
        c.glBlendFunc(c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA);
        c.glEnableVertexAttribArray(0);
        c.glEnableVertexAttribArray(1);
        render.walk(&painter, lookup, &root.node, 0, 0, null);

        if (use_scene) {
            c.glBindFramebuffer(c.GL_FRAMEBUFFER, out_fbo);
            c.glViewport(0, 0, w, h);
            c.glDisable(c.GL_BLEND);
            c.glUseProgram(self.post.id);
            c.glUniform2f(self.post.size, 1, 1);
            c.glActiveTexture(c.GL_TEXTURE0);
            c.glBindTexture(c.GL_TEXTURE_2D, self.scene_tex);
            c.glUniform1i(self.post.tex, 0);
            c.glUniform1f(self.post.zoom, post.zoom);
            c.glUniform2f(self.post.focus, post.fx, post.fy);
            c.glUniformMatrix3fv(self.post.matrix, 1, c.GL_FALSE, &post.m);
            c.glUniform3f(self.post.offset, post.off[0], post.off[1], post.off[2]);
            // One quad over the whole output; positions are in 0..1 here (u_size is 1x1).
            const quad = [_]Vertex{
                .{ .x = 0, .y = 0, .u = 0, .v = 0 }, .{ .x = 1, .y = 0, .u = 1, .v = 0 }, .{ .x = 0, .y = 1, .u = 0, .v = 1 },
                .{ .x = 1, .y = 0, .u = 1, .v = 0 }, .{ .x = 1, .y = 1, .u = 1, .v = 1 }, .{ .x = 0, .y = 1, .u = 0, .v = 1 },
            };
            c.glVertexAttribPointer(0, 2, c.GL_FLOAT, c.GL_FALSE, @sizeOf(Vertex), &quad[0].x);
            c.glVertexAttribPointer(1, 2, c.GL_FLOAT, c.GL_FALSE, @sizeOf(Vertex), &quad[0].u);
            c.glDrawArrays(c.GL_TRIANGLES, 0, 6);
        }
        c.glDisableVertexAttribArray(0);
        c.glDisableVertexAttribArray(1);
        c.glBindTexture(c.GL_TEXTURE_2D, 0);
        c.glUseProgram(0);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
        // The buffer goes to the display next: everything drawn must be done first.
        c.glFinish();

        // The software cursor (when the output has no hardware one) is drawn by wlroots on top.
        if (c.wlr_renderer_begin_buffer_pass(self.renderer, buffer, null)) |pass| {
            var full: c.pixman_region32_t = undefined;
            c.pixman_region32_init_rect(&full, 0, 0, @intCast(w), @intCast(h));
            defer c.pixman_region32_fini(&full);
            c.wlr_output_add_software_cursors_to_render_pass(output, pass, &full);
            if (!c.wlr_render_pass_submit(pass)) return false;
        }
        c.wlr_output_state_set_buffer(&state, buffer);
        return c.wlr_output_commit_state(output, &state);
    }
};

/// The scene walker's painter for GL: a quad (or, for a warped window, a grid) per rectangle and texture.
const Painter = struct {
    gfx: *Gfx,
    /// The output's size in pixels, its place in the layout, its scale.
    w: f32,
    h: f32,
    ox: f32,
    oy: f32,
    scale: f32,

    /// Layout coordinates (after the window transform) to output pixels.
    fn dev(self: *const Painter, x: f32, y: f32, xf: ?Xf) [2]f32 {
        var px = x;
        var py = y;
        if (xf) |t| {
            px = t.ax + (x - t.ax) * t.scale + t.tx;
            py = t.ay + (y - t.ay) * t.scale + t.ty;
        }
        return .{ (px - self.ox) * self.scale, (py - self.oy) * self.scale };
    }

    pub fn rect(self: *const Painter, x: f32, y: f32, w: f32, h: f32, color: [4]f32, xf: ?Xf) void {
        const a: f32 = if (xf) |t| t.alpha else 1;
        const p0 = self.dev(x, y, xf);
        const p1 = self.dev(x + w, y + h, xf);
        const g = self.gfx;
        c.glUseProgram(g.solid.id);
        c.glUniform2f(g.solid.size, self.w, self.h);
        c.glUniform4f(g.solid.color, color[0] * a, color[1] * a, color[2] * a, color[3] * a);
        const quad = [_]Vertex{
            .{ .x = p0[0], .y = p0[1], .u = 0, .v = 0 }, .{ .x = p1[0], .y = p0[1], .u = 0, .v = 0 }, .{ .x = p0[0], .y = p1[1], .u = 0, .v = 0 },
            .{ .x = p1[0], .y = p0[1], .u = 0, .v = 0 }, .{ .x = p1[0], .y = p1[1], .u = 0, .v = 0 }, .{ .x = p0[0], .y = p1[1], .u = 0, .v = 0 },
        };
        c.glVertexAttribPointer(0, 2, c.GL_FLOAT, c.GL_FALSE, @sizeOf(Vertex), &quad[0].x);
        c.glVertexAttribPointer(1, 2, c.GL_FLOAT, c.GL_FALSE, @sizeOf(Vertex), &quad[0].u);
        c.glDrawArrays(c.GL_TRIANGLES, 0, 6);
    }

    pub fn texture(self: *const Painter, sb: *c.wlr_scene_buffer, tex: *c.wlr_texture, x: f32, y: f32, w: f32, h: f32, xf: ?Xf) void {
        if (!c.wlr_texture_is_gles2(tex)) return;
        var attribs: c.wlr_gles2_texture_attribs = std.mem.zeroes(c.wlr_gles2_texture_attribs);
        c.wlr_gles2_texture_get_attribs(tex, &attribs);
        const g = self.gfx;
        const prog = if (attribs.target == c.GL_TEXTURE_EXTERNAL_OES) (g.ext orelse return) else g.tex;
        c.glUseProgram(prog.id);
        c.glUniform2f(prog.size, self.w, self.h);
        c.glUniform1f(prog.alpha, sb.opacity * (if (xf) |t| t.alpha else 1));
        c.glUniform1f(prog.has_alpha, if (attribs.has_alpha) 1 else 0);
        c.glActiveTexture(c.GL_TEXTURE0);
        c.glBindTexture(attribs.target, attribs.tex);
        c.glTexParameteri(attribs.target, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
        c.glTexParameteri(attribs.target, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
        c.glUniform1i(prog.tex, 0);

        // The part of the texture that shows (the whole of it unless the scene buffer crops).
        const tw: f32 = @floatFromInt(tex.*.width);
        const th: f32 = @floatFromInt(tex.*.height);
        var tu0: f32 = 0;
        var tv0: f32 = 0;
        var tu1: f32 = 1;
        var tv1: f32 = 1;
        if (sb.src_box.width > 0 and sb.src_box.height > 0) {
            tu0 = @floatCast(sb.src_box.x / tw);
            tv0 = @floatCast(sb.src_box.y / th);
            tu1 = @floatCast((sb.src_box.x + sb.src_box.width) / tw);
            tv1 = @floatCast((sb.src_box.y + sb.src_box.height) / th);
        }
        const p0 = self.dev(x, y, xf);
        const p1 = self.dev(x + w, y + h, xf);
        const quad = [_]Vertex{
            .{ .x = p0[0], .y = p0[1], .u = tu0, .v = tv0 }, .{ .x = p1[0], .y = p0[1], .u = tu1, .v = tv0 }, .{ .x = p0[0], .y = p1[1], .u = tu0, .v = tv1 },
            .{ .x = p1[0], .y = p0[1], .u = tu1, .v = tv0 }, .{ .x = p1[0], .y = p1[1], .u = tu1, .v = tv1 }, .{ .x = p0[0], .y = p1[1], .u = tu0, .v = tv1 },
        };
        c.glVertexAttribPointer(0, 2, c.GL_FLOAT, c.GL_FALSE, @sizeOf(Vertex), &quad[0].x);
        c.glVertexAttribPointer(1, 2, c.GL_FLOAT, c.GL_FALSE, @sizeOf(Vertex), &quad[0].u);
        c.glDrawArrays(c.GL_TRIANGLES, 0, 6);
    }
};

test "an unchanged frame needs no post pass" {
    const p: Post = .{};
    try std.testing.expect(!p.active());
    try std.testing.expect((Post{ .zoom = 2 }).active());
    try std.testing.expect((Post{ .m = fromRows(.{ -1, 0, 0, 0, -1, 0, 0, 0, -1 }), .off = .{ 1, 1, 1 } }).active());
}

test "a matrix given by rows is stored by columns" {
    const m = fromRows(.{ 1, 2, 3, 4, 5, 6, 7, 8, 9 });
    try std.testing.expectEqual(@as(f32, 2), m[3]);
    try std.testing.expectEqual(@as(f32, 4), m[1]);
}
