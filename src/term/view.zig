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
const profile_mod = @import("profile.zig");
const Pty = @import("pty.zig").Pty;

const log = std.log.scoped(.term);

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
};

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

    // Search within the scrollback.
    search: ?vt.search.Screen = null,

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
            .colors = termColors(self.colors),
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
        const cwd: ?[]const u8 = if (directory) |d| d else if (profile.directory.len > 0) profile.directory else null;
        var env_list: std.ArrayList([]const u8) = .empty;
        defer env_list.deinit(allocator);
        var env_parts = std.mem.splitScalar(u8, profile.environment, ';');
        while (env_parts.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " ");
            if (trimmed.len > 0) env_list.append(allocator, trimmed) catch {};
        }
        self.pty = try Pty.spawn(allocator, .{ .argv = argv, .cwd = cwd, .env = env_list.items, .size = self.ptySize() });
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
        _ = self;
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

    fn termColors(scheme: profile_mod.Scheme) @TypeOf(@as(vt.Terminal.Options, undefined).colors) {
        var colors: @TypeOf(@as(vt.Terminal.Options, undefined).colors) = .default;
        colors.background = .init(rgb(scheme.background));
        colors.foreground = .init(rgb(scheme.foreground));
        return colors;
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
        const cols: u16 = @intFromFloat(@max(2, @floor((@as(f64, @floatFromInt(width)) - 2 * self.pad()) / self.cell_w)));
        const rows: u16 = @intFromFloat(@max(1, @floor((@as(f64, @floatFromInt(height)) - 2 * self.pad()) / self.cell_h)));
        if (cols == self.cols and rows == self.rows and self.surface != null) return;
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
                .data => |n| self.stream.nextSlice(buf[0..n]),
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
        if (self.refresh_source != 0) return;
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
        for (0..n) |x| {
            const bg = self.cellColors(raws[x], styles[x], default_fg, default_bg, isSelected(selected, x));
            if (std.meta.eql(bg.bg, default_bg)) continue;
            setSource(cr, bg.bg);
            const width: f64 = if (raws[x].wide == .wide) 2 else 1;
            cr.rectangle(self.pad() + @as(f64, @floatFromInt(x)) * self.cell_w, top, width * self.cell_w, self.cell_h);
            cr.fill();
        }

        // Pass 2: glyphs and decorations.
        var buf: [32]u8 = undefined;
        for (0..n) |x| {
            const raw = raws[x];
            if (raw.wide == .spacer_tail or raw.wide == .spacer_head) continue;
            const style = if (raw.style_id != 0) styles[x] else vt.Style{};
            const colors = self.cellColors(raw, styles[x], default_fg, default_bg, isSelected(selected, x));
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

        const scroll = gtk.EventControllerScroll.new(.{ .vertical = true });
        _ = gtk.EventControllerScroll.signals.scroll.connect(scroll, *TerminalView, &onScroll, self, .{});
        widget_.addController(scroll.as(gtk.EventController));
    }

    fn onFocusEnter(_: *gtk.EventControllerFocus, self: *TerminalView) callconv(.c) void {
        self.focused = true;
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
        self.scrollToBottom();
        return @intFromBool(self.sendKey(.press, keyval, keycode, state));
    }

    fn onKeyReleased(_: *gtk.EventControllerKey, keyval: c_uint, keycode: c_uint, state: gdk.ModifierType, self: *TerminalView) callconv(.c) void {
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

    pub fn paste(self: *TerminalView, text: []const u8) void {
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

        // Ctrl+click opens an OSC 8 hyperlink.
        if (button == 1 and state.control_mask) {
            if (self.linkAt(x, y)) |uri| {
                defer self.allocator.free(uri);
                var err: ?*glib.Error = null;
                if (gio.AppInfo.launchDefaultForUri(uri, null, &err) == 0) {
                    const message = if (err) |e| e.f_message orelse "unknown error" else "unknown error";
                    common.dialogs.showError(if (self.area.as(gtk.Widget).getRoot()) |root| @as(*gtk.Window, @ptrCast(@alignCast(root))) else null, common.tr("Cannot open this link"), std.mem.span(message));
                    if (err) |e| e.free();
                }
                return;
            }
        }
        // Shift forces selection even when the program tracks the mouse.
        if (self.mouseTracking() and !state.shift_mask) {
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

    /// The OSC 8 hyperlink under a point, owned by the caller.
    fn linkAt(self: *TerminalView, x: f64, y: f64) ?[:0]u8 {
        const cell = self.cellAt(x, y);
        const screen = self.term.screens.active;
        const pin = screen.pages.pin(.{ .viewport = .{ .x = cell.col, .y = cell.row } }) orelse return null;
        const page = pin.node.page();
        const raw = pin.rowAndCell().cell;
        const link_id = page.lookupHyperlink(raw) orelse return null;
        const entry = page.hyperlink_set.get(page.memory, link_id);
        return self.allocator.dupeSentinel(u8, entry.uri.slice(page.memory), 0) catch null;
    }

    // ---- search ----------------------------------------------------------------

    /// Starts (or restarts) a search for `needle` and jumps to the newest
    /// match. An empty needle ends the search.
    pub fn searchSet(self: *TerminalView, needle: []const u8) void {
        self.searchClose();
        if (needle.len == 0) return;
        const screen = self.term.screens.active;
        var search = vt.search.Screen.init(self.allocator, screen, needle) catch return;
        search.searchAll() catch {
            search.deinit();
            return;
        };
        self.search = search;
        _ = self.searchStep(true);
    }

    /// Moves to the next (older) or previous (newer) match. Returns whether
    /// there was one.
    pub fn searchStep(self: *TerminalView, older: bool) bool {
        const search = &(self.search orelse return false);
        const moved = search.select(if (older) .next else .prev) catch return false;
        if (!moved) return false;
        const match = search.selectedMatch() orelse return false;
        const screen = self.term.screens.active;
        const start = match.startPin();
        const end = match.endPin();
        screen.select(vt.Selection.init(start, end, false)) catch return false;
        screen.scroll(.{ .pin = start });
        self.needs_full_repaint = true;
        self.scheduleRefresh();
        return true;
    }

    pub fn searchClose(self: *TerminalView) void {
        if (self.search) |*search| {
            search.deinit();
            self.search = null;
            self.term.screens.active.clearSelection();
            self.needs_full_repaint = true;
            self.scheduleRefresh();
        }
    }

    pub fn grabFocus(self: *TerminalView) void {
        _ = self.area.as(gtk.Widget).grabFocus();
    }
};
