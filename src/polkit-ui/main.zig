//! dkde-polkit-ui: the dialog of the polkit agent (SPEC.md 5.12). The agent
//! (`dkde-polkit`, which speaks only D-Bus and so costs a few megabytes while
//! idle) starts one of these for each request and waits for it.
//!
//!     dkde-polkit-ui --message TEXT [--icon NAME] [--program TEXT] --uid N [--uid N ...]
//!
//! The polkit cookie arrives on standard input, on a line of its own, never on
//! the command line. The program asks for the password in a dialog, runs it
//! through polkit's authentication helper, and exits: 0 when the user was
//! authenticated, 1 when not, 2 when the dialog was cancelled.
//!
//! The helper (polkit-agent-helper-1, reached through the socket
//! `/run/polkit/agent-helper.socket`, else as a setuid program) is sent the
//! user name and the cookie, one per line, and answers with PAM prompts. It is
//! the helper, not this program, that tells polkitd authentication worked.

const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");
const proto = @import("polkitproto");

const tr = common.tr;
const log = std.log.scoped(.polkit_ui);
pub const std_options: std.Options = .{ .logFn = common.log.logFn, .log_level = .debug };

const gpa = std.heap.c_allocator;

const helper_socket = "/run/polkit/agent-helper.socket";
const helper_programs = [_][:0]const u8{
    "/usr/lib/polkit-1/polkit-agent-helper-1",
    "/usr/libexec/polkit-agent-helper-1",
    "/usr/lib/policykit-1/polkit-agent-helper-1",
    "/usr/libexec/polkit-1/polkit-agent-helper-1",
};
const max_hard_failures = 3;

const exit_ok = 0;
const exit_failed = 1;
const exit_cancelled = 2;

const Identity = struct {
    uid: u32,
    name: [64]u8 = undefined,
    name_len: usize = 0,

    fn nameSlice(self: *const Identity) []const u8 {
        return self.name[0..self.name_len];
    }
};

const Ui = struct {
    app: *gtk.Application,
    cookie: [:0]u8 = undefined,
    message: [:0]u8 = undefined,
    icon: [:0]u8 = undefined,
    program: [:0]u8 = undefined,
    identities: std.ArrayList(Identity) = .empty,
    chosen: usize = 0,

    window: ?*gtk.Window = null,
    entry: ?*gtk.PasswordEntry = null,
    ok: ?*gtk.Button = null,
    prompt_label: ?*gtk.Label = null,
    status: ?*gtk.Label = null,

    // The session with the helper.
    in: ?*gio.DataInputStream = null,
    out: ?*gio.OutputStream = null,
    conn: ?*gio.IOStream = null,
    proc: ?*gio.Subprocess = null,
    cancellable: ?*gio.Cancellable = null,
    generation: u32 = 0,
    /// A prompt is on screen and the next thing typed answers it.
    awaiting: bool = false,
    /// Prompts seen in this session: none means the helper itself did not work.
    prompts: u32 = 0,
    hard_failures: u32 = 0,
};

var ui: Ui = undefined;

// ---- finishing ------------------------------------------------------------------------------

/// Closes the helper session and the dialog and ends the program. Nothing is
/// left running, so nothing needs freeing.
fn finish(code: u8) noreturn {
    closeSession();
    if (ui.window) |w| w.destroy();
    std.process.exit(code);
}

// ---- the helper -----------------------------------------------------------------------------

fn closeSession() void {
    ui.generation +%= 1;
    ui.awaiting = false;
    if (ui.cancellable) |c| {
        c.cancel();
        c.as(gobject.Object).unref();
        ui.cancellable = null;
    }
    if (ui.in) |i| {
        i.as(gobject.Object).unref();
        ui.in = null;
    }
    if (ui.conn) |c| {
        _ = c.close(null, null);
        c.as(gobject.Object).unref();
        ui.conn = null;
    }
    if (ui.proc) |p| {
        p.forceExit();
        p.as(gobject.Object).unref();
        ui.proc = null;
    }
    ui.out = null;
}

fn writeLine(text: []const u8) bool {
    const out = ui.out orelse return false;
    var err: ?*glib.Error = null;
    if (out.writeAll(@constCast(text.ptr), text.len, null, null, &err) == 0) {
        if (err) |e| {
            log.warn("cannot write to the helper: {s}", .{e.f_message orelse "unknown"});
            e.free();
        }
        return false;
    }
    return true;
}

/// Opens the helper for the chosen identity and starts reading its lines.
fn startSession() void {
    closeSession();
    ui.prompts = 0;
    const user = ui.identities.items[ui.chosen].nameSlice();
    var err: ?*glib.Error = null;

    var opened = false;
    if (std.c.access(helper_socket, 0) == 0) {
        // polkit's socket-activated helper: the user name, then the cookie, one per line.
        const client = gio.SocketClient.new();
        defer client.as(gobject.Object).unref();
        const addr = gio.UnixSocketAddress.new(helper_socket);
        defer addr.as(gobject.Object).unref();
        if (client.connect(addr.as(gio.SocketConnectable), null, &err)) |conn| {
            const io = conn.as(gio.IOStream);
            ui.conn = io;
            ui.out = io.getOutputStream();
            ui.in = gio.DataInputStream.new(io.getInputStream());
            opened = writeLine(user) and writeLine("\n") and writeLine(ui.cookie) and writeLine("\n");
        } else if (err) |e| {
            log.warn("cannot reach {s}: {s}", .{ helper_socket, e.f_message orelse "unknown" });
            e.free();
            err = null;
        }
    }
    if (!opened) {
        closeSession();
        // The setuid helper: the user name as an argument, the cookie on stdin.
        const program: ?[:0]const u8 = for (helper_programs) |p| {
            if (std.c.access(p, 1) == 0) break p;
        } else null;
        if (program) |prog| {
            const user_z = gpa.dupeSentinel(u8, user, 0) catch return;
            defer gpa.free(user_z);
            // GLib wants a NULL-terminated argument list.
            const terminated: [3]?[*:0]const u8 = .{ prog.ptr, user_z.ptr, null };
            if (gio.Subprocess.newv(@ptrCast(&terminated), .{ .stdin_pipe = true, .stdout_pipe = true, .stderr_silence = true }, &err)) |p| {
                ui.proc = p;
                ui.out = p.getStdinPipe();
                ui.in = gio.DataInputStream.new(p.getStdoutPipe().?);
                opened = writeLine(ui.cookie) and writeLine("\n");
            } else if (err) |e| {
                log.warn("cannot start {s}: {s}", .{ prog, e.f_message orelse "unknown" });
                e.free();
            }
        } else log.warn("no polkit helper found: not at {s} and no polkit-agent-helper-1 in the usual places", .{helper_socket});
    }
    if (!opened) {
        closeSession();
        setStatus(tr("Authentication could not be started. Is polkit installed?"), true);
        ui.hard_failures += 1;
        if (ui.hard_failures >= max_hard_failures) finish(exit_failed);
        return;
    }
    ui.cancellable = gio.Cancellable.new();
    readNext();
}

const ReadCtx = struct { generation: u32 };

fn readNext() void {
    const in = ui.in orelse return;
    const ctx = gpa.create(ReadCtx) catch return;
    ctx.* = .{ .generation = ui.generation };
    in.readLineAsync(glib.PRIORITY_DEFAULT, ui.cancellable, onLine, ctx);
}

fn onLine(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
    const ctx: *ReadCtx = @ptrCast(@alignCast(data.?));
    const generation = ctx.generation;
    gpa.destroy(ctx);

    const stream: *gio.DataInputStream = @ptrCast(source.?);
    var length: usize = 0;
    var err: ?*glib.Error = null;
    const line = stream.readLineFinish(result, &length, &err);
    // A read from a session that was closed or replaced: nothing to do.
    if (generation != ui.generation) {
        if (err) |e| e.free();
        if (line) |l| glib.free(l);
        return;
    }
    if (line == null) {
        if (err) |e| e.free();
        log.warn("the helper closed without a verdict", .{});
        failed(false);
        return;
    }
    defer glib.free(line.?);

    var buf: [1024]u8 = undefined;
    switch (proto.parseHelperLine(line.?[0..length], &buf)) {
        .prompt_secret, .prompt_visible => |m| {
            ui.prompts += 1;
            askPrompt(m);
        },
        .error_text => |m| setStatusText(m, true),
        .info => |m| setStatusText(m, false),
        .success => finish(exit_ok),
        .failure => {
            failed(ui.prompts > 0);
            return;
        },
        .other => |m| log.debug("helper: {s}", .{m}),
    }
    readNext();
}

/// The helper said no (or went away). After a real attempt the user may try
/// again; if the helper never got as far as a prompt, give up after a few tries.
fn failed(wrong_password: bool) void {
    if (wrong_password) {
        ui.hard_failures = 0;
        setStatus(tr("Sorry, that didn't work. Please try again."), true);
        startSession();
        return;
    }
    ui.hard_failures += 1;
    if (ui.hard_failures >= max_hard_failures) finish(exit_failed);
    startSession();
}

// ---- the dialog --------------------------------------------------------------------------------

fn setStatusText(text: []const u8, is_error: bool) void {
    var buf: [600]u8 = undefined;
    const clean = proto.cleanText(text[0..@min(text.len, 500)], &buf);
    const z = gpa.dupeSentinel(u8, clean, 0) catch return;
    defer gpa.free(z);
    setStatus(z, is_error);
}

fn setStatus(text: [:0]const u8, is_error: bool) void {
    const label = ui.status orelse return;
    label.setText(text);
    const w = label.as(gtk.Widget);
    if (is_error) w.addCssClass("error") else w.removeCssClass("error");
}

fn askPrompt(prompt: []const u8) void {
    ui.awaiting = true;
    if (ui.prompt_label) |l| {
        var buf: [200]u8 = undefined;
        const clean = std.mem.trimEnd(u8, proto.cleanText(prompt[0..@min(prompt.len, 150)], &buf), ": ");
        const text = std.fmt.allocPrintSentinel(gpa, "{s}:", .{if (clean.len > 0) clean else "Password"}, 0) catch return;
        defer gpa.free(text);
        l.setText(text);
    }
    if (ui.entry) |e| {
        e.as(gtk.Widget).setSensitive(1);
        _ = e.as(gtk.Widget).grabFocus();
    }
    if (ui.ok) |b| b.as(gtk.Widget).setSensitive(1);
}

fn submit() void {
    if (!ui.awaiting) return;
    const entry = ui.entry orelse return;
    const text = std.mem.span(entry.as(gtk.Editable).getText());
    // Answer first, then wipe: the bytes go straight from the entry to the helper.
    if (!writeLine(text) or !writeLine("\n")) {
        failed(false);
        return;
    }
    ui.awaiting = false;
    entry.as(gtk.Editable).setText("");
    entry.as(gtk.Widget).setSensitive(0);
    if (ui.ok) |b| b.as(gtk.Widget).setSensitive(0);
    setStatus(tr("Checking…"), false);
}

fn onOk(_: *gtk.Button, _: ?*anyopaque) callconv(.c) void {
    submit();
}

fn onActivate(_: *gtk.PasswordEntry, _: ?*anyopaque) callconv(.c) void {
    submit();
}

fn onCancel(_: *gtk.Button, _: ?*anyopaque) callconv(.c) void {
    finish(exit_cancelled);
}

fn onClose(_: *gtk.Window, _: ?*anyopaque) callconv(.c) c_int {
    finish(exit_cancelled);
}

fn onIdentity(dd: *gtk.DropDown, _: *gobject.ParamSpec, _: ?*anyopaque) callconv(.c) void {
    const i = dd.getSelected();
    if (i >= ui.identities.items.len or i == ui.chosen) return;
    ui.chosen = i;
    setStatus("", false);
    startSession();
}

fn buildDialog() void {
    const window = gtk.Window.new();
    window.setTitle(tr("Authentication required"));
    window.setResizable(0);
    window.setDefaultSize(420, -1);
    window.as(gtk.Widget).addCssClass("dkde");
    window.setApplication(ui.app);

    const box = gtk.Box.new(.vertical, 10);
    box.as(gtk.Widget).setMarginTop(16);
    box.as(gtk.Widget).setMarginBottom(16);
    box.as(gtk.Widget).setMarginStart(16);
    box.as(gtk.Widget).setMarginEnd(16);
    window.setChild(box.as(gtk.Widget));

    const top = gtk.Box.new(.horizontal, 12);
    const icon = gtk.Image.newFromIconName(if (ui.icon.len > 0) ui.icon.ptr else "dialog-password-symbolic");
    icon.setPixelSize(48);
    icon.as(gtk.Widget).setValign(.start);
    top.append(icon.as(gtk.Widget));
    const texts = gtk.Box.new(.vertical, 6);
    texts.as(gtk.Widget).setHexpand(1);
    const heading = gtk.Label.new(tr("Authentication required"));
    heading.setXalign(0);
    heading.as(gtk.Widget).addCssClass("heading");
    texts.append(heading.as(gtk.Widget));
    const message = gtk.Label.new(ui.message);
    message.setXalign(0);
    message.setWrap(1);
    texts.append(message.as(gtk.Widget));
    if (ui.program.len > 0) {
        const program = gtk.Label.new(ui.program);
        program.setXalign(0);
        program.setWrap(1);
        program.setEllipsize(.middle);
        program.as(gtk.Widget).addCssClass("dim-label");
        texts.append(program.as(gtk.Widget));
    }
    top.append(texts.as(gtk.Widget));
    box.append(top.as(gtk.Widget));

    // Who to authenticate as: a choice when polkit offers several.
    if (ui.identities.items.len > 1) {
        const list = gtk.StringList.new(null);
        for (ui.identities.items) |i| {
            const z = gpa.dupeSentinel(u8, i.nameSlice(), 0) catch continue;
            defer gpa.free(z);
            list.append(z.ptr);
        }
        const dd = gtk.DropDown.new(list.as(gio.ListModel), null);
        dd.setSelected(@intCast(ui.chosen));
        _ = gobject.Object.signals.notify.connect(dd, ?*anyopaque, &onIdentity, null, .{ .detail = "selected" });
        const row = gtk.Box.new(.horizontal, 8);
        const l = gtk.Label.new(tr("Authenticate as:"));
        l.setXalign(0);
        row.append(l.as(gtk.Widget));
        row.append(dd.as(gtk.Widget));
        box.append(row.as(gtk.Widget));
    } else {
        var buf: [96]u8 = undefined;
        const who = std.fmt.bufPrintSentinel(&buf, "Authenticating as {s}", .{ui.identities.items[0].nameSlice()}, 0) catch "";
        const l = gtk.Label.new(who);
        l.setXalign(0);
        l.as(gtk.Widget).addCssClass("dim-label");
        box.append(l.as(gtk.Widget));
    }

    const prompt = gtk.Label.new(tr("Password:"));
    prompt.setXalign(0);
    box.append(prompt.as(gtk.Widget));
    const entry = gtk.PasswordEntry.new();
    entry.setShowPeekIcon(1);
    entry.as(gtk.Widget).setHexpand(1);
    // Disabled until the helper asks: it prompts right after it starts.
    entry.as(gtk.Widget).setSensitive(0);
    box.append(entry.as(gtk.Widget));

    const status = gtk.Label.new("");
    status.setXalign(0);
    status.setWrap(1);
    box.append(status.as(gtk.Widget));

    const buttons = gtk.Box.new(.horizontal, 8);
    buttons.as(gtk.Widget).setHalign(.end);
    const cancel = gtk.Button.newWithLabel(tr("Cancel"));
    const ok = gtk.Button.newWithLabel(tr("Authenticate"));
    ok.as(gtk.Widget).addCssClass("suggested-action");
    ok.as(gtk.Widget).setSensitive(0);
    buttons.append(cancel.as(gtk.Widget));
    buttons.append(ok.as(gtk.Widget));
    box.append(buttons.as(gtk.Widget));

    ui.window = window;
    ui.entry = entry;
    ui.ok = ok;
    ui.prompt_label = prompt;
    ui.status = status;
    _ = gtk.Button.signals.clicked.connect(ok, ?*anyopaque, &onOk, null, .{});
    _ = gtk.Button.signals.clicked.connect(cancel, ?*anyopaque, &onCancel, null, .{});
    _ = gtk.PasswordEntry.signals.activate.connect(entry, ?*anyopaque, &onActivate, null, .{});
    _ = gtk.Window.signals.close_request.connect(window, ?*anyopaque, &onClose, null, .{});
    window.present();
}

// ---- start-up ----------------------------------------------------------------------------------

fn addIdentity(uid: u32) void {
    for (ui.identities.items) |i| {
        if (i.uid == uid) return;
    }
    const pw = std.c.getpwuid(uid) orelse return;
    const name = std.mem.span(pw.name orelse return);
    if (!proto.validUserName(name)) return;
    var id: Identity = .{ .uid = uid };
    const n = @min(name.len, id.name.len);
    @memcpy(id.name[0..n], name[0..n]);
    id.name_len = n;
    ui.identities.append(gpa, id) catch {};
}

/// The cookie: the first line of standard input.
fn readCookie() ?[:0]u8 {
    var buf: [300]u8 = undefined;
    var n: usize = 0;
    while (n < buf.len) {
        const r = std.c.read(0, buf[n..].ptr, 1);
        if (r <= 0) break;
        if (buf[n] == '\n') break;
        n += 1;
    }
    if (!proto.validCookie(buf[0..n])) return null;
    return gpa.dupeSentinel(u8, buf[0..n], 0) catch null;
}

fn activate(app: *gtk.Application, _: ?*anyopaque) callconv(.c) void {
    common.style.load(gpa) catch |err| log.warn("stylesheet not loaded: {s}", .{@errorName(err)});
    _ = common.style.Appearance.create(gpa) catch null;
    ui.app = app;
    ui.chosen = proto.defaultIdentity(blk: {
        var uids: [16]u32 = undefined;
        const n = @min(ui.identities.items.len, uids.len);
        for (ui.identities.items[0..n], 0..) |i, k| uids[k] = i.uid;
        break :blk uids[0..n];
    }, std.c.getuid());
    buildDialog();
    startSession();
}

pub fn main(init: std.process.Init.Minimal) !void {
    common.perf.init();
    ui = .{ .app = undefined };
    ui.message = try gpa.dupeSentinel(u8, "", 0);
    ui.icon = try gpa.dupeSentinel(u8, "", 0);
    ui.program = try gpa.dupeSentinel(u8, "", 0);

    const args = init.args.vector;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = std.mem.span(args[i]);
        if (i + 1 >= args.len) break;
        const v = std.mem.span(args[i + 1]);
        var buf: [1024]u8 = undefined;
        if (std.mem.eql(u8, a, "--message")) {
            ui.message = try gpa.dupeSentinel(u8, proto.cleanText(v[0..@min(v.len, 512)], &buf), 0);
        } else if (std.mem.eql(u8, a, "--icon")) {
            ui.icon = try gpa.dupeSentinel(u8, proto.cleanText(v[0..@min(v.len, 128)], &buf), 0);
        } else if (std.mem.eql(u8, a, "--program")) {
            ui.program = try gpa.dupeSentinel(u8, proto.cleanText(v[0..@min(v.len, 400)], &buf), 0);
        } else if (std.mem.eql(u8, a, "--uid")) {
            if (std.fmt.parseInt(u32, v, 10)) |uid| addIdentity(uid) else |_| {}
        } else continue;
        i += 1;
    }
    if (ui.identities.items.len == 0) {
        log.err("usage: dkde-polkit-ui --message TEXT [--icon NAME] [--program TEXT] --uid N [--uid N ...]  (cookie on stdin)", .{});
        std.process.exit(exit_failed);
    }
    ui.cookie = readCookie() orelse {
        log.err("no valid cookie on standard input", .{});
        std.process.exit(exit_failed);
    };

    const gtk_app = gtk.Application.new("org.dkde.polkit-ui", .{ .non_unique = true });
    _ = gio.Application.signals.activate.connect(gtk_app, ?*anyopaque, &activate, null, .{});
    // GApplication only gets the program name; the options are ours.
    var argv = [_]?[*:0]const u8{ init.args.vector[0], null };
    const status = gio.Application.run(gtk_app.as(gio.Application), 1, @ptrCast(&argv));
    std.process.exit(@intCast(status));
}
