//! dkde-greeter: the login screen (SPEC.md 5.10). greetd runs it, under a
//! kiosk labwc, as an unprivileged user. It asks greetd to authenticate the
//! chosen account and, on success, to start the dkde session.

const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

const greetd = @import("greetd.zig");

const session_command = [_][]const u8{"dkde-session"};

const Greeter = struct {
    allocator: std.mem.Allocator,
    window: *gtk.ApplicationWindow,
    users: *gtk.DropDown,
    names: std.ArrayList([:0]u8) = .empty,
    password: *gtk.PasswordEntry,
    message: *gtk.Label,
    button: *gtk.Button,
    connection: ?greetd.Connection = null,

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
            .password = gtk.PasswordEntry.new(),
            .message = gtk.Label.new(""),
            .button = gtk.Button.newWithLabel(common.tr("Sign in")),
        };
        self.loadUsers();

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
                const start = try greetd.startSession(a, &session_command);
                defer a.free(start);
                try connection.send(start);
                // The reply to start_session ends the greeter's job either way.
                const done = try connection.receive(a);
                defer a.free(done);
                var result = try greetd.parseReply(a, done);
                defer result.deinit();
                if (std.mem.eql(u8, result.value.type, "success")) {
                    self.window.as(gtk.Window).close();
                    return;
                }
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

const App = struct {
    allocator: std.mem.Allocator,
    greeter: ?*Greeter = null,
};

pub const std_options: std.Options = .{ .logFn = common.log.logFn, .log_level = .debug };

pub fn main(init: std.process.Init.Minimal) !void {
    common.perf.init();
    var debug_allocator: common.perf.Gpa = .{};
    defer debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var app: App = .{ .allocator = allocator };
    const gtk_app = gtk.Application.new("org.dkde.greeter", .{ .non_unique = true });
    defer gtk_app.as(gobject.Object).unref();
    _ = gio.Application.signals.activate.connect(gtk_app, *App, &Greeter.activate, &app, .{});
    const status = gio.Application.run(gtk_app.as(gio.Application), @intCast(init.args.vector.len), @ptrCast(@constCast(init.args.vector.ptr)));
    if (status != 0) std.process.exit(@intCast(status));
}

test {
    _ = @import("greetd.zig");
}
