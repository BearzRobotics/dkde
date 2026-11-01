//! dkde-term: the terminal emulator (SPEC.md 5.3).

const std = @import("std");
const gio = @import("gio2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

const TermWindow = @import("window.zig").TermWindow;

const App = struct {
    allocator: std.mem.Allocator,
    config: common.Config,
    appearance: ?*common.style.Appearance = null,
    /// Command given after `-e`, run in the first tab instead of the shell.
    command: ?[]const []const u8,

    fn activate(app: *gtk.Application, self: *App) callconv(.c) void {
        common.style.load(self.allocator) catch |err|
            std.log.warn("stylesheet not loaded: {s}", .{@errorName(err)});
        self.appearance = common.style.Appearance.create(self.allocator) catch null;

        const window = TermWindow.create(self.allocator, app, &self.config, self.command) catch |err| {
            std.log.err("cannot create the window: {s}", .{@errorName(err)});
            return;
        };
        window.present();
    }
};

pub const std_options: std.Options = .{ .logFn = common.log.logFn, .log_level = .debug };

pub fn main(init: std.process.Init.Minimal) !void {
    common.perf.init();
    var debug_allocator: common.perf.Gpa = .{};
    defer debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    // `dkde-term -e command args...` runs `command` instead of the shell.
    var command: std.ArrayList([]const u8) = .empty;
    defer command.deinit(allocator);
    var args = init.args.vector[1..];
    if (args.len > 0 and std.mem.eql(u8, std.mem.span(args[0]), "-e")) {
        for (args[1..]) |arg| try command.append(allocator, std.mem.span(arg));
        args = args[0..0];
    }

    var app: App = .{
        .allocator = allocator,
        .config = try common.Config.load(allocator, "term.conf"),
        .command = if (command.items.len > 0) command.items else null,
    };
    defer app.config.deinit();
    defer if (app.appearance) |a| a.destroy();

    // Uniqueness needs a session D-Bus, which dkde does not have.
    const gtk_app = gtk.Application.new("org.dkde.term", .{ .non_unique = true });
    defer gtk_app.as(gobject.Object).unref();
    _ = gio.Application.signals.activate.connect(gtk_app, *App, &App.activate, &app, .{});

    // GApplication only gets the program name; the rest is ours.
    var argv = [_]?[*:0]const u8{ init.args.vector[0], null };
    const status = gio.Application.run(gtk_app.as(gio.Application), 1, @ptrCast(&argv));
    if (status != 0) std.process.exit(@intCast(status));
}

test {
    _ = @import("profile.zig");
    _ = @import("pty.zig");
    _ = @import("view.zig");
    _ = @import("window.zig");
}

test "libghostty-vt parses a sequence" {
    const vt = @import("ghostty-vt");
    var tm: vt.Terminal = try .init(std.testing.io, std.testing.allocator, .{ .cols = 20, .rows = 5 });
    defer tm.deinit(std.testing.allocator);
    var stream = tm.vtStream();
    defer stream.deinit();
    stream.nextSlice("hi\x1b[1;32m there\x1b[0m");
    const text = try tm.plainString(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "hi there"));
}
