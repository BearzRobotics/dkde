//! AppArmor and SELinux, as the Security page of the task manager shows them:
//! which one is active, the profiles or booleans, and the recent denials
//! told in plain words. This file only parses text (aa-status --json, kernel
//! audit lines, getsebool) so it can be tested; the page runs the tools.

const std = @import("std");

pub const Kind = enum { none, apparmor, selinux };

/// The kernel's own switches, read from `/sys`: pass what those files contain (null when missing).
pub fn detect(apparmor_enabled: ?[]const u8, selinux_enforce: ?[]const u8) Kind {
    if (selinux_enforce != null) return .selinux;
    if (apparmor_enabled) |v| if (v.len > 0 and (v[0] == 'Y' or v[0] == 'y')) return .apparmor;
    return .none;
}

pub const Mode = enum {
    enforce,
    complain,
    kill,
    prompt,
    unconfined,
    other,

    pub fn fromName(name: []const u8) Mode {
        inline for (.{ .{ "enforce", Mode.enforce }, .{ "complain", Mode.complain }, .{ "kill", Mode.kill }, .{ "prompt", Mode.prompt }, .{ "unconfined", Mode.unconfined } }) |p| {
            if (std.mem.eql(u8, name, p[0])) return p[1];
        }
        return .other;
    }

    pub fn label(self: Mode) []const u8 {
        return switch (self) {
            .enforce => "Enforcing",
            .complain => "Complaining (logs only)",
            .kill => "Enforcing (kills)",
            .prompt => "Prompting",
            .unconfined => "Unconfined",
            .other => "Other",
        };
    }
};

pub const Profile = struct {
    name: []const u8,
    mode: Mode,
    /// Processes running under it.
    processes: u32 = 0,
};

/// `aa-status --json`: {"profiles": {"name": "enforce", ...}, "processes": {"/exe": [{"profile": "name", ...}]}}.
/// The profiles are copied into `arena`.
pub fn parseAaStatus(arena: std.mem.Allocator, text: []const u8) ![]Profile {
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, text, .{});
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.BadFormat,
    };
    var list: std.ArrayList(Profile) = .empty;
    const profiles = switch (root.get("profiles") orelse return error.BadFormat) {
        .object => |o| o,
        else => return error.BadFormat,
    };
    var it = profiles.iterator();
    while (it.next()) |e| {
        const mode_name = switch (e.value_ptr.*) {
            .string => |s| s,
            else => "other",
        };
        try list.append(arena, .{ .name = e.key_ptr.*, .mode = Mode.fromName(mode_name) });
    }
    // Count the processes of each profile.
    if (root.get("processes")) |procs| if (procs == .object) {
        var pit = procs.object.iterator();
        while (pit.next()) |e| {
            if (e.value_ptr.* != .array) continue;
            for (e.value_ptr.array.items) |item| {
                if (item != .object) continue;
                const name = switch (item.object.get("profile") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                for (list.items) |*p| if (std.mem.eql(u8, p.name, name)) {
                    p.processes += 1;
                };
            }
        }
    };
    std.mem.sort(Profile, list.items, {}, struct {
        fn less(_: void, a: Profile, b: Profile) bool {
            return std.ascii.lessThanIgnoreCase(a.name, b.name);
        }
    }.less);
    return list.toOwnedSlice(arena);
}

pub const Boolean = struct { name: []const u8, on: bool };

/// `getsebool -a`: "allow_httpd_anon_write --> off".
pub fn parseBooleans(arena: std.mem.Allocator, text: []const u8) ![]Boolean {
    var list: std.ArrayList(Boolean) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const arrow = std.mem.indexOf(u8, line, " --> ") orelse continue;
        const value = std.mem.trim(u8, line[arrow + 5 ..], " ");
        try list.append(arena, .{ .name = line[0..arrow], .on = std.mem.eql(u8, value, "on") });
    }
    return list.toOwnedSlice(arena);
}

pub const Denial = struct {
    /// "2026-11-15 12:30", or empty.
    time: []const u8 = "",
    /// The program (comm) that was refused, or the profile / domain when that is all there is.
    who: []const u8 = "",
    /// The AppArmor profile or the SELinux domain (type) it ran as.
    confinement: []const u8 = "",
    /// What it tried, in words: "read", "write to", "run", "use the net_admin capability".
    action: []const u8 = "",
    /// The file, socket or object.
    target: []const u8 = "",
    /// SELinux object class or AppArmor class ("file", "capability", "net").
    class: []const u8 = "",
    /// Only logged: complain / permissive mode, so nothing was actually refused.
    only_logged: bool = false,
    count: u32 = 1,
};

/// The value of `key=` in an audit line: quoted ("...") or bare (up to a space).
fn field(line: []const u8, key: []const u8) ?[]const u8 {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, line, from, key)) |at| {
        from = at + key.len;
        // The key must start a word and be followed by '='.
        if (at > 0 and line[at - 1] != ' ' and line[at - 1] != '{' and line[at - 1] != '(') continue;
        if (from >= line.len or line[from] != '=') continue;
        const rest = line[from + 1 ..];
        if (rest.len == 0) return null;
        if (rest[0] == '"') {
            const end = std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse return null;
            return rest[1..end];
        }
        const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        return rest[0..end];
    }
    return null;
}

/// "2026-11-15T12:30:44-0500 host kernel: ..." (journalctl -o short-iso) to "2026-11-15 12:30".
fn leadingTime(line: []const u8, buf: []u8) []const u8 {
    if (line.len < 16 or line[4] != '-' or line[10] != 'T') return "";
    @memcpy(buf[0..10], line[0..10]);
    buf[10] = ' ';
    @memcpy(buf[11..16], line[11..16]);
    return buf[0..16];
}

fn maskWords(mask: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    const words = [_]struct { c: u8, w: []const u8 }{ .{ .c = 'r', .w = "read" }, .{ .c = 'w', .w = "write" }, .{ .c = 'a', .w = "append" }, .{ .c = 'x', .w = "execute" }, .{ .c = 'c', .w = "create" }, .{ .c = 'd', .w = "delete" }, .{ .c = 'k', .w = "lock" }, .{ .c = 'l', .w = "link" }, .{ .c = 'm', .w = "map" } };
    for (words) |w| {
        if (std.mem.indexOfScalar(u8, mask, w.c) == null) continue;
        const sep: []const u8 = if (n == 0) "" else ", ";
        const piece = std.fmt.bufPrint(buf[n..], "{s}{s}", .{ sep, w.w }) catch break;
        n += piece.len;
    }
    return buf[0..n];
}

/// One AppArmor audit line: `apparmor="DENIED" operation="open" profile="x" name="/etc/y" comm="z" requested_mask="r"`.
/// Strings point into `line`, except the action, which is written into `buf`.
pub fn parseAppArmor(line: []const u8, buf: []u8, time_buf: []u8) ?Denial {
    const verdict = field(line, "apparmor") orelse return null;
    const denied = std.mem.eql(u8, verdict, "DENIED");
    const allowed = std.mem.eql(u8, verdict, "ALLOWED");
    if (!denied and !allowed) return null;
    var d: Denial = .{ .time = leadingTime(line, time_buf), .only_logged = allowed };
    d.confinement = field(line, "profile") orelse "";
    d.who = field(line, "comm") orelse d.confinement;
    d.class = field(line, "class") orelse "";
    d.target = field(line, "name") orelse field(line, "name2") orelse field(line, "addr") orelse "";
    // A network refusal names no file: say which kind of connection it was.
    if (d.target.len == 0) if (field(line, "family")) |fam| {
        d.target = fam;
    };
    const op = field(line, "operation") orelse "access";
    if (field(line, "capname")) |cap| {
        d.action = std.fmt.bufPrint(buf, "use the {s} capability", .{cap}) catch return d;
        return d;
    }
    const mask = field(line, "requested_mask") orelse field(line, "denied_mask") orelse "";
    if (std.mem.eql(u8, op, "exec")) {
        d.action = "run";
    } else if (std.mem.eql(u8, op, "connect")) {
        d.action = "connect to";
    } else if (std.mem.eql(u8, op, "ptrace")) {
        d.action = "trace";
    } else if (std.mem.eql(u8, op, "signal")) {
        d.action = "send a signal to";
    } else if (std.mem.eql(u8, op, "mount") or std.mem.eql(u8, op, "umount")) {
        d.action = op;
    } else if (mask.len > 0) {
        const w = maskWords(mask, buf);
        d.action = if (w.len > 0) w else op;
    } else d.action = op;
    return d;
}

/// One SELinux AVC line: `avc:  denied  { read write } for  pid=1 comm="httpd" name="x" scontext=u:r:httpd_t:s0 tcontext=u:object_r:user_home_t:s0 tclass=file permissive=0`.
pub fn parseAvc(line: []const u8, buf: []u8, time_buf: []u8) ?Denial {
    const at = std.mem.indexOf(u8, line, "avc:") orelse return null;
    const rest = line[at..];
    if (std.mem.indexOf(u8, rest, "denied") == null) return null;
    const open = std.mem.indexOfScalar(u8, rest, '{') orelse return null;
    const close = std.mem.indexOfScalarPos(u8, rest, open, '}') orelse return null;
    const perms = std.mem.trim(u8, rest[open + 1 .. close], " ");
    var d: Denial = .{ .time = leadingTime(line, time_buf) };
    d.only_logged = if (field(rest, "permissive")) |p| std.mem.eql(u8, p, "1") else false;
    d.class = field(rest, "tclass") orelse "";
    d.who = field(rest, "comm") orelse "";
    d.target = field(rest, "name") orelse field(rest, "path") orelse "";
    if (field(rest, "scontext")) |sc| d.confinement = typeOf(sc);
    if (d.who.len == 0) d.who = d.confinement;
    if (d.target.len == 0) if (field(rest, "tcontext")) |tc| {
        d.target = typeOf(tc);
    };
    d.action = std.fmt.bufPrint(buf, "{s}", .{perms}) catch perms;
    return d;
}

/// The type of an SELinux context "user:role:type:level".
fn typeOf(context: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, context, ':');
    _ = it.next();
    _ = it.next();
    return it.next() orelse context;
}

/// Either kind of line.
pub fn parseDenial(line: []const u8, buf: []u8, time_buf: []u8) ?Denial {
    return parseAppArmor(line, buf, time_buf) orelse parseAvc(line, buf, time_buf);
}

/// "firefox was refused: read /etc/shadow".
pub fn sentence(out: []u8, d: Denial) []const u8 {
    const verb: []const u8 = if (d.only_logged) "would have been refused (only logged)" else "was refused";
    const text = if (d.target.len > 0)
        std.fmt.bufPrint(out, "{s} {s}: {s} {s}", .{ d.who, verb, d.action, d.target })
    else
        std.fmt.bufPrint(out, "{s} {s}: {s}", .{ d.who, verb, d.action });
    return text catch out[0..0];
}

/// Collapses repeats of the same refusal into one with a count. Takes ownership of nothing:
/// the slices in `list` still point at their lines and buffers.
pub fn collapse(list: []Denial) usize {
    var n: usize = 0;
    for (list) |d| {
        var merged = false;
        for (list[0..n]) |*e| {
            if (std.mem.eql(u8, e.who, d.who) and std.mem.eql(u8, e.action, d.action) and std.mem.eql(u8, e.target, d.target) and std.mem.eql(u8, e.confinement, d.confinement)) {
                e.count += d.count;
                // Keep the latest time.
                if (std.mem.order(u8, d.time, e.time) == .gt) e.time = d.time;
                merged = true;
                break;
            }
        }
        if (!merged) {
            list[n] = d;
            n += 1;
        }
    }
    return n;
}

test "detect picks SELinux when its filesystem is there, AppArmor when enabled" {
    try std.testing.expectEqual(Kind.selinux, detect(null, "1"));
    try std.testing.expectEqual(Kind.apparmor, detect("Y\n", null));
    try std.testing.expectEqual(Kind.none, detect("N\n", null));
    try std.testing.expectEqual(Kind.none, detect(null, null));
}

test "aa-status json: modes and process counts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const text =
        \\{"version": "2", "profiles": {"/usr/sbin/cupsd": "enforce", "firefox": "complain", "ping": "enforce"},
        \\ "processes": {"/usr/sbin/cupsd": [{"profile": "/usr/sbin/cupsd", "pid": "812", "status": "enforce"}],
        \\  "/usr/bin/x": [{"profile": "firefox", "pid": "9", "status": "complain"}, {"profile": "firefox", "pid": "10", "status": "complain"}]}}
    ;
    const list = try parseAaStatus(arena_state.allocator(), text);
    try std.testing.expectEqual(@as(usize, 3), list.len);
    // Sorted by name, ignoring case and the leading slash character order.
    var firefox: ?Profile = null;
    var cups: ?Profile = null;
    for (list) |p| {
        if (std.mem.eql(u8, p.name, "firefox")) firefox = p;
        if (std.mem.eql(u8, p.name, "/usr/sbin/cupsd")) cups = p;
    }
    try std.testing.expectEqual(Mode.complain, firefox.?.mode);
    try std.testing.expectEqual(@as(u32, 2), firefox.?.processes);
    try std.testing.expectEqual(@as(u32, 1), cups.?.processes);
    try std.testing.expectError(error.BadFormat, parseAaStatus(arena_state.allocator(), "[]"));
}

test "getsebool output" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const list = try parseBooleans(arena_state.allocator(), "allow_httpd_anon_write --> off\nhttpd_can_network_connect --> on\nnonsense\n");
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expect(!list[0].on and list[1].on);
    try std.testing.expectEqualStrings("httpd_can_network_connect", list[1].name);
}

test "an AppArmor denial in words" {
    var buf: [128]u8 = undefined;
    var tb: [16]u8 = undefined;
    const line = "2026-11-15T12:30:44-0500 host kernel: audit: type=1400 audit(1763227844.123:45): apparmor=\"DENIED\" operation=\"open\" class=\"file\" profile=\"firefox\" name=\"/etc/shadow\" pid=123 comm=\"firefox\" requested_mask=\"r\" denied_mask=\"r\" fsuid=1000 ouid=0";
    const d = parseAppArmor(line, &buf, &tb).?;
    try std.testing.expectEqualStrings("firefox", d.who);
    try std.testing.expectEqualStrings("read", d.action);
    try std.testing.expectEqualStrings("/etc/shadow", d.target);
    try std.testing.expectEqualStrings("2026-11-15 12:30", d.time);
    try std.testing.expect(!d.only_logged);
    var out: [200]u8 = undefined;
    try std.testing.expectEqualStrings("firefox was refused: read /etc/shadow", sentence(&out, d));
}

test "AppArmor: capability, exec, complain mode, other lines ignored" {
    var buf: [128]u8 = undefined;
    var tb: [16]u8 = undefined;
    const net = parseAppArmor("apparmor=\"DENIED\" operation=\"connect\" class=\"net\" profile=\"x\" comm=\"cupsd\" family=\"inet\" sock_type=\"stream\"", &buf, &tb).?;
    try std.testing.expectEqualStrings("inet", net.target);
    const cap = parseAppArmor("apparmor=\"DENIED\" operation=\"capable\" class=\"cap\" profile=\"ping\" comm=\"ping\" capability=13 capname=\"net_raw\"", &buf, &tb).?;
    try std.testing.expectEqualStrings("use the net_raw capability", cap.action);
    const ex = parseAppArmor("apparmor=\"ALLOWED\" operation=\"exec\" profile=\"p\" name=\"/bin/ls\" comm=\"sh\"", &buf, &tb).?;
    try std.testing.expectEqualStrings("run", ex.action);
    try std.testing.expect(ex.only_logged);
    var out: [200]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, sentence(&out, ex), "only logged") != null);
    try std.testing.expect(parseAppArmor("apparmor=\"STATUS\" operation=\"profile_load\"", &buf, &tb) == null);
    try std.testing.expect(parseAppArmor("nothing to see", &buf, &tb) == null);
    const multi = parseAppArmor("apparmor=\"DENIED\" operation=\"file_perm\" profile=\"x\" name=\"/a\" comm=\"x\" requested_mask=\"wr\"", &buf, &tb).?;
    try std.testing.expectEqualStrings("read, write", multi.action);
}

test "an SELinux AVC in words" {
    var buf: [128]u8 = undefined;
    var tb: [16]u8 = undefined;
    const line = "2026-11-15T09:01:02-0500 host audit[812]: AVC avc:  denied  { read write } for  pid=812 comm=\"httpd\" name=\"index.html\" dev=\"sda1\" ino=1234 scontext=system_u:system_r:httpd_t:s0 tcontext=unconfined_u:object_r:user_home_t:s0 tclass=file permissive=0";
    const d = parseAvc(line, &buf, &tb).?;
    try std.testing.expectEqualStrings("httpd", d.who);
    try std.testing.expectEqualStrings("httpd_t", d.confinement);
    try std.testing.expectEqualStrings("read write", d.action);
    try std.testing.expectEqualStrings("index.html", d.target);
    try std.testing.expectEqualStrings("file", d.class);
    try std.testing.expect(!d.only_logged);
    const perm = parseAvc("avc:  denied  { open } for pid=1 comm=\"x\" scontext=a:b:c_t:s0 tcontext=a:b:d_t:s0 tclass=file permissive=1", &buf, &tb).?;
    try std.testing.expect(perm.only_logged);
    try std.testing.expectEqualStrings("d_t", perm.target);
    try std.testing.expect(parseAvc("avc: granted { read }", &buf, &tb) == null);
}

test "repeats collapse into one line with a count" {
    var list = [_]Denial{
        .{ .who = "a", .action = "read", .target = "/x", .time = "2026-11-15 10:00" },
        .{ .who = "b", .action = "read", .target = "/x" },
        .{ .who = "a", .action = "read", .target = "/x", .time = "2026-11-15 11:00" },
    };
    const n = collapse(&list);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(u32, 2), list[0].count);
    try std.testing.expectEqualStrings("2026-11-15 11:00", list[0].time);
}
