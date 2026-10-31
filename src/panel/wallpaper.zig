//! Wallpaper surface for one output (SPEC.md 5.1): an image or a solid
//! colour, on the `background` layer.

const std = @import("std");
const gdk = @import("gdk4");
const gtk = @import("gtk4");

const common = @import("common");

const surface = @import("surface.zig");
const Desktop = @import("desktop.zig").Desktop;

pub const Wallpaper = struct {
    window: *gtk.Window,
    /// The picture sits under the desktop icons (when this output has them).
    overlay: *gtk.Overlay,

    pub fn create(monitor: *gdk.Monitor, image: ?[:0]const u8, fit: gtk.ContentFit, icons: ?*const common.Config) Wallpaper {
        const window = gtk.Window.new();
        window.as(gtk.Widget).addCssClass("dkde-wallpaper");

        surface.setup(window, .{
            .name_space = "dkde-wallpaper",
            .layer = .background,
            .monitor = monitor,
            .anchors = &.{ .top, .bottom, .left, .right },
            .exclusive_zone = -1,
        });

        const click = gtk.GestureClick.new();
        click.as(gtk.GestureSingle).setButton(3);
        _ = gtk.GestureClick.signals.pressed.connect(click, *gtk.Window, &onRightClick, window, .{});
        window.as(gtk.Widget).addController(click.as(gtk.EventController));

        const overlay = gtk.Overlay.new();
        window.setChild(overlay.as(gtk.Widget));
        if (icons) |config| {
            if (Desktop.create(std.heap.c_allocator, config)) |desktop| overlay.addOverlay(desktop.widget());
        }
        var self: Wallpaper = .{ .window = window, .overlay = overlay };
        self.setImage(image, fit);
        window.present();
        return self;
    }

    const personalize = 0;
    const open_terminal = 1;
    const open_files = 2;

    fn onRightClick(_: *gtk.GestureClick, _: c_int, x: f64, y: f64, window: *gtk.Window) callconv(.c) void {
        common.contextmenu.show(window.as(gtk.Widget), x, y, &.{
            .{ .label = common.tr("Personalize"), .id = personalize },
            .{ .label = common.tr("Open Terminal"), .id = open_terminal },
            .{ .label = common.tr("Open Files"), .id = open_files },
        }, gtk.Window, onChosen, window);
    }

    fn onChosen(_: *gtk.Window, id: usize) void {
        const allocator = std.heap.c_allocator;
        switch (id) {
            personalize => common.appinfo.spawn(allocator, &.{"dkde-settings"}),
            open_terminal => common.appinfo.spawn(allocator, &.{"dkde-term"}),
            open_files => common.appinfo.spawn(allocator, &.{"dkde-files"}),
            else => {},
        }
    }

    pub fn destroy(self: *Wallpaper) void {
        self.window.destroy();
    }

    /// Shows `image`, or just the colour from the stylesheet when null.
    pub fn setImage(self: *Wallpaper, image: ?[:0]const u8, fit: gtk.ContentFit) void {
        const path = image orelse {
            self.overlay.setChild(null);
            return;
        };
        const picture = gtk.Picture.newForFilename(path);
        picture.setContentFit(fit);
        self.overlay.setChild(picture.as(gtk.Widget));
    }
};
