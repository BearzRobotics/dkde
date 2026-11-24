//! GLES2 drawing for dkde-xcomp: EGL on the composite overlay window, a textured quad per window (scaled,
//! shifted and translucent as the effects ask), blur behind translucent windows, the workspace cube, and the
//! post pass (zoom, colour filter, lens, ripples, motion blur). The shaders and the settings for the post pass
//! are the compositor's own (shared fx.zig).
//!
//! Everything is drawn the way GL has it, bottom-up, with window pictures uploaded top row first (the X
//! server's order), so a texture's v = 0 is the top of the window; layers are given in screen pixels with the
//! origin at the top left.

const std = @import("std");
const c = @import("c");
const shared = @import("shared");
const fx = shared.fx;
const anim = shared.anim;
const cube_mod = shared.cube;

pub const Post = fx.Post;

/// One picture to draw, bottom to top: a window, the root's background, a sprite.
pub const Layer = struct {
    tex: c.GLuint,
    /// Where it is on the screen (top-left origin) and how big.
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    /// The window's own opacity.
    alpha: f32 = 1,
    /// False for a window without an alpha channel (its alpha byte is not meaningful).
    has_alpha: bool = false,
    tint: [3]f32 = .{ 1, 1, 1 },
    /// Scale about a point, shift and fade of an animation (the identity draws it as it is).
    xf: anim.Xf = .{},
    /// Blur what is behind it first (a translucent window).
    blur: bool = false,
};

/// The desktop cube turning from one workspace to another.
pub const Cube = struct {
    pos: f32,
    count: usize,
    tilt: f32,
    /// The workspace being left (its last picture is kept) and the one entered (drawn live).
    from: usize,
    to: usize,
};

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
    tint: c.GLint = -1,
    aspect: c.GLint = -1,
    lens: c.GLint = -1,
    ripple: c.GLint = -1,
    prev: c.GLint = -1,
    motion: c.GLint = -1,
};

fn warn(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("dkde-xcomp: " ++ fmt ++ "\n", args);
}

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
        warn("shader: {s}", .{log[0..@intCast(len)]});
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
        warn("a shader program does not link", .{});
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
        .tint = c.glGetUniformLocation(id, "u_tint"),
        .aspect = c.glGetUniformLocation(id, "u_aspect"),
        .lens = c.glGetUniformLocation(id, "u_lens"),
        .ripple = c.glGetUniformLocation(id, "u_ripple"),
        .prev = c.glGetUniformLocation(id, "u_prev"),
        .motion = c.glGetUniformLocation(id, "u_motion"),
    };
}

const Vertex = extern struct { x: f32, y: f32, u: f32, v: f32 };
const Pv = extern struct { x: f32, y: f32, z: f32, w: f32, u: f32, v: f32 };

const Target = struct { tex: c.GLuint = 0, fbo: c.GLuint = 0 };

pub const Renderer = struct {
    display: c.EGLDisplay,
    surface: c.EGLSurface,
    context: c.EGLContext,
    w: i32,
    h: i32,
    /// The driver takes BGRA pictures directly (the X server's byte order); otherwise they are swapped here.
    bgra: bool,
    tex: Program,
    solid: Program,
    post: Program,
    blur: Program,
    persp: Program,
    scene: Target = .{},
    mid: Target = .{},
    /// The last picture of the screen, kept for the cube, and for motion blur.
    old_tex: c.GLuint = 0,
    prev_tex: c.GLuint = 0,
    prev_valid: bool = false,
    blur_src: c.GLuint = 0,
    blur_tex: [2]c.GLuint = .{ 0, 0 },
    blur_fbo: [2]c.GLuint = .{ 0, 0 },
    cap_tex: c.GLuint = 0,
    dark_tex: c.GLuint = 0,
    ring_tex: c.GLuint = 0,
    dot_tex: c.GLuint = 0,
    blur_passes: u32 = 2,
    scratch: []u8 = &.{},

    /// Null when EGL or GLES2 are not there (the caller then runs without compositing).
    pub fn init(allocator: std.mem.Allocator, conn: *c.xcb_connection_t, screen_num: c_int, overlay: c.xcb_window_t, visual: c.xcb_visualid_t, w: i32, h: i32) ?*Renderer {
        const get_display: c.PFNEGLGETPLATFORMDISPLAYEXTPROC = @ptrCast(c.eglGetProcAddress("eglGetPlatformDisplayEXT"));
        const make_surface: c.PFNEGLCREATEPLATFORMWINDOWSURFACEEXTPROC = @ptrCast(c.eglGetProcAddress("eglCreatePlatformWindowSurfaceEXT"));
        const get = get_display orelse {
            warn("EGL has no eglGetPlatformDisplayEXT", .{});
            return null;
        };
        const mk = make_surface orelse {
            warn("EGL has no eglCreatePlatformWindowSurfaceEXT", .{});
            return null;
        };
        const attribs = [_]c.EGLint{ c.EGL_PLATFORM_XCB_SCREEN_EXT, screen_num, c.EGL_NONE };
        const display = get(c.EGL_PLATFORM_XCB_EXT, conn, &attribs);
        if (display == c.EGL_NO_DISPLAY) {
            warn("EGL cannot use the X connection (it needs EGL_EXT_platform_xcb)", .{});
            return null;
        }
        var major: c.EGLint = 0;
        var minor: c.EGLint = 0;
        if (c.eglInitialize(display, &major, &minor) == 0) {
            warn("eglInitialize failed", .{});
            return null;
        }
        if (c.eglBindAPI(c.EGL_OPENGL_ES_API) == 0) return null;
        // A configuration for GLES2 on a window of the root's visual.
        var configs: [64]c.EGLConfig = undefined;
        var count: c.EGLint = 0;
        const want = [_]c.EGLint{
            c.EGL_SURFACE_TYPE,    c.EGL_WINDOW_BIT,
            c.EGL_RENDERABLE_TYPE, c.EGL_OPENGL_ES2_BIT,
            c.EGL_RED_SIZE,        8,
            c.EGL_GREEN_SIZE,      8,
            c.EGL_BLUE_SIZE,       8,
            c.EGL_NONE,
        };
        if (c.eglChooseConfig(display, &want, &configs, configs.len, &count) == 0 or count == 0) {
            warn("no EGL configuration for GLES2 on a window", .{});
            return null;
        }
        var chosen: ?c.EGLConfig = null;
        for (configs[0..@intCast(count)]) |cfg| {
            var id: c.EGLint = 0;
            _ = c.eglGetConfigAttrib(display, cfg, c.EGL_NATIVE_VISUAL_ID, &id);
            if (@as(u32, @intCast(id)) == visual) {
                chosen = cfg;
                break;
            }
        }
        const cfg = chosen orelse configs[0];
        const ctx_attribs = [_]c.EGLint{ c.EGL_CONTEXT_CLIENT_VERSION, 2, c.EGL_NONE };
        const context = c.eglCreateContext(display, cfg, c.EGL_NO_CONTEXT, &ctx_attribs);
        if (context == c.EGL_NO_CONTEXT) {
            warn("cannot create a GLES2 context", .{});
            return null;
        }
        var win = overlay;
        const surface = mk(display, cfg, &win, null);
        if (surface == c.EGL_NO_SURFACE) {
            warn("cannot create an EGL surface on the overlay window", .{});
            return null;
        }
        if (c.eglMakeCurrent(display, surface, surface, context) == 0) {
            warn("eglMakeCurrent failed", .{});
            return null;
        }
        _ = c.eglSwapInterval(display, 0);
        const ext_ptr = c.glGetString(c.GL_EXTENSIONS);
        const bgra = ext_ptr != null and std.mem.indexOf(u8, std.mem.span(@as([*:0]const u8, @ptrCast(ext_ptr))), "GL_EXT_texture_format_BGRA8888") != null;
        const tex = link(fx.vertex_src, fx.frag_tex) orelse return null;
        const solid = link(fx.vertex_src, fx.frag_solid) orelse return null;
        const post = link(fx.vertex_src, fx.frag_post) orelse return null;
        const blur = link(fx.vertex_src, fx.frag_blur) orelse return null;
        const persp = link(fx.vertex_persp, fx.frag_tex) orelse return null;
        const self = allocator.create(Renderer) catch return null;
        self.* = .{ .display = display, .surface = surface, .context = context, .w = w, .h = h, .bgra = bgra, .tex = tex, .solid = solid, .post = post, .blur = blur, .persp = persp };
        c.glEnableVertexAttribArray(0);
        c.glEnableVertexAttribArray(1);
        self.ring_tex = makeSprite(ringAlpha);
        self.dot_tex = makeSprite(dotAlpha);
        self.dark_tex = makeSolid(14, 16, 24);
        self.cap_tex = makeSolid(34, 42, 62);
        return self;
    }

    pub fn destroy(self: *Renderer, allocator: std.mem.Allocator) void {
        _ = c.eglMakeCurrent(self.display, c.EGL_NO_SURFACE, c.EGL_NO_SURFACE, c.EGL_NO_CONTEXT);
        _ = c.eglDestroySurface(self.display, self.surface);
        _ = c.eglDestroyContext(self.display, self.context);
        _ = c.eglTerminate(self.display);
        allocator.free(self.scratch);
        allocator.destroy(self);
    }

    // ---- textures --------------------------------------------------------------------------------------------

    fn params() void {
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
    }

    fn makeTexture(w: i32, h: i32) c.GLuint {
        var t: c.GLuint = 0;
        c.glGenTextures(1, &t);
        c.glBindTexture(c.GL_TEXTURE_2D, t);
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA, w, h, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, null);
        params();
        return t;
    }

    fn makeSolid(r: u8, g: u8, b: u8) c.GLuint {
        var t: c.GLuint = 0;
        c.glGenTextures(1, &t);
        c.glBindTexture(c.GL_TEXTURE_2D, t);
        const px = [4]u8{ r, g, b, 255 };
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA, 1, 1, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, &px);
        params();
        return t;
    }

    fn dotAlpha(d: f32) f32 {
        return if (d >= 1) 0 else (1 - d) * (1 - d) * 1.3;
    }

    fn ringAlpha(d: f32) f32 {
        const k = (d - 0.8) / 0.12;
        return std.math.exp(-k * k);
    }

    /// A white picture whose opacity follows `alpha_at(distance from the centre, 0..1)`, premultiplied.
    fn makeSprite(comptime alpha_at: fn (f32) f32) c.GLuint {
        const size = 64;
        var pixels: [size * size * 4]u8 = undefined;
        for (0..size) |j| {
            for (0..size) |i| {
                const dx = (@as(f32, @floatFromInt(i)) + 0.5) / size * 2 - 1;
                const dy = (@as(f32, @floatFromInt(j)) + 0.5) / size * 2 - 1;
                const a = std.math.clamp(alpha_at(@sqrt(dx * dx + dy * dy)), 0, 1);
                const v: u8 = @intFromFloat(a * 255);
                const o = (j * size + i) * 4;
                pixels[o] = v;
                pixels[o + 1] = v;
                pixels[o + 2] = v;
                pixels[o + 3] = v;
            }
        }
        var t: c.GLuint = 0;
        c.glGenTextures(1, &t);
        c.glBindTexture(c.GL_TEXTURE_2D, t);
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA, size, size, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, &pixels);
        params();
        return t;
    }

    pub fn newTexture(self: *Renderer) c.GLuint {
        _ = self;
        var t: c.GLuint = 0;
        c.glGenTextures(1, &t);
        c.glBindTexture(c.GL_TEXTURE_2D, t);
        params();
        return t;
    }

    pub fn deleteTexture(self: *Renderer, t: c.GLuint) void {
        _ = self;
        if (t != 0) c.glDeleteTextures(1, &t);
    }

    /// Makes a texture hold a w by h picture of 4-byte pixels in the X server's order (blue, green, red, other).
    pub fn setImage(self: *Renderer, allocator: std.mem.Allocator, tex: c.GLuint, w: i32, h: i32, data: []const u8) void {
        c.glBindTexture(c.GL_TEXTURE_2D, tex);
        if (self.bgra) {
            c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_BGRA_EXT, w, h, 0, c.GL_BGRA_EXT, c.GL_UNSIGNED_BYTE, data.ptr);
        } else {
            const px = self.swapped(allocator, data) orelse return;
            c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA, w, h, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, px.ptr);
        }
    }

    /// Replaces a part of a texture's picture.
    pub fn subImage(self: *Renderer, allocator: std.mem.Allocator, tex: c.GLuint, x: i32, y: i32, w: i32, h: i32, data: []const u8) void {
        c.glBindTexture(c.GL_TEXTURE_2D, tex);
        if (self.bgra) {
            c.glTexSubImage2D(c.GL_TEXTURE_2D, 0, x, y, w, h, c.GL_BGRA_EXT, c.GL_UNSIGNED_BYTE, data.ptr);
        } else {
            const px = self.swapped(allocator, data) orelse return;
            c.glTexSubImage2D(c.GL_TEXTURE_2D, 0, x, y, w, h, c.GL_RGBA, c.GL_UNSIGNED_BYTE, px.ptr);
        }
    }

    fn swapped(self: *Renderer, allocator: std.mem.Allocator, data: []const u8) ?[]const u8 {
        if (self.scratch.len < data.len) {
            allocator.free(self.scratch);
            self.scratch = allocator.alloc(u8, data.len) catch {
                self.scratch = &.{};
                return null;
            };
        }
        var i: usize = 0;
        while (i + 3 < data.len) : (i += 4) {
            self.scratch[i] = data[i + 2];
            self.scratch[i + 1] = data[i + 1];
            self.scratch[i + 2] = data[i];
            self.scratch[i + 3] = data[i + 3];
        }
        return self.scratch[0..data.len];
    }

    fn ensureTarget(t: *Target, w: i32, h: i32) bool {
        if (t.fbo != 0) return true;
        t.tex = makeTexture(w, h);
        c.glGenFramebuffers(1, &t.fbo);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, t.fbo);
        c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, t.tex, 0);
        return c.glCheckFramebufferStatus(c.GL_FRAMEBUFFER) == c.GL_FRAMEBUFFER_COMPLETE;
    }

    fn dropTarget(t: *Target) void {
        if (t.tex != 0) c.glDeleteTextures(1, &t.tex);
        if (t.fbo != 0) c.glDeleteFramebuffers(1, &t.fbo);
        t.* = .{};
    }

    /// The screen changed size: the buffers sized to it are made again when next needed.
    pub fn resize(self: *Renderer, w: i32, h: i32) void {
        if (w == self.w and h == self.h) return;
        self.w = w;
        self.h = h;
        dropTarget(&self.scene);
        dropTarget(&self.mid);
        for ([_]*c.GLuint{ &self.old_tex, &self.prev_tex, &self.blur_src }) |t| {
            if (t.* != 0) c.glDeleteTextures(1, t);
            t.* = 0;
        }
        for (0..2) |i| {
            if (self.blur_tex[i] != 0) c.glDeleteTextures(1, &self.blur_tex[i]);
            if (self.blur_fbo[i] != 0) c.glDeleteFramebuffers(1, &self.blur_fbo[i]);
            self.blur_tex[i] = 0;
            self.blur_fbo[i] = 0;
        }
        self.prev_valid = false;
    }

    fn ensureBlur(self: *Renderer) bool {
        if (self.blur_src != 0) return true;
        self.blur_src = makeTexture(self.w, self.h);
        for (0..2) |i| {
            self.blur_tex[i] = makeTexture(@divTrunc(self.w, 2) + 1, @divTrunc(self.h, 2) + 1);
            c.glGenFramebuffers(1, &self.blur_fbo[i]);
            c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.blur_fbo[i]);
            c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, self.blur_tex[i], 0);
        }
        return true;
    }

    // ---- drawing ---------------------------------------------------------------------------------------------

    fn quad(p0: [2]f32, p1: [2]f32, v_top: f32, v_bottom: f32) [6]Vertex {
        return .{
            .{ .x = p0[0], .y = p1[1], .u = 0, .v = v_top },    .{ .x = p1[0], .y = p1[1], .u = 1, .v = v_top },    .{ .x = p0[0], .y = p0[1], .u = 0, .v = v_bottom },
            .{ .x = p1[0], .y = p1[1], .u = 1, .v = v_top },    .{ .x = p1[0], .y = p0[1], .u = 1, .v = v_bottom }, .{ .x = p0[0], .y = p0[1], .u = 0, .v = v_bottom },
        };
    }

    fn draw(q: *const [6]Vertex) void {
        c.glVertexAttribPointer(0, 2, c.GL_FLOAT, c.GL_FALSE, @sizeOf(Vertex), &q[0].x);
        c.glVertexAttribPointer(1, 2, c.GL_FLOAT, c.GL_FALSE, @sizeOf(Vertex), &q[0].u);
        c.glDrawArrays(c.GL_TRIANGLES, 0, 6);
    }

    /// A layer's corners in GL pixels (origin bottom left): the screen's top-left rectangle after the animation.
    fn corners(self: *const Renderer, l: Layer) struct { x0: f32, y0: f32, x1: f32, y1: f32 } {
        const t = l.xf;
        const fh: f32 = @floatFromInt(self.h);
        const ax0 = t.ax + (l.x - t.ax) * t.scale + t.tx;
        const ay0 = t.ay + (l.y - t.ay) * t.scale + t.ty;
        const ax1 = t.ax + (l.x + l.w - t.ax) * t.scale + t.tx;
        const ay1 = t.ay + (l.y + l.h - t.ay) * t.scale + t.ty;
        return .{ .x0 = ax0, .x1 = ax1, .y0 = fh - ay1, .y1 = fh - ay0 };
    }

    fn drawLayer(self: *Renderer, l: Layer, fbo: c.GLuint) void {
        const a = l.alpha * l.xf.alpha;
        if (a <= 0.002 or l.tex == 0) return;
        const k = self.corners(l);
        if (l.blur and a < 0.995) self.blurBehind(k.x0, k.y0, k.x1, k.y1, fbo);
        c.glEnable(c.GL_BLEND);
        c.glBlendFunc(c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA);
        const p = self.tex;
        c.glUseProgram(p.id);
        c.glUniform2f(p.size, @floatFromInt(self.w), @floatFromInt(self.h));
        c.glUniform1f(p.alpha, a);
        c.glUniform1f(p.has_alpha, if (l.has_alpha) 1 else 0);
        c.glUniform3f(p.tint, l.tint[0], l.tint[1], l.tint[2]);
        c.glActiveTexture(c.GL_TEXTURE0);
        c.glBindTexture(c.GL_TEXTURE_2D, l.tex);
        c.glUniform1i(p.tex, 0);
        const q = quad(.{ k.x0, k.y0 }, .{ k.x1, k.y1 }, 0, 1);
        draw(&q);
    }

    /// Blurs what has been drawn so far inside the box (GL pixels) and puts the result back, so a translucent
    /// window drawn next lies on a frosted background.
    fn blurBehind(self: *Renderer, bx0: f32, by0: f32, bx1: f32, by1: f32, fbo: c.GLuint) void {
        const iw = self.w;
        const ih = self.h;
        const x0: i32 = std.math.clamp(@as(i32, @intFromFloat(@floor(bx0))), 0, iw - 1);
        const y0: i32 = std.math.clamp(@as(i32, @intFromFloat(@floor(by0))), 0, ih - 1);
        const x1: i32 = std.math.clamp(@as(i32, @intFromFloat(@ceil(bx1))), 1, iw);
        const y1: i32 = std.math.clamp(@as(i32, @intFromFloat(@ceil(by1))), 1, ih);
        const rw = x1 - x0;
        const rh = y1 - y0;
        if (rw < 8 or rh < 8 or !self.ensureBlur()) return;
        c.glDisable(c.GL_BLEND);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, fbo);
        c.glBindTexture(c.GL_TEXTURE_2D, self.blur_src);
        c.glCopyTexSubImage2D(c.GL_TEXTURE_2D, 0, x0, y0, x0, y0, rw, rh);

        const fw: f32 = @floatFromInt(iw);
        const fh: f32 = @floatFromInt(ih);
        const hw: i32 = @divTrunc(rw, 2);
        const hh: i32 = @divTrunc(rh, 2);
        const src_u0 = @as(f32, @floatFromInt(x0)) / fw;
        const src_v0 = @as(f32, @floatFromInt(y0)) / fh;
        const src_u1 = @as(f32, @floatFromInt(x1)) / fw;
        const src_v1 = @as(f32, @floatFromInt(y1)) / fh;
        const half_w: f32 = @floatFromInt(@divTrunc(iw, 2) + 1);
        const half_h: f32 = @floatFromInt(@divTrunc(ih, 2) + 1);
        const hu1 = @as(f32, @floatFromInt(hw)) / half_w;
        const hv1 = @as(f32, @floatFromInt(hh)) / half_h;

        const b = self.blur;
        c.glUseProgram(b.id);
        c.glUniform2f(b.size, 1, 1);
        c.glUniform1i(b.tex, 0);
        c.glActiveTexture(c.GL_TEXTURE0);
        var from: c.GLuint = self.blur_src;
        var which: usize = 0;
        var pass: u32 = 0;
        while (pass < self.blur_passes * 2) : (pass += 1) {
            const horizontal = pass % 2 == 0;
            const first = pass == 0;
            c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.blur_fbo[which]);
            c.glViewport(0, 0, hw, hh);
            c.glBindTexture(c.GL_TEXTURE_2D, from);
            const u0r: f32 = if (first) src_u0 else 0;
            const v0r: f32 = if (first) src_v0 else 0;
            const u1r: f32 = if (first) src_u1 else hu1;
            const v1r: f32 = if (first) src_v1 else hv1;
            const texel_w: f32 = if (first) 1.0 / fw else 1.0 / half_w;
            const texel_h: f32 = if (first) 1.0 / fh else 1.0 / half_h;
            c.glUniform2f(b.step, if (horizontal) texel_w * 1.5 else 0, if (horizontal) 0 else texel_h * 1.5);
            c.glUniform4f(b.clamp, u0r + texel_w * 0.5, v0r + texel_h * 0.5, u1r - texel_w * 0.5, v1r - texel_h * 0.5);
            const q = [_]Vertex{
                .{ .x = 0, .y = 0, .u = u0r, .v = v0r }, .{ .x = 1, .y = 0, .u = u1r, .v = v0r }, .{ .x = 0, .y = 1, .u = u0r, .v = v1r },
                .{ .x = 1, .y = 0, .u = u1r, .v = v0r }, .{ .x = 1, .y = 1, .u = u1r, .v = v1r }, .{ .x = 0, .y = 1, .u = u0r, .v = v1r },
            };
            draw(&q);
            from = self.blur_tex[which];
            which = 1 - which;
        }
        // Back to the frame: the blurred region over the original.
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, fbo);
        c.glViewport(0, 0, iw, ih);
        const t = self.tex;
        c.glUseProgram(t.id);
        c.glUniform3f(t.tint, 1, 1, 1);
        c.glUniform2f(t.size, fw, fh);
        c.glUniform1f(t.alpha, 1);
        c.glUniform1f(t.has_alpha, 0);
        c.glUniform1i(t.tex, 0);
        c.glBindTexture(c.GL_TEXTURE_2D, from);
        const fx0: f32 = @floatFromInt(x0);
        const fy0: f32 = @floatFromInt(y0);
        const fx1: f32 = @floatFromInt(x1);
        const fy1: f32 = @floatFromInt(y1);
        const q = [_]Vertex{
            .{ .x = fx0, .y = fy0, .u = 0, .v = 0 }, .{ .x = fx1, .y = fy0, .u = hu1, .v = 0 }, .{ .x = fx0, .y = fy1, .u = 0, .v = hv1 },
            .{ .x = fx1, .y = fy0, .u = hu1, .v = 0 }, .{ .x = fx1, .y = fy1, .u = hu1, .v = hv1 }, .{ .x = fx0, .y = fy1, .u = 0, .v = hv1 },
        };
        draw(&q);
        c.glEnable(c.GL_BLEND);
    }

    fn drawLayers(self: *Renderer, layers: []const Layer, fbo: c.GLuint) void {
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, fbo);
        c.glViewport(0, 0, self.w, self.h);
        c.glDisable(c.GL_SCISSOR_TEST);
        c.glClearColor(0, 0, 0, 1);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
        for (layers) |l| self.drawLayer(l, fbo);
    }

    fn drawPersp(face_quad: *const [6]Pv) void {
        c.glVertexAttribPointer(0, 4, c.GL_FLOAT, c.GL_FALSE, @sizeOf(Pv), &face_quad[0].x);
        c.glVertexAttribPointer(1, 2, c.GL_FLOAT, c.GL_FALSE, @sizeOf(Pv), &face_quad[0].u);
        c.glDrawArrays(c.GL_TRIANGLES, 0, 6);
    }

    /// Clip-space vertex for GL: the cube module's y runs down the screen, GL's up; v = 0 is the top row.
    fn pv(v: cube_mod.Vertex) Pv {
        return .{ .x = v.x, .y = -v.y, .z = 0, .w = v.w, .u = v.u, .v = 1 - v.v };
    }

    fn faceQuad(f: cube_mod.Face) [6]Pv {
        var out: [6]Pv = undefined;
        const order = [6]usize{ 0, 1, 2, 1, 3, 2 };
        for (order, 0..) |q, i| out[i] = pv(f.corners[q]);
        return out;
    }

    /// The cube: the old workspace's last picture and the live scene on faces, turned to `cb.pos`.
    fn drawCube(self: *Renderer, cb: Cube, target: c.GLuint) void {
        const fw: f32 = @floatFromInt(self.w);
        const fh: f32 = @floatFromInt(self.h);
        var faces: [9]cube_mod.Face = undefined;
        const count = @min(cb.count, 9);
        const shown = cube_mod.faces(count, cb.pos, fw, fh, cb.tilt, false, &faces);
        var mirrors: [9]cube_mod.Face = undefined;
        const mirrored = cube_mod.faces(count, cb.pos, fw, fh, cb.tilt, true, &mirrors);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, target);
        c.glViewport(0, 0, self.w, self.h);
        c.glClearColor(0, 0, 0, 1);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
        c.glDisable(c.GL_BLEND);
        const p = self.persp;
        c.glUseProgram(p.id);
        c.glUniform3f(p.tint, 1, 1, 1);
        c.glActiveTexture(c.GL_TEXTURE0);
        c.glUniform1i(p.tex, 0);
        c.glUniform1f(p.has_alpha, 0);
        for (faces[0..shown]) |f| {
            c.glBindTexture(c.GL_TEXTURE_2D, self.faceTexture(f.index, cb));
            c.glUniform1f(p.alpha, f.light);
            const q = faceQuad(f);
            drawPersp(&q);
        }
        var cap: [27]cube_mod.Vertex = undefined;
        const cap_n = cube_mod.topCap(count, cb.pos, fw, fh, cb.tilt, &cap);
        if (cap_n > 0) {
            c.glBindTexture(c.GL_TEXTURE_2D, self.cap_tex);
            c.glUniform1f(p.alpha, 1);
            var q: [27]Pv = undefined;
            for (0..cap_n) |i| q[i] = pv(cap[i]);
            c.glVertexAttribPointer(0, 4, c.GL_FLOAT, c.GL_FALSE, @sizeOf(Pv), &q[0].x);
            c.glVertexAttribPointer(1, 2, c.GL_FLOAT, c.GL_FALSE, @sizeOf(Pv), &q[0].u);
            c.glDrawArrays(c.GL_TRIANGLES, 0, @intCast(cap_n));
        }
        c.glEnable(c.GL_BLEND);
        c.glBlendFunc(c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA);
        for (mirrors[0..mirrored]) |f| {
            c.glBindTexture(c.GL_TEXTURE_2D, self.faceTexture(f.index, cb));
            c.glUniform1f(p.alpha, f.light * 0.22);
            const q = faceQuad(f);
            drawPersp(&q);
        }
    }

    fn faceTexture(self: *const Renderer, index: usize, cb: Cube) c.GLuint {
        if (index == cb.to) return self.scene.tex;
        if (index == cb.from and self.old_tex != 0) return self.old_tex;
        return self.dark_tex;
    }

    fn postPass(self: *Renderer, input: c.GLuint, post: Post) void {
        // Made first: creating a texture binds it, which would replace the input on the unit.
        if (self.prev_tex == 0) {
            self.prev_tex = makeTexture(self.w, self.h);
            self.prev_valid = false;
        }
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
        c.glViewport(0, 0, self.w, self.h);
        c.glDisable(c.GL_BLEND);
        const p = self.post;
        c.glUseProgram(p.id);
        c.glUniform2f(p.size, 1, 1);
        c.glActiveTexture(c.GL_TEXTURE0);
        c.glBindTexture(c.GL_TEXTURE_2D, input);
        c.glUniform1i(p.tex, 0);
        c.glUniform1f(p.zoom, post.zoom);
        c.glUniform2f(p.focus, post.fx, post.fy);
        c.glUniformMatrix3fv(p.matrix, 1, c.GL_FALSE, &post.m);
        c.glUniform3f(p.offset, post.off[0], post.off[1], post.off[2]);
        c.glUniform1f(p.aspect, @as(f32, @floatFromInt(self.w)) / @as(f32, @floatFromInt(self.h)));
        c.glUniform4f(p.lens, post.lens_x, post.lens_y, post.lens_r, post.lens_zoom);
        var rip = std.mem.zeroes([Post.max_ripples][4]f32);
        for (0..post.ripple_count) |i| rip[i] = post.ripples[i];
        c.glUniform4fv(p.ripple, Post.max_ripples, &rip[0][0]);
        c.glUniform1f(p.motion, if (self.prev_valid) post.motion else 0);
        c.glUniform1i(p.prev, 1);
        c.glActiveTexture(c.GL_TEXTURE1);
        c.glBindTexture(c.GL_TEXTURE_2D, self.prev_tex);
        c.glActiveTexture(c.GL_TEXTURE0);
        const q = [_]Vertex{
            .{ .x = 0, .y = 0, .u = 0, .v = 0 }, .{ .x = 1, .y = 0, .u = 1, .v = 0 }, .{ .x = 0, .y = 1, .u = 0, .v = 1 },
            .{ .x = 1, .y = 0, .u = 1, .v = 0 }, .{ .x = 1, .y = 1, .u = 1, .v = 1 }, .{ .x = 0, .y = 1, .u = 0, .v = 1 },
        };
        draw(&q);
    }

    /// Draws one frame: the layers (bottom to top), the cube if it is turning, the post effects, and shows it.
    /// With `keep`, the finished picture is kept for the cube's next turn.
    pub fn frame(self: *Renderer, layers: []const Layer, post: Post, cube: ?Cube, keep: bool) bool {
        const need_scene = cube != null or post.active();
        if (need_scene and !ensureTarget(&self.scene, self.w, self.h)) return false;
        if (cube != null and post.active() and !ensureTarget(&self.mid, self.w, self.h)) return false;
        if (cube) |cb| {
            self.drawLayers(layers, self.scene.fbo);
            if (post.active()) {
                self.drawCube(cb, self.mid.fbo);
                self.postPass(self.mid.tex, post);
            } else {
                self.drawCube(cb, 0);
            }
        } else if (post.active()) {
            self.drawLayers(layers, self.scene.fbo);
            self.postPass(self.scene.tex, post);
        } else {
            self.drawLayers(layers, 0);
        }
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
        if (post.motion > 0) {
            if (self.prev_tex == 0) self.prev_tex = makeTexture(self.w, self.h);
            c.glBindTexture(c.GL_TEXTURE_2D, self.prev_tex);
            c.glCopyTexSubImage2D(c.GL_TEXTURE_2D, 0, 0, 0, 0, 0, self.w, self.h);
            self.prev_valid = true;
        } else {
            self.prev_valid = false;
        }
        if (keep) {
            if (self.old_tex == 0) self.old_tex = makeTexture(self.w, self.h);
            c.glBindTexture(c.GL_TEXTURE_2D, self.old_tex);
            c.glCopyTexSubImage2D(c.GL_TEXTURE_2D, 0, 0, 0, 0, 0, self.w, self.h);
        }
        return c.eglSwapBuffers(self.display, self.surface) != 0;
    }
};
