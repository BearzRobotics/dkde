//! dkde-notify: sends a desktop notification from a script or a hook
//! (SPEC.md 5.1), like notify-send but with nothing to install. It speaks to
//! whatever notification daemon owns the session bus: the panel's own, or
//! another.
//!
//!     dkde-notify [-i ICON] [-t MILLISECONDS] SUMMARY [BODY]
//!
//! The text is shown as given; it is never read as markup or as a command.

const std = @import("std");
const common = @import("common");

pub const std_options: std.Options = .{ .logFn = common.log.logFn, .log_level = .debug };

const usage =
    \\usage: dkde-notify [-i ICON] [-t MILLISECONDS] SUMMARY [BODY]
    \\  -i ICON   an icon name such as drive-removable-media, or a file path
    \\  -t MS     how long it stays: -1 (default) lets the notification daemon decide,
    \\            0 keeps it until it is dismissed
    \\
;

pub const Parsed = struct {
    summary: []const u8,
    body: []const u8 = "",
    icon: []const u8 = "dialog-information",
    timeout: i32 = -1,
};

pub const ParseError = error{ Usage, BadTimeout };

/// Reads the command line (without the program name). Options come before the
/// text; `--` ends them, so a summary that starts with a dash can be sent.
pub fn parse(args: []const []const u8) ParseError!Parsed {
    var out: Parsed = .{ .summary = "" };
    var i: usize = 0;
    var texts: [2][]const u8 = .{ "", "" };
    var n: usize = 0;
    var options = true;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (options and std.mem.eql(u8, a, "--")) {
            options = false;
            continue;
        }
        if (options and std.mem.eql(u8, a, "-i")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            out.icon = args[i];
            continue;
        }
        if (options and std.mem.eql(u8, a, "-t")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            out.timeout = std.fmt.parseInt(i32, args[i], 10) catch return error.BadTimeout;
            if (out.timeout < -1) return error.BadTimeout;
            continue;
        }
        if (options and a.len > 1 and a[0] == '-') return error.Usage;
        if (n >= texts.len) return error.Usage;
        texts[n] = a;
        n += 1;
    }
    if (n == 0 or texts[0].len == 0) return error.Usage;
    out.summary = texts[0];
    out.body = texts[1];
    return out;
}

pub fn main(init: std.process.Init.Minimal) !void {
    const allocator = std.heap.c_allocator;
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    for (init.args.vector[1..]) |a| try args.append(allocator, std.mem.span(a));

    const parsed = parse(args.items) catch |err| {
        if (err == error.BadTimeout) std.log.err("-t takes a number of milliseconds: -1, 0 or more", .{});
        _ = std.c.write(2, usage.ptr, usage.len);
        std.process.exit(2);
    };
    const summary = try allocator.dupeSentinel(u8, parsed.summary, 0);
    const body = try allocator.dupeSentinel(u8, parsed.body, 0);
    const icon = try allocator.dupeSentinel(u8, parsed.icon, 0);
    common.notify.sendTimed(summary, body, icon, parsed.timeout);
}

test "summary and body" {
    const p = try parse(&.{ "Drive mounted", "/dev/sdd1" });
    try std.testing.expectEqualStrings("Drive mounted", p.summary);
    try std.testing.expectEqualStrings("/dev/sdd1", p.body);
    try std.testing.expectEqual(@as(i32, -1), p.timeout);
}

test "options" {
    const p = try parse(&.{ "-i", "drive-removable-media", "-t", "0", "Title" });
    try std.testing.expectEqualStrings("drive-removable-media", p.icon);
    try std.testing.expectEqual(@as(i32, 0), p.timeout);
    try std.testing.expectEqualStrings("Title", p.summary);
    try std.testing.expectEqualStrings("", p.body);
}

test "a summary that starts with a dash after --" {
    const p = try parse(&.{ "--", "-5 degrees" });
    try std.testing.expectEqualStrings("-5 degrees", p.summary);
}

test "wrong use" {
    try std.testing.expectError(error.Usage, parse(&.{}));
    try std.testing.expectError(error.Usage, parse(&.{ "a", "b", "c" }));
    try std.testing.expectError(error.Usage, parse(&.{ "-x", "a" }));
    try std.testing.expectError(error.Usage, parse(&.{"-i"}));
    try std.testing.expectError(error.BadTimeout, parse(&.{ "-t", "soon", "a" }));
    try std.testing.expectError(error.BadTimeout, parse(&.{ "-t", "-5", "a" }));
    try std.testing.expectError(error.Usage, parse(&.{""}));
}
