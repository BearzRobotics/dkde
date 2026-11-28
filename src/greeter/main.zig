// SPDX-License-Identifier: GPL-2.0-or-later
//! dkde-greeter: the login screen (SPEC.md 5.10). greetd runs it, under a
//! kiosk labwc, as an unprivileged user. It asks greetd to authenticate the
//! chosen account and, on success, to start the dkde session.

const std = @import("std");
const cli = @import("cli");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

const greetd = @import("greetd.zig");

/// One login-manager session entry (share/wayland-sessions or share/xsessions).
const Session = struct {
    name: [:0]u8,
    /// The Exec line, run through `sh -c`.
    exec: [:0]u8,
    x11: bool,
    file: []u8,
};

const session_dirs = [_]struct { dir: []const u8, x11: bool }{
    .{ .dir = "/usr/share/wayland-sessions", .x11 = false },
    .{ .dir = "/usr/local/share/wayland-sessions", .x11 = false },
    .{ .dir = "/usr/share/xsessions", .x11 = true },
    .{ .dir = "/usr/local/share/xsessions", .x11 = true },
};

/// Remembers the last session chosen, when the greeter's account may write it.
const last_session_file = "/var/cache/dkde-greeter/last-session";

const Greeter = struct {
    allocator: std.mem.Allocator,
    window: *gtk.ApplicationWindow,
    users: *gtk.DropDown,
    names: std.ArrayList([:0]u8) = .empty,
    sessions_box: *gtk.DropDown,
    sessions: std.ArrayList(Session) = .empty,
    password: *gtk.PasswordEntry,
    message: *gtk.Label,
    button: *gtk.Button,
    connection: ?greetd.Connection = null,

    fn destroy(self: *Greeter) void {
        for (self.names.items) |n| self.allocator.free(n);
        self.names.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn activate(app: *gtk.Application, self: *App) callconv(.c) void {
        common.style.load(self.allocator) catch {};
        self.greeter = Greeter.create(self.allocator, app) catch |err| {
            std.log.err("cannot create the login screen: {s}", .{@errorName(err)});
            return;
        };
    }

    fn create(allocator: std.mem.Allocator, app: *gtk.Application) !*Greeter {
        const self = try allocator.create(Greeter);
        self.* = .{
            .allocator = allocator,
            .window = gtk.ApplicationWindow.new(app),
            .users = undefined,
            .sessions_box = undefined,
            .password = gtk.PasswordEntry.new(),
            .message = gtk.Label.new(""),
            .button = gtk.Button.newWithLabel(common.tr("Sign in")),
        };
        self.loadUsers();
        self.loadSessions();

        const window = self.window.as(gtk.Window);
        window.setTitle(common.tr("Sign in"));
        window.as(gtk.Widget).addCssClass("dkde-greeter");
        window.fullscreen();

        const card = gtk.Box.new(.vertical, 12);
        card.as(gtk.Widget).addCssClass("dkde-greeter-card");
        card.as(gtk.Widget).setHalign(.center);
        card.as(gtk.Widget).setValign(.center);
        card.as(gtk.Widget).setSizeRequest(340, -1);

        const avatar = gtk.Image.newFromIconName("avatar-default-symbolic");
        avatar.setPixelSize(96);
        card.append(avatar.as(gtk.Widget));

        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(allocator);
        for (self.names.items) |n| try names.append(allocator, n);
        const strings = gtk.StringList.new(null);
        for (names.items) |n| strings.append(@ptrCast(n.ptr));
        self.users = gtk.DropDown.new(strings.as(gio.ListModel), null);
        card.append(self.users.as(gtk.Widget));

        // The desktop to start: every installed session entry (Wayland and X11).
        const session_names = gtk.StringList.new(null);
        for (self.sessions.items) |sess| session_names.append(sess.name.ptr);
        self.sessions_box = gtk.DropDown.new(session_names.as(gio.ListModel), null);
        self.sessions_box.as(gtk.Widget).setTooltipText(common.tr("Desktop session"));
        self.sessions_box.setSelected(self.preferredSession());
        card.append(self.sessions_box.as(gtk.Widget));

        self.password.setShowPeekIcon(1);
        self.password.as(gtk.Widget).setHexpand(1);
        _ = gtk.PasswordEntry.signals.activate.connect(self.password, *Greeter, &onActivateEntry, self, .{});
        card.append(self.password.as(gtk.Widget));

        self.button.as(gtk.Widget).addCssClass("suggested-action");
        _ = gtk.Button.signals.clicked.connect(self.button, *Greeter, &onSignIn, self, .{});
        card.append(self.button.as(gtk.Widget));

        self.message.as(gtk.Widget).addCssClass("error");
        self.message.setWrap(1);
        card.append(self.message.as(gtk.Widget));

        window.setChild(card.as(gtk.Widget));
        window.present();
        _ = self.password.as(gtk.Widget).grabFocus();
        return self;
    }

    /// Local accounts: uid 1000 and up with a real shell.
    fn loadUsers(self: *Greeter) void {
        var contents: [*]u8 = undefined;
        var len: usize = 0;
        if (glib.fileGetContents("/etc/passwd", &contents, &len, null) == 0) return;
        defer glib.free(contents);
        var lines = std.mem.splitScalar(u8, contents[0..len], '\n');
        while (lines.next()) |line| {
            var f = std.mem.splitScalar(u8, line, ':');
            const name = f.next() orelse continue;
            _ = f.next();
            const uid = std.fmt.parseInt(u32, f.next() orelse continue, 10) catch continue;
            _ = f.next();
            _ = f.next();
            _ = f.next();
            const shell = f.next() orelse continue;
            if (uid < 1000 or uid >= 60000) continue;
            if (std.mem.endsWith(u8, shell, "nologin") or std.mem.endsWith(u8, shell, "false")) continue;
            self.names.append(self.allocator, self.allocator.dupeSentinel(u8, name, 0) catch continue) catch {};
        }
    }

    fn loadSessions(self: *Greeter) void {
        for (session_dirs) |entry| {
            var dir = std.Io.Dir.cwd().openDir(common.fsio.io(), entry.dir, .{ .iterate = true }) catch continue;
            defer dir.close(common.fsio.io());
            var it = dir.iterate();
            while (it.next(common.fsio.io()) catch null) |item| {
                if (!std.mem.endsWith(u8, item.name, ".desktop")) continue;
                self.addSession(entry.dir, item.name, entry.x11);
            }
        }
        // dkde's own first, then by name.
        std.mem.sort(Session, self.sessions.items, {}, struct {
            fn less(_: void, a: Session, b: Session) bool {
                const ad = std.mem.startsWith(u8, a.file, "dkde");
                const bd = std.mem.startsWith(u8, b.file, "dkde");
                if (ad != bd) return ad;
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.less);
        if (self.sessions.items.len == 0) {
            // Nothing listed: the plain dkde session.
            const name = self.allocator.dupeSentinel(u8, "dkde", 0) catch return;
            const exec = self.allocator.dupeSentinel(u8, "dkde-session", 0) catch return;
            self.sessions.append(self.allocator, .{ .name = name, .exec = exec, .x11 = false, .file = self.allocator.dupe(u8, "dkde.desktop") catch return }) catch {};
        }
    }

    fn addSession(self: *Greeter, dir: []const u8, file: []const u8, x11: bool) void {
        const a = self.allocator;
        const path = std.fmt.allocPrint(a, "{s}/{s}", .{ dir, file }) catch return;
        defer a.free(path);
        const text = common.fsio.readFile(a, path, 64 * 1024) catch return orelse return;
        defer a.free(text);
        var name: ?[]const u8 = null;
        var exec: ?[]const u8 = null;
        var try_exec: ?[]const u8 = null;
        var hidden = false;
        var in_entry = false;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len > 0 and line[0] == '[') {
                in_entry = std.mem.eql(u8, line, "[Desktop Entry]");
                continue;
            }
            if (!in_entry) continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = line[0..eq];
            const value = line[eq + 1 ..];
            if (std.mem.eql(u8, key, "Name")) name = value;
            if (std.mem.eql(u8, key, "Exec")) exec = value;
            if (std.mem.eql(u8, key, "TryExec")) try_exec = value;
            if ((std.mem.eql(u8, key, "Hidden") or std.mem.eql(u8, key, "NoDisplay")) and std.mem.eql(u8, value, "true")) hidden = true;
        }
        if (hidden or name == null or exec == null) return;
        // Offer only what is installed.
        if (try_exec) |t| if (!commandExists(a, t)) return;
        const first = firstCommand(exec.?);
        if (first.len > 0 and !commandExists(a, first)) return;
        for (self.sessions.items) |s| if (std.mem.eql(u8, s.file, file)) return;
        const n = a.dupeSentinel(u8, name.?, 0) catch return;
        const e = a.dupeSentinel(u8, exec.?, 0) catch return;
        const f = a.dupe(u8, file) catch return;
        self.sessions.append(a, .{ .name = n, .exec = e, .x11 = x11, .file = f }) catch {};
    }

    /// The index of the session chosen last time, or of the first (dkde's own).
    fn preferredSession(self: *Greeter) u32 {
        const a = self.allocator;
        const text = (common.fsio.readFile(a, last_session_file, 512) catch return 0) orelse return 0;
        defer a.free(text);
        const want = std.mem.trim(u8, text, " \n\r\t");
        for (self.sessions.items, 0..) |s, i| if (std.mem.eql(u8, s.file, want)) return @intCast(i);
        return 0;
    }

    fn rememberSession(self: *Greeter, index: usize) void {
        common.fsio.writeFileAtomic(last_session_file, self.sessions.items[index].file) catch {};
    }

    fn onActivateEntry(_: *gtk.PasswordEntry, self: *Greeter) callconv(.c) void {
        self.signIn();
    }

    fn onSignIn(_: *gtk.Button, self: *Greeter) callconv(.c) void {
        self.signIn();
    }

    fn fail(self: *Greeter, text: [:0]const u8) void {
        self.message.setText(text);
        self.password.as(gtk.Editable).setText("");
        self.button.as(gtk.Widget).setSensitive(1);
        _ = self.password.as(gtk.Widget).grabFocus();
    }

    fn signIn(self: *Greeter) void {
        const index = self.users.getSelected();
        if (index >= self.names.items.len) return self.fail(common.tr("No accounts to sign in to."));
        self.message.setText("");
        self.button.as(gtk.Widget).setSensitive(0);
        self.authenticate(self.names.items[index]) catch |err| {
            std.log.warn("login failed: {s}", .{@errorName(err)});
            self.fail(common.tr("Could not talk to the login service (greetd)."));
        };
    }

    /// One whole login conversation. It blocks the window for as long as PAM
    /// takes, which is a second or two.
    fn authenticate(self: *Greeter, user: []const u8) !void {
        const a = self.allocator;
        const sock = glib.getenv("GREETD_SOCK") orelse return error.NoSocket;
        const connection = try greetd.Connection.open(std.mem.span(sock));
        defer connection.deinit();

        const first = try greetd.createSession(a, user);
        defer a.free(first);
        try connection.send(first);

        while (true) {
            const raw = try connection.receive(a);
            defer a.free(raw);
            var reply = try greetd.parseReply(a, raw);
            defer reply.deinit();
            const kind = reply.value.type;

            if (std.mem.eql(u8, kind, "success")) {
                const choice = self.sessions_box.getSelected();
                const sess = if (choice < self.sessions.items.len) self.sessions.items[choice] else self.sessions.items[0];
                const command = [_][]const u8{ "/bin/sh", "-c", sess.exec };
                const env = [_][]const u8{if (sess.x11) "DKDE_SESSION_TYPE=x11" else "DKDE_SESSION_TYPE=wayland"};
                const start = try greetd.startSession(a, &command, &env);
                defer a.free(start);
                try connection.send(start);
                // The reply to start_session ends the greeter's job either way.
                const done = try connection.receive(a);
                defer a.free(done);
                var result = try greetd.parseReply(a, done);
                defer result.deinit();
                if (std.mem.eql(u8, result.value.type, "success")) {
                    self.rememberSession(choice);
                    self.window.as(gtk.Window).close();
                    return;
                }
                // The conversation is over but greetd still holds the session: release it.
                try connection.send(greetd.cancel_session);
                const ack = connection.receive(a) catch null;
                if (ack) |m| a.free(m);
                return self.fail(common.tr("The session could not be started."));
            }
            if (std.mem.eql(u8, kind, "auth_message")) {
                const message_type = reply.value.auth_message_type orelse "info";
                if (std.mem.eql(u8, message_type, "secret") or std.mem.eql(u8, message_type, "visible")) {
                    const answer = try greetd.postAuthResponse(a, std.mem.span(self.password.as(gtk.Editable).getText()));
                    defer {
                        @memset(answer, 0);
                        a.free(answer);
                    }
                    try connection.send(answer);
                } else {
                    const ack = try greetd.postAuthResponse(a, null);
                    defer a.free(ack);
                    try connection.send(ack);
                }
                continue;
            }
            // An error: wrong password, unknown account, and so on.
            try connection.send(greetd.cancel_session);
            const ack = connection.receive(a) catch null;
            if (ack) |m| a.free(m);
            return self.fail(common.tr("Incorrect user name or password."));
        }
    }
};

/// The first word of an Exec line (after any leading `env VAR=value`).
fn firstCommand(exec: []const u8) []const u8 {
    var words = std.mem.tokenizeScalar(u8, exec, ' ');
    while (words.next()) |w| {
        if (std.mem.eql(u8, w, "env")) continue;
        if (std.mem.indexOfScalar(u8, w, '=') != null) continue;
        return w;
    }
    return "";
}

fn commandExists(a: std.mem.Allocator, cmd: []const u8) bool {
    if (std.mem.indexOfScalar(u8, cmd, '/') != null) {
        const z = a.dupeSentinel(u8, cmd, 0) catch return false;
        defer a.free(z);
        return std.c.access(z.ptr, std.c.X_OK) == 0;
    }
    const path = std.mem.span(glib.getenv("PATH") orelse "/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin");
    var dirs = std.mem.splitScalar(u8, path, ':');
    while (dirs.next()) |d| {
        const full = std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ d, cmd }, 0) catch return false;
        defer a.free(full);
        if (std.c.access(full.ptr, std.c.X_OK) == 0) return true;
    }
    return false;
}

const App = struct {
    allocator: std.mem.Allocator,
    greeter: ?*Greeter = null,
};

pub const std_options: std.Options = .{ .logFn = common.log.logFn, .log_level = .debug };

pub fn main(init: std.process.Init.Minimal) !void {
    cli.handle(init.args, .{ .name = "dkde-greeter", .summary = "Graphical login screen (run by greetd)" });
    common.perf.init();
    var debug_allocator: common.perf.Gpa = .{};
    defer debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var app: App = .{ .allocator = allocator };
    const gtk_app = gtk.Application.new("org.dkde.greeter", .{ .non_unique = true });
    defer gtk_app.as(gobject.Object).unref();
    _ = gio.Application.signals.activate.connect(gtk_app, *App, &Greeter.activate, &app, .{});
    const status = gio.Application.run(gtk_app.as(gio.Application), @intCast(init.args.vector.len), @ptrCast(@constCast(init.args.vector.ptr)));
    if (app.greeter) |g| g.destroy();
    if (status != 0) std.process.exit(@intCast(status));
}

test {
    _ = @import("greetd.zig");
}
