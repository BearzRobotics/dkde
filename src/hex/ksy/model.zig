//! Loads a Kaitai Struct `.ksy` description into plain Zig structures. Only the
//! subset that describes binary layouts is understood; everything is kept in
//! the `Format`'s arena. interp.zig walks the result over a byte buffer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Yaml = @import("yaml").Yaml;
const Value = @import("yaml").Yaml.Value;
const expr = @import("expr.zig");
const prep = @import("prep.zig");

pub const Expr = expr.Expr;

pub const Endian = enum { default, le, be };

pub const Builtin = union(enum) {
    uint: struct { size: u8, endian: Endian },
    sint: struct { size: u8, endian: Endian },
    float: struct { size: u8, endian: Endian },
    bits: struct { count: u8, little: bool },
    /// `str` and `strz`: bytes shown as text.
    str,
    /// No `type`: raw bytes.
    bytes,
};

pub const Case = struct { match: ?*const Expr, ty: *const TypeRef };

pub const TypeRef = union(enum) {
    builtin: Builtin,
    user: struct { path: []const []const u8, args: []const *const Expr },
    switch_on: struct { on: *const Expr, cases: []const Case },
};

pub const Repeat = enum { none, eos, count, until };

pub const Attr = struct {
    id: []const u8,
    ty: *const TypeRef,
    size: ?*const Expr = null,
    size_eos: bool = false,
    contents: ?[]const u8 = null,
    repeat: Repeat = .none,
    repeat_expr: ?*const Expr = null,
    cond: ?*const Expr = null,
    enum_name: ?[]const u8 = null,
    terminator: ?u8 = null,
    consume: bool = true,
    include: bool = false,
    eos_error: bool = true,
    pos: ?*const Expr = null,
    /// Instances only: read from this stream instead of the current one.
    io: ?*const Expr = null,
    value: ?*const Expr = null,
    process: bool = false,
    strz: bool = false,
};

pub const EnumDef = struct {
    name: []const u8,
    names: std.AutoArrayHashMapUnmanaged(i64, []const u8) = .empty,
    values: std.StringArrayHashMapUnmanaged(i64) = .empty,
};

pub const EndianSpec = union(enum) {
    inherit,
    fixed: bool, // true = little
    calc: struct { on: *const Expr, cases: []const EndianCase },
};

pub const EndianCase = struct { match: ?*const Expr, little: bool };

pub const TypeDef = struct {
    name: []const u8,
    parent: ?*TypeDef,
    endian: EndianSpec = .inherit,
    params: []const []const u8 = &.{},
    seq: []const Attr = &.{},
    instances: []const Attr = &.{},
    types: std.StringArrayHashMapUnmanaged(*TypeDef) = .empty,
    enums: std.StringArrayHashMapUnmanaged(*EnumDef) = .empty,
    /// Root types of imported files, by their `meta.id` (only set on a root).
    imports: std.StringArrayHashMapUnmanaged(*TypeDef) = .empty,
};

pub const Loader = struct {
    ctx: *anyopaque,
    /// Returns the text of the imported file `name` (like `common/riff`), owned
    /// by `gpa`, or null if it cannot be found.
    read: *const fn (ctx: *anyopaque, gpa: Allocator, name: []const u8) ?[]u8,
};

pub const LoadError = error{ BadFormat, OutOfMemory };

/// A loaded `.ksy`: owns everything reachable from `root`.
pub const Format = struct {
    arena: std.heap.ArenaAllocator,
    root: *TypeDef,
    id: []const u8 = "",
    title: []const u8 = "",
    extensions: []const []const u8 = &.{},
    /// Bytes the file starts with, when the first field is a `contents`.
    magic: []const u8 = &.{},
    /// Why a loaded file may not show everything (unsupported parts).
    warnings: []const []const u8 = &.{},
    /// Formats pulled in by `meta.imports`; their types are reachable from `root`.
    imported: std.ArrayList(*Format) = .empty,

    pub fn deinit(self: *Format) void {
        const gpa = self.arena.child_allocator;
        for (self.imported.items) |sub| sub.deinit();
        self.imported.deinit(gpa);
        self.arena.deinit();
        gpa.destroy(self);
    }
};

const Ctx = struct {
    gpa: Allocator,
    arena: Allocator,
    loader: ?Loader,
    depth: u8,
    warnings: std.ArrayList([]const u8) = .empty,
    importing: *std.ArrayList([]const u8),

    fn warn(self: *Ctx, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.arena, fmt, args) catch return;
        self.warnings.append(self.arena, msg) catch {};
    }
};

pub fn load(gpa: Allocator, source: []const u8, loader: ?Loader) LoadError!*Format {
    var chain: std.ArrayList([]const u8) = .empty;
    defer chain.deinit(gpa);
    return loadDepth(gpa, source, loader, 0, &chain);
}

fn loadDepth(gpa: Allocator, source: []const u8, loader: ?Loader, depth: u8, chain: *std.ArrayList([]const u8)) LoadError!*Format {
    const f = try gpa.create(Format);
    errdefer gpa.destroy(f);
    f.* = .{ .arena = std.heap.ArenaAllocator.init(gpa), .root = undefined };
    errdefer {
        for (f.imported.items) |sub| sub.deinit();
        f.imported.deinit(gpa);
        f.arena.deinit();
    }
    const arena = f.arena.allocator();

    const prepared = try prep.prepare(gpa, source);
    defer gpa.free(prepared);
    var y: Yaml = .{ .source = prepared };
    defer y.deinit(gpa);
    y.load(gpa) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadFormat,
    };
    if (y.docs.items.len == 0) return error.BadFormat;
    const top = y.docs.items[0];
    if (top != .map) return error.BadFormat;

    var ctx: Ctx = .{ .gpa = gpa, .arena = arena, .loader = loader, .depth = depth, .importing = chain };
    const meta = get(top, "meta");
    const id = if (meta) |m| text(get(m, "id")) orelse "" else "";
    f.id = try arena.dupe(u8, id);
    f.title = if (meta) |m| try arena.dupe(u8, text(get(m, "title")) orelse "") else "";
    f.extensions = if (meta) |m| try stringList(arena, get(m, "file-extension")) else &.{};

    const root = try arena.create(TypeDef);
    root.* = .{ .name = f.id, .parent = null };
    f.root = root;
    try fillType(&ctx, root, top, null);

    // Imports register the other file's root type under its own id.
    if (meta) |m| {
        for (try stringList(arena, get(m, "imports"))) |name| {
            const l = loader orelse {
                ctx.warn("import {s} needs a formats folder", .{name});
                continue;
            };
            if (depth >= 6) {
                ctx.warn("imports nest too deeply at {s}", .{name});
                continue;
            }
            const already = for (chain.items) |c| {
                if (std.mem.eql(u8, c, name)) break true;
            } else false;
            if (already) continue;
            const src = l.read(l.ctx, gpa, name) orelse {
                ctx.warn("import {s} not found", .{name});
                continue;
            };
            defer gpa.free(src);
            try chain.append(gpa, name);
            defer _ = chain.pop();
            const sub = loadDepth(gpa, src, loader, depth + 1, chain) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.BadFormat => {
                    ctx.warn("import {s} is not readable", .{name});
                    continue;
                },
            };
            f.imported.append(gpa, sub) catch {
                sub.deinit();
                return error.OutOfMemory;
            };
            try root.imports.put(arena, sub.id, sub.root);
            for (sub.warnings) |w| try ctx.warnings.append(arena, w);
        }
    }

    f.warnings = ctx.warnings.items;
    // Magic: the first field's `contents`, when it comes first at offset 0.
    if (root.seq.len > 0) {
        if (root.seq[0].contents) |c| f.magic = c;
    }
    return f;
}

fn text(v: ?Value) ?[]const u8 {
    const x = v orelse return null;
    return switch (x) {
        .scalar => |s| s,
        .boolean => |b| if (b) "true" else "false",
        else => null,
    };
}

fn get(v: Value, key: []const u8) ?Value {
    if (v != .map) return null;
    return v.map.get(key);
}

fn stringList(arena: Allocator, v: ?Value) Allocator.Error![]const []const u8 {
    const x = v orelse return &.{};
    switch (x) {
        .scalar => |s| {
            const t = std.mem.trim(u8, s, " ");
            if (t.len >= 2 and t[0] == '[' and t[t.len - 1] == ']') {
                var out: std.ArrayList([]const u8) = .empty;
                var it = std.mem.splitScalar(u8, t[1 .. t.len - 1], ',');
                while (it.next()) |part| {
                    const p = std.mem.trim(u8, part, " '\"");
                    if (p.len > 0) try out.append(arena, try arena.dupe(u8, p));
                }
                return out.items;
            }
            const out = try arena.alloc([]const u8, 1);
            out[0] = try arena.dupe(u8, s);
            return out;
        },
        .list => |l| {
            var out: std.ArrayList([]const u8) = .empty;
            for (l) |item| if (text(item)) |s| try out.append(arena, try arena.dupe(u8, s));
            return out.items;
        },
        else => return &.{},
    }
}

fn parseExpr(ctx: *Ctx, src: []const u8) ?*const Expr {
    // The tree points into its source, which must outlive the YAML tree.
    const owned = ctx.arena.dupe(u8, src) catch return null;
    return expr.parse(ctx.arena, owned) catch |err| switch (err) {
        error.BadExpression => {
            ctx.warn("cannot read expression: {s}", .{src});
            return null;
        },
        error.OutOfMemory => null,
    };
}

fn exprOf(ctx: *Ctx, v: ?Value) ?*const Expr {
    const s = text(v) orelse return null;
    return parseExpr(ctx, s);
}

fn flag(v: ?Value, default: bool) bool {
    const s = text(v) orelse return default;
    return std.mem.eql(u8, s, "true");
}

fn fillType(ctx: *Ctx, td: *TypeDef, v: Value, lexical: ?*TypeDef) LoadError!void {
    const arena = ctx.arena;
    _ = lexical;
    if (get(v, "meta")) |meta| {
        if (get(meta, "endian")) |e| td.endian = endianSpec(ctx, e);
    }
    if (get(v, "params")) |p| {
        if (p == .list) {
            var names: std.ArrayList([]const u8) = .empty;
            for (p.list) |item| if (text(get(item, "id"))) |n| try names.append(arena, try arena.dupe(u8, n));
            td.params = names.items;
        }
    }
    if (get(v, "enums")) |enums| {
        if (enums == .map) for (enums.map.keys(), enums.map.values()) |name, ev| {
            const e = try arena.create(EnumDef);
            e.* = .{ .name = try arena.dupe(u8, name) };
            if (ev == .map) for (ev.map.keys(), ev.map.values()) |k, member| {
                const num = parseInt(k) orelse continue;
                const mname = text(member) orelse text(get(member, "id")) orelse continue;
                const owned = try arena.dupe(u8, mname);
                try e.names.put(arena, num, owned);
                try e.values.put(arena, owned, num);
            };
            try td.enums.put(arena, e.name, e);
        };
    }
    if (get(v, "types")) |types| {
        if (types == .map) for (types.map.keys(), types.map.values()) |name, tv| {
            const child = try arena.create(TypeDef);
            child.* = .{ .name = try arena.dupe(u8, name), .parent = td };
            try td.types.put(arena, child.name, child);
            try fillType(ctx, child, tv, td);
        };
    }
    if (get(v, "seq")) |seq| {
        if (seq == .list) {
            var attrs: std.ArrayList(Attr) = .empty;
            for (seq.list, 0..) |item, i| {
                const id = if (text(get(item, "id"))) |n| try arena.dupe(u8, n) else try std.fmt.allocPrint(arena, "_unnamed{d}", .{i});
                try attrs.append(arena, try parseAttr(ctx, id, item));
            }
            td.seq = attrs.items;
        }
    }
    if (get(v, "instances")) |inst| {
        if (inst == .map) {
            var attrs: std.ArrayList(Attr) = .empty;
            for (inst.map.keys(), inst.map.values()) |name, item| {
                try attrs.append(arena, try parseAttr(ctx, try arena.dupe(u8, name), item));
            }
            td.instances = attrs.items;
        }
    }
}

fn endianSpec(ctx: *Ctx, v: Value) EndianSpec {
    if (text(v)) |s| {
        if (std.mem.eql(u8, s, "le")) return .{ .fixed = true };
        if (std.mem.eql(u8, s, "be")) return .{ .fixed = false };
        return .inherit;
    }
    const on = exprOf(ctx, get(v, "switch-on")) orelse return .inherit;
    const cases = get(v, "cases") orelse return .inherit;
    if (cases != .map) return .inherit;
    var out: std.ArrayList(EndianCase) = .empty;
    for (cases.map.keys(), cases.map.values()) |k, cv| {
        const val = text(cv) orelse continue;
        const key = prep.unescapeKey(ctx.arena, k) catch continue;
        const match: ?*const Expr = if (std.mem.eql(u8, key, "_")) null else (parseExpr(ctx, key) orelse continue);
        out.append(ctx.arena, .{ .match = match, .little = std.mem.eql(u8, val, "le") }) catch continue;
    }
    return .{ .calc = .{ .on = on, .cases = out.items } };
}

fn parseInt(s: []const u8) ?i64 {
    const t = std.mem.trim(u8, s, " ");
    var neg = false;
    var digits = t;
    if (std.mem.startsWith(u8, digits, "-")) {
        neg = true;
        digits = digits[1..];
    }
    var base: u8 = 10;
    if (std.mem.startsWith(u8, digits, "0x")) {
        base = 16;
        digits = digits[2..];
    } else if (std.mem.startsWith(u8, digits, "0b")) {
        base = 2;
        digits = digits[2..];
    }
    var v: i64 = 0;
    if (digits.len == 0) return null;
    for (digits) |c| {
        if (c == '_') continue;
        const d = std.fmt.charToDigit(c, base) catch return null;
        v = v *% base +% d;
    }
    return if (neg) -v else v;
}

fn parseAttr(ctx: *Ctx, id: []const u8, v: Value) LoadError!Attr {
    const arena = ctx.arena;
    const bytes_ref = try arena.create(TypeRef);
    bytes_ref.* = .{ .builtin = .bytes };
    var a: Attr = .{ .id = id, .ty = bytes_ref };
    if (v != .map) return a;

    a.size = exprOf(ctx, get(v, "size"));
    a.size_eos = flag(get(v, "size-eos"), false);
    a.cond = exprOf(ctx, get(v, "if"));
    a.pos = exprOf(ctx, get(v, "pos"));
    a.io = exprOf(ctx, get(v, "io"));
    a.value = exprOf(ctx, get(v, "value"));
    a.consume = flag(get(v, "consume"), true);
    a.include = flag(get(v, "include"), false);
    a.eos_error = flag(get(v, "eos-error"), true);
    a.process = get(v, "process") != null;
    if (text(get(v, "enum"))) |e| a.enum_name = try arena.dupe(u8, e);
    if (text(get(v, "terminator"))) |t| a.terminator = if (parseInt(t)) |n| @truncate(@as(u64, @bitCast(n))) else null;

    if (text(get(v, "repeat"))) |r| {
        if (std.mem.eql(u8, r, "eos")) a.repeat = .eos;
        if (std.mem.eql(u8, r, "expr")) a.repeat = .count;
        if (std.mem.eql(u8, r, "until")) a.repeat = .until;
    }
    if (a.repeat == .count) a.repeat_expr = exprOf(ctx, get(v, "repeat-expr"));
    if (a.repeat == .until) a.repeat_expr = exprOf(ctx, get(v, "repeat-until"));

    if (get(v, "contents")) |c| a.contents = try contentsBytes(ctx, c);
    if (get(v, "type")) |t| a.ty = try typeRef(ctx, t);
    if (a.ty.* == .builtin and a.ty.builtin == .str) {
        // strz is parsed as a `str` ending at a zero byte.
        if (text(get(v, "type"))) |ts| {
            if (std.mem.eql(u8, ts, "strz")) {
                a.strz = true;
                if (a.terminator == null) a.terminator = 0;
            }
        }
    }
    return a;
}

fn contentsBytes(ctx: *Ctx, v: Value) LoadError![]const u8 {
    const arena = ctx.arena;
    var out: std.ArrayList(u8) = .empty;
    switch (v) {
        .scalar => |s| {
            const t = std.mem.trim(u8, s, " ");
            if (t.len >= 2 and t[0] == '[' and t[t.len - 1] == ']') {
                const e = parseExpr(ctx, t) orelse return out.items;
                if (e.* == .array) for (e.array) |item| try appendContent(&out, arena, item);
            } else {
                try out.appendSlice(arena, s);
            }
        },
        .list => |l| for (l) |item| {
            const s = text(item) orelse continue;
            if (parseInt(s)) |n| {
                try out.append(arena, @truncate(@as(u64, @bitCast(n))));
            } else {
                try out.appendSlice(arena, s);
            }
        },
        else => {},
    }
    return out.items;
}

fn appendContent(out: *std.ArrayList(u8), arena: Allocator, e: *const Expr) !void {
    switch (e.*) {
        .int => |n| try out.append(arena, @truncate(@as(u64, @bitCast(n)))),
        .str => |s| try out.appendSlice(arena, s),
        else => {},
    }
}

fn builtinOf(name: []const u8) ?Builtin {
    if (std.mem.eql(u8, name, "str") or std.mem.eql(u8, name, "strz")) return .str;
    if (std.mem.eql(u8, name, "bytes")) return .bytes;
    var rest = name;
    var endian: Endian = .default;
    if (std.mem.endsWith(u8, rest, "le")) {
        endian = .le;
        rest = rest[0 .. rest.len - 2];
    } else if (std.mem.endsWith(u8, rest, "be")) {
        endian = .be;
        rest = rest[0 .. rest.len - 2];
    }
    if (rest.len < 2) return null;
    const n = std.fmt.parseInt(u8, rest[1..], 10) catch return null;
    switch (rest[0]) {
        'u' => if (n == 1 or n == 2 or n == 4 or n == 8) return .{ .uint = .{ .size = n, .endian = endian } },
        's' => if (n == 1 or n == 2 or n == 4 or n == 8) return .{ .sint = .{ .size = n, .endian = endian } },
        'f' => if (n == 4 or n == 8) return .{ .float = .{ .size = n, .endian = endian } },
        'b' => if (n >= 1 and n <= 64) return .{ .bits = .{ .count = n, .little = endian == .le } },
        else => {},
    }
    return null;
}

fn typeRef(ctx: *Ctx, v: Value) LoadError!*const TypeRef {
    const arena = ctx.arena;
    const out = try arena.create(TypeRef);
    if (text(v)) |s| {
        out.* = typeFromText(ctx, std.mem.trim(u8, s, " "));
        return out;
    }
    if (v == .map) {
        const on = exprOf(ctx, get(v, "switch-on"));
        const cases = get(v, "cases");
        if (on != null and cases != null and cases.? == .map) {
            var list: std.ArrayList(Case) = .empty;
            for (cases.?.map.keys(), cases.?.map.values()) |k, cv| {
                const ts = text(cv) orelse continue;
                const key = try prep.unescapeKey(arena, k);
                const match: ?*const Expr = if (std.mem.eql(u8, key, "_")) null else (parseExpr(ctx, key) orelse continue);
                const sub = try arena.create(TypeRef);
                sub.* = typeFromText(ctx, std.mem.trim(u8, ts, " "));
                try list.append(arena, .{ .match = match, .ty = sub });
            }
            out.* = .{ .switch_on = .{ .on = on.?, .cases = list.items } };
            return out;
        }
    }
    out.* = .{ .builtin = .bytes };
    return out;
}

fn typeFromText(ctx: *Ctx, text_in: []const u8) TypeRef {
    if (builtinOf(text_in)) |b| return .{ .builtin = b };
    const s = ctx.arena.dupe(u8, text_in) catch return .{ .builtin = .bytes };
    var name: []const u8 = s;
    var args: []const *const Expr = &.{};
    if (std.mem.indexOfScalar(u8, s, '(')) |p| {
        name = std.mem.trim(u8, s[0..p], " ");
        const close = std.mem.lastIndexOfScalar(u8, s, ')') orelse s.len;
        const inner = std.fmt.allocPrint(ctx.arena, "[{s}]", .{s[p + 1 .. close]}) catch return .{ .builtin = .bytes };
        if (parseExpr(ctx, inner)) |e| {
            if (e.* == .array) args = e.array;
        }
    }
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitSequence(u8, name, "::");
    while (it.next()) |part| parts.append(ctx.arena, part) catch return .{ .builtin = .bytes };
    return .{ .user = .{ .path = parts.items, .args = args } };
}

// -- name lookup, shared with the interpreter ----------------------------------

pub fn findType(td: *TypeDef, name: []const u8) ?*TypeDef {
    var scope: ?*TypeDef = td;
    var last: *TypeDef = td;
    while (scope) |s| : (scope = s.parent) {
        if (s.types.get(name)) |t| return t;
        if (std.mem.eql(u8, s.name, name)) return s;
        last = s;
    }
    return last.imports.get(name);
}

pub fn resolvePath(td: *TypeDef, path: []const []const u8) ?*TypeDef {
    if (path.len == 0) return null;
    var cur = findType(td, path[0]) orelse return null;
    for (path[1..]) |part| cur = cur.types.get(part) orelse return null;
    return cur;
}

pub fn findEnum(td: *TypeDef, name: []const u8) ?*EnumDef {
    var scope: ?*TypeDef = td;
    while (scope) |s| : (scope = s.parent) {
        if (s.enums.get(name)) |e| return e;
    }
    return null;
}

/// `a::b::member` -> the enum and member value, searching from `td`.
pub fn resolveEnumMember(td: *TypeDef, path: []const []const u8) ?struct { e: *EnumDef, value: i64 } {
    if (path.len < 2) return null;
    var scope = td;
    if (path.len > 2) scope = resolvePath(td, path[0 .. path.len - 2]) orelse return null;
    const e = (if (path.len > 2) scope.enums.get(path[path.len - 2]) else findEnum(scope, path[0])) orelse return null;
    const v = e.values.get(path[path.len - 1]) orelse return null;
    return .{ .e = e, .value = v };
}

test "loads types, enums and instances" {
    const src =
        \\meta:
        \\  id: demo
        \\  title: A demo # comment
        \\  file-extension: [dm, dmo]
        \\  endian: le
        \\seq:
        \\  - id: magic
        \\    contents: [0x44, "EMO"]
        \\  - id: kind
        \\    type: u1
        \\    enum: kinds
        \\  - id: body
        \\    type:
        \\      switch-on: kind
        \\      cases:
        \\        'kinds::one': one
        \\        _: u2be
        \\types:
        \\  one:
        \\    seq:
        \\      - id: x
        \\        type: u4
        \\enums:
        \\  kinds:
        \\    1: one
        \\    2: two
    ;
    const f = try load(std.testing.allocator, src, null);
    defer f.deinit();
    try std.testing.expectEqualStrings("demo", f.id);
    try std.testing.expectEqualStrings("DEMO", f.magic);
    try std.testing.expectEqual(@as(usize, 2), f.extensions.len);
    try std.testing.expectEqual(@as(usize, 3), f.root.seq.len);
    const kind = f.root.seq[1];
    try std.testing.expectEqualStrings("kinds", kind.enum_name.?);
    const sw = f.root.seq[2].ty.switch_on;
    try std.testing.expectEqual(@as(usize, 2), sw.cases.len);
    try std.testing.expect(sw.cases[1].match == null);
    try std.testing.expectEqual(@as(i64, 2), resolveEnumMember(f.root, &.{ "kinds", "two" }).?.value);
    try std.testing.expect(findType(f.root, "one") != null);
}
