//! dkde-color: mix a colour with sliders or type a hex code, and copy it as
//! hex, rgb() or hsl() (SPEC.md 5.6). It cannot pick from the screen.

const std = @import("std");
const cairo = @import("cairo1");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

const pure = @import("pure.zig");

pub const std_options: std.Options = .{ .logFn = common.log.logFn, .log_level = .debug };

const ColorTool = struct {
    allocator: std.mem.Allocator,
    window: *gtk.ApplicationWindow,
    swatch: *gtk.DrawingArea,
    sliders: [3]*gtk.Scale,
    hex: *gtk.Entry,
    rgb: *gtk.Entry,
    hsl: *gtk.Entry,
    color: pure.Rgb = .{ .r = 0x35, .g = 0x84, .b = 0xe4 },
    /// Set while the controls are being updated from `color`.
    syncing: bool = false,

    pub fn create(allocator: std.mem.Allocator, app: *gtk.Application) !*ColorTool {
        const self = try allocator.create(ColorTool);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .window = gtk.ApplicationWindow.new(app),
            .swatch = gtk.DrawingArea.new(),
            .sliders = .{ gtk.Scale.newWithRange(.horizontal, 0, 255, 1), gtk.Scale.newWithRange(.horizontal, 0, 255, 1), gtk.Scale.newWithRange(.horizontal, 0, 255, 1) },
            .hex = gtk.Entry.new(),
            .rgb = gtk.Entry.new(),
            .hsl = gtk.Entry.new(),
        };
        const window = self.window.as(gtk.Window);
        window.setTitle(common.tr("Colour"));
        window.setDefaultSize(420, 420);
        self.window.as(gtk.Widget).addCssClass("dkde");
        _ = common.header.create(window, "applications-graphics", true);

        self.swatch.setContentHeight(110);
        self.swatch.setDrawFunc(onDraw, self, null);
        self.swatch.as(gtk.Widget).addCssClass("dkde-color-swatch");

        const box = gtk.Box.new(.vertical, 10);
        box.as(gtk.Widget).setMarginTop(16);
        box.as(gtk.Widget).setMarginBottom(16);
        box.as(gtk.Widget).setMarginStart(16);
        box.as(gtk.Widget).setMarginEnd(16);
        box.append(self.swatch.as(gtk.Widget));

        const names = [_][:0]const u8{ "Red", "Green", "Blue" };
        inline for (self.sliders, names) |scale, name| {
            const row = gtk.Box.new(.horizontal, 8);
            const label = gtk.Label.new(common.tr(name));
            label.setXalign(0);
            label.as(gtk.Widget).setSizeRequest(48, -1);
            scale.as(gtk.Widget).setHexpand(1);
            scale.setDrawValue(1);
            _ = gtk.Range.signals.value_changed.connect(scale.as(gtk.Range), *ColorTool, &onSlider, self, .{});
            row.append(label.as(gtk.Widget));
            row.append(scale.as(gtk.Widget));
            box.append(row.as(gtk.Widget));
        }

        _ = gtk.Editable.signals.changed.connect(self.hex.as(gtk.Editable), *ColorTool, &onHexEdited, self, .{});
        box.append(self.field(common.tr("Hex"), self.hex));
        self.rgb.as(gtk.Editable).setEditable(0);
        self.hsl.as(gtk.Editable).setEditable(0);
        box.append(self.field(common.tr("RGB"), self.rgb));
        box.append(self.field(common.tr("HSL"), self.hsl));
        window.setChild(box.as(gtk.Widget));

        self.apply(self.color, true);
        return self;
    }

    pub fn present(self: *ColorTool) void {
        self.window.as(gtk.Window).present();
    }

    fn field(self: *ColorTool, label_text: [:0]const u8, entry: *gtk.Entry) *gtk.Widget {
        _ = self;
        const row = gtk.Box.new(.horizontal, 8);
        const label = gtk.Label.new(label_text);
        label.setXalign(0);
        label.as(gtk.Widget).setSizeRequest(48, -1);
        entry.as(gtk.Widget).setHexpand(1);
        const copy = gtk.Button.newFromIconName("edit-copy-symbolic");
        copy.as(gtk.Widget).setTooltipText(common.tr("Copy"));
        const Ctx = struct {
            fn clicked(button: *gtk.Button, e: *gtk.Entry) callconv(.c) void {
                button.as(gtk.Widget).getClipboard().setText(e.as(gtk.Editable).getText());
            }
        };
        _ = gtk.Button.signals.clicked.connect(copy, *gtk.Entry, &Ctx.clicked, entry, .{});
        row.append(label.as(gtk.Widget));
        row.append(entry.as(gtk.Widget));
        row.append(copy.as(gtk.Widget));
        return row.as(gtk.Widget);
    }

    fn onDraw(_: *gtk.DrawingArea, cr: *cairo.Context, width: c_int, height: c_int, data: ?*anyopaque) callconv(.c) void {
        const self: *ColorTool = @ptrCast(@alignCast(data.?));
        cr.setSourceRgb(@as(f64, @floatFromInt(self.color.r)) / 255.0, @as(f64, @floatFromInt(self.color.g)) / 255.0, @as(f64, @floatFromInt(self.color.b)) / 255.0);
        cr.rectangle(0, 0, @floatFromInt(width), @floatFromInt(height));
        cr.fill();
    }

    /// Shows `c` everywhere; `skip_hex` leaves the hex box alone while it is being typed in.
    fn apply(self: *ColorTool, c: pure.Rgb, update_hex: bool) void {
        self.color = c;
        self.syncing = true;
        defer self.syncing = false;
        self.sliders[0].as(gtk.Range).setValue(@floatFromInt(c.r));
        self.sliders[1].as(gtk.Range).setValue(@floatFromInt(c.g));
        self.sliders[2].as(gtk.Range).setValue(@floatFromInt(c.b));
        var hex_buf: [7]u8 = undefined;
        var z: [64]u8 = undefined;
        if (update_hex) self.hex.as(gtk.Editable).setText(std.fmt.bufPrintSentinel(&z, "{s}", .{pure.toHex(c, &hex_buf)}, 0) catch "");
        self.rgb.as(gtk.Editable).setText(std.fmt.bufPrintSentinel(&z, "rgb({d}, {d}, {d})", .{ c.r, c.g, c.b }, 0) catch "");
        const hsl = pure.toHsl(c);
        self.hsl.as(gtk.Editable).setText(std.fmt.bufPrintSentinel(&z, "hsl({d}, {d}%, {d}%)", .{ hsl.h, hsl.s, hsl.l }, 0) catch "");
        self.swatch.as(gtk.Widget).queueDraw();
    }

    fn onSlider(_: *gtk.Range, self: *ColorTool) callconv(.c) void {
        if (self.syncing) return;
        const c: pure.Rgb = .{
            .r = @intFromFloat(self.sliders[0].as(gtk.Range).getValue()),
            .g = @intFromFloat(self.sliders[1].as(gtk.Range).getValue()),
            .b = @intFromFloat(self.sliders[2].as(gtk.Range).getValue()),
        };
        self.apply(c, true);
    }

    fn onHexEdited(entry: *gtk.Editable, self: *ColorTool) callconv(.c) void {
        if (self.syncing) return;
        const c = pure.parseHex(std.mem.span(entry.getText())) orelse return;
        self.apply(c, false);
    }
};

pub fn main(init: std.process.Init.Minimal) !void {
    try common.runapp.run("org.dkde.color", ColorTool, init);
}

test {
    _ = @import("pure.zig");
}
