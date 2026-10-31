//! Screen capture on X11 (SPEC.md 5.9), compiled only with `-Dx11=true`:
//! `XGetImage` of the root window. Only 32-bit-per-pixel visuals are handled,
//! which is what every current X server provides.

const std = @import("std");
const gdk = @import("gdk4");
const gdkx11 = @import("gdkx114");
const gobject = @import("gobject2");

const Display = anyopaque;
const Window = c_ulong;

extern fn XGetImage(dpy: *Display, drawable: Window, x: c_int, y: c_int, width: c_uint, height: c_uint, plane_mask: c_ulong, format: c_int) ?*Image;
extern fn XDestroyImage(image: *Image) c_int;
extern fn XDefaultScreen(dpy: *Display) c_int;
extern fn XDisplayWidth(dpy: *Display, screen: c_int) c_int;
extern fn XDisplayHeight(dpy: *Display, screen: c_int) c_int;
extern fn XRootWindow(dpy: *Display, screen: c_int) Window;

const ZPixmap = 2;

/// The leading fields of Xlib's XImage, which is all we read.
const Image = extern struct {
    width: c_int,
    height: c_int,
    xoffset: c_int,
    format: c_int,
    data: [*]u8,
    byte_order: c_int,
    bitmap_unit: c_int,
    bitmap_bit_order: c_int,
    bitmap_pad: c_int,
    depth: c_int,
    bytes_per_line: c_int,
    bits_per_pixel: c_int,
};

pub fn isActive() bool {
    const display = gdk.Display.getDefault() orelse return false;
    return gobject.typeCheckInstanceIsA(@ptrCast(@alignCast(display)), gdkx11.X11Display.getGObjectType()) != 0;
}

pub const Shot = struct {
    width: usize,
    height: usize,
    /// Tightly packed B,G,R,X rows, owned by the caller.
    pixels: []u8,
};

pub fn grabScreen(allocator: std.mem.Allocator) !Shot {
    const gdk_display = gdk.Display.getDefault() orelse return error.NoDisplay;
    const x: *gdkx11.X11Display = @ptrCast(@alignCast(gdk_display));
    const dpy: *Display = @ptrCast(x.getXdisplay());
    const screen = XDefaultScreen(dpy);
    const w: c_uint = @intCast(XDisplayWidth(dpy, screen));
    const h: c_uint = @intCast(XDisplayHeight(dpy, screen));
    const image = XGetImage(dpy, XRootWindow(dpy, screen), 0, 0, w, h, ~@as(c_ulong, 0), ZPixmap) orelse return error.GrabFailed;
    defer _ = XDestroyImage(image);
    if (image.bits_per_pixel != 32) return error.UnsupportedFormat;

    const width: usize = @intCast(image.width);
    const height: usize = @intCast(image.height);
    const stride: usize = @intCast(image.bytes_per_line);
    const pixels = try allocator.alloc(u8, width * height * 4);
    for (0..height) |row| @memcpy(pixels[row * width * 4 ..][0 .. width * 4], image.data[row * stride ..][0 .. width * 4]);
    return .{ .width = width, .height = height, .pixels = pixels };
}
