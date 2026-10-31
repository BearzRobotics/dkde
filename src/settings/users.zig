//! Account management helpers for the User settings page. Pure functions
//! over the contents of /etc/passwd and /etc/group, so they are unit tested,
//! plus the fixed shell scripts used for the privileged steps.
//!
//! The scripts take every user-supplied value as a positional parameter
//! (`$1`, `$2`, ...) and never splice it into the script text, so a name or
//! password cannot be interpreted as shell code.

const std = @import("std");

pub const User = struct {
    name: []const u8,
    uid: u32,
    /// The part of the GECOS field before the first comma.
    full_name: []const u8,
    shell: []const u8,
};

/// Accounts a person logs in with: uid 1000 and up (below the "nobody"
/// range) and a real shell. Slices point into `content`.
pub fn parsePasswd(allocator: std.mem.Allocator, content: []const u8) ![]User {
    var out: std.ArrayList(User) = .empty;
    errdefer out.deinit(allocator);
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var f = std.mem.splitScalar(u8, line, ':');
        const name = f.next() orelse continue;
        _ = f.next() orelse continue;
        const uid = std.fmt.parseInt(u32, f.next() orelse continue, 10) catch continue;
        _ = f.next() orelse continue;
        const gecos = f.next() orelse continue;
        _ = f.next() orelse continue;
        const shell = f.next() orelse continue;
        if (uid < 1000 or uid >= 60000) continue;
        if (std.mem.endsWith(u8, shell, "nologin") or std.mem.endsWith(u8, shell, "/false")) continue;
        const comma = std.mem.indexOfScalar(u8, gecos, ',') orelse gecos.len;
        try out.append(allocator, .{ .name = name, .uid = uid, .full_name = gecos[0..comma], .shell = shell });
    }
    return out.toOwnedSlice(allocator);
}

/// Debian's rule for new names: lower-case letters, digits, `_` and `-`,
/// starting with a letter or `_`, at most 32 characters.
pub fn isValidUsername(name: []const u8) bool {
    if (name.len == 0 or name.len > 32) return false;
    if (!(std.ascii.isLower(name[0]) or name[0] == '_')) return false;
    for (name) |c| {
        if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_' or c == '-')) return false;
    }
    return true;
}

/// The full name goes into a colon-separated file, so those and control
/// characters are not allowed.
pub fn isValidFullName(text: []const u8) bool {
    if (text.len > 100) return false;
    for (text) |c| if (c == ':' or c == ',' or c < 0x20 or c == 0x7f) return false;
    return true;
}

const admin_groups = [_][]const u8{ "sudo", "wheel", "admin" };

/// The group that grants administrator rights on this system.
pub fn adminGroup(group_file: []const u8) ?[]const u8 {
    for (admin_groups) |wanted| {
        var lines = std.mem.splitScalar(u8, group_file, '\n');
        while (lines.next()) |line| {
            var f = std.mem.splitScalar(u8, line, ':');
            const name = f.next() orelse continue;
            if (std.mem.eql(u8, name, wanted)) return wanted;
        }
    }
    return null;
}

/// Whether `user` is listed as a member of `group` in /etc/group.
pub fn isMember(group_file: []const u8, group: []const u8, user: []const u8) bool {
    var lines = std.mem.splitScalar(u8, group_file, '\n');
    while (lines.next()) |line| {
        var f = std.mem.splitScalar(u8, line, ':');
        const name = f.next() orelse continue;
        if (!std.mem.eql(u8, name, group)) continue;
        _ = f.next();
        _ = f.next();
        const members = f.next() orelse return false;
        var it = std.mem.tokenizeScalar(u8, members, ',');
        while (it.next()) |m| if (std.mem.eql(u8, m, user)) return true;
        return false;
    }
    return false;
}

pub const Group = struct {
    name: []const u8,
    gid: u32,
    /// Comma-separated member names; points into the parsed content.
    members: []const u8,

    /// Groups from gid 1000 up are ones people create; below that they belong
    /// to the system and its packages.
    pub fn isUserGroup(self: Group) bool {
        return self.gid >= 1000 and self.gid < 60000;
    }

    pub fn has(self: Group, user: []const u8) bool {
        var it = std.mem.tokenizeScalar(u8, self.members, ',');
        while (it.next()) |m| if (std.mem.eql(u8, m, user)) return true;
        return false;
    }
};

/// All groups in /etc/group, in file order. Slices point into `content`.
pub fn parseGroups(allocator: std.mem.Allocator, content: []const u8) ![]Group {
    var out: std.ArrayList(Group) = .empty;
    errdefer out.deinit(allocator);
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var f = std.mem.splitScalar(u8, line, ':');
        const name = f.next() orelse continue;
        _ = f.next() orelse continue;
        const gid = std.fmt.parseInt(u32, f.next() orelse continue, 10) catch continue;
        try out.append(allocator, .{ .name = name, .gid = gid, .members = f.next() orelse "" });
    }
    return out.toOwnedSlice(allocator);
}

/// Group names are passed to the privileged script as one space-separated
/// word list, so they must contain no spaces or shell-special characters.
pub fn isValidGroupName(name: []const u8) bool {
    if (name.len == 0 or name.len > 32) return false;
    if (!(std.ascii.isLower(name[0]) or name[0] == '_')) return false;
    for (name) |c| {
        if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_' or c == '-' or c == '.')) return false;
    }
    return true;
}

pub fn exists(users: []const User, name: []const u8) bool {
    for (users) |u| if (std.mem.eql(u8, u.name, name)) return true;
    return false;
}

/// `sh -c <script> sh $1=name $2=full name $3=yes|no $4=admin group`; stdin
/// carries the new account's password on its first line.
pub const add_script =
    \\set -e
    \\read -r pw
    \\useradd -m -s /bin/bash -c "$2" -- "$1"
    \\printf '%s:%s\n' "$1" "$pw" | chpasswd
    \\if [ "$3" = yes ]; then usermod -aG "$4" -- "$1"; fi
;

/// `sh -c <script> sh $1=user $2=groups to join $3=groups to leave`, each
/// a space-separated list of validated group names.
pub const groups_script =
    \\set -e
    \\u="$1"
    \\for g in $2; do usermod -aG "$g" -- "$u"; done
    \\for g in $3; do gpasswd -d "$u" "$g" >/dev/null; done
;

/// `sh -c <script> sh $1=name`; stdin carries the new password.
pub const password_script =
    \\set -e
    \\read -r pw
    \\printf '%s:%s\n' "$1" "$pw" | chpasswd
;

test "parsePasswd keeps people, not system accounts" {
    const a = std.testing.allocator;
    const passwd =
        \\root:x:0:0:root:/root:/bin/bash
        \\daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
        \\dakota:x:1000:1000:Dakota Smith,,,:/home/dakota:/bin/bash
        \\guest:x:1001:1001::/home/guest:/bin/sh
        \\svc:x:1002:1002:Service:/var/svc:/usr/sbin/nologin
        \\nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
        \\
    ;
    const users = try parsePasswd(a, passwd);
    defer a.free(users);
    try std.testing.expectEqual(@as(usize, 2), users.len);
    try std.testing.expectEqualStrings("dakota", users[0].name);
    try std.testing.expectEqualStrings("Dakota Smith", users[0].full_name);
    try std.testing.expectEqualStrings("", users[1].full_name);
}

test "username rules" {
    try std.testing.expect(isValidUsername("alice"));
    try std.testing.expect(isValidUsername("_svc-1"));
    try std.testing.expect(!isValidUsername("Alice"));
    try std.testing.expect(!isValidUsername("1abc"));
    try std.testing.expect(!isValidUsername(""));
    try std.testing.expect(!isValidUsername("a b"));
    try std.testing.expect(!isValidUsername("x;rm -rf /"));
    try std.testing.expect(!isValidUsername("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
}

test "full name rules" {
    try std.testing.expect(isValidFullName("Alice B. Carol"));
    try std.testing.expect(isValidFullName(""));
    try std.testing.expect(!isValidFullName("a:b"));
    try std.testing.expect(!isValidFullName("a,b"));
    try std.testing.expect(!isValidFullName("a\nb"));
}

test "admin group and membership" {
    const groups = "root:x:0:\nsudo:x:27:dakota,alice\nusers:x:100:\n";
    try std.testing.expectEqualStrings("sudo", adminGroup(groups).?);
    try std.testing.expect(isMember(groups, "sudo", "alice"));
    try std.testing.expect(!isMember(groups, "sudo", "bob"));
    try std.testing.expect(adminGroup("root:x:0:\n") == null);
    try std.testing.expectEqualStrings("wheel", adminGroup("wheel:x:10:me\n").?);
}

test "groups parse and report members" {
    const a = std.testing.allocator;
    const groups = try parseGroups(a, "root:x:0:\nsudo:x:27:dakota,alice\nstaff:x:1005:bob\n");
    defer a.free(groups);
    try std.testing.expectEqual(@as(usize, 3), groups.len);
    try std.testing.expect(groups[1].has("alice"));
    try std.testing.expect(!groups[1].has("bob"));
    try std.testing.expect(!groups[1].isUserGroup());
    try std.testing.expect(groups[2].isUserGroup());
}

test "group name rules" {
    try std.testing.expect(isValidGroupName("docker"));
    try std.testing.expect(isValidGroupName("my.group-1"));
    try std.testing.expect(!isValidGroupName("Docker"));
    try std.testing.expect(!isValidGroupName("a b"));
    try std.testing.expect(!isValidGroupName("a;b"));
    try std.testing.expect(!isValidGroupName(""));
}

test "exists" {
    const users = [_]User{.{ .name = "a", .uid = 1000, .full_name = "", .shell = "/bin/sh" }};
    try std.testing.expect(exists(&users, "a"));
    try std.testing.expect(!exists(&users, "b"));
}
