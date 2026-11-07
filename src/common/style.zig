//! Stylesheet loading (SPEC.md 6.2): the system stylesheet at application
//! priority, then the user's overrides above it.

const std = @import("std");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const config_mod = @import("core").config;

const paths = @import("core").paths;
const icons = @import("core").icons;
const toolkits = @import("core").toolkits;

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
    /// The icon theme before dkde chose one, to go back to when the choice is cleared.
    system_icon_theme: ?[:0]u8 = null,
    icon_paths_added: bool = false,
    applied_icons: ?[]u8 = null,

    pub fn create(allocator: std.mem.Allocator) !*Appearance {
        const self = try allocator.create(Appearance);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .config = try config_mod.Config.load(allocator, "dkde.toml"),
            .provider = gtk.CssProvider.new(),
        };
        errdefer self.config.deinit();
        if (gtk.Settings.getDefault()) |settings| {
            var current: ?[*:0]u8 = null;
            settings.as(gobject.Object).get("gtk-icon-theme-name", &current, @as(?*anyopaque, null));
            if (current) |c| {
                defer glib.free(c);
                self.system_icon_theme = allocator.dupeSentinel(u8, std.mem.span(c), 0) catch null;
            }
        }

        const display = gdk.Display.getDefault() orelse return error.NoDisplay;
        gtk.StyleContext.addProviderForDisplay(display, self.provider.as(gtk.StyleProvider), appearance_priority);
        self.apply();
        self.config.watch(Appearance, onChanged, self) catch |err|
            log.warn("dkde.conf not watched: {s}", .{@errorName(err)});
        return self;
    }

    pub fn destroy(self: *Appearance) void {
        if (self.system_icon_theme) |t| self.allocator.free(t);
        if (self.applied_icons) |t| self.allocator.free(t);
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
        const effective_icons = self.applyIcons(settings);
        const font = self.config.getString(self.allocator, "appearance", "font", "") catch return;
        defer self.allocator.free(font);
        if (font.len > 0) {
            const font_z = self.allocator.dupeSentinel(u8, font, 0) catch return;
            defer self.allocator.free(font_z);
            settings.as(gobject.Object).set("gtk-font-name", font_z.ptr, @as(?*anyopaque, null));
        }
        if (export_toolkits and self.config.getBool("appearance", "export-toolkits", true)) self.exportToolkits(accent_z, dark, effective_icons, font);
    }

    /// Sets GTK's icon theme from the two icon settings and returns the name
    /// that was set (borrowed from `self`), or "" when the system's is kept.
    ///
    /// `icon-theme` is the theme for apps, folders and file types. `ui-icon-theme`
    /// is the theme for the small interface glyphs (window buttons, arrows,
    /// toolbar actions). GTK has one icon theme, so when both are in play a
    /// generated theme ("dkde-active") inherits the UI one first, then the other.
    fn applyIcons(self: *Appearance, settings: *gtk.Settings) []const u8 {
        const a = self.allocator;
        if (!self.icon_paths_added) {
            self.icon_paths_added = true;
            if (gdk.Display.getDefault()) |display| {
                const theme = gtk.IconTheme.getForDisplay(display);
                if (icons.bundledDirs(a)) |dirs| {
                    defer icons.free(a, dirs);
                    for (dirs) |d| if (a.dupeSentinel(u8, d, 0)) |z| {
                        defer a.free(z);
                        theme.addSearchPath(z);
                    } else |_| {};
                } else |_| {}
            }
        }
        const app_chosen = self.config.getString(a, "appearance", "icon-theme", "") catch return "";
        defer a.free(app_chosen);
        const ui_chosen = self.config.getString(a, "appearance", "ui-icon-theme", "") catch return "";
        defer a.free(ui_chosen);
        const installed = icons.list(a) catch return "";
        defer icons.free(a, installed);
        const have = struct {
            fn has(names: [][]u8, want: []const u8) bool {
                for (names) |n| if (std.mem.eql(u8, n, want)) return true;
                return false;
            }
        }.has;

        // The theme for apps and file types: the chosen one, else Fluent, then Papirus, then the system's.
        const app: []const u8 = if (app_chosen.len > 0 and have(installed, app_chosen)) app_chosen else if (have(installed, "Fluent")) "Fluent" else if (have(installed, "Papirus")) "Papirus" else if (self.system_icon_theme) |sys| sys else "";
        // The theme for interface glyphs: "same" means no separate one; empty is dkde-ui.
        const ui: []const u8 = if (std.mem.eql(u8, ui_chosen, "same")) "" else if (ui_chosen.len > 0 and have(installed, ui_chosen)) ui_chosen else if (ui_chosen.len == 0 and have(installed, "dkde-ui")) "dkde-ui" else "";

        const name: []const u8 = blk: {
            if (ui.len == 0 or std.mem.eql(u8, ui, app)) break :blk app;
            const changed = icons.writeComposite(a, ui, app) catch break :blk app;
            if (changed) {
                // GTK reloads a theme when the name changes, not when its file does.
                settings.as(gobject.Object).set("gtk-icon-theme-name", @as([*:0]const u8, "hicolor"), @as(?*anyopaque, null));
            }
            break :blk icons.composite_name;
        };
        if (name.len == 0) return "";
        if (a.dupeSentinel(u8, name, 0)) |z| {
            defer a.free(z);
            settings.as(gobject.Object).set("gtk-icon-theme-name", z.ptr, @as(?*anyopaque, null));
        } else |_| return "";
        if (self.applied_icons) |old| a.free(old);
        self.applied_icons = a.dupe(u8, name) catch null;
        return self.applied_icons orelse "";
    }

    fn exportToolkits(self: *Appearance, accent: [:0]const u8, dark: bool, chosen_icons: []const u8, font: []const u8) void {
        var rgba: gdk.RGBA = undefined;
        if (rgba.parse(accent) == 0) return;
        var hex_buf: [8]u8 = undefined;
        const hex = std.fmt.bufPrint(&hex_buf, "#{x:0>2}{x:0>2}{x:0>2}", .{
            channel(rgba.f_red), channel(rgba.f_green), channel(rgba.f_blue),
        }) catch return;
        const icon_name = chosen_icons;
        toolkits.sync(self.allocator, .{ .dark = dark, .accent = hex, .font = font, .icon_theme = icon_name });
    }
};

fn channel(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}

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

/// Set by the one long-running program (the panel) that exports the appearance
/// to GTK 3/4 and Qt config files; the other programs leave those files alone.
pub var export_toolkits = false;
