//! JPEG 2000 (JPXDecode) and JBIG2 (JBIG2Decode) images through the system's
//! OpenJPEG and jbig2dec, the libraries poppler uses for the same images.
//!
//! Both are optional. They are loaded with dlopen the first time an image
//! needs them, so dkde builds and runs without them (and without their
//! headers): such images are then drawn as a pale box, as before. In a sample
//! of 420 PDFs from a real collection, 35% had JPEG 2000 images and 14% JBIG2,
//! most of them scanned books, where the image is the whole page.

const std = @import("std");

pub const Error = error{ Unavailable, Failed, TooBig, OutOfMemory };

/// Larger images are refused (a malformed header could ask for anything).
const max_pixels: u64 = 128 * 1000 * 1000;

// ---- loading ---------------------------------------------------------------

extern fn dlopen(name: [*:0]const u8, flags: c_int) ?*anyopaque;
extern fn dlsym(handle: *anyopaque, name: [*:0]const u8) ?*anyopaque;
const RTLD_NOW: c_int = 2;

fn openFirst(names: []const [*:0]const u8) ?*anyopaque {
    for (names) |n| if (dlopen(n, RTLD_NOW)) |h| return h;
    return null;
}

/// Fills every function pointer field of `T` from `handle`; false if one is missing.
fn bind(comptime T: type, handle: *anyopaque, out: *T) bool {
    inline for (@typeInfo(T).@"struct".field_names) |name| {
        const sym = dlsym(handle, name) orelse return false;
        @field(out, name) = @ptrCast(@alignCast(sym));
    }
    return true;
}

/// Guards the one-time loading (the renderer may draw pages on several threads).
var load_lock: std.atomic.Mutex = .unlocked;

fn lock() void {
    while (!load_lock.tryLock()) std.atomic.spinLoopHint();
}

// ---- JPEG 2000 -------------------------------------------------------------

const opj_bool = c_int;
const OpjStream = opaque {};
const OpjCodec = opaque {};

/// OpenJPEG 2.x `opj_image_comp_t`.
const OpjComp = extern struct {
    dx: u32,
    dy: u32,
    w: u32,
    h: u32,
    x0: u32,
    y0: u32,
    prec: u32,
    bpp: u32,
    sgnd: u32,
    resno_decoded: u32,
    factor: u32,
    data: ?[*]i32,
    alpha: u16,
};

/// OpenJPEG 2.x `opj_image_t`.
const OpjImage = extern struct {
    x0: u32,
    y0: u32,
    x1: u32,
    y1: u32,
    numcomps: u32,
    color_space: c_int,
    comps: ?[*]OpjComp,
    icc_profile_buf: ?[*]u8,
    icc_profile_len: u32,
};

const OPJ_CLRSPC_SRGB = 1;
const OPJ_CLRSPC_GRAY = 2;
const OPJ_CLRSPC_SYCC = 3;
const OPJ_CLRSPC_EYCC = 4;
const OPJ_CLRSPC_CMYK = 5;

const MsgFn = *const fn ([*:0]const u8, ?*anyopaque) callconv(.c) void;

const Opj = struct {
    opj_stream_default_create: *const fn (opj_bool) callconv(.c) ?*OpjStream,
    opj_stream_set_read_function: *const fn (*OpjStream, *const fn (?*anyopaque, usize, ?*anyopaque) callconv(.c) usize) callconv(.c) void,
    opj_stream_set_skip_function: *const fn (*OpjStream, *const fn (i64, ?*anyopaque) callconv(.c) i64) callconv(.c) void,
    opj_stream_set_seek_function: *const fn (*OpjStream, *const fn (i64, ?*anyopaque) callconv(.c) opj_bool) callconv(.c) void,
    opj_stream_set_user_data: *const fn (*OpjStream, ?*anyopaque, ?*const fn (?*anyopaque) callconv(.c) void) callconv(.c) void,
    opj_stream_set_user_data_length: *const fn (*OpjStream, u64) callconv(.c) void,
    opj_stream_destroy: *const fn (*OpjStream) callconv(.c) void,
    opj_create_decompress: *const fn (c_int) callconv(.c) ?*OpjCodec,
    opj_set_default_decoder_parameters: *const fn (*anyopaque) callconv(.c) void,
    opj_setup_decoder: *const fn (*OpjCodec, *anyopaque) callconv(.c) opj_bool,
    opj_set_error_handler: *const fn (*OpjCodec, ?MsgFn, ?*anyopaque) callconv(.c) opj_bool,
    opj_set_warning_handler: *const fn (*OpjCodec, ?MsgFn, ?*anyopaque) callconv(.c) opj_bool,
    opj_set_info_handler: *const fn (*OpjCodec, ?MsgFn, ?*anyopaque) callconv(.c) opj_bool,
    opj_read_header: *const fn (*OpjStream, *OpjCodec, *?*OpjImage) callconv(.c) opj_bool,
    opj_decode: *const fn (*OpjCodec, *OpjStream, *OpjImage) callconv(.c) opj_bool,
    opj_end_decompress: *const fn (*OpjCodec, *OpjStream) callconv(.c) opj_bool,
    opj_destroy_codec: *const fn (*OpjCodec) callconv(.c) void,
    opj_image_destroy: *const fn (*OpjImage) callconv(.c) void,
};

var opj: ?Opj = null;
var opj_tried = false;

fn loadOpj() ?*const Opj {
    lock();
    defer load_lock.unlock();
    if (!opj_tried) {
        opj_tried = true;
        if (openFirst(&.{ "libopenjp2.so.7", "libopenjp2.so" })) |h| {
            var fns: Opj = undefined;
            if (bind(Opj, h, &fns)) opj = fns;
        }
    }
    return if (opj) |*o| o else null;
}

/// A decoded JPEG 2000 image: 8-bit samples, `channels` per pixel, rows
/// packed, top row first. `alpha` says the last channel is opacity.
pub const Jpx = struct {
    width: u32,
    height: u32,
    channels: u8,
    alpha: bool,
    space: Space,
    samples: []u8,

    pub const Space = enum { gray, rgb, cmyk, other };
};

const MemReader = struct {
    data: []const u8,
    pos: usize = 0,

    fn read(buf: ?*anyopaque, n: usize, user: ?*anyopaque) callconv(.c) usize {
        const self: *MemReader = @ptrCast(@alignCast(user.?));
        if (self.pos >= self.data.len) return std.math.maxInt(usize); // (size_t)-1: end of stream
        const k = @min(n, self.data.len - self.pos);
        const dst: [*]u8 = @ptrCast(buf.?);
        @memcpy(dst[0..k], self.data[self.pos..][0..k]);
        self.pos += k;
        return k;
    }

    fn skip(n: i64, user: ?*anyopaque) callconv(.c) i64 {
        const self: *MemReader = @ptrCast(@alignCast(user.?));
        if (n < 0) {
            const back: usize = @intCast(@min(-n, @as(i64, @intCast(self.pos))));
            self.pos -= back;
            return -@as(i64, @intCast(back));
        }
        const k: usize = @intCast(@min(n, @as(i64, @intCast(self.data.len - @min(self.pos, self.data.len)))));
        self.pos += k;
        return @intCast(k);
    }

    fn seek(n: i64, user: ?*anyopaque) callconv(.c) opj_bool {
        const self: *MemReader = @ptrCast(@alignCast(user.?));
        if (n < 0 or n > self.data.len) return 0;
        self.pos = @intCast(n);
        return 1;
    }
};

fn quiet(_: [*:0]const u8, _: ?*anyopaque) callconv(.c) void {}

/// Decodes a JPEG 2000 codestream or JP2 file.
///
/// `raw` keeps the sample values as they are (clamped to 0..255), for an
/// /Indexed colour space whose samples are palette indices; otherwise samples
/// are scaled to 8 bits. `max_side` lets OpenJPEG decode at a lower
/// resolution when the image is far larger than it will be shown (0: full).
pub fn decodeJpx(a: std.mem.Allocator, data: []const u8, raw: bool, max_side: u32) Error!Jpx {
    // A page shown far smaller than the scan: decode a lower resolution level
    // (each level halves both sides), which is much faster. The factor must be
    // known before OpenJPEG reads the header, so the size comes from the
    // codestream's SIZ marker; a file with fewer levels is decoded in full.
    var factor: u32 = 0;
    if (max_side > 0) if (codestreamSize(data)) |size| {
        const full = @max(size[0], size[1]);
        while (factor < 5 and (full >> @intCast(factor + 1)) >= max_side) factor += 1;
    };
    if (factor > 0) {
        if (decodeJpxAt(a, data, raw, factor)) |j| return j else |e| if (e == error.Unavailable or e == error.OutOfMemory) return e;
    }
    return decodeJpxAt(a, data, raw, 0);
}

/// Width and height from the codestream's SIZ marker (it follows SOC, FF4F,
/// at the start of a bare codestream or of a JP2 file's jp2c box).
fn codestreamSize(data: []const u8) ?[2]u32 {
    const at = std.mem.indexOf(u8, data, "\xff\x4f\xff\x51") orelse return null;
    const siz = data[at + 4 ..];
    // Lsiz(2) Rsiz(2) Xsiz(4) Ysiz(4) XOsiz(4) YOsiz(4)
    if (siz.len < 20) return null;
    const x = std.mem.readInt(u32, siz[4..8], .big);
    const y = std.mem.readInt(u32, siz[8..12], .big);
    const xo = std.mem.readInt(u32, siz[12..16], .big);
    const yo = std.mem.readInt(u32, siz[16..20], .big);
    if (x <= xo or y <= yo) return null;
    return .{ x - xo, y - yo };
}

fn decodeJpxAt(a: std.mem.Allocator, data: []const u8, raw: bool, factor: u32) Error!Jpx {
    const o = loadOpj() orelse return error.Unavailable;
    // JP2 files start with a signature box; a bare codestream with SOC + SIZ.
    const is_jp2 = data.len >= 12 and std.mem.eql(u8, data[4..12], "jP  \r\n\x87\n");
    const codec = o.opj_create_decompress(if (is_jp2) 2 else 0) orelse return error.Failed;
    defer o.opj_destroy_codec(codec);
    _ = o.opj_set_error_handler(codec, quiet, null);
    _ = o.opj_set_warning_handler(codec, quiet, null);
    _ = o.opj_set_info_handler(codec, quiet, null);

    // opj_dparameters_t is about 8.3 KB; it is only handed back to the library.
    var params: [16384]u8 align(16) = undefined;
    o.opj_set_default_decoder_parameters(&params);
    // cp_reduce, the struct's first field: resolution levels to drop.
    @as(*u32, @ptrCast(&params)).* = factor;
    if (o.opj_setup_decoder(codec, &params) == 0) return error.Failed;

    var reader: MemReader = .{ .data = data };
    const stream = o.opj_stream_default_create(1) orelse return error.Failed;
    defer o.opj_stream_destroy(stream);
    o.opj_stream_set_read_function(stream, MemReader.read);
    o.opj_stream_set_skip_function(stream, MemReader.skip);
    o.opj_stream_set_seek_function(stream, MemReader.seek);
    o.opj_stream_set_user_data(stream, &reader, null);
    o.opj_stream_set_user_data_length(stream, data.len);

    var image_opt: ?*OpjImage = null;
    if (o.opj_read_header(stream, codec, &image_opt) == 0) {
        if (image_opt) |im| o.opj_image_destroy(im);
        return error.Failed;
    }
    const image = image_opt orelse return error.Failed;
    defer o.opj_image_destroy(image);

    if (o.opj_decode(codec, stream, image) == 0) return error.Failed;
    _ = o.opj_end_decompress(codec, stream);

    const n = image.numcomps;
    const comps = image.comps orelse return error.Failed;
    if (n == 0) return error.Failed;
    for (comps[0..n]) |c| if (c.data == null) return error.Failed;
    const w = comps[0].w;
    const h = comps[0].h;
    if (w == 0 or h == 0) return error.Failed;
    if (@as(u64, w) * h > max_pixels) return error.TooBig;

    // Which components are colour, and is there an alpha channel?
    var colour: u32 = switch (image.color_space) {
        OPJ_CLRSPC_GRAY => 1,
        OPJ_CLRSPC_SRGB, OPJ_CLRSPC_SYCC, OPJ_CLRSPC_EYCC => 3,
        OPJ_CLRSPC_CMYK => 4,
        else => if (n >= 3) 3 else 1,
    };
    colour = @min(colour, n);
    const has_alpha = n > colour and comps[colour].alpha != 0;
    const channels: u32 = colour + @intFromBool(has_alpha);
    const space: Jpx.Space = switch (colour) {
        1 => .gray,
        3 => .rgb,
        4 => .cmyk,
        else => .other,
    };

    const out = try a.alloc(u8, @as(usize, w) * h * channels);
    for (0..channels) |ci| {
        const c = comps[ci];
        // Subsampled components (4:2:0 chroma) are stretched to the full size.
        const sx = @max(1, c.dx / @max(1, comps[0].dx));
        const sy = @max(1, c.dy / @max(1, comps[0].dy));
        const shift: i32 = @as(i32, @intCast(c.prec)) - 8;
        const offset: i32 = if (c.sgnd != 0 and c.prec > 0) @as(i32, 1) << @intCast(c.prec - 1) else 0;
        const src = c.data.?;
        for (0..h) |y| {
            const cy = @min(y / sy, @as(usize, c.h) -| 1);
            for (0..w) |x| {
                const cx = @min(x / sx, @as(usize, c.w) -| 1);
                var v = src[cy * c.w + cx] + offset;
                if (!raw) {
                    if (shift > 0) v >>= @intCast(shift) else if (shift < 0) v <<= @intCast(-shift);
                }
                out[(y * w + x) * channels + ci] = @intCast(std.math.clamp(v, 0, 255));
            }
        }
    }

    // YCbCr to RGB (JPEG 2000 files from scanners often store sYCC).
    if (!raw and colour == 3 and (image.color_space == OPJ_CLRSPC_SYCC or image.color_space == OPJ_CLRSPC_EYCC)) {
        var i: usize = 0;
        while (i < out.len) : (i += channels) {
            const yy: f32 = @floatFromInt(out[i]);
            const cb: f32 = @as(f32, @floatFromInt(out[i + 1])) - 128;
            const cr: f32 = @as(f32, @floatFromInt(out[i + 2])) - 128;
            out[i] = clamp8(yy + 1.402 * cr);
            out[i + 1] = clamp8(yy - 0.344136 * cb - 0.714136 * cr);
            out[i + 2] = clamp8(yy + 1.772 * cb);
        }
    }
    return .{ .width = w, .height = h, .channels = @intCast(channels), .alpha = has_alpha, .space = space, .samples = out };
}

fn clamp8(v: f32) u8 {
    return @intFromFloat(std.math.clamp(v + 0.5, 0, 255));
}

// ---- JBIG2 -------------------------------------------------------------------

const J2Ctx = opaque {};
const J2Global = opaque {};
const J2Image = extern struct {
    width: u32,
    height: u32,
    stride: u32,
    data: ?[*]u8,
    refcount: c_int,
};
const J2ErrFn = *const fn (?*anyopaque, ?[*:0]const u8, c_int, u32) callconv(.c) void;

const Jbig2 = struct {
    jbig2_ctx_new_imp: *const fn (?*anyopaque, c_int, ?*J2Global, ?J2ErrFn, ?*anyopaque, c_int, c_int) callconv(.c) ?*J2Ctx,
    jbig2_data_in: *const fn (*J2Ctx, [*]const u8, usize) callconv(.c) c_int,
    jbig2_make_global_ctx: *const fn (*J2Ctx) callconv(.c) ?*J2Global,
    jbig2_global_ctx_free: *const fn (*J2Global) callconv(.c) ?*anyopaque,
    jbig2_ctx_free: *const fn (*J2Ctx) callconv(.c) ?*anyopaque,
    jbig2_complete_page: *const fn (*J2Ctx) callconv(.c) c_int,
    jbig2_page_out: *const fn (*J2Ctx) callconv(.c) ?*J2Image,
    jbig2_release_page: *const fn (*J2Ctx, *J2Image) callconv(.c) void,
};

var jb: ?Jbig2 = null;
var jb_tried = false;
/// jbig2dec refuses a context unless the caller names its exact version; the
/// header is not available here, so the version is found by trying.
var jb_minor: c_int = -1;

fn quietJbig2(_: ?*anyopaque, _: ?[*:0]const u8, _: c_int, _: u32) callconv(.c) void {}

fn loadJbig2() ?*const Jbig2 {
    lock();
    defer load_lock.unlock();
    if (!jb_tried) {
        jb_tried = true;
        if (openFirst(&.{ "libjbig2dec.so.0", "libjbig2dec.so" })) |h| {
            var fns: Jbig2 = undefined;
            if (bind(Jbig2, h, &fns)) {
                var minor: c_int = 30;
                while (minor >= 10) : (minor -= 1) {
                    if (fns.jbig2_ctx_new_imp(null, 1, null, quietJbig2, null, 0, minor)) |ctx| {
                        _ = fns.jbig2_ctx_free(ctx);
                        jb_minor = minor;
                        jb = fns;
                        break;
                    }
                }
            }
        }
    }
    return if (jb) |*j| j else null;
}

/// A decoded JBIG2 page: 1 bit per pixel, 1 = black, rows `stride` bytes.
pub const Bitmap = struct {
    width: u32,
    height: u32,
    stride: u32,
    bits: []u8,
};

/// Decodes embedded JBIG2 data (the PDF form: no file header), with the
/// stream's /JBIG2Globals data when it has one.
pub fn decodeJbig2(a: std.mem.Allocator, data: []const u8, globals: ?[]const u8) Error!Bitmap {
    const j = loadJbig2() orelse return error.Unavailable;
    var global: ?*J2Global = null;
    if (globals) |g| {
        const gctx = j.jbig2_ctx_new_imp(null, 1, null, quietJbig2, null, 0, jb_minor) orelse return error.Failed;
        _ = j.jbig2_data_in(gctx, g.ptr, g.len);
        global = j.jbig2_make_global_ctx(gctx);
    }
    defer if (global) |g| {
        _ = j.jbig2_global_ctx_free(g);
    };
    const ctx = j.jbig2_ctx_new_imp(null, 1, global, quietJbig2, null, 0, jb_minor) orelse return error.Failed;
    defer _ = j.jbig2_ctx_free(ctx);
    _ = j.jbig2_data_in(ctx, data.ptr, data.len);
    _ = j.jbig2_complete_page(ctx);
    const page = j.jbig2_page_out(ctx) orelse return error.Failed;
    defer j.jbig2_release_page(ctx, page);
    const bits = page.data orelse return error.Failed;
    if (page.width == 0 or page.height == 0) return error.Failed;
    if (@as(u64, page.width) * page.height > max_pixels) return error.TooBig;
    const len = @as(usize, page.stride) * page.height;
    return .{ .width = page.width, .height = page.height, .stride = page.stride, .bits = try a.dupe(u8, bits[0..len]) };
}
