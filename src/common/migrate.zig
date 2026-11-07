//! One-time conversion of the old INI configuration to TOML
//! (ai/DKDE-SPEC.md sections 19.5 and 23). Run on request by
//! `dkde-setup --migrate-config`; no program converts files by itself.
//!
//! What it does for each legacy `<name>.conf` in the user's config directory:
//!   1. Reads it with GKeyFile, the reader that wrote it.
//!   2. Writes `<name>.toml` next to it (atomically), unless that file exists.
//!   3. Renames the original to `<name>.conf.migrated`. The original text is
//!      kept, byte for byte, so nothing is lost; it is never deleted.
//!
//! Types come from the text: `true`/`false` become booleans, whole numbers
//! become integers, keys named in `list_keys` become arrays (split on `;`
//! with GKeyFile's own rules), everything else is a string. Comments are not
//! carried over (they are in the `.migrated` file).

const std = @import("std");
const toml = @import("toml");
const glib = @import("glib2");
const fsio = @import("fsio.zig");

const paths = @import("paths.zig");

const log = std.log.scoped(.migrate);

/// Legacy files, by base name.
pub const legacy_names = [_][]const u8{ "dkde", "panel", "term", "files", "edit", "calendar", "desktop" };

const ListKey = struct { file: []const u8, group: []const u8, key: []const u8 };

/// Keys that held `;`-separated lists and are arrays now. Everything the code
/// reads with `getStringList`.
pub const list_keys = [_]ListKey{
    .{ .file = "panel", .group = "panel", .key = "quick-settings" },
    .{ .file = "panel", .group = "panel", .key = "taskbar-pinned" },
    .{ .file = "panel", .group = "menu", .key = "pinned" },
    .{ .file = "files", .group = "bookmarks", .key = "paths" },
};

pub const Outcome = enum {
    /// Converted; the original is now `<name>.conf.migrated`.
    migrated,
    /// No legacy file: nothing to do.
    absent,
    /// `<name>.toml` already exists; both files were left alone.
    toml_exists,
};

fn isList(file: []const u8, group: []const u8, key: []const u8) bool {
    for (list_keys) |l| {
        if (std.mem.eql(u8, l.file, file) and std.mem.eql(u8, l.group, group) and std.mem.eql(u8, l.key, key)) return true;
    }
    return false;
}

/// Is `raw` (an INI value, still escaped) a plain integer that fits `i32`?
fn asInteger(raw: []const u8) ?i32 {
    if (raw.len == 0 or raw.len > 11) return null;
    for (raw, 0..) |c, i| {
        if (!(std.ascii.isDigit(c) or (i == 0 and c == '-' and raw.len > 1))) return null;
    }
    return std.fmt.parseInt(i32, raw, 10) catch null;
}

/// Converts INI `text` to a TOML document. `file` is the base name ("panel").
pub fn convertText(allocator: std.mem.Allocator, file: []const u8, text: []const u8) !toml.Document {
    const kf = glib.KeyFile.new();
    defer kf.free();
    const z = try allocator.dupeSentinel(u8, text, 0);
    defer allocator.free(z);
    var err: ?*glib.Error = null;
    if (kf.loadFromData(z, text.len, .{}, &err) == 0) {
        if (err) |e| {
            log.warn("{s}.conf: {s}", .{ file, e.f_message orelse "not an INI file" });
            e.free();
        }
        return error.NotIni;
    }

    var doc = try toml.Document.init(allocator);
    errdefer doc.deinit();
    const a = doc.allocator();

    var n_groups: usize = 0;
    const groups = kf.getGroups(&n_groups);
    defer glib.strfreev(groups);
    for (groups[0..n_groups]) |group_z| {
        const group = std.mem.span(group_z.?);
        var n_keys: usize = 0;
        const keys = kf.getKeys(group_z.?, &n_keys, null) orelse continue;
        defer glib.strfreev(keys);
        for (keys[0..n_keys]) |key_z| {
            const key = std.mem.span(key_z.?);
            const raw_z = kf.getValue(group_z.?, key_z.?, null) orelse continue;
            defer glib.free(raw_z);
            const raw = std.mem.span(raw_z);

            const value: toml.Value = if (isList(file, group, key)) blk: {
                var len: usize = 0;
                const list = kf.getStringList(group_z.?, key_z.?, &len, null);
                defer if (list != null) glib.strfreev(list);
                const arr = try a.create(toml.Array);
                arr.* = .{};
                if (list) |l| for (l[0..len]) |item| try arr.items.append(a, .{ .string = try doc.dupe(std.mem.span(item.?)) });
                break :blk .{ .array = arr };
            } else if (std.mem.eql(u8, raw, "true"))
                .{ .boolean = true }
            else if (std.mem.eql(u8, raw, "false"))
                .{ .boolean = false }
            else if (asInteger(raw)) |i|
                .{ .integer = i }
            else blk: {
                const s = kf.getString(group_z.?, key_z.?, null) orelse break :blk toml.Value{ .string = try doc.dupe(raw) };
                defer glib.free(s);
                break :blk .{ .string = try doc.dupe(std.mem.span(s)) };
            };
            try doc.set(&.{ group, key }, value);
        }
    }
    return doc;
}

/// Migrates `<dir>/<name>.conf` to `<dir>/<name>.toml`. `dir` is the user's
/// dkde config directory.
pub fn migrateFile(allocator: std.mem.Allocator, dir: []const u8, name: []const u8) !Outcome {
    const legacy = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}.conf", .{ dir, name }, 0);
    defer allocator.free(legacy);
    const target = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}.toml", .{ dir, name }, 0);
    defer allocator.free(target);
    const backup = try std.fmt.allocPrintSentinel(allocator, "{s}.migrated", .{legacy}, 0);
    defer allocator.free(backup);

    if (!fsio.exists(legacy)) return .absent;
    if (fsio.exists(target)) return .toml_exists;

    const contents = (fsio.readFile(allocator, legacy, 1 << 20) catch return error.ReadFailed) orelse return error.ReadFailed;
    defer allocator.free(contents);

    var doc = try convertText(allocator, name, contents);
    defer doc.deinit();
    const text = try doc.toOwnedString(allocator);
    defer allocator.free(text);

    // Write the new file first and rename the old one last: an interruption
    // leaves both files, and the next run reports `toml_exists` rather than
    // converting again.
    fsio.writeFileAtomic(target, text) catch return error.WriteFailed;
    if (std.c.rename(legacy, backup) != 0) return error.BackupFailed;
    return .migrated;
}

/// Migrates every known legacy file of the current user. Calls
/// `report(name, outcome_or_error)` for each file that exists.
pub fn migrateUser(allocator: std.mem.Allocator, context: anytype, comptime report: fn (@TypeOf(context), []const u8, anyerror!Outcome) void) !void {
    const dir = try std.fmt.allocPrint(allocator, "{s}/dkde", .{std.mem.span(glib.getUserConfigDir())});
    defer allocator.free(dir);
    for (legacy_names) |name| {
        const result = migrateFile(allocator, dir, name);
        if (result) |outcome| {
            if (outcome == .absent) continue;
        } else |_| {}
        report(context, name, result);
    }
}

/// True when the user has an old `<name>.conf` and no `<name>.toml`. Used to
/// tell the user to run the migration; it never converts anything itself.
pub fn legacyPending(allocator: std.mem.Allocator, name: []const u8) bool {
    const dir = glib.getUserConfigDir();
    const legacy = std.fmt.allocPrintSentinel(allocator, "{s}/dkde/{s}.conf", .{ std.mem.span(dir), name }, 0) catch return false;
    defer allocator.free(legacy);
    const target = std.fmt.allocPrintSentinel(allocator, "{s}/dkde/{s}.toml", .{ std.mem.span(dir), name }, 0) catch return false;
    defer allocator.free(target);
    return fsio.exists(legacy) and !fsio.exists(target);
}

// ---- tests ---------------------------------------------------------------------------------

test "types are taken from the text" {
    const a = std.testing.allocator;
    var doc = try convertText(a, "panel",
        \\# a comment
        \\[panel]
        \\height=48
        \\autohide=true
        \\position=top
        \\clock-format=%H:%M\n%d
        \\quick-settings=network;sound;
        \\taskbar-pinned=
        \\[menu]
        \\pinned=a.desktop;b.desktop
        \\[profile:Default]
        \\font=Monospace 11
        \\accent=#3584e4
        \\name=5x5
        \\neg=-3
        \\big=99999999999
    );
    defer doc.deinit();
    const r = doc.root;
    try std.testing.expectEqual(@as(i64, 48), r.lookup("panel.height").?.integer);
    try std.testing.expectEqual(true, r.lookup("panel.autohide").?.boolean);
    try std.testing.expectEqualStrings("top", r.lookup("panel.position").?.string);
    // GKeyFile's \n escape becomes a real newline.
    try std.testing.expectEqualStrings("%H:%M\n%d", r.lookup("panel.clock-format").?.string);
    try std.testing.expectEqual(@as(usize, 2), r.getTable("panel").?.getArray("quick-settings").?.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), r.getTable("panel").?.getArray("taskbar-pinned").?.items.items.len);
    try std.testing.expectEqual(@as(usize, 2), r.getTable("menu").?.getArray("pinned").?.items.items.len);
    // A group name with a colon survives as a quoted table name.
    try std.testing.expectEqualStrings("Monospace 11", r.getTable("profile:Default").?.getString("font").?);
    try std.testing.expectEqualStrings("#3584e4", r.getTable("profile:Default").?.getString("accent").?);
    try std.testing.expectEqualStrings("5x5", r.getTable("profile:Default").?.getString("name").?);
    try std.testing.expectEqual(@as(i64, -3), r.getTable("profile:Default").?.getInt("neg").?);
    // Too big for i32: stays text rather than changing value.
    try std.testing.expectEqualStrings("99999999999", r.getTable("profile:Default").?.getString("big").?);
}

test "the converted text parses back to the same values" {
    const a = std.testing.allocator;
    var doc = try convertText(a, "term", "[\"x\"]\n[profile:A b]\ncommand=sh -c \"echo \\\"hi\\\"\"\nenvironment=A=1;B=2\n");
    defer doc.deinit();
    const text = try doc.toOwnedString(a);
    defer a.free(text);
    var again = try toml.Document.parse(a, text, .{}, null);
    defer again.deinit();
    const t = again.root.getTable("profile:A b").?;
    try std.testing.expectEqualStrings("sh -c \"echo \\\"hi\\\"\"", t.getString("command").?);
    try std.testing.expectEqualStrings("A=1;B=2", t.getString("environment").?);
}

test "not an INI file is rejected, nothing is written" {
    try std.testing.expectError(error.NotIni, convertText(std.testing.allocator, "x", "this is not ini\n"));
}

fn tmpDir() ![:0]u8 {
    const d = glib.Dir.makeTmp("dkde-migrate-XXXXXX", null) orelse return error.NoTmp;
    defer glib.free(d);
    return std.testing.allocator.dupeSentinel(u8, std.mem.span(d), 0);
}

fn put(a: std.mem.Allocator, dir: []const u8, name: []const u8, text: []const u8) !void {
    const p = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dir, name }, 0);
    defer a.free(p);
    try fsio.writeFileAtomic(p, text);
}

fn slurp(a: std.mem.Allocator, dir: []const u8, name: []const u8) !?[]u8 {
    const p = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dir, name }, 0);
    defer a.free(p);
    return try fsio.readFile(a, p, 1 << 20);
}

test "migrating keeps the original, and a second run changes nothing" {
    const a = std.testing.allocator;
    const dir = try tmpDir();
    defer a.free(dir);
    const original = "# mine\n[panel]\nheight=48\n";
    try put(a, dir, "panel.conf", original);

    try std.testing.expectEqual(Outcome.migrated, try migrateFile(a, dir, "panel"));
    const kept = (try slurp(a, dir, "panel.conf.migrated")).?;
    defer a.free(kept);
    try std.testing.expectEqualStrings(original, kept);
    try std.testing.expect((try slurp(a, dir, "panel.conf")) == null);
    const out = (try slurp(a, dir, "panel.toml")).?;
    defer a.free(out);
    try std.testing.expectEqualStrings("[panel]\nheight = 48\n", out);

    try std.testing.expectEqual(Outcome.absent, try migrateFile(a, dir, "panel"));
}

test "an existing toml file is never overwritten" {
    const a = std.testing.allocator;
    const dir = try tmpDir();
    defer a.free(dir);
    try put(a, dir, "files.conf", "[files]\nview=list\n");
    try put(a, dir, "files.toml", "[files]\nview = \"small\"\n");
    try std.testing.expectEqual(Outcome.toml_exists, try migrateFile(a, dir, "files"));
    const toml_text = (try slurp(a, dir, "files.toml")).?;
    defer a.free(toml_text);
    try std.testing.expectEqualStrings("[files]\nview = \"small\"\n", toml_text);
    const legacy = (try slurp(a, dir, "files.conf")).?;
    defer a.free(legacy);
    try std.testing.expectEqualStrings("[files]\nview=list\n", legacy);
}

test "a file that is not INI is left alone" {
    const a = std.testing.allocator;
    const dir = try tmpDir();
    defer a.free(dir);
    try put(a, dir, "edit.conf", "garbage without a group\n");
    try std.testing.expectError(error.NotIni, migrateFile(a, dir, "edit"));
    const left = (try slurp(a, dir, "edit.conf")).?;
    defer a.free(left);
    try std.testing.expectEqualStrings("garbage without a group\n", left);
    try std.testing.expect((try slurp(a, dir, "edit.toml")) == null);
}
