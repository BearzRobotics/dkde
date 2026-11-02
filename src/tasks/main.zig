//! dkde-tasks: Task Manager (SPEC.md 5.6). Processes come from /proc.

const std = @import("std");
const gdk = @import("gdk4");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const cairo = @import("cairo1");
const gtk = @import("gtk4");
const common = @import("common");

const proc = @import("proc.zig");
const perfview = @import("perfview.zig");
const perf = @import("perf.zig");

extern fn kill(pid: c_int, sig: c_int) c_int;
extern fn setpriority(which: c_int, who: c_uint, prio: c_int) c_int;
extern fn sysconf(name: c_int) c_long;
extern fn __errno_location() *c_int;
const SC_CLK_TCK = 2;
const SC_PAGESIZE = 30;
const SC_NPROCESSORS_ONLN = 84;
const SIGTERM = 15;
const SIGKILL = 9;

const App = struct {
    allocator: std.mem.Allocator,
    appearance: ?*common.style.Appearance = null,
    /// Tab to open first, from `--tab processes|performance`.
    tab: c_int = 0,
    /// Performance resource to show first, from `--resource cpu|memory|sda|eth0|card0`.
    resource: ?[:0]const u8 = null,

    fn activate(app: *gtk.Application, self: *App) callconv(.c) void {
        common.style.load(self.allocator) catch |err|
            std.log.warn("stylesheet not loaded: {s}", .{@errorName(err)});
        self.appearance = common.style.Appearance.create(self.allocator) catch null;
        const manager = TaskManager.create(self.allocator, app) catch |err| {
            std.log.err("cannot create the window: {s}", .{@errorName(err)});
            return;
        };
        manager.notebook.setCurrentPage(self.tab);
        if (self.resource) |r| manager.perf.select(r);
        manager.window.as(gtk.Window).present();
    }
};

const Process = struct {
    pid: u32,
    name: [64]u8 = undefined,
    name_len: usize = 0,
    user: [32]u8 = undefined,
    user_len: usize = 0,
    state: u8 = '?',
    ticks: u64 = 0,
    prev_ticks: u64 = 0,
    cpu: f64 = 0,
    rss_kb: u64 = 0,
    threads: u32 = 0,
    seen: bool = false,
    nice: i32 = 0,
    /// Bytes per second to and from storage; `io` says whether it can be known.
    disk_rate: f64 = 0,
    prev_io: u64 = 0,
    io: enum { unknown, ok, denied } = .unknown,
    /// The kernel's name, to notice a program changing identity (exec).
    comm: [16]u8 = undefined,
    comm_len: usize = 0,
    /// Where the program file is, when this user may ask.
    path: [192]u8 = undefined,
    path_len: usize = 0,
    cmd: [192]u8 = undefined,
    cmd_len: usize = 0,

    fn nameSlice(self: *const Process) []const u8 {
        return self.name[0..self.name_len];
    }
    fn pathSlice(self: *const Process) []const u8 {
        return self.path[0..self.path_len];
    }
    fn cmdSlice(self: *const Process) []const u8 {
        return self.cmd[0..self.cmd_len];
    }
};

const Column = enum { name, pid, user, status, cpu, memory, disk, threads, priority, command };
const columns = [_]Column{ .name, .pid, .user, .status, .cpu, .memory, .disk, .threads, .priority, .command };
const SortBy = Column;
const column_titles = [_][:0]const u8{ "Name", "PID", "User", "Status", "CPU %", "Memory", "Disk", "Threads", "Priority", "Command" };
/// Shown the first time; the View menu turns the others on.
const default_visible = [_]Column{ .name, .pid, .user, .cpu, .memory, .disk, .threads };

fn columnName(c: Column) [:0]const u8 {
    return @tagName(c);
}

/// Numbers that matter most list the biggest first when a header is clicked.
fn bigFirst(c: Column) bool {
    return switch (c) {
        .cpu, .memory, .disk, .threads => true,
        else => false,
    };
}

/// The Windows names for nice values: root may go above Normal, anyone below.
const priorities = [_]struct { label: [:0]const u8, nice: c_int }{
    .{ .label = "High", .nice = -10 },
    .{ .label = "Above normal", .nice = -5 },
    .{ .label = "Normal", .nice = 0 },
    .{ .label = "Below normal", .nice = 5 },
    .{ .label = "Low", .nice = 15 },
};

fn priorityText(buf: []u8, nice: i32) []const u8 {
    const name: []const u8 = if (nice <= -10) "High" else if (nice < 0) "Above normal" else if (nice == 0) "Normal" else if (nice < 10) "Below normal" else "Low";
    return std.fmt.bufPrint(buf, "{s} ({d})", .{ name, nice }) catch name;
}

fn statusText(state: u8) []const u8 {
    return switch (state) {
        'R' => "Running",
        'S' => "Sleeping",
        'D' => "Disk wait",
        'I' => "Idle",
        'T', 't' => "Stopped",
        'Z' => "Zombie",
        else => "—",
    };
}

const TaskManager = struct {
    allocator: std.mem.Allocator,
    window: *gtk.ApplicationWindow,
    list: *gtk.StringList,
    selection: *gtk.SingleSelection,
    /// The table; context menus attach here because rows are rebuilt on every refresh.
    table: ?*gtk.ColumnView = null,
    summary: *gtk.Label,
    perf: *perfview.Perf,
    notebook: *gtk.Notebook = undefined,
    search: *gtk.SearchEntry,
    /// Lower-cased search text; empty shows everything.
    query: [64]u8 = undefined,
    query_len: usize = 0,

    processes: std.AutoHashMapUnmanaged(u32, Process) = .empty,
    /// Pids in display order; mirrors `list`.
    order: std.ArrayList(u32) = .empty,
    sort_by: SortBy = .cpu,
    /// Header clicks can flip the natural order (CPU and memory: biggest first).
    sort_reverse: bool = false,
    sort_columns: [columns.len]?*gtk.ColumnViewColumn = @splat(null),
    col_visible: [columns.len]bool = @splat(false),
    prev_us: i64 = 0,
    prev_cpu: ?proc.CpuTimes = null,
    cpu_count: usize = 1,
    clock_ticks: f64 = 100,
    page_kb: u64 = 4,
    passwd: ?[]u8 = null,
    timer: c_uint = 0,

    fn create(allocator: std.mem.Allocator, app: *gtk.Application) !*TaskManager {
        const self = try allocator.create(TaskManager);
        errdefer allocator.destroy(self);

        const list = gtk.StringList.new(null);
        self.* = .{
            .allocator = allocator,
            .window = gtk.ApplicationWindow.new(app),
            .list = list,
            .selection = gtk.SingleSelection.new(list.as(gio.ListModel)),
            .summary = gtk.Label.new(""),
            .perf = perfview.Perf.create(allocator),
            .search = gtk.SearchEntry.new(),
            .cpu_count = @intCast(@max(1, sysconf(SC_NPROCESSORS_ONLN))),
            .clock_ticks = @floatFromInt(@max(1, sysconf(SC_CLK_TCK))),
            .page_kb = @intCast(@max(1, @divTrunc(sysconf(SC_PAGESIZE), 1024))),
        };
        self.selection.setAutoselect(0);
        self.selection.setCanUnselect(1);

        var contents: [*]u8 = undefined;
        var length: usize = 0;
        if (glib.fileGetContents("/etc/passwd", &contents, &length, null) != 0) {
            defer glib.free(contents);
            self.passwd = allocator.dupe(u8, contents[0..length]) catch null;
        }

        const window = self.window;
        window.as(gtk.Window).setTitle(common.tr("Task Manager"));
        window.as(gtk.Window).setDefaultSize(900, 660);
        window.as(gtk.Widget).addCssClass("dkde");

        _ = common.header.create(window.as(gtk.Window), "utilities-system-monitor", true);

        self.loadColumns();
        const mb = common.menubar;
        const view_entries = blk: {
            var entries: [5 + columns.len - 1]mb.Entry = undefined;
            entries[0] = mb.item("Sort by _CPU", "sort-cpu", null);
            entries[1] = mb.item("Sort by _Memory", "sort-memory", null);
            entries[2] = mb.item("Sort by _Name", "sort-name", null);
            entries[3] = mb.item("Sort by _PID", "sort-pid", null);
            entries[4] = .separator;
            // The name column always shows; the others can be turned on and off.
            inline for (columns[1..], 0..) |c, i| {
                entries[5 + i] = mb.check("Show " ++ column_titles[i + 1], "col-" ++ @tagName(c), self.col_visible[i + 1]);
            }
            break :blk entries;
        };
        const menus = [_]mb.Menu{
            .{ .label = "_File", .entries = &.{
                mb.item("_End Task", "end", "Delete"),
                mb.item("_Force Quit…", "force", null),
                .separator,
                mb.item("E_xit", "close", "<Control>q"),
            } },
            .{ .label = "_View", .entries = &view_entries },
        };
        const menu_bar = mb.build(app, window, &menus, TaskManager, onMenuAction, self);

        // Toolbar with search and End Task.
        const toolbar = gtk.Box.new(.horizontal, 8);
        toolbar.as(gtk.Widget).setMarginStart(12);
        toolbar.as(gtk.Widget).setMarginEnd(12);
        toolbar.as(gtk.Widget).setMarginTop(6);
        toolbar.as(gtk.Widget).setMarginBottom(6);
        self.search.setPlaceholderText(common.tr("Search processes"));
        self.search.as(gtk.Widget).setHexpand(1);
        _ = gtk.SearchEntry.signals.search_changed.connect(self.search, *TaskManager, &onSearchChanged, self, .{});
        toolbar.append(self.search.as(gtk.Widget));

        // Process table.
        const view = gtk.ColumnView.new(self.selection.as(gtk.SelectionModel));
        self.table = view;
        view.as(gtk.Widget).setVexpand(1);
        view.as(gtk.Widget).addCssClass("dkde-process-table");
        inline for (columns, 0..) |kind, i| {
            const factory = gtk.SignalListItemFactory.new();
            _ = gtk.SignalListItemFactory.signals.setup.connect(factory, *TaskManager, &onSetup, self, .{});
            _ = gtk.SignalListItemFactory.signals.bind.connect(factory, *TaskManager, &onBindFor(kind), self, .{});
            const column = gtk.ColumnViewColumn.new(common.tr(column_titles[i]), factory.as(gtk.ListItemFactory));
            column.setVisible(@intFromBool(self.col_visible[i]));
            column.setResizable(1);
            column.setExpand(@intFromBool(kind == .name));
            // Clicking a header sorts by it; the list itself is ordered in `less`.
            column.setSorter(gtk.CustomSorter.new(null, null, null).as(gtk.Sorter));
            self.sort_columns[i] = column;
            view.appendColumn(column);
        }
        if (view.getSorter()) |sorter| _ = gtk.Sorter.signals.changed.connect(sorter, *TaskManager, &onSortChanged, self, .{});
        if (self.sort_columns[@intFromEnum(Column.cpu)]) |cpu_column| view.sortByColumn(cpu_column, .descending);
        const scroller = gtk.ScrolledWindow.new();
        scroller.setChild(view.as(gtk.Widget));
        scroller.as(gtk.Widget).setVexpand(1);

        self.summary.setXalign(0);
        self.summary.as(gtk.Widget).setMarginStart(8);
        self.summary.as(gtk.Widget).addCssClass("dim-label");

        // Bottom row: process count and the End Task buttons, as in Windows.
        const bottom = gtk.Box.new(.horizontal, 6);
        bottom.as(gtk.Widget).setMarginStart(8);
        bottom.as(gtk.Widget).setMarginEnd(8);
        bottom.as(gtk.Widget).setMarginTop(4);
        bottom.as(gtk.Widget).setMarginBottom(6);
        self.summary.as(gtk.Widget).setHexpand(1);
        bottom.append(self.summary.as(gtk.Widget));
        const force = gtk.Button.newWithLabel(common.tr("Force Quit"));
        force.as(gtk.Widget).addCssClass("destructive-action");
        _ = gtk.Button.signals.clicked.connect(force, *TaskManager, &onForceClicked, self, .{});
        const end = gtk.Button.newWithLabel(common.tr("End Task"));
        _ = gtk.Button.signals.clicked.connect(end, *TaskManager, &onEndClicked, self, .{});
        end.as(gtk.Widget).addCssClass("suggested-action");
        toolbar.append(end.as(gtk.Widget));
        toolbar.append(force.as(gtk.Widget));

        const root = gtk.Box.new(.vertical, 0);
        root.append(toolbar.as(gtk.Widget));
        root.append(scroller.as(gtk.Widget));
        root.append(bottom.as(gtk.Widget));

        // Two tabs, as in Windows: the process table and the Performance page.
        const notebook = gtk.Notebook.new();
        self.notebook = notebook;
        notebook.as(gtk.Widget).setVexpand(1);
        _ = notebook.appendPage(root.as(gtk.Widget), gtk.Label.new(common.tr("Processes")).as(gtk.Widget));
        _ = notebook.appendPage(self.perf.widget, gtk.Label.new(common.tr("Performance")).as(gtk.Widget));
        _ = gtk.Notebook.signals.switch_page.connect(notebook, *TaskManager, &onSwitchPage, self, .{});
        const outer = gtk.Box.new(.vertical, 0);
        outer.append(menu_bar.as(gtk.Widget));
        outer.append(notebook.as(gtk.Widget));
        window.as(gtk.Window).setChild(outer.as(gtk.Widget));

        // Delete ends the selected task; Escape closes.
        const keys = gtk.EventControllerKey.new();
        keys.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *TaskManager, &onKey, self, .{});
        window.as(gtk.Widget).addController(keys.as(gtk.EventController));

        _ = gtk.Widget.signals.destroy.connect(window, *TaskManager, &onDestroy, self, .{});
        self.refresh();
        self.timer = glib.timeoutAdd(1500, onTimer, self);
        return self;
    }

    /// Which columns show, from the state file (SPEC.md 6.1: what a program
    /// remembers as it runs is state, not configuration).
    fn loadColumns(self: *TaskManager) void {
        var saved = common.state.loadList(self.allocator, "tasks.state", "columns", "visible") catch std.ArrayList([]u8).empty;
        defer common.state.freeList(self.allocator, &saved);
        for (columns, 0..) |c, i| {
            if (saved.items.len == 0) {
                self.col_visible[i] = std.mem.indexOfScalar(Column, &default_visible, c) != null;
            } else {
                for (saved.items) |name| {
                    if (std.mem.eql(u8, name, @tagName(c))) self.col_visible[i] = true;
                }
            }
        }
        self.col_visible[0] = true;
    }

    fn saveColumns(self: *TaskManager) void {
        var names: std.ArrayList([]u8) = .empty;
        defer names.deinit(self.allocator);
        for (columns, 0..) |c, i| {
            if (self.col_visible[i]) names.append(self.allocator, @constCast(@tagName(c))) catch return;
        }
        common.state.saveList(self.allocator, "tasks.state", "columns", "visible", names.items) catch |err|
            std.log.warn("cannot save the column choice: {s}", .{@errorName(err)});
    }

    /// Whether the process list can be seen: its tab is the open one and the
    /// window is not minimized.
    fn listVisible(self: *TaskManager) bool {
        if (self.notebook.getCurrentPage() != 0) return false;
        if (self.window.as(gtk.Native).getSurface()) |surface| {
            const toplevel: *gdk.Toplevel = @ptrCast(surface);
            if (toplevel.getState().minimized) return false;
        }
        return true;
    }

    fn onSwitchPage(_: *gtk.Notebook, _: *gtk.Widget, _: c_uint, self: *TaskManager) callconv(.c) void {
        // The signal comes before the page changes: look again when the main loop is idle.
        _ = glib.idleAdd(onShownIdle, self);
    }

    fn onShownIdle(data: ?*anyopaque) callconv(.c) c_int {
        const self: *TaskManager = @ptrCast(@alignCast(data.?));
        if (self.listVisible()) self.rebuildList();
        return 0;
    }

    fn onDestroy(_: *gtk.ApplicationWindow, self: *TaskManager) callconv(.c) void {
        if (self.timer != 0) _ = glib.Source.remove(self.timer);
        self.processes.deinit(self.allocator);
        self.order.deinit(self.allocator);
        if (self.passwd) |p| self.allocator.free(p);
        self.perf.destroy();
        self.allocator.destroy(self);
    }

    fn onTimer(data: ?*anyopaque) callconv(.c) c_int {
        const self: *TaskManager = @ptrCast(@alignCast(data.?));
        self.refresh();
        return 1;
    }

    // ---- sampling --------------------------------------------------------------

    fn readFile(allocator: std.mem.Allocator, path: [:0]const u8) ?[]u8 {
        var contents: [*]u8 = undefined;
        var length: usize = 0;
        if (glib.fileGetContents(path, &contents, &length, null) == 0) return null;
        defer glib.free(contents);
        return allocator.dupe(u8, contents[0..length]) catch null;
    }

    fn refresh(self: *TaskManager) void {
        const a = self.allocator;

        // System totals first, for the CPU delta.
        var total_delta: u64 = 0;
        if (readFile(a, "/proc/stat")) |content| {
            defer a.free(content);
            if (proc.parseCpuTimes(content)) |now| {
                if (self.prev_cpu) |prev| total_delta = now.total -| prev.total;
                self.prev_cpu = now;
            }
        }

        const now_us = glib.getMonotonicTime();
        const dt: f64 = if (self.prev_us == 0) 0 else @as(f64, @floatFromInt(now_us - self.prev_us)) / 1e6;
        self.prev_us = now_us;

        // Mark everything unseen, then walk /proc.
        var it = self.processes.valueIterator();
        while (it.next()) |p| p.seen = false;

        const dir = gio.File.newForPath("/proc");
        defer dir.as(gobject.Object).unref();
        if (dir.enumerateChildren("standard::name", .{}, null, null)) |children| {
            defer children.as(gobject.Object).unref();
            while (children.nextFile(null, null)) |info| {
                defer info.as(gobject.Object).unref();
                const pid = std.fmt.parseInt(u32, std.mem.span(info.getName()), 10) catch continue;
                self.sample(pid, total_delta, dt);
            }
        }

        // Drop the dead.
        var dead: std.ArrayList(u32) = .empty;
        defer dead.deinit(a);
        var all = self.processes.iterator();
        while (all.next()) |entry| if (!entry.value_ptr.seen) dead.append(a, entry.key_ptr.*) catch {};
        for (dead.items) |pid| _ = self.processes.remove(pid);

        var threads: usize = 0;
        var counted = self.processes.valueIterator();
        while (counted.next()) |p| threads += p.threads;
        self.perf.update(self.processes.count(), threads);

        // Nobody sees the list while the Performance tab is open or the window
        // is minimized, so it is not touched then; GTK's work on a list that is
        // replaced every refresh is most of this program's CPU. It is brought
        // up to date when the tab is shown again.
        if (self.listVisible()) self.rebuildList();
    }

    fn sample(self: *TaskManager, pid: u32, total_delta: u64, dt: f64) void {
        const a = self.allocator;
        var path_buf: [64]u8 = undefined;
        const stat_path = std.fmt.bufPrintSentinel(&path_buf, "/proc/{d}/stat", .{pid}, 0) catch return;
        const content = readFile(a, stat_path) orelse return;
        defer a.free(content);
        const stat = proc.parseStat(content) orelse return;

        const entry = self.processes.getOrPut(a, pid) catch return;
        if (!entry.found_existing) {
            entry.value_ptr.* = .{ .pid = pid };
            entry.value_ptr.prev_ticks = stat.cpu_ticks;
            // Owner, once: it never changes.
            var status_path: [64]u8 = undefined;
            const sp = std.fmt.bufPrintSentinel(&status_path, "/proc/{d}/status", .{pid}, 0) catch return;
            if (readFile(a, sp)) |status| {
                defer a.free(status);
                if (proc.parseUid(status)) |uid| {
                    const name = if (self.passwd) |pw| proc.userName(pw, uid) else null;
                    const text = name orelse "?";
                    const n = @min(text.len, entry.value_ptr.user.len);
                    @memcpy(entry.value_ptr.user[0..n], text[0..n]);
                    entry.value_ptr.user_len = n;
                }
            }
        }
        const p = entry.value_ptr;
        p.seen = true;
        // The name comes from the program file, found again only when the
        // kernel's name changes (a new process, or an exec).
        const comm = stat.comm[0..@min(stat.comm.len, p.comm.len)];
        if (p.name_len == 0 or !std.mem.eql(u8, comm, p.comm[0..p.comm_len])) {
            @memcpy(p.comm[0..comm.len], comm);
            p.comm_len = comm.len;
            self.identify(p, stat.comm);
        }
        p.nice = stat.nice;
        self.sampleIo(p, dt);
        p.state = stat.state;
        p.threads = stat.threads;
        p.rss_kb = stat.rss_pages * self.page_kb;
        p.ticks = stat.cpu_ticks;
        p.cpu = proc.cpuPercent(stat.cpu_ticks -| p.prev_ticks, total_delta, self.cpu_count);
        p.prev_ticks = stat.cpu_ticks;
    }

    /// Name, program file and command line of `p`.
    fn identify(self: *TaskManager, p: *Process, comm: []const u8) void {
        const a = self.allocator;
        var pb: [64]u8 = undefined;
        // The program file: only readable for the user's own processes.
        var exe: []const u8 = "";
        var exe_owned: ?[*:0]u8 = null;
        defer if (exe_owned) |e| glib.free(e);
        if (std.fmt.bufPrintSentinel(&pb, "/proc/{d}/exe", .{p.pid}, 0)) |path| {
            if (glib.fileReadLink(path, null)) |target| {
                exe_owned = target;
                exe = std.mem.span(target);
            }
        } else |_| {}
        var cmdline: []const u8 = "";
        var cmd_owned: ?[]u8 = null;
        defer if (cmd_owned) |c| a.free(c);
        if (std.fmt.bufPrintSentinel(&pb, "/proc/{d}/cmdline", .{p.pid}, 0)) |path| {
            if (readFile(a, path)) |c| {
                cmd_owned = c;
                cmdline = c;
            }
        } else |_| {}

        const name = proc.displayName(exe, cmdline, comm);
        const n = @min(name.len, p.name.len);
        @memcpy(p.name[0..n], name[0..n]);
        p.name_len = n;
        const pn = @min(exe.len, p.path.len);
        @memcpy(p.path[0..pn], exe[0..pn]);
        p.path_len = if (std.mem.endsWith(u8, exe, " (deleted)")) 0 else pn;
        p.cmd_len = proc.cmdlineText(cmdline, &p.cmd).len;
    }

    /// Bytes per second to and from storage, for processes whose `io` file this
    /// user may read (the other ones show a dash).
    fn sampleIo(self: *TaskManager, p: *Process, dt: f64) void {
        if (p.io == .denied) return;
        var pb: [64]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&pb, "/proc/{d}/io", .{p.pid}, 0) catch return;
        const content = readFile(self.allocator, path) orelse {
            p.io = .denied;
            p.disk_rate = 0;
            return;
        };
        defer self.allocator.free(content);
        const io = proc.parseIo(content) orelse {
            p.io = .denied;
            return;
        };
        const total = io.read +| io.write;
        if (p.io == .ok and dt > 0) p.disk_rate = @as(f64, @floatFromInt(total -| p.prev_io)) / dt;
        p.prev_io = total;
        p.io = .ok;
    }

    fn less(self: *TaskManager, a: u32, b: u32) bool {
        const pa = self.processes.get(a) orelse return false;
        const pb = self.processes.get(b) orelse return true;
        const forward = switch (self.sort_by) {
            .cpu => if (pa.cpu != pb.cpu) pa.cpu > pb.cpu else pa.rss_kb > pb.rss_kb,
            .memory => pa.rss_kb > pb.rss_kb,
            .disk => if (pa.disk_rate != pb.disk_rate) pa.disk_rate > pb.disk_rate else pa.rss_kb > pb.rss_kb,
            .threads => pa.threads > pb.threads,
            .name => std.ascii.lessThanIgnoreCase(pa.nameSlice(), pb.nameSlice()),
            .user => std.ascii.lessThanIgnoreCase(pa.user[0..pa.user_len], pb.user[0..pb.user_len]),
            .status => std.ascii.lessThanIgnoreCase(statusText(pa.state), statusText(pb.state)),
            .command => std.ascii.lessThanIgnoreCase(pa.cmdSlice(), pb.cmdSlice()),
            // Smallest nice first: the most important programs on top.
            .priority => pa.nice < pb.nice,
            .pid => a < b,
        };
        if (!self.sort_reverse) return forward;
        // Reversed: strictly the other way round, so equal rows stay in a stable order.
        return !forward and (a != b);
    }

    /// Rewrites the list in display order, keeping the selected pid selected.
    /// A header was clicked: sort by that column, in the direction its arrow shows.
    fn onSortChanged(sorter: *gtk.Sorter, _: gtk.SorterChange, self: *TaskManager) callconv(.c) void {
        const view_sorter: *gtk.ColumnViewSorter = @ptrCast(sorter);
        const column = view_sorter.getPrimarySortColumn() orelse return;
        const ascending = view_sorter.getPrimarySortOrder() == .ascending;
        for (self.sort_columns, 0..) |c, i| {
            if (c != column) continue;
            self.sort_by = columns[i];
            // The numbers that matter list the biggest first, names and ids the smallest.
            self.sort_reverse = if (bigFirst(self.sort_by)) ascending else !ascending;
            self.rebuildList();
            return;
        }
    }

    fn onSearchChanged(entry: *gtk.SearchEntry, self: *TaskManager) callconv(.c) void {
        const text = std.mem.span(entry.as(gtk.Editable).getText());
        const n = @min(text.len, self.query.len);
        for (text[0..n], 0..) |c, i| self.query[i] = std.ascii.toLower(c);
        self.query_len = n;
        self.rebuildList();
    }

    fn matches(self: *TaskManager, p: *const Process) bool {
        if (self.query_len == 0) return true;
        var lower: [64]u8 = undefined;
        const query = self.query[0..self.query_len];
        // The name, the command line (which finds a script by its file name)
        // and the PID.
        for ([_][]const u8{ p.nameSlice(), p.cmdSlice() }) |text| {
            const n = @min(text.len, lower.len);
            for (text[0..n], 0..) |c, i| lower[i] = std.ascii.toLower(c);
            if (std.mem.indexOf(u8, lower[0..n], query) != null) return true;
        }
        var pb: [16]u8 = undefined;
        return std.mem.indexOf(u8, std.fmt.bufPrint(&pb, "{d}", .{p.pid}) catch "", query) != null;
    }

    fn rebuildList(self: *TaskManager) void {
        const a = self.allocator;
        const selected_pid: ?u32 = blk: {
            const pos = self.selection.getSelected();
            if (pos == gtk.INVALID_LIST_POSITION or pos >= self.order.items.len) break :blk null;
            break :blk self.order.items[pos];
        };

        self.order.clearRetainingCapacity();
        var keys = self.processes.keyIterator();
        while (keys.next()) |pid| {
            if (self.processes.getPtr(pid.*)) |p| if (!self.matches(p)) continue;
            self.order.append(a, pid.*) catch return;
        }
        std.mem.sort(u32, self.order.items, self, struct {
            fn lt(ctx: *TaskManager, x: u32, y: u32) bool {
                return ctx.less(x, y);
            }
        }.lt);

        // The model stores pids as strings; cells look the rest up by pid.
        const strings = a.alloc(?[*:0]const u8, self.order.items.len + 1) catch return;
        defer a.free(strings);
        var made: usize = 0;
        defer for (strings[0..made]) |s| a.free(std.mem.span(s.?));
        for (self.order.items, 0..) |pid, i| {
            const text = std.fmt.allocPrintSentinel(a, "{d}", .{pid}, 0) catch return;
            strings[i] = text.ptr;
            made += 1;
        }
        strings[self.order.items.len] = null;
        self.list.splice(0, self.list.as(gio.ListModel).getNItems(), @ptrCast(strings.ptr));

        if (selected_pid) |pid| {
            if (std.mem.indexOfScalar(u32, self.order.items, pid)) |index| _ = self.selection.setSelected(@intCast(index));
        }
        var buf: [64]u8 = undefined;
        self.summary.setText(std.fmt.bufPrintSentinel(&buf, "{d} processes", .{self.order.items.len}, 0) catch "");
    }

    // ---- cells ----------------------------------------------------------------------

    fn onSetup(_: *gtk.SignalListItemFactory, item_obj: *gobject.Object, self: *TaskManager) callconv(.c) void {
        const item: *gtk.ListItem = @ptrCast(item_obj);
        const label = gtk.Label.new(null);
        label.setXalign(0);
        label.setEllipsize(.end);
        item.setChild(label.as(gtk.Widget));
        // Right-click a process for its menu.
        const ctx = std.heap.c_allocator.create(RowCtx) catch return;
        ctx.* = .{ .app = self, .item = item };
        const click = gtk.GestureClick.new();
        click.as(gtk.GestureSingle).setButton(3);
        _ = gtk.GestureClick.signals.pressed.connect(click, *RowCtx, &onRowRightClick, ctx, .{});
        _ = gtk.Widget.signals.destroy.connect(label, *RowCtx, &onRowCtxDestroy, ctx, .{});
        label.as(gtk.Widget).addController(click.as(gtk.EventController));
    }

    const RowCtx = struct { app: *TaskManager, item: *gtk.ListItem };

    fn onRowCtxDestroy(_: *gtk.Label, ctx: *RowCtx) callconv(.c) void {
        std.heap.c_allocator.destroy(ctx);
    }

    const menu_end = 0;
    const menu_force = 1;
    const menu_copy_pid = 2;
    const menu_copy_name = 3;
    const menu_copy_cmd = 4;
    const menu_location = 5;
    /// `menu_priority + i` sets `priorities[i]`.
    const menu_priority = 10;

    fn onRowRightClick(gesture: *gtk.GestureClick, _: c_int, x: f64, y: f64, ctx: *RowCtx) callconv(.c) void {
        const self = ctx.app;
        // The row under the pointer becomes the selected one, then the menu opens on it.
        self.selection.setSelected(ctx.item.getPosition());
        const widget = gesture.as(gtk.EventController).getWidget() orelse return;
        // Rows are rebuilt on every refresh, so the menu hangs off the table.
        const table = (self.table orelse return).as(gtk.Widget);
        var tx: f64 = x;
        var ty: f64 = y;
        _ = widget.translateCoordinates(table, x, y, &tx, &ty);
        const pid = self.selectedPid();
        const has_path = if (pid) |id| (if (self.processes.get(id)) |p| p.path_len > 0 else false) else false;
        var items: [6 + priorities.len + 1]common.contextmenu.Item = undefined;
        var n: usize = 0;
        for ([_]common.contextmenu.Item{
            .{ .label = common.tr("End Task"), .id = menu_end },
            .{ .label = common.tr("Force Quit\u{2026}"), .id = menu_force },
            .{ .label = common.tr("Open file location"), .id = menu_location, .enabled = has_path },
        }) |it| {
            items[n] = it;
            n += 1;
        }
        inline for (priorities, 0..) |pr, i| {
            items[n] = .{ .label = common.tr("Priority: " ++ pr.label), .id = menu_priority + i };
            n += 1;
        }
        for ([_]common.contextmenu.Item{
            .{ .label = common.tr("Copy PID"), .id = menu_copy_pid },
            .{ .label = common.tr("Copy name"), .id = menu_copy_name },
            .{ .label = common.tr("Copy command line"), .id = menu_copy_cmd },
        }) |it| {
            items[n] = it;
            n += 1;
        }
        common.contextmenu.show(table, tx, ty, items[0..n], TaskManager, onProcessMenu, self);
    }

    fn onProcessMenu(self: *TaskManager, id: usize) void {
        switch (id) {
            menu_end => self.signal(SIGTERM),
            menu_force => onForceClicked(undefined, self),
            menu_location => self.openLocation(),
            menu_copy_pid, menu_copy_name, menu_copy_cmd => {
                const pid = self.selectedPid() orelse return;
                var buf: [256]u8 = undefined;
                const text = if (id == menu_copy_pid)
                    std.fmt.bufPrintSentinel(&buf, "{d}", .{pid}, 0) catch return
                else blk: {
                    const p = self.processes.get(pid) orelse return;
                    const what = if (id == menu_copy_name) p.nameSlice() else p.cmdSlice();
                    break :blk std.fmt.bufPrintSentinel(&buf, "{s}", .{what}, 0) catch return;
                };
                self.window.as(gtk.Widget).getClipboard().setText(text);
            },
            else => if (id >= menu_priority and id < menu_priority + priorities.len) self.setPriority(priorities[id - menu_priority].nice),
        }
    }

    fn onBindFor(comptime kind: Column) fn (*gtk.SignalListItemFactory, *gobject.Object, *TaskManager) callconv(.c) void {
        return struct {
            fn bind(_: *gtk.SignalListItemFactory, item_obj: *gobject.Object, self: *TaskManager) callconv(.c) void {
                const item: *gtk.ListItem = @ptrCast(item_obj);
                const label: *gtk.Label = @ptrCast(@alignCast(item.getChild() orelse return));
                const string: *gtk.StringObject = @ptrCast(@alignCast(item.getItem() orelse return));
                const pid = std.fmt.parseInt(u32, std.mem.span(string.getString()), 10) catch return;
                const p = self.processes.get(pid) orelse return;
                var buf: [96]u8 = undefined;
                const text: [:0]const u8 = switch (kind) {
                    .name => std.fmt.bufPrintSentinel(&buf, "{s}", .{p.nameSlice()}, 0) catch "",
                    .pid => std.fmt.bufPrintSentinel(&buf, "{d}", .{p.pid}, 0) catch "",
                    .user => std.fmt.bufPrintSentinel(&buf, "{s}", .{p.user[0..p.user_len]}, 0) catch "",
                    .cpu => std.fmt.bufPrintSentinel(&buf, "{d:.1}", .{p.cpu}, 0) catch "",
                    .memory => if (p.rss_kb >= 10240)
                        std.fmt.bufPrintSentinel(&buf, "{d} MB", .{p.rss_kb / 1024}, 0) catch ""
                    else
                        std.fmt.bufPrintSentinel(&buf, "{d} kB", .{p.rss_kb}, 0) catch "",
                    .threads => std.fmt.bufPrintSentinel(&buf, "{d}", .{p.threads}, 0) catch "",
                    .status => std.fmt.bufPrintSentinel(&buf, "{s}", .{statusText(p.state)}, 0) catch "",
                    .disk => if (p.io != .ok) "—" else blk: {
                        var rb: [32]u8 = undefined;
                        break :blk std.fmt.bufPrintSentinel(&buf, "{s}", .{perf.fmtByteRate(&rb, p.disk_rate)}, 0) catch "";
                    },
                    .priority => blk: {
                        var pb2: [48]u8 = undefined;
                        break :blk std.fmt.bufPrintSentinel(&buf, "{s}", .{priorityText(&pb2, p.nice)}, 0) catch "";
                    },
                    .command => blk: {
                        // Longer than the buffer: the cell ellipsizes anyway.
                        const c = p.cmdSlice();
                        break :blk std.fmt.bufPrintSentinel(&buf, "{s}", .{c[0..@min(c.len, buf.len - 1)]}, 0) catch "";
                    },
                };
                label.setText(text);
                label.setXalign(switch (kind) {
                    .name, .user, .status, .priority, .command => 0,
                    else => 1,
                });
                // Busy processes stand out, as in the Windows Task Manager.
                const widget = label.as(gtk.Widget);
                for ([_][:0]const u8{ "dkde-heat-1", "dkde-heat-2", "dkde-heat-3" }) |c| widget.removeCssClass(c);
                const heat: u8 = switch (kind) {
                    .cpu => if (p.cpu >= 50) 3 else if (p.cpu >= 15) 2 else if (p.cpu >= 2) 1 else 0,
                    .memory => if (p.rss_kb >= 1024 * 1024) 3 else if (p.rss_kb >= 400 * 1024) 2 else if (p.rss_kb >= 100 * 1024) 1 else 0,
                    .disk => if (p.disk_rate >= 50 * 1024 * 1024) 3 else if (p.disk_rate >= 10 * 1024 * 1024) 2 else if (p.disk_rate >= 1024 * 1024) 1 else 0,
                    else => 0,
                };
                if (heat == 1) widget.addCssClass("dkde-heat-1");
                if (heat == 2) widget.addCssClass("dkde-heat-2");
                if (heat == 3) widget.addCssClass("dkde-heat-3");
            }
        }.bind;
    }

    // ---- actions ------------------------------------------------------------------------

    fn selectedPid(self: *TaskManager) ?u32 {
        const pos = self.selection.getSelected();
        if (pos == gtk.INVALID_LIST_POSITION or pos >= self.order.items.len) return null;
        return self.order.items[pos];
    }

    fn signal(self: *TaskManager, sig: c_int) void {
        const pid = self.selectedPid() orelse return;
        if (kill(@intCast(pid), sig) != 0) {
            common.dialogs.showError(self.window.as(gtk.Window), common.tr("Cannot end this task"), "You may not have permission to end it.");
        }
    }

    /// Shows the folder of the selected program in the default file manager.
    fn openLocation(self: *TaskManager) void {
        const pid = self.selectedPid() orelse return;
        const p = self.processes.get(pid) orelse return;
        const path = p.pathSlice();
        const dir = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[0..@max(i, 1)] else "";
        if (dir.len == 0) {
            common.dialogs.showError(self.window.as(gtk.Window), common.tr("Cannot open the file location"), common.tr("The program file of this process is not known. It may belong to another user, or have no file."));
            return;
        }
        common.appinfo.spawnIn(self.allocator, &.{ "dkde-files", dir }, dir);
    }

    /// Gives the selected process a new nice value. Making one less important
    /// is allowed for its owner; making one more important needs root, as on any
    /// Linux system.
    fn setPriority(self: *TaskManager, nice: c_int) void {
        const pid = self.selectedPid() orelse return;
        if (setpriority(0, pid, nice) != 0) {
            std.log.warn("setpriority {d} to {d}: errno {d}", .{ pid, nice, __errno_location().* });
            common.dialogs.showError(self.window.as(gtk.Window), common.tr("Cannot change the priority"), common.tr("You can lower the priority of your own programs. Raising it, or changing another user's program, needs administrator rights."));
            return;
        }
        self.refresh();
    }

    fn onEndClicked(_: *gtk.Button, self: *TaskManager) callconv(.c) void {
        self.signal(SIGTERM);
    }

    fn onForceClicked(_: *gtk.Button, self: *TaskManager) callconv(.c) void {
        const pid = self.selectedPid() orelse return;
        const p = self.processes.get(pid) orelse return;
        var buf: [160]u8 = undefined;
        const message = std.fmt.bufPrintSentinel(&buf, "Force quit \"{s}\"?", .{p.nameSlice()}, 0) catch return;
        common.dialogs.choose(
            self.window.as(gtk.Window),
            message,
            common.tr("Unsaved work in this program will be lost."),
            &.{ "Cancel", "Force Quit" },
            0,
            TaskManager,
            onForceAnswer,
            self,
        );
    }

    fn onForceAnswer(self: *TaskManager, index: c_int) void {
        if (index == 1) self.signal(SIGKILL);
    }

    fn onMenuAction(self: *TaskManager, action: []const u8) void {
        const eql = std.mem.eql;
        if (eql(u8, action, "end")) return self.signal(SIGTERM);
        if (eql(u8, action, "force")) return onForceClicked(undefined, self);
        if (eql(u8, action, "close")) return self.window.as(gtk.Window).close();
        // A check item in the View menu: show or hide a column.
        if (std.mem.startsWith(u8, action, "col-")) {
            inline for (columns, 0..) |c, i| {
                if (i > 0 and eql(u8, action["col-".len..], @tagName(c))) {
                    self.col_visible[i] = !self.col_visible[i];
                    if (self.sort_columns[i]) |col| col.setVisible(@intFromBool(self.col_visible[i]));
                    self.saveColumns();
                }
            }
            return;
        }
        const sort: ?SortBy = if (eql(u8, action, "sort-cpu")) .cpu else if (eql(u8, action, "sort-memory")) .memory else if (eql(u8, action, "sort-name")) .name else if (eql(u8, action, "sort-pid")) .pid else null;
        if (sort) |s| {
            self.sort_by = s;
            self.sort_reverse = false;
            self.rebuildList();
        }
    }

    fn onKey(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, _: gdk.ModifierType, self: *TaskManager) callconv(.c) c_int {
        switch (keyval) {
            gdk.KEY_Delete => {
                self.signal(SIGTERM);
                return 1;
            },
            gdk.KEY_Escape => {
                self.window.as(gtk.Window).close();
                return 1;
            },
            else => return 0,
        }
    }
};

pub const std_options: std.Options = .{ .logFn = common.log.logFn, .log_level = .debug };

pub fn main(init: std.process.Init.Minimal) !void {
    common.perf.init();
    var debug_allocator: common.perf.Gpa = .{};
    defer debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var app: App = .{ .allocator = allocator };
    const args = init.args.vector;
    var i: usize = 1;
    while (i + 1 < args.len) : (i += 1) {
        if (std.mem.eql(u8, std.mem.span(args[i]), "--tab"))
            app.tab = if (std.ascii.eqlIgnoreCase(std.mem.span(args[i + 1]), "performance")) 1 else 0;
        if (std.mem.eql(u8, std.mem.span(args[i]), "--resource")) {
            app.resource = std.mem.span(args[i + 1]);
            app.tab = 1;
        }
    }
    defer if (app.appearance) |a| a.destroy();

    const gtk_app = gtk.Application.new("org.dkde.tasks", .{ .non_unique = true });
    defer gtk_app.as(gobject.Object).unref();
    _ = gio.Application.signals.activate.connect(gtk_app, *App, &App.activate, &app, .{});
    // GApplication only gets the program name; --tab is ours.
    var argv = [_]?[*:0]const u8{ init.args.vector[0], null };
    const status = gio.Application.run(gtk_app.as(gio.Application), 1, @ptrCast(&argv));
    if (status != 0) std.process.exit(@intCast(status));
}

test {
    _ = @import("proc.zig");
    _ = @import("perf.zig");
    _ = @import("perfview.zig");
}
