//! Window rules, with no wlroots in it: `[[rules]]` in compositor.toml say what to do with a window
//! that matches an application id or a title. dkde-wm can read the same rules.
//!
//!   [[rules]]
//!   app_id = "dkde-calc"      # glob: * any run of characters, ? any one character
//!   title = "*Preferences*"   # both must match when both are given; matching ignores case
//!   floating = true           # and any of: workspace = 2, sticky, above, below, maximized,
//!   workspace = 2             # fullscreen, opacity = 0.9, position = "center", x, y, width, height

const std = @import("std");
const toml = @import("toml");
const place = @import("place.zig");

pub const Rule = struct {
    app_id: ?[]const u8 = null,
    title: ?[]const u8 = null,
    floating: ?bool = null,
    /// 0-based.
    workspace: ?u8 = null,
    sticky: ?bool = null,
    above: ?bool = null,
    below: ?bool = null,
    maximized: ?bool = null,
    fullscreen: ?bool = null,
    opacity: ?f32 = null,
    position: ?place.Position = null,
    x: ?i32 = null,
    y: ?i32 = null,
    width: ?i32 = null,
    height: ?i32 = null,
};

/// Case-insensitive glob: `*` is any run of characters, `?` any single one.
pub fn glob(pattern: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;
    while (t < text.len) {
        if (p < pattern.len and (pattern[p] == '?' or std.ascii.toLower(pattern[p]) == std.ascii.toLower(text[t]))) {
            p += 1;
            t += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star = p;
            p += 1;
            mark = t;
        } else if (star) |s| {
            p = s + 1;
            mark += 1;
            t = mark;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

pub fn matches(rule: Rule, app_id: []const u8, title: []const u8) bool {
    if (rule.app_id == null and rule.title == null) return false; // a rule must name something
    if (rule.app_id) |a| if (!glob(a, app_id)) return false;
    if (rule.title) |t| if (!glob(t, title)) return false;
    return true;
}

/// The rules that match, later ones overriding earlier ones field by field.
pub fn resolve(rules: []const Rule, app_id: []const u8, title: []const u8) Rule {
    var out: Rule = .{};
    for (rules) |r| {
        if (!matches(r, app_id, title)) continue;
        if (r.floating != null) out.floating = r.floating;
        if (r.workspace != null) out.workspace = r.workspace;
        if (r.sticky != null) out.sticky = r.sticky;
        if (r.above != null) out.above = r.above;
        if (r.below != null) out.below = r.below;
        if (r.maximized != null) out.maximized = r.maximized;
        if (r.fullscreen != null) out.fullscreen = r.fullscreen;
        if (r.opacity != null) out.opacity = r.opacity;
        if (r.position != null) out.position = r.position;
        if (r.x != null) out.x = r.x;
        if (r.y != null) out.y = r.y;
        if (r.width != null) out.width = r.width;
        if (r.height != null) out.height = r.height;
    }
    return out;
}

pub fn freeAll(gpa: std.mem.Allocator, rules: []const Rule) void {
    for (rules) |r| {
        if (r.app_id) |a| gpa.free(a);
        if (r.title) |t| gpa.free(t);
    }
    gpa.free(rules);
}

fn boolField(t: *const toml.Table, key: []const u8, gpa: std.mem.Allocator, warnings: *std.ArrayList([]const u8)) !?bool {
    const v = t.get(key) orelse return null;
    switch (v) {
        .boolean => |b| return b,
        else => {
            try warnings.append(gpa, try std.fmt.allocPrint(gpa, "[[rules]] {s}: expected true or false; ignored", .{key}));
            return null;
        },
    }
}

fn intField(t: *const toml.Table, key: []const u8, lo: i64, hi: i64, gpa: std.mem.Allocator, warnings: *std.ArrayList([]const u8)) !?i32 {
    const v = t.get(key) orelse return null;
    switch (v) {
        .integer => |i| {
            if (i < lo or i > hi) {
                try warnings.append(gpa, try std.fmt.allocPrint(gpa, "[[rules]] {s} = {d}: expected {d} to {d}; ignored", .{ key, i, lo, hi }));
                return null;
            }
            return @intCast(i);
        },
        else => {
            try warnings.append(gpa, try std.fmt.allocPrint(gpa, "[[rules]] {s}: expected an integer; ignored", .{key}));
            return null;
        },
    }
}

/// Reads `[[rules]]` from the document root. Problems go to `warnings`; the result is owned (`freeAll`).
pub fn parse(gpa: std.mem.Allocator, root: *const toml.Table, warnings: *std.ArrayList([]const u8)) ![]Rule {
    var list: std.ArrayList(Rule) = .empty;
    errdefer {
        for (list.items) |r| {
            if (r.app_id) |a| gpa.free(a);
            if (r.title) |t| gpa.free(t);
        }
        list.deinit(gpa);
    }
    const array = root.getArray("rules") orelse return list.toOwnedSlice(gpa);
    for (array.items.items) |item| {
        const t = switch (item) {
            .table => |tt| tt,
            else => continue,
        };
        var r: Rule = .{};
        if (t.getString("app_id")) |s| r.app_id = try gpa.dupe(u8, s);
        errdefer if (r.app_id) |a| gpa.free(a);
        if (t.getString("title")) |s| r.title = try gpa.dupe(u8, s);
        if (r.app_id == null and r.title == null) {
            try warnings.append(gpa, try gpa.dupe(u8, "[[rules]] needs an app_id or a title to match; ignored"));
            continue;
        }
        r.floating = try boolField(t, "floating", gpa, warnings);
        r.sticky = try boolField(t, "sticky", gpa, warnings);
        r.above = try boolField(t, "above", gpa, warnings);
        r.below = try boolField(t, "below", gpa, warnings);
        r.maximized = try boolField(t, "maximized", gpa, warnings);
        r.fullscreen = try boolField(t, "fullscreen", gpa, warnings);
        if (try intField(t, "workspace", 1, 9, gpa, warnings)) |n| r.workspace = @intCast(n - 1);
        r.x = try intField(t, "x", -20000, 20000, gpa, warnings);
        r.y = try intField(t, "y", -20000, 20000, gpa, warnings);
        r.width = try intField(t, "width", 50, 20000, gpa, warnings);
        r.height = try intField(t, "height", 50, 20000, gpa, warnings);
        if (t.get("opacity")) |v| {
            const f: ?f64 = switch (v) {
                .float => |x| x,
                .integer => |i| @floatFromInt(i),
                else => null,
            };
            if (f != null and f.? >= 0.1 and f.? <= 1.0) {
                r.opacity = @floatCast(f.?);
            } else try warnings.append(gpa, try gpa.dupe(u8, "[[rules]] opacity: expected 0.1 to 1; ignored"));
        }
        if (t.getString("position")) |s| {
            r.position = place.parsePosition(s);
            if (r.position == null) try warnings.append(gpa, try std.fmt.allocPrint(gpa, "[[rules]] position = \"{s}\": not a position; ignored", .{s}));
        }
        try list.append(gpa, r);
    }
    return list.toOwnedSlice(gpa);
}

test "globs" {
    try std.testing.expect(glob("dkde-*", "dkde-calc"));
    try std.testing.expect(glob("*Pref*", "App Preferences"));
    try std.testing.expect(glob("FIREFOX", "firefox"));
    try std.testing.expect(glob("a?c", "abc"));
    try std.testing.expect(!glob("a?c", "ac"));
    try std.testing.expect(!glob("dkde-*", "other"));
    try std.testing.expect(glob("*", ""));
}

test "rules resolve in order" {
    const rules = [_]Rule{
        .{ .app_id = "dkde-*", .opacity = 0.9, .floating = true },
        .{ .app_id = "dkde-calc", .opacity = 0.8, .workspace = 1 },
        .{ .app_id = "other", .sticky = true },
        .{ .floating = true }, // names nothing: never matches
    };
    const r = resolve(&rules, "dkde-calc", "Calculator");
    try std.testing.expectEqual(@as(?f32, 0.8), r.opacity);
    try std.testing.expectEqual(@as(?bool, true), r.floating);
    try std.testing.expectEqual(@as(?u8, 1), r.workspace);
    try std.testing.expect(r.sticky == null);
    const none = resolve(&rules, "xterm", "x");
    try std.testing.expect(none.opacity == null and none.floating == null);
}

test "rules parse from TOML" {
    const gpa = std.testing.allocator;
    var doc = try toml.Document.parse(gpa,
        \\[[rules]]
        \\app_id = "mpv"
        \\floating = true
        \\position = "bottom-right"
        \\opacity = 0.9
        \\[[rules]]
        \\title = "*Settings*"
        \\workspace = 3
        \\width = 700
        \\[[rules]]
        \\floating = true
        \\[[rules]]
        \\app_id = "x"
        \\workspace = 12
    , .{}, null);
    defer doc.deinit();
    var warnings: std.ArrayList([]const u8) = .empty;
    defer {
        for (warnings.items) |w| gpa.free(w);
        warnings.deinit(gpa);
    }
    const rules = try parse(gpa, doc.root, &warnings);
    defer freeAll(gpa, rules);
    try std.testing.expectEqual(@as(usize, 3), rules.len);
    try std.testing.expectEqual(place.Position.bottom_right, rules[0].position.?);
    try std.testing.expectEqual(@as(?u8, 2), rules[1].workspace);
    try std.testing.expectEqual(@as(?i32, 700), rules[1].width);
    try std.testing.expect(rules[2].workspace == null);
    try std.testing.expectEqual(@as(usize, 2), warnings.items.len);
}
