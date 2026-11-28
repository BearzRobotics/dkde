// SPDX-License-Identifier: GPL-2.0-or-later
//! Running something as administrator from a dkde app (SPEC.md 5.5, 5.7).
//!
//! There is no polkit agent or D-Bus in a dkde session, so this asks for the
//! user's password in a small dialog of its own and runs the command through
//! sudo. The password goes only to sudo's stdin and is wiped from memory
//! afterwards; it is never put on a command line, in the environment or on disk.
//!
//! sudo reads a password only when its rules want one for that command: under
//! `NOPASSWD` it reads nothing, and the command would get whatever was written
//! for sudo. `-k` does not change that (it only ignores a cached ticket). So
//! each command is first tried as `sudo -k -n`, with nothing but its own
//! input: it runs if no password is wanted. Only when sudo says it needs one
//! is it run again with `-S` and the password ahead of the input. For a shell
//! command with input, a marker line the shell discards up to separates the
//! two as well.
//!
//! Anything the command should read from stdin is passed in `stdin_data`.
//! Its standard output is dropped unless captured, and its error output goes
//! to a temporary file: with pipes, a command that printed would be killed
//! once they were closed, or would stall once they were full.

const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");

const core = @import("core");
const tr = core.i18n.tr;
const dialogs = @import("dialogs.zig");

pub const Outcome = enum { ok, cancelled, failed };

const max_attempts = 3;

const Job = struct {
    parent: ?*gtk.Window,
    reason: [:0]u8,
    argv: [][:0]u8,
    stdin_data: []u8,
    attempts: usize = 0,
    callback: *const fn (*anyopaque, *const anyopaque, Outcome, []const u8) void,
    /// The caller's own typed callback, which `callback` adapts.
    target: *const anyopaque,
    data: *anyopaque,
    window: ?*gtk.Window = null,
    entry: ?*gtk.PasswordEntry = null,
    message: ?*gtk.Label = null,
    /// While a child runs: the file its errors go to, and its pid.
    stderr_fd: c_int = -1,
    pid: glib.Pid = 0,
    running: bool = false,
    /// The running attempt is the one without a password (`sudo -n`).
    probing: bool = false,
    /// The password, from that attempt until the one that may need it.
    secret: ?[]u8 = null,
    /// runCapture: the command's output goes to this temporary file (a
    /// file, not a pipe, so a long output cannot stall the command).
    capture: bool = false,
    out_fd: c_int = -1,
    /// The unlock job: keep the password as the unlocked session's when it is accepted.
    remember: bool = false,
    /// The password came from the unlocked session, so a refusal means it changed: lock and ask again.
    from_session: bool = false,
};

// ---- the unlocked session -------------------------------------------------
//
// A padlock on the pages that need an administrator: unlocked once, the password is kept in this program's
// memory (never written anywhere) and used for every action until it is locked again, by the padlock, after
// `idle_seconds` without an action, or when the program ends. Each program has its own lock.

const gpa = std.heap.c_allocator;
/// How long the unlocked session lasts after the last action: `[security] unlock-minutes` in dkde.toml
/// (Settings > Accounts > User), 0 meaning until the program closes. Read each time the lock opens.
var idle_seconds: c_uint = 300;

fn readIdleSeconds() void {
    var cfg = core.Config.load(gpa, "dkde.toml") catch return;
    defer cfg.deinit();
    const minutes = cfg.getInt("security", "unlock-minutes", 5);
    idle_seconds = @intCast(std.math.clamp(minutes, 0, 1440) * 60);
}

var session_password: ?[]u8 = null;
var idle_timer: c_uint = 0;

const Padlock = struct { button: *gtk.Button, parent: ?*gtk.Window };
var padlocks: std.ArrayList(Padlock) = .empty;
const Listener = struct { callback: *const fn (?*anyopaque) void, data: ?*anyopaque };
var listeners: std.ArrayList(Listener) = .empty;

pub fn isUnlocked() bool {
    return session_password != null;
}

/// `callback(data)` runs whenever the lock opens or closes.
pub fn onChange(callback: *const fn (?*anyopaque) void, data: ?*anyopaque) void {
    listeners.append(gpa, .{ .callback = callback, .data = data }) catch {};
}

pub fn removeListener(callback: *const fn (?*anyopaque) void, data: ?*anyopaque) void {
    var i: usize = 0;
    while (i < listeners.items.len) {
        if (listeners.items[i].callback == callback and listeners.items[i].data == data) _ = listeners.orderedRemove(i) else i += 1;
    }
}

fn changed() void {
    for (padlocks.items) |p| paintPadlock(p.button);
    for (listeners.items) |l| l.callback(l.data);
}

fn restartIdle() void {
    if (idle_timer != 0) _ = glib.Source.remove(idle_timer);
    idle_timer = 0;
    if (idle_seconds == 0) return;
    idle_timer = glib.timeoutAddSeconds(idle_seconds, onIdle, null);
}

fn onIdle(_: ?*anyopaque) callconv(.c) c_int {
    idle_timer = 0;
    lock();
    return 0;
}

pub fn lock() void {
    if (idle_timer != 0) _ = glib.Source.remove(idle_timer);
    idle_timer = 0;
    if (session_password) |p| {
        @memset(p, 0);
        gpa.free(p);
        session_password = null;
        changed();
    }
}

var unlock_data: u8 = 0;

fn unlockDone(_: *u8, _: Outcome, _: []const u8) void {}

/// Asks for the password once and keeps it for the session.
pub fn unlock(parent: ?*gtk.Window) void {
    if (isUnlocked()) return;
    const job = makeJob(parent, tr("Unlock administrator actions. The password is kept only in this program, until it is locked again (Settings > Accounts sets how long after the last action)."), &.{"true"}, "", false, u8, unlockDone, &unlock_data) orelse return;
    job.remember = true;
    prompt(job, null);
}

fn paintPadlock(button: *gtk.Button) void {
    const open = isUnlocked();
    button.setIconName(if (open) "changes-allow-symbolic" else "changes-prevent-symbolic");
    button.as(gtk.Widget).setTooltipText(if (open) tr("Unlocked: administrator actions run without asking. Click to lock.") else tr("Locked: click to unlock administrator actions once, instead of typing the password for each."));
    if (open) button.as(gtk.Widget).addCssClass("suggested-action") else button.as(gtk.Widget).removeCssClass("suggested-action");
}

fn onPadlock(button: *gtk.Button, parent: ?*gtk.Window) callconv(.c) void {
    _ = button;
    if (isUnlocked()) return lock();
    unlock(parent);
}

fn onPadlockGone(widget: *gtk.Button, _: ?*anyopaque) callconv(.c) void {
    var i: usize = 0;
    while (i < padlocks.items.len) : (i += 1) {
        if (padlocks.items[i].button == widget) {
            _ = padlocks.swapRemove(i);
            return;
        }
    }
}

/// The padlock button for a page's command bar: shows locked or unlocked, and toggles.
pub fn padlock(parent: ?*gtk.Window) *gtk.Button {
    const button = gtk.Button.new();
    button.setHasFrame(0);
    paintPadlock(button);
    _ = gtk.Button.signals.clicked.connect(button, ?*gtk.Window, &onPadlock, parent, .{});
    _ = gtk.Widget.signals.destroy.connect(button, ?*anyopaque, &onPadlockGone, null, .{});
    padlocks.append(gpa, .{ .button = button, .parent = parent }) catch {};
    return button;
}

extern fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern fn memfd_create(name: [*:0]const u8, flags: c_uint) c_int;
const mfd_cloexec = 1;
extern fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern fn close(fd: c_int) c_int;
extern fn lseek(fd: c_int, offset: i64, whence: c_int) i64;

/// Asks for the password and runs `argv` as root. `callback(data, outcome,
/// message)` runs once: `message` is sudo's or the command's error text when
/// the outcome is `.failed`.
pub fn run(
    parent: ?*gtk.Window,
    reason: []const u8,
    argv: []const []const u8,
    stdin_data: []const u8,
    comptime Data: type,
    callback: *const fn (*Data, Outcome, []const u8) void,
    data: *Data,
) void {
    start(parent, reason, argv, stdin_data, false, Data, callback, data);
}

/// Like `run`, for a command whose output is wanted (a list, a log): on
/// `.ok`, `message` is what it printed (at most a megabyte).
pub fn runCapture(
    parent: ?*gtk.Window,
    reason: []const u8,
    argv: []const []const u8,
    comptime Data: type,
    callback: *const fn (*Data, Outcome, []const u8) void,
    data: *Data,
) void {
    start(parent, reason, argv, "", true, Data, callback, data);
}

/// `runCapture` with `stdin_data` written to the command's standard input.
pub fn runInputCapture(
    parent: ?*gtk.Window,
    reason: []const u8,
    argv: []const []const u8,
    stdin_data: []const u8,
    comptime Data: type,
    callback: *const fn (*Data, Outcome, []const u8) void,
    data: *Data,
) void {
    start(parent, reason, argv, stdin_data, true, Data, callback, data);
}

fn start(
    parent: ?*gtk.Window,
    reason: []const u8,
    argv: []const []const u8,
    stdin_data: []const u8,
    capture: bool,
    comptime Data: type,
    callback: *const fn (*Data, Outcome, []const u8) void,
    data: *Data,
) void {
    const job = makeJob(parent, reason, argv, stdin_data, capture, Data, callback, data) orelse return;
    // Unlocked: no dialog. If sudo refuses the kept password (it changed), the lock closes and the dialog comes.
    if (session_password) |pw| {
        job.from_session = true;
        restartIdle();
        return attempt(job, pw);
    }
    prompt(job, null);
}

fn makeJob(
    parent: ?*gtk.Window,
    reason: []const u8,
    argv: []const []const u8,
    stdin_data: []const u8,
    capture: bool,
    comptime Data: type,
    callback: *const fn (*Data, Outcome, []const u8) void,
    data: *Data,
) ?*Job {
    const a = std.heap.c_allocator;
    const job = a.create(Job) catch return null;
    const Thunk = struct {
        fn call(raw: *anyopaque, target: *const anyopaque, outcome: Outcome, message: []const u8) void {
            const f: *const fn (*Data, Outcome, []const u8) void = @ptrCast(@alignCast(target));
            f(@ptrCast(@alignCast(raw)), outcome, message);
        }
    };

    const owned_argv = a.alloc([:0]u8, argv.len) catch return null;
    for (argv, 0..) |arg, i| owned_argv[i] = a.dupeSentinel(u8, arg, 0) catch return null;
    job.* = .{
        .parent = parent,
        .reason = a.dupeSentinel(u8, reason, 0) catch return null,
        .argv = owned_argv,
        .stdin_data = a.dupe(u8, stdin_data) catch return null,
        .callback = Thunk.call,
        .target = @ptrCast(callback),
        .data = data,
        .capture = capture,
    };
    watchParent(job);
    return job;
}

/// The password dialog may open after the window that asked for it has gone.
fn watchParent(job: *Job) void {
    if (job.parent) |p| p.as(gobject.Object).addWeakPointer(@ptrCast(&job.parent));
}

fn unwatchParent(job: *Job) void {
    if (job.parent) |p| p.as(gobject.Object).removeWeakPointer(@ptrCast(&job.parent));
}

fn forgetSecret(job: *Job) void {
    if (job.secret) |s| {
        @memset(s, 0);
        gpa.free(s);
        job.secret = null;
    }
}

fn finish(job: *Job, outcome: Outcome, message: []const u8) void {
    const a = std.heap.c_allocator;
    const callback = job.callback;
    const target = job.target;
    const data = job.data;
    unwatchParent(job);
    if (job.window) |w| w.destroy();
    forgetSecret(job);
    if (job.out_fd >= 0) _ = close(job.out_fd);
    @memset(job.stdin_data, 0); // it may hold a new account's password
    a.free(job.stdin_data);
    for (job.argv) |arg| a.free(arg);
    a.free(job.argv);
    a.free(job.reason);
    a.destroy(job);
    callback(data, target, outcome, message);
}

// ---- the password dialog -------------------------------------------------

fn prompt(job: *Job, problem: ?[:0]const u8) void {
    if (job.window) |w| w.destroy();

    const window = gtk.Window.new();
    window.setTitle(tr("Administrator password"));
    window.setModal(1);
    dialogs.closeOnEscape(window);
    window.setResizable(0);
    window.setDefaultSize(380, -1);
    if (job.parent) |p| window.setTransientFor(p);
    window.as(gtk.Widget).addCssClass("dkde");

    const box = gtk.Box.new(.vertical, 10);
    box.as(gtk.Widget).setMarginTop(16);
    box.as(gtk.Widget).setMarginBottom(16);
    box.as(gtk.Widget).setMarginStart(16);
    box.as(gtk.Widget).setMarginEnd(16);
    window.setChild(box.as(gtk.Widget));

    const heading = gtk.Label.new(tr("Authentication required"));
    heading.setXalign(0);
    heading.as(gtk.Widget).addCssClass("heading");
    box.append(heading.as(gtk.Widget));
    const reason = gtk.Label.new(job.reason);
    reason.setXalign(0);
    reason.setWrap(1);
    box.append(reason.as(gtk.Widget));

    const entry = gtk.PasswordEntry.new();
    entry.setShowPeekIcon(1);
    entry.as(gtk.Widget).setHexpand(1);
    box.append(entry.as(gtk.Widget));

    const message = gtk.Label.new(problem orelse "");
    message.setXalign(0);
    message.as(gtk.Widget).addCssClass("error");
    box.append(message.as(gtk.Widget));

    const buttons = gtk.Box.new(.horizontal, 8);
    buttons.as(gtk.Widget).setHalign(.end);
    const cancel = gtk.Button.newWithLabel(tr("Cancel"));
    const ok = gtk.Button.newWithLabel(tr("Authenticate"));
    ok.as(gtk.Widget).addCssClass("suggested-action");
    buttons.append(cancel.as(gtk.Widget));
    buttons.append(ok.as(gtk.Widget));
    box.append(buttons.as(gtk.Widget));

    job.window = window;
    job.entry = entry;
    job.message = message;
    _ = gtk.Button.signals.clicked.connect(ok, *Job, &onOk, job, .{});
    _ = gtk.Button.signals.clicked.connect(cancel, *Job, &onCancel, job, .{});
    _ = gtk.PasswordEntry.signals.activate.connect(entry, *Job, &onEntryActivate, job, .{});
    _ = gtk.Window.signals.close_request.connect(window, *Job, &onClose, job, .{});

    window.present();
    _ = entry.as(gtk.Widget).grabFocus();
}

fn onOk(_: *gtk.Button, job: *Job) callconv(.c) void {
    submit(job);
}

fn onEntryActivate(_: *gtk.PasswordEntry, job: *Job) callconv(.c) void {
    submit(job);
}

// Once a command is running it cannot be called back, and `onChildExit` still
// holds the job: only that ends it then.

fn onCancel(_: *gtk.Button, job: *Job) callconv(.c) void {
    if (!job.running) finish(job, .cancelled, "");
}

fn onClose(_: *gtk.Window, job: *Job) callconv(.c) c_int {
    if (!job.running) finish(job, .cancelled, "");
    return 1;
}

fn submit(job: *Job) void {
    const entry = job.entry orelse return;
    const text = std.mem.span(entry.as(gtk.Editable).getText());
    if (text.len == 0) return;
    job.attempts += 1;
    attempt(job, text);
}

// ---- running sudo ---------------------------------------------------------

/// The sudo to run; the tests name their stand-in by its full path.
var sudo_program: []const u8 = "sudo";

/// Between the password and a shell command's input: the shell discards
/// everything up to it, so a password sudo did not read goes no further.
const input_marker = "dkde-input-6f1c3a9e5b2d4870";
const skip_to_marker = "while IFS= read -r line; do [ \"$line\" = \"$0\" ] && break; done; exec \"$@\"";

/// Runs the job with `password`: first without it, in case sudo wants none.
fn attempt(job: *Job, password: []const u8) void {
    if (job.running) return;
    forgetSecret(job);
    job.secret = gpa.dupe(u8, password) catch return finish(job, .failed, "out of memory");
    job.probing = true;
    spawnSudo(job);
}

/// A file in memory holding `parts`, read from its start.
fn inputFile(parts: []const []const u8) c_int {
    const fd = memfd_create("dkde-input", mfd_cloexec);
    if (fd < 0) return -1;
    for (parts) |part| {
        var rest = part;
        while (rest.len > 0) {
            const n = write(fd, rest.ptr, rest.len);
            if (n <= 0) {
                _ = close(fd);
                return -1;
            }
            rest = rest[@intCast(n)..];
        }
    }
    _ = lseek(fd, 0, 0);
    return fd;
}

/// An open file with no name.
fn scratchFile() c_int {
    var name: [*:0]u8 = undefined;
    const fd = glib.fileOpenTmp("dkde-elevate-XXXXXX", &name, null);
    if (fd >= 0) {
        // Only the descriptor is needed; nobody else can open the file.
        _ = glib.unlink(name);
        glib.free(name);
    }
    return fd;
}

fn spawnSudo(job: *Job) void {
    const a = std.heap.c_allocator;
    const password = job.secret orelse "";
    const marked = !job.probing and job.stdin_data.len > 0 and job.argv.len > 0 and std.mem.eql(u8, job.argv[0], "sh");

    var words: std.ArrayList([]const u8) = .empty;
    defer words.deinit(a);
    const options: []const []const u8 = if (job.probing) &.{ "-k", "-n", "--" } else &.{ "-S", "-k", "-p", "", "--" };
    words.append(a, sudo_program) catch return finish(job, .failed, "out of memory");
    words.appendSlice(a, options) catch return finish(job, .failed, "out of memory");
    if (marked) words.appendSlice(a, &.{ "sh", "-c", skip_to_marker, input_marker }) catch return finish(job, .failed, "out of memory");
    for (job.argv) |arg| words.append(a, arg) catch return finish(job, .failed, "out of memory");

    const argv = a.alloc(?[*:0]u8, words.items.len + 1) catch return finish(job, .failed, "out of memory");
    defer a.free(argv);
    var made: usize = 0;
    defer for (argv[0..made]) |p| a.free(std.mem.span(p.?));
    for (words.items) |word| {
        argv[made] = (a.dupeSentinel(u8, word, 0) catch return finish(job, .failed, "out of memory")).ptr;
        made += 1;
    }
    argv[made] = null;

    // sudo's messages are matched below, so ask for them in English.
    var envp = glib.getEnviron();
    envp = glib.environSetenv(envp, "LC_ALL", "C", 1);
    envp = glib.environSetenv(envp, "LANGUAGE", "C", 1);
    defer glib.strfreev(envp);

    // The password line comes first, and only for the attempt that asks for one.
    const parts: []const []const u8 = if (job.probing)
        &.{job.stdin_data}
    else if (marked)
        &.{ password, "\n", input_marker, "\n", job.stdin_data }
    else
        &.{ password, "\n", job.stdin_data };
    const stdin_fd = inputFile(parts);
    if (stdin_fd < 0) return finish(job, .failed, "cannot pass the command its input");
    defer _ = close(stdin_fd);

    if (job.capture and job.out_fd < 0) job.out_fd = scratchFile();
    if (job.capture and job.out_fd < 0) return finish(job, .failed, "cannot make a temporary file");
    if (job.capture) {
        _ = ftruncate(job.out_fd, 0);
        _ = lseek(job.out_fd, 0, 0);
    }
    job.stderr_fd = scratchFile();
    if (job.stderr_fd < 0) return finish(job, .failed, "cannot make a temporary file");

    var err: ?*glib.Error = null;
    const spawned = glib.spawnAsyncWithPipesAndFds(
        null,
        @ptrCast(argv.ptr),
        @ptrCast(envp),
        .{ .search_path = true, .do_not_reap_child = true, .stdout_to_dev_null = !job.capture },
        null,
        null,
        stdin_fd,
        if (job.capture) job.out_fd else -1,
        job.stderr_fd,
        null,
        null,
        0,
        &job.pid,
        null,
        null,
        null,
        &err,
    );
    if (spawned == 0) {
        _ = close(job.stderr_fd);
        const message = if (err) |e| e.f_message orelse "cannot start sudo" else "cannot start sudo";
        const text = std.heap.c_allocator.dupe(u8, std.mem.span(message)) catch "cannot start sudo";
        if (err) |e| e.free();
        return finish(job, .failed, text);
    }
    job.running = true;
    // The question has been answered; do not leave it in front while the command runs.
    if (job.window) |w| w.as(gtk.Widget).setVisible(0);
    _ = glib.childWatchAdd(job.pid, onChildExit, job);
}

extern fn ftruncate(fd: c_int, length: i64) c_int;

/// The last of what was written to `fd`, into `buf`.
fn readTail(fd: c_int, buf: []u8) []const u8 {
    const size = lseek(fd, 0, 2);
    if (size <= 0) return buf[0..0];
    const n: usize = @min(buf.len, @as(usize, @intCast(size)));
    _ = lseek(fd, size - @as(i64, @intCast(n)), 0);
    var got: usize = 0;
    while (got < n) {
        const r = read(fd, buf[got..].ptr, n - got);
        if (r <= 0) break;
        got += @intCast(r);
    }
    return buf[0..got];
}

/// Whether `sudo -n` gave up, without running the command, because it needs to
/// authenticate. Both sudo and sudo-rs say so on a line of their own.
fn wantsPassword(errors: []const u8) bool {
    var lines = std.mem.splitScalar(u8, errors, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "sudo:") and !std.mem.startsWith(u8, line, "sudo-rs:")) continue;
        for ([_][]const u8{ "a password is required", "authentication is required", "a terminal is required" }) |phrase| {
            if (std.mem.find(u8, line, phrase) != null) return true;
        }
    }
    return false;
}

fn onChildExit(pid: glib.Pid, status: c_int, data: ?*anyopaque) callconv(.c) void {
    const job: *Job = @ptrCast(@alignCast(data.?));
    glib.spawnClosePid(pid);
    job.running = false;

    var buf: [4096]u8 = undefined;
    const stderr_text = std.mem.trim(u8, readTail(job.stderr_fd, &buf), " \t\r\n");
    _ = close(job.stderr_fd);

    if (job.probing and status != 0 and wantsPassword(stderr_text)) {
        job.probing = false;
        return spawnSudo(job);
    }

    if (status == 0) {
        // The unlock job: sudo took the password, so the session keeps it.
        if (job.remember) {
            if (job.secret) |s| {
                if (session_password) |old| {
                    @memset(old, 0);
                    gpa.free(old);
                }
                session_password = s;
                job.secret = null;
                readIdleSeconds();
                restartIdle();
                changed();
            }
        }
        if (job.capture and job.out_fd >= 0) {
            const a = std.heap.c_allocator;
            const size = lseek(job.out_fd, 0, 2);
            const out = a.alloc(u8, @intCast(std.math.clamp(size, 0, 1024 * 1024))) catch return finish(job, .ok, "");
            defer a.free(out);
            return finish(job, .ok, readTail(job.out_fd, out));
        }
        return finish(job, .ok, "");
    }

    const wrong = !job.probing and (std.ascii.findIgnoreCase(stderr_text, "incorrect password") != null or
        std.ascii.findIgnoreCase(stderr_text, "sorry, try again") != null or
        std.ascii.findIgnoreCase(stderr_text, "authentication failure") != null);
    if (wrong and job.from_session) {
        // The kept password no longer works: close the lock and ask for it again.
        job.from_session = false;
        lock();
        return prompt(job, tr("The password was not accepted. Enter it again."));
    }
    if (wrong and job.attempts < max_attempts) {
        return prompt(job, tr("Wrong password. Try again."));
    }
    if (wrong) return finish(job, .failed, "Wrong password.");

    // Report the last line: sudo and the tools print the useful part there.
    const line_start = if (std.mem.lastIndexOfScalar(u8, stderr_text, '\n')) |i| i + 1 else 0;
    const text = stderr_text[line_start..];
    finish(job, .failed, if (text.len > 0) text else "the command failed");
}

const TestResult = struct {
    loop: *glib.MainLoop,
    outcome: Outcome = .cancelled,
    message: [256]u8 = undefined,
    message_len: usize = 0,

    fn done(self: *TestResult, outcome: Outcome, message: []const u8) void {
        self.outcome = outcome;
        self.message_len = @min(message.len, self.message.len);
        @memcpy(self.message[0..self.message_len], message[0..self.message_len]);
        self.loop.quit();
    }
};

/// A stand-in sudo. With no policy file it asks for the password "secret" like
/// a normal rule; run with `free` it asks for nothing, like `NOPASSWD`.
const fake_sudo =
    \\#!/bin/sh
    \\ask=yes
    \\case $0 in *-free) ask=no ;; esac
    \\if [ "$2" = -n ]; then
    \\    shift 3
    \\    [ $ask = no ] && exec "$@"
    \\    echo "sudo: interactive authentication is required" >&2
    \\    exit 1
    \\fi
    \\shift 5
    \\if [ $ask = yes ]; then
    \\    IFS= read -r pw
    \\    if [ "$pw" != "secret" ]; then echo "Sorry, try again." >&2; exit 1; fi
    \\fi
    \\exec "$@"
    \\
;

/// As `fake_sudo`, but `-n` refuses even though no password is then read: a
/// module that lets the user in without one.
const forgetful_sudo =
    \\#!/bin/sh
    \\if [ "$2" = -n ]; then echo "sudo: a password is required" >&2; exit 1; fi
    \\shift 5
    \\exec "$@"
    \\
;

const Rule = enum { password, free, forgetful };

/// Runs `attempt` against a stand-in sudo, so the real file and exit-status
/// handling is exercised. It is named by its full path: a search of PATH would
/// go on to the real sudo if the stand-in could not be run.
fn runFake(rule: Rule, password: []const u8, stdin_data: []const u8, command: []const []const u8, attempts: usize, capture: bool) !TestResult {
    const a = std.heap.c_allocator;
    const dir = glib.Dir.makeTmp("dkde-elevate-XXXXXX", null) orelse return error.NoTmp;
    defer glib.free(dir);
    defer _ = std.c.rmdir(dir);

    const script_path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/sudo{s}", .{ std.mem.span(dir), if (rule == .free) "-free" else "" }, 0);
    defer std.testing.allocator.free(script_path);
    const script: []const u8 = if (rule == .forgetful) forgetful_sudo else fake_sudo;
    if (glib.fileSetContents(script_path, script.ptr, @intCast(script.len), null) == 0) return error.WriteFailed;
    defer _ = std.c.unlink(script_path);
    if (std.c.chmod(script_path, 0o755) != 0) return error.ChmodFailed;
    if (glib.fileTest(script_path, .{ .is_executable = true }) == 0) return error.NotExecutable;

    sudo_program = script_path;
    // Never left naming the real one while a test might run.
    defer sudo_program = "/nonexistent/sudo";

    var result: TestResult = .{ .loop = glib.MainLoop.new(null, 0) };
    defer result.loop.unref();

    const argv = try a.alloc([:0]u8, command.len);
    for (command, 0..) |c, i| argv[i] = try a.dupeSentinel(u8, c, 0);
    const job = try a.create(Job);
    job.* = .{
        .parent = null,
        .reason = try a.dupeSentinel(u8, "test", 0),
        .argv = argv,
        .stdin_data = try a.dupe(u8, stdin_data),
        .attempts = attempts,
        .callback = struct {
            fn cb(raw: *anyopaque, _: *const anyopaque, outcome: Outcome, message: []const u8) void {
                const r: *TestResult = @ptrCast(@alignCast(raw));
                r.done(outcome, message);
            }
        }.cb,
        .target = undefined,
        .data = &result,
        .capture = capture,
    };
    attempt(job, password);
    result.loop.run();
    return result;
}

test "the right password runs the command and passes stdin through" {
    // The command succeeds only if it received the data and nothing before it.
    const r = try runFake(.password, "secret", "newpw\n", &.{ "sh", "-c", "read -r x; test \"$x\" = newpw" }, 1, false);
    try std.testing.expectEqual(Outcome.ok, r.outcome);
}

test "a password sudo does not ask for never reaches the command" {
    for ([_]Rule{ .password, .free, .forgetful }) |rule| {
        // What a root `cat > file` would save is the data and nothing else.
        const r = try runFake(rule, "secret", "real file content\n", &.{ "sh", "-c", "cat" }, 1, true);
        try std.testing.expectEqual(Outcome.ok, r.outcome);
        try std.testing.expectEqualStrings("real file content\n", r.message[0..r.message_len]);
    }
    // A program run as administrator, with no input of its own.
    for ([_]Rule{ .password, .free }) |rule| {
        const r = try runFake(rule, "secret", "", &.{"cat"}, 1, true);
        try std.testing.expectEqual(Outcome.ok, r.outcome);
        try std.testing.expectEqualStrings("", r.message[0..r.message_len]);
    }
}

test "a command may print freely, to either output" {
    const noisy = "i=0; while [ $i -lt 4000 ]; do echo 'a line of ordinary output from a tool'; echo 'a warning of the same sort' >&2; i=$((i+1)); done; ";
    const ok = try runFake(.password, "secret", "", &.{ "sh", "-c", noisy ++ "echo done > /dev/null" }, 1, false);
    try std.testing.expectEqual(Outcome.ok, ok.outcome);
    // The last line is the one reported, however much came before it.
    const bad = try runFake(.password, "secret", "", &.{ "sh", "-c", noisy ++ "echo 'mkfs: it broke' >&2; exit 1" }, 1, false);
    try std.testing.expectEqual(Outcome.failed, bad.outcome);
    try std.testing.expectEqualStrings("mkfs: it broke", bad.message[0..bad.message_len]);
}

test "a program left behind does not hold up the answer" {
    const started = glib.getMonotonicTime();
    const r = try runFake(.password, "secret", "", &.{ "sh", "-c", "sleep 5 & exit 0" }, 1, false);
    try std.testing.expectEqual(Outcome.ok, r.outcome);
    try std.testing.expect(glib.getMonotonicTime() - started < 3 * std.time.us_per_s);
}

test "a command that fails without a password is not run twice" {
    const r = try runFake(.free, "secret", "", &.{ "sh", "-c", "echo 'tool: a password is required for this volume' >&2; exit 2" }, 1, false);
    try std.testing.expectEqual(Outcome.failed, r.outcome);
    try std.testing.expectEqualStrings("tool: a password is required for this volume", r.message[0..r.message_len]);
    try std.testing.expect(wantsPassword("sudo: a password is required"));
    try std.testing.expect(wantsPassword("sudo-rs: interactive authentication is required"));
    try std.testing.expect(!wantsPassword("tool: a password is required"));
}

test "a wrong password is reported once attempts run out" {
    const r = try runFake(.password, "nope", "", &.{"true"}, max_attempts, false);
    try std.testing.expectEqual(Outcome.failed, r.outcome);
    try std.testing.expect(std.ascii.findIgnoreCase(r.message[0..r.message_len], "wrong password") != null);
}

test "a failing command reports its last error line" {
    const r = try runFake(.password, "secret", "", &.{ "sh", "-c", "echo first >&2; echo useradd: user exists >&2; exit 9" }, 1, false);
    try std.testing.expectEqual(Outcome.failed, r.outcome);
    try std.testing.expectEqualStrings("useradd: user exists", r.message[0..r.message_len]);
}
