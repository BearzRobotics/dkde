//! The structure side of dkde-hex: a library of Kaitai formats found on disk,
//! detection of which one fits a file, and the tree panel that shows a parsed
//! file (SPEC.md 5.6).

const std = @import("std");
const gdk = @import("gdk4");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

const model = @import("ksy/model.zig");
const hexpat = @import("hexpat/eval.zig");
const hexpat_parse = @import("hexpat/parse.zig");
const interp = @import("ksy/interp.zig");
const view_mod = @import("view.zig");

pub const Node = interp.Node;

/// What the picker and detection need to know about one `.ksy`, without
/// keeping the whole format around.
pub const Kind = enum { ksy, hexpat };

pub const Entry = struct {
    kind: Kind = .ksy,
    path: [:0]u8,
    id: []u8,
    title: []u8,
    /// Lower case, without the dot.
    extensions: [][]u8,
    magic: []u8,
    /// Where the magic bytes sit in the file (ImHex patterns may say not 0).
    magic_offset: usize = 0,
    /// Content types the pattern claims (`#pragma MIME`).
    mimes: [][]u8 = &.{},
};

const max_entries = 4000;

pub const Library = struct {
    allocator: std.mem.Allocator,
    dir: []u8,
    /// The ImHex-Patterns folder (with `patterns/` and `includes/` inside).
    pattern_dir: []u8,
    entries: std.ArrayList(Entry) = .empty,
    /// Where imports of a hand-picked file are also looked for.
    extra_dir: ?[]u8 = null,

    pub fn scan(allocator: std.mem.Allocator, dir: []const u8, pattern_dir: []const u8) !*Library {
        const self = try allocator.create(Library);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .dir = try allocator.dupe(u8, dir), .pattern_dir = try allocator.dupe(u8, pattern_dir) };
        errdefer self.deinit();
        try self.walk(self.dir, 0);
        if (self.pattern_dir.len > 0) {
            // Clone layout first (patterns/ inside), else the folder itself.
            const inner = try std.fs.path.join(allocator, &.{ self.pattern_dir, "patterns" });
            defer allocator.free(inner);
            const z = try allocator.dupeSentinel(u8, inner, 0);
            defer allocator.free(z);
            try self.walk(if (glib.fileTest(z, .{ .is_dir = true }) != 0) inner else self.pattern_dir, 0);
        }
        std.mem.sort(Entry, self.entries.items, {}, entryLess);
        return self;
    }

    fn entryLess(_: void, a: Entry, b: Entry) bool {
        return std.ascii.lessThanIgnoreCase(if (a.title.len > 0) a.title else a.id, if (b.title.len > 0) b.title else b.id);
    }

    pub fn deinit(self: *Library) void {
        const a = self.allocator;
        for (self.entries.items) |e| {
            a.free(e.path);
            a.free(e.id);
            a.free(e.title);
            for (e.extensions) |x| a.free(x);
            a.free(e.extensions);
            a.free(e.magic);
            for (e.mimes) |x| a.free(x);
            a.free(e.mimes);
        }
        self.entries.deinit(a);
        if (self.extra_dir) |d| a.free(d);
        a.free(self.dir);
        a.free(self.pattern_dir);
        a.destroy(self);
    }

    fn walk(self: *Library, dir_path: []const u8, depth: u8) !void {
        if (depth > 6) return;
        const z = try self.allocator.dupeSentinel(u8, dir_path, 0);
        defer self.allocator.free(z);
        var err: ?*glib.Error = null;
        const dir = glib.Dir.open(z, 0, &err) orelse {
            if (err) |e| e.free();
            return;
        };
        defer dir.close();
        while (@as(?[*:0]const u8, @ptrCast(dir.readName()))) |name_z| {
            if (self.entries.items.len >= max_entries) return;
            const name = std.mem.span(name_z);
            if (name.len == 0 or name[0] == '.') continue;
            const full = try std.fs.path.joinZ(self.allocator, &.{ dir_path, name });
            defer self.allocator.free(full);
            if (glib.fileTest(full, .{ .is_dir = true }) != 0) {
                try self.walk(full, depth + 1);
            } else if (std.mem.endsWith(u8, name, ".ksy")) {
                self.addFile(full) catch |e| switch (e) {
                    error.OutOfMemory => return e,
                    else => {},
                };
            } else if (std.mem.endsWith(u8, name, ".hexpat")) {
                self.addPattern(full, name) catch |e| switch (e) {
                    error.OutOfMemory => return e,
                    else => {},
                };
            }
        }
    }

    fn addFile(self: *Library, path: [:0]const u8) !void {
        const a = self.allocator;
        const src = try readFile(a, path);
        defer a.free(src);
        const f = try model.load(a, src, null);
        defer f.deinit();
        if (f.id.len == 0) return;
        const exts = try a.alloc([]u8, f.extensions.len);
        var made: usize = 0;
        errdefer {
            for (exts[0..made]) |x| a.free(x);
            a.free(exts);
        }
        for (f.extensions) |x| {
            exts[made] = try std.ascii.allocLowerString(a, x);
            made += 1;
        }
        const entry: Entry = .{
            .path = try a.dupeSentinel(u8, path, 0),
            .id = try a.dupe(u8, f.id),
            .title = try a.dupe(u8, if (f.title.len > 0) f.title else f.id),
            .extensions = exts,
            .magic = try a.dupe(u8, f.magic),
        };
        errdefer {
            a.free(entry.path);
            a.free(entry.id);
            a.free(entry.title);
            a.free(entry.magic);
        }
        try self.entries.append(a, entry);
    }

    fn addPattern(self: *Library, path: [:0]const u8, name: []const u8) !void {
        const a = self.allocator;
        const src = try readFile(a, path);
        defer a.free(src);
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const info = try hexpat_parse.pragmas(arena.allocator(), src);
        const stem = name[0 .. name.len - ".hexpat".len];
        const mimes = try a.alloc([]u8, info.mimes.len);
        var made: usize = 0;
        errdefer {
            for (mimes[0..made]) |m| a.free(m);
            a.free(mimes);
        }
        for (info.mimes) |m| {
            mimes[made] = try std.ascii.allocLowerString(a, m);
            made += 1;
        }
        const exts = try a.alloc([]u8, 1);
        errdefer a.free(exts);
        exts[0] = try std.ascii.allocLowerString(a, stem);
        errdefer a.free(exts[0]);
        const entry: Entry = .{
            .kind = .hexpat,
            .path = try a.dupeSentinel(u8, path, 0),
            .id = try a.dupe(u8, stem),
            .title = try a.dupe(u8, if (info.description.len > 0) info.description else stem),
            .extensions = exts,
            .magic = try a.dupe(u8, info.magic),
            .magic_offset = info.magic_offset,
            .mimes = mimes,
        };
        errdefer {
            a.free(entry.path);
            a.free(entry.id);
            a.free(entry.title);
            a.free(entry.magic);
        }
        try self.entries.append(a, entry);
    }

    /// The best format for `data` (and the file's `path`, for its extension):
    /// the longest matching magic, else a unique extension match.
    pub fn detect(self: *const Library, data: []const u8, path: ?[]const u8) ?*const Entry {
        var best: ?*const Entry = null;
        for (self.entries.items) |*e| {
            if (e.magic.len < 2 or e.magic_offset + e.magic.len > data.len) continue;
            if (!std.mem.eql(u8, data[e.magic_offset..][0..e.magic.len], e.magic)) continue;
            // A longer magic wins; on a tie a Kaitai format beats a pattern.
            if (best == null or e.magic.len > best.?.magic.len or (e.magic.len == best.?.magic.len and e.kind == .ksy and best.?.kind == .hexpat)) best = e;
        }
        if (best != null) return best;
        // The content type GIO guesses, against what patterns say they handle.
        if (self.byMime(data, path)) |e| return e;
        const p = path orelse return null;
        const ext_raw = std.fs.path.extension(p);
        if (ext_raw.len < 2) return null;
        var buf: [32]u8 = undefined;
        if (ext_raw.len - 1 > buf.len) return null;
        const ext = std.ascii.lowerString(&buf, ext_raw[1..]);
        var ksy_hit: ?*const Entry = null;
        var ksy_count: usize = 0;
        var pat_hit: ?*const Entry = null;
        var pat_count: usize = 0;
        for (self.entries.items) |*e| {
            for (e.extensions) |x| if (std.mem.eql(u8, x, ext)) {
                if (e.kind == .ksy) {
                    ksy_hit = e;
                    ksy_count += 1;
                } else {
                    pat_hit = e;
                    pat_count += 1;
                }
            };
        }
        // Several candidates are ambiguous: let the user choose.
        if (ksy_count == 1) return ksy_hit;
        if (ksy_count == 0 and pat_count == 1) return pat_hit;
        return null;
    }

    fn byMime(self: *const Library, data: []const u8, path: ?[]const u8) ?*const Entry {
        var name_buf: [512]u8 = undefined;
        const name: ?[*:0]const u8 = if (path) |p| (std.fmt.bufPrintSentinel(&name_buf, "{s}", .{std.fs.path.basename(p)}, 0) catch null) else null;
        const head = data[0..@min(data.len, 4096)];
        var uncertain: c_int = 0;
        const ct = gio.contentTypeGuess(name, head.ptr, head.len, &uncertain);
        defer glib.free(ct);
        const mime_c = gio.contentTypeGetMimeType(ct) orelse return null;
        defer glib.free(mime_c);
        var lower: [96]u8 = undefined;
        const mime = std.ascii.lowerString(&lower, std.mem.span(mime_c)[0..@min(std.mem.span(mime_c).len, lower.len)]);
        var found: ?*const Entry = null;
        for (self.entries.items) |*e| {
            if (e.kind != .hexpat) continue;
            for (e.mimes) |m| if (std.mem.eql(u8, m, mime)) {
                if (found == null or e.magic.len > found.?.magic.len) found = e;
            };
        }
        return found;
    }

    /// Loads and parses the format at `path`, resolving its imports here.
    pub fn load(self: *Library, path: []const u8) !*model.Format {
        const a = self.allocator;
        const z = try a.dupeSentinel(u8, path, 0);
        defer a.free(z);
        const src = try readFile(a, z);
        defer a.free(src);
        if (self.extra_dir) |d| a.free(d);
        self.extra_dir = try a.dupe(u8, std.fs.path.dirname(path) orelse ".");
        return model.load(a, src, .{ .ctx = self, .read = readImport });
    }

    /// Loads the `.hexpat` at `path`; imports come from `<pattern folder>/includes`.
    pub fn loadPattern(self: *Library, path: []const u8, failure: *?hexpat.LoadFailure) !?*hexpat.Pattern {
        const a = self.allocator;
        const z = try a.dupeSentinel(u8, path, 0);
        defer a.free(z);
        const src = try readFile(a, z);
        defer a.free(src);
        if (self.extra_dir) |d| a.free(d);
        self.extra_dir = try a.dupe(u8, std.fs.path.dirname(path) orelse ".");
        return hexpat.load(a, src, .{ .ctx = self, .read = readPatternImport }, failure);
    }

    fn readPatternImport(ctx: *anyopaque, gpa: std.mem.Allocator, name: []const u8) ?[]u8 {
        const self: *Library = @ptrCast(@alignCast(ctx));
        const rel = std.mem.trimStart(u8, name, "/");
        const bases = [_]?[]const u8{ self.pattern_dir, self.extra_dir };
        for (bases) |base| {
            const b = base orelse continue;
            for ([_][]const u8{ ".pat", ".hexpat" }) |ext| {
                for ([_][]const u8{ "includes/", "../includes/", "" }) |prefix| {
                    const full = std.fmt.allocPrintSentinel(gpa, "{s}/{s}{s}{s}", .{ b, prefix, rel, ext }, 0) catch return null;
                    defer gpa.free(full);
                    if (readFile(gpa, full)) |bytes| return bytes else |_| {}
                }
            }
        }
        return null;
    }

    fn readImport(ctx: *anyopaque, gpa: std.mem.Allocator, name: []const u8) ?[]u8 {
        const self: *Library = @ptrCast(@alignCast(ctx));
        const rel = std.mem.trimStart(u8, name, "/");
        const bases = [_]?[]const u8{ self.dir, self.extra_dir };
        for (bases) |base| {
            const b = base orelse continue;
            const full = std.fmt.allocPrintSentinel(gpa, "{s}/{s}.ksy", .{ b, rel }, 0) catch return null;
            defer gpa.free(full);
            if (readFile(gpa, full)) |bytes| return bytes else |_| {}
        }
        // Fall back to any format with that file name.
        const want = std.fmt.allocPrint(gpa, "/{s}.ksy", .{std.fs.path.basename(rel)}) catch return null;
        defer gpa.free(want);
        for (self.entries.items) |e| {
            if (std.mem.endsWith(u8, e.path, want)) return readFile(gpa, e.path) catch null;
        }
        return null;
    }
};

fn readFile(allocator: std.mem.Allocator, path: [:0]const u8) ![]u8 {
    var contents: [*]u8 = undefined;
    var length: usize = 0;
    var err: ?*glib.Error = null;
    if (glib.fileGetContents(path, &contents, &length, &err) == 0) {
        if (err) |e| e.free();
        return error.CannotRead;
    }
    defer glib.free(contents);
    if (length > 8 << 20) return error.TooLarge;
    return allocator.dupe(u8, contents[0..length]);
}

// -- highlights -----------------------------------------------------------------------

/// Flattens the tree into coloured ranges for the hex view: the leaves, in
/// file order, with neighbouring fields getting different colours.
pub fn collectRanges(allocator: std.mem.Allocator, root: *const Node) ![]view_mod.Range {
    var list: std.ArrayList(view_mod.Range) = .empty;
    errdefer list.deinit(allocator);
    var counter: u8 = 0;
    try collect(allocator, root, &list, &counter);
    std.mem.sort(view_mod.Range, list.items, {}, struct {
        fn less(_: void, a: view_mod.Range, b: view_mod.Range) bool {
            return a.start < b.start;
        }
    }.less);
    return list.toOwnedSlice(allocator);
}

fn collect(allocator: std.mem.Allocator, node: *const Node, list: *std.ArrayList(view_mod.Range), counter: *u8) !void {
    for (node.children.items) |c| {
        if (c.kind == .err or c.kind == .virtual or c.len == 0) continue;
        // A bit field is one value (kind int) even though it lists its bits.
        if (c.children.items.len > 0 and c.kind != .int) {
            try collect(allocator, c, list, counter);
        } else {
            try list.append(allocator, .{ .start = c.start, .len = c.len, .color = counter.*, .rgb = c.color });
            counter.* +%= 1;
        }
    }
}

/// The innermost field covering `offset`.
pub fn nodeAt(root: *Node, offset: usize) ?*Node {
    var best: ?*Node = null;
    var cur = root;
    outer: while (true) {
        for (cur.children.items) |c| {
            if (c.kind == .err or c.kind == .virtual or c.len == 0) continue;
            if (offset >= c.start and offset < c.start + c.len) {
                best = c;
                cur = c;
                continue :outer;
            }
        }
        return best;
    }
}

/// `header.magic` or `entries[2].len`, written into `buf`.
pub fn pathOf(node: *const Node, buf: []u8) []const u8 {
    var parts: [32]*const Node = undefined;
    var n: usize = 0;
    var cur: ?*const Node = node;
    while (cur) |c| : (cur = c.parent) {
        if (c.parent == null) break; // the root is the file itself
        if (n == parts.len) break;
        parts[n] = c;
        n += 1;
    }
    var w: usize = 0;
    while (n > 0) {
        n -= 1;
        const name = parts[n].name;
        const dot = w > 0 and !(name.len > 0 and name[0] == '[');
        const need = name.len + @intFromBool(dot);
        if (w + need > buf.len) break;
        if (dot) {
            buf[w] = '.';
            w += 1;
        }
        @memcpy(buf[w..][0..name.len], name);
        w += name.len;
    }
    return buf[0..w];
}

// -- the panel ------------------------------------------------------------------------

/// What turned the bytes into the tree: a Kaitai format or an ImHex pattern.
pub const Engine = union(enum) {
    ksy: *model.Format,
    hexpat: *hexpat.Pattern,

    pub fn deinit(self: Engine) void {
        switch (self) {
            .ksy => |f| f.deinit(),
            .hexpat => |p| p.deinit(),
        }
    }

    pub fn title(self: Engine) []const u8 {
        return switch (self) {
            .ksy => |f| if (f.title.len > 0) f.title else f.id,
            .hexpat => |p| if (p.description.len > 0) p.description else "ImHex pattern",
        };
    }

    pub fn warning(self: Engine) ?[]const u8 {
        return switch (self) {
            .ksy => |f| if (f.warnings.len > 0) f.warnings[0] else null,
            .hexpat => |p| if (p.warnings.len > 0) p.warnings[0] else null,
        };
    }

    /// Runs it over `data`.
    pub fn run(self: Engine, allocator: std.mem.Allocator, data: []const u8) std.mem.Allocator.Error!*interp.Result {
        return switch (self) {
            .ksy => |f| interp.run(allocator, f, data),
            .hexpat => |p| hexpat.run(allocator, p, data),
        };
    }
};

pub const Panel = struct {
    allocator: std.mem.Allocator,
    box: *gtk.Box,
    heading: *gtk.Label,
    hint: *gtk.Label,
    list: *gtk.ListBox,
    scroller: *gtk.ScrolledWindow,
    scroll_source: c_uint = 0,
    scroll_to: ?*Node = null,
    engine: ?Engine = null,
    result: ?*interp.Result = null,
    rows: std.ArrayList(*Node) = .empty,
    expanded: std.AutoHashMapUnmanaged(*Node, void) = .empty,
    /// True while the program (not the user) moves the selection.
    syncing: bool = false,
    on_pick: *const fn (*anyopaque, *Node) void,
    on_pick_data: *anyopaque,

    pub fn create(allocator: std.mem.Allocator, on_pick: *const fn (*anyopaque, *Node) void, data: *anyopaque) !*Panel {
        const self = try allocator.create(Panel);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .box = gtk.Box.new(.vertical, 2),
            .heading = gtk.Label.new(common.tr("Structure")),
            .hint = gtk.Label.new(""),
            .list = gtk.ListBox.new(),
            .scroller = gtk.ScrolledWindow.new(),
            .on_pick = on_pick,
            .on_pick_data = data,
        };
        const w = self.box.as(gtk.Widget);
        w.addCssClass("dkde-hex-structure");
        w.setSizeRequest(340, -1);
        w.setHexpand(0);
        w.setMarginStart(8);
        w.setMarginEnd(4);
        w.setMarginTop(8);
        self.heading.setXalign(0);
        self.heading.as(gtk.Widget).addCssClass("heading");
        self.hint.setXalign(0);
        self.hint.setWrap(1);
        self.hint.setMaxWidthChars(38);
        self.hint.as(gtk.Widget).addCssClass("dim-label");
        self.box.append(self.heading.as(gtk.Widget));
        self.box.append(self.hint.as(gtk.Widget));
        self.list.setSelectionMode(.single);
        self.list.setActivateOnSingleClick(0);
        const scroller = self.scroller;
        scroller.setChild(self.list.as(gtk.Widget));
        scroller.as(gtk.Widget).setVexpand(1);
        scroller.setPolicy(.never, .automatic);
        self.box.append(scroller.as(gtk.Widget));
        _ = gtk.ListBox.signals.row_selected.connect(self.list, *Panel, &onRowSelected, self, .{});
        _ = gtk.ListBox.signals.row_activated.connect(self.list, *Panel, &onRowActivated, self, .{});
        self.setHint(common.tr("No format applied. Use Structure \u{25B8} Choose format\u{2026} or Load definition\u{2026}"));
        return self;
    }

    pub fn destroy(self: *Panel) void {
        if (self.scroll_source != 0) _ = glib.Source.remove(self.scroll_source);
        self.clear();
        self.rows.deinit(self.allocator);
        self.expanded.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn setHint(self: *Panel, text: [:0]const u8) void {
        self.hint.setText(text);
        self.hint.as(gtk.Widget).setVisible(@intFromBool(text.len > 0));
    }

    pub fn clear(self: *Panel) void {
        self.syncing = true;
        self.list.removeAll();
        self.syncing = false;
        self.rows.clearRetainingCapacity();
        self.expanded.clearRetainingCapacity();
        self.scroll_to = null;
        if (self.result) |r| r.deinit();
        if (self.engine) |e| e.deinit();
        self.result = null;
        self.engine = null;
        self.heading.setText(common.tr("Structure"));
    }

    /// Takes over `engine` and `result`.
    pub fn show(self: *Panel, engine: Engine, result: *interp.Result) void {
        self.clear();
        self.engine = engine;
        self.result = result;
        self.expanded.put(self.allocator, result.root, {}) catch {};
        var buf: [256]u8 = undefined;
        self.heading.setText(std.fmt.bufPrintSentinel(&buf, "{s}", .{engine.title()}, 0) catch "Structure");
        if (result.message) |m| {
            var hb: [512]u8 = undefined;
            self.setHint(std.fmt.bufPrintSentinel(&hb, "Stopped: {s}", .{m}, 0) catch "Parsing stopped early.");
        } else if (engine.warning()) |w| {
            var hb: [512]u8 = undefined;
            self.setHint(std.fmt.bufPrintSentinel(&hb, "Note: {s}", .{w}, 0) catch "");
        } else {
            self.setHint("");
        }
        self.rebuild();
    }

    pub fn rebuild(self: *Panel) void {
        self.syncing = true;
        defer self.syncing = false;
        self.list.removeAll();
        self.rows.clearRetainingCapacity();
        const r = self.result orelse return;
        self.addRows(r.root, 0);
    }

    fn addRows(self: *Panel, node: *Node, depth: usize) void {
        for (node.children.items) |c| {
            self.addRow(c, depth);
            if (self.expanded.contains(c)) self.addRows(c, depth + 1);
        }
        if (node.omitted > 0) {
            var buf: [64]u8 = undefined;
            const label = gtk.Label.new(std.fmt.bufPrintSentinel(&buf, "\u{2026} {d} more not listed", .{node.omitted}, 0) catch "\u{2026}");
            label.setXalign(0);
            label.as(gtk.Widget).addCssClass("dim-label");
            label.as(gtk.Widget).setMarginStart(@intCast(8 + depth * 14 + 16));
            const row = gtk.ListBoxRow.new();
            row.setSelectable(0);
            row.setChild(label.as(gtk.Widget));
            self.list.append(row.as(gtk.Widget));
            // Keep `rows` aligned with the list: this row maps to its parent.
            self.rows.append(self.allocator, node) catch {};
        }
    }

    fn addRow(self: *Panel, node: *Node, depth: usize) void {
        const line = gtk.Box.new(.horizontal, 6);
        line.as(gtk.Widget).setMarginStart(@intCast(4 + depth * 14));
        line.as(gtk.Widget).setMarginEnd(4);

        const has_children = node.children.items.len > 0;
        const arrow = gtk.Label.new(if (!has_children) "" else if (self.expanded.contains(node)) "\u{25BE}" else "\u{25B8}");
        arrow.as(gtk.Widget).setSizeRequest(12, -1);
        line.append(arrow.as(gtk.Widget));

        var nb: [160]u8 = undefined;
        const name = gtk.Label.new(std.fmt.bufPrintSentinel(&nb, "{s}", .{node.name}, 0) catch "?");
        name.setXalign(0);
        name.as(gtk.Widget).addCssClass(if (node.kind == .err) "error" else "heading");
        line.append(name.as(gtk.Widget));

        if (node.text.len > 0 or node.type_name.len > 0) {
            var vb: [200]u8 = undefined;
            const text = if (node.text.len > 0) node.text else node.type_name;
            const value = gtk.Label.new(std.fmt.bufPrintSentinel(&vb, "{s}", .{text[0..@min(text.len, 150)]}, 0) catch "");
            value.setXalign(0);
            value.setEllipsize(.end);
            value.as(gtk.Widget).setHexpand(1);
            value.setMaxWidthChars(22);
            value.setSelectable(0);
            value.as(gtk.Widget).addCssClass("dim-label");
            line.append(value.as(gtk.Widget));
        }
        const row = gtk.ListBoxRow.new();
        row.setChild(line.as(gtk.Widget));
        self.list.append(row.as(gtk.Widget));
        self.rows.append(self.allocator, node) catch {};
    }

    fn nodeOfRow(self: *Panel, row: *gtk.ListBoxRow) ?*Node {
        const i = row.getIndex();
        if (i < 0 or i >= self.rows.items.len) return null;
        return self.rows.items[@intCast(i)];
    }

    fn onRowSelected(_: *gtk.ListBox, row: ?*gtk.ListBoxRow, self: *Panel) callconv(.c) void {
        if (self.syncing) return;
        const r = row orelse return;
        const node = self.nodeOfRow(r) orelse return;
        self.on_pick(self.on_pick_data, node);
    }

    fn onRowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Panel) callconv(.c) void {
        const node = self.nodeOfRow(row) orelse return;
        if (node.children.items.len == 0) return;
        if (self.expanded.remove(node)) {} else self.expanded.put(self.allocator, node, {}) catch return;
        self.rebuild();
        self.selectNode(node);
    }

    /// Expands the path to `node`, selects its row and scrolls to it.
    pub fn reveal(self: *Panel, node: *Node) void {
        var changed = false;
        var p = node.parent;
        while (p) |x| : (p = x.parent) {
            if (x.parent == null) break;
            if (!self.expanded.contains(x)) {
                self.expanded.put(self.allocator, x, {}) catch return;
                changed = true;
            }
        }
        if (changed) self.rebuild();
        self.selectNode(node);
    }

    fn selectNode(self: *Panel, node: *Node) void {
        for (self.rows.items, 0..) |n, i| {
            if (n != node) continue;
            if (self.list.getRowAtIndex(@intCast(i))) |row| {
                self.syncing = true;
                defer self.syncing = false;
                self.list.selectRow(row);
            }
            self.scroll_to = node;
            // Row positions are only known after the next layout pass.
            if (self.scroll_source == 0) self.scroll_source = glib.timeoutAdd(1, onScrollTick, self);
            return;
        }
    }
};

fn onScrollTick(data: ?*anyopaque) callconv(.c) c_int {
    const self: *Panel = @ptrCast(@alignCast(data.?));
    self.scroll_source = 0;
    const node = self.scroll_to orelse return 0;
    self.scroll_to = null;
    for (self.rows.items, 0..) |n, i| {
        if (n != node) continue;
        const row = self.list.getRowAtIndex(@intCast(i)) orelse return 0;
        var rect: gdk.Rectangle = undefined;
        row.as(gtk.Widget).getAllocation(&rect);
        const adj = self.scroller.getVadjustment();
        const top: f64 = @floatFromInt(rect.f_y);
        const bottom: f64 = top + @as(f64, @floatFromInt(rect.f_height));
        const value = adj.getValue();
        const page = adj.getPageSize();
        if (top < value) adj.setValue(top) else if (bottom > value + page) adj.setValue(bottom - page);
        return 0;
    }
    return 0;
}

test "paths read like Kaitai expressions" {
    var root: Node = .{ .name = "file", .kind = .struct_ };
    var hdr: Node = .{ .name = "header", .kind = .struct_, .parent = &root };
    var arr: Node = .{ .name = "entries", .kind = .array, .parent = &hdr };
    var el: Node = .{ .name = "[2]", .kind = .struct_, .parent = &arr };
    var f: Node = .{ .name = "len", .kind = .int, .parent = &el };
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("header.entries[2].len", pathOf(&f, &buf));
}

test "node lookup finds the innermost field" {
    const a = std.testing.allocator;
    var root: Node = .{ .name = "file", .kind = .struct_, .len = 10 };
    var hdr: Node = .{ .name = "header", .kind = .struct_, .start = 0, .len = 6, .parent = &root };
    var x: Node = .{ .name = "x", .kind = .int, .start = 2, .len = 2, .parent = &hdr };
    defer root.children.deinit(a);
    defer hdr.children.deinit(a);
    try root.children.append(a, &hdr);
    try hdr.children.append(a, &x);
    try std.testing.expectEqual(&x, nodeAt(&root, 3).?);
    try std.testing.expectEqual(&hdr, nodeAt(&root, 5).?);
    try std.testing.expect(nodeAt(&root, 8) == null);

    const ranges = try collectRanges(a, &root);
    defer a.free(ranges);
    try std.testing.expectEqual(@as(usize, 1), ranges.len);
    try std.testing.expectEqual(@as(usize, 2), ranges[0].start);
}
