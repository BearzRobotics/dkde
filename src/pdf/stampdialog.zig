// SPDX-License-Identifier: GPL-2.0-or-later
//! The window that asks what to stamp on the pages (see `stamp.zig`).

const std = @import("std");
const common = @import("common");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const stamp = @import("stamp.zig");

const Allocator = std.mem.Allocator;

/// What the person chose. The slices are only good during the call.
pub const Choice = struct {
    /// Pages as typed ("1-3, 5"; empty for all).
    pages: []const u8,
    /// The text to draw, or null for a picture.
    text: ?[]const u8,
    image_path: [:0]const u8,
    position: stamp.Position,
    /// The picture's width and the opacity, 0 to 1.
    width: f64,
    opacity: f64,
    under: bool,
};

/// `apply(context, choice)` returns true when the stamp is on, which closes
/// the window; false leaves it open to be corrected.
pub const Apply = struct {
    context: *anyopaque,
    apply: *const fn (*anyopaque, Choice) bool,
};

const Dialog = struct {
    allocator: Allocator,
    window: *gtk.Window,
    kind: *gtk.DropDown,
    text: *gtk.Entry,
    image: *gtk.Entry,
    position: *gtk.DropDown,
    width: *gtk.SpinButton,
    opacity: *gtk.SpinButton,
    under: *gtk.CheckButton,
    pages: *gtk.Entry,
    text_rows: [2]*gtk.Widget = undefined,
    image_rows: [7]*gtk.Widget = undefined,
    receiver: Apply,
    /// File dialogs still to answer: the memory waits for them.
    waiting: u32 = 0,
    closed: bool = false,

    fn onDestroy(_: *gtk.Window, self: *Dialog) callconv(.c) void {
        self.closed = true;
        if (self.waiting == 0) self.allocator.destroy(self);
    }

    fn onKind(_: *gobject.Object, _: *gobject.ParamSpec, self: *Dialog) callconv(.c) void {
        self.showRows();
    }

    fn showRows(self: *Dialog) void {
        const picture = self.kind.getSelected() == 1;
        for (self.text_rows) |w| w.setVisible(@intFromBool(!picture));
        for (self.image_rows) |w| w.setVisible(@intFromBool(picture));
        // A watermark is faint; a picture such as a signature is solid.
        self.opacity.setValue(if (picture) 100 else 25);
    }

    fn onChoose(_: *gtk.Button, self: *Dialog) callconv(.c) void {
        const dialog = gtk.FileDialog.new();
        defer dialog.as(gobject.Object).unref();
        self.waiting += 1;
        dialog.open(self.window, null, onChosen, self);
    }

    fn onChosen(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Dialog = @ptrCast(@alignCast(data.?));
        const dialog: *gtk.FileDialog = @ptrCast(@alignCast(source.?));
        var err: ?*glib.Error = null;
        const chosen = dialog.openFinish(result, &err);
        if (err) |e| e.free();
        defer if (chosen) |file| file.as(gobject.Object).unref();
        self.waiting -= 1;
        if (self.closed) {
            if (self.waiting == 0) self.allocator.destroy(self);
            return;
        }
        const file = chosen orelse return;
        const path = file.getPath() orelse return;
        defer glib.free(path);
        self.image.as(gtk.Editable).setText(path);
    }

    fn onApply(_: *gtk.Button, self: *Dialog) callconv(.c) void {
        const picture = self.kind.getSelected() == 1;
        const done = self.receiver.apply(self.receiver.context, .{
            .pages = std.mem.span(self.pages.as(gtk.Editable).getText()),
            .text = if (picture) null else std.mem.span(self.text.as(gtk.Editable).getText()),
            .image_path = std.mem.span(self.image.as(gtk.Editable).getText()),
            .position = @fromBackingInt(@intCast(@min(self.position.getSelected(), 8))),
            .width = self.width.getValue() / 100,
            .opacity = self.opacity.getValue() / 100,
            .under = self.under.getActive() != 0,
        });
        if (done) self.window.destroy();
    }

    fn onCancel(_: *gtk.Button, self: *Dialog) callconv(.c) void {
        self.window.destroy();
    }
};

/// A label in the first column and `field` beside it; returns both.
fn row(grid: *gtk.Grid, at: c_int, label: [:0]const u8, field: *gtk.Widget) [2]*gtk.Widget {
    const l = gtk.Label.new(label);
    l.setXalign(0);
    grid.attach(l.as(gtk.Widget), 0, at, 1, 1);
    field.setHexpand(1);
    grid.attach(field, 1, at, 1, 1);
    return .{ l.as(gtk.Widget), field };
}

pub fn show(allocator: Allocator, parent: *gtk.Window, receiver: Apply) error{OutOfMemory}!void {
    const self = try allocator.create(Dialog);
    const kinds = [_:null]?[*:0]const u8{ common.tr("Text watermark"), common.tr("Picture") };
    const positions = [_:null]?[*:0]const u8{
        common.tr("Top left"),    common.tr("Top"),    common.tr("Top right"),
        common.tr("Left"),        common.tr("Centre"), common.tr("Right"),
        common.tr("Bottom left"), common.tr("Bottom"), common.tr("Bottom right"),
    };
    const window = gtk.Window.new();
    self.* = .{
        .allocator = allocator,
        .window = window,
        .kind = gtk.DropDown.newFromStrings(@ptrCast(&kinds)),
        .text = gtk.Entry.new(),
        .image = gtk.Entry.new(),
        .position = gtk.DropDown.newFromStrings(@ptrCast(&positions)),
        .width = gtk.SpinButton.newWithRange(1, 100, 1),
        .opacity = gtk.SpinButton.newWithRange(1, 100, 5),
        .under = gtk.CheckButton.newWithLabel(common.tr("Behind what the page shows (a scanned page hides it)")),
        .pages = gtk.Entry.new(),
        .receiver = receiver,
    };
    window.setTitle(common.tr("Stamp or Watermark"));
    window.setTransientFor(parent);
    window.setModal(1);
    window.setDestroyWithParent(1);
    window.setDefaultSize(460, -1);
    common.dialogs.closeOnEscape(window);
    _ = gtk.Widget.signals.destroy.connect(window, *Dialog, &Dialog.onDestroy, self, .{});

    const grid = gtk.Grid.new();
    grid.setRowSpacing(8);
    grid.setColumnSpacing(10);
    const widget = grid.as(gtk.Widget);
    widget.setMarginStart(12);
    widget.setMarginEnd(12);
    widget.setMarginTop(12);
    widget.setMarginBottom(12);

    _ = row(grid, 0, common.tr("Kind"), self.kind.as(gtk.Widget));
    self.text.as(gtk.Editable).setText("DRAFT");
    self.text_rows = row(grid, 1, common.tr("Text"), self.text.as(gtk.Widget));

    const file_box = gtk.Box.new(.horizontal, 6);
    self.image.as(gtk.Widget).setHexpand(1);
    file_box.append(self.image.as(gtk.Widget));
    const choose = gtk.Button.newWithLabel(common.tr("Choose\u{2026}"));
    _ = gtk.Button.signals.clicked.connect(choose, *Dialog, &Dialog.onChoose, self, .{});
    file_box.append(choose.as(gtk.Widget));
    const first = row(grid, 2, common.tr("Picture file"), file_box.as(gtk.Widget));
    const second = row(grid, 3, common.tr("Place"), self.position.as(gtk.Widget));
    self.position.setSelected(8);
    self.width.setValue(25);
    const third = row(grid, 4, common.tr("Width (% of page)"), self.width.as(gtk.Widget));

    _ = row(grid, 5, common.tr("Opacity (%)"), self.opacity.as(gtk.Widget));
    self.pages.setPlaceholderText(common.tr("All pages, or for example 1-3, 5"));
    _ = row(grid, 6, common.tr("Pages"), self.pages.as(gtk.Widget));
    grid.attach(self.under.as(gtk.Widget), 0, 7, 2, 1);
    const note = gtk.Label.new(common.tr("A picture of a signature does not sign the document."));
    note.setXalign(0);
    note.setWrap(1);
    grid.attach(note.as(gtk.Widget), 0, 8, 2, 1);
    self.image_rows = first ++ second ++ third ++ [1]*gtk.Widget{note.as(gtk.Widget)};

    const buttons = gtk.Box.new(.horizontal, 6);
    buttons.as(gtk.Widget).setHalign(.end);
    const cancel = gtk.Button.newWithLabel(common.tr("Cancel"));
    const add = gtk.Button.newWithLabel(common.tr("Add"));
    add.as(gtk.Widget).addCssClass("suggested-action");
    _ = gtk.Button.signals.clicked.connect(cancel, *Dialog, &Dialog.onCancel, self, .{});
    _ = gtk.Button.signals.clicked.connect(add, *Dialog, &Dialog.onApply, self, .{});
    buttons.append(cancel.as(gtk.Widget));
    buttons.append(add.as(gtk.Widget));
    grid.attach(buttons.as(gtk.Widget), 0, 9, 2, 1);

    window.setChild(widget);
    self.showRows();
    _ = gobject.Object.signals.notify.connect(self.kind.as(gobject.Object), *Dialog, &Dialog.onKind, self, .{ .detail = "selected" });
    window.present();
}
