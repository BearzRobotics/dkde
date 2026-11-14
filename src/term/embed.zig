//! A terminal that other DKDE programs can host in their own window, the way
//! Kate and Dolphin host Konsole: the file manager and the editor show one in
//! a panel below their content (ai/DKDE-SPEC.md 6.3: the host imports this
//! module, never another program's `main.zig`).
//!
//! The panel costs nothing until it is first shown: the shell, the terminal
//! state and term.toml are only created then. It uses the host's default
//! terminal profile. Typing into the shell is left to the user, except for
//! `changeDirectory`, which the host calls on the user's request.

const std = @import("std");
const glib = @import("glib2");
const gtk = @import("gtk4");
const common = @import("common");

const profile_mod = @import("profile.zig");
const TerminalView = @import("view.zig").TerminalView;

const log = std.log.scoped(.term);

pub const Panel = struct {
    allocator: std.mem.Allocator,
    /// The panel's widget: put it in the host's layout. Hidden until `show`.
    box: *gtk.Box,
    config: ?common.Config = null,
    view: ?*TerminalView = null,
    /// Called when the shell ends and the panel closes itself.
    on_closed: ?*const fn (data: ?*anyopaque) void = null,
    on_closed_data: ?*anyopaque = null,

    pub fn create(allocator: std.mem.Allocator) !*Panel {
        const self = try allocator.create(Panel);
        self.* = .{ .allocator = allocator, .box = gtk.Box.new(.vertical, 0) };
        const widget_ = self.box.as(gtk.Widget);
        widget_.setVisible(0);
        widget_.setSizeRequest(-1, 120);
        widget_.addCssClass("dkde-terminal-panel");
        return self;
    }

    /// Frees the panel. Call it from the host's destroy handler. The view is
    /// not touched: GTK has already destroyed it with the window, and it frees
    /// itself and stops its timers when its widget goes.
    pub fn destroy(self: *Panel) void {
        if (self.config) |*c| c.deinit();
        self.allocator.destroy(self);
    }

    pub fn widget(self: *Panel) *gtk.Widget {
        return self.box.as(gtk.Widget);
    }

    pub fn isVisible(self: *const Panel) bool {
        return self.box.as(gtk.Widget).getVisible() != 0;
    }

    /// Shows the panel and gives the terminal the focus. The first time, the
    /// shell starts in `directory` (the home folder when null).
    pub fn show(self: *Panel, directory: ?[]const u8) void {
        if (self.view == null) self.start(directory) catch |err| {
            log.err("cannot start the embedded terminal: {s}", .{@errorName(err)});
            return;
        };
        self.box.as(gtk.Widget).setVisible(1);
        if (self.view) |v| v.grabFocus();
    }

    pub fn hide(self: *Panel) void {
        self.box.as(gtk.Widget).setVisible(0);
    }

    pub fn toggle(self: *Panel, directory: ?[]const u8) void {
        if (self.isVisible()) self.hide() else self.show(directory);
    }

    /// Pastes the clipboard into the shell (the host's Paste command, when the terminal has the focus).
    pub fn paste(self: *Panel) void {
        if (self.view) |v| v.pasteClipboard(false);
    }

    /// Types `cd -- '<directory>'` and Enter into the shell. Only call it when
    /// the user asked for it: a program that is running in the terminal would
    /// receive the text instead of the shell.
    pub fn changeDirectory(self: *Panel, directory: []const u8) void {
        const v = self.view orelse return;
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.allocator);
        // Ctrl+U first, so text the user had half typed does not join the command.
        appendCd(self.allocator, &line, directory) catch return;
        v.typeText(line.items);
    }

    fn start(self: *Panel, directory: ?[]const u8) !void {
        if (self.config == null) self.config = try common.Config.load(self.allocator, "term.toml");
        const cfg = &self.config.?;
        const name = try cfg.getString(self.allocator, "terminal", "default-profile", "Default");
        defer self.allocator.free(name);
        const prof = try profile_mod.load(self.allocator, cfg, name);
        const scrollback: usize = @intCast(@max(0, cfg.getInt("terminal", "scrollback-lines", 10_000)));
        const view = try TerminalView.create(self.allocator, prof, null, directory, scrollback, .{
            .data = self,
            .title_changed = onTitle,
            .exited = onExited,
            .focused = onFocused,
        });
        view.widget().setHexpand(1);
        view.widget().setVexpand(1);
        self.box.append(view.widget());
        self.view = view;
    }

    fn onTitle(_: *anyopaque, _: *TerminalView) void {}
    fn onFocused(_: *anyopaque, _: *TerminalView) void {}

    fn onExited(data: *anyopaque, _: *TerminalView) void {
        // The view cannot be freed from inside its own child-watch callback.
        _ = glib.idleAdd(closeIdle, data);
    }

    fn closeIdle(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Panel = @ptrCast(@alignCast(data.?));
        const view = self.view orelse return 0;
        self.view = null;
        view.shutdown();
        self.box.remove(view.widget());
        self.hide();
        if (self.on_closed) |f| f(self.on_closed_data);
        return 0;
    }
};

/// Appends the keystrokes for "change to `directory`": Ctrl+U to clear the
/// line, then `cd -- '<directory>'` with single quotes escaped, then Enter.
fn appendCd(allocator: std.mem.Allocator, out: *std.ArrayList(u8), directory: []const u8) !void {
    try out.append(allocator, 0x15);
    try out.appendSlice(allocator, "cd -- '");
    for (directory) |c| {
        // A newline or other control byte would end or alter the command.
        if (c < 0x20 or c == 0x7f) return error.InvalidDirectory;
        if (c == '\'') try out.appendSlice(allocator, "'\\''") else try out.append(allocator, c);
    }
    try out.appendSlice(allocator, "'\r");
}

test "cd line quotes single quotes" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try appendCd(std.testing.allocator, &out, "/tmp/it's here");
    try std.testing.expectEqualStrings("\x15cd -- '/tmp/it'\\''s here'\r", out.items);
}

test "cd line refuses control bytes" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidDirectory, appendCd(std.testing.allocator, &out, "/tmp/a\nrm -rf ~"));
}
