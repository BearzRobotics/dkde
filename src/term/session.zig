//! What dkde-term keeps between runs and reads from other programs, without
//! GTK: the tabs of the last session, and container names from toolbox and
//! distrobox.
//!
//! The session file (`$XDG_STATE_HOME/dkde/term-session`) has one line per
//! tab, `T<TAB>profile<TAB>title`, followed by its pane tree in prefix
//! order: `S<TAB>h|v<TAB>permille` for a split (its two children follow),
//! `V<TAB>profile<TAB>folder` for a pane.

const std = @import("std");

pub const Node = union(enum) {
    pane: struct { profile: []const u8, directory: []const u8 },
    split: struct { horizontal: bool, permille: u16 },
};

pub const Tab = struct {
    title: []const u8,
    /// Index in `nodes` of the tab's tree.
    first: usize,
};

pub const Session = struct {
    tabs: []Tab,
    nodes: []Node,

    pub fn deinit(self: *Session, gpa: std.mem.Allocator) void {
        gpa.free(self.tabs);
        gpa.free(self.nodes);
    }
};

fn fields(line: []const u8, comptime n: usize) ?[n][]const u8 {
    var out: [n][]const u8 = undefined;
    var it = std.mem.splitScalar(u8, line, '\t');
    inline for (0..n - 1) |i| out[i] = it.next() orelse return null;
    out[n - 1] = it.rest();
    return out;
}

/// Reads a session; the strings point into `text`. A tab whose tree is
/// broken is left out.
pub fn parse(gpa: std.mem.Allocator, text: []const u8) !Session {
    var tabs: std.ArrayList(Tab) = .empty;
    errdefer tabs.deinit(gpa);
    var nodes: std.ArrayList(Node) = .empty;
    errdefer nodes.deinit(gpa);
    // How many subtrees the current tab still needs (a split adds one).
    var needed: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len < 2 or line[1] != '\t') continue;
        switch (line[0]) {
            'T' => {
                if (needed > 0 and tabs.items.len > 0) {
                    const broken = tabs.pop().?;
                    nodes.shrinkRetainingCapacity(broken.first);
                }
                const f = fields(line[2..], 2) orelse continue;
                try tabs.append(gpa, .{ .title = f[1], .first = nodes.items.len });
                needed = 1;
            },
            'S' => {
                if (needed == 0) continue;
                const f = fields(line[2..], 2) orelse continue;
                const permille = std.fmt.parseInt(u16, f[1], 10) catch 500;
                try nodes.append(gpa, .{ .split = .{ .horizontal = std.mem.eql(u8, f[0], "h"), .permille = std.math.clamp(permille, 50, 950) } });
                needed += 1;
            },
            'V' => {
                if (needed == 0) continue;
                const f = fields(line[2..], 2) orelse continue;
                try nodes.append(gpa, .{ .pane = .{ .profile = f[0], .directory = f[1] } });
                needed -= 1;
            },
            else => {},
        }
    }
    if (needed > 0 and tabs.items.len > 0) {
        const broken = tabs.pop().?;
        nodes.shrinkRetainingCapacity(broken.first);
    }
    return .{ .tabs = try tabs.toOwnedSlice(gpa), .nodes = try nodes.toOwnedSlice(gpa) };
}

/// Container names from `distrobox list --no-color` (columns split by
/// '|') or `toolbox list --containers` (columns split by two or more
/// spaces); the header line is skipped. The names point into `text`.
pub fn containerNames(text: []const u8, out: [][]const u8) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r");
        if (line.len == 0) continue;
        if (first) {
            first = false;
            continue;
        }
        const name = if (std.mem.indexOfScalar(u8, line, '|') != null) blk: {
            var cols = std.mem.splitScalar(u8, line, '|');
            _ = cols.next();
            break :blk std.mem.trim(u8, cols.next() orelse continue, " ");
        } else blk: {
            // toolbox: ID, then the name after a run of spaces.
            var i: usize = 0;
            while (i < line.len and line[i] != ' ') i += 1;
            while (i < line.len and line[i] == ' ') i += 1;
            var j = i;
            while (j < line.len and !(line[j] == ' ' and j + 1 < line.len and line[j + 1] == ' ')) j += 1;
            break :blk std.mem.trim(u8, line[i..j], " ");
        };
        if (name.len == 0 or n >= out.len) continue;
        // A name that could not be passed safely as one argument is skipped.
        const ok = for (name) |c| {
            if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) break false;
        } else true;
        if (!ok) continue;
        out[n] = name;
        n += 1;
    }
    return n;
}

test "a session with splits is read back" {
    const gpa = std.testing.allocator;
    const text = "T\tDefault\t\nV\tDefault\t/home/u\nT\tDefault\tbuild\nS\th\t600\nV\tDefault\t/src\nS\tv\t500\nV\tDefault\t/src/a\nV\tRoot\t/\n";
    var s = try parse(gpa, text);
    defer s.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), s.tabs.len);
    try std.testing.expectEqualStrings("build", s.tabs[1].title);
    try std.testing.expectEqual(@as(usize, 1), s.tabs[1].first);
    try std.testing.expectEqual(@as(usize, 6), s.nodes.len);
    try std.testing.expect(s.nodes[1].split.horizontal);
    try std.testing.expectEqual(@as(u16, 600), s.nodes[1].split.permille);
    try std.testing.expectEqualStrings("Root", s.nodes[5].pane.profile);
}

test "a broken tab is left out" {
    const gpa = std.testing.allocator;
    var s = try parse(gpa, "T\tDefault\t\nS\th\t500\nV\tDefault\t/a\nT\tDefault\t\nV\tDefault\t/b\n");
    defer s.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), s.tabs.len);
    try std.testing.expectEqualStrings("/b", s.nodes[s.tabs[0].first].pane.directory);
}

test "container names" {
    var names: [8][]const u8 = undefined;
    const db = "ID           | NAME                 | STATUS             | IMAGE\n0a1b2c3d4e5f | arch                 | Up 2 hours         | archlinux:latest\n9f8e7d6c5b4a | ubuntu-22            | Exited (0)         | ubuntu:22.04\n";
    try std.testing.expectEqual(@as(usize, 2), containerNames(db, &names));
    try std.testing.expectEqualStrings("arch", names[0]);
    try std.testing.expectEqualStrings("ubuntu-22", names[1]);
    const tb = "CONTAINER ID  CONTAINER NAME     CREATED        STATUS   IMAGE NAME\nd7e1a2b3c4d5  fedora-toolbox-40  3 weeks ago    exited   registry.fedoraproject.org/fedora-toolbox:40\n";
    try std.testing.expectEqual(@as(usize, 1), containerNames(tb, &names));
    try std.testing.expectEqualStrings("fedora-toolbox-40", names[0]);
}
