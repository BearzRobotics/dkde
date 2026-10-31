//! dkde-files: the file manager (SPEC.md 5.4).

const std = @import("std");
const gio = @import("gio2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

const FilesWindow = @import("window.zig").FilesWindow;

const App = struct {
    allocator: std.mem.Allocator,
    config: common.Config,
    /// Folder to open, from the command line.
    start: ?[:0]const u8,
    appearance: ?*common.style.Appearance = null,

    fn activate(app: *gtk.Application, self: *App) callconv(.c) void {
        common.style.load(self.allocator) catch |err|
            std.log.warn("stylesheet not loaded: {s}", .{@errorName(err)});

        self.appearance = common.style.Appearance.create(self.allocator) catch null;
        const window = FilesWindow.create(self.allocator, app, &self.config, self.start) catch |err| {
            std.log.err("cannot create the window: {s}", .{@errorName(err)});
            return;
        };
        window.present();
    }
};

pub const std_options: std.Options = .{ .logFn = common.log.logFn, .log_level = .debug };

pub fn main(init: std.process.Init.Minimal) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var app: App = .{
        .allocator = allocator,
        .config = try common.Config.load(allocator, "files.conf"),
        .start = if (init.args.vector.len > 1) std.mem.span(init.args.vector[1]) else null,
    };
    defer app.config.deinit();
    defer if (app.appearance) |a| a.destroy();

    // Uniqueness needs a session D-Bus, which dkde does not have.
    const gtk_app = gtk.Application.new("org.dkde.files", .{ .non_unique = true });
    defer gtk_app.as(gobject.Object).unref();
    _ = gio.Application.signals.activate.connect(gtk_app, *App, &App.activate, &app, .{});

    // Only the program name goes to GApplication: the folder argument is ours.
    // GApplication walks argv to its NULL terminator, so give it its own.
    var argv = [_]?[*:0]const u8{ init.args.vector[0], null };
    const status = gio.Application.run(gtk_app.as(gio.Application), 1, @ptrCast(&argv));
    if (status != 0) std.process.exit(@intCast(status));
}

test {
    _ = @import("pure.zig");
    _ = @import("props.zig");
    _ = @import("ops.zig");
}
