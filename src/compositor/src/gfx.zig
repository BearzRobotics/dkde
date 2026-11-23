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
const cube_mod = @import("cube.zig");

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

/// The desktop cube for this frame.
pub const Cube = struct {
    /// Where it is turned to, in workspaces (fractional while it turns), and how many faces it has.
    pos: f32,
    count: usize,
    /// Called with the workspace whose windows the scene should show next (null: back to normal).
    filter: *const fn (?usize) void,
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

const vertex_persp =
    \\attribute vec4 a_pos;
    \\attribute vec2 a_uv;
    \\varying vec2 v_uv;
    \\void main() {
    \\    v_uv = a_uv;
    \\    gl_Position = a_pos;
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

const frag_blur =
    \\precision mediump float;
    \\varying vec2 v_uv;
    \\uniform sampler2D u_tex;
    \\uniform vec2 u_step;
    \\uniform vec4 u_clamp;
    \\void main() {
    \\    vec2 lo = u_clamp.xy;
    \\    vec2 hi = u_clamp.zw;
    \\    vec4 c = texture2D(u_tex, clamp(v_uv, lo, hi)) * 0.2270270270;
    \\    c += texture2D(u_tex, clamp(v_uv + u_step * 1.3846153846, lo, hi)) * 0.3162162162;
    \\    c += texture2D(u_tex, clamp(v_uv - u_step * 1.3846153846, lo, hi)) * 0.3162162162;
    \\    c += texture2D(u_tex, clamp(v_uv + u_step * 3.2307692308, lo, hi)) * 0.0702702703;
    \\    c += texture2D(u_tex, clamp(v_uv - u_step * 3.2307692308, lo, hi)) * 0.0702702703;
    \\    gl_FragColor = c;
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
    step: c.GLint = -1,
    clamp: c.GLint = -1,
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
        .step = c.glGetUniformLocation(id, "u_step"),
        .clamp = c.glGetUniformLocation(id, "u_clamp"),
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
    blur: Program,
    persp: Program,
    /// One texture and framebuffer per workspace, for the faces of the cube.
    face_tex: [9]c.GLuint = std.mem.zeroes([9]c.GLuint),
    face_fbo: [9]c.GLuint = std.mem.zeroes([9]c.GLuint),
    face_w: i32 = 0,
    face_h: i32 = 0,
    /// Blur of what is behind translucent windows: a copy of the frame, and two half-size targets to blur between.
    blur_src: c.GLuint = 0,
    blur_tex: [2]c.GLuint = .{ 0, 0 },
    blur_fbo: [2]c.GLuint = .{ 0, 0 },
    blur_w: i32 = 0,
    blur_h: i32 = 0,
    /// How many blur passes pairs (each widens the blur).
    blur_passes: u32 = 2,
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
        const blur = link(vertex_src, frag_blur) orelse return null;
        const persp = link(vertex_persp, frag_tex) orelse return null;
        // The external-image variant exists only where the driver has the extension.
        const ext = if (c.wlr_gles2_renderer_check_ext(renderer, "GL_OES_EGL_image_external")) link(vertex_src, frag_ext) else null;
        const self = allocator.create(Gfx) catch return null;
        self.* = .{ .renderer = renderer, .display = display, .context = context, .tex = tex, .ext = ext, .solid = solid, .post = post, .blur = blur, .persp = persp };
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

    fn makeTexture(w: i32, h: i32) c.GLuint {
        var t: c.GLuint = 0;
        c.glGenTextures(1, &t);
        c.glBindTexture(c.GL_TEXTURE_2D, t);
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA, w, h, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, null);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
        return t;
    }

    fn ensureBlur(self: *Gfx, w: i32, h: i32) bool {
        if (self.blur_w == w and self.blur_h == h and self.blur_src != 0) return true;
        if (self.blur_src != 0) c.glDeleteTextures(1, &self.blur_src);
        for (0..2) |i| {
            if (self.blur_tex[i] != 0) c.glDeleteTextures(1, &self.blur_tex[i]);
            if (self.blur_fbo[i] != 0) c.glDeleteFramebuffers(1, &self.blur_fbo[i]);
        }
        self.blur_src = makeTexture(w, h);
        for (0..2) |i| {
            self.blur_tex[i] = makeTexture(@divTrunc(w, 2) + 1, @divTrunc(h, 2) + 1);
            c.glGenFramebuffers(1, &self.blur_fbo[i]);
            c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.blur_fbo[i]);
            c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, self.blur_tex[i], 0);
        }
        self.blur_w = w;
        self.blur_h = h;
        return true;
    }

    fn ensureFace(self: *Gfx, index: usize, w: i32, h: i32) bool {
        if (self.face_w != w or self.face_h != h) {
            for (0..9) |i| {
                if (self.face_tex[i] != 0) c.glDeleteTextures(1, &self.face_tex[i]);
                if (self.face_fbo[i] != 0) c.glDeleteFramebuffers(1, &self.face_fbo[i]);
                self.face_tex[i] = 0;
                self.face_fbo[i] = 0;
            }
            self.face_w = w;
            self.face_h = h;
        }
        if (self.face_fbo[index] != 0) return true;
        self.face_tex[index] = makeTexture(w, h);
        c.glGenFramebuffers(1, &self.face_fbo[index]);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.face_fbo[index]);
        c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, self.face_tex[index], 0);
        return c.glCheckFramebufferStatus(c.GL_FRAMEBUFFER) == c.GL_FRAMEBUFFER_COMPLETE;
    }

    fn drawCube(self: *Gfx, painter: *Painter, lookup: render.Lookup, root: *c.wlr_scene_tree, cb: Cube, target: c.GLuint, w: i32, h: i32) void {
        drawCubeImpl(self, painter, lookup, root, cb, target, w, h);
    }

    /// Draws the whole scene onto the output and commits it. False when anything failed.
    pub fn compose(self: *Gfx, output: *c.wlr_output, layout: *c.wlr_output_layout, root: *c.wlr_scene_tree, lookup: render.Lookup, post: Post, cube: ?Cube) bool {
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
        var painter: Painter = .{
            .gfx = self,
            .w = @floatFromInt(w),
            .h = @floatFromInt(h),
            .ox = @floatFromInt(box.x),
            .oy = @floatFromInt(box.y),
            .scale = output.*.scale,
        };

        var painter_fbo = out_fbo;
        const use_scene = post.active();
        if (use_scene) {
            if (!self.ensureScene(w, h)) return false;
            c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.scene_fbo);
            painter_fbo = self.scene_fbo;
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
        painter.fbo = painter_fbo;
        if (cube) |cb| {
            self.drawCube(&painter, lookup, root, cb, painter_fbo, w, h);
        } else {
            render.walk(&painter, lookup, &root.node, 0, 0, null);
        }

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

/// The cube: each visible face is the scene drawn with only that workspace's windows, put on a turning prism.
fn drawCubeImpl(self: *Gfx, painter: *Painter, lookup: render.Lookup, root: *c.wlr_scene_tree, cb: Cube, target: c.GLuint, w: i32, h: i32) void {
    var faces: [9]cube_mod.Face = undefined;
    const count = @min(cb.count, 9);
    const shown = cube_mod.faces(count, cb.pos, @floatFromInt(w), @floatFromInt(h), &faces);
    for (faces[0..shown]) |f| {
        if (!self.ensureFace(f.index, w, h)) continue;
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.face_fbo[f.index]);
        c.glViewport(0, 0, w, h);
        c.glClearColor(0, 0, 0, 1);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
        c.glEnable(c.GL_BLEND);
        painter.fbo = self.face_fbo[f.index];
        cb.filter(f.index);
        render.walk(painter, lookup, &root.node, 0, 0, null);
        cb.filter(null);
    }
    painter.fbo = target;
    c.glBindFramebuffer(c.GL_FRAMEBUFFER, target);
    c.glViewport(0, 0, w, h);
    c.glClearColor(0, 0, 0, 1);
    c.glClear(c.GL_COLOR_BUFFER_BIT);
    c.glDisable(c.GL_BLEND);
    c.glUseProgram(self.persp.id);
    c.glActiveTexture(c.GL_TEXTURE0);
    c.glUniform1i(self.persp.tex, 0);
    c.glUniform1f(self.persp.has_alpha, 0);
    for (faces[0..shown]) |f| {
        c.glBindTexture(c.GL_TEXTURE_2D, self.face_tex[f.index]);
        c.glUniform1f(self.persp.alpha, f.light);
        const Pv = extern struct { x: f32, y: f32, z: f32, w: f32, u: f32, v: f32 };
        var quad: [6]Pv = undefined;
        const order = [6]usize{ 0, 1, 2, 1, 3, 2 };
        for (order, 0..) |q, i| {
            const cv = f.corners[q];
            quad[i] = .{ .x = cv.x, .y = cv.y, .z = 0, .w = cv.w, .u = cv.u, .v = cv.v };
        }
        c.glVertexAttribPointer(0, 4, c.GL_FLOAT, c.GL_FALSE, @sizeOf(Pv), &quad[0].x);
        c.glVertexAttribPointer(1, 2, c.GL_FLOAT, c.GL_FALSE, @sizeOf(Pv), &quad[0].u);
        c.glDrawArrays(c.GL_TRIANGLES, 0, 6);
    }
    c.glEnable(c.GL_BLEND);
}

/// The scene walker's painter for GL: a quad (or, for a warped window, a grid) per rectangle and texture.
const Painter = struct {
    gfx: *Gfx,
    /// The output's size in pixels, its place in the layout, its scale.
    w: f32,
    h: f32,
    ox: f32,
    oy: f32,
    scale: f32,
    /// The framebuffer being drawn to (blurring switches away from it and back).
    fbo: c.GLuint = 0,

    /// Blurs what has been drawn so far inside the box (output pixels) and puts the result back, so a
    /// translucent window drawn next lies on a frosted background.
    fn blurBehind(self: *const Painter, bx0: f32, by0: f32, bx1: f32, by1: f32) void {
        const g = self.gfx;
        const iw: i32 = @intFromFloat(self.w);
        const ih: i32 = @intFromFloat(self.h);
        const x0: i32 = std.math.clamp(@as(i32, @intFromFloat(@floor(bx0))), 0, iw - 1);
        const y0: i32 = std.math.clamp(@as(i32, @intFromFloat(@floor(by0))), 0, ih - 1);
        const x1: i32 = std.math.clamp(@as(i32, @intFromFloat(@ceil(bx1))), 1, iw);
        const y1: i32 = std.math.clamp(@as(i32, @intFromFloat(@ceil(by1))), 1, ih);
        const rw = x1 - x0;
        const rh = y1 - y0;
        if (rw < 8 or rh < 8 or !g.ensureBlur(iw, ih)) return;
        c.glDisable(c.GL_BLEND);
        // The frame so far, into the copy.
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.fbo);
        c.glBindTexture(c.GL_TEXTURE_2D, g.blur_src);
        c.glCopyTexSubImage2D(c.GL_TEXTURE_2D, 0, x0, y0, x0, y0, rw, rh);

        const fw: f32 = self.w;
        const fh: f32 = self.h;
        const hw: i32 = @divTrunc(rw, 2);
        const hh: i32 = @divTrunc(rh, 2);
        // Where the region sits in the full-size copy and in the half-size targets (which start at their corner).
        const src_u0 = @as(f32, @floatFromInt(x0)) / fw;
        const src_v0 = @as(f32, @floatFromInt(y0)) / fh;
        const src_u1 = @as(f32, @floatFromInt(x1)) / fw;
        const src_v1 = @as(f32, @floatFromInt(y1)) / fh;
        const half_w: f32 = @floatFromInt(@divTrunc(iw, 2) + 1);
        const half_h: f32 = @floatFromInt(@divTrunc(ih, 2) + 1);
        const hu1 = @as(f32, @floatFromInt(hw)) / half_w;
        const hv1 = @as(f32, @floatFromInt(hh)) / half_h;

        c.glUseProgram(g.blur.id);
        c.glUniform2f(g.blur.size, 1, 1);
        c.glUniform1i(g.blur.tex, 0);
        c.glActiveTexture(c.GL_TEXTURE0);
        var from: c.GLuint = g.blur_src;
        var which: usize = 0;
        var pass: u32 = 0;
        while (pass < g.blur_passes * 2) : (pass += 1) {
            const horizontal = pass % 2 == 0;
            const first = pass == 0;
            c.glBindFramebuffer(c.GL_FRAMEBUFFER, g.blur_fbo[which]);
            c.glViewport(0, 0, hw, hh);
            c.glBindTexture(c.GL_TEXTURE_2D, from);
            // The first pass reads the full-size copy (so it also halves the size); the rest read half-size targets.
            const u0r: f32 = if (first) src_u0 else 0;
            const v0r: f32 = if (first) src_v0 else 0;
            const u1r: f32 = if (first) src_u1 else hu1;
            const v1r: f32 = if (first) src_v1 else hv1;
            const texel_w: f32 = if (first) 1.0 / fw else 1.0 / half_w;
            const texel_h: f32 = if (first) 1.0 / fh else 1.0 / half_h;
            c.glUniform2f(g.blur.step, if (horizontal) texel_w * 1.5 else 0, if (horizontal) 0 else texel_h * 1.5);
            c.glUniform4f(g.blur.clamp, u0r + texel_w * 0.5, v0r + texel_h * 0.5, u1r - texel_w * 0.5, v1r - texel_h * 0.5);
            const quad = [_]Vertex{
                .{ .x = 0, .y = 0, .u = u0r, .v = v0r }, .{ .x = 1, .y = 0, .u = u1r, .v = v0r }, .{ .x = 0, .y = 1, .u = u0r, .v = v1r },
                .{ .x = 1, .y = 0, .u = u1r, .v = v0r }, .{ .x = 1, .y = 1, .u = u1r, .v = v1r }, .{ .x = 0, .y = 1, .u = u0r, .v = v1r },
            };
            c.glVertexAttribPointer(0, 2, c.GL_FLOAT, c.GL_FALSE, @sizeOf(Vertex), &quad[0].x);
            c.glVertexAttribPointer(1, 2, c.GL_FLOAT, c.GL_FALSE, @sizeOf(Vertex), &quad[0].u);
            c.glDrawArrays(c.GL_TRIANGLES, 0, 6);
            from = g.blur_tex[which];
            which = 1 - which;
        }
        // Back to the frame: the blurred region over the original.
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.fbo);
        c.glViewport(0, 0, iw, ih);
        c.glUseProgram(g.tex.id);
        c.glUniform2f(g.tex.size, self.w, self.h);
        c.glUniform1f(g.tex.alpha, 1);
        c.glUniform1f(g.tex.has_alpha, 0);
        c.glUniform1i(g.tex.tex, 0);
        c.glBindTexture(c.GL_TEXTURE_2D, from);
        const fx0: f32 = @floatFromInt(x0);
        const fy0: f32 = @floatFromInt(y0);
        const fx1: f32 = @floatFromInt(x1);
        const fy1: f32 = @floatFromInt(y1);
        const quad = [_]Vertex{
            .{ .x = fx0, .y = fy0, .u = 0, .v = 0 }, .{ .x = fx1, .y = fy0, .u = hu1, .v = 0 }, .{ .x = fx0, .y = fy1, .u = 0, .v = hv1 },
            .{ .x = fx1, .y = fy0, .u = hu1, .v = 0 }, .{ .x = fx1, .y = fy1, .u = hu1, .v = hv1 }, .{ .x = fx0, .y = fy1, .u = 0, .v = hv1 },
        };
        c.glVertexAttribPointer(0, 2, c.GL_FLOAT, c.GL_FALSE, @sizeOf(Vertex), &quad[0].x);
        c.glVertexAttribPointer(1, 2, c.GL_FLOAT, c.GL_FALSE, @sizeOf(Vertex), &quad[0].u);
        c.glDrawArrays(c.GL_TRIANGLES, 0, 6);
        c.glEnable(c.GL_BLEND);
    }

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

    /// A texture through a wobbly window's mesh: the quad becomes a grid, each corner displaced.
    fn drawWarped(self: *const Painter, xf: Xf, x: f32, y: f32, w: f32, h: f32, uv: [4]f32) void {
        const cells = 8;
        var verts: [cells * cells * 6]Vertex = undefined;
        var n: usize = 0;
        const warp = xf.warp.?;
        for (0..cells) |j| {
            for (0..cells) |i| {
                const fi: f32 = @floatFromInt(i);
                const fj: f32 = @floatFromInt(j);
                const k: f32 = @floatFromInt(cells);
                const corners = [4][2]f32{ .{ fi / k, fj / k }, .{ (fi + 1) / k, fj / k }, .{ fi / k, (fj + 1) / k }, .{ (fi + 1) / k, (fj + 1) / k } };
                var v: [4]Vertex = undefined;
                for (corners, 0..) |cn, q| {
                    const lx = x + cn[0] * w;
                    const ly = y + cn[1] * h;
                    const d = warp.at(lx, ly);
                    const p = self.dev(lx + d[0], ly + d[1], xf);
                    v[q] = .{ .x = p[0], .y = p[1], .u = uv[0] + (uv[2] - uv[0]) * cn[0], .v = uv[1] + (uv[3] - uv[1]) * cn[1] };
                }
                const tri = [6]usize{ 0, 1, 2, 1, 3, 2 };
                for (tri) |t| {
                    verts[n] = v[t];
                    n += 1;
                }
            }
        }
        c.glVertexAttribPointer(0, 2, c.GL_FLOAT, c.GL_FALSE, @sizeOf(Vertex), &verts[0].x);
        c.glVertexAttribPointer(1, 2, c.GL_FLOAT, c.GL_FALSE, @sizeOf(Vertex), &verts[0].u);
        c.glDrawArrays(c.GL_TRIANGLES, 0, @intCast(n));
    }

    pub fn texture(self: *const Painter, sb: *c.wlr_scene_buffer, tex: *c.wlr_texture, x: f32, y: f32, w: f32, h: f32, xf: ?Xf) void {
        if (!c.wlr_texture_is_gles2(tex)) return;
        if (xf != null and xf.?.blur) {
            const b0 = self.dev(x, y, xf);
            const b1 = self.dev(x + w, y + h, xf);
            self.blurBehind(b0[0], b0[1], b1[0], b1[1]);
        }
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
        if (xf != null and xf.?.warp != null) {
            self.drawWarped(xf.?, x, y, w, h, .{ tu0, tv0, tu1, tv1 });
            return;
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
