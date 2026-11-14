//! dkde-calc: the calculator (SPEC.md 5.6), on the lines of the Windows 7
//! calculator, GNOME Calculator, KCalc and Qalculate.
//!
//! - Exact arithmetic on fractions and big numbers (num.zig); an entry is an
//!   expression, a variable (x = 5), a function of one's own (f(x) = x² + 1)
//!   or an equation solved for its unknown (eval.zig). Enter works it out;
//!   "=" is part of what is typed.
//! - Standard, Scientific and Programmer keypads (Alt+1, 2, 3); memory keys;
//!   a preview of the result while typing; errors point at where they are.
//! - Panes: History with variables and functions (Ctrl+H), Unit Conversion
//!   (Ctrl+U, also "5 km in mi" in the entry), Date Calculation (Ctrl+E) and
//!   Graph (Ctrl+G).

const std = @import("std");
const cli = @import("cli");
const gdk = @import("gdk4");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

const num = @import("num.zig");
const eval = @import("eval.zig");
const units = @import("units.zig");
const convert = @import("convert.zig");
const rich = @import("rich.zig");
const dates = @import("dates.zig");
const graph_mod = @import("graph.zig");
const simplify = @import("simplify.zig");
const formulas = @import("formulas.zig");
const calculus = @import("calculus.zig");
const quantity = @import("quantity.zig");
const rates = @import("rates.zig");
const highlight = @import("highlight.zig");
const export_session = @import("export.zig");
const pango = @import("pango1");

const t = common.tr;
/// Thousands are grouped with a narrow no-break space, which can never be
/// mistaken for the comma between a function's arguments.
const group_sep = "\u{202F}";

const Mode = enum { standard, scientific, programmer };
const Pane = enum { none, history, units, currency, dates, graph, formulas };

const Cmd = enum { insert, enter, clear, back, negate, reciprocal, mc, mr, ms, mplus, mminus, plot };

const Spec = struct {
    label: [:0]const u8,
    insert: []const u8 = "",
    cmd: Cmd = .insert,
    css: ?[:0]const u8 = null,
    tip: ?[:0]const u8 = null,
};

fn k(label: [:0]const u8, insert: []const u8) Spec {
    return .{ .label = label, .insert = insert };
}

fn op(label: [:0]const u8, insert: []const u8) Spec {
    return .{ .label = label, .insert = insert, .css = "dkde-calc-op" };
}

fn cmd(label: [:0]const u8, c: Cmd, tip: ?[:0]const u8) Spec {
    return .{ .label = label, .cmd = c, .css = "dkde-calc-op", .tip = tip };
}

const enter_key: Spec = .{ .label = "⏎", .cmd = .enter, .css = "dkde-calc-enter", .tip = "Work it out (Enter)" };

const standard_keys = [_][5]Spec{
    .{ cmd("C", .clear, "Clear (Esc)"), cmd("⌫", .back, "Delete the last character (BackSpace)"), op("(", "("), op(")", ")"), op("÷", "÷") },
    .{ k("7", "7"), k("8", "8"), k("9", "9"), op("×", "×"), op("√", "√(") },
    .{ k("4", "4"), k("5", "5"), k("6", "6"), op("−", "−"), op("x²", "²") },
    .{ k("1", "1"), k("2", "2"), k("3", "3"), op("+", "+"), op("%", "%") },
    .{ cmd("±", .negate, "Change the sign"), k("0", "0"), k(".", "."), .{ .label = "=", .insert = "=", .css = "dkde-calc-equals" }, enter_key },
};

const scientific_keys = [_][5]Spec{
    .{ op("sin", "sin("), op("cos", "cos("), op("tan", "tan("), op("π", "π"), op("e", "e") },
    .{ op("asin", "asin("), op("acos", "acos("), op("atan", "atan("), op("x", "x"), op("ans", "ans") },
    .{ op("ln", "ln("), op("log", "log("), op("10ˣ", "10^"), op("eˣ", "e^"), op("xʸ", "^") },
    .{ op("∛", "∛("), op("n!", "!"), op("mod", " mod "), op("|x|", "abs("), cmd("1/x", .reciprocal, "Reciprocal") },
    .{ op("sinh", "sinh("), op("cosh", "cosh("), op("tanh", "tanh("), op(",", ", "), .{ .label = "Plot", .cmd = .plot, .css = "dkde-calc-op", .tip = "Draw the entry as a graph of x" } },
};

const programmer_keys = [_][5]Spec{
    .{ k("A", "A"), k("B", "B"), k("C", "C"), op("And", " and "), op("Or", " or ") },
    .{ k("D", "D"), k("E", "E"), k("F", "F"), op("Xor", " xor "), op("Not", "not ") },
    .{ op("Lsh", " << "), op("Rsh", " >> "), op("RoL", "rol("), op("RoR", "ror("), op("Mod", " mod ") },
};

const memory_keys = [_]Spec{
    cmd("MC", .mc, "Clear the memory"),
    cmd("MR", .mr, "Recall the memory"),
    cmd("MS", .ms, "Store the result in the memory"),
    cmd("M+", .mplus, "Add the result to the memory"),
    cmd("M−", .mminus, "Subtract the result from the memory"),
};

const HistoryItem = struct { expr: []u8, result: []u8 };

/// The formula in the entry: a built-in one or one of the user's own.
const Picked = union(enum) { builtin: usize, own: usize };

/// A field of the Formulas pane: a value for one letter.
const Field = struct { calc: *Calc, name: []u8, entry: *gtk.Entry };

const Key = struct { calc: *Calc, spec: *const Spec };

const Calc = struct {
    gpa: std.mem.Allocator,
    app: *gtk.Application,
    window: *gtk.ApplicationWindow,
    config: common.Config,
    session: eval.Session,

    entry: *gtk.Entry,
    expr_label: *gtk.Label,
    preview: *gtk.Label,
    memory_label: *gtk.Label,
    keypad: *gtk.Box,
    bases: *gtk.Box,
    bits: *gtk.Grid,
    side: *gtk.Stack,
    history_list: *gtk.ListBox,
    vars_list: *gtk.ListBox,
    graph: *graph_mod.Graph,
    formula_list: *gtk.ListBox,
    formula_form: *gtk.Box,
    formula_search: *gtk.SearchEntry,

    /// The entry holds a formula from the Formulas pane: Enter solves it.
    formula: ?Picked = null,
    /// The user's own formulas ("Save Entry as Formula").
    own_formulas: std.ArrayList([]u8) = .empty,
    formula_fields: std.ArrayList(Field) = .empty,
    /// The Formulas pane's Graph button, and what it would draw.
    formula_graph: ?*gtk.Button = null,
    graph_plan: ?struct { expr: []u8, y: []u8, x: []u8 } = null,

    mode: Mode = .standard,
    pane: Pane = .none,
    /// The exact form (2√2) of the result being shown, for the line above the entry.
    exact_tail: ?[]const u8 = null,
    /// The tape of recent entries above the entry (View > Expanded).
    expanded: bool = false,
    tape_scroll: *gtk.ScrolledWindow = undefined,
    tape_list: *gtk.ListBox = undefined,
    /// The tape is at the newest line (set when it changes; scrolling up is free until the next change).
    tape_stick: bool = true,
    angle: eval.Angle = .degrees,
    base: u8 = 10,
    word: u8 = 64,
    style: num.Style = .{ .group_sep = group_sep },

    /// The entry shows a result: typing a digit starts again, an operator goes on.
    fresh: bool = false,
    /// The last result, unformatted (to go on from).
    plain: ?[]u8 = null,
    /// The value of the last result or preview in programmer mode, for the bits.
    int_value: i128 = 0,
    memory: ?eval.Stored = null,
    history: std.ArrayList(HistoryItem) = .empty,
    /// Up and Down in the entry go through the history.
    recall: ?usize = null,
    keys: std.ArrayList(*Key) = .empty,
    bit_buttons: [64]*gtk.Button = undefined,
    base_labels: [4]*gtk.Label = undefined,
    finished: bool = false,
    /// The entry is being set by the calculator, not typed in.
    quiet: bool = false,

    // Unit Conversion.
    unit_category: *gtk.DropDown = undefined,
    unit_from: *gtk.DropDown = undefined,
    unit_to: *gtk.DropDown = undefined,
    unit_value: *gtk.Entry = undefined,
    unit_result: *gtk.Label = undefined,
    // Currency.
    cur_from: *gtk.DropDown = undefined,
    cur_to: *gtk.DropDown = undefined,
    cur_value: *gtk.Entry = undefined,
    cur_result: *gtk.Label = undefined,
    cur_status: *gtk.Label = undefined,
    cur_button: *gtk.Button = undefined,
    /// The rates in use, in their own arena (quantity.zig points into it).
    rate_arena: ?std.heap.ArenaAllocator = null,
    /// The fetched rates (in rate_arena) and the ones typed in by hand (strings owned by gpa).
    fetched: []const quantity.Currency = &.{},
    manual: std.ArrayList(quantity.Currency) = .empty,
    cur_manual: *gtk.Entry = undefined,
    updating: bool = false,
    /// The Currency pane exists (rates can load before it is built).
    cur_ready: bool = false,
    // Date Calculation.
    date_kind: *gtk.DropDown = undefined,
    date_system: *gtk.DropDown = undefined,
    date_sys: dates.System = .gregorian,
    date_fields: std.ArrayList(*DateField) = .empty,
    date_pages: *gtk.Stack = undefined,
    date_from: *gtk.Entry = undefined,
    date_to: *gtk.Entry = undefined,
    date_start: *gtk.Entry = undefined,
    date_sign: *gtk.DropDown = undefined,
    date_years: *gtk.SpinButton = undefined,
    date_months: *gtk.SpinButton = undefined,
    date_days: *gtk.SpinButton = undefined,
    date_result: *gtk.Label = undefined,

    pub fn create(gpa: std.mem.Allocator, app: *gtk.Application) !*Calc {
        const self = try gpa.create(Calc);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .app = app,
            .window = gtk.ApplicationWindow.new(app),
            .config = try common.Config.load(gpa, "calc.toml"),
            .session = .{ .gpa = gpa },
            .entry = gtk.Entry.new(),
            .expr_label = gtk.Label.new(""),
            .preview = gtk.Label.new(""),
            .memory_label = gtk.Label.new(""),
            .keypad = gtk.Box.new(.horizontal, 8),
            .bases = gtk.Box.new(.vertical, 0),
            .bits = gtk.Grid.new(),
            .side = gtk.Stack.new(),
            .history_list = gtk.ListBox.new(),
            .vars_list = gtk.ListBox.new(),
            .graph = undefined,
            .formula_list = gtk.ListBox.new(),
            .formula_form = gtk.Box.new(.vertical, 6),
            .formula_search = gtk.SearchEntry.new(),
        };
        self.graph = try graph_mod.Graph.create(gpa, &self.session);
        self.readSettings();
        self.loadState();
        self.loadManualRates();
        self.loadRates();
        quantity.today_fn = &todayDays;

        const win = self.window.as(gtk.Window);
        win.setTitle(t("Calculator"));
        win.setDefaultSize(self.config.getInt("calc", "width", 380), self.config.getInt("calc", "height", 520));
        self.window.as(gtk.Widget).addCssClass("dkde");
        _ = common.header.create(win, "accessories-calculator", true);

        const menu_bar = self.buildMenus();

        // The display.
        const display = gtk.Box.new(.vertical, 2);
        display.as(gtk.Widget).addCssClass("dkde-calc-screen");
        // The tape: recent entries and answers, oldest at the top (View > Expanded).
        self.tape_scroll = gtk.ScrolledWindow.new();
        self.tape_list = gtk.ListBox.new();
        self.tape_scroll.setChild(self.tape_list.as(gtk.Widget));
        self.tape_scroll.setPolicy(.never, .automatic);
        self.tape_scroll.setMinContentHeight(170);
        const adj = self.tape_scroll.getVadjustment();
        _ = gtk.Adjustment.signals.changed.connect(adj, *Calc, &onTapeSized, self, .{});
        _ = gobject.Object.signals.notify.connect(adj, *Calc, &onTapeNotify, self, .{ .detail = "upper" });
        _ = gobject.Object.signals.notify.connect(adj, *Calc, &onTapeNotify, self, .{ .detail = "page-size" });
        self.tape_list.setSelectionMode(.none);
        self.tape_list.setActivateOnSingleClick(1);
        self.tape_list.as(gtk.Widget).addCssClass("dkde-calc-history");
        _ = gtk.ListBox.signals.row_activated.connect(self.tape_list, *Calc, &onTapeRow, self, .{});
        self.tape_scroll.as(gtk.Widget).setTooltipText(t("Click a line to use its result."));
        self.tape_scroll.as(gtk.Widget).setVisible(@intFromBool(self.expanded));
        display.append(self.tape_scroll.as(gtk.Widget));
        const top = gtk.Box.new(.horizontal, 6);
        self.memory_label.as(gtk.Widget).addCssClass("dkde-calc-memory");
        self.memory_label.as(gtk.Widget).setTooltipText(t("A value is in the memory"));
        top.append(self.memory_label.as(gtk.Widget));
        self.expr_label.setXalign(1);
        self.expr_label.setEllipsize(.start);
        self.expr_label.setSelectable(1);
        self.expr_label.as(gtk.Widget).setHexpand(1);
        self.expr_label.as(gtk.Widget).addCssClass("dkde-calc-expr");
        top.append(self.expr_label.as(gtk.Widget));
        display.append(top.as(gtk.Widget));
        self.entry.setAlignment(1);
        self.entry.as(gtk.Widget).addCssClass("dkde-calc-display");
        self.entry.setPlaceholderText("0");
        _ = gtk.Entry.signals.activate.connect(self.entry, *Calc, &onActivate, self, .{});
        _ = gtk.Editable.signals.changed.connect(self.entry.as(gtk.Editable), *Calc, &onChanged, self, .{});
        _ = gobject.Object.signals.notify.connect(self.entry, *Calc, &onCursorMoved, self, .{ .detail = "cursor-position" });
        display.append(self.entry.as(gtk.Widget));
        self.preview.setXalign(1);
        self.preview.setEllipsize(.end);
        self.preview.setSelectable(1);
        self.preview.as(gtk.Widget).addCssClass("dkde-calc-preview");
        display.append(self.preview.as(gtk.Widget));

        // Programmer: the value in every base, and its bits.
        self.buildBases();
        self.buildBits();

        const memory = gtk.Grid.new();
        memory.setColumnHomogeneous(1);
        memory.setColumnSpacing(4);
        for (&memory_keys, 0..) |*s, i| {
            const key = self.keyButton(s);
            // The memory row stays one key high; the keypad below takes the room.
            key.setVexpand(0);
            memory.attach(key, @intCast(i), 0, 1, 1);
        }

        self.keypad.as(gtk.Widget).setVexpand(1);
        self.keypad.setHomogeneous(0);

        const left = gtk.Box.new(.vertical, 8);
        left.as(gtk.Widget).setMarginTop(10);
        left.as(gtk.Widget).setMarginBottom(10);
        left.as(gtk.Widget).setMarginStart(10);
        left.as(gtk.Widget).setMarginEnd(10);
        left.as(gtk.Widget).setHexpand(1);
        left.append(display.as(gtk.Widget));
        left.append(self.bases.as(gtk.Widget));
        left.append(self.bits.as(gtk.Widget));
        left.append(memory.as(gtk.Widget));
        left.append(self.keypad.as(gtk.Widget));

        // The panes on the right.
        self.side.as(gtk.Widget).setSizeRequest(320, -1);
        self.side.as(gtk.Widget).setMarginTop(10);
        self.side.as(gtk.Widget).setMarginBottom(10);
        self.side.as(gtk.Widget).setMarginEnd(10);
        self.side.as(gtk.Widget).setHexpand(1);
        _ = self.side.addNamed(self.buildHistory(), "history");
        _ = self.side.addNamed(self.buildUnits(), "units");
        _ = self.side.addNamed(self.buildCurrency(), "currency");
        _ = self.side.addNamed(self.buildDates(), "dates");
        _ = self.side.addNamed(self.graph.widget(), "graph");
        _ = self.side.addNamed(self.buildFormulas(), "formulas");

        const body = gtk.Box.new(.horizontal, 0);
        body.append(left.as(gtk.Widget));
        body.append(self.side.as(gtk.Widget));
        body.as(gtk.Widget).setVexpand(1);

        const root = gtk.Box.new(.vertical, 0);
        root.append(menu_bar);
        root.append(body.as(gtk.Widget));
        win.setChild(root.as(gtk.Widget));

        const keys = gtk.EventControllerKey.new();
        keys.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *Calc, &onKey, self, .{});
        self.window.as(gtk.Widget).addController(keys.as(gtk.EventController));

        _ = gtk.Window.signals.close_request.connect(win, *Calc, &onCloseRequest, self, .{});
        _ = gtk.Widget.signals.destroy.connect(self.window, *Calc, &onDestroy, self, .{});

        self.setMode(self.mode);
        self.showPane(self.pane);
        self.fillHistory();
        self.fillVars();
        self.updateMemory();
        _ = self.entry.as(gtk.Widget).grabFocus();
        return self;
    }

    pub fn present(self: *Calc) void {
        self.window.as(gtk.Window).present();
    }

    fn readSettings(self: *Calc) void {
        var buf: [32]u8 = undefined;
        self.mode = std.meta.stringToEnum(Mode, self.configString(&buf, "mode", "standard")) orelse .standard;
        self.pane = std.meta.stringToEnum(Pane, self.configString(&buf, "pane", "none")) orelse .none;
        self.angle = eval.Angle.parse(self.configString(&buf, "angle", "degrees"));
        const b = self.config.getInt("calc", "base", 10);
        self.base = if (b == 2 or b == 8 or b == 16) @intCast(b) else 10;
        const w = self.config.getInt("calc", "word-bits", 64);
        self.word = if (w == 8 or w == 16 or w == 32) @intCast(w) else 64;
        self.style.decimals = @intCast(std.math.clamp(self.config.getInt("calc", "decimals", 10), 0, 30));
        self.style.grouping = self.config.getBool("calc", "grouping", true);
        self.expanded = self.config.getBool("calc", "expanded", false);
        self.style.notation = std.meta.stringToEnum(num.Notation, self.configString(&buf, "notation", "auto")) orelse .auto;
    }

    fn configString(self: *Calc, buf: []u8, key: [:0]const u8, default: []const u8) []const u8 {
        const v = self.config.getString(self.gpa, "calc", key, default) catch return default;
        defer self.gpa.free(v);
        const n = @min(v.len, buf.len);
        @memcpy(buf[0..n], v[0..n]);
        return buf[0..n];
    }

    fn evalMode(self: *const Calc) eval.Mode {
        return .{
            .angle = self.angle,
            .programmer = self.mode == .programmer,
            .base = if (self.mode == .programmer) self.base else 10,
            .bits = self.word,
            .solve_only = self.formula != null,
        };
    }

    fn buildMenus(self: *Calc) *gtk.Widget {
        const mb = common.menubar;
        const menus = [_]mb.Menu{
            .{ .label = "_File", .entries = &.{
                mb.item("_Open Session…", "open-session", "<Control>o"),
                mb.item("_Save Session…", "save-session", "<Control>s"),
                mb.item("_Export Session…", "export-session", null),
                .separator,
                mb.item("_Close", "close", "<Control>w"),
            } },
            .{ .label = "_Edit", .entries = &.{
                mb.item("_Copy Result", "copy", "<Control><Shift>c"),
                mb.item("_Paste", "paste", null),
                .separator,
                mb.item("C_lear", "clear", null),
                mb.item("Clear _History", "clear-history", null),
                mb.item("Clear _Variables and Functions", "clear-vars", null),
            } },
            .{ .label = "_View", .entries = &.{
                mb.checkKey("_Standard", "mode-standard", self.mode == .standard, "<Alt>1"),
                mb.checkKey("S_cientific", "mode-scientific", self.mode == .scientific, "<Alt>2"),
                mb.checkKey("_Programmer", "mode-programmer", self.mode == .programmer, "<Alt>3"),
                .separator,
                mb.checkKey("E_xpanded Tape", "expanded", self.expanded, "<Control>t"),
                mb.checkKey("_History", "pane-history", self.pane == .history, "<Control>h"),
                mb.checkKey("_Unit Conversion", "pane-units", self.pane == .units, "<Control>u"),
                mb.checkKey("_Currency", "pane-currency", self.pane == .currency, "<Control>k"),
                mb.checkKey("_Date Calculation", "pane-dates", self.pane == .dates, "<Control>e"),
                mb.checkKey("_Graph", "pane-graph", self.pane == .graph, "<Control>g"),
                mb.checkKey("_Formulas", "pane-formulas", self.pane == .formulas, "<Control><Shift>f"),
                mb.item("Update E_xchange Rates", "update-rates", null),
                .separator,
                mb.check("_Degrees", "angle-degrees", self.angle == .degrees),
                mb.check("_Radians", "angle-radians", self.angle == .radians),
                mb.check("_Gradians", "angle-gradians", self.angle == .gradians),
                .separator,
                mb.check("Digit G_rouping", "grouping", self.style.grouping),
                mb.check("Scientific _Notation", "notation-scientific", self.style.notation == .scientific),
                mb.check("_Engineering Notation", "notation-engineering", self.style.notation == .engineering),
                mb.dynamic("Decimal _Places", "decimals"),
            } },
        };
        const bar = mb.build(self.app, self.window, &menus, Calc, onMenuAction, self);
        const string_type = glib.VariantType.new("s");
        defer string_type.free();
        const action = gio.SimpleAction.new("decimals", string_type);
        _ = gio.SimpleAction.signals.activate.connect(action, *Calc, &onDecimals, self, .{});
        self.window.as(gio.ActionMap).addAction(action.as(gio.Action));
        action.as(gobject.Object).unref();
        if (mb.submenu(self.window, "decimals")) |m| {
            for ([_][:0]const u8{ "0", "2", "4", "6", "8", "10", "15", "20", "30" }) |d| {
                const it = gio.MenuItem.new(d, null);
                defer it.as(gobject.Object).unref();
                it.setActionAndTargetValue("win.decimals", glib.Variant.newString(d));
                m.appendItem(it);
            }
        }
        return bar.as(gtk.Widget);
    }

    // ---- keys ------------------------------------------------------------------------

    fn keyButton(self: *Calc, spec: *const Spec) *gtk.Widget {
        const button = gtk.Button.newWithLabel(spec.label);
        const w = button.as(gtk.Widget);
        w.addCssClass("dkde-calc-key");
        if (spec.css) |c| w.addCssClass(c);
        if (spec.cmd == .enter) w.addCssClass("suggested-action");
        if (spec.tip) |tip| w.setTooltipText(tip) else if (std.mem.eql(u8, spec.label, "=")) w.setTooltipText(t("Equals: for equations (2x + 3 = 11), variables (x = 5) and functions (f(x) = x² + 1)"));
        w.setFocusOnClick(0);
        w.setHexpand(1);
        w.setVexpand(1);
        // Keys that depend on the base or mode say what they are (not their label: C is also Clear).
        if (spec.cmd == .insert and spec.insert.len == 1 and std.ascii.isHex(spec.insert[0])) {
            var nb: [16]u8 = undefined;
            w.setName(std.fmt.bufPrintSentinel(&nb, "digit-{c}", .{spec.insert[0]}, 0) catch "");
        } else if (std.mem.eql(u8, spec.label, ".") or std.mem.eql(u8, spec.label, "√") or std.mem.eql(u8, spec.label, "x²") or std.mem.eql(u8, spec.label, "%")) {
            w.setName("not-programmer");
        }
        const key = self.gpa.create(Key) catch return w;
        key.* = .{ .calc = self, .spec = spec };
        self.keys.append(self.gpa, key) catch {};
        _ = gtk.Button.signals.clicked.connect(button, *Key, &onKeyClicked, key, .{});
        return w;
    }

    fn onKeyClicked(_: *gtk.Button, key: *Key) callconv(.c) void {
        key.calc.press(key.spec);
    }

    fn grid(self: *Calc, rows: anytype) *gtk.Grid {
        const g = gtk.Grid.new();
        g.setRowSpacing(4);
        g.setColumnSpacing(4);
        g.setRowHomogeneous(1);
        g.setColumnHomogeneous(1);
        g.as(gtk.Widget).setHexpand(1);
        g.as(gtk.Widget).setVexpand(1);
        for (rows, 0..) |*row, y| for (row, 0..) |*s, x| g.attach(self.keyButton(s), @intCast(x), @intCast(y), 1, 1);
        return g;
    }

    fn setMode(self: *Calc, mode: Mode) void {
        self.mode = mode;
        while (self.keypad.as(gtk.Widget).getFirstChild()) |c| self.keypad.remove(c);
        for (self.keys.items) |key| self.gpa.destroy(key);
        self.keys.clearRetainingCapacity();
        // The memory row's keys were made before; keep them alive.
        self.keepMemoryKeys();
        switch (mode) {
            .standard => {},
            .scientific => self.keypad.append(self.scientificPanel()),
            .programmer => self.keypad.append(self.programmerPanel()),
        }
        self.keypad.append(self.grid(&standard_keys).as(gtk.Widget));
        self.bases.as(gtk.Widget).setVisible(@intFromBool(mode == .programmer));
        self.bits.as(gtk.Widget).setVisible(@intFromBool(mode == .programmer));
        inline for (.{ "standard", "scientific", "programmer" }) |name| {
            common.menubar.setChecked(self.window, "mode-" ++ name, std.mem.eql(u8, @tagName(mode), name));
        }
        self.config.setString("calc", "mode", @tagName(mode)) catch {};
        self.window.as(gtk.Window).setDefaultSize(-1, -1);
        self.updateKeys();
        self.refreshPreview();
    }

    /// The memory keys are made once, in `create`; setMode only frees the keypad's.
    fn keepMemoryKeys(self: *Calc) void {
        _ = self;
    }

    fn scientificPanel(self: *Calc) *gtk.Widget {
        const box = gtk.Box.new(.vertical, 4);
        box.as(gtk.Widget).setHexpand(1);
        // Degrees, radians, gradians, as in the Windows calculator.
        const angles = gtk.Box.new(.horizontal, 0);
        angles.as(gtk.Widget).addCssClass("linked");
        var first: ?*gtk.ToggleButton = null;
        inline for (.{ .{ "Deg", eval.Angle.degrees }, .{ "Rad", eval.Angle.radians }, .{ "Grad", eval.Angle.gradians } }) |p| {
            const b = gtk.ToggleButton.newWithLabel(p[0]);
            b.as(gtk.Widget).setHexpand(1);
            b.as(gtk.Widget).setFocusOnClick(0);
            if (first) |f| b.setGroup(f) else first = b;
            if (self.angle == p[1]) b.setActive(1);
            _ = gtk.ToggleButton.signals.toggled.connect(b, *Calc, &struct {
                fn f(tb: *gtk.ToggleButton, c: *Calc) callconv(.c) void {
                    if (tb.getActive() != 0) c.setAngle(p[1]);
                }
            }.f, self, .{});
            angles.append(b.as(gtk.Widget));
        }
        box.append(angles.as(gtk.Widget));
        box.append(self.grid(&scientific_keys).as(gtk.Widget));
        return box.as(gtk.Widget);
    }

    fn programmerPanel(self: *Calc) *gtk.Widget {
        const box = gtk.Box.new(.vertical, 4);
        box.as(gtk.Widget).setHexpand(1);
        const row = gtk.Box.new(.horizontal, 6);
        const bases = gtk.Box.new(.horizontal, 0);
        bases.as(gtk.Widget).addCssClass("linked");
        var first: ?*gtk.ToggleButton = null;
        inline for (.{ .{ "Hex", 16 }, .{ "Dec", 10 }, .{ "Oct", 8 }, .{ "Bin", 2 } }) |p| {
            const b = gtk.ToggleButton.newWithLabel(p[0]);
            b.as(gtk.Widget).setFocusOnClick(0);
            if (first) |f| b.setGroup(f) else first = b;
            if (self.base == p[1]) b.setActive(1);
            _ = gtk.ToggleButton.signals.toggled.connect(b, *Calc, &struct {
                fn f(tb: *gtk.ToggleButton, c: *Calc) callconv(.c) void {
                    if (tb.getActive() != 0) c.setBase(p[1]);
                }
            }.f, self, .{});
            bases.append(b.as(gtk.Widget));
        }
        row.append(bases.as(gtk.Widget));
        var words = [_:null]?[*:0]const u8{ "Qword (64)", "Dword (32)", "Word (16)", "Byte (8)" };
        const word = gtk.DropDown.newFromStrings(@ptrCast(&words));
        word.setSelected(switch (self.word) {
            8 => 3,
            16 => 2,
            32 => 1,
            else => 0,
        });
        word.as(gtk.Widget).setHexpand(1);
        word.as(gtk.Widget).setFocusOnClick(0);
        _ = gobject.Object.signals.notify.connect(word, *Calc, &onWord, self, .{ .detail = "selected" });
        row.append(word.as(gtk.Widget));
        box.append(row.as(gtk.Widget));
        box.append(self.grid(&programmer_keys).as(gtk.Widget));
        return box.as(gtk.Widget);
    }

    fn onWord(dd: *gtk.DropDown, _: *gobject.ParamSpec, self: *Calc) callconv(.c) void {
        self.word = switch (dd.getSelected()) {
            1 => 32,
            2 => 16,
            3 => 8,
            else => 64,
        };
        self.config.setInt("calc", "word-bits", self.word) catch {};
        self.int_value = num.wrap(self.int_value, self.word);
        self.showProgrammerValue();
        self.refreshPreview();
    }

    fn setAngle(self: *Calc, a: eval.Angle) void {
        self.angle = a;
        inline for (.{ "degrees", "radians", "gradians" }) |name| {
            common.menubar.setChecked(self.window, "angle-" ++ name, std.mem.eql(u8, @tagName(a), name));
        }
        self.config.setString("calc", "angle", @tagName(a)) catch {};
        self.refreshPreview();
    }

    fn setBase(self: *Calc, base: u8) void {
        const was = self.base;
        self.base = base;
        self.config.setInt("calc", "base", base) catch {};
        // A shown result is written again in the new base.
        if (self.fresh or std.mem.span(self.entry.as(gtk.Editable).getText()).len == 0 or was == base) {
            if (self.fresh) self.showResultText(self.int_value);
        }
        self.updateKeys();
        self.refreshPreview();
    }

    /// Digits that do not exist in the current base, and the point in
    /// programmer mode, are greyed out.
    fn updateKeys(self: *Calc) void {
        var child = self.keypad.as(gtk.Widget).getFirstChild();
        while (child) |c| : (child = c.getNextSibling()) self.updateKeysIn(c);
    }

    fn updateKeysIn(self: *Calc, w: *gtk.Widget) void {
        var child = w.getFirstChild();
        while (child) |c| : (child = c.getNextSibling()) {
            const name = std.mem.span(c.getName());
            if (std.mem.startsWith(u8, name, "digit-")) {
                const value = std.fmt.charToDigit(name[6], 16) catch 0;
                const base: u8 = if (self.mode == .programmer) self.base else 10;
                c.setSensitive(@intFromBool(value < base));
            } else if (std.mem.eql(u8, name, "not-programmer")) {
                c.setSensitive(@intFromBool(self.mode != .programmer));
            } else self.updateKeysIn(c);
        }
    }

    fn press(self: *Calc, spec: *const Spec) void {
        self.recall = null;
        switch (spec.cmd) {
            .insert => self.insert(spec.insert),
            .enter => self.calculate(),
            .clear => self.clear(),
            .back => self.backspace(),
            .negate => self.wrapEntry("−(", ")", true),
            .reciprocal => self.wrapEntry("1/(", ")", false),
            .mc => {
                if (self.memory) |m| m.deinit(self.gpa);
                self.memory = null;
                self.updateMemory();
            },
            .mr => if (self.memory) |m| {
                var arena = std.heap.ArenaAllocator.init(self.gpa);
                defer arena.deinit();
                const v = m.load(arena.allocator()) catch return;
                const text = self.plainText(arena.allocator(), v) catch return;
                self.insert(text);
            },
            .ms, .mplus, .mminus => self.memoryOp(spec.cmd),
            .plot => self.plotEntry(),
        }
        _ = self.entry.as(gtk.Widget).grabFocus();
        self.entry.as(gtk.Editable).setPosition(-1);
    }

    fn entryText(self: *Calc) []const u8 {
        return std.mem.span(self.entry.as(gtk.Editable).getText());
    }

    fn setEntry(self: *Calc, text: []const u8) void {
        var buf: [4096]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{text}, 0) catch return;
        self.quiet = true;
        defer self.quiet = false;
        self.entry.as(gtk.Editable).setText(z);
        self.entry.as(gtk.Editable).setPosition(-1);
    }

    fn insert(self: *Calc, text: []const u8) void {
        if (self.fresh) {
            self.fresh = false;
            // After a result an operator goes on from it; anything else starts over.
            const goes_on = text.len > 0 and (std.mem.indexOfScalar(u8, "+−-×*÷/^²³!%=)", text[0]) != null or
                std.mem.startsWith(u8, text, "−") or std.mem.startsWith(u8, text, "×") or std.mem.startsWith(u8, text, "÷") or
                std.mem.startsWith(u8, text, "²") or std.mem.startsWith(u8, text, " "));
            self.setEntry(if (goes_on) (self.plain orelse "") else "");
            self.formula = null;
        }
        var buf: [256]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{text}, 0) catch return;
        const editable = self.entry.as(gtk.Editable);
        var start: c_int = 0;
        var end: c_int = 0;
        if (editable.getSelectionBounds(&start, &end) != 0) editable.deleteText(start, end);
        var pos: c_int = editable.getPosition();
        editable.insertText(z, -1, &pos);
        editable.setPosition(pos);
    }

    fn clear(self: *Calc) void {
        self.formula = null;
        self.setEntry("");
        self.expr_label.setText("");
        self.preview.setText("");
        self.fresh = false;
        self.recall = null;
    }

    fn backspace(self: *Calc) void {
        if (self.fresh) return self.clear();
        const editable = self.entry.as(gtk.Editable);
        var start: c_int = 0;
        var end: c_int = 0;
        if (editable.getSelectionBounds(&start, &end) != 0) return editable.deleteText(start, end);
        const pos = editable.getPosition();
        if (pos > 0) editable.deleteText(pos - 1, pos);
    }

    /// "± " and "1/x" act on the whole entry (or the last result).
    fn wrapEntry(self: *Calc, before: []const u8, after: []const u8, toggle: bool) void {
        const text = if (self.fresh) (self.plain orelse "") else self.entryText();
        self.fresh = false;
        if (text.len == 0) return;
        var buf: [4096]u8 = undefined;
        if (toggle) {
            if (std.mem.startsWith(u8, text, "−(") and std.mem.endsWith(u8, text, ")")) return self.setEntry(text["−(".len .. text.len - 1]);
            if (isPlainNumber(text)) {
                if (std.mem.startsWith(u8, text, "-")) return self.setEntry(text[1..]);
                if (std.mem.startsWith(u8, text, "−")) return self.setEntry(text["−".len..]);
                return self.setEntry(std.fmt.bufPrint(&buf, "-{s}", .{text}) catch return);
            }
        }
        self.setEntry(std.fmt.bufPrint(&buf, "{s}{s}{s}", .{ before, text, after }) catch return);
    }

    fn isPlainNumber(text: []const u8) bool {
        for (text, 0..) |c, i| {
            if (std.ascii.isDigit(c) or c == '.') continue;
            if (i == 0 and c == '-') continue;
            return false;
        }
        return text.len > 0;
    }

    // ---- working it out -------------------------------------------------------------------

    /// The entry without the narrow spaces that group digits.
    fn cleaned(a: std.mem.Allocator, text: []const u8) ![]u8 {
        return std.mem.replaceOwned(u8, a, text, group_sep, "");
    }

    /// An entry that starts with an operator goes on from the last answer, as on a TI:
    /// "+ 3" is "ans + 3". (A leading "-" stays a minus sign: "-3" is negative three.)
    fn withAns(self: *Calc, a: std.mem.Allocator, raw: []const u8) []const u8 {
        if (self.formula != null) return raw;
        const t0 = std.mem.trimStart(u8, raw, " ");
        if (t0.len == 0) return raw;
        const starts = [_][]const u8{ "+", "*", "/", "^", "×", "÷", "·", "²", "³" };
        for (starts) |lead| if (std.mem.startsWith(u8, t0, lead)) {
            if (self.session.ans == null and !self.session.rich.contains("ans")) return raw;
            return std.fmt.allocPrint(a, "ans {s}", .{t0}) catch raw;
        };
        return raw;
    }

    fn calculate(self: *Calc) void {
        var arena0 = std.heap.ArenaAllocator.init(self.gpa);
        defer arena0.deinit();
        const raw = self.withAns(arena0.allocator(), self.entryText());
        if (std.mem.trim(u8, raw, " ").len == 0) return;
        if (self.fresh) return; // the result of the last calculation: nothing new
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const text = cleaned(a, raw) catch return;
        const expr_copy = a.dupe(u8, raw) catch return;

        // With the Graph pane open, functions of x are drawn: "sin(x)", "y = x^2", "sin(x); cos(x)".
        if (self.pane == .graph and self.formula == null and self.mode != .programmer and self.plotFunctions(a, text)) return;

        // "255 to hex", "0.75 to fraction", "360 to factors".
        if (self.mode != .programmer) if (convert.request(text)) |req| {
            var p: eval.Problem = .{};
            const out = eval.run(a, &self.session, req.expr, self.evalMode(), &p) catch |e| return self.showError(e, p, text);
            const out_value = eval.plainValue(out) orelse return self.showError(error.Syntax, p, text);
            const sh = convert.apply(a, out_value, req.kind, self.style) catch |e| return self.showError(switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                error.TooLarge => error.TooLarge,
                else => error.Domain,
            }, p, text);
            self.finishResultAs(expr_copy, sh.text, null, a, false);
            return;
        };

        // "5 km in mi".
        if (self.mode != .programmer) if (units.request(text)) |req| {
            var p: eval.Problem = .{};
            const amount = eval.run(a, &self.session, req.amount, self.evalMode(), &p) catch |e| return self.showError(e, p, text);
            const amount_value = eval.plainValue(amount) orelse return self.showError(error.Syntax, p, text);
            const v = units.convert(req.from.category, req.from.unit, req.to.unit, amount_value.toFloat());
            const shown = num.format(a, .{ .approx = v }, self.style) catch return;
            const result = std.fmt.allocPrint(a, "{s} {s}", .{ shown, units.shortName(req.to) }) catch return;
            self.finishResult(expr_copy, result, num.fromFloat(v) catch null, a);
            return;
        };

        var p: eval.Problem = .{};
        quantity.resetUsed();
        const outcome = eval.run(a, &self.session, text, self.evalMode(), &p) catch |e| return self.showError(e, p, text);
        switch (outcome) {
            .value => |v| {
                const shown = self.displayText(a, v) catch return;
                self.finishResult(expr_copy, shown, v, a);
                self.noteRatesUsed(a);
            },
            .assigned => |s| {
                const shown = self.displayText(a, s.value) catch return;
                const line = std.fmt.allocPrint(a, "{s} = {s}", .{ s.name, shown }) catch return;
                self.finishResult(expr_copy, line, s.value, a);
                self.saveState();
                self.fillVars();
                self.graph.refresh();
            },
            .defined => |name| {
                self.addHistory(expr_copy, std.fmt.allocPrint(a, "{s} defined", .{name}) catch return);
                var buf: [128]u8 = undefined;
                self.expr_label.setText(std.fmt.bufPrintSentinel(&buf, "{s}", .{expr_copy}, 0) catch "");
                self.preview.setText(std.fmt.bufPrintSentinel(&buf, "{s} is defined: use it as {s}(…)", .{ name, name }, 0) catch "");
                self.setEntry("");
                self.saveState();
                self.fillVars();
                self.graph.refresh();
            },
            .solved => |s| {
                var parts: std.ArrayList(u8) = .empty;
                for (s.roots, 0..) |r, i| {
                    if (i > 0) parts.appendSlice(a, ";  ") catch return;
                    const shown = num.format(a, r, self.style) catch return;
                    // An exact form: x = −√2 ≈ −1.4142135624.
                    if (s.exact) |ex| if (i < ex.len and !r.isExact()) {
                        parts.print(a, "{s} = {s} ≈ {s}", .{ s.name, ex[i], shown }) catch return;
                        continue;
                    };
                    // In letters too when that says more: A = 9π ≈ 28.27.
                    if (s.form) |f| if (!r.isExact() and !std.mem.eql(u8, f, shown) and f.len < 60 and !looksNumeric(f)) {
                        parts.print(a, "{s} = {s} ≈ {s}", .{ s.name, f, shown }) catch return;
                        continue;
                    };
                    parts.print(a, "{s} {s} {s}", .{ s.name, if (r.isExact()) "=" else "≈", shown }) catch return;
                }
                self.finishResult(expr_copy, parts.items, if (s.roots.len == 1) s.roots[0] else null, a);
                // The answer cannot be typed on from; Enter again does nothing.
                if (s.roots.len != 1) {
                    if (self.plain) |pl| self.gpa.free(pl);
                    self.plain = null;
                }
            },
            .truth => |yes| self.finishResult(expr_copy, if (yes) t("true") else t("false"), null, a),
            .system => |sy| {
                var parts: std.ArrayList(u8) = .empty;
                for (sy.names, sy.values, 0..) |nm, v, i| {
                    const shown = num.format(a, v, self.style) catch return;
                    parts.print(a, "{s}{s} {s} {s}", .{ if (i > 0) ";  " else "", nm, if (v.isExact()) "=" else "≈", shown }) catch return;
                }
                self.finishResultAs(expr_copy, parts.items, null, a, false);
                if (self.plain) |pl| self.gpa.free(pl);
                self.plain = null;
            },
            .symbolic => |sy| {
                const shown = self.displayText(a, sy.value) catch return;
                self.exact_tail = sy.text;
                self.finishResult(expr_copy, shown, sy.value, a);
            },
            .rich => |v| {
                self.finishRich(expr_copy, v, null, a);
                self.noteRatesUsed(a);
            },
            .rich_assigned => |s| {
                self.finishRich(expr_copy, s.value, s.name, a);
                self.fillVars();
            },
            .complex => |cx| {
                var parts: std.ArrayList(u8) = .empty;
                for (cx.re, cx.im, 0..) |re, im, i| {
                    if (i > 0) parts.appendSlice(a, ";  ") catch return;
                    const z = complexText(a, re, im, self.style) catch return;
                    if (cx.exact) |ex| if (i < ex.len) {
                        parts.print(a, "{s} = {s} ≈ {s}", .{ cx.name, ex[i], z }) catch return;
                        continue;
                    };
                    parts.print(a, "{s} = {s}", .{ cx.name, z }) catch return;
                }
                self.finishResult(expr_copy, parts.items, null, a);
                if (self.plain) |pl| self.gpa.free(pl);
                self.plain = null;
                self.preview.setText(t("No real solution: these are the complex ones (i = √−1)"));
            },
            .simplified => |x| {
                self.finishResult(expr_copy, x, null, a);
                if (self.plain) |pl| self.gpa.free(pl);
                self.plain = self.gpa.dupe(u8, x) catch null;
                var buf: [256]u8 = undefined;
                self.preview.setText(std.fmt.bufPrintSentinel(&buf, "{s}", .{t("Simplified: give the other letters values to work it out")}, 0) catch "");
            },
        }
    }

    /// "3 + 2i", "−14.3874945699i".
    fn complexText(a: std.mem.Allocator, re: f64, im: f64, style: num.Style) ![]u8 {
        const im_text = try num.format(a, .{ .approx = @abs(im) }, style);
        const im_part = if (std.mem.eql(u8, im_text, "1")) "" else im_text;
        if (re == 0) return std.fmt.allocPrint(a, "{s}{s}i", .{ if (im < 0) "−" else "", im_part });
        const re_text = try num.format(a, .{ .approx = re }, style);
        return std.fmt.allocPrint(a, "{s} {s} {s}i", .{ re_text, if (im < 0) "−" else "+", im_part });
    }

    fn looksNumeric(text: []const u8) bool {
        for (text) |c| if (!(std.ascii.isDigit(c) or c == '.' or c == '-' or c == ' ')) return false;
        return true;
    }

    fn displayText(self: *Calc, a: std.mem.Allocator, v: num.Number) ![]u8 {
        if (self.mode == .programmer) {
            const i = num.int128(v) orelse return num.format(a, v, self.style);
            return num.formatBase(a, i, self.base, self.word, false);
        }
        return num.format(a, v, self.style);
    }

    /// Text that can be typed back in (no grouping, plain point).
    fn plainText(self: *Calc, a: std.mem.Allocator, v: num.Number) ![]u8 {
        if (self.mode == .programmer) {
            const i = num.int128(v) orelse return error.Domain;
            return num.formatBase(a, i, self.base, self.word, false);
        }
        var style = self.style;
        style.grouping = false;
        // Enough digits to go on with.
        style.decimals = @max(style.decimals, 15);
        return num.format(a, v, style);
    }

    /// A complex number or matrix (typed back in as it is shown).
    fn finishRich(self: *Calc, expr: []const u8, v: rich.Value, name: ?[]const u8, a: std.mem.Allocator) void {
        const text = rich.format(a, v, self.style) catch return;
        const shown = if (name) |nm| std.fmt.allocPrint(a, "{s} = {s}", .{ nm, text }) catch return else text;
        self.finishResultMarked(expr, shown, null, a, std.mem.indexOfScalar(u8, expr, '=') == null, !rich.isExact(v));
        if (self.plain) |pl| self.gpa.free(pl);
        self.plain = self.gpa.dupe(u8, text) catch null;
    }

    fn finishResult(self: *Calc, expr: []const u8, shown: []const u8, value: ?num.Number, a: std.mem.Allocator) void {
        self.finishResultAs(expr, shown, value, a, std.mem.indexOfScalar(u8, expr, '=') == null);
    }

    fn finishResultAs(self: *Calc, expr: []const u8, shown: []const u8, value: ?num.Number, a: std.mem.Allocator, equals: bool) void {
        self.finishResultMarked(expr, shown, value, a, equals, false);
    }

    fn finishResultMarked(self: *Calc, expr: []const u8, shown: []const u8, value: ?num.Number, a: std.mem.Allocator, equals: bool, rounded: bool) void {
        var line_buf: [4096]u8 = undefined;
        // The expression above, with "≈" when the result is rounded and the fraction when there is one.
        var tail: []const u8 = "";
        if (self.exact_tail) |exact| {
            // 2√2, π/4: the exact form beside the decimals.
            tail = std.fmt.allocPrint(a, "   (= {s})", .{exact}) catch "";
            self.exact_tail = null;
        } else if (value) |v| {
            if (num.fraction(a, v) catch null) |f| {
                if (self.mode != .programmer) tail = std.fmt.allocPrint(a, "   (= {s})", .{f}) catch "";
            }
        }
        const approx = rounded or (if (value) |v| !v.isExact() else false);
        const mark: []const u8 = if (!equals) "" else if (approx) " ≈" else " =";
        self.expr_label.setText(std.fmt.bufPrintSentinel(&line_buf, "{s}{s}{s}", .{ expr, mark, tail }, 0) catch "");
        self.preview.setText("");
        self.preview.as(gtk.Widget).removeCssClass("error");
        self.addHistory(expr, shown);
        if (self.plain) |pl| self.gpa.free(pl);
        self.plain = null;
        if (value) |v| {
            self.session.setAns(v) catch {};
            self.plain = if (self.plainText(a, v)) |pt| self.gpa.dupe(u8, pt) catch null else |_| null;
            if (num.int128(v)) |i| self.int_value = num.wrap(i, self.word);
            self.showProgrammerValue();
        }
        self.setEntry(shown);
        self.fresh = true;
        self.saveState();
    }

    fn showResultText(self: *Calc, v: i128) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const text = num.formatBase(a, v, self.base, self.word, false) catch return;
        if (self.plain) |pl| self.gpa.free(pl);
        self.plain = self.gpa.dupe(u8, text) catch null;
        self.setEntry(text);
        self.fresh = true;
    }

    fn showError(self: *Calc, e: eval.Error, p: eval.Problem, text: []const u8) void {
        var buf: [256]u8 = undefined;
        const message: [:0]const u8 = switch (e) {
            error.Syntax => t("Something is missing or out of place here"),
            error.DivisionByZero => t("Cannot divide by zero"),
            error.Domain => t("The result is undefined"),
            error.UnknownName => std.fmt.bufPrintSentinel(&buf, "Unknown name: {s}", .{p.name}, 0) catch "Unknown name",
            error.TooLarge => t("The number is too large"),
            error.NotInteger => t("Programmer mode works with whole numbers"),
            error.WrongArguments => std.fmt.bufPrintSentinel(&buf, "Wrong number of values for {s}", .{p.name}, 0) catch "Wrong number of values",
            error.TooManyUnknowns => std.fmt.bufPrintSentinel(&buf, "More than one unknown (also {s}): give the others values first", .{p.name}, 0) catch "More than one unknown",
            error.NoSolution => t("No real solution was found"),
            error.Recursion => t("A function uses itself without end"),
            error.Units => t("These units do not match: they measure different things"),
            error.NoRates => t("No exchange rates yet: choose View ▸ Update Exchange Rates"),
            error.OutOfMemory => t("Not enough memory"),
        };
        self.preview.setText(message);
        self.preview.as(gtk.Widget).addCssClass("error");
        // Select from where the problem is.
        if (e == error.Syntax or e == error.UnknownName or e == error.WrongArguments) {
            const at = @min(p.pos, text.len);
            const chars = std.unicode.utf8CountCodepoints(text[0..at]) catch at;
            self.entry.as(gtk.Editable).selectRegion(@intCast(chars), -1);
        }
    }

    fn onActivate(_: *gtk.Entry, self: *Calc) callconv(.c) void {
        self.calculate();
    }

    /// While typing: the result so far, under the entry.
    fn onChanged(_: *gtk.Editable, self: *Calc) callconv(.c) void {
        if (self.quiet) return;
        // Editing a shown result by hand goes on from it.
        self.fresh = false;
        self.refreshPreview();
        self.highlightEntry();
    }

    fn onCursorMoved(_: *gtk.Entry, _: *gobject.ParamSpec, self: *Calc) callconv(.c) void {
        self.highlightEntry();
    }

    /// Colours the entry's text by what each part is (see highlight.zig).
    fn highlightEntry(self: *Calc) void {
        const text = self.entryText();
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const chars: usize = @intCast(@max(self.entry.as(gtk.Editable).getPosition(), 0));
        var cursor: usize = 0;
        var seen: usize = 0;
        while (cursor < text.len and seen < chars) : (seen += 1) {
            cursor += std.unicode.utf8ByteSequenceLength(text[cursor]) catch 1;
        }
        const list = highlight.spans(a, text, cursor, &self.session) catch return;
        // Light text means a dark theme: lighter colours there.
        var fg: gdk.RGBA = undefined;
        self.entry.as(gtk.Widget).getStyleContext().getColor(&fg);
        const dark = fg.f_red * 0.3 + fg.f_green * 0.59 + fg.f_blue * 0.11 > 0.5;
        const attrs = pango.AttrList.new();
        defer attrs.unref();
        for (list) |sp| {
            const rgb: [3]u16 = switch (sp.kind) {
                .number => if (dark) .{ 0x7a00, 0xb800, 0xff00 } else .{ 0x0b00, 0x4f00, 0xc500 },
                .function => if (dark) .{ 0xd700, 0x9b00, 0xff00 } else .{ 0x7a00, 0x2a00, 0xa800 },
                .constant => if (dark) .{ 0xff00, 0xc200, 0x5c00 } else .{ 0xa800, 0x5c00, 0x0000 },
                .variable => if (dark) .{ 0x5c00, 0xd900, 0xc800 } else .{ 0x0000, 0x6b00, 0x5e00 },
                .unit => if (dark) .{ 0x6ee0, 0xd800, 0x7a00 } else .{ 0x1a00, 0x6a00, 0x2400 },
                .operator => if (dark) .{ 0xb000, 0xb000, 0xb000 } else .{ 0x6000, 0x6000, 0x6000 },
                .bracket => if (dark) .{ 0xb000, 0xb000, 0xb000 } else .{ 0x6000, 0x6000, 0x6000 },
                .bracket_match => if (dark) .{ 0xff00, 0xff00, 0xff00 } else .{ 0x0000, 0x0000, 0x0000 },
                .bracket_error => if (dark) .{ 0xff00, 0x6600, 0x6600 } else .{ 0xc800, 0x1400, 0x1400 },
            };
            const fgattr = pango.attrForegroundNew(rgb[0], rgb[1], rgb[2]);
            fgattr.f_start_index = @intCast(sp.start);
            fgattr.f_end_index = @intCast(sp.end);
            attrs.insert(fgattr);
            if (sp.kind == .bracket_match or sp.kind == .function) {
                const w = pango.attrWeightNew(.bold);
                w.f_start_index = @intCast(sp.start);
                w.f_end_index = @intCast(sp.end);
                attrs.insert(w);
            }
            if (sp.kind == .bracket_error) {
                const u = pango.attrUnderlineNew(.@"error");
                u.f_start_index = @intCast(sp.start);
                u.f_end_index = @intCast(sp.end);
                attrs.insert(u);
            }
        }
        self.entry.setAttributes(attrs);
    }

    fn refreshPreview(self: *Calc) void {
        if (self.fresh) return;
        self.preview.as(gtk.Widget).removeCssClass("error");
        const raw = self.entryText();
        if (std.mem.trim(u8, raw, " ").len == 0) return self.preview.setText("");
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const text = cleaned(a, self.withAns(a, raw)) catch return;
        if (self.mode != .programmer) if (convert.request(text)) |req| {
            var p: eval.Problem = .{};
            const st = eval.parse(a, req.expr, self.evalMode(), &p) catch return self.preview.setText("");
            if (st != .expr) return self.preview.setText("");
            var ev: eval.Eval = .{ .a = a, .session = &self.session, .mode = self.evalMode(), .problem = &p };
            const v = ev.eval(st.expr, null) catch return self.preview.setText("");
            const sh = convert.apply(a, v, req.kind, self.style) catch return self.preview.setText("");
            var buf: [512]u8 = undefined;
            return self.preview.setText(std.fmt.bufPrintSentinel(&buf, "{s} {s}", .{ if (sh.approx) "≈" else "=", sh.text }, 0) catch "");
        };
        if (self.mode != .programmer) if (units.request(text)) |req| {
            var p: eval.Problem = .{};
            const st = eval.parse(a, req.amount, self.evalMode(), &p) catch return self.preview.setText("");
            if (st != .expr) return self.preview.setText("");
            var ev: eval.Eval = .{ .a = a, .session = &self.session, .mode = self.evalMode(), .problem = &p };
            const v = ev.eval(st.expr, null) catch return self.preview.setText("");
            const shown = num.format(a, .{ .approx = units.convert(req.from.category, req.from.unit, req.to.unit, v.toFloat()) }, self.style) catch return;
            var buf: [256]u8 = undefined;
            return self.preview.setText(std.fmt.bufPrintSentinel(&buf, "= {s} {s}", .{ shown, units.shortName(req.to) }, 0) catch "");
        };
        var p: eval.Problem = .{};
        const st = eval.parse(a, text, self.evalMode(), &p) catch return self.preview.setText("");
        switch (st) {
            .equation => |eq| {
                const hint: [:0]const u8 = if (self.formula != null)
                    t("Enter works out the letter left empty (or simplifies the formula)")
                else if (eq.l.* == .name) t("Enter sets the variable or solves the equation") else if (eq.l.* == .call) t("Enter defines the function or solves the equation") else t("Enter solves the equation");
                self.preview.setText(hint);
            },
            .expr => |n| {
                var ev: eval.Eval = .{ .a = a, .session = &self.session, .mode = self.evalMode(), .problem = &p };
                if (self.mode != .programmer and rich.needs(n, &self.session)) {
                    var rr = rich.Rich.init(&ev);
                    const rv = rr.value(n, null) catch return self.preview.setText("");
                    const text2 = rich.format(a, rv, self.style) catch return;
                    var buf: [2048]u8 = undefined;
                    return self.preview.setText(std.fmt.bufPrintSentinel(&buf, "{s} {s}", .{ if (rich.isExact(rv)) "=" else "≈", text2 }, 0) catch "");
                }
                const v = ev.eval(n, null) catch |e| {
                    if (e == error.Domain and self.mode != .programmer) {
                        var rr = rich.Rich.init(&ev);
                        if (rr.value(n, null)) |rv| {
                            const text2 = rich.format(a, rv, self.style) catch return;
                            var buf: [2048]u8 = undefined;
                            return self.preview.setText(std.fmt.bufPrintSentinel(&buf, "{s} {s}", .{ if (rich.isExact(rv)) "=" else "≈", text2 }, 0) catch "");
                        } else |_| {}
                    }
                    if (e == error.UnknownName and self.mode != .programmer) {
                        const tidy = simplify.simplify(a, &ev, n) catch return self.preview.setText("");
                        var buf: [1024]u8 = undefined;
                        return self.preview.setText(std.fmt.bufPrintSentinel(&buf, "→ {s}", .{tidy}, 0) catch "");
                    }
                    return self.preview.setText("");
                };
                const shown = self.displayText(a, v) catch return;
                var buf: [1024]u8 = undefined;
                self.preview.setText(std.fmt.bufPrintSentinel(&buf, "{s} {s}", .{ if (v.isExact()) "=" else "≈", shown }, 0) catch "");
                if (self.mode == .programmer) if (num.int128(v)) |i| {
                    self.int_value = num.wrap(i, self.word);
                    self.showProgrammerValue();
                };
            },
        }
    }

    // ---- memory ----------------------------------------------------------------------------

    /// The value to store: the last result, or what the entry works out to.
    fn currentValue(self: *Calc, a: std.mem.Allocator) ?num.Number {
        const text = if (self.fresh) (self.plain orelse return null) else self.entryText();
        if (std.mem.trim(u8, text, " ").len == 0) return null;
        const c = cleaned(a, text) catch return null;
        var p: eval.Problem = .{};
        const st = eval.parse(a, c, self.evalMode(), &p) catch return null;
        if (st != .expr) return null;
        var ev: eval.Eval = .{ .a = a, .session = &self.session, .mode = self.evalMode(), .problem = &p };
        return ev.eval(st.expr, null) catch null;
    }

    fn memoryOp(self: *Calc, c: Cmd) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const v = self.currentValue(a) orelse return;
        var result = v;
        if (c != .ms) {
            const old = if (self.memory) |m| (m.load(a) catch return) else (num.fromInt(a, 0) catch return);
            result = (if (c == .mplus) num.add(a, old, v) else num.sub(a, old, v)) catch return;
        }
        const stored = eval.Stored.of(self.gpa, result) catch return;
        if (self.memory) |m| m.deinit(self.gpa);
        self.memory = stored;
        self.updateMemory();
        self.saveState();
    }

    fn updateMemory(self: *Calc) void {
        self.memory_label.setText(if (self.memory != null) "M" else "");
    }

    // ---- programmer mode: bases and bits ------------------------------------------------------

    fn buildBases(self: *Calc) void {
        self.bases.as(gtk.Widget).addCssClass("dkde-calc-bases");
        const names = [_][:0]const u8{ "HEX", "DEC", "OCT", "BIN" };
        const values = [_]u8{ 16, 10, 8, 2 };
        for (names, values, 0..) |n, v, i| {
            const row = gtk.Box.new(.horizontal, 8);
            const name = gtk.Label.new(n);
            name.as(gtk.Widget).addCssClass("dim-label");
            name.as(gtk.Widget).setSizeRequest(36, -1);
            name.setXalign(0);
            const value = gtk.Label.new("0");
            value.setXalign(1);
            value.setSelectable(1);
            value.setEllipsize(.start);
            value.as(gtk.Widget).setHexpand(1);
            value.as(gtk.Widget).addCssClass("monospace");
            self.base_labels[i] = value;
            row.append(name.as(gtk.Widget));
            row.append(value.as(gtk.Widget));
            const button = gtk.Button.new();
            button.setChild(row.as(gtk.Widget));
            button.setHasFrame(0);
            button.as(gtk.Widget).setFocusOnClick(0);
            button.as(gtk.Widget).setTooltipText(t("Work in this base"));
            const BaseClick = struct {
                fn f(_: *gtk.Button, c: *Calc) callconv(.c) void {
                    _ = c;
                }
            };
            _ = BaseClick;
            _ = v;
            self.bases.append(button.as(gtk.Widget));
        }
    }

    fn buildBits(self: *Calc) void {
        self.bits.setColumnSpacing(0);
        self.bits.setRowSpacing(0);
        self.bits.as(gtk.Widget).addCssClass("dkde-calc-bits");
        self.bits.as(gtk.Widget).setHalign(.center);
        // Four rows of 16 bits, highest first, with a gap every four.
        for (0..64) |i| {
            const bit: u6 = @intCast(63 - i);
            const b = gtk.Button.newWithLabel("0");
            b.setHasFrame(0);
            b.as(gtk.Widget).setFocusOnClick(0);
            b.as(gtk.Widget).addCssClass("dkde-calc-bit");
            var tip: [32]u8 = undefined;
            b.as(gtk.Widget).setTooltipText(std.fmt.bufPrintSentinel(&tip, "Bit {d}", .{bit}, 0) catch null);
            self.bit_buttons[bit] = b;
            const row: c_int = @intCast(i / 16);
            const col: c_int = @intCast((i % 16) + (i % 16) / 4);
            self.bits.attach(b.as(gtk.Widget), col, row, 1, 1);
            _ = gtk.Button.signals.clicked.connect(b, *Calc, &onBit, self, .{});
            if (i % 16 == 15) {
                var nb: [8]u8 = undefined;
                const label = gtk.Label.new(std.fmt.bufPrintSentinel(&nb, "{d}", .{bit}, 0) catch "");
                label.as(gtk.Widget).addCssClass("dim-label");
                label.as(gtk.Widget).setMarginStart(6);
                self.bits.attach(label.as(gtk.Widget), 20, row, 1, 1);
            }
        }
    }

    fn onBit(button: *gtk.Button, self: *Calc) callconv(.c) void {
        for (self.bit_buttons, 0..) |b, i| {
            if (b != button) continue;
            if (i >= self.word) return;
            self.int_value = num.wrap(self.int_value ^ (@as(i128, 1) << @intCast(i)), self.word);
            self.showResultText(self.int_value);
            self.showProgrammerValue();
            return;
        }
    }

    fn showProgrammerValue(self: *Calc) void {
        if (self.mode != .programmer) return;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const v = self.int_value;
        for ([_]u8{ 16, 10, 8, 2 }, 0..) |base, i| {
            const text = num.formatBase(a, v, base, self.word, true) catch continue;
            const z = a.dupeSentinel(u8, text, 0) catch continue;
            self.base_labels[i].setText(z);
            self.base_labels[i].as(gtk.Widget).getParent().?.getParent().?.setSensitive(1);
        }
        const mask: u128 = if (self.word >= 128) std.math.maxInt(u128) else (@as(u128, 1) << @intCast(self.word)) - 1;
        const u: u128 = @as(u128, @bitCast(v)) & mask;
        for (self.bit_buttons, 0..) |b, i| {
            b.setLabel(if (i < 128 and (u >> @intCast(i)) & 1 == 1) "1" else "0");
            b.as(gtk.Widget).setSensitive(@intFromBool(i < self.word));
        }
    }

    // ---- history, variables and functions ------------------------------------------------------

    fn buildHistory(self: *Calc) *gtk.Widget {
        const box = gtk.Box.new(.vertical, 6);
        const title = gtk.Label.new(t("History"));
        title.setXalign(0);
        title.as(gtk.Widget).addCssClass("heading");
        box.append(title.as(gtk.Widget));
        const scroll = gtk.ScrolledWindow.new();
        scroll.setChild(self.history_list.as(gtk.Widget));
        scroll.as(gtk.Widget).setVexpand(1);
        scroll.setPolicy(.never, .automatic);
        self.history_list.setSelectionMode(.none);
        self.history_list.setActivateOnSingleClick(1);
        self.history_list.as(gtk.Widget).addCssClass("dkde-calc-history");
        _ = gtk.ListBox.signals.row_activated.connect(self.history_list, *Calc, &onHistoryRow, self, .{});
        box.append(scroll.as(gtk.Widget));
        const hint = gtk.Label.new(t("Click a line to use its result."));
        hint.setXalign(0);
        hint.as(gtk.Widget).addCssClass("dim-label");
        box.append(hint.as(gtk.Widget));
        const clear_button = gtk.Button.newWithLabel(t("Clear History"));
        clear_button.as(gtk.Widget).setTooltipText(t("Forget every calculation (variables and functions are kept)"));
        _ = gtk.Button.signals.clicked.connect(clear_button, *Calc, &onClearHistory, self, .{});
        box.append(clear_button.as(gtk.Widget));

        const vtitle = gtk.Label.new(t("Variables and Functions"));
        vtitle.setXalign(0);
        vtitle.as(gtk.Widget).addCssClass("heading");
        vtitle.as(gtk.Widget).setMarginTop(8);
        box.append(vtitle.as(gtk.Widget));
        const vscroll = gtk.ScrolledWindow.new();
        vscroll.setChild(self.vars_list.as(gtk.Widget));
        vscroll.setPolicy(.never, .automatic);
        vscroll.as(gtk.Widget).setSizeRequest(-1, 120);
        self.vars_list.setSelectionMode(.none);
        self.vars_list.setActivateOnSingleClick(1);
        _ = gtk.ListBox.signals.row_activated.connect(self.vars_list, *Calc, &onVarRow, self, .{});
        box.append(vscroll.as(gtk.Widget));
        const vhint = gtk.Label.new(t("Set one with x = 5 or f(x) = x² + 1."));
        vhint.setXalign(0);
        vhint.setWrap(1);
        vhint.setMaxWidthChars(40);
        vhint.as(gtk.Widget).addCssClass("dim-label");
        box.append(vhint.as(gtk.Widget));
        return box.as(gtk.Widget);
    }

    fn addHistory(self: *Calc, expr: []const u8, result: []const u8) void {
        const e = self.gpa.dupe(u8, expr) catch return;
        const r = self.gpa.dupe(u8, result) catch {
            self.gpa.free(e);
            return;
        };
        self.history.append(self.gpa, .{ .expr = e, .result = r }) catch {
            self.gpa.free(e);
            self.gpa.free(r);
            return;
        };
        const limit: usize = @intCast(std.math.clamp(self.config.getInt("calc", "history-size", 200), 0, 10000));
        while (self.history.items.len > limit) {
            const old = self.history.orderedRemove(0);
            self.gpa.free(old.expr);
            self.gpa.free(old.result);
        }
        self.fillHistory();
    }

    fn onClearHistory(_: *gtk.Button, self: *Calc) callconv(.c) void {
        self.onMenuAction("clear-history");
    }

    fn historyRow(h: HistoryItem) *gtk.Widget {
        const box = gtk.Box.new(.vertical, 0);
        box.as(gtk.Widget).setMarginTop(4);
        box.as(gtk.Widget).setMarginBottom(4);
        var buf: [4096]u8 = undefined;
        const e = gtk.Label.new(std.fmt.bufPrintSentinel(&buf, "{s}", .{h.expr}, 0) catch "");
        e.setXalign(1);
        e.setWrap(1);
        e.setMaxWidthChars(40);
        e.setWrapMode(.word_char);
        e.as(gtk.Widget).addCssClass("dim-label");
        const r = gtk.Label.new(std.fmt.bufPrintSentinel(&buf, "{s}", .{h.result}, 0) catch "");
        r.setXalign(1);
        r.setWrap(1);
        r.setMaxWidthChars(40);
        r.setWrapMode(.word_char);
        r.as(gtk.Widget).addCssClass("dkde-calc-history-result");
        box.append(e.as(gtk.Widget));
        box.append(r.as(gtk.Widget));
        return box.as(gtk.Widget);
    }

    fn fillHistory(self: *Calc) void {
        self.history_list.removeAll();
        self.tape_list.removeAll();
        // The History pane: newest first. The tape: oldest first, scrolled to the newest.
        var i = self.history.items.len;
        while (i > 0) {
            i -= 1;
            self.history_list.append(historyRow(self.history.items[i]));
        }
        for (self.history.items) |h| self.tape_list.append(historyRow(h));
        if (self.expanded) self.scrollTape();
    }

    fn scrollTape(self: *Calc) void {
        self.tape_stick = true;
        onTapeSized(self.tape_scroll.getVadjustment(), self);
        // Layout settles after this call: once more a moment later.
        _ = glib.timeoutAdd(60, onTapeLater, self);
    }

    fn onTapeLater(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Calc = @ptrCast(@alignCast(data.?));
        if (!self.tape_stick) return 0;
        // A value set while the view is being laid out is not drawn; set it again from here.
        const adj = self.tape_scroll.getVadjustment();
        adj.setValue(0);
        adj.setValue(adj.getUpper() - adj.getPageSize());
        return 0;
    }

    fn onTapeNotify(adj: *gtk.Adjustment, _: *gobject.ParamSpec, self: *Calc) callconv(.c) void {
        onTapeSized(adj, self);
    }

    /// The tape grew or was resized: stay at the newest line.
    fn onTapeSized(adj: *gtk.Adjustment, self: *Calc) callconv(.c) void {
        if (self.tape_stick) adj.setValue(adj.getUpper() - adj.getPageSize());
    }

    fn onTapeRow(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Calc) callconv(.c) void {
        const index: usize = @intCast(row.getIndex());
        if (index >= self.history.items.len) return;
        self.useHistoryResult(self.history.items[index]);
    }

    fn onHistoryRow(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Calc) callconv(.c) void {
        const index: usize = @intCast(row.getIndex());
        if (index >= self.history.items.len) return;
        self.useHistoryResult(self.history.items[self.history.items.len - 1 - index]);
    }

    /// Puts a history line's result into the entry (or in at the cursor).
    fn useHistoryResult(self: *Calc, h: HistoryItem) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const plain = cleaned(arena.allocator(), h.result) catch return;
        // A line such as "x = 5" or "km" results: only the number.
        const value = if (std.mem.lastIndexOf(u8, plain, "= ")) |eq| plain[eq + 2 ..] else plain;
        const first = std.mem.sliceTo(value, ' ');
        if (self.fresh or self.entryText().len == 0) {
            self.fresh = false;
            self.setEntry(first);
        } else self.insert(first);
        _ = self.entry.as(gtk.Widget).grabFocus();
        self.entry.as(gtk.Editable).setPosition(-1);
    }

    fn fillVars(self: *Calc) void {
        self.vars_list.removeAll();
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var it = self.session.vars.iterator();
        while (it.next()) |e| {
            const v = e.value_ptr.load(a) catch continue;
            const shown = num.format(a, v, self.style) catch continue;
            self.varRow(e.key_ptr.*, std.fmt.allocPrint(a, "{s} = {s}", .{ e.key_ptr.*, shown }) catch continue);
        }
        var rit = self.session.rich.iterator();
        while (rit.next()) |e| {
            if (std.mem.eql(u8, e.key_ptr.*, "ans")) continue;
            const v = e.value_ptr.load(a) catch continue;
            const shown = rich.format(a, v, self.style) catch continue;
            self.varRow(e.key_ptr.*, std.fmt.allocPrint(a, "{s} = {s}", .{ e.key_ptr.*, shown }) catch continue);
        }
        var fit = self.session.funcs.iterator();
        while (fit.next()) |e| {
            const params = std.mem.join(a, ", ", @ptrCast(e.value_ptr.params)) catch continue;
            self.varRow(e.key_ptr.*, std.fmt.allocPrint(a, "{s}({s}) = {s}", .{ e.key_ptr.*, params, e.value_ptr.body }) catch continue);
        }
    }

    fn varRow(self: *Calc, name: []const u8, text: []const u8) void {
        const box = gtk.Box.new(.horizontal, 6);
        var buf: [1024]u8 = undefined;
        const l = gtk.Label.new(std.fmt.bufPrintSentinel(&buf, "{s}", .{text}, 0) catch "");
        l.setXalign(0);
        l.setEllipsize(.end);
        l.as(gtk.Widget).setHexpand(1);
        box.append(l.as(gtk.Widget));
        const del = gtk.Button.newFromIconName("edit-delete-symbolic");
        del.setHasFrame(0);
        del.as(gtk.Widget).setTooltipText(t("Forget it"));
        del.as(gtk.Widget).setName(std.fmt.bufPrintSentinel(&buf, "{s}", .{name}, 0) catch "");
        _ = gtk.Button.signals.clicked.connect(del, *Calc, &onForget, self, .{});
        box.append(del.as(gtk.Widget));
        box.as(gtk.Widget).setName(std.fmt.bufPrintSentinel(&buf, "{s}", .{name}, 0) catch "");
        self.vars_list.append(box.as(gtk.Widget));
    }

    fn onVarRow(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Calc) callconv(.c) void {
        const child = row.getChild() orelse return;
        const name = std.mem.span(child.getName());
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const text = if (self.session.funcs.contains(name)) std.fmt.allocPrint(arena.allocator(), "{s}(", .{name}) catch return else name;
        self.insert(text);
        _ = self.entry.as(gtk.Widget).grabFocus();
    }

    fn onForget(button: *gtk.Button, self: *Calc) callconv(.c) void {
        const name = std.mem.span(button.as(gtk.Widget).getName());
        var copy: [256]u8 = undefined;
        const n = @min(name.len, copy.len);
        @memcpy(copy[0..n], name[0..n]);
        _ = self.session.remove(copy[0..n]);
        self.saveState();
        // Rebuilding the list destroys this button: do it when idle.
        _ = glib.idleAdd(refillVars, self);
        self.graph.refresh();
    }

    fn refillVars(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Calc = @ptrCast(@alignCast(data.?));
        self.fillVars();
        return 0;
    }

    // ---- unit conversion -------------------------------------------------------------------

    fn buildUnits(self: *Calc) *gtk.Widget {
        const box = gtk.Box.new(.vertical, 8);
        const title = gtk.Label.new(t("Unit Conversion"));
        title.setXalign(0);
        title.as(gtk.Widget).addCssClass("heading");
        box.append(title.as(gtk.Widget));

        var names: [units.categories.len + 1:null]?[*:0]const u8 = @splat(null);
        inline for (units.categories, 0..) |c, i| names[i] = @ptrCast((c.label ++ "\x00").ptr);
        self.unit_category = gtk.DropDown.newFromStrings(@ptrCast(&names));
        _ = gobject.Object.signals.notify.connect(self.unit_category, *Calc, &onUnitCategory, self, .{ .detail = "selected" });
        box.append(self.unit_category.as(gtk.Widget));

        const from_label = gtk.Label.new(t("From"));
        from_label.setXalign(0);
        box.append(from_label.as(gtk.Widget));
        self.unit_value = gtk.Entry.new();
        self.unit_value.as(gtk.Editable).setText("1");
        self.unit_value.as(gtk.Widget).addCssClass("dkde-calc-unit-value");
        _ = gtk.Editable.signals.changed.connect(self.unit_value.as(gtk.Editable), *Calc, &onUnitChanged, self, .{});
        box.append(self.unit_value.as(gtk.Widget));
        self.unit_from = gtk.DropDown.new(null, null);
        _ = gobject.Object.signals.notify.connect(self.unit_from, *Calc, &onUnitPick, self, .{ .detail = "selected" });
        box.append(self.unit_from.as(gtk.Widget));

        const swap = gtk.Button.newWithLabel("⇅");
        swap.as(gtk.Widget).setTooltipText(t("Swap the units"));
        swap.as(gtk.Widget).setHalign(.center);
        _ = gtk.Button.signals.clicked.connect(swap, *Calc, &onUnitSwap, self, .{});
        box.append(swap.as(gtk.Widget));

        const to_label = gtk.Label.new(t("To"));
        to_label.setXalign(0);
        box.append(to_label.as(gtk.Widget));
        self.unit_to = gtk.DropDown.new(null, null);
        _ = gobject.Object.signals.notify.connect(self.unit_to, *Calc, &onUnitPick, self, .{ .detail = "selected" });
        box.append(self.unit_to.as(gtk.Widget));
        self.unit_result = gtk.Label.new("");
        self.unit_result.setXalign(0);
        self.unit_result.setSelectable(1);
        self.unit_result.setWrap(1);
        self.unit_result.setMaxWidthChars(40);
        self.unit_result.as(gtk.Widget).addCssClass("dkde-calc-unit-result");
        box.append(self.unit_result.as(gtk.Widget));

        const hint = gtk.Label.new(t("In the calculator, type for example 5 km in mi or 100 °F to °C."));
        hint.setXalign(0);
        hint.setWrap(1);
        hint.setMaxWidthChars(40);
        hint.as(gtk.Widget).addCssClass("dim-label");
        hint.as(gtk.Widget).setVexpand(1);
        hint.as(gtk.Widget).setValign(.end);
        box.append(hint.as(gtk.Widget));
        self.fillUnits(0);
        return box.as(gtk.Widget);
    }

    fn fillUnits(self: *Calc, category: usize) void {
        const c = units.categories[category];
        var names: [32:null]?[*:0]const u8 = @splat(null);
        var bufs: [32][80]u8 = undefined;
        for (c.units, 0..) |un, i| {
            if (i >= 31) break;
            const label: [:0]const u8 = std.fmt.bufPrintSentinel(&bufs[i], "{s} ({s})", .{ un.label, un.names[0] }, 0) catch "?";
            names[i] = label.ptr;
        }
        const from_model = gtk.StringList.new(@ptrCast(&names));
        const to_model = gtk.StringList.new(@ptrCast(&names));
        self.unit_from.setModel(from_model.as(gio.ListModel));
        self.unit_to.setModel(to_model.as(gio.ListModel));
        from_model.as(gobject.Object).unref();
        to_model.as(gobject.Object).unref();
        self.unit_to.setSelected(@intCast(@min(1, c.units.len - 1)));
        self.convertUnits();
    }

    fn onUnitCategory(dd: *gtk.DropDown, _: *gobject.ParamSpec, self: *Calc) callconv(.c) void {
        const i = dd.getSelected();
        if (i < units.categories.len) self.fillUnits(i);
    }

    fn onUnitPick(_: *gtk.DropDown, _: *gobject.ParamSpec, self: *Calc) callconv(.c) void {
        self.convertUnits();
    }

    fn onUnitChanged(_: *gtk.Editable, self: *Calc) callconv(.c) void {
        self.convertUnits();
    }

    fn onUnitSwap(_: *gtk.Button, self: *Calc) callconv(.c) void {
        const f = self.unit_from.getSelected();
        self.unit_from.setSelected(self.unit_to.getSelected());
        self.unit_to.setSelected(f);
    }

    fn convertUnits(self: *Calc) void {
        const ci = self.unit_category.getSelected();
        if (ci >= units.categories.len) return;
        const c = units.categories[ci];
        const from = self.unit_from.getSelected();
        const to = self.unit_to.getSelected();
        if (from >= c.units.len or to >= c.units.len) return;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const text = cleaned(a, std.mem.span(self.unit_value.as(gtk.Editable).getText())) catch return;
        var p: eval.Problem = .{};
        const st = eval.parse(a, text, .{ .angle = self.angle }, &p) catch return self.unit_result.setText("");
        if (st != .expr) return self.unit_result.setText("");
        var ev: eval.Eval = .{ .a = a, .session = &self.session, .mode = .{ .angle = self.angle }, .problem = &p };
        const v = ev.eval(st.expr, null) catch return self.unit_result.setText("");
        const r = units.convert(ci, from, to, v.toFloat());
        const shown = num.format(a, num.fromFloat(r) catch return self.unit_result.setText("—"), self.style) catch return;
        var buf: [256]u8 = undefined;
        self.unit_result.setText(std.fmt.bufPrintSentinel(&buf, "= {s} {s}", .{ shown, c.units[to].names[0] }, 0) catch "");
    }

    // ---- currencies -------------------------------------------------------------------------
    //
    // Rates come from rates.zig's sources only when View > Update Exchange Rates is
    // chosen; otherwise the last copy in the cache directory is used.

    /// Today (local), as days since 1970-01-01, for `today`.
    fn todayDays() i64 {
        const now = glib.DateTime.newNowLocal() orelse return 0;
        defer now.unref();
        return quantity.civilToDays(now.getYear(), @intCast(now.getMonth()), @intCast(now.getDayOfMonth()));
    }

    fn ratesPath(self: *Calc) ?[]u8 {
        return std.fmt.allocPrint(self.gpa, "{s}/dkde/calc-rates", .{std.mem.span(glib.getUserCacheDir())}) catch null;
    }

    /// Makes `fetched` (copied) plus the manual rates the rates in use.
    fn setRates(self: *Calc, fetched: []const quantity.Currency) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        const a = arena.allocator();
        const text = rates.serialize(a, fetched) catch return arena.deinit();
        const copy = rates.deserialize(a, text) catch return arena.deinit();
        const merged = rates.merge(a, copy, self.manual.items) catch return arena.deinit();
        const text2 = rates.serialize(a, merged) catch return arena.deinit();
        const table = rates.deserialize(a, text2) catch return arena.deinit();
        quantity.setCurrencies(table);
        self.fetched = copy;
        if (self.rate_arena) |*old| old.deinit();
        self.rate_arena = arena;
        self.showRateStatus();
    }

    fn manualPath(self: *Calc) ?[:0]u8 {
        return self.statePath("calc-rates-manual");
    }

    fn loadManualRates(self: *Calc) void {
        const path = self.manualPath() orelse return;
        defer self.gpa.free(path);
        const text = (common.fsio.readFile(self.gpa, path, 1 << 20) catch null) orelse return;
        defer self.gpa.free(text);
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const list = rates.deserialize(arena.allocator(), text) catch return;
        for (list) |c| self.putManual(c.code, c.usd, c.date) catch {};
    }

    fn saveManualRates(self: *Calc) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const text = rates.serialize(arena.allocator(), self.manual.items) catch return;
        const path = self.manualPath() orelse return;
        defer self.gpa.free(path);
        if (std.fs.path.dirname(path)) |dir| common.fsio.makePath(dir) catch {};
        common.fsio.writeFileAtomic(path, text) catch {};
    }

    fn dropManual(self: *Calc, code: []const u8) bool {
        for (self.manual.items, 0..) |c, i| if (std.mem.eql(u8, c.code, code)) {
            const old = self.manual.orderedRemove(i);
            self.gpa.free(old.usd);
            self.gpa.free(old.date);
            return true;
        };
        return false;
    }

    /// A rate typed in by hand for `code` (dollars per unit), replacing an earlier one.
    fn putManual(self: *Calc, code: []const u8, usd: []const u8, date: []const u8) !void {
        const canon = quantity.canonicalCode(code) orelse return error.Domain;
        _ = self.dropManual(canon);
        const u = try self.gpa.dupe(u8, usd);
        errdefer self.gpa.free(u);
        const d = try self.gpa.dupe(u8, date);
        errdefer self.gpa.free(d);
        const kind: quantity.Kind = if (std.mem.eql(u8, canon, "GBK")) .goldback else for (quantity.fiat_codes) |f| {
            if (std.mem.eql(u8, f, canon)) break .fiat;
        } else .crypto;
        try self.manual.append(self.gpa, .{ .code = canon, .kind = kind, .usd = u, .date = d, .source = "manual" });
    }

    /// Dollars per unit of `code` in the rates in use, as a number.
    fn usdOf(code: []const u8) ?f64 {
        for (quantity.currencies()) |c| if (std.mem.eql(u8, c.code, code)) {
            if (std.mem.indexOfScalar(u8, c.usd, '/')) |i| {
                const n = std.fmt.parseFloat(f64, c.usd[0..i]) catch return null;
                const dn = std.fmt.parseFloat(f64, c.usd[i + 1 ..]) catch return null;
                return n / dn;
            }
            return std.fmt.parseFloat(f64, c.usd) catch null;
        };
        return null;
    }

    /// "1 FROM = x TO", typed by hand: used instead of the fetched rate of FROM.
    fn setManualRate(self: *Calc) void {
        const from = currencyCode(self.cur_from.getSelected());
        const to = currencyCode(self.cur_to.getSelected());
        var buf: [200]u8 = undefined;
        if (std.mem.eql(u8, from, "USD")) return self.cur_status.setText(t("The dollar is the base of every rate; choose another currency to set."));
        if (std.mem.eql(u8, from, to)) return self.cur_status.setText(t("Choose two different currencies."));
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const typed = cleaned(a, std.mem.trim(u8, std.mem.span(self.cur_manual.as(gtk.Editable).getText()), " ")) catch return;
        const x = std.fmt.parseFloat(f64, typed) catch return self.cur_status.setText(t("Type the rate as a number, for example 1.0842."));
        if (!(x > 0) or !std.math.isFinite(x)) return self.cur_status.setText(t("The rate must be a number above zero."));
        const to_usd = usdOf(to) orelse return self.cur_status.setText(std.fmt.bufPrintSentinel(&buf, "No rate for {s} yet: update the rates, or set {s} by hand first.", .{ to, to }, 0) catch "");
        const usd = std.fmt.allocPrint(a, "{d}", .{x * to_usd}) catch return;
        const when = rates.dateText(a, @divFloor(glib.getRealTime(), std.time.us_per_s)) catch "";
        self.putManual(from, usd, when) catch return;
        self.saveManualRates();
        self.setRates(self.fetched);
        self.cur_status.setText(std.fmt.bufPrintSentinel(&buf, "Manual rate set: 1 {s} = {s} {s}. The fetched rate is not used while it stays.", .{ from, typed, to }, 0) catch "");
        self.convertCurrency();
        self.refreshPreview();
    }

    fn clearManualRate(self: *Calc) void {
        const from = currencyCode(self.cur_from.getSelected());
        var buf: [160]u8 = undefined;
        if (!self.dropManual(from)) return self.cur_status.setText(std.fmt.bufPrintSentinel(&buf, "{s} has no manual rate.", .{from}, 0) catch "");
        self.saveManualRates();
        self.setRates(self.fetched);
        self.cur_status.setText(std.fmt.bufPrintSentinel(&buf, "Manual rate of {s} removed.", .{from}, 0) catch "");
        self.convertCurrency();
        self.refreshPreview();
    }

    fn onManualSet(_: *gtk.Button, self: *Calc) callconv(.c) void {
        self.setManualRate();
    }

    fn onManualClear(_: *gtk.Button, self: *Calc) callconv(.c) void {
        self.clearManualRate();
    }

    fn loadRates(self: *Calc) void {
        const path = self.ratesPath() orelse return;
        defer self.gpa.free(path);
        const text = (common.fsio.readFile(self.gpa, path, 1 << 20) catch null) orelse return;
        defer self.gpa.free(text);
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const list = rates.deserialize(arena.allocator(), text) catch return;
        self.setRates(list);
    }

    fn saveRates(self: *Calc, a: std.mem.Allocator, list: []const quantity.Currency) void {
        const text = rates.serialize(a, list) catch return;
        const path = self.ratesPath() orelse return;
        defer self.gpa.free(path);
        if (std.fs.path.dirname(path)) |dir| common.fsio.makePath(dir) catch {};
        common.fsio.writeFileAtomic(path, text) catch {};
    }

    fn showRateStatus(self: *Calc) void {
        if (!self.cur_ready) return;
        const list = quantity.currencies();
        var buf: [320]u8 = undefined;
        var newest: []const u8 = "";
        for (list) |c| if (std.mem.order(u8, c.date, newest) == .gt) {
            newest = c.date;
        };
        const msg: [:0]const u8 = if (list.len == 0)
            t("No rates yet. Update them from View ▸ Update Exchange Rates.")
        else
            std.fmt.bufPrintSentinel(&buf, "{d} currencies{s}. Newest rate: {s}.", .{ list.len, if (self.manual.items.len > 0) " (some set by hand)" else "", newest }, 0) catch "";
        self.cur_status.setText(msg);
    }

    /// Under a result that used currencies: where the rates came from and when.
    fn noteRatesUsed(self: *Calc, a: std.mem.Allocator) void {
        const used = quantity.usedRates();
        if (used.len == 0) return;
        var line: std.ArrayList(u8) = .empty;
        line.appendSlice(a, "Rates: ") catch return;
        for (used, 0..) |c, i| {
            line.print(a, "{s}{s} {s} ({s})", .{ if (i > 0) "; " else "", c.code, c.date, c.source }) catch return;
        }
        const z = a.dupeSentinel(u8, line.items, 0) catch return;
        self.preview.setText(z);
    }

    const RateJob = struct {
        calc: *Calc,
        got: std.ArrayList(quantity.Currency) = .empty,
        errors: u8 = 0,
        arena: std.heap.ArenaAllocator,
    };

    fn updateRates(self: *Calc) void {
        if (self.updating) return;
        const job = self.gpa.create(RateJob) catch return;
        job.* = .{ .calc = self, .arena = std.heap.ArenaAllocator.init(self.gpa) };
        const thread = std.Thread.spawn(.{}, rateWorker, .{job}) catch {
            job.arena.deinit();
            self.gpa.destroy(job);
            return self.cur_status.setText(t("Could not start the update."));
        };
        thread.detach();
        self.updating = true;
        self.cur_button.as(gtk.Widget).setSensitive(0);
        self.cur_status.setText(t("Updating exchange rates…"));
    }

    fn rateWorker(job: *RateJob) void {
        const a = job.arena.allocator();
        const now = rates.dateText(a, @divFloor(glib.getRealTime(), std.time.us_per_s)) catch "";
        const Src = struct { url: []const u8, kind: u8 };
        const sources = [_]Src{
            .{ .url = rates.ecb_url, .kind = 0 },
            .{ .url = rates.coingecko_url, .kind = 1 },
            .{ .url = rates.goldback_url, .kind = 2 },
        };
        for (sources) |src| {
            const body = common.feeds.fetchWith(a, src.url, null, "*/*") catch {
                job.errors += 1;
                continue;
            };
            const list = switch (src.kind) {
                0 => rates.parseEcb(a, body),
                1 => rates.parseCoingecko(a, body, now),
                else => rates.parseGoldback(a, body),
            } catch {
                job.errors += 1;
                continue;
            };
            job.got.appendSlice(a, list) catch {};
        }
        _ = glib.idleAdd(rateDone, job);
    }

    fn rateDone(data: ?*anyopaque) callconv(.c) c_int {
        const job: *RateJob = @ptrCast(@alignCast(data.?));
        const self = job.calc;
        defer {
            job.arena.deinit();
            self.gpa.destroy(job);
        }
        self.updating = false;
        self.cur_button.as(gtk.Widget).setSensitive(1);
        if (job.got.items.len > 0) {
            const a = job.arena.allocator();
            if (rates.merge(a, self.fetched, job.got.items)) |merged| {
                self.setRates(merged);
                self.saveRates(a, merged);
            } else |_| {}
        }
        if (job.errors > 0) {
            var buf: [160]u8 = undefined;
            const msg = std.fmt.bufPrintSentinel(&buf, "{d} of 3 sources could not be read; the last rates are kept for those.", .{job.errors}, 0) catch "";
            self.cur_status.setText(msg);
        }
        self.convertCurrency();
        self.refreshPreview();
        return 0;
    }

    fn buildCurrency(self: *Calc) *gtk.Widget {
        const box = gtk.Box.new(.vertical, 8);
        const title = gtk.Label.new(t("Currency"));
        title.setXalign(0);
        title.as(gtk.Widget).addCssClass("heading");
        box.append(title.as(gtk.Widget));

        var names: [quantity.fiat_codes.len + quantity.crypto_list.len + 2:null]?[*:0]const u8 = @splat(null);
        var n: usize = 0;
        inline for (quantity.fiat_codes, quantity.fiat_names) |c, nm| {
            names[n] = @ptrCast((c ++ " (" ++ nm ++ ")\x00").ptr);
            n += 1;
        }
        inline for (quantity.crypto_list) |c| {
            names[n] = @ptrCast((c.code ++ " (" ++ c.name ++ ")\x00").ptr);
            n += 1;
        }
        names[n] = "GBK (Goldback)";
        self.cur_value = gtk.Entry.new();
        self.cur_value.as(gtk.Editable).setText("1");
        _ = gtk.Editable.signals.changed.connect(self.cur_value.as(gtk.Editable), *Calc, &onCurrencyChanged, self, .{});
        box.append(self.cur_value.as(gtk.Widget));
        self.cur_from = gtk.DropDown.newFromStrings(@ptrCast(&names));
        self.cur_to = gtk.DropDown.newFromStrings(@ptrCast(&names));
        self.cur_to.setSelected(1);
        _ = gobject.Object.signals.notify.connect(self.cur_from, *Calc, &onCurrencyPick, self, .{ .detail = "selected" });
        _ = gobject.Object.signals.notify.connect(self.cur_to, *Calc, &onCurrencyPick, self, .{ .detail = "selected" });
        box.append(self.cur_from.as(gtk.Widget));
        box.append(self.cur_to.as(gtk.Widget));
        self.cur_result = gtk.Label.new("");
        self.cur_result.setXalign(0);
        self.cur_result.setSelectable(1);
        self.cur_result.setWrap(1);
        box.append(self.cur_result.as(gtk.Widget));
        const manual_label = gtk.Label.new(t("Manual rate: 1 of the first currency equals this many of the second"));
        manual_label.setXalign(0);
        manual_label.setWrap(1);
        manual_label.setMaxWidthChars(40);
        box.append(manual_label.as(gtk.Widget));
        const manual_row = gtk.Box.new(.horizontal, 6);
        self.cur_manual = gtk.Entry.new();
        self.cur_manual.setPlaceholderText(t("rate"));
        self.cur_manual.as(gtk.Widget).setHexpand(1);
        manual_row.append(self.cur_manual.as(gtk.Widget));
        const set_button = gtk.Button.newWithLabel(t("Set"));
        _ = gtk.Button.signals.clicked.connect(set_button, *Calc, &onManualSet, self, .{});
        manual_row.append(set_button.as(gtk.Widget));
        const clear_button = gtk.Button.newWithLabel(t("Clear"));
        clear_button.as(gtk.Widget).setTooltipText(t("Remove the manual rate of the first currency"));
        _ = gtk.Button.signals.clicked.connect(clear_button, *Calc, &onManualClear, self, .{});
        manual_row.append(clear_button.as(gtk.Widget));
        box.append(manual_row.as(gtk.Widget));
        self.cur_button = gtk.Button.newWithLabel(t("Update exchange rates"));
        _ = gtk.Button.signals.clicked.connect(self.cur_button, *Calc, &onCurrencyUpdate, self, .{});
        box.append(self.cur_button.as(gtk.Widget));
        self.cur_status = gtk.Label.new("");
        self.cur_status.setXalign(0);
        self.cur_status.setWrap(1);
        self.cur_status.setMaxWidthChars(40);
        self.cur_status.as(gtk.Widget).addCssClass("dim-label");
        box.append(self.cur_status.as(gtk.Widget));
        const hint = gtk.Label.new(t("In the calculator, type for example 100 USD to EUR, 0.5 BTC in USD or 3 goldback to USD. Rates are fetched only when you update them."));
        hint.setXalign(0);
        hint.setWrap(1);
        hint.setMaxWidthChars(40);
        hint.as(gtk.Widget).addCssClass("dim-label");
        hint.as(gtk.Widget).setVexpand(1);
        hint.as(gtk.Widget).setValign(.end);
        box.append(hint.as(gtk.Widget));
        self.cur_ready = true;
        self.showRateStatus();
        self.convertCurrency();
        return box.as(gtk.Widget);
    }

    fn onCurrencyChanged(_: *gtk.Editable, self: *Calc) callconv(.c) void {
        self.convertCurrency();
    }
    fn onCurrencyPick(_: *gtk.DropDown, _: *gobject.ParamSpec, self: *Calc) callconv(.c) void {
        self.convertCurrency();
    }
    fn onCurrencyUpdate(_: *gtk.Button, self: *Calc) callconv(.c) void {
        self.updateRates();
    }

    fn currencyCode(i: u32) []const u8 {
        if (i < quantity.fiat_codes.len) return quantity.fiat_codes[i];
        const j = i - quantity.fiat_codes.len;
        if (j < quantity.crypto_list.len) return quantity.crypto_list[j].code;
        return "GBK";
    }

    fn convertCurrency(self: *Calc) void {
        if (!self.cur_ready) return;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const amount = cleaned(a, std.mem.span(self.cur_value.as(gtk.Editable).getText())) catch return;
        if (amount.len == 0) return self.cur_result.setText("");
        const text = std.fmt.allocPrint(a, "({s}) {s} to {s}", .{ amount, currencyCode(self.cur_from.getSelected()), currencyCode(self.cur_to.getSelected()) }) catch return;
        var p: eval.Problem = .{};
        const out = eval.run(a, &self.session, text, self.evalMode(), &p) catch |e| {
            return self.cur_result.setText(if (e == error.NoRates) t("No exchange rates yet.") else "");
        };
        switch (out) {
            .value => |v| {
                const shown = self.displayText(a, v) catch return;
                self.cur_result.setText(a.dupeSentinel(u8, shown, 0) catch return);
            },
            .rich => |v| {
                const shown = rich.format(a, v, self.style) catch return;
                self.cur_result.setText(a.dupeSentinel(u8, shown, 0) catch return);
            },
            else => self.cur_result.setText(""),
        }
    }

    // ---- date calculation -------------------------------------------------------------------
    //
    // In any calendar dkde-calendar knows. Dates are typed in the calendar's
    // own numbering; the calendar picker (Gregorian) converts into it, and
    // each date is described under its field, with its Gregorian date.

    fn buildDates(self: *Calc) *gtk.Widget {
        const box = gtk.Box.new(.vertical, 8);
        const title = gtk.Label.new(t("Date Calculation"));
        title.setXalign(0);
        title.as(gtk.Widget).addCssClass("heading");
        box.append(title.as(gtk.Widget));

        var names: [dates.all_systems.len + 1:null]?[*:0]const u8 = @splat(null);
        for (dates.all_systems, 0..) |sys, i| names[i] = sys.label().ptr;
        self.date_system = gtk.DropDown.newFromStrings(@ptrCast(&names));
        var buf: [32]u8 = undefined;
        self.date_sys = dates.System.parse(self.configString(&buf, "date-calendar", "gregorian"));
        for (dates.all_systems, 0..) |sys, i| if (sys == self.date_sys) self.date_system.setSelected(@intCast(i));
        self.date_system.as(gtk.Widget).setTooltipText(t("The calendar the dates are written in"));
        box.append(self.date_system.as(gtk.Widget));

        var kinds = [_:null]?[*:0]const u8{ "Time between two dates", "Add to or subtract from a date" };
        self.date_kind = gtk.DropDown.newFromStrings(@ptrCast(&kinds));
        box.append(self.date_kind.as(gtk.Widget));

        const today = dates.calsys.fromCivil(self.date_sys, todayCivil());
        self.date_pages = gtk.Stack.new();
        // Between two dates.
        const between = gtk.Box.new(.vertical, 6);
        self.date_from = self.dateField(between, t("From"), today);
        self.date_to = self.dateField(between, t("To"), today);
        _ = self.date_pages.addNamed(between.as(gtk.Widget), "between");
        // Adding.
        const adding = gtk.Box.new(.vertical, 6);
        self.date_start = self.dateField(adding, t("From"), today);
        var signs = [_:null]?[*:0]const u8{ "Add", "Subtract" };
        self.date_sign = gtk.DropDown.newFromStrings(@ptrCast(&signs));
        _ = gobject.Object.signals.notify.connect(self.date_sign, *Calc, &onDateDrop, self, .{ .detail = "selected" });
        adding.append(self.date_sign.as(gtk.Widget));
        const amounts = gtk.Grid.new();
        amounts.setColumnSpacing(6);
        amounts.setRowSpacing(4);
        inline for (.{ .{ "Years", "date_years" }, .{ "Months", "date_months" }, .{ "Days", "date_days" } }, 0..) |p, i| {
            const l = gtk.Label.new(p[0]);
            l.setXalign(0);
            const sb = gtk.SpinButton.newWithRange(0, 100000, 1);
            sb.as(gtk.Widget).setHexpand(1);
            _ = gtk.SpinButton.signals.value_changed.connect(sb, *Calc, &onDateSpin, self, .{});
            @field(self, p[1]) = sb;
            amounts.attach(l.as(gtk.Widget), 0, @intCast(i), 1, 1);
            amounts.attach(sb.as(gtk.Widget), 1, @intCast(i), 1, 1);
        }
        adding.append(amounts.as(gtk.Widget));
        _ = self.date_pages.addNamed(adding.as(gtk.Widget), "add");
        box.append(self.date_pages.as(gtk.Widget));

        self.date_result = gtk.Label.new("");
        self.date_result.setXalign(0);
        self.date_result.setWrap(1);
        self.date_result.setMaxWidthChars(40);
        self.date_result.setSelectable(1);
        self.date_result.as(gtk.Widget).addCssClass("dkde-calc-unit-result");
        box.append(self.date_result.as(gtk.Widget));
        // Connected last: the handlers read the widgets above.
        _ = gobject.Object.signals.notify.connect(self.date_kind, *Calc, &onDateKind, self, .{ .detail = "selected" });
        _ = gobject.Object.signals.notify.connect(self.date_system, *Calc, &onDateSystem, self, .{ .detail = "selected" });
        self.workDates();
        return box.as(gtk.Widget);
    }

    fn todayCivil() dates.calsys.Date {
        const now = glib.DateTime.newNowLocal() orelse return .{ .year = 2000, .month = 1, .day = 1 };
        defer now.unref();
        return .{ .year = @intCast(now.getYear()), .month = @intCast(now.getMonth()), .day = @intCast(now.getDayOfMonth()) };
    }

    const DateField = struct { calc: *Calc, entry: *gtk.Entry, popover: *gtk.Popover, about: *gtk.Label };

    /// A date entry (in the chosen calendar), a calendar to pick from, and
    /// the date described under it.
    fn dateField(self: *Calc, box: *gtk.Box, label: [:0]const u8, initial: dates.Ymd) *gtk.Entry {
        const l = gtk.Label.new(label);
        l.setXalign(0);
        box.append(l.as(gtk.Widget));
        const row = gtk.Box.new(.horizontal, 4);
        const entry = gtk.Entry.new();
        var buf: [32]u8 = undefined;
        entry.as(gtk.Editable).setText(std.fmt.bufPrintSentinel(&buf, "{s}", .{dates.write(buf[16..], initial)}, 0) catch "");
        entry.setPlaceholderText(t("year-month-day"));
        entry.as(gtk.Widget).setHexpand(1);
        row.append(entry.as(gtk.Widget));
        const button = gtk.MenuButton.new();
        button.setIconName("x-office-calendar-symbolic");
        button.as(gtk.Widget).setTooltipText(t("Choose on a (Gregorian) calendar"));
        const popover = gtk.Popover.new();
        const calendar = gtk.Calendar.new();
        popover.setChild(calendar.as(gtk.Widget));
        button.setPopover(popover);
        row.append(button.as(gtk.Widget));
        box.append(row.as(gtk.Widget));
        const about = gtk.Label.new("");
        about.setXalign(0);
        about.setWrap(1);
        about.setMaxWidthChars(40);
        about.as(gtk.Widget).addCssClass("dim-label");
        box.append(about.as(gtk.Widget));
        const field = self.gpa.create(DateField) catch return entry;
        field.* = .{ .calc = self, .entry = entry, .popover = popover, .about = about };
        self.date_fields.append(self.gpa, field) catch {};
        _ = gtk.Calendar.signals.day_selected.connect(calendar, *DateField, &onCalendarDay, field, .{});
        _ = gtk.Editable.signals.changed.connect(entry.as(gtk.Editable), *Calc, &onDateChanged, self, .{});
        return entry;
    }

    fn onCalendarDay(cal: *gtk.Calendar, field: *DateField) callconv(.c) void {
        const d = cal.getDate();
        defer d.unref();
        const civil_date: dates.calsys.Date = .{ .year = @intCast(d.getYear()), .month = @intCast(d.getMonth()), .day = @intCast(d.getDayOfMonth()) };
        var buf: [32]u8 = undefined;
        const text = dates.write(&buf, dates.calsys.fromCivil(field.calc.date_sys, civil_date));
        var zb: [32]u8 = undefined;
        field.entry.as(gtk.Editable).setText(std.fmt.bufPrintSentinel(&zb, "{s}", .{text}, 0) catch return);
        field.popover.popdown();
    }

    /// The calendar changed: the same days, written in the new one.
    fn onDateSystem(dd: *gtk.DropDown, _: *gobject.ParamSpec, self: *Calc) callconv(.c) void {
        const i = dd.getSelected();
        if (i >= dates.all_systems.len) return;
        const old = self.date_sys;
        const new = dates.all_systems[i];
        for (self.date_fields.items) |f| {
            const v = dates.parse(old, std.mem.span(f.entry.as(gtk.Editable).getText())) orelse continue;
            const moved = dates.calsys.fromCivil(new, dates.calsys.toCivil(old, v));
            var buf: [32]u8 = undefined;
            var zb: [32]u8 = undefined;
            self.date_sys = new;
            f.entry.as(gtk.Editable).setText(std.fmt.bufPrintSentinel(&zb, "{s}", .{dates.write(&buf, moved)}, 0) catch continue);
        }
        self.date_sys = new;
        self.config.setString("calc", "date-calendar", new.name()) catch {};
        self.workDates();
    }

    fn onDateKind(dd: *gtk.DropDown, _: *gobject.ParamSpec, self: *Calc) callconv(.c) void {
        self.date_pages.setVisibleChildName(if (dd.getSelected() == 0) "between" else "add");
        self.workDates();
    }

    fn onDateDrop(_: *gtk.DropDown, _: *gobject.ParamSpec, self: *Calc) callconv(.c) void {
        self.workDates();
    }

    fn onDateChanged(_: *gtk.Editable, self: *Calc) callconv(.c) void {
        self.workDates();
    }

    fn onDateSpin(_: *gtk.SpinButton, self: *Calc) callconv(.c) void {
        self.workDates();
    }

    /// "Tuesday, Heshvan 20, 5787 (2026-11-11)".
    fn describeDate(self: *Calc, buf: []u8, v: dates.Ymd) []const u8 {
        const civil_date = dates.calsys.toCivil(self.date_sys, v);
        var db: [256]u8 = undefined;
        const d = dates.calsys.describe(&db, self.date_sys, civil_date);
        if (self.date_sys == .gregorian) return std.fmt.bufPrint(buf, "{s}", .{d}) catch "";
        return std.fmt.bufPrint(buf, "{s}  ({d}-{d:0>2}-{d:0>2} Gregorian)", .{ d, civil_date.year, civil_date.month, civil_date.day }) catch "";
    }

    fn workDates(self: *Calc) void {
        var buf: [512]u8 = undefined;
        const sys = self.date_sys;
        // Each date described under its field.
        for (self.date_fields.items) |f| {
            if (dates.parse(sys, std.mem.span(f.entry.as(gtk.Editable).getText()))) |v| {
                f.about.setText(std.fmt.bufPrintSentinel(&buf, "{s}", .{self.describeDate(buf[256..], v)}, 0) catch "");
            } else {
                f.about.setText(t("Not a date in this calendar (year-month-day)"));
            }
        }
        const kind = self.date_kind.getSelected();
        if (kind == 0) {
            const a = dates.parse(sys, std.mem.span(self.date_from.as(gtk.Editable).getText())) orelse return self.date_result.setText("");
            const b = dates.parse(sys, std.mem.span(self.date_to.as(gtk.Editable).getText())) orelse return self.date_result.setText("");
            const s = dates.between(sys, a, b);
            if (s.total_days == 0) return self.date_result.setText(t("The same day"));
            var parts: [3][]const u8 = undefined;
            var n: usize = 0;
            var pbuf: [3][32]u8 = undefined;
            inline for (.{ .{ s.years, "year" }, .{ s.months, "month" }, .{ s.days, "day" } }) |p| {
                if (p[0] != 0) {
                    parts[n] = std.fmt.bufPrint(&pbuf[n], "{d} {s}{s}", .{ p[0], p[1], if (p[0] == 1) "" else "s" }) catch "";
                    n += 1;
                }
            }
            var joined: [160]u8 = undefined;
            var w: std.Io.Writer = .fixed(&joined);
            for (parts[0..n], 0..) |p, i| {
                if (i > 0) w.writeAll(", ") catch {};
                w.writeAll(p) catch {};
            }
            const weeks = @divFloor(s.total_days, 7);
            const extra = @mod(s.total_days, 7);
            self.date_result.setText(std.fmt.bufPrintSentinel(&buf, "{s}\n{d} days in all ({d} weeks and {d} days)", .{ w.buffered(), s.total_days, weeks, extra }, 0) catch "");
        } else {
            const start = dates.parse(sys, std.mem.span(self.date_start.as(gtk.Editable).getText())) orelse return self.date_result.setText("");
            const sign: i64 = if (self.date_sign.getSelected() == 1) -1 else 1;
            const y: i64 = @intFromFloat(self.date_years.getValue());
            const m: i64 = @intFromFloat(self.date_months.getValue());
            const d: i64 = @intFromFloat(self.date_days.getValue());
            const r = dates.add(sys, start, sign * y, sign * m, sign * d);
            var wb: [32]u8 = undefined;
            var db: [300]u8 = undefined;
            self.date_result.setText(std.fmt.bufPrintSentinel(&buf, "{s}\n{s}", .{ dates.write(&wb, r), self.describeDate(&db, r) }, 0) catch "");
        }
    }

    // ---- formulas ----------------------------------------------------------------------------

    fn buildFormulas(self: *Calc) *gtk.Widget {
        const box = gtk.Box.new(.vertical, 6);
        const title = gtk.Label.new(t("Formulas"));
        title.setXalign(0);
        title.as(gtk.Widget).addCssClass("heading");
        box.append(title.as(gtk.Widget));
        self.formula_search.setPlaceholderText(t("Search formulas (area, speed, interest…)"));
        _ = gtk.SearchEntry.signals.search_changed.connect(self.formula_search, *Calc, &onFormulaSearch, self, .{});
        box.append(self.formula_search.as(gtk.Widget));
        const scroll = gtk.ScrolledWindow.new();
        scroll.setChild(self.formula_list.as(gtk.Widget));
        scroll.setPolicy(.never, .automatic);
        scroll.as(gtk.Widget).setSizeRequest(-1, 200);
        scroll.as(gtk.Widget).setVexpand(1);
        self.formula_list.setSelectionMode(.single);
        self.formula_list.setActivateOnSingleClick(1);
        self.formula_list.setHeaderFunc(formulaHeader, self, null);
        self.formula_list.setFilterFunc(formulaFilter, self, null);
        _ = gtk.ListBox.signals.row_activated.connect(self.formula_list, *Calc, &onFormulaRow, self, .{});
        box.append(scroll.as(gtk.Widget));
        self.formula_form.as(gtk.Widget).setMarginTop(6);
        box.append(self.formula_form.as(gtk.Widget));
        const save = gtk.Button.newWithLabel(t("Save Entry as Formula"));
        save.as(gtk.Widget).setTooltipText(t("Keep the equation in the entry (such as P = U·I) among My Formulas"));
        _ = gtk.Button.signals.clicked.connect(save, *Calc, &onSaveFormula, self, .{});
        box.append(save.as(gtk.Widget));
        self.fillFormulaList();
        self.showFormHint();
        return box.as(gtk.Widget);
    }

    fn formulaText(self: *Calc, p: Picked) []const u8 {
        return switch (p) {
            .builtin => |i| formulas.all[i].text,
            .own => |i| if (i < self.own_formulas.items.len) self.own_formulas.items[i] else "",
        };
    }

    /// Rows: the built-in formulas, then My Formulas. A row's name is its index
    /// ("b3", "u0"); the group shows as a header.
    fn fillFormulaList(self: *Calc) void {
        self.formula_list.removeAll();
        var buf: [256]u8 = undefined;
        var nbuf: [16]u8 = undefined;
        for (formulas.all, 0..) |f, i| {
            const name = std.fmt.bufPrintSentinel(&nbuf, "b{d}", .{i}, 0) catch continue;
            self.formulaRow(std.fmt.bufPrintSentinel(&buf, "{s}\n{s}", .{ f.name, f.text }, 0) catch continue, name, false);
        }
        for (self.own_formulas.items, 0..) |f, i| {
            const name = std.fmt.bufPrintSentinel(&nbuf, "u{d}", .{i}, 0) catch continue;
            self.formulaRow(std.fmt.bufPrintSentinel(&buf, "{s}", .{f}, 0) catch continue, name, true);
        }
    }

    /// A row named before it is added, so the group headers see its name.
    fn formulaRow(self: *Calc, text: [:0]const u8, name: [:0]const u8, own: bool) void {
        const row = gtk.ListBoxRow.new();
        row.as(gtk.Widget).setName(name);
        const box = gtk.Box.new(.horizontal, 6);
        const l = gtk.Label.new(text);
        l.setXalign(0);
        l.as(gtk.Widget).setHexpand(1);
        l.as(gtk.Widget).setMarginTop(3);
        l.as(gtk.Widget).setMarginBottom(3);
        box.append(l.as(gtk.Widget));
        if (own) {
            const del = gtk.Button.newFromIconName("edit-delete-symbolic");
            del.setHasFrame(0);
            del.as(gtk.Widget).setTooltipText(t("Remove this formula"));
            _ = gtk.Button.signals.clicked.connect(del, *Calc, &onRemoveFormula, self, .{});
            box.append(del.as(gtk.Widget));
        }
        row.setChild(box.as(gtk.Widget));
        self.formula_list.append(row.as(gtk.Widget));
    }

    fn rowPick(row: *gtk.ListBoxRow) ?Picked {
        const name = std.mem.span(row.as(gtk.Widget).getName());
        if (name.len < 2) return null;
        const i = std.fmt.parseInt(usize, name[1..], 10) catch return null;
        return if (name[0] == 'b') .{ .builtin = i } else .{ .own = i };
    }

    fn onFormulaSearch(_: *gtk.SearchEntry, self: *Calc) callconv(.c) void {
        self.formula_list.invalidateFilter();
        self.formula_list.invalidateHeaders();
    }

    /// A formula shows when every word typed is in its name, group or text.
    fn formulaFilter(row: *gtk.ListBoxRow, data: ?*anyopaque) callconv(.c) c_int {
        const self: *Calc = @ptrCast(@alignCast(data.?));
        const query = std.mem.span(self.formula_search.as(gtk.Editable).getText());
        if (std.mem.trim(u8, query, " ").len == 0) return 1;
        const p = rowPick(row) orelse return 1;
        const name, const group, const text = switch (p) {
            .builtin => |i| .{ formulas.all[i].name, formulas.all[i].group, formulas.all[i].text },
            .own => |i| .{ "", "My Formulas", if (i < self.own_formulas.items.len) self.own_formulas.items[i] else "" },
        };
        var words = std.mem.tokenizeScalar(u8, query, ' ');
        while (words.next()) |w| {
            if (std.ascii.findIgnoreCase(name, w) == null and std.ascii.findIgnoreCase(group, w) == null and std.mem.indexOf(u8, text, w) == null) return 0;
        }
        return 1;
    }

    fn formulaHeader(row: *gtk.ListBoxRow, before: ?*gtk.ListBoxRow, data: ?*anyopaque) callconv(.c) void {
        _ = data;
        const group = groupOf(row);
        const prev_group: []const u8 = if (before) |b| groupOf(b) else "";
        if (std.mem.eql(u8, group, prev_group)) return row.setHeader(null);
        var buf: [64]u8 = undefined;
        const l = gtk.Label.new(std.fmt.bufPrintSentinel(&buf, "{s}", .{group}, 0) catch "");
        l.setXalign(0);
        l.as(gtk.Widget).addCssClass("heading");
        l.as(gtk.Widget).setMarginTop(8);
        l.as(gtk.Widget).setMarginStart(4);
        row.setHeader(l.as(gtk.Widget));
    }

    fn groupOf(row: *gtk.ListBoxRow) []const u8 {
        const p = rowPick(row) orelse return "";
        return switch (p) {
            .builtin => |i| if (i < formulas.all.len) formulas.all[i].group else "",
            .own => "My Formulas",
        };
    }

    fn onFormulaRow(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Calc) callconv(.c) void {
        const p = rowPick(row) orelse return;
        self.pickFormula(p);
    }

    fn dropGraphPlan(self: *Calc) void {
        if (self.graph_plan) |gp| {
            self.gpa.free(gp.expr);
            self.gpa.free(gp.y);
            self.gpa.free(gp.x);
        }
        self.graph_plan = null;
    }

    /// A formula can be drawn when one side is a single letter left empty and
    /// exactly one other letter is empty: that one goes along the x axis.
    fn planGraph(self: *Calc, a: std.mem.Allocator, ev: *eval.Eval, l: *eval.Node, r: *eval.Node) void {
        self.dropGraphPlan();
        var empty: std.ArrayList([]const u8) = .empty;
        for (self.formula_fields.items) |f| {
            if (std.mem.trim(u8, std.mem.span(f.entry.as(gtk.Editable).getText()), " ").len == 0) empty.append(a, f.name) catch return;
        }
        const button = self.formula_graph orelse return;
        defer {
            button.as(gtk.Widget).setSensitive(@intFromBool(self.graph_plan != null));
            button.as(gtk.Widget).setTooltipText(if (self.graph_plan != null)
                t("Draw the formula: the first empty letter up, the other along")
            else
                t("To draw a formula, leave empty the letter on its own on one side and one other letter"));
        }
        if (empty.items.len != 2) return;
        for ([_][2]*eval.Node{ .{ l, r }, .{ r, l } }) |sides| {
            if (sides[0].* != .name) continue;
            const y = sides[0].name.text;
            const x = for (empty.items) |e| {
                if (!std.mem.eql(u8, e, y)) break e;
            } else continue;
            const is_empty = for (empty.items) |e| {
                if (std.mem.eql(u8, e, y)) break true;
            } else false;
            if (!is_empty or !calculus.uses(sides[1], x)) continue;
            const x_node = a.create(eval.Node) catch return;
            x_node.* = .{ .name = .{ .text = "x", .pos = 0 } };
            const along = calculus.substitute(a, sides[1], x, x_node) catch return;
            const text = simplify.print(a, ev, along) catch return;
            self.graph_plan = .{
                .expr = self.gpa.dupe(u8, text) catch return,
                .y = self.gpa.dupe(u8, y) catch return,
                .x = self.gpa.dupe(u8, x) catch return,
            };
            return;
        }
    }

    fn onFormulaGraph(_: *gtk.Button, self: *Calc) callconv(.c) void {
        const gp = self.graph_plan orelse return;
        var buf: [256]u8 = undefined;
        const note = std.fmt.bufPrint(&buf, "{s} up, {s} along (x)", .{ gp.y, gp.x }) catch "";
        // The graph pane replaces this one; the formula stays in the entry.
        self.showPane(.graph);
        self.graph.plot(gp.expr, .{ .y = gp.y, .x = gp.x });
        self.graph.note(note);
    }

    fn clearFields(self: *Calc) void {
        self.dropGraphPlan();
        for (self.formula_fields.items) |f| self.gpa.free(f.name);
        self.formula_fields.clearRetainingCapacity();
        while (self.formula_form.as(gtk.Widget).getFirstChild()) |c| self.formula_form.remove(c);
    }

    fn showFormHint(self: *Calc) void {
        const hint = gtk.Label.new(t("Pick a formula: it goes into the entry, and its letters get fields here. Fill in what you know and press Enter: the one left empty is worked out. With several left empty, the formula is simplified as far as it goes."));
        hint.setXalign(0);
        hint.setWrap(1);
        hint.setMaxWidthChars(40);
        hint.as(gtk.Widget).addCssClass("dim-label");
        self.formula_form.append(hint.as(gtk.Widget));
    }

    /// Puts the formula in the entry and makes a field for each of its letters.
    fn pickFormula(self: *Calc, p: Picked) void {
        self.clearFields();
        const text = self.formulaText(p);
        if (text.len == 0) return;
        self.formula = p;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        // Its letters, in the order of the built-in descriptions (or as they appear).
        var names: std.ArrayList([]const u8) = .empty;
        var whats: std.ArrayList([]const u8) = .empty;
        var defaults: std.ArrayList([]const u8) = .empty;
        switch (p) {
            .builtin => |i| for (formulas.all[i].vars) |v| {
                names.append(a, v.name) catch return;
                whats.append(a, v.what) catch return;
                defaults.append(a, v.default) catch return;
            },
            .own => {
                var pr: eval.Problem = .{};
                const st = eval.parse(a, text, .{}, &pr) catch return;
                switch (st) {
                    .equation => |eq| {
                        collectNames(a, eq.l, &names) catch return;
                        collectNames(a, eq.r, &names) catch return;
                    },
                    .expr => |n| collectNames(a, n, &names) catch return,
                }
                for (names.items) |_| {
                    whats.append(a, "") catch return;
                    defaults.append(a, "") catch return;
                }
            },
        }
        var buf: [256]u8 = undefined;
        const heading = gtk.Label.new(std.fmt.bufPrintSentinel(&buf, "{s}", .{text}, 0) catch "");
        heading.setXalign(0);
        heading.as(gtk.Widget).addCssClass("dkde-calc-formula");
        self.formula_form.append(heading.as(gtk.Widget));
        const g = gtk.Grid.new();
        g.setColumnSpacing(8);
        g.setRowSpacing(4);
        for (names.items, whats.items, defaults.items, 0..) |name, what, default, row| {
            const nl = gtk.Label.new(std.fmt.bufPrintSentinel(&buf, "{s}", .{name}, 0) catch "");
            nl.setXalign(1);
            nl.as(gtk.Widget).addCssClass("dkde-calc-formula-letter");
            const entry = gtk.Entry.new();
            entry.as(gtk.Widget).setHexpand(1);
            entry.setPlaceholderText(if (what.len > 0) (std.fmt.bufPrintSentinel(&buf, "{s}", .{what}, 0) catch null) else t("value"));
            if (default.len > 0) entry.as(gtk.Editable).setText(std.fmt.bufPrintSentinel(&buf, "{s}", .{default}, 0) catch "");
            entry.as(gtk.Widget).setTooltipText(if (what.len > 0) (std.fmt.bufPrintSentinel(&buf, "{s}: {s}", .{ name, what }, 0) catch null) else null);
            g.attach(nl.as(gtk.Widget), 0, @intCast(row), 1, 1);
            g.attach(entry.as(gtk.Widget), 1, @intCast(row), 1, 1);
            const owned = self.gpa.dupe(u8, name) catch continue;
            self.formula_fields.append(self.gpa, .{ .calc = self, .name = owned, .entry = entry }) catch {
                self.gpa.free(owned);
                continue;
            };
            _ = gtk.Editable.signals.changed.connect(entry.as(gtk.Editable), *Calc, &onFieldChanged, self, .{});
            // Enter in a field works the formula out, as in the entry.
            _ = gtk.Entry.signals.activate.connect(entry, *Calc, &onFieldActivate, self, .{});
        }
        self.formula_form.append(g.as(gtk.Widget));
        const buttons = gtk.Box.new(.horizontal, 6);
        const clear_button = gtk.Button.newWithLabel(t("Clear the Values"));
        _ = gtk.Button.signals.clicked.connect(clear_button, *Calc, &onClearFields, self, .{});
        buttons.append(clear_button.as(gtk.Widget));
        const graph_button = gtk.Button.newWithLabel(t("Graph"));
        _ = gtk.Button.signals.clicked.connect(graph_button, *Calc, &onFormulaGraph, self, .{});
        buttons.append(graph_button.as(gtk.Widget));
        self.formula_graph = graph_button;
        self.formula_form.append(buttons.as(gtk.Widget));
        self.updateFormulaEntry();
        if (self.formula_fields.items.len > 0) _ = self.formula_fields.items[0].entry.as(gtk.Widget).grabFocus();
    }

    fn collectNames(a: std.mem.Allocator, n: *const eval.Node, out: *std.ArrayList([]const u8)) !void {
        switch (n.*) {
            .number => {},
            .name => |nm| {
                if (eval.isConstant(nm.text)) return;
                for (out.items) |o| if (std.mem.eql(u8, o, nm.text)) return;
                try out.append(a, nm.text);
            },
            .unary => |u| try collectNames(a, u.arg, out),
            .binary => |b| {
                try collectNames(a, b.l, out);
                try collectNames(a, b.r, out);
            },
            .call => |c| for (c.args) |x| try collectNames(a, x, out),
        }
    }

    fn onFieldChanged(_: *gtk.Editable, self: *Calc) callconv(.c) void {
        self.updateFormulaEntry();
    }

    fn onFieldActivate(_: *gtk.Entry, self: *Calc) callconv(.c) void {
        self.updateFormulaEntry();
        self.calculate();
    }

    fn onClearFields(_: *gtk.Button, self: *Calc) callconv(.c) void {
        for (self.formula_fields.items) |f| f.entry.as(gtk.Editable).setText("");
    }

    /// The formula with the values filled in so far, in the entry.
    fn updateFormulaEntry(self: *Calc) void {
        const p = self.formula orelse return;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const text = self.formulaText(p);
        var pr: eval.Problem = .{};
        const st = eval.parse(a, text, .{}, &pr) catch return;
        var ev: eval.Eval = .{ .a = a, .session = &self.session, .mode = self.evalMode(), .problem = &pr };
        if (st == .equation) {
            const l = self.substitute(a, st.equation.l) catch return;
            const r = self.substitute(a, st.equation.r) catch return;
            self.planGraph(a, &ev, l, r);
        }
        const filled = switch (st) {
            .equation => |eq| std.fmt.allocPrint(a, "{s} = {s}", .{
                simplify.print(a, &ev, self.substitute(a, eq.l) catch return) catch return,
                simplify.print(a, &ev, self.substitute(a, eq.r) catch return) catch return,
            }) catch return,
            .expr => |n| simplify.print(a, &ev, self.substitute(a, n) catch return) catch return,
        };
        // Setting the entry would otherwise drop the formula (it is not typed by hand).
        const keep = self.formula;
        self.fresh = false;
        self.setEntry(filled);
        self.formula = keep;
        self.refreshPreview();
    }

    /// A copy of `n` with each letter that has a value in its field replaced by it.
    fn substitute(self: *Calc, a: std.mem.Allocator, n: *const eval.Node) !*eval.Node {
        const out = try a.create(eval.Node);
        switch (n.*) {
            .name => |nm| {
                for (self.formula_fields.items) |f| {
                    if (!std.mem.eql(u8, f.name, nm.text)) continue;
                    const raw = std.mem.trim(u8, std.mem.span(f.entry.as(gtk.Editable).getText()), " ");
                    if (raw.len == 0) break;
                    const value = cleaned(a, raw) catch break;
                    var pr: eval.Problem = .{};
                    return eval.parseExpr(a, value, .{}, &pr) catch break;
                }
                out.* = n.*;
            },
            .number => out.* = n.*,
            .unary => |u| out.* = .{ .unary = .{ .op = u.op, .arg = try self.substitute(a, u.arg) } },
            .binary => |b| out.* = .{ .binary = .{ .op = b.op, .l = try self.substitute(a, b.l), .r = try self.substitute(a, b.r) } },
            .call => |c| {
                var args = try a.alloc(*eval.Node, c.args.len);
                for (c.args, 0..) |x, i| args[i] = try self.substitute(a, x);
                out.* = .{ .call = .{ .name = c.name, .args = args, .pos = c.pos } };
            },
        }
        return out;
    }

    fn onSaveFormula(_: *gtk.Button, self: *Calc) callconv(.c) void {
        const text = std.mem.trim(u8, self.entryText(), " ");
        if (text.len == 0 or self.fresh) {
            self.preview.setText(t("Type a formula such as P = U·I in the entry first"));
            return;
        }
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        var pr: eval.Problem = .{};
        _ = eval.parse(arena.allocator(), text, .{}, &pr) catch {
            self.preview.setText(t("The entry is not a formula the calculator understands"));
            return;
        };
        for (self.own_formulas.items) |f| if (std.mem.eql(u8, f, text)) return;
        const owned = self.gpa.dupe(u8, text) catch return;
        self.own_formulas.append(self.gpa, owned) catch {
            self.gpa.free(owned);
            return;
        };
        self.fillFormulaList();
        self.saveState();
        self.preview.setText(t("Saved among My Formulas"));
    }

    fn onRemoveFormula(button: *gtk.Button, self: *Calc) callconv(.c) void {
        // The button's row says which formula.
        var w: ?*gtk.Widget = button.as(gtk.Widget);
        while (w) |x| : (w = x.getParent()) {
            if (gobject.typeCheckInstanceIsA(@ptrCast(x), gtk.ListBoxRow.getGObjectType()) == 0) continue;
            const p = rowPick(@ptrCast(@alignCast(x))) orelse return;
            if (p != .own or p.own >= self.own_formulas.items.len) return;
            self.gpa.free(self.own_formulas.orderedRemove(p.own));
            if (self.formula) |f| if (f == .own) {
                self.formula = null;
                self.clearFields();
                self.showFormHint();
            };
            self.saveState();
            _ = glib.idleAdd(refillFormulas, self);
            return;
        }
    }

    fn refillFormulas(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Calc = @ptrCast(@alignCast(data.?));
        self.fillFormulaList();
        return 0;
    }

    // ---- graph ----------------------------------------------------------------------------

    /// Draws each ;-separated part of the entry that is a function of x, if all of them are.
    fn plotFunctions(self: *Calc, a: std.mem.Allocator, text: []const u8) bool {
        const parts = eval.splitTop(a, text, ';') catch return false;
        var found: std.ArrayList([]const u8) = .empty;
        for (parts) |part| {
            if (std.mem.trim(u8, part, " ").len == 0) continue;
            const g = eval.graphable(a, &self.session, part, self.evalMode()) orelse return false;
            found.append(a, g) catch return false;
        }
        if (found.items.len == 0) return false;
        var added: usize = 0;
        var skipped: usize = 0;
        for (found.items) |g| {
            if (self.graph.has(g)) continue;
            if (self.graph.room() == 0) {
                skipped += 1;
                continue;
            }
            self.graph.plot(g, null);
            added += 1;
        }
        var buf: [200]u8 = undefined;
        const msg = if (skipped > 0)
            std.fmt.bufPrintSentinel(&buf, "The graph holds six functions: {d} not added. Remove one first.", .{skipped}, 0) catch ""
        else if (added == 0)
            std.fmt.bufPrintSentinel(&buf, "Already in the graph.", .{}, 0) catch ""
        else
            std.fmt.bufPrintSentinel(&buf, "Added {d} function{s} to the graph.", .{ added, if (added == 1) "" else "s" }, 0) catch "";
        self.preview.as(gtk.Widget).removeCssClass("error");
        self.preview.setText(msg);
        return true;
    }

    fn plotEntry(self: *Calc) void {
        const text = if (self.fresh) "" else self.entryText();
        self.showPane(.graph);
        if (std.mem.trim(u8, text, " ").len > 0) self.graph.plot(text, null);
    }

    // ---- panes and menus --------------------------------------------------------------------

    fn showPane(self: *Calc, pane: Pane) void {
        self.pane = pane;
        const w = self.side.as(gtk.Widget);
        w.setVisible(@intFromBool(pane != .none));
        if (pane != .none) self.side.setVisibleChildName(@tagName(pane));
        inline for (.{ "history", "units", "currency", "dates", "graph", "formulas" }) |name| {
            common.menubar.setChecked(self.window, "pane-" ++ name, std.mem.eql(u8, @tagName(pane), name));
        }
        self.config.setString("calc", "pane", @tagName(pane)) catch {};
        // The window shrinks back when the pane closes.
        self.window.as(gtk.Window).setDefaultSize(-1, -1);
    }

    fn onMenuAction(self: *Calc, action: []const u8) void {
        const eql = std.mem.eql;
        if (eql(u8, action, "close")) return self.window.as(gtk.Window).close();
        if (eql(u8, action, "save-session")) return self.sessionDialog(true);
        if (eql(u8, action, "open-session")) return self.sessionDialog(false);
        if (eql(u8, action, "export-session")) return self.exportDialog();
        if (eql(u8, action, "update-rates")) return self.updateRates();
        if (eql(u8, action, "copy")) return self.copyResult();
        if (eql(u8, action, "paste")) {
            _ = self.entry.as(gtk.Widget).activateAction("clipboard.paste", null);
            return;
        }
        if (eql(u8, action, "clear")) return self.clear();
        if (eql(u8, action, "clear-history")) {
            for (self.history.items) |h| {
                self.gpa.free(h.expr);
                self.gpa.free(h.result);
            }
            self.history.clearRetainingCapacity();
            self.fillHistory();
            self.saveState();
            return;
        }
        if (eql(u8, action, "clear-vars")) {
            while (self.session.vars.count() > 0) _ = self.session.remove(self.session.vars.keys()[0]);
            while (self.session.funcs.count() > 0) _ = self.session.remove(self.session.funcs.keys()[0]);
            self.fillVars();
            self.saveState();
            self.graph.refresh();
            return;
        }
        if (std.mem.startsWith(u8, action, "mode-")) return self.setMode(std.meta.stringToEnum(Mode, action[5..]) orelse .standard);
        if (std.mem.startsWith(u8, action, "pane-")) {
            const p = std.meta.stringToEnum(Pane, action[5..]) orelse .none;
            return self.showPane(if (p == self.pane) .none else p);
        }
        if (std.mem.startsWith(u8, action, "angle-")) return self.setAngle(eval.Angle.parse(action[6..]));
        if (eql(u8, action, "expanded")) {
            self.expanded = !self.expanded;
            self.config.setBool("calc", "expanded", self.expanded) catch {};
            self.tape_scroll.as(gtk.Widget).setVisible(@intFromBool(self.expanded));
            common.menubar.setChecked(self.window, "expanded", self.expanded);
            if (self.expanded) self.scrollTape();
            self.window.as(gtk.Window).setDefaultSize(-1, -1);
            return;
        }
        if (eql(u8, action, "grouping")) {
            self.style.grouping = !self.style.grouping;
            self.config.setBool("calc", "grouping", self.style.grouping) catch {};
            return self.refreshPreview();
        }
        if (std.mem.startsWith(u8, action, "notation-")) {
            const n = std.meta.stringToEnum(num.Notation, action[9..]) orelse .auto;
            self.style.notation = if (self.style.notation == n) .auto else n;
            common.menubar.setChecked(self.window, "notation-scientific", self.style.notation == .scientific);
            common.menubar.setChecked(self.window, "notation-engineering", self.style.notation == .engineering);
            self.config.setString("calc", "notation", @tagName(self.style.notation)) catch {};
            return self.refreshPreview();
        }
    }

    fn onDecimals(_: *gio.SimpleAction, param: ?*glib.Variant, self: *Calc) callconv(.c) void {
        const v = param orelse return;
        const d = std.fmt.parseInt(u8, std.mem.span(v.getString(null)), 10) catch return;
        self.style.decimals = d;
        self.config.setInt("calc", "decimals", d) catch {};
        self.refreshPreview();
    }

    fn copyResult(self: *Calc) void {
        const text = if (self.fresh) (self.plain orelse self.entryText()) else self.entryText();
        var buf: [4096]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{text}, 0) catch return;
        self.window.as(gtk.Widget).getClipboard().setText(z);
    }

    /// Enter works anywhere in the window; typing goes to the entry even
    /// when a key has the focus; Up and Down go through the history.
    fn onKey(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, state: gdk.ModifierType, self: *Calc) callconv(.c) c_int {
        const focus = self.window.as(gtk.Window).getFocus();
        const in_main = focus != null and (focus.? == self.entry.as(gtk.Widget) or focus.?.isAncestor(self.entry.as(gtk.Widget)) != 0);
        const in_other_field = focus != null and !in_main and gobject.typeCheckInstanceIsA(@ptrCast(focus.?), gtk.Text.getGObjectType()) != 0;
        if (in_other_field) return 0;
        const plain_key = !state.control_mask and !state.alt_mask;
        switch (keyval) {
            gdk.KEY_Return, gdk.KEY_KP_Enter, gdk.KEY_ISO_Enter => {
                if (!plain_key) return 0;
                self.calculate();
                return 1;
            },
            gdk.KEY_Escape => {
                self.clear();
                return 1;
            },
            gdk.KEY_Up, gdk.KEY_Down => if (in_main and plain_key) {
                self.recallHistory(keyval == gdk.KEY_Up);
                return 1;
            },
            else => {},
        }
        if (!in_main and plain_key) {
            const ch = gdk.keyvalToUnicode(keyval);
            if (ch >= 0x20 and ch != 0x7f) {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(@intCast(ch), &buf) catch return 0;
                _ = self.entry.as(gtk.Widget).grabFocus();
                self.entry.as(gtk.Editable).setPosition(-1);
                self.insert(buf[0..n]);
                return 1;
            }
            if (keyval == gdk.KEY_BackSpace) {
                self.backspace();
                return 1;
            }
        }
        return 0;
    }

    fn recallHistory(self: *Calc, older: bool) void {
        const n = self.history.items.len;
        if (n == 0) return;
        if (self.recall) |r| {
            if (older) {
                if (r > 0) self.recall = r - 1;
            } else if (r + 1 < n) {
                self.recall = r + 1;
            } else {
                self.recall = null;
                self.fresh = false;
                return self.setEntry("");
            }
        } else if (older) self.recall = n - 1 else return;
        self.fresh = false;
        self.setEntry(self.history.items[self.recall.?].expr);
    }

    // ---- what is kept ----------------------------------------------------------------------

    // ---- sessions saved to a file ---------------------------------------------------------

    fn sessionDialog(self: *Calc, saving: bool) void {
        const dialog = gtk.FileDialog.new();
        defer dialog.as(gobject.Object).unref();
        const filters = gio.ListStore.new(gtk.FileFilter.getGObjectType());
        defer filters.as(gobject.Object).unref();
        const filter = gtk.FileFilter.new();
        filter.setName(t("Calculator sessions"));
        filter.addPattern("*.dkcalc");
        filters.append(filter.as(gobject.Object));
        filter.as(gobject.Object).unref();
        dialog.setFilters(filters.as(gio.ListModel));
        const parent = self.window.as(gtk.Window);
        if (saving) {
            dialog.setInitialName("session.dkcalc");
            dialog.save(parent, null, onSessionSaved, self);
        } else {
            dialog.open(parent, null, onSessionOpened, self);
        }
    }

    /// File > Export Session…: the history, variables and functions as plain text or HTML.
    fn exportDialog(self: *Calc) void {
        const dialog = gtk.FileDialog.new();
        defer dialog.as(gobject.Object).unref();
        const filters = gio.ListStore.new(gtk.FileFilter.getGObjectType());
        defer filters.as(gobject.Object).unref();
        inline for (.{ .{ "Plain text", "*.txt" }, .{ "HTML page", "*.html" } }) |f| {
            const filter = gtk.FileFilter.new();
            filter.setName(t(f[0]));
            filter.addPattern(f[1]);
            filters.append(filter.as(gobject.Object));
            filter.as(gobject.Object).unref();
        }
        dialog.setFilters(filters.as(gio.ListModel));
        dialog.setInitialName("session.txt");
        dialog.save(self.window.as(gtk.Window), null, onExportSaved, self);
    }

    fn onExportSaved(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Calc = @ptrCast(@alignCast(data.?));
        const dialog: *gtk.FileDialog = @ptrCast(@alignCast(source.?));
        const file = dialog.saveFinish(result, null) orelse return;
        defer file.as(gobject.Object).unref();
        const path = file.getPath() orelse return;
        defer glib.free(path);
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const failed = t("The session could not be exported.");
        var full: []const u8 = std.mem.span(path);
        // No extension: plain text.
        if (std.fs.path.extension(full).len == 0) full = std.fmt.allocPrint(a, "{s}.txt", .{full}) catch return;
        const body = self.exportBody(a, export_session.formatOf(full)) orelse return self.preview.setText(failed);
        common.fsio.writeFileAtomic(full, body) catch return self.preview.setText(failed);
        self.preview.setText(t("Session exported."));
    }

    fn exportBody(self: *Calc, a: std.mem.Allocator, format: export_session.Format) ?[]const u8 {
        var entries: std.ArrayList(export_session.Entry) = .empty;
        for (self.history.items) |h| entries.append(a, .{ .expr = h.expr, .result = h.result }) catch return null;
        var vars: std.ArrayList(export_session.Named) = .empty;
        var it = self.session.vars.iterator();
        while (it.next()) |e| {
            const v = e.value_ptr.load(a) catch continue;
            vars.append(a, .{ .name = e.key_ptr.*, .value = num.format(a, v, self.style) catch continue }) catch return null;
        }
        var rit = self.session.rich.iterator();
        while (rit.next()) |e| {
            if (std.mem.eql(u8, e.key_ptr.*, "ans")) continue;
            const v = e.value_ptr.load(a) catch continue;
            vars.append(a, .{ .name = e.key_ptr.*, .value = rich.format(a, v, self.style) catch continue }) catch return null;
        }
        var funcs: std.ArrayList(export_session.Named) = .empty;
        var fit = self.session.funcs.iterator();
        while (fit.next()) |e| {
            const params = std.mem.join(a, ", ", @ptrCast(e.value_ptr.params)) catch continue;
            funcs.append(a, .{ .name = std.fmt.allocPrint(a, "{s}({s})", .{ e.key_ptr.*, params }) catch continue, .value = e.value_ptr.body }) catch return null;
        }
        const now = glib.DateTime.newNowLocal();
        defer if (now) |n| n.unref();
        var when: []const u8 = "";
        if (now) |n| if (n.format("%Y-%m-%d %H:%M")) |f| {
            defer glib.free(f);
            when = a.dupe(u8, std.mem.span(f)) catch "";
        };
        const session: export_session.Session = .{ .when = when, .entries = entries.items, .variables = vars.items, .functions = funcs.items };
        return switch (format) {
            .text => export_session.text(a, session) catch null,
            .html => export_session.html(a, session) catch null,
        };
    }

    fn onSessionSaved(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Calc = @ptrCast(@alignCast(data.?));
        const dialog: *gtk.FileDialog = @ptrCast(@alignCast(source.?));
        const file = dialog.saveFinish(result, null) orelse return;
        defer file.as(gobject.Object).unref();
        const path = file.getPath() orelse return;
        defer glib.free(path);
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const text = self.stateText(arena.allocator()) orelse return self.preview.setText(t("The session could not be saved."));
        var full: []const u8 = std.mem.span(path);
        const named = if (std.ascii.endsWithIgnoreCase(full, ".dkcalc")) full else (std.fmt.allocPrint(arena.allocator(), "{s}.dkcalc", .{full}) catch return);
        full = named;
        common.fsio.writeFileAtomic(full, text) catch return self.preview.setText(t("The session could not be saved."));
        self.preview.setText(t("Session saved."));
    }

    fn onSessionOpened(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Calc = @ptrCast(@alignCast(data.?));
        const dialog: *gtk.FileDialog = @ptrCast(@alignCast(source.?));
        const file = dialog.openFinish(result, null) orelse return;
        defer file.as(gobject.Object).unref();
        const path = file.getPath() orelse return;
        defer glib.free(path);
        const text = (common.fsio.readFile(self.gpa, std.mem.span(path), 4 << 20) catch null) orelse return self.preview.setText(t("The session could not be read."));
        defer self.gpa.free(text);
        self.resetState();
        self.applyState(text);
        self.fillHistory();
        self.fillVars();
        self.graph.refresh();
        self.saveState();
        self.preview.setText(t("Session opened."));
    }

    fn statePath(self: *Calc, name: []const u8) ?[:0]u8 {
        return common.paths.userStateFile(self.gpa, name) catch null;
    }

    /// History, variables, functions, the last answer and the memory, in
    /// $XDG_STATE_HOME/dkde/calc-state: one tab-separated record per line.
    fn saveState(self: *Calc) void {
        const path = self.statePath("calc-state") orelse return;
        defer self.gpa.free(path);
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const text = self.stateText(arena.allocator()) orelse return;
        if (std.fs.path.dirname(path)) |dir| common.fsio.makePath(dir) catch {};
        common.fsio.writeFileAtomic(path, text) catch {};
    }

    /// The whole session as text (the state file's records).
    fn stateText(self: *Calc, a: std.mem.Allocator) ?[]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (self.history.items) |h| out.print(a, "h\t{s}\t{s}\n", .{ oneLine(a, h.expr), oneLine(a, h.result) }) catch return null;
        var it = self.session.vars.iterator();
        while (it.next()) |e| out.print(a, "v\t{s}\t{s}\n", .{ e.key_ptr.*, e.value_ptr.text(a) catch continue }) catch return null;
        var rit = self.session.rich.iterator();
        while (rit.next()) |e| {
            if (std.mem.eql(u8, e.key_ptr.*, "ans")) continue;
            out.print(a, "r\t{s}\t{s}\n", .{ e.key_ptr.*, e.value_ptr.text(a) catch continue }) catch return null;
        }
        var fit = self.session.funcs.iterator();
        while (fit.next()) |e| {
            const params = std.mem.join(a, ",", @ptrCast(e.value_ptr.params)) catch continue;
            out.print(a, "f\t{s}\t{s}\t{s}\n", .{ e.key_ptr.*, params, oneLine(a, e.value_ptr.body) }) catch return null;
        }
        if (self.session.ans) |s| out.print(a, "a\t{s}\n", .{s.text(a) catch ""}) catch return null;
        if (self.memory) |m| out.print(a, "m\t{s}\n", .{m.text(a) catch ""}) catch return null;
        for (self.own_formulas.items) |f| out.print(a, "u\t{s}\n", .{oneLine(a, f)}) catch return null;
        return out.items;
    }

    fn oneLine(a: std.mem.Allocator, s: []const u8) []const u8 {
        const r1 = std.mem.replaceOwned(u8, a, s, "\t", " ") catch return s;
        return std.mem.replaceOwned(u8, a, r1, "\n", " ") catch r1;
    }

    fn loadState(self: *Calc) void {
        const path = self.statePath("calc-state") orelse return;
        defer self.gpa.free(path);
        const text = (common.fsio.readFile(self.gpa, path, 4 << 20) catch null) orelse return;
        defer self.gpa.free(text);
        self.applyState(text);
    }

    /// Forgets the history, variables, functions, answer, memory and own formulas.
    fn resetState(self: *Calc) void {
        for (self.history.items) |h| {
            self.gpa.free(h.expr);
            self.gpa.free(h.result);
        }
        self.history.clearRetainingCapacity();
        while (self.session.vars.count() > 0) _ = self.session.remove(self.session.vars.keys()[0]);
        while (self.session.rich.count() > 0) _ = self.session.remove(self.session.rich.keys()[0]);
        while (self.session.funcs.count() > 0) _ = self.session.remove(self.session.funcs.keys()[0]);
        if (self.session.ans) |s| s.deinit(self.gpa);
        self.session.ans = null;
        if (self.memory) |mm| mm.deinit(self.gpa);
        self.memory = null;
        for (self.own_formulas.items) |f| self.gpa.free(f);
        self.own_formulas.clearRetainingCapacity();
    }

    fn applyState(self: *Calc, text: []const u8) void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            var f = std.mem.splitScalar(u8, line, '\t');
            const kind = f.next() orelse continue;
            if (std.mem.eql(u8, kind, "h")) {
                const e = f.next() orelse continue;
                const r = f.next() orelse continue;
                const ed = self.gpa.dupe(u8, e) catch continue;
                const rd = self.gpa.dupe(u8, r) catch {
                    self.gpa.free(ed);
                    continue;
                };
                self.history.append(self.gpa, .{ .expr = ed, .result = rd }) catch {
                    self.gpa.free(ed);
                    self.gpa.free(rd);
                };
            } else if (std.mem.eql(u8, kind, "v")) {
                const name = f.next() orelse continue;
                const stored = eval.Stored.fromText(self.gpa, f.next() orelse continue) catch continue;
                const key = self.gpa.dupe(u8, name) catch {
                    stored.deinit(self.gpa);
                    continue;
                };
                self.session.vars.put(self.gpa, key, stored) catch {
                    self.gpa.free(key);
                    stored.deinit(self.gpa);
                };
            } else if (std.mem.eql(u8, kind, "r")) {
                const name = f.next() orelse continue;
                const stored = rich.Stored.fromText(self.gpa, f.next() orelse continue) catch continue;
                const key = self.gpa.dupe(u8, name) catch {
                    stored.deinit(self.gpa);
                    continue;
                };
                self.session.rich.put(self.gpa, key, stored) catch {
                    self.gpa.free(key);
                    stored.deinit(self.gpa);
                };
            } else if (std.mem.eql(u8, kind, "f")) {
                const name = f.next() orelse continue;
                const params_text = f.next() orelse continue;
                const body = f.next() orelse continue;
                var params: [16][]const u8 = undefined;
                var n: usize = 0;
                var pit = std.mem.splitScalar(u8, params_text, ',');
                while (pit.next()) |p| {
                    if (n == params.len) break;
                    params[n] = p;
                    n += 1;
                }
                self.session.define(name, params[0..n], body) catch {};
            } else if (std.mem.eql(u8, kind, "u")) {
                const f_text = f.next() orelse continue;
                const owned = self.gpa.dupe(u8, f_text) catch continue;
                self.own_formulas.append(self.gpa, owned) catch self.gpa.free(owned);
            } else if (std.mem.eql(u8, kind, "a") or std.mem.eql(u8, kind, "m")) {
                const stored = eval.Stored.fromText(self.gpa, f.next() orelse continue) catch continue;
                if (kind[0] == 'a') {
                    if (self.session.ans) |s| s.deinit(self.gpa);
                    self.session.ans = stored;
                } else {
                    if (self.memory) |m| m.deinit(self.gpa);
                    self.memory = stored;
                }
            }
        }
    }

    // ---- closing -------------------------------------------------------------------------

    fn onCloseRequest(_: *gtk.Window, self: *Calc) callconv(.c) c_int {
        if (!self.finished) {
            self.finished = true;
            const w = self.window.as(gtk.Widget);
            if (self.window.as(gtk.Window).isMaximized() == 0 and w.getWidth() > 0 and self.pane == .none) {
                self.config.setInt("calc", "width", w.getWidth()) catch {};
                self.config.setInt("calc", "height", w.getHeight()) catch {};
            }
        }
        return 0;
    }

    fn onDestroy(_: *gtk.ApplicationWindow, self: *Calc) callconv(.c) void {
        for (self.keys.items) |key| self.gpa.destroy(key);
        self.keys.deinit(self.gpa);
        for (self.date_fields.items) |f| self.gpa.destroy(f);
        self.date_fields.deinit(self.gpa);
        for (self.history.items) |h| {
            self.gpa.free(h.expr);
            self.gpa.free(h.result);
        }
        self.history.deinit(self.gpa);
        if (self.plain) |p| self.gpa.free(p);
        if (self.memory) |m| m.deinit(self.gpa);
        for (self.own_formulas.items) |f| self.gpa.free(f);
        self.own_formulas.deinit(self.gpa);
        self.dropGraphPlan();
        // The widgets are already gone: only the names are freed.
        for (self.formula_fields.items) |f| self.gpa.free(f.name);
        self.formula_fields.deinit(self.gpa);
        self.graph.destroy();
        self.session.deinit();
        self.config.deinit();
        self.gpa.destroy(self);
    }
};

pub const std_options: std.Options = .{ .logFn = common.log.logFn, .log_level = .debug };

pub fn main(init: std.process.Init.Minimal) !void {
    cli.handle(init.args, .{ .name = "dkde-calc", .summary = "Calculator" });
    try common.runapp.run("org.dkde.calc", Calc, init);
}

test {
    _ = @import("num.zig");
    _ = @import("eval.zig");
    _ = @import("units.zig");
    _ = @import("dates.zig");
    _ = @import("simplify.zig");
    _ = @import("calculus.zig");
    _ = @import("formulas.zig");
    _ = @import("letters.zig");
    _ = @import("accuracy_test.zig");
    _ = @import("qalc_reference_test.zig");
    _ = @import("functions.zig");
    _ = @import("convert.zig");
    _ = @import("rich.zig");
    _ = @import("quantity.zig");
    _ = @import("highlight.zig");
    _ = @import("export.zig");
    _ = @import("bigreal.zig");
    _ = @import("symbolic.zig");
    _ = @import("algebra.zig");
    _ = @import("steps.zig");
}
