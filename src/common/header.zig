//! The shared window header (SPEC.md 6.2): a flat bar with the app icon and
//! title at the left and the window buttons at the right, like Windows.

const std = @import("std");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");

/// Installs a header on `window`. With `with_title` the window title is
/// shown beside the icon and kept in step with it; without it (a window that
/// puts its own widget in the middle) only the icon is shown.
/// Returns the bar so the caller can pack more widgets after the title.
pub fn create(window: *gtk.Window, icon_name: [:0]const u8, with_title: bool) *gtk.HeaderBar {
    const header = gtk.HeaderBar.new();
    header.as(gtk.Widget).addCssClass("dkde-header");
    // The centred default title is replaced by the left-aligned one below.
    header.setTitleWidget(gtk.Box.new(.horizontal, 0).as(gtk.Widget));

    const icon = gtk.Image.newFromIconName(icon_name);
    icon.setPixelSize(16);
    icon.as(gtk.Widget).addCssClass("dkde-header-icon");
    header.packStart(icon.as(gtk.Widget));

    if (with_title) {
        const label = gtk.Label.new(window.getTitle());
        label.setXalign(0);
        label.setEllipsize(.end);
        label.as(gtk.Widget).addCssClass("dkde-header-title");
        header.packStart(label.as(gtk.Widget));
        _ = gobject.Object.signals.notify.connect(window, *gtk.Label, &onTitleChanged, label, .{ .detail = "title" });
    }
    window.setTitlebar(header.as(gtk.Widget));
    return header;
}

fn onTitleChanged(window: *gtk.Window, _: *gobject.ParamSpec, label: *gtk.Label) callconv(.c) void {
    label.setText(window.getTitle() orelse "");
}
