//! One terminal: a pty, libghostty-vt's parser and screen state, and a GTK
//! drawing area that renders it with Pango (SPEC.md 5.3).
//!
//! Output is drawn into an off-screen surface, one row at a time, and only
//! for rows libghostty-vt reports as changed. The widget just blits that
//! surface and overlays the cursor, so a keystroke repaints one row, not the
//! window.

const std = @import("std");
const cairo = @import("cairo1");
const gdk = @import("gdk4");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const pango = @import("pango1");
const pangocairo = @import("pangocairo1");
const vt = @import("ghostty-vt");
const common = @import("common");

const keymap = @import("termcore").keymap;
const glue = @import("termcore").glue;
const profile_mod = @import("profile.zig");
const urls = @import("urls.zig");
const finder_mod = @import("finder.zig");
const safety = @import("safety.zig");
const Pty = @import("pty.zig").Pty;

const log = std.log.scoped(.term);

extern fn tcgetpgrp(fd: c_int) c_int;

/// Splits a command line like a shell; null when it is empty or malformed.
fn splitCommand(allocator: std.mem.Allocator, text: []const u8) ?[][]u8 {
    const z = allocator.dupeSentinel(u8, text, 0) catch return null;
    defer allocator.free(z);
    var count: c_int = 0;
    var vector: [*:null]?[*:0]u8 = undefined;
    if (glib.shellParseArgv(z, &count, &vector, null) == 0) return null;
    defer glib.strfreev(@ptrCast(vector));
    if (count <= 0) return null;
    const list = allocator.alloc([]u8, @intCast(count)) catch return null;
    var made: usize = 0;
    for (0..@intCast(count)) |i| {
        list[i] = allocator.dupe(u8, std.mem.span(vector[i].?)) catch {
            freeArgv(allocator, list[0..made]);
            return null;
        };
        made += 1;
    }
    return list;
}

fn freeArgv(allocator: std.mem.Allocator, list: [][]u8) void {
    for (list) |item| allocator.free(item);
    allocator.free(list);
}

pub const Callbacks = struct {
    data: *anyopaque,
    /// The tab title changed (OSC 0/2) or the child's name is now known.
    title_changed: *const fn (data: *anyopaque, view: *TerminalView) void,
    /// The child exited.
    exited: *const fn (data: *anyopaque, view: *TerminalView) void,
    /// The view took keyboard focus (which pane of a tab is active).
    focused: *const fn (data: *anyopaque, view: *TerminalView) void,
    /// The bell rang (the window marks a tab that is not showing).
    bell: ?*const fn (data: *anyopaque, view: *TerminalView) void = null,
    /// A right-click menu item the window carries out ("split-right", ...).
    /// Without it (a terminal embedded in another program) those items are
    /// not offered.
    menu: ?*const fn (data: *anyopaque, view: *TerminalView, action: []const u8) void = null,
};

/// What a click on the right-click menu does.
const MenuItem = enum { copy, copy_html, paste, open_link, copy_link, select_all, find, clear, reset, read_only, save_output, split_right, split_down, close_pane };

pub const TerminalView = struct {
    allocator: std.mem.Allocator,
    callbacks: Callbacks,
    profile: profile_mod.Profile,
    colors: profile_mod.Scheme,

    /// Drawing area plus scroll bar; this is what goes into the window.
    box: *gtk.Box,
    area: *gtk.DrawingArea,
    scrollbar: *gtk.Scrollbar,
    adjustment: *gtk.Adjustment,
    syncing_scrollbar: bool = false,
    pty: *Pty,
    child_watch: c_uint = 0,
    /// The raw wait status of the child once it has ended.
    exit_status: c_int = 0,

    tiny_io: vt.TinyIo = .init,
    term: vt.Terminal,
    stream: vt.TerminalStream,
    render: vt.RenderState = .empty,
    /// Synchronized output (mode 2026): hold off drawing while true.
    hold: bool = false,

    cols: u16 = 80,
    rows: u16 = 24,
    cell_w: f64 = 8,
    cell_h: f64 = 16,
    ascent: f64 = 12,
    fonts: [4]*pango.FontDescription,
    layout: *pango.Layout,

    surface: ?*cairo.Surface = null,
    surface_w: c_int = 0,
    surface_h: c_int = 0,
    needs_full_repaint: bool = true,
    refresh_source: c_uint = 0,
    read_source: c_uint = 0,
    cursor_visible: bool = true,
    blink_source: c_uint = 0,
    focused: bool = false,
    /// Shut down: nothing may be scheduled any more.
    dead: bool = false,

    // Search within the scrollback: every match, highlighted.
    finder: finder_mod.Finder = .{},
    search_needle: ?[]u8 = null,
    search_opts: finder_mod.Options = .{},
    /// Output arrived while a search is open: find again shortly.
    search_stale: bool = false,
    search_source: c_uint = 0,
    /// The screen row at the top of the view, for the highlights.
    view_top: u32 = 0,

    /// Font size factor (Ctrl+Plus / Ctrl+Minus).
    zoom: f64 = 1.0,
    /// The address under the mouse: underlined, opened with Ctrl+click.
    hover: ?struct { row: u16, x0: u16, x1: u16 } = null,
    hover_link: ?[:0]u8 = null,
    /// Keys, pastes and drops are refused (View > Read-Only).
    read_only: bool = false,
    /// The visual bell: the view flashes briefly.
    bell_flash: bool = false,
    bell_source: c_uint = 0,
    /// Konsole's monitors: tell when a pane gets busy or goes quiet.
    monitor_activity: bool = false,
    monitor_silence: bool = false,
    silence_source: c_uint = 0,
    silence_told: bool = false,
    last_activity_note: i64 = 0,
    /// Text waiting for the paste warning to be answered.
    pending_paste: ?[]u8 = null,
    /// Warn before pasting text that runs commands on its own.
    paste_warning: bool = true,
    /// The menu's item ids and labels, for the right-click menu.
    menu_link: ?[:0]u8 = null,

    // Selection and links.
    selecting: bool = false,
    anchor: ?vt.Pin = null,
    scroll_accum: f64 = 0,

    pub fn create(
        allocator: std.mem.Allocator,
        profile: profile_mod.Profile,
        command: ?[]const []const u8,
        directory: ?[]const u8,
        scrollback_lines: usize,
        callbacks: Callbacks,
    ) !*TerminalView {
        const self = try allocator.create(TerminalView);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .callbacks = callbacks,
            .profile = profile,
            .colors = profile_mod.scheme(profile.scheme_name),
            .paste_warning = profile.paste_warning,
            .box = gtk.Box.new(.horizontal, 0),
            .area = gtk.DrawingArea.new(),
            .adjustment = gtk.Adjustment.new(0, 0, 1, 1, 10, 1),
            .scrollbar = undefined,
            .pty = undefined,
            .term = undefined,
            .stream = undefined,
            .fonts = undefined,
            .layout = undefined,
        };

        self.term = try vt.Terminal.init(self.tiny_io.io(), allocator, .{
            .cols = self.cols,
            .rows = self.rows,
            .max_scrollback_lines = scrollback_lines,
            // The scheme's 16 colours too, not only its background and text.
            .colors = try glue.terminalColors(allocator, self.colors),
            .default_cursor_style = switch (profile.cursor) {
                .block => .block,
                .bar => .bar,
                .underline => .underline,
            },
        });
        errdefer self.term.deinit(allocator);
        self.stream = self.term.vtStream();
        self.stream.handler.effects = effects;

        self.setupFonts();
        self.measureCells();

        const area_widget = self.area.as(gtk.Widget);
        area_widget.setFocusable(1);
        area_widget.setCanFocus(1);
        area_widget.setHexpand(1);
        area_widget.setVexpand(1);
        area_widget.addCssClass("dkde-terminal");
        self.scrollbar = gtk.Scrollbar.new(.vertical, self.adjustment);
        _ = gtk.Adjustment.signals.value_changed.connect(self.adjustment, *TerminalView, &onScrollbarMoved, self, .{});
        self.box.append(area_widget);
        self.box.append(self.scrollbar.as(gtk.Widget));
        self.area.setDrawFunc(onDraw, self, null);
        _ = gtk.DrawingArea.signals.resize.connect(self.area, *TerminalView, &onResize, self, .{});
        self.installControllers();
        _ = gtk.Widget.signals.destroy.connect(self.area, *TerminalView, &onWidgetDestroy, self, .{});

        // Start the child.
        var default_command: [1][]const u8 = undefined;
        // A profile's command may carry arguments ("ssh host", "wsl -d Ubuntu"),
        // split the way a shell would.
        var parsed: ?[][]u8 = null;
        defer if (parsed) |list| freeArgv(allocator, list);
        const argv: []const []const u8 = if (command) |c| c else blk: {
            if (profile.command.len > 0) {
                parsed = splitCommand(allocator, profile.command);
                if (parsed) |list| break :blk @as([]const []const u8, @ptrCast(list));
                default_command[0] = profile.command;
                break :blk &default_command;
            }
            const shell = glib.getenv("SHELL");
            default_command[0] = if (shell) |s| std.mem.span(s) else "/bin/sh";
            break :blk &default_command;
        };
        // The user's own shell, taught to mark its prompts and report long
        // commands (bash: an rc file that reads ~/.bashrc first; zsh: a
        // ZDOTDIR whose .zshrc reads the user's).
        var integrated: [3][]const u8 = undefined;
        var integration_env: ?[]u8 = null;
        defer if (integration_env) |e| allocator.free(e);
        var integration_file: ?[:0]u8 = null;
        defer if (integration_file) |f| allocator.free(f);
        const final_argv: []const []const u8 = blk: {
            if (command != null or profile.command.len > 0 or !profile.shell_integration) break :blk argv;
            const base = std.fs.path.basename(argv[0]);
            if (std.mem.eql(u8, base, "bash")) {
                integration_file = common.paths.systemDataFile(allocator, "term-shell/bash.sh") catch null;
                const f = integration_file orelse break :blk argv;
                integrated = .{ argv[0], "--rcfile", f };
                break :blk &integrated;
            }
            if (std.mem.eql(u8, base, "zsh")) {
                integration_file = common.paths.systemDataFile(allocator, "term-shell/zsh/.zshrc") catch null;
                const f = integration_file orelse break :blk argv;
                const old = if (glib.getenv("ZDOTDIR")) |z| std.mem.span(z) else "";
                integration_env = std.fmt.allocPrint(allocator, "ZDOTDIR={s}\x00DKDE_USER_ZDOTDIR={s}", .{ std.fs.path.dirname(f) orelse "", old }) catch break :blk argv;
            }
            break :blk argv;
        };
        const cwd: ?[]const u8 = if (directory) |d| d else if (profile.directory.len > 0) profile.directory else null;
        var env_list: std.ArrayList([]const u8) = .empty;
        defer env_list.deinit(allocator);
        if (integration_env) |e| {
            var parts = std.mem.splitScalar(u8, e, 0);
            while (parts.next()) |part| env_list.append(allocator, part) catch {};
        }
        var env_parts = std.mem.splitScalar(u8, profile.environment, ';');
        while (env_parts.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " ");
            if (trimmed.len > 0) env_list.append(allocator, trimmed) catch {};
        }
        self.pty = try Pty.spawn(allocator, .{ .argv = final_argv, .cwd = cwd, .env = env_list.items, .size = self.ptySize() });
        errdefer self.pty.deinit();

        const channel = glib.IOChannel.unixNew(self.pty.master);
        defer channel.unref();
        _ = channel.setEncoding(null, null);
        self.read_source = glib.ioAddWatch(channel, .{ .in = true, .hup = true, .err = true }, onPtyReadable, self);
        self.child_watch = glib.childWatchAdd(self.pty.pid, onChildExit, self);
        return self;
    }

    /// Stops everything that could call back into the view. The memory stays
    /// until GTK destroys the widget, because controllers can still fire
    /// (a focus-leave while the widget is torn down, for instance).
    pub fn shutdown(self: *TerminalView) void {
        self.dead = true;
        if (self.search_source != 0) _ = glib.Source.remove(self.search_source);
        if (self.bell_source != 0) _ = glib.Source.remove(self.bell_source);
        if (self.silence_source != 0) _ = glib.Source.remove(self.silence_source);
        self.search_source = 0;
        self.bell_source = 0;
        self.silence_source = 0;
        if (self.read_source != 0) _ = glib.Source.remove(self.read_source);
        if (self.child_watch != 0) _ = glib.Source.remove(self.child_watch);
        if (self.refresh_source != 0) _ = glib.Source.remove(self.refresh_source);
        if (self.blink_source != 0) _ = glib.Source.remove(self.blink_source);
        self.read_source = 0;
        self.child_watch = 0;
        self.refresh_source = 0;
        self.blink_source = 0;
    }

    fn onWidgetDestroy(_: *gtk.DrawingArea, self: *TerminalView) callconv(.c) void {
        self.shutdown();
        self.searchClose();
        self.finder.deinit(self.allocator);
        if (self.search_needle) |n| self.allocator.free(n);
        if (self.hover_link) |l| self.allocator.free(l);
        if (self.menu_link) |l| self.allocator.free(l);
        if (self.pending_paste) |p| {
            @memset(p, 0);
            self.allocator.free(p);
        }
        self.pty.deinit();
        self.stream.deinit();
        self.render.deinit(self.allocator);
        self.term.deinit(self.allocator);
        if (self.surface) |s| s.destroy();
        for (self.fonts) |f| f.free();
        self.layout.as(gobject.Object).unref();
        self.profile.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// The program running in the foreground, other than the shell itself:
    /// closing the pane would end it. Its name is put in `buf`.
    pub fn runningProgram(self: *TerminalView, buf: []u8) ?[]const u8 {
        if (self.child_watch == 0) return null; // already ended
        const fg = tcgetpgrp(self.pty.master);
        const shell_pid: c_int = self.pty.pid;
        var name_buf: [64]u8 = undefined;
        if (fg > 0 and fg != shell_pid) return processName(fg, buf);
        // The pane's own program, when it is not a shell (a profile can run
        // htop or ssh directly).
        const own = processName(shell_pid, &name_buf) orelse return null;
        const shells = [_][]const u8{ "bash", "zsh", "fish", "sh", "dash", "ksh", "mksh", "tcsh", "csh", "nu", "elvish", "xonsh" };
        for (shells) |sh| if (std.mem.eql(u8, own, sh)) return null;
        const n = @min(own.len, buf.len);
        @memcpy(buf[0..n], own[0..n]);
        return buf[0..n];
    }

    fn processName(pid: c_int, buf: []u8) ?[]const u8 {
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/comm", .{pid}) catch return null;
        // /proc files say they are empty: read what is there.
        var zbuf: [64]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&zbuf, "{s}", .{path}, 0) catch return null;
        const f = std.c.fopen(z.ptr, "r") orelse return null;
        defer _ = std.c.fclose(f);
        var text: [64]u8 = undefined;
        const got = std.c.fread(&text, 1, text.len, f);
        const name = std.mem.trimEnd(u8, text[0..got], "\n");
        const n = @min(name.len, buf.len);
        @memcpy(buf[0..n], name[0..n]);
        return buf[0..n];
    }

    pub fn widget(self: *TerminalView) *gtk.Widget {
        return self.box.as(gtk.Widget);
    }

    pub fn title(self: *const TerminalView) ?[]const u8 {
        return self.term.getTitle();
    }

    /// Current directory of the shell, from OSC 7, as a path.
    pub fn workingDirectory(self: *const TerminalView, allocator: std.mem.Allocator) ?[]u8 {
        const uri = self.term.getPwd() orelse return null;
        const path = glib.filenameFromUri(uri, null, null) orelse return null;
        defer glib.free(path);
        return allocator.dupe(u8, std.mem.span(path)) catch null;
    }

    // ---- terminal effects -------------------------------------------------

    const effects: vt.TerminalStream.Handler.Effects = blk: {
        var e = vt.TerminalStream.Handler.Effects.readonly;
        e.write_pty = onWritePty;
        e.bell = onBell;
        e.title_changed = onTitleChanged;
        e.clipboard_write = onClipboardWrite;
        e.render_hold = onRenderHold;
        e.device_attributes = onDeviceAttributes;
        e.size = onSizeReport;
        e.xtversion = onXtversion;
        e.desktop_notification = onDesktopNotification;
        break :blk e;
    };

    fn fromHandler(handler: *vt.TerminalStream.Handler) *TerminalView {
        const stream: *vt.TerminalStream = @fieldParentPtr("handler", handler);
        return @fieldParentPtr("stream", stream);
    }

    fn onWritePty(handler: *vt.TerminalStream.Handler, data: []const u8) void {
        fromHandler(handler).pty.send(data);
    }

    fn onBell(handler: *vt.TerminalStream.Handler) void {
        const self = fromHandler(handler);
        if (gdk.Display.getDefault()) |display| display.beep();
        // A visible bell too, and the tab is marked when it is not showing.
        self.bell_flash = true;
        if (self.bell_source != 0) _ = glib.Source.remove(self.bell_source);
        self.bell_source = glib.timeoutAdd(150, onBellOver, self);
        self.area.as(gtk.Widget).queueDraw();
        if (self.callbacks.bell) |f| f(self.callbacks.data, self);
    }

    fn onBellOver(data: ?*anyopaque) callconv(.c) c_int {
        const self: *TerminalView = @ptrCast(@alignCast(data.?));
        self.bell_source = 0;
        self.bell_flash = false;
        self.area.as(gtk.Widget).queueDraw();
        return 0;
    }

    /// True when the user is looking at this pane: its window is the active
    /// one and the pane has the keyboard.
    fn seen(self: *TerminalView) bool {
        const root = self.area.as(gtk.Widget).getRoot() orelse return false;
        const window: *gtk.Window = @ptrCast(@alignCast(root));
        return self.focused and window.isActive() != 0;
    }

    /// A program asked for a desktop notification (OSC 9 or OSC 777), for
    /// example the shell integration when a long command ends.
    fn onDesktopNotification(handler: *vt.TerminalStream.Handler, n: vt.TerminalStream.Action.ShowDesktopNotification) void {
        const self = fromHandler(handler);
        if (self.seen()) return;
        var tbuf: [200]u8 = undefined;
        var bbuf: [600]u8 = undefined;
        const t = std.fmt.bufPrintSentinel(&tbuf, "{s}", .{if (n.title.len > 0) n.title[0..@min(n.title.len, 190)] else self.title() orelse "Terminal"}, 0) catch return;
        const b = std.fmt.bufPrintSentinel(&bbuf, "{s}", .{n.body[0..@min(n.body.len, 590)]}, 0) catch return;
        if (!std.unicode.utf8ValidateSlice(t) or !std.unicode.utf8ValidateSlice(b)) return;
        common.notify.send(t, b, "utilities-terminal");
    }

    /// Output arrived: Konsole-style activity and silence monitoring.
    fn noteActivity(self: *TerminalView) void {
        if (self.monitor_activity and !self.seen()) {
            const now = @divTrunc(glib.getMonotonicTime(), std.time.us_per_s);
            if (now - self.last_activity_note >= 10) {
                self.last_activity_note = now;
                self.notifyAbout("Activity in \u{201c}{s}\u{201d}");
            }
        }
        if (self.monitor_silence) {
            if (self.silence_source != 0) _ = glib.Source.remove(self.silence_source);
            self.silence_told = false;
            self.silence_source = glib.timeoutAddSeconds(10, onSilence, self);
        }
    }

    fn onSilence(data: ?*anyopaque) callconv(.c) c_int {
        const self: *TerminalView = @ptrCast(@alignCast(data.?));
        self.silence_source = 0;
        if (!self.silence_told and self.monitor_silence) {
            self.silence_told = true;
            self.notifyAbout("Silence in \u{201c}{s}\u{201d}");
        }
        return 0;
    }

    fn notifyAbout(self: *TerminalView, comptime fmt: []const u8) void {
        var buf: [256]u8 = undefined;
        const name: []const u8 = self.title() orelse "Terminal";
        const t = std.fmt.bufPrintSentinel(&buf, fmt, .{name[0..@min(name.len, 200)]}, 0) catch return;
        common.notify.send(t, "", "utilities-terminal");
    }

    pub fn setMonitors(self: *TerminalView, activity: bool, silence: bool) void {
        self.monitor_activity = activity;
        self.monitor_silence = silence;
        if (!silence and self.silence_source != 0) {
            _ = glib.Source.remove(self.silence_source);
            self.silence_source = 0;
        }
        if (silence) self.noteActivity();
    }

    fn onTitleChanged(handler: *vt.TerminalStream.Handler) void {
        const self = fromHandler(handler);
        self.callbacks.title_changed(self.callbacks.data, self);
    }

    fn onClipboardWrite(handler: *vt.TerminalStream.Handler, write: vt.clipboard.Write) void {
        const self = fromHandler(handler);
        // OSC 52 is allowed per profile (SPEC.md 5.3).
        if (!self.profile.osc52) return;
        const content = for (write.contents) |c| {
            if (std.mem.eql(u8, c.mime, "text/plain")) break c;
        } else return;
        const text = self.allocator.dupeSentinel(u8, content.data, 0) catch return;
        defer self.allocator.free(text);
        const clipboard = if (write.location == .primary)
            self.area.as(gtk.Widget).getPrimaryClipboard()
        else
            self.area.as(gtk.Widget).getClipboard();
        clipboard.setText(text);
    }

    fn onRenderHold(handler: *vt.TerminalStream.Handler, hold: bool) void {
        const self = fromHandler(handler);
        self.hold = hold;
        if (!hold) self.scheduleRefresh();
    }

    fn onDeviceAttributes(_: *vt.TerminalStream.Handler) vt.device_attributes.Attributes {
        return .{};
    }

    fn onSizeReport(handler: *vt.TerminalStream.Handler) ?vt.size_report.Size {
        const self = fromHandler(handler);
        return .{
            .rows = self.rows,
            .columns = self.cols,
            .cell_width = @intFromFloat(self.cell_w),
            .cell_height = @intFromFloat(self.cell_h),
        };
    }

    fn onXtversion(_: *vt.TerminalStream.Handler) []const u8 {
        return "dkde-term 0.1";
    }

    fn rgb(value: u24) vt.color.RGB {
        return .{ .r = @truncate(value >> 16), .g = @truncate(value >> 8), .b = @truncate(value) };
    }

    // ---- fonts and metrics --------------------------------------------------

    fn setupFonts(self: *TerminalView) void {
        const base = self.allocator.dupeSentinel(u8, self.profile.font, 0) catch "Monospace 11";
        defer if (base.ptr != "Monospace 11".ptr) self.allocator.free(base);
        for (&self.fonts, 0..) |*slot, i| {
            const desc = pango.FontDescription.fromString(base);
            const size = desc.getSize();
            const pts: f64 = if (size > 0) @as(f64, @floatFromInt(size)) / pango.SCALE else 11;
            desc.setSize(@intFromFloat(@max(4, pts * self.zoom) * pango.SCALE));
            if (i & 1 != 0) desc.setWeight(.bold);
            if (i & 2 != 0) desc.setStyle(.italic);
            slot.* = desc;
        }
        self.layout = self.area.as(gtk.Widget).createPangoLayout(null);
    }

    fn measureCells(self: *TerminalView) void {
        const context = self.layout.getContext();
        const metrics = context.getMetrics(self.fonts[0], null);
        defer metrics.unref();
        const scale: f64 = pango.SCALE;
        self.cell_w = @max(1, @as(f64, @floatFromInt(metrics.getApproximateCharWidth())) / scale);
        const ascent: f64 = @as(f64, @floatFromInt(metrics.getAscent())) / scale;
        const descent: f64 = @as(f64, @floatFromInt(metrics.getDescent())) / scale;
        self.cell_h = @ceil(ascent + descent);
        self.ascent = ascent;
    }

    pub fn cellWidth(self: *const TerminalView) f64 {
        return self.cell_w;
    }

    pub fn cellHeight(self: *const TerminalView) f64 {
        return self.cell_h;
    }

    fn pad(self: *const TerminalView) f64 {
        return @floatFromInt(self.profile.padding);
    }

    fn ptySize(self: *const TerminalView) Pty.Size {
        return .{ .cols = self.cols, .rows = self.rows, .cell_w = @intFromFloat(self.cell_w), .cell_h = @intFromFloat(self.cell_h) };
    }

    fn onResize(_: *gtk.DrawingArea, width: c_int, height: c_int, self: *TerminalView) callconv(.c) void {
        self.resizeTo(width, height, false);
    }

    /// Changes the font size by `factor` of the profile's (1 is normal).
    pub fn setZoom(self: *TerminalView, factor: f64) void {
        self.zoom = std.math.clamp(factor, 0.3, 4.0);
        for (self.fonts) |f| f.free();
        self.layout.as(gobject.Object).unref();
        self.setupFonts();
        self.measureCells();
        const w = self.area.as(gtk.Widget);
        self.resizeTo(w.getWidth(), w.getHeight(), true);
    }

    fn resizeTo(self: *TerminalView, width: c_int, height: c_int, force: bool) void {
        if (width <= 0 or height <= 0) return;
        const cols: u16 = @intFromFloat(@max(2, @floor((@as(f64, @floatFromInt(width)) - 2 * self.pad()) / self.cell_w)));
        const rows: u16 = @intFromFloat(@max(1, @floor((@as(f64, @floatFromInt(height)) - 2 * self.pad()) / self.cell_h)));
        if (!force and cols == self.cols and rows == self.rows and self.surface != null) return;
        self.cols = cols;
        self.rows = rows;

        self.stream.handler.resize(.{
            .cols = cols,
            .rows = rows,
            .cell_size_px = .{ .width = @intFromFloat(self.cell_w), .height = @intFromFloat(self.cell_h) },
        }) catch |err| log.warn("resize failed: {s}", .{@errorName(err)});
        self.pty.resize(self.ptySize());

        if (self.surface) |s| s.destroy();
        self.surface_w = width;
        self.surface_h = height;
        self.surface = cairo.Surface.imageCreate(.argb32, width, height);
        self.needs_full_repaint = true;
        self.scheduleRefresh();
    }

    // ---- reading output -----------------------------------------------------

    fn onPtyReadable(_: *glib.IOChannel, _: glib.IOCondition, data: ?*anyopaque) callconv(.c) c_int {
        const self: *TerminalView = @ptrCast(@alignCast(data.?));
        var buf: [16384]u8 = undefined;
        // Bounded, so a flood of output cannot starve the UI.
        var rounds: usize = 0;
        while (rounds < 16) : (rounds += 1) {
            switch (self.pty.readSome(&buf)) {
                .data => |n| {
                    self.stream.nextSlice(buf[0..n]);
                    if (rounds == 0) self.noteActivity();
                    if (self.search_needle != null) self.markSearchStale();
                },
                .would_block => break,
                .closed => {
                    self.read_source = 0;
                    return 0;
                },
            }
        }
        self.scheduleRefresh();
        return 1;
    }

    fn onChildExit(_: glib.Pid, status: c_int, data: ?*anyopaque) callconv(.c) void {
        const self: *TerminalView = @ptrCast(@alignCast(data.?));
        self.child_watch = 0;
        self.exit_status = status;
        self.callbacks.exited(self.callbacks.data, self);
    }

    // ---- drawing --------------------------------------------------------------

    /// Coalesces bursts of output into one repaint a few milliseconds later.
    fn scheduleRefresh(self: *TerminalView) void {
        if (self.dead or self.refresh_source != 0) return;
        self.refresh_source = glib.timeoutAdd(8, onRefreshTick, self);
    }

    fn onRefreshTick(data: ?*anyopaque) callconv(.c) c_int {
        const self: *TerminalView = @ptrCast(@alignCast(data.?));
        self.refresh_source = 0;
        if (!self.hold) self.refresh();
        return 0;
    }

    /// Writes a line of our own into the terminal (not sent to the program),
    /// for example the exit notice of a tab that stays open.
    pub fn printNotice(self: *TerminalView, text: []const u8) void {
        self.stream.nextSlice("\r\n\x1b[2m");
        self.stream.nextSlice(text);
        self.stream.nextSlice("\x1b[0m\r\n");
        self.needs_full_repaint = true;
        self.scheduleRefresh();
    }

    /// Applies a changed background opacity and repaints everything.
    pub fn setOpacity(self: *TerminalView, opacity: f32) void {
        if (self.profile.opacity == opacity) return;
        self.profile.opacity = opacity;
        self.needs_full_repaint = true;
        self.scheduleRefresh();
    }

    fn refresh(self: *TerminalView) void {
        const surface = self.surface orelse return;
        self.render.update(self.allocator, &self.term) catch return;

        const cr = cairo.Context.create(surface);
        defer cr.destroy();

        // Which screen row the view starts at, for the search highlights.
        const screen = self.term.screens.active;
        self.view_top = if (screen.pages.pointFromPin(.screen, screen.pages.getTopLeft(.viewport))) |pt| pt.screen.y else 0;
        const row_data = self.render.row_data.slice();
        const dirty = row_data.items(.dirty);
        const cells = row_data.items(.cells);
        const selection = row_data.items(.selection);
        const full = self.needs_full_repaint or self.render.dirty != .false;
        if (full) {
            // The margins around the cell grid carry the background too.
            const bg = self.render.colors.background;
            cr.setOperator(.source);
            cr.setSourceRgba(
                @as(f64, @floatFromInt(bg.r)) / 255.0,
                @as(f64, @floatFromInt(bg.g)) / 255.0,
                @as(f64, @floatFromInt(bg.b)) / 255.0,
                self.profile.opacity,
            );
            cr.paint();
            cr.setOperator(.over);
        }
        for (0..self.render.rows) |y| {
            if (!full and !dirty[y]) continue;
            self.paintRow(cr, y, cells[y], selection[y]);
        }
        self.needs_full_repaint = false;
        self.render.clean();
        self.syncScrollbar();
        self.area.as(gtk.Widget).queueDraw();
    }

    /// Mirrors the scrollback position into the scroll bar.
    fn syncScrollbar(self: *TerminalView) void {
        const sb = self.term.screens.active.pages.scrollbar();
        self.syncing_scrollbar = true;
        defer self.syncing_scrollbar = false;
        self.adjustment.configure(
            @floatFromInt(sb.offset),
            0,
            @floatFromInt(@max(sb.total, 1)),
            1,
            @floatFromInt(@max(sb.len, 1)),
            @floatFromInt(@max(sb.len, 1)),
        );
        self.scrollbar.as(gtk.Widget).setVisible(@intFromBool(sb.total > sb.len));
    }

    fn onScrollbarMoved(adj: *gtk.Adjustment, self: *TerminalView) callconv(.c) void {
        if (self.syncing_scrollbar) return;
        const row: usize = @intFromFloat(@max(0, adj.getValue()));
        self.term.screens.active.scroll(.{ .row = row });
        self.needs_full_repaint = true;
        self.scheduleRefresh();
    }

    fn colorOf(self: *const TerminalView, c: vt.Style.Color, default: vt.color.RGB) vt.color.RGB {
        return switch (c) {
            .none => default,
            .palette => |index| self.render.colors.palette[index],
            .rgb => |value| value,
        };
    }

    fn setSource(cr: *cairo.Context, c: vt.color.RGB) void {
        cr.setSourceRgb(@as(f64, @floatFromInt(c.r)) / 255.0, @as(f64, @floatFromInt(c.g)) / 255.0, @as(f64, @floatFromInt(c.b)) / 255.0);
    }

    fn paintRow(self: *TerminalView, cr: *cairo.Context, y: usize, cells: anytype, selected: ?[2]vt.size.CellCountInt) void {
        const default_bg = self.render.colors.background;
        const default_fg = self.render.colors.foreground;
        const top = self.pad() + @as(f64, @floatFromInt(y)) * self.cell_h;

        // Row background; the default colour carries the profile's opacity.
        cr.setOperator(.source);
        cr.setSourceRgba(
            @as(f64, @floatFromInt(default_bg.r)) / 255.0,
            @as(f64, @floatFromInt(default_bg.g)) / 255.0,
            @as(f64, @floatFromInt(default_bg.b)) / 255.0,
            self.profile.opacity,
        );
        cr.rectangle(0, top, @floatFromInt(self.surface_w), self.cell_h);
        cr.fill();
        cr.setOperator(.over);

        const raws = cells.items(.raw);
        const styles = cells.items(.style);
        const graphemes = cells.items(.grapheme);
        const n = @min(raws.len, self.cols);

        // Pass 1: backgrounds.
        const searching = self.finder.matches.items.len > 0;
        for (0..n) |x| {
            var bg = self.cellColors(raws[x], styles[x], default_fg, default_bg, isSelected(selected, x));
            if (searching and !isSelected(selected, x) and self.finder.covers(self.view_top + @as(u32, @intCast(y)), @intCast(x))) bg.bg = search_bg;
            if (std.meta.eql(bg.bg, default_bg)) continue;
            setSource(cr, bg.bg);
            const width: f64 = if (raws[x].wide == .wide) 2 else 1;
            // Whole pixels, so neighbouring cells meet without a seam.
            const x0 = @round(self.pad() + @as(f64, @floatFromInt(x)) * self.cell_w);
            const x1 = @round(self.pad() + (@as(f64, @floatFromInt(x)) + width) * self.cell_w);
            cr.rectangle(x0, top, x1 - x0, self.cell_h);
            cr.fill();
        }

        // Pass 2: glyphs and decorations.
        var buf: [32]u8 = undefined;
        for (0..n) |x| {
            const raw = raws[x];
            if (raw.wide == .spacer_tail or raw.wide == .spacer_head) continue;
            const style = if (raw.style_id != 0) styles[x] else vt.Style{};
            var colors = self.cellColors(raw, styles[x], default_fg, default_bg, isSelected(selected, x));
            if (searching and !isSelected(selected, x) and self.finder.covers(self.view_top + @as(u32, @intCast(y)), @intCast(x))) colors = .{ .fg = .{ .r = 0, .g = 0, .b = 0 }, .bg = search_bg };
            const left = self.pad() + @as(f64, @floatFromInt(x)) * self.cell_w;

            if (style.flags.invisible) continue;
            const text = cellText(&buf, raw, graphemes[x]) orelse continue;
            if (text.len == 0 or (text.len == 1 and text[0] == ' ')) {
                self.decorations(cr, style, colors.fg, left, top, 1);
                continue;
            }
            var fg = colors.fg;
            if (style.flags.faint) fg = .{ .r = fg.r / 2 + colors.bg.r / 2, .g = fg.g / 2 + colors.bg.g / 2, .b = fg.b / 2 + colors.bg.b / 2 };
            setSource(cr, fg);
            const font_index: usize = @as(usize, @intFromBool(style.flags.bold)) | (@as(usize, @intFromBool(style.flags.italic)) << 1);
            self.layout.setFontDescription(self.fonts[font_index]);
            self.layout.setText(@ptrCast(text.ptr), @intCast(text.len));
            cr.moveTo(left, top);
            pangocairo.showLayout(cr, self.layout);
            self.decorations(cr, style, colors.fg, left, top, if (raw.wide == .wide) 2 else 1);
        }
    }

    fn decorations(self: *TerminalView, cr: *cairo.Context, style: vt.Style, fg: vt.color.RGB, left: f64, top: f64, cells: f64) void {
        if (style.flags.underline == .none and !style.flags.strikethrough and !style.flags.overline) return;
        setSource(cr, fg);
        cr.setLineWidth(1);
        const width = cells * self.cell_w;
        if (style.flags.underline != .none) {
            const yline = top + self.cell_h - 1.5;
            cr.moveTo(left, yline);
            cr.rectangle(left, yline, width, 1);
            cr.fill();
        }
        if (style.flags.strikethrough) {
            cr.rectangle(left, top + self.cell_h / 2, width, 1);
            cr.fill();
        }
        if (style.flags.overline) {
            cr.rectangle(left, top, width, 1);
            cr.fill();
        }
    }

    /// The colour behind search matches (the current one is selected).
    const search_bg: vt.color.RGB = .{ .r = 0xF6, .g = 0xD3, .b = 0x2D };

    fn isSelected(selected: ?[2]vt.size.CellCountInt, x: usize) bool {
        const range = selected orelse return false;
        return x >= range[0] and x <= range[1];
    }

    const CellColors = struct { fg: vt.color.RGB, bg: vt.color.RGB };

    fn cellColors(self: *const TerminalView, raw: vt.Cell, style: vt.Style, default_fg: vt.color.RGB, default_bg: vt.color.RGB, selected: bool) CellColors {
        var fg = default_fg;
        var bg = default_bg;
        switch (raw.content_tag) {
            .bg_color_palette => bg = self.render.colors.palette[raw.content.color_palette.data],
            .bg_color_rgb => bg = .{ .r = raw.content.color_rgb.r, .g = raw.content.color_rgb.g, .b = raw.content.color_rgb.b },
            else => {},
        }
        if (raw.style_id != 0) {
            fg = self.colorOf(style.fg_color, default_fg);
            const styled_bg = self.colorOf(style.bg_color, bg);
            bg = styled_bg;
            if (style.flags.bold and style.fg_color == .palette and style.fg_color.palette < 8) {
                fg = self.render.colors.palette[style.fg_color.palette + 8];
            }
            if (style.flags.inverse) std.mem.swap(vt.color.RGB, &fg, &bg);
        }
        if (selected) std.mem.swap(vt.color.RGB, &fg, &bg);
        return .{ .fg = fg, .bg = bg };
    }

    /// UTF-8 text of a cell, or null if it has none.
    fn cellText(buf: []u8, raw: vt.Cell, grapheme: []const u21) ?[]const u8 {
        switch (raw.content_tag) {
            .codepoint => {
                const cp = raw.content.codepoint.data;
                if (cp == 0) return buf[0..0];
                const n = std.unicode.utf8Encode(cp, buf) catch return null;
                return buf[0..n];
            },
            .codepoint_grapheme => {
                var len = std.unicode.utf8Encode(raw.content.codepoint.data, buf) catch return null;
                for (grapheme) |cp| {
                    if (len + 4 > buf.len) break;
                    len += std.unicode.utf8Encode(cp, buf[len..]) catch break;
                }
                return buf[0..len];
            },
            else => return buf[0..0],
        }
    }

    fn onDraw(_: *gtk.DrawingArea, cr: *cairo.Context, _: c_int, _: c_int, data: ?*anyopaque) callconv(.c) void {
        const self: *TerminalView = @ptrCast(@alignCast(data.?));
        if (self.surface) |surface| {
            cr.setSourceSurface(surface, 0, 0);
            cr.paint();
        }
        self.drawCursor(cr);
        self.drawOverlays(cr);
    }

    /// The address under the mouse, the bell's flash and the read-only badge.
    fn drawOverlays(self: *TerminalView, cr: *cairo.Context) void {
        if (self.hover) |h| {
            setSource(cr, self.render.colors.foreground);
            const left = self.pad() + @as(f64, @floatFromInt(h.x0)) * self.cell_w;
            const width = @as(f64, @floatFromInt(h.x1 - h.x0 + 1)) * self.cell_w;
            cr.rectangle(left, self.pad() + @as(f64, @floatFromInt(h.row + 1)) * self.cell_h - 1.5, width, 1);
            cr.fill();
        }
        if (self.bell_flash) {
            const fg = self.render.colors.foreground;
            cr.setSourceRgba(@as(f64, @floatFromInt(fg.r)) / 255.0, @as(f64, @floatFromInt(fg.g)) / 255.0, @as(f64, @floatFromInt(fg.b)) / 255.0, 0.18);
            cr.paint();
        }
        if (self.read_only) {
            const text = common.tr("Read-only");
            self.layout.setFontDescription(self.fonts[0]);
            self.layout.setText(text, -1);
            var w: c_int = 0;
            var h: c_int = 0;
            self.layout.getPixelSize(&w, &h);
            const x = @as(f64, @floatFromInt(self.surface_w - w)) - 14;
            cr.setSourceRgba(0.8, 0.2, 0.1, 0.85);
            cr.rectangle(x - 6, 4, @as(f64, @floatFromInt(w)) + 12, @as(f64, @floatFromInt(h)) + 4);
            cr.fill();
            cr.setSourceRgb(1, 1, 1);
            cr.moveTo(x, 6);
            pangocairo.showLayout(cr, self.layout);
        }
    }

    fn drawCursor(self: *TerminalView, cr: *cairo.Context) void {
        const cursor = self.render.cursor;
        if (!cursor.visible) return;
        const pos = cursor.viewport orelse return;
        if (cursor.blinking and !self.cursor_visible and self.focused) return;

        const left = self.pad() + @as(f64, @floatFromInt(pos.x)) * self.cell_w;
        const top = self.pad() + @as(f64, @floatFromInt(pos.y)) * self.cell_h;
        const fg = self.render.colors.cursor orelse self.render.colors.foreground;
        setSource(cr, fg);
        if (!self.focused) {
            cr.setLineWidth(1);
            cr.rectangle(left + 0.5, top + 0.5, self.cell_w - 1, self.cell_h - 1);
            cr.stroke();
            return;
        }
        switch (cursor.visual_style) {
            .block, .block_hollow => {
                cr.rectangle(left, top, self.cell_w, self.cell_h);
                cr.fill();
                // Redraw the glyph in the background colour so it stays readable.
                const row_data = self.render.row_data.slice();
                const cells = row_data.items(.cells)[pos.y];
                var buf: [32]u8 = undefined;
                if (cellText(&buf, cells.items(.raw)[pos.x], cells.items(.grapheme)[pos.x])) |text| {
                    if (text.len > 0 and text[0] != ' ') {
                        setSource(cr, self.render.colors.background);
                        self.layout.setFontDescription(self.fonts[0]);
                        self.layout.setText(@ptrCast(text.ptr), @intCast(text.len));
                        cr.moveTo(left, top);
                        pangocairo.showLayout(cr, self.layout);
                    }
                }
            },
            .bar => {
                cr.rectangle(left, top, 2, self.cell_h);
                cr.fill();
            },
            .underline => {
                cr.rectangle(left, top + self.cell_h - 2, self.cell_w, 2);
                cr.fill();
            },
        }
    }

    // ---- input ---------------------------------------------------------------

    fn installControllers(self: *TerminalView) void {
        const widget_ = self.area.as(gtk.Widget);

        const keys = gtk.EventControllerKey.new();
        _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *TerminalView, &onKeyPressed, self, .{});
        _ = gtk.EventControllerKey.signals.key_released.connect(keys, *TerminalView, &onKeyReleased, self, .{});
        widget_.addController(keys.as(gtk.EventController));

        const focus = gtk.EventControllerFocus.new();
        _ = gtk.EventControllerFocus.signals.enter.connect(focus, *TerminalView, &onFocusEnter, self, .{});
        _ = gtk.EventControllerFocus.signals.leave.connect(focus, *TerminalView, &onFocusLeave, self, .{});
        widget_.addController(focus.as(gtk.EventController));

        const click = gtk.GestureClick.new();
        click.as(gtk.GestureSingle).setButton(0);
        _ = gtk.GestureClick.signals.pressed.connect(click, *TerminalView, &onPressed, self, .{});
        _ = gtk.GestureClick.signals.released.connect(click, *TerminalView, &onReleased, self, .{});
        widget_.addController(click.as(gtk.EventController));

        const motion = gtk.EventControllerMotion.new();
        _ = gtk.EventControllerMotion.signals.motion.connect(motion, *TerminalView, &onMotion, self, .{});
        widget_.addController(motion.as(gtk.EventController));

        // Files dropped on the terminal are typed as quoted paths; text as a paste.
        const drop = gtk.DropTarget.new(gobject.ext.types.invalid, .{ .copy = true });
        var types = [_]gobject.Type{ gdk.FileList.getGObjectType(), gobject.ext.types.string };
        drop.setGtypes(&types, types.len);
        _ = gtk.DropTarget.signals.drop.connect(drop, *TerminalView, &onDrop, self, .{});
        widget_.addController(drop.as(gtk.EventController));

        const scroll = gtk.EventControllerScroll.new(.{ .vertical = true });
        _ = gtk.EventControllerScroll.signals.scroll.connect(scroll, *TerminalView, &onScroll, self, .{});
        widget_.addController(scroll.as(gtk.EventController));
    }

    fn onFocusEnter(_: *gtk.EventControllerFocus, self: *TerminalView) callconv(.c) void {
        self.focused = true;
        self.callbacks.focused(self.callbacks.data, self);
        self.cursor_visible = true;
        if (self.blink_source == 0) self.blink_source = glib.timeoutAdd(600, onBlink, self);
        if (self.term.modes.get(.focus_event)) self.sendFocus(.gained);
        self.area.as(gtk.Widget).queueDraw();
    }

    fn onFocusLeave(_: *gtk.EventControllerFocus, self: *TerminalView) callconv(.c) void {
        self.focused = false;
        if (self.term.modes.get(.focus_event)) self.sendFocus(.lost);
        self.area.as(gtk.Widget).queueDraw();
    }

    fn sendFocus(self: *TerminalView, event: vt.input.FocusEvent) void {
        var buf: [vt.input.max_focus_encode_size]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        vt.input.encodeFocus(&w, event) catch return;
        self.pty.send(w.buffered());
    }

    fn onBlink(data: ?*anyopaque) callconv(.c) c_int {
        const self: *TerminalView = @ptrCast(@alignCast(data.?));
        if (!self.focused) {
            self.blink_source = 0;
            return 0;
        }
        self.cursor_visible = !self.cursor_visible;
        if (self.render.cursor.blinking) self.area.as(gtk.Widget).queueDraw();
        return 1;
    }

    fn modsOf(state: gdk.ModifierType) vt.input.KeyMods {
        return .{
            .shift = state.shift_mask,
            .ctrl = state.control_mask,
            .alt = state.alt_mask,
            .super = state.super_mask,
            .caps_lock = state.lock_mask,
        };
    }

    fn onKeyPressed(_: *gtk.EventControllerKey, keyval: c_uint, keycode: c_uint, state: gdk.ModifierType, self: *TerminalView) callconv(.c) c_int {
        if (self.handleShortcut(keyval, state)) return 1;
        // Read-only: the keys go nowhere (modifiers alone are let through).
        if (self.read_only) return @intFromBool(gdk.keyvalToUnicode(keyval) != 0 or keyval == gdk.KEY_Return or keyval == gdk.KEY_BackSpace or keyval == gdk.KEY_Tab);
        self.scrollToBottom();
        return @intFromBool(self.sendKey(.press, keyval, keycode, state));
    }

    fn onKeyReleased(_: *gtk.EventControllerKey, keyval: c_uint, keycode: c_uint, state: gdk.ModifierType, self: *TerminalView) callconv(.c) void {
        if (self.read_only) return;
        _ = self.sendKey(.release, keyval, keycode, state);
    }

    fn sendKey(self: *TerminalView, action: vt.input.KeyAction, keyval: c_uint, keycode: c_uint, state: gdk.ModifierType) bool {
        var text_buf: [8]u8 = undefined;
        var text: []const u8 = "";
        const cp = gdk.keyvalToUnicode(keyval);
        if (cp >= 0x20 and cp != 0x7f) {
            const n = std.unicode.utf8Encode(@intCast(cp), &text_buf) catch 0;
            text = text_buf[0..n];
        }
        const mods = modsOf(state);
        var event: vt.input.KeyEvent = .{
            .action = action,
            .key = keymap.fromHardwareKeycode(keycode),
            .mods = mods,
            .utf8 = if (action == .release) "" else text,
            .unshifted_codepoint = @intCast(gdk.keyvalToUnicode(gdk.keyvalToLower(keyval))),
        };
        if (text.len > 0 and mods.shift) event.consumed_mods = .{ .shift = true };

        var buf: [128]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        const opts = vt.input.KeyEncodeOptions.fromTerminal(&self.term);
        vt.input.encodeKey(&w, event, opts) catch return false;
        const out = w.buffered();
        if (out.len == 0) return false;
        self.pty.send(out);
        return true;
    }

    /// Terminal-level shortcuts (SPEC.md 6.3). Plain Ctrl+letters belong to
    /// the program running in the terminal, so these use Ctrl+Shift.
    fn handleShortcut(self: *TerminalView, keyval: c_uint, state: gdk.ModifierType) bool {
        const ctrl_shift = state.control_mask and state.shift_mask and !state.alt_mask;
        if (ctrl_shift) {
            switch (gdk.keyvalToLower(keyval)) {
                gdk.KEY_c => {
                    self.copySelection();
                    return true;
                },
                gdk.KEY_v => {
                    self.pasteClipboard(false);
                    return true;
                },
                // Jump between shell prompts (needs shell integration).
                gdk.KEY_Up, gdk.KEY_Down => {
                    self.term.scrollViewport(.{ .delta_prompt = if (keyval == gdk.KEY_Up) -1 else 1 });
                    self.needs_full_repaint = true;
                    self.scheduleRefresh();
                    return true;
                },
                else => {},
            }
        }
        if (state.shift_mask and !state.control_mask and !state.alt_mask) {
            switch (keyval) {
                gdk.KEY_Page_Up => {
                    self.term.scrollViewport(.{ .delta = -@as(isize, self.rows) + 1 });
                    self.scheduleRefresh();
                    return true;
                },
                gdk.KEY_Page_Down => {
                    self.term.scrollViewport(.{ .delta = @as(isize, self.rows) - 1 });
                    self.scheduleRefresh();
                    return true;
                },
                gdk.KEY_Insert => {
                    self.pasteClipboard(true);
                    return true;
                },
                else => {},
            }
        }
        return false;
    }

    fn scrollToBottom(self: *TerminalView) void {
        self.term.scrollViewport(.bottom);
    }

    // ---- clipboard -------------------------------------------------------------

    pub fn copySelection(self: *TerminalView) void {
        const screen = self.term.screens.active;
        const selection = screen.selection orelse return;
        const text = screen.selectionString(self.allocator, .{ .sel = selection }) catch return;
        defer self.allocator.free(text);
        self.area.as(gtk.Widget).getClipboard().setText(text);
    }

    pub fn pasteClipboard(self: *TerminalView, primary: bool) void {
        const clipboard = if (primary) self.area.as(gtk.Widget).getPrimaryClipboard() else self.area.as(gtk.Widget).getClipboard();
        clipboard.readTextAsync(null, onPasteText, self);
    }

    fn onPasteText(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *TerminalView = @ptrCast(@alignCast(data.?));
        const clipboard: *gdk.Clipboard = @ptrCast(@alignCast(source.?));
        var err: ?*glib.Error = null;
        const text = clipboard.readTextFinish(result, &err) orelse {
            if (err) |e| e.free();
            return;
        };
        defer glib.free(text);
        self.paste(std.mem.span(text));
    }

    /// Types `bytes` into the program as if the user had (no paste markers).
    pub fn typeText(self: *TerminalView, bytes: []const u8) void {
        if (self.read_only) return;
        self.pty.send(bytes);
    }

    /// Pastes `text`, asking first when it would run commands by itself
    /// (several lines without bracketed paste, sudo, or control characters).
    pub fn paste(self: *TerminalView, text: []const u8) void {
        if (self.read_only) return;
        const bracketed = self.term.modes.get(.bracketed_paste);
        if (self.paste_warning) if (safety.risk(text, bracketed)) |why| {
            if (self.pending_paste) |old| self.allocator.free(old);
            self.pending_paste = self.allocator.dupe(u8, text) catch return;
            var buf: [300]u8 = undefined;
            const detail = std.fmt.bufPrintSentinel(&buf, "{s} Paste it anyway?", .{why}, 0) catch "";
            common.dialogs.choose(self.rootWindow(), common.tr("This paste may run commands"), detail, &.{ "Cancel", "Paste" }, 0, TerminalView, onPasteAnswer, self);
            return;
        };
        self.pasteNow(text);
    }

    fn onPasteAnswer(self: *TerminalView, choice: c_int) void {
        const text = self.pending_paste orelse return;
        self.pending_paste = null;
        defer {
            @memset(text, 0);
            self.allocator.free(text);
        }
        if (choice == 1) self.pasteNow(text);
        self.grabFocus();
    }

    fn rootWindow(self: *TerminalView) ?*gtk.Window {
        const root = self.area.as(gtk.Widget).getRoot() orelse return null;
        return @ptrCast(@alignCast(root));
    }

    fn pasteNow(self: *TerminalView, text: []const u8) void {
        const copy = self.allocator.dupe(u8, text) catch return;
        defer self.allocator.free(copy);
        const opts = vt.input.PasteOptions.fromTerminal(&self.term);
        const parts = vt.input.encodePaste(copy, opts);
        for (parts) |part| if (part.len > 0) self.pty.send(part);
        self.scrollToBottom();
    }

    // ---- mouse -----------------------------------------------------------------

    fn cellAt(self: *const TerminalView, x: f64, y: f64) struct { col: u16, row: u16 } {
        const col = @max(0, @min(@as(f64, @floatFromInt(self.cols - 1)), @floor((x - self.pad()) / self.cell_w)));
        const row = @max(0, @min(@as(f64, @floatFromInt(self.rows - 1)), @floor((y - self.pad()) / self.cell_h)));
        return .{ .col = @intFromFloat(col), .row = @intFromFloat(row) };
    }

    fn mouseTracking(self: *const TerminalView) bool {
        return self.term.flags.mouse_event != .none;
    }

    fn sendMouse(self: *TerminalView, action: vt.input.MouseAction, button: ?vt.input.MouseButton, x: f64, y: f64, state: gdk.ModifierType) void {
        var buf: [64]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        const MouseSize = @FieldType(vt.input.MouseEncodeOptions, "size");
        const size: MouseSize = .{
            .screen = .{ .width = @as(u32, @intCast(@max(1, self.surface_w))), .height = @as(u32, @intCast(@max(1, self.surface_h))) },
            .cell = .{ .width = @as(u32, @intFromFloat(self.cell_w)), .height = @as(u32, @intFromFloat(self.cell_h)) },
            .padding = .{ .top = @as(u32, self.profile.padding), .bottom = @as(u32, self.profile.padding), .right = @as(u32, self.profile.padding), .left = @as(u32, self.profile.padding) },
        };
        var opts = vt.input.MouseEncodeOptions.fromTerminal(&self.term, size);
        opts.any_button_pressed = self.selecting;
        vt.input.encodeMouse(&w, .{
            .action = action,
            .button = button,
            .mods = modsOf(state),
            .pos = .{ .x = @floatCast(x), .y = @floatCast(y) },
        }, opts) catch return;
        self.pty.send(w.buffered());
    }

    fn onPressed(gesture: *gtk.GestureClick, n_press: c_int, x: f64, y: f64, self: *TerminalView) callconv(.c) void {
        _ = self.area.as(gtk.Widget).grabFocus();
        const button = gesture.as(gtk.GestureSingle).getCurrentButton();
        const state = gesture.as(gtk.EventController).getCurrentEventState();

        // Ctrl+click opens a link: one a program marked (OSC 8), or an
        // address in the text.
        if (button == 1 and state.control_mask) {
            if (self.linkAt(x, y)) |uri| {
                defer self.allocator.free(uri);
                self.openUri(uri);
                return;
            }
        }
        // The right-click menu, unless the program wants the right button.
        if (button == 3 and (!self.mouseTracking() or state.shift_mask)) {
            self.showMenu(x, y);
            return;
        }
        // Shift forces selection even when the program tracks the mouse.
        if (self.mouseTracking() and !state.shift_mask) {
            if (self.read_only) return;
            self.selecting = true;
            self.sendMouse(.press, mouseButton(button), x, y, state);
            return;
        }
        if (button == 2) {
            self.pasteClipboard(true);
            return;
        }
        if (button != 1) return;

        const cell = self.cellAt(x, y);
        const screen = self.term.screens.active;
        const pin = screen.pages.pin(.{ .viewport = .{ .x = cell.col, .y = cell.row } }) orelse return;
        self.selecting = true;
        self.anchor = pin;
        if (n_press == 1) {
            screen.clearSelection();
        } else {
            // Double click selects the whole row's word region; triple, the line.
            const left = screen.pages.pin(.{ .viewport = .{ .x = 0, .y = cell.row } }) orelse return;
            const right = screen.pages.pin(.{ .viewport = .{ .x = self.cols - 1, .y = cell.row } }) orelse return;
            screen.select(vt.Selection.init(if (n_press >= 3) left else pin, if (n_press >= 3) right else pin, false)) catch {};
        }
        self.scheduleRefresh();
    }

    fn onReleased(gesture: *gtk.GestureClick, _: c_int, x: f64, y: f64, self: *TerminalView) callconv(.c) void {
        const button = gesture.as(gtk.GestureSingle).getCurrentButton();
        const state = gesture.as(gtk.EventController).getCurrentEventState();
        const was_tracking = self.selecting and self.mouseTracking() and !state.shift_mask;
        self.selecting = false;
        if (was_tracking) {
            self.sendMouse(.release, mouseButton(button), x, y, state);
            return;
        }
        // Selecting text copies it to the primary selection, like other terminals.
        const screen = self.term.screens.active;
        if (screen.selection) |selection| {
            const text = screen.selectionString(self.allocator, .{ .sel = selection }) catch return;
            defer self.allocator.free(text);
            self.area.as(gtk.Widget).getPrimaryClipboard().setText(text);
            // Like Windows Terminal's "copy on select": also the regular clipboard.
            if (self.profile.copy_on_select and text.len > 0) self.area.as(gtk.Widget).getClipboard().setText(text);
        }
    }

    fn onMotion(ctrl: *gtk.EventControllerMotion, x: f64, y: f64, self: *TerminalView) callconv(.c) void {
        const state = ctrl.as(gtk.EventController).getCurrentEventState();
        if (!self.selecting) self.updateHover(x, y);
        if (self.mouseTracking() and !state.shift_mask) {
            if (self.term.flags.mouse_event == .any or (self.term.flags.mouse_event == .button and self.selecting))
                self.sendMouse(.motion, null, x, y, state);
            return;
        }
        if (!self.selecting) return;
        const anchor = self.anchor orelse return;
        const cell = self.cellAt(x, y);
        const screen = self.term.screens.active;
        const pin = screen.pages.pin(.{ .viewport = .{ .x = cell.col, .y = cell.row } }) orelse return;
        screen.select(vt.Selection.init(anchor, pin, state.alt_mask)) catch return;
        self.scheduleRefresh();
    }

    fn onScroll(ctrl: *gtk.EventControllerScroll, _: f64, dy: f64, self: *TerminalView) callconv(.c) c_int {
        const state = ctrl.as(gtk.EventController).getCurrentEventState();
        if (self.mouseTracking() and !state.shift_mask) {
            self.sendMouse(.press, if (dy < 0) .four else .five, 0, 0, state);
            return 1;
        }
        self.scroll_accum += dy * 3;
        const lines: isize = @intFromFloat(self.scroll_accum);
        if (lines != 0) {
            self.scroll_accum -= @floatFromInt(lines);
            self.term.scrollViewport(.{ .delta = lines });
            self.scheduleRefresh();
        }
        return 1;
    }

    fn mouseButton(button: c_uint) ?vt.input.MouseButton {
        return switch (button) {
            1 => .left,
            2 => .middle,
            3 => .right,
            else => null,
        };
    }

    /// The link under a point: an OSC 8 hyperlink, or an address in the
    /// text. Owned by the caller.
    fn linkAt(self: *TerminalView, x: f64, y: f64) ?[:0]u8 {
        const cell = self.cellAt(x, y);
        if (self.osc8At(cell.col, cell.row)) |uri| return uri;
        const found = self.urlAt(cell.col, cell.row) orelse return null;
        return found.uri;
    }

    fn osc8At(self: *TerminalView, col: u16, row: u16) ?[:0]u8 {
        const screen = self.term.screens.active;
        const pin = screen.pages.pin(.{ .viewport = .{ .x = col, .y = row } }) orelse return null;
        const page = pin.node.page();
        const raw = pin.rowAndCell().cell;
        const link_id = page.lookupHyperlink(raw) orelse return null;
        const entry = page.hyperlink_set.get(page.memory, link_id);
        return self.allocator.dupeSentinel(u8, entry.uri.slice(page.memory), 0) catch null;
    }

    const UrlHit = struct { uri: [:0]u8, x0: u16, x1: u16 };

    /// A plain address in the text of view row `row` covering column `col`.
    fn urlAt(self: *TerminalView, col: u16, row: u16) ?UrlHit {
        const screen = self.term.screens.active;
        var line: [1024]u8 = undefined;
        var cols: [1024]u16 = undefined;
        var len: usize = 0;
        var x: u16 = 0;
        var at: ?usize = null;
        while (x < self.cols) : (x += 1) {
            const pin = screen.pages.pin(.{ .viewport = .{ .x = x, .y = row } }) orelse break;
            const c = pin.rowAndCell().cell;
            if (c.wide == .spacer_tail) continue;
            const cp: u21 = if (c.content_tag == .codepoint or c.content_tag == .codepoint_grapheme) c.content.codepoint.data else 0;
            var enc: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(if (cp == 0) ' ' else cp, &enc) catch 1;
            if (len + n > line.len) break;
            if (x == col) at = len;
            @memcpy(line[len..][0..n], enc[0..n]);
            for (0..n) |i| cols[len + i] = x;
            len += n;
        }
        const byte = at orelse return null;
        const span = urls.at(line[0..len], byte) orelse return null;
        var buf: [1100]u8 = undefined;
        const text = urls.openable(&buf, line[span.start..span.end]);
        return .{
            .uri = self.allocator.dupeSentinel(u8, text, 0) catch return null,
            .x0 = cols[span.start],
            .x1 = cols[span.end - 1],
        };
    }

    /// Underlines the address under the mouse and shows a hand pointer.
    fn updateHover(self: *TerminalView, x: f64, y: f64) void {
        const cell = self.cellAt(x, y);
        var next: @TypeOf(self.hover) = null;
        if (self.osc8At(cell.col, cell.row)) |uri| {
            self.allocator.free(uri);
            next = .{ .row = cell.row, .x0 = cell.col, .x1 = cell.col };
        } else if (self.urlAt(cell.col, cell.row)) |hit| {
            self.allocator.free(hit.uri);
            next = .{ .row = cell.row, .x0 = hit.x0, .x1 = hit.x1 };
        }
        if (std.meta.eql(next, self.hover)) return;
        self.hover = next;
        self.area.as(gtk.Widget).setCursorFromName(if (next != null) "pointer" else "text");
        self.area.as(gtk.Widget).queueDraw();
    }

    fn openUri(self: *TerminalView, uri: [:0]const u8) void {
        var err: ?*glib.Error = null;
        if (gio.AppInfo.launchDefaultForUri(uri, null, &err) == 0) {
            const message = if (err) |e| e.f_message orelse "unknown error" else "unknown error";
            common.dialogs.showError(self.rootWindow(), common.tr("Cannot open this link"), std.mem.span(message));
            if (err) |e| e.free();
        }
    }

    // ---- the right-click menu ----------------------------------------------------

    fn showMenu(self: *TerminalView, x: f64, y: f64) void {
        if (self.menu_link) |l| self.allocator.free(l);
        self.menu_link = self.linkAt(x, y);
        const has_sel = self.term.screens.active.selection != null;
        const tr = common.tr;
        var items: [16]common.contextmenu.Item = undefined;
        var n: usize = 0;
        const add = struct {
            fn f(list: []common.contextmenu.Item, count: *usize, label: [:0]const u8, item: MenuItem, enabled: bool) void {
                list[count.*] = .{ .label = label, .id = @intFromEnum(item), .enabled = enabled };
                count.* += 1;
            }
        }.f;
        if (self.menu_link != null) {
            add(&items, &n, tr("Open Link"), .open_link, true);
            add(&items, &n, tr("Copy Link Address"), .copy_link, true);
        }
        add(&items, &n, tr("Copy"), .copy, has_sel);
        add(&items, &n, tr("Copy as HTML"), .copy_html, has_sel);
        add(&items, &n, tr("Paste"), .paste, !self.read_only);
        add(&items, &n, tr("Select All"), .select_all, true);
        const windowed = self.callbacks.menu != null;
        if (windowed) add(&items, &n, tr("Find\u{2026}"), .find, true);
        if (windowed) add(&items, &n, tr("Split Left/Right"), .split_right, true);
        if (windowed) add(&items, &n, tr("Split Top/Bottom"), .split_down, true);
        add(&items, &n, if (self.read_only) tr("Allow Typing") else tr("Read-Only"), .read_only, true);
        if (windowed) add(&items, &n, tr("Save Output As\u{2026}"), .save_output, true);
        add(&items, &n, tr("Clear Scrollback"), .clear, true);
        add(&items, &n, tr("Reset"), .reset, true);
        if (windowed) add(&items, &n, tr("Close Pane"), .close_pane, true);
        common.contextmenu.show(self.area.as(gtk.Widget), x, y, items[0..n], TerminalView, onMenuChosen, self);
    }

    fn onMenuChosen(self: *TerminalView, id: usize) void {
        const item: MenuItem = @enumFromInt(id);
        switch (item) {
            .copy => self.copySelection(),
            .copy_html => self.copySelectionHtml(),
            .paste => self.pasteClipboard(false),
            .open_link => if (self.menu_link) |l| self.openUri(l),
            .copy_link => if (self.menu_link) |l| self.area.as(gtk.Widget).getClipboard().setText(l),
            .select_all => self.selectAll(),
            .clear => self.clearScrollback(),
            .reset => self.reset(),
            .read_only => self.setReadOnly(!self.read_only),
            .find => self.forward("find"),
            .save_output => self.forward("save-output"),
            .split_right => self.forward("split-right"),
            .split_down => self.forward("split-down"),
            .close_pane => self.forward("close-pane"),
        }
    }

    fn forward(self: *TerminalView, action: []const u8) void {
        if (self.callbacks.menu) |f| f(self.callbacks.data, self, action);
    }

    pub fn setReadOnly(self: *TerminalView, on: bool) void {
        self.read_only = on;
        self.area.as(gtk.Widget).queueDraw();
    }

    pub fn selectAll(self: *TerminalView) void {
        const screen = self.term.screens.active;
        const sel = screen.selectAll() orelse return;
        screen.select(sel) catch return;
        self.needs_full_repaint = true;
        self.scheduleRefresh();
    }

    /// Forgets the lines above the screen.
    pub fn clearScrollback(self: *TerminalView) void {
        self.term.eraseDisplay(.scrollback, false);
        self.needs_full_repaint = true;
        self.scheduleRefresh();
    }

    /// Puts the terminal back as it started (colours, modes, the screen),
    /// for when a program left it in a strange state.
    pub fn reset(self: *TerminalView) void {
        self.term.fullReset();
        self.needs_full_repaint = true;
        self.scheduleRefresh();
    }

    // ---- saving and copying with colours ---------------------------------------

    /// The whole scrollback and screen as plain text or as an HTML page.
    pub fn outputText(self: *TerminalView, html: bool) ![]u8 {
        const screen = self.term.screens.active;
        const tl = screen.pages.getTopLeft(.screen);
        const br = screen.pages.getBottomRight(.screen) orelse return self.allocator.dupe(u8, "");
        return self.formatRange(vt.Selection.init(tl, br, false), html, true);
    }

    fn formatRange(self: *TerminalView, sel: vt.Selection, html: bool, page: bool) ![]u8 {
        const screen = self.term.screens.active;
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const palette = self.render.colors.palette;
        var f: vt.formatter.ScreenFormatter = .init(screen, .{
            .emit = if (html) .html else .plain,
            .unwrap = true,
            .trim = true,
            .background = self.render.colors.background,
            .foreground = self.render.colors.foreground,
            .palette = &palette,
        });
        f.content = .{ .selection = sel };
        if (html) f.extra = .styles;
        const w = &out.writer;
        if (html and page) try w.writeAll("<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"><title>Terminal output</title></head><body>\n");
        try f.format(w);
        if (html and page) try w.writeAll("\n</body></html>\n");
        return out.toOwnedSlice();
    }

    /// Copies the selection with its colours (as HTML, with plain text too).
    pub fn copySelectionHtml(self: *TerminalView) void {
        const screen = self.term.screens.active;
        const sel = screen.selection orelse return;
        const html = self.formatRange(sel, true, false) catch return;
        defer self.allocator.free(html);
        const text = screen.selectionString(self.allocator, .{ .sel = sel }) catch return;
        defer self.allocator.free(text);
        const html_bytes = glib.Bytes.new(html.ptr, html.len);
        defer html_bytes.unref();
        const text_bytes = glib.Bytes.new(text.ptr, text.len);
        defer text_bytes.unref();
        var providers = [_]*gdk.ContentProvider{
            gdk.ContentProvider.newForBytes("text/html", html_bytes),
            gdk.ContentProvider.newForBytes("text/plain;charset=utf-8", text_bytes),
        };
        const both = gdk.ContentProvider.newUnion(&providers, providers.len);
        defer both.as(gobject.Object).unref();
        _ = self.area.as(gtk.Widget).getClipboard().setContent(both);
    }

    // ---- drops -----------------------------------------------------------------

    fn onDrop(_: *gtk.DropTarget, value: *gobject.Value, _: f64, _: f64, self: *TerminalView) callconv(.c) c_int {
        if (self.read_only) return 0;
        if (value.f_g_type == gdk.FileList.getGObjectType()) {
            const list: *gdk.FileList = @ptrCast(@alignCast(value.getBoxed() orelse return 0));
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(self.allocator);
            var node: ?*glib.SList = list.getFiles();
            const head = node;
            defer if (head) |h| h.free();
            while (node) |n| : (node = n.f_next) {
                const f: *gio.File = @ptrCast(@alignCast(n.f_data orelse continue));
                const path = f.getPath() orelse continue;
                defer glib.free(path);
                safety.shellQuote(self.allocator, &out, std.mem.span(path)) catch return 0;
                out.append(self.allocator, ' ') catch return 0;
            }
            if (out.items.len == 0) return 0;
            self.pasteNow(out.items);
            self.grabFocus();
            return 1;
        }
        const text = value.getString() orelse return 0;
        self.paste(std.mem.span(text));
        self.grabFocus();
        return 1;
    }

    // ---- search ----------------------------------------------------------------

    /// Finds every match of `needle`; an empty needle ends the search.
    pub fn searchSet(self: *TerminalView, needle: []const u8, opts: finder_mod.Options) void {
        if (needle.len == 0) return self.searchClose();
        const same = if (self.search_needle) |n| std.mem.eql(u8, n, needle) and std.meta.eql(opts, self.search_opts) else false;
        if (!same) {
            if (self.search_needle) |n| self.allocator.free(n);
            self.search_needle = self.allocator.dupe(u8, needle) catch null;
            self.search_opts = opts;
            self.finder.current = null;
        }
        self.finder.run(self.allocator, self.term.screens.active, needle, opts) catch {};
        if (!same) _ = self.searchStep(true) else {
            self.needs_full_repaint = true;
            self.scheduleRefresh();
        }
    }

    /// Moves to the next (older) or previous (newer) match. Returns whether
    /// there was one.
    pub fn searchStep(self: *TerminalView, older: bool) bool {
        const m = self.finder.step(older) orelse {
            self.needs_full_repaint = true;
            self.scheduleRefresh();
            return false;
        };
        const screen = self.term.screens.active;
        const start = screen.pages.pin(.{ .screen = .{ .x = m.start_x, .y = m.start_y } }) orelse return false;
        const end = screen.pages.pin(.{ .screen = .{ .x = m.end_x, .y = m.end_y } }) orelse return false;
        screen.select(vt.Selection.init(start, end, false)) catch return false;
        // Keep the match a few lines below the top of the view.
        screen.scroll(.{ .pin = start });
        self.term.scrollViewport(.{ .delta = -@as(isize, @min(self.rows / 3, 5)) });
        self.needs_full_repaint = true;
        self.scheduleRefresh();
        return true;
    }

    /// "3 of 12", the matches and which one is selected (0 when none).
    pub fn searchCount(self: *const TerminalView) struct { current: usize, total: usize, error_text: ?[]const u8 } {
        return .{
            .current = if (self.finder.current) |c| self.finder.matches.items.len - c else 0,
            .total = self.finder.matches.items.len,
            .error_text = self.finder.errorText(),
        };
    }

    fn markSearchStale(self: *TerminalView) void {
        if (!self.dead and self.search_source == 0) self.search_source = glib.timeoutAdd(400, onSearchStale, self);
    }

    fn onSearchStale(data: ?*anyopaque) callconv(.c) c_int {
        const self: *TerminalView = @ptrCast(@alignCast(data.?));
        self.search_source = 0;
        if (self.search_needle) |n| {
            self.finder.run(self.allocator, self.term.screens.active, n, self.search_opts) catch {};
            self.needs_full_repaint = true;
            self.scheduleRefresh();
        }
        return 0;
    }

    pub fn searchClose(self: *TerminalView) void {
        if (self.search_needle) |n| self.allocator.free(n);
        self.search_needle = null;
        if (self.finder.matches.items.len > 0 or self.finder.current != null) {
            self.finder.clear();
            self.term.screens.active.clearSelection();
        }
        self.needs_full_repaint = true;
        self.scheduleRefresh();
    }

    pub fn grabFocus(self: *TerminalView) void {
        _ = self.area.as(gtk.Widget).grabFocus();
    }
};
