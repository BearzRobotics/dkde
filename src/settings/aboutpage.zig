//! The About page (SPEC.md 5.5): what this computer is, in one place, with a
//! button that copies it for a bug report.

const std = @import("std");
const builtin = @import("builtin");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");
const build_options = @import("build_options");

const info = @import("sysinfo.zig");
const win = @import("window.zig");
const SettingsWindow = win.SettingsWindow;

const gpa = std.heap.c_allocator;

fn readText(path: [:0]const u8) ?[]u8 {
    var contents: [*]u8 = undefined;
    var length: usize = 0;
    if (glib.fileGetContents(path, &contents, &length, null) == 0) return null;
    defer glib.free(contents);
    return gpa.dupe(u8, contents[0..length]) catch null;
}

/// Free space and size of the file system holding `/`.
fn rootStorage(buf: []u8) []const u8 {
    const root = gio.File.newForPath("/");
    defer root.as(gobject.Object).unref();
    const fi = root.queryFilesystemInfo("filesystem::size,filesystem::free", null, null) orelse return "—";
    defer fi.as(gobject.Object).unref();
    const size = fi.getAttributeUint64("filesystem::size");
    const free = fi.getAttributeUint64("filesystem::free");
    if (size == 0) return "—";
    var a: [24]u8 = undefined;
    var b: [24]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s} free of {s}", .{ info.formatBytes(&a, free), info.formatBytes(&b, size) }) catch "—";
}

pub const AboutPage = struct {
    /// "Label: value" lines, for the Copy button.
    text: std.ArrayList(u8) = .empty,
    window: *SettingsWindow,

    pub fn build(window: *SettingsWindow) *gtk.Box {
        const page = SettingsWindow.newPage(common.tr("About"));
        const self = gpa.create(AboutPage) catch @panic("OOM");
        self.* = .{ .window = window };

        var buf: [160]u8 = undefined;

        self.row(page, "Device name", std.mem.span(glib.getHostName()));

        var os_text: []const u8 = "Linux";
        const os_file = readText("/etc/os-release") orelse readText("/usr/lib/os-release");
        defer if (os_file) |f| gpa.free(f);
        if (os_file) |f| os_text = info.osPrettyName(f) orelse os_text;
        self.row(page, "Operating system", os_text);

        const kernel = readText("/proc/sys/kernel/osrelease");
        defer if (kernel) |k| gpa.free(k);
        self.row(page, "Kernel", std.fmt.bufPrint(&buf, "Linux {s}", .{std.mem.trim(u8, kernel orelse "?", " \n")}) catch "Linux");
        self.row(page, "Architecture", @tagName(builtin.cpu.arch));

        const cpuinfo = readText("/proc/cpuinfo");
        defer if (cpuinfo) |c| gpa.free(c);
        if (cpuinfo) |c| {
            const cpu = info.parseCpu(c);
            self.row(page, "Processor", std.fmt.bufPrint(&buf, "{s} ({d} logical)", .{ if (cpu.model.len > 0) cpu.model else "unknown", cpu.logical }) catch "unknown");
        }

        const meminfo = readText("/proc/meminfo");
        defer if (meminfo) |m| gpa.free(m);
        if (meminfo) |m| if (info.memTotalKb(m)) |kb| {
            var mb: [24]u8 = undefined;
            self.row(page, "Memory", info.formatBytes(&mb, kb * 1024));
        };

        var sb: [64]u8 = undefined;
        self.row(page, "Storage", rootStorage(&sb));

        const up = readText("/proc/uptime");
        defer if (up) |u| gpa.free(u);
        if (up) |u| {
            const secs = std.fmt.parseFloat(f64, std.mem.sliceTo(u, ' ')) catch 0;
            const s: u64 = @intFromFloat(secs);
            self.row(page, "Up time", std.fmt.bufPrint(&buf, "{d} days, {d} hours, {d} minutes", .{ s / 86400, s % 86400 / 3600, s % 3600 / 60 }) catch "");
        }

        self.row(page, "dkde", "version " ++ build_options.version);

        const copy = gtk.Button.newWithLabel(common.tr("Copy"));
        copy.as(gtk.Widget).setHalign(.start);
        _ = gtk.Button.signals.clicked.connect(copy, *AboutPage, &onCopy, self, .{});
        page.append(copy.as(gtk.Widget));
        return page;
    }

    fn row(self: *AboutPage, page: *gtk.Box, label: [:0]const u8, value: []const u8) void {
        const z = gpa.dupeSentinel(u8, value, 0) catch return;
        defer gpa.free(z);
        const v = gtk.Label.new(z);
        v.setSelectable(1);
        v.setXalign(1);
        v.setWrap(1);
        SettingsWindow.addRow(page, label, v.as(gtk.Widget));
        self.text.print(gpa, "{s}: {s}\n", .{ label, value }) catch {};
    }

    fn onCopy(_: *gtk.Button, self: *AboutPage) callconv(.c) void {
        const z = gpa.dupeSentinel(u8, self.text.items, 0) catch return;
        defer gpa.free(z);
        self.window.window.as(gtk.Widget).getClipboard().setText(z);
    }
};
