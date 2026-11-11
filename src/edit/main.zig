//! dkde-edit: the text editor (SPEC.md 5.6). Notepad-simple to start with,
//! with what gedit, GNOME Text Editor and Kate offer when it is wanted:
//! syntax colours, line numbers and the other GtkSourceView extras when
//! that library is installed (source.zig), find and replace with regular
//! expressions, files in any common encoding and line ending, a folder
//! panel, Find in Files, split view, extra cursors, spell checking, and tabs
//! (with unsaved text) that come back after a restart or a crash.

const std = @import("std");
const cli = @import("cli");
const gio = @import("gio2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

const Editor = @import("editor.zig").Editor;

const App = struct {
    allocator: std.mem.Allocator,
    config: common.Config,
    appearance: ?*common.style.Appearance = null,
    /// Files to open, one tab each, from the command line.
    files: []const [:0]const u8,

    fn activate(app: *gtk.Application, self: *App) callconv(.c) void {
        common.style.load(self.allocator) catch |err|
            std.log.warn("stylesheet not loaded: {s}", .{@errorName(err)});
        self.appearance = common.style.Appearance.create(self.allocator) catch null;
        const editor = Editor.create(self.allocator, app, &self.config) catch |err| {
            std.log.err("cannot create the window: {s}", .{@errorName(err)});
            return;
        };
        editor.restoreSession(self.files.len > 0);
        for (self.files) |path| editor.openPath(path);
        editor.window.as(gtk.Window).present();
        editor.focusTextSoon();
    }
};

pub const std_options: std.Options = .{ .logFn = common.log.logFn, .log_level = .debug };

pub fn main(init: std.process.Init.Minimal) !void {
    cli.handle(init.args, .{ .name = "dkde-edit", .summary = "Text editor", .usage = "[FILE...]" });
    common.perf.init();
    var debug_allocator: common.perf.Gpa = .{};
    defer debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var files: std.ArrayList([:0]const u8) = .empty;
    defer files.deinit(allocator);
    for (init.args.vector[1..]) |arg| try files.append(allocator, std.mem.span(arg));

    var app: App = .{
        .allocator = allocator,
        .config = try common.Config.load(allocator, "edit.toml"),
        .files = files.items,
    };
    defer app.config.deinit();
    defer if (app.appearance) |a| a.destroy();

    const gtk_app = gtk.Application.new("org.dkde.edit", .{ .non_unique = true });
    defer gtk_app.as(gobject.Object).unref();
    common.runapp.quitAfterEnv(gtk_app);
    _ = gio.Application.signals.activate.connect(gtk_app, *App, &App.activate, &app, .{});

    // GApplication only gets the program name; the file arguments are ours.
    var argv = [_]?[*:0]const u8{ init.args.vector[0], null };
    const status = gio.Application.run(gtk_app.as(gio.Application), 1, @ptrCast(&argv));
    if (status != 0) std.process.exit(@intCast(status));
}

test {
    _ = @import("textfile.zig");
    _ = @import("search.zig");
    _ = @import("memory.zig");
}
