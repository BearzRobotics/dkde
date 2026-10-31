//! The taskbar widget (SPEC.md 5.1): one button per window, or one per
//! application when windows are combined. A combined button shows a count and
//! opens a list of its windows; icon-only mode hides the titles.

const std = @import("std");
const gdk = @import("gdk4");
const gio = @import("gio2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

const giounix = @import("giounix2");
const toplevels = @import("toplevels.zig");
const pins = @import("taskbar_pins.zig");
const Toplevel = toplevels.Toplevel;

pub const Options = struct {
    /// One button per application instead of per window.
    group: bool = true,
    /// Show window titles next to the icons.
    labels: bool = true,
    /// Desktop file IDs pinned to the taskbar, in order.
    pinned: []const []const u8 = &.{},
};

pub const Taskbar = struct {
    allocator: std.mem.Allocator,
    box: *gtk.Box,
    /// Buttons by key: `app:<app_id>` when combined, `win:<address>` otherwise.
    buttons: std.StringHashMapUnmanaged(*Entry) = .empty,
    /// On a left or right panel the buttons stack top to bottom.
    vertical: bool = false,

    const Entry = struct {
        taskbar: *Taskbar,
        key: []u8,
        /// The windows this button stands for.
        members: std.ArrayList(*Toplevel) = .empty,
        /// The window that clicks and the menu act on; null for a pinned app that is not running.
        toplevel: ?*Toplevel,
        /// The desktop file ID when this button is a pinned app.
        pin_id: ?[]u8 = null,
        open_item: *gtk.Button,
        close_item: *gtk.Button,
        pin_item: *gtk.Button,
        button: *gtk.Button,
        icon: *gtk.Image,
        label: *gtk.Label,
        count: *gtk.Label,
        menu: *gtk.Popover,
        restore: *gtk.Button,
        maximize: *gtk.Button,
        close_all: *gtk.Button,
        list_popover: *gtk.Popover,
        list_box: *gtk.Box,
    };

    pub fn create(allocator: std.mem.Allocator, vertical: bool) !*Taskbar {
        const self = try allocator.create(Taskbar);
        const box = gtk.Box.new(if (vertical) .vertical else .horizontal, 2);
        box.as(gtk.Widget).addCssClass("dkde-taskbar");
        self.* = .{ .allocator = allocator, .box = box, .vertical = vertical };
        return self;
    }

    /// The bar owns the widget tree; this frees only the bookkeeping.
    pub fn destroy(self: *Taskbar) void {
        var it = self.buttons.valueIterator();
        while (it.next()) |entry| self.freeEntry(entry.*);
        self.buttons.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn freeEntry(self: *Taskbar, entry: *Entry) void {
        entry.members.deinit(self.allocator);
        if (entry.pin_id) |p| self.allocator.free(p);
        self.allocator.free(entry.key);
        self.allocator.destroy(entry);
    }

    const Group = struct {
        key: []u8,
        members: std.ArrayList(*Toplevel) = .empty,
    };

    /// Brings the buttons in line with `list`: adds, updates and removes.
    pub fn sync(self: *Taskbar, list: []const *Toplevel, opts: Options) void {
        const a = self.allocator;

        // 1. Which buttons should exist, and which windows each stands for.
        var groups: std.ArrayList(Group) = .empty;
        defer {
            for (groups.items) |*g| {
                g.members.deinit(a);
                a.free(g.key);
            }
            groups.deinit(a);
        }
        // Windows of a pinned app share the pinned button when combined.
        const pinned_ids = opts.pinned;
        for (list) |t| {
            if (!t.ready) continue;
            var pin: ?[]const u8 = null;
            if (pinned_ids.len > 0 and t.app_id.len > 0) {
                if (common.appinfo.find(t.app_id)) |info| {
                    defer info.as(gobject.Object).unref();
                    if (info.getId()) |id_c| {
                        for (pinned_ids) |p| if (std.mem.eql(u8, p, std.mem.span(id_c))) {
                            pin = p;
                        };
                    }
                }
            }
            const key = if (opts.group and pin != null)
                std.fmt.allocPrint(a, "pin:{s}", .{pin.?}) catch continue
            else if (opts.group and t.app_id.len > 0)
                std.fmt.allocPrint(a, "app:{s}", .{t.app_id}) catch continue
            else
                std.fmt.allocPrint(a, "win:{x}", .{@intFromPtr(t)}) catch continue;
            var found: ?*Group = null;
            for (groups.items) |*g| if (std.mem.eql(u8, g.key, key)) {
                found = g;
                break;
            };
            if (found) |g| {
                a.free(key);
                g.members.append(a, t) catch {};
            } else {
                var g: Group = .{ .key = key };
                g.members.append(a, t) catch {};
                groups.append(a, g) catch {
                    g.members.deinit(a);
                    a.free(key);
                };
            }
        }
        // A pinned app with no window keeps an idle launcher button.
        var windowed_pins: usize = 0;
        for (pinned_ids) |p| {
            const key = std.fmt.allocPrint(a, "pin:{s}", .{p}) catch continue;
            var present = false;
            for (groups.items) |g| if (std.mem.eql(u8, g.key, key)) {
                present = true;
            };
            if (present) {
                a.free(key);
                windowed_pins += 1;
                continue;
            }
            groups.append(a, .{ .key = key }) catch a.free(key);
        }
        // Pinned buttons first, in the pinned order, then the rest.
        var ordered: std.ArrayList(*Group) = .empty;
        defer ordered.deinit(a);
        for (pinned_ids) |p| {
            var kb: [320]u8 = undefined;
            const key = std.fmt.bufPrint(&kb, "pin:{s}", .{p}) catch continue;
            for (groups.items) |*g| if (std.mem.eql(u8, g.key, key)) ordered.append(a, g) catch {};
        }
        for (groups.items) |*g| if (!std.mem.startsWith(u8, g.key, "pin:")) ordered.append(a, g) catch {};

        // 2. Drop buttons nothing stands behind any more.
        var gone: std.ArrayList([]const u8) = .empty;
        defer gone.deinit(a);
        var keys = self.buttons.keyIterator();
        while (keys.next()) |key| {
            var wanted = false;
            for (groups.items) |g| if (std.mem.eql(u8, g.key, key.*)) {
                wanted = true;
                break;
            };
            if (!wanted) gone.append(a, key.*) catch {};
        }
        for (gone.items) |key| {
            const entry = self.buttons.fetchRemove(key).?.value;
            self.box.remove(entry.button.as(gtk.Widget));
            self.freeEntry(entry);
        }

        // 3. Add the new, refresh every button and put them in order.
        var previous: ?*gtk.Widget = null;
        for (ordered.items) |g| {
            const first: ?*Toplevel = if (g.members.items.len > 0) g.members.items[0] else null;
            const entry = self.buttons.get(g.key) orelse (self.add(g.key, first) catch continue);
            entry.members.clearRetainingCapacity();
            entry.members.appendSlice(a, g.members.items) catch continue;
            update(entry, opts);
            self.box.reorderChildAfter(entry.button.as(gtk.Widget), previous);
            previous = entry.button.as(gtk.Widget);
        }
    }

    fn add(self: *Taskbar, key: []const u8, first: ?*Toplevel) !*Entry {
        const entry = try self.allocator.create(Entry);
        errdefer self.allocator.destroy(entry);
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);

        const content = gtk.Box.new(.horizontal, 6);
        const icon = gtk.Image.new();
        icon.setPixelSize(20);
        const label = gtk.Label.new(null);
        label.setEllipsize(.end);
        label.setXalign(0);
        label.setWidthChars(14);
        label.setMaxWidthChars(20);
        const count = gtk.Label.new(null);
        count.as(gtk.Widget).addCssClass("dkde-task-count");
        content.append(icon.as(gtk.Widget));
        content.append(label.as(gtk.Widget));
        content.append(count.as(gtk.Widget));

        const button = gtk.Button.new();
        button.setChild(content.as(gtk.Widget));
        button.as(gtk.Widget).addCssClass("dkde-task");
        // Like Windows: a capped width, left-aligned. The bar only squeezes
        // the buttons (the labels ellipsize) once it runs out of room.
        button.as(gtk.Widget).setHexpand(0);
        button.as(gtk.Widget).setHalign(if (self.vertical) .fill else .start);

        // Right-click menu: Restore/Minimize, Maximize, Close (Close all for stacks).
        const menu = gtk.Popover.new();
        menu.as(gtk.Widget).addCssClass("dkde-task-menu");
        const items = gtk.Box.new(.vertical, 0);
        menu.setChild(items.as(gtk.Widget));
        const open_item = gtk.Button.newWithLabel(common.tr("Open"));
        const restore = gtk.Button.new();
        const maximize = gtk.Button.new();
        const close = gtk.Button.newWithLabel(common.tr("Close"));
        const close_all = gtk.Button.newWithLabel(common.tr("Close all windows"));
        const pin_item = gtk.Button.newWithLabel(common.tr("Pin to taskbar"));
        for ([_]*gtk.Button{ open_item, restore, maximize, close, close_all, pin_item }) |item| {
            item.setHasFrame(0);
            items.append(item.as(gtk.Widget));
        }
        menu.as(gtk.Widget).setParent(button.as(gtk.Widget));

        // The list of windows a stack opens on click.
        const list_popover = gtk.Popover.new();
        list_popover.as(gtk.Widget).addCssClass("dkde-task-list");
        const list_box = gtk.Box.new(.vertical, 0);
        list_popover.setChild(list_box.as(gtk.Widget));
        list_popover.as(gtk.Widget).setParent(button.as(gtk.Widget));

        entry.* = .{
            .taskbar = self,
            .key = owned_key,
            .toplevel = first,
            .pin_id = if (std.mem.startsWith(u8, key, "pin:")) try self.allocator.dupe(u8, key["pin:".len..]) else null,
            .open_item = open_item,
            .close_item = close,
            .pin_item = pin_item,
            .button = button,
            .icon = icon,
            .label = label,
            .count = count,
            .menu = menu,
            .restore = restore,
            .maximize = maximize,
            .close_all = close_all,
            .list_popover = list_popover,
            .list_box = list_box,
        };

        _ = gtk.Button.signals.clicked.connect(button, *Entry, &onClicked, entry, .{});
        _ = gtk.Button.signals.clicked.connect(open_item, *Entry, &onOpenClicked, entry, .{});
        _ = gtk.Button.signals.clicked.connect(pin_item, *Entry, &onPinClicked, entry, .{});
        _ = gtk.Button.signals.clicked.connect(restore, *Entry, &onRestoreClicked, entry, .{});
        _ = gtk.Button.signals.clicked.connect(maximize, *Entry, &onMaximizeClicked, entry, .{});
        _ = gtk.Button.signals.clicked.connect(close, *Entry, &onCloseClicked, entry, .{});
        _ = gtk.Button.signals.clicked.connect(close_all, *Entry, &onCloseAllClicked, entry, .{});

        const clicks = gtk.GestureClick.new();
        clicks.as(gtk.GestureSingle).setButton(0);
        _ = gtk.GestureClick.signals.pressed.connect(clicks, *Entry, &onPressed, entry, .{});
        button.as(gtk.Widget).addController(clicks.as(gtk.EventController));

        // Keyboard access to the right-click menu: Menu key or Shift+F10.
        const keys = gtk.EventControllerKey.new();
        _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *Entry, &onKeyPressed, entry, .{});
        button.as(gtk.Widget).addController(keys.as(gtk.EventController));

        // The popovers are children of the button; unparent them with it.
        _ = gtk.Widget.signals.destroy.connect(button, *Entry, &onButtonDestroy, entry, .{});

        self.box.append(button.as(gtk.Widget));
        try self.buttons.put(self.allocator, owned_key, entry);
        return entry;
    }

    /// The window clicks act on: the active one, else the first that is shown.
    fn representative(entry: *const Entry) *Toplevel {
        for (entry.members.items) |t| if (t.activated) return t;
        for (entry.members.items) |t| if (!t.minimized) return t;
        return entry.members.items[0];
    }

    /// The app a button stands for (pinned, or found from its window).
    fn appInfo(entry: *const Entry) ?*gio.AppInfo {
        if (entry.pin_id) |id| {
            const z = entry.taskbar.allocator.dupeSentinel(u8, id, 0) catch return null;
            defer entry.taskbar.allocator.free(z);
            const d = giounix.DesktopAppInfo.new(z) orelse return null;
            return @ptrCast(d);
        }
        if (entry.members.items.len > 0) return common.appinfo.find(entry.members.items[0].app_id);
        return null;
    }

    /// A pinned app that is not running: just an icon that launches it.
    fn updateIdle(entry: *Entry) void {
        const a = entry.taskbar.allocator;
        const widget = entry.button.as(gtk.Widget);
        entry.toplevel = null;
        entry.label.as(gtk.Widget).setVisible(0);
        entry.count.as(gtk.Widget).setVisible(0);
        setClass(widget, "icon-only", true);
        setClass(widget, "stacked", false);
        setClass(widget, "active", false);
        setClass(widget, "minimized", false);
        setClass(widget, "pinned", true);
        widget.setSizeRequest(-1, -1);
        if (appInfo(entry)) |info| {
            defer info.as(gobject.Object).unref();
            if (info.getIcon()) |icon| entry.icon.setFromGicon(icon) else entry.icon.setFromIconName("application-x-executable");
            const name = a.dupeSentinel(u8, std.mem.span(info.getDisplayName()), 0) catch return;
            defer a.free(name);
            widget.setTooltipText(name);
        } else entry.icon.setFromIconName("application-x-executable");
        entry.open_item.as(gtk.Widget).setVisible(1);
        entry.restore.as(gtk.Widget).setVisible(0);
        entry.maximize.as(gtk.Widget).setVisible(0);
        entry.close_item.as(gtk.Widget).setVisible(0);
        entry.close_all.as(gtk.Widget).setVisible(0);
        entry.pin_item.setLabel(common.tr("Unpin from taskbar"));
        entry.pin_item.as(gtk.Widget).setVisible(1);
    }

    fn update(entry: *Entry, opts: Options) void {
        if (entry.members.items.len == 0) return updateIdle(entry);
        const a = entry.taskbar.allocator;
        setClass(entry.button.as(gtk.Widget), "pinned", entry.pin_id != null);
        entry.open_item.as(gtk.Widget).setVisible(0);
        entry.restore.as(gtk.Widget).setVisible(1);
        entry.maximize.as(gtk.Widget).setVisible(1);
        entry.close_item.as(gtk.Widget).setVisible(1);
        const rep = representative(entry);
        entry.toplevel = rep;
        const widget = entry.button.as(gtk.Widget);
        const stacked = entry.members.items.len > 1;

        // Text: the window title, or the application's name for a stack.
        var text: []const u8 = rep.title;
        var app_name: ?[:0]u8 = null;
        defer if (app_name) |n| a.free(n);
        if (stacked) {
            if (common.appinfo.find(rep.app_id)) |info| {
                defer info.as(gobject.Object).unref();
                app_name = a.dupeSentinel(u8, std.mem.span(info.getDisplayName()), 0) catch null;
            }
            text = if (app_name) |n| n else rep.app_id;
        }
        const label_text = a.dupeSentinel(u8, text, 0) catch return;
        defer a.free(label_text);
        entry.label.setText(label_text);
        entry.label.as(gtk.Widget).setVisible(@intFromBool(opts.labels));
        setClass(widget, "icon-only", !opts.labels);
        widget.setSizeRequest(if (opts.labels) 48 else -1, -1);

        var tip_buf: [512]u8 = undefined;
        const tip = if (stacked)
            std.fmt.bufPrintSentinel(&tip_buf, "{s} ({d} windows)", .{ text, entry.members.items.len }, 0) catch label_text
        else
            label_text;
        widget.setTooltipText(tip);

        var count_buf: [16]u8 = undefined;
        entry.count.setText(std.fmt.bufPrintSentinel(&count_buf, "{d}", .{entry.members.items.len}, 0) catch "");
        entry.count.as(gtk.Widget).setVisible(@intFromBool(stacked));
        setClass(widget, "stacked", stacked);

        var any_active = false;
        var all_minimized = true;
        for (entry.members.items) |t| {
            if (t.activated) any_active = true;
            if (!t.minimized) all_minimized = false;
        }
        setClass(widget, "active", any_active);
        setClass(widget, "minimized", all_minimized);

        setIcon(entry.icon, rep.app_id);

        entry.restore.setLabel(if (rep.minimized) common.tr("Restore") else common.tr("Minimize"));
        entry.maximize.setLabel(if (rep.maximized) common.tr("Unmaximize") else common.tr("Maximize"));
        entry.close_all.as(gtk.Widget).setVisible(@intFromBool(stacked));
        // Pin or unpin, when the window belongs to an app with a desktop entry.
        if (entry.pin_id != null) {
            entry.pin_item.setLabel(common.tr("Unpin from taskbar"));
            entry.pin_item.as(gtk.Widget).setVisible(1);
        } else if (common.appinfo.find(rep.app_id)) |info| {
            info.as(gobject.Object).unref();
            entry.pin_item.setLabel(common.tr("Pin to taskbar"));
            entry.pin_item.as(gtk.Widget).setVisible(1);
        } else entry.pin_item.as(gtk.Widget).setVisible(0);
    }

    fn setIcon(image: *gtk.Image, app_id: []const u8) void {
        if (common.appinfo.find(app_id)) |info| {
            defer info.as(gobject.Object).unref();
            if (info.getIcon()) |icon| {
                image.setFromGicon(icon);
                return;
            }
        }
        image.setFromIconName("application-x-executable");
    }

    fn setClass(widget: *gtk.Widget, class: [:0]const u8, on: bool) void {
        if (on) widget.addCssClass(class) else widget.removeCssClass(class);
    }

    // Left click: activate; if already active, minimize. A stack lists its windows.
    fn onClicked(_: *gtk.Button, entry: *Entry) callconv(.c) void {
        if (entry.members.items.len == 0) return launch(entry);
        if (entry.members.items.len > 1) return showList(entry);
        const t = entry.toplevel orelse return;
        if (t.activated and !t.minimized) t.setMinimized(true) else t.activate();
    }

    fn launch(entry: *Entry) void {
        const info = appInfo(entry) orelse return;
        defer info.as(gobject.Object).unref();
        common.appinfo.launch(entry.taskbar.allocator, info);
    }

    fn onOpenClicked(_: *gtk.Button, entry: *Entry) callconv(.c) void {
        entry.menu.popdown();
        launch(entry);
    }

    fn onPinClicked(_: *gtk.Button, entry: *Entry) callconv(.c) void {
        entry.menu.popdown();
        const info = appInfo(entry) orelse return;
        defer info.as(gobject.Object).unref();
        const id = std.mem.span(info.getId() orelse return);
        pins.toggle(entry.taskbar.allocator, id);
    }

    const ListItem = struct { entry: *Entry, toplevel: *Toplevel };

    fn onListItemDestroy(_: *gtk.Button, item: *ListItem) callconv(.c) void {
        std.heap.c_allocator.destroy(item);
    }

    fn onListItemClicked(_: *gtk.Button, item: *ListItem) callconv(.c) void {
        const entry = item.entry;
        entry.list_popover.popdown();
        // The window may have closed since the list was built.
        if (std.mem.indexOfScalar(*Toplevel, entry.members.items, item.toplevel) == null) return;
        item.toplevel.activate();
    }

    fn showList(entry: *Entry) void {
        while (entry.list_box.as(gtk.Widget).getFirstChild()) |child| entry.list_box.remove(child);
        const a = entry.taskbar.allocator;
        for (entry.members.items) |t| {
            const title = a.dupeSentinel(u8, if (t.title.len > 0) t.title else t.app_id, 0) catch continue;
            defer a.free(title);
            const row = gtk.Button.newWithLabel(title);
            row.setHasFrame(0);
            if (row.getChild()) |child| {
                const l: *gtk.Label = @ptrCast(@alignCast(child));
                l.setXalign(0);
                l.setEllipsize(.end);
                l.setMaxWidthChars(40);
            }
            if (t.activated) row.as(gtk.Widget).addCssClass("active");
            const item = std.heap.c_allocator.create(ListItem) catch continue;
            item.* = .{ .entry = entry, .toplevel = t };
            _ = gtk.Button.signals.clicked.connect(row, *ListItem, &onListItemClicked, item, .{});
            _ = gtk.Widget.signals.destroy.connect(row, *ListItem, &onListItemDestroy, item, .{});
            entry.list_box.append(row.as(gtk.Widget));
        }
        entry.list_popover.popup();
    }

    // Middle click closes, right click opens the menu.
    fn onPressed(gesture: *gtk.GestureClick, _: c_int, _: f64, _: f64, entry: *Entry) callconv(.c) void {
        switch (gesture.as(gtk.GestureSingle).getCurrentButton()) {
            2 => if (entry.toplevel) |t| t.close(),
            3 => entry.menu.popup(),
            else => {},
        }
    }

    fn onKeyPressed(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, state: gdk.ModifierType, entry: *Entry) callconv(.c) c_int {
        const menu_key = keyval == gdk.KEY_Menu or (keyval == gdk.KEY_F10 and state.shift_mask);
        if (!menu_key) return 0;
        entry.menu.popup();
        return 1;
    }

    fn onRestoreClicked(_: *gtk.Button, entry: *Entry) callconv(.c) void {
        entry.menu.popdown();
        const t = entry.toplevel orelse return;
        if (t.minimized) t.activate() else t.setMinimized(true);
    }

    fn onMaximizeClicked(_: *gtk.Button, entry: *Entry) callconv(.c) void {
        entry.menu.popdown();
        const t = entry.toplevel orelse return;
        t.setMaximized(!t.maximized);
    }

    fn onCloseClicked(_: *gtk.Button, entry: *Entry) callconv(.c) void {
        entry.menu.popdown();
        if (entry.toplevel) |t| t.close();
    }

    fn onCloseAllClicked(_: *gtk.Button, entry: *Entry) callconv(.c) void {
        entry.menu.popdown();
        for (entry.members.items) |t| t.close();
    }

    fn onButtonDestroy(button: *gtk.Button, entry: *Entry) callconv(.c) void {
        _ = button;
        entry.menu.as(gtk.Widget).unparent();
        entry.list_popover.as(gtk.Widget).unparent();
    }
};
