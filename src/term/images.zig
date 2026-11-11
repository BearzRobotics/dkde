//! Pictures in the terminal: the Kitty graphics protocol, which `kitten
//! icat`, chafa, timg, yazi, ranger and others use to show images. The
//! protocol itself (receiving, storing and placing images) is libghostty-vt's;
//! this draws the placements it reports, and gives it a PNG decoder (GDK's),
//! since programs mostly send PNG.

const std = @import("std");
const cairo = @import("cairo1");
const gdkpixbuf = @import("gdkpixbuf2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const vt = @import("ghostty-vt");

/// Lets libghostty-vt accept PNG images (it has no decoder of its own here).
pub fn installPngDecoder() void {
    if (vt.sys.decode_png == null) vt.sys.decode_png = &decodePng;
}

fn decodePng(gpa: std.mem.Allocator, data: []const u8) vt.sys.DecodeError!vt.sys.Image {
    const loader = gdkpixbuf.PixbufLoader.newWithType("png", null) orelse return error.InvalidData;
    defer loader.as(gobject.Object).unref();
    var err: ?*glib.Error = null;
    if (loader.write(@constCast(data.ptr), data.len, &err) == 0) {
        if (err) |e| e.free();
        _ = loader.close(null);
        return error.InvalidData;
    }
    if (loader.close(&err) == 0) {
        if (err) |e| e.free();
        return error.InvalidData;
    }
    const pix = loader.getPixbuf() orelse return error.InvalidData;
    const w: u32 = @intCast(@max(0, pix.getWidth()));
    const h: u32 = @intCast(@max(0, pix.getHeight()));
    if (w == 0 or h == 0 or @as(u64, w) * h > 64 * 1000 * 1000) return error.InvalidData;
    const stride: usize = @intCast(pix.getRowstride());
    const channels: usize = @intCast(pix.getNChannels());
    const src: [*]const u8 = @ptrCast(pix.readPixels());
    const out = try gpa.alloc(u8, @as(usize, w) * h * 4);
    for (0..h) |y| {
        for (0..w) |x| {
            const s = src[y * stride + x * channels ..];
            const d = out[(y * w + x) * 4 ..];
            d[0] = s[0];
            d[1] = s[1];
            d[2] = s[2];
            d[3] = if (channels == 4) s[3] else 255;
        }
    }
    return .{ .width = w, .height = h, .data = out };
}

/// One image ready to draw, kept until its pixels change.
const Entry = struct { generation: u64, surface: *cairo.Surface };

pub const Cache = struct {
    map: std.AutoHashMapUnmanaged(u32, Entry) = .empty,
    /// The placements of the last update, in drawing order.
    placements: std.ArrayList(vt.RenderState.ImagePlacement) = .empty,

    pub fn deinit(self: *Cache, gpa: std.mem.Allocator) void {
        var it = self.map.valueIterator();
        while (it.next()) |e| e.surface.destroy();
        self.map.deinit(gpa);
        self.placements.deinit(gpa);
    }

    /// Takes the placements from the render state just updated.
    pub fn collect(self: *Cache, gpa: std.mem.Allocator, render: *const vt.RenderState) void {
        self.placements.clearRetainingCapacity();
        var it = render.imagePlacementIterator();
        while (it.next()) |p| self.placements.append(gpa, p) catch break;
        std.mem.sort(vt.RenderState.ImagePlacement, self.placements.items, {}, struct {
            fn less(_: void, a: vt.RenderState.ImagePlacement, b: vt.RenderState.ImagePlacement) bool {
                if (a.layer != b.layer) return @intFromEnum(a.layer) < @intFromEnum(b.layer);
                return a.z < b.z;
            }
        }.less);
    }

    pub fn empty(self: *const Cache) bool {
        return self.placements.items.len == 0;
    }

    /// Draws every placement; `left`/`top` is the grid's corner, `cell_w`
    /// and `cell_h` a cell's size.
    pub fn draw(self: *Cache, gpa: std.mem.Allocator, cr: *cairo.Context, term: *vt.Terminal, left: f64, top: f64, cell_w: f64, cell_h: f64) void {
        for (self.placements.items) |p| {
            const id = switch (p.protocol) {
                .kitty => p.image_id,
            };
            const surface = self.surfaceFor(gpa, term, id, p.image_generation) orelse continue;
            if (p.source_width == 0 or p.source_height == 0 or p.width == 0 or p.height == 0) continue;
            const x = left + @as(f64, @floatFromInt(p.x)) * cell_w + @as(f64, @floatFromInt(p.offset_x));
            const y = top + @as(f64, @floatFromInt(p.y)) * cell_h + @as(f64, @floatFromInt(p.offset_y));
            const sx = @as(f64, @floatFromInt(p.width)) / @as(f64, @floatFromInt(p.source_width));
            const sy = @as(f64, @floatFromInt(p.height)) / @as(f64, @floatFromInt(p.source_height));
            cr.save();
            cr.rectangle(x, y, @floatFromInt(p.width), @floatFromInt(p.height));
            cr.clip();
            cr.translate(x, y);
            cr.scale(sx, sy);
            cr.setSourceSurface(surface, -@as(f64, @floatFromInt(p.source_x)), -@as(f64, @floatFromInt(p.source_y)));
            cr.paint();
            cr.restore();
        }
        self.forgetGone(term);
    }

    fn surfaceFor(self: *Cache, gpa: std.mem.Allocator, term: *vt.Terminal, id: u32, generation: u64) ?*cairo.Surface {
        if (self.map.get(id)) |e| {
            if (e.generation == generation) return e.surface;
            e.surface.destroy();
            _ = self.map.remove(id);
        }
        const image = term.screens.active.kitty_images.imageById(id) orelse return null;
        const bytes = image.renderData().bytes() orelse return null;
        const surface = toSurface(image.width, image.height, image.format, bytes) orelse return null;
        self.map.put(gpa, id, .{ .generation = generation, .surface = surface }) catch {
            surface.destroy();
            return null;
        };
        return surface;
    }

    /// Drops the surfaces of images the program deleted.
    fn forgetGone(self: *Cache, term: *vt.Terminal) void {
        var gone: [16]u32 = undefined;
        var n: usize = 0;
        var it = self.map.iterator();
        while (it.next()) |e| {
            if (term.screens.active.kitty_images.imageById(e.key_ptr.*) == null and n < gone.len) {
                gone[n] = e.key_ptr.*;
                n += 1;
            }
        }
        for (gone[0..n]) |id| if (self.map.fetchRemove(id)) |kv| kv.value.surface.destroy();
    }
};

/// The image's pixels as a cairo surface (premultiplied ARGB, native order).
fn toSurface(w: u32, h: u32, format: anytype, bytes: []const u8) ?*cairo.Surface {
    if (w == 0 or h == 0 or w > 16384 or h > 16384) return null;
    const bpp: usize = switch (format) {
        .rgb => 3,
        .rgba => 4,
        .gray => 1,
        .gray_alpha => 2,
        .png => return null, // decoded on arrival; never stored as PNG
    };
    const count = @as(usize, w) * h;
    if (bytes.len < count * bpp) return null;
    const surface = cairo.Surface.imageCreate(.argb32, @intCast(w), @intCast(h));
    surface.flush();
    const stride: usize = @intCast(surface.imageGetStride());
    const data = surface.imageGetData() orelse {
        surface.destroy();
        return null;
    };
    for (0..h) |y| {
        const row: [*]u32 = @ptrCast(@alignCast(data + y * stride));
        for (0..w) |x| {
            const s = bytes[(y * w + x) * bpp ..];
            var r: u32 = 0;
            var g: u32 = 0;
            var b: u32 = 0;
            var a: u32 = 255;
            switch (bpp) {
                3, 4 => {
                    r = s[0];
                    g = s[1];
                    b = s[2];
                    if (bpp == 4) a = s[3];
                },
                1, 2 => {
                    r = s[0];
                    g = s[0];
                    b = s[0];
                    if (bpp == 2) a = s[1];
                },
                else => {},
            }
            // Premultiplied, as cairo wants.
            r = r * a / 255;
            g = g * a / 255;
            b = b * a / 255;
            row[x] = (a << 24) | (r << 16) | (g << 8) | b;
        }
    }
    surface.markDirty();
    return surface;
}
