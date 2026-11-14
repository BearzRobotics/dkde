//! Syntax highlighting for the entry (SpeedCrunch style): numbers, functions,
//! constants, variables, units and currencies, operators, and brackets, with the
//! bracket next to the cursor and its partner marked, and brackets that have no
//! partner marked as errors.
//!
//! This only decides what each part of the text is; main.zig turns the spans
//! into colours. Offsets are bytes, as Pango wants them.

const std = @import("std");
const eval = @import("eval.zig");
const functions = @import("functions.zig");
const quantity = @import("quantity.zig");
const units = @import("units.zig");

pub const Kind = enum { number, function, constant, variable, unit, operator, bracket, bracket_match, bracket_error };

pub const Span = struct { start: usize, end: usize, kind: Kind };

fn isOpen(c: u8) bool {
    return c == '(' or c == '[' or c == '{';
}

fn isClose(c: u8) bool {
    return c == ')' or c == ']' or c == '}';
}

fn partner(c: u8) u8 {
    return switch (c) {
        '(' => ')',
        '[' => ']',
        '{' => '}',
        ')' => '(',
        ']' => '[',
        else => '{',
    };
}

/// Operator symbols beyond ASCII that are not part of a name.
const symbol_operators = [_][]const u8{ "×", "÷", "−", "·", "√", "±", "≠", "≤", "≥", "→", "∑", "∏", "²", "³", "∞" };

fn symbolAt(text: []const u8, i: usize) usize {
    for (symbol_operators) |s| if (std.mem.startsWith(u8, text[i..], s)) return s.len;
    return 0;
}

fn nameByte(text: []const u8, i: usize) bool {
    const c = text[i];
    if (std.ascii.isAlphanumeric(c) or c == '_') return true;
    return c >= 0x80 and symbolAt(text, i) == 0;
}

/// The bytes of the name starting at `i` (letters, digits, underscore, Greek and so on).
fn nameEnd(text: []const u8, i: usize) usize {
    var j = i;
    while (j < text.len) {
        if (!nameByte(text, j)) break;
        j += 1;
    }
    return j;
}

fn isCaseWord(name: []const u8, word: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, word);
}

fn nameKind(session: ?*const eval.Session, name: []const u8, call: bool) ?Kind {
    if (isCaseWord(name, "to") or isCaseWord(name, "in") or isCaseWord(name, "mod") or isCaseWord(name, "and") or isCaseWord(name, "or") or isCaseWord(name, "xor")) return .operator;
    if (call) {
        if (eval.isBuiltin(name) or functions.isKnown(name) or quantity.isDateFunction(name)) return .function;
        if (session) |s| if (s.funcs.contains(name)) return .function;
    }
    if (session) |s| if (s.vars.contains(name) or s.rich.contains(name)) return .variable;
    if (eval.isConstant(name) or quantity.isDateName(name)) return .constant;
    if (functions.isKnown(name) and call) return .function;
    if (quantity.isUnitName(name) or units.find(name) != null) return .unit;
    return null;
}

/// The spans of `text` that have a meaning, in order. `cursor` is a byte offset.
pub fn spans(a: std.mem.Allocator, text: []const u8, cursor: usize, session: ?*const eval.Session) ![]Span {
    var out: std.ArrayList(Span) = .empty;
    const Open = struct { at: usize, ch: u8, span: usize };
    var stack: std.ArrayList(Open) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == ' ' or c == '\t') {
            i += 1;
        } else if (eval.dateLiteral(text[i..])) {
            try out.append(a, .{ .start = i, .end = i + 10, .kind = .number });
            i += 10;
        } else if (std.ascii.isDigit(c) or (c == '.' and i + 1 < text.len and std.ascii.isDigit(text[i + 1]))) {
            var j = i;
            if (c == '0' and i + 1 < text.len and (text[i + 1] == 'x' or text[i + 1] == 'X' or text[i + 1] == 'b' or text[i + 1] == 'B' or text[i + 1] == 'o' or text[i + 1] == 'O')) {
                j += 2;
                while (j < text.len and (std.ascii.isAlphanumeric(text[j]) or text[j] == '_')) j += 1;
            } else {
                while (j < text.len and (std.ascii.isDigit(text[j]) or text[j] == '.' or text[j] == '_' or (text[j] == ',' and j + 1 < text.len and std.ascii.isDigit(text[j + 1]) and j > i))) j += 1;
                // 1e5, 2.5E-3: only when digits follow.
                if (j < text.len and (text[j] == 'e' or text[j] == 'E')) {
                    var k = j + 1;
                    if (k < text.len and (text[k] == '+' or text[k] == '-')) k += 1;
                    if (k < text.len and std.ascii.isDigit(text[k])) {
                        while (k < text.len and std.ascii.isDigit(text[k])) k += 1;
                        j = k;
                    }
                }
            }
            try out.append(a, .{ .start = i, .end = j, .kind = .number });
            i = j;
        } else if (isOpen(c)) {
            try stack.append(a, .{ .at = i, .ch = c, .span = out.items.len });
            try out.append(a, .{ .start = i, .end = i + 1, .kind = .bracket });
            i += 1;
        } else if (isClose(c)) {
            if (stack.items.len > 0 and stack.items[stack.items.len - 1].ch == partner(c)) {
                const o = stack.pop().?;
                const near = (cursor == o.at or cursor == o.at + 1 or cursor == i or cursor == i + 1);
                try out.append(a, .{ .start = i, .end = i + 1, .kind = if (near) .bracket_match else .bracket });
                if (near) out.items[o.span].kind = .bracket_match;
            } else try out.append(a, .{ .start = i, .end = i + 1, .kind = .bracket_error });
            i += 1;
        } else if (nameByte(text, i) and !std.ascii.isDigit(c)) {
            const j = nameEnd(text, i);
            var k = j;
            while (k < text.len and text[k] == ' ') k += 1;
            const call = k < text.len and text[k] == '(';
            if (nameKind(session, text[i..j], call)) |kind| try out.append(a, .{ .start = i, .end = j, .kind = kind });
            i = j;
        } else if (symbolAt(text, i) > 0) {
            const n = symbolAt(text, i);
            try out.append(a, .{ .start = i, .end = i + n, .kind = .operator });
            i += n;
        } else if (std.mem.indexOfScalar(u8, "+-*/^=<>!%&|~,;:", c) != null) {
            try out.append(a, .{ .start = i, .end = i + 1, .kind = .operator });
            i += 1;
        } else i += 1;
    }
    // Brackets still open have no partner.
    for (stack.items) |o| out.items[o.span].kind = .bracket_error;
    return out.items;
}

test "numbers, names and brackets are told apart" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try spans(a, "sin(2.5e-3) + pi * 5 km to mi", 100, null);
    const want = [_]Kind{ .function, .bracket, .number, .bracket, .operator, .constant, .operator, .number, .unit, .operator, .unit };
    try std.testing.expectEqual(want.len, s.len);
    for (want, s) |k, sp| try std.testing.expectEqual(k, sp.kind);
    try std.testing.expectEqualStrings("2.5e-3", "sin(2.5e-3) + pi * 5 km to mi"[s[2].start..s[2].end]);
}

test "brackets: partners at the cursor, strays as errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const near = try spans(a, "(1+2)*3", 5, null);
    try std.testing.expectEqual(Kind.bracket_match, near[0].kind);
    try std.testing.expectEqual(Kind.bracket_match, near[4].kind);
    const stray = try spans(a, "((1+2)+3", 100, null);
    try std.testing.expectEqual(Kind.bracket_error, stray[0].kind);
    try std.testing.expectEqual(Kind.bracket, stray[1].kind);
    const extra = try spans(a, "1+2)", 100, null);
    try std.testing.expectEqual(Kind.bracket_error, extra[extra.len - 1].kind);
    const mixed = try spans(a, "(1+2]", 100, null);
    try std.testing.expectEqual(Kind.bracket_error, mixed[0].kind);
    try std.testing.expectEqual(Kind.bracket_error, mixed[mixed.len - 1].kind);
}

test "unicode operators and greek names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try spans(a, "2×π÷3 √4", 100, null);
    const want = [_]Kind{ .number, .operator, .constant, .operator, .number, .operator, .number };
    try std.testing.expectEqual(want.len, s.len);
    for (want, s) |k, sp| try std.testing.expectEqual(k, sp.kind);
}
