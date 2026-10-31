//! Panel IPC (SPEC.md 4.1): a Unix socket at `$XDG_RUNTIME_DIR/dkde/panel.sock`
//! speaking one line of text per command. The reply is one line too.

const std = @import("std");
const gio = @import("gio2");
const giounix = @import("giounix2");
const glib = @import("glib2");
const gobject = @import("gobject2");

const log = std.log.scoped(.ipc);

pub const Handler = *const fn (data: *anyopaque, command: []const u8) []const u8;

fn socketPath(allocator: std.mem.Allocator) ![:0]u8 {
    return std.fmt.allocPrintSentinel(allocator, "{s}/dkde/panel.sock", .{std.mem.span(glib.getUserRuntimeDir())}, 0);
}

pub const Server = struct {
    allocator: std.mem.Allocator,
    listener: *gio.SocketListener,
    path: [:0]u8,
    handler: Handler,
    data: *anyopaque,

    pub fn start(allocator: std.mem.Allocator, handler: Handler, data: *anyopaque) !*Server {
        const path = try socketPath(allocator);
        errdefer allocator.free(path);

        const dir = glib.pathGetDirname(path);
        defer glib.free(dir);
        _ = glib.mkdirWithParents(dir, 0o700);
        // A socket left behind by a crashed panel would make bind fail.
        _ = glib.unlink(path);

        const listener = gio.SocketListener.new();
        errdefer listener.as(gobject.Object).unref();
        const address = gio.UnixSocketAddress.new(path);
        defer address.as(gobject.Object).unref();
        var err: ?*glib.Error = null;
        if (listener.addAddress(address.as(gio.SocketAddress), .stream, .default, null, null, &err) == 0) {
            log.err("cannot listen on {s}: {s}", .{ path, if (err) |e| e.f_message orelse "unknown" else "unknown" });
            if (err) |e| e.free();
            return error.ListenFailed;
        }

        const self = try allocator.create(Server);
        self.* = .{ .allocator = allocator, .listener = listener, .path = path, .handler = handler, .data = data };
        self.accept();
        return self;
    }

    pub fn stop(self: *Server) void {
        self.listener.close();
        _ = glib.unlink(self.path);
        self.listener.as(gobject.Object).unref();
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }

    fn accept(self: *Server) void {
        self.listener.acceptAsync(null, onAccept, self);
    }

    fn onAccept(_: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Server = @ptrCast(@alignCast(data.?));
        var err: ?*glib.Error = null;
        const conn = self.listener.acceptFinish(result, null, &err) orelse {
            // Cancelled on shutdown: do not re-arm.
            if (err) |e| e.free();
            return;
        };
        self.accept();

        const input = gio.DataInputStream.new(conn.as(gio.IOStream).getInputStream());
        const pending = self.allocator.create(Pending) catch {
            conn.as(gobject.Object).unref();
            input.as(gobject.Object).unref();
            return;
        };
        pending.* = .{ .server = self, .conn = conn, .input = input };
        input.readLineAsync(glib.PRIORITY_DEFAULT, null, onLine, pending);
    }

    const Pending = struct {
        server: *Server,
        conn: *gio.SocketConnection,
        input: *gio.DataInputStream,
    };

    fn onLine(_: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const pending: *Pending = @ptrCast(@alignCast(data.?));
        const server = pending.server;
        defer {
            _ = pending.conn.as(gio.IOStream).close(null, null);
            pending.input.as(gobject.Object).unref();
            pending.conn.as(gobject.Object).unref();
            server.allocator.destroy(pending);
        }

        var length: usize = 0;
        var err: ?*glib.Error = null;
        const line = pending.input.readLineFinish(result, &length, &err) orelse {
            if (err) |e| e.free();
            return;
        };
        defer glib.free(line);

        const command = std.mem.trim(u8, line[0..length], " \t\r");
        const reply = server.handler(server.data, command);

        var buf: [128]u8 = undefined;
        const out = std.fmt.bufPrint(&buf, "{s}\n", .{reply}) catch return;
        _ = pending.conn.as(gio.IOStream).getOutputStream().writeAll(out.ptr, out.len, null, null, null);
    }
};

/// `dkde-panel msg <command>`: sends `command` to the running panel and
/// returns its one-line reply (caller frees).
pub fn send(allocator: std.mem.Allocator, command: []const u8) ![]u8 {
    const path = try socketPath(allocator);
    defer allocator.free(path);

    const client = gio.SocketClient.new();
    defer client.as(gobject.Object).unref();
    const address = gio.UnixSocketAddress.new(path);
    defer address.as(gobject.Object).unref();

    var err: ?*glib.Error = null;
    const conn = client.connect(address.as(gio.SocketConnectable), null, &err) orelse {
        if (err) |e| e.free();
        return error.PanelNotRunning;
    };
    defer conn.as(gobject.Object).unref();

    const line = try std.fmt.allocPrint(allocator, "{s}\n", .{command});
    defer allocator.free(line);
    if (conn.as(gio.IOStream).getOutputStream().writeAll(line.ptr, line.len, null, null, &err) == 0) {
        if (err) |e| e.free();
        return error.WriteFailed;
    }

    const input = gio.DataInputStream.new(conn.as(gio.IOStream).getInputStream());
    defer input.as(gobject.Object).unref();
    var length: usize = 0;
    const reply = input.readLine(&length, null, &err) orelse {
        if (err) |e| e.free();
        return error.NoReply;
    };
    defer glib.free(reply);
    return allocator.dupe(u8, reply[0..length]);
}
