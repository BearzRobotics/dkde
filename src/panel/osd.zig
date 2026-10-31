//! The on-screen display for volume and brightness keys (SPEC.md 5.1): a small
//! pill at the bottom centre of the screen with an icon, a level bar and a
//! label, shown for a moment on the overlay layer. It never takes input.
//! Wayland only (it needs layer-shell).

const std = @import("std");
const cairo = @import("cairo1");
const glib = @import("glib2");
const gtk = @import("gtk4");

const surface = @import("surface.zig");

const show_ms = 1500;

pub const Osd = struct {
    allocator: std.mem.Allocator,
    window: *gtk.Window,
    icon: *gtk.Image,
    bar: *gtk.ProgressBar,
    label: *gtk.Label,
    hide_source: c_uint = 0,

    pub fn create(allocator: std.mem.Allocator) ?*Osd {
        if (surface.isX11()) return null;
        const self = allocator.create(Osd) catch return null;
        const window = gtk.Window.new();
        window.as(gtk.Widget).addCssClass("dkde-osd-window");
        surface.setup(window, .{
            .name_space = "dkde-osd",
            .layer = .overlay,
            .anchors = &.{.bottom},
            .exclusive_zone = 0,
        });
        const pill = gtk.Box.new(.horizontal, 12);
        pill.as(gtk.Widget).addCssClass("dkde-osd");
        pill.as(gtk.Widget).setMarginBottom(72);
        const icon = gtk.Image.new();
        icon.setPixelSize(28);
        const bar = gtk.ProgressBar.new();
        bar.as(gtk.Widget).setSizeRequest(180, -1);
        bar.as(gtk.Widget).setValign(.center);
        const label = gtk.Label.new("");
        label.setWidthChars(5);
        pill.append(icon.as(gtk.Widget));
        pill.append(bar.as(gtk.Widget));
        pill.append(label.as(gtk.Widget));
        window.setChild(pill.as(gtk.Widget));
        self.* = .{ .allocator = allocator, .window = window, .icon = icon, .bar = bar, .label = label };
        _ = gtk.Widget.signals.realize.connect(window, *Osd, &onRealize, self, .{});
        return self;
    }

    pub fn destroy(self: *Osd) void {
        if (self.hide_source != 0) _ = glib.Source.remove(self.hide_source);
        self.window.destroy();
        self.allocator.destroy(self);
    }

    /// The display must not catch clicks meant for the window under it.
    fn onRealize(window: *gtk.Window, _: *Osd) callconv(.c) void {
        const native: *gtk.Native = @ptrCast(window);
        const gdk_surface = native.getSurface() orelse return;
        const empty = cairo.Region.create();
        defer empty.destroy();
        gdk_surface.setInputRegion(empty);
    }

    /// Shows `icon_name`, a level from 0 to 1 and a short label.
    pub fn show(self: *Osd, icon_name: [:0]const u8, fraction: f64, text: []const u8) void {
        self.icon.setFromIconName(icon_name);
        self.bar.setFraction(std.math.clamp(fraction, 0, 1));
        var buf: [32]u8 = undefined;
        self.label.setText(std.fmt.bufPrintSentinel(&buf, "{s}", .{text}, 0) catch "");
        self.window.as(gtk.Widget).setVisible(1);
        self.window.present();
        if (self.hide_source != 0) _ = glib.Source.remove(self.hide_source);
        self.hide_source = glib.timeoutAdd(show_ms, onHide, self);
    }

    fn onHide(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Osd = @ptrCast(@alignCast(data.?));
        self.hide_source = 0;
        self.window.as(gtk.Widget).setVisible(0);
        return 0;
    }
};
