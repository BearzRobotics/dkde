//! Letters people paste from mathematics: the Mathematical Alphanumeric
//! Symbols (𝑥, 𝐅, 𝒜, 𝔸, 𝛼, 𝟏 …, U+1D400–U+1D7FF) and the Letterlike
//! Symbols used in their place (ℎ, ℝ, ℯ …) are read as the plain letters and
//! digits they are styles of, so "𝐹 = 𝑚𝑎" means F = m·a. Subscript digits
//! become plain digits (x₁ is the name x1). Greek letters stay Greek.

const std = @import("std");

/// The 58 letters of each Greek style, in Unicode's order.
const greek_order = [58]u21{
    'Α', 'Β', 'Γ', 'Δ', 'Ε', 'Ζ', 'Η', 'Θ', 'Ι', 'Κ', 'Λ', 'Μ', 'Ν', 'Ξ', 'Ο', 'Π', 'Ρ', 'ϴ', 'Σ', 'Τ', 'Υ', 'Φ', 'Χ', 'Ψ', 'Ω', '∇',
    'α', 'β', 'γ', 'δ', 'ε', 'ζ', 'η', 'θ', 'ι', 'κ', 'λ', 'μ', 'ν', 'ξ', 'ο', 'π', 'ρ', 'ς', 'σ', 'τ', 'υ', 'φ', 'χ', 'ψ', 'ω', '∂',
    'ϵ', 'ϑ', 'ϰ', 'ϕ', 'ϱ', 'ϖ',
};

/// The plain character a styled one stands for, or null.
pub fn plain(cp: u21) ?u21 {
    switch (cp) {
        0x1D400...0x1D6A3 => {
            const i = (cp - 0x1D400) % 52;
            return if (i < 26) 'A' + i else 'a' + (i - 26);
        },
        0x1D6A4 => return 'ı',
        0x1D6A5 => return 'ȷ',
        0x1D6A8...0x1D7C9 => return greek_order[(cp - 0x1D6A8) % 58],
        0x1D7CA => return 'Ϝ',
        0x1D7CB => return 'ϝ',
        0x1D7CE...0x1D7FF => return '0' + (cp - 0x1D7CE) % 10,
        0x2080...0x2089 => return '0' + (cp - 0x2080),
        // Letterlike Symbols that fill the holes of the styled alphabets.
        'ℎ' => return 'h',
        'ℯ', 'ℰ' => return if (cp == 'ℯ') 'e' else 'E',
        'ℊ' => return 'g',
        'ℴ' => return 'o',
        'ℬ' => return 'B',
        'ℱ' => return 'F',
        'ℋ', 'ℌ', 'ℍ' => return 'H',
        'ℐ', 'ℑ' => return 'I',
        'ℒ' => return 'L',
        'ℳ' => return 'M',
        'ℛ', 'ℜ', 'ℝ' => return 'R',
        'ℂ', 'ℭ' => return 'C',
        'ℕ' => return 'N',
        'ℙ' => return 'P',
        'ℚ' => return 'Q',
        'ℤ', 'ℨ' => return 'Z',
        else => return null,
    }
}

/// `text` with styled letters and digits made plain. Returns `text` itself
/// when there is nothing to change.
pub fn normalize(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var changed = false;
    var it = (std.unicode.Utf8View.init(text) catch return text).iterator();
    while (it.nextCodepoint()) |cp| if (plain(cp) != null) {
        changed = true;
        break;
    };
    if (!changed) return text;
    var out: std.ArrayList(u8) = .empty;
    it = (std.unicode.Utf8View.init(text) catch return text).iterator();
    while (it.nextCodepoint()) |cp| {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(plain(cp) orelse cp, &buf) catch continue;
        try out.appendSlice(a, buf[0..n]);
    }
    return out.items;
}

/// Whether `cp` is a Greek letter (a name of one letter in expressions).
pub fn isGreek(cp: u21) bool {
    return (cp >= 0x391 and cp <= 0x3A9 and cp != 0x3A2) or (cp >= 0x3B1 and cp <= 0x3C9) or
        cp == 'ϑ' or cp == 'ϕ' or cp == 'ϖ' or cp == 'ϵ' or cp == 'ϱ' or cp == 'ϰ' or cp == 'ϴ';
}

test "styled letters read as plain ones" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("F = ma", try normalize(a, "𝐹 = 𝑚𝑎"));
    try std.testing.expectEqualStrings("x1 + y2", try normalize(a, "x₁ + 𝒚₂"));
    try std.testing.expectEqualStrings("RNh", try normalize(a, "ℝℕℎ"));
    try std.testing.expectEqualStrings("α + 12", try normalize(a, "𝛼 + 𝟏𝟐"));
    try std.testing.expectEqualStrings("ABC", try normalize(a, "𝔄𝔅ℭ"));
    try std.testing.expectEqualStrings("plain", try normalize(a, "plain"));
    try std.testing.expectEqual(@as(?u21, 'z'), plain(0x1D6A3));
    try std.testing.expectEqual(@as(?u21, '9'), plain(0x1D7FF));
    try std.testing.expect(isGreek('θ') and isGreek('Ω') and !isGreek('π' + 100));
}
