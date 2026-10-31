//! Terminal profiles and colour schemes (SPEC.md 5.3). A profile is a
//! `[profile:<name>]` group of term.conf (see SPEC.md 5.5).

const std = @import("std");
const common = @import("common");

pub const CursorStyle = enum { block, bar, underline };
pub const Startup = enum { windowed, maximized, fullscreen };
/// What happens to a tab when its program ends.
pub const CloseOnExit = enum { always, never, success };

pub const Scheme = struct {
    background: u24,
    foreground: u24,
    /// The 16 ANSI colours: normal 0-7, bright 8-15.
    ansi: [16]u24,
};

pub const default_scheme = "campbell";

const campbell: Scheme = .{
    .background = 0x0C0C0C,
    .foreground = 0xCCCCCC,
    .ansi = .{
        0x0C0C0C, 0xC50F1F, 0x13A10E, 0xC19C00, 0x0037DA, 0x881798, 0x3A96DD, 0xCCCCCC,
        0x767676, 0xE74856, 0x16C60C, 0xF9F1A5, 0x3B78FF, 0xB4009E, 0x61D6D6, 0xF2F2F2,
    },
};

const one_half_dark: Scheme = .{
    .background = 0x282C34,
    .foreground = 0xDCDFE4,
    .ansi = .{
        0x282C34, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xDCDFE4,
        0x5A6374, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xDCDFE4,
    },
};

const solarized_ansi = [16]u24{
    0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
    0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3,
};

const solarized_dark: Scheme = .{ .background = 0x002B36, .foreground = 0x839496, .ansi = solarized_ansi };
const solarized_light: Scheme = .{ .background = 0xFDF6E3, .foreground = 0x657B83, .ansi = solarized_ansi };

/// Looks a scheme up by name; unknown names give the default.
pub fn scheme(name: []const u8) Scheme {
    if (std.ascii.eqlIgnoreCase(name, "one-half-dark")) return one_half_dark;
    if (std.ascii.eqlIgnoreCase(name, "solarized-dark")) return solarized_dark;
    if (std.ascii.eqlIgnoreCase(name, "solarized-light")) return solarized_light;
    return campbell;
}

pub fn parseCursor(text: []const u8) CursorStyle {
    if (std.ascii.eqlIgnoreCase(text, "bar")) return .bar;
    if (std.ascii.eqlIgnoreCase(text, "underline")) return .underline;
    return .block;
}

pub const Profile = struct {
    /// Owned by the profile.
    name: []u8,
    /// Empty means the user's login shell.
    command: []u8,
    directory: []u8,
    font: []u8,
    scheme_name: []u8,
    cursor: CursorStyle,
    osc52: bool,
    /// 0.2 to 1.0; below 1 the terminal background is see-through.
    opacity: f32,
    /// Fixed tab title; empty follows the program's title.
    title: []u8,
    /// Icon name or image path shown on the tab.
    icon: []u8,
    /// CSS colour of the tab's top edge; empty for none.
    tab_color: []u8,
    /// Extra environment for the program, "NAME=value;NAME2=value2".
    environment: []u8,
    /// Size of a new window in character cells; 0 keeps the default size.
    columns: u16,
    rows: u16,
    startup: Startup,
    close_on_exit: CloseOnExit,
    /// Space around the text, in pixels.
    padding: u8,
    copy_on_select: bool,

    pub fn deinit(self: *Profile, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.command);
        allocator.free(self.directory);
        allocator.free(self.font);
        allocator.free(self.scheme_name);
        allocator.free(self.title);
        allocator.free(self.icon);
        allocator.free(self.tab_color);
        allocator.free(self.environment);
    }
};

pub fn parseStartup(text: []const u8) Startup {
    if (std.ascii.eqlIgnoreCase(text, "maximized")) return .maximized;
    if (std.ascii.eqlIgnoreCase(text, "fullscreen")) return .fullscreen;
    return .windowed;
}

pub fn parseCloseOnExit(text: []const u8) CloseOnExit {
    if (std.ascii.eqlIgnoreCase(text, "never")) return .never;
    if (std.ascii.eqlIgnoreCase(text, "success")) return .success;
    return .always;
}

/// Should a tab close, given how its program ended? `status` is the raw wait status.
pub fn closesTab(mode: CloseOnExit, status: c_int) bool {
    return switch (mode) {
        .always => true,
        .never => false,
        .success => (status & 0x7f) == 0 and ((status >> 8) & 0xff) == 0,
    };
}

/// The exit code for display: the code for a normal exit, 128 plus the signal otherwise.
pub fn exitCode(status: c_int) c_int {
    if ((status & 0x7f) == 0) return (status >> 8) & 0xff;
    return 128 + (status & 0x7f);
}

/// Reads profile `name` from `cfg`. Missing keys take their defaults, so a
/// profile that does not exist is simply the default profile.
pub fn load(allocator: std.mem.Allocator, cfg: *const common.Config, name: []const u8) !Profile {
    const group = try std.fmt.allocPrintSentinel(allocator, "profile:{s}", .{name}, 0);
    defer allocator.free(group);

    const display_name = try allocator.dupe(u8, name);
    errdefer allocator.free(display_name);
    const command = try cfg.getString(allocator, group, "command", "");
    errdefer allocator.free(command);
    const directory = try cfg.getString(allocator, group, "directory", "");
    errdefer allocator.free(directory);
    const font = try cfg.getString(allocator, group, "font", "Monospace 11");
    errdefer allocator.free(font);
    const scheme_name = try cfg.getString(allocator, group, "color-scheme", default_scheme);
    errdefer allocator.free(scheme_name);
    const cursor_text = try cfg.getString(allocator, group, "cursor-style", "block");
    defer allocator.free(cursor_text);
    const title = try cfg.getString(allocator, group, "title", "");
    errdefer allocator.free(title);
    const icon = try cfg.getString(allocator, group, "icon", "");
    errdefer allocator.free(icon);
    const tab_color = try cfg.getString(allocator, group, "tab-color", "");
    errdefer allocator.free(tab_color);
    const environment = try cfg.getString(allocator, group, "environment", "");
    errdefer allocator.free(environment);
    const startup_text = try cfg.getString(allocator, group, "startup", "windowed");
    defer allocator.free(startup_text);
    const close_text = try cfg.getString(allocator, group, "close-on-exit", "always");
    defer allocator.free(close_text);

    return .{
        .name = display_name,
        .command = command,
        .directory = directory,
        .font = font,
        .scheme_name = scheme_name,
        .cursor = parseCursor(cursor_text),
        .osc52 = cfg.getBool(group, "osc52", true),
        .opacity = opacityFromPercent(cfg.getInt(group, "opacity", 100)),
        .title = title,
        .icon = icon,
        .tab_color = tab_color,
        .environment = environment,
        .columns = @intCast(std.math.clamp(cfg.getInt(group, "columns", 0), 0, 500)),
        .rows = @intCast(std.math.clamp(cfg.getInt(group, "rows", 0), 0, 300)),
        .startup = parseStartup(startup_text),
        .close_on_exit = parseCloseOnExit(close_text),
        .padding = @intCast(std.math.clamp(cfg.getInt(group, "padding", 4), 0, 40)),
        .copy_on_select = cfg.getBool(group, "copy-on-select", true),
    };
}

/// `opacity` is stored as a percentage; clamp it to something readable.
pub fn opacityFromPercent(percent: i32) f32 {
    const clamped = std.math.clamp(percent, 20, 100);
    return @as(f32, @floatFromInt(clamped)) / 100.0;
}

test "opacity is clamped" {
    try std.testing.expectEqual(@as(f32, 1.0), opacityFromPercent(250));
    try std.testing.expectEqual(@as(f32, 0.2), opacityFromPercent(-5));
    try std.testing.expectEqual(@as(f32, 0.8), opacityFromPercent(80));
}

test "scheme lookup is case-insensitive and falls back" {
    try std.testing.expectEqual(@as(u24, 0x002B36), scheme("Solarized-Dark").background);
    try std.testing.expectEqual(@as(u24, 0x0C0C0C), scheme("no-such-scheme").background);
}

test "cursor style parsing" {
    try std.testing.expectEqual(CursorStyle.bar, parseCursor("Bar"));
    try std.testing.expectEqual(CursorStyle.block, parseCursor("whatever"));
}

test "exit handling" {
    try std.testing.expect(closesTab(.always, 256));
    try std.testing.expect(!closesTab(.never, 0));
    try std.testing.expect(closesTab(.success, 0));
    try std.testing.expect(!closesTab(.success, 1 << 8));
    try std.testing.expect(!closesTab(.success, 9)); // killed by a signal
    try std.testing.expectEqual(@as(c_int, 2), exitCode(2 << 8));
    try std.testing.expectEqual(@as(c_int, 137), exitCode(9));
}

test "startup and close names" {
    try std.testing.expectEqual(Startup.maximized, parseStartup("Maximized"));
    try std.testing.expectEqual(Startup.windowed, parseStartup("whatever"));
    try std.testing.expectEqual(CloseOnExit.never, parseCloseOnExit("never"));
}
