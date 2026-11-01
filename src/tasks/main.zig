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

extern fn kill(pid: c_int, sig: c_int) c_int;
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

    fn activate(app: *gtk.Application, self: *App) callconv(.c) void {
        common.style.load(self.allocator) catch |err|
            std.log.warn("stylesheet not loaded: {s}", .{@errorName(err)});
        self.appearance = common.style.Appearance.create(self.allocator) catch null;
        const manager = TaskManager.create(self.allocator, app) catch |err| {
            std.log.err("cannot create the window: {s}", .{@errorName(err)});
            return;
        };
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

    fn nameSlice(self: *const Process) []const u8 {
        return self.name[0..self.name_len];
    }
};

const SortBy = enum { cpu, memory, name, pid };
const Column = enum { name, pid, user, cpu, memory, threads };
const columns = [_]Column{ .name, .pid, .user, .cpu, .memory, .threads };

const TaskManager = struct {
    allocator: std.mem.Allocator,
    window: *gtk.ApplicationWindow,
    list: *gtk.StringList,
    selection: *gtk.SingleSelection,
    /// The table; context menus attach here because rows are rebuilt on every refresh.
    table: ?*gtk.ColumnView = null,
    summary: *gtk.Label,
    perf: *perfview.Perf,
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
    sort_columns: [4]?*gtk.ColumnViewColumn = @splat(null),
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

        const mb = common.menubar;
        const menus = [_]mb.Menu{
            .{ .label = "_File", .entries = &.{
                mb.item("_End Task", "end", "Delete"),
                mb.item("_Force Quit…", "force", null),
                .separator,
                mb.item("E_xit", "close", "<Control>q"),
            } },
            .{ .label = "_View", .entries = &.{
                mb.item("Sort by _CPU", "sort-cpu", null),
                mb.item("Sort by _Memory", "sort-memory", null),
                mb.item("Sort by _Name", "sort-name", null),
                mb.item("Sort by _PID", "sort-pid", null),
            } },
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
        const titles = [_][:0]const u8{ "Name", "PID", "User", "CPU %", "Memory", "Threads" };
        inline for (columns, 0..) |kind, i| {
            const factory = gtk.SignalListItemFactory.new();
            _ = gtk.SignalListItemFactory.signals.setup.connect(factory, *TaskManager, &onSetup, self, .{});
            _ = gtk.SignalListItemFactory.signals.bind.connect(factory, *TaskManager, &onBindFor(kind), self, .{});
            const column = gtk.ColumnViewColumn.new(common.tr(titles[i]), factory.as(gtk.ListItemFactory));
            column.setResizable(1);
            column.setExpand(@intFromBool(kind == .name));
            // Clicking a header sorts by it; the list itself is ordered in `less`.
            const slot: ?usize = switch (kind) {
                .name => 0,
                .pid => 1,
                .cpu => 2,
                .memory => 3,
                else => null,
            };
            if (slot) |idx| {
                column.setSorter(gtk.CustomSorter.new(null, null, null).as(gtk.Sorter));
                self.sort_columns[idx] = column;
            }
            view.appendColumn(column);
        }
        if (view.getSorter()) |sorter| _ = gtk.Sorter.signals.changed.connect(sorter, *TaskManager, &onSortChanged, self, .{});
        if (self.sort_columns[2]) |cpu_column| view.sortByColumn(cpu_column, .descending);
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
        notebook.as(gtk.Widget).setVexpand(1);
        _ = notebook.appendPage(root.as(gtk.Widget), gtk.Label.new(common.tr("Processes")).as(gtk.Widget));
        _ = notebook.appendPage(self.perf.widget, gtk.Label.new(common.tr("Performance")).as(gtk.Widget));
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
                self.sample(pid, total_delta);
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

        self.rebuildList();
    }

    fn sample(self: *TaskManager, pid: u32, total_delta: u64) void {
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
        const n = @min(stat.comm.len, p.name.len);
        @memcpy(p.name[0..n], stat.comm[0..n]);
        p.name_len = n;
        p.state = stat.state;
        p.threads = stat.threads;
        p.rss_kb = stat.rss_pages * self.page_kb;
        p.ticks = stat.cpu_ticks;
        p.cpu = proc.cpuPercent(stat.cpu_ticks -| p.prev_ticks, total_delta, self.cpu_count);
        p.prev_ticks = stat.cpu_ticks;
    }

    fn less(self: *TaskManager, a: u32, b: u32) bool {
        const pa = self.processes.get(a) orelse return false;
        const pb = self.processes.get(b) orelse return true;
        const forward = switch (self.sort_by) {
            .cpu => if (pa.cpu != pb.cpu) pa.cpu > pb.cpu else pa.rss_kb > pb.rss_kb,
            .memory => pa.rss_kb > pb.rss_kb,
            .name => std.ascii.lessThanIgnoreCase(pa.nameSlice(), pb.nameSlice()),
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
            self.sort_by = switch (i) {
                0 => .name,
                1 => .pid,
                2 => .cpu,
                else => .memory,
            };
            // CPU and memory list the biggest first, names and ids the smallest.
            self.sort_reverse = switch (self.sort_by) {
                .cpu, .memory => ascending,
                .name, .pid => !ascending,
            };
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
        const name = p.nameSlice();
        const n = @min(name.len, lower.len);
        for (name[0..n], 0..) |c, i| lower[i] = std.ascii.toLower(c);
        return std.mem.indexOf(u8, lower[0..n], self.query[0..self.query_len]) != null;
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
        common.contextmenu.show(table, tx, ty, &.{
            .{ .label = common.tr("End Task"), .id = menu_end },
            .{ .label = common.tr("Force Quit\u{2026}"), .id = menu_force },
            .{ .label = common.tr("Copy PID"), .id = menu_copy_pid },
            .{ .label = common.tr("Copy name"), .id = menu_copy_name },
        }, TaskManager, onProcessMenu, self);
    }

    fn onProcessMenu(self: *TaskManager, id: usize) void {
        switch (id) {
            menu_end => self.signal(SIGTERM),
            menu_force => onForceClicked(undefined, self),
            menu_copy_pid, menu_copy_name => {
                const pid = self.selectedPid() orelse return;
                var buf: [128]u8 = undefined;
                const text = if (id == menu_copy_pid)
                    std.fmt.bufPrintSentinel(&buf, "{d}", .{pid}, 0) catch return
                else blk: {
                    const p = self.processes.get(pid) orelse return;
                    break :blk std.fmt.bufPrintSentinel(&buf, "{s}", .{p.nameSlice()}, 0) catch return;
                };
                self.window.as(gtk.Widget).getClipboard().setText(text);
            },
            else => {},
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
                };
                label.setText(text);
                if (kind != .name and kind != .user) label.setXalign(1);
                // Busy processes stand out, as in the Windows Task Manager.
                const widget = label.as(gtk.Widget);
                for ([_][:0]const u8{ "dkde-heat-1", "dkde-heat-2", "dkde-heat-3" }) |c| widget.removeCssClass(c);
                const heat: u8 = switch (kind) {
                    .cpu => if (p.cpu >= 50) 3 else if (p.cpu >= 15) 2 else if (p.cpu >= 2) 1 else 0,
                    .memory => if (p.rss_kb >= 1024 * 1024) 3 else if (p.rss_kb >= 400 * 1024) 2 else if (p.rss_kb >= 100 * 1024) 1 else 0,
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
    defer if (app.appearance) |a| a.destroy();

    const gtk_app = gtk.Application.new("org.dkde.tasks", .{ .non_unique = true });
    defer gtk_app.as(gobject.Object).unref();
    _ = gio.Application.signals.activate.connect(gtk_app, *App, &App.activate, &app, .{});
    const status = gio.Application.run(gtk_app.as(gio.Application), @intCast(init.args.vector.len), @ptrCast(@constCast(init.args.vector.ptr)));
    if (status != 0) std.process.exit(@intCast(status));
}

test {
    _ = @import("proc.zig");
    _ = @import("perf.zig");
    _ = @import("perfview.zig");
}
