//! Runs a parsed ImHex pattern over a byte buffer and records the fields as the
//! same tree of nodes the Kaitai interpreter produces. A failed run keeps the
//! tree built so far and adds the problem as an error node.

const std = @import("std");
const Allocator = std.mem.Allocator;
const parse = @import("parse.zig");
const interp = @import("../ksy/interp.zig");

pub const Node = interp.Node;
pub const Result = interp.Result;
const Kind = interp.Kind;

const Expr = parse.Expr;
const Stmt = parse.Stmt;
const TypeExpr = parse.TypeExpr;
const Def = parse.Def;

// -- values ---------------------------------------------------------------------------------

const Val = union(enum) {
    int: i128,
    float: f64,
    boolean: bool,
    /// Text, and arrays of `char` and `u8` (a view of the data, never copied).
    str: []const u8,
    arr: []const Val,
    obj: *Obj,
    none,
};

const Field = struct { val: Val, start: usize = 0, size: usize = 0, local: bool = false };

const Obj = struct {
    name: []const u8,
    parent: ?*Obj,
    fields: std.StringArrayHashMapUnmanaged(Field) = .empty,
    start: usize,
    node: ?*Node,
    tb: ?*Bindings = null,
};

const Bindings = std.StringHashMapUnmanaged(Binding);
const Binding = union(enum) { ty: TypeRef, val: Val };

const BuiltinKind = enum { uint, sint, float, char, bool_, padding, str, auto };
const Builtin = struct { kind: BuiltinKind, size: u8 };

const TypeRef = union(enum) {
    builtin: Builtin,
    strukt: struct { def: *const parse.StructDef, tb: ?*Bindings },
    enum_: *const parse.EnumDef,
    bitfield: struct { def: *const parse.BitfieldDef, tb: ?*Bindings },
    align_to: i128,
};

const Error = error{ Parse, OutOfMemory };

const Flow = enum { normal, brk, cont, ret };

const max_nodes = 150_000;
const max_shown = 512;
const max_steps = 6_000_000;
const max_depth = 64;

/// Where a name or a read happens: the struct being filled in, the function
/// frame, and the template arguments in force.
const Ctx = struct {
    obj: ?*Obj,
    locals: ?*std.StringHashMapUnmanaged(Val) = null,
    tb: ?*Bindings = null,
    ns: []const u8 = "",
    little: bool = true,
    ret: Val = .none,
    /// The array element being read.
    index: usize = 0,
    /// Colour inherited from an enclosing structure.
    color: ?u32 = null,
};

const Interp = struct {
    arena: Allocator,
    data: []const u8,
    cursor: usize = 0,
    nodes: usize = 0,
    steps: usize = 0,
    depth: usize = 0,
    message: ?[]const u8 = null,
    defs: std.StringHashMapUnmanaged(*const Def) = .empty,
    root: *Obj = undefined,
    /// Where the cursor was when the current statement began (for errors).
    last_obj: ?*Obj = null,

    fn fail(self: *Interp, obj: ?*Obj, comptime fmt: []const u8, args: anytype) Error {
        if (self.message == null) {
            const msg = std.fmt.allocPrint(self.arena, fmt, args) catch return error.OutOfMemory;
            self.message = std.fmt.allocPrint(self.arena, "{s} (at 0x{X})", .{ msg, self.cursor }) catch return error.OutOfMemory;
            const holder: ?*Node = if (obj) |o| o.node else if (self.last_obj) |o| o.node else null;
            if (holder) |h| {
                const n = self.newNode(h, "error", .err, self.cursor, 0) catch return error.Parse;
                n.text = self.message.?;
            }
        }
        return error.Parse;
    }

    fn newNode(self: *Interp, parent: *Node, name: []const u8, kind: Kind, start: usize, len: usize) Allocator.Error!*Node {
        const n = try self.arena.create(Node);
        n.* = .{ .name = name, .kind = kind, .start = start, .len = len, .parent = parent };
        try parent.children.append(self.arena, n);
        self.nodes += 1;
        return n;
    }

    fn tick(self: *Interp, obj: ?*Obj) Error!void {
        self.steps += 1;
        if (self.steps > max_steps) return self.fail(obj, "stopped: the pattern needs too much work here", .{});
    }

    // -- definitions -----------------------------------------------------------------------

    fn register(self: *Interp, stmts: []const Stmt) Allocator.Error!void {
        for (stmts) |s| switch (s) {
            .def => |d| {
                const ns: []const u8, const name: []const u8 = switch (d.*) {
                    .struct_ => |x| .{ x.ns, x.name },
                    .enum_ => |x| .{ x.ns, x.name },
                    .bitfield => |x| .{ x.ns, x.name },
                    .using => |x| .{ x.ns, x.name },
                    .func => |x| .{ x.ns, x.name },
                };
                const key = if (ns.len > 0) try std.fmt.allocPrint(self.arena, "{s}::{s}", .{ ns, name }) else name;
                // A forward `using X;` must not hide a later definition.
                if (d.* == .using and d.using.target == null and self.defs.contains(key)) continue;
                try self.defs.put(self.arena, key, d);
            },
            .block => |b| try self.register(b),
            else => {},
        };
    }

    /// `a::b::name` found from namespace `ns`, trying outer namespaces too.
    fn lookupDef(self: *Interp, ns: []const u8, path: []const []const u8) ?*const Def {
        var parts = path;
        if (parts.len > 0 and std.mem.eql(u8, parts[0], "builtin")) parts = parts[1..];
        var buf: [256]u8 = undefined;
        var w: usize = 0;
        for (parts, 0..) |p, i| {
            if (i > 0) {
                if (w + 2 > buf.len) return null;
                buf[w] = ':';
                buf[w + 1] = ':';
                w += 2;
            }
            if (w + p.len > buf.len) return null;
            @memcpy(buf[w..][0..p.len], p);
            w += p.len;
        }
        const name = buf[0..w];
        var scope = ns;
        while (true) {
            var key_buf: [512]u8 = undefined;
            const key = if (scope.len > 0) std.fmt.bufPrint(&key_buf, "{s}::{s}", .{ scope, name }) catch return null else name;
            if (self.defs.get(key)) |d| return d;
            if (scope.len == 0) return null;
            scope = if (std.mem.lastIndexOf(u8, scope, "::")) |i| scope[0..i] else "";
        }
    }

    // -- types -----------------------------------------------------------------------------

    fn builtinOf(name: []const u8) ?Builtin {
        const eql = std.mem.eql;
        if (eql(u8, name, "float")) return .{ .kind = .float, .size = 4 };
        if (eql(u8, name, "double")) return .{ .kind = .float, .size = 8 };
        if (eql(u8, name, "char")) return .{ .kind = .char, .size = 1 };
        if (eql(u8, name, "char16")) return .{ .kind = .char, .size = 2 };
        if (eql(u8, name, "bool")) return .{ .kind = .bool_, .size = 1 };
        if (eql(u8, name, "padding")) return .{ .kind = .padding, .size = 1 };
        if (eql(u8, name, "str")) return .{ .kind = .str, .size = 0 };
        if (eql(u8, name, "auto")) return .{ .kind = .auto, .size = 0 };
        if (name.len >= 2 and (name[0] == 'u' or name[0] == 's')) {
            const bits = std.fmt.parseInt(u16, name[1..], 10) catch return null;
            if (bits % 8 != 0 or bits == 0 or bits > 128) return null;
            return .{ .kind = if (name[0] == 'u') .uint else .sint, .size = @intCast(bits / 8) };
        }
        return null;
    }

    fn resolveType(self: *Interp, ctx: *Ctx, te: *const TypeExpr) Error!TypeRef {
        const path = te.path;
        if (path.len == 1) {
            if (ctx.tb) |tb| if (tb.get(path[0])) |b| switch (b) {
                .ty => |t| return t,
                .val => {},
            };
            if (builtinOf(path[0])) |b| return .{ .builtin = b };
        }
        const def = self.lookupDef(ctx.ns, path) orelse {
            // std::mem::AlignTo<N> and friends.
            var joined: std.ArrayList(u8) = .empty;
            for (path, 0..) |p, i| {
                if (i > 0) try joined.appendSlice(self.arena, "::");
                try joined.appendSlice(self.arena, p);
            }
            if (std.mem.eql(u8, joined.items, "std::mem::AlignTo") and te.args.len == 1 and te.args[0] == .expr) {
                return .{ .align_to = try self.asInt(ctx.obj, try self.eval(ctx, te.args[0].expr)) };
            }
            return self.fail(ctx.obj, "unknown type {s}", .{joined.items});
        };
        switch (def.*) {
            .struct_ => |*sd| return .{ .strukt = .{ .def = sd, .tb = try self.bindArgs(ctx, sd.params, te.args) } },
            .enum_ => |*ed| return .{ .enum_ = ed },
            .bitfield => |*bd| return .{ .bitfield = .{ .def = bd, .tb = try self.bindArgs(ctx, bd.params, te.args) } },
            .using => |ud| {
                const target = ud.target orelse return self.fail(ctx.obj, "type {s} is only declared", .{ud.name});
                var inner = ctx.*;
                inner.ns = ud.ns;
                inner.tb = try self.bindArgs(ctx, ud.params, te.args);
                var t = try self.resolveType(&inner, target);
                // `be`/`le` on the alias is applied by the caller.
                if (t == .strukt and inner.tb != null and t.strukt.tb == null) t.strukt.tb = inner.tb;
                return t;
            },
            .func => return self.fail(ctx.obj, "{s} is a function, not a type", .{path[path.len - 1]}),
        }
    }

    fn bindArgs(self: *Interp, ctx: *Ctx, params: []const parse.Param, args: []const parse.TypeArg) Error!?*Bindings {
        if (params.len == 0) return null;
        const tb = try self.arena.create(Bindings);
        tb.* = .empty;
        for (params, 0..) |p, i| {
            if (i >= args.len) break;
            switch (args[i]) {
                .ty => |t| {
                    // A name that is not a type is a value (an enum or a constant).
                    if (self.resolveType(ctx, t)) |rt| {
                        try tb.put(self.arena, p.name, .{ .ty = rt });
                    } else |_| {
                        self.message = null;
                        const v = try self.eval(ctx, &.{ .path = t.path });
                        try tb.put(self.arena, p.name, .{ .val = v });
                    }
                },
                .expr => |e| try tb.put(self.arena, p.name, .{ .val = try self.eval(ctx, e) }),
            }
        }
        return tb;
    }

    // -- reading ---------------------------------------------------------------------------

    fn readUint(self: *Interp, obj: ?*Obj, size: usize, little: bool) Error!u128 {
        if (size > self.data.len -| self.cursor or self.cursor > self.data.len) {
            return self.fail(obj, "need {d} bytes but only {d} remain", .{ size, self.data.len -| self.cursor });
        }
        const b = self.data[self.cursor..][0..size];
        self.cursor += size;
        var v: u128 = 0;
        for (0..size) |i| {
            const byte: u128 = if (little) b[size - 1 - i] else b[i];
            v = (v << 8) | byte;
        }
        return v;
    }

    fn sizeOfType(self: *Interp, t: TypeRef) ?usize {
        _ = self;
        return switch (t) {
            .builtin => |b| b.size,
            .enum_ => null,
            else => null,
        };
    }

    fn enumBase(self: *Interp, ctx: *Ctx, ed: *const parse.EnumDef) Error!Builtin {
        var inner = ctx.*;
        inner.ns = ed.ns;
        const t = try self.resolveType(&inner, ed.base);
        return switch (t) {
            .builtin => |b| b,
            else => self.fail(ctx.obj, "enum {s} needs an integer type", .{ed.name}),
        };
    }

    fn enumName(self: *Interp, ctx: *Ctx, ed: *const parse.EnumDef, value: i128) ?[]const u8 {
        var next: i128 = 0;
        var inner = ctx.*;
        inner.ns = ed.ns;
        for (ed.entries) |en| {
            var lo = next;
            var hi = next;
            if (en.value) |ve| {
                lo = self.asInt(ctx.obj, self.eval(&inner, ve) catch return null) catch return null;
                hi = lo;
                if (en.hi) |he| hi = self.asInt(ctx.obj, self.eval(&inner, he) catch return null) catch return null;
            }
            next = hi + 1;
            if (value >= lo and value <= hi) return en.name;
        }
        return null;
    }

    fn attrOf(attrs: []const parse.Attr, name: []const u8) ?parse.Attr {
        for (attrs) |a| if (std.mem.eql(u8, a.name, name)) return a;
        return null;
    }

    fn colorOf(self: *Interp, ctx: *Ctx, attrs: []const parse.Attr) ?u32 {
        const a = attrOf(attrs, "color") orelse return null;
        if (a.args.len != 1) return null;
        const v = self.eval(ctx, a.args[0]) catch {
            self.message = null;
            return null;
        };
        return switch (v) {
            .str => |s| std.fmt.parseInt(u32, std.mem.trim(u8, s, "#"), 16) catch null,
            .int => |i| @truncate(@as(u128, @bitCast(i))),
            else => null,
        };
    }

    fn displayName(self: *Interp, ctx: *Ctx, attrs: []const parse.Attr, default: []const u8) []const u8 {
        const a = attrOf(attrs, "name") orelse return default;
        if (a.args.len != 1) return default;
        const v = self.eval(ctx, a.args[0]) catch {
            self.message = null;
            return default;
        };
        return switch (v) {
            .str => |s| self.arena.dupe(u8, s) catch default,
            else => default,
        };
    }

    /// Reads one value of type `t` at the cursor, creating its node under `parent`.
    fn readType(self: *Interp, ctx: *Ctx, t: TypeRef, name: []const u8, parent: ?*Node, attrs: []const parse.Attr, endian: parse.Endian) Error!Field {
        try self.tick(ctx.obj);
        var cx = ctx.*;
        switch (endian) {
            .big => cx.little = false,
            .little => cx.little = true,
            .default => {},
        }
        const start = self.cursor;
        const hidden = attrOf(attrs, "hidden") != null;
        const color = self.colorOf(&cx, attrs) orelse ctx.color;
        const shown_parent: ?*Node = if (hidden or self.nodes >= max_nodes) null else parent;
        const shown_name = if (name.len > 0 and (t == .builtin or t == .enum_)) self.displayName(&cx, attrs, name) else name;

        switch (t) {
            .align_to => |n| {
                if (n > 0) {
                    const rem = self.cursor % @as(usize, @intCast(n));
                    if (rem != 0) self.cursor += @as(usize, @intCast(n)) - rem;
                }
                return .{ .val = .none, .start = start, .size = self.cursor - start };
            },
            .builtin => |b| return self.readBuiltin(&cx, b, shown_name, shown_parent, color),
            .enum_ => |ed| {
                const base = try self.enumBase(&cx, ed);
                const f = try self.readBuiltin(&cx, base, name, null, color);
                const value = f.val.int;
                if (shown_parent) |p| {
                    const n = try self.newNode(p, shown_name, .int, start, self.cursor - start);
                    n.type_name = ed.name;
                    n.color = color;
                    n.text = if (self.enumName(&cx, ed, value)) |en|
                        try std.fmt.allocPrint(self.arena, "{s}::{s} (0x{X})", .{ ed.name, en, @as(u128, @bitCast(value)) })
                    else
                        try std.fmt.allocPrint(self.arena, "{d} (0x{X})", .{ value, @as(u128, @bitCast(value)) });
                }
                return .{ .val = f.val, .start = start, .size = self.cursor - start };
            },
            .bitfield => |bf| return self.readBitfield(&cx, bf.def, bf.tb, name, shown_parent, attrs, color),
            .strukt => |sd| return self.readStruct(&cx, sd.def, sd.tb, name, shown_parent, attrs, color),
        }
    }

    fn readBuiltin(self: *Interp, ctx: *Ctx, b: Builtin, name: []const u8, parent: ?*Node, color: ?u32) Error!Field {
        const start = self.cursor;
        var val: Val = .none;
        var kind: Kind = .int;
        switch (b.kind) {
            .uint, .char => val = .{ .int = @intCast(try self.readUint(ctx.obj, b.size, ctx.little)) },
            .sint => {
                const raw = try self.readUint(ctx.obj, b.size, ctx.little);
                const shift: u7 = @intCast(128 - 8 * @as(u16, b.size));
                val = .{ .int = @as(i128, @bitCast(raw << shift)) >> shift };
            },
            .bool_ => {
                const raw = try self.readUint(ctx.obj, 1, ctx.little);
                val = .{ .boolean = raw != 0 };
                kind = .bool;
            },
            .float => {
                const raw = try self.readUint(ctx.obj, b.size, ctx.little);
                val = .{ .float = if (b.size == 4) @as(f32, @bitCast(@as(u32, @truncate(raw)))) else @bitCast(@as(u64, @truncate(raw))) };
                kind = .float;
            },
            .padding => {
                _ = try self.readUint(ctx.obj, 1, true);
                return .{ .val = .none, .start = start, .size = 1 };
            },
            .str, .auto => return self.fail(ctx.obj, "a value of this type needs a size", .{}),
        }
        if (parent) |p| {
            const n = try self.newNode(p, name, kind, start, self.cursor - start);
            n.type_name = typeLabel(b);
            n.color = color;
            n.text = try self.show(val, b);
        }
        return .{ .val = val, .start = start, .size = self.cursor - start };
    }

    fn typeLabel(b: Builtin) []const u8 {
        return switch (b.kind) {
            .uint => switch (b.size) {
                1 => "u8",
                2 => "u16",
                3 => "u24",
                4 => "u32",
                6 => "u48",
                8 => "u64",
                16 => "u128",
                else => "uint",
            },
            .sint => switch (b.size) {
                1 => "s8",
                2 => "s16",
                3 => "s24",
                4 => "s32",
                6 => "s48",
                8 => "s64",
                16 => "s128",
                else => "sint",
            },
            .float => if (b.size == 4) "float" else "double",
            .char => if (b.size == 1) "char" else "char16",
            .bool_ => "bool",
            .padding => "padding",
            .str => "str",
            .auto => "auto",
        };
    }

    fn show(self: *Interp, v: Val, b: Builtin) Allocator.Error![]const u8 {
        switch (v) {
            .int => |i| {
                if (b.kind == .char) {
                    const c: u8 = @truncate(@as(u128, @bitCast(i)));
                    if (c >= 0x20 and c < 0x7f) return std.fmt.allocPrint(self.arena, "'{c}' (0x{X:0>2})", .{ c, c });
                    return std.fmt.allocPrint(self.arena, "0x{X:0>2}", .{c});
                }
                if (i >= 10 or i < -10) return std.fmt.allocPrint(self.arena, "{d} (0x{X})", .{ i, @as(u128, @bitCast(i)) & mask(b) });
                return std.fmt.allocPrint(self.arena, "{d}", .{i});
            },
            .float => |f| return std.fmt.allocPrint(self.arena, "{d}", .{f}),
            .boolean => |x| return if (x) "true" else "false",
            else => return "",
        }
    }

    fn mask(b: Builtin) u128 {
        if (b.size >= 16) return ~@as(u128, 0);
        return (@as(u128, 1) << @intCast(8 * @as(u16, b.size))) - 1;
    }

    fn textOfBytes(self: *Interp, bytes: []const u8, as_text: bool) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        if (as_text) {
            try out.append(self.arena, '"');
            for (bytes[0..@min(bytes.len, 80)]) |c| {
                if (c >= 0x20 and c < 0x7f and c != '"') try out.append(self.arena, c) else if (c != 0) try out.print(self.arena, "\\x{X:0>2}", .{c});
            }
            try out.append(self.arena, '"');
            if (bytes.len > 80) try out.print(self.arena, "… ({d} bytes)", .{bytes.len});
        } else {
            for (bytes[0..@min(bytes.len, 12)], 0..) |c, i| {
                if (i > 0) try out.append(self.arena, ' ');
                try out.print(self.arena, "{X:0>2}", .{c});
            }
            if (bytes.len > 12) try out.appendSlice(self.arena, " …");
            try out.print(self.arena, " ({d} bytes)", .{bytes.len});
        }
        return out.items;
    }

    fn looksLikeText(bytes: []const u8) bool {
        if (bytes.len == 0) return false;
        var printable: usize = 0;
        for (bytes[0..@min(bytes.len, 64)]) |c| {
            if ((c >= 0x20 and c < 0x7f) or c == '\t') printable += 1 else if (c != 0) return false;
        }
        return printable > 0;
    }

    fn readBitfield(self: *Interp, ctx: *Ctx, def: *const parse.BitfieldDef, tb: ?*Bindings, name: []const u8, parent: ?*Node, attrs: []const parse.Attr, color: ?u32) Error!Field {
        const start = self.cursor;
        var inner = ctx.*;
        inner.ns = def.ns;
        inner.tb = tb;
        const obj = try self.arena.create(Obj);
        obj.* = .{ .name = def.name, .parent = ctx.obj, .start = start, .node = null, .tb = tb };
        inner.obj = obj;

        var total: usize = 0;
        for (def.entries) |en| {
            if (en.bits) |be| total += @intCast(try self.asInt(obj, try self.eval(&inner, be)));
        }
        const nbytes = (total + 7) / 8;
        if (nbytes > 16) return self.fail(ctx.obj, "bitfield {s} is wider than 128 bits", .{def.name});
        const raw = try self.readUint(ctx.obj, nbytes, ctx.little);

        var node: ?*Node = null;
        if (parent) |p| if (self.nodes < max_nodes) {
            node = try self.newNode(p, self.displayName(&inner, attrs, name), .int, start, nbytes);
            node.?.type_name = def.name;
            node.?.color = color;
            node.?.text = try std.fmt.allocPrint(self.arena, "0x{X}", .{raw});
        };
        obj.node = node;
        var bit: usize = 0;
        for (def.entries) |en| {
            if (en.value) |ve| {
                const v = try self.eval(&inner, ve);
                try obj.fields.put(self.arena, en.name, .{ .val = v, .start = start, .size = nbytes, .local = true });
                continue;
            }
            const width: usize = @intCast(try self.asInt(obj, try self.eval(&inner, en.bits.?)));
            defer bit += width;
            if (en.is_padding) continue;
            const part: u128 = if (width >= 128) raw else (raw >> @intCast(bit)) & ((@as(u128, 1) << @intCast(width)) - 1);
            var val: Val = .{ .int = @intCast(part) };
            if (width == 1 and en.ty == null) val = .{ .int = @intCast(part) };
            // Which bytes hold these bits.
            const lo_byte = bit / 8;
            const hi_byte = (bit + @max(width, 1) - 1) / 8;
            const first = if (ctx.little) lo_byte else nbytes - 1 - hi_byte;
            const span = hi_byte - lo_byte + 1;
            try obj.fields.put(self.arena, en.name, .{ .val = val, .start = start + first, .size = span });
            if (node) |bn| {
                const fnode = try self.newNode(bn, self.displayName(&inner, en.attrs, en.name), .int, start + first, span);
                fnode.type_name = if (width == 1) "1 bit" else try std.fmt.allocPrint(self.arena, "{d} bits", .{width});
                fnode.color = color;
                fnode.text = try std.fmt.allocPrint(self.arena, "{d}", .{part});
                if (en.ty) |te| {
                    var tcx = inner;
                    if (self.resolveType(&tcx, te)) |rt| {
                        if (rt == .enum_) {
                            if (self.enumName(&tcx, rt.enum_, @intCast(part))) |en_name| {
                                fnode.text = try std.fmt.allocPrint(self.arena, "{s}::{s} ({d})", .{ rt.enum_.name, en_name, part });
                            }
                        }
                    } else |_| self.message = null;
                }
            }
        }
        return .{ .val = .{ .obj = obj }, .start = start, .size = nbytes };
    }

    fn readStruct(self: *Interp, ctx: *Ctx, def: *const parse.StructDef, tb: ?*Bindings, name: []const u8, parent: ?*Node, attrs: []const parse.Attr, color: ?u32) Error!Field {
        if (self.depth >= max_depth) return self.fail(ctx.obj, "structures nest too deeply", .{});
        self.depth += 1;
        defer self.depth -= 1;
        const start = self.cursor;
        const obj = try self.arena.create(Obj);
        obj.* = .{ .name = def.name, .parent = ctx.obj, .start = start, .node = null, .tb = tb };
        // Attributes of the declaration come first, then the type's own.
        const all = if (def.attrs.len == 0) attrs else try std.mem.concat(self.arena, parse.Attr, &.{ attrs, def.attrs });
        var inner = ctx.*;
        inner.obj = obj;
        inner.locals = null;
        inner.ns = def.ns;
        inner.tb = tb;
        inner.color = self.colorOf(&inner, all) orelse color;

        const inline_attr = attrOf(all, "inline") != null;
        var node: ?*Node = null;
        if (parent) |p| if (self.nodes < max_nodes) {
            if (inline_attr) {
                node = p;
            } else {
                node = try self.newNode(p, self.displayName(&inner, all, name), .struct_, start, 0);
                node.?.type_name = def.name;
                node.?.color = inner.color;
            }
        };
        obj.node = node;
        const owned_node = node != null and !inline_attr;
        defer if (owned_node) {
            node.?.len = self.cursor -| start;
        };

        try self.execBody(&inner, def, obj);
        if (def.is_union) {
            // Members of a union share the start; the size is the largest.
            var biggest: usize = 0;
            for (obj.fields.values()) |f| biggest = @max(biggest, f.size);
            self.cursor = start + biggest;
        }
        if (attrOf(all, "sealed") != null) if (owned_node) {
            node.?.children.clearRetainingCapacity();
        };
        return .{ .val = .{ .obj = obj }, .start = start, .size = self.cursor - start };
    }

    fn execBody(self: *Interp, ctx: *Ctx, def: *const parse.StructDef, obj: *Obj) Error!void {
        if (def.parent) |pe| {
            var pcx = ctx.*;
            const pt = try self.resolveType(&pcx, pe);
            if (pt == .strukt) {
                var base = ctx.*;
                base.ns = pt.strukt.def.ns;
                base.tb = pt.strukt.tb;
                try self.execBody(&base, pt.strukt.def, obj);
                // The derived type's own names are looked up with its own bindings.
            } else return self.fail(ctx.obj, "{s} cannot inherit from that", .{def.name});
        }
        const saved_tb = obj.tb;
        _ = saved_tb;
        const flow = try self.execStmts(ctx, def.body);
        _ = flow;
        const start_union = obj.start;
        if (def.is_union) self.cursor = start_union;
    }

    // -- statements ------------------------------------------------------------------------

    fn execStmts(self: *Interp, ctx: *Ctx, stmts: []const Stmt) Error!Flow {
        for (stmts) |s| {
            const flow = try self.execStmt(ctx, s);
            if (flow != .normal) return flow;
        }
        return .normal;
    }

    fn truthy(self: *Interp, ctx: *Ctx, v: Val) Error!bool {
        return switch (v) {
            .boolean => |b| b,
            .int => |i| i != 0,
            .str => |s| s.len > 0,
            else => self.fail(ctx.obj, "a condition is not true/false", .{}),
        };
    }

    fn execStmt(self: *Interp, ctx: *Ctx, s: Stmt) Error!Flow {
        try self.tick(ctx.obj);
        if (ctx.obj) |o| self.last_obj = o;
        switch (s) {
            .nop, .def => return .normal,
            .block => |b| return self.execStmts(ctx, b),
            .decl => |d| {
                try self.execDecl(ctx, d);
                return .normal;
            },
            .expr => |e| {
                _ = try self.eval(ctx, e);
                return .normal;
            },
            .padding => |e| {
                const n = try self.asInt(ctx.obj, try self.eval(ctx, e));
                if (n < 0 or n > self.data.len) return self.fail(ctx.obj, "padding of {d} bytes", .{n});
                const start = self.cursor;
                self.cursor += @intCast(n);
                if (ctx.obj) |o| if (o.node) |node| if (self.nodes < max_nodes and n > 0) {
                    const pn = try self.newNode(node, "padding", .bytes, start, @intCast(n));
                    pn.type_name = "padding";
                    pn.text = try std.fmt.allocPrint(self.arena, "{d} bytes", .{n});
                };
                return .normal;
            },
            .if_ => |i| {
                const c = try self.truthy(ctx, try self.eval(ctx, i.cond));
                return self.execStmts(ctx, if (c) i.then else i.else_);
            },
            .while_ => |w| {
                while (try self.truthy(ctx, try self.eval(ctx, w.cond))) {
                    try self.tick(ctx.obj);
                    const f = try self.execStmts(ctx, w.body);
                    if (f == .brk) break;
                    if (f == .ret) return .ret;
                }
                return .normal;
            },
            .for_ => |f| {
                _ = try self.execStmts(ctx, f.init);
                while (true) {
                    if (f.cond) |c| if (!try self.truthy(ctx, try self.eval(ctx, c))) break;
                    try self.tick(ctx.obj);
                    const fl = try self.execStmts(ctx, f.body);
                    if (fl == .brk) break;
                    if (fl == .ret) return .ret;
                    if (f.step) |st| _ = try self.eval(ctx, st);
                }
                return .normal;
            },
            .match => |m| {
                var values: std.ArrayList(Val) = .empty;
                for (m.values) |v| try values.append(self.arena, try self.eval(ctx, v));
                for (m.cases) |c| {
                    if (try self.caseMatches(ctx, c, values.items)) return self.execStmts(ctx, c.body);
                }
                return .normal;
            },
            .return_ => |e| {
                if (e) |x| ctx.ret = try self.eval(ctx, x);
                return .ret;
            },
            .break_ => return .brk,
            .continue_ => return .cont,
        }
    }

    fn caseMatches(self: *Interp, ctx: *Ctx, c: parse.MatchCase, values: []const Val) Error!bool {
        if (c.patterns.len != values.len) return false;
        for (c.patterns, values) |pat, v| {
            const p = pat orelse continue;
            if (p.hi) |hi| {
                const lo_v = try self.asInt(ctx.obj, try self.eval(ctx, p.lo));
                const hi_v = try self.asInt(ctx.obj, try self.eval(ctx, hi));
                const x = try self.asInt(ctx.obj, v);
                if (x < lo_v or x > hi_v) return false;
                continue;
            }
            var hit = try self.valEql(ctx, v, try self.eval(ctx, p.lo));
            for (p.alternatives) |alt| {
                if (hit) break;
                hit = try self.valEql(ctx, v, try self.eval(ctx, alt));
            }
            if (!hit) return false;
        }
        return true;
    }

    fn defaultValue(self: *Interp, ctx: *Ctx, te: *const TypeExpr) Val {
        _ = self;
        _ = ctx;
        if (te.path.len == 1 and std.mem.eql(u8, te.path[0], "str")) return .{ .str = "" };
        if (te.path.len == 1 and (std.mem.eql(u8, te.path[0], "float") or std.mem.eql(u8, te.path[0], "double"))) return .{ .float = 0 };
        if (te.path.len == 1 and std.mem.eql(u8, te.path[0], "bool")) return .{ .boolean = false };
        return .{ .int = 0 };
    }

    fn execDecl(self: *Interp, ctx: *Ctx, d: parse.Decl) Error!void {
        // A variable: it has a value and is not placed, or it lives in a function.
        // At the top level a declaration without `@` is a variable, not a read.
        const at_top = ctx.obj != null and ctx.obj.? == self.root;
        const is_local = (d.init != null and d.placement == null) or (ctx.locals != null and d.placement == null) or (at_top and d.placement == null and d.name.len > 0);
        if (is_local and d.name.len > 0) {
            const v = if (d.init) |ie| try self.eval(ctx, ie) else self.defaultValue(ctx, d.ty);
            if (ctx.locals) |l| {
                try l.put(self.arena, d.name, v);
            } else if (ctx.obj) |o| {
                try o.fields.put(self.arena, d.name, .{ .val = v, .local = true });
            }
            return;
        }
        const obj = ctx.obj orelse return self.fail(null, "{s} cannot be placed here", .{d.name});
        const saved = self.cursor;
        if (d.placement) |pe| {
            const at = try self.asInt(obj, try self.eval(ctx, pe));
            if (at < 0 or at > self.data.len) return self.fail(obj, "{s} is placed outside the data (0x{X})", .{ d.name, at });
            self.cursor = @intCast(at);
        }
        const start = self.cursor;
        const field = try self.readDecl(ctx, d, obj);
        if (d.name.len > 0) try obj.fields.put(self.arena, d.name, field);
        const no_advance = attrOf(d.attrs, "no_unique_address") != null;
        // An overlay (such as a whole-file view of the data) must not hide the fields under it.
        if (no_advance) if (obj.node) |n| if (n.children.items.len > 0) {
            const last = n.children.items[n.children.items.len - 1];
            if (last.start == start and last.kind != .err) last.kind = .virtual;
        };
        if (d.placement != null and obj != self.root) self.cursor = saved;
        if (no_advance) self.cursor = if (d.placement != null) saved else start;
    }

    fn readDecl(self: *Interp, ctx: *Ctx, d: parse.Decl, obj: *Obj) Error!Field {
        const t = try self.resolveType(ctx, d.ty);
        const parent = obj.node;
        const start = self.cursor;

        if (d.pointer) |pte| {
            // `Type *name : u32;`: read the offset, then the value there.
            const pt = try self.resolveType(ctx, pte);
            if (pt != .builtin) return self.fail(obj, "a pointer needs an integer type", .{});
            const pf = try self.readBuiltin(ctx, pt.builtin, d.name, null, ctx.color);
            const target = try self.asInt(obj, pf.val);
            if (target < 0 or target > self.data.len) return self.fail(obj, "{s} points outside the data (0x{X})", .{ d.name, target });
            const back = self.cursor;
            self.cursor = @intCast(target);
            const f = try self.readType(ctx, t, d.name, parent, d.attrs, d.ty.endian);
            self.cursor = back;
            return .{ .val = f.val, .start = start, .size = back - start };
        }
        const arr = d.array orelse return self.readType(ctx, t, d.name, parent, d.attrs, d.ty.endian);

        // Arrays.
        const is_bytes = t == .builtin and (t.builtin.kind == .char or (t.builtin.kind == .uint and t.builtin.size == 1)) and t.builtin.size == 1;
        switch (arr) {
            .unsized => {
                if (!is_bytes) return self.fail(obj, "{s}[] needs a char or u8 type", .{d.name});
                const rest = self.data[@min(self.cursor, self.data.len)..];
                const end = std.mem.indexOfScalar(u8, rest, 0) orelse return self.fail(obj, "no terminating zero byte for {s}", .{d.name});
                const bytes = rest[0..end];
                self.cursor += end + 1;
                try self.byteNode(ctx, parent, d, t, start, bytes);
                return .{ .val = .{ .str = bytes }, .start = start, .size = end + 1 };
            },
            .count => |ce| {
                const n_i = try self.asInt(obj, try self.eval(ctx, ce));
                if (n_i < 0 or n_i > 1 << 28) return self.fail(obj, "{s} has {d} elements", .{ d.name, n_i });
                const n: usize = @intCast(n_i);
                if (is_bytes) {
                    if (n > self.data.len -| self.cursor) return self.fail(obj, "{s} needs {d} bytes but only {d} remain", .{ d.name, n, self.data.len -| self.cursor });
                    const bytes = self.data[self.cursor..][0..n];
                    self.cursor += n;
                    try self.byteNode(ctx, parent, d, t, start, bytes);
                    return .{ .val = .{ .str = bytes }, .start = start, .size = n };
                }
                return self.readElements(ctx, d, obj, t, start, n, null);
            },
            .while_ => |cond| {
                if (is_bytes) {
                    var n: usize = 0;
                    var cx = ctx.*;
                    while (self.cursor < self.data.len) : (n += 1) {
                        cx.index = n;
                        try self.tick(obj);
                        if (!try self.truthy(&cx, try self.eval(&cx, cond))) break;
                        self.cursor += 1;
                    }
                    const bytes = self.data[start..self.cursor];
                    try self.byteNode(ctx, parent, d, t, start, bytes);
                    return .{ .val = .{ .str = bytes }, .start = start, .size = bytes.len };
                }
                return self.readElements(ctx, d, obj, t, start, std.math.maxInt(usize), cond);
            },
        }
    }

    fn byteNode(self: *Interp, ctx: *Ctx, parent: ?*Node, d: parse.Decl, t: TypeRef, start: usize, bytes: []const u8) Error!void {
        if (attrOf(d.attrs, "hidden") != null) return;
        const p = parent orelse return;
        if (self.nodes >= max_nodes) return;
        const n = try self.newNode(p, d.name, .bytes, start, bytes.len);
        n.kind = if (t.builtin.kind == .char or looksLikeText(bytes)) .str else .bytes;
        n.type_name = try std.fmt.allocPrint(self.arena, "{s}[{d}]", .{ typeLabel(t.builtin), bytes.len });
        n.color = self.colorOf(ctx, d.attrs) orelse ctx.color;
        n.text = try self.textOfBytes(bytes, t.builtin.kind == .char or looksLikeText(bytes));
    }

    fn readElements(self: *Interp, ctx: *Ctx, d: parse.Decl, obj: *Obj, t: TypeRef, start: usize, count: usize, cond: ?*const Expr) Error!Field {
        const hidden = attrOf(d.attrs, "hidden") != null;
        var holder: ?*Node = null;
        if (obj.node) |p| if (!hidden and self.nodes < max_nodes) {
            holder = try self.newNode(p, d.name, .array, start, 0);
            holder.?.color = self.colorOf(ctx, d.attrs) orelse ctx.color;
        };
        const scalar = t == .builtin or t == .enum_;
        // Elements of simple types get no nodes of their own beyond a handful.
        const make_nodes = !scalar or count <= 16;
        var items: std.ArrayList(Val) = .empty;
        var cx = ctx.*;
        const saved_index = ctx.index;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            if (cond) |c| {
                cx.index = i;
                if (!try self.truthy(&cx, try self.eval(&cx, c))) break;
            }
            try self.tick(obj);
            cx.index = i;
            const shown = make_nodes and i < max_shown;
            var name_buf: [24]u8 = undefined;
            const name = if (shown and holder != null) try self.arena.dupe(u8, std.fmt.bufPrint(&name_buf, "[{d}]", .{i}) catch "[]") else "";
            const before = self.cursor;
            const f = try self.readType(&cx, t, name, if (shown) holder else null, &.{}, d.ty.endian);
            try items.append(self.arena, f.val);
            if (!shown) if (holder) |h| {
                h.omitted += 1;
            };
            if (cond != null and self.cursor == before) return self.fail(obj, "{s} makes no progress", .{d.name});
        }
        _ = saved_index;
        if (holder) |h| {
            h.len = self.cursor - start;
            h.type_name = try std.fmt.allocPrint(self.arena, "{s}[{d}]", .{ switch (t) {
                .builtin => |b| typeLabel(b),
                .strukt => |s| s.def.name,
                .enum_ => |e| e.name,
                .bitfield => |b| b.def.name,
                .align_to => "align",
            }, items.items.len });
            h.text = try std.fmt.allocPrint(self.arena, "{d} items", .{items.items.len});
            if (scalar and items.items.len > 16 and items.items.len <= 4096) {
                // A preview instead of thousands of rows.
                var pv: std.ArrayList(u8) = .empty;
                for (items.items[0..@min(items.items.len, 8)], 0..) |v, k| {
                    if (k > 0) try pv.appendSlice(self.arena, ", ");
                    if (v == .int) try pv.print(self.arena, "{d}", .{v.int}) else if (v == .float) try pv.print(self.arena, "{d}", .{v.float});
                }
                try pv.appendSlice(self.arena, ", …");
                h.text = try std.fmt.allocPrint(self.arena, "{d} items: {s}", .{ items.items.len, pv.items });
            }
        }
        return .{ .val = .{ .arr = items.items }, .start = start, .size = self.cursor - start };
    }

    // -- expressions -----------------------------------------------------------------------

    fn asInt(self: *Interp, obj: ?*Obj, v: Val) Error!i128 {
        return switch (v) {
            .int => |i| i,
            .boolean => |b| @intFromBool(b),
            .float => |f| @intFromFloat(f),
            .str => |s| if (s.len == 1) s[0] else self.fail(obj, "expected a number but found text", .{}),
            else => self.fail(obj, "expected a number", .{}),
        };
    }

    fn lookupName(self: *Interp, ctx: *Ctx, name: []const u8) Error!Val {
        if (ctx.locals) |l| if (l.get(name)) |v| return v;
        if (ctx.tb) |tb| if (tb.get(name)) |b| switch (b) {
            .val => |v| return v,
            .ty => {},
        };
        if (ctx.obj) |o| {
            if (o.fields.get(name)) |f| return f.val;
            if (o.tb) |tb| if (tb.get(name)) |b| switch (b) {
                .val => |v| return v,
                .ty => {},
            };
        }
        if (self.root.fields.get(name)) |f| return f.val;
        return self.fail(ctx.obj, "unknown name {s}", .{name});
    }

    fn fieldOf(self: *Interp, ctx: *Ctx, e: *const Expr) Error!?Field {
        switch (e.*) {
            .path => |p| {
                if (p.len != 1) return null;
                if (ctx.obj) |o| if (o.fields.get(p[0])) |f| return f;
                if (self.root.fields.get(p[0])) |f| return f;
                return null;
            },
            .this => if (ctx.obj) |o| return .{ .val = .{ .obj = o }, .start = o.start, .size = self.cursor -| o.start },
            .parent => if (ctx.obj) |o| if (o.parent) |p| return .{ .val = .{ .obj = p }, .start = p.start, .size = self.cursor -| p.start },
            .member => |m| {
                const t = try self.eval(ctx, m.target);
                if (t == .obj) if (t.obj.fields.get(m.name)) |f| return f;
            },
            .index => |ix| {
                const t = try self.eval(ctx, ix.target);
                const i = try self.asInt(ctx.obj, try self.eval(ctx, ix.idx));
                if (t == .arr and i >= 0 and i < t.arr.len) return .{ .val = t.arr[@intCast(i)] };
            },
            else => {},
        }
        return null;
    }

    fn valEql(self: *Interp, ctx: *Ctx, a: Val, b: Val) Error!bool {
        return switch (a) {
            .int => |x| switch (b) {
                .int => |y| x == y,
                .boolean => |y| x == @intFromBool(y),
                .float => |y| @as(f64, @floatFromInt(x)) == y,
                else => false,
            },
            .boolean => |x| switch (b) {
                .boolean => |y| x == y,
                .int => |y| @intFromBool(x) == y,
                else => false,
            },
            .float => |x| switch (b) {
                .float => |y| x == y,
                .int => |y| x == @as(f64, @floatFromInt(y)),
                else => false,
            },
            .str => |x| switch (b) {
                // A char array compared with a string: stop at a zero byte.
                .str => |y| std.mem.eql(u8, std.mem.sliceTo(x, 0), std.mem.sliceTo(y, 0)),
                else => false,
            },
            else => self.fail(ctx.obj, "cannot compare those", .{}),
        };
    }

    pub fn eval(self: *Interp, ctx: *Ctx, e: *const Expr) Error!Val {
        try self.tick(ctx.obj);
        switch (e.*) {
            .int => |v| return .{ .int = v },
            .float => |v| return .{ .float = v },
            .str => |v| return .{ .str = v },
            .boolean => |v| return .{ .boolean = v },
            .null_ => return .{ .int = 0 },
            .dollar => return .{ .int = @intCast(self.cursor) },
            .this => return if (ctx.obj) |o| .{ .obj = o } else self.fail(null, "`this` is used outside a structure", .{}),
            .parent => {
                const o = ctx.obj orelse return self.fail(null, "`parent` is used outside a structure", .{});
                return if (o.parent) |p| .{ .obj = p } else self.fail(o, "`parent` is used at the top level", .{});
            },
            .path => |p| return self.evalPath(ctx, p),
            .neg => |x| return switch (try self.eval(ctx, x)) {
                .int => |i| .{ .int = -%i },
                .float => |f| .{ .float = -f },
                else => self.fail(ctx.obj, "cannot negate that", .{}),
            },
            .plus => |x| return self.eval(ctx, x),
            .bit_not => |x| return .{ .int = ~(try self.asInt(ctx.obj, try self.eval(ctx, x))) },
            .log_not => |x| return .{ .boolean = !(try self.truthy(ctx, try self.eval(ctx, x))) },
            .ternary => |t| return self.eval(ctx, if (try self.truthy(ctx, try self.eval(ctx, t.cond))) t.a else t.b),
            .binary => |b| return self.binary(ctx, b.op, b.l, b.r),
            .member => |m| {
                const t = try self.eval(ctx, m.target);
                switch (t) {
                    .obj => |o| {
                        if (o.fields.get(m.name)) |f| return f.val;
                        if (o.tb) |tb| if (tb.get(m.name)) |b| if (b == .val) return b.val;
                        return self.fail(ctx.obj, "{s} has no member {s}", .{ o.name, m.name });
                    },
                    else => return self.fail(ctx.obj, "cannot read .{s} of that", .{m.name}),
                }
            },
            .index => |ix| {
                const t = try self.eval(ctx, ix.target);
                const i = try self.asInt(ctx.obj, try self.eval(ctx, ix.idx));
                switch (t) {
                    .arr => |a| {
                        if (i < 0 or i >= a.len) return self.fail(ctx.obj, "index {d} is outside the array", .{i});
                        return a[@intCast(i)];
                    },
                    .str => |s| {
                        if (i < 0 or i >= s.len) return self.fail(ctx.obj, "index {d} is outside the array", .{i});
                        return .{ .int = s[@intCast(i)] };
                    },
                    else => return self.fail(ctx.obj, "cannot index that", .{}),
                }
            },
            .call => |c| return self.call(ctx, c.callee, c.args),
            .sizeof => |s| return self.sizeofOperand(ctx, s),
            .addressof => |x| {
                const f = (try self.fieldOf(ctx, x)) orelse return self.fail(ctx.obj, "cannot take the address of that", .{});
                return .{ .int = @intCast(f.start) };
            },
            .cast => |c| {
                const v = try self.eval(ctx, c.e);
                const t = try self.resolveType(ctx, c.ty);
                if (t != .builtin) return self.fail(ctx.obj, "cannot convert to that type", .{});
                return self.convert(ctx, v, t.builtin);
            },
            .type_value => return .none,
            .assign => |a| return self.assign(ctx, a.target, a.op, a.value),
        }
    }

    fn convert(self: *Interp, ctx: *Ctx, v: Val, b: Builtin) Error!Val {
        switch (b.kind) {
            .float => return .{ .float = switch (v) {
                .float => |f| f,
                else => @floatFromInt(try self.asInt(ctx.obj, v)),
            } },
            .bool_ => return .{ .boolean = try self.truthy(ctx, v) },
            .uint, .char => {
                const i = try self.asInt(ctx.obj, v);
                return .{ .int = @intCast(@as(u128, @bitCast(i)) & mask(b)) };
            },
            .sint => {
                const i = try self.asInt(ctx.obj, v);
                const shift: u7 = @intCast(128 - 8 * @as(u16, b.size));
                return .{ .int = @as(i128, @bitCast(@as(u128, @bitCast(i)) << shift)) >> shift };
            },
            else => return v,
        }
    }

    fn evalPath(self: *Interp, ctx: *Ctx, p: []const []const u8) Error!Val {
        if (p.len == 1) return self.lookupName(ctx, p[0]);
        // Enum::Member, then namespace constants.
        const enum_path = p[0 .. p.len - 1];
        if (self.lookupDef(ctx.ns, enum_path)) |d| if (d.* == .enum_) {
            const ed = &d.enum_;
            var inner = ctx.*;
            inner.ns = ed.ns;
            var next: i128 = 0;
            for (ed.entries) |en| {
                var v = next;
                if (en.value) |ve| v = try self.asInt(ctx.obj, try self.eval(&inner, ve));
                next = v + 1;
                if (std.mem.eql(u8, en.name, p[p.len - 1])) return .{ .int = v };
            }
        };
        // Constants of the built-in library.
        if (p.len == 4 and std.mem.eql(u8, p[0], "std") and std.mem.eql(u8, p[1], "mem") and std.mem.eql(u8, p[2], "Endian")) {
            if (std.mem.eql(u8, p[3], "Native")) return .{ .int = 0 };
            if (std.mem.eql(u8, p[3], "Big")) return .{ .int = 1 };
            if (std.mem.eql(u8, p[3], "Little")) return .{ .int = 2 };
        }
        return self.fail(ctx.obj, "unknown name {s}", .{p[p.len - 1]});
    }

    fn binary(self: *Interp, ctx: *Ctx, op: parse.Op, le: *const Expr, re: *const Expr) Error!Val {
        if (op == .log_and or op == .log_or) {
            const l = try self.truthy(ctx, try self.eval(ctx, le));
            if (op == .log_and and !l) return .{ .boolean = false };
            if (op == .log_or and l) return .{ .boolean = true };
            return .{ .boolean = try self.truthy(ctx, try self.eval(ctx, re)) };
        }
        const l = try self.eval(ctx, le);
        const r = try self.eval(ctx, re);
        switch (op) {
            .eq => return .{ .boolean = try self.valEql(ctx, l, r) },
            .ne => return .{ .boolean = !(try self.valEql(ctx, l, r)) },
            else => {},
        }
        if (op == .add and (l == .str or r == .str)) {
            const a = try self.toText(l);
            const b = try self.toText(r);
            return .{ .str = try std.mem.concat(self.arena, u8, &.{ a, b }) };
        }
        if (l == .float or r == .float) {
            const a: f64 = if (l == .float) l.float else @floatFromInt(try self.asInt(ctx.obj, l));
            const b: f64 = if (r == .float) r.float else @floatFromInt(try self.asInt(ctx.obj, r));
            return switch (op) {
                .add => .{ .float = a + b },
                .sub => .{ .float = a - b },
                .mul => .{ .float = a * b },
                .div => .{ .float = a / b },
                .lt => .{ .boolean = a < b },
                .le => .{ .boolean = a <= b },
                .gt => .{ .boolean = a > b },
                .ge => .{ .boolean = a >= b },
                else => self.fail(ctx.obj, "that operator needs integers", .{}),
            };
        }
        const a = try self.asInt(ctx.obj, l);
        const b = try self.asInt(ctx.obj, r);
        return switch (op) {
            .add => .{ .int = a +% b },
            .sub => .{ .int = a -% b },
            .mul => .{ .int = a *% b },
            .div => if (b == 0) self.fail(ctx.obj, "division by zero", .{}) else .{ .int = @divTrunc(a, b) },
            .mod => if (b == 0) self.fail(ctx.obj, "division by zero", .{}) else .{ .int = @rem(a, b) },
            .shl => .{ .int = if (b < 0 or b > 127) 0 else a << @intCast(b) },
            .shr => .{ .int = if (b < 0 or b > 127) 0 else a >> @intCast(b) },
            .lt => .{ .boolean = a < b },
            .le => .{ .boolean = a <= b },
            .gt => .{ .boolean = a > b },
            .ge => .{ .boolean = a >= b },
            .bit_and => .{ .int = a & b },
            .bit_or => .{ .int = a | b },
            .bit_xor => .{ .int = a ^ b },
            else => unreachable,
        };
    }

    fn toText(self: *Interp, v: Val) Allocator.Error![]const u8 {
        return switch (v) {
            .str => |s| s,
            .int => |i| std.fmt.allocPrint(self.arena, "{d}", .{i}),
            .float => |f| std.fmt.allocPrint(self.arena, "{d}", .{f}),
            .boolean => |b| if (b) "true" else "false",
            else => "",
        };
    }

    fn assign(self: *Interp, ctx: *Ctx, target: *const Expr, op: ?parse.Op, value: *const Expr) Error!Val {
        var v = try self.eval(ctx, value);
        if (op) |o| {
            const cur = try self.eval(ctx, target);
            // Reuse the binary operator on the two values.
            const lit_l = try self.arena.create(Expr);
            lit_l.* = valueExpr(cur);
            const lit_r = try self.arena.create(Expr);
            lit_r.* = valueExpr(v);
            v = try self.binary(ctx, o, lit_l, lit_r);
        }
        switch (target.*) {
            .path => |p| if (p.len == 1) {
                if (ctx.locals) |l| if (l.contains(p[0])) {
                    try l.put(self.arena, p[0], v);
                    return v;
                };
                if (ctx.obj) |ob| if (ob.fields.getPtr(p[0])) |f| {
                    f.val = v;
                    return v;
                };
                if (self.root.fields.getPtr(p[0])) |f| {
                    f.val = v;
                    return v;
                }
                // A new variable in a function.
                if (ctx.locals) |l| {
                    try l.put(self.arena, p[0], v);
                    return v;
                }
            },
            .member => |m| {
                const t = try self.eval(ctx, m.target);
                if (t == .obj) if (t.obj.fields.getPtr(m.name)) |f| {
                    f.val = v;
                    return v;
                };
            },
            else => {},
        }
        return self.fail(ctx.obj, "cannot assign to that", .{});
    }

    fn valueExpr(v: Val) Expr {
        return switch (v) {
            .int => |i| .{ .int = i },
            .float => |f| .{ .float = f },
            .boolean => |b| .{ .boolean = b },
            .str => |s| .{ .str = s },
            else => .{ .int = 0 },
        };
    }

    fn sizeofOperand(self: *Interp, ctx: *Ctx, s: parse.Operand) Error!Val {
        switch (s) {
            .ty => |te| {
                // `sizeof(name)` parses as a type; a name that is no type is a value.
                const t = self.resolveType(ctx, te) catch {
                    self.message = null;
                    const e: Expr = .{ .path = te.path };
                    return self.sizeofOperand(ctx, .{ .expr = &e });
                };
                return switch (t) {
                    .builtin => |b| .{ .int = b.size },
                    .enum_ => |ed| .{ .int = (try self.enumBase(ctx, ed)).size },
                    else => self.fail(ctx.obj, "sizeof of a structure type is not supported; use sizeof on a field", .{}),
                };
            },
            .expr => |e| {
                if (e.* == .dollar) return .{ .int = @intCast(self.data.len) };
                if (try self.fieldOf(ctx, e)) |f| return .{ .int = @intCast(f.size) };
                const v = try self.eval(ctx, e);
                return switch (v) {
                    .str => |t| .{ .int = @intCast(t.len) },
                    .arr => |a| .{ .int = @intCast(a.len) },
                    else => self.fail(ctx.obj, "cannot take the size of that", .{}),
                };
            },
        }
    }

    // -- calls -----------------------------------------------------------------------------

    fn calleeName(self: *Interp, callee: *const Expr) Allocator.Error![]const u8 {
        switch (callee.*) {
            .path => |p| {
                var out: std.ArrayList(u8) = .empty;
                var parts = p;
                if (parts.len > 0 and std.mem.eql(u8, parts[0], "builtin")) parts = parts[1..];
                for (parts, 0..) |x, i| {
                    if (i > 0) try out.appendSlice(self.arena, "::");
                    try out.appendSlice(self.arena, x);
                }
                return out.items;
            },
            else => return "",
        }
    }

    fn call(self: *Interp, ctx: *Ctx, callee: *const Expr, arg_exprs: []const *const Expr) Error!Val {
        // Method-style calls on text and arrays: s.length() is not ImHex, so only paths.
        if (callee.* != .path) return self.fail(ctx.obj, "that cannot be called", .{});
        const path = callee.path;
        if (self.lookupDef(ctx.ns, path)) |d| if (d.* == .func) return self.callUser(ctx, &d.func, arg_exprs);
        const name = try self.calleeName(callee);
        var args: std.ArrayList(Val) = .empty;
        for (arg_exprs) |a| try args.append(self.arena, try self.eval(ctx, a));
        return self.native(ctx, name, args.items, arg_exprs);
    }

    fn callUser(self: *Interp, ctx: *Ctx, f: *const parse.FuncDef, arg_exprs: []const *const Expr) Error!Val {
        if (self.depth >= max_depth) return self.fail(ctx.obj, "functions nest too deeply", .{});
        self.depth += 1;
        defer self.depth -= 1;
        const locals = try self.arena.create(std.StringHashMapUnmanaged(Val));
        locals.* = .empty;
        var inner: Ctx = .{ .obj = ctx.obj, .locals = locals, .ns = f.ns, .little = ctx.little };
        for (f.params, 0..) |p, i| {
            const v = if (i < arg_exprs.len) try self.eval(ctx, arg_exprs[i]) else if (p.default) |de| try self.eval(&inner, de) else return self.fail(ctx.obj, "{s} needs more arguments", .{f.name});
            try locals.put(self.arena, p.name, v);
        }
        _ = try self.execStmts(&inner, f.body);
        return inner.ret;
    }

    fn strArg(self: *Interp, ctx: *Ctx, args: []const Val, i: usize) Error![]const u8 {
        if (i >= args.len) return self.fail(ctx.obj, "a function is missing an argument", .{});
        return switch (args[i]) {
            .str => |s| s,
            else => self.fail(ctx.obj, "expected text", .{}),
        };
    }

    fn intArg(self: *Interp, ctx: *Ctx, args: []const Val, i: usize) Error!i128 {
        if (i >= args.len) return self.fail(ctx.obj, "a function is missing an argument", .{});
        return self.asInt(ctx.obj, args[i]);
    }

    fn native(self: *Interp, ctx: *Ctx, name: []const u8, args: []const Val, exprs: []const *const Expr) Error!Val {
        const eql = std.mem.eql;
        if (eql(u8, name, "std::print") or eql(u8, name, "std::warning") or eql(u8, name, "std::assert_warn")) return .none;
        if (eql(u8, name, "std::error")) return self.fail(ctx.obj, "{s}", .{try self.strArg(ctx, args, 0)});
        if (eql(u8, name, "std::assert")) {
            if (!try self.truthy(ctx, args[0])) return self.fail(ctx.obj, "{s}", .{if (args.len > 1 and args[1] == .str) args[1].str else "assertion failed"});
            return .none;
        }
        if (eql(u8, name, "std::mem::size")) return .{ .int = @intCast(self.data.len) };
        if (eql(u8, name, "std::mem::eof")) return .{ .boolean = self.cursor >= self.data.len };
        if (eql(u8, name, "std::mem::read_unsigned") or eql(u8, name, "std::mem::read_signed")) {
            const off = try self.intArg(ctx, args, 0);
            const size: usize = @intCast(try self.intArg(ctx, args, 1));
            var little = ctx.little;
            if (args.len > 2) little = (try self.intArg(ctx, args, 2)) == 0;
            if (off < 0 or size > 16 or @as(usize, @intCast(off)) + size > self.data.len) return self.fail(ctx.obj, "read outside the data", .{});
            const saved = self.cursor;
            self.cursor = @intCast(off);
            defer self.cursor = saved;
            const raw = try self.readUint(ctx.obj, size, little);
            if (eql(u8, name, "std::mem::read_unsigned") or size == 0) return .{ .int = @intCast(raw) };
            const shift: u7 = @intCast(128 - 8 * @as(u16, @intCast(size)));
            return .{ .int = @as(i128, @bitCast(raw << shift)) >> shift };
        }
        if (eql(u8, name, "std::mem::read_string")) {
            const off = try self.intArg(ctx, args, 0);
            const size: usize = @intCast(try self.intArg(ctx, args, 1));
            if (off < 0 or @as(usize, @intCast(off)) + size > self.data.len) return self.fail(ctx.obj, "read outside the data", .{});
            return .{ .str = self.data[@intCast(off)..][0..size] };
        }
        if (eql(u8, name, "std::mem::align_to")) {
            const a = try self.intArg(ctx, args, 0);
            const v = try self.intArg(ctx, args, 1);
            if (a <= 0) return .{ .int = v };
            const rem = @mod(v, a);
            return .{ .int = if (rem == 0) v else v + a - rem };
        }
        if (std.mem.startsWith(u8, name, "std::ctype::")) {
            const c: u8 = @truncate(@as(u128, @bitCast(try self.intArg(ctx, args, 0))));
            const which = name["std::ctype::".len..];
            const r = if (eql(u8, which, "isprint")) (c >= 0x20 and c < 0x7f) else if (eql(u8, which, "isdigit")) std.ascii.isDigit(c) else if (eql(u8, which, "isalpha")) std.ascii.isAlphabetic(c) else if (eql(u8, which, "isalnum")) std.ascii.isAlphanumeric(c) else if (eql(u8, which, "isspace")) std.ascii.isWhitespace(c) else if (eql(u8, which, "isupper")) std.ascii.isUpper(c) else if (eql(u8, which, "islower")) std.ascii.isLower(c) else if (eql(u8, which, "isxdigit")) std.ascii.isHex(c) else false;
            return .{ .boolean = r };
        }
        if (eql(u8, name, "std::string::length")) return .{ .int = @intCast((try self.strArg(ctx, args, 0)).len) };
        if (eql(u8, name, "std::string::substr")) {
            const s = try self.strArg(ctx, args, 0);
            const pos: usize = @intCast(@max(0, try self.intArg(ctx, args, 1)));
            const len: usize = @intCast(@max(0, try self.intArg(ctx, args, 2)));
            if (pos > s.len) return .{ .str = "" };
            return .{ .str = s[pos..@min(s.len, pos + len)] };
        }
        if (eql(u8, name, "std::string::starts_with")) return .{ .boolean = std.mem.startsWith(u8, try self.strArg(ctx, args, 0), try self.strArg(ctx, args, 1)) };
        if (eql(u8, name, "std::string::ends_with")) return .{ .boolean = std.mem.endsWith(u8, try self.strArg(ctx, args, 0), try self.strArg(ctx, args, 1)) };
        if (eql(u8, name, "std::string::contains")) return .{ .boolean = std.mem.indexOf(u8, try self.strArg(ctx, args, 0), try self.strArg(ctx, args, 1)) != null };
        if (eql(u8, name, "std::string::to_string")) return .{ .str = try self.toText(args[0]) };
        if (eql(u8, name, "std::string::parse_int")) {
            const base: u8 = if (args.len > 1) @intCast(try self.intArg(ctx, args, 1)) else 10;
            return .{ .int = std.fmt.parseInt(i128, std.mem.trim(u8, try self.strArg(ctx, args, 0), " \x00"), base) catch 0 };
        }
        if (eql(u8, name, "std::math::pow")) {
            const base = try self.intArg(ctx, args, 0);
            const e = try self.intArg(ctx, args, 1);
            var r: i128 = 1;
            var k: i128 = 0;
            while (k < e and k < 128) : (k += 1) r *%= base;
            return .{ .int = r };
        }
        if (eql(u8, name, "std::math::min")) return .{ .int = @min(try self.intArg(ctx, args, 0), try self.intArg(ctx, args, 1)) };
        if (eql(u8, name, "std::math::max")) return .{ .int = @max(try self.intArg(ctx, args, 0), try self.intArg(ctx, args, 1)) };
        if (eql(u8, name, "std::math::abs")) {
            const v = try self.intArg(ctx, args, 0);
            return .{ .int = if (v < 0) -v else v };
        }
        if (eql(u8, name, "std::core::member_count")) {
            if (args.len > 0 and args[0] == .obj) {
                var n: i128 = 0;
                for (args[0].obj.fields.values()) |f| if (!f.local) {
                    n += 1;
                };
                return .{ .int = n };
            }
            if (args.len > 0 and args[0] == .arr) return .{ .int = @intCast(args[0].arr.len) };
            return .{ .int = 0 };
        }
        if (eql(u8, name, "std::core::has_member")) {
            if (args.len > 1 and args[0] == .obj and args[1] == .str) return .{ .boolean = args[0].obj.fields.contains(args[1].str) };
            return .{ .boolean = false };
        }
        if (eql(u8, name, "std::core::array_index")) return .{ .int = @intCast(ctx.index) };
        if (eql(u8, name, "std::core::set_display_name")) {
            if (args.len > 1 and args[0] == .obj and args[1] == .str) if (args[0].obj.node) |n| {
                n.name = try self.arena.dupe(u8, args[1].str);
            };
            return .none;
        }
        if (eql(u8, name, "std::core::set_endian")) {
            ctx.little = (try self.intArg(ctx, args, 0)) != 1;
            return .none;
        }
        if (eql(u8, name, "std::core::formatted_value") or eql(u8, name, "std::core::set_pattern_color")) return .none;
        if (eql(u8, name, "typenameof")) return .{ .str = if (args.len > 0 and args[0] == .obj) args[0].obj.name else "" };
        if (eql(u8, name, "std::format")) return .{ .str = try self.format(ctx, args) };
        _ = exprs;
        return self.fail(ctx.obj, "the function {s} is not supported", .{name});
    }

    /// `std::format` with `{}`, `{:x}`, `{:X}`, `{:08X}` and `{:d}`.
    fn format(self: *Interp, ctx: *Ctx, args: []const Val) Error![]const u8 {
        const fmt = try self.strArg(ctx, args, 0);
        var out: std.ArrayList(u8) = .empty;
        var next: usize = 1;
        var i: usize = 0;
        while (i < fmt.len) : (i += 1) {
            const c = fmt[i];
            if (c == '{' and i + 1 < fmt.len and fmt[i + 1] == '{') {
                try out.append(self.arena, '{');
                i += 1;
                continue;
            }
            if (c == '}' and i + 1 < fmt.len and fmt[i + 1] == '}') {
                try out.append(self.arena, '}');
                i += 1;
                continue;
            }
            if (c != '{') {
                try out.append(self.arena, c);
                continue;
            }
            const close = std.mem.indexOfScalarPos(u8, fmt, i, '}') orelse break;
            const spec = fmt[i + 1 .. close];
            i = close;
            if (next >= args.len) continue;
            const v = args[next];
            next += 1;
            const colon = std.mem.indexOfScalar(u8, spec, ':');
            const mode: u8 = if (colon) |ci| (if (spec.len > ci + 1) spec[spec.len - 1] else 'd') else 'd';
            var width: usize = 0;
            if (colon) |ci| {
                var digits = spec[ci + 1 ..];
                if (digits.len > 0 and (digits[digits.len - 1] == 'x' or digits[digits.len - 1] == 'X' or digits[digits.len - 1] == 'd')) digits = digits[0 .. digits.len - 1];
                width = std.fmt.parseInt(usize, std.mem.trimStart(u8, digits, "0"), 10) catch 0;
            }
            switch (v) {
                .int => |n| {
                    var buf: [80]u8 = undefined;
                    const un: u128 = @bitCast(n);
                    const text = switch (mode) {
                        'x' => std.fmt.bufPrint(&buf, "{x}", .{un}) catch "",
                        'X' => std.fmt.bufPrint(&buf, "{X}", .{un}) catch "",
                        else => std.fmt.bufPrint(&buf, "{d}", .{n}) catch "",
                    };
                    var pad: usize = if (width > text.len) width - text.len else 0;
                    while (pad > 0) : (pad -= 1) try out.append(self.arena, '0');
                    try out.appendSlice(self.arena, text);
                },
                else => try out.appendSlice(self.arena, try self.toText(v)),
            }
        }
        return out.items;
    }
};

// -- entry ------------------------------------------------------------------------------------

pub const Loader = struct {
    ctx: *anyopaque,
    /// Source of an imported file, owned by `gpa`; null if missing.
    read: *const fn (ctx: *anyopaque, gpa: Allocator, name: []const u8) ?[]u8,
};

pub const Pattern = struct {
    arena: std.heap.ArenaAllocator,
    program: parse.Program,
    /// Definitions from imported files, run before the program.
    imported: []const []const Stmt,
    warnings: []const []const u8,
    description: []const u8,

    pub fn deinit(self: *Pattern) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self);
    }
};

pub const LoadFailure = struct { line: u32, message: []const u8 };

/// Parses `source` and the files it imports. On a syntax error returns null
/// and fills `failure` (its text lives in the returned-from `arena_out`).
pub fn load(gpa: Allocator, source: []const u8, loader: ?Loader, failure: *?LoadFailure) Allocator.Error!?*Pattern {
    const p = try gpa.create(Pattern);
    errdefer gpa.destroy(p);
    p.* = .{ .arena = std.heap.ArenaAllocator.init(gpa), .program = undefined, .imported = &.{}, .warnings = &.{}, .description = "" };
    errdefer p.arena.deinit();
    const arena = p.arena.allocator();

    var pf: ?parse.Failure = null;
    // The tree points into the text, which the caller may free.
    const owned_source = try arena.dupe(u8, source);
    p.program = parse.parse(arena, owned_source, &pf) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Syntax => {
            if (pf) |f| failure.* = .{ .line = f.line, .message = try gpa.dupe(u8, f.message) } else failure.* = .{ .line = 0, .message = try gpa.dupe(u8, "syntax error") };
            p.arena.deinit();
            gpa.destroy(p);
            return null;
        },
    };
    p.description = p.program.description;

    var imported: std.ArrayList([]const Stmt) = .empty;
    var warnings: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    try loadImports(gpa, arena, p.program.imports, loader, &imported, &warnings, &seen, 0);
    p.imported = imported.items;
    p.warnings = warnings.items;
    return p;
}

fn loadImports(gpa: Allocator, arena: Allocator, names: []const []const u8, loader: ?Loader, out: *std.ArrayList([]const Stmt), warnings: *std.ArrayList([]const u8), seen: *std.StringHashMapUnmanaged(void), depth: u8) Allocator.Error!void {
    for (names) |raw| {
        // The standard library is built in.
        if (std.mem.startsWith(u8, raw, "std/") or std.mem.startsWith(u8, raw, "std.")) continue;
        if (seen.contains(raw)) continue;
        try seen.put(arena, raw, {});
        const l = loader orelse continue;
        if (depth > 6) continue;
        const text = l.read(l.ctx, gpa, raw) orelse {
            try warnings.append(arena, try std.fmt.allocPrint(arena, "import {s} not found", .{raw}));
            continue;
        };
        defer gpa.free(text);
        var pf: ?parse.Failure = null;
        const kept = try arena.dupe(u8, text);
        const prog = parse.parse(arena, kept, &pf) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Syntax => {
                try warnings.append(arena, try std.fmt.allocPrint(arena, "import {s} has an unsupported construct (line {d})", .{ raw, if (pf) |f| f.line else 0 }));
                continue;
            },
        };
        try loadImports(gpa, arena, prog.imports, loader, out, warnings, seen, depth + 1);
        try out.append(arena, prog.stmts);
    }
}

/// Runs `pattern` over `data`. A failed run still returns the partial tree.
pub fn run(gpa: Allocator, pattern: *Pattern, data: []const u8) Allocator.Error!*Result {
    const r = try gpa.create(Result);
    errdefer gpa.destroy(r);
    r.* = .{ .arena = std.heap.ArenaAllocator.init(gpa), .root = undefined };
    errdefer r.arena.deinit();
    const arena = r.arena.allocator();

    const root_node = try arena.create(Node);
    root_node.* = .{ .name = if (pattern.description.len > 0) pattern.description else "file", .kind = .struct_, .start = 0, .len = data.len };
    r.root = root_node;

    var it: Interp = .{ .arena = arena, .data = data };
    const root = try arena.create(Obj);
    root.* = .{ .name = "root", .parent = null, .start = 0, .node = root_node };
    it.root = root;
    it.last_obj = root;
    for (pattern.imported) |stmts| try it.register(stmts);
    try it.register(pattern.program.stmts);

    var ctx: Ctx = .{ .obj = root, .little = pattern.program.endian != .big };
    _ = it.execStmts(&ctx, pattern.program.stmts) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Parse => {},
    };
    r.message = it.message;
    return r;
}

// -- tests ------------------------------------------------------------------------------------

fn runText(gpa: Allocator, src: []const u8, data: []const u8) !struct { p: *Pattern, r: *Result } {
    var failure: ?LoadFailure = null;
    const p = (try load(gpa, src, null, &failure)) orelse return error.TestSyntax;
    errdefer p.deinit();
    return .{ .p = p, .r = try run(gpa, p, data) };
}

fn child(n: *const Node, name: []const u8) ?*Node {
    for (n.children.items) |c| if (std.mem.eql(u8, c.name, name)) return c;
    return null;
}

test "structs, enums, arrays and conditions" {
    const a = std.testing.allocator;
    const t = try runText(a,
        \\#pragma endian big
        \\enum Kind : u8 { One = 1, Two };
        \\struct Item { u8 len; char name[len]; };
        \\struct File {
        \\  char magic[2];
        \\  u16 count;
        \\  Kind kind;
        \\  Item items[count];
        \\  if (kind == Kind::Two) { u8 extra; }
        \\};
        \\File f @ 0;
    , "AB\x00\x02\x02\x02hi\x01Z\x09");
    defer t.p.deinit();
    defer t.r.deinit();
    try std.testing.expect(t.r.message == null);
    const f = child(t.r.root, "f").?;
    try std.testing.expectEqualStrings("\"AB\"", child(f, "magic").?.text);
    try std.testing.expectEqualStrings("2", child(f, "count").?.text);
    try std.testing.expectEqualStrings("Kind::Two (0x2)", child(f, "kind").?.text);
    try std.testing.expectEqual(@as(usize, 2), child(f, "items").?.children.items.len);
    try std.testing.expectEqualStrings("9", child(f, "extra").?.text);
    try std.testing.expectEqual(@as(usize, 11), f.len);
}

test "bitfields, templates, functions and while arrays" {
    const a = std.testing.allocator;
    const t = try runText(a,
        \\bitfield Flags { lo : 3; mid : 1; hi : 4; };
        \\struct Box<T, auto N> { T v[N]; };
        \\fn twice(u32 x) { return x * 2; };
        \\struct S {
        \\  Flags flags;
        \\  Box<u8, 2> b;
        \\  u8 list[while(std::mem::read_unsigned($, 1) != 0)];
        \\  padding[1];
        \\  u8 after = twice(3);
        \\};
        \\S s @ 0;
    , "\xA5\x01\x02\x07\x08\x00\x00");
    defer t.p.deinit();
    defer t.r.deinit();
    try std.testing.expect(t.r.message == null);
    const s = child(t.r.root, "s").?;
    const flags = child(s, "flags").?;
    try std.testing.expectEqualStrings("5", child(flags, "lo").?.text);
    try std.testing.expectEqualStrings("0", child(flags, "mid").?.text);
    try std.testing.expectEqualStrings("10", child(flags, "hi").?.text);
    try std.testing.expectEqual(@as(usize, 2), child(s, "list").?.len);
}

test "a failing read keeps the partial tree" {
    const a = std.testing.allocator;
    const t = try runText(a,
        \\struct S { u8 a; u32 b; u8 never; };
        \\S s @ 0;
    , "\x01\x02");
    defer t.p.deinit();
    defer t.r.deinit();
    try std.testing.expect(t.r.message != null);
    const s = child(t.r.root, "s").?;
    try std.testing.expect(child(s, "a") != null);
    try std.testing.expect(child(s, "error") != null);
}

test "match, inheritance, placement and attributes" {
    const a = std.testing.allocator;
    const t = try runText(a,
        \\struct Base { u8 tag; };
        \\struct Derived : Base { u8 more; } [[color("FF0000")]];
        \\struct M {
        \\  u8 k;
        \\  match (k) { (1 | 2): u8 a; (_): u16 b; }
        \\  u8 far @ 6 [[name("Far")]];
        \\};
        \\M m @ 0;
        \\Derived d @ 4;
    , "\x03\x01\x00\x00\x07\x08\x09");
    defer t.p.deinit();
    defer t.r.deinit();
    try std.testing.expect(t.r.message == null);
    const m = child(t.r.root, "m").?;
    try std.testing.expect(child(m, "b") != null);
    try std.testing.expectEqualStrings("9", child(m, "Far").?.text);
    const d = child(t.r.root, "d").?;
    try std.testing.expectEqual(@as(?u32, 0xFF0000), d.color);
    try std.testing.expect(child(d, "tag") != null);
    try std.testing.expect(child(d, "more") != null);
}
