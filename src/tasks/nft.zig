// SPDX-License-Identifier: GPL-2.0-or-later
//! nftables as the Firewall page shows and edits it: `nft -j list ruleset` read into tables, chains
//! and rules, each rule told in plain words, and the arguments of the few changes the page makes
//! (add a rule, delete one by its handle, set a chain's policy). Everything a person types is
//! validated here and passed to `nft` as separate arguments, never as shell text.

const std = @import("std");

pub const Kind = enum { chain, rule };

pub const Row = struct {
    kind: Kind,
    family: []const u8,
    table: []const u8,
    chain: []const u8,
    /// A chain: "input (filter, hook input, policy drop)". A rule: the plain-words sentence.
    text: []const u8,
    /// Rules: the handle `nft delete rule` needs. Chains: 0.
    handle: u64 = 0,
    /// Base chains: "accept" or "drop"; empty for regular chains.
    policy: []const u8 = "",
    /// Owned by firewalld (its own table): changes here would be undone.
    managed: bool = false,
};

fn str(v: std.json.Value) ?[]const u8 {
    return if (v == .string) v.string else null;
}

fn objGet(v: std.json.Value, key: []const u8) ?std.json.Value {
    return if (v == .object) v.object.get(key) else null;
}

fn intOf(v: std.json.Value) ?u64 {
    return switch (v) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        else => null,
    };
}

/// A value on the right of a match: 22, "established", {"set": [22, 80]}, {"range": [1, 9]}, {"prefix": {"addr": "10.0.0.0", "len": 8}}.
fn valueText(a: std.mem.Allocator, v: std.json.Value) std.mem.Allocator.Error![]const u8 {
    switch (v) {
        .integer => |i| return std.fmt.allocPrint(a, "{d}", .{i}),
        .string => |s| return s,
        .object => |o| {
            if (o.get("set")) |set| if (set == .array) {
                var out: std.ArrayList(u8) = .empty;
                for (set.array.items, 0..) |item, i| {
                    if (i > 0) try out.appendSlice(a, if (i + 1 == set.array.items.len) " or " else ", ");
                    try out.appendSlice(a, try valueText(a, item));
                }
                return out.items;
            };
            if (o.get("range")) |r| if (r == .array and r.array.items.len == 2) return std.fmt.allocPrint(a, "{s}–{s}", .{ try valueText(a, r.array.items[0]), try valueText(a, r.array.items[1]) });
            if (o.get("prefix")) |p| {
                const addr = if (objGet(p, "addr")) |x| str(x) orelse "" else "";
                const len = if (objGet(p, "len")) |x| intOf(x) orelse 0 else 0;
                return std.fmt.allocPrint(a, "{s}/{d}", .{ addr, len });
            }
            return "…";
        },
        else => return "…",
    }
}

fn upper(a: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]const u8 {
    return std.ascii.allocUpperString(a, s);
}

/// One `match` expression in words: "TCP destination port is 22".
fn matchText(a: std.mem.Allocator, m: std.json.Value) std.mem.Allocator.Error!?[]const u8 {
    const op = if (objGet(m, "op")) |o| str(o) orelse "==" else "==";
    const left = objGet(m, "left") orelse return null;
    const right = objGet(m, "right") orelse return null;
    const value = try valueText(a, right);
    const verb: []const u8 = if (std.mem.eql(u8, op, "!=")) "is not" else if (std.mem.eql(u8, op, "in")) "is" else if (std.mem.eql(u8, op, "<")) "is below" else if (std.mem.eql(u8, op, ">")) "is above" else "is";
    if (objGet(left, "payload")) |p| {
        const proto = if (objGet(p, "protocol")) |x| str(x) orelse "" else "";
        const field = if (objGet(p, "field")) |x| str(x) orelse "" else "";
        const upper_proto = try upper(a, proto);
        if (std.mem.eql(u8, field, "dport")) return try std.fmt.allocPrint(a, "{s} destination port {s} {s}", .{ upper_proto, verb, value });
        if (std.mem.eql(u8, field, "sport")) return try std.fmt.allocPrint(a, "{s} source port {s} {s}", .{ upper_proto, verb, value });
        if (std.mem.eql(u8, field, "saddr")) return try std.fmt.allocPrint(a, "source address {s} {s}", .{ verb, value });
        if (std.mem.eql(u8, field, "daddr")) return try std.fmt.allocPrint(a, "destination address {s} {s}", .{ verb, value });
        if (std.mem.eql(u8, field, "type")) return try std.fmt.allocPrint(a, "{s} type {s} {s}", .{ upper_proto, verb, value });
        return try std.fmt.allocPrint(a, "{s} {s} {s} {s}", .{ proto, field, verb, value });
    }
    if (objGet(left, "meta")) |meta| {
        const key = if (objGet(meta, "key")) |x| str(x) orelse "" else "";
        if (std.mem.eql(u8, key, "iifname") or std.mem.eql(u8, key, "iif")) return try std.fmt.allocPrint(a, "arriving on {s}{s}", .{ if (std.mem.eql(u8, op, "!=")) "anything but " else "", value });
        if (std.mem.eql(u8, key, "oifname") or std.mem.eql(u8, key, "oif")) return try std.fmt.allocPrint(a, "leaving on {s}{s}", .{ if (std.mem.eql(u8, op, "!=")) "anything but " else "", value });
        if (std.mem.eql(u8, key, "l4proto") or std.mem.eql(u8, key, "protocol")) return try std.fmt.allocPrint(a, "protocol {s} {s}", .{ verb, value });
        return try std.fmt.allocPrint(a, "{s} {s} {s}", .{ key, verb, value });
    }
    if (objGet(left, "ct")) |ct| {
        const key = if (objGet(ct, "key")) |x| str(x) orelse "" else "";
        if (std.mem.eql(u8, key, "state")) return try std.fmt.allocPrint(a, "the connection is {s}", .{value});
        return try std.fmt.allocPrint(a, "connection {s} {s} {s}", .{ key, verb, value });
    }
    return null;
}

/// The whole rule, `expr`, as a sentence: "Allow: TCP destination port is 22, source address is 10.0.0.0/8".
pub fn explainRule(a: std.mem.Allocator, expr: std.json.Value) std.mem.Allocator.Error![]const u8 {
    if (expr != .array) return "";
    var conditions: std.ArrayList([]const u8) = .empty;
    var verdict: []const u8 = "Count";
    var detail: []const u8 = "";
    for (expr.array.items) |item| {
        if (item != .object) continue;
        if (item.object.get("match")) |m| {
            if (try matchText(a, m)) |text| try conditions.append(a, text);
        } else if (item.object.get("accept") != null) {
            verdict = "Allow";
        } else if (item.object.get("drop") != null) {
            verdict = "Drop";
        } else if (item.object.get("reject") != null) {
            verdict = "Reject";
        } else if (item.object.get("masquerade") != null) {
            verdict = "Masquerade";
        } else if (item.object.get("return") != null) {
            verdict = "Return to the calling chain";
        } else if (item.object.get("jump")) |j| {
            verdict = "Jump to chain";
            detail = if (objGet(j, "target")) |x| str(x) orelse "" else "";
        } else if (item.object.get("goto")) |j| {
            verdict = "Go to chain";
            detail = if (objGet(j, "target")) |x| str(x) orelse "" else "";
        } else if (item.object.get("log") != null) {
            if (std.mem.eql(u8, verdict, "Count")) verdict = "Log";
        } else if (item.object.get("limit") != null) {
            try conditions.append(a, "within a rate limit");
        }
    }
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, verdict);
    if (detail.len > 0) try out.print(a, " {s}", .{detail});
    if (conditions.items.len == 0) {
        try out.appendSlice(a, if (std.mem.eql(u8, verdict, "Allow") or std.mem.eql(u8, verdict, "Drop") or std.mem.eql(u8, verdict, "Reject")) " all traffic here" else "");
    } else {
        try out.appendSlice(a, ": ");
        for (conditions.items, 0..) |c, i| {
            if (i > 0) try out.appendSlice(a, ", ");
            try out.appendSlice(a, c);
        }
    }
    return out.items;
}

/// `nft -j list ruleset` as rows: each chain, then its rules in order. Strings are copied into `a`.
pub fn parse(a: std.mem.Allocator, json: []const u8) ![]Row {
    const parsed = std.json.parseFromSlice(std.json.Value, a, json, .{}) catch return error.BadFormat;
    const root = parsed.value;
    const items = switch (objGet(root, "nftables") orelse return error.BadFormat) {
        .array => |arr| arr.items,
        else => return error.BadFormat,
    };
    var rows: std.ArrayList(Row) = .empty;
    // Chains come before their rules; remember where each chain's row is, so rules follow it.
    var chain_rows: std.ArrayList(struct { key: []const u8, at: usize }) = .empty;
    var pending: std.ArrayList(Row) = .empty;
    for (items) |it| {
        if (objGet(it, "chain")) |c| {
            const fam = str(objGet(c, "family") orelse continue) orelse continue;
            const table = str(objGet(c, "table") orelse continue) orelse continue;
            const name = str(objGet(c, "name") orelse continue) orelse continue;
            const kind = if (objGet(c, "type")) |x| str(x) orelse "" else "";
            const hook = if (objGet(c, "hook")) |x| str(x) orelse "" else "";
            const policy = if (objGet(c, "policy")) |x| str(x) orelse "" else "";
            const text = if (hook.len > 0)
                try std.fmt.allocPrint(a, "{s}: base chain ({s}, hook {s}), policy {s}", .{ name, kind, hook, if (policy.len > 0) policy else "accept" })
            else
                try std.fmt.allocPrint(a, "{s}: chain you jump to from another", .{name});
            try chain_rows.append(a, .{ .key = try std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ fam, table, name }), .at = rows.items.len });
            try rows.append(a, .{ .kind = .chain, .family = fam, .table = table, .chain = name, .text = text, .policy = policy, .managed = std.mem.eql(u8, table, "firewalld") });
        } else if (objGet(it, "rule")) |r| {
            const fam = str(objGet(r, "family") orelse continue) orelse continue;
            const table = str(objGet(r, "table") orelse continue) orelse continue;
            const chain = str(objGet(r, "chain") orelse continue) orelse continue;
            const handle = intOf(objGet(r, "handle") orelse continue) orelse 0;
            const expr = objGet(r, "expr") orelse .null;
            try pending.append(a, .{ .kind = .rule, .family = fam, .table = table, .chain = chain, .text = try explainRule(a, expr), .handle = handle, .managed = std.mem.eql(u8, table, "firewalld") });
        }
    }
    // Put each rule under its chain, keeping their order.
    var ordered: std.ArrayList(Row) = .empty;
    for (rows.items) |chain_row| {
        try ordered.append(a, chain_row);
        for (pending.items) |rule| {
            if (std.mem.eql(u8, rule.family, chain_row.family) and std.mem.eql(u8, rule.table, chain_row.table) and std.mem.eql(u8, rule.chain, chain_row.chain)) try ordered.append(a, rule);
        }
    }
    return ordered.items;
}

// ---- changes ---------------------------------------------------------------------------------

/// A table, chain or family name: what nft allows, kept to the safe subset.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    if (!(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.')) return false;
    return true;
}

pub const Verdict = enum { accept, drop, reject };
pub const Proto = enum { tcp, udp, any };

pub const RuleSpec = struct {
    family: []const u8,
    table: []const u8,
    chain: []const u8,
    verdict: Verdict = .accept,
    proto: Proto = .tcp,
    /// "22", "80,443", "8000-8100"; empty = any.
    port: []const u8 = "",
    /// An address or network; empty = any.
    saddr: []const u8 = "",
    /// Count packets (a counter shows in the ruleset).
    counter: bool = true,
};

pub const SpecError = error{ BadName, BadPort, BadAddress, ProtoNeedsPort, Empty };

fn validPortList(text: []const u8) bool {
    if (text.len == 0) return false;
    if (std.mem.indexOfScalar(u8, text, '-')) |dash| {
        if (std.mem.indexOfScalar(u8, text, ',') != null) return false;
        const a = std.fmt.parseInt(u32, text[0..dash], 10) catch return false;
        const b = std.fmt.parseInt(u32, text[dash + 1 ..], 10) catch return false;
        return a >= 1 and b <= 65535 and a < b;
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

fn validAddress(text: []const u8) bool {
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

/// Arguments of `nft add rule`, written into `argv` (the strings in `a`): returns how many.
pub fn addRuleArgs(a: std.mem.Allocator, spec: RuleSpec, argv: *[24][]const u8) (SpecError || std.mem.Allocator.Error)!usize {
    if (!validName(spec.family) or !validName(spec.table) or !validName(spec.chain)) return error.BadName;
    if (spec.port.len > 0 and !validPortList(spec.port)) return error.BadPort;
    if (spec.saddr.len > 0 and !validAddress(spec.saddr)) return error.BadAddress;
    if (spec.proto != .any and spec.port.len == 0) return error.ProtoNeedsPort;
    if (spec.proto == .any and spec.saddr.len == 0 and spec.port.len == 0) return error.Empty;
    var n: usize = 0;
    for ([_][]const u8{ "nft", "add", "rule", spec.family, spec.table, spec.chain }) |s| {
        argv[n] = s;
        n += 1;
    }
    if (spec.saddr.len > 0) {
        argv[n] = if (std.mem.indexOfScalar(u8, spec.saddr, ':') != null) "ip6" else "ip";
        argv[n + 1] = "saddr";
        argv[n + 2] = spec.saddr;
        n += 3;
    }
    if (spec.proto != .any) {
        argv[n] = @tagName(spec.proto);
        argv[n + 1] = "dport";
        n += 2;
        if (std.mem.indexOfScalar(u8, spec.port, ',') != null) {
            // A list is a set: { 80, 443 }.
            argv[n] = "{";
            argv[n + 1] = try a.dupe(u8, spec.port);
            argv[n + 2] = "}";
            n += 3;
        } else {
            argv[n] = spec.port;
            n += 1;
        }
    }
    if (spec.counter) {
        argv[n] = "counter";
        n += 1;
    }
    argv[n] = @tagName(spec.verdict);
    n += 1;
    return n;
}

/// `nft delete rule FAMILY TABLE CHAIN handle N`.
pub fn deleteArgs(a: std.mem.Allocator, row: Row, argv: *[8][]const u8) (SpecError || std.mem.Allocator.Error)!usize {
    if (row.kind != .rule or row.handle == 0) return error.Empty;
    if (!validName(row.family) or !validName(row.table) or !validName(row.chain)) return error.BadName;
    const handle = try std.fmt.allocPrint(a, "{d}", .{row.handle});
    const list = [_][]const u8{ "nft", "delete", "rule", row.family, row.table, row.chain, "handle", handle };
    for (list, 0..) |s, i| argv[i] = s;
    return list.len;
}

/// `nft chain FAMILY TABLE CHAIN { policy accept|drop ; }` for a base chain.
pub fn policyArgs(row: Row, accept: bool, argv: *[8][]const u8) SpecError!usize {
    if (row.kind != .chain or row.policy.len == 0) return error.Empty;
    if (!validName(row.family) or !validName(row.table) or !validName(row.chain)) return error.BadName;
    const list = [_][]const u8{ "nft", "chain", row.family, row.table, row.chain, if (accept) "{ policy accept; }" else "{ policy drop; }" };
    for (list, 0..) |s, i| argv[i] = s;
    return list.len;
}

/// What "Save" runs: back up the file once, then write the running ruleset in the format `nft -f` reads at boot.
pub const save_script = "[ -f /etc/nftables.conf ] && [ ! -f /etc/nftables.conf.dkde-backup ] && cp /etc/nftables.conf /etc/nftables.conf.dkde-backup; " ++
    "{ echo '#!/usr/sbin/nft -f'; echo; echo 'flush ruleset'; echo; nft list ruleset; } > /etc/nftables.conf";

const sample =
    \\{"nftables": [
    \\ {"metainfo": {"version": "1.0.9"}},
    \\ {"table": {"family": "inet", "name": "filter", "handle": 1}},
    \\ {"chain": {"family": "inet", "table": "filter", "name": "input", "handle": 1, "type": "filter", "hook": "input", "prio": 0, "policy": "drop"}},
    \\ {"chain": {"family": "inet", "table": "filter", "name": "mine", "handle": 4}},
    \\ {"rule": {"family": "inet", "table": "filter", "chain": "input", "handle": 5, "expr": [
    \\    {"match": {"op": "==", "left": {"ct": {"key": "state"}}, "right": {"set": ["established", "related"]}}}, {"accept": null}]}},
    \\ {"rule": {"family": "inet", "table": "filter", "chain": "input", "handle": 6, "expr": [
    \\    {"match": {"op": "==", "left": {"payload": {"protocol": "tcp", "field": "dport"}}, "right": 22}},
    \\    {"match": {"op": "==", "left": {"payload": {"protocol": "ip", "field": "saddr"}}, "right": {"prefix": {"addr": "10.0.0.0", "len": 8}}}},
    \\    {"counter": {"packets": 0, "bytes": 0}}, {"accept": null}]}},
    \\ {"rule": {"family": "inet", "table": "filter", "chain": "input", "handle": 7, "expr": [
    \\    {"match": {"op": "==", "left": {"meta": {"key": "iifname"}}, "right": "lo"}}, {"accept": null}]}},
    \\ {"rule": {"family": "inet", "table": "filter", "chain": "mine", "handle": 8, "expr": [{"drop": null}]}},
    \\ {"table": {"family": "inet", "name": "firewalld", "handle": 2}},
    \\ {"chain": {"family": "inet", "table": "firewalld", "name": "filter_INPUT", "handle": 2, "type": "filter", "hook": "input", "prio": 10, "policy": "accept"}}
    \\]}
;

test "tables, chains and rules in plain words" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const rows = try parse(arena_state.allocator(), sample);
    try std.testing.expectEqual(@as(usize, 7), rows.len);
    try std.testing.expect(rows[0].kind == .chain);
    try std.testing.expectEqualStrings("input: base chain (filter, hook input), policy drop", rows[0].text);
    try std.testing.expectEqualStrings("drop", rows[0].policy);
    try std.testing.expectEqualStrings("Allow: the connection is established or related", rows[1].text);
    try std.testing.expectEqualStrings("Allow: TCP destination port is 22, source address is 10.0.0.0/8", rows[2].text);
    try std.testing.expectEqual(@as(u64, 6), rows[2].handle);
    try std.testing.expectEqualStrings("Allow: arriving on lo", rows[3].text);
    // The chain without a hook, with its own rule under it.
    try std.testing.expect(rows[4].kind == .chain and rows[4].policy.len == 0);
    try std.testing.expectEqualStrings("Drop all traffic here", rows[5].text);
    // firewalld's tables are marked, so the page does not edit them.
    try std.testing.expect(rows[6].managed and rows[6].kind == .chain);
    try std.testing.expect(!rows[0].managed);
}

test "bad input is an error, not a crash" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(error.BadFormat, parse(arena_state.allocator(), "not json"));
    try std.testing.expectError(error.BadFormat, parse(arena_state.allocator(), "{\"other\": 1}"));
    const none = try parse(arena_state.allocator(), "{\"nftables\": []}");
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "names, ports and addresses are checked" {
    try std.testing.expect(validName("filter") and validName("my_table-1") and validName("inet"));
    try std.testing.expect(!validName("") and !validName("1abc") and !validName("a b") and !validName("a;b") and !validName("$(id)"));
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var argv: [24][]const u8 = undefined;
    const n = try addRuleArgs(a, .{ .family = "inet", .table = "filter", .chain = "input", .proto = .tcp, .port = "80,443", .saddr = "192.168.1.0/24" }, &argv);
    const want = [_][]const u8{ "nft", "add", "rule", "inet", "filter", "input", "ip", "saddr", "192.168.1.0/24", "tcp", "dport", "{", "80,443", "}", "counter", "accept" };
    try std.testing.expectEqual(want.len, n);
    for (want, argv[0..n]) |w, g| try std.testing.expectEqualStrings(w, g);
    const range = try addRuleArgs(a, .{ .family = "ip", .table = "t", .chain = "c", .verdict = .drop, .proto = .udp, .port = "8000-8100", .counter = false }, &argv);
    try std.testing.expectEqualStrings("8000-8100", argv[range - 2]);
    try std.testing.expectEqualStrings("drop", argv[range - 1]);
    try std.testing.expectError(error.BadPort, addRuleArgs(a, .{ .family = "inet", .table = "t", .chain = "c", .port = "80;reboot" }, &argv));
    try std.testing.expectError(error.BadAddress, addRuleArgs(a, .{ .family = "inet", .table = "t", .chain = "c", .port = "80", .saddr = "evil" }, &argv));
    try std.testing.expectError(error.BadName, addRuleArgs(a, .{ .family = "inet", .table = "t t", .chain = "c", .port = "80" }, &argv));
    try std.testing.expectError(error.ProtoNeedsPort, addRuleArgs(a, .{ .family = "inet", .table = "t", .chain = "c", .saddr = "1.2.3.4" }, &argv));
    try std.testing.expectError(error.Empty, addRuleArgs(a, .{ .family = "inet", .table = "t", .chain = "c", .proto = .any }, &argv));
}

test "delete and policy arguments" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const rows = try parse(a, sample);
    var argv: [8][]const u8 = undefined;
    const n = try deleteArgs(a, rows[2], &argv);
    try std.testing.expectEqual(@as(usize, 8), n);
    try std.testing.expectEqualStrings("handle", argv[6]);
    try std.testing.expectEqualStrings("6", argv[7]);
    try std.testing.expectError(error.Empty, deleteArgs(a, rows[0], &argv));
    const p = try policyArgs(rows[0], true, &argv);
    try std.testing.expectEqual(@as(usize, 6), p);
    try std.testing.expectEqualStrings("{ policy accept; }", argv[5]);
    try std.testing.expectError(error.Empty, policyArgs(rows[4], true, &argv));
}
