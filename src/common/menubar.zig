//! Classic menu bars (File, Edit, View, ...) for every dkde app. Menus are
//! described as plain data; choosing an item calls one callback with the
//! action's name, so each app keeps a single `perform(name)` for menus,
//! shortcuts and buttons alike.

const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");

pub const Item = struct {
    label: [:0]const u8,
    /// Name passed to the callback; also the action's name under `win.`.
    action: [:0]const u8,
    /// Shown beside the label and registered as a shortcut, e.g. "<Control>s".
    accel: ?[:0]const u8 = null,
    /// Makes the item a check mark with this initial state.
    toggle: ?bool = null,
};

pub const Entry = union(enum) {
    item: Item,
    /// A line between groups of items.
    separator,
};

pub const Menu = struct {
    label: [:0]const u8,
    entries: []const Entry,
};

pub fn item(label: [:0]const u8, action: [:0]const u8, accel: ?[:0]const u8) Entry {
    return .{ .item = .{ .label = label, .action = action, .accel = accel } };
}

pub fn check(label: [:0]const u8, action: [:0]const u8, initial: bool) Entry {
    return .{ .item = .{ .label = label, .action = action, .toggle = initial } };
}

/// Builds the bar, registers one `win.<action>` per item and returns the
/// widget to place above the window's content. `callback(data, name)` runs
/// when an item is chosen (for a check item, after its state flipped).
pub fn build(
    app: *gtk.Application,
    window: *gtk.ApplicationWindow,
    menus: []const Menu,
    comptime Data: type,
    callback: *const fn (*Data, []const u8) void,
    data: *Data,
) *gtk.PopoverMenuBar {
    const model = gio.Menu.new();
    defer model.as(gobject.Object).unref();

    const Ctx = struct {
        callback: *const fn (*Data, []const u8) void,
        data: *Data,
        name: [:0]const u8,
        toggle: bool,

        fn onActivate(action: *gio.SimpleAction, _: ?*glib.Variant, ctx: *@This()) callconv(.c) void {
            if (ctx.toggle) {
                // A check item: flip its state, then tell the app.
                const state = action.as(gio.Action).getState();
                const now = if (state) |s| s.getBoolean() != 0 else false;
                action.setState(glib.Variant.newBoolean(@intFromBool(!now)));
            }
            ctx.callback(ctx.data, ctx.name);
        }
    };

    for (menus) |menu| {
        const section = gio.Menu.new();
        defer section.as(gobject.Object).unref();
        var group = gio.Menu.new();
        defer group.as(gobject.Object).unref();

        for (menu.entries) |entry| switch (entry) {
            .separator => {
                section.appendSection(null, group.as(gio.MenuModel));
                group.as(gobject.Object).unref();
                group = gio.Menu.new();
            },
            .item => |it| {
                var detailed_buf: [96]u8 = undefined;
                const detailed = std.fmt.bufPrintSentinel(&detailed_buf, "win.{s}", .{it.action}, 0) catch continue;
                group.append(it.label, detailed);

                const action = if (it.toggle) |initial|
                    gio.SimpleAction.newStateful(it.action, null, glib.Variant.newBoolean(@intFromBool(initial)))
                else
                    gio.SimpleAction.new(it.action, null);
                const ctx = std.heap.c_allocator.create(Ctx) catch continue;
                ctx.* = .{ .callback = callback, .data = data, .name = it.action, .toggle = it.toggle != null };
                _ = gio.SimpleAction.signals.activate.connect(action, *Ctx, &Ctx.onActivate, ctx, .{});
                window.as(gio.ActionMap).addAction(action.as(gio.Action));
                action.as(gobject.Object).unref();

                if (it.accel) |accel| {
                    const accels = [_:null]?[*:0]const u8{accel.ptr};
                    app.setAccelsForAction(detailed, &accels);
                }
            },
        };
        section.appendSection(null, group.as(gio.MenuModel));
        model.appendSubmenu(menu.label, section.as(gio.MenuModel));
    }

    const bar = gtk.PopoverMenuBar.newFromModel(model.as(gio.MenuModel));
    bar.as(gtk.Widget).addCssClass("dkde-menubar");
    return bar;
}

/// Sets a check item's state without triggering the callback.
pub fn setChecked(window: *gtk.ApplicationWindow, action: [:0]const u8, on: bool) void {
    const found = window.as(gio.ActionMap).lookupAction(action) orelse return;
    const simple: *gio.SimpleAction = @ptrCast(@alignCast(found));
    simple.setState(glib.Variant.newBoolean(@intFromBool(on)));
}

/// Enables or disables an item.
pub fn setEnabled(window: *gtk.ApplicationWindow, action: [:0]const u8, enabled: bool) void {
    const found = window.as(gio.ActionMap).lookupAction(action) orelse return;
    const simple: *gio.SimpleAction = @ptrCast(@alignCast(found));
    simple.setEnabled(@intFromBool(enabled));
}
