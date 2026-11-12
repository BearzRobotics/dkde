//! The process table of the Processes and Details pages.
//!
//! Processes groups what runs as Windows 11 does: Apps (each app one row,
//! its helper processes under it), Background processes and Windows (here:
//! System) processes; or, as a choice, the tree of which process started
//! which. Details lists every process flat.
//!
//! The rows are worked out here (`rows`), and the list model only says how
//! many there are: a refresh that changes no row only writes the new figures
//! into the cells on screen, and one that does replaces just the rows that
//! differ. GTK rebuilding the whole list every second was most of this
//! program's CPU.

const std = @import("std");
const gdk = @import("gdk4");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

const sampler_mod = @import("sampler.zig");
const columns = @import("columns.zig");
const actions_mod = @import("actions.zig");
const perf = @import("perf.zig");

const Sampler = sampler_mod.Sampler;
const Process = sampler_mod.Process;
const Kind = sampler_mod.Kind;
const Column = columns.Column;
const Actions = actions_mod.Actions;
const t = common.tr;

const column_count = @typeInfo(Column).@"enum".field_names.len;

pub const Mode = enum { grouped, tree, flat };
pub const Goto = enum { details, service };

const Row = struct {
    header: bool = false,
    pid: u32 = 0,
    kind: Kind = .app,
    depth: u8 = 0,
    expandable: bool = false,
    expanded: bool = false,
    /// An app's row: the sum of its processes.
    aggregate: bool = false,
    /// Processes under a header or app (shown as "Apps (12)").
    count: u32 = 0,

    fn same(a: Row, b: Row) bool {
        return std.meta.eql(a, b);
    }
};

/// One cell on screen, written again on each refresh.
const Cell = struct {
    table: *Table,
    item: *gtk.ListItem,
    column: Column,
    label: *gtk.Label,
    // The name column only.
    expander: ?*gtk.Button = null,
    icon: ?*gtk.Image = null,
    icon_name: [96]u8 = @splat(0),
    box: ?*gtk.Box = null,
};

pub const Table = struct {
    gpa: std.mem.Allocator,
    sampler: *Sampler,
    actions: *Actions,
    /// The state file group its columns are remembered under.
    name: [:0]const u8,
    mode: Mode,
    /// Column titles carry the machine's totals (Processes).
    totals: bool,
    widget: *gtk.Widget,
    view: *gtk.ColumnView,
    model: *gtk.StringList,
    selection: *gtk.SingleSelection,
    action_group: *gio.SimpleActionGroup,
    /// The columns this table offers, in order.
    offered: []const Column,
    cols: [column_count]?*gtk.ColumnViewColumn = @splat(null),
    visible: [column_count]bool = @splat(false),
    rows: std.ArrayList(Row) = .empty,
    cells: std.ArrayList(*Cell) = .empty,
    /// The figures of each app (its processes summed).
    aggregates: std.AutoHashMapUnmanaged(u32, Process) = .empty,
    expanded: std.AutoHashMapUnmanaged(u32, void) = .empty,
    sort_by: Column = .cpu,
    sort_reverse: bool = false,
    query: [64]u8 = undefined,
    query_len: usize = 0,
    /// The page shows it: refreshes rebuild only then.
    shown: bool = false,
    /// Told when the selection changes (to enable buttons).
    on_selection: ?*const fn (*anyopaque) void = null,
    /// "Go to details" and "Go to service".
    on_goto: ?*const fn (*anyopaque, Goto, u32) void = null,
    owner: *anyopaque = undefined,
    menu: *gio.Menu,

    pub fn create(gpa: std.mem.Allocator, sampler: *Sampler, actions: *Actions, name: [:0]const u8, offered: []const Column, defaults: []const Column, mode: Mode, totals: bool) *Table {
        const self = gpa.create(Table) catch @panic("OOM");
        const model = gtk.StringList.new(null);
        const selection = gtk.SingleSelection.new(model.as(gio.ListModel));
        selection.setAutoselect(0);
        selection.setCanUnselect(1);
        const view = gtk.ColumnView.new(selection.as(gtk.SelectionModel));
        self.* = .{
            .gpa = gpa,
            .sampler = sampler,
            .actions = actions,
            .name = name,
            .mode = mode,
            .totals = totals,
            .widget = undefined,
            .view = view,
            .model = model,
            .selection = selection,
            .action_group = gio.SimpleActionGroup.new(),
            .offered = offered,
            .menu = gio.Menu.new(),
        };
        self.loadState(defaults);
        view.as(gtk.Widget).addCssClass("dkde-process-table");
        view.as(gtk.Widget).setVexpand(1);
        view.setShowColumnSeparators(1);
        view.setReorderable(1);

        // Right-clicking a header offers the columns, as in Windows.
        const header_menu = gio.Menu.new();
        for (offered) |c| {
            if (c == .name) continue;
            var ab: [48]u8 = undefined;
            const detailed = std.fmt.bufPrintSentinel(&ab, "table.col-{s}", .{@tagName(c)}, 0) catch continue;
            header_menu.append(c.title(), detailed);
            const action = gio.SimpleAction.newStateful(detailed["table.".len..], null, glib.Variant.newBoolean(@intFromBool(self.visible[@intFromEnum(c)])));
            _ = gio.SimpleAction.signals.change_state.connect(action, *Table, &onColumnToggled, self, .{});
            self.action_group.as(gio.ActionMap).addAction(action.as(gio.Action));
            action.as(gobject.Object).unref();
        }

        for (offered) |c| {
            const factory = gtk.SignalListItemFactory.new();
            const ctx = gpa.create(ColumnCtx) catch @panic("OOM");
            ctx.* = .{ .table = self, .column = c };
            _ = gtk.SignalListItemFactory.signals.setup.connect(factory, *ColumnCtx, &onSetup, ctx, .{});
            _ = gtk.SignalListItemFactory.signals.bind.connect(factory, *ColumnCtx, &onBind, ctx, .{});
            _ = gtk.SignalListItemFactory.signals.teardown.connect(factory, *ColumnCtx, &onTeardown, ctx, .{});
            const column = gtk.ColumnViewColumn.new(c.title(), factory.as(gtk.ListItemFactory));
            column.setVisible(@intFromBool(self.visible[@intFromEnum(c)]));
            column.setResizable(1);
            column.setExpand(@intFromBool(c == .name or c == .command));
            column.setSorter(gtk.CustomSorter.new(null, null, null).as(gtk.Sorter));
            column.setHeaderMenu(header_menu.as(gio.MenuModel));
            column.as(gobject.Object).setData("dkde-ctx", ctx);
            if (self.savedWidth(c)) |w| column.setFixedWidth(w) else if (c == .name) column.setFixedWidth(260);
            self.cols[@intFromEnum(c)] = column;
            view.appendColumn(column);
        }
        header_menu.as(gobject.Object).unref();
        if (view.getSorter()) |sorter| _ = gtk.Sorter.signals.changed.connect(sorter, *Table, &onSortChanged, self, .{});
        if (self.cols[@intFromEnum(self.sort_by)]) |c| view.sortByColumn(c, if (self.sort_reverse == self.sort_by.bigFirst()) .ascending else .descending);

        // The row menu.
        self.buildMenu();
        view.as(gtk.Widget).insertActionGroup("table", self.action_group.as(gio.ActionGroup));

        _ = gtk.ColumnView.signals.activate.connect(view, *Table, &onActivate, self, .{});
        const click = gtk.GestureClick.new();
        click.as(gtk.GestureSingle).setButton(3);
        _ = gtk.GestureClick.signals.pressed.connect(click, *Table, &onRightClick, self, .{});
        view.as(gtk.Widget).addController(click.as(gtk.EventController));
        _ = gtk.SelectionModel.signals.selection_changed.connect(selection.as(gtk.SelectionModel), *Table, &onSelectionChanged, self, .{});

        const scroller = gtk.ScrolledWindow.new();
        scroller.setChild(view.as(gtk.Widget));
        scroller.as(gtk.Widget).setVexpand(1);
        self.widget = scroller.as(gtk.Widget);
        return self;
    }

    const ColumnCtx = struct { table: *Table, column: Column };

    pub fn destroy(self: *Table) void {
        self.saveState();
        for (self.offered) |c| if (self.cols[@intFromEnum(c)]) |col| {
            if (col.as(gobject.Object).getData("dkde-ctx")) |raw| self.gpa.destroy(@as(*ColumnCtx, @ptrCast(@alignCast(raw))));
        };
        for (self.cells.items) |cell| self.gpa.destroy(cell);
        self.cells.deinit(self.gpa);
        self.rows.deinit(self.gpa);
        self.aggregates.deinit(self.gpa);
        self.expanded.deinit(self.gpa);
        self.menu.as(gobject.Object).unref();
        self.gpa.destroy(self);
    }

    // ---- what is remembered -----------------------------------------------------------

    fn loadState(self: *Table, defaults: []const Column) void {
        var saved = common.state.loadList(self.gpa, "tasks.state", self.name, "columns") catch std.ArrayList([]u8).empty;
        defer common.state.freeList(self.gpa, &saved);
        for (self.offered) |c| {
            const i = @intFromEnum(c);
            if (saved.items.len == 0) {
                self.visible[i] = std.mem.indexOfScalar(Column, defaults, c) != null;
            } else for (saved.items) |n| {
                if (std.mem.eql(u8, n, @tagName(c))) self.visible[i] = true;
            }
        }
        self.visible[@intFromEnum(Column.name)] = true;
        // Columns added to the defaults after a choice was saved show once;
        // hidden again, they stay hidden.
        var added = common.state.loadList(self.gpa, "tasks.state", self.name, "defaults-applied") catch std.ArrayList([]u8).empty;
        defer common.state.freeList(self.gpa, &added);
        var changed = false;
        for (defaults) |c| {
            const done = for (added.items) |n| {
                if (std.mem.eql(u8, n, @tagName(c))) break true;
            } else false;
            if (done) continue;
            self.visible[@intFromEnum(c)] = true;
            added.append(self.gpa, self.gpa.dupe(u8, @tagName(c)) catch continue) catch continue;
            changed = true;
        }
        if (changed) common.state.saveList(self.gpa, "tasks.state", self.name, "defaults-applied", added.items) catch {};
        var sort = common.state.loadList(self.gpa, "tasks.state", self.name, "sort") catch std.ArrayList([]u8).empty;
        defer common.state.freeList(self.gpa, &sort);
        if (sort.items.len >= 1) {
            if (std.meta.stringToEnum(Column, sort.items[0])) |c| self.sort_by = c;
        }
        if (sort.items.len >= 2) self.sort_reverse = std.mem.eql(u8, sort.items[1], "reverse");
        var mode = common.state.loadList(self.gpa, "tasks.state", self.name, "mode") catch std.ArrayList([]u8).empty;
        defer common.state.freeList(self.gpa, &mode);
        if (mode.items.len == 1 and self.mode != .flat) {
            if (std.meta.stringToEnum(Mode, mode.items[0])) |m| if (m != .flat) {
                self.mode = m;
            };
        }
    }

    fn savedWidth(self: *Table, c: Column) ?c_int {
        var widths = common.state.loadList(self.gpa, "tasks.state", self.name, "widths") catch return null;
        defer common.state.freeList(self.gpa, &widths);
        for (widths.items) |w| {
            const eq = std.mem.indexOfScalar(u8, w, '=') orelse continue;
            if (!std.mem.eql(u8, w[0..eq], @tagName(c))) continue;
            const v = std.fmt.parseInt(c_int, w[eq + 1 ..], 10) catch return null;
            return if (v >= 30 and v < 2000) v else null;
        }
        return null;
    }

    fn saveState(self: *Table) void {
        const a = self.gpa;
        var names: std.ArrayList([]u8) = .empty;
        defer names.deinit(a);
        var widths: std.ArrayList([]u8) = .empty;
        defer {
            for (widths.items) |w| a.free(w);
            widths.deinit(a);
        }
        for (self.offered) |c| {
            if (self.visible[@intFromEnum(c)]) names.append(a, @constCast(@tagName(c))) catch return;
            const col = self.cols[@intFromEnum(c)] orelse continue;
            const w = col.getFixedWidth();
            if (w > 0) widths.append(a, std.fmt.allocPrint(a, "{s}={d}", .{ @tagName(c), w }) catch continue) catch {};
        }
        common.state.saveList(a, "tasks.state", self.name, "columns", names.items) catch {};
        common.state.saveList(a, "tasks.state", self.name, "widths", widths.items) catch {};
        var sort = [_][]u8{ @constCast(@tagName(self.sort_by)), @constCast(if (self.sort_reverse) "reverse" else "natural") };
        common.state.saveList(a, "tasks.state", self.name, "sort", &sort) catch {};
        var mode = [_][]u8{@constCast(@tagName(self.mode))};
        common.state.saveList(a, "tasks.state", self.name, "mode", &mode) catch {};
    }

    /// Shows or hides a column (from the View menu, or the header's menu).
    pub fn setColumn(self: *Table, c: Column, on: bool) void {
        if (c == .name) return;
        self.visible[@intFromEnum(c)] = on;
        if (self.cols[@intFromEnum(c)]) |col| col.setVisible(@intFromBool(on));
        var ab: [48]u8 = undefined;
        const name = std.fmt.bufPrintSentinel(&ab, "col-{s}", .{@tagName(c)}, 0) catch return;
        if (self.action_group.as(gio.ActionMap).lookupAction(name)) |found| {
            const simple: *gio.SimpleAction = @ptrCast(@alignCast(found));
            simple.setState(glib.Variant.newBoolean(@intFromBool(on)));
        }
        self.saveState();
        self.render();
    }

    fn onColumnToggled(action: *gio.SimpleAction, value: ?*glib.Variant, self: *Table) callconv(.c) void {
        const v = value orelse return;
        const name = std.mem.span(action.as(gio.Action).getName());
        const c = std.meta.stringToEnum(Column, name["col-".len..]) orelse return;
        self.setColumn(c, v.getBoolean() != 0);
    }

    /// The View menu's column choices: the same actions as the header menu.
    pub fn columnMenu(self: *Table) *gio.Menu {
        const menu = gio.Menu.new();
        for (self.offered) |c| {
            if (c == .name) continue;
            var ab: [48]u8 = undefined;
            menu.append(c.title(), std.fmt.bufPrintSentinel(&ab, "table.col-{s}", .{@tagName(c)}, 0) catch continue);
        }
        return menu;
    }

    pub fn setMode(self: *Table, mode: Mode) void {
        self.mode = mode;
        self.saveState();
        self.rebuild();
    }

    pub fn setQuery(self: *Table, text: []const u8) void {
        const n = @min(text.len, self.query.len);
        for (text[0..n], 0..) |ch, i| self.query[i] = std.ascii.toLower(ch);
        self.query_len = n;
        self.rebuild();
    }

    fn matches(self: *Table, p: *const Process) bool {
        if (self.query_len == 0) return true;
        const query = self.query[0..self.query_len];
        const app_name: []const u8 = if (p.app) |e| e.nameSlice() else "";
        for ([_][]const u8{ p.nameSlice(), p.cmdSlice(), app_name, p.userSlice(), p.unitSlice() }) |text| {
            if (std.ascii.findIgnoreCase(text, query) != null) return true;
        }
        var pb: [16]u8 = undefined;
        return std.mem.indexOf(u8, std.fmt.bufPrint(&pb, "{d}", .{p.pid}) catch "", query) != null;
    }

    // ---- rows -----------------------------------------------------------------------------

    fn processFor(self: *const Table, row: Row) ?*const Process {
        if (row.aggregate) if (self.aggregates.getPtr(row.pid)) |p| return p;
        return self.sampler.processes.getPtr(row.pid);
    }

    const SortCtx = struct {
        table: *const Table,
        aggregate: bool,
        fn lt(ctx: SortCtx, a: u32, b: u32) bool {
            const pa = ctx.get(a) orelse return false;
            const pb = ctx.get(b) orelse return true;
            return columns.less(ctx.table.sampler, pa, pb, ctx.table.sort_by, ctx.table.sort_reverse);
        }
        fn get(ctx: SortCtx, pid: u32) ?*const Process {
            if (ctx.aggregate) if (ctx.table.aggregates.getPtr(pid)) |p| return p;
            return ctx.table.sampler.processes.getPtr(pid);
        }
    };

    fn sortPids(self: *const Table, pids: []u32, summed: bool) void {
        std.mem.sort(u32, pids, SortCtx{ .table = self, .aggregate = summed }, SortCtx.lt);
    }

    /// Each app's processes summed into one row's figures.
    fn sumApps(self: *Table, members: *const std.AutoHashMapUnmanaged(u32, std.ArrayList(u32))) void {
        self.aggregates.clearRetainingCapacity();
        var it = members.iterator();
        while (it.next()) |e| {
            const root = self.sampler.processes.getPtr(e.key_ptr.*) orelse continue;
            var sum = root.*;
            if (root.app) |app| sampler_mod.copyInto(&sum.name, &sum.name_len, app.nameSlice());
            for (e.value_ptr.items) |pid| {
                const p = self.sampler.processes.getPtr(pid) orelse continue;
                sum.cpu += p.cpu;
                sum.private_kb += p.private_kb;
                sum.rss_kb += p.rss_kb;
                sum.swap_kb += p.swap_kb;
                sum.disk_rate += p.disk_rate;
                sum.read_bytes += p.read_bytes;
                sum.write_bytes += p.write_bytes;
                sum.threads += p.threads;
                sum.ticks += p.ticks;
                sum.gpu = @max(sum.gpu, p.gpu);
                sum.gpu_mem_kb += p.gpu_mem_kb;
                sum.has_gpu = sum.has_gpu or p.has_gpu;
                // An app is suspended only when all of it is.
                if (p.state != 'T' and p.state != 't' and (sum.state == 'T' or sum.state == 't')) sum.state = p.state;
            }
            self.aggregates.put(self.gpa, e.key_ptr.*, sum) catch {};
        }
    }

    /// Works the rows out again and brings the list up to date.
    pub fn rebuild(self: *Table) void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var rows: std.ArrayList(Row) = .empty;
        defer rows.deinit(self.gpa);
        const s = self.sampler;

        const searching = self.query_len > 0;
        const mode: Mode = if (searching and self.mode == .tree) .flat else self.mode;
        switch (mode) {
            .flat => {
                var pids: std.ArrayList(u32) = .empty;
                var it = s.processes.valueIterator();
                while (it.next()) |p| if (self.matches(p)) pids.append(arena, p.pid) catch return;
                self.sortPids(pids.items, false);
                for (pids.items) |pid| rows.append(self.gpa, .{ .pid = pid, .kind = s.processes.getPtr(pid).?.kind }) catch return;
            },
            .grouped => {
                // Each app's processes other than its main one.
                var members: std.AutoHashMapUnmanaged(u32, std.ArrayList(u32)) = .empty;
                var by_kind: [3]std.ArrayList(u32) = @splat(.empty);
                var it = s.processes.valueIterator();
                while (it.next()) |p| {
                    if (p.kind == .app and p.group != 0) {
                        const e = members.getOrPut(arena, p.group) catch return;
                        if (!e.found_existing) e.value_ptr.* = .empty;
                        if (p.group != p.pid) e.value_ptr.append(arena, p.pid) catch return;
                    }
                }
                self.sumApps(&members);
                it = s.processes.valueIterator();
                while (it.next()) |p| {
                    const top = p.kind != .app or p.group == p.pid or p.group == 0;
                    if (!top) continue;
                    // Searching: an app shows when any of its processes match.
                    if (searching and !self.matches(p)) {
                        const m = members.get(p.pid) orelse continue;
                        const any = for (m.items) |pid| {
                            if (s.processes.getPtr(pid)) |q| if (self.matches(q)) break true;
                        } else false;
                        if (!any) continue;
                    }
                    by_kind[@intFromEnum(p.kind)].append(arena, p.pid) catch return;
                }
                for (&by_kind, 0..) |*list, k| {
                    if (list.items.len == 0) continue;
                    const kind: Kind = @enumFromInt(k);
                    var count: u32 = 0;
                    for (list.items) |pid| count += 1 + if (members.get(pid)) |m| @as(u32, @intCast(m.items.len)) else 0;
                    rows.append(self.gpa, .{ .header = true, .kind = kind, .count = if (kind == .app) @intCast(list.items.len) else count }) catch return;
                    self.sortPids(list.items, kind == .app);
                    for (list.items) |pid| {
                        const m = members.get(pid);
                        const n: u32 = if (m) |x| @intCast(x.items.len) else 0;
                        const open = n > 0 and (searching or self.expanded.contains(pid));
                        rows.append(self.gpa, .{ .pid = pid, .kind = kind, .expandable = n > 0, .expanded = open, .aggregate = m != null, .count = n + 1 }) catch return;
                        if (!open) continue;
                        // The app's own process first, then its helpers.
                        rows.append(self.gpa, .{ .pid = pid, .kind = kind, .depth = 1 }) catch return;
                        self.sortPids(m.?.items, false);
                        for (m.?.items) |child| {
                            if (searching) if (s.processes.getPtr(child)) |q| if (!self.matches(q)) continue;
                            rows.append(self.gpa, .{ .pid = child, .kind = kind, .depth = 1 }) catch return;
                        }
                    }
                }
            },
            .tree => {
                var children: std.AutoHashMapUnmanaged(u32, std.ArrayList(u32)) = .empty;
                var roots: std.ArrayList(u32) = .empty;
                var it = s.processes.valueIterator();
                while (it.next()) |p| {
                    if (p.ppid == 0 or p.ppid == p.pid or !s.processes.contains(p.ppid)) {
                        roots.append(arena, p.pid) catch return;
                        continue;
                    }
                    const e = children.getOrPut(arena, p.ppid) catch return;
                    if (!e.found_existing) e.value_ptr.* = .empty;
                    e.value_ptr.append(arena, p.pid) catch return;
                }
                self.sortPids(roots.items, false);
                for (roots.items) |pid| self.addTree(&rows, &children, pid, 0) catch return;
            },
        }
        self.apply(rows.items);
    }

    fn addTree(self: *Table, rows: *std.ArrayList(Row), children: *std.AutoHashMapUnmanaged(u32, std.ArrayList(u32)), pid: u32, depth: u8) !void {
        const kids = children.getPtr(pid);
        const n: usize = if (kids) |k| k.items.len else 0;
        const open = n > 0 and self.expanded.contains(pid);
        const kind = if (self.sampler.processes.getPtr(pid)) |p| p.kind else .system;
        try rows.append(self.gpa, .{ .pid = pid, .kind = kind, .depth = depth, .expandable = n > 0, .expanded = open, .count = @intCast(n) });
        if (!open or depth > 40) return;
        self.sortPids(kids.?.items, false);
        for (kids.?.items) |child| try self.addTree(rows, children, child, depth + 1);
    }

    /// Replaces only the rows that changed, keeping the selection.
    fn apply(self: *Table, new: []const Row) void {
        const selected: ?Row = self.selectedRow();
        const old = self.rows.items;
        var prefix: usize = 0;
        while (prefix < old.len and prefix < new.len and old[prefix].same(new[prefix])) prefix += 1;
        var suffix: usize = 0;
        while (suffix < old.len - prefix and suffix < new.len - prefix and old[old.len - 1 - suffix].same(new[new.len - 1 - suffix])) suffix += 1;
        const removed = old.len - prefix - suffix;
        const added = new.len - prefix - suffix;
        self.rows.clearRetainingCapacity();
        self.rows.appendSlice(self.gpa, new) catch return;
        if (removed > 0 or added > 0) {
            const blanks = self.gpa.alloc(?[*:0]const u8, added + 1) catch return;
            defer self.gpa.free(blanks);
            @memset(blanks[0..added], "");
            blanks[added] = null;
            self.model.splice(@intCast(prefix), @intCast(removed), @ptrCast(blanks.ptr));
        }
        if (selected) |sel| {
            const want = for (self.rows.items, 0..) |r, i| {
                if (r.header == sel.header and r.pid == sel.pid and r.depth == sel.depth and r.kind == sel.kind) break i;
            } else null;
            if (want) |i| {
                if (self.selection.getSelected() != i) self.selection.setSelected(@intCast(i));
            } else _ = self.selection.as(gtk.SelectionModel).unselectAll();
        }
        self.render();
    }

    /// Writes the figures into every cell on screen.
    pub fn render(self: *Table) void {
        for (self.cells.items) |cell| self.renderCell(cell);
        if (self.totals) self.renderTotals();
    }

    fn renderTotals(self: *Table) void {
        const s = self.sampler;
        var b: [64]u8 = undefined;
        var rb: [32]u8 = undefined;
        if (self.cols[@intFromEnum(Column.cpu)]) |c| c.setTitle(std.fmt.bufPrintSentinel(&b, "{d:.0}%\n{s}", .{ s.cpu_total, t("CPU") }, 0) catch "CPU");
        if (self.cols[@intFromEnum(Column.memory)]) |c| c.setTitle(std.fmt.bufPrintSentinel(&b, "{d:.0}%\n{s}", .{ s.mem_used_fraction * 100, t("Memory") }, 0) catch "Memory");
        if (self.cols[@intFromEnum(Column.disk)]) |c| c.setTitle(std.fmt.bufPrintSentinel(&b, "{s}\n{s}", .{ perf.fmtByteRate(&rb, s.disk_total_rate), t("Disk") }, 0) catch "Disk");
        if (self.cols[@intFromEnum(Column.gpu)]) |c| {
            var best: ?f64 = null;
            for (s.loads.items) |*l| best = @max(best orelse 0, l.busy(s.load_elapsed_ns));
            if (best) |v| {
                c.setTitle(std.fmt.bufPrintSentinel(&b, "{d:.0}%\n{s}", .{ v * 100, t("GPU") }, 0) catch "GPU");
            } else c.setTitle(std.fmt.bufPrintSentinel(&b, "\n{s}", .{t("GPU")}, 0) catch "GPU");
        }
    }

    fn renderCell(self: *Table, cell: *Cell) void {
        if (cell.item.getItem() == null) return;
        const pos = cell.item.getPosition();
        if (pos >= self.rows.items.len) return;
        const row = self.rows.items[pos];
        const label = cell.label;
        const widget = label.as(gtk.Widget);
        if (row.header) {
            columns.applyHeat(widget, 0);
            if (cell.column != .name) return label.setText("");
            var b: [64]u8 = undefined;
            const title: [:0]const u8 = switch (row.kind) {
                .app => "Apps",
                .background => "Background processes",
                .system => "System processes",
            };
            label.setText(std.fmt.bufPrintSentinel(&b, "{s} ({d})", .{ title, row.count }, 0) catch "");
            widget.addCssClass("dkde-group-header");
            if (cell.expander) |e| e.as(gtk.Widget).setVisible(0);
            if (cell.icon) |i| i.as(gtk.Widget).setVisible(0);
            if (cell.box) |bx| bx.as(gtk.Widget).setMarginStart(0);
            return;
        }
        widget.removeCssClass("dkde-group-header");
        const p = self.processFor(row) orelse return label.setText("");
        var scratch: [256]u8 = undefined;
        var buf: [320]u8 = undefined;
        const raw = columns.text(&scratch, self.sampler, p, cell.column);
        const clipped = raw[0..@min(raw.len, 280)];
        const shown = if (cell.column == .name and row.aggregate and row.count > 1)
            std.fmt.bufPrintSentinel(&buf, "{s} ({d})", .{ clipped, row.count }, 0) catch ""
        else
            std.fmt.bufPrintSentinel(&buf, "{s}", .{clipped}, 0) catch "";
        label.setText(shown);
        columns.applyHeat(widget, columns.heat(p, cell.column));
        if (cell.column == .name) self.renderName(cell, row, p);
    }

    fn renderName(self: *Table, cell: *Cell, row: Row, p: *const Process) void {
        _ = self;
        const box = cell.box orelse return;
        box.as(gtk.Widget).setMarginStart(@as(c_int, row.depth) * 18);
        if (cell.expander) |e| {
            e.as(gtk.Widget).setVisible(1);
            e.as(gtk.Widget).setOpacity(if (row.expandable) 1 else 0);
            e.as(gtk.Widget).setCanTarget(@intFromBool(row.expandable));
            e.setIconName(if (row.expanded) "pan-down-symbolic" else "pan-end-symbolic");
        }
        const icon = cell.icon orelse return;
        // Helpers under an app need no icon of their own.
        const name: []const u8 = if (row.depth > 0 and row.kind == .app)
            ""
        else if (p.app) |a|
            a.iconSlice()
        else if (p.isKernel())
            "system-run-symbolic"
        else if (row.kind == .system)
            "system-run"
        else
            "application-x-executable";
        if (!std.mem.eql(u8, std.mem.sliceTo(&cell.icon_name, 0), name)) {
            @memset(&cell.icon_name, 0);
            @memcpy(cell.icon_name[0..@min(name.len, cell.icon_name.len - 1)], name[0..@min(name.len, cell.icon_name.len - 1)]);
            if (name.len == 0) {
                icon.clear();
            } else if (name[0] == '/') {
                icon.setFromFile(@ptrCast(&cell.icon_name));
            } else {
                // A themed name, with stand-ins for themes that lack it.
                var names = [_:null]?[*:0]const u8{ @ptrCast(&cell.icon_name), "application-x-executable", "application-x-executable-symbolic", "system-run-symbolic" };
                const gi = gio.ThemedIcon.newFromNames(@ptrCast(&names), names.len);
                defer gi.as(gobject.Object).unref();
                icon.setFromGicon(gi.as(gio.Icon));
            }
        }
        icon.as(gtk.Widget).setVisible(1);
    }

    // ---- cells --------------------------------------------------------------------------

    fn onSetup(_: *gtk.SignalListItemFactory, obj: *gobject.Object, ctx: *ColumnCtx) callconv(.c) void {
        const self = ctx.table;
        const item: *gtk.ListItem = @ptrCast(obj);
        const cell = self.gpa.create(Cell) catch return;
        const label = gtk.Label.new(null);
        label.setXalign(if (ctx.column.rightAligned()) 1 else 0);
        label.setEllipsize(.end);
        cell.* = .{ .table = self, .item = item, .column = ctx.column, .label = label };
        var child = label.as(gtk.Widget);
        if (ctx.column == .name) {
            const box = gtk.Box.new(.horizontal, 4);
            const expander = gtk.Button.newFromIconName("pan-end-symbolic");
            expander.setHasFrame(0);
            expander.as(gtk.Widget).addCssClass("dkde-expander");
            expander.as(gtk.Widget).setFocusable(0);
            _ = gtk.Button.signals.clicked.connect(expander, *Cell, &onExpander, cell, .{});
            const icon = gtk.Image.new();
            icon.setPixelSize(16);
            label.as(gtk.Widget).setHexpand(1);
            box.append(expander.as(gtk.Widget));
            box.append(icon.as(gtk.Widget));
            box.append(label.as(gtk.Widget));
            cell.expander = expander;
            cell.icon = icon;
            cell.box = box;
            child = box.as(gtk.Widget);
        }
        // The list's right-click finds the cell through this.
        child.as(gobject.Object).setData("dkde-cell", cell);
        item.setChild(child);
        self.cells.append(self.gpa, cell) catch {};
        item.as(gobject.Object).setData("dkde-cell", cell);
    }

    fn onBind(_: *gtk.SignalListItemFactory, obj: *gobject.Object, ctx: *ColumnCtx) callconv(.c) void {
        const item: *gtk.ListItem = @ptrCast(obj);
        const raw = item.as(gobject.Object).getData("dkde-cell") orelse return;
        ctx.table.renderCell(@ptrCast(@alignCast(raw)));
    }

    fn onTeardown(_: *gtk.SignalListItemFactory, obj: *gobject.Object, ctx: *ColumnCtx) callconv(.c) void {
        const self = ctx.table;
        const item: *gtk.ListItem = @ptrCast(obj);
        const raw = item.as(gobject.Object).getData("dkde-cell") orelse return;
        const cell: *Cell = @ptrCast(@alignCast(raw));
        if (std.mem.indexOfScalar(*Cell, self.cells.items, cell)) |i| _ = self.cells.swapRemove(i);
        item.as(gobject.Object).setData("dkde-cell", null);
        if (item.getChild()) |w| w.as(gobject.Object).setData("dkde-cell", null);
        self.gpa.destroy(cell);
    }

    fn onExpander(_: *gtk.Button, cell: *Cell) callconv(.c) void {
        const self = cell.table;
        const pos = cell.item.getPosition();
        if (pos >= self.rows.items.len) return;
        self.toggle(self.rows.items[pos]);
    }

    fn toggle(self: *Table, row: Row) void {
        if (!row.expandable) return;
        if (self.expanded.contains(row.pid)) {
            _ = self.expanded.remove(row.pid);
        } else self.expanded.put(self.gpa, row.pid, {}) catch return;
        self.rebuild();
    }

    fn onActivate(_: *gtk.ColumnView, pos: c_uint, self: *Table) callconv(.c) void {
        if (pos >= self.rows.items.len) return;
        const row = self.rows.items[pos];
        if (row.expandable) return self.toggle(row);
        if (!row.header) self.actions.properties(row.pid);
    }

    fn onSortChanged(sorter: *gtk.Sorter, _: gtk.SorterChange, self: *Table) callconv(.c) void {
        const view_sorter: *gtk.ColumnViewSorter = @ptrCast(sorter);
        const column = view_sorter.getPrimarySortColumn() orelse return;
        const ascending = view_sorter.getPrimarySortOrder() == .ascending;
        for (self.offered) |c| {
            if (self.cols[@intFromEnum(c)] != column) continue;
            self.sort_by = c;
            // Figures list the biggest first, names and ids the smallest.
            self.sort_reverse = if (c.bigFirst()) ascending else !ascending;
            self.saveState();
            self.rebuild();
            return;
        }
    }

    fn onSelectionChanged(_: *gtk.SelectionModel, _: c_uint, _: c_uint, self: *Table) callconv(.c) void {
        if (self.on_selection) |f| f(self.owner);
    }

    // ---- selection and the row menu ---------------------------------------------

    fn selectedRow(self: *const Table) ?Row {
        const pos = self.selection.getSelected();
        if (pos == gtk.INVALID_LIST_POSITION or pos >= self.rows.items.len) return null;
        return self.rows.items[pos];
    }

    /// The selected process (an app's row gives its main process).
    pub fn selectedPid(self: *const Table) ?u32 {
        const row = self.selectedRow() orelse return null;
        if (row.header) return null;
        return row.pid;
    }

    /// Whether the selection is a whole app (ending it ends its helpers too).
    pub fn selectedIsApp(self: *const Table) bool {
        const row = self.selectedRow() orelse return false;
        return row.aggregate;
    }

    pub fn selectPid(self: *Table, pid: u32) void {
        for (self.rows.items, 0..) |r, i| if (!r.header and r.pid == pid) {
            self.selection.setSelected(@intCast(i));
            self.view.scrollTo(@intCast(i), null, .{ .focus = true, .select = true }, null);
            return;
        };
    }

    /// End task: an app ends with all its processes, as in Windows.
    pub fn endSelected(self: *Table) void {
        const pid = self.selectedPid() orelse return;
        if (self.selectedIsApp()) return self.actions.endTree(pid);
        self.actions.signal(pid, actions_mod.SIGTERM);
    }

    fn buildMenu(self: *Table) void {
        const m = self.menu;
        const first = gio.Menu.new();
        first.append(t("End task"), "table.end");
        first.append(t("End process tree"), "table.end-tree");
        first.append(t("Force quit…"), "table.force");
        m.appendSection(null, first.as(gio.MenuModel));
        first.as(gobject.Object).unref();
        const second = gio.Menu.new();
        second.append(t("Suspend"), "table.suspend");
        second.append(t("Resume"), "table.resume");
        second.append(t("Efficiency mode"), "table.efficiency");
        const prio = gio.Menu.new();
        for (columns.priorities) |pr| {
            var db: [48]u8 = undefined;
            prio.append(pr.label, std.fmt.bufPrintSentinel(&db, "table.priority({d})", .{pr.nice}, 0) catch continue);
        }
        second.appendSubmenu(t("Set priority"), prio.as(gio.MenuModel));
        prio.as(gobject.Object).unref();
        const io = gio.Menu.new();
        io.append(t("High"), "table.io-priority('high')");
        io.append(t("Normal"), "table.io-priority('normal')");
        io.append(t("Low"), "table.io-priority('low')");
        io.append(t("Idle (background)"), "table.io-priority('idle')");
        second.appendSubmenu(t("Set disk priority"), io.as(gio.MenuModel));
        io.as(gobject.Object).unref();
        second.append(t("Set processors…"), "table.affinity");
        m.appendSection(null, second.as(gio.MenuModel));
        second.as(gobject.Object).unref();
        const third = gio.Menu.new();
        third.append(t("Open file location"), "table.open-location");
        third.append(t("Go to details"), "table.goto-details");
        third.append(t("Go to service"), "table.goto-service");
        third.append(t("Properties"), "table.properties");
        const copy = gio.Menu.new();
        copy.append(t("Name"), "table.copy-text('name')");
        copy.append(t("PID"), "table.copy-text('pid')");
        copy.append(t("Command line"), "table.copy-text('command')");
        copy.append(t("Program file"), "table.copy-text('path')");
        third.appendSubmenu(t("Copy"), copy.as(gio.MenuModel));
        copy.as(gobject.Object).unref();
        m.appendSection(null, third.as(gio.MenuModel));
        third.as(gobject.Object).unref();

        const simple = [_][:0]const u8{ "end", "end-tree", "force", "suspend", "resume", "affinity", "open-location", "goto-details", "goto-service", "properties" };
        for (simple) |name| self.addAction(name, null);
        self.addAction("priority", glib.VariantType.new("i"));
        self.addAction("io-priority", glib.VariantType.new("s"));
        self.addAction("copy-text", glib.VariantType.new("s"));
        const eff = gio.SimpleAction.newStateful("efficiency", null, glib.Variant.newBoolean(0));
        _ = gio.SimpleAction.signals.activate.connect(eff, *Table, &onRowAction, self, .{});
        self.action_group.as(gio.ActionMap).addAction(eff.as(gio.Action));
        eff.as(gobject.Object).unref();
    }

    fn addAction(self: *Table, name: [:0]const u8, param: ?*const glib.VariantType) void {
        const action = gio.SimpleAction.new(name, param);
        _ = gio.SimpleAction.signals.activate.connect(action, *Table, &onRowAction, self, .{});
        self.action_group.as(gio.ActionMap).addAction(action.as(gio.Action));
        action.as(gobject.Object).unref();
    }

    fn enable(self: *Table, name: [:0]const u8, on: bool) void {
        const found = self.action_group.as(gio.ActionMap).lookupAction(name) orelse return;
        const simple: *gio.SimpleAction = @ptrCast(@alignCast(found));
        simple.setEnabled(@intFromBool(on));
    }

    fn onRightClick(_: *gtk.GestureClick, _: c_int, x: f64, y: f64, self: *Table) callconv(.c) void {
        const raw = @import("simplelist.zig").cellAt(self.view.as(gtk.Widget), x, y) orelse return;
        const cell: *Cell = @ptrCast(@alignCast(raw));
        const pos = cell.item.getPosition();
        if (pos >= self.rows.items.len or self.rows.items[pos].header) return;
        self.selection.setSelected(pos);
        self.popupMenu(x, y);
    }

    pub fn popupMenu(self: *Table, x: f64, y: f64) void {
        const pid = self.selectedPid() orelse return;
        const p = self.sampler.processes.getPtr(pid) orelse return;
        const suspended = p.state == 'T' or p.state == 't';
        self.enable("suspend", !suspended);
        self.enable("resume", suspended);
        self.enable("open-location", p.path_len > 0);
        self.enable("goto-service", p.unit_len > 0);
        self.enable("goto-details", std.mem.eql(u8, self.name, "processes"));
        if (self.action_group.as(gio.ActionMap).lookupAction("efficiency")) |found| {
            const simple: *gio.SimpleAction = @ptrCast(@alignCast(found));
            simple.setState(glib.Variant.newBoolean(@intFromBool(p.efficient())));
        }
        const popover = gtk.PopoverMenu.newFromModel(self.menu.as(gio.MenuModel));
        popover.as(gtk.Widget).setParent(self.view.as(gtk.Widget));
        popover.as(gtk.Popover).setHasArrow(0);
        const rect: gdk.Rectangle = .{ .f_x = @intFromFloat(x), .f_y = @intFromFloat(y), .f_width = 1, .f_height = 1 };
        popover.as(gtk.Popover).setPointingTo(&rect);
        popover.as(gtk.Widget).setHalign(.start);
        _ = gtk.Popover.signals.closed.connect(popover.as(gtk.Popover), ?*anyopaque, &onMenuClosed, null, .{});
        popover.as(gtk.Popover).popup();
    }

    fn onMenuClosed(popover: *gtk.Popover, _: ?*anyopaque) callconv(.c) void {
        // After the chosen action has run.
        _ = glib.idleAdd(unparentLater, popover);
    }

    fn unparentLater(data: ?*anyopaque) callconv(.c) c_int {
        const popover: *gtk.Widget = @ptrCast(@alignCast(data.?));
        popover.unparent();
        return 0;
    }

    fn onRowAction(action: *gio.SimpleAction, param: ?*glib.Variant, self: *Table) callconv(.c) void {
        const name = std.mem.span(action.as(gio.Action).getName());
        const pid = self.selectedPid() orelse return;
        const acts = self.actions;
        const eql = std.mem.eql;
        if (eql(u8, name, "end")) return self.endSelected();
        if (eql(u8, name, "end-tree")) return acts.endTree(pid);
        if (eql(u8, name, "force")) return acts.forceQuit(pid);
        if (eql(u8, name, "suspend")) return acts.signal(pid, actions_mod.SIGSTOP);
        if (eql(u8, name, "resume")) return acts.signal(pid, actions_mod.SIGCONT);
        if (eql(u8, name, "efficiency")) return acts.toggleEfficiency(pid);
        if (eql(u8, name, "affinity")) return acts.affinity(pid);
        if (eql(u8, name, "open-location")) return acts.openLocation(pid);
        if (eql(u8, name, "properties")) return acts.properties(pid);
        if (eql(u8, name, "goto-details")) return if (self.on_goto) |f| f(self.owner, .details, pid);
        if (eql(u8, name, "goto-service")) return if (self.on_goto) |f| f(self.owner, .service, pid);
        if (eql(u8, name, "priority")) return acts.setPriority(pid, param.?.getInt32());
        if (eql(u8, name, "io-priority")) {
            const v = std.mem.span(param.?.getString(null));
            if (eql(u8, v, "high")) return acts.setIoPriority(pid, .best_effort, 0);
            if (eql(u8, v, "low")) return acts.setIoPriority(pid, .best_effort, 7);
            if (eql(u8, v, "idle")) return acts.setIoPriority(pid, .idle, 0);
            return acts.setIoPriority(pid, .best_effort, 4);
        }
        if (eql(u8, name, "copy-text")) {
            const p = self.sampler.processes.getPtr(pid) orelse return;
            const what = std.mem.span(param.?.getString(null));
            var buf: [300]u8 = undefined;
            const text: []const u8 = if (eql(u8, what, "pid"))
                std.fmt.bufPrint(&buf, "{d}", .{pid}) catch return
            else if (eql(u8, what, "command"))
                p.cmdSlice()
            else if (eql(u8, what, "path"))
                p.pathSlice()
            else if (self.selectedIsApp() and p.app != null)
                p.app.?.nameSlice()
            else
                p.nameSlice();
            var zb: [300]u8 = undefined;
            const z = std.fmt.bufPrintSentinel(&zb, "{s}", .{text[0..@min(text.len, 290)]}, 0) catch return;
            self.view.as(gtk.Widget).getClipboard().setText(z);
        }
    }
};
