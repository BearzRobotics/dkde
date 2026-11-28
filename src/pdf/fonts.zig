// SPDX-License-Identifier: GPL-2.0-or-later
//! A font to embed when typed text goes beyond what a PDF's built-in fonts
//! have. pdf-zig draws form fields and text boxes in Helvetica with the
//! Western European characters (WinAnsi) and shows anything else as `?`,
//! unless it is given a TrueType font. Fontconfig ranks the installed fonts;
//! the first one pdf-zig can read, may embed and that has every character is
//! used. Ordinary text embeds nothing, so those files stay as they were.

const std = @import("std");
const pdf = @import("pdf");

const Allocator = std.mem.Allocator;

pub const Error = Allocator.Error || error{ NoFont, BadText };

/// The code points of windows-1252 that are not their own byte values.
const win_ansi_extras = [_]u21{
    0x20AC, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039,
    0x0152, 0x017D, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122,
    0x0161, 0x203A, 0x0153, 0x017E, 0x0178,
};

/// Line breaks, tabs and other controls are not characters a font draws.
fn drawn(c: u21) bool {
    return c >= 0x20 and !(c >= 0x7F and c < 0xA0);
}

fn inWinAnsi(c: u21) bool {
    if ((c >= 0x20 and c < 0x7F) or (c >= 0xA0 and c <= 0xFF)) return true;
    return std.mem.indexOfScalar(u21, &win_ansi_extras, c) != null;
}

/// True when `text` has a character the built-in fonts lack.
pub fn needsEmbedding(text: []const u8) bool {
    var it = (std.unicode.Utf8View.init(text) catch return false).iterator();
    while (it.nextCodepoint()) |c| if (drawn(c) and !inWinAnsi(c)) return true;
    return false;
}

/// True when `text` is in a script that needs shaping or right-to-left layout,
/// which pdf-zig does not do: Hebrew, Arabic and the Indic and South-East
/// Asian scripts. Its letters are stored correctly but may be drawn wrongly.
pub fn needsShaping(text: []const u8) bool {
    var it = (std.unicode.Utf8View.init(text) catch return false).iterator();
    while (it.nextCodepoint()) |c| {
        if ((c >= 0x0590 and c <= 0x08FF) or // Hebrew, Arabic, Syriac, Thaana, N'Ko
            (c >= 0x0900 and c <= 0x109F) or // Devanagari ... Myanmar
            (c >= 0x1780 and c <= 0x17FF) or // Khmer
            (c >= 0xFB1D and c <= 0xFDFF) or (c >= 0xFE70 and c <= 0xFEFF)) return true;
    }
    return false;
}

// ---- fontconfig (declared by hand: a few calls on opaque pointers) --------------------------

const Pattern = opaque {};
const CharSet = opaque {};
const FontSet = extern struct { nfont: c_int, sfont: c_int, fonts: [*]const *Pattern };

extern fn FcPatternCreate() ?*Pattern;
extern fn FcPatternDestroy(p: *Pattern) void;
extern fn FcPatternAddString(p: *Pattern, object: [*:0]const u8, s: [*:0]const u8) c_int;
extern fn FcPatternAddCharSet(p: *Pattern, object: [*:0]const u8, c: *const CharSet) c_int;
extern fn FcPatternGetString(p: *const Pattern, object: [*:0]const u8, n: c_int, s: *?[*:0]const u8) c_int;
extern fn FcPatternGetCharSet(p: *const Pattern, object: [*:0]const u8, n: c_int, c: *?*CharSet) c_int;
extern fn FcPatternGetInteger(p: *const Pattern, object: [*:0]const u8, n: c_int, i: *c_int) c_int;
extern fn FcCharSetCreate() ?*CharSet;
extern fn FcCharSetDestroy(c: *CharSet) void;
extern fn FcCharSetAddChar(c: *CharSet, ucs4: u32) c_int;
extern fn FcCharSetHasChar(c: *const CharSet, ucs4: u32) c_int;
extern fn FcConfigSubstitute(config: ?*anyopaque, p: *Pattern, kind: c_int) c_int;
extern fn FcDefaultSubstitute(p: *Pattern) void;
extern fn FcFontSort(config: ?*anyopaque, p: *Pattern, trim: c_int, csp: ?*?*CharSet, result: *c_int) ?*FontSet;
extern fn FcFontSetDestroy(s: *FontSet) void;

const fc_match_pattern: c_int = 0;
const fc_result_match: c_int = 0;

/// The best installed font that pdf-zig can embed in a form and that has every
/// character of all `texts`. The caller owns it (`deinit`).
pub fn find(gpa: Allocator, texts: []const []const u8) Error!pdf.truetype.Font {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var chars: std.AutoArrayHashMapUnmanaged(u21, void) = .empty;
    for (texts) |text| {
        var it = (std.unicode.Utf8View.init(text) catch return error.BadText).iterator();
        while (it.nextCodepoint()) |c| if (drawn(c)) try chars.put(a, c, {});
    }

    const pattern = FcPatternCreate() orelse return error.OutOfMemory;
    defer FcPatternDestroy(pattern);
    const wanted = FcCharSetCreate() orelse return error.OutOfMemory;
    defer FcCharSetDestroy(wanted);
    for (chars.keys()) |c| _ = FcCharSetAddChar(wanted, c);
    _ = FcPatternAddString(pattern, "family", "sans-serif");
    _ = FcPatternAddString(pattern, "fontformat", "TrueType");
    _ = FcPatternAddCharSet(pattern, "charset", wanted);
    _ = FcConfigSubstitute(null, pattern, fc_match_pattern);
    FcDefaultSubstitute(pattern);
    var result: c_int = 0;
    const set = FcFontSort(null, pattern, 0, null, &result) orelse return error.NoFont;
    defer FcFontSetDestroy(set);

    candidates: for (set.fonts[0..@intCast(@max(set.nfont, 0))]) |candidate| {
        var has: ?*CharSet = null;
        if (FcPatternGetCharSet(candidate, "charset", 0, &has) != fc_result_match) continue;
        for (chars.keys()) |c| if (FcCharSetHasChar(has.?, c) == 0) continue :candidates;
        // Only whole `.ttf` files: not another face of a collection, nor a
        // named instance of a variable font.
        var index: c_int = 0;
        if (FcPatternGetInteger(candidate, "index", 0, &index) == fc_result_match and index != 0) continue;
        var file: ?[*:0]const u8 = null;
        if (FcPatternGetString(candidate, "file", 0, &file) != fc_result_match) continue;
        const path = std.mem.span(file.?);
        if (!std.ascii.endsWithIgnoreCase(path, ".ttf")) continue;

        const io = std.Io.Threaded.global_single_threaded.io();
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(pdf.truetype.max_bytes)) catch continue;
        var font = pdf.truetype.Font.init(gpa, data, .{}) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        // A font for "preview and print" may not fill a form.
        if (font.permission == .preview_and_print) {
            font.deinit();
            continue;
        }
        // Fontconfig's list of characters and the font's own can differ.
        for (chars.keys()) |c| if (font.glyphFor(c) == null) {
            font.deinit();
            continue :candidates;
        };
        return font;
    }
    return error.NoFont;
}

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;

test "only text outside WinAnsi needs a font" {
    try testing.expect(!needsEmbedding("Plain text, caf\u{e9}, \u{20ac}5 \u{2014} \u{201c}quoted\u{201d}\nsecond line\t."));
    try testing.expect(!needsEmbedding(""));
    try testing.expect(needsEmbedding("\u{3b1}\u{3b2}\u{3b3}"));
    try testing.expect(needsEmbedding("Za\u{17c}\u{f3}\u{142}\u{107}"));
    try testing.expect(needsEmbedding("\u{4e2d}"));
}

test "scripts that need shaping are recognised" {
    try testing.expect(needsShaping("\u{5e9}\u{5dc}\u{5d5}\u{5dd}"));
    try testing.expect(needsShaping("\u{645}\u{631}\u{62d}\u{628}\u{627}"));
    try testing.expect(needsShaping("\u{928}\u{92e}\u{938}\u{94d}\u{924}\u{947}"));
    try testing.expect(!needsShaping("\u{3b1} \u{4e2d} \u{44f} abc"));
}
