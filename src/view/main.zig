//! dkde-view: image viewer (SPEC.md 5.6). Loading goes through gdk-pixbuf,
//! so it opens whatever formats the installed pixbuf loaders support.

const std = @import("std");
const gdk = @import("gdk4");
const gdkpixbuf = @import("gdkpixbuf2");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

const pure = @import("pure.zig");

const App = struct {
    allocator: std.mem.Allocator,
    appearance: ?*common.style.Appearance = null,
    start: ?[:0]const u8,

    fn activate(app: *gtk.Application, self: *App) callconv(.c) void {
        common.style.load(self.allocator) catch |err|
            std.log.warn("stylesheet not loaded: {s}", .{@errorName(err)});
        self.appearance = common.style.Appearance.create(self.allocator) catch null;
        const viewer = Viewer.create(self.allocator, app) catch |err| {
            std.log.err("cannot create the window: {s}", .{@errorName(err)});
            return;
        };
        if (self.start) |path| viewer.openPath(path);
        viewer.window.as(gtk.Window).present();
    }
};

const Viewer = struct {
    allocator: std.mem.Allocator,
    window: *gtk.ApplicationWindow,
    picture: *gtk.Picture,
    scroller: *gtk.ScrolledWindow,
    status: *gtk.Label,

    pixbuf: ?*gdkpixbuf.Pixbuf = null,
    path: ?[:0]u8 = null,
    /// Sibling images in the same folder, sorted by name.
    siblings: std.ArrayList([:0]u8) = .empty,
    index: usize = 0,
    /// Null means "fit to window".
    zoom: ?f64 = null,

    fn create(allocator: std.mem.Allocator, app: *gtk.Application) !*Viewer {
        const self = try allocator.create(Viewer);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .window = gtk.ApplicationWindow.new(app),
            .picture = gtk.Picture.new(),
            .scroller = gtk.ScrolledWindow.new(),
            .status = gtk.Label.new(""),
        };
        const window = self.window;
        window.as(gtk.Window).setTitle(common.tr("Image Viewer"));
        window.as(gtk.Window).setDefaultSize(900, 640);
        window.as(gtk.Widget).addCssClass("dkde");

        _ = common.header.create(window.as(gtk.Window), "image-x-generic", true);

        const mb = common.menubar;
        const menus = [_]mb.Menu{
            .{ .label = "_File", .entries = &.{
                mb.item("_Open…", "open", "<Control>o"),
                mb.item("Set as _Wallpaper", "wallpaper", null),
                .separator,
                mb.item("_Close", "close", "<Control>w"),
            } },
            .{ .label = "_View", .entries = &.{
                mb.item("Zoom _In", "zoom-in", "plus"),
                mb.item("Zoom _Out", "zoom-out", "minus"),
                mb.item("_Fit to Window", "fit", "0"),
                mb.item("_Actual Size", "actual", "1"),
                .separator,
                mb.item("F_ull Screen", "fullscreen", "F11"),
            } },
            .{ .label = "_Image", .entries = &.{
                mb.item("Rotate _Right", "rotate-right", "r"),
                mb.item("Rotate _Left", "rotate-left", "<Shift>r"),
                .separator,
                mb.item("_Previous", "prev", "Left"),
                mb.item("_Next", "next", "Right"),
            } },
        };
        const menu_bar = mb.build(app, window, &menus, Viewer, onMenuAction, self);

        self.picture.setCanShrink(1);
        self.picture.setContentFit(.contain);
        self.scroller.setChild(self.picture.as(gtk.Widget));
        self.scroller.as(gtk.Widget).setVexpand(1);
        self.scroller.as(gtk.Widget).addCssClass("dkde-viewer");

        // Ctrl+scroll zooms.
        const scroll = gtk.EventControllerScroll.new(.{ .vertical = true });
        scroll.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.EventControllerScroll.signals.scroll.connect(scroll, *Viewer, &onScroll, self, .{});
        self.scroller.as(gtk.Widget).addController(scroll.as(gtk.EventController));

        self.status.setXalign(0);
        self.status.as(gtk.Widget).setMarginStart(8);
        self.status.as(gtk.Widget).addCssClass("dim-label");

        const root = gtk.Box.new(.vertical, 0);
        root.append(menu_bar.as(gtk.Widget));
        root.append(self.scroller.as(gtk.Widget));
        root.append(self.status.as(gtk.Widget));
        window.as(gtk.Window).setChild(root.as(gtk.Widget));

        self.installShortcuts();
        _ = gtk.Widget.signals.destroy.connect(window, *Viewer, &onDestroy, self, .{});
        return self;
    }

    fn onDestroy(_: *gtk.ApplicationWindow, self: *Viewer) callconv(.c) void {
        if (self.pixbuf) |p| p.as(gobject.Object).unref();
        if (self.path) |p| self.allocator.free(p);
        for (self.siblings.items) |s| self.allocator.free(s);
        self.siblings.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn onMenuAction(self: *Viewer, action: []const u8) void {
        self.perform(action);
    }

    fn perform(self: *Viewer, action: []const u8) void {
        const eql = std.mem.eql;
        if (eql(u8, action, "open")) return self.openDialog();
        if (eql(u8, action, "prev")) return self.step(false);
        if (eql(u8, action, "next")) return self.step(true);
        if (eql(u8, action, "rotate-right")) return self.rotate(.clockwise);
        if (eql(u8, action, "rotate-left")) return self.rotate(.counterclockwise);
        if (eql(u8, action, "zoom-in")) return self.setZoom(pure.stepZoom(self.zoom orelse self.fitZoom(), true));
        if (eql(u8, action, "zoom-out")) return self.setZoom(pure.stepZoom(self.zoom orelse self.fitZoom(), false));
        if (eql(u8, action, "fit")) return self.fit();
        if (eql(u8, action, "actual")) return self.setZoom(1.0);
        if (eql(u8, action, "wallpaper")) return self.setWallpaper();
        if (eql(u8, action, "fullscreen")) {
            const w = self.window.as(gtk.Window);
            if (w.isFullscreen() != 0) w.unfullscreen() else w.fullscreen();
        }
        if (eql(u8, action, "close")) self.window.as(gtk.Window).close();
    }

    const Shortcut = struct { trigger: [:0]const u8, action: []const u8 };
    const shortcuts = [_]Shortcut{
        .{ .trigger = "<Control>o", .action = "open" },
        .{ .trigger = "Left", .action = "prev" },
        .{ .trigger = "Right", .action = "next" },
        .{ .trigger = "Page_Up", .action = "prev" },
        .{ .trigger = "Page_Down", .action = "next" },
        .{ .trigger = "r", .action = "rotate-right" },
        .{ .trigger = "<Shift>r", .action = "rotate-left" },
        .{ .trigger = "plus", .action = "zoom-in" },
        .{ .trigger = "equal", .action = "zoom-in" },
        .{ .trigger = "KP_Add", .action = "zoom-in" },
        .{ .trigger = "minus", .action = "zoom-out" },
        .{ .trigger = "KP_Subtract", .action = "zoom-out" },
        .{ .trigger = "0", .action = "fit" },
        .{ .trigger = "1", .action = "actual" },
        .{ .trigger = "F11", .action = "fullscreen" },
        .{ .trigger = "<Control>w", .action = "close" },
        .{ .trigger = "<Control>q", .action = "close" },
        .{ .trigger = "Escape", .action = "close" },
    };

    fn installShortcuts(self: *Viewer) void {
        const controller = gtk.ShortcutController.new();
        controller.as(gtk.EventController).setPropagationPhase(.capture);
        inline for (shortcuts) |s| {
            const action = gtk.CallbackAction.new(onShortcut, @ptrCast(@constCast(&s)), null);
            controller.addShortcut(gtk.Shortcut.new(gtk.ShortcutTrigger.parseString(s.trigger), @ptrCast(action)));
        }
        self.window.as(gtk.Widget).addController(controller.as(gtk.EventController));
        self.window.as(gobject.Object).setData("dkde-viewer", self);
    }

    fn onShortcut(widget: *gtk.Widget, _: ?*glib.Variant, data: ?*anyopaque) callconv(.c) c_int {
        const shortcut: *const Shortcut = @ptrCast(@alignCast(data.?));
        const obj: *gobject.Object = @ptrCast(@alignCast(widget));
        const self: *Viewer = @ptrCast(@alignCast(obj.getData("dkde-viewer") orelse return 0));
        self.perform(shortcut.action);
        return 1;
    }

    fn onScroll(ctrl: *gtk.EventControllerScroll, _: f64, dy: f64, self: *Viewer) callconv(.c) c_int {
        const state = ctrl.as(gtk.EventController).getCurrentEventState();
        if (!state.control_mask) return 0;
        self.setZoom(pure.stepZoom(self.zoom orelse self.fitZoom(), dy < 0));
        return 1;
    }

    // ---- loading -------------------------------------------------------------

    pub fn openPath(self: *Viewer, path: [:0]const u8) void {
        const file = gio.File.newForCommandlineArg(path);
        defer file.as(gobject.Object).unref();
        const real = file.getPath() orelse return;
        defer glib.free(real);
        self.loadFile(std.mem.span(real));
        self.scanFolder();
    }

    fn openDialog(self: *Viewer) void {
        const dialog = gtk.FileDialog.new();
        defer dialog.as(gobject.Object).unref();
        dialog.open(self.window.as(gtk.Window), null, onOpenChosen, self);
    }

    fn onOpenChosen(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Viewer = @ptrCast(@alignCast(data.?));
        const dialog: *gtk.FileDialog = @ptrCast(@alignCast(source.?));
        var err: ?*glib.Error = null;
        const file = dialog.openFinish(result, &err) orelse {
            if (err) |e| e.free();
            return;
        };
        defer file.as(gobject.Object).unref();
        const path = file.getPath() orelse return;
        defer glib.free(path);
        self.loadFile(std.mem.span(path));
        self.scanFolder();
    }

    fn loadFile(self: *Viewer, path: []const u8) void {
        const z = self.allocator.dupeSentinel(u8, path, 0) catch return;
        errdefer self.allocator.free(z);

        var err: ?*glib.Error = null;
        const loaded = gdkpixbuf.Pixbuf.newFromFile(z, &err) orelse {
            const message = if (err) |e| e.f_message orelse "unknown error" else "unknown error";
            common.dialogs.showError(self.window.as(gtk.Window), common.tr("Cannot open this image"), std.mem.span(message));
            if (err) |e| e.free();
            self.allocator.free(z);
            return;
        };
        // Honour the camera's orientation tag.
        const oriented = loaded.applyEmbeddedOrientation();
        const pixbuf = oriented orelse loaded;
        if (oriented != null) loaded.as(gobject.Object).unref();

        if (self.path) |p| self.allocator.free(p);
        self.path = z;
        self.setPixbuf(pixbuf);
        self.fit();
    }

    fn setPixbuf(self: *Viewer, pixbuf: *gdkpixbuf.Pixbuf) void {
        if (self.pixbuf) |old| old.as(gobject.Object).unref();
        self.pixbuf = pixbuf;
        const texture = gdk.Texture.newForPixbuf(pixbuf);
        defer texture.as(gobject.Object).unref();
        self.picture.setPaintable(texture.as(gdk.Paintable));
    }

    /// Lists the other images in the file's folder, for previous and next.
    fn scanFolder(self: *Viewer) void {
        for (self.siblings.items) |s| self.allocator.free(s);
        self.siblings.clearRetainingCapacity();
        const path = self.path orelse return;
        const dir_path = glib.pathGetDirname(path);
        defer glib.free(dir_path);
        const dir = gio.File.newForPath(dir_path);
        defer dir.as(gobject.Object).unref();
        const children = dir.enumerateChildren("standard::name", .{}, null, null) orelse return;
        defer children.as(gobject.Object).unref();
        while (children.nextFile(null, null)) |info| {
            defer info.as(gobject.Object).unref();
            const name = std.mem.span(info.getName());
            if (!pure.isImageName(name)) continue;
            const full = std.fmt.allocPrintSentinel(self.allocator, "{s}/{s}", .{ std.mem.span(dir_path), name }, 0) catch continue;
            self.siblings.append(self.allocator, full) catch self.allocator.free(full);
        }
        std.mem.sort([:0]u8, self.siblings.items, {}, struct {
            fn less(_: void, a: [:0]u8, b: [:0]u8) bool {
                return std.ascii.lessThanIgnoreCase(a, b);
            }
        }.less);
        for (self.siblings.items, 0..) |s, i| {
            if (std.mem.eql(u8, s, path)) self.index = i;
        }
        self.updateStatus();
    }

    fn step(self: *Viewer, forward: bool) void {
        if (self.siblings.items.len < 2) return;
        self.index = pure.neighbour(self.index, self.siblings.items.len, forward);
        self.loadFile(self.siblings.items[self.index]);
        self.updateStatus();
    }

    // ---- zoom and rotation -------------------------------------------------------

    fn imageSize(self: *const Viewer) ?struct { w: f64, h: f64 } {
        const p = self.pixbuf orelse return null;
        return .{ .w = @floatFromInt(p.getWidth()), .h = @floatFromInt(p.getHeight()) };
    }

    /// The zoom at which the whole image fits the window.
    fn fitZoom(self: *const Viewer) f64 {
        const size = self.imageSize() orelse return 1;
        const widget = self.scroller.as(gtk.Widget);
        const w: f64 = @floatFromInt(@max(1, widget.getWidth()));
        const h: f64 = @floatFromInt(@max(1, widget.getHeight()));
        return pure.clampZoom(@min(w / size.w, h / size.h));
    }

    fn fit(self: *Viewer) void {
        self.zoom = null;
        self.scroller.setPolicy(.never, .never);
        self.picture.setCanShrink(1);
        self.picture.setContentFit(.contain);
        self.picture.as(gtk.Widget).setSizeRequest(-1, -1);
        self.updateStatus();
    }

    fn setZoom(self: *Viewer, zoom: f64) void {
        const size = self.imageSize() orelse return;
        const z = pure.clampZoom(zoom);
        self.zoom = z;
        self.scroller.setPolicy(.automatic, .automatic);
        self.picture.setCanShrink(0);
        self.picture.setContentFit(.fill);
        self.picture.as(gtk.Widget).setSizeRequest(@intFromFloat(size.w * z), @intFromFloat(size.h * z));
        self.updateStatus();
    }

    fn rotate(self: *Viewer, angle: gdkpixbuf.PixbufRotation) void {
        const current = self.pixbuf orelse return;
        const rotated = current.rotateSimple(angle) orelse return;
        self.setPixbuf(rotated);
        if (self.zoom) |z| self.setZoom(z) else self.fit();
    }

    // ---- wallpaper -----------------------------------------------------------------

    fn setWallpaper(self: *Viewer) void {
        const path = self.path orelse return;
        var cfg = common.Config.load(self.allocator, "panel.conf") catch return;
        defer cfg.deinit();
        // A slideshow folder would override the picture, so turn it off.
        cfg.setString("wallpaper", "slideshow-dir", "") catch return;
        cfg.setString("wallpaper", "image", path) catch return;
        self.status.setText(common.tr("Wallpaper set"));
    }

    fn updateStatus(self: *Viewer) void {
        const path = self.path orelse {
            self.status.setText(common.tr("Open an image with Ctrl+O"));
            return;
        };
        var buf: [768]u8 = undefined;
        const size = self.imageSize();
        const zoom_percent: i32 = @intFromFloat((self.zoom orelse self.fitZoom()) * 100);
        const text = std.fmt.bufPrintSentinel(&buf, "{s}   {d}×{d}   {d}%   ({d}/{d})", .{
            std.fs.path.basename(path),
            if (size) |s| @as(i32, @intFromFloat(s.w)) else 0,
            if (size) |s| @as(i32, @intFromFloat(s.h)) else 0,
            zoom_percent,
            self.index + 1,
            @max(1, self.siblings.items.len),
        }, 0) catch return;
        self.status.setText(text);
        var title: [512]u8 = undefined;
        self.window.as(gtk.Window).setTitle(std.fmt.bufPrintSentinel(&title, "{s} - Image Viewer", .{std.fs.path.basename(path)}, 0) catch "Image Viewer");
    }
};

pub const std_options: std.Options = .{ .logFn = common.log.logFn, .log_level = .debug };

pub fn main(init: std.process.Init.Minimal) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var app: App = .{
        .allocator = allocator,
        .start = if (init.args.vector.len > 1) std.mem.span(init.args.vector[1]) else null,
    };
    defer if (app.appearance) |a| a.destroy();

    const gtk_app = gtk.Application.new("org.dkde.view", .{ .non_unique = true });
    defer gtk_app.as(gobject.Object).unref();
    _ = gio.Application.signals.activate.connect(gtk_app, *App, &App.activate, &app, .{});

    var argv = [_]?[*:0]const u8{ init.args.vector[0], null };
    const status = gio.Application.run(gtk_app.as(gio.Application), 1, @ptrCast(&argv));
    if (status != 0) std.process.exit(@intCast(status));
}

test {
    _ = @import("pure.zig");
}
