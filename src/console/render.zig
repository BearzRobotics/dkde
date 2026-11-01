//! Drawing the terminal's cells into a dumb buffer with PSF bitmap fonts
//! (SPEC.md 5.11, *Display* and *Fonts*). It reads libghostty-vt's render
//! state, as dkde-term does, and writes XRGB8888 pixels; there is no
//! rasterizer, a glyph is a copy of bits.

const std = @import("std");
const vt = @import("ghostty-vt");
const psf = @import("psf.zig");
const drm = @import("drm.zig");

pub const Rgb = vt.color.RGB;

pub inline fn pack(c: Rgb) u32 {
    return (@as(u32, c.r) << 16) | (@as(u32, c.g) << 8) | c.b;
}

pub const Cursor = struct {
    x: u16,
    y: u16,
    style: enum { block, bar, underline, hollow },
    color: Rgb,
};

pub const Renderer = struct {
    /// The main font first, then the fallback fonts.
    fonts: []const *const psf.Font,
    scale: u32,
    cell_w: u32,
    cell_h: u32,

    pub fn init(fonts: []const *const psf.Font, scale: u32) Renderer {
        const f = fonts[0];
        return .{ .fonts = fonts, .scale = scale, .cell_w = f.width * scale, .cell_h = f.height * scale };
    }

    const Glyph = struct { font: *const psf.Font, bitmap: []const u8 };

    fn glyphFor(self: *const Renderer, cp: u21) ?Glyph {
        const main = self.fonts[0];
        for (self.fonts) |f| {
            // Only fonts with the same cell size can share a grid.
            if (f.width != main.width or f.height != main.height) continue;
            if (f.lookup(cp)) |bm| return .{ .font = f, .bitmap = bm };
        }
        return null;
    }

    /// Colours of a cell after style, inverse, bold-as-bright and selection.
    pub const Colors = struct { fg: Rgb, bg: Rgb };

    pub fn cellColors(
        state: *const vt.RenderState,
        raw: vt.Cell,
        style: vt.Style,
        selected: bool,
    ) Colors {
        const default_fg = state.colors.foreground;
        const default_bg = state.colors.background;
        var fg = default_fg;
        var bg = default_bg;
        switch (raw.content_tag) {
            .bg_color_palette => bg = state.colors.palette[raw.content.color_palette.data],
            .bg_color_rgb => bg = .{ .r = raw.content.color_rgb.r, .g = raw.content.color_rgb.g, .b = raw.content.color_rgb.b },
            else => {},
        }
        if (raw.style_id != 0) {
            fg = colorOf(state, style.fg_color, default_fg);
            bg = colorOf(state, style.bg_color, bg);
            if (style.flags.bold and style.fg_color == .palette and style.fg_color.palette < 8) {
                fg = state.colors.palette[style.fg_color.palette + 8];
            }
            if (style.flags.inverse) std.mem.swap(Rgb, &fg, &bg);
            if (style.flags.faint) fg = .{ .r = fg.r / 2 + bg.r / 2, .g = fg.g / 2 + bg.g / 2, .b = fg.b / 2 + bg.b / 2 };
        }
        if (selected) std.mem.swap(Rgb, &fg, &bg);
        return .{ .fg = fg, .bg = bg };
    }

    fn colorOf(state: *const vt.RenderState, c: vt.Style.Color, default: Rgb) Rgb {
        return switch (c) {
            .none => default,
            .palette => |i| state.colors.palette[i],
            .rgb => |v| v,
        };
    }

    fn cellCodepoint(raw: vt.Cell) u21 {
        return switch (raw.content_tag) {
            .codepoint, .codepoint_grapheme => raw.content.codepoint.data,
            else => 0,
        };
    }

    /// Fill a rectangle, clipped to the buffer.
    pub fn fill(buf: *const drm.Buffer, x: u32, y: u32, w: u32, h: u32, color: u32) void {
        if (x >= buf.width or y >= buf.height) return;
        const x1 = @min(buf.width, x + w);
        const y1 = @min(buf.height, y + h);
        var yy = y;
        while (yy < y1) : (yy += 1) @memset(buf.row(yy)[x..x1], color);
    }

    /// Draw one cell (or the first of two, for a wide character) at pixel (px, py).
    fn drawCell(
        self: *const Renderer,
        buf: *const drm.Buffer,
        px: u32,
        py: u32,
        cp: u21,
        cells_wide: u32,
        fg: u32,
        bg: u32,
        flags: @FieldType(vt.Style, "flags"),
    ) void {
        const w = self.cell_w * cells_wide;
        fill(buf, px, py, w, self.cell_h, bg);
        if (flags.invisible) return;

        const blank = cp == 0 or cp == ' ';
        if (!blank) {
            if (self.glyphFor(cp)) |g| {
                self.blit(buf, px, py, g, fg, flags.bold);
            } else self.box(buf, px, py, fg);
        }
        const s = self.scale;
        if (flags.underline != .none) fill(buf, px, py + self.cell_h - 2 * s, w, s, fg);
        if (flags.strikethrough) fill(buf, px, py + self.cell_h / 2, w, s, fg);
        if (flags.overline) fill(buf, px, py, w, s, fg);
    }

    fn blit(self: *const Renderer, buf: *const drm.Buffer, px: u32, py: u32, g: Glyph, fg: u32, bold: bool) void {
        const f = g.font;
        const s = self.scale;
        var gy: u32 = 0;
        while (gy < f.height) : (gy += 1) {
            var sy: u32 = 0;
            while (sy < s) : (sy += 1) {
                const y = py + gy * s + sy;
                if (y >= buf.height) return;
                const row = buf.row(y);
                var gx: u32 = 0;
                while (gx < f.width) : (gx += 1) {
                    var on = f.pixel(g.bitmap, gx, gy);
                    // No bold font: smear the glyph one pixel to the right.
                    if (!on and bold and gx > 0) on = f.pixel(g.bitmap, gx - 1, gy);
                    if (!on) continue;
                    var sx: u32 = 0;
                    while (sx < s) : (sx += 1) {
                        const x = px + gx * s + sx;
                        if (x < buf.width) row[x] = fg;
                    }
                }
            }
        }
    }

    /// The box drawn for a character no font has.
    fn box(self: *const Renderer, buf: *const drm.Buffer, px: u32, py: u32, fg: u32) void {
        const s = self.scale;
        const x0 = px + s;
        const y0 = py + 2 * s;
        const w = self.cell_w -| 2 * s;
        const h = self.cell_h -| 4 * s;
        if (w < 3 * s or h < 3 * s) return;
        fill(buf, x0, y0, w, s, fg);
        fill(buf, x0, y0 + h - s, w, s, fg);
        fill(buf, x0, y0, s, h, fg);
        fill(buf, x0 + w - s, y0, s, h, fg);
    }

    /// Draw row `y` completely: every cell, then the cursor if it is on this row.
    pub fn drawRow(
        self: *const Renderer,
        buf: *const drm.Buffer,
        origin_x: u32,
        origin_y: u32,
        state: *const vt.RenderState,
        y: usize,
        cursor: ?Cursor,
    ) void {
        const row_data = state.row_data.slice();
        const cells = row_data.items(.cells)[y];
        const selection = row_data.items(.selection)[y];
        const raws = cells.items(.raw);
        const styles = cells.items(.style);
        const py = origin_y + @as(u32, @intCast(y)) * self.cell_h;
        const n = @min(raws.len, state.cols);

        // Margins at the sides of the grid carry the background colour too.
        const bg_default = pack(state.colors.background);
        fill(buf, 0, py, origin_x, self.cell_h, bg_default);
        fill(buf, origin_x + @as(u32, @intCast(n)) * self.cell_w, py, buf.width, self.cell_h, bg_default);

        var x: usize = 0;
        while (x < n) : (x += 1) {
            const raw = raws[x];
            if (raw.wide == .spacer_tail or raw.wide == .spacer_head) continue;
            const style = if (raw.style_id != 0) styles[x] else vt.Style{};
            const sel = if (selection) |r| x >= r[0] and x <= r[1] else false;
            var colors = cellColors(state, raw, style, sel);
            const is_cursor = if (cursor) |c| c.y == y and c.x == x else false;
            if (is_cursor and cursor.?.style == .block) {
                colors.bg = cursor.?.color;
                colors.fg = state.colors.background;
            }
            const wide: u32 = if (raw.wide == .wide) 2 else 1;
            const cx = origin_x + @as(u32, @intCast(x)) * self.cell_w;
            self.drawCell(buf, cx, py, cellCodepoint(raw), wide, pack(colors.fg), pack(colors.bg), style.flags);
            if (is_cursor) {
                const cc = pack(cursor.?.color);
                const s = self.scale;
                switch (cursor.?.style) {
                    .block => {},
                    .bar => fill(buf, cx, py, 2 * s, self.cell_h, cc),
                    .underline => fill(buf, cx, py + self.cell_h - 2 * s, self.cell_w, 2 * s, cc),
                    .hollow => {
                        fill(buf, cx, py, self.cell_w, s, cc);
                        fill(buf, cx, py + self.cell_h - s, self.cell_w, s, cc);
                        fill(buf, cx, py, s, self.cell_h, cc);
                        fill(buf, cx + self.cell_w - s, py, s, self.cell_h, cc);
                    },
                }
            }
        }
    }

    /// Everything outside the grid: the margins above and below it.
    pub fn drawMargins(self: *const Renderer, buf: *const drm.Buffer, origin_y: u32, rows: u32, bg: u32) void {
        fill(buf, 0, 0, buf.width, origin_y, bg);
        const below = origin_y + rows * self.cell_h;
        if (below < buf.height) fill(buf, 0, below, buf.width, buf.height - below, bg);
    }
};

/// A 12x19 arrow, one bit per pixel: bit set means white, with a black outline
/// where `outline` has it.
pub const pointer_w = 12;
pub const pointer_h = 19;
const pointer_rows = [pointer_h]u16{
    0b100000000000, 0b110000000000, 0b111000000000, 0b111100000000,
    0b111110000000, 0b111111000000, 0b111111100000, 0b111111110000,
    0b111111111000, 0b111111111100, 0b111111000000, 0b110111100000,
    0b100111100000, 0b000011110000, 0b000011110000, 0b000001111000,
    0b000001111000, 0b000000110000, 0b000000000000,
};

/// Draw the pointer with its tip at (x, y).
pub fn drawPointer(buf: *const drm.Buffer, x: u32, y: u32) void {
    for (pointer_rows, 0..) |bits, j| {
        const yy = y + @as(u32, @intCast(j));
        if (yy >= buf.height) break;
        const row = buf.row(yy);
        var i: u32 = 0;
        while (i < pointer_w) : (i += 1) {
            const shift: u4 = @intCast(pointer_w - 1 - i);
            const on = bits >> shift & 1 != 0;
            // Black outline: any set neighbour to the left or right of an unset bit.
            const left = i > 0 and (bits >> (shift + 1)) & 1 != 0;
            const right = i + 1 < pointer_w and (bits >> (shift -| 1)) & 1 != 0 and shift > 0;
            const xx = x + i;
            if (xx >= buf.width) break;
            if (on) {
                row[xx] = 0xFFFFFF;
            } else if (left or right) row[xx] = 0x000000;
        }
    }
}

// ---- tests ---------------------------------------------------------------------

const testing = std.testing;
const termcore = @import("termcore");

/// A buffer in ordinary memory, for drawing without a display.
fn fakeBuffer(a: std.mem.Allocator, w: u32, h: u32) !drm.Buffer {
    const bytes = try a.alignedAlloc(u8, .fromByteUnits(4096), w * h * 4);
    @memset(bytes, 0);
    return .{ .handle = 0, .fb_id = 0, .pitch = w * 4, .size = bytes.len, .width = w, .height = h, .pixels = bytes };
}

fn drawScreen(a: std.mem.Allocator, input: []const u8, cols: u16, rows: u16, scale: u32) !struct { buf: drm.Buffer, r: Renderer, font: *psf.Font } {
    const font = try a.create(psf.Font);
    font.* = try psf.Font.parse(a, psf.builtin_data[0].data);
    const fonts = try a.alloc(*const psf.Font, 1);
    fonts[0] = font;
    const r = Renderer.init(fonts, scale);

    var io: vt.TinyIo = .init;
    var term = try vt.Terminal.init(io.io(), a, .{
        .cols = cols,
        .rows = rows,
        .colors = try termcore.glue.terminalColors(a, termcore.schemes.scheme("campbell")),
    });
    defer term.deinit(a);
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice(input);

    var state: vt.RenderState = .empty;
    defer state.deinit(a);
    try state.update(a, &term);

    const buf = try fakeBuffer(a, cols * r.cell_w, rows * r.cell_h);
    for (0..rows) |y| r.drawRow(&buf, 0, 0, &state, y, null);
    return .{ .buf = buf, .r = r, .font = font };
}

fn countPixels(buf: *const drm.Buffer, x0: u32, y0: u32, w: u32, h: u32, color: u32) u32 {
    var n: u32 = 0;
    var y = y0;
    while (y < y0 + h) : (y += 1) {
        for (buf.row(y)[x0 .. x0 + w]) |p| {
            if (p == color) n += 1;
        }
    }
    return n;
}

test "text is drawn in the colours the escape sequences ask for" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const red = pack(termcore.glue.rgb(termcore.schemes.scheme("campbell").ansi[1]));
    const bg = pack(termcore.glue.rgb(termcore.schemes.scheme("campbell").background));
    const s = try drawScreen(a, "\x1b[31mA\x1b[0m B", 10, 2, 1);
    // Cell 0 is a red 'A' on the background; cell 2 is a default-colour 'B'.
    try testing.expect(countPixels(&s.buf, 0, 0, 8, 16, red) > 10);
    try testing.expect(countPixels(&s.buf, 0, 0, 8, 16, bg) > 40);
    try testing.expectEqual(@as(u32, 0), countPixels(&s.buf, 16, 0, 8, 16, red));
    // The empty second row is all background.
    try testing.expectEqual(@as(u32, 8 * 16), countPixels(&s.buf, 0, 16, 8, 16, bg));
}

test "scale 2 doubles every pixel" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const fg = pack(termcore.glue.rgb(termcore.schemes.scheme("campbell").foreground));
    const one = try drawScreen(a, "W", 4, 1, 1);
    const two = try drawScreen(a, "W", 4, 1, 2);
    const n1 = countPixels(&one.buf, 0, 0, 8, 16, fg);
    const n2 = countPixels(&two.buf, 0, 0, 16, 32, fg);
    try testing.expectEqual(n1 * 4, n2);
}

test "a character no font has is drawn as a box, and inverse swaps colours" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const fg = pack(termcore.glue.rgb(termcore.schemes.scheme("campbell").foreground));
    const bg = pack(termcore.glue.rgb(termcore.schemes.scheme("campbell").background));
    const boxed = try drawScreen(a, "\u{10FFFD}", 4, 1, 1);
    try testing.expect(countPixels(&boxed.buf, 0, 0, 8, 16, fg) > 10);
    const inv = try drawScreen(a, "\x1b[7m ", 4, 1, 1);
    try testing.expectEqual(@as(u32, 8 * 16), countPixels(&inv.buf, 0, 0, 8, 16, fg));
    try testing.expectEqual(@as(u32, 0), countPixels(&inv.buf, 0, 0, 8, 16, bg));
}
