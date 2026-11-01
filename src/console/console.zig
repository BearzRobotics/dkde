//! One console on one VT (SPEC.md 5.11): libghostty-vt for the terminal, a pty
//! with `login` in it, the kernel's VT layer, DRM for the screen, evdev for the
//! keyboard and mouse. A single `poll` loop drives all of it, so an idle console
//! sleeps until something happens.

const std = @import("std");
const vt = @import("ghostty-vt");
const termcore = @import("termcore");
const Pty = termcore.pty.Pty;
const config = @import("consolefont").config;
const configtool = @import("configtool.zig");
const drm = @import("drm.zig");
const evdev = @import("evdev.zig");
const fallback = @import("fallback.zig");
const issue = @import("issue.zig");
const kbd = @import("kbd.zig");
const psf = @import("consolefont").psf;
const ttf = @import("consolefont").ttf;
const render = @import("render.zig");
const sys = @import("sys.zig");
const vtmod = @import("vt.zig");

const log = std.log.scoped(.console);

extern fn poll(fds: [*]evdev.PollFd, n: c_ulong, timeout: c_int) c_int;
extern fn clock_gettime(clock: c_int, ts: *Timespec) c_int;
extern fn nanosleep(req: *const Timespec, rem: ?*Timespec) c_int;
extern fn inotify_init1(flags: c_int) c_int;
extern fn inotify_add_watch(fd: c_int, path: [*:0]const u8, mask: u32) c_int;
const Timespec = extern struct { sec: c_long, nsec: c_long };

fn nowSeconds() i64 {
    var ts: Timespec = undefined;
    _ = clock_gettime(1, &ts); // CLOCK_MONOTONIC
    return ts.sec;
}

const login_paths = [_][:0]const u8{ "/bin/login", "/usr/bin/login", "/sbin/login", "/usr/sbin/login" };

pub const Options = struct { vt: u32 };

pub fn run(allocator: std.mem.Allocator, opts: Options) u8 {
    var c: Console = .{ .allocator = allocator, .vt_num = opts.vt };
    return c.main();
}

const Damage = struct {
    full: bool = true,
    rows: std.ArrayList(bool) = .empty,
};

const FontSet = struct {
    /// Owned file data for fonts read from disk (the built-in ones borrow).
    data: std.ArrayList([]u8) = .empty,
    fonts: std.ArrayList(*psf.Font) = .empty,
    ptrs: std.ArrayList(*const psf.Font) = .empty,
    faces: std.ArrayList(*ttf.Face) = .empty,

    fn deinit(self: *FontSet, a: std.mem.Allocator) void {
        for (self.fonts.items) |f| {
            f.deinit(a);
            a.destroy(f);
        }
        for (self.faces.items) |f| {
            f.deinit();
            a.destroy(f);
        }
        self.faces.deinit(a);
        for (self.data.items) |d| a.free(d);
        self.data.deinit(a);
        self.fonts.deinit(a);
        self.ptrs.deinit(a);
    }

    fn add(self: *FontSet, a: std.mem.Allocator, bytes: []const u8, owned: ?[]u8) !void {
        const f = try a.create(psf.Font);
        errdefer a.destroy(f);
        f.* = try psf.Font.parse(a, bytes);
        errdefer f.deinit(a);
        try self.fonts.append(a, f);
        errdefer _ = self.fonts.pop();
        try self.ptrs.append(a, f);
        if (owned) |o| try self.data.append(a, o);
    }

    /// A TrueType file: a face `cell_h` pixels tall. The file data is kept
    /// by the font set.
    fn addTrueType(self: *FontSet, a: std.mem.Allocator, bytes: []u8, cell_h: u32) bool {
        const f = a.create(ttf.Face) catch return false;
        f.* = ttf.Face.init(a, bytes, cell_h) catch {
            a.destroy(f);
            return false;
        };
        self.faces.append(a, f) catch {
            f.deinit();
            a.destroy(f);
            return false;
        };
        self.data.append(a, bytes) catch {
            _ = self.faces.pop();
            f.deinit();
            a.destroy(f);
            return false;
        };
        return true;
    }

    /// A PSF or TrueType font file. TrueType gets `cell_h` pixels of height.
    fn addFile(self: *FontSet, a: std.mem.Allocator, path: []const u8, cell_h: u32) bool {
        const bytes = sys.readFile(a, path, 32 << 20) catch return false;
        if (ttf.looksLikeTrueType(bytes)) {
            if (self.addTrueType(a, bytes, cell_h)) return true;
            a.free(bytes);
            return false;
        }
        self.add(a, bytes, bytes) catch {
            a.free(bytes);
            return false;
        };
        return true;
    }

    fn addBuiltin(self: *FontSet, a: std.mem.Allocator, height: u32) !void {
        const i: usize = if (height >= 32) 2 else if (height >= 24) 1 else 0;
        try self.add(a, psf.builtin_data[i].data, null);
    }
};

pub const Console = struct {
    allocator: std.mem.Allocator,
    vt_num: u32,

    // settings
    etc: ?*anyopaque = null,
    etc_doc: @import("termcore").ini.Document = undefined,
    defs_doc: @import("termcore").ini.Document = undefined,
    docs_loaded: bool = false,
    settings: config.Settings = undefined,
    conf_watch: c_int = -1,

    // kernel interfaces
    vtdev: vtmod.Vt = undefined,
    sig_fd: c_int = -1,
    dev: ?drm.Device = null,
    out: drm.Output = undefined,
    bufs: [2]?drm.Buffer = .{ null, null },
    /// The buffer to draw into next; the other one is on screen.
    back: u1 = 1,
    flip_pending: bool = false,
    damage: [2]Damage = .{ .{}, .{} },
    have_display: bool = false,
    input: evdev.Input = undefined,
    keymap: kbd.Keymap = undefined,
    decoder: kbd.Decoder = undefined,

    // text
    fonts: FontSet = .{},
    renderer: render.Renderer = undefined,
    cols: u16 = 80,
    rows: u16 = 24,
    origin_x: u32 = 0,
    origin_y: u32 = 0,
    scheme: termcore.schemes.Scheme = undefined,

    // terminal
    tiny_io: vt.TinyIo = .init,
    term: vt.Terminal = undefined,
    stream: vt.TerminalStream = undefined,
    state: vt.RenderState = .empty,
    hold: bool = false,
    pty: Pty = .{ .master = -1, .pid = 0 },
    login_running: bool = false,
    last_cursor: ?struct { x: u16, y: u16 } = null,
    cursor_on: bool = true,
    next_blink: i64 = 0,

    // pointer and selection
    pointer_visible: bool = false,
    pointer_x: i32 = 0,
    pointer_y: i32 = 0,
    pointer_shown_rows: ?[2]u32 = null,
    selecting: bool = false,
    anchor: ?vt.Pin = null,
    primary: std.ArrayList(u8) = .empty,

    /// The fonts changed while this VT was in the background.
    layout_stale: bool = false,
    login_started_at: i64 = 0,
    healthy_at: i64 = 0,
    healthy_done: bool = false,
    quit: bool = false,

    // ---- start-up ----------------------------------------------------------------

    fn main(self: *Console) u8 {
        const a = self.allocator;
        self.vtdev = vtmod.Vt.open(self.vt_num) orelse {
            sys.print(2, "dkde-console: cannot open /dev/tty{d}\n", .{self.vt_num});
            return 1;
        };
        // A crash cannot restore the VT, so every start does (SPEC.md 5.11).
        self.vtdev.restoreText();

        self.loadSettings();
        const decision = fallback.decide(fallback.readCounter(a, self.vt_num));
        if (decision.fall_back) {
            sys.print(2, "dkde-console: too many recent crashes on tty{d}; using the plain getty\n", .{self.vt_num});
            fallback.execFallback(a, self.settings.fallback, &self.vtdev);
            return 1;
        }
        if (decision.write_count) |n| fallback.writeCounter(self.vt_num, n);

        self.sig_fd = vtmod.installSignals() orelse -1;

        if (!self.openDisplay()) {
            sys.print(2, "dkde-console: no usable display; using the plain getty\n", .{});
            fallback.execFallback(a, self.settings.fallback, &self.vtdev);
            return 1;
        }

        self.input = evdev.Input.init(a);
        self.keymap = kbd.Keymap.init(a);
        self.decoder = kbd.Decoder.init(&self.keymap);

        self.setupTerminal() catch |e| {
            sys.print(2, "dkde-console: terminal setup failed ({s}); using the plain getty\n", .{@errorName(e)});
            self.closeDisplay();
            fallback.execFallback(a, self.settings.fallback, &self.vtdev);
            return 1;
        };
        self.startLogin();

        _ = self.vtdev.take();
        if (self.vtdev.isActive()) {
            self.acquire();
        } else if (self.dev) |*d| {
            // Another VT is on screen. Opening the card made us its master if
            // nobody else was, and a compositor over there must be able to take
            // it, so let go until this VT is shown.
            d.dropMaster();
        }

        self.healthy_at = nowSeconds() + fallback.healthy_seconds;
        self.watchConfig();
        self.loop();
        self.shutdown();
        return 0;
    }

    fn shutdown(self: *Console) void {
        self.pty.deinit();
        self.releaseDisplayResources();
        self.input.deinit();
        self.keymap.deinit();
        if (self.dev) |*d| d.close();
        // Back to a text console for whoever comes next.
        self.vtdev.restoreText();
        self.vtdev.close();
    }

    fn loadSettings(self: *Console) void {
        const a = self.allocator;
        if (self.docs_loaded) {
            self.etc_doc.deinit();
            self.defs_doc.deinit();
        }
        self.etc_doc = configtool.loadDoc(a, configtool.etcPath());
        var dbuf: [std.fs.max_path_bytes]u8 = undefined;
        self.defs_doc = configtool.loadDoc(a, configtool.defaultsPath(&dbuf));
        self.docs_loaded = true;
        self.settings = config.Settings.resolve(.{ .etc = &self.etc_doc, .defaults = &self.defs_doc }, self.vt_num);
        self.scheme = termcore.schemes.scheme(self.settings.colors);
    }

    fn watchConfig(self: *Console) void {
        const path = configtool.etcPath();
        const dir = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[0..i] else ".";
        var b: [std.fs.max_path_bytes]u8 = undefined;
        const z = sys.pathZ(&b, dir) orelse return;
        self.conf_watch = inotify_init1(sys.O_CLOEXEC | sys.O_NONBLOCK);
        if (self.conf_watch < 0) return;
        // IN_CLOSE_WRITE | IN_MOVED_TO: the tool writes through a rename.
        if (inotify_add_watch(self.conf_watch, z.ptr, 0x8 | 0x80) < 0) {
            _ = sys.close(self.conf_watch);
            self.conf_watch = -1;
        }
    }

    // ---- display -------------------------------------------------------------------

    fn openDisplay(self: *Console) bool {
        var d = drm.Device.openFirst(self.allocator) catch return false;
        const out = d.probe(self.allocator) catch {
            d.close();
            return false;
        };
        self.dev = d;
        self.out = out;
        self.buildLayout() catch {
            d.close();
            self.dev = null;
            return false;
        };
        return true;
    }

    fn closeDisplay(self: *Console) void {
        if (self.dev) |*d| d.close();
        self.dev = null;
    }

    /// Fonts, then the grid that fits the screen.
    fn buildLayout(self: *Console) !void {
        const a = self.allocator;
        var set: FontSet = .{};
        errdefer set.deinit(a);

        var h = self.settings.font_size * self.settings.scale;
        if (h == 0) h = drm.chooseFontHeight(self.out.width(), self.out.height(), self.out.mm_height) * self.settings.scale;
        var main_ok = false;
        if (self.settings.font.len > 0) main_ok = set.addFile(a, self.settings.font, h);
        // A TrueType cell is not half as wide as it is tall: shrink until 80 columns fit.
        while (main_ok and set.faces.items.len > 0 and h > 8 and self.out.width() / set.faces.items[0].cell_w < 80) {
            h -= 1;
            set.deinit(a);
            set = .{};
            main_ok = set.addFile(a, self.settings.font, h);
        }
        if (!main_ok) try set.addBuiltin(a, if (self.settings.font_size == 0) h / self.settings.scale else self.settings.font_size);
        var it = std.mem.tokenizeAny(u8, self.settings.fallback_fonts, ", ");
        while (it.next()) |path| _ = set.addFile(a, path, h);
        // The built-in fonts of the same size back up a font from disk.
        if (main_ok and set.fonts.items.len > 0) try set.addBuiltin(a, set.fonts.items[0].height);
        if (main_ok and set.fonts.items.len == 0) try set.addBuiltin(a, 16);

        self.fonts.deinit(a);
        self.fonts = set;
        self.renderer = render.Renderer.initMixed(self.fonts.ptrs.items, self.fonts.faces.items, self.settings.scale);

        const cols = self.out.width() / self.renderer.cell_w;
        const rows = self.out.height() / self.renderer.cell_h;
        self.cols = @intCast(@max(2, @min(cols, 1000)));
        self.rows = @intCast(@max(1, @min(rows, 1000)));
        self.origin_x = (self.out.width() - @as(u32, self.cols) * self.renderer.cell_w) / 2;
        self.origin_y = (self.out.height() - @as(u32, self.rows) * self.renderer.cell_h) / 2;
    }

    /// Frame buffers, input devices and the keymap: what only the visible VT holds.
    fn acquire(self: *Console) void {
        const d = &(self.dev orelse return);
        d.setMaster();
        // Outputs are probed again on every acquire (SPEC.md 5.11).
        if (d.probe(self.allocator)) |o| {
            const resized = o.width() != self.out.width() or o.height() != self.out.height();
            self.out = o;
            if (resized or self.layout_stale) {
                self.buildLayout() catch {};
                self.resizeTerminal();
                self.layout_stale = false;
            }
        } else |_| {}

        for (0..2) |i| {
            self.bufs[i] = d.createBuffer(self.out.width(), self.out.height()) catch null;
            if (self.bufs[i] == null) {
                self.releaseDisplayResources();
                return;
            }
        }
        if (d.setMode(&self.out, &self.bufs[0].?)) {} else |_| {
            self.releaseDisplayResources();
            return;
        }
        self.back = 1;
        self.flip_pending = false;
        self.have_display = true;
        for (&self.damage) |*dm| dm.full = true;

        self.input.open();
        if (kbd.Keymap.load(self.allocator, self.vtdev.fd)) |km| {
            self.keymap.deinit();
            self.keymap = km;
            self.decoder = kbd.Decoder.init(&self.keymap);
        } else |_| {}
        self.draw(0);
    }

    fn releaseDisplayResources(self: *Console) void {
        self.have_display = false;
        self.flip_pending = false;
        if (self.dev) |*d| {
            for (&self.bufs) |*b| if (b.*) |*buf| {
                d.destroyBuffer(buf);
                b.* = null;
            };
        }
        for (&self.damage) |*dm| dm.rows.clearRetainingCapacity();
        self.input.closeAll();
        self.decoder.reset();
        self.selecting = false;
    }

    /// The kernel asks to switch away: let go of everything, then say yes. The
    /// acknowledgement is sent no matter what, or the user cannot leave.
    fn release(self: *Console) void {
        if (self.dev) |*d| {
            d.dropMaster();
        }
        self.releaseDisplayResources();
        self.vtdev.ackRelease();
    }

    fn onAcquire(self: *Console) void {
        self.vtdev.ackAcquire();
        self.acquire();
    }

    // ---- terminal --------------------------------------------------------------------

    fn setupTerminal(self: *Console) !void {
        const a = self.allocator;
        self.term = try vt.Terminal.init(self.tiny_io.io(), a, .{
            .cols = self.cols,
            .rows = self.rows,
            .max_scrollback_lines = self.settings.scrollback_lines,
            .colors = try termcore.glue.terminalColors(a, self.scheme),
        });
        self.stream = self.term.vtStream();
        var e = vt.TerminalStream.Handler.Effects.readonly;
        e.write_pty = onWritePty;
        e.render_hold = onRenderHold;
        e.clipboard_write = onClipboardWrite;
        e.device_attributes = onDeviceAttributes;
        e.size = onSizeReport;
        e.xtversion = onXtversion;
        self.stream.handler.effects = e;
    }

    fn fromHandler(handler: *vt.TerminalStream.Handler) *Console {
        const stream: *vt.TerminalStream = @fieldParentPtr("handler", handler);
        return @fieldParentPtr("stream", stream);
    }

    fn onWritePty(handler: *vt.TerminalStream.Handler, data: []const u8) void {
        const self = fromHandler(handler);
        if (self.login_running) self.pty.writeAll(data);
    }

    fn onRenderHold(handler: *vt.TerminalStream.Handler, hold: bool) void {
        fromHandler(handler).hold = hold;
    }

    fn onClipboardWrite(handler: *vt.TerminalStream.Handler, write: vt.clipboard.Write) void {
        const self = fromHandler(handler);
        for (write.contents) |c| {
            if (!std.mem.eql(u8, c.mime, "text/plain")) continue;
            self.primary.clearRetainingCapacity();
            self.primary.appendSlice(self.allocator, c.data) catch {};
            return;
        }
    }

    fn onDeviceAttributes(_: *vt.TerminalStream.Handler) vt.device_attributes.Attributes {
        return .{};
    }

    fn onSizeReport(handler: *vt.TerminalStream.Handler) ?vt.size_report.Size {
        const self = fromHandler(handler);
        return .{ .rows = self.rows, .columns = self.cols, .cell_width = @intCast(self.renderer.cell_w), .cell_height = @intCast(self.renderer.cell_h) };
    }

    fn onXtversion(_: *vt.TerminalStream.Handler) []const u8 {
        return "dkde-console 0.1";
    }

    fn ptySize(self: *const Console) termcore.pty.Size {
        return .{ .cols = self.cols, .rows = self.rows, .cell_w = @intCast(self.renderer.cell_w), .cell_h = @intCast(self.renderer.cell_h) };
    }

    fn resizeTerminal(self: *Console) void {
        self.stream.handler.resize(.{
            .cols = self.cols,
            .rows = self.rows,
            .cell_size_px = .{ .width = self.renderer.cell_w, .height = self.renderer.cell_h },
        }) catch |e| log.warn("resize failed: {s}", .{@errorName(e)});
        if (self.login_running) self.pty.resize(self.ptySize());
    }

    // ---- login -------------------------------------------------------------------------

    fn startLogin(self: *Console) void {
        const a = self.allocator;
        // A login that keeps exiting at once (a broken PAM setup) must not make
        // this loop spin: wait a second before the next try.
        const now = nowSeconds();
        if (self.login_started_at != 0 and now - self.login_started_at < 1) {
            var ts: Timespec = .{ .sec = 1, .nsec = 0 };
            _ = nanosleep(&ts, null);
        }
        self.login_started_at = nowSeconds();
        self.printIssue();
        const path: [:0]const u8 = for (login_paths) |p| {
            if (sys.exists(p)) break p;
        } else {
            self.stream.nextSlice("dkde-console: no login program found\r\n");
            return;
        };
        self.pty = Pty.spawn(a, .{
            .path = path,
            .argv = &.{"login"},
            .env = &.{ "TERM=xterm-256color", "COLORTERM=truecolor" },
            .size = self.ptySize(),
        }) catch {
            self.stream.nextSlice("dkde-console: cannot start login\r\n");
            return;
        };
        self.login_running = true;
    }

    fn printIssue(self: *Console) void {
        const a = self.allocator;
        const text = sys.readFile(a, "/etc/issue", 64 << 10) catch return;
        defer a.free(text);
        var uts: issue.Uts = .{};
        var line: [16]u8 = undefined;
        const tty = std.fmt.bufPrint(&line, "tty{d}", .{self.vt_num}) catch "tty";
        const sysinfo = uts.system(tty);
        var aw: std.Io.Writer.Allocating = .init(a);
        defer aw.deinit();
        issue.expand(&aw.writer, text, sysinfo) catch return;
        self.stream.nextSlice(aw.written());
    }

    /// `login` ended: clear the screen and start it again. It never runs a
    /// shell itself.
    fn loginExited(self: *Console) void {
        self.pty.deinit();
        self.login_running = false;
        self.stream.nextSlice("\x1b[0m\x1b[H\x1b[2J\x1b[3J");
        self.term.scrollViewport(.bottom);
        self.startLogin();
    }

    // ---- the loop ---------------------------------------------------------------------

    fn loop(self: *Console) void {
        var fds: [96]evdev.PollFd = undefined;
        var events: std.ArrayList(evdev.Event) = .empty;
        defer events.deinit(self.allocator);

        while (!self.quit) {
            var n: usize = 0;
            const sig_i = n;
            fds[n] = .{ .fd = self.sig_fd, .events = evdev.POLLIN, .revents = 0 };
            n += 1;
            const pty_i = n;
            fds[n] = .{ .fd = if (self.login_running) self.pty.fd() else -1, .events = evdev.POLLIN, .revents = 0 };
            n += 1;
            const conf_i = n;
            fds[n] = .{ .fd = self.conf_watch, .events = evdev.POLLIN, .revents = 0 };
            n += 1;
            const drm_i = n;
            fds[n] = .{ .fd = if (self.have_display and self.flip_pending) self.dev.?.fd else -1, .events = evdev.POLLIN, .revents = 0 };
            n += 1;
            const input_i = n;
            if (self.have_display) n += self.input.pollFds(fds[n..]);

            const r = poll(&fds, n, self.timeoutMs());
            if (r < 0) {
                if (sys.errno() == sys.EINTR) continue;
                break;
            }
            const now = nowSeconds();
            if (!self.healthy_done and now >= self.healthy_at) {
                fallback.writeCounter(self.vt_num, 0);
                self.healthy_done = true;
            }

            var dirty = false;
            if (fds[sig_i].revents != 0) self.handleSignals(&dirty);
            if (self.quit) break;
            if (fds[conf_i].revents != 0) self.reloadConfig(&dirty);
            if (fds[pty_i].revents != 0) self.readPty(&dirty);
            if (fds[drm_i].revents != 0) {
                if (self.dev.?.readEvents() > 0) {
                    self.flip_pending = false;
                    self.back ^= 1;
                    dirty = true;
                }
            }
            if (self.have_display) {
                events.clearRetainingCapacity();
                for (fds[input_i..n]) |p| {
                    if (p.revents != 0) self.input.service(p.fd, &events);
                }
                for (events.items) |ev| self.handleInput(ev, &dirty);
            }
            if (self.cursor_blink_due(now)) dirty = true;
            if (dirty) self.draw(now);
        }
    }

    fn timeoutMs(self: *const Console) c_int {
        var ms: i64 = -1;
        const now = nowSeconds();
        if (!self.healthy_done) ms = @max(0, self.healthy_at - now) * 1000;
        if (self.have_display and self.settings.cursor_blink) {
            ms = if (ms < 0) 500 else @min(ms, 500);
        }
        return @intCast(ms);
    }

    fn cursor_blink_due(self: *Console, now: i64) bool {
        _ = now;
        if (!self.have_display or !self.settings.cursor_blink) return false;
        // Toggled once per poll timeout; the timer runs only on the visible VT.
        var ts: Timespec = undefined;
        _ = clock_gettime(1, &ts);
        const ms = ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
        if (ms < self.next_blink) return false;
        self.next_blink = ms + 500;
        self.cursor_on = !self.cursor_on;
        return true;
    }

    fn handleSignals(self: *Console, dirty: *bool) void {
        var buf: [32]u8 = undefined;
        for (vtmod.drainSignals(self.sig_fd, &buf)) |s| {
            switch (s) {
                vtmod.SIGUSR1 => self.release(),
                vtmod.SIGUSR2 => {
                    self.onAcquire();
                    dirty.* = true;
                },
                vtmod.SIGCHLD => if (self.login_running) {
                    if (self.pty.poll() != null) {
                        self.pty.pid = 0;
                        self.loginExited();
                        dirty.* = true;
                    }
                },
                else => self.quit = true, // TERM, INT, HUP
            }
        }
    }

    fn reloadConfig(self: *Console, dirty: *bool) void {
        var buf: [512]u8 align(4) = undefined;
        while (sys.read(self.conf_watch, &buf, buf.len) > 0) {}
        const old = self.settings;
        const old_scheme = self.scheme;
        self.loadSettings();
        _ = old_scheme;
        // Fonts and colours change on the next frame; `fallback` is read at start-up.
        const font_changed = !std.mem.eql(u8, old.font, self.settings.font) or
            !std.mem.eql(u8, old.fallback_fonts, self.settings.fallback_fonts) or
            old.font_size != self.settings.font_size or old.scale != self.settings.scale;
        if (font_changed) {
            if (self.have_display) {
                self.buildLayout() catch return;
                self.resizeTerminal();
            } else self.layout_stale = true;
        }
        self.term.colors.background = .init(termcore.glue.rgb(self.scheme.background));
        self.term.colors.foreground = .init(termcore.glue.rgb(self.scheme.foreground));
        self.term.colors.palette.changeDefault(self.allocator, termcore.glue.palette(self.scheme)) catch {};
        for (&self.damage) |*dm| dm.full = true;
        dirty.* = true;
    }

    fn readPty(self: *Console, dirty: *bool) void {
        if (!self.login_running) return;
        var buf: [16384]u8 = undefined;
        var rounds: usize = 0;
        // Bounded, so a flood of output cannot starve the keyboard.
        while (rounds < 16) : (rounds += 1) {
            const n = self.pty.readSome(&buf) orelse {
                // The slave side closed: login ended; SIGCHLD will say so, but do
                // not spin on a closed descriptor meanwhile.
                if (self.pty.poll() != null) {
                    self.pty.pid = 0;
                    self.loginExited();
                }
                dirty.* = true;
                return;
            };
            if (n == 0) break;
            self.stream.nextSlice(buf[0..n]);
            dirty.* = true;
        }
    }

    // ---- drawing ---------------------------------------------------------------------

    fn markRow(self: *Console, y: usize) void {
        for (&self.damage) |*dm| {
            if (dm.full) continue;
            if (dm.rows.items.len <= y) dm.rows.resize(self.allocator, y + 1) catch {
                dm.full = true;
                continue;
            };
            dm.rows.items[y] = true;
        }
    }

    fn markAll(self: *Console) void {
        for (&self.damage) |*dm| dm.full = true;
    }

    fn draw(self: *Console, now: i64) void {
        _ = now;
        if (!self.have_display or self.hold) return;
        self.state.update(self.allocator, &self.term) catch return;

        // What the renderer says changed, plus the cursor's old and new rows.
        if (self.state.dirty != .false) {
            self.markAll();
        } else {
            const row_data = self.state.row_data.slice();
            for (row_data.items(.dirty), 0..) |d, y| if (d) self.markRow(y);
        }
        const cursor = self.cursorToDraw();
        if (self.last_cursor) |lc| self.markRow(lc.y);
        if (cursor) |c| self.markRow(c.y);
        self.last_cursor = if (cursor) |c| .{ .x = c.x, .y = c.y } else null;
        self.markPointerRows();
        self.state.clean();

        if (self.flip_pending) return; // keep the damage; the flip event brings us back
        const dm = &self.damage[self.back];
        const any = dm.full or std.mem.indexOfScalar(bool, dm.rows.items, true) != null;
        if (!any) return;
        const buf = &self.bufs[self.back].?;

        if (dm.full) {
            self.renderer.drawMargins(buf, self.origin_y, self.rows, render.pack(self.state.colors.background));
            for (0..self.state.rows) |y| self.renderer.drawRow(buf, self.origin_x, self.origin_y, &self.state, y, cursor);
        } else {
            for (dm.rows.items, 0..) |d, y| {
                if (d and y < self.state.rows) self.renderer.drawRow(buf, self.origin_x, self.origin_y, &self.state, y, cursor);
            }
        }
        dm.full = false;
        @memset(dm.rows.items, false);
        if (self.pointer_visible) render.drawPointer(buf, @intCast(@max(0, self.pointer_x)), @intCast(@max(0, self.pointer_y)));

        if (self.dev.?.flip(&self.out, buf)) {
            self.flip_pending = true;
        } else {
            // The flip failed (the display went away?): retry on the next change.
            self.markAll();
        }
    }

    fn cursorToDraw(self: *const Console) ?render.Cursor {
        const c = self.state.cursor;
        if (!c.visible) return null;
        const pos = c.viewport orelse return null;
        if (c.blinking and self.settings.cursor_blink and !self.cursor_on) return null;
        return .{
            .x = pos.x,
            .y = pos.y,
            .style = switch (c.visual_style) {
                .block => .block,
                .block_hollow => .hollow,
                .bar => .bar,
                .underline => .underline,
            },
            .color = self.state.colors.cursor orelse self.state.colors.foreground,
        };
    }

    fn markPointerRows(self: *Console) void {
        if (self.pointer_shown_rows) |r| {
            var y = r[0];
            while (y <= r[1]) : (y += 1) self.markRow(y);
        }
        if (!self.pointer_visible) {
            self.pointer_shown_rows = null;
            return;
        }
        const cell_h = self.renderer.cell_h;
        const top = @as(u32, @intCast(@max(0, self.pointer_y)));
        const first = (top -| self.origin_y) / cell_h;
        const last = @min(@as(u32, self.rows) - 1, (top + render.pointer_h -| self.origin_y) / cell_h);
        self.pointer_shown_rows = .{ @min(first, last), last };
        var y = first;
        while (y <= last) : (y += 1) self.markRow(y);
    }

    // ---- input ---------------------------------------------------------------------

    fn handleInput(self: *Console, ev: evdev.Event, dirty: *bool) void {
        switch (ev) {
            .key => |k| self.handleKey(k.code, k.value, dirty),
            .motion => |m| {
                self.pointer_visible = true;
                self.pointer_x = std.math.clamp(self.pointer_x + m.dx, 0, @as(i32, @intCast(self.out.width())) - 1);
                self.pointer_y = std.math.clamp(self.pointer_y + m.dy, 0, @as(i32, @intCast(self.out.height())) - 1);
                self.pointerMoved(dirty);
            },
            .position => |p| {
                self.pointer_visible = true;
                self.pointer_x = @intCast(@as(u32, p.x) * (self.out.width() - 1) / 65535);
                self.pointer_y = @intCast(@as(u32, p.y) * (self.out.height() - 1) / 65535);
                self.pointerMoved(dirty);
            },
            .button => |b| self.handleButton(b.code, b.pressed, dirty),
            .wheel => |w| {
                if (self.term.flags.mouse_event != .none) {
                    var i: i32 = 0;
                    while (i < @abs(w)) : (i += 1) self.sendMouse(.press, if (w > 0) .four else .five);
                } else {
                    self.term.scrollViewport(.{ .delta = -@as(isize, w) * 3 });
                    dirty.* = true;
                }
            },
        }
    }

    fn handleKey(self: *Console, code: u16, value: i32, dirty: *bool) void {
        const ev = self.decoder.feed(code, value);
        // The pointer hides again on the next key press.
        if (ev.action == .press and self.pointer_visible) {
            self.pointer_visible = false;
            dirty.* = true;
        }
        if (kbd.vtSwitch(&ev)) |n| {
            self.vtdev.activate(n);
            return;
        }
        if (ev.action != .release and ev.shift and !ev.ctrl and !ev.alt) {
            switch (code) {
                104 => { // Shift+PageUp
                    self.term.scrollViewport(.{ .delta = -@as(isize, self.rows) + 1 });
                    dirty.* = true;
                    return;
                },
                109 => { // Shift+PageDown
                    self.term.scrollViewport(.{ .delta = @as(isize, self.rows) - 1 });
                    dirty.* = true;
                    return;
                },
                110 => { // Shift+Insert
                    if (ev.action == .press) self.pasteText(self.primary.items);
                    return;
                },
                else => {},
            }
        }
        if (!self.login_running) return;
        if (ev.action != .release) self.term.scrollViewport(.bottom);

        var event: vt.input.KeyEvent = .{
            .action = switch (ev.action) {
                .press => .press,
                .repeat => .repeat,
                .release => .release,
            },
            .key = termcore.keymap.fromEvdev(code),
            .mods = .{ .shift = ev.shift, .ctrl = ev.ctrl, .alt = ev.alt, .super = ev.super, .caps_lock = ev.caps_lock, .num_lock = ev.num_lock },
            .utf8 = if (ev.action == .release) "" else ev.textSlice(),
            .unshifted_codepoint = ev.unshifted,
        };
        if (event.utf8.len > 0 and ev.shift) event.consumed_mods = .{ .shift = true };
        var buf: [128]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        const opts = vt.input.KeyEncodeOptions.fromTerminal(&self.term);
        vt.input.encodeKey(&w, event, opts) catch return;
        const out = w.buffered();
        if (out.len > 0) self.pty.writeAll(out);
        dirty.* = true;
    }

    fn pasteText(self: *Console, text: []const u8) void {
        if (text.len == 0 or !self.login_running) return;
        const copy = self.allocator.dupe(u8, text) catch return;
        defer self.allocator.free(copy);
        const opts = vt.input.PasteOptions.fromTerminal(&self.term);
        for (vt.input.encodePaste(copy, opts)) |part| if (part.len > 0) self.pty.writeAll(part);
        self.term.scrollViewport(.bottom);
    }

    fn cellAt(self: *const Console) struct { col: u16, row: u16 } {
        const x = @as(u32, @intCast(@max(0, self.pointer_x)));
        const y = @as(u32, @intCast(@max(0, self.pointer_y)));
        const col = @min(@as(u32, self.cols) - 1, (x -| self.origin_x) / self.renderer.cell_w);
        const row = @min(@as(u32, self.rows) - 1, (y -| self.origin_y) / self.renderer.cell_h);
        return .{ .col = @intCast(col), .row = @intCast(row) };
    }

    fn sendMouse(self: *Console, action: vt.input.MouseAction, button: ?vt.input.MouseButton) void {
        if (!self.login_running) return;
        var buf: [64]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        const MouseSize = @FieldType(vt.input.MouseEncodeOptions, "size");
        const size: MouseSize = .{
            .screen = .{ .width = self.out.width(), .height = self.out.height() },
            .cell = .{ .width = self.renderer.cell_w, .height = self.renderer.cell_h },
            .padding = .{ .top = self.origin_y, .bottom = self.origin_y, .right = self.origin_x, .left = self.origin_x },
        };
        var opts = vt.input.MouseEncodeOptions.fromTerminal(&self.term, size);
        opts.any_button_pressed = self.selecting;
        vt.input.encodeMouse(&w, .{
            .action = action,
            .button = button,
            .mods = .{ .shift = self.decoder.held[0] > 0, .ctrl = self.decoder.held[2] > 0, .alt = self.decoder.held[3] > 0 },
            .pos = .{ .x = @floatFromInt(self.pointer_x), .y = @floatFromInt(self.pointer_y) },
        }, opts) catch return;
        self.pty.writeAll(w.buffered());
    }

    fn pointerMoved(self: *Console, dirty: *bool) void {
        dirty.* = true;
        const shift = self.decoder.held[0] > 0;
        if (self.term.flags.mouse_event != .none and !shift) {
            if (self.term.flags.mouse_event == .any or (self.term.flags.mouse_event == .button and self.selecting))
                self.sendMouse(.motion, null);
            return;
        }
        if (!self.selecting) return;
        const cell = self.cellAt();
        const screen = self.term.screens.active;
        const pin = screen.pages.pin(.{ .viewport = .{ .x = cell.col, .y = cell.row } }) orelse return;
        const anchor = self.anchor orelse return;
        screen.select(vt.Selection.init(anchor, pin, self.decoder.held[3] > 0)) catch return;
    }

    fn handleButton(self: *Console, code: u16, pressed: bool, dirty: *bool) void {
        dirty.* = true;
        const button: vt.input.MouseButton = switch (code) {
            evdev.BTN_LEFT => .left,
            evdev.BTN_RIGHT => .right,
            evdev.BTN_MIDDLE => .middle,
            else => return,
        };
        const shift = self.decoder.held[0] > 0;
        if (self.term.flags.mouse_event != .none and !shift) {
            self.selecting = pressed;
            self.sendMouse(if (pressed) .press else .release, button);
            return;
        }
        if (button == .middle) {
            if (pressed) self.pasteText(self.primary.items);
            return;
        }
        if (button != .left) return;
        const screen = self.term.screens.active;
        if (pressed) {
            const cell = self.cellAt();
            const pin = screen.pages.pin(.{ .viewport = .{ .x = cell.col, .y = cell.row } }) orelse return;
            self.selecting = true;
            self.anchor = pin;
            screen.clearSelection();
        } else {
            self.selecting = false;
            // Selecting copies, within this console (SPEC.md 5.11).
            const selection = screen.selection orelse return;
            const text = screen.selectionString(self.allocator, .{ .sel = selection }) catch return;
            defer self.allocator.free(text);
            self.primary.clearRetainingCapacity();
            self.primary.appendSlice(self.allocator, text) catch {};
        }
    }
};
