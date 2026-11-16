//! A pointer that moves and scrolls by itself on X11, through the XTEST extension written out by hand
//! (FakeInput), so no extension headers are needed. Used by dkde-snip to scroll a page for a long capture.

const std = @import("std");
const c = @import("c");

pub const Pointer = struct {
    conn: *c.xcb_connection_t,
    root: c.xcb_window_t,

    var xtest_ext: c.xcb_extension_t = .{ .name = "XTEST", .global_id = 0 };

    /// Connects to $DISPLAY; null when there is no X server or it lacks XTEST.
    pub fn open() ?Pointer {
        var num: c_int = 0;
        const conn = c.xcb_connect(null, &num) orelse return null;
        if (c.xcb_connection_has_error(conn) != 0) return null;
        const data = c.xcb_get_extension_data(conn, &xtest_ext);
        if (data == null or data.?.*.present == 0) {
            c.xcb_disconnect(conn);
            return null;
        }
        var it = c.xcb_setup_roots_iterator(c.xcb_get_setup(conn));
        var i: c_int = 0;
        while (i < num) : (i += 1) c.xcb_screen_next(&it);
        return .{ .conn = conn, .root = it.data.*.root };
    }

    pub fn close(self: Pointer) void {
        c.xcb_disconnect(self.conn);
    }

    const button_press = 4;
    const button_release = 5;
    const motion_notify = 6;

    /// XTEST FakeInput (minor 2): one fake event; `detail` is the button, or 0 for absolute motion.
    fn fake(self: Pointer, kind: u8, detail: u8, x: i16, y: i16) void {
        const Request = extern struct {
            major: u8,
            minor: u8,
            length: u16,
            kind: u8,
            detail: u8,
            pad0: u16,
            time: u32,
            root: u32,
            pad1: [8]u8,
            x: i16,
            y: i16,
            pad2: [7]u8,
            device: u8,
        };
        comptime std.debug.assert(@sizeOf(Request) == 36);
        var req: Request = .{ .major = 0, .minor = 2, .length = 0, .kind = kind, .detail = detail, .pad0 = 0, .time = 0, .root = self.root, .pad1 = @splat(0), .x = x, .y = y, .pad2 = @splat(0), .device = 0 };
        var parts: [4]c.struct_iovec = undefined;
        parts[2] = .{ .iov_base = &req, .iov_len = @sizeOf(Request) };
        parts[3] = .{ .iov_base = null, .iov_len = 0 };
        var proto: c.xcb_protocol_request_t = .{ .count = 2, .ext = &xtest_ext, .opcode = 2, .isvoid = 1 };
        _ = c.xcb_send_request(self.conn, 0, &parts[2], &proto);
        _ = c.xcb_flush(self.conn);
    }

    /// Puts the pointer at a screen position.
    pub fn moveTo(self: Pointer, x: i32, y: i32) void {
        self.fake(motion_notify, 0, @intCast(x), @intCast(y));
    }

    /// One wheel notch down (button 5).
    pub fn wheelDown(self: Pointer) void {
        self.fake(button_press, 5, 0, 0);
        self.fake(button_release, 5, 0, 0);
    }
};
