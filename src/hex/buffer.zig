//! The bytes being edited, with undo and redo (SPEC.md 5.6, dkde-hex). Every
//! change is one replace: remove `removed` at `offset` and put `inserted` there.
//! Overwriting a byte, inserting, deleting and pasting are all that one
//! operation, so undo is just doing the opposite.

const std = @import("std");

pub const Edit = struct {
    offset: usize,
    removed: []u8,
    inserted: []u8,
    /// Typing the second nibble of a byte continues the first one's edit.
    mergeable: bool = false,
};

pub const Buffer = struct {
    allocator: std.mem.Allocator,
    data: std.ArrayList(u8) = .empty,
    undo_stack: std.ArrayList(Edit) = .empty,
    redo_stack: std.ArrayList(Edit) = .empty,
    /// Length of the undo stack when the file was last saved; null once that
    /// state can no longer be reached by undoing or redoing.
    saved_at: ?usize = 0,
    /// Bumps on every change to the content, so a cache can tell it is stale.
    revision: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) Buffer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Buffer) void {
        self.clearHistory();
        self.undo_stack.deinit(self.allocator);
        self.redo_stack.deinit(self.allocator);
        self.data.deinit(self.allocator);
    }

    fn freeEdit(self: *Buffer, e: Edit) void {
        self.allocator.free(e.removed);
        self.allocator.free(e.inserted);
    }

    fn clearHistory(self: *Buffer) void {
        for (self.undo_stack.items) |e| self.freeEdit(e);
        for (self.redo_stack.items) |e| self.freeEdit(e);
        self.undo_stack.clearRetainingCapacity();
        self.redo_stack.clearRetainingCapacity();
    }

    /// Replaces all content (opening a file) and forgets the history.
    pub fn load(self: *Buffer, content: []const u8) !void {
        self.clearHistory();
        self.data.clearRetainingCapacity();
        try self.data.appendSlice(self.allocator, content);
        self.saved_at = 0;
        self.revision += 1;
    }

    /// Loading without a second copy: returns `size` bytes to fill in place,
    /// then `endLoad(got)` says how many were really read.
    pub fn beginLoad(self: *Buffer, size: usize) ![]u8 {
        self.clearHistory();
        self.data.clearRetainingCapacity();
        try self.data.resize(self.allocator, size);
        return self.data.items;
    }

    pub fn endLoad(self: *Buffer, got: usize) void {
        self.data.shrinkRetainingCapacity(got);
        self.saved_at = 0;
        self.revision += 1;
    }

    pub fn len(self: *const Buffer) usize {
        return self.data.items.len;
    }

    pub fn slice(self: *const Buffer) []const u8 {
        return self.data.items;
    }

    pub fn isModified(self: *const Buffer) bool {
        return self.saved_at == null or self.saved_at.? != self.undo_stack.items.len;
    }

    pub fn markSaved(self: *Buffer) void {
        self.saved_at = self.undo_stack.items.len;
    }

    fn apply(self: *Buffer, offset: usize, remove_len: usize, insert: []const u8) !void {
        self.revision += 1;
        try self.data.replaceRange(self.allocator, offset, remove_len, insert);
    }

    /// Removes `remove_len` bytes at `offset` and puts `insert` there.
    pub fn replace(self: *Buffer, offset: usize, remove_len: usize, insert: []const u8, mergeable: bool) !void {
        if (offset > self.data.items.len) return error.OutOfRange;
        const remove = @min(remove_len, self.data.items.len - offset);
        if (remove == 0 and insert.len == 0) return;

        // Typing both nibbles of one byte is a single undo step.
        if (mergeable and self.undo_stack.items.len > 0 and self.redo_stack.items.len == 0) {
            const top = &self.undo_stack.items[self.undo_stack.items.len - 1];
            if (top.mergeable and top.offset == offset and top.inserted.len == 1 and insert.len == 1 and remove == 1) {
                self.data.items[offset] = insert[0];
                self.revision += 1;
                top.inserted[0] = insert[0];
                top.mergeable = false;
                return;
            }
        }

        const removed = try self.allocator.dupe(u8, self.data.items[offset .. offset + remove]);
        errdefer self.allocator.free(removed);
        const inserted = try self.allocator.dupe(u8, insert);
        errdefer self.allocator.free(inserted);
        try self.apply(offset, remove, insert);
        try self.undo_stack.append(self.allocator, .{ .offset = offset, .removed = removed, .inserted = inserted, .mergeable = mergeable });

        for (self.redo_stack.items) |e| self.freeEdit(e);
        self.redo_stack.clearRetainingCapacity();
        // A saved state that lived on the redo stack is gone for good.
        if (self.saved_at) |s| if (s > self.undo_stack.items.len - 1) {
            self.saved_at = null;
        };
    }

    pub fn setByte(self: *Buffer, offset: usize, value: u8, mergeable: bool) !void {
        if (offset >= self.data.items.len) return error.OutOfRange;
        try self.replace(offset, 1, &.{value}, mergeable);
    }

    /// Undoes the last edit; returns the offset to show, or null if none.
    pub fn undo(self: *Buffer) !?usize {
        const e = self.undo_stack.pop() orelse return null;
        try self.apply(e.offset, e.inserted.len, e.removed);
        try self.redo_stack.append(self.allocator, e);
        return e.offset;
    }

    pub fn redo(self: *Buffer) !?usize {
        const e = self.redo_stack.pop() orelse return null;
        try self.apply(e.offset, e.removed.len, e.inserted);
        try self.undo_stack.append(self.allocator, e);
        return e.offset;
    }

    /// First match of `needle` at or after `from` (or before it, when
    /// searching backwards), wrapping around. Null when absent.
    pub fn find(self: *const Buffer, needle: []const u8, from: usize, forward: bool) ?usize {
        const hay = self.data.items;
        if (needle.len == 0 or needle.len > hay.len) return null;
        const last = hay.len - needle.len;
        if (forward) {
            var i = @min(from, last + 1);
            var steps: usize = 0;
            while (steps <= last + 1) : (steps += 1) {
                if (i > last) i = 0;
                if (std.mem.eql(u8, hay[i .. i + needle.len], needle)) return i;
                i += 1;
            }
        } else {
            var i: usize = if (from == 0) last else @min(from - 1, last);
            var steps: usize = 0;
            while (steps <= last + 1) : (steps += 1) {
                if (std.mem.eql(u8, hay[i .. i + needle.len], needle)) return i;
                i = if (i == 0) last else i - 1;
            }
        }
        return null;
    }
};

/// "de ad BE EF", "0xdeadbeef" and "DEADBEEF" all give the same four bytes.
/// Null when the text is not valid hex (an odd number of digits counts).
pub fn parseHex(allocator: std.mem.Allocator, text: []const u8) !?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var high: ?u8 = null;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == ',' or c == ':') continue;
        if (c == '0' and i + 1 < text.len and (text[i + 1] == 'x' or text[i + 1] == 'X')) {
            i += 1;
            continue;
        }
        const v = std.fmt.charToDigit(c, 16) catch {
            out.deinit(allocator);
            return null;
        };
        if (high) |h| {
            try out.append(allocator, h << 4 | v);
            high = null;
        } else high = v;
    }
    if (high != null or out.items.len == 0) {
        out.deinit(allocator);
        return null;
    }
    return try out.toOwnedSlice(allocator);
}

test "overwrite, insert, delete and undo" {
    const a = std.testing.allocator;
    var b = Buffer.init(a);
    defer b.deinit();
    try b.load("abcdef");
    try std.testing.expect(!b.isModified());

    try b.setByte(1, 'X', false);
    try b.replace(3, 0, "123", false); // insert
    try b.replace(0, 1, "", false); // delete
    try std.testing.expectEqualStrings("Xc123def", b.slice());
    try std.testing.expect(b.isModified());

    try std.testing.expectEqual(@as(?usize, 0), try b.undo());
    try std.testing.expectEqualStrings("aXc123def", b.slice());
    _ = try b.undo();
    _ = try b.undo();
    try std.testing.expectEqualStrings("abcdef", b.slice());
    try std.testing.expect(!b.isModified());
    _ = try b.redo();
    try std.testing.expectEqualStrings("aXcdef", b.slice());
    try std.testing.expect(b.isModified());
    try std.testing.expect(try b.undo() != null);
    try std.testing.expect(try b.undo() == null);
}

test "typing two nibbles is one undo step, and a new edit drops redo" {
    const a = std.testing.allocator;
    var b = Buffer.init(a);
    defer b.deinit();
    try b.load("\x00\x00");
    try b.setByte(0, 0x40, true);
    try b.setByte(0, 0x41, true);
    try std.testing.expectEqual(@as(usize, 1), b.undo_stack.items.len);
    _ = try b.undo();
    try std.testing.expectEqualSlices(u8, "\x00\x00", b.slice());
    try b.setByte(1, 9, false);
    try std.testing.expect(try b.redo() == null);
}

test "saved state tracking" {
    const a = std.testing.allocator;
    var b = Buffer.init(a);
    defer b.deinit();
    try b.load("abc");
    try b.setByte(0, 'x', false);
    b.markSaved();
    try std.testing.expect(!b.isModified());
    _ = try b.undo();
    try std.testing.expect(b.isModified());
    _ = try b.redo();
    try std.testing.expect(!b.isModified());
    _ = try b.undo();
    try b.setByte(1, 'y', false); // the saved state can no longer be reached
    try std.testing.expect(b.isModified());
    try b.setByte(1, 'b', false);
    try std.testing.expect(b.isModified());
}

test "find wraps in both directions" {
    const a = std.testing.allocator;
    var b = Buffer.init(a);
    defer b.deinit();
    try b.load("xxABxxABxx");
    try std.testing.expectEqual(@as(?usize, 2), b.find("AB", 0, true));
    try std.testing.expectEqual(@as(?usize, 6), b.find("AB", 3, true));
    try std.testing.expectEqual(@as(?usize, 2), b.find("AB", 7, true)); // wrapped
    try std.testing.expectEqual(@as(?usize, 2), b.find("AB", 6, false));
    try std.testing.expectEqual(@as(?usize, 6), b.find("AB", 2, false)); // wrapped
    try std.testing.expect(b.find("ZZ", 0, true) == null);
    try std.testing.expect(b.find("", 0, true) == null);
}

test "hex text" {
    const a = std.testing.allocator;
    const bytes = (try parseHex(a, "de ad BE:EF")).?;
    defer a.free(bytes);
    try std.testing.expectEqualSlices(u8, "\xde\xad\xbe\xef", bytes);
    const prefixed = (try parseHex(a, "0x01 0x02")).?;
    defer a.free(prefixed);
    try std.testing.expectEqualSlices(u8, "\x01\x02", prefixed);
    try std.testing.expect((try parseHex(a, "abc")) == null);
    try std.testing.expect((try parseHex(a, "zz")) == null);
    try std.testing.expect((try parseHex(a, "")) == null);
}
