//! dkde-settings: the settings app (SPEC.md 5.5).

const std = @import("std");
const gio = @import("gio2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

const SettingsWindow = @import("window.zig").SettingsWindow;

const App = struct {
    allocator: std.mem.Allocator,
    appearance: ?*common.style.Appearance = null,
    /// Page to open first, from `--page <id>`.
    page: ?[:0]const u8 = null,

    fn activate(app: *gtk.Application, self: *App) callconv(.c) void {
        common.style.load(self.allocator) catch |err|
            std.log.warn("stylesheet not loaded: {s}", .{@errorName(err)});
        self.appearance = common.style.Appearance.create(self.allocator) catch null;

        const window = SettingsWindow.create(self.allocator, app) catch |err| {
            std.log.err("cannot create the window: {s}", .{@errorName(err)});
            return;
        };
        if (self.page) |id| window.showPage(id);
        window.present();
    }
};

pub const std_options: std.Options = .{ .logFn = common.log.logFn, .log_level = .debug };

pub fn main(init: std.process.Init.Minimal) !void {
    common.perf.init();
    var debug_allocator: common.perf.Gpa = .{};
    defer debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var app: App = .{ .allocator = allocator };
    const args = init.args.vector;
    var i: usize = 1;
    while (i + 1 < args.len) : (i += 1) {
        if (std.mem.eql(u8, std.mem.span(args[i]), "--page")) app.page = std.mem.span(args[i + 1]);
    }
    defer if (app.appearance) |a| a.destroy();

    // Uniqueness needs a session D-Bus, which dkde does not have.
    const gtk_app = gtk.Application.new("org.dkde.settings", .{ .non_unique = true });
    defer gtk_app.as(gobject.Object).unref();
    _ = gio.Application.signals.activate.connect(gtk_app, *App, &App.activate, &app, .{});

    // GApplication only gets the program name; --page is ours.
    var argv = [_]?[*:0]const u8{ init.args.vector[0], null };
    const status = gio.Application.run(gtk_app.as(gio.Application), 1, @ptrCast(&argv));
    if (status != 0) std.process.exit(@intCast(status));
}

test {
    _ = @import("hardware.zig");
    _ = @import("hwpages.zig");
}

test {
    _ = @import("users.zig");
}
