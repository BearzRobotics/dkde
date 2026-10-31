//! dkde-calc: calculator with standard and scientific modes (SPEC.md 5.6).

const std = @import("std");
const gio = @import("gio2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

const eval = @import("eval.zig");

const App = struct {
    allocator: std.mem.Allocator,
    appearance: ?*common.style.Appearance = null,

    fn activate(app: *gtk.Application, self: *App) callconv(.c) void {
        common.style.load(self.allocator) catch |err|
            std.log.warn("stylesheet not loaded: {s}", .{@errorName(err)});
        self.appearance = common.style.Appearance.create(self.allocator) catch null;
        const calc = Calculator.create(self.allocator, app) catch |err| {
            std.log.err("cannot create the window: {s}", .{@errorName(err)});
            return;
        };
        calc.window.as(gtk.Window).present();
    }
};

const Calculator = struct {
    allocator: std.mem.Allocator,
    window: *gtk.ApplicationWindow,
    entry: *gtk.Entry,
    history: *gtk.Label,
    scientific: *gtk.Revealer,
    degrees: bool = true,
    /// Set after "=": the next digit starts a new expression.
    fresh: bool = false,

    const standard_keys = [_][4][:0]const u8{
        .{ "C", "⌫", "(", ")" },
        .{ "7", "8", "9", "÷" },
        .{ "4", "5", "6", "×" },
        .{ "1", "2", "3", "−" },
        .{ "0", ".", "=", "+" },
    };
    const scientific_keys = [_][3][:0]const u8{
        .{ "sin(", "cos(", "tan(" },
        .{ "asin(", "acos(", "atan(" },
        .{ "ln(", "log(", "√" },
        .{ "^", "!", "%" },
        .{ "π", "e", "mod" },
    };

    fn create(allocator: std.mem.Allocator, app: *gtk.Application) !*Calculator {
        const self = try allocator.create(Calculator);
        self.* = .{
            .allocator = allocator,
            .window = gtk.ApplicationWindow.new(app),
            .entry = gtk.Entry.new(),
            .history = gtk.Label.new(""),
            .scientific = gtk.Revealer.new(),
        };
        const window = self.window;
        window.as(gtk.Window).setTitle(common.tr("Calculator"));
        window.as(gtk.Window).setResizable(0);
        window.as(gtk.Window).setDefaultSize(340, -1);
        window.as(gtk.Widget).addCssClass("dkde");

        _ = common.header.create(window.as(gtk.Window), "accessories-calculator", true);

        const mb = common.menubar;
        const menus = [_]mb.Menu{
            .{ .label = "_File", .entries = &.{
                mb.item("E_xit", "close", "<Control>q"),
            } },
            .{ .label = "_Edit", .entries = &.{
                mb.item("_Copy", "copy", "<Control>c"),
                mb.item("_Paste", "paste", "<Control>v"),
                .separator,
                mb.item("C_lear", "clear", "Escape"),
            } },
            .{ .label = "_View", .entries = &.{
                mb.check("_Scientific", "scientific", false),
                mb.check("_Degrees (off for radians)", "degrees", true),
            } },
        };
        const menu_bar = mb.build(app, window, &menus, Calculator, onMenuAction, self);

        const root = gtk.Box.new(.vertical, 8);
        root.as(gtk.Widget).setMarginTop(12);
        root.as(gtk.Widget).setMarginBottom(12);
        root.as(gtk.Widget).setMarginStart(12);
        root.as(gtk.Widget).setMarginEnd(12);

        self.history.setXalign(1);
        self.history.as(gtk.Widget).addCssClass("dim-label");
        root.append(self.history.as(gtk.Widget));

        self.entry.setAlignment(1);
        self.entry.as(gtk.Widget).addCssClass("dkde-calc-display");
        self.entry.setPlaceholderText("0");
        _ = gtk.Entry.signals.activate.connect(self.entry, *Calculator, &onActivate, self, .{});
        const keys = gtk.EventControllerKey.new();
        keys.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *Calculator, &onKey, self, .{});
        self.entry.as(gtk.Widget).addController(keys.as(gtk.EventController));
        root.append(self.entry.as(gtk.Widget));

        const body = gtk.Box.new(.horizontal, 8);
        body.as(gtk.Widget).setHexpand(1);

        const sci_grid = gtk.Grid.new();
        sci_grid.setRowSpacing(4);
        sci_grid.setColumnSpacing(4);
        sci_grid.setRowHomogeneous(1);
        sci_grid.setColumnHomogeneous(1);
        for (scientific_keys, 0..) |row, y| {
            for (row, 0..) |label, x| sci_grid.attach(self.keyButton(label).as(gtk.Widget), @intCast(x), @intCast(y), 1, 1);
        }
        self.scientific.setChild(sci_grid.as(gtk.Widget));
        self.scientific.setTransitionType(.slide_right);
        body.append(self.scientific.as(gtk.Widget));

        const grid = gtk.Grid.new();
        grid.setRowSpacing(4);
        grid.setColumnSpacing(4);
        grid.setRowHomogeneous(1);
        grid.setColumnHomogeneous(1);
        for (standard_keys, 0..) |row, y| {
            for (row, 0..) |label, x| grid.attach(self.keyButton(label).as(gtk.Widget), @intCast(x), @intCast(y), 1, 1);
        }
        grid.as(gtk.Widget).setSizeRequest(300, 250);
        grid.as(gtk.Widget).setHexpand(1);
        body.append(grid.as(gtk.Widget));
        root.append(body.as(gtk.Widget));

        const outer = gtk.Box.new(.vertical, 0);
        outer.append(menu_bar.as(gtk.Widget));
        outer.append(root.as(gtk.Widget));
        window.as(gtk.Window).setChild(outer.as(gtk.Widget));
        _ = self.entry.as(gtk.Widget).grabFocus();
        _ = gtk.Widget.signals.destroy.connect(window, *Calculator, &onDestroy, self, .{});
        return self;
    }

    fn onDestroy(_: *gtk.ApplicationWindow, self: *Calculator) callconv(.c) void {
        self.allocator.destroy(self);
    }

    fn keyButton(self: *Calculator, label: [:0]const u8) *gtk.Button {
        const button = gtk.Button.newWithLabel(label);
        const is_operator = std.mem.eql(u8, label, "=");
        if (is_operator) button.as(gtk.Widget).addCssClass("suggested-action");
        const key = Key.make(self, label);
        _ = gtk.Button.signals.clicked.connect(button, *Key, &onKeyClicked, key, .{});
        _ = gtk.Widget.signals.destroy.connect(button, *Key, &onKeyDestroy, key, .{});
        return button;
    }

    // Button context; allocated per key and freed with the button.
    const Key = struct {
        calc: *Calculator,
        label: [:0]const u8,
        fn make(calc: *Calculator, label: [:0]const u8) *Key {
            const key = calc.allocator.create(Key) catch @panic("OOM");
            key.* = .{ .calc = calc, .label = label };
            return key;
        }
    };

    fn onKeyDestroy(_: *gtk.Button, key: *Key) callconv(.c) void {
        key.calc.allocator.destroy(key);
    }

    fn onKeyClicked(_: *gtk.Button, key: *Key) callconv(.c) void {
        key.calc.press(key.label);
    }

    fn press(self: *Calculator, label: []const u8) void {
        const eql = std.mem.eql;
        if (eql(u8, label, "C")) {
            self.entry.as(gtk.Editable).setText("");
            self.history.setText("");
            self.fresh = false;
        } else if (eql(u8, label, "⌫")) {
            self.backspace();
        } else if (eql(u8, label, "=")) {
            self.calculate();
        } else {
            self.insert(label);
        }
        _ = self.entry.as(gtk.Widget).grabFocus();
        self.entry.as(gtk.Editable).setPosition(-1);
    }

    fn insert(self: *Calculator, text: []const u8) void {
        // After a result, typing a number starts over; an operator continues it.
        if (self.fresh) {
            const continues = text.len == 0 or !std.ascii.isDigit(text[0]) and !std.ascii.isAlphabetic(text[0]) and !std.mem.startsWith(u8, text, "π") and !std.mem.startsWith(u8, text, "√");
            if (!continues) self.entry.as(gtk.Editable).setText("");
            self.fresh = false;
        }
        var buf: [128]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{text}, 0) catch return;
        var pos: c_int = -1;
        self.entry.as(gtk.Editable).insertText(z, -1, &pos);
    }

    fn backspace(self: *Calculator) void {
        const text = std.mem.span(self.entry.as(gtk.Editable).getText());
        if (text.len == 0) return;
        // Remove one whole UTF-8 character.
        var end = text.len - 1;
        while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
        var buf: [256]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{text[0..end]}, 0) catch return;
        self.entry.as(gtk.Editable).setText(z);
    }

    fn calculate(self: *Calculator) void {
        const text = std.mem.span(self.entry.as(gtk.Editable).getText());
        if (text.len == 0) return;
        const mode: eval.AngleMode = if (self.degrees) .degrees else .radians;
        const value = eval.evaluate(text, mode) catch |err| {
            self.history.setText(switch (err) {
                error.DivisionByZero => common.tr("Cannot divide by zero"),
                error.Domain => common.tr("Result is undefined"),
                error.UnknownName => common.tr("Unknown function"),
                error.Syntax => common.tr("Invalid expression"),
            });
            return;
        };
        var result_buf: [64]u8 = undefined;
        const result = eval.format(&result_buf, value);
        var line: [320]u8 = undefined;
        const history = std.fmt.bufPrintSentinel(&line, "{s} =", .{text}, 0) catch return;
        self.history.setText(history);
        var out: [96]u8 = undefined;
        const result_z = std.fmt.bufPrintSentinel(&out, "{s}", .{result}, 0) catch return;
        self.entry.as(gtk.Editable).setText(result_z);
        self.fresh = true;
    }

    fn onActivate(_: *gtk.Entry, self: *Calculator) callconv(.c) void {
        self.calculate();
    }

    /// Escape clears; everything else is the entry's own typing.
    fn onKey(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, _: @import("gdk4").ModifierType, self: *Calculator) callconv(.c) c_int {
        if (keyval == @import("gdk4").KEY_Escape) {
            self.press("C");
            return 1;
        }
        return 0;
    }

    fn onMenuAction(self: *Calculator, action: []const u8) void {
        const eql = std.mem.eql;
        if (eql(u8, action, "close")) return self.window.as(gtk.Window).close();
        if (eql(u8, action, "clear")) return self.press("C");
        if (eql(u8, action, "copy")) {
            self.entry.as(gtk.Widget).getClipboard().setText(self.entry.as(gtk.Editable).getText());
            return;
        }
        if (eql(u8, action, "paste")) {
            _ = self.entry.as(gtk.Widget).activateAction("clipboard.paste", null);
            return;
        }
        if (eql(u8, action, "scientific")) {
            self.scientific.setRevealChild(@intFromBool(self.scientific.getRevealChild() == 0));
            self.window.as(gtk.Window).setDefaultSize(-1, -1);
            return;
        }
        if (eql(u8, action, "degrees")) self.degrees = !self.degrees;
    }
};

pub const std_options: std.Options = .{ .logFn = common.log.logFn, .log_level = .debug };

pub fn main(init: std.process.Init.Minimal) !void {
    common.perf.init();
    var debug_allocator: common.perf.Gpa = .{};
    defer debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var app: App = .{ .allocator = allocator };
    defer if (app.appearance) |a| a.destroy();

    const gtk_app = gtk.Application.new("org.dkde.calc", .{ .non_unique = true });
    defer gtk_app.as(gobject.Object).unref();
    _ = gio.Application.signals.activate.connect(gtk_app, *App, &App.activate, &app, .{});
    const status = gio.Application.run(gtk_app.as(gio.Application), @intCast(init.args.vector.len), @ptrCast(@constCast(init.args.vector.ptr)));
    if (status != 0) std.process.exit(@intCast(status));
}

test {
    _ = @import("eval.zig");
}
