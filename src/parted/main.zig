//! dkde-parted: disks and partitions (SPEC.md 5.6). It reads `lsblk`, shows each
//! disk with a size bar, and changes disks only through `parted`, `mkfs.*`,
//! `mount`, `umount` and the checkers, as administrator, after a confirmation.

const std = @import("std");
const cairo = @import("cairo1");
const pangocairo = @import("pangocairo1");
const gdk = @import("gdk4");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

const model = @import("model.zig");
const fs = @import("fs.zig");
const ops_mod = @import("ops.zig");
const selftest = @import("selftest.zig");

pub const std_options: std.Options = .{ .logFn = common.log.logFn, .log_level = .debug };

const lsblk_columns = "NAME,PATH,TYPE,SIZE,START,FSTYPE,LABEL,MOUNTPOINTS,PTTYPE,MODEL,RM,RO,LOG-SEC";
/// Older lsblk has no usage columns; the call is repeated without them.
const lsblk_columns_usage = lsblk_columns ++ ",FSUSED,FSAVAIL";

const Action = enum { new_table, new_partition, format, mount, new_image, resize, label, flag };

const Row = union(enum) { part: usize, gap: usize };

const PendingOp = struct { disk_path: []const u8, op: ops_mod.Op, text: []const u8 };

const Dlg = struct {
    app: *Parted,
    window: *gtk.Window,
    action: Action,
    dropdown: ?*gtk.DropDown = null,
    spin: ?*gtk.SpinButton = null,
    entry: ?*gtk.Entry = null,
    /// The filesystems the dropdown lists, in order.
    kinds: [24]*const fs.Fs = undefined,
    /// The flag dropdown and its on/off partner.
    dropdown2: ?*gtk.DropDown = null,
    n_kinds: usize = 0,
};

const Parted = struct {
    allocator: std.mem.Allocator,
    window: *gtk.ApplicationWindow,
    disk_drop: *gtk.DropDown,
    /// One size group per table column, so the header lines up with the rows.
    col_groups: [8]*gtk.SizeGroup = undefined,
    part_list: *gtk.ListBox,
    bar: *gtk.DrawingArea,
    status: *gtk.Label,
    probe: *gtk.Widget,
    buttons: [16]*gtk.Button = undefined,
    /// Image files opened or created in this session.
    images: std.ArrayList([]u8) = .empty,
    /// Index of the image being read during a rescan.
    scan_image: usize = 0,
    scan_disks: std.ArrayList(model.Disk) = .empty,
    arena: std.heap.ArenaAllocator,
    disks: []const model.Disk = &.{},
    gaps: []const model.Gap = &.{},
    rows: std.ArrayList(Row) = .empty,
    selected_disk: ?usize = null,
    selected_row: ?usize = null,
    busy: bool = false,
    /// What is on the disks; `disks` is that with the pending operations applied on paper.
    real: []const model.Disk = &.{},
    pending: std.ArrayList(PendingOp) = .empty,
    /// Strings of the pending operations live here; `sim_arena` holds the predicted layout.
    pending_arena: std.heap.ArenaAllocator = undefined,
    sim_arena: std.heap.ArenaAllocator = undefined,
    pending_list: *gtk.ListBox = undefined,
    pending_box: *gtk.Box = undefined,
    apply_button: *gtk.Button = undefined,
    /// The administrator commands, run after any that need no password.
    apply_root: ?[]const []const u8 = null,
    scanning: bool = false,
    rescan_again: bool = false,
    /// A just-created image to add after it exists.
    pending_image: ?[]u8 = null,
    /// A disk to select after the next rescan.
    select_path: ?[]u8 = null,
    proc_guard: *common.proc.Guard(Parted) = undefined,
    /// What to say when the running command works.
    done_note: [96]u8 = undefined,
    done_len: usize = 0,

    const b_rescan = 0;
    const b_new_image = 1;
    const b_open_image = 2;
    const b_table = 3;
    const b_new = 4;
    const b_delete = 5;
    const b_resize = 6;
    const b_format = 7;
    const b_mount = 8;
    const b_unmount = 9;
    const b_check = 10;
    const b_label = 11;
    const b_flag = 12;
    const b_wipe = 13;
    const b_support = 14;
    const b_log = 15;

    pub fn create(allocator: std.mem.Allocator, app: *gtk.Application) !*Parted {
        const self = try allocator.create(Parted);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .window = gtk.ApplicationWindow.new(app),
            .disk_drop = gtk.DropDown.newFromStrings(@ptrCast(&[_]?[*:0]const u8{null})),
            .part_list = gtk.ListBox.new(),
            .bar = gtk.DrawingArea.new(),
            .status = gtk.Label.new(""),
            .probe = undefined,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .pending_arena = std.heap.ArenaAllocator.init(allocator),
            .sim_arena = std.heap.ArenaAllocator.init(allocator),
        };
        self.proc_guard = common.proc.Guard(Parted).create(self);
        // parted, mkfs.* and friends live in sbin, which a user's PATH often lacks.
        if (glib.getenv("PATH")) |old| {
            var buf: [2048]u8 = undefined;
            if (std.fmt.bufPrintSentinel(&buf, "{s}:/usr/local/sbin:/usr/sbin:/sbin", .{std.mem.span(old)}, 0)) |p| _ = glib.setenv("PATH", p, 1) else |_| {}
        }
        const probe = gtk.Label.new("");
        probe.as(gtk.Widget).addCssClass("dkde-accent-probe");
        self.probe = probe.as(gtk.Widget);

        const window = self.window.as(gtk.Window);
        window.setTitle(common.tr("Partitions"));
        window.setDefaultSize(1100, 640);
        self.window.as(gtk.Widget).addCssClass("dkde");
        _ = common.header.create(window, "drive-harddisk", true);

        // Toolbar.
        const bar = gtk.FlowBox.new();
        bar.setSelectionMode(.none);
        bar.setHomogeneous(0);
        bar.setMaxChildrenPerLine(15);
        bar.setColumnSpacing(4);
        bar.setRowSpacing(4);
        bar.as(gtk.Widget).setMarginTop(8);
        bar.as(gtk.Widget).setMarginBottom(4);
        bar.as(gtk.Widget).setMarginStart(12);
        bar.as(gtk.Widget).setMarginEnd(12);
        const labels = [_][:0]const u8{ "Rescan", "New image", "Open image", "New table", "New partition", "Delete", "Resize", "Format", "Mount", "Unmount", "Check", "Label", "Flag", "Erase", "Filesystems", "Log" };
        inline for (labels, 0..) |text, i| {
            const b = gtk.Button.newWithLabel(common.tr(text));
            _ = gtk.Button.signals.clicked.connect(b, *Parted, &onButton(i), self, .{});
            self.buttons[i] = b;
        }
        // The everyday actions in the bar, the rest under "More".
        const primary = [_]usize{ b_rescan, b_table, b_new, b_delete, b_resize, b_format };
        for (primary) |i| bar.append(self.buttons[i].as(gtk.Widget));
        const more = gtk.MenuButton.new();
        more.setLabel(common.tr("More"));
        const more_pop = gtk.Popover.new();
        const more_box = gtk.Box.new(.vertical, 2);
        more_pop.setChild(more_box.as(gtk.Widget));
        more.setPopover(more_pop);
        const secondary = [_]usize{ b_label, b_flag, b_new_image, b_open_image, b_mount, b_unmount, b_check, b_wipe, b_support, b_log };
        for (secondary) |i| {
            self.buttons[i].setHasFrame(0);
            if (self.buttons[i].getChild()) |child| {
                const l: *gtk.Label = @ptrCast(@alignCast(child));
                l.setXalign(0);
            }
            more_box.append(self.buttons[i].as(gtk.Widget));
        }
        more.as(gtk.Widget).setValign(.start);
        more.as(gtk.Widget).setMarginTop(8);
        more.as(gtk.Widget).setMarginEnd(6);
        bar.append(self.probe);
        self.probe.setVisible(0);

        // The disk chooser sits at the top right, like GParted's.
        self.disk_drop.as(gtk.Widget).setValign(.start);
        self.disk_drop.as(gtk.Widget).setMarginTop(8);
        self.disk_drop.as(gtk.Widget).setMarginEnd(12);
        self.disk_drop.as(gtk.Widget).setSizeRequest(260, -1);
        _ = gobject.Object.signals.notify.connect(self.disk_drop, *Parted, &onDiskSelected, self, .{ .detail = "selected" });

        // The size bar across the window, then the table of partitions.
        self.bar.as(gtk.Widget).setSizeRequest(-1, 52);
        self.bar.as(gtk.Widget).setMarginTop(4);
        self.bar.as(gtk.Widget).setMarginStart(12);
        self.bar.as(gtk.Widget).setMarginEnd(12);
        self.bar.setDrawFunc(onDraw, self, null);
        const bar_click = gtk.GestureClick.new();
        _ = gtk.GestureClick.signals.pressed.connect(bar_click, *Parted, &onBarClick, self, .{});
        self.bar.as(gtk.Widget).addController(bar_click.as(gtk.EventController));

        for (&self.col_groups) |*g| g.* = gtk.SizeGroup.new(.horizontal);
        const header = gtk.Box.new(.horizontal, 12);
        header.as(gtk.Widget).setMarginTop(10);
        header.as(gtk.Widget).setMarginStart(20);
        header.as(gtk.Widget).setMarginEnd(20);
        const titles = [_][:0]const u8{ "Partition", "File system", "Mount point", "Label", "Size", "Used", "Unused", "Flags" };
        inline for (titles, 0..) |title, i| {
            const l = gtk.Label.new(common.tr(title));
            l.setXalign(0);
            l.as(gtk.Widget).addCssClass("heading");
            self.col_groups[i].addWidget(l.as(gtk.Widget));
            header.append(l.as(gtk.Widget));
        }
        self.part_list.setSelectionMode(.single);
        _ = gtk.ListBox.signals.row_selected.connect(self.part_list, *Parted, &onRowSelected, self, .{});
        const part_scroller = gtk.ScrolledWindow.new();
        part_scroller.setChild(self.part_list.as(gtk.Widget));
        part_scroller.as(gtk.Widget).setVexpand(1);
        part_scroller.as(gtk.Widget).setMarginStart(12);
        part_scroller.as(gtk.Widget).setMarginEnd(12);
        part_scroller.as(gtk.Widget).setMarginTop(4);
        part_scroller.as(gtk.Widget).setMarginBottom(8);
        bar.as(gtk.Widget).setHexpand(1);
        const top = gtk.Box.new(.horizontal, 0);
        top.append(bar.as(gtk.Widget));
        top.append(more.as(gtk.Widget));
        top.append(self.disk_drop.as(gtk.Widget));

        // Pending operations, as in GParted: shown here until applied.
        self.pending_list = gtk.ListBox.new();
        self.pending_list.setSelectionMode(.none);
        const pending_scroller = gtk.ScrolledWindow.new();
        pending_scroller.setChild(self.pending_list.as(gtk.Widget));
        pending_scroller.setMinContentHeight(70);
        pending_scroller.setMaxContentHeight(110);
        pending_scroller.setPropagateNaturalHeight(1);
        self.pending_box = gtk.Box.new(.vertical, 4);
        self.pending_box.as(gtk.Widget).setMarginStart(12);
        self.pending_box.as(gtk.Widget).setMarginEnd(12);
        self.pending_box.as(gtk.Widget).setMarginBottom(4);
        const pending_title = gtk.Label.new(common.tr("Pending operations (nothing changes until you Apply)"));
        pending_title.setXalign(0);
        pending_title.as(gtk.Widget).addCssClass("heading");
        self.pending_box.append(pending_title.as(gtk.Widget));
        self.pending_box.append(pending_scroller.as(gtk.Widget));
        const pending_buttons = gtk.Box.new(.horizontal, 6);
        pending_buttons.as(gtk.Widget).setHalign(.end);
        const undo = gtk.Button.newWithLabel(common.tr("Undo last"));
        const clear = gtk.Button.newWithLabel(common.tr("Clear all"));
        const show = gtk.Button.newWithLabel(common.tr("Show commands"));
        self.apply_button = gtk.Button.newWithLabel(common.tr("Apply"));
        self.apply_button.as(gtk.Widget).addCssClass("suggested-action");
        _ = gtk.Button.signals.clicked.connect(undo, *Parted, &onUndo, self, .{});
        _ = gtk.Button.signals.clicked.connect(clear, *Parted, &onClear, self, .{});
        _ = gtk.Button.signals.clicked.connect(show, *Parted, &onShowCommands, self, .{});
        _ = gtk.Button.signals.clicked.connect(self.apply_button, *Parted, &onApply, self, .{});
        pending_buttons.append(undo.as(gtk.Widget));
        pending_buttons.append(clear.as(gtk.Widget));
        pending_buttons.append(show.as(gtk.Widget));
        pending_buttons.append(self.apply_button.as(gtk.Widget));
        self.pending_box.append(pending_buttons.as(gtk.Widget));
        self.pending_box.as(gtk.Widget).setVisible(0);

        self.status.setXalign(0);
        self.status.as(gtk.Widget).setMarginStart(12);
        self.status.as(gtk.Widget).setMarginTop(4);
        self.status.as(gtk.Widget).setMarginBottom(6);
        self.status.as(gtk.Widget).addCssClass("dim-label");

        const root = gtk.Box.new(.vertical, 0);
        root.append(top.as(gtk.Widget));
        root.append(self.bar.as(gtk.Widget));
        root.append(header.as(gtk.Widget));
        root.append(part_scroller.as(gtk.Widget));
        root.append(self.pending_box.as(gtk.Widget));
        root.append(self.status.as(gtk.Widget));
        window.setChild(root.as(gtk.Widget));
        _ = gtk.Widget.signals.destroy.connect(self.window, *Parted, &onDestroy, self, .{});

        self.updateButtons();
        // `dkde-parted disk.img ...` opens images straight away.
        for (common.runapp.args) |arg| {
            const path = std.mem.span(arg);
            if (path.len > 0 and path[0] == '/') self.images.append(allocator, allocator.dupe(u8, path) catch continue) catch {};
        }
        self.rescan();
        return self;
    }

    pub fn present(self: *Parted) void {
        self.window.as(gtk.Window).present();
    }

    fn onDestroy(_: *gtk.ApplicationWindow, self: *Parted) callconv(.c) void {
        self.proc_guard.kill();
        self.rows.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.pending_arena.deinit();
        self.sim_arena.deinit();
        if (self.pending_image) |p| self.allocator.free(p);
        if (self.select_path) |p| self.allocator.free(p);
        for (self.images.items) |p| self.allocator.free(p);
        self.images.deinit(self.allocator);
        self.scan_disks.deinit(self.allocator);
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    fn onButton(comptime index: usize) fn (*gtk.Button, *Parted) callconv(.c) void {
        return struct {
            fn call(_: *gtk.Button, self: *Parted) callconv(.c) void {
                switch (index) {
                    b_rescan => self.rescan(),
                    b_new_image => self.openDialog(.new_image),
                    b_open_image => self.openImageDialog(),
                    b_resize => self.openDialog(.resize),
                    b_label => self.openDialog(.label),
                    b_flag => self.openDialog(.flag),
                    b_wipe => self.askWipe(),
                    b_support => self.showSupport(),
                    b_log => self.showLog(),
                    b_table => self.openDialog(.new_table),
                    b_new => self.openDialog(.new_partition),
                    b_delete => self.askDelete(),
                    b_format => self.openDialog(.format),
                    b_mount => self.openDialog(.mount),
                    b_unmount => self.unmountSelected(),
                    b_check => self.checkSelected(),
                    else => {},
                }
            }
        }.call;
    }

    // ---- reading the disks -------------------------------------------------------------------

    fn rescan(self: *Parted) void {
        // A scan reads the images one after another; a second one started now
        // would interleave with it, so it waits for the first to finish.
        if (self.scanning) {
            self.rescan_again = true;
            return;
        }
        self.scanning = true;
        self.status.setText(common.tr("Reading the disks\u{2026}"));
        common.proc.run(Parted, self.proc_guard, &.{ "lsblk", "-J", "-b", "-o", lsblk_columns_usage }, onLsblkUsage);
    }

    /// Tries the usage columns first; older lsblk lacks them.
    fn onLsblkUsage(self: *Parted, ok: bool, out: []const u8) void {
        if (ok) return self.onLsblk(true, out);
        common.proc.run(Parted, self.proc_guard, &.{ "lsblk", "-J", "-b", "-o", lsblk_columns }, onLsblk);
    }

    fn onLsblk(self: *Parted, ok: bool, out: []const u8) void {
        var fresh = std.heap.ArenaAllocator.init(self.allocator);
        self.scan_disks.clearRetainingCapacity();
        if (ok) {
            const disks = model.parseLsblk(fresh.allocator(), out) catch &.{};
            self.scan_disks.appendSlice(self.allocator, disks) catch {};
        } else if (self.images.items.len == 0) {
            fresh.deinit();
            self.status.setText(common.tr("lsblk is missing or failed, so the disks cannot be listed."));
            self.endScan();
            return;
        }
        // Keep the new arena for the whole rescan; images are read into it too.
        self.arena.deinit();
        self.arena = fresh;
        self.scan_image = 0;
        self.scanNextImage();
    }

    /// Reads the images one at a time, then shows everything.
    fn scanNextImage(self: *Parted) void {
        if (self.scan_image >= self.images.items.len) return self.finishScan();
        const path = self.images.items[self.scan_image];
        common.proc.run(Parted, self.proc_guard, &.{ "parted", "-m", "-s", path, "unit", "B", "print" }, onImage);
    }

    fn onImage(self: *Parted, ok: bool, out: []const u8) void {
        if (self.scan_image >= self.images.items.len) return self.finishScan();
        const path = self.images.items[self.scan_image];
        var size: u64 = 0;
        const file = gio.File.newForPath(self.arenaZ(path));
        defer file.as(gobject.Object).unref();
        if (file.queryInfo("standard::size", .{}, null, null)) |info| {
            defer info.as(gobject.Object).unref();
            size = @intCast(info.getSize());
        }
        const text = if (ok) out else "";
        const disk = model.parsePartedMachine(self.arena.allocator(), path, text, size) catch {
            self.scan_image += 1;
            return self.scanNextImage();
        };
        self.scan_disks.append(self.allocator, disk) catch {};
        self.scan_image += 1;
        self.scanNextImage();
    }

    fn arenaZ(self: *Parted, s: []const u8) [:0]const u8 {
        return self.arena.allocator().dupeSentinel(u8, s, 0) catch "";
    }

    /// Ends a scan and starts another one if one was asked for meanwhile.
    fn endScan(self: *Parted) void {
        self.scanning = false;
        if (self.rescan_again) {
            self.rescan_again = false;
            self.rescan();
        }
    }

    fn finishScan(self: *Parted) void {
        defer self.endScan();
        const keep = self.selected_disk;
        const disks = self.arena.allocator().dupe(model.Disk, self.scan_disks.items) catch &.{};
        // What is on the disks now replaces any prediction.
        self.real = disks;
        self.pending.clearRetainingCapacity();
        _ = self.pending_arena.reset(.free_all);
        _ = self.sim_arena.reset(.free_all);
        self.disks = disks;
        self.refreshPending();
        self.selected_disk = null;
        self.selected_row = null;
        self.fillDisks();
        // Stay on the same disk after a change.
        var index = if (keep) |k| (if (k < disks.len) k else 0) else 0;
        if (self.select_path) |sp| {
            for (disks, 0..) |d, i| if (std.mem.eql(u8, d.path, sp)) {
                index = i;
            };
            self.allocator.free(sp);
            self.select_path = null;
        }
        if (disks.len > 0) {
            self.disk_drop.setSelected(@intCast(index));
            // Selecting the entry already shown does not notify; fill by hand.
            self.selected_disk = index;
            self.fillParts();
        }
        self.status.setText("");
    }

    fn fillDisks(self: *Parted) void {
        // The dropdown lists "/dev/sda  Model  (size)".
        const list = gtk.StringList.new(null);
        for (self.disks) |d| {
            var buf: [200]u8 = undefined;
            var size_buf: [32]u8 = undefined;
            const text = std.fmt.bufPrintSentinel(&buf, "{s}  ({s}{s})", .{
                if (d.image) d.name else d.path,
                if (d.image) "image, " else "",
                formatSize(&size_buf, d.size),
            }, 0) catch continue;
            list.append(text);
        }
        self.disk_drop.setModel(list.as(gio.ListModel));
    }

    fn onDiskSelected(dd: *gtk.DropDown, _: *gobject.ParamSpec, self: *Parted) callconv(.c) void {
        const i: usize = @intCast(dd.getSelected());
        if (i >= self.disks.len or self.selected_disk == i) return;
        self.selected_disk = i;
        self.fillParts();
    }

    fn fillParts(self: *Parted) void {
        self.part_list.removeAll();
        self.rows.clearRetainingCapacity();
        self.selected_row = null;
        const d = self.disks[self.selected_disk.?];
        self.gaps = model.freeSpace(self.arena.allocator(), d) catch &.{};
        // Partitions and free stretches in disk order.
        var pi: usize = 0;
        var gi: usize = 0;
        while (pi < d.parts.len or gi < self.gaps.len) {
            const take_gap = gi < self.gaps.len and (pi >= d.parts.len or self.gaps[gi].start < d.parts[pi].start);
            if (take_gap) {
                self.addRow(.{ .gap = gi });
                gi += 1;
            } else {
                self.addRow(.{ .part = pi });
                pi += 1;
            }
        }
        if (self.rows.items.len == 0) {
            var buf: [160]u8 = undefined;
            const note = gtk.Label.new(std.fmt.bufPrintSentinel(&buf, "{s}", .{if (d.fstype.len > 0) "A filesystem fills the whole disk; there is no partition table. Create a new table to partition it (this erases the filesystem)." else "No partitions and no free space."}, 0) catch "");
            note.setWrap(1);
            note.setXalign(0);
            note.as(gtk.Widget).setMarginTop(12);
            note.as(gtk.Widget).setMarginStart(12);
            note.as(gtk.Widget).addCssClass("dim-label");
            self.part_list.append(note.as(gtk.Widget));
            if (self.part_list.getRowAtIndex(0)) |r| {
                r.setSelectable(0);
                r.setActivatable(0);
            }
        }
        self.bar.as(gtk.Widget).queueDraw();
        self.updateButtons();
    }

    fn cell(self: *Parted, line: *gtk.Box, col: usize, text: []const u8, dim: bool) void {
        var buf: [200]u8 = undefined;
        const l = gtk.Label.new(std.fmt.bufPrintSentinel(&buf, "{s}", .{text}, 0) catch "");
        l.setXalign(0);
        l.setEllipsize(.end);
        if (dim) l.as(gtk.Widget).addCssClass("dim-label");
        self.col_groups[col].addWidget(l.as(gtk.Widget));
        line.append(l.as(gtk.Widget));
    }

    /// The file system column: a coloured square, then its name.
    fn fsCell(self: *Parted, line: *gtk.Box, fstype: []const u8, free: bool) void {
        const c = if (free) [3]f64{ 0.7, 0.7, 0.7 } else colorOf(fstype);
        var buf: [160]u8 = undefined;
        const name = if (free) "unallocated" else if (fstype.len > 0) fstype else "unformatted";
        const markup = std.fmt.bufPrintSentinel(&buf, "<span foreground=\"#{X:0>2}{X:0>2}{X:0>2}\">\u{25A0}</span> {s}", .{
            @as(u8, @intFromFloat(c[0] * 255)), @as(u8, @intFromFloat(c[1] * 255)), @as(u8, @intFromFloat(c[2] * 255)), name,
        }, 0) catch return;
        const l = gtk.Label.new(null);
        l.setMarkup(markup);
        l.setXalign(0);
        self.col_groups[1].addWidget(l.as(gtk.Widget));
        line.append(l.as(gtk.Widget));
    }

    fn addRow(self: *Parted, row: Row) void {
        self.rows.append(self.allocator, row) catch return;
        const d = self.disks[self.selected_disk.?];
        const line = gtk.Box.new(.horizontal, 12);
        line.as(gtk.Widget).setMarginTop(6);
        line.as(gtk.Widget).setMarginBottom(6);
        line.as(gtk.Widget).setMarginStart(8);
        var sb: [32]u8 = undefined;
        var ub: [32]u8 = undefined;
        var fb: [32]u8 = undefined;
        var nb: [32]u8 = undefined;
        switch (row) {
            .part => |i| {
                const p = d.parts[i];
                self.cell(line, 0, if (d.image) std.fmt.bufPrint(&nb, "partition {d}", .{p.number}) catch "" else p.path, false);
                self.fsCell(line, p.fstype, false);
                self.cell(line, 2, if (p.mounts.len > 0) p.mounts[0] else "", false);
                self.cell(line, 3, p.label, false);
                self.cell(line, 4, formatSize(&sb, p.size), false);
                self.cell(line, 5, if (p.used) |u| formatSize(&ub, u) else "\u{2014}", p.used == null);
                self.cell(line, 6, if (p.avail) |u| formatSize(&fb, u) else "\u{2014}", p.avail == null);
                self.cell(line, 7, p.flags, false);
            },
            .gap => |i| {
                const g = self.gaps[i];
                self.cell(line, 0, "unallocated", true);
                self.fsCell(line, "", true);
                self.cell(line, 2, "", false);
                self.cell(line, 3, "", false);
                self.cell(line, 4, formatSize(&sb, g.bytes(d.sector)), false);
                self.cell(line, 5, "", false);
                self.cell(line, 6, "", false);
                self.cell(line, 7, "", false);
            },
        }
        self.part_list.append(line.as(gtk.Widget));
    }

    fn onRowSelected(_: *gtk.ListBox, row: ?*gtk.ListBoxRow, self: *Parted) callconv(.c) void {
        const r = row orelse {
            self.selected_row = null;
            return self.updateButtons();
        };
        const i: usize = @intCast(r.getIndex());
        self.selected_row = if (i < self.rows.items.len) i else null;
        self.bar.as(gtk.Widget).queueDraw();
        self.updateButtons();
    }

    fn selectedDisk(self: *const Parted) ?model.Disk {
        const i = self.selected_disk orelse return null;
        return if (i < self.disks.len) self.disks[i] else null;
    }

    fn selectedPart(self: *const Parted) ?model.Part {
        const d = self.selectedDisk() orelse return null;
        const r = self.selected_row orelse return null;
        return switch (self.rows.items[r]) {
            .part => |i| d.parts[i],
            .gap => null,
        };
    }

    fn selectedGap(self: *const Parted) ?model.Gap {
        const r = self.selected_row orelse return null;
        return switch (self.rows.items[r]) {
            .gap => |i| self.gaps[i],
            .part => null,
        };
    }

    fn updateButtons(self: *Parted) void {
        const d = self.selectedDisk();
        const writable = d != null and !self.busy and model.refuseReason(d.?) == null;
        const part = self.selectedPart();
        const set = struct {
            fn on(b: *gtk.Button, yes: bool) void {
                b.as(gtk.Widget).setSensitive(@intFromBool(yes));
            }
        }.on;
        set(self.buttons[b_rescan], !self.busy);
        set(self.buttons[b_new_image], !self.busy and common.proc.hasProgram("parted"));
        set(self.buttons[b_open_image], !self.busy);
        set(self.buttons[b_resize], writable and part != null and common.proc.hasProgram("parted"));
        set(self.buttons[b_table], writable and common.proc.hasProgram("parted"));
        set(self.buttons[b_new], writable and self.selectedGap() != null and d.?.table.len > 0 and common.proc.hasProgram("parted"));
        set(self.buttons[b_delete], writable and part != null and common.proc.hasProgram("parted"));
        set(self.buttons[b_format], writable and part != null);
        // Mounting does not rewrite a disk, so only the busy state matters.
        const dirty = self.pending.items.len > 0;
        set(self.buttons[b_mount], !dirty and !self.busy and part != null and !d.?.image and part.?.mounts.len == 0 and part.?.fstype.len > 0);
        set(self.buttons[b_unmount], !dirty and !self.busy and part != null and part.?.mounts.len > 0 and !(d != null and model.isSystemDisk(d.?)));
        set(self.buttons[b_check], !dirty and !self.busy and part != null and part.?.mounts.len == 0 and part.?.fstype.len > 0 and fs.byId(part.?.fstype) != null and fs.byId(part.?.fstype).?.check.len > 0);
        set(self.buttons[b_label], writable and part != null and part.?.fstype.len > 0 and fs.byId(part.?.fstype) != null and fs.byId(part.?.fstype).?.relabel != null);
        set(self.buttons[b_flag], writable and part != null and common.proc.hasProgram("parted") and d.?.table.len > 0);
        set(self.buttons[b_wipe], writable and part != null);
        set(self.buttons[b_support], true);
        set(self.buttons[b_log], true);
        if (d) |disk| if (model.refuseReason(disk)) |why| {
            var buf: [200]u8 = undefined;
            self.status.setText(std.fmt.bufPrintSentinel(&buf, "{s}", .{why}, 0) catch "");
        } else if (!self.busy) self.status.setText("");
    }

    // ---- the size bar ------------------------------------------------------------------------

    fn colorOf(fstype: []const u8) [3]f64 {
        const eql = std.mem.eql;
        if (eql(u8, fstype, "ext4") or eql(u8, fstype, "ext3") or eql(u8, fstype, "ext2")) return .{ 0.30, 0.60, 0.90 };
        if (eql(u8, fstype, "btrfs")) return .{ 0.35, 0.75, 0.45 };
        if (eql(u8, fstype, "xfs")) return .{ 0.55, 0.45, 0.85 };
        if (eql(u8, fstype, "vfat") or eql(u8, fstype, "exfat")) return .{ 0.95, 0.65, 0.20 };
        if (eql(u8, fstype, "ntfs")) return .{ 0.20, 0.70, 0.75 };
        if (eql(u8, fstype, "swap") or eql(u8, fstype, "linux_swap")) return .{ 0.85, 0.40, 0.45 };
        return .{ 0.55, 0.55, 0.60 };
    }

    fn onDraw(_: *gtk.DrawingArea, cr: *cairo.Context, width: c_int, height: c_int, data: ?*anyopaque) callconv(.c) void {
        const self: *Parted = @ptrCast(@alignCast(data.?));
        const d = self.selectedDisk() orelse return;
        if (d.size == 0) return;
        const w: f64 = @floatFromInt(width);
        const h: f64 = @floatFromInt(height);
        const total: f64 = @floatFromInt(d.size / d.sector);
        const accent = common.style.accentOf(self.probe);
        var fg: gdk.RGBA = undefined;
        self.bar.as(gtk.Widget).getColor(&fg);
        const layout = self.bar.as(gtk.Widget).createPangoLayout(null);
        defer layout.as(gobject.Object).unref();
        layout.setEllipsize(.end);
        for (self.rows.items, 0..) |row, ri| {
            var start: f64 = 0;
            var len: f64 = 0;
            var color: [3]f64 = .{ 0.5, 0.5, 0.5 };
            var free = false;
            switch (row) {
                .part => |i| {
                    const p = d.parts[i];
                    start = @floatFromInt(p.start);
                    len = @floatFromInt(p.size / d.sector);
                    color = colorOf(p.fstype);
                },
                .gap => |i| {
                    const g = self.gaps[i];
                    start = @floatFromInt(g.start);
                    len = @floatFromInt(g.end - g.start);
                    free = true;
                },
            }
            const x = start / total * w;
            const seg = @max(2.0, len / total * w);
            if (free) cr.setSourceRgba(0.5, 0.5, 0.5, 0.18) else cr.setSourceRgba(color[0], color[1], color[2], 0.85);
            cr.rectangle(x, 0, seg, h);
            cr.fill();
            cr.setSourceRgba(0, 0, 0, 0.35);
            cr.rectangle(x + 0.5, 0.5, seg - 1, h - 1);
            cr.stroke();
            // A label when the segment is wide enough to read.
            if (seg > 70) {
                var tb: [96]u8 = undefined;
                var sb: [32]u8 = undefined;
                const text = switch (row) {
                    .part => |i| std.fmt.bufPrint(&tb, "{s}\n{s}", .{ if (d.parts[i].fstype.len > 0) d.parts[i].fstype else "partition", formatSize(&sb, d.parts[i].size) }) catch "",
                    .gap => |i| std.fmt.bufPrint(&tb, "free\n{s}", .{formatSize(&sb, self.gaps[i].bytes(d.sector))}) catch "",
                };
                layout.setWidth(@intFromFloat((seg - 12) * 1024));
                layout.setText(@ptrCast(text.ptr), @intCast(text.len));
                if (free) cr.setSourceRgba(fg.f_red, fg.f_green, fg.f_blue, 0.8) else cr.setSourceRgba(1, 1, 1, 0.95);
                cr.moveTo(x + 6, 4);
                pangocairo.showLayout(cr, layout);
            }
            if (self.selected_row != null and self.selected_row.? == ri) {
                cr.setSourceRgba(accent.f_red, accent.f_green, accent.f_blue, 1);
                cr.setLineWidth(3);
                cr.rectangle(x + 1.5, 1.5, seg - 3, h - 3);
                cr.stroke();
                cr.setLineWidth(1);
            }
        }
    }

    /// Clicking a segment of the bar selects its row.
    fn onBarClick(_: *gtk.GestureClick, _: c_int, x: f64, _: f64, self: *Parted) callconv(.c) void {
        const d = self.selectedDisk() orelse return;
        const w: f64 = @floatFromInt(self.bar.as(gtk.Widget).getWidth());
        if (w <= 0 or d.size == 0) return;
        const sector: u64 = @intFromFloat(x / w * @as(f64, @floatFromInt(d.size / d.sector)));
        for (self.rows.items, 0..) |row, ri| {
            const lo: u64, const hi: u64 = switch (row) {
                .part => |i| .{ d.parts[i].start, d.parts[i].start + d.parts[i].size / d.sector },
                .gap => |i| .{ self.gaps[i].start, self.gaps[i].end },
            };
            if (sector >= lo and sector < hi) {
                if (self.part_list.getRowAtIndex(@intCast(ri))) |r| self.part_list.selectRow(r);
                return;
            }
        }
    }

    // ---- dialogs -----------------------------------------------------------------------------

    fn newDialog(self: *Parted, action: Action, title: [:0]const u8, message: [:0]const u8, ok_label: [:0]const u8, destructive: bool) ?struct { dlg: *Dlg, box: *gtk.Box } {
        const dlg = self.allocator.create(Dlg) catch return null;
        const window = gtk.Window.new();
        window.setTitle(title);
        window.setTransientFor(self.window.as(gtk.Window));
        window.setModal(1);
        window.setDefaultSize(440, -1);
        window.as(gtk.Widget).addCssClass("dkde");
        const box = gtk.Box.new(.vertical, 10);
        box.as(gtk.Widget).setMarginTop(16);
        box.as(gtk.Widget).setMarginBottom(16);
        box.as(gtk.Widget).setMarginStart(16);
        box.as(gtk.Widget).setMarginEnd(16);
        window.setChild(box.as(gtk.Widget));
        const note = gtk.Label.new(message);
        note.setWrap(1);
        note.setXalign(0);
        box.append(note.as(gtk.Widget));
        dlg.* = .{ .app = self, .window = window, .action = action };
        _ = gtk.Widget.signals.destroy.connect(window, *Dlg, &onDlgDestroy, dlg, .{});
        // The buttons are added by `finishDialog` after the form widgets.
        _ = ok_label;
        _ = destructive;
        return .{ .dlg = dlg, .box = box };
    }

    fn finishDialog(dlg: *Dlg, box: *gtk.Box, ok_label: [:0]const u8, destructive: bool) void {
        const buttons = gtk.Box.new(.horizontal, 8);
        buttons.as(gtk.Widget).setHalign(.end);
        const cancel = gtk.Button.newWithLabel(common.tr("Cancel"));
        const ok = gtk.Button.newWithLabel(ok_label);
        ok.as(gtk.Widget).addCssClass(if (destructive) "destructive-action" else "suggested-action");
        buttons.append(cancel.as(gtk.Widget));
        buttons.append(ok.as(gtk.Widget));
        box.append(buttons.as(gtk.Widget));
        _ = gtk.Button.signals.clicked.connect(cancel, *Dlg, &onDlgCancel, dlg, .{});
        _ = gtk.Button.signals.clicked.connect(ok, *Dlg, &onDlgOk, dlg, .{});
        dlg.window.present();
    }

    fn onDlgDestroy(_: *gtk.Window, dlg: *Dlg) callconv(.c) void {
        dlg.app.allocator.destroy(dlg);
    }

    fn onDlgCancel(_: *gtk.Button, dlg: *Dlg) callconv(.c) void {
        dlg.window.destroy();
    }

    fn openDialog(self: *Parted, action: Action) void {
        const d = self.selectedDisk() orelse return;
        var msg: [400]u8 = undefined;
        switch (action) {
            .new_table => {
                const text = std.fmt.bufPrintSentinel(&msg, "Creating a new partition table on {s} erases the current one: every partition on the disk becomes inaccessible. Data is not wiped but is very hard to get back.", .{d.path}, 0) catch return;
                const made = self.newDialog(.new_table, common.tr("New partition table"), text, "", true) orelse return;
                const dd = gtk.DropDown.newFromStrings(@ptrCast(&[_]?[*:0]const u8{ "GPT (modern, recommended)", "MBR (old BIOS, DOS)", null }));
                made.dlg.dropdown = dd;
                made.box.append(dd.as(gtk.Widget));
                finishDialog(made.dlg, made.box, common.tr("Create table"), true);
            },
            .new_partition => {
                const gap = self.selectedGap() orelse return;
                const text = std.fmt.bufPrintSentinel(&msg, "A new partition in the free space of {s}. It is created empty; format it afterwards.", .{d.path}, 0) catch return;
                const made = self.newDialog(.new_partition, common.tr("New partition"), text, "", false) orelse return;
                const max_mib = gap.bytes(d.sector) / model.mib;
                const spin = gtk.SpinButton.newWithRange(1, @floatFromInt(@max(max_mib, 1)), 1);
                spin.setValue(@floatFromInt(max_mib));
                made.dlg.spin = spin;
                const row = gtk.Box.new(.horizontal, 8);
                row.append(gtk.Label.new(common.tr("Size (MiB)")).as(gtk.Widget));
                row.append(spin.as(gtk.Widget));
                made.box.append(row.as(gtk.Widget));
                // Optionally format it straight away.
                var names: [26]?[*:0]const u8 = @splat(null);
                names[0] = "No filesystem (leave unformatted)";
                var n: usize = 0;
                for (&fs.table) |*f| if (common.proc.hasProgram(f.mkfs)) {
                    made.dlg.kinds[n] = f;
                    names[n + 1] = f.name.ptr;
                    n += 1;
                };
                made.dlg.n_kinds = n;
                const dd = gtk.DropDown.newFromStrings(@ptrCast(&names));
                made.dlg.dropdown = dd;
                made.box.append(dd.as(gtk.Widget));
                const entry = gtk.Entry.new();
                entry.setPlaceholderText(common.tr("Label (optional)"));
                made.dlg.entry = entry;
                made.box.append(entry.as(gtk.Widget));
                finishDialog(made.dlg, made.box, common.tr("Create"), false);
            },
            .label => {
                const p = self.selectedPart() orelse return;
                const text = std.fmt.bufPrintSentinel(&msg, "Change the label of the {s} filesystem on {s}.", .{ p.fstype, if (d.image) "this partition" else p.path }, 0) catch return;
                const made = self.newDialog(.label, common.tr("Change label"), text, "", false) orelse return;
                const entry = gtk.Entry.new();
                entry.as(gtk.Editable).setText(@ptrCast(self.arenaZ(p.label).ptr));
                made.dlg.entry = entry;
                made.box.append(entry.as(gtk.Widget));
                finishDialog(made.dlg, made.box, common.tr("Change"), false);
            },
            .flag => {
                const p = self.selectedPart() orelse return;
                const text = std.fmt.bufPrintSentinel(&msg, "Set or clear a partition flag on {s}. For example esp marks an EFI system partition; boot marks the partition to boot from on MBR disks.", .{if (d.image) "this partition" else p.path}, 0) catch return;
                const made = self.newDialog(.flag, common.tr("Partition flag"), text, "", false) orelse return;
                var names: [10]?[*:0]const u8 = @splat(null);
                for (fs.flags, 0..) |fl, i| names[i] = @ptrCast(self.arenaZ(fl).ptr);
                const dd = gtk.DropDown.newFromStrings(@ptrCast(&names));
                made.dlg.dropdown = dd;
                made.box.append(dd.as(gtk.Widget));
                const onoff = gtk.DropDown.newFromStrings(@ptrCast(&[_]?[*:0]const u8{ "Turn on", "Turn off", null }));
                made.dlg.dropdown2 = onoff;
                made.box.append(onoff.as(gtk.Widget));
                finishDialog(made.dlg, made.box, common.tr("Apply"), false);
            },
            .format => {
                const p = self.selectedPart() orelse return;
                const text = std.fmt.bufPrintSentinel(&msg, "Formatting {s} ERASES ALL DATA on it. This cannot be undone.", .{p.path}, 0) catch return;
                const made = self.newDialog(.format, common.tr("Format partition"), text, "", true) orelse return;
                // Only the filesystems whose tool is installed.
                var names: [24]?[*:0]const u8 = @splat(null);
                var n: usize = 0;
                for (&fs.table) |*f| if (common.proc.hasProgram(f.mkfs)) {
                    made.dlg.kinds[n] = f;
                    names[n] = f.name.ptr;
                    n += 1;
                };
                made.dlg.n_kinds = n;
                if (n == 0) {
                    made.dlg.window.destroy();
                    return self.status.setText(common.tr("No mkfs tools are installed. Press Filesystems to see what to install."));
                }
                const dd = gtk.DropDown.newFromStrings(@ptrCast(&names));
                made.dlg.dropdown = dd;
                made.box.append(dd.as(gtk.Widget));
                const entry = gtk.Entry.new();
                entry.setPlaceholderText(common.tr("Label (optional)"));
                made.dlg.entry = entry;
                made.box.append(entry.as(gtk.Widget));
                finishDialog(made.dlg, made.box, common.tr("Format"), true);
            },
            .new_image => {
                const made = self.newDialog(.new_image, common.tr("New disk image"), common.tr("Creates a sparse image file (it only uses disk space as data is written) with an empty partition table. You can then partition and format it here."), "", false) orelse return;
                const entry = gtk.Entry.new();
                var def: [300]u8 = undefined;
                entry.as(gtk.Editable).setText(std.fmt.bufPrintSentinel(&def, "{s}/disk.img", .{std.mem.span(glib.getHomeDir())}, 0) catch "disk.img");
                made.dlg.entry = entry;
                made.box.append(entry.as(gtk.Widget).as(gtk.Widget));
                const spin = gtk.SpinButton.newWithRange(1, 4194304, 64);
                spin.setValue(1024);
                made.dlg.spin = spin;
                const row = gtk.Box.new(.horizontal, 8);
                row.append(gtk.Label.new(common.tr("Size (MiB)")).as(gtk.Widget));
                row.append(spin.as(gtk.Widget));
                made.box.append(row.as(gtk.Widget));
                const dd = gtk.DropDown.newFromStrings(@ptrCast(&[_]?[*:0]const u8{ "GPT partition table", "MBR partition table", "No partition table", null }));
                made.dlg.dropdown = dd;
                made.box.append(dd.as(gtk.Widget));
                finishDialog(made.dlg, made.box, common.tr("Create"), false);
            },
            .resize => {
                const p = self.selectedPart() orelse return;
                const cur_mib = p.size / model.mib;
                // It can grow into free space that follows it.
                var room_mib: u64 = 0;
                const end_sector = p.start + p.size / d.sector;
                for (self.gaps) |g| if (g.start >= end_sector -| 2048 and g.start <= end_sector + 2048) {
                    room_mib = (g.end - g.start) * d.sector / model.mib;
                };
                const text = std.fmt.bufPrintSentinel(&msg, "Resize {s}. Shrinking needs the filesystem to fit in the new size; the filesystem is resized with its own tool, and a check runs first. Back up anything important.", .{if (d.image) "this partition" else p.path}, 0) catch return;
                const made = self.newDialog(.resize, common.tr("Resize partition"), text, "", true) orelse return;
                const spin = gtk.SpinButton.newWithRange(1, @floatFromInt(cur_mib + room_mib), 1);
                spin.setValue(@floatFromInt(cur_mib));
                made.dlg.spin = spin;
                const row = gtk.Box.new(.horizontal, 8);
                row.append(gtk.Label.new(common.tr("New size (MiB)")).as(gtk.Widget));
                row.append(spin.as(gtk.Widget));
                made.box.append(row.as(gtk.Widget));
                finishDialog(made.dlg, made.box, common.tr("Resize"), true);
            },
            .mount => {
                const p = self.selectedPart() orelse return;
                const text = std.fmt.bufPrintSentinel(&msg, "Mount {s} in this folder (created if missing):", .{p.path}, 0) catch return;
                const made = self.newDialog(.mount, common.tr("Mount"), text, "", false) orelse return;
                const entry = gtk.Entry.new();
                var def: [200]u8 = undefined;
                const name = if (p.label.len > 0) p.label else std.fs.path.basename(p.path);
                entry.as(gtk.Editable).setText(std.fmt.bufPrintSentinel(&def, "/mnt/{s}", .{name}, 0) catch "/mnt/disk");
                made.dlg.entry = entry;
                made.box.append(entry.as(gtk.Widget));
                finishDialog(made.dlg, made.box, common.tr("Mount"), false);
            },
        }
    }

    fn onDlgOk(_: *gtk.Button, dlg: *Dlg) callconv(.c) void {
        const self = dlg.app;
        defer dlg.window.destroy();
        const d = self.selectedDisk() orelse return;
        const a = self.arena.allocator();
        switch (dlg.action) {
            .new_table => {
                const kind: []const u8 = if (dlg.dropdown.?.getSelected() == 0) "gpt" else "msdos";
                self.queueOp(d.path, .{ .new_table = .{ .kind = kind } });
            },
            .new_partition => {
                const gap = self.selectedGap() orelse return;
                const start_mib = gap.start * d.sector / model.mib;
                const size: u64 = @intCast(dlg.spin.?.getValueAsInt());
                const choice = dlg.dropdown.?.getSelected();
                const number = fs.nextNumber(d);
                self.queueOp(d.path, .{ .create = .{ .start_mib = start_mib, .end_mib = start_mib + size } });
                if (choice > 0 and choice <= dlg.n_kinds) {
                    const label = std.mem.span(dlg.entry.?.as(gtk.Editable).getText());
                    self.queueOp(d.path, .{ .format = .{ .number = number, .fs = dlg.kinds[choice - 1], .label = label } });
                }
            },
            .format => {
                const p = self.selectedPart() orelse return;
                const idx: usize = @intCast(dlg.dropdown.?.getSelected());
                if (idx >= dlg.n_kinds) return;
                const label = std.mem.span(dlg.entry.?.as(gtk.Editable).getText());
                self.queueOp(d.path, .{ .format = .{ .number = p.number, .fs = dlg.kinds[idx], .label = label } });
            },
            .label => {
                const p = self.selectedPart() orelse return;
                const label = std.mem.span(dlg.entry.?.as(gtk.Editable).getText());
                self.queueOp(d.path, .{ .label = .{ .number = p.number, .label = label } });
            },
            .flag => {
                const p = self.selectedPart() orelse return;
                const idx: usize = @intCast(dlg.dropdown.?.getSelected());
                if (idx >= fs.flags.len) return;
                const on = dlg.dropdown2.?.getSelected() == 0;
                self.queueOp(d.path, .{ .flag = .{ .number = p.number, .flag = fs.flags[idx], .on = on } });
            },
            .new_image => {
                const path = std.mem.span(dlg.entry.?.as(gtk.Editable).getText());
                if (path.len == 0 or path[0] != '/') return self.status.setText(common.tr("Give a full file path, such as /home/you/disk.img."));
                const kind: []const u8 = switch (dlg.dropdown.?.getSelected()) {
                    0 => "gpt",
                    1 => "msdos",
                    else => "none",
                };
                const argv = fs.newImage(a, path, @intCast(dlg.spin.?.getValueAsInt()), kind) catch return;
                self.pending_image = self.allocator.dupe(u8, path) catch return;
                self.run(false, "Create a disk image", argv, "Image created.");
            },
            .resize => {
                const p = self.selectedPart() orelse return;
                const cur_mib = p.size / model.mib;
                const new_mib: u64 = @intCast(dlg.spin.?.getValueAsInt());
                if (new_mib == cur_mib) return;
                const shrink = new_mib < cur_mib;
                if (fs.resizeRefusal(p.fstype, shrink)) |why| {
                    var buf: [200]u8 = undefined;
                    return self.status.setText(std.fmt.bufPrintSentinel(&buf, "{s}", .{why}, 0) catch "");
                }
                const start_mib = p.start * d.sector / model.mib;
                self.queueOp(d.path, .{ .resize = .{ .number = p.number, .new_end_mib = start_mib + new_mib } });
            },
            .mount => {
                const p = self.selectedPart() orelse return;
                const dir = std.mem.span(dlg.entry.?.as(gtk.Editable).getText());
                if (dir.len == 0 or dir[0] != '/') return self.status.setText(common.tr("Give a full folder path, such as /mnt/data."));
                const argv = fs.mount(a, p.path, dir) catch return;
                self.runElevated("Mount a partition", argv, "Mounted.");
            },
        }
    }

    fn askDelete(self: *Parted) void {
        const d = self.selectedDisk() orelse return;
        const p = self.selectedPart() orelse return;
        self.queueOp(d.path, .{ .delete = .{ .number = p.number } });
    }

    fn askWipe(self: *Parted) void {
        const d = self.selectedDisk() orelse return;
        const p = self.selectedPart() orelse return;
        self.queueOp(d.path, .{ .wipe = .{ .number = p.number } });
    }

    /// Which filesystems can be made, and what to install for the rest.
    fn showSupport(self: *Parted) void {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(self.allocator);
        for (&fs.table) |*f| {
            const have = common.proc.hasProgram(f.mkfs);
            text.print(self.allocator, "{s}  {s:<9} create: {s}   resize: {s}{s}\n", .{
                if (have) "\u{2714}" else "\u{2718}",
                f.name,
                if (have) "yes" else "needs",
                if (f.grow != null or f.shrink != null) (if (f.grow != null and f.shrink != null) "grow, shrink" else "grow only") else "no",
                if (have) "" else std.fmt.allocPrint(self.arena.allocator(), "   ({s})", .{f.package}) catch "",
            }) catch return;
        }
        text.appendSlice(self.allocator, "\nA missing mkfs tool hides that filesystem; the package to install is in brackets. Resizing and checking need their own tools too (resize2fs, ntfsresize, fatresize, ...).") catch return;
        const z = self.allocator.dupeSentinel(u8, text.items, 0) catch return;
        defer self.allocator.free(z);
        const made = self.newDialog(.format, common.tr("Filesystem support"), z, "", false) orelse return;
        // A read-only list: reuse the dialog frame with a single Close button.
        const close = gtk.Button.newWithLabel(common.tr("Close"));
        close.as(gtk.Widget).setHalign(.end);
        _ = gtk.Button.signals.clicked.connect(close, *Dlg, &onDlgCancel, made.dlg, .{});
        made.box.append(close.as(gtk.Widget));
        made.dlg.window.present();
    }

    fn unmountSelected(self: *Parted) void {
        const p = self.selectedPart() orelse return;
        const argv = fs.unmount(self.arena.allocator(), p.path) catch return;
        self.runElevated("Unmount a partition", argv, "Unmounted.");
    }

    fn checkSelected(self: *Parted) void {
        const p = self.selectedPart() orelse return;
        const d = self.selectedDisk() orelse return;
        const f = fs.byId(p.fstype) orelse return;
        const argv = (fs.checkScript(self.arena.allocator(), if (d.image) d.path else null, p.number, p.path, f) catch return) orelse
            return self.status.setText(common.tr("There is no checker for this filesystem."));
        self.run(true, "Check a filesystem (read-only)", argv, "The check found no problems.");
    }

    // ---- pending operations ------------------------------------------------------------------

    fn realDisk(self: *const Parted, path: []const u8) ?model.Disk {
        for (self.real) |d| if (std.mem.eql(u8, d.path, path)) return d;
        return null;
    }

    /// Adds `op` for the disk at `disk_path` and shows the predicted layout.
    fn queueOp(self: *Parted, disk_path: []const u8, op_in: ops_mod.Op) void {
        const pa = self.pending_arena.allocator();
        // Own the strings (they come from dialogs).
        var op = op_in;
        switch (op) {
            .new_table => |*o| o.kind = pa.dupe(u8, o.kind) catch return,
            .format => |*o| o.label = pa.dupe(u8, o.label) catch return,
            .label => |*o| o.label = pa.dupe(u8, o.label) catch return,
            .flag => |*o| o.flag = pa.dupe(u8, o.flag) catch return,
            else => {},
        }
        // The layout this operation will see: everything before it, applied.
        const before = self.predicted(disk_path, self.pending.items.len) orelse return;
        if (op == .resize) {
            const o = op.resize;
            for (before.parts) |p| if (p.number == o.number) {
                const start_mib = p.start * before.sector / model.mib;
                const shrink = o.new_end_mib - start_mib < p.size / model.mib;
                if (fs.resizeRefusal(p.fstype, shrink)) |why| {
                    var buf: [200]u8 = undefined;
                    return self.status.setText(std.fmt.bufPrintSentinel(&buf, "{s}", .{why}, 0) catch "");
                }
            };
        }
        const text = ops_mod.describe(pa, before, op) catch return;
        self.pending.append(self.allocator, .{ .disk_path = pa.dupe(u8, disk_path) catch return, .op = op, .text = text }) catch return;
        self.recompute();
    }

    /// `disk_path` as it will be after the first `count` pending operations.
    fn predicted(self: *Parted, disk_path: []const u8, count: usize) ?model.Disk {
        var d = self.realDisk(disk_path) orelse return null;
        const a = self.sim_arena.allocator();
        for (self.pending.items[0..count]) |p| {
            if (!std.mem.eql(u8, p.disk_path, disk_path)) continue;
            d = ops_mod.simulate(a, d, p.op) catch return null;
        }
        return d;
    }

    /// Rebuilds `disks` from `real` plus the queue, and refreshes the screen.
    fn recompute(self: *Parted) void {
        _ = self.sim_arena.reset(.retain_capacity);
        const a = self.sim_arena.allocator();
        const out = a.alloc(model.Disk, self.real.len) catch return;
        for (self.real, 0..) |d, i| out[i] = self.predicted(d.path, self.pending.items.len) orelse d;
        self.disks = out;
        self.refreshPending();
        if (self.selected_disk != null) self.fillParts();
        self.updateButtons();
    }

    fn refreshPending(self: *Parted) void {
        self.pending_list.removeAll();
        for (self.pending.items) |p| {
            var buf: [300]u8 = undefined;
            const l = gtk.Label.new(std.fmt.bufPrintSentinel(&buf, "{s}", .{p.text}, 0) catch "");
            l.setXalign(0);
            l.as(gtk.Widget).setMarginTop(3);
            l.as(gtk.Widget).setMarginBottom(3);
            l.as(gtk.Widget).setMarginStart(6);
            self.pending_list.append(l.as(gtk.Widget));
        }
        var b: [48]u8 = undefined;
        self.apply_button.setLabel(std.fmt.bufPrintSentinel(&b, "Apply {d} operation{s}", .{ self.pending.items.len, if (self.pending.items.len == 1) "" else "s" }, 0) catch "Apply");
        self.pending_box.as(gtk.Widget).setVisible(@intFromBool(self.pending.items.len > 0));
    }

    fn onUndo(_: *gtk.Button, self: *Parted) callconv(.c) void {
        if (self.pending.items.len == 0) return;
        _ = self.pending.pop();
        self.recompute();
    }

    fn onClear(_: *gtk.Button, self: *Parted) callconv(.c) void {
        self.pending.clearRetainingCapacity();
        self.recompute();
    }

    /// The commands the queue would run, grouped by whether they need root.
    const Plan = struct { plain: []const ops_mod.Cmd, root: []const ops_mod.Cmd };

    fn plan(self: *Parted) ?Plan {
        const a = self.sim_arena.allocator();
        var plain: std.ArrayList(ops_mod.Cmd) = .empty;
        var root: std.ArrayList(ops_mod.Cmd) = .empty;
        // The layout of each disk as the queue is walked.
        const state = a.alloc(model.Disk, self.real.len) catch return null;
        @memcpy(state, self.real);
        for (self.pending.items) |p| {
            var di: usize = 0;
            while (di < state.len and !std.mem.eql(u8, state[di].path, p.disk_path)) di += 1;
            if (di == state.len) continue;
            const cmd = (ops_mod.commands(a, state[di], p.op) catch return null) orelse return null;
            (if (cmd.root) &root else &plain).append(a, cmd) catch return null;
            state[di] = ops_mod.simulate(a, state[di], p.op) catch return null;
        }
        return .{ .plain = plain.items, .root = root.items };
    }

    fn onShowCommands(_: *gtk.Button, self: *Parted) callconv(.c) void {
        const p = self.plan() orelse return self.status.setText(common.tr("Some operation cannot be turned into commands."));
        const a = self.sim_arena.allocator();
        const both = std.mem.concat(a, ops_mod.Cmd, &.{ p.plain, p.root }) catch return;
        const text = ops_mod.preview(a, both) catch return;
        self.showText(common.tr("Commands that will run"), text);
    }

    fn onApply(_: *gtk.Button, self: *Parted) callconv(.c) void {
        if (self.pending.items.len == 0 or self.busy) return;
        var buf: [600]u8 = undefined;
        var w: usize = 0;
        for (self.pending.items, 0..) |p, i| {
            if (i >= 8) {
                const more = std.fmt.bufPrint(buf[w..], "\u{2026} and {d} more\n", .{self.pending.items.len - 8}) catch break;
                w += more.len;
                break;
            }
            const line = std.fmt.bufPrint(buf[w..], "\u{2022} {s}\n", .{p.text}) catch break;
            w += line.len;
        }
        const text = std.fmt.allocPrintSentinel(self.allocator, "{s}\nThese changes cannot be undone. Make sure you have a backup of anything important on these disks.", .{buf[0..w]}, 0) catch return;
        defer self.allocator.free(text);
        common.dialogs.choose(self.window.as(gtk.Window), common.tr("Apply the pending operations?"), text, &.{ "Cancel", "Apply" }, 0, Parted, onApplyAnswer, self);
    }

    fn onApplyAnswer(self: *Parted, index: c_int) void {
        if (index != 1) return;
        const p = self.plan() orelse return self.status.setText(common.tr("Some operation cannot be turned into commands."));
        const a = self.sim_arena.allocator();
        self.busy = true;
        self.updateButtons();
        // Commands as you first (images), then the administrator ones in one go.
        self.apply_root = if (p.root.len > 0) (ops_mod.master(a, p.root) catch null) else null;
        const log_text = ops_mod.preview(a, std.mem.concat(a, ops_mod.Cmd, &.{ p.plain, p.root }) catch &.{}) catch "";
        self.logText("APPLY", log_text);
        self.status.setText(common.tr("Working\u{2026} (this cannot be cancelled once started)"));
        if (p.plain.len > 0) {
            const master = ops_mod.master(a, p.plain) catch return;
            common.proc.run(Parted, self.proc_guard, master, onPlainStage);
        } else self.runRootStage();
    }

    fn onPlainStage(self: *Parted, ok: bool, _: []const u8) void {
        if (!ok) return self.applyFinished(false, "A command failed while changing an image file.");
        self.runRootStage();
    }

    fn runRootStage(self: *Parted) void {
        const master = self.apply_root orelse return self.applyFinished(true, "");
        common.elevate.run(self.window.as(gtk.Window), "Apply partition changes", master, "", Parted, onRootStage, self);
    }

    fn onRootStage(self: *Parted, outcome: common.elevate.Outcome, message: []const u8) void {
        switch (outcome) {
            .ok => self.applyFinished(true, ""),
            .cancelled => {
                self.busy = false;
                self.status.setText(common.tr("Cancelled. Nothing was applied."));
                self.logText("CANCELLED", "");
                self.updateButtons();
            },
            .failed => self.applyFinished(false, message),
        }
    }

    fn applyFinished(self: *Parted, ok: bool, message: []const u8) void {
        self.busy = false;
        self.apply_root = null;
        self.logText(if (ok) "DONE" else "FAILED", message);
        if (ok) {
            self.status.setText(common.tr("Applied."));
        } else {
            var buf: [900]u8 = undefined;
            common.dialogs.showError(self.window.as(gtk.Window), common.tr("The operations failed"), std.fmt.bufPrintSentinel(&buf, "{s}\n\nEarlier steps may already have been applied. The layout shown has been re-read from the disks.", .{message[0..@min(message.len, 700)]}, 0) catch "");
        }
        self.pending.clearRetainingCapacity();
        self.rescan();
    }

    // The log of what was run, in the state folder.

    fn logPath(self: *Parted) ?[:0]u8 {
        return common.paths.userStateFile(self.allocator, "parted.log") catch null;
    }

    fn logText(self: *Parted, tag: []const u8, text: []const u8) void {
        const path = self.logPath() orelse return;
        defer self.allocator.free(path);
        var old: []u8 = &.{};
        var contents: [*]u8 = undefined;
        var length: usize = 0;
        if (glib.fileGetContents(path, &contents, &length, null) != 0) {
            defer glib.free(contents);
            // Keep the file from growing without end: the last 200 KiB.
            const keep = @min(length, 200 * 1024);
            old = self.allocator.dupe(u8, contents[length - keep .. length]) catch &.{};
        }
        defer if (old.len > 0) self.allocator.free(old);
        const now = glib.DateTime.newNowLocal() orelse return;
        defer now.unref();
        const stamp = now.format("%Y-%m-%d %H:%M:%S") orelse return;
        defer glib.free(stamp);
        const entry = std.fmt.allocPrint(self.allocator, "{s}[{s}] {s}\n{s}{s}", .{ old, std.mem.span(stamp), tag, text, if (text.len > 0 and text[text.len - 1] != '\n') "\n" else "" }) catch return;
        defer self.allocator.free(entry);
        const dir = glib.pathGetDirname(path);
        defer glib.free(dir);
        _ = glib.mkdirWithParents(dir, 0o755);
        _ = glib.fileSetContents(path, entry.ptr, @intCast(entry.len), null);
    }

    fn showLog(self: *Parted) void {
        const path = self.logPath() orelse return;
        defer self.allocator.free(path);
        var contents: [*]u8 = undefined;
        var length: usize = 0;
        if (glib.fileGetContents(path, &contents, &length, null) == 0) return self.showText(common.tr("Operation log"), "Nothing has been run yet.");
        defer glib.free(contents);
        self.showText(common.tr("Operation log"), contents[0..length]);
    }

    fn showText(self: *Parted, title: [:0]const u8, text: []const u8) void {
        const z = self.allocator.dupeSentinel(u8, text, 0) catch return;
        defer self.allocator.free(z);
        const window = gtk.Window.new();
        window.setTitle(title);
        window.setTransientFor(self.window.as(gtk.Window));
        window.setDefaultSize(720, 460);
        window.as(gtk.Widget).addCssClass("dkde");
        const label = gtk.Label.new(z);
        label.setSelectable(1);
        label.setXalign(0);
        label.setYalign(0);
        label.as(gtk.Widget).addCssClass("monospace");
        label.as(gtk.Widget).setMarginTop(12);
        label.as(gtk.Widget).setMarginStart(12);
        const scroller = gtk.ScrolledWindow.new();
        scroller.setChild(label.as(gtk.Widget));
        window.setChild(scroller.as(gtk.Widget));
        window.present();
    }

    // ---- running commands --------------------------------------------------------------------

    /// Runs `argv` as administrator when `root`, else as you (image files).
    fn run(self: *Parted, root: bool, reason: []const u8, argv: []const []const u8, done: []const u8) void {
        if (root) return self.runElevated(reason, argv, done);
        self.busy = true;
        self.done_len = @min(done.len, self.done_note.len);
        @memcpy(self.done_note[0..self.done_len], done[0..self.done_len]);
        self.updateButtons();
        self.status.setText(common.tr("Working\u{2026}"));
        common.proc.run(Parted, self.proc_guard, argv, onPlainDone);
    }

    fn onPlainDone(self: *Parted, ok: bool, _: []const u8) void {
        if (ok) return self.onRunDone(.ok, "");
        self.onRunDone(.failed, "The command failed. For an image file, check the path and that parted is installed.");
    }

    fn openImageDialog(self: *Parted) void {
        const dialog = gtk.FileDialog.new();
        defer dialog.as(gobject.Object).unref();
        dialog.setTitle(common.tr("Open a disk image"));
        dialog.open(self.window.as(gtk.Window), null, onImageChosen, self);
    }

    fn onImageChosen(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Parted = @ptrCast(@alignCast(data.?));
        const dialog: *gtk.FileDialog = @ptrCast(@alignCast(source.?));
        var err: ?*glib.Error = null;
        const file = dialog.openFinish(result, &err) orelse {
            if (err) |e| e.free();
            return;
        };
        defer file.as(gobject.Object).unref();
        const path = file.getPath() orelse return;
        defer glib.free(path);
        self.addImage(std.mem.span(path));
    }

    fn addImage(self: *Parted, path: []const u8) void {
        for (self.images.items) |p| if (std.mem.eql(u8, p, path)) return self.rescan();
        const copy = self.allocator.dupe(u8, path) catch return;
        self.images.append(self.allocator, copy) catch return;
        // Show the new image once the list is read.
        self.select_path = self.allocator.dupe(u8, path) catch null;
        self.rescan();
    }

    // ---- running as administrator ------------------------------------------------------------

    fn runElevated(self: *Parted, reason: []const u8, argv: []const []const u8, done: []const u8) void {
        self.busy = true;
        self.done_len = @min(done.len, self.done_note.len);
        @memcpy(self.done_note[0..self.done_len], done[0..self.done_len]);
        self.updateButtons();
        self.status.setText(common.tr("Working\u{2026}"));
        common.elevate.run(self.window.as(gtk.Window), reason, argv, "", Parted, onRunDone, self);
    }

    fn onRunDone(self: *Parted, outcome: common.elevate.Outcome, message: []const u8) void {
        self.busy = false;
        switch (outcome) {
            .ok => {
                if (self.pending_image) |path| {
                    self.addImage(path);
                    self.allocator.free(path);
                    self.pending_image = null;
                }
                var buf: [128]u8 = undefined;
                self.status.setText(std.fmt.bufPrintSentinel(&buf, "{s}", .{self.done_note[0..self.done_len]}, 0) catch "");
                self.rescan();
            },
            .cancelled => {
                self.status.setText(common.tr("Cancelled."));
                self.updateButtons();
            },
            .failed => {
                if (self.pending_image) |p| self.allocator.free(p);
                self.pending_image = null;
                var buf: [900]u8 = undefined;
                common.dialogs.showError(self.window.as(gtk.Window), common.tr("The operation failed"), std.fmt.bufPrintSentinel(&buf, "{s}", .{message[0..@min(message.len, 800)]}, 0) catch "");
                self.rescan();
            },
        }
    }
};

fn formatSize(buf: *[32]u8, bytes: u64) []const u8 {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB" };
    var v: f64 = @floatFromInt(bytes);
    var u: usize = 0;
    while (v >= 1024 and u + 1 < units.len) : (u += 1) v /= 1024;
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ v, units[u] }) catch "";
}

pub fn main(init: std.process.Init.Minimal) !void {
    // `--selftest IMAGE` runs headless, with no window.
    if (init.args.vector.len > 2 and std.mem.eql(u8, std.mem.span(init.args.vector[1]), "--selftest")) {
        var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
        defer _ = debug_allocator.deinit();
        std.process.exit(selftest.run(debug_allocator.allocator(), std.mem.span(init.args.vector[2])));
    }
    try common.runapp.run("org.dkde.parted", Parted, init);
}

test {
    _ = @import("model.zig");
    _ = @import("fs.zig");
    _ = @import("ops.zig");
}
