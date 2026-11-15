//! Idle time and screen power on X11, with the two extensions written out by
//! hand (MIT-SCREEN-SAVER for the time since the last input, DPMS for switching
//! the screen off), so no extension headers are needed. Used by dkde-idle.

const std = @import("std");
const c = @import("c");

pub const Idle = struct {
    conn: *c.xcb_connection_t,
    root: c.xcb_window_t,

    var saver_ext: c.xcb_extension_t = .{ .name = "MIT-SCREEN-SAVER", .global_id = 0 };
    var dpms_ext: c.xcb_extension_t = .{ .name = "DPMS", .global_id = 0 };

    /// Connects to $DISPLAY; null when there is no X server or no screen-saver extension.
    pub fn open() ?Idle {
        var num: c_int = 0;
        const conn = c.xcb_connect(null, &num) orelse return null;
        if (c.xcb_connection_has_error(conn) != 0) return null;
        const data = c.xcb_get_extension_data(conn, &saver_ext);
        if (data == null or data.?.*.present == 0) {
            c.xcb_disconnect(conn);
            return null;
        }
        var it = c.xcb_setup_roots_iterator(c.xcb_get_setup(conn));
        var i: c_int = 0;
        while (i < num) : (i += 1) c.xcb_screen_next(&it);
        return .{ .conn = conn, .root = it.data.*.root };
    }

    pub fn close(self: Idle) void {
        c.xcb_disconnect(self.conn);
    }

    /// Milliseconds since the last keyboard or pointer input, or null when the server will not say.
    pub fn idleMs(self: Idle) ?u32 {
        // MIT-SCREEN-SAVER QueryInfo (minor 1): the drawable to ask about.
        const Request = extern struct { major: u8, minor: u8, length: u16, drawable: u32 };
        var req: Request = .{ .major = 0, .minor = 1, .length = 0, .drawable = self.root };
        var parts: [4]c.struct_iovec = undefined;
        parts[2] = .{ .iov_base = &req, .iov_len = @sizeOf(Request) };
        parts[3] = .{ .iov_base = null, .iov_len = 0 };
        var proto: c.xcb_protocol_request_t = .{ .count = 2, .ext = &saver_ext, .opcode = 1, .isvoid = 0 };
        const cookie = c.xcb_send_request(self.conn, 0, &parts[2], &proto);
        var err: ?*c.xcb_generic_error_t = null;
        const reply = c.xcb_wait_for_reply(self.conn, cookie, &err) orelse {
            if (err) |e| std.c.free(e);
            return null;
        };
        defer std.c.free(reply);
        // response_type, state, sequence, length, window, ms until saver, ms since input, event mask, kind.
        const bytes: [*]const u8 = @ptrCast(reply);
        return std.mem.readInt(u32, bytes[16..20], .little);
    }

    fn dpmsRequest(self: Idle, minor: u8, words: u16, level: u16) void {
        const data = c.xcb_get_extension_data(self.conn, &dpms_ext);
        if (data == null or data.?.*.present == 0) return;
        const Request = extern struct { major: u8, minor: u8, length: u16, arg: u16, pad: u16 };
        var req: Request = .{ .major = 0, .minor = minor, .length = 0, .arg = level, .pad = 0 };
        var parts: [4]c.struct_iovec = undefined;
        parts[2] = .{ .iov_base = &req, .iov_len = if (words == 1) 4 else @sizeOf(Request) };
        parts[3] = .{ .iov_base = null, .iov_len = 0 };
        var proto: c.xcb_protocol_request_t = .{ .count = 2, .ext = &dpms_ext, .opcode = minor, .isvoid = 1 };
        _ = c.xcb_send_request(self.conn, 0, &parts[2], &proto);
    }

    /// Turns the screen off (DPMS); any input wakes it. Returns false when the server has no DPMS.
    pub fn screenOff(self: Idle) bool {
        const data = c.xcb_get_extension_data(self.conn, &dpms_ext);
        if (data == null or data.?.*.present == 0) return false;
        self.dpmsRequest(4, 1, 0); // Enable
        self.dpmsRequest(6, 2, 3); // ForceLevel: off
        _ = c.xcb_flush(self.conn);
        self.drain();
        return true;
    }

    /// Turns it on again.
    pub fn screenOn(self: Idle) void {
        self.dpmsRequest(6, 2, 0);
        _ = c.xcb_flush(self.conn);
        self.drain();
    }

    /// Errors of requests we did not wait for pile up as events; drop them.
    pub fn drain(self: Idle) void {
        while (c.xcb_poll_for_event(self.conn)) |ev| std.c.free(ev);
    }
};
