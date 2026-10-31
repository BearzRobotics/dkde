//! Desktop icons (SPEC.md 5.1): the contents of the Desktop folder, drawn on
//! the primary output's wallpaper surface. Icons are placed freely: drag one
//! and it snaps to the grid and the position is remembered in `desktop.conf`.
//! Double-click opens an item; a `.desktop` launcher starts its app.
//! Right-click on an icon offers Open and Move to Trash; right-click on empty
//! space belongs to the wallpaper.

const std = @import("std");
const gio = @import("gio2");
const giounix = @import("giounix2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");

const common = @import("common");

const attributes = "standard::name,standard::display-name,standard::icon,standard::type,standard::content-type,standard::is-hidden,standard::is-backup";

pub const Desktop = struct {
    allocator: std.mem.Allocator,
    dir_path: [:0]u8,
    list: *gtk.DirectoryList,
    model: *gio.ListModel,
    fixed: *gtk.Fixed,
    /// Remembered positions, keyed by file name.
    positions: common.Config,
    selected: ?*Item = null,
    config: *const common.Config,

    const cell_w: f64 = 96;
    const cell_h: f64 = 104;
    const margin: f64 = 8;

    /// The icon layer to place over the wallpaper, or null when there is no Desktop folder.
    pub fn create(allocator: std.mem.Allocator, config: *const common.Config) ?*Desktop {
        const path = glib.getUserSpecialDir(.directory_desktop) orelse return null;
        if (glib.fileTest(path, .{ .is_dir = true }) == 0) return null;
        const self = allocator.create(Desktop) catch return null;
        self.allocator = allocator;
        self.dir_path = allocator.dupeSentinel(u8, std.mem.span(path), 0) catch return null;
        self.positions = common.Config.load(allocator, "desktop.conf") catch return null;
        self.selected = null;
        self.config = config;

        const dir = gio.File.newForPath(self.dir_path);
        defer dir.as(gobject.Object).unref();
        self.list = gtk.DirectoryList.new(attributes, dir);
        self.list.setMonitored(1);

        const filter = gtk.CustomFilter.new(filterFunc, null, null);
        const filtered = gtk.FilterListModel.new(self.list.as(gio.ListModel), filter.as(gtk.Filter));
        const sorter = gtk.CustomSorter.new(compareFunc, null, null);
        const sorted = gtk.SortListModel.new(filtered.as(gio.ListModel), sorter.as(gtk.Sorter));
        self.model = sorted.as(gio.ListModel);

        self.fixed = gtk.Fixed.new();
        self.fixed.as(gtk.Widget).addCssClass("dkde-desktop-icons");
        _ = gio.ListModel.signals.items_changed.connect(self.model, *Desktop, &onItemsChanged, self, .{});
        // Clicking empty space clears the selection.
        const click = gtk.GestureClick.new();
        _ = gtk.GestureClick.signals.pressed.connect(click, *Desktop, &onBackgroundClick, self, .{});
        self.fixed.as(gtk.Widget).addController(click.as(gtk.EventController));
        // The list loads asynchronously; the first items_changed fills the view.
        return self;
    }

    pub fn widget(self: *Desktop) *gtk.Widget {
        return self.fixed.as(gtk.Widget);
    }

    // ---- model ----------------------------------------------------------------

    fn filterFunc(item: *gobject.Object, _: ?*anyopaque) callconv(.c) c_int {
        const info: *gio.FileInfo = @ptrCast(item);
        return @intFromBool(info.getIsHidden() == 0 and info.getIsBackup() == 0);
    }

    fn compareFunc(a_raw: ?*const anyopaque, b_raw: ?*const anyopaque, _: ?*anyopaque) callconv(.c) c_int {
        const a: *gio.FileInfo = @ptrCast(@alignCast(@constCast(a_raw.?)));
        const b: *gio.FileInfo = @ptrCast(@alignCast(@constCast(b_raw.?)));
        const a_dir = a.getFileType() == .directory;
        const b_dir = b.getFileType() == .directory;
        if (a_dir != b_dir) return if (a_dir) -1 else 1;
        return switch (std.ascii.orderIgnoreCase(std.mem.span(a.getDisplayName()), std.mem.span(b.getDisplayName()))) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        };
    }

    fn onItemsChanged(_: *gio.ListModel, _: c_uint, _: c_uint, _: c_uint, self: *Desktop) callconv(.c) void {
        self.rebuild();
    }

    fn onBackgroundClick(_: *gtk.GestureClick, _: c_int, _: f64, _: f64, self: *Desktop) callconv(.c) void {
        self.select(null);
    }

    // ---- positions --------------------------------------------------------------------

    fn savedPosition(self: *Desktop, name: [:0]const u8) ?[2]f64 {
        const text = self.positions.getString(self.allocator, "icons", name, "") catch return null;
        defer self.allocator.free(text);
        var parts = std.mem.splitScalar(u8, text, ',');
        const x = std.fmt.parseFloat(f64, parts.next() orelse return null) catch return null;
        const y = std.fmt.parseFloat(f64, parts.next() orelse return null) catch return null;
        return .{ x, y };
    }

    fn savePosition(self: *Desktop, name: [:0]const u8, x: f64, y: f64) void {
        var buf: [48]u8 = undefined;
        const text = std.fmt.bufPrintSentinel(&buf, "{d:.0},{d:.0}", .{ x, y }, 0) catch return;
        self.positions.setString("icons", name, text) catch {};
    }

    fn snap(v: f64, size: f64) f64 {
        return margin + @max(0, @round((v - margin) / size)) * size;
    }

    fn occupied(placed: []const [2]f64, x: f64, y: f64) bool {
        for (placed) |p| if (@abs(p[0] - x) < cell_w / 2 and @abs(p[1] - y) < cell_h / 2) return true;
        return false;
    }

    /// Next free cell, filling a column top to bottom and then moving right,
    /// like Windows.
    fn freeCell(self: *Desktop, placed: []const [2]f64) [2]f64 {
        const height: f64 = @floatFromInt(@max(self.fixed.as(gtk.Widget).getHeight(), 600));
        const rows: usize = @max(1, @as(usize, @intFromFloat((height - margin) / cell_h)));
        var col: usize = 0;
        while (col < 64) : (col += 1) {
            for (0..rows) |row| {
                const x = margin + @as(f64, @floatFromInt(col)) * cell_w;
                const y = margin + @as(f64, @floatFromInt(row)) * cell_h;
                if (!occupied(placed, x, y)) return .{ x, y };
            }
        }
        return .{ margin, margin };
    }

    // ---- icons --------------------------------------------------------------------------

    const Item = struct {
        desktop: *Desktop,
        /// The file's name inside the Desktop folder.
        name: [:0]u8,
        is_dir: bool,
        widget: *gtk.Box,
        start: [2]f64 = .{ 0, 0 },
        dragged: bool = false,
    };

    fn rebuild(self: *Desktop) void {
        self.selected = null;
        while (self.fixed.as(gtk.Widget).getFirstChild()) |child| self.fixed.remove(child);

        var placed: std.ArrayList([2]f64) = .empty;
        defer placed.deinit(self.allocator);
        // Saved positions first, so new files take the cells that are left.
        const count = self.model.getNItems();
        var i: c_uint = 0;
        while (i < count) : (i += 1) {
            const obj: *gobject.Object = @ptrCast(@alignCast(self.model.getItem(i) orelse continue));
            defer obj.unref();
            const info: *gio.FileInfo = @ptrCast(obj);
            const name: [:0]const u8 = std.mem.span(info.getName());
            if (self.savedPosition(name)) |pos| placed.append(self.allocator, pos) catch {};
        }
        i = 0;
        while (i < count) : (i += 1) {
            const obj: *gobject.Object = @ptrCast(@alignCast(self.model.getItem(i) orelse continue));
            defer obj.unref();
            const info: *gio.FileInfo = @ptrCast(obj);
            const name: [:0]const u8 = std.mem.span(info.getName());
            const pos = self.savedPosition(name) orelse blk: {
                const free = self.freeCell(placed.items);
                placed.append(self.allocator, free) catch {};
                break :blk free;
            };
            self.addItem(info, pos);
        }
    }

    fn addItem(self: *Desktop, info: *gio.FileInfo, pos: [2]f64) void {
        const box = gtk.Box.new(.vertical, 4);
        box.as(gtk.Widget).setSizeRequest(@intFromFloat(cell_w - 8), -1);
        box.as(gtk.Widget).addCssClass("dkde-desktop-item");
        const icon = gtk.Image.new();
        icon.setPixelSize(48);
        const label = gtk.Label.new(null);
        label.setEllipsize(.middle);
        label.setMaxWidthChars(12);
        label.setWrap(1);
        label.setLines(2);
        label.setJustify(.center);
        box.append(icon.as(gtk.Widget));
        box.append(label.as(gtk.Widget));

        // A launcher shows the app's own name and icon.
        if (self.launcher(info)) |app| {
            defer app.as(gobject.Object).unref();
            if (app.getIcon()) |gicon| icon.setFromGicon(gicon) else icon.setFromIconName("application-x-executable");
            label.setText(app.getName());
        } else {
            if (info.getIcon()) |gicon| icon.setFromGicon(gicon) else icon.setFromIconName("text-x-generic");
            label.setText(info.getDisplayName());
        }

        const item = self.allocator.create(Item) catch return;
        item.* = .{
            .desktop = self,
            .name = self.allocator.dupeSentinel(u8, std.mem.span(info.getName()), 0) catch return,
            .is_dir = info.getFileType() == .directory,
            .widget = box,
        };
        _ = gtk.Widget.signals.destroy.connect(box, *Item, &onItemDestroy, item, .{});

        const press = gtk.GestureClick.new();
        press.as(gtk.GestureSingle).setButton(0);
        _ = gtk.GestureClick.signals.pressed.connect(press, *Item, &onPressed, item, .{});
        box.as(gtk.Widget).addController(press.as(gtk.EventController));

        const drag = gtk.GestureDrag.new();
        drag.as(gtk.GestureSingle).setButton(1);
        _ = gtk.GestureDrag.signals.drag_begin.connect(drag, *Item, &onDragBegin, item, .{});
        _ = gtk.GestureDrag.signals.drag_update.connect(drag, *Item, &onDragUpdate, item, .{});
        _ = gtk.GestureDrag.signals.drag_end.connect(drag, *Item, &onDragEnd, item, .{});
        box.as(gtk.Widget).addController(drag.as(gtk.EventController));

        self.fixed.put(box.as(gtk.Widget), pos[0], pos[1]);
    }

    fn onItemDestroy(_: *gtk.Box, item: *Item) callconv(.c) void {
        if (item.desktop.selected == item) item.desktop.selected = null;
        item.desktop.allocator.free(item.name);
        item.desktop.allocator.destroy(item);
    }

    fn select(self: *Desktop, item: ?*Item) void {
        if (self.selected) |old| old.widget.as(gtk.Widget).removeCssClass("selected");
        self.selected = item;
        if (item) |it| it.widget.as(gtk.Widget).addCssClass("selected");
    }

    fn position(item: *Item) [2]f64 {
        var x: f64 = 0;
        var y: f64 = 0;
        item.desktop.fixed.getChildPosition(item.widget.as(gtk.Widget), &x, &y);
        return .{ x, y };
    }

    fn onPressed(gesture: *gtk.GestureClick, n_press: c_int, x: f64, y: f64, item: *Item) callconv(.c) void {
        const button = gesture.as(gtk.GestureSingle).getCurrentButton();
        item.desktop.select(item);
        if (button == 3) {
            common.contextmenu.show(item.widget.as(gtk.Widget), x, y, &.{
                .{ .label = common.tr("Open"), .id = open_item },
                .{ .label = common.tr("Move to Trash"), .id = trash_item },
            }, Item, onChosen, item);
        } else if (button == 1 and n_press == 2) {
            item.desktop.open(item);
        }
    }

    fn onDragBegin(_: *gtk.GestureDrag, _: f64, _: f64, item: *Item) callconv(.c) void {
        item.start = position(item);
        item.dragged = false;
    }

    fn onDragUpdate(_: *gtk.GestureDrag, dx: f64, dy: f64, item: *Item) callconv(.c) void {
        // A few pixels of wobble is still a click.
        if (!item.dragged and @abs(dx) < 4 and @abs(dy) < 4) return;
        item.dragged = true;
        item.desktop.fixed.move(item.widget.as(gtk.Widget), @max(0, item.start[0] + dx), @max(0, item.start[1] + dy));
    }

    fn onDragEnd(_: *gtk.GestureDrag, _: f64, _: f64, item: *Item) callconv(.c) void {
        if (!item.dragged) return;
        const self = item.desktop;
        const area = self.fixed.as(gtk.Widget);
        const here = position(item);
        const max_x: f64 = @floatFromInt(@max(0, area.getWidth() - @as(c_int, @intFromFloat(cell_w))));
        const max_y: f64 = @floatFromInt(@max(0, area.getHeight() - @as(c_int, @intFromFloat(cell_h))));
        const aligned = self.config.getBool("desktop", "snap-to-grid", true);
        const x = if (aligned) @min(snap(here[0], cell_w), snap(max_x, cell_w)) else std.math.clamp(here[0], 0, max_x);
        const y = if (aligned) @min(snap(here[1], cell_h), snap(max_y, cell_h)) else std.math.clamp(here[1], 0, max_y);
        self.fixed.move(item.widget.as(gtk.Widget), x, y);
        self.savePosition(item.name, x, y);
    }

    fn pathOf(self: *Desktop, name: []const u8) ?[:0]u8 {
        return std.fmt.allocPrintSentinel(self.allocator, "{s}/{s}", .{ self.dir_path, name }, 0) catch null;
    }

    /// The app a `.desktop` file on the desktop launches, if it is one.
    fn launcher(self: *Desktop, info: *gio.FileInfo) ?*gio.AppInfo {
        const name = std.mem.span(info.getName());
        if (!std.mem.endsWith(u8, name, ".desktop")) return null;
        const path = self.pathOf(name) orelse return null;
        defer self.allocator.free(path);
        const app = giounix.DesktopAppInfo.newFromFilename(path) orelse return null;
        return @ptrCast(app);
    }

    // ---- actions -----------------------------------------------------------------------

    fn open(self: *Desktop, item: *Item) void {
        const path = self.pathOf(item.name) orelse return;
        defer self.allocator.free(path);
        if (std.mem.endsWith(u8, item.name, ".desktop")) {
            if (giounix.DesktopAppInfo.newFromFilename(path)) |app| {
                defer app.as(gobject.Object).unref();
                return common.appinfo.launch(self.allocator, @ptrCast(app));
            }
        }
        if (item.is_dir) return common.appinfo.spawn(self.allocator, &.{ "dkde-files", path });
        const file = gio.File.newForPath(path);
        defer file.as(gobject.Object).unref();
        const uri = file.getUri();
        defer glib.free(uri);
        var err: ?*glib.Error = null;
        if (gio.AppInfo.launchDefaultForUri(uri, null, &err) == 0) {
            if (err) |e| {
                std.log.warn("cannot open {s}: {s}", .{ path, e.f_message orelse "unknown error" });
                e.free();
            }
        }
    }

    const open_item = 0;
    const trash_item = 1;

    fn onChosen(item: *Item, id: usize) void {
        const self = item.desktop;
        switch (id) {
            open_item => self.open(item),
            trash_item => {
                const path = self.pathOf(item.name) orelse return;
                defer self.allocator.free(path);
                const file = gio.File.newForPath(path);
                defer file.as(gobject.Object).unref();
                var err: ?*glib.Error = null;
                if (file.trash(null, &err) == 0) {
                    if (err) |e| {
                        std.log.warn("cannot trash {s}: {s}", .{ path, e.f_message orelse "unknown error" });
                        e.free();
                    }
                }
            },
            else => {},
        }
    }
};
