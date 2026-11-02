//! The parts of dkde-polkit that are plain data handling, so they are unit
//! tested: the line protocol of polkit's authentication helper, choosing who
//! to authenticate as, and finding the login session. See main.zig for the
//! agent itself and SPEC.md 5.12.

const std = @import("std");

// ---- the helper's line protocol -------------------------------------------------
//
// The helper (polkit-agent-helper-1, reached through /run/polkit/agent-helper.socket
// or as a setuid program) prints one line per event: a prefix, a space, and the
// message escaped as GLib's g_strescape does. The agent answers a prompt with the
// answer and one newline. The helper itself tells polkitd that authentication
// worked; the agent only has to wait for SUCCESS or FAILURE.

pub const HelperMsg = union(enum) {
    /// A question whose answer must not be shown (a password).
    prompt_secret: []const u8,
    /// A question whose answer may be shown.
    prompt_visible: []const u8,
    error_text: []const u8,
    info: []const u8,
    success,
    failure,
    /// Anything else, such as the helper's own diagnostics
    /// ("polkit-agent-helper-1: pam_authenticate failed ..."): worth logging only.
    other: []const u8,
};

/// What `g_strcompress` does: `\n`, `\t`, `\\`, `\"` and octal escapes.
pub fn unescape(text: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len and n < out.len) : (i += 1) {
        const c = text[i];
        if (c != '\\' or i + 1 >= text.len) {
            out[n] = c;
            n += 1;
            continue;
        }
        i += 1;
        switch (text[i]) {
            'b' => out[n] = 8,
            'f' => out[n] = 12,
            'n' => out[n] = '\n',
            'r' => out[n] = '\r',
            't' => out[n] = '\t',
            'v' => out[n] = 11,
            '0'...'7' => {
                // Up to three octal digits.
                var v: u32 = 0;
                var digits: usize = 0;
                while (digits < 3 and i < text.len and text[i] >= '0' and text[i] <= '7') : (digits += 1) {
                    v = v * 8 + (text[i] - '0');
                    i += 1;
                }
                i -= 1;
                out[n] = @truncate(v);
            },
            else => |other| out[n] = other,
        }
        n += 1;
    }
    return out[0..n];
}

/// Reads one line from the helper (without its newline). `out` holds the
/// unescaped message the result points into.
pub fn parseHelperLine(line: []const u8, out: []u8) HelperMsg {
    const prefixes = [_]struct { p: []const u8, kind: u8 }{
        .{ .p = "PAM_PROMPT_ECHO_OFF ", .kind = 0 },
        .{ .p = "PAM_PROMPT_ECHO_ON ", .kind = 1 },
        .{ .p = "PAM_ERROR_MSG ", .kind = 2 },
        .{ .p = "PAM_TEXT_INFO ", .kind = 3 },
    };
    for (prefixes) |pf| {
        if (std.mem.startsWith(u8, line, pf.p)) {
            const msg = unescape(line[pf.p.len..], out);
            return switch (pf.kind) {
                0 => .{ .prompt_secret = msg },
                1 => .{ .prompt_visible = msg },
                2 => .{ .error_text = msg },
                else => .{ .info = msg },
            };
        }
    }
    if (std.mem.startsWith(u8, line, "SUCCESS")) return .success;
    if (std.mem.startsWith(u8, line, "FAILURE")) return .failure;
    return .{ .other = line };
}

/// A cookie is written to the helper on a line of its own, so it must not hold
/// a newline or a NUL. polkitd makes them of letters, digits and dashes.
pub fn validCookie(cookie: []const u8) bool {
    if (cookie.len == 0 or cookie.len > 256) return false;
    for (cookie) |c| {
        if (c < 0x21 or c > 0x7e) return false;
    }
    return true;
}

/// A user name goes on the helper's first line the same way.
pub fn validUserName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| {
        if (c < 0x21 or c > 0x7e) return false;
    }
    return true;
}

// ---- who to authenticate as ----------------------------------------------------------

/// The user to select first among the identities polkit offers: the signed-in
/// user if they are one (an administrator typing their own password), else the
/// first that is not root, else root.
pub fn defaultIdentity(uids: []const u32, me: u32) usize {
    for (uids, 0..) |u, i| {
        if (u == me) return i;
    }
    for (uids, 0..) |u, i| {
        if (u != 0) return i;
    }
    return 0;
}

// ---- session and process ---------------------------------------------------------------

/// The id of a logind session from its object path
/// (`/org/freedesktop/login1/session/_31` is session "1": the bus escapes
/// every character that is not a letter or digit as `_` and two hex digits).
pub fn sessionIdFromPath(path: []const u8, out: []u8) ?[]const u8 {
    const prefix = "/org/freedesktop/login1/session/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const tail = path[prefix.len..];
    var n: usize = 0;
    var i: usize = 0;
    while (i < tail.len) : (i += 1) {
        if (n >= out.len) return null;
        if (tail[i] == '_') {
            if (i + 2 >= tail.len) return null;
            const hi = std.fmt.charToDigit(tail[i + 1], 16) catch return null;
            const lo = std.fmt.charToDigit(tail[i + 2], 16) catch return null;
            out[n] = hi * 16 + lo;
            i += 2;
        } else out[n] = tail[i];
        n += 1;
    }
    return if (n == 0) null else out[0..n];
}

/// Start time of a process in clock ticks since boot: field 22 of
/// `/proc/<pid>/stat`, which polkit uses to tell a process from a later one
/// with the same pid.
pub fn startTimeFromStat(content: []const u8) ?u64 {
    const close = std.mem.lastIndexOfScalar(u8, content, ')') orelse return null;
    var fields = std.mem.tokenizeScalar(u8, content[close + 1 ..], ' ');
    var index: usize = 0;
    // After "(comm)", the state is field 3; field 22 is the 20th after that.
    while (fields.next()) |f| : (index += 1) {
        if (index == 19) return std.fmt.parseInt(u64, std.mem.trim(u8, f, "\n"), 10) catch null;
    }
    return null;
}

/// Text from another program, made safe to show in a label: control characters
/// become spaces. Labels show plain text, never markup.
pub fn cleanText(text: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    for (text) |c| {
        if (n >= out.len) break;
        out[n] = if ((c < 0x20 and c != '\n') or c == 0x7f) ' ' else c;
        n += 1;
    }
    return out[0..n];
}

test "prompts, messages and the end" {
    var b: [128]u8 = undefined;
    switch (parseHelperLine("PAM_PROMPT_ECHO_OFF Password: ", &b)) {
        .prompt_secret => |m| try std.testing.expectEqualStrings("Password: ", m),
        else => return error.WrongKind,
    }
    switch (parseHelperLine("PAM_PROMPT_ECHO_ON Username: ", &b)) {
        .prompt_visible => |m| try std.testing.expectEqualStrings("Username: ", m),
        else => return error.WrongKind,
    }
    switch (parseHelperLine("PAM_ERROR_MSG Account locked", &b)) {
        .error_text => |m| try std.testing.expectEqualStrings("Account locked", m),
        else => return error.WrongKind,
    }
    switch (parseHelperLine("PAM_TEXT_INFO Touch the key", &b)) {
        .info => |m| try std.testing.expectEqualStrings("Touch the key", m),
        else => return error.WrongKind,
    }
    try std.testing.expect(parseHelperLine("SUCCESS", &b) == .success);
    try std.testing.expect(parseHelperLine("FAILURE", &b) == .failure);
}

test "the helper's own diagnostics are not an error" {
    var b: [128]u8 = undefined;
    switch (parseHelperLine("polkit-agent-helper-1: pam_authenticate failed: Authentication failure", &b)) {
        .other => |m| try std.testing.expect(std.mem.startsWith(u8, m, "polkit-agent-helper-1:")),
        else => return error.WrongKind,
    }
}

test "unescape like g_strcompress" {
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings("a\nb\tc\\d\"e", unescape("a\\nb\\tc\\\\d\\\"e", &b));
    try std.testing.expectEqualStrings("A", unescape("\\101", &b));
    try std.testing.expectEqualStrings("é", unescape("\\303\\251", &b));
    // A lone backslash at the end stays.
    try std.testing.expectEqualStrings("x\\", unescape("x\\", &b));
}

test "cookies and user names go on a line of their own" {
    try std.testing.expect(validCookie("3-0123456789abcdef-1"));
    try std.testing.expect(!validCookie(""));
    try std.testing.expect(!validCookie("a\nb"));
    try std.testing.expect(!validCookie("a b"));
    try std.testing.expect(validUserName("dakota"));
    try std.testing.expect(!validUserName("da\nkota"));
}

test "choose who to authenticate as" {
    try std.testing.expectEqual(@as(usize, 1), defaultIdentity(&.{ 0, 1000 }, 1000));
    try std.testing.expectEqual(@as(usize, 1), defaultIdentity(&.{ 0, 1001 }, 1000));
    try std.testing.expectEqual(@as(usize, 0), defaultIdentity(&.{0}, 1000));
    try std.testing.expectEqual(@as(usize, 0), defaultIdentity(&.{ 1002, 1001 }, 1000));
}

test "session id from a logind path" {
    var b: [32]u8 = undefined;
    try std.testing.expectEqualStrings("c3", sessionIdFromPath("/org/freedesktop/login1/session/c3", &b).?);
    try std.testing.expectEqualStrings("1", sessionIdFromPath("/org/freedesktop/login1/session/_31", &b).?);
    try std.testing.expect(sessionIdFromPath("/org/other/c3", &b) == null);
    try std.testing.expect(sessionIdFromPath("/org/freedesktop/login1/session/", &b) == null);
    try std.testing.expect(sessionIdFromPath("/org/freedesktop/login1/session/_3", &b) == null);
}

test "start time from /proc stat" {
    const stat = "1234 (my (odd) app) S 1 1234 1234 0 -1 4194304 100 0 0 0 250 50 0 0 20 0 3 0 5000 1000000 700 18446744073709551615\n";
    try std.testing.expectEqual(@as(u64, 5000), startTimeFromStat(stat).?);
    try std.testing.expect(startTimeFromStat("1 (x) S 1 2") == null);
}

test "text from another program is made safe to show" {
    var b: [32]u8 = undefined;
    try std.testing.expectEqualStrings("a b\nc", cleanText("a\x1bb\nc", &b));
}
