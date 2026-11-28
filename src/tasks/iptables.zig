// SPDX-License-Identifier: GPL-2.0-or-later
//! iptables as the fallback for machines with neither firewalld nor nftables tooling: `iptables -S`
//! read into chains and rules (the same rows the nftables page shows), each rule in plain words, and
//! the arguments of the changes the page makes. Names, ports and addresses are validated here and
//! passed as separate arguments, never as shell text.

const std = @import("std");
const nft = @import("nft.zig");

pub const Row = nft.Row;

fn managedChain(name: []const u8) bool {
    const prefixes = [_][]const u8{ "ufw", "f2b-", "fail2ban", "DOCKER", "KUBE-", "cali-", "LIBVIRT", "DOCKER-USER", "FORWARD_" };
    for (prefixes) |p| if (std.mem.startsWith(u8, name, p)) return true;
    return false;
}

fn upper(a: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]const u8 {
    return std.ascii.allocUpperString(a, s);
}

/// The words of one `-A` line after the chain name, as plain English.
fn explain(a: std.mem.Allocator, args: []const []const u8) std.mem.Allocator.Error![]const u8 {
    var conditions: std.ArrayList([]const u8) = .empty;
    var verdict: []const u8 = "Count";
    var detail: []const u8 = "";
    var proto: []const u8 = "";
    var negate = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const w = args[i];
        const next: []const u8 = if (i + 1 < args.len) args[i + 1] else "";
        if (std.mem.eql(u8, w, "!")) {
            negate = true;
            continue;
        }
        const not: []const u8 = if (negate) "not " else "";
        defer negate = false;
        if (std.mem.eql(u8, w, "-p")) {
            proto = next;
            i += 1;
        } else if (std.mem.eql(u8, w, "-s")) {
            try conditions.append(a, try std.fmt.allocPrint(a, "source address is {s}{s}", .{ not, next }));
            i += 1;
        } else if (std.mem.eql(u8, w, "-d")) {
            try conditions.append(a, try std.fmt.allocPrint(a, "destination address is {s}{s}", .{ not, next }));
            i += 1;
        } else if (std.mem.eql(u8, w, "-i")) {
            try conditions.append(a, try std.fmt.allocPrint(a, "arriving on {s}{s}", .{ not, next }));
            i += 1;
        } else if (std.mem.eql(u8, w, "-o")) {
            try conditions.append(a, try std.fmt.allocPrint(a, "leaving on {s}{s}", .{ not, next }));
            i += 1;
        } else if (std.mem.eql(u8, w, "--dport") or std.mem.eql(u8, w, "--dports")) {
            try conditions.append(a, try std.fmt.allocPrint(a, "{s} destination port is {s}", .{ try upper(a, if (proto.len > 0) proto else "tcp"), next }));
            i += 1;
        } else if (std.mem.eql(u8, w, "--sport") or std.mem.eql(u8, w, "--sports")) {
            try conditions.append(a, try std.fmt.allocPrint(a, "{s} source port is {s}", .{ try upper(a, if (proto.len > 0) proto else "tcp"), next }));
            i += 1;
        } else if (std.mem.eql(u8, w, "--ctstate") or std.mem.eql(u8, w, "--state")) {
            try conditions.append(a, try std.fmt.allocPrint(a, "the connection is {s}", .{next}));
            i += 1;
        } else if (std.mem.eql(u8, w, "--icmp-type")) {
            try conditions.append(a, try std.fmt.allocPrint(a, "ICMP type is {s}", .{next}));
            i += 1;
        } else if (std.mem.eql(u8, w, "-j") or std.mem.eql(u8, w, "-g")) {
            if (std.mem.eql(u8, next, "ACCEPT")) {
                verdict = "Allow";
            } else if (std.mem.eql(u8, next, "DROP")) {
                verdict = "Drop";
            } else if (std.mem.eql(u8, next, "REJECT")) {
                verdict = "Reject";
            } else if (std.mem.eql(u8, next, "RETURN")) {
                verdict = "Return to the calling chain";
            } else if (std.mem.eql(u8, next, "LOG")) {
                verdict = "Log";
            } else if (std.mem.eql(u8, next, "MASQUERADE")) {
                verdict = "Masquerade";
            } else {
                verdict = "Jump to chain";
                detail = next;
            }
            i += 1;
        }
    }
    // A protocol with no port still narrows the rule.
    if (proto.len > 0 and !std.mem.eql(u8, proto, "all")) {
        var has_port = false;
        for (conditions.items) |c| if (std.mem.indexOf(u8, c, "port is") != null) {
            has_port = true;
        };
        if (!has_port) try conditions.insert(a, 0, try std.fmt.allocPrint(a, "protocol is {s}", .{try upper(a, proto)}));
    }
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, verdict);
    if (detail.len > 0) try out.print(a, " {s}", .{detail});
    if (conditions.items.len == 0) {
        if (std.mem.eql(u8, verdict, "Allow") or std.mem.eql(u8, verdict, "Drop") or std.mem.eql(u8, verdict, "Reject")) try out.appendSlice(a, " all traffic here");
    } else {
        try out.appendSlice(a, ": ");
        for (conditions.items, 0..) |c, idx| {
            if (idx > 0) try out.appendSlice(a, ", ");
            try out.appendSlice(a, c);
        }
    }
    return out.items;
}

/// `iptables -S`: "-P INPUT DROP", "-N mychain", "-A INPUT -p tcp -m tcp --dport 22 -j ACCEPT". A rule's
/// handle is its position in its chain (what `-D CHAIN N` takes).
pub fn parse(a: std.mem.Allocator, text: []const u8) ![]Row {
    var chains: std.ArrayList(Row) = .empty;
    var rules: std.ArrayList(Row) = .empty;
    var counts: std.StringHashMapUnmanaged(u64) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len < 4 or line[0] != '-') continue;
        var words: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        while (it.next()) |w| try words.append(a, std.mem.trim(u8, w, "\""));
        if (words.items.len < 2) continue;
        const flag = words.items[0];
        const chain = words.items[1];
        if (std.mem.eql(u8, flag, "-P") and words.items.len >= 3) {
            try chains.append(a, .{
                .kind = .chain,
                .family = "ip",
                .table = "filter",
                .chain = try a.dupe(u8, chain),
                .text = try std.fmt.allocPrint(a, "{s}: built-in chain, policy {s}", .{ chain, words.items[2] }),
                .policy = try std.ascii.allocLowerString(a, words.items[2]),
            });
        } else if (std.mem.eql(u8, flag, "-N")) {
            try chains.append(a, .{ .kind = .chain, .family = "ip", .table = "filter", .chain = try a.dupe(u8, chain), .text = try std.fmt.allocPrint(a, "{s}: chain you jump to from another", .{chain}), .managed = managedChain(chain) });
        } else if (std.mem.eql(u8, flag, "-A")) {
            const n = (counts.get(chain) orelse 0) + 1;
            try counts.put(a, try a.dupe(u8, chain), n);
            try rules.append(a, .{ .kind = .rule, .family = "ip", .table = "filter", .chain = try a.dupe(u8, chain), .text = try explain(a, words.items[2..]), .handle = n, .managed = managedChain(chain) });
        }
    }
    var ordered: std.ArrayList(Row) = .empty;
    for (chains.items) |c| {
        try ordered.append(a, c);
        for (rules.items) |r| if (std.mem.eql(u8, r.chain, c.chain)) try ordered.append(a, r);
    }
    return ordered.items;
}

pub const Verdict = nft.Verdict;
pub const Proto = nft.Proto;

pub const RuleSpec = struct {
    chain: []const u8,
    verdict: Verdict = .accept,
    proto: Proto = .tcp,
    /// "22", "80,443", "8000:8100".
    port: []const u8 = "",
    saddr: []const u8 = "",
};

pub const SpecError = nft.SpecError;

fn validPorts(text: []const u8) bool {
    if (text.len == 0) return false;
    if (std.mem.indexOfScalar(u8, text, ':')) |c| {
        if (std.mem.indexOfScalar(u8, text, ',') != null) return false;
        const lo = std.fmt.parseInt(u32, text[0..c], 10) catch return false;
        const hi = std.fmt.parseInt(u32, text[c + 1 ..], 10) catch return false;
        return lo >= 1 and hi <= 65535 and lo < hi;
    }
    var it = std.mem.splitScalar(u8, text, ',');
    var n: usize = 0;
    while (it.next()) |p| {
        const v = std.fmt.parseInt(u32, p, 10) catch return false;
        if (v < 1 or v > 65535) return false;
        n += 1;
    }
    return n > 0 and n <= 15;
}

/// Whether the rule is for IPv6 (an address with colons): it needs ip6tables.
pub fn isV6(spec: RuleSpec) bool {
    return std.mem.indexOfScalar(u8, spec.saddr, ':') != null;
}

/// Arguments for `iptables -A CHAIN ...` (or ip6tables), into `argv`; returns how many.
pub fn addRuleArgs(spec: RuleSpec, argv: *[20][]const u8) SpecError!usize {
    if (!nft.validName(spec.chain)) return error.BadName;
    if (spec.port.len > 0 and !validPorts(spec.port)) return error.BadPort;
    if (spec.saddr.len > 0 and !validAddressText(spec.saddr)) return error.BadAddress;
    if (spec.proto != .any and spec.port.len == 0) return error.ProtoNeedsPort;
    if (spec.proto == .any and spec.saddr.len == 0 and spec.port.len == 0) return error.Empty;
    var n: usize = 0;
    argv[n] = if (isV6(spec)) "ip6tables" else "iptables";
    argv[n + 1] = "-A";
    argv[n + 2] = spec.chain;
    n += 3;
    if (spec.saddr.len > 0) {
        argv[n] = "-s";
        argv[n + 1] = spec.saddr;
        n += 2;
    }
    if (spec.proto != .any) {
        argv[n] = "-p";
        argv[n + 1] = @tagName(spec.proto);
        n += 2;
        if (std.mem.indexOfScalar(u8, spec.port, ',') != null) {
            argv[n] = "-m";
            argv[n + 1] = "multiport";
            argv[n + 2] = "--dports";
            argv[n + 3] = spec.port;
            n += 4;
        } else {
            argv[n] = "--dport";
            argv[n + 1] = spec.port;
            n += 2;
        }
    }
    argv[n] = "-j";
    argv[n + 1] = switch (spec.verdict) {
        .accept => "ACCEPT",
        .drop => "DROP",
        .reject => "REJECT",
    };
    n += 2;
    return n;
}

fn validAddressText(text: []const u8) bool {
    if (text.len == 0 or text.len > 49) return false;
    var slashes: usize = 0;
    var colons: usize = 0;
    var dots: usize = 0;
    for (text) |c| switch (c) {
        '0'...'9', 'a'...'f', 'A'...'F' => {},
        ':' => colons += 1,
        '.' => dots += 1,
        '/' => slashes += 1,
        else => return false,
    };
    return slashes <= 1 and (dots == 3 or colons >= 2);
}

pub fn deleteArgs(a: std.mem.Allocator, row: Row, argv: *[5][]const u8) (SpecError || std.mem.Allocator.Error)!usize {
    if (row.kind != .rule or row.handle == 0) return error.Empty;
    if (!nft.validName(row.chain)) return error.BadName;
    argv[0] = "iptables";
    argv[1] = "-D";
    argv[2] = row.chain;
    argv[3] = try std.fmt.allocPrint(a, "{d}", .{row.handle});
    return 4;
}

pub fn policyArgs(row: Row, accept: bool, argv: *[5][]const u8) SpecError!usize {
    if (row.kind != .chain or row.policy.len == 0) return error.Empty;
    if (!nft.validName(row.chain)) return error.BadName;
    argv[0] = "iptables";
    argv[1] = "-P";
    argv[2] = row.chain;
    argv[3] = if (accept) "ACCEPT" else "DROP";
    return 4;
}

/// What "Save" runs: Debian's netfilter-persistent when there is one, else the files it would read.
pub const save_script = "if command -v netfilter-persistent >/dev/null 2>&1; then netfilter-persistent save; " ++
    "else mkdir -p /etc/iptables && iptables-save > /etc/iptables/rules.v4 && { ! command -v ip6tables-save >/dev/null 2>&1 || ip6tables-save > /etc/iptables/rules.v6; }; fi";

const sample =
    \\-P INPUT DROP
    \\-P FORWARD DROP
    \\-P OUTPUT ACCEPT
    \\-N ufw-before-input
    \\-A INPUT -i lo -j ACCEPT
    \\-A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    \\-A INPUT -s 10.0.0.0/8 -p tcp -m tcp --dport 22 -j ACCEPT
    \\-A INPUT -p tcp -m multiport --dports 80,443 -j ACCEPT
    \\-A INPUT -p icmp -j DROP
    \\-A INPUT -j ufw-before-input
    \\-A ufw-before-input -j RETURN
    \\
;

test "iptables -S in plain words" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const rows = try parse(arena_state.allocator(), sample);
    // 3 built-in chains + 1 user chain + 7 rules.
    try std.testing.expectEqual(@as(usize, 11), rows.len);
    try std.testing.expect(rows[0].kind == .chain);
    try std.testing.expectEqualStrings("INPUT: built-in chain, policy DROP", rows[0].text);
    try std.testing.expectEqualStrings("drop", rows[0].policy);
    try std.testing.expectEqualStrings("Allow: arriving on lo", rows[1].text);
    try std.testing.expectEqualStrings("Allow: the connection is RELATED,ESTABLISHED", rows[2].text);
    try std.testing.expectEqualStrings("Allow: source address is 10.0.0.0/8, TCP destination port is 22", rows[3].text);
    try std.testing.expectEqualStrings("Allow: TCP destination port is 80,443", rows[4].text);
    try std.testing.expectEqualStrings("Drop: protocol is ICMP", rows[5].text);
    try std.testing.expectEqualStrings("Jump to chain ufw-before-input", rows[6].text);
    try std.testing.expectEqual(@as(u64, 3), rows[3].handle);
    // ufw's chains are its own: marked, so they are not edited from here.
    var managed: usize = 0;
    for (rows) |r| if (r.managed) {
        managed += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), managed);
}

test "iptables arguments" {
    var argv: [20][]const u8 = undefined;
    const n = try addRuleArgs(.{ .chain = "INPUT", .proto = .tcp, .port = "80,443", .saddr = "192.168.1.0/24" }, &argv);
    const want = [_][]const u8{ "iptables", "-A", "INPUT", "-s", "192.168.1.0/24", "-p", "tcp", "-m", "multiport", "--dports", "80,443", "-j", "ACCEPT" };
    try std.testing.expectEqual(want.len, n);
    for (want, argv[0..n]) |w, g| try std.testing.expectEqualStrings(w, g);
    const v6 = try addRuleArgs(.{ .chain = "INPUT", .proto = .any, .saddr = "fe80::1", .verdict = .drop }, &argv);
    try std.testing.expectEqualStrings("ip6tables", argv[0]);
    try std.testing.expectEqualStrings("DROP", argv[v6 - 1]);
    try std.testing.expectError(error.BadPort, addRuleArgs(.{ .chain = "INPUT", .port = "80 ; reboot" }, &argv));
    try std.testing.expectError(error.BadName, addRuleArgs(.{ .chain = "IN PUT", .port = "80" }, &argv));
    try std.testing.expectError(error.BadAddress, addRuleArgs(.{ .chain = "INPUT", .port = "80", .saddr = "x" }, &argv));
}

test "delete and policy" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const rows = try parse(a, sample);
    var argv: [5][]const u8 = undefined;
    const n = try deleteArgs(a, rows[3], &argv);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualStrings("3", argv[3]);
    const p = try policyArgs(rows[0], true, &argv);
    try std.testing.expectEqualStrings("ACCEPT", argv[p - 1]);
}
