//! dkde-snip: screenshots (SPEC.md 5.6) through `wlr-screencopy-unstable-v1`.
//!
//! The whole output is captured first; for a region the picture is shown
//! frozen, full screen, and the user drags a rectangle on it. Window capture
//! and scrolling capture are not offered: the protocols dkde uses give no
//! window geometry and no way to drive another program's scrolling.

const std = @import("std");
const cairo = @import("cairo1");
const gdk = @import("gdk4");
const gdkpixbuf = @import("gdkpixbuf2");
const gdkwayland = @import("gdkwayland4");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const wayland = @import("wayland");
const common = @import("common");

const build_options = @import("build_options");
const pure = @import("pure.zig");
const x11grab = if (build_options.x11) @import("x11grab.zig") else struct {
    pub fn isActive() bool {
        return false;
    }
};

const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

extern fn memfd_create(name: [*:0]const u8, flags: c_uint) c_int;
extern fn ftruncate(fd: c_int, length: c_long) c_int;
extern fn mmap(addr: ?*anyopaque, length: usize, prot: c_int, flags: c_int, fd: c_int, offset: c_long) ?*anyopaque;
extern fn munmap(addr: *anyopaque, length: usize) c_int;
extern fn close(fd: c_int) c_int;
const PROT_READ_WRITE = 3;
const MAP_SHARED = 1;

const log = std.log.scoped(.snip);

const Mode = enum { full, region, scroll };

const App = struct {
    allocator: std.mem.Allocator,
    appearance: ?*common.style.Appearance = null,
    /// Capture right away: `--full` or `--region` on the command line.
    immediate: ?Mode,
    /// `--scroll-region x,y,w,h`: a scrolling capture of that region, no picker.
    preset_region: ?pure.Rect = null,

    fn activate(app: *gtk.Application, self: *App) callconv(.c) void {
        common.style.load(self.allocator) catch |err|
            std.log.warn("stylesheet not loaded: {s}", .{@errorName(err)});
        self.appearance = common.style.Appearance.create(self.allocator) catch null;
        const snip = Snip.create(self.allocator, app) catch |err| {
            std.log.err("cannot start: {s}", .{@errorName(err)});
            return;
        };
        snip.preset_region = self.preset_region;
        if (self.immediate) |mode| snip.begin(mode) else snip.window.as(gtk.Window).present();
    }
};

const Snip = struct {
    allocator: std.mem.Allocator,
    window: *gtk.ApplicationWindow,
    preview: *gtk.Picture,
    status: *gtk.Label,
    delay: *gtk.SpinButton,

    registry: ?*wl.Registry = null,
    manager: ?*zwlr.ScreencopyManagerV1 = null,
    shm: ?*wl.Shm = null,
    output: ?*wl.Output = null,
    vptr_manager: ?*zwlr.VirtualPointerManagerV1 = null,
    seat: ?*wl.Seat = null,
    /// While a scrolling capture runs: frames go to the job, not to the picker.
    scroll: ?*ScrollJob = null,

    mode: Mode = .full,
    preset_region: ?pure.Rect = null,
    picker: ?*Picker = null,

    fn create(allocator: std.mem.Allocator, app: *gtk.Application) !*Snip {
        const display = gdk.Display.getDefault() orelse return error.NoDisplay;
        const on_x11 = x11grab.isActive();
        if (!on_x11 and gobject.typeCheckInstanceIsA(@ptrCast(@alignCast(display)), gdkwayland.WaylandDisplay.getGObjectType()) == 0) return error.NotWayland;

        const self = try allocator.create(Snip);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .window = gtk.ApplicationWindow.new(app),
            .preview = gtk.Picture.new(),
            .status = gtk.Label.new(common.tr("Choose what to capture")),
            .delay = gtk.SpinButton.newWithRange(0, 30, 1),
        };
        // On X11 the screen is read with XGetImage; only Wayland needs the protocols.
        if (!on_x11) {
            const wl_display: *wl.Display = @ptrCast(gdkwayland.WaylandDisplay.getWlDisplay(@ptrCast(display)) orelse return error.NoDisplay);
            self.registry = try wl_display.getRegistry();
            self.registry.?.setListener(*Snip, registryEvent, self);
            _ = wl_display.roundtrip();
            if (self.manager == null) log.warn("the compositor does not offer wlr-screencopy", .{});
        }

        const window = self.window;
        window.as(gtk.Window).setTitle(common.tr("Screenshot"));
        window.as(gtk.Window).setDefaultSize(520, 420);
        window.as(gtk.Widget).addCssClass("dkde");

        _ = common.header.create(window.as(gtk.Window), "applets-screenshooter", true);

        const mb = common.menubar;
        const menus = [_]mb.Menu{
            .{ .label = "_File", .entries = &.{
                mb.item("_Full Screen", "full", "Print"),
                mb.item("_Region…", "region", "<Shift>Print"),
                mb.item("_Scrolling Region…", "scroll", null),
                .separator,
                mb.item("_Close", "close", "<Control>w"),
            } },
        };
        const menu_bar = mb.build(app, window, &menus, Snip, onMenuAction, self);

        // Capture buttons and the delay sit in a toolbar row under the menu.
        const tools = gtk.Box.new(.horizontal, 8);
        tools.as(gtk.Widget).setMarginTop(8);
        tools.as(gtk.Widget).setMarginBottom(4);
        tools.as(gtk.Widget).setMarginStart(8);
        tools.as(gtk.Widget).setMarginEnd(8);
        const full = gtk.Button.newWithLabel(common.tr("Full screen"));
        _ = gtk.Button.signals.clicked.connect(full, *Snip, &onFull, self, .{});
        const region = gtk.Button.newWithLabel(common.tr("Region"));
        _ = gtk.Button.signals.clicked.connect(region, *Snip, &onRegion, self, .{});
        tools.append(full.as(gtk.Widget));
        tools.append(region.as(gtk.Widget));
        const scrolling = gtk.Button.newWithLabel(common.tr("Scrolling"));
        scrolling.as(gtk.Widget).setTooltipText(common.tr("Pick a region; the page is scrolled and stitched into one tall picture"));
        _ = gtk.Button.signals.clicked.connect(scrolling, *Snip, &onScrolling, self, .{});
        tools.append(scrolling.as(gtk.Widget));
        const spacer = gtk.Box.new(.horizontal, 0);
        spacer.as(gtk.Widget).setHexpand(1);
        tools.append(spacer.as(gtk.Widget));
        tools.append(gtk.Label.new(common.tr("Delay (s)")).as(gtk.Widget));
        tools.append(self.delay.as(gtk.Widget));

        self.preview.setContentFit(.contain);
        self.preview.as(gtk.Widget).setVexpand(1);
        self.status.setWrap(1);
        self.status.as(gtk.Widget).setMarginTop(8);
        self.status.as(gtk.Widget).setMarginBottom(8);
        self.status.as(gtk.Widget).setMarginStart(8);
        self.status.as(gtk.Widget).setMarginEnd(8);
        const root = gtk.Box.new(.vertical, 0);
        root.append(menu_bar.as(gtk.Widget));
        root.append(tools.as(gtk.Widget));
        root.append(self.preview.as(gtk.Widget));
        root.append(self.status.as(gtk.Widget));
        window.as(gtk.Window).setChild(root.as(gtk.Widget));

        const keys = gtk.EventControllerKey.new();
        _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *Snip, &onKey, self, .{});
        window.as(gtk.Widget).addController(keys.as(gtk.EventController));
        _ = gtk.Widget.signals.destroy.connect(window, *Snip, &onDestroy, self, .{});
        return self;
    }

    fn onDestroy(_: *gtk.ApplicationWindow, self: *Snip) callconv(.c) void {
        if (self.registry) |r| r.destroy();
        self.allocator.destroy(self);
    }

    fn registryEvent(registry: *wl.Registry, event: wl.Registry.Event, self: *Snip) void {
        switch (event) {
            .global => |g| {
                const name = std.mem.span(g.interface);
                if (std.mem.eql(u8, name, std.mem.span(zwlr.ScreencopyManagerV1.interface.name))) {
                    self.manager = registry.bind(g.name, zwlr.ScreencopyManagerV1, @min(g.version, 3)) catch null;
                } else if (std.mem.eql(u8, name, std.mem.span(wl.Shm.interface.name))) {
                    self.shm = registry.bind(g.name, wl.Shm, 1) catch null;
                } else if (std.mem.eql(u8, name, std.mem.span(zwlr.VirtualPointerManagerV1.interface.name))) {
                    self.vptr_manager = registry.bind(g.name, zwlr.VirtualPointerManagerV1, @min(g.version, 2)) catch null;
                } else if (std.mem.eql(u8, name, std.mem.span(wl.Seat.interface.name))) {
                    if (self.seat == null) self.seat = registry.bind(g.name, wl.Seat, 1) catch null;
                } else if (std.mem.eql(u8, name, std.mem.span(wl.Output.interface.name))) {
                    // The first output is captured.
                    if (self.output == null) self.output = registry.bind(g.name, wl.Output, 1) catch null;
                }
            },
            .global_remove => {},
        }
    }

    fn onMenuAction(self: *Snip, action: []const u8) void {
        if (std.mem.eql(u8, action, "full")) return self.begin(.full);
        if (std.mem.eql(u8, action, "region")) return self.begin(.region);
        if (std.mem.eql(u8, action, "scroll")) return self.begin(.scroll);
        if (std.mem.eql(u8, action, "close")) self.window.as(gtk.Window).close();
    }

    fn onFull(_: *gtk.Button, self: *Snip) callconv(.c) void {
        self.begin(.full);
    }

    fn onScrolling(_: *gtk.Button, self: *Snip) callconv(.c) void {
        self.begin(.scroll);
    }

    fn onRegion(_: *gtk.Button, self: *Snip) callconv(.c) void {
        self.begin(.region);
    }

    fn onKey(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, _: gdk.ModifierType, self: *Snip) callconv(.c) c_int {
        if (keyval == gdk.KEY_Escape) {
            self.window.as(gtk.Window).close();
            return 1;
        }
        return 0;
    }

    // ---- capture ---------------------------------------------------------------

    /// Hides the window (so it is not in the picture), waits the delay, then captures.
    fn begin(self: *Snip, mode: Mode) void {
        if (!x11grab.isActive() and (self.manager == null or self.shm == null or self.output == null)) {
            self.fail(common.tr("This compositor does not support screen capture (wlr-screencopy)."));
            return;
        }
        self.mode = mode;
        const seconds: u32 = @intCast(@max(0, self.delay.getValueAsInt()));
        self.window.as(gtk.Widget).setVisible(0);
        // A little extra so the compositor has really removed our window.
        _ = glib.timeoutAdd(seconds * 1000 + 300, onCaptureTimer, self);
    }

    fn onCaptureTimer(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Snip = @ptrCast(@alignCast(data.?));
        self.captureNow();
        return 0;
    }

    /// X11: read the root window directly.
    fn captureX11(self: *Snip) void {
        if (!build_options.x11) return;
        const shot = x11grab.grabScreen(self.allocator) catch |err| {
            var buf: [96]u8 = undefined;
            return self.fail(std.fmt.bufPrintSentinel(&buf, "Could not capture the screen ({s}).", .{@errorName(err)}, 0) catch "Could not capture the screen.");
        };
        defer self.allocator.free(shot.pixels);
        const rgba = self.allocator.alloc(u8, shot.pixels.len) catch return self.fail("Out of memory");
        defer self.allocator.free(rgba);
        pure.toRgba(rgba, shot.pixels, shot.width, shot.height, shot.width * 4, .bgra, false);
        const pixbuf = gdkpixbuf.Pixbuf.new(.rgb, 1, 8, @intCast(shot.width), @intCast(shot.height)) orelse return self.fail("Out of memory");
        const dst = pixbuf.getPixels();
        const rowstride: usize = @intCast(pixbuf.getRowstride());
        for (0..shot.height) |y| @memcpy(dst[y * rowstride ..][0 .. shot.width * 4], rgba[y * shot.width * 4 ..][0 .. shot.width * 4]);
        self.captured(pixbuf);
    }

    fn captureNow(self: *Snip) void {
        if (x11grab.isActive()) return self.captureX11();
        const frame = self.manager.?.captureOutput(0, self.output.?) catch {
            return self.fail(common.tr("Could not start the capture."));
        };
        const cap = self.allocator.create(Capture) catch return self.fail("Out of memory");
        cap.* = .{ .snip = self, .frame = frame };
        frame.setListener(*Capture, Capture.onEvent, cap);
    }

    fn fail(self: *Snip, message: [:0]const u8) void {
        self.window.as(gtk.Widget).setVisible(1);
        self.status.setText(message);
        self.window.as(gtk.Window).present();
    }

    /// A finished capture: crop it if needed, then save, copy and show it.
    fn captured(self: *Snip, pixbuf: *gdkpixbuf.Pixbuf) void {
        if (self.scroll) |job| return job.onFrame(pixbuf);
        if (self.mode == .scroll) {
            if (self.preset_region) |rect| {
                const out_w = pixbuf.getWidth();
                const out_h = pixbuf.getHeight();
                pixbuf.as(gobject.Object).unref();
                return ScrollJob.start(self, rect, out_w, out_h);
            }
        }
        if (self.mode == .region or self.mode == .scroll) {
            self.picker = Picker.show(self, pixbuf) catch {
                pixbuf.as(gobject.Object).unref();
                return self.fail(common.tr("Could not show the region selector."));
            };
            return;
        }
        self.finish(pixbuf);
    }

    /// Takes ownership of `pixbuf`.
    fn finish(self: *Snip, pixbuf: *gdkpixbuf.Pixbuf) void {
        defer pixbuf.as(gobject.Object).unref();
        const texture = gdk.Texture.newForPixbuf(pixbuf);
        defer texture.as(gobject.Object).unref();

        self.window.as(gtk.Widget).setVisible(1);
        self.preview.setPaintable(texture.as(gdk.Paintable));
        self.window.as(gtk.Window).present();

        // Always copy, so a screenshot can be pasted even if saving fails.
        gdk.Display.getDefault().?.getClipboard().setTexture(texture);

        const dir = self.screenshotDir() orelse return self.fail(common.tr("Cannot create the Screenshots folder."));
        defer self.allocator.free(dir);
        const now = glib.DateTime.newNowLocal() orelse return;
        defer now.unref();
        var name_buf: [96]u8 = undefined;
        const name = pure.fileName(&name_buf, now.getYear(), now.getMonth(), now.getDayOfMonth(), now.getHour(), now.getMinute(), now.getSecond());
        const path = std.fmt.allocPrintSentinel(self.allocator, "{s}/{s}", .{ dir, name }, 0) catch return;
        defer self.allocator.free(path);

        if (texture.saveToPng(path) == 0) return self.fail(common.tr("Could not save the screenshot."));
        var buf: [768]u8 = undefined;
        self.status.setText(std.fmt.bufPrintSentinel(&buf, "Saved to {s} and copied to the clipboard.", .{path}, 0) catch "Saved.");
    }

    fn screenshotDir(self: *Snip) ?[:0]u8 {
        const pictures = glib.getUserSpecialDir(.directory_pictures) orelse glib.getHomeDir();
        const dir = std.fmt.allocPrintSentinel(self.allocator, "{s}/Screenshots", .{std.mem.span(pictures)}, 0) catch return null;
        if (glib.mkdirWithParents(dir, 0o755) != 0) {
            self.allocator.free(dir);
            return null;
        }
        return dir;
    }
};

/// One screencopy request in flight.
const Capture = struct {
    snip: *Snip,
    frame: *zwlr.ScreencopyFrameV1,
    format: wl.Shm.Format = .argb8888,
    width: u32 = 0,
    height: u32 = 0,
    stride: u32 = 0,
    y_invert: bool = false,
    map: ?[*]u8 = null,
    size: usize = 0,
    buffer: ?*wl.Buffer = null,

    fn onEvent(frame: *zwlr.ScreencopyFrameV1, event: zwlr.ScreencopyFrameV1.Event, self: *Capture) void {
        _ = frame;
        switch (event) {
            .buffer => |b| {
                self.format = b.format;
                self.width = b.width;
                self.height = b.height;
                self.stride = b.stride;
            },
            .flags => |f| self.y_invert = f.flags.y_invert,
            // Version 3 announces every buffer type, then says it is done.
            .buffer_done => self.copy(),
            .ready => self.ready(),
            .failed => {
                self.snip.fail(common.tr("The compositor refused the capture."));
                self.release();
            },
            .damage, .linux_dmabuf => {},
        }
    }

    fn copy(self: *Capture) void {
        const snip = self.snip;
        self.size = @as(usize, self.stride) * self.height;
        const fd = memfd_create("dkde-snip", 0);
        if (fd < 0 or ftruncate(fd, @intCast(self.size)) != 0) {
            if (fd >= 0) _ = close(fd);
            snip.fail(common.tr("Could not allocate shared memory."));
            return self.release();
        }
        defer _ = close(fd);
        const mapped = mmap(null, self.size, PROT_READ_WRITE, MAP_SHARED, fd, 0) orelse {
            snip.fail(common.tr("Could not map shared memory."));
            return self.release();
        };
        if (@intFromPtr(mapped) == std.math.maxInt(usize)) {
            snip.fail(common.tr("Could not map shared memory."));
            return self.release();
        }
        self.map = @ptrCast(mapped);

        const pool = snip.shm.?.createPool(fd, @intCast(self.size)) catch {
            snip.fail(common.tr("Could not create the capture buffer."));
            return self.release();
        };
        defer pool.destroy();
        self.buffer = pool.createBuffer(0, @intCast(self.width), @intCast(self.height), @intCast(self.stride), self.format) catch {
            snip.fail(common.tr("Could not create the capture buffer."));
            return self.release();
        };
        self.frame.copy(self.buffer.?);
    }

    fn ready(self: *Capture) void {
        const snip = self.snip;
        defer self.release();

        const layout: pure.Layout = switch (self.format) {
            .argb8888, .xrgb8888 => .bgra,
            .abgr8888, .xbgr8888 => .rgba,
            else => {
                snip.fail(common.tr("The compositor used a pixel format dkde-snip cannot read."));
                return;
            },
        };
        const w: usize = self.width;
        const h: usize = self.height;
        const rgba = snip.allocator.alloc(u8, w * h * 4) catch return snip.fail("Out of memory");
        defer snip.allocator.free(rgba);
        pure.toRgba(rgba, self.map.?[0..self.size], w, h, self.stride, layout, self.y_invert);

        const pixbuf = gdkpixbuf.Pixbuf.new(.rgb, 1, 8, @intCast(w), @intCast(h)) orelse return snip.fail("Out of memory");
        const dst = pixbuf.getPixels();
        const rowstride: usize = @intCast(pixbuf.getRowstride());
        for (0..h) |y| @memcpy(dst[y * rowstride ..][0 .. w * 4], rgba[y * w * 4 ..][0 .. w * 4]);
        snip.captured(pixbuf);
    }

    fn release(self: *Capture) void {
        if (self.buffer) |b| b.destroy();
        if (self.map) |m| _ = munmap(@ptrCast(m), self.size);
        self.frame.destroy();
        self.snip.allocator.destroy(self);
    }
};

/// A scrolling capture: scroll the page under the region with a virtual
/// pointer, capture after each step, and stitch the new rows onto the end.
const ScrollJob = struct {
    snip: *Snip,
    rect: pure.Rect,
    out_w: i32,
    out_h: i32,
    pointer: *zwlr.VirtualPointerV1,
    /// The stitched picture so far, tightly packed RGBA rows.
    stitched: std.ArrayList(u8) = .empty,
    /// The previous frame's crop, for finding how far the page moved.
    prev: []u8 = &.{},
    frames: usize = 0,
    /// Consecutive frames in which nothing moved: a few are tolerated, since
    /// a browser can swallow the first wheel event.
    stalls: usize = 0,
    nudge: bool = false,

    const max_frames = 150;
    /// GTK's texture limit; a taller picture could not be saved.
    const max_rows: usize = 16000;
    const settle_ms = 450;

    fn start(snip: *Snip, rect: pure.Rect, out_w: i32, out_h: i32) void {
        const manager = snip.vptr_manager orelse return snip.fail(common.tr("This compositor does not allow scrolling windows for you (wlr-virtual-pointer is missing)."));
        const seat = snip.seat orelse return snip.fail(common.tr("No input seat found."));
        const job = snip.allocator.create(ScrollJob) catch return snip.fail("Out of memory");
        job.* = .{
            .snip = snip,
            .rect = rect,
            .out_w = out_w,
            .out_h = out_h,
            .pointer = manager.createVirtualPointer(seat) catch {
                snip.allocator.destroy(job);
                return snip.fail(common.tr("Could not create the virtual pointer."));
            },
        };
        snip.scroll = job;
        // Put the pointer over the region so the wheel reaches that window.
        job.pointer.motionAbsolute(now(), @intCast(rect.x + @divTrunc(rect.w, 2)), @intCast(rect.y + @divTrunc(rect.h, 2)), @intCast(out_w), @intCast(out_h));
        job.pointer.frame();
        _ = glib.timeoutAdd(400, onCaptureTimer, job);
    }

    fn now() u32 {
        return @truncate(@as(u64, @intCast(glib.getMonotonicTime())) / 1000);
    }

    fn onCaptureTimer(data: ?*anyopaque) callconv(.c) c_int {
        const job: *ScrollJob = @ptrCast(@alignCast(data.?));
        job.snip.captureNow();
        return 0;
    }

    /// One wheel notch down. The pointer is nudged by a pixel first so the
    /// window under it has certainly seen it move, and both the continuous
    /// and the notch form of the event are sent because clients differ in
    /// which they listen to.
    fn scrollOnce(self: *ScrollJob) void {
        const cx: u32 = @intCast(self.rect.x + @divTrunc(self.rect.w, 2));
        const cy: u32 = @intCast(self.rect.y + @divTrunc(self.rect.h, 2));
        self.nudge = !self.nudge;
        self.pointer.motionAbsolute(now(), cx + @intFromBool(self.nudge), cy, @intCast(self.out_w), @intCast(self.out_h));
        self.pointer.frame();
        self.pointer.axisSource(.wheel);
        self.pointer.axis(now(), .vertical_scroll, .fromInt(15));
        self.pointer.axisDiscrete(now(), .vertical_scroll, .fromInt(15), 1);
        self.pointer.frame();
    }

    /// The region of a full-screen frame as tightly packed RGBA.
    fn crop(self: *ScrollJob, pixbuf: *gdkpixbuf.Pixbuf) ?[]u8 {
        const w: usize = @intCast(self.rect.w);
        const h: usize = @intCast(self.rect.h);
        const out = self.snip.allocator.alloc(u8, w * h * 4) catch return null;
        const pixels = pixbuf.getPixels();
        const stride: usize = @intCast(pixbuf.getRowstride());
        const channels: usize = @intCast(pixbuf.getNChannels());
        for (0..h) |row| {
            const src = (@as(usize, @intCast(self.rect.y)) + row) * stride + @as(usize, @intCast(self.rect.x)) * channels;
            for (0..w) |col| {
                const px = pixels[src + col * channels ..][0..channels];
                const dst = out[(row * w + col) * 4 ..][0..4];
                dst[0] = px[0];
                dst[1] = px[1];
                dst[2] = px[2];
                dst[3] = 255;
            }
        }
        return out;
    }

    fn onFrame(self: *ScrollJob, pixbuf: *gdkpixbuf.Pixbuf) void {
        const a = self.snip.allocator;
        defer pixbuf.as(gobject.Object).unref();
        const cur = self.crop(pixbuf) orelse return self.finish();
        const w: usize = @intCast(self.rect.w);
        const h: usize = @intCast(self.rect.h);
        self.frames += 1;

        if (self.prev.len == 0) {
            self.stitched.appendSlice(a, cur) catch {
                a.free(cur);
                return self.finish();
            };
            self.prev = cur;
        } else {
            const verdict = pure.findScroll(a, self.prev, cur, w, h) catch {
                a.free(cur);
                return self.finish();
            };
            switch (verdict) {
                // Nothing moved. Maybe the event was swallowed; try a few
                // times before deciding this is the end of the page.
                .same => {
                    a.free(cur);
                    self.stalls += 1;
                    if (self.stalls > 3) return self.finish();
                    self.scrollOnce();
                    _ = glib.timeoutAdd(settle_ms + 300, onCaptureTimer, self);
                    return;
                },
                .unknown => {
                    if (glib.getenv("DKDE_SNIP_DEBUG_DIR")) |dir| {
                        saveDebug(a, std.mem.span(dir), "prev.png", self.prev, w, h);
                        saveDebug(a, std.mem.span(dir), "cur.png", cur, w, h);
                    }
                    a.free(cur);
                    // Probably caught mid-animation: wait and look again
                    // (without scrolling) before giving up.
                    self.stalls += 1;
                    if (self.stalls > 4) return self.finish();
                    _ = glib.timeoutAdd(settle_ms + 400, onCaptureTimer, self);
                    return;
                },
                .moved => |d| {
                    self.stalls = 0;
                    // The last `d` rows of the new frame are the new content.
                    self.stitched.appendSlice(a, cur[(h - d) * w * 4 ..]) catch {
                        a.free(cur);
                        return self.finish();
                    };
                    a.free(self.prev);
                    self.prev = cur;
                },
            }
        }

        if (self.frames >= max_frames or self.stitched.items.len / (w * 4) >= max_rows) return self.finish();
        self.scrollOnce();
        _ = glib.timeoutAdd(settle_ms, onCaptureTimer, self);
    }

    /// Debug aid: writes a crop to `<dir>/<name>` (set DKDE_SNIP_DEBUG_DIR).
    fn saveDebug(a: std.mem.Allocator, dir: []const u8, name: []const u8, rgba: []const u8, w: usize, h: usize) void {
        const pb = gdkpixbuf.Pixbuf.new(.rgb, 1, 8, @intCast(w), @intCast(h)) orelse return;
        defer pb.as(gobject.Object).unref();
        const dst = pb.getPixels();
        const stride: usize = @intCast(pb.getRowstride());
        for (0..h) |r| @memcpy(dst[r * stride ..][0 .. w * 4], rgba[r * w * 4 ..][0 .. w * 4]);
        const path = std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dir, name }, 0) catch return;
        defer a.free(path);
        const texture = gdk.Texture.newForPixbuf(pb);
        defer texture.as(gobject.Object).unref();
        _ = texture.saveToPng(path);
    }

    /// Builds the picture from the stitched rows and hands it back.
    fn finish(self: *ScrollJob) void {
        const snip = self.snip;
        const a = snip.allocator;
        const w: usize = @intCast(self.rect.w);
        const rows = @min(self.stitched.items.len / (w * 4), max_rows);
        const pixbuf = gdkpixbuf.Pixbuf.new(.rgb, 1, 8, @intCast(w), @intCast(@max(rows, 1)));
        if (pixbuf) |pb| {
            const dst = pb.getPixels();
            const stride: usize = @intCast(pb.getRowstride());
            for (0..rows) |r| @memcpy(dst[r * stride ..][0 .. w * 4], self.stitched.items[r * w * 4 ..][0 .. w * 4]);
        }
        self.pointer.destroy();
        self.stitched.deinit(a);
        if (self.prev.len > 0) a.free(self.prev);
        snip.scroll = null;
        a.destroy(self);
        if (pixbuf) |pb| snip.finish(pb) else snip.fail(common.tr("Out of memory"));
    }
};

/// Full-screen overlay showing the frozen capture, with a draggable rectangle.
const Picker = struct {
    snip: *Snip,
    window: *gtk.Window,
    area: *gtk.DrawingArea,
    pixbuf: *gdkpixbuf.Pixbuf,
    start_x: f64 = 0,
    start_y: f64 = 0,
    end_x: f64 = 0,
    end_y: f64 = 0,
    dragging: bool = false,

    fn show(snip: *Snip, pixbuf: *gdkpixbuf.Pixbuf) !*Picker {
        const self = try snip.allocator.create(Picker);
        self.* = .{ .snip = snip, .window = gtk.Window.new(), .area = gtk.DrawingArea.new(), .pixbuf = pixbuf };

        self.window.setTitle(common.tr("Select a region"));
        self.window.setDecorated(0);
        self.window.setChild(self.area.as(gtk.Widget));
        self.area.setDrawFunc(onDraw, self, null);
        self.area.as(gtk.Widget).setCursorFromName("crosshair");

        const drag = gtk.GestureDrag.new();
        _ = gtk.GestureDrag.signals.drag_begin.connect(drag, *Picker, &onBegin, self, .{});
        _ = gtk.GestureDrag.signals.drag_update.connect(drag, *Picker, &onUpdate, self, .{});
        _ = gtk.GestureDrag.signals.drag_end.connect(drag, *Picker, &onEnd, self, .{});
        self.area.as(gtk.Widget).addController(drag.as(gtk.EventController));

        const keys = gtk.EventControllerKey.new();
        _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *Picker, &onKey, self, .{});
        self.window.as(gtk.Widget).addController(keys.as(gtk.EventController));

        self.window.fullscreen();
        self.window.present();
        return self;
    }

    fn close(self: *Picker, cropped: ?*gdkpixbuf.Pixbuf) void {
        const snip = self.snip;
        self.window.destroy();
        snip.picker = null;
        snip.allocator.destroy(self);
        if (cropped) |c| snip.finish(c) else snip.fail(common.tr("Capture cancelled."));
    }

    fn onDraw(_: *gtk.DrawingArea, cr: *cairo.Context, width: c_int, height: c_int, data: ?*anyopaque) callconv(.c) void {
        const self: *Picker = @ptrCast(@alignCast(data.?));
        const image_w: f64 = @floatFromInt(self.pixbuf.getWidth());
        const image_h: f64 = @floatFromInt(self.pixbuf.getHeight());
        const sx = @as(f64, @floatFromInt(width)) / image_w;
        const sy = @as(f64, @floatFromInt(height)) / image_h;

        cr.save();
        cr.scale(sx, sy);
        gdk.cairoSetSourcePixbuf(cr, self.pixbuf, 0, 0);
        cr.paint();
        cr.restore();

        // Dim everything, then show the selection at full brightness.
        cr.setSourceRgba(0, 0, 0, 0.45);
        cr.paint();
        if (!self.dragging and self.start_x == self.end_x) return;
        const r = pure.normalize(self.start_x, self.start_y, self.end_x, self.end_y);
        cr.save();
        cr.rectangle(@floatFromInt(r.x), @floatFromInt(r.y), @floatFromInt(r.w), @floatFromInt(r.h));
        cr.clip();
        cr.scale(sx, sy);
        gdk.cairoSetSourcePixbuf(cr, self.pixbuf, 0, 0);
        cr.paint();
        cr.restore();
        cr.setSourceRgb(1, 1, 1);
        cr.setLineWidth(1);
        cr.rectangle(@as(f64, @floatFromInt(r.x)) + 0.5, @as(f64, @floatFromInt(r.y)) + 0.5, @floatFromInt(r.w), @floatFromInt(r.h));
        cr.stroke();
    }

    fn onBegin(_: *gtk.GestureDrag, x: f64, y: f64, self: *Picker) callconv(.c) void {
        self.start_x = x;
        self.start_y = y;
        self.end_x = x;
        self.end_y = y;
        self.dragging = true;
        self.area.as(gtk.Widget).queueDraw();
    }

    fn onUpdate(_: *gtk.GestureDrag, dx: f64, dy: f64, self: *Picker) callconv(.c) void {
        self.end_x = self.start_x + dx;
        self.end_y = self.start_y + dy;
        self.area.as(gtk.Widget).queueDraw();
    }

    fn onEnd(_: *gtk.GestureDrag, dx: f64, dy: f64, self: *Picker) callconv(.c) void {
        self.end_x = self.start_x + dx;
        self.end_y = self.start_y + dy;
        self.dragging = false;
        const widget = self.area.as(gtk.Widget);
        const rect = pure.normalize(self.start_x, self.start_y, self.end_x, self.end_y);
        const image = pure.toImage(rect, @floatFromInt(widget.getWidth()), @floatFromInt(widget.getHeight()), self.pixbuf.getWidth(), self.pixbuf.getHeight()) orelse {
            // A click without a drag: stay and let the user try again.
            widget.queueDraw();
            return;
        };
        if (self.snip.mode == .scroll) {
            const snip = self.snip;
            const out_w = self.pixbuf.getWidth();
            const out_h = self.pixbuf.getHeight();
            self.pixbuf.as(gobject.Object).unref();
            self.window.destroy();
            snip.picker = null;
            snip.allocator.destroy(self);
            ScrollJob.start(snip, image, out_w, out_h);
            return;
        }
        const cropped = self.pixbuf.newSubpixbuf(image.x, image.y, image.w, image.h);
        // The subpixbuf shares memory with the full picture; copy it out first.
        const copy = cropped.copy();
        cropped.as(gobject.Object).unref();
        self.pixbuf.as(gobject.Object).unref();
        self.close(copy);
    }

    fn onKey(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, _: gdk.ModifierType, self: *Picker) callconv(.c) c_int {
        if (keyval == gdk.KEY_Escape) {
            self.pixbuf.as(gobject.Object).unref();
            self.close(null);
            return 1;
        }
        return 0;
    }
};

pub const std_options: std.Options = .{ .logFn = common.log.logFn, .log_level = .debug };

pub fn main(init: std.process.Init.Minimal) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    // `--full` and `--region` capture straight away (for the Print key).
    var immediate: ?Mode = null;
    var preset: ?pure.Rect = null;
    const args_it = init.args.vector[1..];
    var arg_index: usize = 0;
    while (arg_index < args_it.len) : (arg_index += 1) {
        const text = std.mem.span(args_it[arg_index]);
        if (std.mem.eql(u8, text, "--scroll-region") and arg_index + 1 < args_it.len) {
            var parts = std.mem.splitScalar(u8, std.mem.span(args_it[arg_index + 1]), ',');
            var v: [4]i32 = undefined;
            var ok = true;
            for (&v) |*slot| slot.* = std.fmt.parseInt(i32, parts.next() orelse "x", 10) catch blk: {
                ok = false;
                break :blk 0;
            };
            if (ok and v[2] > 0 and v[3] > 0) {
                preset = .{ .x = v[0], .y = v[1], .w = v[2], .h = v[3] };
                immediate = .scroll;
            }
            arg_index += 1;
            continue;
        }
        if (std.mem.eql(u8, text, "--full")) immediate = .full;
        if (std.mem.eql(u8, text, "--region")) immediate = .region;
    }

    var app: App = .{ .allocator = allocator, .immediate = immediate, .preset_region = preset };
    defer if (app.appearance) |a| a.destroy();

    const gtk_app = gtk.Application.new("org.dkde.snip", .{ .non_unique = true });
    defer gtk_app.as(gobject.Object).unref();
    _ = gio.Application.signals.activate.connect(gtk_app, *App, &App.activate, &app, .{});

    var argv = [_]?[*:0]const u8{ init.args.vector[0], null };
    const status = gio.Application.run(gtk_app.as(gio.Application), 1, @ptrCast(&argv));
    if (status != 0) std.process.exit(@intCast(status));
}

test {
    _ = @import("pure.zig");
}
