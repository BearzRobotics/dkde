//! The system tray (SPEC.md 5.1): a StatusNotifierItem host. The panel owns
//! `org.kde.StatusNotifierWatcher` on the session bus (nothing else does in a
//! dkde session), apps register their `StatusNotifierItem`, and each shows as
//! an icon in the bar. Left click activates the item, middle click is its
//! secondary action, right click opens its menu: the app's own
//! `com.canonical.dbusmenu` if it has one (shown flat, submenu entries
//! indented), otherwise the item's `ContextMenu` method.
//!
//! With no session bus there is no tray, and the panel carries on without it.

const std = @import("std");
const gdk = @import("gdk4");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");

const common = @import("common");

const watcher_name = "org.kde.StatusNotifierWatcher";
const watcher_path = "/StatusNotifierWatcher";
const item_interface = "org.kde.StatusNotifierItem";
const default_item_path = "/StatusNotifierItem";

const introspection =
    \\<node>
    \\  <interface name="org.kde.StatusNotifierWatcher">
    \\    <method name="RegisterStatusNotifierItem"><arg direction="in" name="service" type="s"/></method>
    \\    <method name="RegisterStatusNotifierHost"><arg direction="in" name="service" type="s"/></method>
    \\    <property name="RegisteredStatusNotifierItems" type="as" access="read"/>
    \\    <property name="IsStatusNotifierHostRegistered" type="b" access="read"/>
    \\    <property name="ProtocolVersion" type="i" access="read"/>
    \\    <signal name="StatusNotifierItemRegistered"><arg type="s"/></signal>
    \\    <signal name="StatusNotifierItemUnregistered"><arg type="s"/></signal>
    \\    <signal name="StatusNotifierHostRegistered"/>
    \\  </interface>
    \\</node>
;

extern fn g_variant_lookup_value(dict: *glib.Variant, key: [*:0]const u8, expected: ?*const anyopaque) ?*glib.Variant;

const Status = enum { passive, active, attention };

const Item = struct {
    key: u64,
    service: [:0]u8,
    path: [:0]u8,
    watch_id: c_uint = 0,
    subscription: c_uint = 0,
    icon_name: ?[:0]u8 = null,
    texture: ?*gdk.Texture = null,
    title: ?[:0]u8 = null,
    status: Status = .active,
    menu_path: ?[:0]u8 = null,
};

pub const Tray = struct {
    allocator: std.mem.Allocator,
    owner_id: c_uint = 0,
    connection: ?*gio.DBusConnection = null,
    items: std.ArrayList(*Item) = .empty,
    /// One box per bar; every one shows the same icons.
    boxes: std.ArrayList(*gtk.Box) = .empty,
    next_key: u64 = 1,
    /// The item whose menu is open, for sending the chosen entry back.
    menu_key: u64 = 0,
    menu_target_path: ?[:0]u8 = null,

    pub fn create(allocator: std.mem.Allocator) ?*Tray {
        if (glib.getenv("DBUS_SESSION_BUS_ADDRESS") == null) return null;
        const self = allocator.create(Tray) catch return null;
        self.* = .{ .allocator = allocator };
        self.owner_id = gio.busOwnName(.session, watcher_name, .{}, onBusAcquired, onNameAcquired, onNameLost, self, null);
        return self;
    }

    pub fn destroy(self: *Tray) void {
        if (self.owner_id != 0) gio.busUnownName(self.owner_id);
        for (self.items.items) |item| self.freeItem(item);
        self.items.deinit(self.allocator);
        self.boxes.deinit(self.allocator);
        if (self.menu_target_path) |p| self.allocator.free(p);
        self.allocator.destroy(self);
    }

    /// Adds a bar's tray box; the icons appear in it at once.
    pub fn addBox(self: *Tray, box: *gtk.Box) void {
        self.boxes.append(self.allocator, box) catch return;
        self.populate(box);
    }

    pub fn removeBox(self: *Tray, box: *gtk.Box) void {
        for (self.boxes.items, 0..) |b, i| {
            if (b == box) {
                _ = self.boxes.orderedRemove(i);
                return;
            }
        }
    }

    // ---- the watcher ----------------------------------------------------------------

    fn onBusAcquired(connection: *gio.DBusConnection, _: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
        const self: *Tray = @ptrCast(@alignCast(data.?));
        self.connection = connection;
        var err: ?*glib.Error = null;
        const node = gio.DBusNodeInfo.newForXml(introspection, &err) orelse {
            if (err) |e| e.free();
            return;
        };
        const iface = node.lookupInterface(watcher_name) orelse return;
        const vtable = struct {
            var table: gio.DBusInterfaceVTable = .{
                .f_method_call = onMethodCall,
                .f_get_property = onGetProperty,
                .f_set_property = null,
                .f_padding = undefined,
            };
        };
        if (connection.registerObject(watcher_path, iface, &vtable.table, self, noopFree, &err) == 0) {
            if (err) |e| {
                std.log.warn("cannot register the tray watcher: {s}", .{e.f_message orelse "unknown error"});
                e.free();
            }
        }
    }

    fn noopFree(_: ?*anyopaque) callconv(.c) void {}

    fn onNameAcquired(connection: *gio.DBusConnection, _: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
        _ = data;
        // We are the host as soon as we own the watcher.
        _ = connection.emitSignal(null, watcher_path, watcher_name, "StatusNotifierHostRegistered", null, null);
        std.log.info("tray: ready", .{});
    }

    fn onNameLost(_: *gio.DBusConnection, _: [*:0]const u8, _: ?*anyopaque) callconv(.c) void {
        std.log.info("tray: another watcher owns the name, or there is no bus", .{});
    }

    fn onMethodCall(
        _: *gio.DBusConnection,
        sender: ?[*:0]const u8,
        _: [*:0]const u8,
        _: ?[*:0]const u8,
        method: [*:0]const u8,
        parameters: *glib.Variant,
        invocation: *gio.DBusMethodInvocation,
        data: ?*anyopaque,
    ) callconv(.c) void {
        const self: *Tray = @ptrCast(@alignCast(data.?));
        const name = std.mem.span(method);
        if (std.mem.eql(u8, name, "RegisterStatusNotifierItem")) {
            const arg = parameters.getChildValue(0);
            defer arg.unref();
            self.register(std.mem.span(arg.getString(null)), if (sender) |s| std.mem.span(s) else "");
        } else if (!std.mem.eql(u8, name, "RegisterStatusNotifierHost")) {
            invocation.returnErrorLiteral(glib.quarkFromString("dkde-tray"), 0, "unknown method");
            return;
        }
        invocation.returnValue(glib.Variant.newTuple(&[_]*glib.Variant{}, 0));
    }

    fn onGetProperty(
        _: *gio.DBusConnection,
        _: ?[*:0]const u8,
        _: [*:0]const u8,
        _: [*:0]const u8,
        property: [*:0]const u8,
        _: **glib.Error,
        data: ?*anyopaque,
    ) callconv(.c) ?*glib.Variant {
        const self: *Tray = @ptrCast(@alignCast(data.?));
        const name = std.mem.span(property);
        if (std.mem.eql(u8, name, "IsStatusNotifierHostRegistered")) return glib.Variant.newBoolean(1);
        if (std.mem.eql(u8, name, "ProtocolVersion")) return glib.Variant.newInt32(0);
        if (std.mem.eql(u8, name, "RegisteredStatusNotifierItems")) {
            const a = std.heap.c_allocator;
            var names: std.ArrayList(?[*:0]const u8) = .empty;
            defer names.deinit(a);
            var strings: std.ArrayList([:0]u8) = .empty;
            defer {
                for (strings.items) |s| a.free(s);
                strings.deinit(a);
            }
            for (self.items.items) |item| {
                const text = std.fmt.allocPrintSentinel(a, "{s}{s}", .{ item.service, item.path }, 0) catch continue;
                strings.append(a, text) catch continue;
                names.append(a, text.ptr) catch continue;
            }
            return glib.Variant.newStrv(names.items.ptr, @intCast(names.items.len));
        }
        return null;
    }

    // ---- items ------------------------------------------------------------------------

    /// `service` is a bus name, optionally followed by the object path; some apps
    /// register only an object path, in which case the sender is the bus name.
    fn register(self: *Tray, service: []const u8, sender: []const u8) void {
        var bus: []const u8 = service;
        var path: []const u8 = default_item_path;
        if (service.len > 0 and service[0] == '/') {
            bus = sender;
            path = service;
        } else if (std.mem.indexOfScalar(u8, service, '/')) |slash| {
            bus = service[0..slash];
            path = service[slash..];
        }
        if (bus.len == 0) return;
        for (self.items.items) |item| {
            if (std.mem.eql(u8, item.service, bus) and std.mem.eql(u8, item.path, path)) return;
        }
        const item = self.allocator.create(Item) catch return;
        item.* = .{
            .key = self.next_key,
            .service = self.allocator.dupeSentinel(u8, bus, 0) catch return,
            .path = self.allocator.dupeSentinel(u8, path, 0) catch return,
        };
        self.next_key += 1;
        self.items.append(self.allocator, item) catch return;

        const connection = self.connection orelse return;
        const key_ptr: ?*anyopaque = @ptrFromInt(item.key);
        item.watch_id = gio.busWatchNameOnConnection(connection, item.service, .{}, null, onVanished, self, null);
        _ = key_ptr;
        item.subscription = connection.signalSubscribe(item.service, item_interface, null, item.path, null, .{}, onItemSignal, self, null);
        self.fetch(item);

        var buf: [320]u8 = undefined;
        const full = std.fmt.bufPrintSentinel(&buf, "{s}{s}", .{ item.service, item.path }, 0) catch return;
        var children = [_]*glib.Variant{glib.Variant.newString(full)};
        _ = connection.emitSignal(null, watcher_path, watcher_name, "StatusNotifierItemRegistered", glib.Variant.newTuple(&children, 1), null);
    }

    fn find(self: *Tray, key: u64) ?*Item {
        for (self.items.items) |item| if (item.key == key) return item;
        return null;
    }

    fn findByService(self: *Tray, service: []const u8, path: []const u8) ?*Item {
        for (self.items.items) |item| {
            if (std.mem.eql(u8, item.service, service) and std.mem.eql(u8, item.path, path)) return item;
        }
        return null;
    }

    fn freeItem(self: *Tray, item: *Item) void {
        if (self.connection) |c| if (item.subscription != 0) c.signalUnsubscribe(item.subscription);
        if (item.watch_id != 0) gio.busUnwatchName(item.watch_id);
        self.allocator.free(item.service);
        self.allocator.free(item.path);
        if (item.icon_name) |n| self.allocator.free(n);
        if (item.title) |n| self.allocator.free(n);
        if (item.menu_path) |n| self.allocator.free(n);
        if (item.texture) |t| t.as(gobject.Object).unref();
        self.allocator.destroy(item);
    }

    /// The app (or the bus connection that registered) went away.
    fn onVanished(_: *gio.DBusConnection, name: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
        const self: *Tray = @ptrCast(@alignCast(data.?));
        const gone = std.mem.span(name);
        var i: usize = 0;
        var changed = false;
        while (i < self.items.items.len) {
            const item = self.items.items[i];
            if (!std.mem.eql(u8, item.service, gone)) {
                i += 1;
                continue;
            }
            _ = self.items.orderedRemove(i);
            if (self.connection) |c| {
                var buf: [320]u8 = undefined;
                if (std.fmt.bufPrintSentinel(&buf, "{s}{s}", .{ item.service, item.path }, 0)) |full| {
                    var children = [_]*glib.Variant{glib.Variant.newString(full)};
                    _ = c.emitSignal(null, watcher_path, watcher_name, "StatusNotifierItemUnregistered", glib.Variant.newTuple(&children, 1), null);
                } else |_| {}
            }
            self.freeItem(item);
            changed = true;
        }
        if (changed) self.rebuildAll();
    }

    /// NewIcon, NewTitle, NewStatus and friends: read the properties again.
    fn onItemSignal(
        _: *gio.DBusConnection,
        sender: ?[*:0]const u8,
        path: [*:0]const u8,
        _: [*:0]const u8,
        _: [*:0]const u8,
        _: *glib.Variant,
        data: ?*anyopaque,
    ) callconv(.c) void {
        const self: *Tray = @ptrCast(@alignCast(data.?));
        // The sender of a signal is the unique name; items are keyed by the
        // name they registered, so match on the path and refresh them all.
        _ = sender;
        for (self.items.items) |item| {
            if (std.mem.eql(u8, item.path, std.mem.span(path))) self.fetch(item);
        }
    }

    // ---- properties -----------------------------------------------------------------------

    const Request = struct { tray: *Tray, key: u64 };

    fn fetch(self: *Tray, item: *Item) void {
        const connection = self.connection orelse return;
        const request = self.allocator.create(Request) catch return;
        request.* = .{ .tray = self, .key = item.key };
        var children = [_]*glib.Variant{glib.Variant.newString(item_interface)};
        const reply_type = glib.VariantType.new("(a{sv})");
        defer reply_type.free();
        connection.call(item.service, item.path, "org.freedesktop.DBus.Properties", "GetAll", glib.Variant.newTuple(&children, 1), reply_type, .{}, 5000, null, onProperties, request);
    }

    fn onProperties(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const request: *Request = @ptrCast(@alignCast(data.?));
        const self = request.tray;
        const key = request.key;
        self.allocator.destroy(request);
        const connection: *gio.DBusConnection = @ptrCast(@alignCast(source.?));
        var err: ?*glib.Error = null;
        const reply = connection.callFinish(result, &err) orelse {
            if (err) |e| e.free();
            return;
        };
        defer reply.unref();
        const item = self.find(key) orelse return;
        const dict = reply.getChildValue(0);
        defer dict.unref();

        item.status = .active;
        if (stringProp(dict, "Status")) |s| {
            defer glib.free(s.ptr);
            if (std.mem.eql(u8, s, "Passive")) item.status = .passive;
            if (std.mem.eql(u8, s, "NeedsAttention")) item.status = .attention;
        }
        const icon_key: [*:0]const u8 = if (item.status == .attention) "AttentionIconName" else "IconName";
        self.setString(&item.icon_name, stringProp(dict, icon_key));
        if (item.icon_name != null and item.icon_name.?.len == 0 and item.status == .attention) {
            self.setString(&item.icon_name, stringProp(dict, "IconName"));
        }
        self.setString(&item.title, stringProp(dict, "Title"));
        self.setString(&item.menu_path, stringProp(dict, "Menu"));
        if (item.texture) |t| t.as(gobject.Object).unref();
        item.texture = null;
        if (item.icon_name == null or item.icon_name.?.len == 0) item.texture = pixmapProp(dict);
        self.rebuildAll();
        // Dev aid: pop the first item's menu without a click, for screenshots.
        if (!debug_menu_shown and glib.getenv("DKDE_DEBUG_TRAY_MENU") != null and item.menu_path != null and self.boxes.items.len > 0) {
            debug_menu_shown = true;
            self.openMenu(item, self.boxes.items[0].as(gtk.Widget), 5, 5);
        }
    }

    var debug_menu_shown = false;

    /// A string (or object path) property as a copy from the glib allocator, so the
    /// caller frees it with `glib.free`; null when absent or of another type.
    fn stringProp(dict: *glib.Variant, key: [*:0]const u8) ?[:0]u8 {
        const value = g_variant_lookup_value(dict, key, null) orelse return null;
        defer value.unref();
        const type_string = std.mem.span(value.getTypeString());
        if (!std.mem.eql(u8, type_string, "s") and !std.mem.eql(u8, type_string, "o")) return null;
        const text = std.mem.span(value.getString(null));
        const copy: [*]u8 = @ptrCast(glib.malloc(text.len + 1) orelse return null);
        @memcpy(copy[0..text.len], text);
        copy[text.len] = 0;
        return copy[0..text.len :0];
    }

    /// Moves a glib-allocated string into an item field.
    fn setString(self: *Tray, field: *?[:0]u8, value: ?[:0]u8) void {
        if (field.*) |old| self.allocator.free(old);
        field.* = null;
        const v = value orelse return;
        defer glib.free(v.ptr);
        field.* = self.allocator.dupeSentinel(u8, v, 0) catch null;
    }

    /// `IconPixmap` is a(iiay): width, height and ARGB32 bytes (network order).
    fn pixmapProp(dict: *glib.Variant) ?*gdk.Texture {
        const value = g_variant_lookup_value(dict, "IconPixmap", null) orelse return null;
        defer value.unref();
        const count = value.nChildren();
        if (count == 0) return null;
        // The largest one up to 64 pixels; the bar scales it down.
        var best: ?*glib.Variant = null;
        var best_size: i32 = 0;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const entry = value.getChildValue(i);
            const w = entry.getChildValue(0);
            const size = w.getInt32();
            w.unref();
            if (size <= 64 and size > best_size) {
                if (best) |b| b.unref();
                best = entry;
                best_size = size;
            } else entry.unref();
        }
        const entry = best orelse return null;
        defer entry.unref();
        const wv = entry.getChildValue(0);
        defer wv.unref();
        const hv = entry.getChildValue(1);
        defer hv.unref();
        const bytes = entry.getChildValue(2);
        defer bytes.unref();
        const width = wv.getInt32();
        const height = hv.getInt32();
        var n: usize = 0;
        const raw: [*]const u8 = @ptrCast(bytes.getFixedArray(&n, 1));
        if (width <= 0 or height <= 0 or n < @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4) return null;
        const gbytes = glib.Bytes.new(raw, n);
        defer gbytes.unref();
        const texture = gdk.MemoryTexture.new(width, height, .a8r8g8b8, gbytes, @as(usize, @intCast(width)) * 4);
        return @ptrCast(texture);
    }

    // ---- the icons -----------------------------------------------------------------------------

    fn rebuildAll(self: *Tray) void {
        for (self.boxes.items) |box| self.populate(box);
    }

    fn populate(self: *Tray, box: *gtk.Box) void {
        while (box.as(gtk.Widget).getFirstChild()) |child| box.remove(child);
        for (self.items.items) |item| {
            if (item.status == .passive) continue;
            const image = gtk.Image.new();
            image.setPixelSize(20);
            if (item.icon_name) |name| {
                if (name.len > 0) {
                    if (name[0] == '/') image.setFromFile(name) else image.setFromIconName(name);
                }
            }
            if (item.texture) |t| image.setFromPaintable(@ptrCast(t));
            if (item.icon_name == null and item.texture == null) image.setFromIconName("application-x-executable");

            const holder = gtk.Box.new(.horizontal, 0);
            holder.as(gtk.Widget).addCssClass("dkde-tray-item");
            if (item.status == .attention) holder.as(gtk.Widget).addCssClass("attention");
            holder.append(image.as(gtk.Widget));
            if (item.title) |t| holder.as(gtk.Widget).setTooltipText(t);

            const click = gtk.GestureClick.new();
            click.as(gtk.GestureSingle).setButton(0);
            const ctx = self.allocator.create(Click) catch continue;
            ctx.* = .{ .tray = self, .key = item.key };
            _ = gtk.GestureClick.signals.pressed.connect(click, *Click, &onClick, ctx, .{});
            _ = gtk.Widget.signals.destroy.connect(holder, *Click, &onClickDestroy, ctx, .{});
            holder.as(gtk.Widget).addController(click.as(gtk.EventController));
            box.append(holder.as(gtk.Widget));
        }
        box.as(gtk.Widget).setVisible(@intFromBool(box.as(gtk.Widget).getFirstChild() != null));
    }

    const Click = struct { tray: *Tray, key: u64 };

    fn onClickDestroy(_: *gtk.Box, ctx: *Click) callconv(.c) void {
        ctx.tray.allocator.destroy(ctx);
    }

    fn onClick(gesture: *gtk.GestureClick, _: c_int, x: f64, y: f64, ctx: *Click) callconv(.c) void {
        const self = ctx.tray;
        const item = self.find(ctx.key) orelse return;
        const connection = self.connection orelse return;
        const button = gesture.as(gtk.GestureSingle).getCurrentButton();
        const widget = gesture.as(gtk.EventController).getWidget() orelse return;
        switch (button) {
            1 => self.invoke(connection, item, "Activate"),
            2 => self.invoke(connection, item, "SecondaryActivate"),
            3 => {
                if (item.menu_path) |menu| if (menu.len > 1) return self.openMenu(item, widget, x, y);
                self.invoke(connection, item, "ContextMenu");
            },
            else => {},
        }
    }

    /// Wayland gives a client no screen coordinates, so zeros go to the app.
    fn invoke(_: *Tray, connection: *gio.DBusConnection, item: *Item, method: [*:0]const u8) void {
        var args = [_]*glib.Variant{ glib.Variant.newInt32(0), glib.Variant.newInt32(0) };
        connection.call(item.service, item.path, item_interface, method, glib.Variant.newTuple(&args, 2), null, .{}, 5000, null, null, null);
    }

    // ---- the app's menu (com.canonical.dbusmenu) -------------------------------------------------

    const MenuRequest = struct { tray: *Tray, key: u64, widget: *gtk.Widget, x: f64, y: f64 };

    fn openMenu(self: *Tray, item: *Item, widget: *gtk.Widget, x: f64, y: f64) void {
        const connection = self.connection orelse return;
        const menu = item.menu_path orelse return;
        const request = self.allocator.create(MenuRequest) catch return;
        request.* = .{ .tray = self, .key = item.key, .widget = widget, .x = x, .y = y };
        // Some apps build their menu lazily; ask for it to be ready, then fetch.
        var about = [_]*glib.Variant{glib.Variant.newInt32(0)};
        connection.call(item.service, menu, "com.canonical.dbusmenu", "AboutToShow", glib.Variant.newTuple(&about, 1), null, .{}, 2000, null, null, null);

        var args = [_]*glib.Variant{
            glib.Variant.newInt32(0),
            glib.Variant.newInt32(-1),
            glib.Variant.newStrv(&[_]?[*:0]const u8{}, 0),
        };
        const reply_type = glib.VariantType.new("(u(ia{sv}av))");
        defer reply_type.free();
        connection.call(item.service, menu, "com.canonical.dbusmenu", "GetLayout", glib.Variant.newTuple(&args, 3), reply_type, .{}, 5000, null, onLayout, request);
    }

    const Entry = struct { label: [:0]u8, id: i32, enabled: bool };

    fn onLayout(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const request: *MenuRequest = @ptrCast(@alignCast(data.?));
        const self = request.tray;
        defer self.allocator.destroy(request);
        const connection: *gio.DBusConnection = @ptrCast(@alignCast(source.?));
        var err: ?*glib.Error = null;
        const reply = connection.callFinish(result, &err) orelse {
            if (err) |e| e.free();
            return;
        };
        defer reply.unref();
        const item = self.find(request.key) orelse return;

        var entries: std.ArrayList(Entry) = .empty;
        defer {
            for (entries.items) |e| self.allocator.free(e.label);
            entries.deinit(self.allocator);
        }
        const root = reply.getChildValue(1);
        defer root.unref();
        self.collect(root, 0, &entries);
        if (entries.items.len == 0) return;

        var items: std.ArrayList(common.contextmenu.Item) = .empty;
        defer items.deinit(self.allocator);
        for (entries.items) |e| items.append(self.allocator, .{ .label = e.label, .id = @intCast(e.id), .enabled = e.enabled }) catch return;

        self.menu_key = item.key;
        if (self.menu_target_path) |p| self.allocator.free(p);
        self.menu_target_path = self.allocator.dupeSentinel(u8, item.menu_path orelse return, 0) catch null;
        common.contextmenu.show(request.widget, request.x, request.y, items.items, Tray, onMenuChosen, self);
    }

    /// Flattens a dbusmenu layout `(ia{sv}av)` into entries; submenus are
    /// indented under their parent. Separators and hidden entries are skipped.
    fn collect(self: *Tray, node: *glib.Variant, depth: usize, out: *std.ArrayList(Entry)) void {
        const id_value = node.getChildValue(0);
        defer id_value.unref();
        const props = node.getChildValue(1);
        defer props.unref();
        const children = node.getChildValue(2);
        defer children.unref();

        if (depth > 0) self.addEntry(id_value.getInt32(), props, depth, out);
        const count = children.nChildren();
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const boxed = children.getChildValue(i);
            defer boxed.unref();
            const child = boxed.getVariant();
            defer child.unref();
            self.collect(child, depth + 1, out);
        }
    }

    fn addEntry(self: *Tray, id: i32, props: *glib.Variant, depth: usize, out: *std.ArrayList(Entry)) void {
        if (g_variant_lookup_value(props, "visible", null)) |v| {
            defer v.unref();
            if (v.getBoolean() == 0) return;
        }
        if (stringProp(props, "type")) |t| {
            defer glib.free(t.ptr);
            if (std.mem.eql(u8, t, "separator")) return;
        }
        const raw = stringProp(props, "label") orelse return;
        defer glib.free(raw.ptr);
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(self.allocator);
        for (0..(depth -| 1)) |_| text.appendSlice(self.allocator, "    ") catch return;
        // A single underscore marks the mnemonic and "__" is a literal one.
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            if (raw[i] == '_') {
                if (i + 1 < raw.len and raw[i + 1] == '_') {
                    text.append(self.allocator, '_') catch return;
                    i += 1;
                }
                continue;
            }
            text.append(self.allocator, raw[i]) catch return;
        }
        var enabled = true;
        if (g_variant_lookup_value(props, "enabled", null)) |v| {
            defer v.unref();
            enabled = v.getBoolean() != 0;
        }
        const label = self.allocator.dupeSentinel(u8, text.items, 0) catch return;
        out.append(self.allocator, .{ .label = label, .id = id, .enabled = enabled }) catch self.allocator.free(label);
    }

    fn onMenuChosen(self: *Tray, id: usize) void {
        const connection = self.connection orelse return;
        const item = self.find(self.menu_key) orelse return;
        const path = self.menu_target_path orelse return;
        const zero = glib.Variant.newVariant(glib.Variant.newInt32(0));
        var args = [_]*glib.Variant{
            glib.Variant.newInt32(@intCast(id)),
            glib.Variant.newString("clicked"),
            zero,
            glib.Variant.newUint32(0),
        };
        connection.call(item.service, path, "com.canonical.dbusmenu", "Event", glib.Variant.newTuple(&args, 4), null, .{}, 5000, null, null, null);
    }
};
