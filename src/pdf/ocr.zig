//! Recognising the text of scanned pages (OCR), done by OCRmyPDF (which runs
//! Tesseract) when it is installed. This file holds the parts that need no
//! GTK: which pages need it, the page list and the languages to ask for.

const std = @import("std");

/// A page with fewer visible characters than this is taken for a scan. A
/// scanned court filing still carries a stamped header line of about 70.
pub const scanned_below = 200;

/// The program that does the work, and the package that brings it.
pub const program = "ocrmypdf";
pub const package = "ocrmypdf";

/// `pages` (zero-based, ascending) as OCRmyPDF's one-based list, runs joined:
/// {0,1,2,4} gives "1-3,5".
pub fn pageList(gpa: std.mem.Allocator, pages: []const usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var i: usize = 0;
    while (i < pages.len) {
        var j = i;
        while (j + 1 < pages.len and pages[j + 1] == pages[j] + 1) j += 1;
        if (i > 0) try out.writer.writeByte(',');
        if (j == i)
            try out.writer.print("{d}", .{pages[i] + 1})
        else
            try out.writer.print("{d}-{d}", .{ pages[i] + 1, pages[j] + 1 });
        i = j + 1;
    }
    return out.toOwnedSlice();
}

/// Tesseract's name for the language of a locale such as "de_DE.UTF-8".
fn tesseractName(locale: []const u8) ?[]const u8 {
    const map = [_][2][]const u8{
        .{ "en", "eng" }, .{ "de", "deu" }, .{ "fr", "fra" }, .{ "es", "spa" },
        .{ "it", "ita" }, .{ "pt", "por" }, .{ "nl", "nld" }, .{ "sv", "swe" },
        .{ "da", "dan" }, .{ "nb", "nor" }, .{ "no", "nor" }, .{ "fi", "fin" },
        .{ "pl", "pol" }, .{ "cs", "ces" }, .{ "sk", "slk" }, .{ "hu", "hun" },
        .{ "ro", "ron" }, .{ "ru", "rus" }, .{ "uk", "ukr" }, .{ "el", "ell" },
        .{ "tr", "tur" }, .{ "he", "heb" }, .{ "ar", "ara" }, .{ "ja", "jpn" },
        .{ "ko", "kor" }, .{ "zh", "chi_sim" }, .{ "la", "lat" },
    };
    const end = std.mem.indexOfAny(u8, locale, "_.@") orelse locale.len;
    const lang = locale[0..end];
    if (std.mem.eql(u8, lang, "zh") and (std.mem.indexOf(u8, locale, "TW") != null or std.mem.indexOf(u8, locale, "HK") != null)) return "chi_tra";
    for (map) |m| if (std.mem.eql(u8, m[0], lang)) return m[1];
    return null;
}

fn installed(list: []const u8, name: []const u8) bool {
    var lines = std.mem.tokenizeAny(u8, list, "\r\n");
    while (lines.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t"), name)) return true;
    }
    return false;
}

/// The `-l` argument: the locale's language when its data is installed
/// (`list` is what `tesseract --list-langs` prints), with English too since
/// so much is mixed with it; English alone otherwise.
pub fn languages(buf: []u8, locale: []const u8, list: []const u8) []const u8 {
    const own = tesseractName(locale) orelse "eng";
    if (std.mem.eql(u8, own, "eng") or !installed(list, own)) return "eng";
    if (!installed(list, "eng")) return std.fmt.bufPrint(buf, "{s}", .{own}) catch "eng";
    return std.fmt.bufPrint(buf, "{s}+eng", .{own}) catch "eng";
}

/// The last line of OCRmyPDF's error output worth showing.
pub fn lastMessage(stderr: []const u8) []const u8 {
    var it = std.mem.splitBackwardsScalar(u8, stderr, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len > 0) return t;
    }
    return "";
}

test "page lists join runs" {
    const gpa = std.testing.allocator;
    const cases = .{
        .{ &[_]usize{}, "" },
        .{ &[_]usize{0}, "1" },
        .{ &[_]usize{ 0, 1, 2, 4 }, "1-3,5" },
        .{ &[_]usize{ 1, 3, 4, 9, 10, 11 }, "2,4-5,10-12" },
    };
    inline for (cases) |c| {
        const got = try pageList(gpa, c[0]);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(c[1], got);
    }
}

test "the locale's language is asked for when installed" {
    var buf: [32]u8 = undefined;
    const list = "List of available languages in \"/usr/share/tesseract-ocr/5/tessdata/\" (3):\ndeu\neng\nosd\n";
    try std.testing.expectEqualStrings("deu+eng", languages(&buf, "de_DE.UTF-8", list));
    try std.testing.expectEqualStrings("eng", languages(&buf, "en_US.UTF-8", list));
    try std.testing.expectEqualStrings("eng", languages(&buf, "fr_FR.UTF-8", list));
    try std.testing.expectEqualStrings("eng", languages(&buf, "C", list));
    try std.testing.expectEqualStrings("fra", languages(&buf, "fr_CA", "fra\nosd\n"));
    try std.testing.expectEqualStrings("chi_tra+eng", languages(&buf, "zh_TW.UTF-8", "chi_tra\neng\n"));
}

test "the last error line is found" {
    try std.testing.expectEqualStrings("EncryptedPdfError: input PDF is encrypted", lastMessage("info\nEncryptedPdfError: input PDF is encrypted\n\n"));
    try std.testing.expectEqualStrings("", lastMessage(""));
}
