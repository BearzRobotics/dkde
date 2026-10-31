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
    window.setDefaultSize(400, -1);
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
    const edit = std.heap.c_allocator.create(Edit) catch return;
    edit.* = .{ .file = @ptrCast(file.as(gobject.Object).ref()), .window = window, .name = gtk.Entry.new() };
    {
        const key = gtk.Label.new(common.tr("Name"));
        key.setXalign(1);
        key.as(gtk.Widget).addCssClass("dim-label");
        grid.attach(key.as(gtk.Widget), 0, row, 1, 1);
        edit.name.as(gtk.Editable).setText(info.getDisplayName());
        edit.name.as(gtk.Widget).setHexpand(1);
        grid.attach(edit.name.as(gtk.Widget), 1, row, 1, 1);
        row += 1;
    }

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
        addRow(grid, &row, common.tr("Owner"), text[11..]);
        edit.original_mode = mode & 0o777;
        edit.has_mode = true;
        const perm = gtk.Grid.new();
        perm.setColumnSpacing(14);
        perm.setRowSpacing(4);
        const heads = [_][:0]const u8{ "Read", "Write", "Run" };
        const rows = [_][:0]const u8{ "Owner", "Group", "Others" };
        inline for (heads, 0..) |h, c| {
            const l = gtk.Label.new(common.tr(h));
            l.as(gtk.Widget).addCssClass("dim-label");
            perm.attach(l.as(gtk.Widget), @intCast(c + 1), 0, 1, 1);
        }
        inline for (rows, 0..) |name, r| {
            const l = gtk.Label.new(common.tr(name));
            l.setXalign(0);
            perm.attach(l.as(gtk.Widget), 0, @intCast(r + 1), 1, 1);
            for (0..3) |c| {
                const shift: u5 = @intCast(8 - (r * 3 + c));
                const check = gtk.CheckButton.new();
                check.setActive(@intCast((mode >> shift) & 1));
                perm.attach(check.as(gtk.Widget), @intCast(c + 1), @intCast(r + 1), 1, 1);
                edit.checks[r * 3 + c] = check;
            }
        }
        const key = gtk.Label.new(common.tr("Permissions"));
        key.setXalign(1);
        key.setYalign(0);
        key.as(gtk.Widget).addCssClass("dim-label");
        grid.attach(key.as(gtk.Widget), 0, row, 1, 1);
        grid.attach(perm.as(gtk.Widget), 1, row, 1, 1);
        row += 1;
    }

    const buttons = gtk.Box.new(.horizontal, 8);
    buttons.as(gtk.Widget).setHalign(.end);
    buttons.as(gtk.Widget).setMarginTop(8);
    const cancel = gtk.Button.newWithLabel(common.tr("Cancel"));
    const ok = gtk.Button.newWithLabel(common.tr("OK"));
    ok.as(gtk.Widget).addCssClass("suggested-action");
    buttons.append(cancel.as(gtk.Widget));
    buttons.append(ok.as(gtk.Widget));
    grid.attach(buttons.as(gtk.Widget), 0, row, 2, 1);
    _ = gtk.Button.signals.clicked.connect(cancel, *Edit, &onCancel, edit, .{});
    _ = gtk.Button.signals.clicked.connect(ok, *Edit, &onOk, edit, .{});
    _ = gtk.Widget.signals.destroy.connect(window, *Edit, &onDestroy, edit, .{});

    window.present();
}

/// What the dialog can change: the name and the nine permission bits.
const Edit = struct {
    file: *gio.File,
    window: *gtk.Window,
    name: *gtk.Entry,
    checks: [9]*gtk.CheckButton = undefined,
    has_mode: bool = false,
    original_mode: u32 = 0,
};

fn onCancel(_: *gtk.Button, edit: *Edit) callconv(.c) void {
    edit.window.destroy();
}

fn onDestroy(_: *gtk.Window, edit: *Edit) callconv(.c) void {
    edit.file.as(gobject.Object).unref();
    std.heap.c_allocator.destroy(edit);
}

fn onOk(_: *gtk.Button, edit: *Edit) callconv(.c) void {
    var err: ?*glib.Error = null;
    if (edit.has_mode) {
        var mode: u32 = 0;
        for (edit.checks, 0..) |c, i| {
            if (c.getActive() != 0) mode |= @as(u32, 1) << @intCast(8 - i);
        }
        if (mode != edit.original_mode) {
            const info = edit.file.queryInfo("unix::mode", .{}, null, null);
            const full: u32 = if (info) |i| i.getAttributeUint32("unix::mode") else 0;
            if (info) |i| i.as(gobject.Object).unref();
            if (edit.file.setAttributeUint32("unix::mode", (full & ~@as(u32, 0o777)) | mode, .{}, null, &err) == 0) {
                return fail(edit, common.tr("Cannot change the permissions"), err);
            }
        }
    }
    const new_name = std.mem.span(edit.name.as(gtk.Editable).getText());
    const base = edit.file.getBasename();
    defer if (base) |b| glib.free(b);
    if (new_name.len > 0 and (base == null or !std.mem.eql(u8, new_name, std.mem.span(base.?))) and std.mem.indexOfScalar(u8, new_name, '/') == null) {
        if (edit.file.setDisplayName(edit.name.as(gtk.Editable).getText(), null, &err)) |renamed| {
            renamed.as(gobject.Object).unref();
        } else return fail(edit, common.tr("Cannot rename the item"), err);
    }
    edit.window.destroy();
}

fn fail(edit: *Edit, message: [:0]const u8, err: ?*glib.Error) void {
    const text = if (err) |e| e.f_message orelse "unknown error" else "unknown error";
    common.dialogs.showError(edit.window, message, std.mem.span(text));
    if (err) |e| e.free();
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
