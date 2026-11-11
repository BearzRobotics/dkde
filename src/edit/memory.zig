//! What the editor remembers between runs, as small text files in
//! `$XDG_STATE_HOME/dkde/`:
//!
//! - `edit-places`: where the cursor was in each file, one line per file,
//!   newest first: `line<TAB>column<TAB>path`.
//! - `edit-session`: the open tabs, written whenever they change, so they
//!   come back after a restart and unsaved text survives a crash. One line
//!   per tab: `F<TAB>line<TAB>column<TAB>path` for a file, or
//!   `D<TAB>line<TAB>column<TAB>draft<TAB>path` for a tab with unsaved text
//!   kept in `edit-drafts/<draft>` (the path is empty for an untitled tab),
//!   and `A<TAB>index` for the tab that was showing.

const std = @import("std");

pub const Place = struct { line: u32 = 0, column: u32 = 0 };

/// The most files whose place is remembered.
pub const places_limit = 1000;

fn fields(line: []const u8, comptime n: usize) ?[n][]const u8 {
    var out: [n][]const u8 = undefined;
    var it = std.mem.splitScalar(u8, line, '\t');
    inline for (0..n - 1) |i| out[i] = it.next() orelse return null;
    out[n - 1] = it.rest();
    return out;
}

pub fn findPlace(text: []const u8, path: []const u8) ?Place {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const f = fields(line, 3) orelse continue;
        if (!std.mem.eql(u8, f[2], path)) continue;
        return .{
            .line = std.fmt.parseInt(u32, f[0], 10) catch continue,
            .column = std.fmt.parseInt(u32, f[1], 10) catch continue,
        };
    }
    return null;
}

/// `text` with `path` at the top holding `place`; the caller frees it.
pub fn putPlace(gpa: std.mem.Allocator, text: []const u8, path: []const u8, place: Place) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var kept: usize = 0;
    if (path.len > 0 and std.mem.indexOfScalar(u8, path, '\n') == null) {
        try out.writer.print("{d}\t{d}\t{s}\n", .{ place.line, place.column, path });
        kept = 1;
    }
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (kept >= places_limit) break;
        const f = fields(line, 3) orelse continue;
        if (f[2].len == 0 or std.mem.eql(u8, f[2], path)) continue;
        try out.writer.print("{s}\n", .{line});
        kept += 1;
    }
    return out.toOwnedSlice();
}

pub const Tab = struct {
    /// The file, or empty for an untitled tab.
    path: []const u8,
    /// The draft holding unsaved text, or empty.
    draft: []const u8 = "",
    place: Place = .{},
};

pub const Session = struct {
    tabs: []Tab,
    active: usize = 0,

    pub fn deinit(self: *Session, gpa: std.mem.Allocator) void {
        gpa.free(self.tabs);
    }
};

/// Reads a session; its strings point into `text`.
pub fn parseSession(gpa: std.mem.Allocator, text: []const u8) !Session {
    var tabs: std.ArrayList(Tab) = .empty;
    errdefer tabs.deinit(gpa);
    var active: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len < 2 or line[1] != '\t') continue;
        switch (line[0]) {
            'A' => active = std.fmt.parseInt(usize, line[2..], 10) catch 0,
            'F' => {
                const f = fields(line[2..], 3) orelse continue;
                if (f[2].len == 0) continue;
                try tabs.append(gpa, .{ .path = f[2], .place = parsePlace(f[0], f[1]) });
            },
            'D' => {
                const f = fields(line[2..], 4) orelse continue;
                if (f[2].len == 0 or !validDraftName(f[2])) continue;
                try tabs.append(gpa, .{ .path = f[3], .draft = f[2], .place = parsePlace(f[0], f[1]) });
            },
            else => {},
        }
    }
    const last = tabs.items.len -| 1;
    return .{ .tabs = try tabs.toOwnedSlice(gpa), .active = @min(active, last) };
}

fn parsePlace(line: []const u8, column: []const u8) Place {
    return .{ .line = std.fmt.parseInt(u32, line, 10) catch 0, .column = std.fmt.parseInt(u32, column, 10) catch 0 };
}

/// A draft name is made by the editor (letters, digits, '-'); anything else
/// in the file is not trusted as a file name.
pub fn validDraftName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-')) return false;
    return true;
}

pub fn writeSession(w: *std.Io.Writer, session: Session) !void {
    for (session.tabs) |t| {
        if (std.mem.indexOfScalar(u8, t.path, '\n') != null) continue;
        if (t.draft.len > 0)
            try w.print("D\t{d}\t{d}\t{s}\t{s}\n", .{ t.place.line, t.place.column, t.draft, t.path })
        else if (t.path.len > 0)
            try w.print("F\t{d}\t{d}\t{s}\n", .{ t.place.line, t.place.column, t.path });
    }
    try w.print("A\t{d}\n", .{session.active});
}

test "places are stored and found" {
    const gpa = std.testing.allocator;
    const a = try putPlace(gpa, "", "/a.txt", .{ .line = 10, .column = 3 });
    defer gpa.free(a);
    const b = try putPlace(gpa, a, "/b\tc.txt", .{ .line = 2 });
    defer gpa.free(b);
    const c = try putPlace(gpa, b, "/a.txt", .{ .line = 11, .column = 4 });
    defer gpa.free(c);
    try std.testing.expectEqual(Place{ .line = 11, .column = 4 }, findPlace(c, "/a.txt").?);
    try std.testing.expectEqual(Place{ .line = 2 }, findPlace(c, "/b\tc.txt").?);
    try std.testing.expect(std.mem.startsWith(u8, c, "11\t4\t/a.txt\n"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, c, "\n"));
}

test "a session is written and read back" {
    const gpa = std.testing.allocator;
    var tabs = [_]Tab{
        .{ .path = "/etc/hosts", .place = .{ .line = 3, .column = 1 } },
        .{ .path = "", .draft = "d-1" },
        .{ .path = "/home/x/notes.md", .draft = "d-2", .place = .{ .line = 7 } },
    };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try writeSession(&out.writer, .{ .tabs = &tabs, .active = 2 });
    var s = try parseSession(gpa, out.written());
    defer s.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 3), s.tabs.len);
    try std.testing.expectEqual(@as(usize, 2), s.active);
    try std.testing.expectEqualStrings("/etc/hosts", s.tabs[0].path);
    try std.testing.expectEqual(@as(u32, 3), s.tabs[0].place.line);
    try std.testing.expectEqualStrings("", s.tabs[1].path);
    try std.testing.expectEqualStrings("d-1", s.tabs[1].draft);
    try std.testing.expectEqualStrings("/home/x/notes.md", s.tabs[2].path);
}

test "draft names from the file are checked" {
    const gpa = std.testing.allocator;
    var s = try parseSession(gpa, "D\t0\t0\t../../etc/passwd\t\nD\t0\t0\tok-1\t\nA\t9\n");
    defer s.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), s.tabs.len);
    try std.testing.expectEqualStrings("ok-1", s.tabs[0].draft);
    try std.testing.expectEqual(@as(usize, 0), s.active);
}
