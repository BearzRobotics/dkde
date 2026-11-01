//! Facts about the computer and its locale, for the About and Language &
//! region pages (SPEC.md 5.5). Pure functions over file contents, so they are
//! unit tested; the pages read the files.

const std = @import("std");

/// `PRETTY_NAME` of an os-release file, without its quotes.
pub fn osPrettyName(content: []const u8) ?[]const u8 {
    return shellValue(content, "PRETTY_NAME") orelse shellValue(content, "NAME");
}

/// The value of `KEY=value` or `KEY="value"` (a shell-style assignment file,
/// like os-release and locale.conf), or null.
pub fn shellValue(content: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    var found: ?[]const u8 = null;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len <= key.len or line[0] == '#') continue;
        if (!std.mem.startsWith(u8, line, key) or line[key.len] != '=') continue;
        var v = std.mem.trim(u8, line[key.len + 1 ..], " \t");
        if (v.len >= 2 and (v[0] == '"' or v[0] == '\'') and v[v.len - 1] == v[0]) v = v[1 .. v.len - 1];
        found = v; // the last assignment wins, as when the file is sourced
    }
    return found;
}

pub const Cpu = struct { model: []const u8, logical: u32 };

/// The first model name and the number of logical processors in /proc/cpuinfo.
pub fn parseCpu(content: []const u8) Cpu {
    var model: []const u8 = "";
    var n: u32 = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "processor")) n += 1;
        // x86 says "model name", ARM "Model" or "Hardware".
        if (model.len == 0 and (std.mem.startsWith(u8, line, "model name") or std.mem.startsWith(u8, line, "Hardware"))) {
            if (std.mem.indexOfScalar(u8, line, ':')) |i| model = std.mem.trim(u8, line[i + 1 ..], " \t");
        }
    }
    return .{ .model = model, .logical = n };
}

/// `MemTotal` of /proc/meminfo in kB.
pub fn memTotalKb(content: []const u8) ?u64 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "MemTotal:")) continue;
        var it = std.mem.tokenizeAny(u8, line["MemTotal:".len..], " \tkB");
        return std.fmt.parseInt(u64, it.next() orelse return null, 10) catch null;
    }
    return null;
}

/// "7.7 GB", "512 MB": the size as people read it (1024-based, as the
/// Task Manager shows memory).
pub fn formatBytes(buf: []u8, bytes: u64) []const u8 {
    const f: f64 = @floatFromInt(bytes);
    return (if (bytes >= 1 << 40)
        std.fmt.bufPrint(buf, "{d:.1} TB", .{f / (1 << 40)})
    else if (bytes >= 1 << 30)
        std.fmt.bufPrint(buf, "{d:.1} GB", .{f / (1 << 30)})
    else
        std.fmt.bufPrint(buf, "{d} MB", .{bytes >> 20})) catch "";
}

// ---- locales ----------------------------------------------------------------

/// Locale names the system can use, from the output of `locale -a`: UTF-8 ones
/// only (a terminal and GTK want UTF-8), each once, sorted, `C` and `POSIX`
/// left out. `en_US.utf8` and `en_US.UTF-8` are the same locale; the form
/// written is `en_US.UTF-8`.
pub fn usableLocales(allocator: std.mem.Allocator, listing: []const u8) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |l| allocator.free(l);
        out.deinit(allocator);
    }
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |raw| {
        const name = std.mem.trim(u8, raw, " \t\r");
        const dot = std.mem.indexOfScalar(u8, name, '.') orelse continue;
        if (!std.ascii.eqlIgnoreCase(name[dot + 1 ..], "utf8") and !std.ascii.eqlIgnoreCase(name[dot + 1 ..], "utf-8")) continue;
        if (name[0] == '.' or std.mem.startsWith(u8, name, "C.")) continue;
        const norm = try std.fmt.allocPrint(allocator, "{s}.UTF-8", .{name[0..dot]});
        errdefer allocator.free(norm);
        var seen = false;
        for (out.items) |o| {
            if (std.mem.eql(u8, o, norm)) seen = true;
        }
        if (seen) {
            allocator.free(norm);
            continue;
        }
        try out.append(allocator, norm);
    }
    std.mem.sort([]u8, out.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return out.toOwnedSlice(allocator);
}

/// Keys the region settings write, in file order.
pub const locale_keys = [_][]const u8{ "LANG", "LANGUAGE", "LC_TIME", "LC_NUMERIC", "LC_MONETARY", "LC_PAPER", "LC_MEASUREMENT" };

/// `content` (a locale.conf) with `key` set to `value`, or removed when
/// `value` is empty. Other lines, comments included, stay as they are.
pub fn setAssignment(allocator: std.mem.Allocator, content: []const u8, key: []const u8, value: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;
    var replaced = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        // A final newline makes an empty last piece; it is not a line.
        if (lines.peek() == null and raw.len == 0) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len > key.len and std.mem.startsWith(u8, line, key) and line[key.len] == '=') {
            if (value.len > 0 and !replaced) {
                try w.print("{s}={s}\n", .{ key, value });
                replaced = true;
            }
            continue;
        }
        try w.print("{s}\n", .{raw});
    }
    if (value.len > 0 and !replaced) try w.print("{s}={s}\n", .{ key, value });
    return aw.toOwnedSlice();
}

/// Whether a locale name is safe to write into a shell-sourced file: letters,
/// digits and `_.@-` only, so a value can never carry shell syntax.
pub fn validLocaleName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '.' and c != '@' and c != '-') return false;
    }
    return true;
}

test "os-release" {
    const text = "NAME=\"Ubuntu\"\nPRETTY_NAME=\"Ubuntu 24.04 LTS\"\nID=ubuntu\n";
    try std.testing.expectEqualStrings("Ubuntu 24.04 LTS", osPrettyName(text).?);
    try std.testing.expectEqualStrings("Alpine", osPrettyName("NAME=Alpine\n").?);
    try std.testing.expect(osPrettyName("ID=x\n") == null);
}

test "cpu and memory" {
    const c = parseCpu("processor\t: 0\nmodel name\t: AMD Ryzen 5 4600H\nprocessor\t: 1\nmodel name\t: AMD Ryzen 5 4600H\n");
    try std.testing.expectEqualStrings("AMD Ryzen 5 4600H", c.model);
    try std.testing.expectEqual(@as(u32, 2), c.logical);
    try std.testing.expectEqual(@as(u64, 8000000), memTotalKb("MemTotal:        8000000 kB\nMemFree: 1 kB\n").?);
    var b: [32]u8 = undefined;
    try std.testing.expectEqualStrings("7.6 GB", formatBytes(&b, 8000000 * 1024));
    try std.testing.expectEqualStrings("512 MB", formatBytes(&b, 512 << 20));
}

test "usable locales" {
    const a = std.testing.allocator;
    const list = try usableLocales(a, "C\nC.utf8\nPOSIX\nen_US\nen_US.utf8\nde_DE.UTF-8\nfr_FR.ISO-8859-1\nen_US.UTF-8\n");
    defer {
        for (list) |l| a.free(l);
        a.free(list);
    }
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("de_DE.UTF-8", list[0]);
    try std.testing.expectEqualStrings("en_US.UTF-8", list[1]);
}

test "set and remove an assignment, keeping the rest" {
    const a = std.testing.allocator;
    const one = try setAssignment(a, "# mine\nLANG=en_US.UTF-8\nFOO=1\n", "LANG", "de_DE.UTF-8");
    defer a.free(one);
    try std.testing.expectEqualStrings("# mine\nLANG=de_DE.UTF-8\nFOO=1\n", one);
    const two = try setAssignment(a, one, "LC_TIME", "en_GB.UTF-8");
    defer a.free(two);
    try std.testing.expectEqualStrings("# mine\nLANG=de_DE.UTF-8\nFOO=1\nLC_TIME=en_GB.UTF-8\n", two);
    const three = try setAssignment(a, two, "LANG", "");
    defer a.free(three);
    try std.testing.expectEqualStrings("# mine\nFOO=1\nLC_TIME=en_GB.UTF-8\n", three);
    const empty = try setAssignment(a, "", "LANG", "en_US.UTF-8");
    defer a.free(empty);
    try std.testing.expectEqualStrings("LANG=en_US.UTF-8\n", empty);
}

test "locale names cannot carry shell syntax" {
    try std.testing.expect(validLocaleName("en_US.UTF-8"));
    try std.testing.expect(validLocaleName("sr_RS@latin"));
    try std.testing.expect(!validLocaleName("en;rm -rf"));
    try std.testing.expect(!validLocaleName("$(x)"));
    try std.testing.expect(!validLocaleName(""));
}
