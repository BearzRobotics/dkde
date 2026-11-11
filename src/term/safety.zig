//! Pastes that could do something the user did not mean, as Konsole warns
//! about, and quoting paths for the shell.

const std = @import("std");

/// Why pasting `text` is risky, or null when it is not. Several lines run
/// one after another unless the program asked for bracketed paste (then the
/// shell waits for Enter); "sudo" asks for a password the paste may answer;
/// control characters can do anything, bracketed paste or not.
pub fn risk(text: []const u8, bracketed: bool) ?[]const u8 {
    for (text) |c| {
        if (c < 0x20 and c != '\n' and c != '\r' and c != '\t') return "The text holds control characters, which can act like keys.";
        if (c == 0x7f) return "The text holds control characters, which can act like keys.";
    }
    if (bracketed) return null;
    const body = std.mem.trimEnd(u8, text, "\r\n");
    if (std.mem.indexOfAny(u8, body, "\r\n") != null) return "The text has several lines, and each runs as a command at once.";
    if (hasSudo(text) and std.mem.indexOfAny(u8, text, "\r\n") != null) return "The text runs a command with sudo as soon as it is pasted.";
    return null;
}

fn hasSudo(text: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n;&|");
    while (it.next()) |word| if (std.mem.eql(u8, word, "sudo")) return true;
    return false;
}

/// `text` quoted for a POSIX shell: 'a b' stays one word, quotes included.
pub fn shellQuote(gpa: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    const plain = for (text) |c| {
        if (!(std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "/._-+,:@%=", c) != null)) break false;
    } else true;
    if (plain and text.len > 0) return out.appendSlice(gpa, text);
    try out.append(gpa, '\'');
    for (text) |c| {
        if (c == '\'') try out.appendSlice(gpa, "'\\''") else try out.append(gpa, c);
    }
    try out.append(gpa, '\'');
}

test "risky pastes" {
    try std.testing.expect(risk("ls -la", false) == null);
    try std.testing.expect(risk("ls -la\n", false) == null);
    try std.testing.expect(risk("make\nmake install\n", false) != null);
    try std.testing.expect(risk("make\nmake install\n", true) == null);
    try std.testing.expect(risk("sudo rm -rf /tmp/x\n", false) != null);
    try std.testing.expect(risk("echo pseudo\n", false) == null);
    try std.testing.expect(risk("a\x1b[201~b", true) != null);
}

test "paths are quoted for the shell" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try shellQuote(gpa, &out, "/home/u/plain.txt");
    try out.append(gpa, ' ');
    try shellQuote(gpa, &out, "/home/u/it's a file");
    try std.testing.expectEqualStrings("/home/u/plain.txt '/home/u/it'\\''s a file'", out.items);
}
