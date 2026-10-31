//! dkde-charmap: pick Unicode characters from blocks and copy them (SPEC.md 5.6).

const std = @import("std");
const gdk = @import("gdk4");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

const blocks = @import("blocks.zig");

pub const std_options: std.Options = .{ .logFn = common.log.logFn, .log_level = .debug };

const Charmap = struct {
    allocator: std.mem.Allocator,
    window: *gtk.ApplicationWindow,
    grid: *gtk.FlowBox,
    picked: *gtk.Entry,
    info: *gtk.Label,
    current: usize = 0,

    pub fn create(allocator: std.mem.Allocator, app: *gtk.Application) !*Charmap {
        const self = try allocator.create(Charmap);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .window = gtk.ApplicationWindow.new(app),
            .grid = gtk.FlowBox.new(),
            .picked = gtk.Entry.new(),
            .info = gtk.Label.new(""),
        };
        const window = self.window.as(gtk.Window);
        window.setTitle(common.tr("Character Map"));
        window.setDefaultSize(620, 520);
        self.window.as(gtk.Widget).addCssClass("dkde");
        _ = common.header.create(window, "accessories-character-map", true);

        var names: [blocks.blocks.len + 1]?[*:0]const u8 = undefined;
        for (blocks.blocks, 0..) |b, i| names[i] = b.name.ptr;
        names[blocks.blocks.len] = null;
        const chooser = gtk.DropDown.newFromStrings(@ptrCast(&names));
        chooser.as(gtk.Widget).setMarginStart(8);
        chooser.as(gtk.Widget).setMarginEnd(8);
        chooser.as(gtk.Widget).setMarginTop(8);
        _ = gobject.Object.signals.notify.connect(chooser, *Charmap, &onBlock, self, .{ .detail = "selected" });

        self.grid.setSelectionMode(.none);
        self.grid.setMaxChildrenPerLine(16);
        self.grid.setMinChildrenPerLine(8);
        self.grid.as(gtk.Widget).addCssClass("dkde-charmap-grid");
        const scroller = gtk.ScrolledWindow.new();
        scroller.setChild(self.grid.as(gtk.Widget));
        scroller.as(gtk.Widget).setVexpand(1);
        scroller.as(gtk.Widget).setMarginTop(8);

        self.picked.as(gtk.Widget).setHexpand(1);
        self.picked.setPlaceholderText(common.tr("Click characters to collect them here"));
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

        self.info.setXalign(0);
        self.info.as(gtk.Widget).setMarginStart(8);
        self.info.as(gtk.Widget).setMarginBottom(8);
        self.info.as(gtk.Widget).addCssClass("dim-label");

        const root = gtk.Box.new(.vertical, 8);
        root.append(chooser.as(gtk.Widget));
        root.append(scroller.as(gtk.Widget));
        root.append(row.as(gtk.Widget));
        root.append(self.info.as(gtk.Widget));
        window.setChild(root.as(gtk.Widget));

        self.fill(0);
        return self;
    }

    pub fn present(self: *Charmap) void {
        self.window.as(gtk.Window).present();
    }

    fn onBlock(dd: *gtk.DropDown, _: *gobject.ParamSpec, self: *Charmap) callconv(.c) void {
        const i = dd.getSelected();
        if (i < blocks.blocks.len) self.fill(i);
    }

    const Cell = struct { owner: *Charmap, cp: u21 };

    fn onCellDestroy(_: *gtk.Button, cell: *Cell) callconv(.c) void {
        cell.owner.allocator.destroy(cell);
    }

    fn fill(self: *Charmap, index: usize) void {
        self.current = index;
        while (self.grid.as(gtk.Widget).getFirstChild()) |child| self.grid.remove(child);
        const block = blocks.blocks[index];
        var i: usize = 0;
        while (i < blocks.count(block)) : (i += 1) {
            var enc: [4]u8 = undefined;
            const text = blocks.utf8At(block, i, &enc) orelse break;
            var z: [8]u8 = undefined;
            @memcpy(z[0..text.len], text);
            z[text.len] = 0;
            const button = gtk.Button.newWithLabel(@ptrCast(z[0..text.len :0]));
            button.setHasFrame(0);
            button.as(gtk.Widget).addCssClass("dkde-charmap-cell");
            const cell = self.allocator.create(Cell) catch continue;
            cell.* = .{ .owner = self, .cp = block.first + @as(u21, @intCast(i)) };
            _ = gtk.Button.signals.clicked.connect(button, *Cell, &onCell, cell, .{});
            _ = gtk.Widget.signals.destroy.connect(button, *Cell, &onCellDestroy, cell, .{});
            const motion = gtk.EventControllerMotion.new();
            _ = gtk.EventControllerMotion.signals.enter.connect(motion, *Cell, &onHover, cell, .{});
            button.as(gtk.Widget).addController(motion.as(gtk.EventController));
            self.grid.append(button.as(gtk.Widget));
        }
    }

    fn onHover(_: *gtk.EventControllerMotion, _: f64, _: f64, cell: *Cell) callconv(.c) void {
        var out: [64]u8 = undefined;
        var z: [80]u8 = undefined;
        const text = blocks.describe(cell.cp, &out);
        cell.owner.info.setText(std.fmt.bufPrintSentinel(&z, "{s}", .{text}, 0) catch "");
    }

    fn onCell(_: *gtk.Button, cell: *Cell) callconv(.c) void {
        var enc: [5]u8 = @splat(0);
        const n = std.unicode.utf8Encode(cell.cp, enc[0..4]) catch return;
        const entry = cell.owner.picked.as(gtk.Editable);
        var position: c_int = -1;
        entry.insertText(@ptrCast(enc[0..n :0]), @intCast(n), &position);
    }

    fn onCopy(_: *gtk.Button, self: *Charmap) callconv(.c) void {
        const text = self.picked.as(gtk.Editable).getText();
        self.window.as(gtk.Widget).getClipboard().setText(text);
    }

    fn onClear(_: *gtk.Button, self: *Charmap) callconv(.c) void {
        self.picked.as(gtk.Editable).setText("");
    }
};

pub fn main(init: std.process.Init.Minimal) !void {
    try common.runapp.run("org.dkde.charmap", Charmap, init);
}

test {
    _ = @import("blocks.zig");
}
