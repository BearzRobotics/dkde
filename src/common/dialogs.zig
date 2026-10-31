//! Error and confirmation dialogs shared by every component (SPEC.md 4.2).
//! Errors are shown only here, at the UI boundary (SPEC.md 6.4).

const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");

/// Shows `message` with an OK button. Both strings are copied by GTK.
pub fn showError(parent: ?*gtk.Window, message: [:0]const u8, detail: ?[:0]const u8) void {
    const dialog = gtk.AlertDialog.new("%s", message.ptr);
    defer dialog.as(gobject.Object).unref();
    if (detail) |d| dialog.setDetail(d);
    dialog.show(parent);
}

/// Asks the user to pick one of `buttons`; `callback(data, index)` runs with
/// the chosen index, or -1 when the dialog was dismissed.
pub fn choose(
    parent: ?*gtk.Window,
    message: [:0]const u8,
    detail: ?[:0]const u8,
    buttons: []const [*:0]const u8,
    cancel_index: c_int,
    comptime Data: type,
    callback: *const fn (*Data, c_int) void,
    data: *Data,
) void {
    const dialog = gtk.AlertDialog.new("%s", message.ptr);
    defer dialog.as(gobject.Object).unref();
    if (detail) |d| dialog.setDetail(d);

    // GTK wants a NULL-terminated array.
    var terminated: [8]?[*:0]const u8 = @splat(null);
    std.debug.assert(buttons.len < terminated.len);
    for (buttons, 0..) |b, i| terminated[i] = b;
    dialog.setButtons(@ptrCast(&terminated));
    dialog.setCancelButton(cancel_index);
    dialog.setDefaultButton(if (cancel_index == 0) 1 else 0);

    const Ctx = struct {
        callback: *const fn (*Data, c_int) void,
        data: *Data,

        fn finish(source: ?*gobject.Object, result: *gio.AsyncResult, raw: ?*anyopaque) callconv(.c) void {
            const ctx: *@This() = @ptrCast(@alignCast(raw.?));
            defer std.heap.c_allocator.destroy(ctx);
            const self: *gtk.AlertDialog = @ptrCast(@alignCast(source.?));
            var err: ?*glib.Error = null;
            const index = self.chooseFinish(result, &err);
            if (err) |e| e.free();
            ctx.callback(ctx.data, index);
        }
    };
    const ctx = std.heap.c_allocator.create(Ctx) catch return;
    ctx.* = .{ .callback = callback, .data = data };
    dialog.choose(parent, null, Ctx.finish, ctx);
}
