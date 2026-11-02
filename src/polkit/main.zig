//! dkde-polkit: a polkit authentication agent (SPEC.md 5.12). When a program
//! that polkit guards (GParted, NetworkManager, udisks, `pkexec`) needs the
//! user to prove who they are, polkitd calls the agent registered for the login
//! session. This program is that agent, and it only speaks D-Bus: for each
//! request it starts `dkde-polkit-ui`, which shows the dialog and talks to
//! polkit's helper, and answers polkitd with how that went. It links GLib and
//! GIO but not GTK, so while idle it costs a few megabytes.
//!
//! dkde's own tools do not use this: they run commands through sudo with their
//! own dialog (`common.elevate`), so a system without polkit needs none of it.
//! Run this only where polkitd is installed. Autostart:
//!     command -v pkexec >/dev/null && dkde-polkit &
//!
//! From polkit 127's source, checked against a running polkitd:
//!  - The agent exports `org.freedesktop.PolicyKit1.AuthenticationAgent` on the
//!    system bus and registers its object with `RegisterAuthenticationAgent`
//!    for the login session (found through logind or elogind, else
//!    `XDG_SESSION_ID`). A session is needed: polkit sends an agent the requests
//!    of its session. Without one, `--process-subject` registers for this
//!    process alone, which only helps testing with `pkcheck --process`.
//!  - `BeginAuthentication` gives a message, an icon, details, a cookie and the
//!    identities that may authenticate. Only the bus name that owns polkit's
//!    service may call the agent.

const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const proto = @import("polkitproto");

const log = std.log.scoped(.polkit);

const gpa = std.heap.c_allocator;

const agent_path = "/org/dkde/PolicyKit1/AuthenticationAgent";
const agent_interface = "org.freedesktop.PolicyKit1.AuthenticationAgent";
const authority_name = "org.freedesktop.PolicyKit1";
const authority_path = "/org/freedesktop/PolicyKit1/Authority";
const authority_interface = "org.freedesktop.PolicyKit1.Authority";
const ui_program = "dkde-polkit-ui";

const introspection =
    \\<node>
    \\  <interface name="org.freedesktop.PolicyKit1.AuthenticationAgent">
    \\    <method name="BeginAuthentication">
    \\      <arg type="s" name="action_id" direction="in"/>
    \\      <arg type="s" name="message" direction="in"/>
    \\      <arg type="s" name="icon_name" direction="in"/>
    \\      <arg type="a{ss}" name="details" direction="in"/>
    \\      <arg type="s" name="cookie" direction="in"/>
    \\      <arg type="a(sa{sv})" name="identities" direction="in"/>
    \\    </method>
    \\    <method name="CancelAuthentication">
    \\      <arg type="s" name="cookie" direction="in"/>
    \\    </method>
    \\  </interface>
    \\</node>
;

/// One request from polkitd, from BeginAuthentication until it is answered.
const Request = struct {
    invocation: *gio.DBusMethodInvocation,
    cookie: [:0]u8,
    /// The command line for `dkde-polkit-ui`; each string is owned.
    argv: std.ArrayList([:0]u8) = .empty,
    proc: ?*gio.Subprocess = null,
    /// polkitd asked to cancel; the exit of the dialog then means "cancelled".
    cancelled: bool = false,

    fn deinit(self: *Request) void {
        gpa.free(self.cookie);
        for (self.argv.items) |a| gpa.free(a);
        self.argv.deinit(gpa);
        gpa.destroy(self);
    }
};

const Agent = struct {
    /// The bus name that owns polkit's service; only it may call us.
    owner: [80]u8 = undefined,
    owner_len: usize = 0,
    queue: std.ArrayList(*Request) = .empty,
    active: ?*Request = null,
    force_process_subject: bool = false,
};

var agent: Agent = .{};

// ---- the D-Bus object ---------------------------------------------------------------

fn onMethodCall(
    _: *gio.DBusConnection,
    sender: ?[*:0]const u8,
    _: [*:0]const u8,
    _: ?[*:0]const u8,
    method: [*:0]const u8,
    parameters: *glib.Variant,
    invocation: *gio.DBusMethodInvocation,
    _: ?*anyopaque,
) callconv(.c) void {
    // Anyone could send us a request that opens a password dialog; only
    // polkitd may (the shipped D-Bus policy says so too).
    const from = if (sender) |s| std.mem.span(s) else "";
    if (agent.owner_len == 0 or !std.mem.eql(u8, from, agent.owner[0..agent.owner_len])) {
        log.warn("refused a call from {s}: not polkit's service", .{from});
        invocation.returnDbusError("org.freedesktop.DBus.Error.AccessDenied", "only polkitd may call this agent");
        return;
    }
    const name = std.mem.span(method);
    if (std.mem.eql(u8, name, "BeginAuthentication")) {
        beginAuthentication(parameters, invocation);
    } else if (std.mem.eql(u8, name, "CancelAuthentication")) {
        const c = parameters.getChildValue(0);
        defer c.unref();
        cancelAuthentication(std.mem.span(c.getString(null)));
        invocation.returnValue(glib.Variant.newTuple(&[_]*glib.Variant{}, 0));
    } else {
        invocation.returnDbusError("org.freedesktop.DBus.Error.UnknownMethod", "no such method");
    }
}

fn childString(v: *glib.Variant, index: usize) []const u8 {
    const c = v.getChildValue(index);
    defer c.unref();
    return std.mem.span(c.getString(null));
}

fn pushArg(req: *Request, text: []const u8) void {
    const z = gpa.dupeSentinel(u8, text, 0) catch @panic("OOM");
    req.argv.append(gpa, z) catch @panic("OOM");
}

fn pushUid(req: *Request, uid: u32) void {
    var buf: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{uid}) catch return;
    // One --uid per distinct identity.
    var i: usize = 0;
    while (i + 1 < req.argv.items.len) : (i += 1) {
        if (std.mem.eql(u8, req.argv.items[i], "--uid") and std.mem.eql(u8, req.argv.items[i + 1], text)) return;
    }
    pushArg(req, "--uid");
    pushArg(req, text);
}

/// The uid or gid in an identity's detail dictionary (`a{sv}`).
fn detailNumber(dict: *glib.Variant, key: []const u8) ?u32 {
    const n = dict.nChildren();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const entry = dict.getChildValue(i);
        defer entry.unref();
        const k = entry.getChildValue(0);
        defer k.unref();
        if (!std.mem.eql(u8, std.mem.span(k.getString(null)), key)) continue;
        const boxed = entry.getChildValue(1);
        defer boxed.unref();
        const inner = boxed.getVariant();
        defer inner.unref();
        return inner.getUint32();
    }
    return null;
}

fn beginAuthentication(parameters: *glib.Variant, invocation: *gio.DBusMethodInvocation) void {
    const cookie_text = childString(parameters, 4);
    if (!proto.validCookie(cookie_text)) {
        invocation.returnDbusError("org.freedesktop.PolicyKit1.Error.Failed", "invalid cookie");
        return;
    }
    const req = gpa.create(Request) catch @panic("OOM");
    req.* = .{ .invocation = invocation, .cookie = gpa.dupeSentinel(u8, cookie_text, 0) catch @panic("OOM") };
    log.info("authentication requested for {s}", .{childString(parameters, 0)});

    // The command line of the dialog: what to say, then who may authenticate.
    pushArg(req, ui_program);
    pushArg(req, "--message");
    pushArg(req, childString(parameters, 1));
    pushArg(req, "--icon");
    pushArg(req, childString(parameters, 2));

    // Details: pkexec and others say which program asked.
    const details = parameters.getChildValue(3);
    defer details.unref();
    var program: []const u8 = "";
    var command_line: []const u8 = "";
    const nd = details.nChildren();
    var di: usize = 0;
    while (di < nd) : (di += 1) {
        const entry = details.getChildValue(di);
        defer entry.unref();
        const k = childString(entry, 0);
        const v = childString(entry, 1);
        if (std.mem.eql(u8, k, "program")) program = v;
        if (std.mem.eql(u8, k, "command_line")) command_line = v;
    }
    const shown = if (command_line.len > 0) command_line else program;
    if (shown.len > 0) {
        pushArg(req, "--program");
        pushArg(req, shown);
    }

    // The identities that may authenticate: users, and the members of groups.
    const ids = parameters.getChildValue(5);
    defer ids.unref();
    const ni = ids.nChildren();
    var ii: usize = 0;
    while (ii < ni) : (ii += 1) {
        const ident = ids.getChildValue(ii);
        defer ident.unref();
        const kind = childString(ident, 0);
        const dict = ident.getChildValue(1);
        defer dict.unref();
        if (std.mem.eql(u8, kind, "unix-user")) {
            if (detailNumber(dict, "uid")) |uid| pushUid(req, uid);
        } else if (std.mem.eql(u8, kind, "unix-group")) {
            const gid = detailNumber(dict, "gid") orelse continue;
            const grp = std.c.getgrgid(gid) orelse continue;
            var m = grp.mem;
            while (m[0]) |member| : (m += 1) {
                if (std.c.getpwnam(member)) |pw| pushUid(req, pw.uid);
            }
        }
    }

    agent.queue.append(gpa, req) catch @panic("OOM");
    startNext();
}

fn cancelAuthentication(cookie: []const u8) void {
    for (agent.queue.items, 0..) |req, i| {
        if (!std.mem.eql(u8, req.cookie, cookie)) continue;
        if (agent.active == req) {
            // The dialog is closed; its exit answers polkitd.
            req.cancelled = true;
            if (req.proc) |p| p.sendSignal(15);
        } else {
            _ = agent.queue.orderedRemove(i);
            req.invocation.returnDbusError("org.freedesktop.PolicyKit1.Error.Cancelled", "cancelled by polkit");
            req.deinit();
        }
        return;
    }
}

// ---- the dialog process ---------------------------------------------------------------------------

/// `dkde-polkit-ui` in the same directory as this program, so a build that is
/// not installed finds its own dialog; null when there is none there.
fn siblingPath(buf: []u8) ?[:0]const u8 {
    const n = std.c.readlink("/proc/self/exe", buf.ptr, buf.len - ui_program.len - 2);
    if (n <= 0) return null;
    const dir_end = std.mem.lastIndexOfScalar(u8, buf[0..@intCast(n)], '/') orelse return null;
    const start = dir_end + 1;
    @memcpy(buf[start..][0..ui_program.len], ui_program);
    buf[start + ui_program.len] = 0;
    const whole = buf[0 .. start + ui_program.len :0];
    if (std.c.access(whole.ptr, 1) != 0) return null;
    return whole;
}

/// Starts the dialog for the first waiting request, if none is open.
fn startNext() void {
    if (agent.active != null or agent.queue.items.len == 0) return;
    const req = agent.queue.items[0];
    agent.active = req;

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    var args: std.ArrayList(?[*:0]const u8) = .empty;
    defer args.deinit(gpa);
    for (req.argv.items, 0..) |a, i| {
        // PATH is searched for the dialog unless it sits next to this program.
        const use: [*:0]const u8 = if (i == 0) (if (siblingPath(&exe_buf)) |s| s.ptr else a.ptr) else a.ptr;
        args.append(gpa, use) catch @panic("OOM");
    }
    args.append(gpa, null) catch @panic("OOM");

    var err: ?*glib.Error = null;
    const proc = gio.Subprocess.newv(@ptrCast(args.items.ptr), .{ .stdin_pipe = true, .stdout_silence = true }, &err) orelse {
        if (err) |e| {
            log.err("cannot start the dialog ({s}): {s}", .{ ui_program, e.f_message orelse "unknown" });
            e.free();
        }
        answer(req, .failed, "cannot start the dialog");
        return;
    };
    req.proc = proc;
    // The cookie goes in on standard input, never on the command line.
    const stdin = proc.getStdinPipe().?;
    _ = stdin.writeAll(@constCast(req.cookie.ptr), req.cookie.len, null, null, null);
    _ = stdin.writeAll(@constCast("\n"), 1, null, null, null);
    _ = stdin.close(null, null);
    proc.waitAsync(null, onDialogExit, req);
}

fn onDialogExit(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
    const req: *Request = @ptrCast(@alignCast(data.?));
    const proc: *gio.Subprocess = @ptrCast(source.?);
    var err: ?*glib.Error = null;
    _ = proc.waitFinish(result, &err);
    if (err) |e| e.free();

    const outcome: Outcome = if (req.cancelled) .cancelled else if (proc.getIfExited() != 0) switch (proc.getExitStatus()) {
        0 => .ok,
        2 => .cancelled,
        else => .failed,
    } else .failed;
    answer(req, outcome, switch (outcome) {
        .ok => "",
        .cancelled => "cancelled",
        .failed => "authentication failed",
    });
}

const Outcome = enum { ok, cancelled, failed };

/// Answers polkitd and moves on to the next request.
fn answer(req: *Request, outcome: Outcome, message: [:0]const u8) void {
    switch (outcome) {
        .ok => req.invocation.returnValue(glib.Variant.newTuple(&[_]*glib.Variant{}, 0)),
        .cancelled => req.invocation.returnDbusError("org.freedesktop.PolicyKit1.Error.Cancelled", message),
        .failed => req.invocation.returnDbusError("org.freedesktop.PolicyKit1.Error.Failed", message),
    }
    log.info("authentication {s}", .{@tagName(outcome)});
    for (agent.queue.items, 0..) |r, i| {
        if (r == req) {
            _ = agent.queue.orderedRemove(i);
            break;
        }
    }
    if (agent.active == req) agent.active = null;
    if (req.proc) |p| p.as(gobject.Object).unref();
    req.deinit();
    startNext();
}

// ---- registering with polkit ---------------------------------------------------------------------

fn dictEntry(key: [:0]const u8, value: *glib.Variant) *glib.Variant {
    return glib.Variant.newDictEntry(glib.Variant.newString(key), glib.Variant.newVariant(value));
}

/// `(sa{sv})`: a polkit subject.
fn subjectVariant(kind: [:0]const u8, entries: []*glib.Variant) *glib.Variant {
    var children = [_]*glib.Variant{
        glib.Variant.newString(kind),
        glib.Variant.newArray(null, entries.ptr, entries.len),
    };
    return glib.Variant.newTuple(&children, 2);
}

/// The login session this agent belongs to: from logind (or elogind), else
/// `XDG_SESSION_ID`.
fn findSession(conn: *gio.DBusConnection, out: []u8) ?[]const u8 {
    var err: ?*glib.Error = null;
    var args = [_]*glib.Variant{glib.Variant.newUint32(@intCast(std.c.getpid()))};
    if (conn.callSync("org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager", "GetSessionByPID", glib.Variant.newTuple(&args, 1), null, .{}, 2000, null, &err)) |res| {
        defer res.unref();
        const path = res.getChildValue(0);
        defer path.unref();
        if (proto.sessionIdFromPath(std.mem.span(path.getString(null)), out)) |id| return id;
    } else if (err) |e| {
        log.info("logind does not know this process: {s}", .{e.f_message orelse "unknown"});
        e.free();
    }
    if (glib.getenv("XDG_SESSION_ID")) |s| {
        const id = std.mem.span(s);
        if (id.len > 0 and id.len <= out.len) {
            @memcpy(out[0..id.len], id);
            return out[0..id.len];
        }
    }
    return null;
}

/// The subject to register for; null when there is no login session and the
/// process subject was not asked for.
fn buildSubject(conn: *gio.DBusConnection) ?*glib.Variant {
    var id_buf: [64]u8 = undefined;
    if (!agent.force_process_subject) {
        if (findSession(conn, &id_buf)) |id| {
            log.info("registering for login session {s}", .{id});
            const idz = gpa.dupeSentinel(u8, id, 0) catch @panic("OOM");
            defer gpa.free(idz);
            var entries = [_]*glib.Variant{dictEntry("session-id", glib.Variant.newString(idz))};
            return subjectVariant("unix-session", &entries);
        }
        // Without a session, polkit sends this agent only requests that name
        // this very process, so no real program would ever reach it.
        return null;
    }
    // Registered for this process alone (`pkcheck --process`): for testing.
    const pid: u32 = @intCast(std.c.getpid());
    var start: u64 = 0;
    var contents: [*]u8 = undefined;
    var length: usize = 0;
    if (glib.fileGetContents("/proc/self/stat", &contents, &length, null) != 0) {
        defer glib.free(contents);
        start = proto.startTimeFromStat(contents[0..length]) orelse 0;
    }
    log.warn("registering for this process only (pid {d})", .{pid});
    var entries = [_]*glib.Variant{
        dictEntry("pid", glib.Variant.newUint32(pid)),
        dictEntry("start-time", glib.Variant.newUint64(start)),
    };
    return subjectVariant("unix-process", &entries);
}

fn registerWithAuthority(conn: *gio.DBusConnection) void {
    const locale = if (glib.getenv("LANG")) |l| std.mem.span(l) else "en_US.UTF-8";
    const locale_z = gpa.dupeSentinel(u8, locale, 0) catch return;
    defer gpa.free(locale_z);
    const subject = buildSubject(conn) orelse {
        log.err("no login session found: polkit would send this agent nothing. Is logind or elogind running, and was this started from the session? (--process-subject registers for testing)", .{});
        std.process.exit(1);
    };
    var args = [_]*glib.Variant{
        subject,
        glib.Variant.newString(locale_z),
        // A plain string: the interface says `s`, not an object path.
        glib.Variant.newString(agent_path),
    };
    var err: ?*glib.Error = null;
    if (conn.callSync(authority_name, authority_path, authority_interface, "RegisterAuthenticationAgent", glib.Variant.newTuple(&args, 3), null, .{}, 5000, null, &err)) |res| {
        res.unref();
        log.info("registered as an authentication agent", .{});
    } else if (err) |e| {
        log.err("polkit refused the registration: {s}", .{e.f_message orelse "unknown"});
        e.free();
    }
}

fn onAuthorityAppeared(conn: *gio.DBusConnection, _: [*:0]const u8, owner: [*:0]const u8, _: ?*anyopaque) callconv(.c) void {
    const o = std.mem.span(owner);
    const n = @min(o.len, agent.owner.len);
    @memcpy(agent.owner[0..n], o[0..n]);
    agent.owner_len = n;
    registerWithAuthority(conn);
}

fn onAuthorityVanished(_: *gio.DBusConnection, _: [*:0]const u8, _: ?*anyopaque) callconv(.c) void {
    // Registered again when it comes back (D-Bus activation starts it on demand).
    agent.owner_len = 0;
    log.info("polkitd is not running; waiting for it", .{});
}

fn noopFree(_: ?*anyopaque) callconv(.c) void {}

// ---- the program -------------------------------------------------------------------------------------

pub fn main(init: std.process.Init.Minimal) !void {
    for (init.args.vector[1..]) |a| {
        const arg = std.mem.span(a);
        if (std.mem.eql(u8, arg, "--process-subject")) {
            agent.force_process_subject = true;
        } else {
            const usage = "usage: dkde-polkit [--process-subject]\n  --process-subject  register for this process only, to test with `pkcheck --process`\n";
            _ = std.c.write(2, usage.ptr, usage.len);
            std.process.exit(2);
        }
    }

    var err: ?*glib.Error = null;
    const conn = gio.busGetSync(.system, null, &err) orelse {
        log.err("no system bus: {s}", .{if (err) |e| e.f_message orelse "unknown" else "unknown"});
        std.process.exit(1);
    };
    const node = gio.DBusNodeInfo.newForXml(introspection, &err) orelse {
        log.err("bad interface XML", .{});
        std.process.exit(1);
    };
    const iface = node.lookupInterface(agent_interface) orelse std.process.exit(1);
    const vtable = struct {
        var table: gio.DBusInterfaceVTable = .{
            .f_method_call = onMethodCall,
            .f_get_property = null,
            .f_set_property = null,
            .f_padding = undefined,
        };
    };
    if (conn.registerObject(agent_path, iface, &vtable.table, null, noopFree, &err) == 0) {
        log.err("cannot export the agent: {s}", .{if (err) |e| e.f_message orelse "unknown" else "unknown"});
        std.process.exit(1);
    }
    _ = gio.busWatchName(.system, authority_name, .{}, onAuthorityAppeared, onAuthorityVanished, null, null);

    const loop = glib.MainLoop.new(null, 0);
    loop.run();
}

test {
    _ = proto;
}
