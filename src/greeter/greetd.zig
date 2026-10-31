//! The greetd greeter protocol: a 32-bit native-endian length, then a JSON
//! message, over the Unix socket named by $GREETD_SOCK (see greetd-ipc(7)).
//! Message building and parsing are pure so they can be tested; the socket
//! code is at the bottom.

const std = @import("std");

/// Appends `text` as a JSON string, with quotes and escapes.
pub fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    try out.append(allocator, '"');
    for (text) |c| switch (c) {
        '"' => try out.appendSlice(allocator, "\\\""),
        '\\' => try out.appendSlice(allocator, "\\\\"),
        '\n' => try out.appendSlice(allocator, "\\n"),
        '\r' => try out.appendSlice(allocator, "\\r"),
        '\t' => try out.appendSlice(allocator, "\\t"),
        0...8, 11, 12, 14...31 => {
            const escaped = try std.fmt.allocPrint(allocator, "\\u{x:0>4}", .{c});
            defer allocator.free(escaped);
            try out.appendSlice(allocator, escaped);
        },
        else => try out.append(allocator, c),
    };
    try out.append(allocator, '"');
}

pub fn createSession(allocator: std.mem.Allocator, username: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"type\":\"create_session\",\"username\":");
    try appendJsonString(allocator, &out, username);
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

/// `response` is null to acknowledge an informational or error message.
pub fn postAuthResponse(allocator: std.mem.Allocator, response: ?[]const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"type\":\"post_auth_message_response\",\"response\":");
    if (response) |r| try appendJsonString(allocator, &out, r) else try out.appendSlice(allocator, "null");
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

pub fn startSession(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"type\":\"start_session\",\"cmd\":[");
    for (argv, 0..) |arg, i| {
        if (i > 0) try out.append(allocator, ',');
        try appendJsonString(allocator, &out, arg);
    }
    try out.appendSlice(allocator, "],\"env\":[]}");
    return out.toOwnedSlice(allocator);
}

pub const cancel_session = "{\"type\":\"cancel_session\"}";

pub const Reply = struct {
    type: []const u8,
    auth_message_type: ?[]const u8 = null,
    auth_message: ?[]const u8 = null,
    error_type: ?[]const u8 = null,
    description: ?[]const u8 = null,
};

pub fn parseReply(allocator: std.mem.Allocator, text: []const u8) !std.json.Parsed(Reply) {
    return std.json.parseFromSlice(Reply, allocator, text, .{ .ignore_unknown_fields = true });
}

// ---- the socket -----------------------------------------------------------------------

extern fn socket(domain: c_int, kind: c_int, protocol: c_int) c_int;
extern fn connect(fd: c_int, addr: *const anyopaque, len: u32) c_int;
extern fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern fn close(fd: c_int) c_int;

const SockaddrUn = extern struct { family: u16 = 1, path: [108]u8 = @splat(0) };

pub const Connection = struct {
    fd: c_int,

    pub fn open(path: []const u8) !Connection {
        if (path.len >= 108) return error.PathTooLong;
        const fd = socket(1, 1, 0); // AF_UNIX, SOCK_STREAM
        if (fd < 0) return error.Socket;
        var addr: SockaddrUn = .{};
        @memcpy(addr.path[0..path.len], path);
        if (connect(fd, &addr, @sizeOf(SockaddrUn)) != 0) {
            _ = close(fd);
            return error.Connect;
        }
        return .{ .fd = fd };
    }

    pub fn deinit(self: Connection) void {
        _ = close(self.fd);
    }

    fn writeAll(self: Connection, bytes: []const u8) !void {
        var done: usize = 0;
        while (done < bytes.len) {
            const n = write(self.fd, bytes.ptr + done, bytes.len - done);
            if (n <= 0) return error.WriteFailed;
            done += @intCast(n);
        }
    }

    fn readAll(self: Connection, buf: []u8) !void {
        var done: usize = 0;
        while (done < buf.len) {
            const n = read(self.fd, buf.ptr + done, buf.len - done);
            if (n <= 0) return error.ReadFailed;
            done += @intCast(n);
        }
    }

    pub fn send(self: Connection, message: []const u8) !void {
        var header: [4]u8 = undefined;
        std.mem.writeInt(u32, &header, @intCast(message.len), .native);
        try self.writeAll(&header);
        try self.writeAll(message);
    }

    /// Returns the next message; the caller frees it.
    pub fn receive(self: Connection, allocator: std.mem.Allocator) ![]u8 {
        var header: [4]u8 = undefined;
        try self.readAll(&header);
        const len = std.mem.readInt(u32, &header, .native);
        if (len > 1 << 20) return error.MessageTooLarge;
        const buf = try allocator.alloc(u8, len);
        errdefer allocator.free(buf);
        try self.readAll(buf);
        return buf;
    }
};

test "requests are valid json with escaping" {
    const a = std.testing.allocator;
    const msg = try createSession(a, "da\"ko\\ta");
    defer a.free(msg);
    try std.testing.expectEqualStrings("{\"type\":\"create_session\",\"username\":\"da\\\"ko\\\\ta\"}", msg);
    const pw = try postAuthResponse(a, "p\nw\x01");
    defer a.free(pw);
    try std.testing.expectEqualStrings("{\"type\":\"post_auth_message_response\",\"response\":\"p\\nw\\u0001\"}", pw);
    const none = try postAuthResponse(a, null);
    defer a.free(none);
    try std.testing.expectEqualStrings("{\"type\":\"post_auth_message_response\",\"response\":null}", none);
    const start = try startSession(a, &.{ "dkde-session", "--x" });
    defer a.free(start);
    try std.testing.expectEqualStrings("{\"type\":\"start_session\",\"cmd\":[\"dkde-session\",\"--x\"],\"env\":[]}", start);
}

test "replies" {
    const a = std.testing.allocator;
    var ok = try parseReply(a, "{\"type\":\"success\"}");
    defer ok.deinit();
    try std.testing.expectEqualStrings("success", ok.value.type);
    var ask = try parseReply(a, "{\"type\":\"auth_message\",\"auth_message_type\":\"secret\",\"auth_message\":\"Password: \"}");
    defer ask.deinit();
    try std.testing.expectEqualStrings("secret", ask.value.auth_message_type.?);
    var bad = try parseReply(a, "{\"type\":\"error\",\"error_type\":\"auth_error\",\"description\":\"pam_authenticate: AUTH_ERR\"}");
    defer bad.deinit();
    try std.testing.expectEqualStrings("auth_error", bad.value.error_type.?);
}

extern fn socketpair(domain: c_int, kind: c_int, protocol: c_int, fds: *[2]c_int) c_int;

test "framing over a socket pair" {
    const a = std.testing.allocator;
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), socketpair(1, 1, 0, &fds));
    const client: Connection = .{ .fd = fds[0] };
    const server: Connection = .{ .fd = fds[1] };
    defer client.deinit();
    defer server.deinit();

    const request = try createSession(a, "dakota");
    defer a.free(request);
    try client.send(request);
    const got = try server.receive(a);
    defer a.free(got);
    try std.testing.expectEqualStrings(request, got);

    try server.send("{\"type\":\"success\"}");
    const reply = try client.receive(a);
    defer a.free(reply);
    var parsed = try parseReply(a, reply);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("success", parsed.value.type);
}
