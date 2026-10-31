//! Desktop notifications (SPEC.md 5.1): the panel owns
//! `org.freedesktop.Notifications` on the session bus, when there is one,
//! and shows each notification as a toast in the top-right corner. It speaks
//! the Desktop Notifications Specification 1.2 through GIO's GDBus.
//! Supported: summary, body (markup is reduced to plain text), icon,
//! replacing a notification, expiry, closing by click. Actions are not.

const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");

const common = @import("common");

const surface = @import("surface.zig");

const bus_name = "org.freedesktop.Notifications";
const object_path = "/org/freedesktop/Notifications";

const introspection =
    \\<node>
    \\  <interface name="org.freedesktop.Notifications">
    \\    <method name="GetCapabilities"><arg direction="out" name="capabilities" type="as"/></method>
    \\    <method name="Notify">
    \\      <arg direction="in" name="app_name" type="s"/>
    \\      <arg direction="in" name="replaces_id" type="u"/>
    \\      <arg direction="in" name="app_icon" type="s"/>
    \\      <arg direction="in" name="summary" type="s"/>
    \\      <arg direction="in" name="body" type="s"/>
    \\      <arg direction="in" name="actions" type="as"/>
    \\      <arg direction="in" name="hints" type="a{sv}"/>
    \\      <arg direction="in" name="expire_timeout" type="i"/>
    \\      <arg direction="out" name="id" type="u"/>
    \\    </method>
    \\    <method name="CloseNotification"><arg direction="in" name="id" type="u"/></method>
    \\    <method name="GetServerInformation">
    \\      <arg direction="out" name="name" type="s"/>
    \\      <arg direction="out" name="vendor" type="s"/>
    \\      <arg direction="out" name="version" type="s"/>
    \\      <arg direction="out" name="spec_version" type="s"/>
    \\    </method>
    \\    <signal name="NotificationClosed">
    \\      <arg name="id" type="u"/>
    \\      <arg name="reason" type="u"/>
    \\    </signal>
    \\  </interface>
    \\</node>
;

const default_timeout_ms = 6000;
const max_visible = 5;

/// Why a notification closed, as the specification numbers them.
const Reason = enum(u32) { expired = 1, dismissed = 2, closed = 3 };

const Toast = struct {
    owner: *Notifications,
    id: u32,
    widget: *gtk.Box,
    icon: *gtk.Image,
    summary: *gtk.Label,
    body: *gtk.Label,
    timer: c_uint = 0,
};

pub const Notifications = struct {
    allocator: std.mem.Allocator,
    owner_id: c_uint = 0,
    connection: ?*gio.DBusConnection = null,
    window: ?*gtk.Window = null,
    stack: ?*gtk.Box = null,
    toasts: std.ArrayList(*Toast) = .empty,
    next_id: u32 = 1,

    /// Starts owning the name. With no session bus, GIO reports the name as
    /// lost and nothing else happens.
    pub fn create(allocator: std.mem.Allocator) ?*Notifications {
        if (surface.isX11()) return null; // the toast surface needs layer-shell
        if (glib.getenv("DBUS_SESSION_BUS_ADDRESS") == null) {
            std.log.info("no session bus: notifications are off", .{});
            return null;
        }
        const self = allocator.create(Notifications) catch return null;
        self.* = .{ .allocator = allocator };
        self.owner_id = gio.busOwnName(.session, bus_name, .{}, onBusAcquired, onNameAcquired, onNameLost, self, null);
        return self;
    }

    pub fn destroy(self: *Notifications) void {
        if (self.owner_id != 0) gio.busUnownName(self.owner_id);
        for (self.toasts.items) |t| {
            if (t.timer != 0) _ = glib.Source.remove(t.timer);
            self.allocator.destroy(t);
        }
        self.toasts.deinit(self.allocator);
        if (self.window) |w| w.destroy();
        self.allocator.destroy(self);
    }

    // ---- the bus ----------------------------------------------------------------

    fn onBusAcquired(connection: *gio.DBusConnection, _: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
        const self: *Notifications = @ptrCast(@alignCast(data.?));
        self.connection = connection;
        var err: ?*glib.Error = null;
        const node = gio.DBusNodeInfo.newForXml(introspection, &err) orelse {
            if (err) |e| e.free();
            return;
        };
        const iface = node.lookupInterface(bus_name) orelse return;
        const vtable = struct {
            var table: gio.DBusInterfaceVTable = .{
                .f_method_call = onMethodCall,
                .f_get_property = null,
                .f_set_property = null,
                .f_padding = undefined,
            };
        };
        if (connection.registerObject(object_path, iface, &vtable.table, self, noopFree, &err) == 0) {
            if (err) |e| {
                std.log.warn("cannot register notifications: {s}", .{e.f_message orelse "unknown error"});
                e.free();
            }
        }
    }

    fn noopFree(_: ?*anyopaque) callconv(.c) void {}

    fn onNameAcquired(_: *gio.DBusConnection, _: [*:0]const u8, _: ?*anyopaque) callconv(.c) void {
        std.log.info("notifications: ready", .{});
    }

    fn onNameLost(_: *gio.DBusConnection, _: [*:0]const u8, _: ?*anyopaque) callconv(.c) void {
        std.log.info("notifications: another daemon owns the name, or there is no bus", .{});
    }

    fn onMethodCall(
        _: *gio.DBusConnection,
        _: ?[*:0]const u8,
        _: [*:0]const u8,
        _: ?[*:0]const u8,
        method: [*:0]const u8,
        parameters: *glib.Variant,
        invocation: *gio.DBusMethodInvocation,
        data: ?*anyopaque,
    ) callconv(.c) void {
        const self: *Notifications = @ptrCast(@alignCast(data.?));
        const name = std.mem.span(method);
        if (std.mem.eql(u8, name, "GetCapabilities")) {
            const caps = [_]?[*:0]const u8{ "body", "icon-static" };
            const list = glib.Variant.newStrv(&caps, caps.len);
            var children = [_]*glib.Variant{list};
            invocation.returnValue(glib.Variant.newTuple(&children, 1));
        } else if (std.mem.eql(u8, name, "GetServerInformation")) {
            var children = [_]*glib.Variant{
                glib.Variant.newString("dkde-panel"),
                glib.Variant.newString("dkde"),
                glib.Variant.newString("0.1"),
                glib.Variant.newString("1.2"),
            };
            invocation.returnValue(glib.Variant.newTuple(&children, 4));
        } else if (std.mem.eql(u8, name, "CloseNotification")) {
            const arg = parameters.getChildValue(0);
            defer arg.unref();
            self.closeById(arg.getUint32(), .closed);
            invocation.returnValue(glib.Variant.newTuple(&[_]*glib.Variant{}, 0));
        } else if (std.mem.eql(u8, name, "Notify")) {
            const id = self.notify(parameters);
            var children = [_]*glib.Variant{glib.Variant.newUint32(id)};
            invocation.returnValue(glib.Variant.newTuple(&children, 1));
        } else {
            invocation.returnErrorLiteral(glib.quarkFromString("dkde-notifications"), 0, "unknown method");
        }
    }

    fn string(parameters: *glib.Variant, index: usize) [:0]u8 {
        const child = parameters.getChildValue(index);
        defer child.unref();
        return std.heap.c_allocator.dupeSentinel(u8, std.mem.span(child.getString(null)), 0) catch @panic("OOM");
    }

    // ---- toasts ---------------------------------------------------------------------

    fn notify(self: *Notifications, parameters: *glib.Variant) u32 {
        const a = std.heap.c_allocator;
        const icon = string(parameters, 2);
        defer a.free(icon);
        const summary = string(parameters, 3);
        defer a.free(summary);
        const body = string(parameters, 4);
        defer a.free(body);
        const replaces = blk: {
            const c = parameters.getChildValue(1);
            defer c.unref();
            break :blk c.getUint32();
        };
        const timeout = blk: {
            const c = parameters.getChildValue(7);
            defer c.unref();
            break :blk c.getInt32();
        };

        const plain = plainText(a, body) catch return 0;
        defer a.free(plain);

        self.ensureWindow();
        var toast: ?*Toast = null;
        if (replaces != 0) for (self.toasts.items) |t| if (t.id == replaces) {
            toast = t;
        };
        if (toast == null) {
            toast = self.addToast() orelse return 0;
        }
        const t = toast.?;
        if (t.timer != 0) {
            _ = glib.Source.remove(t.timer);
            t.timer = 0;
        }
        setIcon(t.icon, icon);
        t.summary.setText(summary);
        t.body.setText(plain);
        t.body.as(gtk.Widget).setVisible(@intFromBool(plain.len > 0));

        // -1: the server's default; 0: never expires.
        const ms: c_uint = if (timeout < 0) default_timeout_ms else @intCast(timeout);
        if (ms > 0) t.timer = glib.timeoutAdd(ms, onExpire, t);
        self.window.?.as(gtk.Widget).setVisible(1);
        return t.id;
    }

    fn ensureWindow(self: *Notifications) void {
        if (self.window != null) return;
        const window = gtk.Window.new();
        window.as(gtk.Widget).addCssClass("dkde-toasts");
        surface.setup(window, .{
            .name_space = "dkde-notifications",
            .layer = .overlay,
            .anchors = &.{ .top, .right },
            .exclusive_zone = 0,
        });
        const stack = gtk.Box.new(.vertical, 8);
        stack.as(gtk.Widget).setMarginTop(16);
        stack.as(gtk.Widget).setMarginEnd(16);
        stack.as(gtk.Widget).setMarginBottom(8);
        stack.as(gtk.Widget).setMarginStart(8);
        window.setChild(stack.as(gtk.Widget));
        self.window = window;
        self.stack = stack;
    }

    fn addToast(self: *Notifications) ?*Toast {
        // The oldest goes when the stack is full.
        if (self.toasts.items.len >= max_visible) self.closeById(self.toasts.items[0].id, .expired);

        const t = self.allocator.create(Toast) catch return null;
        const box = gtk.Box.new(.horizontal, 12);
        box.as(gtk.Widget).addCssClass("dkde-toast");
        box.as(gtk.Widget).setSizeRequest(340, -1);
        const icon = gtk.Image.new();
        icon.setPixelSize(40);
        icon.as(gtk.Widget).setValign(.start);
        const texts = gtk.Box.new(.vertical, 2);
        texts.as(gtk.Widget).setHexpand(1);
        const summary = gtk.Label.new("");
        summary.setXalign(0);
        summary.setWrap(1);
        summary.as(gtk.Widget).addCssClass("heading");
        const body = gtk.Label.new("");
        body.setXalign(0);
        body.setWrap(1);
        body.setMaxWidthChars(44);
        texts.append(summary.as(gtk.Widget));
        texts.append(body.as(gtk.Widget));
        box.append(icon.as(gtk.Widget));
        box.append(texts.as(gtk.Widget));

        t.* = .{ .owner = self, .id = self.next_id, .widget = box, .icon = icon, .summary = summary, .body = body };
        self.next_id +%= 1;
        if (self.next_id == 0) self.next_id = 1;

        const click = gtk.GestureClick.new();
        _ = gtk.GestureClick.signals.pressed.connect(click, *Toast, &onToastClick, t, .{});
        box.as(gtk.Widget).addController(click.as(gtk.EventController));
        self.stack.?.append(box.as(gtk.Widget));
        self.toasts.append(self.allocator, t) catch {
            self.allocator.destroy(t);
            return null;
        };
        return t;
    }

    fn setIcon(image: *gtk.Image, icon: []const u8) void {
        if (icon.len == 0) return image.setFromIconName("dialog-information");
        const z = std.heap.c_allocator.dupeSentinel(u8, std.mem.trimStart(u8, icon, "file://"), 0) catch return;
        defer std.heap.c_allocator.free(z);
        if (z.len > 0 and z[0] == '/') image.setFromFile(z) else image.setFromIconName(z);
    }

    fn onToastClick(_: *gtk.GestureClick, _: c_int, _: f64, _: f64, t: *Toast) callconv(.c) void {
        t.owner.closeById(t.id, .dismissed);
    }

    fn onExpire(data: ?*anyopaque) callconv(.c) c_int {
        const t: *Toast = @ptrCast(@alignCast(data.?));
        t.timer = 0;
        t.owner.closeById(t.id, .expired);
        return 0;
    }

    fn closeById(self: *Notifications, id: u32, reason: Reason) void {
        for (self.toasts.items, 0..) |t, i| {
            if (t.id != id) continue;
            if (t.timer != 0) _ = glib.Source.remove(t.timer);
            self.stack.?.remove(t.widget.as(gtk.Widget));
            _ = self.toasts.orderedRemove(i);
            self.allocator.destroy(t);
            if (self.toasts.items.len == 0) self.window.?.as(gtk.Widget).setVisible(0);
            self.emitClosed(id, reason);
            return;
        }
    }

    fn emitClosed(self: *Notifications, id: u32, reason: Reason) void {
        const connection = self.connection orelse return;
        var children = [_]*glib.Variant{ glib.Variant.newUint32(id), glib.Variant.newUint32(@backingInt(reason)) };
        _ = connection.emitSignal(null, object_path, bus_name, "NotificationClosed", glib.Variant.newTuple(&children, 2), null);
    }
};

/// Drops markup tags and decodes the five XML entities.
fn plainText(allocator: std.mem.Allocator, markup: []const u8) ![:0]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < markup.len) {
        const c = markup[i];
        if (c == '<') {
            const end = std.mem.indexOfScalarPos(u8, markup, i, '>') orelse markup.len - 1;
            // <br> and <br/> are line breaks; everything else just goes.
            if (std.mem.startsWith(u8, markup[i..], "<br")) try out.append(allocator, '\n');
            i = end + 1;
        } else if (c == '&') {
            const entities = [_][2][]const u8{ .{ "&amp;", "&" }, .{ "&lt;", "<" }, .{ "&gt;", ">" }, .{ "&quot;", "\"" }, .{ "&apos;", "'" } };
            var matched = false;
            for (entities) |e| if (std.mem.startsWith(u8, markup[i..], e[0])) {
                try out.appendSlice(allocator, e[1]);
                i += e[0].len;
                matched = true;
                break;
            };
            if (!matched) {
                try out.append(allocator, c);
                i += 1;
            }
        } else {
            try out.append(allocator, c);
            i += 1;
        }
    }
    return out.toOwnedSliceSentinel(allocator, 0);
}

test "markup is reduced to text" {
    const a = std.testing.allocator;
    const t = try plainText(a, "<b>Hi</b> &amp; bye<br/>x &lt;y&gt;");
    defer a.free(t);
    try std.testing.expectEqualStrings("Hi & bye\nx <y>", t);
}
