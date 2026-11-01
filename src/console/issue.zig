//! `/etc/issue` with agetty's backslash escapes (SPEC.md 5.11, *Process
//! model*). The console prints this before it starts `login`.

const std = @import("std");

/// What the escapes stand for. `System.read` fills it from the running system;
/// tests build it by hand.
pub const System = struct {
    sysname: []const u8 = "Linux",
    nodename: []const u8 = "localhost",
    release: []const u8 = "",
    version: []const u8 = "",
    machine: []const u8 = "",
    /// The line, `tty1` style, without `/dev/`.
    line: []const u8 = "tty1",
    /// `\d` and `\t`, already formatted by the caller.
    date: []const u8 = "",
    time: []const u8 = "",
    users: u32 = 0,
};

const Utsname = extern struct {
    sysname: [65]u8,
    nodename: [65]u8,
    release: [65]u8,
    version: [65]u8,
    machine: [65]u8,
    domainname: [65]u8,
};
extern fn uname(buf: *Utsname) c_int;

/// Backing storage for the slices in a `System` made by `read`.
pub const Uts = struct {
    raw: Utsname = undefined,

    pub fn system(self: *Uts, line: []const u8) System {
        if (uname(&self.raw) != 0) return .{ .line = line };
        const s = struct {
            fn z(a: *const [65]u8) []const u8 {
                return std.mem.sliceTo(a, 0);
            }
        }.z;
        return .{
            .sysname = s(&self.raw.sysname),
            .nodename = s(&self.raw.nodename),
            .release = s(&self.raw.release),
            .version = s(&self.raw.version),
            .machine = s(&self.raw.machine),
            .line = line,
        };
    }
};

/// Expand `text` into `out`. Unknown escapes are copied as written, as
/// agetty does. Newlines become CR LF because the console's pty is in raw
/// output mode until `login` takes over.
pub fn expand(out: *std.Io.Writer, text: []const u8, sys: System) !void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '\n') {
            try out.writeAll("\r\n");
            continue;
        }
        if (c != '\\' or i + 1 >= text.len) {
            try out.writeByte(c);
            continue;
        }
        i += 1;
        switch (text[i]) {
            'n' => try out.writeAll(sys.nodename),
            'l' => try out.writeAll(sys.line),
            's' => try out.writeAll(sys.sysname),
            'r' => try out.writeAll(sys.release),
            'm' => try out.writeAll(sys.machine),
            'v' => try out.writeAll(sys.version),
            'd' => try out.writeAll(sys.date),
            't' => try out.writeAll(sys.time),
            'e' => try out.writeByte(0x1b),
            'u' => try out.print("{d}", .{sys.users}),
            'U' => try out.print("{d} user{s}", .{ sys.users, if (sys.users == 1) "" else "s" }),
            '\\' => try out.writeByte('\\'),
            else => |other| {
                try out.writeByte('\\');
                try out.writeByte(other);
            },
        }
    }
}

fn run(text: []const u8, sys: System) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer aw.deinit();
    try expand(&aw.writer, text, sys);
    return aw.toOwnedSlice();
}

test "escapes" {
    const sys: System = .{ .nodename = "dk", .release = "6.1", .machine = "x86_64", .line = "tty2", .users = 1 };
    const out = try run("Welcome to \\n (\\s \\r \\m) on \\l\nbye \\q \\\\ \\U", sys);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("Welcome to dk (Linux 6.1 x86_64) on tty2\r\nbye \\q \\ 1 user", out);
}

test "newlines get a carriage return and a lone trailing backslash is kept" {
    const out = try run("a\nb\\", .{});
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("a\r\nb\\", out);
}
