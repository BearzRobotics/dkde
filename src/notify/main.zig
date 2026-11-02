//! dkde-notify: sends a desktop notification from a script or a hook
//! (SPEC.md 5.1), like notify-send but with nothing to install. It speaks to
//! whatever notification daemon owns the session bus: the panel's own, or
//! another.
//!
//!     dkde-notify [-i ICON] [-t MILLISECONDS] SUMMARY [BODY]
//!     dkde-notify --mounted|--unmounted|--removed DEVICE
//!
//! The second form is for an automounter's hooks: it is given only the device
//! node (`/dev/sdd1`) and looks up the label and mount point itself, so no
//! text chosen by whoever made the drive ever passes through a shell.
//!
//! The text is shown as given; it is never read as markup or as a command.

const std = @import("std");
const glib = @import("glib2");
const gio = @import("gio2");
const gobject = @import("gobject2");
const common = @import("common");

const mounts = @import("mounts.zig");

pub const std_options: std.Options = .{ .logFn = common.log.logFn, .log_level = .debug };

const usage =
    \\usage: dkde-notify [-i ICON] [-t MILLISECONDS] SUMMARY [BODY]
    \\       dkde-notify --mounted|--unmounted|--removed DEVICE
    \\  -i ICON   an icon name such as drive-removable-media, or a file path
    \\  -t MS     how long it stays: -1 (default) lets the notification daemon decide,
    \\            0 keeps it until it is dismissed
    \\  --mounted DEVICE    "Drive mounted": its label and where it is mounted
    \\  --unmounted DEVICE  "Drive unmounted": it is safe to remove
    \\  --removed DEVICE    "Drive removed"
    \\
;

pub const Drive = enum { mounted, unmounted, removed };

pub const Parsed = struct {
    /// Set for the drive forms; `summary` and `body` are then unused.
    drive: ?Drive = null,
    device: []const u8 = "",
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
        if (options and (std.mem.eql(u8, a, "--mounted") or std.mem.eql(u8, a, "--unmounted") or std.mem.eql(u8, a, "--removed"))) {
            i += 1;
            if (i >= args.len or !mounts.validDevice(args[i]) or out.drive != null) return error.Usage;
            out.drive = if (std.mem.eql(u8, a, "--mounted")) .mounted else if (std.mem.eql(u8, a, "--unmounted")) .unmounted else .removed;
            out.device = args[i];
            continue;
        }
        if (options and a.len > 1 and a[0] == '-') return error.Usage;
        if (n >= texts.len) return error.Usage;
        texts[n] = a;
        n += 1;
    }
    // A drive form takes no text; the text forms need a summary.
    if (out.drive != null) {
        if (n != 0) return error.Usage;
        return out;
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
    if (parsed.drive) |drive| return sendDrive(allocator, drive, parsed.device, parsed.timeout);
    const summary = try allocator.dupeSentinel(u8, parsed.summary, 0);
    const body = try allocator.dupeSentinel(u8, parsed.body, 0);
    const icon = try allocator.dupeSentinel(u8, parsed.icon, 0);
    common.notify.sendTimed(summary, body, icon, parsed.timeout);
}

/// The label of a device, from the by-label links udev keeps. Shown only.
fn labelOf(allocator: std.mem.Allocator, device: []const u8, out: []u8) ?[]const u8 {
    const dir = gio.File.newForPath("/dev/disk/by-label");
    defer dir.as(gobject.Object).unref();
    const children = dir.enumerateChildren("standard::name,standard::symlink-target", .{}, null, null) orelse return null;
    defer children.as(gobject.Object).unref();
    var entries: std.ArrayList(mounts.LabelEntry) = .empty;
    defer {
        for (entries.items) |e| {
            allocator.free(e.name);
            allocator.free(e.target);
        }
        entries.deinit(allocator);
    }
    while (children.nextFile(null, null)) |info| {
        defer info.as(gobject.Object).unref();
        const target = info.getSymlinkTarget() orelse continue;
        const name = allocator.dupe(u8, std.mem.span(info.getName())) catch continue;
        const t = allocator.dupe(u8, std.mem.span(target)) catch {
            allocator.free(name);
            continue;
        };
        entries.append(allocator, .{ .name = name, .target = t }) catch {
            allocator.free(name);
            allocator.free(t);
        };
    }
    return mounts.findLabel(entries.items, mounts.baseName(device), out);
}

fn sendDrive(allocator: std.mem.Allocator, drive: Drive, device: []const u8, timeout: i32) !void {
    var label_buf: [128]u8 = undefined;
    var safe_buf: [128]u8 = undefined;
    const raw_label = labelOf(allocator, device, &label_buf);
    const label = if (raw_label) |l| mounts.sanitize(l, &safe_buf) else "";
    const name = if (label.len > 0) label else device;

    var body_buf: [512]u8 = undefined;
    var summary: [:0]const u8 = "Drive mounted";
    var body: []const u8 = device;
    switch (drive) {
        .mounted => {
            var content: [*]u8 = undefined;
            var length: usize = 0;
            if (glib.fileGetContents("/proc/self/mounts", &content, &length, null) != 0) {
                defer glib.free(content);
                var point_buf: [256]u8 = undefined;
                var point_safe: [256]u8 = undefined;
                if (mounts.findMountPoint(content[0..length], device, &point_buf)) |p| {
                    body = std.fmt.bufPrint(&body_buf, "{s} is at {s}", .{ name, mounts.sanitize(p, &point_safe) }) catch device;
                } else body = name;
            } else body = name;
        },
        .unmounted => {
            summary = "Drive unmounted";
            body = std.fmt.bufPrint(&body_buf, "{s} can be removed safely", .{name}) catch device;
        },
        .removed => summary = "Drive removed",
    }
    const z = try allocator.dupeSentinel(u8, body, 0);
    common.notify.sendTimed(summary, z, "drive-removable-media", timeout);
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

test "the drive forms" {
    const p = try parse(&.{ "--mounted", "/dev/sdd1" });
    try std.testing.expectEqual(Drive.mounted, p.drive.?);
    try std.testing.expectEqualStrings("/dev/sdd1", p.device);
    try std.testing.expectEqual(Drive.removed, (try parse(&.{ "-t", "0", "--removed", "/dev/sdd1" })).drive.?);
    // Only a device node: not a path elsewhere, not text, not two forms at once.
    try std.testing.expectError(error.Usage, parse(&.{ "--mounted", "/etc/passwd" }));
    try std.testing.expectError(error.Usage, parse(&.{ "--mounted", "sdd1" }));
    try std.testing.expectError(error.Usage, parse(&.{"--mounted"}));
    try std.testing.expectError(error.Usage, parse(&.{ "--mounted", "/dev/sdd1", "also text" }));
    try std.testing.expectError(error.Usage, parse(&.{ "--mounted", "/dev/sdd1", "--removed", "/dev/sdd1" }));
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

test {
    _ = mounts;
}
