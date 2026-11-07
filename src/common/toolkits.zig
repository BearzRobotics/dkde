//! Exports dkde's appearance (dark mode, accent, font, icon theme) to the other
//! toolkits, so GTK 3, GTK 4 apps that do not load dkde's stylesheet, and Qt 5/6
//! programs look like the rest of the desktop. Files are rewritten whenever the
//! appearance changes; they live in `$XDG_CONFIG_HOME` where those toolkits look.
//!
//! Qt is styled through qt5ct/qt6ct (palette, icons, fonts) with the Kvantum
//! style on top when it is installed. `scripts/dkde-session` sets
//! `QT_QPA_PLATFORMTHEME=qt6ct` so Qt reads these files.

const std = @import("std");
const glib = @import("glib2");
const fsio = @import("fsio.zig");

pub const Theme = struct {
    dark: bool,
    /// `#rrggbb`.
    accent: []const u8,
    /// A Pango font description, or empty for the toolkit's default.
    font: []const u8 = "",
    /// An icon theme name, or empty for none.
    icon_theme: []const u8 = "",
};

const Palette = struct {
    window: []const u8,
    base: []const u8,
    alt_base: []const u8,
    button: []const u8,
    text: []const u8,
    light: []const u8,
    midlight: []const u8,
    mid: []const u8,
    dark: []const u8,
    shadow: []const u8,
    disabled_text: []const u8,
    tooltip: []const u8,
};

fn paletteFor(dark: bool) Palette {
    return if (dark) .{
        .window = "#242424",
        .base = "#1e1e1e",
        .alt_base = "#282828",
        .button = "#333333",
        .text = "#f0f0f0",
        .light = "#4a4a4a",
        .midlight = "#3d3d3d",
        .mid = "#2c2c2c",
        .dark = "#141414",
        .shadow = "#000000",
        .disabled_text = "#8a8a8a",
        .tooltip = "#3a3a3a",
    } else .{
        .window = "#f6f5f4",
        .base = "#ffffff",
        .alt_base = "#f2f1f0",
        .button = "#e8e6e3",
        .text = "#1e1e1e",
        .light = "#ffffff",
        .midlight = "#f0efed",
        .mid = "#c0bfbc",
        .dark = "#9a9996",
        .shadow = "#77767b",
        .disabled_text = "#8a8a8a",
        .tooltip = "#ffffdc",
    };
}

/// GTK's `settings.ini`, shared by GTK 3 and 4.
pub fn gtkSettings(a: std.mem.Allocator, t: Theme) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.print(a, "[Settings]\ngtk-application-prefer-dark-theme={d}\ngtk-decoration-layout=:minimize,maximize,close\n", .{@intFromBool(t.dark)});
    if (t.icon_theme.len > 0) try out.print(a, "gtk-icon-theme-name={s}\n", .{t.icon_theme});
    if (t.font.len > 0) try out.print(a, "gtk-font-name={s}\n", .{t.font});
    return out.toOwnedSlice(a);
}

/// The colour names GTK 3/4 and libadwaita take their accent and window
/// colours from, written to `gtk-3.0/gtk.css` and `gtk-4.0/gtk.css`.
pub fn gtkCss(a: std.mem.Allocator, t: Theme) std.mem.Allocator.Error![]u8 {
    const p = paletteFor(t.dark);
    return std.fmt.allocPrint(a,
        \\/* Written by dkde from ~/.config/dkde/dkde.toml; edits are overwritten. */
        \\@define-color accent_bg_color {[accent]s};
        \\@define-color accent_color {[accent]s};
        \\@define-color accent_fg_color #ffffff;
        \\@define-color theme_selected_bg_color {[accent]s};
        \\@define-color theme_selected_fg_color #ffffff;
        \\@define-color selected_bg_color {[accent]s};
        \\@define-color selected_fg_color #ffffff;
        \\@define-color window_bg_color {[window]s};
        \\@define-color window_fg_color {[text]s};
        \\@define-color view_bg_color {[base]s};
        \\@define-color view_fg_color {[text]s};
        \\@define-color theme_bg_color {[window]s};
        \\@define-color theme_fg_color {[text]s};
        \\@define-color theme_base_color {[base]s};
        \\@define-color theme_text_color {[text]s};
        \\
    , .{ .accent = t.accent, .window = p.window, .base = p.base, .text = p.text });
}

/// One qt5ct/qt6ct colour list: `#aarrggbb` entries in QPalette role order.
fn qtColors(a: std.mem.Allocator, t: Theme, disabled: bool, with_accent: bool) std.mem.Allocator.Error![]u8 {
    const p = paletteFor(t.dark);
    const fg = if (disabled) p.disabled_text else p.text;
    const roles = [_][]const u8{
        fg, p.button, p.light, p.midlight, p.dark, p.mid, // WindowText Button Light Midlight Dark Mid
        fg, "#ffffff", fg, p.base, p.window, p.shadow, // Text BrightText ButtonText Base Window Shadow
        t.accent, "#ffffff", t.accent, "#a347ba", p.alt_base, // Highlight HighlightedText Link LinkVisited AlternateBase
        p.tooltip, if (t.dark) "#f0f0f0" else "#1e1e1e", p.disabled_text, // ToolTipBase ToolTipText PlaceholderText
    };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for (roles, 0..) |c, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        try out.print(a, "#ff{s}", .{c[1..]});
    }
    if (with_accent) try out.print(a, ", #ff{s}", .{t.accent[1..]});
    return out.toOwnedSlice(a);
}

/// A qt5ct/qt6ct colour scheme file.
pub fn qtColorScheme(a: std.mem.Allocator, t: Theme, qt6: bool) std.mem.Allocator.Error![]u8 {
    const active = try qtColors(a, t, false, qt6);
    defer a.free(active);
    const disabled = try qtColors(a, t, true, qt6);
    defer a.free(disabled);
    return std.fmt.allocPrint(a, "[ColorScheme]\nactive_colors={s}\ninactive_colors={s}\ndisabled_colors={s}\n", .{ active, active, disabled });
}

/// `qt5ct.conf` / `qt6ct.conf`. `scheme` is the colour scheme file's path.
pub fn qtConf(a: std.mem.Allocator, t: Theme, scheme: []const u8, kvantum: bool) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.print(a, "[Appearance]\ncolor_scheme_path={s}\ncustom_palette=true\nstyle={s}\nstandard_dialogs=default\n", .{
        scheme, if (kvantum) "kvantum" else "Fusion",
    });
    if (t.icon_theme.len > 0) try out.print(a, "icon_theme={s}\n", .{t.icon_theme});
    if (t.font.len > 0) try out.print(a, "\n[Fonts]\ngeneral=\"{s}\"\nfixed=\"{s}\"\n", .{ t.font, t.font });
    return out.toOwnedSlice(a);
}

/// `Kvantum/kvantum.kvconfig`: which Kvantum theme is active.
pub fn kvantumSelect(a: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
    return a.dupe(u8, "[General]\ntheme=dkde\n");
}

/// `Kvantum/dkde/dkde.kvconfig`: Kvantum's flat theme recoloured with dkde's palette.
pub fn kvantumTheme(a: std.mem.Allocator, t: Theme) std.mem.Allocator.Error![]u8 {
    const p = paletteFor(t.dark);
    return std.fmt.allocPrint(a,
        \\[%General]
        \\author=dkde
        \\comment=Generated from dkde.toml
        \\inherits={[base]s}
        \\
        \\[GeneralColors]
        \\window.color={[window]s}
        \\base.color={[base_c]s}
        \\alt.base.color={[alt]s}
        \\button.color={[button]s}
        \\light.color={[light]s}
        \\mid.light.color={[midlight]s}
        \\dark.color={[dark]s}
        \\mid.color={[mid]s}
        \\highlight.color={[accent]s}
        \\inactive.highlight.color={[accent]s}
        \\text.color={[text]s}
        \\window.text.color={[text]s}
        \\button.text.color={[text]s}
        \\disabled.text.color={[disabled]s}
        \\tooltip.base.color={[tooltip]s}
        \\tooltip.text.color={[ttext]s}
        \\highlight.text.color=#ffffff
        \\link.color={[accent]s}
        \\link.visited.color=#a347ba
        \\
    , .{
        .base = if (t.dark) "KvFlat" else "KvFlatLight",
        .window = p.window,
        .base_c = p.base,
        .alt = p.alt_base,
        .button = p.button,
        .light = p.light,
        .midlight = p.midlight,
        .dark = p.dark,
        .mid = p.mid,
        .accent = t.accent,
        .text = p.text,
        .disabled = p.disabled_text,
        .tooltip = p.tooltip,
        .ttext = if (t.dark) "#f0f0f0" else "#1e1e1e",
    });
}

fn writeUnder(a: std.mem.Allocator, config_home: []const u8, rel: []const u8, data: []const u8) void {
    const path = std.fmt.allocPrint(a, "{s}/{s}", .{ config_home, rel }) catch return;
    defer a.free(path);
    if (std.fs.path.dirname(path)) |dir| fsio.makePath(dir) catch return;
    // Skip the write when nothing changed, so file watchers stay quiet.
    if (fsio.readFile(a, path, 1 << 20) catch null) |old| {
        defer a.free(old);
        if (std.mem.eql(u8, old, data)) return;
    }
    fsio.writeFileAtomic(path, data) catch {};
}

fn kvantumInstalled() bool {
    if (glib.findProgramInPath("kvantummanager") != null) return true;
    return fsio.exists("/usr/share/Kvantum");
}

/// Writes every toolkit file for `t` under `config_home`. Failures are ignored:
/// a missing toolkit file only means that toolkit keeps its own look.
pub fn writeAll(a: std.mem.Allocator, config_home: []const u8, t: Theme) void {
    const kv = kvantumInstalled();
    inline for (.{ "gtk-3.0", "gtk-4.0" }) |dir| {
        if (gtkSettings(a, t)) |s| {
            defer a.free(s);
            writeUnder(a, config_home, dir ++ "/settings.ini", s);
        } else |_| {}
        if (gtkCss(a, t)) |s| {
            defer a.free(s);
            writeUnder(a, config_home, dir ++ "/gtk.css", s);
        } else |_| {}
    }
    inline for (.{ .{ "qt5ct", false }, .{ "qt6ct", true } }) |q| {
        const scheme = std.fmt.allocPrint(a, "{s}/{s}/colors/dkde.toml", .{ config_home, q[0] }) catch return;
        defer a.free(scheme);
        if (qtColorScheme(a, t, q[1])) |s| {
            defer a.free(s);
            writeUnder(a, config_home, q[0] ++ "/colors/dkde.toml", s);
        } else |_| {}
        if (qtConf(a, t, scheme, kv)) |s| {
            defer a.free(s);
            writeUnder(a, config_home, q[0] ++ "/" ++ q[0] ++ ".conf", s);
        } else |_| {}
    }
    if (kv) {
        if (kvantumSelect(a)) |s| {
            defer a.free(s);
            writeUnder(a, config_home, "Kvantum/kvantum.kvconfig", s);
        } else |_| {}
        if (kvantumTheme(a, t)) |s| {
            defer a.free(s);
            writeUnder(a, config_home, "Kvantum/dkde/dkde.kvconfig", s);
        } else |_| {}
    }
}

/// `writeAll` into the user's `$XDG_CONFIG_HOME`.
pub fn sync(a: std.mem.Allocator, t: Theme) void {
    writeAll(a, std.mem.span(glib.getUserConfigDir()), t);
}

test "renders every file for a dark theme" {
    const a = std.testing.allocator;
    const t: Theme = .{ .dark = true, .accent = "#e66100", .font = "Sans 11", .icon_theme = "Fluent" };
    const ini = try gtkSettings(a, t);
    defer a.free(ini);
    try std.testing.expect(std.mem.indexOf(u8, ini, "prefer-dark-theme=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, ini, "gtk-icon-theme-name=Fluent") != null);
    const css = try gtkCss(a, t);
    defer a.free(css);
    try std.testing.expect(std.mem.indexOf(u8, css, "accent_bg_color #e66100") != null);
    const q6 = try qtColorScheme(a, t, true);
    defer a.free(q6);
    // Qt 6 lists 21 roles (with Accent), Qt 5 lists 20; three lists per file.
    const q5 = try qtColorScheme(a, t, false);
    defer a.free(q5);
    try std.testing.expectEqual(@as(usize, 3 * 20), std.mem.count(u8, q5, "#ff"));
    try std.testing.expectEqual(@as(usize, 3 * 21), std.mem.count(u8, q6, "#ff"));
    const kv = try kvantumTheme(a, t);
    defer a.free(kv);
    try std.testing.expect(std.mem.indexOf(u8, kv, "inherits=KvFlat") != null);
}
