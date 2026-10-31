//! Properties dialog (SPEC.md 5.4): name, type, size, location, timestamps
//! and permissions.

const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

const pure = @import("pure.zig");

const attributes = "standard::*,time::*,unix::mode,owner::user,owner::group";

pub fn show(allocator: std.mem.Allocator, parent: *gtk.Window, file: *gio.File) void {
    const info = file.queryInfo(attributes, .{}, null, null) orelse {
        common.dialogs.showError(parent, common.tr("Cannot read the properties of this item"), null);
        return;
    };
    defer info.as(gobject.Object).unref();

    const window = gtk.Window.new();
    window.setTitle(common.tr("Properties"));
    window.setTransientFor(parent);
    window.setModal(1);
    window.setDefaultSize(380, -1);
    window.as(gtk.Widget).addCssClass("dkde");

    const grid = gtk.Grid.new();
    grid.setRowSpacing(8);
    grid.setColumnSpacing(16);
    grid.as(gtk.Widget).setMarginTop(16);
    grid.as(gtk.Widget).setMarginBottom(16);
    grid.as(gtk.Widget).setMarginStart(16);
    grid.as(gtk.Widget).setMarginEnd(16);
    window.setChild(grid.as(gtk.Widget));

    var row: c_int = 0;
    addRow(grid, &row, common.tr("Name"), std.mem.span(info.getDisplayName()));

    if (info.getContentType()) |content_type| {
        {
            const description = gio.contentTypeGetDescription(content_type);
            defer glib.free(description);
            addRow(grid, &row, common.tr("Type"), std.mem.span(description));
        }
    }

    var size_buf: [64]u8 = undefined;
    if (info.getFileType() == .directory) {
        addRow(grid, &row, common.tr("Size"), "—");
    } else {
        addRow(grid, &row, common.tr("Size"), pure.formatSize(&size_buf, @intCast(info.getSize())));
    }

    if (file.getParent()) |parent_dir| {
        defer parent_dir.as(gobject.Object).unref();
        if (parent_dir.getPath()) |path| {
            defer glib.free(path);
            addRow(grid, &row, common.tr("Location"), std.mem.span(path));
        }
    }

    addTime(allocator, grid, &row, common.tr("Modified"), info.getModificationDateTime());
    addTime(allocator, grid, &row, common.tr("Accessed"), info.getAccessDateTime());
    addTime(allocator, grid, &row, common.tr("Created"), info.getCreationDateTime());

    if (info.hasAttribute("unix::mode") != 0) {
        var perm_buf: [32]u8 = undefined;
        var bits: [9]u8 = undefined;
        const mode = info.getAttributeUint32("unix::mode");
        const owner = info.getAttributeString("owner::user");
        const group = info.getAttributeString("owner::group");
        const text = std.fmt.bufPrint(&perm_buf, "{s}  {s}:{s}", .{
            permissions(&bits, mode),
            if (owner) |o| std.mem.span(o) else "?",
            if (group) |g| std.mem.span(g) else "?",
        }) catch "";
        addRow(grid, &row, common.tr("Permissions"), text);
    }

    window.present();
}

fn addRow(grid: *gtk.Grid, row: *c_int, label: [:0]const u8, value: []const u8) void {
    const key = gtk.Label.new(label);
    key.setXalign(1);
    key.as(gtk.Widget).addCssClass("dim-label");
    grid.attach(key.as(gtk.Widget), 0, row.*, 1, 1);

    var buf: [1024]u8 = undefined;
    const text = std.fmt.bufPrintSentinel(&buf, "{s}", .{value}, 0) catch "";
    const val = gtk.Label.new(text);
    val.setXalign(0);
    val.setSelectable(1);
    val.setWrap(1);
    grid.attach(val.as(gtk.Widget), 1, row.*, 1, 1);
    row.* += 1;
}

fn addTime(allocator: std.mem.Allocator, grid: *gtk.Grid, row: *c_int, label: [:0]const u8, time: ?*glib.DateTime) void {
    _ = allocator;
    const dt = time orelse return;
    defer dt.unref();
    const text = dt.format("%c") orelse return;
    defer glib.free(text);
    addRow(grid, row, label, std.mem.span(text));
}

/// "rwxr-xr-x" for the low nine bits of a Unix mode.
fn permissions(buf: *[9]u8, mode: u32) []const u8 {
    const bits = "rwxrwxrwx";
    for (buf, 0..) |*c, i| {
        const shift: u5 = @intCast(8 - i);
        c.* = if ((mode >> shift) & 1 == 1) bits[i] else '-';
    }
    return buf;
}

test "permissions string" {
    var buf: [9]u8 = undefined;
    try std.testing.expectEqualStrings("rwxr-xr-x", permissions(&buf, 0o755));
    try std.testing.expectEqualStrings("rw-r--r--", permissions(&buf, 0o644));
}
