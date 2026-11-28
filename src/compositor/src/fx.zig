// SPDX-License-Identifier: GPL-2.0-or-later
//! What the GLES frame composers share, with no GL calls in it: the shader sources, the frame post-effect
//! settings and colour-matrix helper. src/compositor/src/gfx.zig (Wayland) and src/xcomp (X11) both use it.

const std = @import("std");

/// What happens to the finished frame: a zoom about a point (which stays where it is) and a colour matrix.
pub const Post = struct {
    zoom: f32 = 1,
    /// The point that stays put, as a fraction of the output (0..1).
    fx: f32 = 0.5,
    fy: f32 = 0.5,
    /// Column-major 3x3 colour matrix and a per-channel offset (identity = no change).
    m: [9]f32 = identity,
    off: [3]f32 = .{ 0, 0, 0 },
    /// The magnifier lens: centre (fractions of the output), radius (fraction of the height), zoom; radius 0 = off.
    lens_x: f32 = 0.5,
    lens_y: f32 = 0.5,
    lens_r: f32 = 0,
    lens_zoom: f32 = 2.5,
    ripples: [max_ripples][4]f32 = std.mem.zeroes([max_ripples][4]f32),
    ripple_count: usize = 0,
    /// Motion blur: how much of the previous frame is mixed in (0 = none).
    motion: f32 = 0,

    pub const max_ripples = 8;
    pub const identity = [9]f32{ 1, 0, 0, 0, 1, 0, 0, 0, 1 };

    pub fn active(self: Post) bool {
        return self.zoom != 1 or self.lens_r > 0 or self.ripple_count > 0 or self.motion > 0 or !std.mem.eql(f32, &self.m, &identity) or self.off[0] != 0 or self.off[1] != 0 or self.off[2] != 0;
    }
};

/// A ripple in the screen (the water effect): centre as a fraction of the output, radius in the output's
/// height, strength.
pub const Ripple = struct { x: f32, y: f32, radius: f32, strength: f32 };

/// A colour matrix given by rows (as they are usually written); the result is column-major for GL.
pub fn fromRows(r: [9]f32) [9]f32 {
    return .{ r[0], r[3], r[6], r[1], r[4], r[7], r[2], r[5], r[8] };
}

pub const vertex_src =
    \\attribute vec2 a_pos;
    \\attribute vec2 a_uv;
    \\uniform vec2 u_size;
    \\varying vec2 v_uv;
    \\void main() {
    \\    v_uv = a_uv;
    \\    gl_Position = vec4(a_pos.x / u_size.x * 2.0 - 1.0, a_pos.y / u_size.y * 2.0 - 1.0, 0.0, 1.0);
    \\}
;

pub const frag_tex =
    \\precision mediump float;
    \\varying vec2 v_uv;
    \\uniform sampler2D u_tex;
    \\uniform float u_alpha;
    \\uniform float u_has_alpha;
    \\uniform vec3 u_tint;
    \\void main() {
    \\    vec4 t = texture2D(u_tex, v_uv);
    \\    if (u_has_alpha < 0.5) t.a = 1.0;
    \\    t.rgb *= u_tint;
    \\    gl_FragColor = t * u_alpha;
    \\}
;

pub const frag_ext =
    \\#extension GL_OES_EGL_image_external : require
    \\precision mediump float;
    \\varying vec2 v_uv;
    \\uniform samplerExternalOES u_tex;
    \\uniform float u_alpha;
    \\uniform float u_has_alpha;
    \\uniform vec3 u_tint;
    \\void main() {
    \\    vec4 t = texture2D(u_tex, v_uv);
    \\    if (u_has_alpha < 0.5) t.a = 1.0;
    \\    t.rgb *= u_tint;
    \\    gl_FragColor = t * u_alpha;
    \\}
;

pub const vertex_persp =
    \\attribute vec4 a_pos;
    \\attribute vec2 a_uv;
    \\varying vec2 v_uv;
    \\void main() {
    \\    v_uv = a_uv;
    \\    gl_Position = a_pos;
    \\}
;

pub const frag_solid =
    \\precision mediump float;
    \\varying vec2 v_uv;
    \\uniform vec4 u_color;
    \\void main() {
    \\    gl_FragColor = u_color;
    \\}
;

pub const frag_post =
    \\precision mediump float;
    \\varying vec2 v_uv;
    \\uniform sampler2D u_tex;
    \\uniform float u_zoom;
    \\uniform vec2 u_focus;
    \\uniform mat3 u_matrix;
    \\uniform vec3 u_offset;
    \\uniform float u_aspect;
    \\uniform vec4 u_lens;
    \\uniform vec4 u_ripple[8];
    \\uniform sampler2D u_prev;
    \\uniform float u_motion;
    \\void main() {
    \\    vec2 uv = u_focus + (v_uv - u_focus) / u_zoom;
    \\    float edge = 0.0;
    \\    if (u_lens.z > 0.0) {
    \\        vec2 d = (uv - u_lens.xy) * vec2(u_aspect, 1.0);
    \\        float dist = length(d);
    \\        if (dist < u_lens.z) {
    \\            uv = u_lens.xy + (uv - u_lens.xy) / u_lens.w;
    \\            edge = smoothstep(u_lens.z - 0.012, u_lens.z, dist);
    \\        }
    \\    }
    \\    for (int i = 0; i < 8; i++) {
    \\        vec4 r = u_ripple[i];
    \\        if (r.w > 0.0) {
    \\            vec2 d = (uv - r.xy) * vec2(u_aspect, 1.0);
    \\            float dist = length(d);
    \\            float k = (dist - r.z) / 0.035;
    \\            float wave = exp(-k * k) * sin(k * 3.0) * r.w;
    \\            uv += normalize(d + vec2(0.0001)) * wave * vec2(1.0 / u_aspect, 1.0) * 0.03;
    \\        }
    \\    }
    \\    vec3 rgb = texture2D(u_tex, uv).rgb;
    \\    rgb = clamp(u_matrix * rgb + u_offset, 0.0, 1.0);
    \\    if (u_motion > 0.0) rgb = mix(rgb, texture2D(u_prev, v_uv).rgb, u_motion);
    \\    gl_FragColor = vec4(mix(rgb, vec3(0.1), edge * 0.8), 1.0);
    \\}
;

pub const frag_blur =
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


/// What dkde-wm asks of the compositing manager (src/xcomp), which it cannot do itself: it sends the root window a
/// `_DKDE_COMP_ACTION` ClientMessage (substructure-notify mask) whose first 32-bit word is one of these.
pub const request_message = "_DKDE_COMP_ACTION";

pub const Request = enum(u32) { zoom_in = 1, zoom_out, zoom_reset, next_filter, show_pointer, lens, _ };
