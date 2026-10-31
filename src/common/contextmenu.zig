//! A small popup menu of text items, used for the right-click menus of the
//! panel and the start menu (SPEC.md 5.7).

const std = @import("std");
const glib = @import("glib2");
const gdk = @import("gdk4");
const gobject = @import("gobject2");
const gtk = @import("gtk4");

pub const Item = struct {
    label: [:0]const u8,
    /// Passed back to the callback.
    id: usize,
    enabled: bool = true,
};

/// Pops up `items` next to (`x`, `y`) in `parent`. `callback(data, id)` runs
/// when one is chosen. The popup frees itself when it closes.
pub fn show(
    parent: *gtk.Widget,
    x: f64,
    y: f64,
    items: []const Item,
    comptime Data: type,
    callback: *const fn (*Data, usize) void,
    data: *Data,
) void {
    const popover = gtk.Popover.new();
    popover.as(gtk.Widget).addCssClass("dkde-context-menu");
    popover.as(gtk.Widget).setParent(parent);
    popover.setHasArrow(0);
    const rect: gdk.Rectangle = .{ .f_x = @intFromFloat(x), .f_y = @intFromFloat(y), .f_width = 1, .f_height = 1 };
    popover.setPointingTo(&rect);
    _ = gtk.Popover.signals.closed.connect(popover, *gtk.Popover, &onClosed, popover, .{});

    const box = gtk.Box.new(.vertical, 0);
    popover.setChild(box.as(gtk.Widget));

    const Ctx = struct {
        popover: *gtk.Popover,
        callback: *const fn (*Data, usize) void,
        data: *Data,
        id: usize,

        fn onClicked(_: *gtk.Button, ctx: *@This()) callconv(.c) void {
            ctx.popover.popdown();
            ctx.callback(ctx.data, ctx.id);
        }

        fn onDestroy(_: *gtk.Button, ctx: *@This()) callconv(.c) void {
            std.heap.c_allocator.destroy(ctx);
        }
    };

    for (items) |item| {
        const button = gtk.Button.newWithLabel(item.label);
        button.setHasFrame(0);
        button.as(gtk.Widget).setSensitive(@intFromBool(item.enabled));
        if (button.getChild()) |child| {
            const label: *gtk.Label = @ptrCast(@alignCast(child));
            label.setXalign(0);
        }
        const ctx = std.heap.c_allocator.create(Ctx) catch return;
        ctx.* = .{ .popover = popover, .callback = callback, .data = data, .id = item.id };
        _ = gtk.Button.signals.clicked.connect(button, *Ctx, &Ctx.onClicked, ctx, .{});
        _ = gtk.Widget.signals.destroy.connect(button, *Ctx, &Ctx.onDestroy, ctx, .{});
        box.append(button.as(gtk.Widget));
    }
    popover.popup();
}

fn onClosed(_: *gtk.Popover, popover: *gtk.Popover) callconv(.c) void {
    // Unparenting inside the signal can crash GTK; wait for idle.
    _ = glib.idleAdd(unparentIdle, popover);
}

fn unparentIdle(data: ?*anyopaque) callconv(.c) c_int {
    const popover: *gtk.Popover = @ptrCast(@alignCast(data.?));
    popover.as(gtk.Widget).unparent();
    return 0;
}
