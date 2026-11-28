// SPDX-License-Identifier: GPL-2.0-or-later
//! Lines of /etc/passwd and /etc/group (passwd(5), group(5)). Reading only:
//! accounts are changed with the system's own tools. These are the files alone,
//! so accounts that come from the network (LDAP and the like) are not seen.

const std = @import("std");

pub const Passwd = struct {
    name: []const u8,
    uid: u32,
    gid: u32,
    gecos: []const u8,
    dir: []const u8,
    shell: []const u8,
};

pub const Group = struct {
    name: []const u8,
    gid: u32,
    /// Comma-separated member names, possibly empty.
    members: []const u8,
};

/// One passwd line, pointing into `line`. Null for comments, blank and
/// malformed lines.
pub fn parsePasswd(line: []const u8) ?Passwd {
    if (line.len == 0 or line[0] == '#') return null;
    var it = std.mem.splitScalar(u8, line, ':');
    const name = it.next() orelse return null;
    _ = it.next() orelse return null;
    const uid = parseId(it.next() orelse return null) orelse return null;
    const gid = parseId(it.next() orelse return null) orelse return null;
    const gecos = it.next() orelse return null;
    const dir = it.next() orelse return null;
    const shell = it.next() orelse return null;
    if (name.len == 0) return null;
    return .{ .name = name, .uid = uid, .gid = gid, .gecos = gecos, .dir = dir, .shell = shell };
}

/// One group line, pointing into `line`. Null as for `parsePasswd`.
pub fn parseGroup(line: []const u8) ?Group {
    if (line.len == 0 or line[0] == '#') return null;
    var it = std.mem.splitScalar(u8, line, ':');
    const name = it.next() orelse return null;
    _ = it.next() orelse return null;
    const gid = parseId(it.next() orelse return null) orelse return null;
    const members = it.next() orelse "";
    if (name.len == 0) return null;
    return .{ .name = name, .gid = gid, .members = members };
}

fn parseId(text: []const u8) ?u32 {
    return std.fmt.parseInt(u32, text, 10) catch null;
}

const testing = std.testing;

test "passwd lines" {
    const e = parsePasswd("alice:x:1000:1001:Alice,,,:/home/alice:/bin/zsh").?;
    try testing.expectEqualStrings("alice", e.name);
    try testing.expectEqual(@as(u32, 1000), e.uid);
    try testing.expectEqual(@as(u32, 1001), e.gid);
    try testing.expectEqualStrings("Alice,,,", e.gecos);
    try testing.expectEqualStrings("/home/alice", e.dir);
    try testing.expectEqualStrings("/bin/zsh", e.shell);
    for ([_][]const u8{ "", "# comment", "bad line", ":x:5:5::/:/bin/sh", "a:x:one:5::/:/bin/sh", "a:x:5::/:/bin/sh", "a:x:5:5::/" }) |bad| {
        try testing.expect(parsePasswd(bad) == null);
    }
}

test "group lines" {
    const g = parseGroup("staff:x:50:alice,bob").?;
    try testing.expectEqualStrings("staff", g.name);
    try testing.expectEqual(@as(u32, 50), g.gid);
    try testing.expectEqualStrings("alice,bob", g.members);
    try testing.expectEqualStrings("", parseGroup("root:x:0:").?.members);
    try testing.expectEqualStrings("", parseGroup("root:x:0").?.members);
    for ([_][]const u8{ "", "#x:x:1:", "root", "root:x", "root:x::", ":x:1:" }) |bad| try testing.expect(parseGroup(bad) == null);
}
