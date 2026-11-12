//! Which service manager runs the system and the user's session, and what
//! dinit says about its services. systemd is asked through systemctl and
//! journalctl; dinit (Chimera Linux and others) through dinitctl and its
//! service directories.

const std = @import("std");
const glib = @import("glib2");
const gio = @import("gio2");
const gobject = @import("gobject2");

pub const Init = enum { systemd, dinit, none };

/// What PID 1 is.
pub fn systemInit() Init {
    var buf: [32]u8 = undefined;
    const comm = readSmall("/proc/1/comm", &buf) orelse return .none;
    if (std.mem.eql(u8, comm, "systemd")) return .systemd;
    if (std.mem.eql(u8, comm, "dinit")) return .dinit;
    // An init that is not one of these: look for the tools.
    return .none;
}

/// The user's own service manager, if one runs: systemd's user instance,
/// or a dinit user instance (turnstile on Chimera starts one per login).
pub fn userInit() Init {
    const runtime = std.mem.span(glib.getUserRuntimeDir());
    var pb: [512]u8 = undefined;
    if (systemInit() == .systemd) {
        const p = std.fmt.bufPrintSentinel(&pb, "{s}/systemd/private", .{runtime}, 0) catch return .none;
        if (glib.fileTest(p, .{ .exists = true }) != 0) return .systemd;
    }
    const socket = std.fmt.bufPrintSentinel(&pb, "{s}/dinitctl", .{runtime}, 0) catch return .none;
    if (glib.fileTest(socket, .{ .exists = true }) != 0) return .dinit;
    const home = std.fmt.bufPrintSentinel(&pb, "{s}/.dinitctl", .{std.mem.span(glib.getHomeDir())}, 0) catch return .none;
    if (glib.fileTest(home, .{ .exists = true }) != 0) return .dinit;
    return .none;
}

fn readSmall(path: [:0]const u8, buf: []u8) ?[]const u8 {
    var contents: [*]u8 = undefined;
    var length: usize = 0;
    if (glib.fileGetContents(path, &contents, &length, null) == 0) return null;
    defer glib.free(contents);
    const n = @min(length, buf.len);
    @memcpy(buf[0..n], contents[0..n]);
    return std.mem.trim(u8, buf[0..n], " \n");
}

// ---- dinit -------------------------------------------------------------------

pub const DinitState = enum { started, stopped, starting, stopping, failed };

pub const DinitLine = struct {
    name: []const u8,
    state: DinitState,
    pid: u32 = 0,
};

/// One line of `dinitctl list`: "[{+}     ] sshd (pid: 412)". Inside the
/// brackets: {+} started, << starting, >> stopping, {-} stopped, X failed;
/// the braces mark the state wanted.
pub fn parseDinitLine(line: []const u8) ?DinitLine {
    const open = std.mem.indexOfScalar(u8, line, '[') orelse return null;
    const close = std.mem.indexOfScalarPos(u8, line, open, ']') orelse return null;
    const marks = line[open + 1 .. close];
    var rest = std.mem.trim(u8, line[close + 1 ..], " ");
    const name_end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    const name = rest[0..name_end];
    if (name.len == 0) return null;
    rest = rest[name_end..];
    const state: DinitState = if (std.mem.indexOf(u8, marks, "<<") != null)
        .starting
    else if (std.mem.indexOf(u8, marks, ">>") != null)
        .stopping
    else if (std.mem.indexOfScalar(u8, marks, '+') != null)
        .started
    else if (std.mem.indexOfScalar(u8, marks, 'X') != null)
        .failed
    else
        .stopped;
    var pid: u32 = 0;
    if (std.mem.indexOf(u8, rest, "(pid: ")) |i| {
        const digits = rest[i + "(pid: ".len ..];
        const end = std.mem.indexOfScalar(u8, digits, ')') orelse digits.len;
        pid = std.fmt.parseInt(u32, digits[0..end], 10) catch 0;
    }
    return .{ .name = name, .state = state, .pid = pid };
}

/// Where dinit looks for service files, the first one winning.
pub fn dinitDirs(user: bool, buf: *[6][256]u8, out: *[6][]const u8) []const []const u8 {
    const system = [_][]const u8{ "/etc/dinit.d", "/run/dinit.d", "/usr/local/lib/dinit.d", "/lib/dinit.d", "/usr/lib/dinit.d" };
    const users = [_][]const u8{ "/etc/dinit.d/user", "/usr/local/lib/dinit.d/user", "/usr/lib/dinit.d/user" };
    var n: usize = 0;
    if (user) {
        out[0] = std.fmt.bufPrint(&buf[0], "{s}/dinit.d", .{std.mem.span(glib.getUserConfigDir())}) catch "";
        n = 1;
        for (users) |d| {
            out[n] = d;
            n += 1;
        }
    } else for (system) |d| {
        out[n] = d;
        n += 1;
    }
    return out[0..n];
}

/// What a dinit service file says of itself.
pub const DinitFile = struct {
    description: [160]u8 = @splat(0),
    logfile: [256]u8 = @splat(0),
    kind: [16]u8 = @splat(0),
};

/// The first comment line (Chimera's files begin with what the service
/// is), `type` and `logfile`.
pub fn parseDinitFile(text: []const u8) DinitFile {
    var f: DinitFile = .{};
    var described = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') {
            const c = std.mem.trim(u8, line[1..], " \t");
            if (!described and c.len > 0) {
                described = true;
                setStr(&f.description, c);
            }
            continue;
        }
        described = true; // only a comment before the settings describes it
        const eq = std.mem.indexOfAny(u8, line, "=:") orelse continue;
        const k = std.mem.trim(u8, line[0..eq], " \t");
        const v = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, k, "type")) setStr(&f.kind, v);
        if (std.mem.eql(u8, k, "logfile")) setStr(&f.logfile, v);
    }
    return f;
}

fn setStr(field: anytype, value: []const u8) void {
    @memset(field, 0);
    const n = @min(value.len, field.len - 1);
    @memcpy(field[0..n], value[0..n]);
}

/// Whether `name` starts at boot (system) or login (user): `dinitctl
/// enable` links it into the boot service's waits-for directory, boot.d.
pub fn dinitEnabled(user: bool, name: []const u8) bool {
    var db: [6][256]u8 = undefined;
    var ds: [6][]const u8 = undefined;
    for (dinitDirs(user, &db, &ds)) |dir| {
        var pb: [512]u8 = undefined;
        const p = std.fmt.bufPrintSentinel(&pb, "{s}/boot.d/{s}", .{ dir, name }, 0) catch continue;
        if (glib.fileTest(p, .{ .exists = true }) != 0 or glib.fileTest(p, .{ .is_symlink = true }) != 0) return true;
    }
    return false;
}

/// Calls `found(ctx, name, path)` for each service file (the first of a name).
pub fn eachDinitFile(gpa: std.mem.Allocator, user: bool, ctx: anytype, comptime found: fn (@TypeOf(ctx), []const u8, [:0]const u8) void) void {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        seen.deinit(gpa);
    }
    var db: [6][256]u8 = undefined;
    var ds: [6][]const u8 = undefined;
    for (dinitDirs(user, &db, &ds)) |dir| {
        var zb: [256]u8 = undefined;
        const zdir = std.fmt.bufPrintSentinel(&zb, "{s}", .{dir}, 0) catch continue;
        const file = gio.File.newForPath(zdir);
        defer file.as(gobject.Object).unref();
        const children = file.enumerateChildren("standard::name,standard::type", .{}, null, null) orelse continue;
        defer children.as(gobject.Object).unref();
        while (children.nextFile(null, null)) |info| {
            defer info.as(gobject.Object).unref();
            if (info.getFileType() != .regular) continue;
            const name = std.mem.span(info.getName());
            if (name.len == 0 or name[0] == '.' or name[name.len - 1] == '~') continue;
            if (seen.contains(name)) continue;
            const owned = gpa.dupe(u8, name) catch continue;
            seen.put(gpa, owned, {}) catch {
                gpa.free(owned);
                continue;
            };
            var pb: [512]u8 = undefined;
            const path = std.fmt.bufPrintSentinel(&pb, "{s}/{s}", .{ dir, name }, 0) catch continue;
            found(ctx, name, path);
        }
    }
}

test "dinitctl list lines" {
    const a = parseDinitLine("[{+}     ] sshd (pid: 412)").?;
    try std.testing.expectEqualStrings("sshd", a.name);
    try std.testing.expectEqual(DinitState.started, a.state);
    try std.testing.expectEqual(@as(u32, 412), a.pid);
    const b = parseDinitLine("[     {-}] cups").?;
    try std.testing.expectEqual(DinitState.stopped, b.state);
    const c = parseDinitLine("[     {X}] broken (exit status: 1)").?;
    try std.testing.expectEqual(DinitState.failed, c.state);
    try std.testing.expectEqualStrings("broken", c.name);
    const d = parseDinitLine("[{ }<<   ] network").?;
    try std.testing.expectEqual(DinitState.starting, d.state);
    try std.testing.expect(parseDinitLine("garbage") == null);
}

test "dinit service files" {
    const f = parseDinitFile("# OpenSSH daemon\n\ntype = process\ncommand = /usr/bin/sshd -D\nlogfile = /var/log/sshd.log\n# not this\n");
    try std.testing.expectEqualStrings("OpenSSH daemon", std.mem.sliceTo(&f.description, 0));
    try std.testing.expectEqualStrings("process", std.mem.sliceTo(&f.kind, 0));
    try std.testing.expectEqualStrings("/var/log/sshd.log", std.mem.sliceTo(&f.logfile, 0));
    const g = parseDinitFile("type: scripted\n# late comment\n");
    try std.testing.expectEqual(@as(u8, 0), g.description[0]);
}
