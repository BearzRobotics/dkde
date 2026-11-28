// SPDX-License-Identifier: GPL-2.0-or-later
//! Watermarks and stamps: a line of text across a page, or a picture (a logo, a
//! scanned signature) at a chosen place, drawn on top of pages or behind them
//! with pdf-zig's `draw.Stamp`. It appends to the file like any other edit.
//! A picture of a signature is only a picture: it signs nothing.

const std = @import("std");
const pdf = @import("pdf");
const imgcodec = @import("imgcodec");
const fonts = @import("fonts.zig");

const Allocator = std.mem.Allocator;
const draw = pdf.draw;

/// Where a picture goes on the page as it is displayed.
pub const Position = enum { top_left, top, top_right, left, center, right, bottom_left, bottom, bottom_right };

pub const Spec = struct {
    what: union(enum) {
        /// One line of text, across the page from lower left to upper right.
        text: []const u8,
        /// The bytes of an image file.
        image: struct {
            file: []const u8,
            position: Position = .bottom_right,
            /// The picture's width as a share of the page's, 0 to 1.
            width: f64 = 0.25,
        },
    },
    /// 0 (invisible) to 1.
    opacity: f64 = 0.25,
    /// Behind what the page shows. A page that paints its whole area, as a scan does, hides it.
    under: bool = false,
    /// The colour of text, 0 to 1 each.
    color: [3]f64 = .{ 0.4, 0.4, 0.4 },
};

pub const Error = pdf.draw.StampError || pdf.draw.Error || pdf.draw.ImageError || fonts.Error || imgcodec.Error ||
    error{ BadImage, TooLarge, EmptyText, BadValue, MissingGlyph, NoSuchPage };

/// The pages `text` names, as indices from 0, each once and in order:
/// numbers and ranges from 1, separated by commas ("1-3, 5", "4-", "-2").
/// Empty means every page. The caller frees the result.
pub fn parsePages(gpa: Allocator, text: []const u8, count: usize) error{ OutOfMemory, BadPages }![]usize {
    const chosen = try gpa.alloc(bool, count);
    defer gpa.free(chosen);
    const all = std.mem.trim(u8, text, " \t").len == 0;
    @memset(chosen, all);
    if (!all) {
        var parts = std.mem.splitScalar(u8, text, ',');
        while (parts.next()) |raw| {
            const part = std.mem.trim(u8, raw, " \t");
            if (part.len == 0) continue;
            var first: usize = 1;
            var last: usize = count;
            if (std.mem.indexOfScalar(u8, part, '-')) |dash| {
                const a = std.mem.trim(u8, part[0..dash], " \t");
                const b = std.mem.trim(u8, part[dash + 1 ..], " \t");
                if (a.len == 0 and b.len == 0) return error.BadPages;
                if (a.len > 0) first = std.fmt.parseInt(usize, a, 10) catch return error.BadPages;
                if (b.len > 0) last = std.fmt.parseInt(usize, b, 10) catch return error.BadPages;
            } else {
                first = std.fmt.parseInt(usize, part, 10) catch return error.BadPages;
                last = first;
            }
            if (first == 0 or last < first or last > count) return error.BadPages;
            @memset(chosen[first - 1 .. last], true);
        }
    }
    var out: std.ArrayList(usize) = .empty;
    errdefer out.deinit(gpa);
    for (chosen, 0..) |is_chosen, i| if (is_chosen) try out.append(gpa, i);
    if (out.items.len == 0) return error.BadPages;
    return out.toOwnedSlice(gpa);
}

/// The top left corner of a `w` by `h` box at `position` on a page, kept
/// `margin` from its edges.
pub fn place(position: Position, page_w: f64, page_h: f64, w: f64, h: f64, margin: f64) struct { x: f64, y: f64 } {
    const column = @backingInt(position) % 3;
    const row = @backingInt(position) / 3;
    return .{
        .x = switch (column) {
            0 => margin,
            1 => (page_w - w) / 2,
            else => page_w - w - margin,
        },
        .y = switch (row) {
            0 => margin,
            1 => (page_h - h) / 2,
            else => page_h - h - margin,
        },
    };
}

/// An image file as pdf-zig takes it. A JPEG is stored as it is when it can
/// be; anything else, and a JPEG that a camera marked as turned, is decoded.
pub fn loadImage(gpa: Allocator, file: []const u8) Error!draw.Image {
    const orientation = imgcodec.exifOrientation(file);
    if (orientation == 1 and std.mem.startsWith(u8, file, "\xff\xd8")) {
        if (draw.Image.fromJpeg(gpa, file)) |image| return image else |e| if (e == error.OutOfMemory) return error.OutOfMemory;
    }
    var decoded = try imgcodec.decode(gpa, file);
    if (orientation != 1) {
        const turned = imgcodec.orient(gpa, decoded, orientation) catch |e| {
            decoded.deinit(gpa);
            return e;
        };
        decoded = turned;
    }
    defer decoded.deinit(gpa);
    const count = decoded.width * decoded.height;
    const rgb = try gpa.alloc(u8, count * 3);
    defer gpa.free(rgb);
    const alpha = try gpa.alloc(u8, count);
    defer gpa.free(alpha);
    var see_through = false;
    for (0..count) |i| {
        @memcpy(rgb[i * 3 ..][0..3], decoded.rgba[i * 4 ..][0..3]);
        alpha[i] = decoded.rgba[i * 4 + 3];
        if (alpha[i] != 255) see_through = true;
    }
    return draw.Image.fromPixels(gpa, .{
        .width = std.math.cast(u32, decoded.width) orelse return error.TooLarge,
        .height = std.math.cast(u32, decoded.height) orelse return error.TooLarge,
        .format = .rgb,
        .samples = rgb,
        .alpha = if (see_through) alpha else null,
    });
}

/// A line from the lower left to the upper right of a `w` by `h` page, sized
/// to fit it.
fn drawText(canvas: *draw.Canvas, font: draw.Font, line: []const u8, w: f64, h: f64, spec: Spec) Error!void {
    const natural = try font.textWidth(1, line);
    if (!(natural > 0)) return error.EmptyText;
    const diagonal = std.math.hypot(w, h);
    const size = @min(diagonal * 0.7 / natural, @min(w, h) / 3);
    const angle = -std.math.atan2(h, w);
    const cos = @cos(angle);
    const sin = @sin(angle);
    // Turned about the middle of the page.
    try canvas.transform(.{ .a = cos, .b = sin, .c = -sin, .d = cos, .e = w / 2, .f = h / 2 });
    try canvas.setAlpha(spec.opacity, spec.opacity);
    try canvas.setFill(.{ .rgb = spec.color });
    try canvas.text(font, size, -natural * size / 2, size * 0.35, line);
}

/// Adds `spec` to pages `indices` of the document `upd` changes.
pub fn apply(gpa: Allocator, upd: *pdf.write.Update, list: pdf.pages.PageList, indices: []const usize, spec: Spec) Error!void {
    if (!(spec.opacity >= 0 and spec.opacity <= 1)) return error.BadValue;
    var stamp: draw.Stamp = .init(upd);

    var embedded: ?pdf.truetype.Font = null;
    defer if (embedded) |*f| f.deinit();
    var font: draw.Font = .helvetica_bold;
    var picture: ?draw.Image = null;
    defer if (picture) |*p| p.deinit();
    switch (spec.what) {
        .text => |line| {
            if (std.mem.trim(u8, line, " ").len == 0) return error.EmptyText;
            if (!font.covers(line)) {
                embedded = try fonts.find(gpa, &.{line});
                font = .{ .embedded = &embedded.? };
            }
        },
        .image => |image| {
            if (!(image.width > 0 and image.width <= 1)) return error.BadValue;
            picture = try loadImage(gpa, image.file);
        },
    }

    for (indices) |index| {
        const page = pdf.pages.page(upd.doc, list, index) orelse return error.NoSuchPage;
        const size = page.displaySize();
        var canvas = try draw.Canvas.init(gpa, size.w, size.h);
        defer canvas.deinit();
        switch (spec.what) {
            .text => |line| try drawText(&canvas, font, line, size.w, size.h, spec),
            .image => |image| {
                const p = &picture.?;
                const aspect = @as(f64, @floatFromInt(p.height)) / @as(f64, @floatFromInt(p.width));
                const margin = @min(size.w, size.h) * 0.04;
                // As wide as asked, but never past the margins.
                const w = @min(size.w * image.width, size.w - 2 * margin, (size.h - 2 * margin) / aspect);
                const h = w * aspect;
                const at = place(image.position, size.w, size.h, w, h, margin);
                try canvas.setAlpha(spec.opacity, spec.opacity);
                try canvas.image(p, at.x, at.y, w, h);
            },
        }
        try stamp.place(page, &canvas, if (spec.under) .under else .over);
    }
    try stamp.finish();
}

// ---- tests -----------------------------------------------------------------------------------

const testing = std.testing;

test "page lists are numbers and ranges" {
    const gpa = testing.allocator;
    for ([_]struct { text: []const u8, want: []const usize }{
        .{ .text = "", .want = &.{ 0, 1, 2, 3, 4 } },
        .{ .text = "  ", .want = &.{ 0, 1, 2, 3, 4 } },
        .{ .text = "3", .want = &.{2} },
        .{ .text = "4-, 1", .want = &.{ 0, 3, 4 } },
        .{ .text = "-2,2-3,", .want = &.{ 0, 1, 2 } },
    }) |case| {
        const got = try parsePages(gpa, case.text, 5);
        defer gpa.free(got);
        try testing.expectEqualSlices(usize, case.want, got);
    }
    for ([_][]const u8{ "0", "6", "3-2", "-", ",", "a", "1-9", "1..3" }) |bad| try testing.expectError(error.BadPages, parsePages(gpa, bad, 5));
}

test "a box is placed within the margins" {
    const first = place(.top_left, 200, 100, 50, 20, 5);
    try testing.expectEqual(@as(f64, 5), first.x);
    try testing.expectEqual(@as(f64, 5), first.y);
    const middle = place(.center, 200, 100, 50, 20, 5);
    try testing.expectEqual(@as(f64, 75), middle.x);
    try testing.expectEqual(@as(f64, 40), middle.y);
    const last = place(.bottom_right, 200, 100, 50, 20, 5);
    try testing.expectEqual(@as(f64, 145), last.x);
    try testing.expectEqual(@as(f64, 75), last.y);
    const below = place(.bottom, 200, 100, 50, 20, 5);
    try testing.expectEqual(@as(f64, 75), below.x);
    try testing.expectEqual(@as(f64, 75), below.y);
}
