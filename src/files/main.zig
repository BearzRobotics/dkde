//! dkde-files: the file manager (SPEC.md 5.4).

const std = @import("std");
const cli = @import("cli");
const gio = @import("gio2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

const FilesWindow = @import("window.zig").FilesWindow;
const arc = @import("arc.zig");

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

/// The helper modes: `--archive-extract ARCHIVE DEST` and
/// `--archive-pack FORMAT OUT DIR NAME...`. They print a sentence on failure and
/// exit 1. The file manager runs itself this way so libarchive works in its own
/// process (see arc.zig).
fn archiveHelper(init: std.process.Init.Minimal) ?u8 {
    const args = init.args.vector;
    if (args.len < 2) return null;
    const mode = std.mem.span(args[1]);
    const gpa = std.heap.c_allocator;
    var out: [1024]u8 = undefined;
    if (std.mem.eql(u8, mode, "--archive-extract") and args.len == 4) {
        arc.extractAll(gpa, std.mem.span(args[2]), std.mem.span(args[3])) catch |err| return fail(&out, err);
        return 0;
    }
    if (std.mem.eql(u8, mode, "--archive-pack") and args.len >= 6) {
        const format = arc.formatOf(std.mem.span(args[2])) orelse return fail(&out, error.Unsupported);
        var names = gpa.alloc([]const u8, args.len - 5) catch return 1;
        defer gpa.free(names);
        for (args[5..], 0..) |a, i| names[i] = std.mem.span(a);
        arc.packAll(gpa, format, std.mem.span(args[3]), std.mem.span(args[4]), names) catch |err| return fail(&out, err);
        return 0;
    }
    return null;
}

fn fail(_: []u8, err: anyerror) u8 {
    const text = arc.describe(err);
    _ = std.c.write(1, text.ptr, text.len);
    return 1;
}

pub fn main(init: std.process.Init.Minimal) !void {
    if (archiveHelper(init)) |status| std.process.exit(status);
    cli.handle(init.args, .{ .name = "dkde-files", .summary = "File manager", .usage = "[DIRECTORY]" });
    common.perf.init();
    var debug_allocator: common.perf.Gpa = .{};
    defer debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var app: App = .{
        .allocator = allocator,
        .config = try common.Config.load(allocator, "files.toml"),
        .start = if (init.args.vector.len > 1) std.mem.span(init.args.vector[1]) else null,
    };
    defer app.config.deinit();
    defer if (app.appearance) |a| a.destroy();

    // Uniqueness needs a session D-Bus, which dkde does not have.
    const gtk_app = gtk.Application.new("org.dkde.files", .{ .non_unique = true });
    defer gtk_app.as(gobject.Object).unref();
    common.runapp.quitAfterEnv(gtk_app);
    _ = gio.Application.signals.activate.connect(gtk_app, *App, &App.activate, &app, .{});

    // Only the program name goes to GApplication: the folder argument is ours.
    // GApplication walks argv to its NULL terminator, so give it its own.
    var argv = [_]?[*:0]const u8{ init.args.vector[0], null };
    const status = gio.Application.run(gtk_app.as(gio.Application), 1, @ptrCast(&argv));
    if (status != 0) std.process.exit(@intCast(status));
}

test {
    _ = @import("pure.zig");
    _ = @import("context.zig");
    _ = @import("clipboard.zig");
    _ = @import("props.zig");
    _ = @import("ops.zig");
    _ = @import("folder.zig");
    _ = @import("arc.zig");
}
