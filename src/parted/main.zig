//! dkde-parted: disks and partitions (SPEC.md 5.6). It reads `lsblk`, shows each
//! disk with a size bar, and changes disks only through `parted`, `mkfs.*`,
//! `mount`, `umount` and the checkers, as administrator, after a confirmation.

const std = @import("std");
const cairo = @import("cairo1");
const gdk = @import("gdk4");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

const model = @import("model.zig");

pub const std_options: std.Options = .{ .logFn = common.log.logFn, .log_level = .debug };

const lsblk_columns = "NAME,PATH,TYPE,SIZE,START,FSTYPE,LABEL,MOUNTPOINTS,PTTYPE,MODEL,RM,RO,LOG-SEC";

const Action = enum { new_table, new_partition, format, mount };

const Row = union(enum) { part: usize, gap: usize };

const Dlg = struct {
    app: *Parted,
    window: *gtk.Window,
    action: Action,
    dropdown: ?*gtk.DropDown = null,
    spin: ?*gtk.SpinButton = null,
    entry: ?*gtk.Entry = null,
    /// The filesystems the dropdown lists, in order.
    kinds: [7]model.FsKind = undefined,
    n_kinds: usize = 0,
};

const Parted = struct {
    allocator: std.mem.Allocator,
    window: *gtk.ApplicationWindow,
    disk_list: *gtk.ListBox,
    part_list: *gtk.ListBox,
    bar: *gtk.DrawingArea,
    status: *gtk.Label,
    probe: *gtk.Widget,
    buttons: [8]*gtk.Button = undefined,
    arena: std.heap.ArenaAllocator,
    disks: []const model.Disk = &.{},
    gaps: []const model.Gap = &.{},
    rows: std.ArrayList(Row) = .empty,
    selected_disk: ?usize = null,
    selected_row: ?usize = null,
    busy: bool = false,
    proc_guard: *common.proc.Guard(Parted) = undefined,
    /// What to say when the running command works.
    done_note: [96]u8 = undefined,
    done_len: usize = 0,

    const b_rescan = 0;
    const b_table = 1;
    const b_new = 2;
    const b_delete = 3;
    const b_format = 4;
    const b_mount = 5;
    const b_unmount = 6;
    const b_check = 7;

    pub fn create(allocator: std.mem.Allocator, app: *gtk.Application) !*Parted {
        const self = try allocator.create(Parted);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .window = gtk.ApplicationWindow.new(app),
            .disk_list = gtk.ListBox.new(),
            .part_list = gtk.ListBox.new(),
            .bar = gtk.DrawingArea.new(),
            .status = gtk.Label.new(""),
            .probe = undefined,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
        self.proc_guard = common.proc.Guard(Parted).create(self);
        const probe = gtk.Label.new("");
        probe.as(gtk.Widget).addCssClass("dkde-accent-probe");
        self.probe = probe.as(gtk.Widget);

        const window = self.window.as(gtk.Window);
        window.setTitle(common.tr("Partitions"));
        window.setDefaultSize(960, 600);
        self.window.as(gtk.Widget).addCssClass("dkde");
        _ = common.header.create(window, "drive-harddisk", true);

        // Toolbar.
        const bar = gtk.Box.new(.horizontal, 6);
        bar.as(gtk.Widget).setMarginTop(8);
        bar.as(gtk.Widget).setMarginBottom(4);
        bar.as(gtk.Widget).setMarginStart(12);
        bar.as(gtk.Widget).setMarginEnd(12);
        const labels = [_][:0]const u8{ "Rescan", "New table\u{2026}", "New partition\u{2026}", "Delete\u{2026}", "Format\u{2026}", "Mount\u{2026}", "Unmount", "Check" };
        inline for (labels, 0..) |text, i| {
            const b = gtk.Button.newWithLabel(common.tr(text));
            _ = gtk.Button.signals.clicked.connect(b, *Parted, &onButton(i), self, .{});
            bar.append(b.as(gtk.Widget));
            self.buttons[i] = b;
        }
        bar.append(self.probe);

        // Disks on the left.
        self.disk_list.setSelectionMode(.single);
        const disk_scroller = gtk.ScrolledWindow.new();
        disk_scroller.setChild(self.disk_list.as(gtk.Widget));
        disk_scroller.as(gtk.Widget).setSizeRequest(260, -1);
        _ = gtk.ListBox.signals.row_selected.connect(self.disk_list, *Parted, &onDiskSelected, self, .{});

        // The size bar and the partitions on the right.
        self.bar.as(gtk.Widget).setSizeRequest(-1, 44);
        self.bar.as(gtk.Widget).setMarginTop(8);
        self.bar.as(gtk.Widget).setMarginStart(8);
        self.bar.as(gtk.Widget).setMarginEnd(8);
        self.bar.setDrawFunc(onDraw, self, null);
        self.part_list.setSelectionMode(.single);
        _ = gtk.ListBox.signals.row_selected.connect(self.part_list, *Parted, &onRowSelected, self, .{});
        const part_scroller = gtk.ScrolledWindow.new();
        part_scroller.setChild(self.part_list.as(gtk.Widget));
        part_scroller.as(gtk.Widget).setVexpand(1);
        part_scroller.as(gtk.Widget).setMarginStart(8);
        part_scroller.as(gtk.Widget).setMarginEnd(8);
        part_scroller.as(gtk.Widget).setMarginBottom(8);
        const right = gtk.Box.new(.vertical, 0);
        right.append(self.bar.as(gtk.Widget));
        right.append(part_scroller.as(gtk.Widget));

        const paned = gtk.Paned.new(.horizontal);
        paned.setStartChild(disk_scroller.as(gtk.Widget));
        paned.setEndChild(right.as(gtk.Widget));
        paned.setShrinkStartChild(0);
        paned.setResizeStartChild(0);
        paned.as(gtk.Widget).setVexpand(1);

        self.status.setXalign(0);
        self.status.as(gtk.Widget).setMarginStart(12);
        self.status.as(gtk.Widget).setMarginTop(4);
        self.status.as(gtk.Widget).setMarginBottom(6);
        self.status.as(gtk.Widget).addCssClass("dim-label");

        const root = gtk.Box.new(.vertical, 0);
        root.append(bar.as(gtk.Widget));
        root.append(paned.as(gtk.Widget));
        root.append(self.status.as(gtk.Widget));
        window.setChild(root.as(gtk.Widget));
        _ = gtk.Widget.signals.destroy.connect(self.window, *Parted, &onDestroy, self, .{});

        self.updateButtons();
        self.rescan();
        return self;
    }

    pub fn present(self: *Parted) void {
        self.window.as(gtk.Window).present();
    }

    fn onDestroy(_: *gtk.ApplicationWindow, self: *Parted) callconv(.c) void {
        self.proc_guard.kill();
        self.rows.deinit(self.allocator);
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    fn onButton(comptime index: usize) fn (*gtk.Button, *Parted) callconv(.c) void {
        return struct {
            fn call(_: *gtk.Button, self: *Parted) callconv(.c) void {
                switch (index) {
                    b_rescan => self.rescan(),
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
        self.status.setText(common.tr("Reading the disks\u{2026}"));
        common.proc.run(Parted, self.proc_guard, &.{ "lsblk", "-J", "-b", "-o", lsblk_columns }, onLsblk);
    }

    fn onLsblk(self: *Parted, ok: bool, out: []const u8) void {
        if (!ok) {
            self.status.setText(common.tr("lsblk is missing or failed, so the disks cannot be listed."));
            return;
        }
        var fresh = std.heap.ArenaAllocator.init(self.allocator);
        const disks = model.parseLsblk(fresh.allocator(), out) catch {
            fresh.deinit();
            self.status.setText(common.tr("The disk list could not be read."));
            return;
        };
        const keep = self.selected_disk;
        self.arena.deinit();
        self.arena = fresh;
        self.disks = disks;
        self.selected_disk = null;
        self.selected_row = null;
        self.fillDisks();
        // Stay on the same disk after a change.
        const index = if (keep) |k| (if (k < disks.len) k else 0) else 0;
        if (disks.len > 0) if (self.disk_list.getRowAtIndex(@intCast(index))) |row| self.disk_list.selectRow(row);
        self.status.setText("");
    }

    fn fillDisks(self: *Parted) void {
        self.disk_list.removeAll();
        for (self.disks) |d| {
            const box = gtk.Box.new(.vertical, 2);
            box.as(gtk.Widget).setMarginTop(6);
            box.as(gtk.Widget).setMarginBottom(6);
            box.as(gtk.Widget).setMarginStart(8);
            var buf: [160]u8 = undefined;
            const title = gtk.Label.new(std.fmt.bufPrintSentinel(&buf, "{s}  {s}", .{ d.path, d.model }, 0) catch "");
            title.setXalign(0);
            title.as(gtk.Widget).addCssClass("heading");
            var buf2: [160]u8 = undefined;
            var size_buf: [32]u8 = undefined;
            const sub = gtk.Label.new(std.fmt.bufPrintSentinel(&buf2, "{s}, {s}{s}{s}", .{
                formatSize(&size_buf, d.size),
                if (d.table.len > 0) d.table else if (d.fstype.len > 0) d.fstype else "no table",
                if (d.removable) ", removable" else "",
                if (model.isSystemDisk(d)) ", system" else "",
            }, 0) catch "");
            sub.setXalign(0);
            sub.as(gtk.Widget).addCssClass("dim-label");
            box.append(title.as(gtk.Widget));
            box.append(sub.as(gtk.Widget));
            self.disk_list.append(box.as(gtk.Widget));
        }
    }

    fn onDiskSelected(_: *gtk.ListBox, row: ?*gtk.ListBoxRow, self: *Parted) callconv(.c) void {
        const r = row orelse return;
        const i: usize = @intCast(r.getIndex());
        if (i >= self.disks.len) return;
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
        self.bar.as(gtk.Widget).queueDraw();
        self.updateButtons();
    }

    fn addRow(self: *Parted, row: Row) void {
        self.rows.append(self.allocator, row) catch return;
        const d = self.disks[self.selected_disk.?];
        const line = gtk.Box.new(.horizontal, 12);
        line.as(gtk.Widget).setMarginTop(5);
        line.as(gtk.Widget).setMarginBottom(5);
        line.as(gtk.Widget).setMarginStart(8);
        var size_buf: [32]u8 = undefined;
        var buf: [256]u8 = undefined;
        switch (row) {
            .part => |i| {
                const p = d.parts[i];
                const mounts = if (p.mounts.len > 0) p.mounts[0] else "";
                const text = std.fmt.bufPrintSentinel(&buf, "{s}   {s}   {s}   {s}   {s}", .{
                    p.path,
                    if (p.fstype.len > 0) p.fstype else "unformatted",
                    if (p.label.len > 0) p.label else "-",
                    formatSize(&size_buf, p.size),
                    if (mounts.len > 0) mounts else "not mounted",
                }, 0) catch "";
                const l = gtk.Label.new(text);
                l.setXalign(0);
                l.as(gtk.Widget).addCssClass("monospace");
                line.append(l.as(gtk.Widget));
            },
            .gap => |i| {
                const g = self.gaps[i];
                const text = std.fmt.bufPrintSentinel(&buf, "Free space   {s}", .{formatSize(&size_buf, g.bytes(d.sector))}, 0) catch "";
                const l = gtk.Label.new(text);
                l.setXalign(0);
                l.as(gtk.Widget).addCssClass("dim-label");
                line.append(l.as(gtk.Widget));
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
        set(self.buttons[b_table], writable and common.proc.hasProgram("parted"));
        set(self.buttons[b_new], writable and self.selectedGap() != null and d.?.table.len > 0 and common.proc.hasProgram("parted"));
        set(self.buttons[b_delete], writable and part != null and common.proc.hasProgram("parted"));
        set(self.buttons[b_format], writable and part != null);
        // Mounting does not rewrite a disk, so only the busy state matters.
        set(self.buttons[b_mount], !self.busy and part != null and part.?.mounts.len == 0 and part.?.fstype.len > 0);
        set(self.buttons[b_unmount], !self.busy and part != null and part.?.mounts.len > 0 and !(d != null and model.isSystemDisk(d.?)));
        set(self.buttons[b_check], !self.busy and part != null and part.?.mounts.len == 0 and part.?.fstype.len > 0);
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
            if (self.selected_row != null and self.selected_row.? == ri) {
                cr.setSourceRgba(accent.f_red, accent.f_green, accent.f_blue, 1);
                cr.setLineWidth(3);
                cr.rectangle(x + 1.5, 1.5, seg - 3, h - 3);
                cr.stroke();
                cr.setLineWidth(1);
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
                finishDialog(made.dlg, made.box, common.tr("Create"), false);
            },
            .format => {
                const p = self.selectedPart() orelse return;
                const text = std.fmt.bufPrintSentinel(&msg, "Formatting {s} ERASES ALL DATA on it. This cannot be undone.", .{p.path}, 0) catch return;
                const made = self.newDialog(.format, common.tr("Format partition"), text, "", true) orelse return;
                // Only the filesystems whose tool is installed.
                var names: [8]?[*:0]const u8 = @splat(null);
                var n: usize = 0;
                inline for (@typeInfo(model.FsKind).@"enum".field_names) |name| {
                    const kind = @field(model.FsKind, name);
                    if (common.proc.hasProgram(model.fsTool(kind))) {
                        made.dlg.kinds[n] = kind;
                        names[n] = model.fsName(kind).ptr;
                        n += 1;
                    }
                }
                made.dlg.n_kinds = n;
                if (n == 0) {
                    made.dlg.window.destroy();
                    return self.status.setText(common.tr("No mkfs tools are installed."));
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
                const argv = model.newTable(a, d.path, kind) catch return;
                self.runElevated("Create a partition table", argv, "Partition table created.");
            },
            .new_partition => {
                const gap = self.selectedGap() orelse return;
                const start_mib = gap.start * d.sector / model.mib;
                const size: u64 = @intCast(dlg.spin.?.getValueAsInt());
                const argv = model.newPartition(a, d.path, start_mib, start_mib + size) catch return;
                self.runElevated("Create a partition", argv, "Partition created. Format it to use it.");
            },
            .format => {
                const p = self.selectedPart() orelse return;
                const idx: usize = @intCast(dlg.dropdown.?.getSelected());
                if (idx >= dlg.n_kinds) return;
                const label = std.mem.span(dlg.entry.?.as(gtk.Editable).getText());
                const argv = model.format(a, dlg.kinds[idx], label, p.path) catch return;
                self.runElevated("Format a partition", argv, "Formatted.");
            },
            .mount => {
                const p = self.selectedPart() orelse return;
                const dir = std.mem.span(dlg.entry.?.as(gtk.Editable).getText());
                if (dir.len == 0 or dir[0] != '/') return self.status.setText(common.tr("Give a full folder path, such as /mnt/data."));
                const argv = model.mount(a, p.path, dir) catch return;
                self.runElevated("Mount a partition", argv, "Mounted.");
            },
        }
    }

    fn askDelete(self: *Parted) void {
        const p = self.selectedPart() orelse return;
        var buf: [300]u8 = undefined;
        const text = std.fmt.bufPrintSentinel(&buf, "Delete {s}? Its data becomes inaccessible. This cannot be undone.", .{p.path}, 0) catch return;
        common.dialogs.choose(self.window.as(gtk.Window), common.tr("Delete partition?"), text, &.{ "Cancel", "Delete" }, 0, Parted, onDeleteAnswer, self);
    }

    fn onDeleteAnswer(self: *Parted, index: c_int) void {
        if (index != 1) return;
        const d = self.selectedDisk() orelse return;
        const p = self.selectedPart() orelse return;
        const argv = model.deletePartition(self.arena.allocator(), d.path, p.number) catch return;
        self.runElevated("Delete a partition", argv, "Deleted.");
    }

    fn unmountSelected(self: *Parted) void {
        const p = self.selectedPart() orelse return;
        const argv = model.unmount(self.arena.allocator(), p.path) catch return;
        self.runElevated("Unmount a partition", argv, "Unmounted.");
    }

    fn checkSelected(self: *Parted) void {
        const p = self.selectedPart() orelse return;
        const argv = model.check(self.arena.allocator(), p.fstype, p.path) catch return;
        self.runElevated("Check a filesystem (read-only)", argv, "The check found no problems.");
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
                var buf: [128]u8 = undefined;
                self.status.setText(std.fmt.bufPrintSentinel(&buf, "{s}", .{self.done_note[0..self.done_len]}, 0) catch "");
                self.rescan();
            },
            .cancelled => {
                self.status.setText(common.tr("Cancelled."));
                self.updateButtons();
            },
            .failed => {
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
    try common.runapp.run("org.dkde.parted", Parted, init);
}

test {
    _ = @import("model.zig");
}
