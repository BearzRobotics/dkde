//! Fuzz tests for the parsers that read files from outside: `.hexpat`
//! patterns, Kaitai `.ksy` descriptions, and `/proc/PID/maps`. Under a plain
//! `zig build test` each runs once on its seed inputs; `zig build test --fuzz`
//! mutates them. The property checked is that nothing crashes, leaks or hangs.

const std = @import("std");
const hexpat = @import("hexpat/eval.zig");
const ksy_model = @import("ksy/model.zig");
const ksy_interp = @import("ksy/interp.zig");
const ksy_expr = @import("ksy/expr.zig");
const ksy_prep = @import("ksy/prep.zig");
const disk = @import("disk.zig");

const sample_data = "\x7fELF\x02\x01\x01\x00\x03\x00\x3e\x00\x01\x00\x00\x00 DKDE sample bytes 0123456789";

fn fuzzHexpat(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [2048]u8 = undefined;
    const n = smith.slice(&buf);
    const a = std.testing.allocator;
    var failure: ?hexpat.LoadFailure = null;
    const p = (try hexpat.load(a, buf[0..n], null, &failure)) orelse {
        if (failure) |f| a.free(f.message);
        return;
    };
    defer p.deinit();
    const r = try hexpat.run(a, p, sample_data);
    r.deinit();
}

test "fuzz: hexpat patterns" {
    try std.testing.fuzz({}, fuzzHexpat, .{ .corpus = &.{
        "struct H { u8 magic[4]; u16 kind; } ; H h @ 0x00;",
        "enum E : u8 { A = 1, B }; struct S { E e; u8 n; u8 data[n]; }; S s @ 0;",
        "bitfield B { a : 3; b : 5; }; B b @ 4; fn f(u32 x) { return x * 2; }; u32 v = f(3);",
        "#define X 4\n#pragma endian big\nu8 a[X] @ 0;",
        "struct T<auto N> { u8 v[N]; }; T<2> t @ 0; match (t.v[0]) { (0x7f): u8 z @ 8; (_): u8 y @ 9; }",
    } });
}

fn fuzzKsy(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [2048]u8 = undefined;
    const n = smith.slice(&buf);
    const a = std.testing.allocator;
    const format = ksy_model.load(a, buf[0..n], null) catch return;
    defer format.deinit();
    const r = try ksy_interp.run(a, format, sample_data);
    r.deinit();
}

test "fuzz: kaitai descriptions" {
    try std.testing.fuzz({}, fuzzKsy, .{ .corpus = &.{
        "meta:\n  id: t\n  endian: le\nseq:\n  - id: magic\n    size: 4\n  - id: n\n    type: u2\n",
        "meta:\n  id: t\nseq:\n  - id: a\n    type: u1\n  - id: b\n    size: a\n    type: str\n    encoding: ASCII\n",
        "meta:\n  id: t\nseq:\n  - id: k\n    type: u1\n  - id: body\n    type:\n      switch-on: k\n      cases:\n        1: u1\n        127: u2\n",
        "meta:\n  id: t\nseq:\n  - id: xs\n    type: u1\n    repeat: until\n    repeat-until: _ == 0\n",
    } });
}

fn fuzzExpr(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [256]u8 = undefined;
    const n = smith.slice(&buf);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = ksy_expr.parse(arena.allocator(), buf[0..n]) catch {};
}

test "fuzz: kaitai expressions" {
    try std.testing.fuzz({}, fuzzExpr, .{ .corpus = &.{
        "a + b * 2 == 0x10 ? foo.bar[3] : -1",
        "(len > 4 and not _io.eof) or x.to_s == \"hi\"",
        "[1, 2, 3].size >> 1",
    } });
}

fn fuzzPrep(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [2048]u8 = undefined;
    const n = smith.slice(&buf);
    const a = std.testing.allocator;
    const out = try ksy_prep.prepare(a, buf[0..n]);
    a.free(out);
}

test "fuzz: ksy preprocessor" {
    try std.testing.fuzz({}, fuzzPrep, .{ .corpus = &.{
        "meta:\n  id: t # comment\ndoc: |\n  text: with colon\nseq:\n  - id: a\n    enum: {x: 1}\n",
        "a: [1, 2, {b: c}]\n\"quoted key\": 1\n",
    } });
}

fn fuzzMaps(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [1024]u8 = undefined;
    const n = smith.slice(&buf);
    const a = std.testing.allocator;
    const regions = try disk.parseMaps(a, buf[0..n]);
    disk.freeRegions(a, regions);
}

test "fuzz: /proc maps" {
    try std.testing.fuzz({}, fuzzMaps, .{ .corpus = &.{
        "55d0c8a00000-55d0c8a21000 r--p 00000000 08:01 1234 /usr/bin/cat\n7ffd1c3a0000-7ffd1c3c1000 rw-p 00000000 00:00 0 [stack]\n",
        "ffffffffff600000-ffffffffff601000 --xp 00000000 00:00 0 [vsyscall]\n",
    } });
}

test "a description that ends right after a key and its space" {
    const a = std.testing.allocator;
    if (ksy_model.load(a, "meta:\n  id: t\nseq:\n  - id: b\n    encoding: ", null)) |f| f.deinit() else |_| {}
    if (ksy_model.load(a, "a: ", null)) |f| f.deinit() else |_| {}
    if (ksy_model.load(a, "a:", null)) |f| f.deinit() else |_| {}
}

test "descriptions cut off in odd places" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "  id: ", "- ", "a:\n  - ", "a: [", "a: {b:", "\"", "a: |\n", "---\n" }) |src| {
        if (ksy_model.load(a, src, null)) |f| f.deinit() else |_| {}
    }
}

test "duplicate keys and failing values in a map do not double free" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "a: 1\nb: 2\na: 3\n", "a: 1\nb: 2\nc:\n  x: 1\n  x: 2\n" }) |src| {
        if (ksy_model.load(a, src, null)) |f| f.deinit() else |_| {}
    }
}

test "unterminated quotes are an error, not a crash" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "'", "\"", "a: 'x", "a: \"x", "'a", "\"a\\" }) |src| {
        if (ksy_model.load(a, src, null)) |f| f.deinit() else |_| {}
    }
}
