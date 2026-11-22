//! dkde-charmap: pick Unicode characters from blocks and copy them (SPEC.md 5.6).

const std = @import("std");
const cli = @import("cli");
const gdk = @import("gdk4");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

const unidata = @import("unidata.zig");

pub const std_options: std.Options = .{ .logFn = common.log.logFn, .log_level = .debug };

const page_size = 256;
const max_results = 1000;
const max_recent = 16;

const Charmap = struct {
    allocator: std.mem.Allocator,
    db: unidata.Db,
    /// Block names as C strings, kept alive for the drop-down.
    block_names: [][:0]u8,
    window: *gtk.ApplicationWindow,
    chooser: *gtk.DropDown,
    search: *gtk.SearchEntry,
    grid: *gtk.FlowBox,
    picked: *gtk.Entry,
    recent_row: *gtk.Box,
    prev: *gtk.Button,
    next: *gtk.Button,
    page_label: *gtk.Label,
    preview: *gtk.Label,
    info: *gtk.Label,
    /// What the grid shows: a block's characters, or the search results.
    cells: std.ArrayList(u21) = .empty,
    recent: std.ArrayList(u21) = .empty,
    page: usize = 0,

    pub fn create(allocator: std.mem.Allocator, app: *gtk.Application) !*Charmap {
        const self = try allocator.create(Charmap);
        errdefer allocator.destroy(self);
        var db = try unidata.Db.load(allocator);
        errdefer db.deinit(allocator);

        const names = try allocator.alloc([:0]u8, db.blocks.len);
        var made: usize = 0;
        errdefer {
            for (names[0..made]) |n| allocator.free(n);
            allocator.free(names);
        }
        const ptrs = try allocator.alloc(?[*:0]const u8, db.blocks.len + 1);
        defer allocator.free(ptrs);
        for (db.blocks, 0..) |b, i| {
            names[i] = try allocator.allocSentinel(u8, b.name.len, 0);
            @memcpy(names[i], b.name);
            made += 1;
            ptrs[i] = names[i].ptr;
        }
        ptrs[db.blocks.len] = null;

        self.* = .{
            .allocator = allocator,
            .db = db,
            .block_names = names,
            .window = gtk.ApplicationWindow.new(app),
            .chooser = gtk.DropDown.newFromStrings(@ptrCast(ptrs.ptr)),
            .search = gtk.SearchEntry.new(),
            .grid = gtk.FlowBox.new(),
            .picked = gtk.Entry.new(),
            .recent_row = gtk.Box.new(.horizontal, 2),
            .prev = gtk.Button.newWithLabel(common.tr("Previous")),
            .next = gtk.Button.newWithLabel(common.tr("Next")),
            .page_label = gtk.Label.new(""),
            .preview = gtk.Label.new(""),
            .info = gtk.Label.new(""),
        };
        _ = gtk.Widget.signals.destroy.connect(self.window, *Charmap, &onDestroy, self, .{});
        const window = self.window.as(gtk.Window);
        window.setTitle(common.tr("Character Map"));
        window.setDefaultSize(660, 600);
        self.window.as(gtk.Widget).addCssClass("dkde");
        _ = common.header.create(window, "accessories-character-map", true);

        self.search.as(gtk.Widget).setHexpand(1);
        self.search.setPlaceholderText(common.tr("Search by name, character or code (U+00E9)"));
        _ = gtk.SearchEntry.signals.search_changed.connect(self.search, *Charmap, &onSearch, self, .{});
        _ = gobject.Object.signals.notify.connect(self.chooser, *Charmap, &onBlock, self, .{ .detail = "selected" });
        self.chooser.as(gtk.Widget).setTooltipText(common.tr("Unicode block"));
        const top = gtk.Box.new(.horizontal, 8);
        top.as(gtk.Widget).setMarginStart(8);
        top.as(gtk.Widget).setMarginEnd(8);
        top.as(gtk.Widget).setMarginTop(8);
        top.append(self.search.as(gtk.Widget));
        top.append(self.chooser.as(gtk.Widget));

        self.grid.setSelectionMode(.none);
        self.grid.setMaxChildrenPerLine(16);
        self.grid.setMinChildrenPerLine(8);
        self.grid.as(gtk.Widget).addCssClass("dkde-charmap-grid");
        const scroller = gtk.ScrolledWindow.new();
        scroller.setChild(self.grid.as(gtk.Widget));
        scroller.as(gtk.Widget).setVexpand(1);

        _ = gtk.Button.signals.clicked.connect(self.prev, *Charmap, &onPrev, self, .{});
        _ = gtk.Button.signals.clicked.connect(self.next, *Charmap, &onNext, self, .{});
        const pager = gtk.Box.new(.horizontal, 8);
        pager.as(gtk.Widget).setHalign(.center);
        pager.append(self.prev.as(gtk.Widget));
        pager.append(self.page_label.as(gtk.Widget));
        pager.append(self.next.as(gtk.Widget));

        const recent_title = gtk.Label.new(common.tr("Recent"));
        recent_title.as(gtk.Widget).addCssClass("dim-label");
        const recent = gtk.Box.new(.horizontal, 8);
        recent.as(gtk.Widget).setMarginStart(8);
        recent.as(gtk.Widget).setMarginEnd(8);
        recent.append(recent_title.as(gtk.Widget));
        recent.append(self.recent_row.as(gtk.Widget));

        self.picked.as(gtk.Widget).setHexpand(1);
        self.picked.setPlaceholderText(common.tr("Click characters to collect them here"));
        _ = gtk.Entry.signals.activate.connect(self.picked, *Charmap, &onActivate, self, .{});
        const copy = gtk.Button.newWithLabel(common.tr("Copy"));
        copy.as(gtk.Widget).addCssClass("suggested-action");
        _ = gtk.Button.signals.clicked.connect(copy, *Charmap, &onCopy, self, .{});
        const clear = gtk.Button.newWithLabel(common.tr("Clear"));
        _ = gtk.Button.signals.clicked.connect(clear, *Charmap, &onClear, self, .{});
        const row = gtk.Box.new(.horizontal, 8);
        row.as(gtk.Widget).setMarginStart(8);
        row.as(gtk.Widget).setMarginEnd(8);
        row.append(self.picked.as(gtk.Widget));
        row.append(clear.as(gtk.Widget));
        row.append(copy.as(gtk.Widget));

        self.preview.as(gtk.Widget).addCssClass("dkde-charmap-preview");
        self.preview.as(gtk.Widget).setSizeRequest(72, -1);
        self.info.setXalign(0);
        self.info.setWrap(1);
        self.info.as(gtk.Widget).setHexpand(1);
        self.info.as(gtk.Widget).addCssClass("dim-label");
        const details = gtk.Box.new(.horizontal, 8);
        details.as(gtk.Widget).setMarginStart(8);
        details.as(gtk.Widget).setMarginEnd(8);
        details.as(gtk.Widget).setMarginBottom(8);
        details.append(self.preview.as(gtk.Widget));
        details.append(self.info.as(gtk.Widget));

        const root = gtk.Box.new(.vertical, 8);
        root.append(top.as(gtk.Widget));
        root.append(scroller.as(gtk.Widget));
        root.append(pager.as(gtk.Widget));
        root.append(recent.as(gtk.Widget));
        root.append(row.as(gtk.Widget));
        root.append(details.as(gtk.Widget));
        window.setChild(root.as(gtk.Widget));

        for (self.db.blocks, 0..) |b, i| {
            if (std.mem.eql(u8, b.name, "Basic Latin")) self.chooser.setSelected(@intCast(i));
        }
        self.showBlock(self.chooser.getSelected());
        return self;
    }

    fn onDestroy(_: *gtk.ApplicationWindow, self: *Charmap) callconv(.c) void {
        const a = self.allocator;
        for (self.block_names) |n| a.free(n);
        a.free(self.block_names);
        self.cells.deinit(a);
        self.recent.deinit(a);
        self.db.deinit(a);
        a.destroy(self);
    }

    pub fn present(self: *Charmap) void {
        self.window.as(gtk.Window).present();
    }

    fn searching(self: *Charmap) bool {
        return std.mem.trim(u8, std.mem.span(self.search.as(gtk.Editable).getText()), " \t").len > 0;
    }

    fn onBlock(dd: *gtk.DropDown, _: *gobject.ParamSpec, self: *Charmap) callconv(.c) void {
        // Choosing a block leaves search mode.
        if (self.searching()) self.search.as(gtk.Editable).setText("");
        self.showBlock(dd.getSelected());
    }

    fn onSearch(entry: *gtk.SearchEntry, self: *Charmap) callconv(.c) void {
        const query = std.mem.span(entry.as(gtk.Editable).getText());
        if (std.mem.trim(u8, query, " \t").len == 0) {
            self.showBlock(self.chooser.getSelected());
            return;
        }
        self.cells.clearRetainingCapacity();
        self.db.search(self.allocator, query, max_results, &self.cells) catch {};
        self.page = 0;
        self.render();
    }

    fn showBlock(self: *Charmap, index: usize) void {
        self.cells.clearRetainingCapacity();
        if (index < self.db.blocks.len) {
            self.db.fillBlock(self.allocator, self.db.blocks[index], &self.cells) catch {};
        }
        self.page = 0;
        self.render();
    }

    fn pageCount(self: *Charmap) usize {
        return @max(1, (self.cells.items.len + page_size - 1) / page_size);
    }

    fn onPrev(_: *gtk.Button, self: *Charmap) callconv(.c) void {
        if (self.page > 0) self.page -= 1;
        self.render();
    }

    fn onNext(_: *gtk.Button, self: *Charmap) callconv(.c) void {
        if (self.page + 1 < self.pageCount()) self.page += 1;
        self.render();
    }

    const Cell = struct { owner: *Charmap, cp: u21 };

    fn onCellDestroy(_: *gtk.Button, cell: *Cell) callconv(.c) void {
        cell.owner.allocator.destroy(cell);
    }

    /// The text to draw for `cp`: combining marks get a dotted circle to sit on.
    fn glyph(self: *Charmap, cp: u21, buf: *[12]u8) [:0]const u8 {
        var n: usize = 0;
        if (self.db.isMark(cp)) n += std.unicode.utf8Encode(0x25CC, buf[0..4]) catch 0;
        n += std.unicode.utf8Encode(cp, buf[n..][0..4]) catch 0;
        buf[n] = 0;
        return buf[0..n :0];
    }

    fn makeCell(self: *Charmap, cp: u21) ?*gtk.Button {
        var z: [12]u8 = undefined;
        const button = gtk.Button.newWithLabel(self.glyph(cp, &z).ptr);
        button.setHasFrame(0);
        button.as(gtk.Widget).addCssClass("dkde-charmap-cell");
        const cell = self.allocator.create(Cell) catch return null;
        cell.* = .{ .owner = self, .cp = cp };
        _ = gtk.Button.signals.clicked.connect(button, *Cell, &onCell, cell, .{});
        _ = gtk.Widget.signals.destroy.connect(button, *Cell, &onCellDestroy, cell, .{});
        const motion = gtk.EventControllerMotion.new();
        _ = gtk.EventControllerMotion.signals.enter.connect(motion, *Cell, &onHover, cell, .{});
        button.as(gtk.Widget).addController(motion.as(gtk.EventController));
        var tip: [160:0]u8 = undefined;
        var nb: [96]u8 = undefined;
        const nm = self.db.name(cp, &nb) orelse "";
        button.as(gtk.Widget).setTooltipText(std.fmt.bufPrintSentinel(&tip, "{s}", .{nm}, 0) catch "");
        return button;
    }

    fn render(self: *Charmap) void {
        while (self.grid.as(gtk.Widget).getFirstChild()) |child| self.grid.remove(child);
        const pages = self.pageCount();
        if (self.page >= pages) self.page = pages - 1;
        const start = self.page * page_size;
        const end = @min(self.cells.items.len, start + page_size);
        for (self.cells.items[start..end]) |cp| {
            const button = self.makeCell(cp) orelse continue;
            self.grid.append(button.as(gtk.Widget));
        }
        self.prev.as(gtk.Widget).setSensitive(@intFromBool(self.page > 0));
        self.next.as(gtk.Widget).setSensitive(@intFromBool(self.page + 1 < pages));
        var z: [96:0]u8 = undefined;
        const total = self.cells.items.len;
        const text = if (self.searching() and total == 0)
            common.tr("No matches")
        else if (pages > 1)
            std.fmt.bufPrintSentinel(&z, "{d}\u{2013}{d} of {d}  (page {d} of {d})", .{ start + 1, end, total, self.page + 1, pages }, 0) catch ""
        else
            std.fmt.bufPrintSentinel(&z, "{d} characters", .{total}, 0) catch "";
        self.page_label.setText(text);
    }

    fn show(self: *Charmap, cp: u21) void {
        var g: [12]u8 = undefined;
        self.preview.setText(self.glyph(cp, &g).ptr);
        var code: [16]u8 = undefined;
        var hex: [16]u8 = undefined;
        var nb: [96]u8 = undefined;
        var z: [200:0]u8 = undefined;
        const text = std.fmt.bufPrintSentinel(&z, "{s}  {s}\nUTF-8: {s}", .{
            unidata.codeLabel(cp, &code),
            self.db.name(cp, &nb) orelse "",
            unidata.utf8Hex(cp, &hex),
        }, 0) catch "";
        self.info.setText(text);
    }

    fn onHover(_: *gtk.EventControllerMotion, _: f64, _: f64, cell: *Cell) callconv(.c) void {
        cell.owner.show(cell.cp);
    }

    fn onCell(_: *gtk.Button, cell: *Cell) callconv(.c) void {
        const self = cell.owner;
        const cp = cell.cp;
        var enc: [5]u8 = @splat(0);
        const n = std.unicode.utf8Encode(cp, enc[0..4]) catch return;
        const entry = self.picked.as(gtk.Editable);
        var position: c_int = -1;
        entry.insertText(@ptrCast(enc[0..n :0]), @intCast(n), &position);
        self.show(cp);
        self.remember(cp);
    }

    /// Put `cp` first in the recent row (without duplicates, newest first).
    /// The buttons are rebuilt from the list, so `cell` must not be used after this.
    fn remember(self: *Charmap, cp: u21) void {
        if (std.mem.indexOfScalar(u21, self.recent.items, cp)) |i| _ = self.recent.orderedRemove(i);
        self.recent.insert(self.allocator, 0, cp) catch return;
        if (self.recent.items.len > max_recent) self.recent.shrinkRetainingCapacity(max_recent);
        while (self.recent_row.as(gtk.Widget).getFirstChild()) |child| self.recent_row.remove(child);
        for (self.recent.items) |r| {
            const button = self.makeCell(r) orelse continue;
            self.recent_row.append(button.as(gtk.Widget));
        }
    }

    fn onCopy(_: *gtk.Button, self: *Charmap) callconv(.c) void {
        self.copyText();
    }

    fn onActivate(_: *gtk.Entry, self: *Charmap) callconv(.c) void {
        self.copyText();
    }

    fn copyText(self: *Charmap) void {
        const text = self.picked.as(gtk.Editable).getText();
        self.window.as(gtk.Widget).getClipboard().setText(text);
    }

    fn onClear(_: *gtk.Button, self: *Charmap) callconv(.c) void {
        self.picked.as(gtk.Editable).setText("");
    }
};

pub fn main(init: std.process.Init.Minimal) !void {
    cli.handle(init.args, .{ .name = "dkde-charmap", .summary = "Character map" });
    try common.runapp.run("org.dkde.charmap", Charmap, init);
}

test {
    _ = @import("unidata.zig");
}
