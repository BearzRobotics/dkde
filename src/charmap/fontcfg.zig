// SPDX-License-Identifier: GPL-2.0-or-later
//! The little of Fontconfig the character map needs: the installed font
//! families, and which characters a family covers (so private-use blocks can
//! show exactly what a font such as Rosquin Glyphs or RE_iO Script defines).

const std = @import("std");
const Allocator = std.mem.Allocator;

const Pattern = opaque {};
const CharSet = opaque {};
const ObjectSet = opaque {};
const FontSet = extern struct { nfont: c_int, sfont: c_int, fonts: ?[*]*Pattern };

extern fn FcPatternCreate() ?*Pattern;
extern fn FcPatternDestroy(p: *Pattern) void;
extern fn FcPatternAddString(p: *Pattern, object: [*:0]const u8, s: [*:0]const u8) c_int;
extern fn FcPatternGetString(p: *Pattern, object: [*:0]const u8, n: c_int, s: *?[*:0]const u8) c_int;
extern fn FcPatternGetCharSet(p: *Pattern, object: [*:0]const u8, n: c_int, cs: *?*CharSet) c_int;
extern fn FcConfigSubstitute(config: ?*anyopaque, p: *Pattern, kind: c_int) c_int;
extern fn FcDefaultSubstitute(p: *Pattern) void;
extern fn FcFontMatch(config: ?*anyopaque, p: *Pattern, result: *c_int) ?*Pattern;
extern fn FcCharSetHasChar(cs: *const CharSet, ucs4: u32) c_int;
extern fn FcObjectSetBuild(first: [*:0]const u8, ...) ?*ObjectSet;
extern fn FcObjectSetDestroy(os: *ObjectSet) void;
extern fn FcFontList(config: ?*anyopaque, p: *Pattern, os: *ObjectSet) ?*FontSet;
extern fn FcFontSetDestroy(s: *FontSet) void;

/// The characters of the font Fontconfig picks for a family.
pub const Cover = struct {
    match: *Pattern,
    chars: *CharSet,

    /// `family` null or empty is the default font.
    pub fn load(family: ?[:0]const u8) ?Cover {
        const pat = FcPatternCreate() orelse return null;
        defer FcPatternDestroy(pat);
        if (family) |f| {
            if (f.len > 0) _ = FcPatternAddString(pat, "family", f.ptr);
        }
        _ = FcConfigSubstitute(null, pat, 0);
        FcDefaultSubstitute(pat);
        var result: c_int = 0;
        const match = FcFontMatch(null, pat, &result) orelse return null;
        var cs: ?*CharSet = null;
        if (FcPatternGetCharSet(match, "charset", 0, &cs) != 0 or cs == null) {
            FcPatternDestroy(match);
            return null;
        }
        return .{ .match = match, .chars = cs.? };
    }

    pub fn deinit(self: Cover) void {
        FcPatternDestroy(self.match);
    }

    /// The font file Fontconfig chose.
    pub fn file(self: Cover) ?[:0]const u8 {
        var path: ?[*:0]const u8 = null;
        if (FcPatternGetString(self.match, "file", 0, &path) != 0) return null;
        return std.mem.span(path orelse return null);
    }

    pub fn has(self: Cover, cp: u21) bool {
        return FcCharSetHasChar(self.chars, cp) != 0;
    }
};

extern fn FcConfigAppFontAddFile(config: ?*anyopaque, file: [*:0]const u8) c_int;
extern fn pango_cairo_font_map_get_default() *anyopaque;
extern fn pango_fc_font_map_config_changed(fontmap: *anyopaque) void;

/// Register a font file for this process. Call before GTK starts.
pub fn addFile(path: [*:0]const u8) bool {
    return FcConfigAppFontAddFile(null, path) != 0;
}

/// Register a font file while the program runs: Pango must be told to look again.
pub fn addFileLive(path: [*:0]const u8) bool {
    if (!addFile(path)) return false;
    pango_fc_font_map_config_changed(pango_cairo_font_map_get_default());
    return true;
}

/// Every installed family once, sorted. Free each name and the slice.
pub fn families(allocator: Allocator) Allocator.Error![][:0]u8 {
    var out: std.ArrayList([:0]u8) = .empty;
    errdefer {
        for (out.items) |n| allocator.free(n);
        out.deinit(allocator);
    }
    const pat = FcPatternCreate() orelse return out.toOwnedSlice(allocator);
    defer FcPatternDestroy(pat);
    const os = FcObjectSetBuild("family", @as(?[*:0]const u8, null)) orelse return out.toOwnedSlice(allocator);
    defer FcObjectSetDestroy(os);
    const set = FcFontList(null, pat, os) orelse return out.toOwnedSlice(allocator);
    defer FcFontSetDestroy(set);
    if (set.fonts) |fonts| {
        for (fonts[0..@intCast(set.nfont)]) |font| {
            var name: ?[*:0]const u8 = null;
            if (FcPatternGetString(font, "family", 0, &name) != 0) continue;
            const n = std.mem.span(name orelse continue);
            if (n.len == 0) continue;
            const copy = try allocator.allocSentinel(u8, n.len, 0);
            @memcpy(copy, n);
            out.append(allocator, copy) catch |e| {
                allocator.free(copy);
                return e;
            };
        }
    }
    std.mem.sort([:0]u8, out.items, {}, lessThan);
    // Drop duplicates (one entry per style).
    var w: usize = 0;
    for (out.items) |n| {
        if (w > 0 and std.mem.eql(u8, out.items[w - 1], n)) {
            allocator.free(n);
        } else {
            out.items[w] = n;
            w += 1;
        }
    }
    out.shrinkRetainingCapacity(w);
    return out.toOwnedSlice(allocator);
}

fn lessThan(_: void, a: [:0]u8, b: [:0]u8) bool {
    return std.ascii.lessThanIgnoreCase(a, b);
}
