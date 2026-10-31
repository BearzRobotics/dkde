//! Running something as administrator from a dkde app (SPEC.md 5.5, 5.7).
//!
//! There is no polkit agent or D-Bus in a dkde session, so this asks for the
//! user's password in a small dialog of its own and runs the command through
//! `sudo -S`. The password goes straight to sudo's stdin and is wiped from
//! memory afterwards; it is never put on a command line or in the
//! environment. `-k` makes sudo always ask, so a cached ticket cannot make it
//! mistake the first stdin line for command input.
//!
//! Anything the command should read from stdin is passed in `stdin_data`
//! and arrives after the password line.

const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");

const tr = @import("i18n.zig").tr;

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
    /// Read end of the child's stderr and its pid while it runs.
    stderr_fd: c_int = -1,
    pid: glib.Pid = 0,
};

extern fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern fn close(fd: c_int) c_int;

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
    const a = std.heap.c_allocator;
    const job = a.create(Job) catch return;
    const Thunk = struct {
        fn call(raw: *anyopaque, target: *const anyopaque, outcome: Outcome, message: []const u8) void {
            const f: *const fn (*Data, Outcome, []const u8) void = @ptrCast(@alignCast(target));
            f(@ptrCast(@alignCast(raw)), outcome, message);
        }
    };

    const owned_argv = a.alloc([:0]u8, argv.len) catch return;
    for (argv, 0..) |arg, i| owned_argv[i] = a.dupeSentinel(u8, arg, 0) catch return;
    job.* = .{
        .parent = parent,
        .reason = a.dupeSentinel(u8, reason, 0) catch return,
        .argv = owned_argv,
        .stdin_data = a.dupe(u8, stdin_data) catch return,
        .callback = Thunk.call,
        .target = @ptrCast(callback),
        .data = data,
    };
    prompt(job, null);
}

fn finish(job: *Job, outcome: Outcome, message: []const u8) void {
    const a = std.heap.c_allocator;
    const callback = job.callback;
    const target = job.target;
    const data = job.data;
    if (job.window) |w| w.destroy();
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

fn onCancel(_: *gtk.Button, job: *Job) callconv(.c) void {
    finish(job, .cancelled, "");
}

fn onClose(_: *gtk.Window, job: *Job) callconv(.c) c_int {
    finish(job, .cancelled, "");
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

fn attempt(job: *Job, password: []const u8) void {
    const a = std.heap.c_allocator;

    const prefix = [_][]const u8{ "sudo", "-S", "-k", "-p", "", "--" };
    const argv = a.alloc(?[*:0]u8, prefix.len + job.argv.len + 1) catch return finish(job, .failed, "out of memory");
    defer a.free(argv);
    var made: usize = 0;
    defer for (argv[0..made]) |p| a.free(std.mem.span(p.?));
    for (prefix) |p| {
        argv[made] = (a.dupeSentinel(u8, p, 0) catch return finish(job, .failed, "out of memory")).ptr;
        made += 1;
    }
    for (job.argv) |arg| {
        argv[made] = (a.dupeSentinel(u8, arg, 0) catch return finish(job, .failed, "out of memory")).ptr;
        made += 1;
    }
    argv[made] = null;

    // sudo's messages are matched below, so ask for them in English.
    var envp = glib.getEnviron();
    envp = glib.environSetenv(envp, "LC_ALL", "C", 1);
    envp = glib.environSetenv(envp, "LANGUAGE", "C", 1);
    defer glib.strfreev(envp);

    var stdin_fd: c_int = -1;
    var stdout_fd: c_int = -1;
    var stderr_fd: c_int = -1;
    var err: ?*glib.Error = null;
    if (glib.spawnAsyncWithPipes(
        null,
        @ptrCast(argv.ptr),
        envp,
        .{ .search_path = true, .do_not_reap_child = true },
        null,
        null,
        &job.pid,
        &stdin_fd,
        &stdout_fd,
        &stderr_fd,
        &err,
    ) == 0) {
        const message = if (err) |e| e.f_message orelse "cannot start sudo" else "cannot start sudo";
        const text = std.heap.c_allocator.dupe(u8, std.mem.span(message)) catch "cannot start sudo";
        if (err) |e| e.free();
        return finish(job, .failed, text);
    }
    _ = close(stdout_fd);
    job.stderr_fd = stderr_fd;

    // Password line first, then whatever the command should read.
    writeAll(stdin_fd, password);
    writeAll(stdin_fd, "\n");
    writeAll(stdin_fd, job.stdin_data);
    _ = close(stdin_fd);

    if (job.window) |w| w.as(gtk.Widget).setSensitive(0);
    _ = glib.childWatchAdd(job.pid, onChildExit, job);
}

fn writeAll(fd: c_int, bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = write(fd, rest.ptr, rest.len);
        if (n <= 0) return;
        rest = rest[@intCast(n)..];
    }
}

fn onChildExit(pid: glib.Pid, status: c_int, data: ?*anyopaque) callconv(.c) void {
    const job: *Job = @ptrCast(@alignCast(data.?));
    glib.spawnClosePid(pid);

    // The child is gone, so reading to the end cannot block.
    var buf: [2048]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        const n = read(job.stderr_fd, buf[len..].ptr, buf.len - len);
        if (n <= 0) break;
        len += @intCast(n);
    }
    _ = close(job.stderr_fd);
    const stderr_text = std.mem.trim(u8, buf[0..len], " \t\r\n");

    if (status == 0) return finish(job, .ok, "");

    const wrong = std.ascii.findIgnoreCase(stderr_text, "incorrect password") != null or
        std.ascii.findIgnoreCase(stderr_text, "sorry, try again") != null or
        std.ascii.findIgnoreCase(stderr_text, "authentication failure") != null;
    if (wrong and job.attempts < max_attempts) {
        if (job.window) |w| w.as(gtk.Widget).setSensitive(1);
        return prompt(job, tr("Wrong password. Try again."));
    }
    if (wrong) return finish(job, .failed, "Wrong password.");

    // Report the last line: sudo and the tools print the useful part there.
    const line_start = if (std.mem.lastIndexOfScalar(u8, stderr_text, '\n')) |i| i + 1 else 0;
    const text = std.heap.c_allocator.dupe(u8, stderr_text[line_start..]) catch "the command failed";
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

/// Runs `attempt` against a stand-in `sudo` that accepts the password
/// "secret", so the real pipe and exit-status handling is exercised.
fn runFake(password: []const u8, stdin_data: []const u8, command: []const []const u8, attempts: usize) !TestResult {
    const a = std.heap.c_allocator;
    const dir = glib.Dir.makeTmp("dkde-elevate-XXXXXX", null) orelse return error.NoTmp;
    defer glib.free(dir);

    const script_path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/sudo", .{std.mem.span(dir)}, 0);
    defer std.testing.allocator.free(script_path);
    const script =
        \\#!/bin/sh
        \\IFS= read -r pw
        \\if [ "$pw" != "secret" ]; then echo "Sorry, try again." >&2; exit 1; fi
        \\shift 5
        \\exec "$@"
        \\
    ;
    if (glib.fileSetContents(script_path, script.ptr, script.len, null) == 0) return error.WriteFailed;
    _ = std.c.chmod(script_path, 0o755);
    defer _ = std.c.unlink(script_path);

    const old = glib.getenv("PATH");
    const new_path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}:{s}", .{ std.mem.span(dir), if (old) |o| std.mem.span(o) else "/usr/bin:/bin" }, 0);
    defer std.testing.allocator.free(new_path);
    _ = glib.setenv("PATH", new_path, 1);
    defer if (old) |o| {
        _ = glib.setenv("PATH", o, 1);
    };

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
    };
    attempt(job, password);
    result.loop.run();
    return result;
}

test "the right password runs the command and passes stdin through" {
    // The command succeeds only if it received the data after the password line.
    const r = try runFake("secret", "newpw\n", &.{ "sh", "-c", "read -r x; test \"$x\" = newpw" }, 1);
    try std.testing.expectEqual(Outcome.ok, r.outcome);
}

test "a wrong password is reported once attempts run out" {
    const r = try runFake("nope", "", &.{"true"}, max_attempts);
    try std.testing.expectEqual(Outcome.failed, r.outcome);
    try std.testing.expect(std.ascii.findIgnoreCase(r.message[0..r.message_len], "wrong password") != null);
}

test "a failing command reports its last error line" {
    const r = try runFake("secret", "", &.{ "sh", "-c", "echo first >&2; echo useradd: user exists >&2; exit 9" }, 1);
    try std.testing.expectEqual(Outcome.failed, r.outcome);
    try std.testing.expectEqualStrings("useradd: user exists", r.message[0..r.message_len]);
}
