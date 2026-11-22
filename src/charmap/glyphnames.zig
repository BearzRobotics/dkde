//! A font's own names for its characters. Private-use characters have no
//! Unicode name, but fonts such as Rosquin Glyphs name every glyph in the
//! `post` table; this reads the cmap (to get from character to glyph) and
//! the `post` names. Pure, bounds-checked, and silent on a font it cannot read.

const std = @import("std");

pub const Names = struct {
    data: []const u8,
    cmap: usize,
    cmap_len: usize,
    post: usize,
    post_len: usize,

    pub fn parse(data: []const u8) ?Names {
        var base: usize = 0;
        if (data.len >= 16 and std.mem.eql(u8, data[0..4], "ttcf")) base = u32At(data, 12) orelse return null;
        const tag = u32At(data, base) orelse return null;
        if (tag != 0x00010000 and tag != 0x74727565 and tag != 0x4F54544F) return null;
        const count = u16At(data, base + 4) orelse return null;
        var n: Names = .{ .data = data, .cmap = 0, .cmap_len = 0, .post = 0, .post_len = 0 };
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const rec = base + 12 + i * 16;
            if (rec + 16 > data.len) return null;
            const off = u32At(data, rec + 8) orelse return null;
            const len = u32At(data, rec + 12) orelse return null;
            if (off > data.len or len > data.len - off) continue;
            if (std.mem.eql(u8, data[rec..][0..4], "cmap")) {
                n.cmap = off;
                n.cmap_len = len;
            } else if (std.mem.eql(u8, data[rec..][0..4], "post")) {
                n.post = off;
                n.post_len = len;
            }
        }
        if (n.cmap_len < 4 or n.post_len < 34) return null;
        if (u32At(data, n.post) != 0x00020000) return null; // only version 2 carries names
        return n;
    }

    /// The glyph the font draws for `cp`.
    fn glyph(self: Names, cp: u21) ?u16 {
        const d = self.data;
        const tables = u16At(d, self.cmap + 2) orelse return null;
        var best: ?usize = null;
        var i: usize = 0;
        while (i < tables) : (i += 1) {
            const rec = self.cmap + 4 + i * 8;
            const platform = u16At(d, rec) orelse return null;
            const enc = u16At(d, rec + 2) orelse return null;
            const off = u32At(d, rec + 4) orelse return null;
            if (off >= self.cmap_len) continue;
            const unicode = (platform == 3 and (enc == 1 or enc == 10)) or platform == 0;
            if (!unicode) continue;
            const sub = self.cmap + off;
            const format = u16At(d, sub) orelse continue;
            // Prefer the format 12 table (all planes) over 4.
            if (format == 12 or (format == 4 and best == null)) best = sub;
        }
        const sub = best orelse return null;
        const format = u16At(d, sub) orelse return null;
        if (format == 12) {
            const groups = u32At(d, sub + 12) orelse return null;
            var g: usize = 0;
            while (g < groups) : (g += 1) {
                const at = sub + 16 + g * 12;
                const start = u32At(d, at) orelse return null;
                const end = u32At(d, at + 4) orelse return null;
                if (cp < start or cp > end) continue;
                const first = u32At(d, at + 8) orelse return null;
                const gid = first + (cp - start);
                return if (gid == 0 or gid > 0xFFFF) null else @intCast(gid);
            }
            return null;
        }
        if (cp > 0xFFFF) return null;
        const seg2 = u16At(d, sub + 6) orelse return null;
        const ends = sub + 14;
        const starts = ends + seg2 + 2;
        const deltas = starts + seg2;
        const ranges = deltas + seg2;
        var s: usize = 0;
        while (s < seg2 / 2) : (s += 1) {
            const end = u16At(d, ends + s * 2) orelse return null;
            if (cp > end) continue;
            const start = u16At(d, starts + s * 2) orelse return null;
            if (cp < start) return null;
            const delta = u16At(d, deltas + s * 2) orelse return null;
            const ro = u16At(d, ranges + s * 2) orelse return null;
            const cp16: u16 = @intCast(cp);
            if (ro == 0) {
                const gid = cp16 +% delta;
                return if (gid == 0) null else gid;
            }
            const raw = u16At(d, ranges + s * 2 + ro + (cp - start) * 2) orelse return null;
            if (raw == 0) return null;
            const gid = raw +% delta;
            return if (gid == 0) null else gid;
        }
        return null;
    }

    /// The font's name for the character, if it gives one of its own
    /// (the 258 standard Macintosh names are not custom, so they are skipped).
    pub fn name(self: Names, cp: u21) ?[]const u8 {
        const d = self.data;
        const gid = self.glyph(cp) orelse return null;
        const num = u16At(d, self.post + 32) orelse return null;
        if (gid >= num) return null;
        const idx = u16At(d, self.post + 34 + @as(usize, gid) * 2) orelse return null;
        if (idx < 258) return null;
        var want: usize = idx - 258;
        var at = self.post + 34 + @as(usize, num) * 2;
        const end = self.post + self.post_len;
        while (at < end) {
            const len = d[at];
            if (at + 1 + len > end) return null;
            if (want == 0) return d[at + 1 ..][0..len];
            want -= 1;
            at += 1 + len;
        }
        return null;
    }
};

fn u16At(d: []const u8, off: usize) ?u16 {
    if (off + 2 > d.len) return null;
    return std.mem.readInt(u16, d[off..][0..2], .big);
}

fn u32At(d: []const u8, off: usize) ?u32 {
    if (off + 4 > d.len) return null;
    return std.mem.readInt(u32, d[off..][0..4], .big);
}

test "names come from the post table" {
    const names = Names.parse(@embedFile("rosquin-font")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("rq_Yrz_4x_T_L_1_1", names.name(0xE000).?);
    try std.testing.expect(names.name(0x41) == null);
    try std.testing.expect(names.name(0xE100) == null);
}

test "damaged fonts are refused" {
    try std.testing.expect(Names.parse("") == null);
    try std.testing.expect(Names.parse("not a font at all, really") == null);
    const font = @embedFile("rosquin-font");
    try std.testing.expect(Names.parse(font[0..40]) == null);
}
