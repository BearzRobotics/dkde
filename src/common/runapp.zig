//! The start-up every small dkde app shares: debug allocator, stylesheet,
//! appearance, a non-unique GApplication and one window. `Window` needs
//! `create(allocator, app) !*Window` and `present(*Window) void`.

const std = @import("std");
const gio = @import("gio2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");

const style = @import("style.zig");

pub fn run(comptime app_id: [:0]const u8, comptime Window: type, init: std.process.Init.Minimal) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();

    const State = struct {
        allocator: std.mem.Allocator,
        appearance: ?*style.Appearance = null,

        fn activate(app: *gtk.Application, self: *@This()) callconv(.c) void {
            style.load(self.allocator) catch |err|
                std.log.warn("stylesheet not loaded: {s}", .{@errorName(err)});
            self.appearance = style.Appearance.create(self.allocator) catch null;
            const window = Window.create(self.allocator, app) catch |err| {
                std.log.err("cannot create the window: {s}", .{@errorName(err)});
                return;
            };
            window.present();
        }
    };

    var state: State = .{ .allocator = debug_allocator.allocator() };
    defer if (state.appearance) |a| a.destroy();

    const gtk_app = gtk.Application.new(app_id, .{ .non_unique = true });
    defer gtk_app.as(gobject.Object).unref();
    _ = gio.Application.signals.activate.connect(gtk_app, *State, &State.activate, &state, .{});
    // Apps read their own arguments; GTK must not reject them as unknown options.
    var argv = [_]?[*:0]const u8{ init.args.vector[0], null };
    const status = gio.Application.run(gtk_app.as(gio.Application), 1, @ptrCast(&argv));
    if (status != 0) std.process.exit(@intCast(status));
}
