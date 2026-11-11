//! dkde-term: the terminal emulator (SPEC.md 5.3).

const std = @import("std");
const cli = @import("cli");
const gio = @import("gio2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

const TermWindow = @import("window.zig").TermWindow;
const dropdown = @import("dropdown.zig");

const App = struct {
    allocator: std.mem.Allocator,
    config: common.Config,
    appearance: ?*common.style.Appearance = null,
    /// Command given after `-e`, run in the first tab instead of the shell.
    command: ?[]const []const u8,
    /// `--dropdown`: the drop-down terminal.
    dropdown: bool = false,

    fn activate(app: *gtk.Application, self: *App) callconv(.c) void {
        common.style.load(self.allocator) catch |err|
            std.log.warn("stylesheet not loaded: {s}", .{@errorName(err)});
        self.appearance = common.style.Appearance.create(self.allocator) catch null;

        // Without a command, the tabs of the last session come back.
        const window = (if (self.command == null and !self.dropdown) blk: {
            const w = TermWindow.createEmpty(self.allocator, app, &self.config) catch |err| break :blk err;
            if (!w.restoreSession()) w.newDefaultTab();
            break :blk w;
        } else TermWindow.create(self.allocator, app, &self.config, self.command)) catch |err| {
            std.log.err("cannot create the window: {s}", .{@errorName(err)});
            return;
        };
        if (self.dropdown) {
            window.makeDropdown(@intCast(std.math.clamp(self.config.getInt("terminal", "dropdown-height", 45), 10, 95)));
            dropdown.listen(window.window.as(gtk.Window));
        }
        window.present();
    }
};

pub const std_options: std.Options = .{ .logFn = common.log.logFn, .log_level = .debug };

pub fn main(init: std.process.Init.Minimal) !void {
    cli.handle(init.args, .{
        .name = "dkde-term",
        .summary = "Terminal emulator",
        .usage = "[--dropdown] [-e COMMAND [ARG...]]",
        .options = "  --dropdown  show or hide the drop-down terminal (bind it to a key, F12 in dkde)",
        .accepted = &.{"--dropdown"},
        .stop_at = &.{"-e"},
    });
    var want_dropdown = false;
    for (init.args.vector[1..]) |a| {
        if (std.mem.eql(u8, std.mem.span(a), "-e")) break;
        if (std.mem.eql(u8, std.mem.span(a), "--dropdown")) want_dropdown = true;
    }
    if (want_dropdown) {
        // A running drop-down terminal only shows or hides itself.
        if (dropdown.toggleRunning()) return;
        dropdown.reexecWithLayerShell(@ptrCast(init.args.vector));
    }
    common.perf.init();
    var debug_allocator: common.perf.Gpa = .{};
    defer debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    // `dkde-term -e command args...` runs `command` instead of the shell.
    var command: std.ArrayList([]const u8) = .empty;
    defer command.deinit(allocator);
    const args = init.args.vector[1..];
    for (args, 0..) |a, i| if (std.mem.eql(u8, std.mem.span(a), "-e")) {
        for (args[i + 1 ..]) |arg| try command.append(allocator, std.mem.span(arg));
        break;
    };

    var app: App = .{
        .allocator = allocator,
        .config = try common.Config.load(allocator, "term.toml"),
        .command = if (command.items.len > 0) command.items else null,
        .dropdown = want_dropdown,
    };
    defer app.config.deinit();
    defer if (app.appearance) |a| a.destroy();

    // Uniqueness needs a session D-Bus, which dkde does not have.
    const gtk_app = gtk.Application.new("org.dkde.term", .{ .non_unique = true });
    defer gtk_app.as(gobject.Object).unref();
    common.runapp.quitAfterEnv(gtk_app);
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
    _ = @import("embed.zig");
    _ = @import("urls.zig");
    _ = @import("finder.zig");
    _ = @import("safety.zig");
    _ = @import("session.zig");
    _ = @import("dropdown.zig");
    _ = @import("schemes.zig");
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
