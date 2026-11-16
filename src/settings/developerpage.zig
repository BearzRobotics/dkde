//! The "For developers" page: logging for dkde's own programs, the GTK inspector and a diagnostics report.
//! Everything here affects dkde programs only. The choices live in `developer.toml` ([developer]); dkde
//! programs started afterwards read them (see common/log.zig), and the environment still wins over the file.

const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");
const build_options = @import("build_options");

const win = @import("window.zig");
const SettingsWindow = win.SettingsWindow;

const gpa = std.heap.c_allocator;
const t = common.tr;

const level_keys = [_][:0]const u8{ "default", "error", "warn", "info", "debug" };

pub const DeveloperPage = struct {
    window: *SettingsWindow,
    config: common.Config,
    status: *gtk.Label,

    pub fn build(window: *SettingsWindow) *gtk.Box {
        const page = SettingsWindow.newPage(t("For developers"));
        const self = gpa.create(DeveloperPage) catch @panic("OOM");
        self.* = .{ .window = window, .config = common.Config.load(gpa, "developer.toml") catch @panic("OOM"), .status = gtk.Label.new("") };

        const note = gtk.Label.new(t("These options are for people working on DKDE. They affect only DKDE programs, and only the ones started after a change."));
        note.setWrap(1);
        note.setXalign(0);
        note.as(gtk.Widget).addCssClass("dim-label");
        page.append(note.as(gtk.Widget));

        // Logging.
        const levels = [_]?[*:0]const u8{ "Default (warnings and errors)", "Errors only", "Warnings", "Information", "Debug (everything)", null };
        const level = gtk.DropDown.newFromStrings(@ptrCast(&levels));
        const current = self.config.getString(gpa, "developer", "log-level", "default") catch null;
        defer if (current) |c| gpa.free(c);
        for (level_keys, 0..) |k, i| if (std.mem.eql(u8, current orelse "default", k)) level.setSelected(@intCast(i));
        _ = gobject.Object.signals.notify.connect(level, *DeveloperPage, &onLevel, self, .{ .detail = "selected" });
        SettingsWindow.addRowDesc(page, t("Log level"), t("How much DKDE programs say. Lines go to the program's error output, which a terminal shows."), level.as(gtk.Widget));

        const files = gtk.Switch.new();
        files.setActive(@intFromBool(self.config.getBool("developer", "log-files", false)));
        _ = gtk.Switch.signals.state_set.connect(files, *DeveloperPage, &onFiles, self, .{});
        var dir_buf: [400]u8 = undefined;
        const dir_text = std.fmt.bufPrintSentinel(&dir_buf, "Write each program's log to {s}/<program>.log, so it survives when the program was not started from a terminal.", .{logDir()}, 0) catch "";
        SettingsWindow.addRowDesc(page, t("Keep log files"), dir_text, files.as(gtk.Widget));

        const glib_debug = gtk.Switch.new();
        glib_debug.setActive(@intFromBool(self.config.getBool("developer", "glib-debug", false)));
        _ = gtk.Switch.signals.state_set.connect(glib_debug, *DeveloperPage, &onGlibDebug, self, .{});
        SettingsWindow.addRowDesc(page, t("Show GTK and GLib debug messages"), t("Adds the toolkit's own diagnostics to the log (G_MESSAGES_DEBUG=all). Noisy."), glib_debug.as(gtk.Widget));

        // The inspector.
        if (inspectorSettings()) |settings| {
            const inspector = gtk.Switch.new();
            inspector.setActive(@intFromBool(settings.getBoolean("enable-inspector-keybinding") != 0));
            _ = gtk.Switch.signals.state_set.connect(inspector, *DeveloperPage, &onInspector, self, .{});
            SettingsWindow.addRowDesc(page, t("GTK inspector shortcut"), t("Ctrl+Shift+I (or Ctrl+Shift+D) opens the inspector in any DKDE program: widget tree, CSS and properties. This is GTK's own setting, so other GTK programs get it too."), inspector.as(gtk.Widget));
            settings.as(gobject.Object).unref();
        }

        // Tools.
        const row = gtk.Box.new(.horizontal, 8);
        const open_dir = gtk.Button.newWithLabel(t("Open log folder"));
        _ = gtk.Button.signals.clicked.connect(open_dir, *DeveloperPage, &onOpenLogs, self, .{});
        const clear = gtk.Button.newWithLabel(t("Delete log files"));
        _ = gtk.Button.signals.clicked.connect(clear, *DeveloperPage, &onClearLogs, self, .{});
        const copy = gtk.Button.newWithLabel(t("Copy diagnostics"));
        copy.as(gtk.Widget).setTooltipText(t("Version, session, display server, backends and these settings, for a bug report"));
        _ = gtk.Button.signals.clicked.connect(copy, *DeveloperPage, &onCopy, self, .{});
        row.append(open_dir.as(gtk.Widget));
        row.append(clear.as(gtk.Widget));
        row.append(copy.as(gtk.Widget));
        page.append(row.as(gtk.Widget));
        self.status.setXalign(0);
        self.status.setWrap(1);
        self.status.as(gtk.Widget).addCssClass("dim-label");
        page.append(self.status.as(gtk.Widget));
        return page;
    }

    fn logDir() []const u8 {
        const S = struct {
            var buf: [400]u8 = undefined;
        };
        return std.fmt.bufPrint(&S.buf, "{s}/dkde", .{std.mem.span(glib.getUserStateDir())}) catch "~/.local/state/dkde";
    }

    fn inspectorSettings() ?*gio.Settings {
        const source = gio.SettingsSchemaSource.getDefault() orelse return null;
        const schema = source.lookup("org.gtk.gtk4.Settings.Debug", 1) orelse return null;
        schema.unref();
        return gio.Settings.new("org.gtk.gtk4.Settings.Debug");
    }

    fn say(self: *DeveloperPage, text: []const u8) void {
        var buf: [300]u8 = undefined;
        self.status.setText(std.fmt.bufPrintSentinel(&buf, "{s}", .{text}, 0) catch "");
    }

    fn onLevel(dd: *gtk.DropDown, _: *gobject.ParamSpec, self: *DeveloperPage) callconv(.c) void {
        const i = dd.getSelected();
        if (i >= level_keys.len) return;
        self.config.setString("developer", "log-level", level_keys[i]) catch {};
        self.say("Saved. Programs started from now on use it.");
    }

    fn onFiles(_: *gtk.Switch, state: c_int, self: *DeveloperPage) callconv(.c) c_int {
        self.config.setBool("developer", "log-files", state != 0) catch {};
        return 0;
    }

    fn onGlibDebug(_: *gtk.Switch, state: c_int, self: *DeveloperPage) callconv(.c) c_int {
        self.config.setBool("developer", "glib-debug", state != 0) catch {};
        return 0;
    }

    fn onInspector(_: *gtk.Switch, state: c_int, self: *DeveloperPage) callconv(.c) c_int {
        const settings = inspectorSettings() orelse return 0;
        defer settings.as(gobject.Object).unref();
        _ = settings.setBoolean("enable-inspector-keybinding", @intFromBool(state != 0));
        gio.Settings.sync();
        self.say("Saved.");
        return 0;
    }

    fn onOpenLogs(_: *gtk.Button, self: *DeveloperPage) callconv(.c) void {
        _ = glib.mkdirWithParents(logDirZ(), 0o755);
        var buf: [460]u8 = undefined;
        const uri = std.fmt.bufPrintSentinel(&buf, "file://{s}", .{logDir()}, 0) catch return;
        var err: ?*glib.Error = null;
        if (gio.AppInfo.launchDefaultForUri(uri, null, &err) == 0) {
            self.say("No program is set to open folders. Default apps in Settings chooses one.");
            if (err) |e| e.free();
        }
    }

    fn onClearLogs(_: *gtk.Button, self: *DeveloperPage) callconv(.c) void {
        var removed: usize = 0;
        const folder = gio.File.newForPath(logDirZ());
        defer folder.as(gobject.Object).unref();
        const list = folder.enumerateChildren("standard::name", .{}, null, null) orelse return self.say("There are no log files.");
        defer list.as(gobject.Object).unref();
        while (list.nextFile(null, null)) |info| {
            defer info.as(gobject.Object).unref();
            const n = std.mem.span(info.getName());
            if (!std.mem.endsWith(u8, n, ".log")) continue;
            var buf: [600]u8 = undefined;
            const path = std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ logDir(), n }, 0) catch continue;
            if (glib.unlink(path) == 0) removed += 1;
        }
        var msg: [80]u8 = undefined;
        self.say(std.fmt.bufPrint(&msg, "Deleted {d} log file{s}.", .{ removed, if (removed == 1) "" else "s" }) catch "Done.");
    }

    fn logDirZ() [:0]const u8 {
        const S = struct {
            var buf: [400]u8 = undefined;
        };
        return std.fmt.bufPrintSentinel(&S.buf, "{s}/dkde", .{std.mem.span(glib.getUserStateDir())}, 0) catch "";
    }

    fn onCopy(_: *gtk.Button, self: *DeveloperPage) callconv(.c) void {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(gpa);
        const env = struct {
            fn get(name: [:0]const u8) []const u8 {
                return if (glib.getenv(name)) |v| std.mem.span(v) else "(not set)";
            }
        };
        text.print(gpa, "dkde {s}\nsession: {s}\nWAYLAND_DISPLAY: {s}\nDISPLAY: {s}\nXDG_CURRENT_DESKTOP: {s}\nXDG_SESSION_TYPE: {s}\n", .{
            build_options.version,
            @tagName(common.session.kind()),
            env.get("WAYLAND_DISPLAY"),
            env.get("DISPLAY"),
            env.get("XDG_CURRENT_DESKTOP"),
            env.get("XDG_SESSION_TYPE"),
        }) catch return;
        const level = self.config.getString(gpa, "developer", "log-level", "default") catch null;
        defer if (level) |l| gpa.free(l);
        text.print(gpa, "log level: {s}, log files: {}, GLib debug: {}\nlog folder: {s}\n", .{
            level orelse "default",
            self.config.getBool("developer", "log-files", false),
            self.config.getBool("developer", "glib-debug", false),
            logDir(),
        }) catch return;
        for ([_][:0]const u8{ "DKDE_LOG", "DKDE_LOG_FILE", "DKDE_SESSION_COMPOSITOR", "DKDE_DATA_DIR", "GDK_BACKEND", "GTK_THEME" }) |name| {
            if (glib.getenv(name)) |v| text.print(gpa, "{s}={s}\n", .{ name, std.mem.span(v) }) catch {};
        }
        const z = gpa.dupeSentinel(u8, text.items, 0) catch return;
        defer gpa.free(z);
        self.window.window.as(gtk.Widget).getClipboard().setText(z);
        self.say("Copied.");
    }
};
