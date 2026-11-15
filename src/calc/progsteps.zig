//! Show Work for Programmer mode: the working a person would write when doing it by hand. Bitwise
//! operations are lined up bit by bit, shifts move the bits, a negative number becomes its two's
//! complement (invert, add one), and the answer is converted to the other bases the way it is done on
//! paper: grouping bits for hex and octal, repeated division for decimal to binary.

const std = @import("std");
const eval = @import("eval.zig");
const num = @import("num.zig");
const steps = @import("steps.zig");

pub const Step = steps.Step;
pub const Ctx = steps.Ctx;
pub const Error = eval.Error;

fn push(a: std.mem.Allocator, list: *std.ArrayList(Step), note: []const u8, math: []const u8) Error!void {
    try list.append(a, .{ .note = note, .math = math });
}

/// The magnitude's digits in `base`, upper case, no prefix.
fn digits(a: std.mem.Allocator, v: u128, base: u8) Error![]u8 {
    if (v == 0) return a.dupe(u8, "0");
    var buf: [130]u8 = undefined;
    var i: usize = buf.len;
    var x = v;
    while (x > 0) {
        i -= 1;
        const d: u8 = @intCast(x % base);
        buf[i] = if (d < 10) '0' + d else 'A' + (d - 10);
        x /= base;
    }
    return a.dupe(u8, buf[i..]);
}

/// `v` as `nibbles` groups of four bits, most significant first: "1100 1010".
fn bitsText(a: std.mem.Allocator, v: u128, nibbles: usize) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var n = nibbles;
    while (n > 0) : (n -= 1) {
        const shift: u7 = @intCast((n - 1) * 4);
        const nib: u8 = @intCast((v >> shift) & 0xf);
        var k: u8 = 4;
        while (k > 0) : (k -= 1) try out.append(a, if ((nib >> @intCast(k - 1)) & 1 == 1) '1' else '0');
        if (n > 1) try out.append(a, ' ');
    }
    return out.toOwnedSlice(a);
}

/// The bits of a value as an unsigned word of `bits`.
fn unsigned(v: i128, bits: u8) u128 {
    const u: u128 = @bitCast(v);
    return if (bits >= 128) u else u & ((@as(u128, 1) << @intCast(bits)) - 1);
}

/// Groups of four needed for the largest of the values, at least two, at most the word.
fn nibblesFor(values: []const u128, bits: u8) usize {
    var most: usize = 0;
    for (values) |v| {
        var n: usize = 0;
        var x = v;
        while (x > 0) : (x >>= 4) n += 1;
        most = @max(most, n);
    }
    return std.math.clamp(most, 2, @max((bits + 3) / 4, 2));
}

fn lineFor(a: std.mem.Allocator, label: []const u8, v: u128, nibbles: usize) Error![]u8 {
    return std.fmt.allocPrint(a, "{s} = {s}", .{ label, try bitsText(a, v, nibbles) });
}

fn opName(op: eval.Op) ?struct { word: []const u8, rule: []const u8 } {
    return switch (op) {
        .band => .{ .word = "AND", .rule = "Each bit is 1 only where both bits are 1" },
        .bor => .{ .word = "OR", .rule = "Each bit is 1 where either bit is 1" },
        .bxor => .{ .word = "XOR", .rule = "Each bit is 1 where the two bits differ" },
        else => null,
    };
}

fn evalInt(ev: *eval.Eval, n: *const eval.Node) ?i128 {
    const v = ev.eval(n, null) catch return null;
    return num.int128(v);
}

/// A negative value as its two's complement in `bits`: the magnitude, the inverted bits, one added.
fn twosComplement(ctx: Ctx, list: *std.ArrayList(Step), v: i128, bits: u8) Error!void {
    const a = ctx.a;
    const mag: u128 = @intCast(-v);
    const nib = nibblesFor(&.{mag}, bits);
    const width = @max((bits + 3) / 4, nib);
    const pos = unsigned(@intCast(mag), bits);
    const inverted = ~pos & (if (bits >= 128) ~@as(u128, 0) else (@as(u128, 1) << @intCast(bits)) - 1);
    const plus_one = (inverted +% 1) & (if (bits >= 128) ~@as(u128, 0) else (@as(u128, 1) << @intCast(bits)) - 1);
    try push(a, list, try std.fmt.allocPrint(a, "A negative number is stored as its two's complement in {d} bits. Write {d} in binary", .{ bits, mag }), try std.fmt.allocPrint(a, "{d} = {s}", .{ mag, try bitsText(a, pos, width) }));
    try push(a, list, "Invert every bit", try std.fmt.allocPrint(a, "NOT = {s}", .{try bitsText(a, inverted, width)}));
    try push(a, list, "Add one", try std.fmt.allocPrint(a, "+ 1 = {s}", .{try bitsText(a, plus_one, width)}));
}

/// Decimal to binary by repeated division by 2, for values small enough to write out (up to 16 bits).
fn divisionSteps(ctx: Ctx, list: *std.ArrayList(Step), v: u128, base: u8) Error!void {
    const a = ctx.a;
    if (v < 2 or v > 0xffff) return;
    var rows: std.ArrayList(u8) = .empty;
    var x = v;
    var remainders: std.ArrayList(u8) = .empty;
    while (x > 0) {
        const q = x / base;
        const r: u8 = @intCast(x % base);
        try rows.print(a, "{s}{d} ÷ {d} = {d} remainder {d}", .{ if (rows.items.len > 0) "\n" else "", x, base, q, r });
        try remainders.append(a, if (r < 10) '0' + r else 'A' + (r - 10));
        x = q;
    }
    std.mem.reverse(u8, remainders.items);
    try push(a, list, try std.fmt.allocPrint(a, "Divide by {d} until nothing is left; the remainders, read from the last to the first, are the digits in base {d}", .{ base, base }), rows.items);
    try push(a, list, "Read the remainders upward", try std.fmt.allocPrint(a, "{d} = {s} (base {d})", .{ v, remainders.items, base }));
}

pub fn explain(ctx: Ctx, text: []const u8) Error!?[]Step {
    const a = ctx.a;
    const bits = ctx.mode.bits;
    var problem: eval.Problem = .{};
    const st = eval.parse(a, text, ctx.mode, &problem) catch return null;
    const root = switch (st) {
        .expr => |n| n,
        .equation => return null,
    };
    var ev: eval.Eval = .{ .a = a, .session = ctx.session, .mode = ctx.mode, .problem = &problem };
    const total = evalInt(&ev, root) orelse return null;

    var list: std.ArrayList(Step) = .empty;
    try push(a, &list, "", try a.dupe(u8, text));

    switch (root.*) {
        .binary => |b| {
            const l = evalInt(&ev, b.l);
            const r = evalInt(&ev, b.r);
            if (l != null and r != null) {
                if (opName(b.op)) |op| {
                    const lu = unsigned(l.?, bits);
                    const ru = unsigned(r.?, bits);
                    const nib = nibblesFor(&.{ lu, ru, unsigned(total, bits) }, bits);
                    try push(a, &list, "Write both numbers in binary, one under the other", try std.fmt.allocPrint(a, "{s}\n{s}", .{ try lineFor(a, "A", lu, nib), try lineFor(a, "B", ru, nib) }));
                    try push(a, &list, try std.fmt.allocPrint(a, "{s}: {s}", .{ op.word, op.rule }), try std.fmt.allocPrint(a, "A {s} B = {s}", .{ op.word, try bitsText(a, unsigned(total, bits), nib) }));
                } else if (b.op == .shl or b.op == .shr) {
                    const nib = nibblesFor(&.{ unsigned(l.?, bits), unsigned(total, bits) }, bits);
                    try push(a, &list, "Write the number in binary", try lineFor(a, "A", unsigned(l.?, bits), nib));
                    const dir: []const u8 = if (b.op == .shl) "left" else "right";
                    const fill: []const u8 = if (b.op == .shl) "Zeros come in on the right; it is the same as multiplying by 2 for each place" else "The bits that fall off the right are lost; it is the same as dividing by 2 for each place, rounding down";
                    try push(a, &list, try std.fmt.allocPrint(a, "Move every bit {d} place(s) to the {s}. {s}", .{ r.?, dir, fill }), try bitsText(a, unsigned(total, bits), nib));
                } else {
                    // Ordinary arithmetic on whole numbers, in decimal.
                    const sym: []const u8 = switch (b.op) {
                        .add => "+",
                        .sub => "−",
                        .mul => "×",
                        .div => "÷",
                        .mod => "mod",
                        .pow => "^",
                        else => "?",
                    };
                    try push(a, &list, "Work it out as whole numbers", try std.fmt.allocPrint(a, "{d} {s} {d} = {d}", .{ l.?, sym, r.?, total }));
                }
            }
        },
        .unary => |u| if (u.op == .bnot) {
            if (evalInt(&ev, u.arg)) |x| {
                const nib = nibblesFor(&.{ unsigned(x, bits), unsigned(total, bits) }, bits);
                try push(a, &list, "Write the number in binary", try lineFor(a, "A", unsigned(x, bits), nib));
                try push(a, &list, "NOT: flip every bit, 1 becomes 0 and 0 becomes 1", try std.fmt.allocPrint(a, "NOT A = {s}", .{try bitsText(a, unsigned(total, bits), nib)}));
            }
        },
        else => {},
    }

    // A negative answer is its two's complement in the word.
    if (total < 0) try twosComplement(ctx, &list, total, bits);

    // The answer in the other bases, the paper way.
    const word = unsigned(total, bits);
    try push(a, &list, "The answer", try std.fmt.allocPrint(a, "{d}", .{total}));
    if (total >= 0) try divisionSteps(ctx, &list, word, 2);
    const nib = nibblesFor(&.{word}, bits);
    const hex_groups = try hexGroups(a, word, nib);
    try push(a, &list, "Group the bits in fours; each group is one hex digit (0–9, A–F)", try std.fmt.allocPrint(a, "{s}\n{s} = 0x{s}", .{ try bitsText(a, word, nib), hex_groups, try digits(a, word, 16) }));
    try push(a, &list, "Group the bits in threes, from the right; each group is one octal digit", try std.fmt.allocPrint(a, "0o{s}", .{try digits(a, word, 8)}));
    return list.items;
}

/// "C   A" under the nibbles: the hex digit of each group of four.
fn hexGroups(a: std.mem.Allocator, v: u128, nibbles: usize) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var n = nibbles;
    while (n > 0) : (n -= 1) {
        const shift: u7 = @intCast((n - 1) * 4);
        const d: u8 = @intCast((v >> shift) & 0xf);
        try out.appendSlice(a, "   ");
        try out.append(a, if (d < 10) '0' + d else 'A' + (d - 10));
        if (n > 1) try out.append(a, ' ');
    }
    return out.items;
}

fn run(source: []const u8, bits: u8, base: u8, want: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var session: eval.Session = .{ .gpa = std.testing.allocator };
    defer session.deinit();
    const out = (try explain(.{ .a = a, .session = &session, .mode = .{ .programmer = true, .bits = bits, .base = base } }, source)) orelse return error.TestUnexpectedResult;
    for (want) |w| {
        var found = false;
        for (out) |s| if (std.mem.indexOf(u8, s.math, w) != null) {
            found = true;
        };
        if (!found) {
            std.debug.print("missing \"{s}\" in:\n", .{w});
            for (out) |s| std.debug.print("  [{s}] {s}\n", .{ s.note, s.math });
            return error.TestExpectedEqual;
        }
    }
}

test "AND is lined up bit by bit" {
    try run("202 and 86", 64, 10, &.{ "A = 1100 1010", "B = 0101 0110", "A AND B = 0100 0010", "= 0x42" });
}

test "OR and XOR" {
    try run("12 or 3", 64, 10, &.{ "A = 0000 1100", "B = 0000 0011", "A OR B = 0000 1111" });
    try run("5 xor 3", 64, 10, &.{"A XOR B = 0000 0110"});
}

test "shifts move the bits" {
    try run("1 << 4", 64, 10, &.{ "A = 0000 0001", "0001 0000" });
}

test "NOT in a word, and a negative answer in two's complement" {
    try run("not 5", 8, 10, &.{ "NOT A = 1111 1010", "= 0xFA" });
    try run("0 - 5", 8, 10, &.{ "5 = 0000 0101", "NOT = 1111 1010", "+ 1 = 1111 1011" });
}

test "decimal to binary by division" {
    try run("10", 64, 10, &.{ "10 ÷ 2 = 5 remainder 0", "1 ÷ 2 = 0 remainder 1", "10 = 1010 (base 2)" });
}
