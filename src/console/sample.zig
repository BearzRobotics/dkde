//! A few lines of sample text drawn with the console's own font code, for the
//! preview on the Settings page (SPEC.md 5.11, *Configuration tools*). It does
//! the same thing the console does for one cell: PSF bits are copied, TrueType
//! coverage is mixed over the background.

const std = @import("std");
const psf = @import("psf.zig");
const ttf = @import("ttf.zig");
const termcore = @import("termcore");

pub const Scheme = termcore.schemes.Scheme;

pub const Preview = struct {
    allocator: std.mem.Allocator,
    psf_font: ?psf.Font = null,
    face: ?ttf.Face = null,
    cell_w: u32,
    cell_h: u32,

    /// `data` is a PSF or TrueType file, or null for the built-in font; it must
    /// outlive the preview. `size` is the cell height (0: 16).
    pub fn init(allocator: std.mem.Allocator, data: ?[]const u8, size: u32) !Preview {
        const h = if (size == 0) 16 else size;
        if (data) |d| {
            if (ttf.looksLikeTrueType(d)) {
                const face = try ttf.Face.init(allocator, d, h);
                return .{ .allocator = allocator, .face = face, .cell_w = face.cell_w, .cell_h = face.cell_h };
            }
            const f = try psf.Font.parse(allocator, d);
            return .{ .allocator = allocator, .psf_font = f, .cell_w = f.width, .cell_h = f.height };
        }
        const i: usize = if (h >= 32) 2 else if (h >= 24) 1 else 0;
        const f = try psf.Font.parse(allocator, psf.builtin_data[i].data);
        return .{ .allocator = allocator, .psf_font = f, .cell_w = f.width, .cell_h = f.height };
    }

    pub fn deinit(self: *Preview) void {
        if (self.psf_font) |*f| f.deinit(self.allocator);
        if (self.face) |*f| f.deinit();
    }

    pub const lines = [_][]const u8{
        "dkde-console on tty1",
        "root@dkde:~# ls --color",
        "The quick brown fox jumps over the lazy dog 0123456789",
        "\u{251C}\u{2500}\u{252C}\u{2500}\u{2510} \u{2591}\u{2592}\u{2593}\u{2588} \u{E0}\u{E9}\u{EE}\u{F5}\u{FC} \u{391}\u{392}\u{393} \u{414}\u{416}\u{417}",
    };

    /// Rows of text the preview needs: the sample lines and a row of colours.
    pub const rows = lines.len + 1;

    /// Draws into `px` (`w` by `h`, 0xFFRRGGBB), margin 8 pixels.
    pub fn draw(self: *Preview, px: []u32, w: u32, h: u32, scheme: Scheme) void {
        const bg: u32 = scheme.background;
        @memset(px[0 .. w * h], 0xFF000000 | bg);
        const margin: u32 = 8;
        for (lines, 0..) |line, row| {
            const y = margin + @as(u32, @intCast(row)) * self.cell_h;
            var x = margin;
            var it = std.unicode.Utf8View.initUnchecked(line).iterator();
            while (it.nextCodepoint()) |cp| {
                if (x + self.cell_w > w) break;
                const fg: u32 = if (row == 1 and x < margin + 13 * self.cell_w) scheme.ansi[10] else scheme.foreground;
                self.glyph(px, w, h, x, y, cp, fg, bg);
                x += self.cell_w;
            }
        }
        // The sixteen colours as blocks, two cells each.
        const y = margin + @as(u32, lines.len) * self.cell_h;
        for (scheme.ansi, 0..) |c, i| {
            const x = margin + @as(u32, @intCast(i)) * self.cell_w * 2;
            fillRect(px, w, h, x, y, self.cell_w * 2, self.cell_h, c);
        }
    }

    fn glyph(self: *Preview, px: []u32, w: u32, h: u32, x0: u32, y0: u32, cp: u21, fg: u32, bg: u32) void {
        if (cp == ' ') return;
        if (self.face) |*f| {
            const cov = f.coverage(cp, false, false, self.cell_w) orelse return;
            var gy: u32 = 0;
            while (gy < self.cell_h and y0 + gy < h) : (gy += 1) {
                for (cov[gy * self.cell_w ..][0..self.cell_w], 0..) |c, gx| {
                    if (c == 0 or x0 + gx >= w) continue;
                    px[(y0 + gy) * w + x0 + gx] = 0xFF000000 | mix(bg, fg, c);
                }
            }
        } else if (self.psf_font) |*f| {
            const bm = f.lookup(cp) orelse return;
            var gy: u32 = 0;
            while (gy < f.height and y0 + gy < h) : (gy += 1) {
                var gx: u32 = 0;
                while (gx < f.width and x0 + gx < w) : (gx += 1) {
                    if (f.pixel(bm, gx, gy)) px[(y0 + gy) * w + x0 + gx] = 0xFF000000 | fg;
                }
            }
        }
    }
};

fn fillRect(px: []u32, w: u32, h: u32, x: u32, y: u32, rw: u32, rh: u32, color: u32) void {
    var yy = y;
    while (yy < @min(h, y + rh)) : (yy += 1) {
        var xx = x;
        while (xx < @min(w, x + rw)) : (xx += 1) px[yy * w + xx] = 0xFF000000 | color;
    }
}

fn mix(bg: u32, fg: u32, a: u8) u32 {
    const al: u32 = a;
    const inv = 255 - al;
    const r = (((bg >> 16) & 255) * inv + ((fg >> 16) & 255) * al + 127) / 255;
    const g = (((bg >> 8) & 255) * inv + ((fg >> 8) & 255) * al + 127) / 255;
    const b = ((bg & 255) * inv + (fg & 255) * al + 127) / 255;
    return (r << 16) | (g << 8) | b;
}

test "the built-in font draws the sample" {
    const a = std.testing.allocator;
    var p = try Preview.init(a, null, 16);
    defer p.deinit();
    const w: u32 = 640;
    const h: u32 = 16 + p.cell_h * @as(u32, Preview.rows);
    const px = try a.alloc(u32, w * h);
    defer a.free(px);
    const scheme = termcore.schemes.scheme("campbell");
    p.draw(px, w, h, scheme);
    var fg_pixels: usize = 0;
    for (px) |v| if (v == 0xFF000000 | @as(u32, scheme.foreground)) {
        fg_pixels += 1;
    };
    try std.testing.expect(fg_pixels > 100);
}
