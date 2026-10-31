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

/// A summary tile: a title, a big number, a detail line and a history graph.
const Card = struct {
    allocator: std.mem.Allocator,
    box: *gtk.Box,
    value: *gtk.Label,
    detail: *gtk.Label,
    graph: *gtk.DrawingArea,
    /// Most recent samples, 0 to 1, oldest first; 60 of them.
    history: [history_len]f64 = @splat(0),
    filled: usize = 0,

    const history_len = 60;

    fn create(allocator: std.mem.Allocator, title: [:0]const u8) *Card {
        const self = allocator.create(Card) catch @panic("OOM");
        const box = gtk.Box.new(.vertical, 2);
        box.as(gtk.Widget).addCssClass("dkde-card");
        box.as(gtk.Widget).setHexpand(1);
        const heading = gtk.Label.new(title);
        heading.setXalign(0);
        heading.as(gtk.Widget).addCssClass("dkde-card-title");
        const value = gtk.Label.new("0%");
        value.setXalign(0);
        value.as(gtk.Widget).addCssClass("dkde-card-value");
        const detail = gtk.Label.new("");
        detail.setXalign(0);
        detail.as(gtk.Widget).addCssClass("dkde-card-detail");
        const graph = gtk.DrawingArea.new();
        graph.setContentHeight(56);
        graph.as(gtk.Widget).setHexpand(1);
        graph.as(gtk.Widget).addCssClass("dkde-card-graph");
        box.append(heading.as(gtk.Widget));
        box.append(value.as(gtk.Widget));
        box.append(detail.as(gtk.Widget));
        box.append(graph.as(gtk.Widget));
        self.* = .{ .allocator = allocator, .box = box, .value = value, .detail = detail, .graph = graph };
        graph.setDrawFunc(onDraw, self, null);
        _ = gtk.Widget.signals.destroy.connect(box, *Card, &onDestroy, self, .{});
        return self;
    }

    fn onDestroy(_: *gtk.Box, self: *Card) callconv(.c) void {
        self.allocator.destroy(self);
    }

    fn push(self: *Card, fraction: f64) void {
        std.mem.copyForwards(f64, self.history[0 .. history_len - 1], self.history[1..history_len]);
        self.history[history_len - 1] = std.math.clamp(fraction, 0, 1);
        self.filled = @min(self.filled + 1, history_len);
        self.graph.as(gtk.Widget).queueDraw();
    }

    /// Fills the area under the line, in the accent colour.
    fn onDraw(_: *gtk.DrawingArea, cr: *cairo.Context, width: c_int, height: c_int, data: ?*anyopaque) callconv(.c) void {
        const self: *Card = @ptrCast(@alignCast(data.?));
        const w: f64 = @floatFromInt(width);
        const h: f64 = @floatFromInt(height);
        const step = w / @as(f64, @floatFromInt(history_len - 1));
        cr.setSourceRgba(0.21, 0.52, 0.89, 0.12);
        cr.rectangle(0, 0, w, h);
        cr.fill();

        cr.moveTo(0, h);
        for (self.history, 0..) |v, i| cr.lineTo(@as(f64, @floatFromInt(i)) * step, h - v * (h - 2) - 1);
        cr.lineTo(w, h);
        cr.closePath();
        cr.setSourceRgba(0.21, 0.52, 0.89, 0.28);
        cr.fillPreserve();

        cr.newPath();
        for (self.history, 0..) |v, i| {
            const x = @as(f64, @floatFromInt(i)) * step;
            const y = h - v * (h - 2) - 1;
            if (i == 0) cr.moveTo(x, y) else cr.lineTo(x, y);
        }
        cr.setSourceRgba(0.21, 0.52, 0.89, 1);
        cr.setLineWidth(1.5);
        cr.stroke();
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
    summary: *gtk.Label,
    cpu_card: *Card,
    mem_card: *Card,
    search: *gtk.SearchEntry,
    /// Lower-cased search text; empty shows everything.
    query: [64]u8 = undefined,
    query_len: usize = 0,

    processes: std.AutoHashMapUnmanaged(u32, Process) = .empty,
    /// Pids in display order; mirrors `list`.
    order: std.ArrayList(u32) = .empty,
    sort_by: SortBy = .cpu,
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
            .cpu_card = Card.create(allocator, common.tr("CPU")),
            .mem_card = Card.create(allocator, common.tr("Memory")),
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

        // Summary cards, then the toolbar with search and End Task.
        const summary_box = gtk.Box.new(.horizontal, 12);
        summary_box.as(gtk.Widget).setMarginStart(12);
        summary_box.as(gtk.Widget).setMarginEnd(12);
        summary_box.as(gtk.Widget).setMarginTop(12);
        summary_box.as(gtk.Widget).setMarginBottom(6);
        summary_box.append(self.cpu_card.box.as(gtk.Widget));
        summary_box.append(self.mem_card.box.as(gtk.Widget));
        self.cpu_card.detail.setText(std.fmt.allocPrintSentinel(allocator, "{d} logical processors", .{self.cpu_count}, 0) catch "");

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
            view.appendColumn(column);
        }
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
        root.append(menu_bar.as(gtk.Widget));
        root.append(summary_box.as(gtk.Widget));
        root.append(toolbar.as(gtk.Widget));
        root.append(scroller.as(gtk.Widget));
        root.append(bottom.as(gtk.Widget));
        window.as(gtk.Window).setChild(root.as(gtk.Widget));

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
                if (self.prev_cpu) |prev| {
                    total_delta = now.total -| prev.total;
                    const idle_delta = now.idle -| prev.idle;
                    const busy: f64 = if (total_delta > 0) 1.0 - @as(f64, @floatFromInt(idle_delta)) / @as(f64, @floatFromInt(total_delta)) else 0;
                    self.cpu_card.push(busy);
                    var buf: [32]u8 = undefined;
                    self.cpu_card.value.setText(std.fmt.bufPrintSentinel(&buf, "{d:.0}%", .{std.math.clamp(busy, 0, 1) * 100}, 0) catch "");
                }
                self.prev_cpu = now;
            }
        }
        if (readFile(a, "/proc/meminfo")) |content| {
            defer a.free(content);
            if (proc.parseMeminfo(content)) |mem| {
                const used = mem.total_kb -| mem.available_kb;
                const fraction = @as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(@max(1, mem.total_kb)));
                self.mem_card.push(fraction);
                var buf: [32]u8 = undefined;
                self.mem_card.value.setText(std.fmt.bufPrintSentinel(&buf, "{d:.0}%", .{fraction * 100}, 0) catch "");
                var detail: [96]u8 = undefined;
                self.mem_card.detail.setText(std.fmt.bufPrintSentinel(&detail, "{d:.1} of {d:.1} GB in use", .{ @as(f64, @floatFromInt(used)) / 1048576.0, @as(f64, @floatFromInt(mem.total_kb)) / 1048576.0 }, 0) catch "");
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
        return switch (self.sort_by) {
            .cpu => if (pa.cpu != pb.cpu) pa.cpu > pb.cpu else pa.rss_kb > pb.rss_kb,
            .memory => pa.rss_kb > pb.rss_kb,
            .name => std.ascii.lessThanIgnoreCase(pa.nameSlice(), pb.nameSlice()),
            .pid => a < b,
        };
    }

    /// Rewrites the list in display order, keeping the selected pid selected.
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

    fn onSetup(_: *gtk.SignalListItemFactory, item_obj: *gobject.Object, _: *TaskManager) callconv(.c) void {
        const item: *gtk.ListItem = @ptrCast(item_obj);
        const label = gtk.Label.new(null);
        label.setXalign(0);
        label.setEllipsize(.end);
        item.setChild(label.as(gtk.Widget));
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
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
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
}
