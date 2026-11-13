//! A sortable list of text columns for the Users, Services and Startup apps
//! pages. The page keeps its rows; this shows them, sorted by the clicked
//! header, and writes changed figures into the cells on screen without
//! rebuilding the list when the rows are the same ones.

const std = @import("std");
const gdk = @import("gdk4");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

pub const ColumnSpec = struct {
    title: [:0]const u8,
    right: bool = false,
    expand: bool = false,
    width: c_int = -1,
    /// Sorting by it lists the biggest first.
    big_first: bool = false,
};

pub const Source = struct {
    owner: *anyopaque,
    /// The text of data row `row` in column `col`.
    text: *const fn (owner: *anyopaque, row: usize, col: usize, buf: []u8) []const u8,
    /// Whether data row `a` comes before `b` sorted by `col`, smallest first.
    less: *const fn (owner: *anyopaque, a: usize, b: usize, col: usize) bool,
    /// An icon for the first column, if any.
    icon: ?*const fn (owner: *anyopaque, row: usize) [:0]const u8 = null,
    /// What identifies a row across refreshes.
    key: *const fn (owner: *anyopaque, row: usize) u64,
    /// How busy the figure is, 0 to 3 (tints the cell).
    heat: ?*const fn (owner: *anyopaque, row: usize, col: usize) u8 = null,
    /// Right-click on a row (already selected), at x, y in the list.
    menu: ?*const fn (owner: *anyopaque, row: usize, x: f64, y: f64) void = null,
    activate: ?*const fn (owner: *anyopaque, row: usize) void = null,
    selection_changed: ?*const fn (owner: *anyopaque) void = null,
};

const Cell = struct { list: *SimpleList, item: *gtk.ListItem, col: usize, label: *gtk.Label, icon: ?*gtk.Image };

pub const SimpleList = struct {
    gpa: std.mem.Allocator,
    source: Source,
    specs: []const ColumnSpec,
    widget: *gtk.Widget,
    view: *gtk.ColumnView,
    model: *gtk.StringList,
    selection: *gtk.SingleSelection,
    cols: std.ArrayList(*gtk.ColumnViewColumn) = .empty,
    ctxs: std.ArrayList(*ColCtx) = .empty,
    cells: std.ArrayList(*Cell) = .empty,
    /// Display position to data row.
    order: std.ArrayList(usize) = .empty,
    keys: std.ArrayList(u64) = .empty,
    sort_col: usize = 0,
    descending: bool = false,

    const ColCtx = struct { list: *SimpleList, col: usize };

    pub fn create(gpa: std.mem.Allocator, specs: []const ColumnSpec, source: Source) *SimpleList {
        const self = gpa.create(SimpleList) catch @panic("OOM");
        const model = gtk.StringList.new(null);
        const selection = gtk.SingleSelection.new(model.as(gio.ListModel));
        selection.setAutoselect(0);
        selection.setCanUnselect(1);
        const view = gtk.ColumnView.new(selection.as(gtk.SelectionModel));
        view.as(gtk.Widget).addCssClass("dkde-process-table");
        view.setShowColumnSeparators(1);
        self.* = .{ .gpa = gpa, .source = source, .specs = specs, .widget = undefined, .view = view, .model = model, .selection = selection };
        for (specs, 0..) |spec, i| {
            const factory = gtk.SignalListItemFactory.new();
            const ctx = gpa.create(ColCtx) catch @panic("OOM");
            ctx.* = .{ .list = self, .col = i };
            self.ctxs.append(gpa, ctx) catch {};
            _ = gtk.SignalListItemFactory.signals.setup.connect(factory, *ColCtx, &onSetup, ctx, .{});
            _ = gtk.SignalListItemFactory.signals.bind.connect(factory, *ColCtx, &onBind, ctx, .{});
            _ = gtk.SignalListItemFactory.signals.teardown.connect(factory, *ColCtx, &onTeardown, ctx, .{});
            const column = gtk.ColumnViewColumn.new(spec.title, factory.as(gtk.ListItemFactory));
            column.setResizable(1);
            column.setExpand(@intFromBool(spec.expand));
            if (spec.width > 0) column.setFixedWidth(spec.width);
            column.setSorter(gtk.CustomSorter.new(null, null, null).as(gtk.Sorter));
            view.appendColumn(column);
            self.cols.append(gpa, column) catch {};
        }
        if (view.getSorter()) |sorter| _ = gtk.Sorter.signals.changed.connect(sorter, *SimpleList, &onSortChanged, self, .{});
        _ = gtk.ColumnView.signals.activate.connect(view, *SimpleList, &onActivate, self, .{});
        const click = gtk.GestureClick.new();
        click.as(gtk.GestureSingle).setButton(3);
        _ = gtk.GestureClick.signals.pressed.connect(click, *SimpleList, &onRightClick, self, .{});
        view.as(gtk.Widget).addController(click.as(gtk.EventController));
        _ = gtk.SelectionModel.signals.selection_changed.connect(selection.as(gtk.SelectionModel), *SimpleList, &onSelection, self, .{});
        const scroller = gtk.ScrolledWindow.new();
        scroller.setChild(view.as(gtk.Widget));
        scroller.as(gtk.Widget).setVexpand(1);
        self.widget = scroller.as(gtk.Widget);
        return self;
    }

    pub fn destroy(self: *SimpleList) void {
        for (self.ctxs.items) |c| self.gpa.destroy(c);
        self.ctxs.deinit(self.gpa);
        for (self.cells.items) |c| self.gpa.destroy(c);
        self.cells.deinit(self.gpa);
        self.cols.deinit(self.gpa);
        self.order.deinit(self.gpa);
        self.keys.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    pub fn sortBy(self: *SimpleList, col: usize, descending: bool) void {
        if (col >= self.cols.items.len) return;
        self.view.sortByColumn(self.cols.items[col], if (descending) .descending else .ascending);
    }

    /// Shows `count` data rows, sorted; keeps the selected row selected.
    pub fn update(self: *SimpleList, count: usize) void {
        const selected_key: ?u64 = if (self.selectedRow()) |r| self.source.key(self.source.owner, r) else null;
        self.order.clearRetainingCapacity();
        for (0..count) |i| self.order.append(self.gpa, i) catch return;
        std.mem.sort(usize, self.order.items, self, struct {
            fn lt(list: *SimpleList, a: usize, b: usize) bool {
                const s = list.source;
                if (list.descending) return s.less(s.owner, b, a, list.sort_col);
                return s.less(s.owner, a, b, list.sort_col);
            }
        }.lt);
        var same = self.keys.items.len == count;
        if (same) for (self.order.items, 0..) |row, i| {
            if (self.keys.items[i] != self.source.key(self.source.owner, row)) {
                same = false;
                break;
            }
        };
        if (!same) {
            self.keys.clearRetainingCapacity();
            for (self.order.items) |row| self.keys.append(self.gpa, self.source.key(self.source.owner, row)) catch return;
            const blanks = self.gpa.alloc(?[*:0]const u8, count + 1) catch return;
            defer self.gpa.free(blanks);
            @memset(blanks[0..count], "");
            blanks[count] = null;
            self.model.splice(0, self.model.as(gio.ListModel).getNItems(), @ptrCast(blanks.ptr));
            if (selected_key) |k| {
                if (std.mem.indexOfScalar(u64, self.keys.items, k)) |i| self.selection.setSelected(@intCast(i));
            }
        }
        for (self.cells.items) |c| self.render(c);
    }

    pub fn selectedRow(self: *const SimpleList) ?usize {
        const pos = self.selection.getSelected();
        if (pos == gtk.INVALID_LIST_POSITION or pos >= self.order.items.len) return null;
        return self.order.items[pos];
    }

    pub fn selectKey(self: *SimpleList, key: u64) void {
        if (std.mem.indexOfScalar(u64, self.keys.items, key)) |i| {
            self.selection.setSelected(@intCast(i));
            self.view.scrollTo(@intCast(i), null, .{ .focus = true, .select = true }, null);
        }
    }

    fn render(self: *SimpleList, cell: *Cell) void {
        if (cell.item.getItem() == null) return;
        const pos = cell.item.getPosition();
        if (pos >= self.order.items.len) return;
        const row = self.order.items[pos];
        var buf: [512]u8 = undefined;
        var zb: [512]u8 = undefined;
        const text = self.source.text(self.source.owner, row, cell.col, &buf);
        cell.label.setText(std.fmt.bufPrintSentinel(&zb, "{s}", .{text[0..@min(text.len, 500)]}, 0) catch "");
        if (self.source.heat) |h| @import("columns.zig").applyHeat(cell.label.as(gtk.Widget), h(self.source.owner, row, cell.col));
        if (cell.icon) |img| if (self.source.icon) |f| {
            const name = f(self.source.owner, row);
            if (name.len > 0 and name[0] == '/') {
                img.setFromFile(name);
            } else if (name.len > 0) {
                if (gio.Icon.newForString(name, null)) |gi| {
                    defer gi.as(gobject.Object).unref();
                    img.setFromGicon(gi);
                }
            } else img.clear();
        };
    }

    fn onSetup(_: *gtk.SignalListItemFactory, obj: *gobject.Object, ctx: *ColCtx) callconv(.c) void {
        const self = ctx.list;
        const item: *gtk.ListItem = @ptrCast(obj);
        const label = gtk.Label.new(null);
        label.setXalign(if (self.specs[ctx.col].right) 1 else 0);
        label.setEllipsize(.end);
        const cell = self.gpa.create(Cell) catch return;
        cell.* = .{ .list = self, .item = item, .col = ctx.col, .label = label, .icon = null };
        var child = label.as(gtk.Widget);
        if (ctx.col == 0 and self.source.icon != null) {
            const box = gtk.Box.new(.horizontal, 6);
            const img = gtk.Image.new();
            img.setPixelSize(16);
            box.append(img.as(gtk.Widget));
            label.as(gtk.Widget).setHexpand(1);
            box.append(label.as(gtk.Widget));
            cell.icon = img;
            child = box.as(gtk.Widget);
        }
        // The list's right-click finds the cell through this.
        child.as(gobject.Object).setData("dkde-cell", cell);
        item.setChild(child);
        item.as(gobject.Object).setData("dkde-cell", cell);
        self.cells.append(self.gpa, cell) catch {};
    }

    fn onBind(_: *gtk.SignalListItemFactory, obj: *gobject.Object, ctx: *ColCtx) callconv(.c) void {
        const item: *gtk.ListItem = @ptrCast(obj);
        const raw = item.as(gobject.Object).getData("dkde-cell") orelse return;
        ctx.list.render(@ptrCast(@alignCast(raw)));
    }

    fn onTeardown(_: *gtk.SignalListItemFactory, obj: *gobject.Object, ctx: *ColCtx) callconv(.c) void {
        const self = ctx.list;
        const item: *gtk.ListItem = @ptrCast(obj);
        const raw = item.as(gobject.Object).getData("dkde-cell") orelse return;
        const cell: *Cell = @ptrCast(@alignCast(raw));
        if (std.mem.indexOfScalar(*Cell, self.cells.items, cell)) |i| _ = self.cells.swapRemove(i);
        item.as(gobject.Object).setData("dkde-cell", null);
        if (item.getChild()) |w| w.as(gobject.Object).setData("dkde-cell", null);
        self.gpa.destroy(cell);
    }

    fn onRightClick(_: *gtk.GestureClick, _: c_int, x: f64, y: f64, self: *SimpleList) callconv(.c) void {
        const raw = @import("simplelist.zig").cellAt(self.view.as(gtk.Widget), x, y) orelse return;
        const cell: *Cell = @ptrCast(@alignCast(raw));
        const f = self.source.menu orelse return;
        const pos = cell.item.getPosition();
        if (pos >= self.order.items.len) return;
        self.selection.setSelected(pos);
        f(self.source.owner, self.order.items[pos], x, y);
    }

    fn onActivate(_: *gtk.ColumnView, pos: c_uint, self: *SimpleList) callconv(.c) void {
        const f = self.source.activate orelse return;
        if (pos < self.order.items.len) f(self.source.owner, self.order.items[pos]);
    }

    fn onSelection(_: *gtk.SelectionModel, _: c_uint, _: c_uint, self: *SimpleList) callconv(.c) void {
        if (self.source.selection_changed) |f| f(self.source.owner);
    }

    fn onSortChanged(sorter: *gtk.Sorter, _: gtk.SorterChange, self: *SimpleList) callconv(.c) void {
        const view_sorter: *gtk.ColumnViewSorter = @ptrCast(sorter);
        const column = view_sorter.getPrimarySortColumn() orelse return;
        const ascending = view_sorter.getPrimarySortOrder() == .ascending;
        for (self.cols.items, 0..) |c, i| if (c == column) {
            self.sort_col = i;
            // Figures: the first click lists the biggest first.
            self.descending = if (self.specs[i].big_first) ascending else !ascending;
            self.keys.clearRetainingCapacity(); // the order changed
            self.update(self.order.items.len);
            return;
        };
    }
};

/// The cell widget's data under (x, y) in a column view: the picked widget,
/// one of its parents, or (in a cell's padding) its child.
pub fn cellAt(view: *gtk.Widget, x: f64, y: f64) ?*anyopaque {
    var w: ?*gtk.Widget = view.pick(x, y, .{});
    while (w) |cur| : (w = cur.getParent()) {
        if (cur == view) return null;
        if (cur.as(gobject.Object).getData("dkde-cell")) |d| return d;
        if (cur.getFirstChild()) |c| {
            if (c.as(gobject.Object).getData("dkde-cell")) |d| return d;
            if (c.getFirstChild()) |cc| if (cc.as(gobject.Object).getData("dkde-cell")) |d| return d;
        }
    }
    return null;
}

/// A key for a row from its name.
pub fn hashKey(text: []const u8) u64 {
    return std.hash.Wyhash.hash(0, text);
}

/// A popup menu of `menu`'s items at x, y in `parent`; actions resolve
/// against the action groups inserted on `parent` or above it.
pub fn popupMenu(parent: *gtk.Widget, menu: *gio.MenuModel, x: f64, y: f64) void {
    const popover = gtk.PopoverMenu.newFromModel(menu);
    popover.as(gtk.Widget).setParent(parent);
    common.contextmenu.noScrollBars(popover);
    popover.as(gtk.Popover).setHasArrow(0);
    popover.as(gtk.Widget).setHalign(.start);
    const rect: gdk.Rectangle = .{ .f_x = @intFromFloat(x), .f_y = @intFromFloat(y), .f_width = 1, .f_height = 1 };
    popover.as(gtk.Popover).setPointingTo(&rect);
    _ = gtk.Popover.signals.closed.connect(popover.as(gtk.Popover), ?*anyopaque, &onClosed, null, .{});
    popover.as(gtk.Popover).popup();
}

fn onClosed(popover: *gtk.Popover, _: ?*anyopaque) callconv(.c) void {
    _ = glib.idleAdd(unparentLater, popover);
}

fn unparentLater(data: ?*anyopaque) callconv(.c) c_int {
    const w: *gtk.Widget = @ptrCast(@alignCast(data.?));
    w.unparent();
    return 0;
}
