//! dkde-disks: how full each mounted filesystem is, and which folders take the
//! space (SPEC.md 5.6). Scanning runs in small steps so the window stays alive.

const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

const pure = @import("pure.zig");

pub const std_options: std.Options = .{ .logFn = common.log.logFn, .log_level = .debug };

const Entry = struct { name: []u8, size: u64 = 0 };

const Disks = struct {
    allocator: std.mem.Allocator,
    window: *gtk.ApplicationWindow,
    filesystems: *gtk.Box,
    results: *gtk.Box,
    status: *gtk.Label,
    root: ?[]u8 = null,
    /// Immediate children of the scanned folder with their totals.
    entries: std.ArrayList(Entry) = .empty,
    /// Folders still to visit, each with the index of the entry it adds to.
    pending: std.ArrayList(struct { path: []u8, owner: usize }) = .empty,
    scan_source: c_uint = 0,
    files_seen: u64 = 0,

    pub fn create(allocator: std.mem.Allocator, app: *gtk.Application) !*Disks {
        const self = try allocator.create(Disks);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .window = gtk.ApplicationWindow.new(app),
            .filesystems = gtk.Box.new(.vertical, 8),
            .results = gtk.Box.new(.vertical, 4),
            .status = gtk.Label.new(""),
        };
        const window = self.window.as(gtk.Window);
        window.setTitle(common.tr("Disk Usage"));
        window.setDefaultSize(700, 620);
        self.window.as(gtk.Widget).addCssClass("dkde");
        _ = common.header.create(window, "drive-harddisk", true);

        const root = gtk.Box.new(.vertical, 8);
        root.as(gtk.Widget).setMarginTop(12);
        root.as(gtk.Widget).setMarginBottom(12);
        root.as(gtk.Widget).setMarginStart(16);
        root.as(gtk.Widget).setMarginEnd(16);

        const h1 = gtk.Label.new(common.tr("Filesystems"));
        h1.setXalign(0);
        h1.as(gtk.Widget).addCssClass("heading");
        root.append(h1.as(gtk.Widget));
        // A machine with many mounts must not push the folder sizes off screen.
        const fs_scroller = gtk.ScrolledWindow.new();
        fs_scroller.setChild(self.filesystems.as(gtk.Widget));
        fs_scroller.setPropagateNaturalHeight(1);
        fs_scroller.setMaxContentHeight(230);
        fs_scroller.setPolicy(.never, .automatic);
        root.append(fs_scroller.as(gtk.Widget));

        const bar = gtk.Box.new(.horizontal, 8);
        const h2 = gtk.Label.new(common.tr("Folder sizes"));
        h2.setXalign(0);
        h2.as(gtk.Widget).addCssClass("heading");
        h2.as(gtk.Widget).setHexpand(1);
        const home = gtk.Button.newWithLabel(common.tr("Scan home"));
        _ = gtk.Button.signals.clicked.connect(home, *Disks, &onScanHome, self, .{});
        const choose = gtk.Button.newWithLabel(common.tr("Scan a folder\u{2026}"));
        choose.as(gtk.Widget).addCssClass("suggested-action");
        _ = gtk.Button.signals.clicked.connect(choose, *Disks, &onChoose, self, .{});
        bar.append(h2.as(gtk.Widget));
        bar.append(home.as(gtk.Widget));
        bar.append(choose.as(gtk.Widget));
        root.append(bar.as(gtk.Widget));

        self.status.setXalign(0);
        self.status.as(gtk.Widget).addCssClass("dim-label");
        root.append(self.status.as(gtk.Widget));
        const scroller = gtk.ScrolledWindow.new();
        scroller.setChild(self.results.as(gtk.Widget));
        scroller.as(gtk.Widget).setVexpand(1);
        root.append(scroller.as(gtk.Widget));
        window.setChild(root.as(gtk.Widget));

        _ = gtk.Widget.signals.destroy.connect(self.window, *Disks, &onDestroy, self, .{});
        self.loadFilesystems();
        // Dev aid: start a scan at once, for screenshots.
        if (glib.getenv("DKDE_DISKS_SCAN")) |path| self.startScan(std.mem.span(path));
        return self;
    }

    pub fn present(self: *Disks) void {
        self.window.as(gtk.Window).present();
    }

    fn onDestroy(_: *gtk.ApplicationWindow, self: *Disks) callconv(.c) void {
        self.stopScan();
        self.clearEntries();
        self.entries.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        if (self.root) |r| self.allocator.free(r);
        self.allocator.destroy(self);
    }

    // ---- filesystems ----------------------------------------------------------------------

    fn usageRow(self: *Disks, title: []const u8, subtitle: []const u8, fraction: f64) *gtk.Box {
        _ = self;
        const box = gtk.Box.new(.vertical, 2);
        var z: [512]u8 = undefined;
        const name = gtk.Label.new(std.fmt.bufPrintSentinel(&z, "{s}", .{title}, 0) catch "");
        name.setXalign(0);
        name.setEllipsize(.middle);
        box.append(name.as(gtk.Widget));
        const progress = gtk.ProgressBar.new();
        progress.setFraction(std.math.clamp(fraction, 0, 1));
        if (fraction > 0.9) progress.as(gtk.Widget).addCssClass("dkde-bar-full");
        box.append(progress.as(gtk.Widget));
        var z2: [256]u8 = undefined;
        const detail = gtk.Label.new(std.fmt.bufPrintSentinel(&z2, "{s}", .{subtitle}, 0) catch "");
        detail.setXalign(0);
        detail.as(gtk.Widget).addCssClass("dim-label");
        box.append(detail.as(gtk.Widget));
        return box;
    }

    fn loadFilesystems(self: *Disks) void {
        var contents: [*]u8 = undefined;
        var length: usize = 0;
        if (glib.fileGetContents("/proc/self/mounts", &contents, &length, null) == 0) return;
        defer glib.free(contents);
        var seen: std.ArrayList([]const u8) = .empty;
        defer seen.deinit(self.allocator);
        var lines = std.mem.splitScalar(u8, contents[0..length], '\n');
        while (lines.next()) |line| {
            const m = pure.parseMountLine(line) orelse continue;
            if (!pure.isInteresting(m.fstype, m.point)) continue;
            // The same device is often mounted more than once.
            var dup = false;
            for (seen.items) |d| if (std.mem.eql(u8, d, m.device)) {
                dup = true;
            };
            if (dup) continue;
            seen.append(self.allocator, m.device) catch {};

            const point_z = self.allocator.dupeSentinel(u8, m.point, 0) catch continue;
            defer self.allocator.free(point_z);
            const file = gio.File.newForPath(point_z);
            defer file.as(gobject.Object).unref();
            const info = file.queryFilesystemInfo("filesystem::size,filesystem::free", null, null) orelse continue;
            defer info.as(gobject.Object).unref();
            const size = info.getAttributeUint64("filesystem::size");
            const free = info.getAttributeUint64("filesystem::free");
            if (size == 0) continue;
            var a: [32]u8 = undefined;
            var b: [32]u8 = undefined;
            var c: [32]u8 = undefined;
            var sub: [160]u8 = undefined;
            const text = std.fmt.bufPrint(&sub, "{s} of {s} used, {s} free \u{2014} {s}", .{
                pure.formatSize(&a, size - free),
                pure.formatSize(&b, size),
                pure.formatSize(&c, free),
                m.fstype,
            }) catch "";
            var title: [320]u8 = undefined;
            const heading = std.fmt.bufPrint(&title, "{s}   ({s})", .{ m.point, m.device }) catch m.point;
            self.filesystems.append(self.usageRow(heading, text, @as(f64, @floatFromInt(size - free)) / @as(f64, @floatFromInt(size))).as(gtk.Widget));
        }
    }

    // ---- scanning -------------------------------------------------------------------------

    fn onScanHome(_: *gtk.Button, self: *Disks) callconv(.c) void {
        self.startScan(std.mem.span(glib.getHomeDir()));
    }

    fn onChoose(_: *gtk.Button, self: *Disks) callconv(.c) void {
        const dialog = gtk.FileDialog.new();
        defer dialog.as(gobject.Object).unref();
        dialog.selectFolder(self.window.as(gtk.Window), null, onFolderChosen, self);
    }

    fn onFolderChosen(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Disks = @ptrCast(@alignCast(data.?));
        const dialog: *gtk.FileDialog = @ptrCast(@alignCast(source.?));
        var err: ?*glib.Error = null;
        const file = dialog.selectFolderFinish(result, &err) orelse {
            if (err) |e| e.free();
            return;
        };
        defer file.as(gobject.Object).unref();
        const path = file.getPath() orelse return;
        defer glib.free(path);
        self.startScan(std.mem.span(path));
    }

    fn stopScan(self: *Disks) void {
        if (self.scan_source != 0) _ = glib.Source.remove(self.scan_source);
        self.scan_source = 0;
        for (self.pending.items) |p| self.allocator.free(p.path);
        self.pending.clearRetainingCapacity();
    }

    fn clearEntries(self: *Disks) void {
        for (self.entries.items) |e| self.allocator.free(e.name);
        self.entries.clearRetainingCapacity();
    }

    fn startScan(self: *Disks, path: []const u8) void {
        self.stopScan();
        self.clearEntries();
        self.files_seen = 0;
        if (self.root) |r| self.allocator.free(r);
        self.root = self.allocator.dupe(u8, path) catch return;
        self.pending.append(self.allocator, .{ .path = self.allocator.dupe(u8, path) catch return, .owner = std.math.maxInt(usize) }) catch return;
        self.scan_source = glib.idleAdd(onScanStep, self);
        self.showResults();
    }

    const attrs = "standard::name,standard::type,standard::allocated-size,standard::size";

    /// Visits one folder per call, adding its files to the entry it belongs to.
    fn onScanStep(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Disks = @ptrCast(@alignCast(data.?));
        const job = self.pending.pop() orelse {
            self.scan_source = 0;
            self.showResults();
            return 0;
        };
        defer self.allocator.free(job.path);
        const z = self.allocator.dupeSentinel(u8, job.path, 0) catch return 1;
        defer self.allocator.free(z);
        const dir = gio.File.newForPath(z);
        defer dir.as(gobject.Object).unref();
        const children = dir.enumerateChildren(attrs, .{ .nofollow_symlinks = true }, null, null) orelse return 1;
        defer children.as(gobject.Object).unref();
        while (children.nextFile(null, null)) |info| {
            defer info.as(gobject.Object).unref();
            self.files_seen += 1;
            const name = std.mem.span(info.getName());
            var owner = job.owner;
            if (owner == std.math.maxInt(usize)) {
                // First level: each child is its own entry.
                self.entries.append(self.allocator, .{ .name = self.allocator.dupe(u8, name) catch continue }) catch continue;
                owner = self.entries.items.len - 1;
            }
            const alloc: u64 = info.getAttributeUint64("standard::allocated-size");
            const size: u64 = if (alloc > 0) alloc else @intCast(@max(0, info.getSize()));
            if (info.getFileType() == .directory) {
                self.entries.items[owner].size += size;
                const child_path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ job.path, name }) catch continue;
                self.pending.append(self.allocator, .{ .path = child_path, .owner = owner }) catch self.allocator.free(child_path);
            } else self.entries.items[owner].size += size;
        }
        if (self.files_seen % 64 < 8) self.showResults();
        return 1;
    }

    fn showResults(self: *Disks) void {
        while (self.results.as(gtk.Widget).getFirstChild()) |child| self.results.remove(child);
        var buf: [160]u8 = undefined;
        self.status.setText(std.fmt.bufPrintSentinel(&buf, "{s}{d} items seen", .{ if (self.scan_source != 0) "Scanning\u{2026} " else "", self.files_seen }, 0) catch "");
        const less = struct {
            fn f(_: void, a: Entry, b: Entry) bool {
                return a.size > b.size;
            }
        }.f;
        std.mem.sort(Entry, self.entries.items, {}, less);
        var total: u64 = 0;
        for (self.entries.items) |e| total += e.size;
        const shown = @min(self.entries.items.len, 40);
        for (self.entries.items[0..shown]) |e| {
            var size_buf: [32]u8 = undefined;
            var pct: [48]u8 = undefined;
            const fraction = if (total > 0) @as(f64, @floatFromInt(e.size)) / @as(f64, @floatFromInt(total)) else 0;
            const sub = std.fmt.bufPrint(&pct, "{s}   {d:.0}%", .{ pure.formatSize(&size_buf, e.size), fraction * 100 }) catch "";
            self.results.append(self.usageRow(e.name, sub, fraction).as(gtk.Widget));
        }
    }
};

pub fn main(init: std.process.Init.Minimal) !void {
    try common.runapp.run("org.dkde.disks", Disks, init);
}

test {
    _ = @import("pure.zig");
}
