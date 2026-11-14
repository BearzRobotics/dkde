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
    // A developer aid: DKDE_DEBUG_MINWIDTH=1 prints what sets the window's least width, once the
    // window is built. (A window wider than half the screen cannot be snapped to a half.)
    if (std.c.getenv("DKDE_DEBUG_MINWIDTH") != null) _ = glib.timeoutAdd(2000, dumpMinWidth, window);
    return header;
}

fn dumpMinWidth(data: ?*anyopaque) callconv(.c) c_int {
    const window: *gtk.Window = @ptrCast(@alignCast(data.?));
    if (window.getChild()) |child| {
        // A quarter of a 1280×720 screen is 640×360; the window's least height at that width.
        var min_h: c_int = 0;
        child.measure(.vertical, 640, &min_h, null, null, null);
        var min_w: c_int = 0;
        child.measure(.horizontal, -1, &min_w, null, null, null);
        var title_h: c_int = 0;
        if (window.getTitlebar()) |t| t.measure(.vertical, 640, &title_h, null, null, null);
        std.debug.print("least size: {d} wide; {d} high at 640 wide (+{d} title bar)\n", .{ min_w, min_h, title_h });
        descend(child, 0);
    }
    return 0;
}

/// Prints the widget with its least width, then the child that dictates it, and so on down.
fn descend(w: *gtk.Widget, depth: usize) void {
    var min: c_int = 0;
    w.measure(.horizontal, -1, &min, null, null, null);
    std.debug.print("{s}{s} min={d}\n", .{ "                                        "[0..@min(depth * 2, 40)], std.mem.span(w.getCssName()), min });
    var best: ?*gtk.Widget = null;
    var best_min: c_int = -1;
    var c = w.getFirstChild();
    while (c) |child| : (c = child.getNextSibling()) {
        if (child.getVisible() == 0) continue;
        var cm: c_int = 0;
        child.measure(.horizontal, -1, &cm, null, null, null);
        if (cm > best_min) {
            best_min = cm;
            best = child;
        }
    }
    if (best) |b| if (depth < 30 and best_min >= 200) descend(b, depth + 1);
}

fn onTitleChanged(window: *gtk.Window, _: *gobject.ParamSpec, label: *gtk.Label) callconv(.c) void {
    label.setText(window.getTitle() orelse "");
}
