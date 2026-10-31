//! Editing labwc's own files without disturbing anything else in them
//! (SPEC.md 5.5). Both editors are textual: only the touched key changes, so
//! comments, ordering and unrelated settings survive.

const std = @import("std");

/// Sets `KEY=value` in the content of labwc's `environment` file. An existing
/// uncommented assignment is replaced in place; otherwise one is appended.
pub fn setEnvVar(allocator: std.mem.Allocator, content: []const u8, key: []const u8, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var replaced = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    var first = true;
    while (lines.next()) |line| {
        // The final empty element after a trailing newline is not a line.
        if (lines.peek() == null and line.len == 0) break;
        if (!first) try out.append(allocator, '\n');
        first = false;
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (!replaced and std.mem.startsWith(u8, trimmed, key) and trimmed.len > key.len and trimmed[key.len] == '=') {
            try out.print(allocator, "{s}={s}", .{ key, value });
            replaced = true;
        } else try out.appendSlice(allocator, line);
    }
    if (!replaced) {
        if (!first) try out.append(allocator, '\n');
        try out.print(allocator, "{s}={s}", .{ key, value });
    }
    try out.append(allocator, '\n');
    return out.toOwnedSlice(allocator);
}

const empty_rc =
    \\<?xml version="1.0"?>
    \\<labwc_config>
    \\</labwc_config>
    \\
;

/// Sets `<tag>value</tag>` inside `<libinput><device category="default">` of
/// labwc's rc.xml, creating the enclosing elements as needed.
pub fn setLibinput(allocator: std.mem.Allocator, xml_in: []const u8, tag: []const u8, value: []const u8) ![]u8 {
    var xml: std.ArrayList(u8) = .empty;
    defer xml.deinit(allocator);
    try xml.appendSlice(allocator, if (std.mem.trim(u8, xml_in, " \t\r\n").len == 0) empty_rc else xml_in);

    // 1. <libinput> section.
    if (std.mem.indexOf(u8, xml.items, "<libinput>") == null) {
        const close = std.mem.lastIndexOf(u8, xml.items, "</labwc_config>") orelse return error.NotLabwcConfig;
        try xml.insertSlice(allocator, close, "  <libinput>\n  </libinput>\n");
    }
    const lib_open = std.mem.indexOf(u8, xml.items, "<libinput>").?;
    const lib_close = std.mem.indexOfPos(u8, xml.items, lib_open, "</libinput>") orelse return error.NotLabwcConfig;

    // 2. <device category="default"> inside it.
    const device_open_tag = "<device category=\"default\">";
    var device_open = std.mem.indexOfPos(u8, xml.items, lib_open, device_open_tag);
    if (device_open == null or device_open.? > lib_close) {
        try xml.insertSlice(allocator, lib_close, "    <device category=\"default\">\n    </device>\n  ");
        device_open = std.mem.indexOfPos(u8, xml.items, lib_open, device_open_tag);
    }
    const body_start = device_open.? + device_open_tag.len;
    const device_close = std.mem.indexOfPos(u8, xml.items, body_start, "</device>") orelse return error.NotLabwcConfig;

    // 3. The element itself.
    const open_tag = try std.fmt.allocPrint(allocator, "<{s}>", .{tag});
    defer allocator.free(open_tag);
    const close_tag = try std.fmt.allocPrint(allocator, "</{s}>", .{tag});
    defer allocator.free(close_tag);

    if (std.mem.indexOfPos(u8, xml.items, body_start, open_tag)) |at| {
        if (at < device_close) {
            const value_start = at + open_tag.len;
            const value_end = std.mem.indexOfPos(u8, xml.items, value_start, close_tag) orelse return error.NotLabwcConfig;
            try xml.replaceRange(allocator, value_start, value_end - value_start, value);
            return xml.toOwnedSlice(allocator);
        }
    }
    const element = try std.fmt.allocPrint(allocator, "      {s}{s}{s}\n    ", .{ open_tag, value, close_tag });
    defer allocator.free(element);
    // Insert before the indentation that precedes </device>.
    var at = device_close;
    while (at > body_start and (xml.items[at - 1] == ' ' or xml.items[at - 1] == '\t')) at -= 1;
    try xml.insertSlice(allocator, at, element[0 .. element.len - 4]);
    return xml.toOwnedSlice(allocator);
}

/// Sets the number of virtual desktops: `<desktops><number>N</number></desktops>`.
pub fn setDesktops(allocator: std.mem.Allocator, xml_in: []const u8, count: u32) ![]u8 {
    var xml: std.ArrayList(u8) = .empty;
    defer xml.deinit(allocator);
    try xml.appendSlice(allocator, if (std.mem.trim(u8, xml_in, " \t\r\n").len == 0) empty_rc else xml_in);
    const value = try std.fmt.allocPrint(allocator, "{d}", .{@max(count, 1)});
    defer allocator.free(value);

    if (std.mem.indexOf(u8, xml.items, "<desktops>")) |open| {
        const close = std.mem.indexOfPos(u8, xml.items, open, "</desktops>") orelse return error.NotLabwcConfig;
        if (std.mem.indexOfPos(u8, xml.items, open, "<number>")) |n| {
            if (n < close) {
                const start = n + "<number>".len;
                const end = std.mem.indexOfPos(u8, xml.items, start, "</number>") orelse return error.NotLabwcConfig;
                try xml.replaceRange(allocator, start, end - start, value);
                return xml.toOwnedSlice(allocator);
            }
        }
        const element = try std.fmt.allocPrint(allocator, "    <number>{s}</number>\n  ", .{value});
        defer allocator.free(element);
        try xml.insertSlice(allocator, close, element);
        return xml.toOwnedSlice(allocator);
    }
    const close = std.mem.lastIndexOf(u8, xml.items, "</labwc_config>") orelse return error.NotLabwcConfig;
    const block = try std.fmt.allocPrint(allocator, "  <desktops>\n    <number>{s}</number>\n  </desktops>\n", .{value});
    defer allocator.free(block);
    try xml.insertSlice(allocator, close, block);
    return xml.toOwnedSlice(allocator);
}

test "desktops: created, then changed in place" {
    const a = std.testing.allocator;
    const first = try setDesktops(a, "", 4);
    defer a.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, "<number>4</number>") != null);
    const second = try setDesktops(a, first, 6);
    defer a.free(second);
    try std.testing.expect(std.mem.indexOf(u8, second, "<number>6</number>") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, second, "<desktops>"));
    const with_empty = try setDesktops(a, "<labwc_config>\n  <desktops>\n    <popupTime>1000</popupTime>\n  </desktops>\n</labwc_config>\n", 3);
    defer a.free(with_empty);
    try std.testing.expect(std.mem.indexOf(u8, with_empty, "<popupTime>1000</popupTime>") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_empty, "<number>3</number>") != null);
}

test "keybinds: actions with a target are written" {
    const a = std.testing.allocator;
    const out = (try mergeKeybinds(a, "", &dkde_keybinds)).?;
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "<action name=\"GoToDesktop\" to=\"right\"/>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "key=\"C-A-S-Left\"") != null);
}

/// A keybinding dkde wants in labwc's rc.xml.
pub const Keybind = struct {
    key: []const u8,
    /// Runs a command; empty when `action` is used instead.
    command: []const u8 = "",
    /// A labwc action with a `to` attribute, such as GoToDesktop.
    action: []const u8 = "",
    to: []const u8 = "",
};

pub const dkde_keybinds = [_]Keybind{
    .{ .key = "Super_L", .command = "dkde-panel msg toggle-menu" },
    .{ .key = "C-S-Escape", .command = "dkde-tasks" },
    .{ .key = "Print", .command = "dkde-snip --full" },
    .{ .key = "S-Print", .command = "dkde-snip --region" },
    // Volume and brightness keys; the panel shows an on-screen display.
    .{ .key = "XF86AudioRaiseVolume", .command = "dkde-panel msg volume-up" },
    .{ .key = "XF86AudioLowerVolume", .command = "dkde-panel msg volume-down" },
    .{ .key = "XF86AudioMute", .command = "dkde-panel msg volume-mute" },
    .{ .key = "XF86MonBrightnessUp", .command = "dkde-panel msg brightness-up" },
    .{ .key = "XF86MonBrightnessDown", .command = "dkde-panel msg brightness-down" },
    // Virtual desktops: switch, or carry the active window along.
    .{ .key = "C-A-Left", .action = "GoToDesktop", .to = "left" },
    .{ .key = "C-A-Right", .action = "GoToDesktop", .to = "right" },
    .{ .key = "C-A-S-Left", .action = "SendToDesktop", .to = "left" },
    .{ .key = "C-A-S-Right", .action = "SendToDesktop", .to = "right" },
};

fn hasKey(xml: []const u8, key: []const u8) bool {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "key=\"{s}\"", .{key}) catch return false;
    return std.mem.indexOf(u8, xml, needle) != null;
}

/// Adds the keybindings in `wanted` that rc.xml does not already bind,
/// creating `<keyboard>` (with the default bindings) if needed. Existing
/// content is left alone. Returns null when nothing had to change.
pub fn mergeKeybinds(allocator: std.mem.Allocator, xml_in: []const u8, wanted: []const Keybind) !?[]u8 {
    var missing: std.ArrayList(Keybind) = .empty;
    defer missing.deinit(allocator);
    for (wanted) |k| if (!hasKey(xml_in, k.key)) try missing.append(allocator, k);
    if (missing.items.len == 0) return null;

    var xml: std.ArrayList(u8) = .empty;
    defer xml.deinit(allocator);
    try xml.appendSlice(allocator, if (std.mem.trim(u8, xml_in, " \t\r\n").len == 0) empty_rc else xml_in);

    if (std.mem.indexOf(u8, xml.items, "<keyboard>") == null) {
        const close = std.mem.lastIndexOf(u8, xml.items, "</labwc_config>") orelse return error.NotLabwcConfig;
        try xml.insertSlice(allocator, close, "  <keyboard>\n    <default />\n  </keyboard>\n");
    }
    const close = std.mem.indexOf(u8, xml.items, "</keyboard>") orelse return error.NotLabwcConfig;

    var block: std.ArrayList(u8) = .empty;
    defer block.deinit(allocator);
    for (missing.items) |k| {
        const onrelease = if (std.mem.eql(u8, k.key, "Super_L")) " onRelease=\"yes\"" else "";
        if (k.action.len > 0) {
            try block.print(allocator, "    <keybind key=\"{s}\">\n      <action name=\"{s}\" to=\"{s}\"/>\n    </keybind>\n", .{ k.key, k.action, k.to });
        } else {
            try block.print(allocator, "    <keybind key=\"{s}\"{s}>\n      <action name=\"Execute\" command=\"{s}\"/>\n    </keybind>\n", .{ k.key, onrelease, k.command });
        }
    }
    var at = close;
    while (at > 0 and (xml.items[at - 1] == ' ' or xml.items[at - 1] == '\t')) at -= 1;
    try xml.insertSlice(allocator, at, block.items);
    return try xml.toOwnedSlice(allocator);
}

/// Makes sure the labwc `autostart` script starts the panel (restarting it
/// if it exits). Returns null when it already does.
pub fn ensureAutostart(allocator: std.mem.Allocator, content: []const u8) !?[]u8 {
    const need_panel = std.mem.indexOf(u8, content, "dkde-panel") == null;
    const need_display = std.mem.indexOf(u8, content, "display.sh") == null;
    if (!need_panel and !need_display) return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, content);
    if (content.len > 0 and content[content.len - 1] != '\n') try out.append(allocator, '\n');
    if (need_panel) try out.appendSlice(allocator, "# dkde: the panel is restarted if it exits.\n(while true; do dkde-panel; sleep 1; done) &\n");
    if (need_display) try out.appendSlice(allocator, "# dkde: the display layout saved by Settings > Display.\n[ -f \"${XDG_CONFIG_HOME:-$HOME/.config}/dkde/display.sh\" ] && sh \"${XDG_CONFIG_HOME:-$HOME/.config}/dkde/display.sh\" &\n");
    return try out.toOwnedSlice(allocator);
}

test "keybinds: created in an empty config" {
    const a = std.testing.allocator;
    const out = (try mergeKeybinds(a, "", &dkde_keybinds)).?;
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "<default />") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "key=\"Super_L\" onRelease=\"yes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "dkde-snip --region") != null);
}

test "keybinds: existing ones are kept and only missing ones added" {
    const a = std.testing.allocator;
    const before =
        \\<labwc_config>
        \\  <keyboard>
        \\    <default />
        \\    <keybind key="Print"><action name="Execute" command="my-shot"/></keybind>
        \\  </keyboard>
        \\</labwc_config>
        \\
    ;
    const out = (try mergeKeybinds(a, before, &dkde_keybinds)).?;
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "my-shot") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "key=\"Print\""));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "key=\"Super_L\""));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "</keyboard>"));
}

test "keybinds: nothing to do when all are present" {
    const a = std.testing.allocator;
    const first = (try mergeKeybinds(a, "", &dkde_keybinds)).?;
    defer a.free(first);
    try std.testing.expect((try mergeKeybinds(a, first, &dkde_keybinds)) == null);
}

test "autostart: appended once" {
    const a = std.testing.allocator;
    const out = (try ensureAutostart(a, "swaybg -c black &")).?;
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "swaybg") != null);
    try std.testing.expect((try ensureAutostart(a, out)) == null);
}

test "environment: replaces an existing assignment, keeps the rest" {
    const a = std.testing.allocator;
    const before = "# keyboard\nXKB_DEFAULT_LAYOUT=us\nXCURSOR_SIZE=24\n";
    const after = try setEnvVar(a, before, "XKB_DEFAULT_LAYOUT", "de");
    defer a.free(after);
    try std.testing.expectEqualStrings("# keyboard\nXKB_DEFAULT_LAYOUT=de\nXCURSOR_SIZE=24\n", after);
}

test "environment: appends when missing and ignores commented examples" {
    const a = std.testing.allocator;
    const after = try setEnvVar(a, "# XKB_DEFAULT_LAYOUT=se\n", "XKB_DEFAULT_LAYOUT", "fr");
    defer a.free(after);
    try std.testing.expectEqualStrings("# XKB_DEFAULT_LAYOUT=se\nXKB_DEFAULT_LAYOUT=fr\n", after);

    const fresh = try setEnvVar(a, "", "XKB_DEFAULT_LAYOUT", "fr");
    defer a.free(fresh);
    try std.testing.expectEqualStrings("XKB_DEFAULT_LAYOUT=fr\n", fresh);
}

test "libinput: creates the section in an empty config" {
    const a = std.testing.allocator;
    const out = try setLibinput(a, "", "naturalScroll", "yes");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "<libinput>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<naturalScroll>yes</naturalScroll>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "</labwc_config>") != null);
}

test "libinput: updates one key and preserves everything else" {
    const a = std.testing.allocator;
    const before =
        \\<?xml version="1.0"?>
        \\<labwc_config>
        \\  <theme><name>Clearlooks</name></theme>
        \\  <!-- keep me -->
        \\  <libinput>
        \\    <device category="default">
        \\      <tap>no</tap>
        \\      <pointerSpeed>0.0</pointerSpeed>
        \\    </device>
        \\  </libinput>
        \\</labwc_config>
        \\
    ;
    const out = try setLibinput(a, before, "pointerSpeed", "0.5");
    defer a.free(out);
    const expected = std.mem.replaceOwned(u8, a, before, "<pointerSpeed>0.0</pointerSpeed>", "<pointerSpeed>0.5</pointerSpeed>") catch unreachable;
    defer a.free(expected);
    try std.testing.expectEqualStrings(expected, out);
}

test "libinput: adds a missing key to the default device" {
    const a = std.testing.allocator;
    const before =
        \\<labwc_config>
        \\  <libinput>
        \\    <device category="default">
        \\      <tap>yes</tap>
        \\    </device>
        \\  </libinput>
        \\</labwc_config>
        \\
    ;
    const out = try setLibinput(a, before, "naturalScroll", "yes");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "<tap>yes</tap>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<naturalScroll>yes</naturalScroll>") != null);
    // Still well-formed: one of each closing tag.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "</device>"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "</libinput>"));
}

test "libinput: a section without the default device gets one" {
    const a = std.testing.allocator;
    const before = "<labwc_config>\n  <libinput>\n    <device category=\"touchpad\">\n      <tap>yes</tap>\n    </device>\n  </libinput>\n</labwc_config>\n";
    const out = try setLibinput(a, before, "tap", "no");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "<device category=\"touchpad\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<device category=\"default\">") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "</device>"));
}
