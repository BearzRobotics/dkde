//! Command-line front ends for the hardware pages (SPEC.md 5.5): display
//! (`wlr-randr`), network (`wpa_cli`, `ip`, `rfkill`), Bluetooth (`bluetoothctl`), printers
//! (CUPS' `lpstat`/`lpadmin`) and sound devices (`wpctl`/`pactl`). dkde has no
//! session D-Bus, so every one of them is a tool the user installs; a page
//! whose tool is missing says which package provides it.
//!
//! This file holds the parsers (pure, unit-tested) and an async command
//! runner that never blocks the UI.

const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const proc = @import("common").proc;

// ---- running commands -------------------------------------------------------

pub const hasProgram = proc.hasProgram;
pub const Guard = proc.Guard;
pub const run = proc.run;
pub const runInput = proc.runInput;

// ---- sound devices ------------------------------------------------------------

pub const Node = struct {
    /// wpctl node id (0 for pactl, which names devices instead).
    id: u32 = 0,
    name: []const u8,
    default: bool,
};

/// The entries of one section ("Sinks" or "Sources") of `wpctl status`:
///
///     ├─ Sinks:
///     │  *   51. Built-in Audio Analog Stereo   [vol: 0.40]
///     │      52. HDMI                           [vol: 1.00]
///
/// Names borrow from `text`.
pub fn parseWpctlNodes(allocator: std.mem.Allocator, text: []const u8, section: []const u8) ![]Node {
    var list: std.ArrayList(Node) = .empty;
    errdefer list.deinit(allocator);
    var in_audio = false;
    var inside = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.ascii.isWhitespace(if (line.len > 0) line[0] else ' ') and line.len > 0) {
            in_audio = std.mem.startsWith(u8, line, "Audio");
            inside = false;
            continue;
        }
        if (!in_audio) continue;
        const is_header = std.mem.indexOf(u8, line, "\u{251c}\u{2500}") != null or std.mem.indexOf(u8, line, "\u{2514}\u{2500}") != null;
        if (is_header) {
            var want: [32]u8 = undefined;
            const header = std.fmt.bufPrint(&want, "{s}:", .{section}) catch return error.NameTooLong;
            inside = std.mem.indexOf(u8, line, header) != null;
            continue;
        }
        if (!inside) continue;
        const digit = for (line, 0..) |c, i| {
            if (std.ascii.isDigit(c)) break i;
        } else continue;
        var end = digit;
        while (end < line.len and std.ascii.isDigit(line[end])) end += 1;
        if (end >= line.len or line[end] != '.') continue;
        const id = std.fmt.parseInt(u32, line[digit..end], 10) catch continue;
        var name = std.mem.trim(u8, line[end + 1 ..], " \t\r");
        if (std.mem.indexOf(u8, name, " [vol:")) |v| name = std.mem.trim(u8, name[0..v], " ");
        try list.append(allocator, .{
            .id = id,
            .name = name,
            .default = std.mem.indexOfScalar(u8, line[0..digit], '*') != null,
        });
    }
    return list.toOwnedSlice(allocator);
}

/// `pactl list short sinks`: "id<TAB>name<TAB>driver<TAB>format<TAB>state".
pub fn parsePactlShort(allocator: std.mem.Allocator, text: []const u8, default_name: []const u8) ![]Node {
    var list: std.ArrayList(Node) = .empty;
    errdefer list.deinit(allocator);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var cols = std.mem.splitScalar(u8, line, '\t');
        _ = cols.next() orelse continue;
        const name = cols.next() orelse continue;
        if (name.len == 0) continue;
        // Monitors of outputs show up as sources; they are not inputs.
        if (std.mem.endsWith(u8, name, ".monitor")) continue;
        try list.append(allocator, .{ .name = name, .default = std.mem.eql(u8, name, std.mem.trim(u8, default_name, " \r\n")) });
    }
    return list.toOwnedSlice(allocator);
}

/// A stereo sine tone as a WAV file image: `left`/`right` pick the channels.
pub fn toneWav(allocator: std.mem.Allocator, left: bool, right: bool) ![]u8 {
    const rate: u32 = 44100;
    const frames: u32 = rate * 3 / 4;
    const data_len = frames * 4;
    const out = try allocator.alloc(u8, 44 + data_len);
    @memcpy(out[0..4], "RIFF");
    std.mem.writeInt(u32, out[4..8], 36 + data_len, .little);
    @memcpy(out[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, out[16..20], 16, .little);
    std.mem.writeInt(u16, out[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, out[22..24], 2, .little);
    std.mem.writeInt(u32, out[24..28], rate, .little);
    std.mem.writeInt(u32, out[28..32], rate * 4, .little);
    std.mem.writeInt(u16, out[32..34], 4, .little);
    std.mem.writeInt(u16, out[34..36], 16, .little);
    @memcpy(out[36..40], "data");
    std.mem.writeInt(u32, out[40..44], data_len, .little);
    var i: u32 = 0;
    while (i < frames) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / rate;
        // Fade in and out so there is no click.
        const edge = @min(@as(f64, @floatFromInt(i)), @as(f64, @floatFromInt(frames - i))) / 2000.0;
        const amp = @min(1.0, edge) * 0.35;
        const v: i16 = @intFromFloat(@sin(t * 2.0 * std.math.pi * 440.0) * amp * 32767.0);
        std.mem.writeInt(i16, out[44 + i * 4 ..][0..2], if (left) v else 0, .little);
        std.mem.writeInt(i16, out[46 + i * 4 ..][0..2], if (right) v else 0, .little);
    }
    return out;
}

// ---- display ----------------------------------------------------------------------

pub const Mode = struct {
    width: i64,
    height: i64,
    refresh: f64 = 0,
    preferred: bool = false,
    current: bool = false,
};

pub const Output = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    enabled: bool = true,
    modes: []const Mode = &.{},
    scale: f64 = 1.0,
};

/// `wlr-randr --json`. Free with `.deinit()`.
pub fn parseOutputs(allocator: std.mem.Allocator, text: []const u8) !std.json.Parsed([]Output) {
    return std.json.parseFromSlice([]Output, allocator, text, .{ .ignore_unknown_fields = true });
}

pub fn currentMode(output: Output) ?Mode {
    for (output.modes) |m| if (m.current) return m;
    return null;
}

/// `rfkill list`: true when every radio is soft-blocked, false when any is on,
/// null when there are none.
pub fn parseRfkill(text: []const u8) ?bool {
    var seen = false;
    var all_blocked = true;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const key = "Soft blocked:";
        if (!std.mem.startsWith(u8, line, key)) continue;
        seen = true;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[key.len..], " "), "yes")) all_blocked = false;
    }
    return if (seen) all_blocked else null;
}

// ---- network ------------------------------------------------------------------------

pub const Network = struct {
    in_use: bool,
    ssid: []const u8,
    signal: u32,
    secured: bool,
};

/// dBm to a 0-100 quality, the usual linear mapping (-100 dBm is 0, -50 is 100).
pub fn dbmToPercent(dbm: i32) u32 {
    return @intCast(std.math.clamp(2 * (dbm + 100), 0, 100));
}

/// Output of `wifi-list` (see `wifi_list_script`): an optional `CUR<TAB>ssid`
/// line for the network in use, then `wpa_cli scan_results` lines
/// `bssid<TAB>freq<TAB>signal<TAB>flags<TAB>ssid`. Strongest first, without
/// duplicates or hidden networks. SSIDs are copied into `arena`.
pub fn parseWifi(arena: std.mem.Allocator, text: []const u8) ![]Network {
    var list: std.ArrayList(Network) = .empty;
    var current: []const u8 = "";
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, "CUR\t")) {
            current = line[4..];
            continue;
        }
        var f = std.mem.splitScalar(u8, line, '\t');
        const bssid = f.next() orelse continue;
        if (bssid.len != 17) continue; // headers and status lines
        _ = f.next() orelse continue;
        const sig = f.next() orelse continue;
        const flags = f.next() orelse continue;
        const ssid = f.next() orelse continue;
        if (ssid.len == 0 or std.mem.startsWith(u8, ssid, "\\x00")) continue;
        const net: Network = .{
            .in_use = false,
            .ssid = try arena.dupe(u8, ssid),
            .signal = dbmToPercent(std.fmt.parseInt(i32, sig, 10) catch -100),
            .secured = std.mem.indexOf(u8, flags, "WPA") != null or std.mem.indexOf(u8, flags, "WEP") != null or std.mem.indexOf(u8, flags, "SAE") != null,
        };
        var dup = false;
        for (list.items) |*seen| if (std.mem.eql(u8, seen.ssid, net.ssid)) {
            dup = true;
            if (net.signal > seen.signal) seen.* = net;
        };
        if (!dup) try list.append(arena, net);
    }
    for (list.items) |*n| n.in_use = current.len > 0 and std.mem.eql(u8, n.ssid, current);
    std.mem.sort(Network, list.items, {}, struct {
        fn less(_: void, a: Network, b: Network) bool {
            if (a.in_use != b.in_use) return a.in_use;
            return a.signal > b.signal;
        }
    }.less);
    return list.items;
}

/// `sh -c <script>`: the network in use, then the scan results.
pub const wifi_list_script =
    \\s=$(wpa_cli status) || exit 1
    \\case "$s" in *wpa_state=COMPLETED*) printf 'CUR\t%s\n' "$(printf '%s\n' "$s" | sed -n 's/^ssid=//p')";; esac
    \\wpa_cli scan_results
;

/// `sh -c <script>`: ask for a fresh scan and give it time to finish.
pub const wifi_scan_script =
    \\wpa_cli scan >/dev/null || exit 1
    \\sleep 4
;

/// `sh -c <script> sh $1=ssid $2=password (empty for an open or saved
/// network) $3="secured" when the network needs a password, so a new one
/// fails fast (exit 2) to be asked for it`. Reuses a saved network of that
/// name, else adds one, selects it, and waits up to 20 seconds for the
/// association; a new network that fails is removed so a wrong password is
/// not remembered. The DHCP client (dhcpcd) takes it from there. The config
/// is saved when wpa_supplicant has `update_config=1`.
pub const wifi_connect_script =
    \\w() { o=$(wpa_cli "$@") || return 1; case "$o" in *FAIL*) return 1;; esac; printf '%s\n' "$o"; }
    \\id=$(w list_networks | awk -F'\t' -v s="$1" '$1 ~ /^[0-9]+$/ && $2 == s { print $1; exit }') || exit 1
    \\new=
    \\if [ -z "$id" ] && [ -z "$2" ] && [ -n "$3" ]; then exit 2; fi
    \\if [ -z "$id" ]; then
    \\  id=$(w add_network | tail -n 1) || exit 1
    \\  new=yes
    \\  w set_network "$id" ssid "\"$1\"" >/dev/null || exit 1
    \\  if [ -z "$2" ]; then w set_network "$id" key_mgmt NONE >/dev/null || exit 1; fi
    \\fi
    \\if [ -n "$2" ]; then w set_network "$id" psk "\"$2\"" >/dev/null || exit 1; fi
    \\w select_network "$id" >/dev/null || exit 1
    \\i=0
    \\while [ "$i" -lt 20 ]; do
    \\  case "$(wpa_cli status)" in *wpa_state=COMPLETED*) w save_config >/dev/null; exit 0;; esac
    \\  i=$((i + 1)); sleep 1
    \\done
    \\if [ -n "$new" ]; then w remove_network "$id" >/dev/null; fi
    \\exit 1
;

// ---- bluetooth ------------------------------------------------------------------------

pub const BtDevice = struct { address: []const u8, name: []const u8 };

/// `bluetoothctl devices`: "Device AA:BB:CC:DD:EE:FF Name". Borrows from `text`.
pub fn parseBtDevices(allocator: std.mem.Allocator, text: []const u8) ![]BtDevice {
    var list: std.ArrayList(BtDevice) = .empty;
    errdefer list.deinit(allocator);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        // Scanning interleaves "[NEW] Device ..." lines; accept both forms.
        const line = std.mem.trim(u8, raw, " \r");
        const at = std.mem.indexOf(u8, line, "Device ") orelse continue;
        const rest = line[at + 7 ..];
        const space = std.mem.indexOfScalar(u8, rest, ' ') orelse continue;
        const address = rest[0..space];
        if (address.len != 17) continue;
        const name = std.mem.trim(u8, rest[space..], " ");
        if (name.len == 0) continue;
        try list.append(allocator, .{ .address = address, .name = name });
    }
    return list.toOwnedSlice(allocator);
}

pub fn btContains(set: []const BtDevice, address: []const u8) bool {
    for (set) |d| if (std.mem.eql(u8, d.address, address)) return true;
    return false;
}

/// "Powered: yes" in `bluetoothctl show`.
pub fn parseBtPowered(text: []const u8) bool {
    const at = std.mem.indexOf(u8, text, "Powered:") orelse return false;
    return std.mem.startsWith(u8, std.mem.trimStart(u8, text[at + 8 ..], " \t"), "yes");
}

// ---- printers ---------------------------------------------------------------------------

pub const Printer = struct { name: []const u8, status: []const u8 };

/// `lpstat -p`: "printer NAME is idle.  enabled since ...". Borrows from `text`.
pub fn parsePrinters(allocator: std.mem.Allocator, text: []const u8) ![]Printer {
    var list: std.ArrayList(Printer) = .empty;
    errdefer list.deinit(allocator);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const prefix = "printer ";
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const rest = line[prefix.len..];
        const space = std.mem.indexOfScalar(u8, rest, ' ') orelse continue;
        const after = rest[space + 1 ..];
        const status = if (std.mem.startsWith(u8, after, "is ")) after[3..] else after;
        const stop = std.mem.indexOfScalar(u8, status, '.') orelse status.len;
        try list.append(allocator, .{ .name = rest[0..space], .status = std.mem.trim(u8, status[0..stop], " ") });
    }
    return list.toOwnedSlice(allocator);
}

/// `lpstat -d`: "system default destination: NAME".
pub fn parseDefaultPrinter(text: []const u8) ?[]const u8 {
    const key = "system default destination:";
    const at = std.mem.indexOf(u8, text, key) orelse return null;
    const rest = text[at + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
    const name = std.mem.trim(u8, rest[0..end], " \r");
    return if (name.len == 0) null else name;
}

// ---- tests ------------------------------------------------------------------------------

test "wpctl sinks and sources" {
    const status =
        \\PipeWire 'pipewire-0' [1.0.5]
        \\
        \\Audio
        \\ ├─ Devices:
        \\ │      49. Built-in Audio                      [alsa]
        \\ │
        \\ ├─ Sinks:
        \\ │  *   51. Built-in Audio Analog Stereo        [vol: 0.40]
        \\ │      52. HDMI / DisplayPort                  [vol: 1.00]
        \\ │
        \\ ├─ Sources:
        \\ │  *   60. Microphone                          [vol: 1.00]
        \\ │
        \\Video
        \\ ├─ Sinks:
        \\ │      99. Not audio
    ;
    const a = std.testing.allocator;
    const sinks = try parseWpctlNodes(a, status, "Sinks");
    defer a.free(sinks);
    try std.testing.expectEqual(@as(usize, 2), sinks.len);
    try std.testing.expectEqual(@as(u32, 51), sinks[0].id);
    try std.testing.expect(sinks[0].default);
    try std.testing.expectEqualStrings("HDMI / DisplayPort", sinks[1].name);
    try std.testing.expect(!sinks[1].default);
    const sources = try parseWpctlNodes(a, status, "Sources");
    defer a.free(sources);
    try std.testing.expectEqual(@as(usize, 1), sources.len);
    try std.testing.expectEqualStrings("Microphone", sources[0].name);
}

test "pactl short list skips monitors" {
    const a = std.testing.allocator;
    const text = "0\tRDPSink\tmodule-rdp-sink.c\ts16le 2ch 44100Hz\tSUSPENDED\n1\tRDPSink.monitor\tx\ty\tz\n";
    const nodes = try parsePactlShort(a, text, "RDPSink\n");
    defer a.free(nodes);
    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    try std.testing.expect(nodes[0].default);
}

test "tone is a valid stereo wav" {
    const a = std.testing.allocator;
    const wav = try toneWav(a, true, false);
    defer a.free(wav);
    try std.testing.expectEqualStrings("RIFF", wav[0..4]);
    try std.testing.expectEqual(@as(usize, 44 + 33075 * 4), wav.len);
    // Right channel stays silent for a left-only tone.
    var loud_right = false;
    var i: usize = 44;
    while (i < wav.len) : (i += 4) {
        if (std.mem.readInt(i16, wav[i + 2 ..][0..2], .little) != 0) loud_right = true;
    }
    try std.testing.expect(!loud_right);
}

test "wlr-randr json" {
    const a = std.testing.allocator;
    const json =
        \\[{"name":"HDMI-A-1","description":"Dell","make":"Dell","enabled":true,"scale":1.5,
        \\ "position":{"x":0,"y":0},"transform":"normal",
        \\ "modes":[{"width":1920,"height":1080,"refresh":60.0,"preferred":true,"current":true},
        \\          {"width":1280,"height":720,"refresh":59.94,"preferred":false,"current":false}]}]
    ;
    var parsed = try parseOutputs(a, json);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.len);
    try std.testing.expectEqual(@as(f64, 1.5), parsed.value[0].scale);
    try std.testing.expectEqual(@as(i64, 1920), currentMode(parsed.value[0]).?.width);
}

test "wpa_cli scan results" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const text = "CUR\tHome 5G\nbssid / frequency / signal level / flags / ssid\n" ++
        "aa:bb:cc:dd:ee:01\t5180\t-61\t[WPA2-PSK-CCMP][ESS]\tHome 5G\n" ++
        "aa:bb:cc:dd:ee:02\t2412\t-80\t[ESS]\tCafe\n" ++
        "aa:bb:cc:dd:ee:03\t2437\t-70\t[WPA2-PSK-CCMP][ESS]\tHome 5G\n" ++
        "aa:bb:cc:dd:ee:04\t2437\t-40\t[WPA2-PSK-CCMP][ESS]\t\n";
    const nets = try parseWifi(arena_state.allocator(), text);
    try std.testing.expectEqual(@as(usize, 2), nets.len);
    try std.testing.expectEqualStrings("Home 5G", nets[0].ssid);
    try std.testing.expect(nets[0].in_use and nets[0].secured);
    try std.testing.expectEqual(@as(u32, 78), nets[0].signal);
    try std.testing.expect(!nets[1].secured);
}

test "bluetooth devices" {
    const a = std.testing.allocator;
    const text = "Device AA:BB:CC:DD:EE:FF Headphones X\n[NEW] Device 11:22:33:44:55:66 Mouse\nDevice bad Short\n";
    const devices = try parseBtDevices(a, text);
    defer a.free(devices);
    try std.testing.expectEqual(@as(usize, 2), devices.len);
    try std.testing.expectEqualStrings("Headphones X", devices[0].name);
    try std.testing.expect(btContains(devices, "11:22:33:44:55:66"));
    try std.testing.expect(parseBtPowered("Controller X\n\tPowered: yes\n"));
    try std.testing.expect(!parseBtPowered("\tPowered: no\n"));
}

test "cups output" {
    const a = std.testing.allocator;
    const text = "printer Brother is idle.  enabled since Sat 31 Oct\nprinter Old disabled since Sat 31 Oct -\n";
    const printers = try parsePrinters(a, text);
    defer a.free(printers);
    try std.testing.expectEqual(@as(usize, 2), printers.len);
    try std.testing.expectEqualStrings("idle", printers[0].status);
    try std.testing.expectEqualStrings("Brother", parseDefaultPrinter("system default destination: Brother\n").?);
    try std.testing.expect(parseDefaultPrinter("no system default destination\n") == null);
}
