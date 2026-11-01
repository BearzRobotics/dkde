//! The Console page (SPEC.md 5.5, 5.11): font, size, colour scheme and
//! scrollback for `dkde-console`, with a preview drawn by the console's own
//! font code. The console's settings live in /etc, so this page never writes
//! them: **Apply** asks for the password and runs `dkde-console config set`
//! for each value, which validates it. A running console picks the change up
//! at once (it watches the file).

const std = @import("std");
const gdk = @import("gdk4");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");
const cf = @import("consolefont");
const termcore = @import("termcore");

const win = @import("window.zig");
const SettingsWindow = win.SettingsWindow;

const gpa = std.heap.c_allocator;
const config = cf.config;

const apply_script =
    \\set -e
    \\dkde-console config set font "$1"
    \\dkde-console config set font-size "$2"
    \\dkde-console config set colors "$3"
    \\dkde-console config set scrollback-lines "$4"
;

pub const ConsolePage = struct {
    window: *SettingsWindow,
    font_list: *gtk.StringList,
    font_dd: *gtk.DropDown,
    /// Path per drop-down entry; entry 0 is the built-in font (empty path).
    font_paths: std.ArrayList([]u8) = .empty,
    size: *gtk.SpinButton,
    scheme_dd: *gtk.DropDown,
    scrollback: *gtk.SpinButton,
    picture: *gtk.Picture,
    status: *gtk.Label,
    /// The loaded font file the preview borrows from.
    font_data: ?[]u8 = null,

    pub fn build(window: *SettingsWindow) *gtk.Box {
        const page = SettingsWindow.newPage(common.tr("Console"));
        const self = gpa.create(ConsolePage) catch @panic("OOM");
        self.* = .{
            .window = window,
            .font_list = gtk.StringList.new(null),
            .font_dd = undefined,
            .size = gtk.SpinButton.newWithRange(0, 128, 1),
            .scheme_dd = undefined,
            .scrollback = gtk.SpinButton.newWithRange(0, 100000, 100),
            .picture = gtk.Picture.new(),
            .status = gtk.Label.new(""),
        };

        const intro = gtk.Label.new(common.tr("The text console on the virtual terminals (Ctrl+Alt+F1 to F6). These settings are system-wide: Apply asks for an administrator password. A running console changes at once."));
        intro.setXalign(0);
        intro.setWrap(1);
        intro.as(gtk.Widget).addCssClass("dim-label");
        page.append(intro.as(gtk.Widget));

        // Current values: /etc over the shipped defaults over the built-in ones.
        var etc = readDoc("DKDE_CONSOLE_CONF", "/etc/dkde/console.conf");
        defer etc.deinit();
        var defs = readDefaults();
        defer defs.deinit();
        const layers: config.Layers = .{ .etc = &etc, .defaults = &defs };
        const cur_font = config.lookup(layers, 0, config.find("font").?).text;
        const cur_size = std.fmt.parseInt(u32, config.lookup(layers, 0, config.find("font-size").?).text, 10) catch 0;
        const cur_scheme = config.lookup(layers, 0, config.find("colors").?).text;
        const cur_scroll = std.fmt.parseInt(u32, config.lookup(layers, 0, config.find("scrollback-lines").?).text, 10) catch 2000;

        self.fillFonts(cur_font);
        self.font_dd = gtk.DropDown.new(self.font_list.as(gio.ListModel), null);
        self.font_dd.as(gtk.Widget).setSizeRequest(300, -1);
        for (self.font_paths.items, 0..) |p, i| if (std.mem.eql(u8, p, cur_font)) self.font_dd.setSelected(@intCast(i));

        const scheme_list = gtk.StringList.new(null);
        var scheme_index: c_uint = 0;
        inline for (termcore.schemes.names, 0..) |n, i| {
            scheme_list.append((n ++ "\x00")[0..n.len :0]);
            if (std.mem.eql(u8, n, cur_scheme)) scheme_index = i;
        }
        self.scheme_dd = gtk.DropDown.new(scheme_list.as(gio.ListModel), null);
        self.scheme_dd.setSelected(scheme_index);
        self.size.setValue(@floatFromInt(cur_size));
        self.scrollback.setValue(@floatFromInt(cur_scroll));

        SettingsWindow.addRowDesc(page, common.tr("Font"), "Built-in Terminus, a console PSF font, or a monospace TrueType font", self.font_dd.as(gtk.Widget));
        SettingsWindow.addRowDesc(page, common.tr("Size"), "Height of a character cell in pixels; 0 picks one from the screen's size", self.size.as(gtk.Widget));
        SettingsWindow.addRow(page, common.tr("Colour scheme"), self.scheme_dd.as(gtk.Widget));
        SettingsWindow.addRow(page, common.tr("Scrollback (lines)"), self.scrollback.as(gtk.Widget));

        self.picture.setCanShrink(0);
        self.picture.as(gtk.Widget).setHalign(.start);
        self.picture.as(gtk.Widget).addCssClass("dkde-console-preview");
        page.append(self.picture.as(gtk.Widget));

        const bar = gtk.Box.new(.horizontal, 8);
        const apply = gtk.Button.newWithLabel(common.tr("Apply to the console"));
        apply.as(gtk.Widget).addCssClass("suggested-action");
        self.status.setXalign(0);
        self.status.as(gtk.Widget).addCssClass("dim-label");
        bar.append(apply.as(gtk.Widget));
        bar.append(self.status.as(gtk.Widget));
        page.append(bar.as(gtk.Widget));

        _ = gobject.Object.signals.notify.connect(self.font_dd, *ConsolePage, &onChanged, self, .{ .detail = "selected" });
        _ = gobject.Object.signals.notify.connect(self.scheme_dd, *ConsolePage, &onChanged, self, .{ .detail = "selected" });
        _ = gtk.SpinButton.signals.value_changed.connect(self.size, *ConsolePage, &onSpin, self, .{});
        _ = gtk.Button.signals.clicked.connect(apply, *ConsolePage, &onApply, self, .{});
        self.refresh();
        return page;
    }

    fn fillFonts(self: *ConsolePage, current: []const u8) void {
        self.font_list.append(common.tr("Built-in (Terminus)"));
        self.font_paths.append(gpa, gpa.dupe(u8, "") catch return) catch return;
        const found = cf.fontscan.scan(gpa) catch &.{};
        defer {
            for (found) |p| gpa.free(p);
            gpa.free(found);
        }
        var have_current = current.len == 0;
        for (found) |p| {
            if (std.mem.eql(u8, p, current)) have_current = true;
            self.addFont(p);
        }
        // A font set by hand that the scan does not list is still shown.
        if (!have_current) self.addFont(current);
    }

    fn addFont(self: *ConsolePage, path: []const u8) void {
        const z = gpa.dupeSentinel(u8, path, 0) catch return;
        defer gpa.free(z);
        self.font_list.append(z.ptr);
        self.font_paths.append(gpa, gpa.dupe(u8, path) catch return) catch return;
    }

    fn onChanged(_: *gtk.DropDown, _: *gobject.ParamSpec, self: *ConsolePage) callconv(.c) void {
        self.refresh();
    }

    fn onSpin(_: *gtk.SpinButton, self: *ConsolePage) callconv(.c) void {
        self.refresh();
    }

    fn selectedFont(self: *ConsolePage) []const u8 {
        const i = self.font_dd.getSelected();
        return if (i < self.font_paths.items.len) self.font_paths.items[i] else "";
    }

    fn selectedScheme(self: *ConsolePage) []const u8 {
        const i = self.scheme_dd.getSelected();
        return if (i < termcore.schemes.names.len) termcore.schemes.names[i] else termcore.schemes.default_scheme;
    }

    /// Draws the preview again with the chosen font, size and scheme.
    fn refresh(self: *ConsolePage) void {
        if (self.font_data) |d| gpa.free(d);
        self.font_data = null;
        const path = self.selectedFont();
        var failed = false;
        if (path.len > 0) {
            if (gpa.dupeSentinel(u8, path, 0)) |z| {
                defer gpa.free(z);
                self.font_data = cf.fontscan.readFile(gpa, z, 32 << 20);
            } else |_| {}
            failed = self.font_data == null;
        }
        const size: u32 = @intCast(self.size.getValueAsInt());
        var preview = cf.sample.Preview.init(gpa, self.font_data, if (size == 0) 20 else size) catch blk: {
            failed = true;
            break :blk cf.sample.Preview.init(gpa, null, 16) catch return;
        };
        defer preview.deinit();
        self.status.setText(if (failed) common.tr("That font cannot be read; the preview shows the built-in one.") else "");

        const w: u32 = 720;
        const h: u32 = 16 + preview.cell_h * @as(u32, cf.sample.Preview.rows);
        const px = gpa.alloc(u32, w * h) catch return;
        defer gpa.free(px);
        preview.draw(px, w, h, termcore.schemes.scheme(self.selectedScheme()));
        const bytes = glib.Bytes.new(@ptrCast(px.ptr), px.len * 4);
        defer bytes.unref();
        const texture = gdk.MemoryTexture.new(@intCast(w), @intCast(h), .b8g8r8a8_premultiplied, bytes, w * 4);
        defer texture.as(gobject.Object).unref();
        self.picture.setPaintable(texture.as(gdk.Paintable));
    }

    fn onApply(_: *gtk.Button, self: *ConsolePage) callconv(.c) void {
        var size_buf: [16]u8 = undefined;
        var scroll_buf: [16]u8 = undefined;
        const size = std.fmt.bufPrint(&size_buf, "{d}", .{self.size.getValueAsInt()}) catch return;
        const scroll = std.fmt.bufPrint(&scroll_buf, "{d}", .{self.scrollback.getValueAsInt()}) catch return;
        common.elevate.run(
            self.window.window.as(gtk.Window),
            "Change the settings of the text console",
            &.{ "sh", "-c", apply_script, "dkde-console-apply", self.selectedFont(), size, self.selectedScheme(), scroll },
            "",
            ConsolePage,
            onDone,
            self,
        );
    }

    fn onDone(self: *ConsolePage, outcome: common.elevate.Outcome, message: []const u8) void {
        if (outcome == .failed) {
            var buf: [512]u8 = undefined;
            const text = std.fmt.bufPrintSentinel(&buf, "{s}", .{message}, 0) catch "";
            common.dialogs.showError(self.window.window.as(gtk.Window), common.tr("The console settings could not be changed"), text);
            return;
        }
        self.status.setText(common.tr("Applied. A running console shows the change now."));
    }
};

fn readDoc(env: [:0]const u8, default: [:0]const u8) termcore.ini.Document {
    const path = if (std.c.getenv(env)) |p| std.mem.span(p) else default;
    return readDocAt(path);
}

fn readDocAt(path: []const u8) termcore.ini.Document {
    const z = gpa.dupeSentinel(u8, path, 0) catch return termcore.ini.Document.init(gpa);
    defer gpa.free(z);
    const text = cf.fontscan.readFile(gpa, z, 1 << 20) orelse return termcore.ini.Document.init(gpa);
    defer gpa.free(text);
    return termcore.ini.Document.parse(gpa, text) catch termcore.ini.Document.init(gpa);
}

fn readDefaults() termcore.ini.Document {
    var buf: [512]u8 = undefined;
    const dir = if (std.c.getenv("DKDE_DATA_DIR")) |p| std.mem.span(p) else "/usr/share/dkde";
    return readDocAt(std.fmt.bufPrint(&buf, "{s}/console.conf", .{dir}) catch "");
}
