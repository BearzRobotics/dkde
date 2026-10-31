//! Stylesheet loading (SPEC.md 6.2): the system stylesheet at application
//! priority, then the user's overrides above it.

const std = @import("std");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const config_mod = @import("config.zig");

const paths = @import("paths.zig");

const log = std.log.scoped(.style);

/// Appearance sits above the system stylesheet and below the user's own.
const appearance_priority = gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 1;
const user_priority = gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 10;

pub const default_accent = "#3584e4";

/// Loads both stylesheets onto the default display. Call once GTK is
/// initialised (from the application's `activate` handler).
pub fn load(allocator: std.mem.Allocator) !void {
    const display = gdk.Display.getDefault() orelse return error.NoDisplay;

    if (try paths.systemDataFile(allocator, "style.css")) |path| {
        defer allocator.free(path);
        add(display, path, gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
    } else {
        log.warn("style.css not found in the dkde data directories", .{});
    }

    const user = try paths.userConfigFile(allocator, "style.css");
    defer allocator.free(user);
    if (glib.fileTest(user, .{ .exists = true }) != 0)
        add(display, user, user_priority);
}

fn add(display: *gdk.Display, path: [:0]const u8, priority: c_uint) void {
    const provider = gtk.CssProvider.new();
    defer provider.as(gobject.Object).unref();
    provider.loadFromPath(path);
    gtk.StyleContext.addProviderForDisplay(display, provider.as(gtk.StyleProvider), priority);
}

/// The shared look from `dkde.conf` (accent colour, light/dark, UI font),
/// applied to this process and re-applied whenever the file changes
/// (SPEC.md 6.2).
pub const Appearance = struct {
    allocator: std.mem.Allocator,
    config: config_mod.Config,
    provider: *gtk.CssProvider,

    pub fn create(allocator: std.mem.Allocator) !*Appearance {
        const self = try allocator.create(Appearance);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .config = try config_mod.Config.load(allocator, "dkde.conf"),
            .provider = gtk.CssProvider.new(),
        };
        errdefer self.config.deinit();

        const display = gdk.Display.getDefault() orelse return error.NoDisplay;
        gtk.StyleContext.addProviderForDisplay(display, self.provider.as(gtk.StyleProvider), appearance_priority);
        self.apply();
        self.config.watch(Appearance, onChanged, self) catch |err|
            log.warn("dkde.conf not watched: {s}", .{@errorName(err)});
        return self;
    }

    pub fn destroy(self: *Appearance) void {
        self.provider.as(gobject.Object).unref();
        self.config.deinit();
        self.allocator.destroy(self);
    }

    fn onChanged(self: *Appearance) void {
        self.apply();
    }

    fn apply(self: *Appearance) void {
        const accent_raw = self.config.getString(self.allocator, "appearance", "accent", default_accent) catch return;
        defer self.allocator.free(accent_raw);
        const accent_z = self.allocator.dupeSentinel(u8, accent_raw, 0) catch return;
        defer self.allocator.free(accent_z);
        var rgba: gdk.RGBA = undefined;
        const accent: [:0]const u8 = if (rgba.parse(accent_z) != 0) accent_z else blk: {
            log.warn("dkde.conf: invalid accent '{s}'; using default", .{accent_raw});
            break :blk default_accent;
        };

        const dark = self.config.getBool("appearance", "dark", false);
        const css = std.fmt.allocPrintSentinel(self.allocator,
            \\@define-color dkde_accent {[accent]s};
            \\@define-color dkde_bg {[bg]s};
            \\@define-color dkde_fg {[fg]s};
            \\/* GTK's own widgets (switches, suggested-action buttons, focus rings,
            \\   selections) take their accent from these names. */
            \\@define-color accent_bg_color {[accent]s};
            \\@define-color accent_color {[accent]s};
            \\@define-color accent_fg_color #ffffff;
            \\@define-color theme_selected_bg_color {[accent]s};
            \\@define-color theme_selected_fg_color #ffffff;
            \\@define-color selected_bg_color {[accent]s};
            \\@define-color selected_fg_color #ffffff;
        , .{
            .accent = accent,
            .bg = if (dark) "#242424" else "#f6f5f4",
            .fg = if (dark) "#f0f0f0" else "#1e1e1e",
        }, 0) catch return;
        defer self.allocator.free(css);
        self.provider.loadFromString(css);

        // Built-in widgets follow GTK's own dark preference and font.
        const settings = gtk.Settings.getDefault() orelse return;
        // Windows-style caption buttons on the right.
        settings.as(gobject.Object).set("gtk-decoration-layout", @as([*:0]const u8, ":minimize,maximize,close"), @as(?*anyopaque, null));
        settings.as(gobject.Object).set("gtk-application-prefer-dark-theme", @as(c_int, @intFromBool(dark)), @as(?*anyopaque, null));
        const font = self.config.getString(self.allocator, "appearance", "font", "") catch return;
        defer self.allocator.free(font);
        if (font.len > 0) {
            const font_z = self.allocator.dupeSentinel(u8, font, 0) catch return;
            defer self.allocator.free(font_z);
            settings.as(gobject.Object).set("gtk-font-name", font_z.ptr, @as(?*anyopaque, null));
        }
    }
};

/// A zero-size widget whose CSS `color` is the accent colour. Code that draws
/// with cairo cannot read CSS variables, but it can read this widget's colour
/// (`accentOf`), so drawn parts follow the accent setting like everything else.
pub fn accentProbe() *gtk.Widget {
    const probe = gtk.Box.new(.horizontal, 0);
    probe.as(gtk.Widget).addCssClass("dkde-accent-probe");
    probe.as(gtk.Widget).setCanTarget(0);
    return probe.as(gtk.Widget);
}

pub fn accentOf(probe: *gtk.Widget) gdk.RGBA {
    var color: gdk.RGBA = undefined;
    probe.getColor(&color);
    return color;
}
