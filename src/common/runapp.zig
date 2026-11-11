//! The start-up every small dkde app shares: debug allocator, stylesheet,
//! appearance, a non-unique GApplication and one window. `Window` needs
//! `create(allocator, app) !*Window` and `present(*Window) void`.

const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");

const style = @import("style.zig");
const perf = @import("core").perf;

/// The program's arguments after its name, for a window that takes a file.
pub var args: []const [*:0]const u8 = &.{};

/// Test aid for smoke tests (ai/DKDE-SPEC.md 25): `DKDE_EXIT_AFTER_MS=3000`
/// quits the program normally after that long, so the exit path (leak
/// reports in Debug builds, clean shutdown) can be checked without a person.
pub fn quitAfterEnv(app: *gtk.Application) void {
    const text = glib.getenv("DKDE_EXIT_AFTER_MS") orelse return;
    const ms = std.fmt.parseInt(c_uint, std.mem.span(text), 10) catch return;
    _ = glib.timeoutAdd(ms, quitCallback, app);
}

fn quitCallback(data: ?*anyopaque) callconv(.c) c_int {
    const app: *gtk.Application = @ptrCast(@alignCast(data.?));
    closeWindows(app);
    app.as(gio.Application).quit();
    return 0;
}

/// Closes every window the way the user does (the close button): handlers that
/// ask to save run, and the windows are destroyed, which frees what they own.
pub fn closeWindows(app: *gtk.Application) void {
    var node: ?*glib.List = app.getWindows();
    while (node) |n| {
        const next = n.f_next;
        if (n.f_data) |d| {
            const w: *gtk.Window = @ptrCast(@alignCast(d));
            w.close();
        }
        node = next;
    }
}

pub fn run(comptime app_id: [:0]const u8, comptime Window: type, init: std.process.Init.Minimal) !void {
    perf.init();
    // Open With and the like should see Flatpak and Snap apps too.
    @import("core").appdirs.ensure();
    var debug_allocator: perf.Gpa = .{};
    defer debug_allocator.deinit();

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

    if (init.args.vector.len > 1) args = @ptrCast(init.args.vector[1..]);
    var state: State = .{ .allocator = debug_allocator.allocator() };
    defer if (state.appearance) |a| a.destroy();

    const gtk_app = gtk.Application.new(app_id, .{ .non_unique = true });
    defer gtk_app.as(gobject.Object).unref();
    quitAfterEnv(gtk_app);
    _ = gio.Application.signals.activate.connect(gtk_app, *State, &State.activate, &state, .{});
    // Apps read their own arguments; GTK must not reject them as unknown options.
    var argv = [_]?[*:0]const u8{ init.args.vector[0], null };
    const status = gio.Application.run(gtk_app.as(gio.Application), 1, @ptrCast(&argv));
    if (status != 0) std.process.exit(@intCast(status));
}
