//! The Performance tab: a list of resources (CPU, memory, each disk, each
//! network adapter, each GPU) on the left, and on the right the graph and the
//! figures for the selected one, laid out as in the Windows 11 Task Manager.

const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const cairo = @import("cairo1");
const gtk = @import("gtk4");
const common = @import("common");

const perf = @import("perf.zig");

extern fn sysconf(name: c_int) c_long;
const SC_NPROCESSORS_ONLN = 84;

const Ifaddrs = extern struct {
    next: ?*Ifaddrs,
    name: [*:0]const u8,
    flags: c_uint,
    addr: ?*const SockAddr,
};
const SockAddr = extern struct { family: u16, data: [14]u8 };
extern fn getifaddrs(ifap: *?*Ifaddrs) c_int;
extern fn freeifaddrs(ifa: ?*Ifaddrs) void;
const AF_INET = 2;
const AF_INET6 = 10;

const history_len = 60;
const max_cores = 256;
const Rgb = [3]f64;

const colors = struct {
    const cpu: Rgb = .{ 0.07, 0.55, 0.82 };
    const memory: Rgb = .{ 0.55, 0.30, 0.75 };
    const disk: Rgb = .{ 0.30, 0.65, 0.25 };
    const network: Rgb = .{ 0.85, 0.50, 0.15 };
    const gpu: Rgb = .{ 0.20, 0.50, 0.85 };
};

// ---- small file helpers ----------------------------------------------------------

fn readSmall(path: []const u8, buf: []u8) ?[]const u8 {
    var pbuf: [256]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&pbuf, "{s}", .{path}, 0) catch return null;
    var contents: [*]u8 = undefined;
    var length: usize = 0;
    if (glib.fileGetContents(z, &contents, &length, null) == 0) return null;
    defer glib.free(contents);
    const n = @min(length, buf.len);
    @memcpy(buf[0..n], contents[0..n]);
    return std.mem.trim(u8, buf[0..n], " \t\r\n");
}

fn readAlloc(allocator: std.mem.Allocator, path: [:0]const u8) ?[]u8 {
    var contents: [*]u8 = undefined;
    var length: usize = 0;
    if (glib.fileGetContents(path, &contents, &length, null) == 0) return null;
    defer glib.free(contents);
    return allocator.dupe(u8, contents[0..length]) catch null;
}

fn readInt(comptime fmt: []const u8, args: anytype) ?u64 {
    var pbuf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, fmt, args) catch return null;
    var buf: [32]u8 = undefined;
    return std.fmt.parseInt(u64, readSmall(path, &buf) orelse return null, 10) catch null;
}

fn pathExists(comptime fmt: []const u8, args: anytype) bool {
    var pbuf: [256]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&pbuf, fmt, args, 0) catch return false;
    return glib.fileTest(path, .{ .exists = true }) != 0;
}

/// Last component of the symlink at the path, e.g. a driver's name.
fn linkBase(comptime fmt: []const u8, args: anytype, out: []u8) ?[]const u8 {
    var pbuf: [256]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&pbuf, fmt, args, 0) catch return null;
    const target = glib.fileReadLink(path, null) orelse return null;
    defer glib.free(target);
    const base = std.fs.path.basename(std.mem.span(target));
    const n = @min(base.len, out.len);
    @memcpy(out[0..n], base[0..n]);
    return out[0..n];
}

fn setText(label: *gtk.Label, comptime fmt: []const u8, args: anytype) void {
    var buf: [160]u8 = undefined;
    label.setText(std.fmt.bufPrintSentinel(&buf, fmt, args, 0) catch "");
}

fn setSlice(label: *gtk.Label, text: []const u8) void {
    var buf: [160]u8 = undefined;
    label.setText(std.fmt.bufPrintSentinel(&buf, "{s}", .{text}, 0) catch "");
}

// ---- graph -----------------------------------------------------------------------

const Unit = enum { percent, bytes_rate, bits_rate, fixed };

/// A rolling history of one or two series, drawn by any number of areas (the
/// big graph and the thumbnail in the list).
const Graph = struct {
    color: Rgb,
    unit: Unit,
    series: u8,
    /// Smallest top of the scale for rates.
    floor: f64,
    data: [2][history_len]f64 = @splat(@splat(0)),
    filled: usize = 0,
    scale: f64 = 100,
    areas: [3]?*gtk.DrawingArea = @splat(null),
    max_label: ?*gtk.Label = null,

    fn create(allocator: std.mem.Allocator, color: Rgb, unit: Unit, series: u8, floor: f64) *Graph {
        const g = allocator.create(Graph) catch @panic("OOM");
        g.* = .{ .color = color, .unit = unit, .series = series, .floor = floor };
        if (unit == .percent) g.scale = 100;
        return g;
    }

    /// A new drawing area showing this graph.
    fn view(self: *Graph, width: c_int, height: c_int) *gtk.DrawingArea {
        const area = gtk.DrawingArea.new();
        area.setContentHeight(height);
        if (width > 0) area.setContentWidth(width);
        area.as(gtk.Widget).setHexpand(@intFromBool(width <= 0));
        area.as(gtk.Widget).setVexpand(@intFromBool(height > 100));
        area.setDrawFunc(onDraw, self, null);
        for (&self.areas) |*slot| if (slot.* == null) {
            slot.* = area;
            break;
        };
        return area;
    }

    /// `a` is the main series; `b` the second (sent, written), when there is one.
    fn push(self: *Graph, a: f64, b: f64) void {
        inline for (0..2) |s| {
            std.mem.copyForwards(f64, self.data[s][0 .. history_len - 1], self.data[s][1..history_len]);
            self.data[s][history_len - 1] = @max(0, if (s == 0) a else b);
        }
        self.filled = @min(self.filled + 1, history_len);
        if (self.unit == .percent) {
            self.scale = 100;
        } else if (self.unit != .fixed) {
            var peak: f64 = 0;
            for (0..self.series) |s| for (self.data[s]) |v| {
                peak = @max(peak, v);
            };
            self.scale = niceMax(@max(peak, self.floor));
        }
        if (self.max_label) |label| {
            var buf: [32]u8 = undefined;
            switch (self.unit) {
                .percent => label.setText("100%"),
                .bytes_rate => setSlice(label, perf.fmtByteRate(&buf, self.scale)),
                .bits_rate => setSlice(label, perf.fmtBitRate(&buf, self.scale)),
                .fixed => {},
            }
        }
        for (self.areas) |area| if (area) |ar| ar.as(gtk.Widget).queueDraw();
    }

    fn onDraw(_: *gtk.DrawingArea, cr: *cairo.Context, width: c_int, height: c_int, data: ?*anyopaque) callconv(.c) void {
        const self: *Graph = @ptrCast(@alignCast(data.?));
        const w: f64 = @floatFromInt(width);
        const h: f64 = @floatFromInt(height);
        const mini = width < 140;
        const c = self.color;
        cr.setSourceRgba(c[0], c[1], c[2], 0.07);
        cr.rectangle(0, 0, w, h);
        cr.fill();

        if (!mini) {
            cr.setSourceRgba(c[0], c[1], c[2], 0.22);
            cr.setLineWidth(1);
            var i: f64 = 1;
            while (i < 4) : (i += 1) {
                cr.moveTo(0, @round(h * i / 4) + 0.5);
                cr.lineTo(w, @round(h * i / 4) + 0.5);
            }
            var x: f64 = w;
            while (x > 0) : (x -= w / 10) {
                cr.moveTo(@round(x) + 0.5, 0);
                cr.lineTo(@round(x) + 0.5, h);
            }
            cr.stroke();
        }

        const step = w / @as(f64, @floatFromInt(history_len - 1));
        const first = history_len - self.filled;
        const scale = if (self.scale > 0) self.scale else 1;
        if (self.filled > 1) {
            var s: usize = self.series;
            while (s > 0) {
                s -= 1;
                cr.newPath();
                for (first..history_len) |i| {
                    const x = @as(f64, @floatFromInt(i)) * step;
                    const y = h - std.math.clamp(self.data[s][i] / scale, 0, 1) * (h - 2) - 1;
                    if (i == first) cr.moveTo(x, y) else cr.lineTo(x, y);
                }
                if (s == 0) {
                    cr.lineTo(w, h);
                    cr.lineTo(@as(f64, @floatFromInt(first)) * step, h);
                    cr.closePath();
                    cr.setSourceRgba(c[0], c[1], c[2], 0.28);
                    cr.fillPreserve();
                    cr.setSourceRgba(c[0], c[1], c[2], 1);
                    cr.setLineWidth(if (mini) 1 else 1.5);
                } else {
                    cr.setSourceRgba(c[0], c[1], c[2], 0.8);
                    cr.setLineWidth(1);
                    const dashes = [_]f64{ 4, 3 };
                    cr.setDash(&dashes, 2, 0);
                }
                cr.stroke();
                cr.setDash(&.{0}, 0, 0);
            }
        }

        cr.setSourceRgba(c[0], c[1], c[2], 0.75);
        cr.setLineWidth(1);
        cr.rectangle(0.5, 0.5, w - 1, h - 1);
        cr.stroke();
    }
};

/// 1, 2, 5 times a power of ten, at or above `v`.
fn niceMax(v: f64) f64 {
    if (v <= 0) return 1;
    const mag = std.math.pow(f64, 10, @floor(std.math.log10(v)));
    const m = v / mag;
    const nice: f64 = if (m <= 1) 1 else if (m <= 2) 2 else if (m <= 5) 5 else 10;
    return nice * mag;
}

/// The memory composition bar: in use, cached, free.
const MemBar = struct {
    area: *gtk.DrawingArea,
    in_use: f64 = 0,
    cached: f64 = 0,

    fn onDraw(_: *gtk.DrawingArea, cr: *cairo.Context, width: c_int, height: c_int, data: ?*anyopaque) callconv(.c) void {
        const self: *MemBar = @ptrCast(@alignCast(data.?));
        const w: f64 = @floatFromInt(width);
        const h: f64 = @floatFromInt(height);
        const c = colors.memory;
        const used_w = w * std.math.clamp(self.in_use, 0, 1);
        const cached_w = w * std.math.clamp(self.cached, 0, 1 - self.in_use);
        cr.setSourceRgba(c[0], c[1], c[2], 0.07);
        cr.rectangle(0, 0, w, h);
        cr.fill();
        cr.setSourceRgba(c[0], c[1], c[2], 0.85);
        cr.rectangle(0, 0, used_w, h);
        cr.fill();
        cr.setSourceRgba(c[0], c[1], c[2], 0.35);
        cr.rectangle(used_w, 0, cached_w, h);
        cr.fill();
        cr.setSourceRgba(c[0], c[1], c[2], 0.75);
        cr.setLineWidth(1);
        cr.rectangle(0.5, 0.5, w - 1, h - 1);
        cr.stroke();
    }
};

// ---- the detail pane -------------------------------------------------------------

const Spec = struct {
    title: [:0]const u8,
    caption_a: [:0]const u8,
    caption_b: ?[:0]const u8 = null,
    big: []const [:0]const u8,
    info: []const [:0]const u8,
    color: Rgb,
    unit_a: Unit,
    series_a: u8 = 1,
    floor_a: f64 = 0,
    unit_b: Unit = .bytes_rate,
    series_b: u8 = 2,
    floor_b: f64 = 100 * 1024,
    /// A second view of graph A, one graph per logical processor.
    cores_toggle: bool = false,
    memory_bar: bool = false,
};

const Detail = struct {
    root: *gtk.Box,
    title: *gtk.Label,
    model: *gtk.Label,
    caption_a: *gtk.Label,
    graph_a: *Graph,
    graph_b: ?*Graph = null,
    stack: ?*gtk.Stack = null,
    cores: ?*gtk.FlowBox = null,
    mem_bar: ?*MemBar = null,
    big: [8]?*gtk.Label = @splat(null),
    info: [14]?*gtk.Label = @splat(null),
};

// ---- resources -------------------------------------------------------------------

const Kind = enum { cpu, memory, disk, ethernet, wifi, gpu };

/// What a rescan looks at: names are unique within a group.
const Group = enum {
    disks,
    network,
    gpus,
    devices,

    fn of(self: Group, kind: Kind) bool {
        return switch (self) {
            .disks => kind == .disk,
            .network => kind == .ethernet or kind == .wifi,
            .gpus => kind == .gpu,
            .devices => kind == .disk or kind == .ethernet or kind == .wifi or kind == .gpu,
        };
    }
};

const Resource = struct {
    kind: Kind,
    name: [32]u8 = undefined,
    name_len: usize = 0,
    detail: *Detail,
    row_title: *gtk.Label,
    row_sub: *gtk.Label,
    /// The row's content; its parent is the list row, hidden while the device is gone.
    row: *gtk.Widget,
    /// Whether the device is there now, and whether the last scan saw it.
    present: bool = true,
    seen: bool = true,
    // Disks.
    prev_disk: ?perf.DiskStat = null,
    // Network.
    prev_net: ?perf.NetBytes = null,
    ssid: [64]u8 = undefined,
    ssid_len: usize = 0,
    // GPUs: hwmon directory of the card, if any.
    hwmon: [96]u8 = undefined,
    hwmon_len: usize = 0,
    has_busy: bool = false,
    has_vram: bool = false,

    fn id(self: *const Resource) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const Perf = struct {
    allocator: std.mem.Allocator,
    widget: *gtk.Widget,
    list: *gtk.ListBox,
    stack: *gtk.Stack,
    resources: std.ArrayList(*Resource) = .empty,
    graphs: std.ArrayList(*Graph) = .empty,
    details: std.ArrayList(*Detail) = .empty,
    mem_bars: std.ArrayList(*MemBar) = .empty,

    cpu_count: usize,
    cpu_model: [96]u8 = undefined,
    cpu_model_len: usize = 0,
    cpuinfo: perf.CpuInfo = .{},
    base_mhz: f64 = 0,
    prev_total: ?perf.CpuTimes = null,
    prev_cores: [max_cores]perf.CpuTimes = undefined,
    prev_core_count: usize = 0,
    core_graphs: [max_cores]?*Graph = @splat(null),
    cache_text: [3][32]u8 = undefined,
    cache_len: [3]usize = .{ 0, 0, 0 },

    prev_us: i64 = 0,
    tick: u32 = 0,
    wifi_guard: ?*common.proc.Guard(Perf) = null,

    pub fn create(allocator: std.mem.Allocator) *Perf {
        const self = allocator.create(Perf) catch @panic("OOM");
        const list = gtk.ListBox.new();
        list.setSelectionMode(.browse);
        list.as(gtk.Widget).addCssClass("dkde-perf-list");
        const stack = gtk.Stack.new();
        stack.as(gtk.Widget).setHexpand(1);
        const side = gtk.ScrolledWindow.new();
        side.setChild(list.as(gtk.Widget));
        side.setPolicy(.never, .automatic);
        side.as(gtk.Widget).setSizeRequest(230, -1);
        const paned = gtk.Paned.new(.horizontal);
        paned.setStartChild(side.as(gtk.Widget));
        paned.setEndChild(stack.as(gtk.Widget));
        paned.setResizeStartChild(0);
        paned.setShrinkStartChild(0);
        paned.setPosition(250);
        self.* = .{
            .allocator = allocator,
            .widget = paned.as(gtk.Widget),
            .list = list,
            .stack = stack,
            .cpu_count = @intCast(@max(1, sysconf(SC_NPROCESSORS_ONLN))),
        };
        self.discover();
        _ = gtk.ListBox.signals.row_selected.connect(list, *Perf, &onRowSelected, self, .{});
        if (list.getRowAtIndex(0)) |row| list.selectRow(row);
        if (self.wifi_guard != null) self.askSsid();
        return self;
    }

    pub fn destroy(self: *Perf) void {
        if (self.wifi_guard) |g| g.kill();
        for (self.resources.items) |r| self.allocator.destroy(r);
        for (self.graphs.items) |g| self.allocator.destroy(g);
        for (self.details.items) |d| self.allocator.destroy(d);
        for (self.mem_bars.items) |m| self.allocator.destroy(m);
        self.resources.deinit(self.allocator);
        self.graphs.deinit(self.allocator);
        self.details.deinit(self.allocator);
        self.mem_bars.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn onRowSelected(_: *gtk.ListBox, row: ?*gtk.ListBoxRow, self: *Perf) callconv(.c) void {
        const r = row orelse return;
        const index: usize = @intCast(r.getIndex());
        if (index >= self.resources.items.len) return;
        var buf: [16]u8 = undefined;
        self.stack.setVisibleChildName(std.fmt.bufPrintSentinel(&buf, "{d}", .{index}, 0) catch return);
    }

    // ---- building ------------------------------------------------------------------

    fn newGraph(self: *Perf, color: Rgb, unit: Unit, series: u8, floor: f64) *Graph {
        const g = Graph.create(self.allocator, color, unit, series, floor);
        self.graphs.append(self.allocator, g) catch @panic("OOM");
        return g;
    }

    fn keyLabel(comptime text: [:0]const u8) *gtk.Label {
        const l = gtk.Label.new(common.tr(text));
        l.setXalign(0);
        l.as(gtk.Widget).addCssClass("dkde-perf-key");
        return l;
    }

    fn valueLabel(css: [:0]const u8) *gtk.Label {
        const l = gtk.Label.new("—");
        l.setXalign(0);
        l.setSelectable(1);
        l.setEllipsize(.end);
        l.as(gtk.Widget).addCssClass(css);
        return l;
    }

    fn buildDetail(self: *Perf, comptime spec: Spec) *Detail {
        const a = self.allocator;
        const d = a.create(Detail) catch @panic("OOM");
        self.details.append(a, d) catch @panic("OOM");

        const root = gtk.Box.new(.vertical, 6);
        root.as(gtk.Widget).setMarginStart(16);
        root.as(gtk.Widget).setMarginEnd(16);
        root.as(gtk.Widget).setMarginTop(12);
        root.as(gtk.Widget).setMarginBottom(12);

        const head = gtk.Box.new(.horizontal, 12);
        const title = gtk.Label.new(common.tr(spec.title));
        title.setXalign(0);
        title.as(gtk.Widget).addCssClass("dkde-perf-title");
        const model = gtk.Label.new("");
        model.setXalign(1);
        model.setEllipsize(.end);
        model.as(gtk.Widget).setHexpand(1);
        model.as(gtk.Widget).setHalign(.end);
        model.as(gtk.Widget).addCssClass("dkde-perf-model");
        head.append(title.as(gtk.Widget));
        head.append(model.as(gtk.Widget));
        root.append(head.as(gtk.Widget));

        const graph_a = self.newGraph(spec.color, spec.unit_a, spec.series_a, spec.floor_a);
        d.* = .{ .root = root, .title = title, .model = model, .caption_a = undefined, .graph_a = graph_a };

        // Caption row: what the graph shows, and the top of its scale.
        const caption_row = gtk.Box.new(.horizontal, 6);
        const caption = gtk.Label.new(common.tr(spec.caption_a));
        caption.setXalign(0);
        caption.as(gtk.Widget).setHexpand(1);
        caption.as(gtk.Widget).addCssClass("dkde-perf-key");
        d.caption_a = caption;
        caption_row.append(caption.as(gtk.Widget));
        const top = gtk.Label.new(if (spec.unit_a == .percent) "100%" else "");
        top.as(gtk.Widget).addCssClass("dkde-perf-key");
        if (spec.unit_a != .fixed) graph_a.max_label = top;
        caption_row.append(top.as(gtk.Widget));
        root.append(caption_row.as(gtk.Widget));

        const big_area = graph_a.view(0, 180);
        if (spec.cores_toggle) {
            const stack = gtk.Stack.new();
            stack.as(gtk.Widget).setVexpand(1);
            _ = stack.addNamed(big_area.as(gtk.Widget), "overall");
            const flow = gtk.FlowBox.new();
            flow.setSelectionMode(.none);
            flow.setHomogeneous(1);
            flow.setMinChildrenPerLine(2);
            flow.setMaxChildrenPerLine(8);
            flow.setRowSpacing(6);
            flow.setColumnSpacing(6);
            const scroll = gtk.ScrolledWindow.new();
            scroll.setChild(flow.as(gtk.Widget));
            _ = stack.addNamed(scroll.as(gtk.Widget), "cores");
            d.stack = stack;
            d.cores = flow;
            const toggle = gtk.ToggleButton.newWithLabel(common.tr("Logical processors"));
            toggle.as(gtk.Widget).setHalign(.end);
            _ = gtk.ToggleButton.signals.toggled.connect(toggle, *Detail, &onCoresToggled, d, .{});
            caption_row.insertChildAfter(toggle.as(gtk.Widget), caption.as(gtk.Widget));
            root.append(stack.as(gtk.Widget));
        } else {
            root.append(big_area.as(gtk.Widget));
        }

        if (spec.memory_bar) {
            const bar = a.create(MemBar) catch @panic("OOM");
            self.mem_bars.append(a, bar) catch @panic("OOM");
            const area = gtk.DrawingArea.new();
            area.setContentHeight(28);
            bar.* = .{ .area = area };
            area.setDrawFunc(MemBar.onDraw, bar, null);
            d.mem_bar = bar;
            const label = keyLabel("Memory composition");
            root.append(label.as(gtk.Widget));
            root.append(area.as(gtk.Widget));
        }

        if (comptime spec.caption_b) |text| {
            const g = self.newGraph(spec.color, spec.unit_b, spec.series_b, spec.floor_b);
            d.graph_b = g;
            const row = gtk.Box.new(.horizontal, 6);
            const cap = gtk.Label.new(common.tr(text));
            cap.setXalign(0);
            cap.as(gtk.Widget).setHexpand(1);
            cap.as(gtk.Widget).addCssClass("dkde-perf-key");
            row.append(cap.as(gtk.Widget));
            const max = gtk.Label.new("");
            max.as(gtk.Widget).addCssClass("dkde-perf-key");
            g.max_label = max;
            row.append(max.as(gtk.Widget));
            root.append(row.as(gtk.Widget));
            root.append(g.view(0, 70).as(gtk.Widget));
        }

        // Figures: the big ones on the left, the plain list on the right.
        const figures = gtk.Box.new(.horizontal, 32);
        figures.as(gtk.Widget).setMarginTop(8);
        const big_grid = gtk.Grid.new();
        big_grid.setColumnSpacing(28);
        big_grid.setRowSpacing(10);
        inline for (spec.big, 0..) |name, i| {
            const cell = gtk.Box.new(.vertical, 0);
            cell.append(keyLabel(name).as(gtk.Widget));
            const v = valueLabel("dkde-perf-big");
            cell.append(v.as(gtk.Widget));
            d.big[i] = v;
            big_grid.attach(cell.as(gtk.Widget), @intCast(i % 3), @intCast(i / 3), 1, 1);
        }
        figures.append(big_grid.as(gtk.Widget));
        const info_grid = gtk.Grid.new();
        info_grid.setColumnSpacing(14);
        info_grid.setRowSpacing(2);
        info_grid.as(gtk.Widget).setHexpand(1);
        inline for (spec.info, 0..) |name, i| {
            info_grid.attach(keyLabel(name).as(gtk.Widget), 0, @intCast(i), 1, 1);
            const v = valueLabel("dkde-perf-value");
            d.info[i] = v;
            info_grid.attach(v.as(gtk.Widget), 1, @intCast(i), 1, 1);
        }
        figures.append(info_grid.as(gtk.Widget));
        root.append(figures.as(gtk.Widget));
        return d;
    }

    fn onCoresToggled(toggle: *gtk.ToggleButton, d: *Detail) callconv(.c) void {
        const stack = d.stack orelse return;
        stack.setVisibleChildName(if (toggle.as(gtk.ToggleButton).getActive() != 0) "cores" else "overall");
    }

    /// Adds a resource: a row in the list and a page in the stack.
    fn addResource(self: *Perf, kind: Kind, name: []const u8, row_title: []const u8, detail: *Detail) *Resource {
        const a = self.allocator;
        const r = a.create(Resource) catch @panic("OOM");
        self.resources.append(a, r) catch @panic("OOM");

        const row_box = gtk.Box.new(.horizontal, 10);
        row_box.as(gtk.Widget).setMarginStart(8);
        row_box.as(gtk.Widget).setMarginEnd(8);
        row_box.as(gtk.Widget).setMarginTop(6);
        row_box.as(gtk.Widget).setMarginBottom(6);
        row_box.append(detail.graph_a.view(64, 44).as(gtk.Widget));
        const text = gtk.Box.new(.vertical, 0);
        text.as(gtk.Widget).setValign(.center);
        text.as(gtk.Widget).setHexpand(1);
        const title = gtk.Label.new("");
        title.setXalign(0);
        title.setEllipsize(.end);
        title.as(gtk.Widget).addCssClass("dkde-perf-row-title");
        setSlice(title, row_title);
        const sub = gtk.Label.new("");
        sub.setXalign(0);
        sub.setEllipsize(.end);
        sub.as(gtk.Widget).addCssClass("dkde-perf-row-sub");
        text.append(title.as(gtk.Widget));
        text.append(sub.as(gtk.Widget));
        row_box.append(text.as(gtk.Widget));
        self.list.append(row_box.as(gtk.Widget));

        r.* = .{ .kind = kind, .detail = detail, .row_title = title, .row_sub = sub, .row = row_box.as(gtk.Widget) };
        const n = @min(name.len, r.name.len);
        @memcpy(r.name[0..n], name[0..n]);
        r.name_len = n;

        var buf: [16]u8 = undefined;
        const page = std.fmt.bufPrintSentinel(&buf, "{d}", .{self.resources.items.len - 1}, 0) catch "x";
        _ = self.stack.addNamed(detail.root.as(gtk.Widget), page);
        return r;
    }

    /// The resource for a device, if one was made before.
    fn find(self: *Perf, group: Group, name: []const u8) ?*Resource {
        for (self.resources.items) |r| {
            if (group.of(r.kind) and std.mem.eql(u8, r.id(), name)) return r;
        }
        return null;
    }

    fn count(self: *Perf, group: Group) usize {
        var n: usize = 0;
        for (self.resources.items) |r| {
            if (group.of(r.kind)) n += 1;
        }
        return n;
    }

    /// Hides the row of a device that was unplugged, and shows it again if it
    /// comes back. Rows are kept, not removed, so the pages stay numbered as
    /// their rows are.
    fn setPresent(self: *Perf, r: *Resource, present: bool) void {
        if (r.present == present) return;
        r.present = present;
        if (r.row.getParent()) |row| row.setVisible(@intFromBool(present));
        // Counters from before the gap would make one huge first sample.
        if (present) {
            r.prev_disk = null;
            r.prev_net = null;
        }
        std.log.info("{s} {s}", .{ r.id(), if (present) "is back" else "is gone" });
        if (!present) {
            // Never leave a vanished device selected.
            if (self.list.getSelectedRow()) |sel| {
                if (sel.as(gtk.Widget) == r.row.getParent()) {
                    if (self.list.getRowAtIndex(0)) |first| self.list.selectRow(first);
                }
            }
        }
    }

    /// Looks for disks, network adapters and GPUs that came or went since the
    /// last scan: a USB disk, a dock, Wi-Fi that was switched on.
    fn rescan(self: *Perf) void {
        for (self.resources.items) |r| r.seen = !Group.devices.of(r.kind);
        self.discoverDisks();
        self.discoverNetwork();
        self.discoverGpus();
        for (self.resources.items) |r| self.setPresent(r, r.seen);
    }

    fn discover(self: *Perf) void {
        self.discoverCpu();
        self.discoverMemory();
        self.discoverDisks();
        self.discoverNetwork();
        self.discoverGpus();
    }

    fn discoverCpu(self: *Perf) void {
        const a = self.allocator;
        if (readAlloc(a, "/proc/cpuinfo")) |content| {
            defer a.free(content);
            self.cpuinfo = perf.parseCpuInfo(content);
            const n = @min(self.cpuinfo.model.len, self.cpu_model.len);
            @memcpy(self.cpu_model[0..n], self.cpuinfo.model[0..n]);
            self.cpu_model_len = n;
            self.cpuinfo.model = "";
        }
        if (readInt("/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq", .{})) |khz| {
            self.base_mhz = @as(f64, @floatFromInt(khz)) / 1000.0;
        } else self.base_mhz = self.cpuinfo.mhz;
        if (readInt("/sys/devices/system/cpu/cpu0/cpufreq/base_frequency", .{})) |khz| self.base_mhz = @as(f64, @floatFromInt(khz)) / 1000.0;

        // Cache totals: size times the number of instances (logical / sharing).
        var l1: u64 = 0;
        var l2: u64 = 0;
        var l3: u64 = 0;
        var index: u32 = 0;
        while (index < 8) : (index += 1) {
            var b1: [32]u8 = undefined;
            var b2: [32]u8 = undefined;
            var b3: [64]u8 = undefined;
            var p: [96]u8 = undefined;
            const level = readSmall(std.fmt.bufPrint(&p, "/sys/devices/system/cpu/cpu0/cache/index{d}/level", .{index}) catch break, &b1) orelse break;
            const kind = readSmall(std.fmt.bufPrint(&p, "/sys/devices/system/cpu/cpu0/cache/index{d}/type", .{index}) catch break, &b2) orelse break;
            if (std.mem.eql(u8, kind, "Instruction") and level.len == 1 and level[0] != '1') continue;
            const size = perf.parseCacheSize(readSmall(std.fmt.bufPrint(&p, "/sys/devices/system/cpu/cpu0/cache/index{d}/size", .{index}) catch break, &b3) orelse continue) orelse continue;
            const shared = perf.countCpuList(readSmall(std.fmt.bufPrint(&p, "/sys/devices/system/cpu/cpu0/cache/index{d}/shared_cpu_list", .{index}) catch break, &b3) orelse "0");
            const instances = @max(1, self.cpu_count / @max(1, shared));
            const total = size * instances;
            switch (level[0]) {
                '1' => l1 += total,
                '2' => l2 += total,
                '3' => l3 += total,
                else => {},
            }
        }
        const totals = [3]u64{ l1, l2, l3 };
        for (totals, 0..) |t, i| {
            if (t == 0) continue;
            self.cache_len[i] = perf.fmtKb(&self.cache_text[i], t).len;
        }

        const d = self.buildDetail(.{
            .title = "CPU",
            .caption_a = "% Utilization over 60 seconds",
            .big = &.{ "Utilization", "Speed", "Processes", "Threads", "Up time" },
            .info = &.{ "Base speed:", "Sockets:", "Cores:", "Logical processors:", "Virtualization:", "Virtual machine:", "L1 cache:", "L2 cache:", "L3 cache:" },
            .color = colors.cpu,
            .unit_a = .percent,
            .cores_toggle = true,
        });
        setSlice(d.model, self.cpu_model[0..self.cpu_model_len]);

        const cores_per = if (self.cpuinfo.cores_per_socket > 0) self.cpuinfo.cores_per_socket * self.cpuinfo.sockets else @as(u32, @intCast(self.cpu_count));
        var buf: [48]u8 = undefined;
        if (self.base_mhz > 0) setText(d.info[0].?, "{d:.2} GHz", .{self.base_mhz / 1000.0});
        setText(d.info[1].?, "{d}", .{self.cpuinfo.sockets});
        setText(d.info[2].?, "{d}", .{cores_per});
        setText(d.info[3].?, "{d}", .{self.cpu_count});
        d.info[4].?.setText(if (self.cpuinfo.hw_virtualization) common.tr("Supported") else common.tr("Not available"));
        d.info[5].?.setText(if (self.cpuinfo.hypervisor) common.tr("Yes") else common.tr("No"));
        for (0..3) |i| if (self.cache_len[i] > 0) setSlice(d.info[6 + i].?, self.cache_text[i][0..self.cache_len[i]]);
        _ = &buf;

        // One small graph per logical processor, for the "Logical processors" view.
        if (d.cores) |flow| {
            const shown = @min(self.cpu_count, max_cores);
            for (0..shown) |i| {
                const g = self.newGraph(colors.cpu, .percent, 1, 0);
                self.core_graphs[i] = g;
                flow.append(g.view(0, 70).as(gtk.Widget));
            }
        }
        const r = self.addResource(.cpu, "cpu", "CPU", d);
        _ = r;
    }

    fn discoverMemory(self: *Perf) void {
        const d = self.buildDetail(.{
            .title = "Memory",
            .caption_a = "Memory usage",
            .big = &.{ "In use", "Available", "Committed", "Cached", "Reclaimable slab", "Unreclaimable slab" },
            .info = &.{ "Total:", "Swap used:", "Shared:", "Buffers:" },
            .color = colors.memory,
            .unit_a = .percent,
            .memory_bar = true,
        });
        _ = self.addResource(.memory, "memory", "Memory", d);
    }

    fn discoverDisks(self: *Perf) void {
        const dir = gio.File.newForPath("/sys/block");
        defer dir.as(gobject.Object).unref();
        const children = dir.enumerateChildren("standard::name", .{}, null, null) orelse return;
        defer children.as(gobject.Object).unref();
        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |n| self.allocator.free(n);
            names.deinit(self.allocator);
        }
        while (children.nextFile(null, null)) |info| {
            defer info.as(gobject.Object).unref();
            const name = std.mem.span(info.getName());
            const prefixes = [_][]const u8{ "sd", "hd", "vd", "xvd", "nvme", "mmcblk" };
            var wanted = false;
            for (prefixes) |p| {
                if (std.mem.startsWith(u8, name, p)) wanted = true;
            }
            if (!wanted or std.mem.indexOf(u8, name, "boot") != null or std.mem.indexOf(u8, name, "rpmb") != null) continue;
            // Empty card readers report a size of zero.
            if ((readInt("/sys/block/{s}/size", .{name}) orelse 0) == 0) continue;
            names.append(self.allocator, self.allocator.dupe(u8, name) catch continue) catch continue;
        }
        std.mem.sort([]u8, names.items, {}, struct {
            fn lt(_: void, x: []u8, y: []u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);

        var root_disk_buf: [32]u8 = undefined;
        const root_disk = rootDisk(&root_disk_buf);
        for (names.items) |name| {
            if (self.find(.disks, name)) |known| {
                known.seen = true;
                continue;
            }
            var tbuf: [48]u8 = undefined;
            const title = std.fmt.bufPrintSentinel(&tbuf, "Disk {d} ({s})", .{ self.count(.disks), name }, 0) catch "Disk";
            const d = self.buildDetail(.{
                .title = "Disk",
                .caption_a = "Active time",
                .caption_b = "Disk transfer rate",
                .big = &.{ "Active time", "Average response time", "Read speed", "Write speed" },
                .info = &.{ "Capacity:", "Type:", "System disk:", "Device:" },
                .color = colors.disk,
                .unit_a = .percent,
            });
            setSlice(d.title, title);

            var mbuf: [96]u8 = undefined;
            var pbuf: [64]u8 = undefined;
            const model = readSmall(std.fmt.bufPrint(&pbuf, "/sys/block/{s}/device/model", .{name}) catch "", &mbuf) orelse "";
            setSlice(d.model, model);
            const sectors = readInt("/sys/block/{s}/size", .{name}) orelse 0;
            var cbuf: [32]u8 = undefined;
            setSlice(d.info[0].?, perf.fmtKb(&cbuf, sectors / 2));
            const rotational = (readInt("/sys/block/{s}/queue/rotational", .{name}) orelse 0) != 0;
            const kind: []const u8 = if (std.mem.startsWith(u8, name, "nvme")) "SSD (NVMe)" else if (std.mem.startsWith(u8, name, "mmcblk")) "Flash card" else if (rotational) "HDD" else "SSD";
            setSlice(d.info[1].?, kind);
            d.info[2].?.setText(if (root_disk) |rd| (if (std.mem.eql(u8, rd, name)) common.tr("Yes") else common.tr("No")) else "—");
            setSlice(d.info[3].?, name);

            const r = self.addResource(.disk, name, title, d);
            setSlice(r.row_sub, kind);
        }
    }

    /// Whole disk holding the root file system, when it can be told.
    fn rootDisk(out: []u8) ?[]const u8 {
        var contents: [*]u8 = undefined;
        var length: usize = 0;
        if (glib.fileGetContents("/proc/mounts", &contents, &length, null) == 0) return null;
        defer glib.free(contents);
        var lines = std.mem.splitScalar(u8, contents[0..length], '\n');
        while (lines.next()) |line| {
            var f = std.mem.tokenizeScalar(u8, line, ' ');
            const dev = f.next() orelse continue;
            const mount = f.next() orelse continue;
            if (!std.mem.eql(u8, mount, "/") or !std.mem.startsWith(u8, dev, "/dev/")) continue;
            const short = dev["/dev/".len..];
            // /sys/class/block/<part>/.. is the disk when <part> is a partition.
            var p: [128]u8 = undefined;
            if (pathExists("/sys/class/block/{s}/partition", .{short})) {
                const path = std.fmt.bufPrintSentinel(&p, "/sys/class/block/{s}", .{short}, 0) catch return null;
                const real = glib.fileReadLink(path, null) orelse return null;
                defer glib.free(real);
                var parts = std.mem.splitBackwardsScalar(u8, std.mem.span(real), '/');
                _ = parts.next();
                const parent = parts.next() orelse return null;
                const n = @min(parent.len, out.len);
                @memcpy(out[0..n], parent[0..n]);
                return out[0..n];
            }
            if (pathExists("/sys/block/{s}", .{short})) {
                const n = @min(short.len, out.len);
                @memcpy(out[0..n], short[0..n]);
                return out[0..n];
            }
            return null;
        }
        return null;
    }

    fn discoverNetwork(self: *Perf) void {
        const dir = gio.File.newForPath("/sys/class/net");
        defer dir.as(gobject.Object).unref();
        const children = dir.enumerateChildren("standard::name", .{}, null, null) orelse return;
        defer children.as(gobject.Object).unref();
        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |n| self.allocator.free(n);
            names.deinit(self.allocator);
        }
        while (children.nextFile(null, null)) |info| {
            defer info.as(gobject.Object).unref();
            const name = std.mem.span(info.getName());
            if (std.mem.eql(u8, name, "lo")) continue;
            const physical = pathExists("/sys/class/net/{s}/device", .{name});
            const named = std.mem.startsWith(u8, name, "eth") or std.mem.startsWith(u8, name, "en") or std.mem.startsWith(u8, name, "wl") or std.mem.startsWith(u8, name, "ww");
            if (!physical and !named) continue;
            names.append(self.allocator, self.allocator.dupe(u8, name) catch continue) catch continue;
        }
        std.mem.sort([]u8, names.items, {}, struct {
            fn lt(_: void, x: []u8, y: []u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);

        for (names.items) |name| {
            if (self.find(.network, name)) |known| {
                known.seen = true;
                continue;
            }
            const wifi = pathExists("/sys/class/net/{s}/wireless", .{name}) or pathExists("/sys/class/net/{s}/phy80211", .{name});
            var tbuf: [48]u8 = undefined;
            const title = std.fmt.bufPrintSentinel(&tbuf, "{s} ({s})", .{ if (wifi) "Wi-Fi" else "Ethernet", name }, 0) catch "Network";
            const d = if (wifi) self.buildDetail(.{
                .title = "Wi-Fi",
                .caption_a = "Throughput",
                .big = &.{ "Send", "Receive" },
                .info = &.{ "Adapter name:", "SSID:", "Driver:", "IPv4 address:", "IPv6 address:", "MAC address:", "Link speed:", "Signal strength:", "State:" },
                .color = colors.network,
                .unit_a = .bits_rate,
                .series_a = 2,
                .floor_a = 12500,
            }) else self.buildDetail(.{
                .title = "Ethernet",
                .caption_a = "Throughput",
                .big = &.{ "Send", "Receive" },
                .info = &.{ "Adapter name:", "Driver:", "IPv4 address:", "IPv6 address:", "MAC address:", "Link speed:", "State:" },
                .color = colors.network,
                .unit_a = .bits_rate,
                .series_a = 2,
                .floor_a = 12500,
            });
            setSlice(d.title, if (wifi) "Wi-Fi" else "Ethernet");
            setSlice(d.model, name);
            _ = self.addResource(if (wifi) .wifi else .ethernet, name, title, d);

            var drv: [48]u8 = undefined;
            const driver = linkBase("/sys/class/net/{s}/device/driver", .{name}, &drv) orelse "—";
            const o: usize = if (wifi) 1 else 0; // wifi rows carry an extra SSID line
            setSlice(d.info[0].?, name);
            setSlice(d.info[1 + o].?, driver);
            var mac: [32]u8 = undefined;
            var pb: [64]u8 = undefined;
            setSlice(d.info[4 + o].?, readSmall(std.fmt.bufPrint(&pb, "/sys/class/net/{s}/address", .{name}) catch "", &mac) orelse "—");
            if (wifi) self.wifi_guard = self.wifi_guard orelse common.proc.Guard(Perf).create(self);
        }
    }

    fn discoverGpus(self: *Perf) void {
        var index: u32 = 0;
        while (index < 8) : (index += 1) {
            var known_name: [16]u8 = undefined;
            // Before reading the PCI id list, which is a megabyte: a card seen
            // before is only marked as still there.
            if (std.fmt.bufPrint(&known_name, "card{d}", .{index})) |kn| {
                if (self.find(.gpus, kn)) |known| {
                    known.seen = true;
                    continue;
                }
            } else |_| {}
            var vb: [16]u8 = undefined;
            var db: [16]u8 = undefined;
            var p: [96]u8 = undefined;
            const vtext = readSmall(std.fmt.bufPrint(&p, "/sys/class/drm/card{d}/device/vendor", .{index}) catch break, &vb) orelse continue;
            const dtext = readSmall(std.fmt.bufPrint(&p, "/sys/class/drm/card{d}/device/device", .{index}) catch break, &db) orelse continue;
            const vendor = std.fmt.parseInt(u16, std.mem.trimStart(u8, vtext, "0x"), 16) catch continue;
            const device = std.fmt.parseInt(u16, std.mem.trimStart(u8, dtext, "0x"), 16) catch continue;

            var name_buf: [128]u8 = undefined;
            var vendor_name: []const u8 = "";
            var device_name: []const u8 = "";
            const ids: ?[]u8 = readAlloc(self.allocator, "/usr/share/hwdata/pci.ids") orelse readAlloc(self.allocator, "/usr/share/misc/pci.ids");
            defer if (ids) |i| self.allocator.free(i);
            if (ids) |content| {
                const names = perf.pciNames(content, vendor, device);
                // Keep copies: the content is freed at the end of this block.
                if (names.vendor) |v| {
                    const short = std.mem.trim(u8, if (std.mem.indexOfScalar(u8, v, '[')) |b| v[b + 1 .. std.mem.indexOfScalar(u8, v, ']') orelse v.len] else v, " ");
                    const n = @min(short.len, 40);
                    @memcpy(name_buf[0..n], short[0..n]);
                    vendor_name = name_buf[0..n];
                }
                if (names.device) |dn| {
                    const n = @min(dn.len, name_buf.len - 48);
                    @memcpy(name_buf[48..][0..n], dn[0..n]);
                    device_name = name_buf[48..][0..n];
                }
            }
            var full_buf: [128]u8 = undefined;
            const full = if (device_name.len > 0)
                std.fmt.bufPrint(&full_buf, "{s} {s}", .{ vendor_name, device_name }) catch device_name
            else
                std.fmt.bufPrint(&full_buf, "GPU {x:0>4}:{x:0>4}", .{ vendor, device }) catch "GPU";

            const busy = pathExists("/sys/class/drm/card{d}/device/gpu_busy_percent", .{index});
            const vram = (readInt("/sys/class/drm/card{d}/device/mem_info_vram_total", .{index}) orelse 0) > 0;
            const has_freq = pathExists("/sys/class/drm/card{d}/gt_cur_freq_mhz", .{index});
            const d = if (vram) self.buildDetail(.{
                .title = "GPU",
                .caption_a = "Utilization",
                .caption_b = "Dedicated GPU memory usage",
                .big = &.{ "Utilization", "GPU memory", "Temperature", "Power", "Clock speed" },
                .info = &.{ "Dedicated GPU memory:", "Shared GPU memory:", "Driver:", "PCI location:", "Vendor:", "Device ID:" },
                .color = colors.gpu,
                .unit_a = .percent,
                .unit_b = .percent,
                .series_b = 1,
            }) else self.buildDetail(.{
                .title = "GPU",
                .caption_a = "Utilization",
                .big = &.{ "Utilization", "GPU memory", "Temperature", "Power", "Clock speed" },
                .info = &.{ "Dedicated GPU memory:", "Shared GPU memory:", "Driver:", "PCI location:", "Vendor:", "Device ID:" },
                .color = colors.gpu,
                .unit_a = .percent,
            });
            if (!busy) d.caption_a.setText(if (has_freq) common.tr("Clock speed (% of maximum)") else common.tr("Utilization (not reported by this driver)"));
            var tbuf: [32]u8 = undefined;
            const title = std.fmt.bufPrintSentinel(&tbuf, "GPU {d}", .{self.count(.gpus)}, 0) catch "GPU";
            setSlice(d.title, title);
            setSlice(d.model, full);

            var cardname: [16]u8 = undefined;
            const cn = std.fmt.bufPrint(&cardname, "card{d}", .{index}) catch "card0";
            const r = self.addResource(.gpu, cn, title, d);
            r.has_busy = busy;
            r.has_vram = vram;
            // hwmon directory for temperature and power.
            const hw = gio.File.newForPath(std.fmt.bufPrintSentinel(&p, "/sys/class/drm/card{d}/device/hwmon", .{index}, 0) catch "/");
            defer hw.as(gobject.Object).unref();
            if (hw.enumerateChildren("standard::name", .{}, null, null)) |kids| {
                defer kids.as(gobject.Object).unref();
                if (kids.nextFile(null, null)) |info| {
                    defer info.as(gobject.Object).unref();
                    const hw_path = std.fmt.bufPrint(&r.hwmon, "/sys/class/drm/card{d}/device/hwmon/{s}", .{ index, std.mem.span(info.getName()) }) catch "";
                    r.hwmon_len = hw_path.len;
                }
            }

            var drv: [48]u8 = undefined;
            var loc: [48]u8 = undefined;
            setSlice(d.info[2].?, linkBase("/sys/class/drm/card{d}/device/driver", .{index}, &drv) orelse "—");
            setSlice(d.info[3].?, linkBase("/sys/class/drm/card{d}/device", .{index}, &loc) orelse "—");
            setSlice(d.info[4].?, if (vendor_name.len > 0) vendor_name else vtext);
            setText(d.info[5].?, "{x:0>4}:{x:0>4}", .{ vendor, device });
            r.row_sub.setText("");
        }
    }

    // ---- sampling ------------------------------------------------------------------

    /// Shows the page of the resource with this id (`cpu`, `memory`, `sda`,
    /// `eth0`, `card0`); an unknown id changes nothing.
    pub fn select(self: *Perf, name: []const u8) void {
        for (self.resources.items, 0..) |r, i| {
            if (!std.mem.eql(u8, r.id(), name)) continue;
            if (self.list.getRowAtIndex(@intCast(i))) |row| self.list.selectRow(row);
            return;
        }
    }

    /// Called on every refresh of the Task Manager.
    pub fn update(self: *Perf, process_count: usize, thread_count: usize) void {
        const now_us = glib.getMonotonicTime();
        const dt: f64 = if (self.prev_us == 0) 0 else @as(f64, @floatFromInt(now_us - self.prev_us)) / 1e6;
        self.prev_us = now_us;
        self.tick +%= 1;
        // Every sixth refresh (about nine seconds), look for devices that came or went.
        if (self.tick % 6 == 0) self.rescan();
        for (self.resources.items) |r| if (r.present) switch (r.kind) {
            .cpu => self.updateCpu(r, process_count, thread_count),
            .memory => self.updateMemory(r),
            .disk => self.updateDisk(r, dt),
            .ethernet, .wifi => self.updateNet(r, dt),
            .gpu => self.updateGpu(r),
        };
        if (self.wifi_guard != null and self.tick % 20 == 0) self.askSsid();
    }

    fn updateCpu(self: *Perf, r: *Resource, processes: usize, threads: usize) void {
        const a = self.allocator;
        const d = r.detail;
        var fraction: f64 = 0;
        if (readAlloc(a, "/proc/stat")) |content| {
            defer a.free(content);
            if (@import("proc.zig").parseCpuTimes(content)) |now| {
                if (self.prev_total) |prev| fraction = perf.busy(prev, now);
                self.prev_total = now;
            }
            var cores: [max_cores]perf.CpuTimes = undefined;
            const n = perf.parseCoreTimes(content, &cores);
            if (self.prev_core_count == n) {
                for (0..n) |i| if (self.core_graphs[i]) |g| g.push(perf.busy(self.prev_cores[i], cores[i]) * 100, 0);
            }
            self.prev_cores = cores;
            self.prev_core_count = n;
        }
        d.graph_a.push(fraction * 100, 0);

        var mhz: f64 = self.cpuinfo.mhz;
        if (readInt("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq", .{})) |khz| mhz = @as(f64, @floatFromInt(khz)) / 1000.0;
        setText(d.big[0].?, "{d:.0}%", .{fraction * 100});
        if (mhz > 0) setText(d.big[1].?, "{d:.2} GHz", .{mhz / 1000.0});
        setText(d.big[2].?, "{d}", .{processes});
        setText(d.big[3].?, "{d}", .{threads});
        var ub: [160]u8 = undefined;
        var cb: [32]u8 = undefined;
        if (readSmall("/proc/uptime", &ub)) |text| {
            if (perf.parseUptime(text)) |secs| setSlice(d.big[4].?, perf.fmtUptime(&cb, secs));
        }
        if (mhz > 0) setText(r.row_sub, "{d:.0}%  {d:.2} GHz", .{ fraction * 100, mhz / 1000.0 }) else setText(r.row_sub, "{d:.0}%", .{fraction * 100});
    }

    fn updateMemory(self: *Perf, r: *Resource) void {
        const a = self.allocator;
        const content = readAlloc(a, "/proc/meminfo") orelse return;
        defer a.free(content);
        const m = perf.parseMem(content) orelse return;
        const d = r.detail;
        const used = m.total -| m.available;
        const total: f64 = @floatFromInt(@max(1, m.total));
        const fraction = @as(f64, @floatFromInt(used)) / total;
        d.graph_a.push(fraction * 100, 0);
        var b: [4][32]u8 = undefined;
        setSlice(d.model, perf.fmtKb(&b[0], m.total));
        if (d.graph_a.max_label) |l| setSlice(l, perf.fmtKb(&b[0], m.total));
        setSlice(d.big[0].?, perf.fmtKb(&b[0], used));
        setSlice(d.big[1].?, perf.fmtKb(&b[1], m.available));
        setText(d.big[2].?, "{s}/{s}", .{ perf.fmtKb(&b[2], m.committed), perf.fmtKb(&b[3], m.commit_limit) });
        setSlice(d.big[3].?, perf.fmtKb(&b[0], m.cached + m.buffers));
        setSlice(d.big[4].?, perf.fmtKb(&b[1], m.reclaimable));
        setSlice(d.big[5].?, perf.fmtKb(&b[2], m.unreclaimable));
        setSlice(d.info[0].?, perf.fmtKb(&b[0], m.total));
        setText(d.info[1].?, "{s} of {s}", .{ perf.fmtKb(&b[1], m.swap_total -| m.swap_free), perf.fmtKb(&b[2], m.swap_total) });
        setSlice(d.info[2].?, perf.fmtKb(&b[3], m.shmem));
        setSlice(d.info[3].?, perf.fmtKb(&b[0], m.buffers));
        if (d.mem_bar) |bar| {
            bar.in_use = fraction;
            bar.cached = @as(f64, @floatFromInt(m.cached + m.buffers)) / total;
            bar.area.as(gtk.Widget).queueDraw();
        }
        setText(r.row_sub, "{s}/{s} ({d:.0}%)", .{ perf.fmtKb(&b[1], used), perf.fmtKb(&b[2], m.total), fraction * 100 });
    }

    fn updateDisk(self: *Perf, r: *Resource, dt: f64) void {
        _ = self;
        var buf: [256]u8 = undefined;
        var pb: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&pb, "/sys/block/{s}/stat", .{r.id()}) catch return;
        const text = readSmall(path, &buf) orelse return;
        const now = perf.parseDiskStat(text) orelse return;
        defer r.prev_disk = now;
        const prev = r.prev_disk orelse return;
        if (dt <= 0) return;
        const d = r.detail;
        const active = std.math.clamp(@as(f64, @floatFromInt(now.io_ms -| prev.io_ms)) / (dt * 1000), 0, 1);
        const ios = (now.reads -| prev.reads) + (now.writes -| prev.writes);
        const ms = (now.read_ms -| prev.read_ms) + (now.write_ms -| prev.write_ms);
        const response: f64 = if (ios > 0) @as(f64, @floatFromInt(ms)) / @as(f64, @floatFromInt(ios)) else 0;
        const read_bps = @as(f64, @floatFromInt(now.read_sectors -| prev.read_sectors)) * 512 / dt;
        const write_bps = @as(f64, @floatFromInt(now.write_sectors -| prev.write_sectors)) * 512 / dt;
        d.graph_a.push(active * 100, 0);
        if (d.graph_b) |g| g.push(read_bps, write_bps);
        var b: [2][32]u8 = undefined;
        setText(d.big[0].?, "{d:.0}%", .{active * 100});
        setText(d.big[1].?, "{d:.1} ms", .{response});
        setSlice(d.big[2].?, perf.fmtByteRate(&b[0], read_bps));
        setSlice(d.big[3].?, perf.fmtByteRate(&b[1], write_bps));
        const kind = d.info[1].?.getText();
        setText(r.row_sub, "{s}  {d:.0}%", .{ std.mem.span(kind), active * 100 });
    }

    fn updateNet(self: *Perf, r: *Resource, dt: f64) void {
        const a = self.allocator;
        const d = r.detail;
        const wifi = r.kind == .wifi;
        const o: usize = if (wifi) 1 else 0;
        const content = readAlloc(a, "/proc/net/dev") orelse return;
        defer a.free(content);
        const now = perf.parseNetDev(content, r.id());
        if (now) |n| {
            if (r.prev_net) |prev| if (dt > 0) {
                const rx = @as(f64, @floatFromInt(n.rx -| prev.rx)) / dt;
                const tx = @as(f64, @floatFromInt(n.tx -| prev.tx)) / dt;
                d.graph_a.push(rx, tx);
                var b: [2][32]u8 = undefined;
                setSlice(d.big[0].?, perf.fmtBitRate(&b[0], tx));
                setSlice(d.big[1].?, perf.fmtBitRate(&b[1], rx));
                setText(r.row_sub, "S: {s}  R: {s}", .{ perf.fmtBitRate(&b[0], tx), perf.fmtBitRate(&b[1], rx) });
            };
            r.prev_net = n;
        }

        var sb: [64]u8 = undefined;
        var pb: [96]u8 = undefined;
        const state = readSmall(std.fmt.bufPrint(&pb, "/sys/class/net/{s}/operstate", .{r.id()}) catch "", &sb) orelse "—";
        setSlice(d.info[6 + 2 * o].?, state);
        var speed_buf: [32]u8 = undefined;
        const speed = readSmall(std.fmt.bufPrint(&pb, "/sys/class/net/{s}/speed", .{r.id()}) catch "", &speed_buf) orelse "";
        const mbit = std.fmt.parseInt(i64, speed, 10) catch -1;
        const link_idx: usize = 5 + o;
        if (mbit > 0) setText(d.info[link_idx].?, "{d} Mbps", .{mbit}) else setSlice(d.info[link_idx].?, "—");

        // Addresses.
        var v4: [32]u8 = undefined;
        var v6: [64]u8 = undefined;
        var v4_text: []const u8 = "—";
        var v6_text: []const u8 = "—";
        var list: ?*Ifaddrs = null;
        if (getifaddrs(&list) == 0) {
            defer freeifaddrs(list);
            var cur = list;
            while (cur) |ifa| : (cur = ifa.next) {
                if (!std.mem.eql(u8, std.mem.span(ifa.name), r.id())) continue;
                const sa = ifa.addr orelse continue;
                if (sa.family == AF_INET and std.mem.eql(u8, v4_text, "—")) {
                    v4_text = std.fmt.bufPrint(&v4, "{d}.{d}.{d}.{d}", .{ sa.data[2], sa.data[3], sa.data[4], sa.data[5] }) catch "—";
                } else if (sa.family == AF_INET6 and std.mem.eql(u8, v6_text, "—")) {
                    // sockaddr_in6: port(2) flowinfo(4) address(16); the 14 bytes held here
                    // are not enough, so read the full structure.
                    const full: *const [28]u8 = @ptrCast(sa);
                    v6_text = perf.fmtIp6(&v6, full[8..24].*);
                }
            }
        }
        setSlice(d.info[2 + o].?, v4_text);
        setSlice(d.info[3 + o].?, v6_text);

        if (wifi) {
            setSlice(d.info[1].?, if (r.ssid_len > 0) r.ssid[0..r.ssid_len] else "—");
            var wb: [2048]u8 = undefined;
            const wtext = readSmall("/proc/net/wireless", &wb) orelse "";
            if (perf.parseWirelessQuality(wtext, r.id())) |q| setText(d.info[7].?, "{d}%", .{q}) else setSlice(d.info[7].?, "—");
        }
    }

    fn updateGpu(self: *Perf, r: *Resource) void {
        _ = self;
        const d = r.detail;
        const idx = std.fmt.parseInt(u32, r.id()["card".len..], 10) catch return;
        var utilization: ?f64 = null;
        if (r.has_busy) {
            if (readInt("/sys/class/drm/card{d}/device/gpu_busy_percent", .{idx})) |v| utilization = @floatFromInt(v);
        }
        const cur_mhz = readInt("/sys/class/drm/card{d}/gt_cur_freq_mhz", .{idx});
        const max_mhz = readInt("/sys/class/drm/card{d}/gt_max_freq_mhz", .{idx});
        if (utilization == null) {
            if (cur_mhz != null and max_mhz != null and max_mhz.? > 0)
                utilization = @as(f64, @floatFromInt(cur_mhz.?)) * 100 / @as(f64, @floatFromInt(max_mhz.?));
        }
        d.graph_a.push(utilization orelse 0, 0);
        if (r.has_busy) setText(d.big[0].?, "{d:.0}%", .{utilization orelse 0}) else d.big[0].?.setText("—");

        var b: [3][32]u8 = undefined;
        if (r.has_vram) {
            const total = readInt("/sys/class/drm/card{d}/device/mem_info_vram_total", .{idx}) orelse 0;
            const used = readInt("/sys/class/drm/card{d}/device/mem_info_vram_used", .{idx}) orelse 0;
            if (d.graph_b) |g| g.push(@as(f64, @floatFromInt(used)) * 100 / @as(f64, @floatFromInt(@max(1, total))), 0);
            setText(d.big[1].?, "{s}/{s}", .{ perf.fmtKb(&b[0], used / 1024), perf.fmtKb(&b[1], total / 1024) });
            setSlice(d.info[0].?, perf.fmtKb(&b[2], total / 1024));
        }
        if (readInt("/sys/class/drm/card{d}/device/mem_info_gtt_total", .{idx})) |gtt| setSlice(d.info[1].?, perf.fmtKb(&b[2], gtt / 1024));

        if (r.hwmon_len > 0) {
            const hw = r.hwmon[0..r.hwmon_len];
            if (readInt("{s}/temp1_input", .{hw})) |milli| setText(d.big[2].?, "{d} °C", .{milli / 1000});
            const power = readInt("{s}/power1_average", .{hw}) orelse readInt("{s}/power1_input", .{hw});
            if (power) |uw| setText(d.big[3].?, "{d:.0} W", .{@as(f64, @floatFromInt(uw)) / 1e6});
            if (readInt("{s}/freq1_input", .{hw})) |hz| setText(d.big[4].?, "{d} MHz", .{hz / 1000000});
        }
        if (cur_mhz) |m| setText(d.big[4].?, "{d} MHz", .{m});

        if (r.has_busy) setText(r.row_sub, "{d:.0}%", .{utilization orelse 0}) else if (utilization) |u| setText(r.row_sub, "{d:.0}% of max clock", .{u}) else r.row_sub.setText("");
    }

    // ---- Wi-Fi network name --------------------------------------------------------

    fn askSsid(self: *Perf) void {
        const guard = self.wifi_guard orelse return;
        if (!common.proc.hasProgram("nmcli")) return;
        common.proc.run(Perf, guard, &.{ "nmcli", "-t", "-f", "ACTIVE,SSID,DEVICE", "dev", "wifi" }, onSsid);
    }

    fn onSsid(self: *Perf, ok: bool, out: []const u8) void {
        if (!ok) return;
        for (self.resources.items) |r| {
            if (r.kind != .wifi) continue;
            r.ssid_len = if (perf.parseNmcliSsid(out, r.id(), &r.ssid)) |s| s.len else 0;
        }
    }
};

test {
    _ = niceMax;
}

test "nice maximum" {
    try std.testing.expectEqual(@as(f64, 100), niceMax(73));
    try std.testing.expectEqual(@as(f64, 200), niceMax(150));
    try std.testing.expectEqual(@as(f64, 500), niceMax(210));
    try std.testing.expectEqual(@as(f64, 1), niceMax(0));
}
