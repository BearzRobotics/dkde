//! The pages of Settings and Task Manager, for the Start menu's search: typing "display" offers
//! a link that opens Settings on the Display page (`dkde-settings --page display`). Settings keeps its
//! own table (with categories); a test there checks that every id here is a page it knows.

const std = @import("std");

pub const Entry = struct {
    /// The program to run, with `--page <id>`.
    program: []const u8,
    id: []const u8,
    title: []const u8,
    /// What the page is for (also searched).
    desc: []const u8,
    icon: []const u8,
};

pub const all = [_]Entry{
    .{ .program = "dkde-settings", .id = "appearance", .title = "Appearance", .desc = "Dark mode, accent colour, icons, wallpaper", .icon = "applications-graphics-symbolic" },
    .{ .program = "dkde-settings", .id = "taskbar", .title = "Taskbar", .desc = "The panel: position, size, clock and tray", .icon = "view-list-symbolic" },
    .{ .program = "dkde-settings", .id = "windows", .title = "Windows", .desc = "Floating or tiling windows, gaps, focus", .icon = "view-restore-symbolic" },
    .{ .program = "dkde-settings", .id = "startmenu", .title = "Start menu", .desc = "Pinned apps and how the menu looks", .icon = "start-here-symbolic" },
    .{ .program = "dkde-settings", .id = "display", .title = "Display", .desc = "Resolution, scale, arrangement of screens and night light", .icon = "video-display-symbolic" },
    .{ .program = "dkde-settings", .id = "audio", .title = "Sound", .desc = "Volume and the input and output devices", .icon = "audio-volume-high-symbolic" },
    .{ .program = "dkde-settings", .id = "power", .title = "Power & lock", .desc = "Sleep, screen lock and the power button", .icon = "system-shutdown-symbolic" },
    .{ .program = "dkde-settings", .id = "network", .title = "Network", .desc = "Wi-Fi and wired connections", .icon = "network-wireless-symbolic" },
    .{ .program = "dkde-settings", .id = "bluetooth", .title = "Bluetooth", .desc = "Pair and manage Bluetooth devices", .icon = "bluetooth-symbolic" },
    .{ .program = "dkde-settings", .id = "printers", .title = "Printers", .desc = "Printers and print queues", .icon = "printer-symbolic" },
    .{ .program = "dkde-settings", .id = "mouse", .title = "Mouse & touchpad", .desc = "Pointer speed, scrolling and tapping", .icon = "input-mouse-symbolic" },
    .{ .program = "dkde-settings", .id = "keyboard", .title = "Keyboard", .desc = "Layouts for typing", .icon = "input-keyboard-symbolic" },
    .{ .program = "dkde-settings", .id = "shortcuts", .title = "Keyboard shortcuts", .desc = "Keys that open apps and manage windows", .icon = "preferences-desktop-keyboard-shortcuts-symbolic" },
    .{ .program = "dkde-settings", .id = "defaults", .title = "Default apps", .desc = "Which app opens which kind of file", .icon = "preferences-other-symbolic" },
    .{ .program = "dkde-settings", .id = "terminal", .title = "Terminal", .desc = "The terminal window and its profiles", .icon = "utilities-terminal-symbolic" },
    .{ .program = "dkde-settings", .id = "datetime", .title = "Date & time", .desc = "Time zone, clock and calendar system", .icon = "preferences-system-time-symbolic" },
    .{ .program = "dkde-settings", .id = "region", .title = "Language & region", .desc = "Language, dates, numbers, currency and measurements", .icon = "preferences-desktop-locale-symbolic" },
    .{ .program = "dkde-settings", .id = "about", .title = "About", .desc = "This computer: name, system, processor, memory, storage", .icon = "help-about-symbolic" },
    .{ .program = "dkde-settings", .id = "developer", .title = "For developers", .desc = "Logging, the GTK inspector and diagnostics", .icon = "applications-development-symbolic" },
    .{ .program = "dkde-settings", .id = "online", .title = "Online accounts", .desc = "Optional online calendars", .icon = "preferences-system-network-symbolic" },
    .{ .program = "dkde-settings", .id = "users", .title = "User accounts", .desc = "Your account and the other accounts on this computer", .icon = "avatar-default-symbolic" },
    .{ .program = "dkde-tasks", .id = "processes", .title = "Task Manager: Processes", .desc = "Running programs and processes", .icon = "utilities-system-monitor-symbolic" },
    .{ .program = "dkde-tasks", .id = "performance", .title = "Task Manager: Performance", .desc = "CPU, memory, disk, network and GPU use", .icon = "utilities-system-monitor-symbolic" },
    .{ .program = "dkde-tasks", .id = "startup", .title = "Task Manager: Startup apps", .desc = "Programs that start at login", .icon = "utilities-system-monitor-symbolic" },
    .{ .program = "dkde-tasks", .id = "services", .title = "Task Manager: Services", .desc = "System services (systemd or dinit)", .icon = "utilities-system-monitor-symbolic" },
    .{ .program = "dkde-tasks", .id = "firewall", .title = "Task Manager: Firewall", .desc = "Firewall rules and status", .icon = "security-medium-symbolic" },
    .{ .program = "dkde-tasks", .id = "security", .title = "Task Manager: Security", .desc = "AppArmor or SELinux", .icon = "security-high-symbolic" },
};

/// Does `query` (case-insensitive) occur in the title, description or id?
pub fn matches(e: Entry, query: []const u8) bool {
    return std.ascii.findIgnoreCase(e.title, query) != null or std.ascii.findIgnoreCase(e.desc, query) != null or std.ascii.findIgnoreCase(e.id, query) != null;
}

test "the display page is found by name and by what it does" {
    var found = false;
    for (all) |e| if (std.mem.eql(u8, e.id, "display") and matches(e, "displ") and matches(e, "night")) {
        found = true;
    };
    try std.testing.expect(found);
}
