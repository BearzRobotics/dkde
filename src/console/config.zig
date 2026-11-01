//! Console settings (SPEC.md 5.11, *Configuration*). One table describes every
//! key, so the loader, `dkde-console config list/get/set/reset` and the
//! Settings page all agree on names, defaults and what is valid.

const std = @import("std");
const termcore = @import("termcore");
const ini = termcore.ini;

pub const group = "console";

pub const Kind = enum { string, int, boolean, list };

pub const Key = struct {
    name: []const u8,
    kind: Kind,
    default: []const u8,
    /// Inclusive limits for `.int`.
    min: i64 = 0,
    max: i64 = 0,
    /// Allowed values for a `.string` that is a choice; empty means any.
    choices: []const []const u8 = &.{},
};

pub const color_schemes = termcore.schemes.names;

pub const keys = [_]Key{
    .{ .name = "font", .kind = .string, .default = "" },
    .{ .name = "fallback-fonts", .kind = .list, .default = "" },
    .{ .name = "font-size", .kind = .int, .default = "0", .min = 0, .max = 128 },
    .{ .name = "scale", .kind = .int, .default = "1", .min = 1, .max = 2 },
    .{ .name = "colors", .kind = .string, .default = "campbell", .choices = &color_schemes },
    .{ .name = "scrollback-lines", .kind = .int, .default = "2000", .min = 0, .max = 100000 },
    .{ .name = "cursor-blink", .kind = .boolean, .default = "false" },
    .{ .name = "fallback", .kind = .string, .default = "/sbin/agetty --noclear tty%N linux" },
    .{ .name = "image-memory", .kind = .int, .default = "32", .min = 0, .max = 4096 },
};

pub fn find(name: []const u8) ?*const Key {
    for (&keys) |*k| if (std.mem.eql(u8, k.name, name)) return k;
    return null;
}

pub const Source = enum { default, system_defaults, etc, vt };

pub const Value = struct { text: []const u8, source: Source };

/// Why a value was refused; `check` returns null for a good one.
pub fn check(key: *const Key, value: []const u8) ?[]const u8 {
    switch (key.kind) {
        .string, .list => {
            if (key.choices.len > 0) {
                for (key.choices) |c| if (std.mem.eql(u8, c, value)) return null;
                return "not one of the known choices";
            }
            return null;
        },
        .int => {
            const n = std.fmt.parseInt(i64, value, 10) catch return "not a whole number";
            if (n < key.min or n > key.max) return "out of range";
            return null;
        },
        .boolean => {
            if (ini.parseBool(value) == null) return "must be true or false";
            return null;
        },
    }
}

/// The layers a value can come from, most specific first. Either document may
/// be absent (no file).
pub const Layers = struct {
    etc: ?*const ini.Document = null,
    defaults: ?*const ini.Document = null,
};

/// Look up `key` for `vt` (0 = no VT): `[vt:N]` in /etc, then `[console]` in
/// /etc, then the shipped defaults file, then the compiled-in default. A value
/// that fails `check` is skipped, so a typo never breaks the console.
pub fn lookup(layers: Layers, vt: u32, key: *const Key) Value {
    var gbuf: [24]u8 = undefined;
    const vt_group = std.fmt.bufPrint(&gbuf, "vt:{d}", .{vt}) catch "";
    if (layers.etc) |d| {
        if (vt != 0) if (d.get(vt_group, key.name)) |v| if (check(key, v) == null) return .{ .text = v, .source = .vt };
        if (d.get(group, key.name)) |v| if (check(key, v) == null) return .{ .text = v, .source = .etc };
    }
    if (layers.defaults) |d| {
        if (d.get(group, key.name)) |v| if (check(key, v) == null) return .{ .text = v, .source = .system_defaults };
    }
    return .{ .text = key.default, .source = .default };
}

/// Typed, resolved settings for one VT.
pub const Settings = struct {
    font: []const u8,
    fallback_fonts: []const u8,
    font_size: u32,
    scale: u32,
    colors: []const u8,
    scrollback_lines: u32,
    cursor_blink: bool,
    fallback: []const u8,
    image_memory_mb: u32,

    pub fn resolve(layers: Layers, vt: u32) Settings {
        const L = struct {
            fn get(l: Layers, v: u32, name: []const u8) []const u8 {
                return lookup(l, v, find(name).?).text;
            }
            fn int(l: Layers, v: u32, name: []const u8) u32 {
                return std.fmt.parseInt(u32, get(l, v, name), 10) catch 0;
            }
        };
        return .{
            .font = L.get(layers, vt, "font"),
            .fallback_fonts = L.get(layers, vt, "fallback-fonts"),
            .font_size = L.int(layers, vt, "font-size"),
            .scale = @max(1, L.int(layers, vt, "scale")),
            .colors = L.get(layers, vt, "colors"),
            .scrollback_lines = L.int(layers, vt, "scrollback-lines"),
            .cursor_blink = ini.parseBool(L.get(layers, vt, "cursor-blink")) orelse false,
            .fallback = L.get(layers, vt, "fallback"),
            .image_memory_mb = L.int(layers, vt, "image-memory"),
        };
    }
};

/// Expand `%N` in the fallback command with the VT number.
pub fn expandFallback(out: *std.Io.Writer, template: []const u8, vt: u32) !void {
    var i: usize = 0;
    while (i < template.len) : (i += 1) {
        if (template[i] == '%' and i + 1 < template.len and template[i + 1] == 'N') {
            try out.print("{d}", .{vt});
            i += 1;
        } else try out.writeByte(template[i]);
    }
}

const testing = std.testing;

test "defaults when there is no file" {
    const s = Settings.resolve(.{}, 1);
    try testing.expectEqual(@as(u32, 2000), s.scrollback_lines);
    try testing.expectEqualStrings("campbell", s.colors);
    try testing.expect(!s.cursor_blink);
    try testing.expectEqual(@as(u32, 1), s.scale);
}

test "vt section beats console section beats defaults file" {
    var etc = try ini.Document.parse(testing.allocator, "[console]\nfont-size=24\nscale=2\n[vt:2]\nfont-size=32\n");
    defer etc.deinit();
    var defs = try ini.Document.parse(testing.allocator, "[console]\nscrollback-lines=500\nscale=1\n");
    defer defs.deinit();
    const layers: Layers = .{ .etc = &etc, .defaults = &defs };
    const s1 = Settings.resolve(layers, 1);
    const s2 = Settings.resolve(layers, 2);
    try testing.expectEqual(@as(u32, 24), s1.font_size);
    try testing.expectEqual(@as(u32, 32), s2.font_size);
    try testing.expectEqual(@as(u32, 2), s2.scale);
    try testing.expectEqual(@as(u32, 500), s1.scrollback_lines);
    try testing.expectEqual(Source.vt, lookup(layers, 2, find("font-size").?).source);
    try testing.expectEqual(Source.system_defaults, lookup(layers, 1, find("scrollback-lines").?).source);
    try testing.expectEqual(Source.default, lookup(layers, 1, find("colors").?).source);
}

test "invalid values fall back instead of failing" {
    var etc = try ini.Document.parse(testing.allocator, "[console]\nscale=7\ncolors=neon\ncursor-blink=maybe\nscrollback-lines=-3\n");
    defer etc.deinit();
    const s = Settings.resolve(.{ .etc = &etc }, 1);
    try testing.expectEqual(@as(u32, 1), s.scale);
    try testing.expectEqualStrings("campbell", s.colors);
    try testing.expect(!s.cursor_blink);
    try testing.expectEqual(@as(u32, 2000), s.scrollback_lines);
}

test "check explains refusals" {
    try testing.expect(check(find("scale").?, "2") == null);
    try testing.expect(check(find("scale").?, "3") != null);
    try testing.expect(check(find("colors").?, "campbell") == null);
    try testing.expect(check(find("colors").?, "x") != null);
    try testing.expect(check(find("cursor-blink").?, "true") == null);
}

test "fallback expands the vt number" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try expandFallback(&aw.writer, "/sbin/agetty --noclear tty%N linux", 3);
    try testing.expectEqualStrings("/sbin/agetty --noclear tty3 linux", aw.written());
}
