//! Changing AppArmor and SELinux from the Security page: the rule that would allow a refused action, the
//! file it belongs in, and the arguments of every command the page runs (profile editing, modules, ports,
//! file labels, the boot-time mode). Names, paths and rule text are validated here; they reach the tools
//! as separate arguments or on standard input, never inside shell text.

const std = @import("std");
const security = @import("security.zig");

pub const Error = error{ BadName, BadPath, BadRule, Unsupported, OutOfMemory };

/// A profile, module, type or domain name: letters, digits and . _ - only.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 80) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-')) return false;
    return true;
}

/// An absolute path without anything that could be taken for syntax: no newline, quote, backslash, braces or control characters.
pub fn validPath(path: []const u8) bool {
    if (path.len < 2 or path.len > 400 or path[0] != '/') return false;
    for (path) |c| {
        if (c < 0x20 or c == 0x7f) return false;
        switch (c) {
            '"', '\'', '\\', '{', '}', '`', '$', ';', '*', '?', '[', ']', '\n' => return false,
            else => {},
        }
    }
    return std.mem.indexOf(u8, path, "..") == null;
}

// ---- AppArmor --------------------------------------------------------------------------------

/// "/usr/bin/evince" -> "usr.bin.evince" (the file name AppArmor gives a profile); a plain name stays.
pub fn profileFile(a: std.mem.Allocator, profile: []const u8) Error![]u8 {
    const trimmed = std.mem.trimStart(u8, profile, "/");
    const out = try a.dupe(u8, trimmed);
    for (out) |*c| if (c.* == '/') {
        c.* = '.';
    };
    if (!validName(out)) {
        a.free(out);
        return error.BadName;
    }
    return out;
}

fn aaMask(a: std.mem.Allocator, mask: []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var want_x = false;
    // Letters AppArmor knows; create and delete are writes.
    for ("rwalkm") |letter| {
        const has = std.mem.indexOfScalar(u8, mask, letter) != null or (letter == 'w' and (std.mem.indexOfScalar(u8, mask, 'c') != null or std.mem.indexOfScalar(u8, mask, 'd') != null));
        if (has) try out.append(a, letter);
    }
    if (std.mem.indexOfScalar(u8, mask, 'x') != null) want_x = true;
    if (want_x) try out.appendSlice(a, "ix");
    return out.items;
}

/// The profile line that would allow what was refused, or null when no simple rule does.
pub fn appArmorRule(a: std.mem.Allocator, d: security.Denial) Error!?[]u8 {
    if (d.capability.len > 0) {
        if (!validName(d.capability)) return error.BadRule;
        return try std.fmt.allocPrint(a, "capability {s},", .{d.capability});
    }
    if (std.mem.eql(u8, d.class, "net") and d.family.len > 0) {
        if (!validName(d.family)) return error.BadRule;
        if (d.sock_type.len > 0 and validName(d.sock_type)) return try std.fmt.allocPrint(a, "network {s} {s},", .{ d.family, d.sock_type });
        return try std.fmt.allocPrint(a, "network {s},", .{d.family});
    }
    if (d.target.len == 0 or d.target[0] != '/') return null;
    if (!validPath(d.target)) return error.BadPath;
    const letters: []u8 = if (std.mem.eql(u8, d.op, "exec")) try a.dupe(u8, "ix") else try aaMask(a, d.mask);
    if (letters.len == 0) return null;
    // A path with spaces is quoted.
    if (std.mem.indexOfScalar(u8, d.target, ' ') != null) return try std.fmt.allocPrint(a, "\"{s}\" {s},", .{ d.target, letters });
    return try std.fmt.allocPrint(a, "{s} {s},", .{ d.target, letters });
}

/// The script that adds one rule to a profile's local override and reloads the profile. Arguments:
/// $1 = file name (usr.bin.evince), $2 = the rule. It prints LOCAL-UNUSED when the profile does not include local/.
pub const add_rule_script =
    \\f="/etc/apparmor.d/$1"; l="/etc/apparmor.d/local/$1";
    \\[ -f "$f" ] || { echo "no profile file $f" >&2; exit 1; }
    \\mkdir -p /etc/apparmor.d/local && printf '%s\n' "$2" >> "$l" || exit 1
    \\apparmor_parser -r "$f" || exit 1
    \\grep -q "local/$1" "$f" || echo LOCAL-UNUSED
;

/// Replaces a profile file with new text from standard input, only if it parses, and reloads it ($1 = file name).
pub const save_profile_script =
    \\f="/etc/apparmor.d/$1"; t="$f.dkde-new";
    \\[ -f "$f" ] && [ ! -f "$f.dkde-backup" ] && cp "$f" "$f.dkde-backup"
    \\cat > "$t" && apparmor_parser -Q -T "$t" || { rm -f "$t"; echo "The profile does not parse; nothing was changed." >&2; exit 1; }
    \\mv "$t" "$f" && apparmor_parser -r "$f"
;

/// Creates a new profile stub for a program ($1), in complain mode, with aa-autodep.
pub fn newProfileArgs(path: []const u8, argv: *[3][]const u8) Error!usize {
    if (!validPath(path)) return error.BadPath;
    argv[0] = "aa-autodep";
    argv[1] = path;
    return 2;
}

// ---- SELinux ---------------------------------------------------------------------------------

/// The boot-time mode in /etc/selinux/config: enforcing, permissive or disabled.
pub fn modeValid(mode: []const u8) bool {
    return std.mem.eql(u8, mode, "enforcing") or std.mem.eql(u8, mode, "permissive") or std.mem.eql(u8, mode, "disabled");
}

/// $1 = the mode. Rewrites the SELINUX= line (and adds one when there is none).
pub const set_boot_mode_script =
    \\c=/etc/selinux/config
    \\[ -f "$c" ] && [ ! -f "$c.dkde-backup" ] && cp "$c" "$c.dkde-backup"
    \\if grep -q '^SELINUX=' "$c" 2>/dev/null; then sed -i "s/^SELINUX=.*/SELINUX=$1/" "$c"; else echo "SELINUX=$1" >> "$c"; fi
;

/// Builds a policy module from audit lines on standard input and installs it ($1 = module name).
pub const allow_script =
    \\d=$(mktemp -d) || exit 1; cd "$d" || exit 1
    \\audit2allow -M "$1" || { rm -rf "$d"; exit 1; }
    \\semodule -i "$1.pp"; r=$?; rm -rf "$d"; exit $r
;

/// A module name from a denial: dkde_<domain>_<target type>, lower case, safe characters only.
pub fn moduleName(a: std.mem.Allocator, d: security.Denial) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "dkde_");
    for ([_][]const u8{ d.confinement, d.target_type }) |part| {
        if (part.len == 0) continue;
        if (out.items.len > 5) try out.append(a, '_');
        for (part) |c| if (std.ascii.isAlphanumeric(c) or c == '_') try out.append(a, std.ascii.toLower(c));
    }
    if (out.items.len <= 5 or out.items.len > 64) return error.BadName;
    return out.items;
}

pub fn validType(t: []const u8) bool {
    if (t.len == 0 or t.len > 64) return false;
    for (t) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

pub const Port = struct { type_name: []const u8, proto: []const u8, ports: []const u8 };

/// `semanage port -l`: "http_port_t   tcp   80, 81, 443, 488".
pub fn parsePorts(a: std.mem.Allocator, text: []const u8) ![]Port {
    var list: std.ArrayList(Port) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        if (raw.len == 0 or raw[0] == ' ' or std.mem.startsWith(u8, raw, "SELinux")) continue;
        var it = std.mem.tokenizeScalar(u8, raw, ' ');
        const name = it.next() orelse continue;
        if (!std.mem.endsWith(u8, name, "_t")) continue;
        const proto = it.next() orelse continue;
        const rest = std.mem.trim(u8, it.rest(), " ");
        if (rest.len == 0) continue;
        try list.append(a, .{ .type_name = try a.dupe(u8, name), .proto = try a.dupe(u8, proto), .ports = try a.dupe(u8, rest) });
    }
    return list.items;
}

pub const Module = struct { name: []const u8, version: []const u8, disabled: bool };

/// `semodule -l --full` or `-l`: "name version" or "100 name pp".
pub fn parseModules(a: std.mem.Allocator, text: []const u8) ![]Module {
    var list: std.ArrayList(Module) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const first = it.next() orelse continue;
        // The full form leads with the priority number.
        const numeric = std.fmt.parseInt(u32, first, 10) catch null;
        const name = if (numeric != null) (it.next() orelse continue) else first;
        const version = if (numeric != null) "" else (it.next() orelse "");
        const disabled = std.mem.indexOf(u8, line, "Disabled") != null;
        if (!validName(name)) continue;
        try list.append(a, .{ .name = try a.dupe(u8, name), .version = try a.dupe(u8, version), .disabled = disabled });
    }
    return list.items;
}

test "names and paths are checked" {
    try std.testing.expect(validName("usr.bin.evince") and validName("dkde_httpd_t") and !validName("a b") and !validName("") and !validName("x;y"));
    try std.testing.expect(validPath("/etc/shadow") and validPath("/home/me/My Docs/a.txt"));
    try std.testing.expect(!validPath("etc/x") and !validPath("/a/../b") and !validPath("/a\"b") and !validPath("/a$b") and !validPath("/a\nb") and !validPath("/a/*"));
    try std.testing.expect(validType("httpd_sys_content_t") and !validType("a b") and !validType("a;b"));
    try std.testing.expect(modeValid("permissive") and !modeValid("Enforcing") and !modeValid("on; reboot"));
}

test "AppArmor rules from refusals" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var buf: [128]u8 = undefined;
    var tb: [16]u8 = undefined;
    const open = security.parseAppArmor("apparmor=\"DENIED\" operation=\"open\" class=\"file\" profile=\"firefox\" name=\"/etc/shadow\" comm=\"firefox\" requested_mask=\"rw\" denied_mask=\"rw\"", &buf, &tb).?;
    try std.testing.expectEqualStrings("/etc/shadow rw,", (try appArmorRule(a, open)).?);
    const cap = security.parseAppArmor("apparmor=\"DENIED\" operation=\"capable\" class=\"cap\" profile=\"ping\" comm=\"ping\" capname=\"net_raw\"", &buf, &tb).?;
    try std.testing.expectEqualStrings("capability net_raw,", (try appArmorRule(a, cap)).?);
    const ex = security.parseAppArmor("apparmor=\"DENIED\" operation=\"exec\" class=\"file\" profile=\"p\" name=\"/bin/ls\" comm=\"sh\" requested_mask=\"x\"", &buf, &tb).?;
    try std.testing.expectEqualStrings("/bin/ls ix,", (try appArmorRule(a, ex)).?);
    const net = security.parseAppArmor("apparmor=\"DENIED\" operation=\"connect\" class=\"net\" profile=\"p\" comm=\"c\" family=\"inet\" sock_type=\"stream\"", &buf, &tb).?;
    try std.testing.expectEqualStrings("network inet stream,", (try appArmorRule(a, net)).?);
    const spaced = security.parseAppArmor("apparmor=\"DENIED\" operation=\"open\" class=\"file\" profile=\"p\" name=\"/home/me/My Docs/a.txt\" comm=\"c\" requested_mask=\"r\"", &buf, &tb).?;
    try std.testing.expectEqualStrings("\"/home/me/My Docs/a.txt\" r,", (try appArmorRule(a, spaced)).?);
    const evil = security.parseAppArmor("apparmor=\"DENIED\" operation=\"open\" class=\"file\" profile=\"p\" name=\"/x\\\" } /etc/** rw,\" comm=\"c\" requested_mask=\"r\"", &buf, &tb);
    if (evil) |d| try std.testing.expectError(error.BadPath, appArmorRule(a, d));
    try std.testing.expectEqualStrings("usr.bin.evince", try profileFile(a, "/usr/bin/evince"));
    try std.testing.expectEqualStrings("firefox", try profileFile(a, "firefox"));
    try std.testing.expectError(error.BadName, profileFile(a, "/usr/bin/a b"));
}

test "SELinux module names, ports and modules" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var buf: [128]u8 = undefined;
    var tb: [16]u8 = undefined;
    const d = security.parseAvc("avc:  denied  { read } for pid=1 comm=\"httpd\" name=\"x\" scontext=system_u:system_r:httpd_t:s0 tcontext=unconfined_u:object_r:user_home_t:s0 tclass=file permissive=0", &buf, &tb).?;
    try std.testing.expectEqualStrings("dkde_httpd_t_user_home_t", try moduleName(a, d));
    const ports = try parsePorts(a, "SELinux Port Type              Proto    Port Number\n\nhttp_port_t                    tcp      80, 81, 443\nssh_port_t                     tcp      22\n");
    try std.testing.expectEqual(@as(usize, 2), ports.len);
    try std.testing.expectEqualStrings("80, 81, 443", ports[0].ports);
    const mods = try parseModules(a, "abrt\t1.4.1\napache\t2.8.0\ndkde_x\t1.0 Disabled\n");
    try std.testing.expectEqual(@as(usize, 3), mods.len);
    try std.testing.expect(mods[2].disabled and !mods[0].disabled);
    const full = try parseModules(a, "100 abrt pp\n400 mine cil\n");
    try std.testing.expectEqualStrings("mine", full[1].name);
}
