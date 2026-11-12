//! What can be done to a process, from the Processes and Details pages:
//! end it (or its whole tree), force it to quit, suspend and resume it,
//! efficiency mode, CPU and disk priority, which CPUs it may run on, its
//! properties; and running a new task.
//!
//! A user may lower the priority of their own programs; raising it, or
//! changing another user's program, needs administrator rights: then the
//! change is made through `renice`/`ionice`/`taskset` run as root, after
//! asking for the password (common.elevate).

const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

const sampler_mod = @import("sampler.zig");
const columns = @import("columns.zig");
const Sampler = sampler_mod.Sampler;

const t = common.tr;
const linux = std.os.linux;

extern fn kill(pid: c_int, sig: c_int) c_int;
extern fn setpriority(which: c_int, who: c_uint, prio: c_int) c_int;
extern fn __errno_location() *c_int;

pub const SIGTERM = 15;
pub const SIGKILL = 9;
pub const SIGSTOP = 19;
pub const SIGCONT = 18;

const IOPRIO_WHO_PROCESS = 1;
const IOPRIO_CLASS_SHIFT = 13;
pub const IoClass = enum(u3) { none = 0, realtime = 1, best_effort = 2, idle = 3 };

pub fn ioprio(class: IoClass, level: u3) usize {
    return (@as(usize, @intFromEnum(class)) << IOPRIO_CLASS_SHIFT) | level;
}

fn ioprioSet(pid: u32, value: usize) bool {
    const r = linux.syscall3(.ioprio_set, IOPRIO_WHO_PROCESS, pid, value);
    return linux.errno(r) == .SUCCESS;
}

pub fn ioprioGet(pid: u32) ?usize {
    const r = linux.syscall2(.ioprio_get, IOPRIO_WHO_PROCESS, pid);
    if (linux.errno(r) != .SUCCESS) return null;
    return r;
}

pub fn ioprioText(value: usize) []const u8 {
    const class = value >> IOPRIO_CLASS_SHIFT;
    return switch (class) {
        1 => "Realtime",
        3 => "Idle (background)",
        2 => switch (value & 7) {
            0, 1 => "High",
            2, 3 => "Above normal",
            4 => "Normal",
            5, 6 => "Below normal",
            else => "Low",
        },
        else => "Normal",
    };
}

pub const Actions = struct {
    gpa: std.mem.Allocator,
    window: *gtk.Window,
    sampler: *Sampler,
    /// Called after a change, so the lists show it at once.
    refreshed: *const fn (*anyopaque) void,
    owner: *anyopaque,
    pending_pid: u32 = 0,

    fn failed(self: *Actions, title: [:0]const u8, detail: [:0]const u8) void {
        common.dialogs.showError(self.window, title, detail);
    }

    fn name(self: *Actions, pid: u32) []const u8 {
        return if (self.sampler.processes.getPtr(pid)) |p| p.nameSlice() else "this process";
    }

    pub fn signal(self: *Actions, pid: u32, sig: c_int) void {
        if (kill(@intCast(pid), sig) != 0) {
            const e = __errno_location().*;
            if (e == 1) return self.asRoot(pid, &.{ "kill", sigName(sig) }, "End or pause another user's process");
            self.failed(t("Cannot do this to the process"), t("It may already have ended."));
            return;
        }
        self.refreshed(self.owner);
    }

    fn sigName(sig: c_int) []const u8 {
        return switch (sig) {
            SIGKILL => "-KILL",
            SIGSTOP => "-STOP",
            SIGCONT => "-CONT",
            else => "-TERM",
        };
    }

    /// Ends `pid` and everything it started, children first.
    pub fn endTree(self: *Actions, pid: u32) void {
        const all = self.sampler.tree(self.gpa, pid) catch return;
        defer self.gpa.free(all);
        var denied = false;
        for (all) |p| if (kill(@intCast(p), SIGTERM) != 0 and __errno_location().* == 1) {
            denied = true;
        };
        if (denied) self.failed(t("Some processes could not be ended"), t("They belong to another user. Ending them needs administrator rights."));
        self.refreshed(self.owner);
    }

    /// Asks first: unsaved work is lost.
    pub fn forceQuit(self: *Actions, pid: u32) void {
        var buf: [200]u8 = undefined;
        const message = std.fmt.bufPrintSentinel(&buf, "Force quit “{s}”?", .{self.name(pid)}, 0) catch return;
        self.pending_pid = pid;
        common.dialogs.choose(self.window, message, t("It ends at once, without saving. Unsaved work in it is lost."), &.{ t("Cancel"), t("Force Quit") }, 0, Actions, onForceAnswer, self);
    }

    fn onForceAnswer(self: *Actions, index: c_int) void {
        if (index == 1) self.signal(self.pending_pid, SIGKILL);
    }

    pub fn setPriority(self: *Actions, pid: u32, nice: c_int) void {
        if (setpriority(0, pid, nice) != 0) {
            var nb: [8]u8 = undefined;
            const n = std.fmt.bufPrint(&nb, "{d}", .{nice}) catch return;
            return self.asRoot(pid, &.{ "renice", "-n", n, "-p" }, "Raise a process's priority");
        }
        self.refreshed(self.owner);
    }

    pub fn setIoPriority(self: *Actions, pid: u32, class: IoClass, level: u3) void {
        if (!ioprioSet(pid, ioprio(class, level))) {
            var lb: [4]u8 = undefined;
            const c: []const u8 = switch (class) {
                .realtime => "1",
                .best_effort => "2",
                .idle => "3",
                .none => "0",
            };
            const l = std.fmt.bufPrint(&lb, "{d}", .{level}) catch return;
            if (class == .idle) return self.asRoot(pid, &.{ "ionice", "-c", c, "-p" }, "Change a process's disk priority");
            return self.asRoot(pid, &.{ "ionice", "-c", c, "-n", l, "-p" }, "Change a process's disk priority");
        }
        self.refreshed(self.owner);
    }

    /// Efficiency mode (as in Windows 11): the lowest CPU priority and idle
    /// disk priority; off again gives normal priority back.
    pub fn toggleEfficiency(self: *Actions, pid: u32) void {
        const p = self.sampler.processes.getPtr(pid) orelse return;
        if (p.efficient()) {
            _ = ioprioSet(pid, ioprio(.best_effort, 4));
            return self.setPriority(pid, 0);
        }
        _ = ioprioSet(pid, ioprio(.idle, 0));
        self.setPriority(pid, 19);
    }

    /// Runs `argv` and the pid as root, after asking for the password.
    fn asRoot(self: *Actions, pid: u32, argv: []const []const u8, reason: []const u8) void {
        var all: [8][]const u8 = undefined;
        @memcpy(all[0..argv.len], argv);
        var pb: [16]u8 = undefined;
        all[argv.len] = std.fmt.bufPrint(&pb, "{d}", .{pid}) catch return;
        if (!common.proc.hasProgram("sudo")) {
            return self.failed(t("This needs administrator rights"), t("You can lower the priority of your own programs, and end or pause them. Changing other users' programs, or raising a priority, needs administrator rights, and sudo is not installed."));
        }
        common.elevate.run(self.window, reason, all[0 .. argv.len + 1], "", Actions, onRootDone, self);
    }

    fn onRootDone(self: *Actions, outcome: common.elevate.Outcome, message: []const u8) void {
        if (outcome == .failed) {
            var buf: [300]u8 = undefined;
            self.failed(t("The change was not made"), std.fmt.bufPrintSentinel(&buf, "{s}", .{message}, 0) catch "");
        }
        self.refreshed(self.owner);
    }

    /// Shows the folder of the program in the file manager.
    pub fn openLocation(self: *Actions, pid: u32) void {
        const p = self.sampler.processes.getPtr(pid) orelse return;
        const path = p.pathSlice();
        const dir = std.fs.path.dirname(path) orelse "";
        if (dir.len == 0) return self.failed(t("Cannot open the file location"), t("The program file of this process is not known. It may belong to another user, or have no file."));
        common.appinfo.spawnIn(self.gpa, &.{ "dkde-files", dir }, dir);
    }

    // ---- CPU affinity -------------------------------------------------------------

    const Affinity = struct {
        actions: *Actions,
        pid: u32,
        window: *gtk.Window,
        checks: std.ArrayList(*gtk.CheckButton) = .empty,
    };

    /// Which CPUs the process may run on.
    pub fn affinity(self: *Actions, pid: u32) void {
        var set: linux.cpu_set_t = std.mem.zeroes(linux.cpu_set_t);
        if (linux.errno(linux.sched_getaffinity(@intCast(pid), @sizeOf(linux.cpu_set_t), &set)) != .SUCCESS) {
            return self.failed(t("Cannot read the process's CPUs"), t("It may already have ended."));
        }
        const st = self.gpa.create(Affinity) catch return;
        st.* = .{ .actions = self, .pid = pid, .window = gtk.Window.new() };
        const win = st.window;
        var title: [200]u8 = undefined;
        win.setTitle(std.fmt.bufPrintSentinel(&title, "Processor affinity: {s}", .{self.name(pid)}, 0) catch "Processor affinity");
        win.setTransientFor(self.window);
        win.setModal(1);
        win.as(gtk.Widget).addCssClass("dkde");
        const box = gtk.Box.new(.vertical, 8);
        inline for (.{ "setMarginStart", "setMarginEnd", "setMarginTop", "setMarginBottom" }) |m| @field(gtk.Widget, m)(box.as(gtk.Widget), 14);
        const intro = gtk.Label.new(t("Which processors may run this process?"));
        intro.setXalign(0);
        box.append(intro.as(gtk.Widget));
        const grid = gtk.FlowBox.new();
        grid.setMaxChildrenPerLine(8);
        grid.setSelectionMode(.none);
        for (0..self.sampler.cpu_count) |i| {
            var lb: [16]u8 = undefined;
            const c = gtk.CheckButton.newWithLabel(std.fmt.bufPrintSentinel(&lb, "CPU {d}", .{i}, 0) catch "CPU");
            const word = set[i / @bitSizeOf(usize)];
            c.setActive(@intFromBool((word >> @intCast(i % @bitSizeOf(usize))) & 1 == 1));
            st.checks.append(self.gpa, c) catch {};
            grid.append(c.as(gtk.Widget));
        }
        box.append(grid.as(gtk.Widget));
        const buttons = gtk.Box.new(.horizontal, 6);
        buttons.as(gtk.Widget).setHalign(.end);
        const all_b = gtk.Button.newWithLabel(t("All"));
        const cancel = gtk.Button.newWithLabel(t("Cancel"));
        const ok = gtk.Button.newWithLabel(t("OK"));
        ok.as(gtk.Widget).addCssClass("suggested-action");
        buttons.append(all_b.as(gtk.Widget));
        buttons.append(cancel.as(gtk.Widget));
        buttons.append(ok.as(gtk.Widget));
        box.append(buttons.as(gtk.Widget));
        win.setChild(box.as(gtk.Widget));
        _ = gtk.Button.signals.clicked.connect(all_b, *Affinity, &onAffinityAll, st, .{});
        _ = gtk.Button.signals.clicked.connect(cancel, *Affinity, &onAffinityCancel, st, .{});
        _ = gtk.Button.signals.clicked.connect(ok, *Affinity, &onAffinityOk, st, .{});
        _ = gtk.Widget.signals.destroy.connect(win, *Affinity, &onAffinityDestroy, st, .{});
        win.present();
    }

    fn onAffinityAll(_: *gtk.Button, st: *Affinity) callconv(.c) void {
        for (st.checks.items) |c| c.setActive(1);
    }

    fn onAffinityCancel(_: *gtk.Button, st: *Affinity) callconv(.c) void {
        st.window.destroy();
    }

    fn onAffinityOk(_: *gtk.Button, st: *Affinity) callconv(.c) void {
        var set: linux.cpu_set_t = std.mem.zeroes(linux.cpu_set_t);
        var any = false;
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(st.actions.gpa);
        for (st.checks.items, 0..) |c, i| if (c.getActive() != 0) {
            set[i / @bitSizeOf(usize)] |= @as(usize, 1) << @intCast(i % @bitSizeOf(usize));
            any = true;
            if (list.items.len > 0) list.append(st.actions.gpa, ',') catch {};
            list.print(st.actions.gpa, "{d}", .{i}) catch {};
        };
        if (!any) return common.dialogs.showError(st.window, t("Choose at least one processor"), null);
        const actions = st.actions;
        const pid = st.pid;
        st.window.destroy();
        if (linux.errno(linux.syscall3(.sched_setaffinity, pid, @sizeOf(linux.cpu_set_t), @intFromPtr(&set))) != .SUCCESS) {
            actions.asRoot(pid, &.{ "taskset", "-a", "-p", "-c", list.items }, "Change which processors a process runs on");
        }
    }

    fn onAffinityDestroy(_: *gtk.Window, st: *Affinity) callconv(.c) void {
        st.checks.deinit(st.actions.gpa);
        st.actions.gpa.destroy(st);
    }

    // ---- run a new task ------------------------------------------------------------------

    const RunTask = struct { actions: *Actions, window: *gtk.Window, entry: *gtk.Entry, admin: *gtk.CheckButton };

    /// Windows' "Run new task": a command, optionally as administrator.
    pub fn runNewTask(self: *Actions) void {
        const st = self.gpa.create(RunTask) catch return;
        st.* = .{ .actions = self, .window = gtk.Window.new(), .entry = gtk.Entry.new(), .admin = gtk.CheckButton.newWithLabel(t("Create this task with administrative privileges")) };
        const win = st.window;
        win.setTitle(t("Run new task"));
        win.setTransientFor(self.window);
        win.setModal(1);
        win.setResizable(0);
        win.setDefaultSize(440, -1);
        win.as(gtk.Widget).addCssClass("dkde");
        const box = gtk.Box.new(.vertical, 10);
        inline for (.{ "setMarginStart", "setMarginEnd", "setMarginTop", "setMarginBottom" }) |m| @field(gtk.Widget, m)(box.as(gtk.Widget), 14);
        const intro = gtk.Label.new(t("Type the name of a program, folder or file to open."));
        intro.setXalign(0);
        intro.setWrap(1);
        box.append(intro.as(gtk.Widget));
        const row = gtk.Box.new(.horizontal, 6);
        st.entry.as(gtk.Widget).setHexpand(1);
        st.entry.setActivatesDefault(1);
        row.append(st.entry.as(gtk.Widget));
        const browse = gtk.Button.newWithLabel(t("Browse…"));
        _ = gtk.Button.signals.clicked.connect(browse, *RunTask, &onBrowse, st, .{});
        row.append(browse.as(gtk.Widget));
        box.append(row.as(gtk.Widget));
        box.append(st.admin.as(gtk.Widget));
        const buttons = gtk.Box.new(.horizontal, 6);
        buttons.as(gtk.Widget).setHalign(.end);
        const cancel = gtk.Button.newWithLabel(t("Cancel"));
        const ok = gtk.Button.newWithLabel(t("OK"));
        ok.as(gtk.Widget).addCssClass("suggested-action");
        buttons.append(cancel.as(gtk.Widget));
        buttons.append(ok.as(gtk.Widget));
        box.append(buttons.as(gtk.Widget));
        win.setChild(box.as(gtk.Widget));
        win.setDefaultWidget(ok.as(gtk.Widget));
        _ = gtk.Button.signals.clicked.connect(cancel, *RunTask, &onRunCancel, st, .{});
        _ = gtk.Button.signals.clicked.connect(ok, *RunTask, &onRunOk, st, .{});
        _ = gtk.Widget.signals.destroy.connect(win, *RunTask, &onRunDestroy, st, .{});
        win.present();
    }

    fn onBrowse(_: *gtk.Button, st: *RunTask) callconv(.c) void {
        const dialog = gtk.FileDialog.new();
        defer dialog.as(gobject.Object).unref();
        dialog.open(st.window, null, onBrowsed, st);
    }

    fn onBrowsed(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const st: *RunTask = @ptrCast(@alignCast(data.?));
        const dialog: *gtk.FileDialog = @ptrCast(@alignCast(source.?));
        const file = dialog.openFinish(result, null) orelse return;
        defer file.as(gobject.Object).unref();
        const path = file.getPath() orelse return;
        defer glib.free(path);
        const quoted = glib.shellQuote(path);
        defer glib.free(quoted);
        st.entry.as(gtk.Editable).setText(quoted);
    }

    fn onRunCancel(_: *gtk.Button, st: *RunTask) callconv(.c) void {
        st.window.destroy();
    }

    fn onRunOk(_: *gtk.Button, st: *RunTask) callconv(.c) void {
        const text = std.mem.trim(u8, std.mem.span(st.entry.as(gtk.Editable).getText()), " ");
        if (text.len == 0) return;
        const actions = st.actions;
        var argc: c_int = 0;
        var argv: ?[*:null]?[*:0]u8 = null;
        var zb: [1024]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&zb, "{s}", .{text}, 0) catch return;
        if (glib.shellParseArgv(z, &argc, @ptrCast(&argv), null) == 0 or argc == 0) {
            return common.dialogs.showError(st.window, t("That is not a command the system can run"), null);
        }
        defer glib.strfreev(@ptrCast(argv));
        var args: [64][]const u8 = undefined;
        const n: usize = @intCast(@min(argc, 64));
        for (0..n) |i| args[i] = std.mem.span(argv.?[i].?);
        const as_admin = st.admin.getActive() != 0;
        // A folder or file (not a program) opens with its usual program.
        const first = args[0];
        if (n == 1 and !as_admin and glib.findProgramInPath(@ptrCast(z.ptr)) == null and common.fsio.exists(first)) {
            const file = gio.File.newForCommandlineArg(@ptrCast(z.ptr));
            defer file.as(gobject.Object).unref();
            const launcher = gtk.FileLauncher.new(file);
            defer launcher.as(gobject.Object).unref();
            launcher.launch(actions.window, null, null, null);
            st.window.destroy();
            return;
        }
        st.window.destroy();
        if (as_admin) {
            common.elevate.run(actions.window, "Run a program as administrator", args[0..n], "", Actions, onRootDone, actions);
        } else {
            common.appinfo.spawn(actions.gpa, args[0..n]);
        }
    }

    fn onRunDestroy(_: *gtk.Window, st: *RunTask) callconv(.c) void {
        st.actions.gpa.destroy(st);
    }

    // ---- properties ---------------------------------------------------------------------

    /// A window with what the system knows of the process: general facts,
    /// open files, environment, memory maps and limits.
    pub fn properties(self: *Actions, pid: u32) void {
        const p = self.sampler.processes.getPtr(pid) orelse return;
        const win = gtk.Window.new();
        var title: [200]u8 = undefined;
        win.setTitle(std.fmt.bufPrintSentinel(&title, "{s} ({d}) Properties", .{ p.nameSlice(), pid }, 0) catch "Properties");
        win.setTransientFor(self.window);
        win.setDefaultSize(620, 520);
        win.as(gtk.Widget).addCssClass("dkde");
        const notebook = gtk.Notebook.new();
        _ = notebook.appendPage(self.generalPage(p), gtk.Label.new(t("General")).as(gtk.Widget));
        _ = notebook.appendPage(textPage(self.gpa, openFiles(self.gpa, pid)), gtk.Label.new(t("Open files")).as(gtk.Widget));
        _ = notebook.appendPage(textPage(self.gpa, environment(self.gpa, pid)), gtk.Label.new(t("Environment")).as(gtk.Widget));
        _ = notebook.appendPage(textPage(self.gpa, memoryMaps(self.gpa, pid)), gtk.Label.new(t("Memory maps")).as(gtk.Widget));
        _ = notebook.appendPage(textPage(self.gpa, readOrNote(self.gpa, pid, "limits")), gtk.Label.new(t("Limits")).as(gtk.Widget));
        win.setChild(notebook.as(gtk.Widget));
        win.present();
    }

    fn generalPage(self: *Actions, p: *const sampler_mod.Process) *gtk.Widget {
        const a = self.gpa;
        const grid = gtk.Grid.new();
        grid.setColumnSpacing(14);
        grid.setRowSpacing(6);
        inline for (.{ "setMarginStart", "setMarginEnd", "setMarginTop", "setMarginBottom" }) |m| @field(gtk.Widget, m)(grid.as(gtk.Widget), 14);
        var row: c_int = 0;
        var b: [512]u8 = undefined;
        const s = self.sampler;
        const parent = if (s.processes.getPtr(p.ppid)) |pp| std.fmt.allocPrint(a, "{s} ({d})", .{ pp.nameSlice(), p.ppid }) catch "" else std.fmt.allocPrint(a, "{d}", .{p.ppid}) catch "";
        defer a.free(parent);
        const cwd = linkTarget(a, p.pid, "cwd");
        defer if (cwd) |c| a.free(c);
        const io = ioprioGet(p.pid);
        var aff_buf: [128]u8 = undefined;
        const aff = affinityText(&aff_buf, p.pid);
        var cb: [32]u8 = undefined;
        const fields = [_][2][]const u8{
            .{ "Name", p.nameSlice() },
            .{ "Process ID", std.fmt.bufPrint(b[0..16], "{d}", .{p.pid}) catch "" },
            .{ "Parent", parent },
            .{ "User", p.userSlice() },
            .{ "Runs as administrator", if (p.euid == 0) "Yes" else "No" },
            .{ "Status", if (columns.statusText(p).len > 0) columns.statusText(p) else "Sleeping" },
            .{ "Started", columns.text(b[16..80], s, p, .started) },
            .{ "CPU time", columns.text(b[80..112], s, p, .cpu_time) },
            .{ "Priority", columns.priorityText(b[112..160], p.nice) },
            .{ "Disk priority", if (io) |v| ioprioText(v) else "—" },
            .{ "Processors", aff },
            .{ "Memory (private)", columns.text(b[160..192], s, p, .memory) },
            .{ "Memory (resident)", std.fmt.bufPrint(b[192..224], "{d} kB", .{p.rss_kb}) catch "" },
            .{ "Swap", if (p.swap_kb > 0) columns.text(b[224..256], s, p, .swap) else "0" },
            .{ "Threads", std.fmt.bufPrint(&cb, "{d}", .{p.threads}) catch "" },
            .{ "Service", if (p.unit_len > 0) p.unitSlice() else "—" },
            .{ "Program file", if (p.path_len > 0) p.pathSlice() else "— (another user's, or none)" },
            .{ "Working folder", cwd orelse "—" },
            .{ "Command line", p.cmdSlice() },
        };
        for (fields) |f| {
            const k = gtk.Label.new(std.fmt.allocPrintSentinel(a, "{s}", .{f[0]}, 0) catch "");
            k.setXalign(1);
            k.setYalign(0);
            k.as(gtk.Widget).addCssClass("dim-label");
            const v = gtk.Label.new(std.fmt.allocPrintSentinel(a, "{s}", .{f[1]}, 0) catch "");
            v.setXalign(0);
            v.setSelectable(1);
            v.setWrap(1);
            v.setWrapMode(.word_char);
            v.setMaxWidthChars(60);
            v.as(gtk.Widget).setHexpand(1);
            grid.attach(k.as(gtk.Widget), 0, row, 1, 1);
            grid.attach(v.as(gtk.Widget), 1, row, 1, 1);
            row += 1;
        }
        const scroller = gtk.ScrolledWindow.new();
        scroller.setChild(grid.as(gtk.Widget));
        return scroller.as(gtk.Widget);
    }
};

fn affinityText(buf: []u8, pid: u32) []const u8 {
    var set: linux.cpu_set_t = std.mem.zeroes(linux.cpu_set_t);
    if (linux.errno(linux.sched_getaffinity(@intCast(pid), @sizeOf(linux.cpu_set_t), &set)) != .SUCCESS) return "—";
    var w: std.Io.Writer = .fixed(buf);
    var first = true;
    var i: usize = 0;
    const total = @bitSizeOf(linux.cpu_set_t);
    while (i < total) : (i += 1) {
        if ((set[i / @bitSizeOf(usize)] >> @intCast(i % @bitSizeOf(usize))) & 1 == 0) continue;
        // Runs of CPUs as ranges: 0-11.
        var j = i;
        while (j + 1 < total and (set[(j + 1) / @bitSizeOf(usize)] >> @intCast((j + 1) % @bitSizeOf(usize))) & 1 == 1) j += 1;
        if (!first) w.writeAll(", ") catch break;
        first = false;
        if (j > i) w.print("{d}–{d}", .{ i, j }) catch break else w.print("{d}", .{i}) catch break;
        i = j;
    }
    return w.buffered();
}

fn linkTarget(gpa: std.mem.Allocator, pid: u32, what: []const u8) ?[]u8 {
    var pb: [64]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&pb, "/proc/{d}/{s}", .{ pid, what }, 0) catch return null;
    const target = glib.fileReadLink(path, null) orelse return null;
    defer glib.free(target);
    return gpa.dupe(u8, std.mem.span(target)) catch null;
}

fn readOrNote(gpa: std.mem.Allocator, pid: u32, what: []const u8) []u8 {
    var pb: [64]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&pb, "/proc/{d}/{s}", .{ pid, what }, 0) catch return gpa.dupe(u8, "") catch &.{};
    return Sampler.readFile(gpa, path) orelse (gpa.dupe(u8, "Only the process's owner (or an administrator) can see this.") catch &.{});
}

/// What each open descriptor points to.
fn openFiles(gpa: std.mem.Allocator, pid: u32) []u8 {
    var out: std.ArrayList(u8) = .empty;
    var pb: [64]u8 = undefined;
    const dir_path = std.fmt.bufPrintSentinel(&pb, "/proc/{d}/fd", .{pid}, 0) catch return out.items;
    const dir = gio.File.newForPath(dir_path);
    defer dir.as(gobject.Object).unref();
    const children = dir.enumerateChildren("standard::name", .{ .nofollow_symlinks = true }, null, null) orelse
        return gpa.dupe(u8, "Only the process's owner (or an administrator) can see this.") catch &.{};
    defer children.as(gobject.Object).unref();
    var lines: std.ArrayList([]u8) = .empty;
    defer {
        for (lines.items) |l| gpa.free(l);
        lines.deinit(gpa);
    }
    while (children.nextFile(null, null)) |info| {
        defer info.as(gobject.Object).unref();
        const fd_name = std.mem.span(info.getName());
        var lb: [96]u8 = undefined;
        const link = std.fmt.bufPrintSentinel(&lb, "{s}/{s}", .{ dir_path, fd_name }, 0) catch continue;
        const target = glib.fileReadLink(link, null);
        defer if (target) |x| glib.free(x);
        const line = std.fmt.allocPrint(gpa, "{s:>5}  {s}", .{ fd_name, if (target) |x| std.mem.span(x) else "?" }) catch continue;
        lines.append(gpa, line) catch gpa.free(line);
    }
    std.mem.sort([]u8, lines.items, {}, struct {
        fn lt(_: void, x: []u8, y: []u8) bool {
            const xa = std.fmt.parseInt(u32, std.mem.trim(u8, x[0..5], " "), 10) catch 0;
            const ya = std.fmt.parseInt(u32, std.mem.trim(u8, y[0..5], " "), 10) catch 0;
            return xa < ya;
        }
    }.lt);
    out.print(gpa, "{d} open\n\n", .{lines.items.len}) catch {};
    for (lines.items) |l| out.print(gpa, "{s}\n", .{l}) catch {};
    return out.toOwnedSlice(gpa) catch &.{};
}

fn environment(gpa: std.mem.Allocator, pid: u32) []u8 {
    const raw = readOrNote(gpa, pid, "environ");
    // NUL-separated: one variable per line.
    for (raw) |*c| if (c.* == 0) {
        c.* = '\n';
    };
    return raw;
}

/// The memory a process has mapped, summed per file: libraries, the
/// program, the heap and stack.
fn memoryMaps(gpa: std.mem.Allocator, pid: u32) []u8 {
    var pb: [64]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&pb, "/proc/{d}/maps", .{pid}, 0) catch return gpa.dupe(u8, "") catch &.{};
    const text = Sampler.readFile(gpa, path) orelse return gpa.dupe(u8, "Only the process's owner (or an administrator) can see this.") catch &.{};
    defer gpa.free(text);
    var sizes: std.StringArrayHashMapUnmanaged(u64) = .empty;
    defer sizes.deinit(gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const range = it.next() orelse continue;
        const dash = std.mem.indexOfScalar(u8, range, '-') orelse continue;
        const lo = std.fmt.parseInt(u64, range[0..dash], 16) catch continue;
        const hi = std.fmt.parseInt(u64, range[dash + 1 ..], 16) catch continue;
        inline for (0..4) |_| _ = it.next();
        const name = it.rest();
        const key = if (std.mem.trim(u8, name, " ").len == 0) "[anonymous]" else std.mem.trim(u8, name, " ");
        const e = sizes.getOrPut(gpa, key) catch continue;
        if (!e.found_existing) e.value_ptr.* = 0;
        e.value_ptr.* += hi - lo;
    }
    const Ctx = struct {
        values: []u64,
        pub fn lessThan(c: @This(), x: usize, y: usize) bool {
            return c.values[x] > c.values[y];
        }
    };
    sizes.sort(Ctx{ .values = sizes.values() });
    var out: std.ArrayList(u8) = .empty;
    out.print(gpa, "{s:>12}  {s}\n", .{ "Size", "Mapped" }) catch {};
    for (sizes.keys(), sizes.values()) |k, v| out.print(gpa, "{d:>9} kB  {s}\n", .{ v / 1024, k }) catch {};
    return out.toOwnedSlice(gpa) catch &.{};
}

fn textPage(gpa: std.mem.Allocator, owned: []u8) *gtk.Widget {
    defer gpa.free(owned);
    const view = gtk.TextView.new();
    view.setEditable(0);
    view.setMonospace(1);
    view.setLeftMargin(10);
    view.setTopMargin(8);
    const z = gpa.dupeSentinel(u8, owned, 0) catch return view.as(gtk.Widget);
    defer gpa.free(z);
    // Not valid UTF-8 (an odd environment): shown escaped rather than refused.
    if (glib.utf8Validate(z.ptr, @intCast(z.len), null) != 0) {
        view.getBuffer().setText(z, -1);
    } else {
        const fixed = glib.utf8MakeValid(z.ptr, @intCast(z.len));
        defer glib.free(fixed);
        view.getBuffer().setText(fixed, -1);
    }
    const scroller = gtk.ScrolledWindow.new();
    scroller.setChild(view.as(gtk.Widget));
    return scroller.as(gtk.Widget);
}
