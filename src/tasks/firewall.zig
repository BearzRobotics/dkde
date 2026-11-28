// SPDX-License-Identifier: GPL-2.0-or-later
//! The firewall as the Firewall page of the task manager shows it: which tool manages it (ufw,
//! firewalld, or nftables by hand), its rules in plain words, and the commands that change them.
//! This file parses what the tools print and builds their arguments (never shell text), so it
//! can be tested; the page runs them with the administrator password.

const std = @import("std");

pub const Backend = enum { none, ufw, firewalld, nft, iptables };

/// What is installed and (for ufw and firewalld) running, by the caller's probes.
pub fn choose(has_ufw: bool, has_firewalld: bool, has_nft: bool, has_iptables: bool, firewalld_active: bool, ufw_active: bool) Backend {
    // A running manager wins (firewalld before ufw). Otherwise the modern tools first: firewalld, then
    // nftables itself; ufw and plain iptables are the fallbacks for machines that have only those.
    if (has_firewalld and firewalld_active) return .firewalld;
    if (has_ufw and ufw_active) return .ufw;
    if (has_firewalld) return .firewalld;
    if (has_nft) return .nft;
    if (has_ufw) return .ufw;
    if (has_iptables) return .iptables;
    return .none;
}

pub const UfwRule = struct {
    number: u32,
    /// "22/tcp", "80,443/tcp", "Anywhere".
    to: []const u8,
    /// "ALLOW IN", "DENY OUT", "LIMIT IN"...
    action: []const u8,
    from: []const u8,
    v6: bool,
};

pub const UfwStatus = struct {
    active: bool = false,
    logging: []const u8 = "",
    default_in: []const u8 = "",
    default_out: []const u8 = "",
    rules: []UfwRule = &.{},
};

/// Splits `line` at runs of two or more spaces.
fn columns(line: []const u8, out: *[4][]const u8) usize {
    var n: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == ' ' and i + 1 < line.len and line[i + 1] == ' ') {
            if (i > start and n < out.len) {
                out[n] = line[start..i];
                n += 1;
            }
            while (i < line.len and line[i] == ' ') i += 1;
            start = i;
        } else i += 1;
    }
    if (start < line.len and n < out.len) {
        out[n] = std.mem.trim(u8, line[start..], " ");
        n += 1;
    }
    return n;
}

/// `ufw status numbered` (the rules) and `ufw status verbose` (the defaults and logging) together;
/// either text may be empty. Strings are copied into `arena`.
pub fn parseUfw(arena: std.mem.Allocator, numbered: []const u8, verbose: []const u8) !UfwStatus {
    var st: UfwStatus = .{};
    var lines = std.mem.splitScalar(u8, verbose, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "Status:")) st.active = std.mem.indexOf(u8, line, "inactive") == null;
        if (std.mem.startsWith(u8, line, "Logging:")) st.logging = try arena.dupe(u8, std.mem.trim(u8, line[8..], " "));
        if (std.mem.startsWith(u8, line, "Default:")) {
            var parts = std.mem.splitSequence(u8, line[8..], ",");
            while (parts.next()) |part| {
                const p = std.mem.trim(u8, part, " ");
                if (std.mem.indexOf(u8, p, "(incoming)")) |at| st.default_in = try arena.dupe(u8, std.mem.trim(u8, p[0..at], " "));
                if (std.mem.indexOf(u8, p, "(outgoing)")) |at| st.default_out = try arena.dupe(u8, std.mem.trim(u8, p[0..at], " "));
            }
        }
    }
    // The numbered listing has "Status:" too, which wins when the verbose one is missing.
    var rules: std.ArrayList(UfwRule) = .empty;
    var nl = std.mem.splitScalar(u8, numbered, '\n');
    while (nl.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "Status:") and verbose.len == 0) st.active = std.mem.indexOf(u8, line, "inactive") == null;
        if (line.len < 4 or line[0] != '[') continue;
        const close = std.mem.indexOfScalar(u8, line, ']') orelse continue;
        const number = std.fmt.parseInt(u32, std.mem.trim(u8, line[1..close], " "), 10) catch continue;
        var cols: [4][]const u8 = undefined;
        const n = columns(std.mem.trim(u8, line[close + 1 ..], " "), &cols);
        if (n < 3) continue;
        const to = cols[0];
        const v6 = std.mem.indexOf(u8, to, "(v6)") != null;
        try rules.append(arena, .{
            .number = number,
            .to = try arena.dupe(u8, std.mem.trim(u8, if (v6) to[0..std.mem.indexOf(u8, to, "(v6)").?] else to, " ")),
            .action = try arena.dupe(u8, cols[1]),
            .from = try arena.dupe(u8, std.mem.trim(u8, if (std.mem.indexOf(u8, cols[2], "(v6)")) |at| cols[2][0..at] else cols[2], " ")),
            .v6 = v6,
        });
    }
    st.rules = try rules.toOwnedSlice(arena);
    return st;
}

/// "ALLOW IN 22/tcp from anywhere" in words: "Allow incoming TCP connections on port 22 from anywhere".
pub fn explainUfw(out: []u8, r: UfwRule) []const u8 {
    const act = r.action;
    const verb: []const u8 = if (std.mem.startsWith(u8, act, "ALLOW")) "Allow" else if (std.mem.startsWith(u8, act, "DENY")) "Block" else if (std.mem.startsWith(u8, act, "REJECT")) "Reject" else if (std.mem.startsWith(u8, act, "LIMIT")) "Rate-limit" else act;
    const dir: []const u8 = if (std.mem.endsWith(u8, act, "OUT")) "outgoing" else if (std.mem.endsWith(u8, act, "FWD")) "forwarded" else "incoming";
    var proto: []const u8 = "";
    var port: []const u8 = r.to;
    if (std.mem.indexOfScalar(u8, r.to, '/')) |slash| {
        port = r.to[0..slash];
        proto = r.to[slash + 1 ..];
    }
    const from: []const u8 = if (std.mem.eql(u8, r.from, "Anywhere")) "anywhere" else r.from;
    const upper = std.ascii.allocUpperString(std.heap.page_allocator, proto) catch return "";
    defer std.heap.page_allocator.free(upper);
    if (std.mem.eql(u8, port, "Anywhere")) {
        return std.fmt.bufPrint(out, "{s} all {s} traffic from {s}", .{ verb, dir, from }) catch "";
    }
    return std.fmt.bufPrint(out, "{s} {s} {s} connections on port {s} from {s}{s}", .{ verb, dir, if (upper.len > 0) upper else "any-protocol", port, from, if (r.v6) " (IPv6)" else "" }) catch "";
}

// ---- adding rules ---------------------------------------------------------------------------

pub const Action = enum { allow, deny, reject, limit };
pub const Direction = enum { in, out };
pub const Proto = enum { tcp, udp, any };

pub const RuleSpec = struct {
    action: Action = .allow,
    direction: Direction = .in,
    proto: Proto = .tcp,
    /// "80", "80,443", "8000:8100"; empty = any port.
    port: []const u8 = "",
    /// An address or network; empty = anywhere.
    from: []const u8 = "",
};

pub const SpecError = error{ BadPort, BadAddress, NeedsPortOrAddress, ProtoNeedsPort };

/// "22", "80,443", "8000:8100": numbers in 1..65535, comma lists or one range.
pub fn validPort(text: []const u8) bool {
    if (text.len == 0) return false;
    if (std.mem.indexOfScalar(u8, text, ':')) |colon| {
        if (std.mem.indexOfScalar(u8, text, ',') != null) return false;
        const a = std.fmt.parseInt(u32, text[0..colon], 10) catch return false;
        const b = std.fmt.parseInt(u32, text[colon + 1 ..], 10) catch return false;
        return a >= 1 and b <= 65535 and a < b;
    }
    var it = std.mem.splitScalar(u8, text, ',');
    var count: usize = 0;
    while (it.next()) |p| {
        const v = std.fmt.parseInt(u32, p, 10) catch return false;
        if (v < 1 or v > 65535) return false;
        count += 1;
    }
    return count > 0 and count <= 15;
}

/// An IPv4 or IPv6 address, optionally with /prefix. Loose on purpose (ufw checks it too); strict about characters.
pub fn validAddress(text: []const u8) bool {
    if (text.len == 0 or text.len > 49) return false;
    var slashes: usize = 0;
    var colons: usize = 0;
    var dots: usize = 0;
    for (text) |ch| {
        switch (ch) {
            '0'...'9', 'a'...'f', 'A'...'F' => {},
            ':' => colons += 1,
            '.' => dots += 1,
            '/' => slashes += 1,
            else => return false,
        }
    }
    if (slashes > 1) return false;
    return dots == 3 or colons >= 2;
}

/// The arguments of `ufw`: `ufw allow in proto tcp from 10.0.0.0/8 to any port 22`. Written into `buf`,
/// which holds the pieces `argv` points to; returns the number of arguments.
pub fn ufwArgs(spec: RuleSpec, argv: *[16][]const u8, buf: []u8) SpecError!usize {
    if (spec.port.len > 0 and !validPort(spec.port)) return error.BadPort;
    if (spec.from.len > 0 and !validAddress(spec.from)) return error.BadAddress;
    if (spec.port.len == 0 and spec.from.len == 0) return error.NeedsPortOrAddress;
    if (spec.proto != .any and spec.port.len == 0) return error.ProtoNeedsPort;
    _ = buf;
    var n: usize = 0;
    argv[n] = "ufw";
    n += 1;
    argv[n] = @tagName(spec.action);
    n += 1;
    argv[n] = @tagName(spec.direction);
    n += 1;
    if (spec.proto != .any) {
        argv[n] = "proto";
        argv[n + 1] = @tagName(spec.proto);
        n += 2;
    }
    argv[n] = "from";
    argv[n + 1] = if (spec.from.len > 0) spec.from else "any";
    n += 2;
    if (spec.port.len > 0) {
        argv[n] = "to";
        argv[n + 1] = "any";
        argv[n + 2] = "port";
        argv[n + 3] = spec.port;
        n += 4;
    }
    return n;
}

// ---- firewalld --------------------------------------------------------------------------------

pub const ItemKind = enum { service, port, protocol, rich };

pub const ZoneItem = struct { kind: ItemKind, name: []const u8 };

pub const Zone = struct {
    name: []const u8 = "",
    active: bool = false,
    is_default: bool = false,
    target: []const u8 = "",
    interfaces: []const u8 = "",
    items: []ZoneItem = &.{},
};

/// `firewall-cmd --list-all-zones` (or `--list-all`, which is one zone):
///   public (default, active)
///     target: default
///     interfaces: wlp15s0
///     services: dhcpv6-client ssh
///     ports: 8080/tcp 443/tcp
///     rich rules:
///     rule family="ipv4" source address="10.0.0.0/8" accept
pub fn parseZones(arena: std.mem.Allocator, text: []const u8) ![]Zone {
    var zones: std.ArrayList(Zone) = .empty;
    var items: std.ArrayList(ZoneItem) = .empty;
    var in_rich = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const indented = raw[0] == ' ' or raw[0] == '\t';
        if (!indented) {
            // A new zone: finish the one before.
            if (zones.items.len > 0) zones.items[zones.items.len - 1].items = try items.toOwnedSlice(arena);
            items = .empty;
            in_rich = false;
            const paren = std.mem.indexOf(u8, line, " (");
            const flags = if (paren) |p| line[p..] else "";
            try zones.append(arena, .{
                .name = try arena.dupe(u8, if (paren) |p| line[0..p] else line),
                .active = std.mem.indexOf(u8, flags, "active") != null,
                .is_default = std.mem.indexOf(u8, flags, "default") != null,
            });
            continue;
        }
        if (zones.items.len == 0) continue;
        const zone = &zones.items[zones.items.len - 1];
        if (in_rich and (std.mem.startsWith(u8, line, "rule "))) {
            try items.append(arena, .{ .kind = .rich, .name = try arena.dupe(u8, line) });
            continue;
        }
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const field = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " ");
        in_rich = std.mem.eql(u8, field, "rich rules");
        if (std.mem.eql(u8, field, "target")) zone.target = try arena.dupe(u8, value);
        if (std.mem.eql(u8, field, "interfaces")) zone.interfaces = try arena.dupe(u8, value);
        const kind: ?ItemKind = if (std.mem.eql(u8, field, "services")) .service else if (std.mem.eql(u8, field, "ports") or std.mem.eql(u8, field, "source-ports")) .port else if (std.mem.eql(u8, field, "protocols")) .protocol else null;
        if (kind) |k| {
            var it = std.mem.tokenizeScalar(u8, value, ' ');
            while (it.next()) |tok| try items.append(arena, .{ .kind = k, .name = try arena.dupe(u8, tok) });
        }
    }
    if (zones.items.len > 0) zones.items[zones.items.len - 1].items = try items.toOwnedSlice(arena);
    return zones.toOwnedSlice(arena);
}

/// One zone (the first in the text); empty when there is none.
pub fn parseZone(arena: std.mem.Allocator, text: []const u8) !Zone {
    const zones = try parseZones(arena, text);
    return if (zones.len > 0) zones[0] else .{};
}

pub fn explainZoneItem(out: []u8, item: ZoneItem) []const u8 {
    return switch (item.kind) {
        .service => std.fmt.bufPrint(out, "Allow the \"{s}\" service in this zone", .{item.name}) catch "",
        .port => std.fmt.bufPrint(out, "Allow connections on port {s} in this zone", .{item.name}) catch "",
        .protocol => std.fmt.bufPrint(out, "Allow the {s} protocol in this zone", .{item.name}) catch "",
        .rich => std.fmt.bufPrint(out, "A custom rule: {s}", .{item.name}) catch "",
    };
}

test "which tool manages the firewall" {
    // Both running: firewalld. Only ufw running: ufw.
    try std.testing.expectEqual(Backend.firewalld, choose(true, true, true, true, true, true));
    try std.testing.expectEqual(Backend.ufw, choose(true, true, true, true, false, true));
    // Nothing running: the modern tools first.
    try std.testing.expectEqual(Backend.firewalld, choose(true, true, true, true, false, false));
    try std.testing.expectEqual(Backend.nft, choose(true, false, true, true, false, false));
    // The fallbacks.
    try std.testing.expectEqual(Backend.ufw, choose(true, false, false, true, false, false));
    try std.testing.expectEqual(Backend.iptables, choose(false, false, false, true, false, false));
    try std.testing.expectEqual(Backend.none, choose(false, false, false, false, false, false));
}

const sample_numbered =
    \\Status: active
    \\
    \\     To                         Action      From
    \\     --                         ------      ----
    \\[ 1] 22/tcp                     ALLOW IN    Anywhere
    \\[ 2] 80,443/tcp                 ALLOW IN    192.168.1.0/24
    \\[ 3] 22/tcp (v6)                ALLOW IN    Anywhere (v6)
    \\[ 4] Anywhere                   DENY IN     10.1.2.3
    \\
;
const sample_verbose =
    \\Status: active
    \\Logging: on (low)
    \\Default: deny (incoming), allow (outgoing), disabled (routed)
    \\New profiles: skip
    \\
;

test "ufw status numbered and verbose" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const st = try parseUfw(arena_state.allocator(), sample_numbered, sample_verbose);
    try std.testing.expect(st.active);
    try std.testing.expectEqualStrings("on (low)", st.logging);
    try std.testing.expectEqualStrings("deny", st.default_in);
    try std.testing.expectEqualStrings("allow", st.default_out);
    try std.testing.expectEqual(@as(usize, 4), st.rules.len);
    try std.testing.expectEqual(@as(u32, 2), st.rules[1].number);
    try std.testing.expectEqualStrings("80,443/tcp", st.rules[1].to);
    try std.testing.expectEqualStrings("192.168.1.0/24", st.rules[1].from);
    try std.testing.expect(st.rules[2].v6);
    try std.testing.expectEqualStrings("22/tcp", st.rules[2].to);
    try std.testing.expectEqualStrings("Anywhere", st.rules[2].from);
    const off = try parseUfw(arena_state.allocator(), "Status: inactive\n", "");
    try std.testing.expect(!off.active);
}

test "rules in words" {
    var out: [200]u8 = undefined;
    const r: UfwRule = .{ .number = 2, .to = "80,443/tcp", .action = "ALLOW IN", .from = "192.168.1.0/24", .v6 = false };
    try std.testing.expectEqualStrings("Allow incoming TCP connections on port 80,443 from 192.168.1.0/24", explainUfw(&out, r));
    const d: UfwRule = .{ .number = 4, .to = "Anywhere", .action = "DENY IN", .from = "10.1.2.3", .v6 = false };
    try std.testing.expectEqualStrings("Block all incoming traffic from 10.1.2.3", explainUfw(&out, d));
    const o: UfwRule = .{ .number = 5, .to = "25/tcp", .action = "REJECT OUT", .from = "Anywhere", .v6 = true };
    try std.testing.expectEqualStrings("Reject outgoing TCP connections on port 25 from anywhere (IPv6)", explainUfw(&out, o));
}

test "ports and addresses are checked before anything is run" {
    try std.testing.expect(validPort("22"));
    try std.testing.expect(validPort("80,443"));
    try std.testing.expect(validPort("8000:8100"));
    try std.testing.expect(!validPort(""));
    try std.testing.expect(!validPort("0"));
    try std.testing.expect(!validPort("70000"));
    try std.testing.expect(!validPort("80;reboot"));
    try std.testing.expect(!validPort("9000:8000"));
    try std.testing.expect(!validPort("80,8000:9000"));
    try std.testing.expect(validAddress("192.168.1.0/24"));
    try std.testing.expect(validAddress("10.0.0.1"));
    try std.testing.expect(validAddress("fe80::1"));
    try std.testing.expect(!validAddress("host.example"));
    try std.testing.expect(!validAddress("1.2.3.4 or any"));
    try std.testing.expect(!validAddress("$(id)"));
}

test "ufw arguments" {
    var argv: [16][]const u8 = undefined;
    var buf: [8]u8 = undefined;
    const n = try ufwArgs(.{ .action = .allow, .direction = .in, .proto = .tcp, .port = "22", .from = "10.0.0.0/8" }, &argv, &buf);
    try std.testing.expectEqual(@as(usize, 11), n);
    try std.testing.expectEqualStrings("ufw", argv[0]);
    try std.testing.expectEqualStrings("allow", argv[1]);
    try std.testing.expectEqualStrings("tcp", argv[4]);
    try std.testing.expectEqualStrings("10.0.0.0/8", argv[6]);
    try std.testing.expectEqualStrings("22", argv[10]);
    const any_port = try ufwArgs(.{ .action = .deny, .direction = .in, .proto = .any, .from = "1.2.3.4" }, &argv, &buf);
    try std.testing.expectEqual(@as(usize, 5), any_port);
    try std.testing.expectError(error.BadPort, ufwArgs(.{ .port = "x" }, &argv, &buf));
    try std.testing.expectError(error.BadAddress, ufwArgs(.{ .port = "22", .from = "nope" }, &argv, &buf));
    try std.testing.expectError(error.NeedsPortOrAddress, ufwArgs(.{}, &argv, &buf));
    try std.testing.expectError(error.ProtoNeedsPort, ufwArgs(.{ .proto = .tcp, .from = "1.2.3.4" }, &argv, &buf));
}

test "firewalld zone" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const text =
        \\public (active)
        \\  target: default
        \\  icmp-block-inversion: no
        \\  interfaces: eth0
        \\  services: dhcpv6-client ssh
        \\  ports: 8080/tcp 443/tcp
        \\  protocols:
        \\
    ;
    const z = try parseZone(arena_state.allocator(), text);
    try std.testing.expectEqualStrings("public", z.name);
    try std.testing.expect(z.active);
    try std.testing.expectEqualStrings("default", z.target);
    try std.testing.expectEqual(@as(usize, 4), z.items.len);
    try std.testing.expectEqualStrings("ssh", z.items[1].name);
    try std.testing.expect(z.items[2].kind == .port);
    var out: [120]u8 = undefined;
    try std.testing.expectEqualStrings("Allow connections on port 8080/tcp in this zone", explainZoneItem(&out, z.items[2]));
}

test "firewalld zones as the real tool prints them" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const text =
        "public (default, active)\n  target: default\n  interfaces: wlp15s0\n  sources: \n  services: dhcpv6-client ssh\n  ports: \n  protocols: \n  forward: yes\n  rich rules: \n\trule family=\"ipv4\" source address=\"10.0.0.0/8\" accept\n" ++
        "libvirt (active)\n  target: ACCEPT\n  interfaces: virbr0\n  services: dhcp dns\n  ports: 8080/tcp\n" ++
        "block\n  target: %%REJECT%%\n";
    const zones = try parseZones(arena_state.allocator(), text);
    try std.testing.expectEqual(@as(usize, 3), zones.len);
    try std.testing.expect(zones[0].is_default and zones[0].active);
    try std.testing.expectEqualStrings("wlp15s0", zones[0].interfaces);
    try std.testing.expectEqual(@as(usize, 3), zones[0].items.len);
    try std.testing.expect(zones[0].items[2].kind == .rich);
    try std.testing.expect(!zones[1].is_default and zones[1].active);
    try std.testing.expectEqualStrings("ACCEPT", zones[1].target);
    try std.testing.expectEqual(@as(usize, 3), zones[1].items.len);
    try std.testing.expect(!zones[2].active);
    try std.testing.expectEqual(@as(usize, 0), zones[2].items.len);
}
