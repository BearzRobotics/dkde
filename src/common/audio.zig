//! Volume control for the Audio settings page. dkde has no D-Bus, so it
//! talks to the sound server through whichever command-line tool is
//! installed: `wpctl` (PipeWire/WirePlumber) or `pactl` (PulseAudio).

const std = @import("std");

pub const Backend = enum { wpctl, pactl };

pub const State = struct {
    /// 0 to 100 (it can exceed 100 when boosted).
    volume_percent: u32,
    muted: bool,
};

/// `wpctl get-volume @DEFAULT_AUDIO_SINK@` prints "Volume: 0.45" with an
/// optional " [MUTED]".
pub fn parseWpctl(output: []const u8) ?State {
    const text = std.mem.trim(u8, output, " \t\r\n");
    const prefix = "Volume:";
    if (!std.mem.startsWith(u8, text, prefix)) return null;
    var it = std.mem.tokenizeAny(u8, text[prefix.len..], " \t");
    const number = it.next() orelse return null;
    const volume = std.fmt.parseFloat(f64, number) catch return null;
    if (volume < 0) return null;
    return .{
        .volume_percent = @intFromFloat(@round(volume * 100)),
        .muted = std.mem.indexOf(u8, text, "[MUTED]") != null,
    };
}

/// The first percentage in `pactl get-sink-volume @DEFAULT_SINK@`, e.g.
/// "Volume: front-left: 29491 /  45% / -20.00 dB, front-right: ...".
pub fn parsePactlVolume(output: []const u8) ?u32 {
    const percent = std.mem.indexOfScalar(u8, output, '%') orelse return null;
    var start = percent;
    while (start > 0 and std.ascii.isDigit(output[start - 1])) start -= 1;
    if (start == percent) return null;
    return std.fmt.parseInt(u32, output[start..percent], 10) catch null;
}

/// `pactl get-sink-mute @DEFAULT_SINK@` prints "Mute: yes" or "Mute: no".
pub fn parsePactlMute(output: []const u8) ?bool {
    const text = std.mem.trim(u8, output, " \t\r\n");
    if (std.mem.eql(u8, text, "Mute: yes")) return true;
    if (std.mem.eql(u8, text, "Mute: no")) return false;
    return null;
}

pub fn volumeArg(buf: []u8, backend: Backend, percent: u32) []const u8 {
    return switch (backend) {
        .wpctl => std.fmt.bufPrint(buf, "{d:.2}", .{@as(f64, @floatFromInt(percent)) / 100.0}) catch "0",
        .pactl => std.fmt.bufPrint(buf, "{d}%", .{percent}) catch "0%",
    };
}

test "wpctl output" {
    const s = parseWpctl("Volume: 0.45\n").?;
    try std.testing.expectEqual(@as(u32, 45), s.volume_percent);
    try std.testing.expect(!s.muted);
    const m = parseWpctl("Volume: 1.00 [MUTED]\n").?;
    try std.testing.expectEqual(@as(u32, 100), m.volume_percent);
    try std.testing.expect(m.muted);
    try std.testing.expect(parseWpctl("nonsense") == null);
}

test "pactl output" {
    const v = "Volume: front-left: 29491 /  45% / -20.00 dB,   front-right: 29491 /  45% / -20.00 dB\n        balance 0.00\n";
    try std.testing.expectEqual(@as(u32, 45), parsePactlVolume(v).?);
    try std.testing.expect(parsePactlVolume("no numbers") == null);
    try std.testing.expectEqual(true, parsePactlMute("Mute: yes\n").?);
    try std.testing.expectEqual(false, parsePactlMute("Mute: no").?);
    try std.testing.expect(parsePactlMute("?") == null);
}

test "volume argument per tool" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("0.45", volumeArg(&buf, .wpctl, 45));
    try std.testing.expectEqualStrings("45%", volumeArg(&buf, .pactl, 45));
}
