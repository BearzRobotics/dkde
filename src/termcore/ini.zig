//! INI reader and writer that keeps the file's own text (SPEC.md 5.11,
//! *Configuration*). It reads the same files as GLib's `GKeyFile` but links
//! nothing: comments, blank lines and unknown keys survive an edit, so a
//! file the user wrote by hand is never reformatted.
//!
//! Format: `[group]` headers, `key=value` lines (whitespace around the key and
//! the value is dropped), and `#` or `;` comment lines. Group names may
//! contain any character except `]`, so `[vt:2]` is a group.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Document = struct {
    allocator: Allocator,
    /// Every line of the file without its newline, in order. Edits replace,
    /// insert or delete lines here; `write` joins them again.
    lines: std.ArrayList([]u8) = .empty,

    pub fn init(allocator: Allocator) Document {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Document) void {
        for (self.lines.items) |l| self.allocator.free(l);
        self.lines.deinit(self.allocator);
    }

    pub fn parse(allocator: Allocator, text: []const u8) !Document {
        var doc = Document.init(allocator);
        errdefer doc.deinit();
        if (text.len == 0) return doc;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |raw| {
            // A final newline makes an empty last piece; it is not a line.
            if (it.peek() == null and raw.len == 0) break;
            const line = std.mem.trimEnd(u8, raw, "\r");
            try doc.lines.append(allocator, try allocator.dupe(u8, line));
        }
        return doc;
    }

    /// Serialise with a trailing newline (empty for an empty document).
    pub fn write(self: *const Document, w: *std.Io.Writer) !void {
        for (self.lines.items) |l| {
            try w.writeAll(l);
            try w.writeByte('\n');
        }
    }

    pub fn toOwnedString(self: *const Document, allocator: Allocator) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        try self.write(&aw.writer);
        return aw.toOwnedSlice();
    }

    const Kind = union(enum) {
        blank,
        comment,
        group: []const u8,
        entry: struct { key: []const u8, value: []const u8 },
    };

    fn classify(line: []const u8) Kind {
        const t = std.mem.trim(u8, line, " \t");
        if (t.len == 0) return .blank;
        if (t[0] == '#' or t[0] == ';') return .comment;
        if (t[0] == '[') {
            const close = std.mem.indexOfScalar(u8, t, ']') orelse return .comment;
            return .{ .group = t[1..close] };
        }
        const eq = std.mem.indexOfScalar(u8, t, '=') orelse return .comment;
        return .{ .entry = .{
            .key = std.mem.trim(u8, t[0..eq], " \t"),
            .value = std.mem.trim(u8, t[eq + 1 ..], " \t"),
        } };
    }

    /// Value of `key` in `group`, or null. The last assignment wins, as in
    /// `GKeyFile`. The slice points into the document.
    pub fn get(self: *const Document, group: []const u8, key: []const u8) ?[]const u8 {
        var in_group = false;
        var found: ?[]const u8 = null;
        for (self.lines.items) |line| {
            switch (classify(line)) {
                .group => |g| in_group = std.mem.eql(u8, g, group),
                .entry => |e| if (in_group and std.mem.eql(u8, e.key, key)) {
                    found = e.value;
                },
                else => {},
            }
        }
        return found;
    }

    pub fn hasGroup(self: *const Document, group: []const u8) bool {
        for (self.lines.items) |line| {
            switch (classify(line)) {
                .group => |g| if (std.mem.eql(u8, g, group)) return true,
                else => {},
            }
        }
        return false;
    }

    /// Set `key` in `group`. Returns false (and changes nothing) when the
    /// value is already in effect: SPEC.md 6.1, static files.
    pub fn set(self: *Document, group: []const u8, key: []const u8, value: []const u8) !bool {
        if (self.get(group, key)) |old| if (std.mem.eql(u8, old, value)) return false;

        const new_line = try std.fmt.allocPrint(self.allocator, "{s}={s}", .{ key, value });
        errdefer self.allocator.free(new_line);

        // Replace the last assignment, if there is one.
        var in_group = false;
        var last_entry: ?usize = null;
        var group_end: ?usize = null; // index after the group's last entry or comment
        var group_start: ?usize = null;
        for (self.lines.items, 0..) |line, i| {
            switch (classify(line)) {
                .group => |g| {
                    if (in_group) break;
                    in_group = std.mem.eql(u8, g, group);
                    if (in_group) {
                        group_start = i;
                        group_end = i + 1;
                    }
                },
                .entry => |e| if (in_group) {
                    group_end = i + 1;
                    if (std.mem.eql(u8, e.key, key)) last_entry = i;
                },
                .blank, .comment => {},
            }
        }
        if (last_entry) |i| {
            self.allocator.free(self.lines.items[i]);
            self.lines.items[i] = new_line;
            return true;
        }
        if (group_start != null) {
            try self.lines.insert(self.allocator, group_end.?, new_line);
            return true;
        }
        // New group at the end, after one blank line.
        if (self.lines.items.len > 0 and classify(self.lines.items[self.lines.items.len - 1]) != .blank) {
            try self.lines.append(self.allocator, try self.allocator.dupe(u8, ""));
        }
        const header = try std.fmt.allocPrint(self.allocator, "[{s}]", .{group});
        errdefer self.allocator.free(header);
        try self.lines.append(self.allocator, header);
        try self.lines.append(self.allocator, new_line);
        return true;
    }

    /// Remove every assignment of `key` in `group`. Returns whether the
    /// document changed. An emptied group is removed too, when it has no
    /// comments of its own.
    pub fn remove(self: *Document, group: []const u8, key: []const u8) bool {
        var changed = false;
        var in_group = false;
        var i: usize = 0;
        while (i < self.lines.items.len) {
            switch (classify(self.lines.items[i])) {
                .group => |g| in_group = std.mem.eql(u8, g, group),
                .entry => |e| if (in_group and std.mem.eql(u8, e.key, key)) {
                    self.allocator.free(self.lines.orderedRemove(i));
                    changed = true;
                    continue;
                },
                else => {},
            }
            i += 1;
        }
        if (changed) self.dropEmptyGroup(group);
        return changed;
    }

    fn dropEmptyGroup(self: *Document, group: []const u8) void {
        var i: usize = 0;
        while (i < self.lines.items.len) : (i += 1) {
            const g = switch (classify(self.lines.items[i])) {
                .group => |g| g,
                else => continue,
            };
            if (!std.mem.eql(u8, g, group)) continue;
            // The group is empty when the next non-blank line is a header or the end.
            var j = i + 1;
            while (j < self.lines.items.len and classify(self.lines.items[j]) == .blank) j += 1;
            if (j < self.lines.items.len and classify(self.lines.items[j]) != .group) return;
            var k = i;
            while (k < j) : (k += 1) self.allocator.free(self.lines.orderedRemove(i));
            return;
        }
    }
};

/// Parse a boolean the way `GKeyFile` does: only `true` and `false`.
pub fn parseBool(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return null;
}

test "get reads groups and trims" {
    const a = std.testing.allocator;
    var d = try Document.parse(a,
        \\# comment
        \\[console]
        \\font-size = 24
        \\colors=campbell
        \\
        \\[vt:2]
        \\font-size=32
        \\
    );
    defer d.deinit();
    try std.testing.expectEqualStrings("24", d.get("console", "font-size").?);
    try std.testing.expectEqualStrings("32", d.get("vt:2", "font-size").?);
    try std.testing.expect(d.get("console", "nope") == null);
    try std.testing.expect(d.get("vt:3", "font-size") == null);
}

test "set keeps comments and writes nothing for an unchanged value" {
    const a = std.testing.allocator;
    const src = "# top\n[console]\n# size\nfont-size=24\ncolors=campbell\n";
    var d = try Document.parse(a, src);
    defer d.deinit();
    try std.testing.expect(!try d.set("console", "font-size", "24"));
    try std.testing.expect(try d.set("console", "font-size", "32"));
    const out = try d.toOwnedString(a);
    defer a.free(out);
    try std.testing.expectEqualStrings("# top\n[console]\n# size\nfont-size=32\ncolors=campbell\n", out);
}

test "set adds keys and groups" {
    const a = std.testing.allocator;
    var d = try Document.parse(a, "[console]\ncolors=campbell\n");
    defer d.deinit();
    try std.testing.expect(try d.set("console", "scale", "2"));
    try std.testing.expect(try d.set("vt:1", "font-size", "32"));
    const out = try d.toOwnedString(a);
    defer a.free(out);
    try std.testing.expectEqualStrings("[console]\ncolors=campbell\nscale=2\n\n[vt:1]\nfont-size=32\n", out);
}

test "remove drops the key and an emptied group" {
    const a = std.testing.allocator;
    var d = try Document.parse(a, "[console]\ncolors=campbell\n\n[vt:1]\nfont-size=32\n");
    defer d.deinit();
    try std.testing.expect(d.remove("vt:1", "font-size"));
    try std.testing.expect(!d.remove("vt:1", "font-size"));
    try std.testing.expect(!d.hasGroup("vt:1"));
    const out = try d.toOwnedString(a);
    defer a.free(out);
    try std.testing.expectEqualStrings("[console]\ncolors=campbell\n\n", out);
}

test "round trip is byte for byte" {
    const a = std.testing.allocator;
    const src = "; x\n\n[a]\nk = v\nnot a pair\n[b]\n";
    var d = try Document.parse(a, src);
    defer d.deinit();
    const out = try d.toOwnedString(a);
    defer a.free(out);
    try std.testing.expectEqualStrings(src, out);
}

test "last assignment wins" {
    const a = std.testing.allocator;
    var d = try Document.parse(a, "[g]\nk=1\nk=2\n");
    defer d.deinit();
    try std.testing.expectEqualStrings("2", d.get("g", "k").?);
}
