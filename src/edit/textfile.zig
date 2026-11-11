//! How a text file is stored on disk: its encoding, whether it starts with a
//! byte-order mark, and its line endings. The editor works on UTF-8 with "\n"
//! line ends; `decode` turns a file into that and `encode` turns it back, so
//! a file that is opened and saved again keeps its format (as gedit and Kate
//! do) unless the user changes it.

const std = @import("std");
const glib = @import("glib2");

pub const Encoding = enum {
    utf8,
    utf16le,
    utf16be,
    /// Western European text from Windows; also takes most Latin-1 files.
    windows1252,
    /// ISO-8859-1: any byte is a character, the last resort.
    latin1,

    /// The name iconv knows it by.
    pub fn codeset(e: Encoding) [:0]const u8 {
        return switch (e) {
            .utf8 => "UTF-8",
            .utf16le => "UTF-16LE",
            .utf16be => "UTF-16BE",
            .windows1252 => "WINDOWS-1252",
            .latin1 => "ISO-8859-1",
        };
    }

    /// The name shown in the status bar.
    pub fn label(e: Encoding) [:0]const u8 {
        return switch (e) {
            .utf8 => "UTF-8",
            .utf16le => "UTF-16 LE",
            .utf16be => "UTF-16 BE",
            .windows1252 => "Windows-1252",
            .latin1 => "ISO-8859-1",
        };
    }
};

pub const Newline = enum {
    lf,
    crlf,
    cr,

    pub fn label(n: Newline) [:0]const u8 {
        return switch (n) {
            .lf => "Unix (LF)",
            .crlf => "Windows (CRLF)",
            .cr => "Classic Mac (CR)",
        };
    }

    fn bytes(n: Newline) []const u8 {
        return switch (n) {
            .lf => "\n",
            .crlf => "\r\n",
            .cr => "\r",
        };
    }
};

pub const Format = struct {
    encoding: Encoding = .utf8,
    bom: bool = false,
    newline: Newline = .lf,
};

pub const Decoded = struct {
    /// UTF-8 with "\n" line ends; owned by the caller.
    text: []u8,
    format: Format,
};

pub const Error = error{
    /// Not text: it holds zero bytes and is not UTF-16.
    Binary,
    /// The text has characters the file's encoding cannot store.
    Unrepresentable,
    OutOfMemory,
};

const bom_utf8 = "\xEF\xBB\xBF";
const bom_utf16le = "\xFF\xFE";
const bom_utf16be = "\xFE\xFF";

/// Reads a file's bytes as text, working out how it is stored.
pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) Error!Decoded {
    var format: Format = .{};
    var body = bytes;
    var utf8: []u8 = undefined;
    if (std.mem.startsWith(u8, bytes, bom_utf8)) {
        format.bom = true;
        body = bytes[bom_utf8.len..];
    } else if (std.mem.startsWith(u8, bytes, bom_utf16le)) {
        format = .{ .encoding = .utf16le, .bom = true };
        body = bytes[bom_utf16le.len..];
    } else if (std.mem.startsWith(u8, bytes, bom_utf16be)) {
        format = .{ .encoding = .utf16be, .bom = true };
        body = bytes[bom_utf16be.len..];
    }

    if (format.encoding == .utf8) {
        if (std.mem.indexOfScalar(u8, body, 0) != null) return error.Binary;
        if (std.unicode.utf8ValidateSlice(body)) {
            utf8 = try gpa.dupe(u8, body);
        } else {
            // Not UTF-8: a legacy single-byte file.
            format.encoding = .windows1252;
            utf8 = convert(gpa, body, "UTF-8", Encoding.windows1252.codeset()) catch blk: {
                format.encoding = .latin1;
                break :blk convert(gpa, body, "UTF-8", Encoding.latin1.codeset()) catch return error.Binary;
            };
        }
    } else {
        utf8 = convert(gpa, body, "UTF-8", format.encoding.codeset()) catch return error.Binary;
        if (std.mem.indexOfScalar(u8, utf8, 0) != null) {
            gpa.free(utf8);
            return error.Binary;
        }
    }
    errdefer gpa.free(utf8);

    format.newline = firstNewline(utf8);
    const text = switch (format.newline) {
        .lf => utf8,
        .crlf => blk: {
            defer gpa.free(utf8);
            break :blk try std.mem.replaceOwned(u8, gpa, utf8, "\r\n", "\n");
        },
        .cr => blk: {
            std.mem.replaceScalar(u8, utf8, '\r', '\n');
            break :blk utf8;
        },
    };
    return .{ .text = text, .format = format };
}

/// The bytes to write for `text` (UTF-8, "\n" line ends) in `format`.
pub fn encode(gpa: std.mem.Allocator, text: []const u8, format: Format) Error![]u8 {
    const lines = if (format.newline == .lf)
        try gpa.dupe(u8, text)
    else
        try std.mem.replaceOwned(u8, gpa, text, "\n", format.newline.bytes());
    defer gpa.free(lines);

    const body = if (format.encoding == .utf8)
        try gpa.dupe(u8, lines)
    else
        convert(gpa, lines, format.encoding.codeset(), "UTF-8") catch return error.Unrepresentable;
    defer gpa.free(body);

    const bom: []const u8 = if (!format.bom) "" else switch (format.encoding) {
        .utf8 => bom_utf8,
        .utf16le => bom_utf16le,
        .utf16be => bom_utf16be,
        else => "",
    };
    return std.mem.concat(gpa, u8, &.{ bom, body });
}

/// The first line end in `text`, which sets the file's style.
fn firstNewline(text: []const u8) Newline {
    const i = std.mem.indexOfAny(u8, text, "\r\n") orelse return .lf;
    if (text[i] == '\n') return .lf;
    if (i + 1 < text.len and text[i + 1] == '\n') return .crlf;
    return .cr;
}

fn convert(gpa: std.mem.Allocator, in: []const u8, to: [:0]const u8, from: [:0]const u8) ![]u8 {
    if (in.len == 0) return gpa.dupe(u8, "");
    var written: usize = 0;
    var err: ?*glib.Error = null;
    const out = glib.convert(in.ptr, @intCast(in.len), to, from, null, &written, &err) orelse {
        if (err) |e| e.free();
        return error.ConversionFailed;
    };
    defer glib.free(out);
    return gpa.dupe(u8, out[0..written]);
}

fn roundTrip(bytes: []const u8, want_text: []const u8, want: Format) !void {
    const gpa = std.testing.allocator;
    const d = try decode(gpa, bytes);
    defer gpa.free(d.text);
    try std.testing.expectEqualStrings(want_text, d.text);
    try std.testing.expectEqual(want, d.format);
    const back = try encode(gpa, d.text, d.format);
    defer gpa.free(back);
    try std.testing.expectEqualSlices(u8, bytes, back);
}

test "files keep their format through opening and saving" {
    try roundTrip("", "", .{});
    try roundTrip("one\ntwo\n", "one\ntwo\n", .{});
    try roundTrip("one\r\ntwo\r\n", "one\ntwo\n", .{ .newline = .crlf });
    try roundTrip("one\rtwo", "one\ntwo", .{ .newline = .cr });
    try roundTrip("\xEF\xBB\xBFcaf\xC3\xA9\n", "café\n", .{ .bom = true });
    try roundTrip("caf\xE9 \x80\r\n", "café €\n", .{ .encoding = .windows1252, .newline = .crlf });
    // 0x81 is not a Windows-1252 character: Latin-1 takes it.
    try roundTrip("a\x81b", "a\u{81}b", .{ .encoding = .latin1 });
    try roundTrip("\xFF\xFEh\x00i\x00\n\x00", "hi\n", .{ .encoding = .utf16le, .bom = true });
    try roundTrip("\xFE\xFF\x00h\x00i", "hi", .{ .encoding = .utf16be, .bom = true });
}

test "binary files are refused, and unstorable text is reported" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.Binary, decode(gpa, "PK\x03\x04\x00\x00ab"));
    try std.testing.expectError(error.Unrepresentable, encode(gpa, "\u{101}", .{ .encoding = .windows1252 }));
    // A CR alone in a Unix file stays as it is.
    const d = try decode(gpa, "a\nb\rc");
    defer gpa.free(d.text);
    try std.testing.expectEqualStrings("a\nb\rc", d.text);
}
