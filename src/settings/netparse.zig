//! Pure parsing and checking for the network page: `nmcli -t` (terse) output, the
//! values typed into the address forms, and the dhcpcd.conf block used when
//! NetworkManager is not there. No GTK and no commands run here, so it is all tested.

const std = @import("std");

/// One line of `nmcli -t` output split into fields. ':' separates fields and is written
/// '\:' inside one; '\\' is a backslash. Fields are allocated from `a`.
pub fn splitTerse(a: std.mem.Allocator, line: []const u8, max_fields: usize) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    var cur: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (c == '\\' and i + 1 < line.len) {
            i += 1;
            try cur.append(a, line[i]);
        } else if (c == ':' and out.items.len + 1 < max_fields) {
            try out.append(a, try cur.toOwnedSlice(a));
        } else try cur.append(a, c);
    }
    try out.append(a, try cur.toOwnedSlice(a));
    return out.toOwnedSlice(a);
}

fn field(f: [][]u8, i: usize) []const u8 {
    return if (i < f.len) f[i] else "";
}

pub const Device = struct { name: []const u8, kind: []const u8, state: []const u8, connection: []const u8 };

/// `nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status`, without loopback, bridges and
/// the Wi-Fi peer-to-peer helper nobody configures.
pub fn parseDevices(a: std.mem.Allocator, text: []const u8) ![]Device {
    var list: std.ArrayList(Device) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const f = try splitTerse(a, line, 4);
        const kind = field(f, 1);
        if (std.mem.eql(u8, kind, "loopback") or std.mem.eql(u8, kind, "bridge") or std.mem.eql(u8, kind, "wifi-p2p")) continue;
        try list.append(a, .{ .name = field(f, 0), .kind = kind, .state = field(f, 2), .connection = field(f, 3) });
    }
    return list.toOwnedSlice(a);
}

pub const Wifi = struct { in_use: bool, ssid: []const u8, signal: u8, security: []const u8 };

/// `nmcli -t -f IN-USE,SSID,SIGNAL,SECURITY device wifi list`: hidden networks left out, one entry
/// per name (the strongest), the one in use first and then by signal.
pub fn parseWifi(a: std.mem.Allocator, text: []const u8) ![]Wifi {
    var list: std.ArrayList(Wifi) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const f = try splitTerse(a, line, 4);
        const ssid = field(f, 1);
        if (ssid.len == 0) continue;
        const entry: Wifi = .{
            .in_use = std.mem.eql(u8, field(f, 0), "*"),
            .ssid = ssid,
            .signal = std.fmt.parseInt(u8, field(f, 2), 10) catch 0,
            .security = field(f, 3),
        };
        var merged = false;
        for (list.items) |*e| if (std.mem.eql(u8, e.ssid, ssid)) {
            if (entry.signal > e.signal) e.signal = entry.signal;
            e.in_use = e.in_use or entry.in_use;
            merged = true;
        };
        if (!merged) try list.append(a, entry);
    }
    std.mem.sort(Wifi, list.items, {}, struct {
        fn lt(_: void, x: Wifi, y: Wifi) bool {
            if (x.in_use != y.in_use) return x.in_use;
            return x.signal > y.signal;
        }
    }.lt);
    return list.toOwnedSlice(a);
}

/// A Wi-Fi network needs a password unless its security column is empty or "--".
pub fn isSecured(security: []const u8) bool {
    return security.len > 0 and !std.mem.eql(u8, security, "--");
}

pub const Connection = struct { name: []const u8, uuid: []const u8, kind: []const u8, device: []const u8 };

/// `nmcli -t -f NAME,UUID,TYPE,DEVICE connection show`, without loopback and bridges.
pub fn parseConnections(a: std.mem.Allocator, text: []const u8) ![]Connection {
    var list: std.ArrayList(Connection) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const f = try splitTerse(a, line, 4);
        const kind = field(f, 2);
        if (std.mem.eql(u8, kind, "loopback") or std.mem.eql(u8, kind, "bridge")) continue;
        if (field(f, 1).len == 0) continue;
        try list.append(a, .{ .name = field(f, 0), .uuid = field(f, 1), .kind = kind, .device = field(f, 3) });
    }
    return list.toOwnedSlice(a);
}

pub fn kindName(kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "802-11-wireless")) return "Wi-Fi";
    if (std.mem.eql(u8, kind, "802-3-ethernet")) return "Wired";
    if (std.mem.eql(u8, kind, "vpn") or std.mem.eql(u8, kind, "wireguard")) return "VPN";
    return kind;
}

/// The IP settings of one profile, as the form shows them.
pub const Ip = struct {
    /// "auto", "manual", "disabled"/"ignore", "link-local", ...
    method: []const u8 = "auto",
    /// "192.168.1.5/24" (first one; extra addresses are kept by nmcli untouched only if not edited).
    address: []const u8 = "",
    gateway: []const u8 = "",
    /// Space separated.
    dns: []const u8 = "",
};

pub const Settings = struct { name: []const u8 = "", autoconnect: bool = true, v4: Ip = .{}, v6: Ip = .{} };

/// `nmcli -t -f connection.autoconnect,ipv4.method,... connection show <uuid>`: "key:value" lines.
pub fn parseSettings(a: std.mem.Allocator, text: []const u8) !Settings {
    var s: Settings = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const f = try splitTerse(a, line, 2);
        if (f.len < 2) continue;
        const key = f[0];
        const value = std.mem.trim(u8, f[1], " ");
        if (std.mem.eql(u8, key, "connection.id")) s.name = value;
        if (std.mem.eql(u8, key, "connection.autoconnect")) s.autoconnect = !std.mem.eql(u8, value, "no");
        const is4 = std.mem.startsWith(u8, key, "ipv4.");
        const is6 = std.mem.startsWith(u8, key, "ipv6.");
        if (!is4 and !is6) continue;
        const ip: *Ip = if (is4) &s.v4 else &s.v6;
        const name = key[5..];
        if (std.mem.eql(u8, name, "method")) ip.method = value;
        if (std.mem.eql(u8, name, "addresses")) {
            // "a/24, b/24": the form edits the first.
            const end = std.mem.indexOfScalar(u8, value, ',') orelse value.len;
            ip.address = std.mem.trim(u8, value[0..end], " ");
        }
        if (std.mem.eql(u8, name, "gateway")) ip.gateway = if (std.mem.eql(u8, value, "--")) "" else value;
        if (std.mem.eql(u8, name, "dns")) {
            const out = try a.dupe(u8, value);
            for (out) |*c| if (c.* == ',') {
                c.* = ' ';
            };
            ip.dns = out;
        }
    }
    return s;
}

// ---- values typed in the forms ------------------------------------------------------------------

pub const CheckError = error{ BadAddress, BadPrefix, BadGateway, BadDns, AddressNeeded };

fn validV4(s: []const u8) bool {
    var parts: usize = 0;
    var it = std.mem.splitScalar(u8, s, '.');
    while (it.next()) |p| {
        parts += 1;
        if (p.len == 0 or p.len > 3) return false;
        const n = std.fmt.parseInt(u16, p, 10) catch return false;
        if (n > 255) return false;
    }
    return parts == 4;
}

fn validV6(s: []const u8) bool {
    if (s.len < 2 or s.len > 45) return false;
    for (s) |c| if (!std.ascii.isHex(c) and c != ':' and c != '.') return false;
    return std.mem.indexOfScalar(u8, s, ':') != null;
}

fn validIp(s: []const u8, v6: bool) bool {
    return if (v6) validV6(s) else validV4(s);
}

/// "192.168.1.5/24" (or an IPv6 address with its prefix); a bare IPv4 address gets /24 added by
/// the caller only if it asks, so here a missing prefix is an error.
pub fn checkAddress(s: []const u8, v6: bool) CheckError!void {
    const slash = std.mem.indexOfScalar(u8, s, '/') orelse return error.BadPrefix;
    if (!validIp(s[0..slash], v6)) return error.BadAddress;
    const prefix = std.fmt.parseInt(u8, s[slash + 1 ..], 10) catch return error.BadPrefix;
    if (prefix == 0 or prefix > (if (v6) @as(u8, 128) else 32)) return error.BadPrefix;
}

pub fn checkGateway(s: []const u8, v6: bool) CheckError!void {
    if (s.len == 0) return;
    if (!validIp(s, v6)) return error.BadGateway;
}

/// Space or comma separated server addresses; empty is fine.
pub fn checkDns(s: []const u8, v6: bool) CheckError!void {
    var it = std.mem.tokenizeAny(u8, s, " ,");
    while (it.next()) |tok| if (!validIp(tok, v6)) return error.BadDns;
}

/// The whole form for one family; `method` is "manual" for a fixed address.
pub fn checkIp(ip: Ip, v6: bool) CheckError!void {
    if (std.mem.eql(u8, ip.method, "manual")) {
        if (ip.address.len == 0) return error.AddressNeeded;
        try checkAddress(ip.address, v6);
        try checkGateway(ip.gateway, v6);
    }
    try checkDns(ip.dns, v6);
}

pub fn describeCheck(e: CheckError) []const u8 {
    return switch (e) {
        error.BadAddress => "That is not a valid address.",
        error.BadPrefix => "Write the address with its prefix length, for example 192.168.1.20/24.",
        error.BadGateway => "The gateway is not a valid address.",
        error.BadDns => "A DNS server is not a valid address.",
        error.AddressNeeded => "A fixed address needs an address to use.",
    };
}

// ---- dhcpcd.conf (without NetworkManager) -----------------------------------------------------

/// The settings in dkde's marked block for `iface` in dhcpcd.conf, or null when there is none
/// (the interface uses DHCP).
pub fn parseDhcpcdBlock(text: []const u8, iface: []const u8) ?Ip {
    var begin_buf: [96]u8 = undefined;
    const begin = std.fmt.bufPrint(&begin_buf, "# dkde-static begin {s}", .{iface}) catch return null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var inside = false;
    var ip: Ip = .{ .method = "manual" };
    var found = false;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.eql(u8, line, begin)) {
            inside = true;
            found = true;
            continue;
        }
        if (inside and std.mem.startsWith(u8, line, "# dkde-static end")) break;
        if (!inside) continue;
        if (std.mem.startsWith(u8, line, "static ip_address=")) ip.address = line["static ip_address=".len..];
        if (std.mem.startsWith(u8, line, "static routers=")) ip.gateway = line["static routers=".len..];
        if (std.mem.startsWith(u8, line, "static domain_name_servers=")) ip.dns = line["static domain_name_servers=".len..];
    }
    return if (found) ip else null;
}

/// The block that makes `iface` use the fixed address in `ip` (checked by `checkIp`).
pub fn dhcpcdBlock(a: std.mem.Allocator, iface: []const u8, ip: Ip) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "# dkde-static begin {s}\ninterface {s}\nstatic ip_address={s}\n", .{ iface, iface, ip.address });
    if (ip.gateway.len > 0) try out.print(a, "static routers={s}\n", .{ip.gateway});
    if (ip.dns.len > 0) {
        try out.appendSlice(a, "static domain_name_servers=");
        var first = true;
        var it = std.mem.tokenizeAny(u8, ip.dns, " ,");
        while (it.next()) |tok| {
            if (!first) try out.append(a, ' ');
            try out.appendSlice(a, tok);
            first = false;
        }
        try out.append(a, '\n');
    }
    try out.print(a, "# dkde-static end {s}\n", .{iface});
    return out.toOwnedSlice(a);
}

/// An interface name that is safe to put in a file and on a command line.
pub fn validIface(name: []const u8) bool {
    if (name.len == 0 or name.len > 15) return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return false;
    return true;
}

// ---- tests ------------------------------------------------------------------------------------

const testing = std.testing;

test "terse fields: escaped colons and backslashes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try splitTerse(arena.allocator(), "Cafe\\: 5G:AA\\\\BB:70:WPA2", 4);
    try testing.expectEqual(@as(usize, 4), f.len);
    try testing.expectEqualStrings("Cafe: 5G", f[0]);
    try testing.expectEqualStrings("AA\\BB", f[1]);
    try testing.expectEqualStrings("WPA2", f[3]);
    const two = try splitTerse(arena.allocator(), "ipv6.addresses:fe80::1/64", 2);
    try testing.expectEqualStrings("fe80::1/64", two[1]); // only the first colon splits
}

test "devices, wifi and connections" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dev = try parseDevices(a, "wlp1:wifi:connected:Home\nlo:loopback:connected (externally):lo\nvirbr0:bridge:connected:virbr0\np2p-dev-wlp1:wifi-p2p:disconnected:\neth0:ethernet:unavailable:\n");
    try testing.expectEqual(@as(usize, 2), dev.len);
    try testing.expectEqualStrings("Home", dev[0].connection);
    const w = try parseWifi(a, " :Home:40:WPA2\n*:Home:69:WPA2 WPA3\n:Cafe:80:--\n::50:WPA2\n");
    try testing.expectEqual(@as(usize, 2), w.len);
    try testing.expect(w[0].in_use and w[0].signal == 69); // in use first, strongest of its duplicates
    try testing.expect(!isSecured(w[1].security));
    try testing.expect(isSecured(w[0].security));
    const c = try parseConnections(a, "Home:aaaa-bbbb:802-11-wireless:wlp1\nlo:cccc:loopback:lo\nWired connection 1:dddd:802-3-ethernet:\n");
    try testing.expectEqual(@as(usize, 2), c.len);
    try testing.expectEqualStrings("Wired", kindName(c[1].kind));
}

test "profile settings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = try parseSettings(arena.allocator(),
        \\connection.autoconnect:no
        \\ipv4.method:manual
        \\ipv4.addresses:192.168.1.5/24, 10.0.0.2/8
        \\ipv4.gateway:192.168.1.1
        \\ipv4.dns:1.1.1.1,8.8.8.8
        \\ipv6.method:auto
        \\ipv6.addresses:
        \\ipv6.gateway:--
        \\ipv6.dns:
    );
    try testing.expect(!s.autoconnect);
    try testing.expectEqualStrings("manual", s.v4.method);
    try testing.expectEqualStrings("192.168.1.5/24", s.v4.address);
    try testing.expectEqualStrings("1.1.1.1 8.8.8.8", s.v4.dns);
    try testing.expectEqualStrings("", s.v6.gateway);
}

test "address checks" {
    try checkAddress("192.168.1.5/24", false);
    try testing.expectError(error.BadPrefix, checkAddress("192.168.1.5", false));
    try testing.expectError(error.BadPrefix, checkAddress("192.168.1.5/33", false));
    try testing.expectError(error.BadAddress, checkAddress("192.168.1.256/24", false));
    try testing.expectError(error.BadAddress, checkAddress("192.168.1/24", false));
    try testing.expectError(error.BadAddress, checkAddress("a b/24", false));
    try checkAddress("fd00::5/64", true);
    try testing.expectError(error.BadAddress, checkAddress("1.2.3.4/24", true));
    try checkGateway("", false);
    try checkGateway("192.168.1.1", false);
    try testing.expectError(error.BadGateway, checkGateway("router", false));
    try checkDns("1.1.1.1, 8.8.8.8", false);
    try testing.expectError(error.BadDns, checkDns("1.1.1.1 dns.example", false));
    try testing.expectError(error.AddressNeeded, checkIp(.{ .method = "manual" }, false));
    try checkIp(.{ .method = "auto", .dns = "9.9.9.9" }, false);
}

test "dhcpcd block round trip and iface names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const block = try dhcpcdBlock(a, "enp1s0", .{ .method = "manual", .address = "192.168.1.20/24", .gateway = "192.168.1.1", .dns = "1.1.1.1, 8.8.8.8" });
    try testing.expectEqualStrings("# dkde-static begin enp1s0\ninterface enp1s0\nstatic ip_address=192.168.1.20/24\nstatic routers=192.168.1.1\nstatic domain_name_servers=1.1.1.1 8.8.8.8\n# dkde-static end enp1s0\n", block);
    const file = try std.fmt.allocPrint(a, "hostname\n{s}option rapid_commit\n", .{block});
    const got = parseDhcpcdBlock(file, "enp1s0").?;
    try testing.expectEqualStrings("192.168.1.20/24", got.address);
    try testing.expectEqualStrings("192.168.1.1", got.gateway);
    try testing.expect(parseDhcpcdBlock(file, "wlp2s0") == null);
    try testing.expect(validIface("enp14s0"));
    try testing.expect(!validIface("a b"));
    try testing.expect(!validIface("../x"));
    try testing.expect(!validIface(""));
}
