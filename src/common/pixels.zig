// SPDX-License-Identifier: GPL-2.0-or-later
//! Pixel format conversion for screen capture. No toolkit, no protocol.

const std = @import("std");

/// Channel order of a 32-bit shm buffer, as bytes in memory.
pub const Layout = enum {
    /// wl_shm argb8888 / xrgb8888 on little-endian: B, G, R, A|X.
    bgra,
    /// abgr8888 / xbgr8888 on little-endian: R, G, B, A|X.
    rgba,
};

/// Converts a shm buffer to tightly packed opaque RGBA. `flip` mirrors it
/// vertically for compositors that report `y_invert`.
pub fn toRgba(dst: []u8, src: []const u8, width: usize, height: usize, stride: usize, layout: Layout, flip: bool) void {
    for (0..height) |y| {
        const src_row = src[(if (flip) height - 1 - y else y) * stride ..][0 .. width * 4];
        const dst_row = dst[y * width * 4 ..][0 .. width * 4];
        for (0..width) |x| {
            const s = src_row[x * 4 ..][0..4];
            const d = dst_row[x * 4 ..][0..4];
            switch (layout) {
                .bgra => {
                    d[0] = s[2];
                    d[1] = s[1];
                    d[2] = s[0];
                },
                .rgba => {
                    d[0] = s[0];
                    d[1] = s[1];
                    d[2] = s[2];
                },
            }
            d[3] = 255; // screenshots are opaque
        }
    }
}

test "bgra to rgba swaps red and blue and forces opaque" {
    const src = [_]u8{ 1, 2, 3, 0, 10, 20, 30, 0 }; // two pixels, B G R X
    var dst: [8]u8 = undefined;
    toRgba(&dst, &src, 2, 1, 8, .bgra, false);
    try std.testing.expectEqualSlices(u8, &.{ 3, 2, 1, 255, 30, 20, 10, 255 }, &dst);
}

test "rgba layout keeps channel order" {
    const src = [_]u8{ 1, 2, 3, 0 };
    var dst: [4]u8 = undefined;
    toRgba(&dst, &src, 1, 1, 4, .rgba, false);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 255 }, &dst);
}

test "stride padding is skipped and flip mirrors rows" {
    // 1 pixel wide, 2 rows, stride 8 (4 bytes padding per row).
    const src = [_]u8{ 1, 1, 1, 0, 9, 9, 9, 9, 2, 2, 2, 0, 9, 9, 9, 9 };
    var dst: [8]u8 = undefined;
    toRgba(&dst, &src, 1, 2, 8, .bgra, true);
    try std.testing.expectEqualSlices(u8, &.{ 2, 2, 2, 255, 1, 1, 1, 255 }, &dst);
}
