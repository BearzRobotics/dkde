//! Reading pictures off the main thread, so a 50-megapixel photo or a slow
//! network folder never freezes the window: one worker thread decodes the
//! picture to show first, then the neighbours (so the next one appears at
//! once) and the gallery's thumbnails. The window collects what is ready
//! with `poll`.
//!
//! Pictures are decoded in Zig (imgcodec) where it can, and by gdk-pixbuf
//! otherwise (WebP, SVG, HEIF, AVIF, JPEG XL, and animations).

const std = @import("std");
const cairo = @import("cairo1");
const gdkpixbuf = @import("gdkpixbuf2");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const imgcodec = @import("imgcodec");

const exif = @import("exif.zig");
const pure = @import("pure.zig");

const c_alloc = std.heap.c_allocator;

/// A picture ready to show. Owned by whoever holds it; `destroy` frees it.
pub const Picture = struct {
    uri: [:0]u8,
    /// The file as read (for its EXIF data and for lossless saving).
    bytes: []u8,
    /// The upright pixels (8-bit RGBA, straight alpha) of a still picture.
    pixels: ?imgcodec.Decoded = null,
    /// A moving picture (GIF, WebP); its frames are drawn as it plays.
    animation: ?*gdkpixbuf.PixbufAnimation = null,
    /// What is drawn: the pixels, or the animation's current frame.
    surface: *cairo.Surface,
    width: u32,
    height: u32,
    format: [16:0]u8 = @splat(0),
    /// The EXIF orientation the file was shown with (already applied to `pixels`).
    orientation: u8 = 1,
    /// SVG: drawn again, sharp, at the zoom it is shown at.
    vector: bool = false,
    has_alpha: bool = false,

    pub fn destroy(self: *Picture) void {
        c_alloc.free(self.uri);
        c_alloc.free(self.bytes);
        if (self.pixels) |p| p.deinit(c_alloc);
        if (self.animation) |a| a.as(gobject.Object).unref();
        self.surface.destroy();
        c_alloc.destroy(self);
    }

    pub fn formatName(self: *const Picture) []const u8 {
        return std.mem.sliceTo(&self.format, 0);
    }

    fn setFormat(self: *Picture, name: []const u8) void {
        const n = @min(name.len, self.format.len);
        @memcpy(self.format[0..n], name[0..n]);
        self.format[n] = 0;
    }

    /// Replaces the pixels (after an edit) and what is drawn.
    pub fn setPixels(self: *Picture, d: imgcodec.Decoded) !void {
        const s = try surfaceFromRgba(d);
        if (self.pixels) |p| p.deinit(c_alloc);
        self.surface.destroy();
        self.pixels = d;
        self.surface = s;
        self.width = @intCast(d.width);
        self.height = @intCast(d.height);
    }
};

pub const Kind = enum { show, preload, thumb, quit };

const Job = struct {
    kind: Kind,
    uri: [:0]u8,
    generation: u64,
};

pub const Result = struct {
    kind: Kind,
    uri: [:0]u8,
    generation: u64,
    picture: ?*Picture = null,
    thumb: ?*gdkpixbuf.Pixbuf = null,
    /// Why the picture could not be shown.
    message: ?[:0]u8 = null,

    pub fn destroy(self: *Result) void {
        c_alloc.free(self.uri);
        if (self.picture) |p| p.destroy();
        if (self.thumb) |t| t.as(gobject.Object).unref();
        if (self.message) |m| c_alloc.free(m);
        c_alloc.destroy(self);
    }
};

pub const Loader = struct {
    jobs: *glib.AsyncQueue,
    done: *glib.AsyncQueue,
    thread: ?std.Thread = null,

    pub fn start(self: *Loader) void {
        self.* = .{ .jobs = glib.AsyncQueue.new(), .done = glib.AsyncQueue.new() };
        self.thread = std.Thread.spawn(.{}, work, .{self}) catch null;
    }

    /// Stops the worker (after the picture it is reading) and drops what
    /// was not collected.
    pub fn stop(self: *Loader) void {
        self.ask(.quit, "", 0, true);
        if (self.thread) |t| t.join();
        while (self.jobs.tryPop()) |j| freeJob(@ptrCast(@alignCast(j)));
        while (self.done.tryPop()) |r| @as(*Result, @ptrCast(@alignCast(r))).destroy();
        self.jobs.unref();
        self.done.unref();
    }

    /// Queues work; `urgent` work goes before everything waiting.
    pub fn ask(self: *Loader, kind: Kind, uri: []const u8, generation: u64, urgent: bool) void {
        const job = c_alloc.create(Job) catch return;
        job.* = .{ .kind = kind, .uri = c_alloc.dupeSentinel(u8, uri, 0) catch {
            c_alloc.destroy(job);
            return;
        }, .generation = generation };
        if (self.thread == null and kind != .quit) {
            // No thread could be started: do it here.
            if (run(job)) |r| self.done.push(r);
            freeJob(job);
            return;
        }
        if (urgent) self.jobs.pushFront(job) else self.jobs.push(job);
    }

    /// Drops queued work of `kind` (when the user has moved on).
    pub fn forget(self: *Loader, kind: Kind) void {
        var keep: std.ArrayList(*Job) = .empty;
        defer keep.deinit(c_alloc);
        while (self.jobs.tryPop()) |raw| {
            const j: *Job = @ptrCast(@alignCast(raw));
            if (j.kind == kind) freeJob(j) else keep.append(c_alloc, j) catch freeJob(j);
        }
        for (keep.items) |j| self.jobs.push(j);
    }

    /// One finished piece of work, if any.
    pub fn poll(self: *Loader) ?*Result {
        const r = self.done.tryPop() orelse return null;
        return @ptrCast(@alignCast(r));
    }

    fn work(self: *Loader) void {
        while (true) {
            const job: *Job = @ptrCast(@alignCast(self.jobs.pop()));
            if (job.kind == .quit) {
                freeJob(job);
                return;
            }
            if (run(job)) |r| self.done.push(r);
            freeJob(job);
        }
    }
};

fn freeJob(job: *Job) void {
    c_alloc.free(job.uri);
    c_alloc.destroy(job);
}

fn run(job: *Job) ?*Result {
    const r = c_alloc.create(Result) catch return null;
    r.* = .{ .kind = job.kind, .uri = c_alloc.dupeSentinel(u8, job.uri, 0) catch {
        c_alloc.destroy(r);
        return null;
    }, .generation = job.generation };
    switch (job.kind) {
        .show, .preload => {
            if (load(job.uri)) |p| r.picture = p else |err| r.message = switch (err) {
                error.Read => c_alloc.dupeSentinel(u8, "The file cannot be read.", 0) catch null,
                error.TooBig => c_alloc.dupeSentinel(u8, "The picture is too large to show.", 0) catch null,
                else => c_alloc.dupeSentinel(u8, "This is not a picture the viewer can read, or the file is damaged.", 0) catch null,
            };
        },
        .thumb => r.thumb = thumbnail(job.uri),
        .quit => {},
    }
    return r;
}

// ---- decoding ---------------------------------------------------------------------

pub const LoadError = error{ Read, Unsupported, TooBig, OutOfMemory };

pub fn load(uri: [:0]const u8) LoadError!*Picture {
    const file = gio.File.newForUri(uri);
    defer file.as(gobject.Object).unref();
    var contents: [*]u8 = undefined;
    var len: usize = 0;
    if (file.loadContents(null, &contents, &len, null, null) == 0) return error.Read;
    defer glib.free(contents);
    const bytes = try c_alloc.dupe(u8, contents[0..len]);
    errdefer c_alloc.free(bytes);
    return fromBytes(uri, bytes);
}

/// Makes a picture of `bytes` (which it then owns).
pub fn fromBytes(uri: [:0]const u8, bytes: []u8) LoadError!*Picture {
    const orientation: u8 = if (exif.find(bytes)) |block| exif.parse(block).orientation else 1;
    const kind = pure.formatName(bytes);
    // GIF and WebP may move; gdk-pixbuf plays them.
    const zig_first = !(std.mem.eql(u8, kind, "GIF") or std.mem.eql(u8, kind, "WebP") or std.mem.eql(u8, kind, "Image"));
    if (zig_first) {
        if (imgcodec.decode(c_alloc, bytes)) |raw| {
            var d = raw;
            d = imgcodec.orient(c_alloc, d, orientation) catch |e| {
                d.deinit(c_alloc);
                return e;
            };
            errdefer d.deinit(c_alloc);
            const p = try newPicture(uri, bytes, d);
            p.setFormat(kind);
            p.orientation = orientation;
            return p;
        } else |e| if (e == error.OutOfMemory) return error.OutOfMemory else if (e == error.TooBig) return error.TooBig;
    }
    return fromPixbuf(uri, bytes, orientation);
}

fn newPicture(uri: [:0]const u8, bytes: []u8, d: imgcodec.Decoded) LoadError!*Picture {
    const surface = try surfaceFromRgba(d);
    errdefer surface.destroy();
    const p = try c_alloc.create(Picture);
    errdefer c_alloc.destroy(p);
    p.* = .{
        .uri = try c_alloc.dupeSentinel(u8, uri, 0),
        .bytes = bytes,
        .pixels = d,
        .surface = surface,
        .width = @intCast(d.width),
        .height = @intCast(d.height),
        .has_alpha = hasAlpha(d.rgba),
    };
    return p;
}

fn fromPixbuf(uri: [:0]const u8, bytes: []u8, orientation: u8) LoadError!*Picture {
    const loader = gdkpixbuf.PixbufLoader.new();
    defer loader.as(gobject.Object).unref();
    if (loader.write(bytes.ptr, bytes.len, null) == 0) {
        _ = loader.close(null);
        return error.Unsupported;
    }
    if (loader.close(null) == 0) return error.Unsupported;
    const anim = loader.getAnimation() orelse return error.Unsupported;
    var name: []const u8 = "Image";
    var vector = false;
    if (loader.getFormat()) |fmt| {
        if (fmt.getName()) |n| name = std.mem.span(n);
        vector = std.mem.eql(u8, name, "svg");
    }
    var label_buf: [16]u8 = undefined;
    const label = formatLabel(&label_buf, name);

    if (anim.isStaticImage() == 0) {
        // A moving picture: show its first frame; the window plays it.
        const iter = anim.getIter(&.{ .f_tv_sec = 0, .f_tv_usec = 0 });
        defer iter.as(gobject.Object).unref();
        const frame = iter.getPixbuf();
        const surface = try surfaceFromPixbuf(frame);
        errdefer surface.destroy();
        const p = try c_alloc.create(Picture);
        p.* = .{
            .uri = c_alloc.dupeSentinel(u8, uri, 0) catch {
                c_alloc.destroy(p);
                return error.OutOfMemory;
            },
            .bytes = bytes,
            .animation = @ptrCast(anim.as(gobject.Object).ref()),
            .surface = surface,
            .width = @intCast(anim.getWidth()),
            .height = @intCast(anim.getHeight()),
            .has_alpha = frame.getHasAlpha() != 0,
        };
        p.setFormat(label);
        return p;
    }
    const still = anim.getStaticImage();
    // gdk-pixbuf turns pictures upright only when asked.
    const upright = still.applyEmbeddedOrientation() orelse return error.OutOfMemory;
    defer upright.as(gobject.Object).unref();
    const d = try decodedFromPixbuf(upright);
    errdefer d.deinit(c_alloc);
    const p = try newPicture(uri, bytes, d);
    p.setFormat(label);
    p.vector = vector;
    p.orientation = orientation;
    return p;
}

fn formatLabel(buf: []u8, name: []const u8) []const u8 {
    const known = .{ .{ "jpeg", "JPEG" }, .{ "png", "PNG" }, .{ "gif", "GIF" }, .{ "webp", "WebP" }, .{ "svg", "SVG" }, .{ "heif", "HEIF" }, .{ "avif", "AVIF" }, .{ "jxl", "JPEG XL" }, .{ "tiff", "TIFF" }, .{ "ico", "ICO" }, .{ "bmp", "BMP" } };
    inline for (known) |k| if (std.mem.eql(u8, name, k[0])) return k[1];
    const n = @min(buf.len, name.len);
    for (name[0..n], 0..) |c, i| buf[i] = std.ascii.toUpper(c);
    return buf[0..n];
}

/// An SVG drawn at `w`×`h`, for sharp edges at the zoom it is shown at.
pub fn renderVector(bytes: []const u8, w: u32, h: u32) ?*cairo.Surface {
    const loader = gdkpixbuf.PixbufLoader.new();
    defer loader.as(gobject.Object).unref();
    loader.setSize(@intCast(w), @intCast(h));
    if (loader.write(bytes.ptr, bytes.len, null) == 0) {
        _ = loader.close(null);
        return null;
    }
    if (loader.close(null) == 0) return null;
    const pb = loader.getPixbuf() orelse return null;
    return surfaceFromPixbuf(pb) catch null;
}

fn hasAlpha(rgba: []const u8) bool {
    var i: usize = 3;
    while (i < rgba.len) : (i += 4) if (rgba[i] != 255) return true;
    return false;
}

pub fn decodedFromPixbuf(pb: *gdkpixbuf.Pixbuf) LoadError!imgcodec.Decoded {
    const w: usize = @intCast(@max(0, pb.getWidth()));
    const h: usize = @intCast(@max(0, pb.getHeight()));
    if (w == 0 or h == 0) return error.Unsupported;
    if (w * h > imgcodec.max_pixels) return error.TooBig;
    const stride: usize = @intCast(pb.getRowstride());
    const channels: usize = @intCast(pb.getNChannels());
    const src: [*]const u8 = @ptrCast(pb.readPixels());
    const out = try c_alloc.alloc(u8, w * h * 4);
    for (0..h) |y| for (0..w) |x| {
        const s = src[y * stride + x * channels ..];
        const d = out[(y * w + x) * 4 ..];
        d[0] = s[0];
        d[1] = s[1];
        d[2] = s[2];
        d[3] = if (channels == 4) s[3] else 255;
    };
    return .{ .width = w, .height = h, .rgba = out };
}

/// A pixbuf over a copy of the pixels (for saving, scaling, printing).
pub fn pixbufFromDecoded(d: imgcodec.Decoded) ?*gdkpixbuf.Pixbuf {
    const copy = c_alloc.dupe(u8, d.rgba) catch return null;
    return gdkpixbuf.Pixbuf.newFromData(copy.ptr, .rgb, 1, 8, @intCast(d.width), @intCast(d.height), @intCast(d.width * 4), &freePixels, null);
}

fn freePixels(data: [*]u8, _: ?*anyopaque) callconv(.c) void {
    std.c.free(data);
}

/// cairo's largest image side.
const max_side = 32767;

pub fn surfaceFromRgba(d: imgcodec.Decoded) LoadError!*cairo.Surface {
    // A picture beyond cairo's limit is shown at a reduced size (one pixel in `step`).
    const step: usize = @max(1, (@max(d.width, d.height) + max_side - 1) / max_side);
    const w = d.width / step;
    const h = d.height / step;
    if (w == 0 or h == 0) return error.Unsupported;
    const surface = cairo.Surface.imageCreate(.argb32, @intCast(w), @intCast(h));
    if (surface.status() != .success) {
        surface.destroy();
        return error.OutOfMemory;
    }
    surface.flush();
    const stride: usize = @intCast(surface.imageGetStride());
    const data = surface.imageGetData() orelse {
        surface.destroy();
        return error.OutOfMemory;
    };
    for (0..h) |y| {
        const row: [*]u32 = @ptrCast(@alignCast(data + y * stride));
        for (0..w) |x| {
            const s = d.rgba[((y * step) * d.width + x * step) * 4 ..];
            const a: u32 = s[3];
            const r: u32 = (@as(u32, s[0]) * a + 127) / 255;
            const g: u32 = (@as(u32, s[1]) * a + 127) / 255;
            const b: u32 = (@as(u32, s[2]) * a + 127) / 255;
            row[x] = (a << 24) | (r << 16) | (g << 8) | b;
        }
    }
    surface.markDirty();
    return surface;
}

pub fn surfaceFromPixbuf(pb: *gdkpixbuf.Pixbuf) LoadError!*cairo.Surface {
    const w: usize = @intCast(@max(0, pb.getWidth()));
    const h: usize = @intCast(@max(0, pb.getHeight()));
    if (w == 0 or h == 0 or w > max_side or h > max_side) return error.Unsupported;
    const surface = cairo.Surface.imageCreate(.argb32, @intCast(w), @intCast(h));
    if (surface.status() != .success) {
        surface.destroy();
        return error.OutOfMemory;
    }
    surface.flush();
    const stride: usize = @intCast(surface.imageGetStride());
    const data = surface.imageGetData() orelse {
        surface.destroy();
        return error.OutOfMemory;
    };
    const sstride: usize = @intCast(pb.getRowstride());
    const channels: usize = @intCast(pb.getNChannels());
    const src: [*]const u8 = @ptrCast(pb.readPixels());
    for (0..h) |y| {
        const row: [*]u32 = @ptrCast(@alignCast(data + y * stride));
        for (0..w) |x| {
            const s = src[y * sstride + x * channels ..];
            const a: u32 = if (channels == 4) s[3] else 255;
            row[x] = (a << 24) | (((@as(u32, s[0]) * a + 127) / 255) << 16) | (((@as(u32, s[1]) * a + 127) / 255) << 8) | ((@as(u32, s[2]) * a + 127) / 255);
        }
    }
    surface.markDirty();
    return surface;
}

// ---- thumbnails ----------------------------------------------------------------------
//
// The freedesktop.org thumbnail cache (~/.cache/thumbnails/normal), which
// file managers and other viewers share: a 128-pixel PNG named after the
// MD5 of the file's URI, valid while its Thumb::MTime matches the file's.

pub const thumb_size = 128;

fn thumbPath(buf: []u8, uri: [:0]const u8) ?[:0]const u8 {
    const md5 = glib.computeChecksumForString(.md5, uri, -1) orelse return null;
    defer glib.free(md5);
    return std.fmt.bufPrintSentinel(buf, "{s}/thumbnails/normal/{s}.png", .{ std.mem.span(glib.getUserCacheDir()), std.mem.span(md5) }, 0) catch null;
}

fn thumbnail(uri: [:0]const u8) ?*gdkpixbuf.Pixbuf {
    const file = gio.File.newForUri(uri);
    defer file.as(gobject.Object).unref();
    // Only local files: reading a whole remote folder for thumbnails is too slow.
    const path = file.getPath() orelse return null;
    defer glib.free(path);
    const info = file.queryInfo("time::modified", .{}, null, null) orelse return null;
    const mtime = info.getAttributeUint64("time::modified");
    info.as(gobject.Object).unref();
    var mbuf: [24]u8 = undefined;
    const mtext = std.fmt.bufPrintSentinel(&mbuf, "{d}", .{mtime}, 0) catch return null;

    var tbuf: [1024]u8 = undefined;
    const cached = thumbPath(&tbuf, uri);
    if (cached) |c| {
        if (gdkpixbuf.Pixbuf.newFromFile(c, null)) |pb| {
            if (pb.getOption("tEXt::Thumb::MTime")) |m| if (std.mem.eql(u8, std.mem.span(m), mtext)) return pb;
            pb.as(gobject.Object).unref();
        }
    }
    const scaled = gdkpixbuf.Pixbuf.newFromFileAtScale(path, thumb_size, thumb_size, 1, null) orelse return null;
    // A new reference either way (the same pixbuf when already upright).
    defer scaled.as(gobject.Object).unref();
    const upright = scaled.applyEmbeddedOrientation() orelse return null;
    // The cache's own files are not thumbnailed into it.
    const cache_dir = std.mem.span(glib.getUserCacheDir());
    if (cached) |c| if (!std.mem.startsWith(u8, std.mem.span(path), cache_dir)) save(upright, c, uri, mtext);
    return upright;
}

fn save(pb: *gdkpixbuf.Pixbuf, path: [:0]const u8, uri: [:0]const u8, mtime: [:0]const u8) void {
    const dir = std.fs.path.dirname(path) orelse return;
    var dbuf: [1024]u8 = undefined;
    const dirz = std.fmt.bufPrintSentinel(&dbuf, "{s}", .{dir}, 0) catch return;
    _ = glib.mkdirWithParents(dirz, 0o700);
    var tmp_buf: [1100]u8 = undefined;
    const tmp = std.fmt.bufPrintSentinel(&tmp_buf, "{s}.dkde-view.tmp", .{path}, 0) catch return;
    var keys = [_:null]?[*:0]const u8{ "tEXt::Thumb::URI", "tEXt::Thumb::MTime", "tEXt::Software" };
    var values = [_:null]?[*:0]const u8{ uri.ptr, mtime.ptr, "dkde-view" };
    if (pb.savev(tmp, "png", @ptrCast(&keys), @ptrCast(&values), null) == 0) return;
    // Thumbnails are private (they show what is in private folders).
    _ = std.c.chmod(tmp.ptr, 0o600);
    _ = std.c.rename(tmp.ptr, path.ptr);
}
