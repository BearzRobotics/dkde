//! Runs a loaded Kaitai format over a byte buffer and records what it found as
//! a tree of nodes with byte ranges. Parsing stops at the first problem but
//! keeps everything read so far, with the problem added as an error node, which
//! is what a reverse engineer wants to see.

const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("model.zig");
const expr = @import("expr.zig");

const Expr = expr.Expr;
const TypeDef = model.TypeDef;
const Attr = model.Attr;
const TypeRef = model.TypeRef;

pub const Kind = enum { struct_, array, int, float, str, bytes, bool, virtual, err };

pub const Node = struct {
    name: []const u8,
    type_name: []const u8 = "",
    kind: Kind,
    /// Absolute byte range in the buffer. `len` is 0 for computed values.
    start: usize = 0,
    len: usize = 0,
    /// The value rendered for display; empty for structures.
    text: []const u8 = "",
    parent: ?*Node = null,
    children: std.ArrayList(*Node) = .empty,
    /// Array elements parsed but not recorded.
    omitted: usize = 0,
};

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    root: *Node,
    /// The first error, also present as a node.
    message: ?[]const u8 = null,

    pub fn deinit(self: *Result) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self);
    }
};

const Val = union(enum) {
    int: i64,
    float: f64,
    boolean: bool,
    bytes: []const u8,
    arr: []const Val,
    obj: *Obj,
    io: *Stream,
    none,
};

const Stream = struct {
    data: []const u8,
    /// Absolute offset of `data[0]` in the whole buffer.
    base: usize,
    pos: usize = 0,
    bits_left: u8 = 0,
    cur: u8 = 0,

    fn eof(self: *const Stream) bool {
        return self.pos >= self.data.len and self.bits_left == 0;
    }
    fn abs(self: *const Stream) usize {
        return self.base + self.pos - @as(usize, if (self.bits_left > 0) 1 else 0);
    }
};

const Obj = struct {
    td: *TypeDef,
    parent: ?*Obj,
    io: *Stream,
    little: bool,
    fields: std.StringArrayHashMapUnmanaged(Val) = .empty,
    args: []const Val = &.{},
    node: ?*Node,
};

const Error = error{ Parse, Limit, OutOfMemory };

const max_nodes = 150_000;
const max_shown = 512;
const max_steps = 4_000_000;
const max_depth = 48;

const Interp = struct {
    arena: Allocator,
    data: []const u8,
    nodes: usize = 0,
    steps: usize = 0,
    depth: usize = 0,
    message: ?[]const u8 = null,
    root_obj: ?*Obj = null,
    /// Element of the repeat-until / current repeat being evaluated.
    underscore: Val = .none,
    index: usize = 0,
    /// Objects that have a node, whose instances are shown once parsing is done
    /// (instances may refer to fields that are only complete by then).
    shown: std.ArrayList(*Obj) = .empty,

    fn fail(self: *Interp, obj: ?*Obj, at: usize, comptime fmt: []const u8, args: anytype) Error {
        if (self.message == null) {
            const msg = std.fmt.allocPrint(self.arena, fmt, args) catch return error.OutOfMemory;
            self.message = std.fmt.allocPrint(self.arena, "{s} (at 0x{X})", .{ msg, at }) catch return error.OutOfMemory;
            const holder: ?*Node = if (obj) |o| o.node else null;
            if (holder) |h| {
                const n = try self.newNode(h, "error", .err, at, 0);
                n.text = self.message.?;
            }
        }
        return error.Parse;
    }

    fn newNode(self: *Interp, parent: *Node, name: []const u8, kind: Kind, start: usize, len: usize) Error!*Node {
        const n = try self.arena.create(Node);
        n.* = .{ .name = name, .kind = kind, .start = start, .len = len, .parent = parent };
        try parent.children.append(self.arena, n);
        self.nodes += 1;
        return n;
    }

    fn tick(self: *Interp, obj: ?*Obj, at: usize) Error!void {
        self.steps += 1;
        if (self.steps > max_steps) return self.fail(obj, at, "stopped: the format needs too much work here", .{});
    }

    // -- stream reads -----------------------------------------------------------

    fn readBytes(self: *Interp, obj: *Obj, io: *Stream, n: usize) Error![]const u8 {
        io.bits_left = 0;
        if (n > io.data.len - io.pos) return self.fail(obj, io.base + io.pos, "need {d} bytes but only {d} remain", .{ n, io.data.len - io.pos });
        const out = io.data[io.pos..][0..n];
        io.pos += n;
        return out;
    }

    fn readUint(self: *Interp, obj: *Obj, io: *Stream, size: u8, little: bool) Error!u64 {
        const b = try self.readBytes(obj, io, size);
        var v: u64 = 0;
        for (0..size) |i| {
            const byte: u64 = if (little) b[size - 1 - i] else b[i];
            v = (v << 8) | byte;
        }
        return v;
    }

    fn readBits(self: *Interp, obj: *Obj, io: *Stream, count: u8, little: bool) Error!u64 {
        var result: u64 = 0;
        var got: u8 = 0;
        while (got < count) {
            if (io.bits_left == 0) {
                if (io.pos >= io.data.len) return self.fail(obj, io.base + io.pos, "ran out of data in a bit field", .{});
                io.cur = io.data[io.pos];
                io.pos += 1;
                io.bits_left = 8;
            }
            const take: u8 = @min(count - got, io.bits_left);
            const mask: u16 = (@as(u16, 1) << @intCast(take)) - 1;
            if (little) {
                const chunk: u64 = (io.cur >> @intCast(8 - io.bits_left)) & mask;
                result |= chunk << @intCast(got);
            } else {
                const chunk: u64 = (@as(u16, io.cur) >> @intCast(io.bits_left - take)) & mask;
                result = (result << @intCast(take)) | chunk;
            }
            io.bits_left -= take;
            got += take;
        }
        return result;
    }

    // -- evaluation -------------------------------------------------------------

    fn truthy(self: *Interp, obj: *Obj, v: Val) Error!bool {
        return switch (v) {
            .boolean => |b| b,
            .int => |i| i != 0,
            else => self.fail(obj, obj.io.abs(), "a condition is not true/false", .{}),
        };
    }

    fn asInt(self: *Interp, obj: *Obj, v: Val) Error!i64 {
        return switch (v) {
            .int => |i| i,
            .boolean => |b| @intFromBool(b),
            .float => |f| @intFromFloat(f),
            else => self.fail(obj, obj.io.abs(), "expected a number", .{}),
        };
    }

    fn lookup(self: *Interp, obj: *Obj, name: []const u8) Error!Val {
        for (obj.td.params, 0..) |p, i| {
            if (std.mem.eql(u8, p, name) and i < obj.args.len) return obj.args[i];
        }
        if (obj.fields.get(name)) |v| return v;
        for (obj.td.instances) |inst| {
            if (std.mem.eql(u8, inst.id, name)) return self.instance(obj, inst);
        }
        for (obj.td.seq) |a| {
            if (std.mem.eql(u8, a.id, name)) return self.fail(obj, obj.io.abs(), "{s} is used before it is read", .{name});
        }
        return self.fail(obj, obj.io.abs(), "unknown name {s}", .{name});
    }

    fn eval(self: *Interp, obj: *Obj, e: *const Expr) Error!Val {
        try self.tick(obj, obj.io.abs());
        switch (e.*) {
            .int => |v| return .{ .int = v },
            .float => |v| return .{ .float = v },
            .str => |v| return .{ .bytes = v },
            .boolean => |v| return .{ .boolean = v },
            .name => |n| {
                if (std.mem.eql(u8, n, "_")) return self.underscore;
                if (std.mem.eql(u8, n, "_index")) return .{ .int = @intCast(self.index) };
                if (std.mem.eql(u8, n, "_root")) return .{ .obj = self.root_obj.? };
                if (std.mem.eql(u8, n, "_parent")) {
                    return if (obj.parent) |p| .{ .obj = p } else self.fail(obj, obj.io.abs(), "_parent used at the top level", .{});
                }
                if (std.mem.eql(u8, n, "_io")) return .{ .io = obj.io };
                return self.lookup(obj, n);
            },
            .scoped => |path| {
                const m = model.resolveEnumMember(obj.td, path) orelse
                    return self.fail(obj, obj.io.abs(), "unknown enum value {s}::{s}", .{ path[0], path[path.len - 1] });
                return .{ .int = m.value };
            },
            .array => |items| {
                const out = try self.arena.alloc(Val, items.len);
                for (items, out) |item, *slot| slot.* = try self.eval(obj, item);
                return .{ .arr = out };
            },
            .neg => |x| return switch (try self.eval(obj, x)) {
                .int => |i| .{ .int = -%i },
                .float => |f| .{ .float = -f },
                else => self.fail(obj, obj.io.abs(), "cannot negate that", .{}),
            },
            .bit_not => |x| return .{ .int = ~(try self.asInt(obj, try self.eval(obj, x))) },
            .log_not => |x| return .{ .boolean = !(try self.truthy(obj, try self.eval(obj, x))) },
            .ternary => |t| {
                const c = try self.truthy(obj, try self.eval(obj, t.cond));
                return self.eval(obj, if (c) t.a else t.b);
            },
            .binary => |b| return self.binary(obj, b.op, b.l, b.r),
            .member => |m| return self.member(obj, try self.eval(obj, m.target), m.name),
            .index => |ix| {
                const t = try self.eval(obj, ix.target);
                const i = try self.asInt(obj, try self.eval(obj, ix.idx));
                switch (t) {
                    .arr => |a| {
                        if (i < 0 or i >= a.len) return self.fail(obj, obj.io.abs(), "index {d} is outside the array", .{i});
                        return a[@intCast(i)];
                    },
                    .bytes => |b| {
                        if (i < 0 or i >= b.len) return self.fail(obj, obj.io.abs(), "index {d} is outside the bytes", .{i});
                        return .{ .int = b[@intCast(i)] };
                    },
                    else => return self.fail(obj, obj.io.abs(), "cannot index that", .{}),
                }
            },
            .call => |c| return self.call(obj, try self.eval(obj, c.target), c.name, c.args),
        }
    }

    fn valEql(self: *Interp, obj: *Obj, a: Val, b: Val) Error!bool {
        return switch (a) {
            .int => |x| switch (b) {
                .int => |y| x == y,
                .float => |y| @as(f64, @floatFromInt(x)) == y,
                .boolean => |y| x == @intFromBool(y),
                else => false,
            },
            .float => |x| switch (b) {
                .float => |y| x == y,
                .int => |y| x == @as(f64, @floatFromInt(y)),
                else => false,
            },
            .boolean => |x| switch (b) {
                .boolean => |y| x == y,
                .int => |y| @intFromBool(x) == y,
                else => false,
            },
            .bytes => |x| switch (b) {
                .bytes => |y| std.mem.eql(u8, x, y),
                else => false,
            },
            else => self.fail(obj, obj.io.abs(), "cannot compare those", .{}),
        };
    }

    fn binary(self: *Interp, obj: *Obj, op: expr.Op, le: *const Expr, re: *const Expr) Error!Val {
        if (op == .log_and or op == .log_or) {
            const l = try self.truthy(obj, try self.eval(obj, le));
            if (op == .log_and and !l) return .{ .boolean = false };
            if (op == .log_or and l) return .{ .boolean = true };
            return .{ .boolean = try self.truthy(obj, try self.eval(obj, re)) };
        }
        const l = try self.eval(obj, le);
        const r = try self.eval(obj, re);
        switch (op) {
            .eq => return .{ .boolean = try self.valEql(obj, l, r) },
            .ne => return .{ .boolean = !(try self.valEql(obj, l, r)) },
            else => {},
        }
        if (l == .bytes and r == .bytes) {
            switch (op) {
                .add => return .{ .bytes = try std.mem.concat(self.arena, u8, &.{ l.bytes, r.bytes }) },
                .lt => return .{ .boolean = std.mem.order(u8, l.bytes, r.bytes) == .lt },
                .le => return .{ .boolean = std.mem.order(u8, l.bytes, r.bytes) != .gt },
                .gt => return .{ .boolean = std.mem.order(u8, l.bytes, r.bytes) == .gt },
                .ge => return .{ .boolean = std.mem.order(u8, l.bytes, r.bytes) != .lt },
                else => {},
            }
        }
        if (l == .float or r == .float) {
            const a: f64 = if (l == .float) l.float else @floatFromInt(try self.asInt(obj, l));
            const b: f64 = if (r == .float) r.float else @floatFromInt(try self.asInt(obj, r));
            return switch (op) {
                .add => .{ .float = a + b },
                .sub => .{ .float = a - b },
                .mul => .{ .float = a * b },
                .div => .{ .float = a / b },
                .lt => .{ .boolean = a < b },
                .le => .{ .boolean = a <= b },
                .gt => .{ .boolean = a > b },
                .ge => .{ .boolean = a >= b },
                else => self.fail(obj, obj.io.abs(), "that operator needs integers", .{}),
            };
        }
        const a = try self.asInt(obj, l);
        const b = try self.asInt(obj, r);
        return switch (op) {
            .add => .{ .int = a +% b },
            .sub => .{ .int = a -% b },
            .mul => .{ .int = a *% b },
            .div => if (b == 0) self.fail(obj, obj.io.abs(), "division by zero", .{}) else .{ .int = @divTrunc(a, b) },
            .mod => if (b == 0) self.fail(obj, obj.io.abs(), "division by zero", .{}) else .{ .int = @mod(a, b) },
            .shl => .{ .int = if (b < 0 or b > 63) 0 else a << @intCast(b) },
            .shr => .{ .int = if (b < 0 or b > 63) 0 else @bitCast(@as(u64, @bitCast(a)) >> @intCast(b)) },
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

    fn member(self: *Interp, obj: *Obj, target: Val, name: []const u8) Error!Val {
        switch (target) {
            .obj => |o| {
                if (std.mem.eql(u8, name, "_io")) return .{ .io = o.io };
                if (std.mem.eql(u8, name, "_root")) return .{ .obj = self.root_obj.? };
                if (std.mem.eql(u8, name, "_parent")) return if (o.parent) |p| .{ .obj = p } else .none;
                return self.lookup(o, name);
            },
            .io => |io| {
                if (std.mem.eql(u8, name, "size")) return .{ .int = @intCast(io.data.len) };
                if (std.mem.eql(u8, name, "pos")) return .{ .int = @intCast(io.pos) };
                if (std.mem.eql(u8, name, "eof")) return .{ .boolean = io.eof() };
            },
            else => {},
        }
        return self.call(obj, target, name, &.{});
    }

    fn call(self: *Interp, obj: *Obj, target: Val, name: []const u8, args: []const *const Expr) Error!Val {
        const eq = std.mem.eql;
        switch (target) {
            .arr => |a| {
                if (eq(u8, name, "size") or eq(u8, name, "length")) return .{ .int = @intCast(a.len) };
                if (a.len > 0 and eq(u8, name, "first")) return a[0];
                if (a.len > 0 and eq(u8, name, "last")) return a[a.len - 1];
                if (a.len > 0 and (eq(u8, name, "min") or eq(u8, name, "max"))) {
                    var best = try self.asInt(obj, a[0]);
                    for (a[1..]) |v| {
                        const x = try self.asInt(obj, v);
                        if (if (eq(u8, name, "min")) x < best else x > best) best = x;
                    }
                    return .{ .int = best };
                }
            },
            .bytes => |b| {
                if (eq(u8, name, "length") or eq(u8, name, "size")) return .{ .int = @intCast(b.len) };
                if (b.len > 0 and eq(u8, name, "first")) return .{ .int = b[0] };
                if (b.len > 0 and eq(u8, name, "last")) return .{ .int = b[b.len - 1] };
                if (eq(u8, name, "to_s")) return target;
                if (eq(u8, name, "reverse")) {
                    const out = try self.arena.dupe(u8, b);
                    std.mem.reverse(u8, out);
                    return .{ .bytes = out };
                }
                if (eq(u8, name, "to_i")) {
                    const base: u8 = if (args.len > 0) @intCast(try self.asInt(obj, try self.eval(obj, args[0]))) else 10;
                    return .{ .int = std.fmt.parseInt(i64, std.mem.trim(u8, b, " \x00"), base) catch 0 };
                }
                if (eq(u8, name, "substring") and args.len == 2) {
                    const from: usize = @intCast(@max(0, try self.asInt(obj, try self.eval(obj, args[0]))));
                    const to: usize = @intCast(@max(0, try self.asInt(obj, try self.eval(obj, args[1]))));
                    if (from > to or to > b.len) return self.fail(obj, obj.io.abs(), "substring range is outside the text", .{});
                    return .{ .bytes = b[from..to] };
                }
            },
            .int => |i| {
                if (eq(u8, name, "to_i")) return target;
                if (eq(u8, name, "to_s")) return .{ .bytes = try std.fmt.allocPrint(self.arena, "{d}", .{i}) };
            },
            .float => |f| {
                if (eq(u8, name, "to_i")) return .{ .int = @intFromFloat(f) };
                if (eq(u8, name, "to_s")) return .{ .bytes = try std.fmt.allocPrint(self.arena, "{d}", .{f}) };
            },
            .boolean => |b| {
                if (eq(u8, name, "to_i")) return .{ .int = @intFromBool(b) };
                if (eq(u8, name, "to_s")) return .{ .bytes = if (b) "true" else "false" };
            },
            else => {},
        }
        return self.fail(obj, obj.io.abs(), "unsupported .{s}", .{name});
    }

    // -- instances --------------------------------------------------------------

    fn instance(self: *Interp, obj: *Obj, inst: Attr) Error!Val {
        if (obj.fields.get(inst.id)) |v| return v;
        const holder = obj.node;
        if (inst.value) |ve| {
            const v = try self.eval(obj, ve);
            try obj.fields.put(self.arena, inst.id, v);
            if (holder) |h| if (self.nodes < max_nodes) {
                const n = try self.newNode(h, inst.id, .virtual, 0, 0);
                n.type_name = "value";
                n.text = try self.display(obj, inst, v);
            };
            return v;
        }
        const saved_io = obj.io;
        defer obj.io = saved_io;
        if (inst.io) |ie| {
            switch (try self.eval(obj, ie)) {
                .io => |other| obj.io = other,
                else => return self.fail(obj, obj.io.abs(), "{s}: io is not a stream", .{inst.id}),
            }
        }
        const saved = obj.io.pos;
        defer obj.io.pos = saved;
        if (inst.pos) |pe| {
            const p = try self.asInt(obj, try self.eval(obj, pe));
            if (p < 0 or p > obj.io.data.len) return self.fail(obj, obj.io.abs(), "{s} points outside the data ({d})", .{ inst.id, p });
            obj.io.pos = @intCast(p);
            obj.io.bits_left = 0;
        }
        const v = try self.readAttr(obj, inst, holder);
        try obj.fields.put(self.arena, inst.id, v);
        return v;
    }

    // -- reading ----------------------------------------------------------------

    fn readAttr(self: *Interp, obj: *Obj, a: Attr, parent: ?*Node) Error!Val {
        if (a.cond) |c| {
            if (!try self.truthy(obj, try self.eval(obj, c))) return .none;
        }
        if (a.repeat == .none) return self.readOne(obj, a, a.id, parent);

        const emit_parent: ?*Node = parent;
        var holder: ?*Node = null;
        if (emit_parent) |p| if (self.nodes < max_nodes) {
            holder = try self.newNode(p, a.id, .array, obj.io.abs(), 0);
        };
        defer if (holder) |h| {
            if (h.children.items.len > 0) {
                const first = h.children.items[0];
                const last = h.children.items[h.children.items.len - 1];
                h.start = first.start;
                h.len = (last.start + last.len) -| h.start;
            }
        };
        var items: std.ArrayList(Val) = .empty;
        const saved_index = self.index;
        const saved_under = self.underscore;
        defer {
            self.index = saved_index;
            self.underscore = saved_under;
        }
        var count: usize = std.math.maxInt(usize);
        if (a.repeat == .count) {
            const n = try self.asInt(obj, try self.eval(obj, a.repeat_expr orelse return self.fail(obj, obj.io.abs(), "repeat-expr is missing", .{})));
            if (n < 0) return self.fail(obj, obj.io.abs(), "negative repeat count", .{});
            count = @intCast(n);
        }
        var i: usize = 0;
        while (i < count) : (i += 1) {
            if (a.repeat == .eos and obj.io.eof()) break;
            self.index = i;
            const shown = i < max_shown;
            var name_buf: [24]u8 = undefined;
            const name = if (shown and holder != null) try self.arena.dupe(u8, std.fmt.bufPrint(&name_buf, "[{d}]", .{i}) catch "[]") else "";
            const before = obj.io.pos;
            const v = try self.readOne(obj, a, name, if (shown) holder else null);
            try items.append(self.arena, v);
            if (!shown) if (holder) |h| {
                h.omitted += 1;
            };
            if (a.repeat == .until) {
                self.underscore = v;
                if (try self.truthy(obj, try self.eval(obj, a.repeat_expr.?))) break;
            }
            if (a.repeat == .eos and obj.io.pos == before and obj.io.bits_left == 0) {
                return self.fail(obj, obj.io.abs(), "repeat made no progress", .{});
            }
        }
        const arr = Val{ .arr = items.items };
        if (holder) |h| {
            h.text = try std.fmt.allocPrint(self.arena, "{d} items", .{items.items.len});
            h.type_name = typeName(a.ty);
        }
        return arr;
    }

    fn typeName(t: *const TypeRef) []const u8 {
        return switch (t.*) {
            .builtin => |b| switch (b) {
                .uint => |u| switch (u.size) {
                    1 => "u1",
                    2 => "u2",
                    4 => "u4",
                    else => "u8",
                },
                .sint => |u| switch (u.size) {
                    1 => "s1",
                    2 => "s2",
                    4 => "s4",
                    else => "s8",
                },
                .float => |f| if (f.size == 4) "f4" else "f8",
                .bits => "bits",
                .str => "str",
                .bytes => "bytes",
            },
            .user => |u| u.path[u.path.len - 1],
            .switch_on => "switch",
        };
    }

    fn resolveType(self: *Interp, obj: *Obj, a: Attr) Error!*const TypeRef {
        var t = a.ty;
        if (t.* == .switch_on) {
            const sw = t.switch_on;
            const on = try self.eval(obj, sw.on);
            var chosen: ?*const TypeRef = null;
            for (sw.cases) |c| {
                if (c.match == null) {
                    if (chosen == null) chosen = c.ty;
                    continue;
                }
                const mv = try self.eval(obj, c.match.?);
                if (try self.valEql(obj, on, mv)) {
                    chosen = c.ty;
                    break;
                }
            }
            t = chosen orelse &raw_bytes;
        }
        return t;
    }

    const raw_bytes: TypeRef = .{ .builtin = .bytes };

    fn readOne(self: *Interp, obj: *Obj, a: Attr, name: []const u8, parent: ?*Node) Error!Val {
        try self.tick(obj, obj.io.abs());
        const io = obj.io;
        const start = io.abs();
        const t = try self.resolveType(obj, a);

        var node: ?*Node = null;
        if (parent) |p| if (self.nodes < max_nodes) {
            node = try self.newNode(p, name, .bytes, start, 0);
            node.?.type_name = typeName(t);
        };

        var val: Val = .none;
        var kind: Kind = .bytes;
        if (a.contents) |expected| {
            const got = try self.readBytes(obj, io, expected.len);
            if (!std.mem.eql(u8, got, expected)) {
                return self.fail(obj, start, "{s} should be {s} but is {s}", .{ a.id, try hexText(self.arena, expected), try hexText(self.arena, got) });
            }
            val = .{ .bytes = got };
        } else switch (t.*) {
            .builtin => |b| switch (b) {
                .uint => |u| {
                    kind = .int;
                    const little = switch (u.endian) {
                        .default => obj.little,
                        .le => true,
                        .be => false,
                    };
                    const v = try self.readUint(obj, io, u.size, little);
                    val = .{ .int = @bitCast(v) };
                },
                .sint => |u| {
                    kind = .int;
                    const little = switch (u.endian) {
                        .default => obj.little,
                        .le => true,
                        .be => false,
                    };
                    const raw = try self.readUint(obj, io, u.size, little);
                    const shift: u6 = @intCast(64 - 8 * @as(u8, u.size));
                    val = .{ .int = (@as(i64, @bitCast(raw << shift))) >> shift };
                },
                .float => |f| {
                    kind = .float;
                    const little = switch (f.endian) {
                        .default => obj.little,
                        .le => true,
                        .be => false,
                    };
                    const raw = try self.readUint(obj, io, f.size, little);
                    val = .{ .float = if (f.size == 4) @as(f32, @bitCast(@as(u32, @truncate(raw)))) else @bitCast(raw) };
                },
                .bits => |bt| {
                    kind = .int;
                    val = .{ .int = @bitCast(try self.readBits(obj, io, bt.count, bt.little)) };
                },
                .str, .bytes => {
                    kind = if (b == .str) .str else .bytes;
                    val = .{ .bytes = try self.readRaw(obj, a, io) };
                },
            },
            .user => |u| {
                kind = .struct_;
                val = try self.readUser(obj, a, u.path, u.args, node);
            },
            .switch_on => unreachable,
        }

        if (a.process and kind == .struct_) kind = .bytes;
        if (node) |n| {
            const end = io.abs() + @as(usize, if (io.bits_left > 0) 1 else 0);
            n.len = end -| start;
            n.kind = kind;
            if (kind != .struct_) n.text = try self.display(obj, a, val);
        }
        return val;
    }

    /// `str` / `bytes`: sized, terminated, or running to the end.
    fn readRaw(self: *Interp, obj: *Obj, a: Attr, io: *Stream) Error![]const u8 {
        io.bits_left = 0;
        if (a.size) |se| {
            const n = try self.asInt(obj, try self.eval(obj, se));
            if (n < 0) return self.fail(obj, io.abs(), "negative size", .{});
            const raw = try self.readBytes(obj, io, @intCast(n));
            if (a.terminator) |term| {
                if (std.mem.indexOfScalar(u8, raw, term)) |i| return raw[0..if (a.include) i + 1 else i];
            }
            return raw;
        }
        if (a.size_eos) return self.readBytes(obj, io, io.data.len - io.pos);
        if (a.terminator) |term| {
            const rest = io.data[io.pos..];
            if (std.mem.indexOfScalar(u8, rest, term)) |i| {
                const upto = if (a.include) i + 1 else i;
                const out = rest[0..upto];
                io.pos += if (a.consume) i + 1 else i;
                return out;
            }
            if (a.eos_error) return self.fail(obj, io.abs(), "no terminator byte {d} before the end of the data", .{term});
            io.pos = io.data.len;
            return rest;
        }
        return self.fail(obj, io.abs(), "{s} has no size", .{a.id});
    }

    fn readUser(self: *Interp, obj: *Obj, a: Attr, path: []const []const u8, args: []const *const Expr, node: ?*Node) Error!Val {
        const td = model.resolvePath(obj.td, path) orelse
            return self.fail(obj, obj.io.abs(), "unknown type {s}", .{path[path.len - 1]});
        if (a.process) return .{ .bytes = try self.readRaw(obj, a, obj.io) };
        var vals: std.ArrayList(Val) = .empty;
        for (args) |e| try vals.append(self.arena, try self.eval(obj, e));

        const io = obj.io;
        if (a.size != null or a.size_eos) {
            io.bits_left = 0;
            const n: usize = if (a.size) |se| blk: {
                const v = try self.asInt(obj, try self.eval(obj, se));
                if (v < 0) return self.fail(obj, io.abs(), "negative size", .{});
                break :blk @intCast(v);
            } else io.data.len - io.pos;
            if (n > io.data.len - io.pos) return self.fail(obj, io.abs(), "{s} needs {d} bytes but only {d} remain", .{ a.id, n, io.data.len - io.pos });
            const sub = try self.arena.create(Stream);
            sub.* = .{ .data = io.data[io.pos..][0..n], .base = io.base + io.pos };
            io.pos += n;
            return self.parseObj(td, obj, sub, vals.items, node);
        }
        return self.parseObj(td, obj, io, vals.items, node);
    }

    fn resolveEndian(self: *Interp, td: *TypeDef, parent: ?*Obj, obj: *Obj) Error!bool {
        switch (td.endian) {
            .fixed => |le| return le,
            .calc => |c| {
                const on = try self.eval(obj, c.on);
                for (c.cases) |cs| {
                    if (cs.match == null) return cs.little;
                    if (try self.valEql(obj, on, try self.eval(obj, cs.match.?))) return cs.little;
                }
                return true;
            },
            .inherit => {
                if (parent) |p| return p.little;
                // Look for a declared endianness up the lexical chain.
                var s: ?*TypeDef = td.parent;
                while (s) |x| : (s = x.parent) {
                    if (x.endian == .fixed) return x.endian.fixed;
                }
                return true;
            },
        }
    }

    fn parseObj(self: *Interp, td: *TypeDef, parent: ?*Obj, io: *Stream, args: []const Val, node: ?*Node) Error!Val {
        if (self.depth >= max_depth) return self.fail(parent, io.abs(), "nested too deeply", .{});
        self.depth += 1;
        defer self.depth -= 1;
        const obj = try self.arena.create(Obj);
        obj.* = .{ .td = td, .parent = parent, .io = io, .little = true, .args = args, .node = node };
        obj.little = try self.resolveEndian(td, parent, obj);
        if (self.root_obj == null) self.root_obj = obj;
        if (node) |n| n.type_name = td.name;

        for (td.seq) |a| {
            const v = try self.readAttr(obj, a, node);
            try obj.fields.put(self.arena, a.id, v);
        }
        if (node != null) try self.shown.append(self.arena, obj);
        return .{ .obj = obj };
    }

    // -- display ----------------------------------------------------------------

    fn display(self: *Interp, obj: *Obj, a: Attr, v: Val) Error![]const u8 {
        switch (v) {
            .int => |i| {
                if (a.enum_name) |en| {
                    if (model.findEnum(obj.td, en)) |e| {
                        if (e.names.get(i)) |nm| return std.fmt.allocPrint(self.arena, "{s} ({d})", .{ nm, i });
                    }
                }
                const unsigned_big = a.ty.* == .builtin and a.ty.builtin == .uint and i < 0;
                if (unsigned_big) return std.fmt.allocPrint(self.arena, "{d}", .{@as(u64, @bitCast(i))});
                if (i >= 10 or i < -10) return std.fmt.allocPrint(self.arena, "{d} (0x{X})", .{ i, @as(u64, @bitCast(i)) & signedMask(a) });
                return std.fmt.allocPrint(self.arena, "{d}", .{i});
            },
            .float => |f| return std.fmt.allocPrint(self.arena, "{d}", .{f}),
            .boolean => |b| return if (b) "true" else "false",
            .bytes => |b| {
                if (a.ty.* == .builtin and a.ty.builtin == .str or isText(b)) {
                    const shown = b[0..@min(b.len, 80)];
                    var out: std.ArrayList(u8) = .empty;
                    try out.append(self.arena, '"');
                    for (shown) |c| {
                        if (c >= 0x20 and c < 0x7f and c != '"') {
                            try out.append(self.arena, c);
                        } else try out.print(self.arena, "\\x{X:0>2}", .{c});
                    }
                    try out.append(self.arena, '"');
                    if (b.len > shown.len) try out.print(self.arena, "… ({d} bytes)", .{b.len});
                    return out.items;
                }
                return hexSummary(self.arena, b);
            },
            .arr => |arr| return std.fmt.allocPrint(self.arena, "{d} items", .{arr.len}),
            .obj, .io => return "",
            .none => return "",
        }
    }
};

fn signedMask(a: Attr) u64 {
    if (a.ty.* == .builtin) switch (a.ty.builtin) {
        .sint => |s| return if (s.size == 8) ~@as(u64, 0) else (@as(u64, 1) << @intCast(8 * @as(u8, s.size))) - 1,
        else => {},
    };
    return ~@as(u64, 0);
}

fn isText(b: []const u8) bool {
    if (b.len == 0) return false;
    for (b[0..@min(b.len, 80)]) |c| if (c < 0x20 or c >= 0x7f) return false;
    return true;
}

fn hexText(arena: Allocator, b: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (b[0..@min(b.len, 12)], 0..) |c, i| {
        if (i > 0) try out.append(arena, ' ');
        try out.print(arena, "{X:0>2}", .{c});
    }
    if (b.len > 12) try out.appendSlice(arena, " …");
    return out.items;
}

fn hexSummary(arena: Allocator, b: []const u8) Allocator.Error![]const u8 {
    const head = try hexText(arena, b);
    return std.fmt.allocPrint(arena, "{s} ({d} bytes)", .{ head, b.len });
}

/// Runs `format` over `data`. A failed parse still returns the partial tree;
/// the error is in `message` and as a node.
pub fn run(gpa: Allocator, format: *model.Format, data: []const u8) Allocator.Error!*Result {
    const r = try gpa.create(Result);
    errdefer gpa.destroy(r);
    r.* = .{ .arena = std.heap.ArenaAllocator.init(gpa), .root = undefined };
    errdefer r.arena.deinit();
    const arena = r.arena.allocator();

    const root_node = try arena.create(Node);
    root_node.* = .{ .name = if (format.id.len > 0) format.id else "file", .type_name = format.root.name, .kind = .struct_, .start = 0, .len = data.len };
    r.root = root_node;

    var it: Interp = .{ .arena = arena, .data = data };
    const io = try arena.create(Stream);
    io.* = .{ .data = data, .base = 0 };
    _ = it.parseObj(format.root, null, io, &.{}, root_node) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Parse, error.Limit => {},
    };
    // Instances not already pulled in by an expression. Errors are recorded;
    // the rest still gets shown.
    var i: usize = 0;
    while (i < it.shown.items.len) : (i += 1) {
        const obj = it.shown.items[i];
        for (obj.td.instances) |inst| {
            if (obj.fields.contains(inst.id)) continue;
            _ = it.instance(obj, inst) catch |err| switch (err) {
                error.Parse => continue,
                error.OutOfMemory => return error.OutOfMemory,
                error.Limit => break,
            };
        }
    }
    r.message = it.message;
    if (it.message != null and root_node.children.items.len == 0) {
        const n = try arena.create(Node);
        n.* = .{ .name = "error", .kind = .err, .text = it.message.?, .parent = root_node };
        try root_node.children.append(arena, n);
    }
    return r;
}

// -- tests -------------------------------------------------------------------------

fn runText(gpa: Allocator, ksy: []const u8, data: []const u8) !struct { f: *model.Format, r: *Result } {
    const f = try model.load(gpa, ksy, null);
    errdefer f.deinit();
    return .{ .f = f, .r = try run(gpa, f, data) };
}

fn child(n: *const Node, name: []const u8) ?*Node {
    for (n.children.items) |c| if (std.mem.eql(u8, c.name, name)) return c;
    return null;
}

test "fixed fields, endianness and enums" {
    const a = std.testing.allocator;
    const t = try runText(a,
        \\meta:
        \\  id: t
        \\  endian: be
        \\seq:
        \\  - id: magic
        \\    contents: "AB"
        \\  - id: len
        \\    type: u2
        \\  - id: small
        \\    type: u2le
        \\  - id: kind
        \\    type: u1
        \\    enum: k
        \\  - id: neg
        \\    type: s1
        \\enums:
        \\  k:
        \\    7: seven
    , "AB\x00\x05\x02\x01\x07\xff");
    defer t.f.deinit();
    defer t.r.deinit();
    try std.testing.expect(t.r.message == null);
    try std.testing.expectEqualStrings("5", child(t.r.root, "len").?.text);
    try std.testing.expectEqualStrings("258 (0x102)", child(t.r.root, "small").?.text);
    try std.testing.expectEqualStrings("seven (7)", child(t.r.root, "kind").?.text);
    try std.testing.expectEqualStrings("-1", child(t.r.root, "neg").?.text);
    const len = child(t.r.root, "len").?;
    try std.testing.expectEqual(@as(usize, 2), len.start);
    try std.testing.expectEqual(@as(usize, 2), len.len);
}

test "sizes, repeat, switch, instances and substreams" {
    const a = std.testing.allocator;
    const t = try runText(a,
        \\meta:
        \\  id: t
        \\  endian: le
        \\seq:
        \\  - id: count
        \\    type: u1
        \\  - id: items
        \\    type: item
        \\    repeat: expr
        \\    repeat-expr: count
        \\  - id: tail
        \\    size-eos: true
        \\instances:
        \\  total:
        \\    value: items[0].len + items[1].len
        \\  second_body:
        \\    pos: 3
        \\    size: 1
        \\types:
        \\  item:
        \\    seq:
        \\      - id: kind
        \\        type: u1
        \\      - id: len
        \\        type: u1
        \\      - id: body
        \\        size: len
        \\        type:
        \\          switch-on: kind
        \\          cases:
        \\            1: str
        \\            _: bytes
    , "\x02\x01\x02hi\x09\x01Z!");
    defer t.f.deinit();
    defer t.r.deinit();
    try std.testing.expect(t.r.message == null);
    const items = child(t.r.root, "items").?;
    try std.testing.expectEqual(@as(usize, 2), items.children.items.len);
    try std.testing.expectEqualStrings("\"hi\"", child(items.children.items[0], "body").?.text);
    try std.testing.expectEqualStrings("3", child(t.r.root, "total").?.text);
    try std.testing.expectEqual(@as(usize, 1), child(t.r.root, "tail").?.len);
}

test "a bad magic stops with a message and keeps the partial tree" {
    const a = std.testing.allocator;
    const t = try runText(a,
        \\meta:
        \\  id: t
        \\seq:
        \\  - id: first
        \\    type: u1
        \\  - id: magic
        \\    contents: "OK"
        \\  - id: never
        \\    type: u1
    , "\x01NO");
    defer t.f.deinit();
    defer t.r.deinit();
    try std.testing.expect(t.r.message != null);
    try std.testing.expect(child(t.r.root, "first") != null);
    try std.testing.expect(child(t.r.root, "never") == null);
    try std.testing.expect(child(t.r.root, "error") != null);
}

test "bit fields, repeat-until, strz and conditions" {
    const a = std.testing.allocator;
    const t = try runText(a,
        \\meta:
        \\  id: t
        \\seq:
        \\  - id: hi
        \\    type: b4
        \\  - id: lo
        \\    type: b4
        \\  - id: name
        \\    type: strz
        \\  - id: nums
        \\    type: u1
        \\    repeat: until
        \\    repeat-until: _ == 0
        \\  - id: extra
        \\    type: u1
        \\    if: hi == 10
    , "\xA5ab\x00\x03\x00\x09");
    defer t.f.deinit();
    defer t.r.deinit();
    try std.testing.expect(t.r.message == null);
    try std.testing.expectEqualStrings("10 (0xA)", child(t.r.root, "hi").?.text);
    try std.testing.expectEqualStrings("5", child(t.r.root, "lo").?.text);
    try std.testing.expectEqualStrings("\"ab\"", child(t.r.root, "name").?.text);
    try std.testing.expectEqual(@as(usize, 2), child(t.r.root, "nums").?.children.items.len);
    try std.testing.expectEqualStrings("9", child(t.r.root, "extra").?.text);
}
