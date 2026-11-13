//! GNOME Online Accounts (GOA), read through its D-Bus interface.
//!
//! GOA is the one place on a desktop where a person signs in to Google,
//! Microsoft, Nextcloud, Fastmail, IMAP and so on. dkde does not run its own
//! sign-in: it asks the GOA daemon (org.gnome.OnlineAccounts) which accounts
//! exist and what each offers (calendar, mail, contacts, files), so one set-up
//! serves every dkde app. This is a client of the daemon's public D-Bus
//! interface through Gio, so there is no libgoa to link and no new build
//! dependency; if GOA is not installed, nothing here does anything.
//!
//! Optional and not intrusive: the daemon is never started by dkde (the bus is
//! asked whether it is already running), nothing is read until a page asks, and
//! nothing is written. Adding an account is left to GOA's own window.
//!
//! Interfaces used (all under /org/gnome/OnlineAccounts/Accounts/<id>):
//!   org.gnome.OnlineAccounts.Account    ProviderType, ProviderName, Identity,
//!                                       PresentationIdentity, AttentionNeeded,
//!                                       CalendarDisabled, ContactsDisabled, MailDisabled, ...
//!   org.gnome.OnlineAccounts.Calendar   Uri   (a CalDAV address)
//!   org.gnome.OnlineAccounts.Contacts   Uri   (a CardDAV address)
//!   org.gnome.OnlineAccounts.Mail       EmailAddress, ImapHost, SmtpHost
//!   org.gnome.OnlineAccounts.Files      Uri

const std = @import("std");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gio = @import("gio2");

const bus_name = "org.gnome.OnlineAccounts";
const root_path = "/org/gnome/OnlineAccounts";
const iface = "org.gnome.OnlineAccounts.";
const account_prefix = "/org/gnome/OnlineAccounts/Accounts/";

pub const Service = enum { calendar, contacts, mail, files };

/// One account GOA knows about. All text is owned by the `Accounts` arena.
pub const Account = struct {
    /// Object path; the only stable handle (GOA's own "Id" is the last part).
    path: []const u8,
    /// "google", "ms_graph", "webdav", "imap_smtp", "owncloud", ...
    provider_type: []const u8,
    provider_name: []const u8,
    /// What the person calls it, usually an address.
    title: []const u8,
    /// The sign-in has expired or was refused: GOA's own window fixes it.
    attention_needed: bool,
    has_calendar: bool,
    has_contacts: bool,
    has_mail: bool,
    has_files: bool,
    /// Signs in with OAuth2 (Google, Microsoft, ...): GOA can hand out an access token.
    oauth2: bool,
    /// The person switched the service off in GOA; dkde respects that.
    calendar_disabled: bool,
    contacts_disabled: bool,
    mail_disabled: bool,
    files_disabled: bool,
    /// CalDAV / CardDAV addresses when the account offers them (empty when not).
    calendar_uri: []const u8,
    contacts_uri: []const u8,

    /// The account offers `s` and the person has not turned it off in GOA.
    pub fn offers(self: Account, s: Service) bool {
        return switch (s) {
            .calendar => self.has_calendar and !self.calendar_disabled,
            .contacts => self.has_contacts and !self.contacts_disabled,
            .mail => self.has_mail and !self.mail_disabled,
            .files => self.has_files and !self.files_disabled,
        };
    }
};

pub const Accounts = struct {
    arena: std.heap.ArenaAllocator,
    items: []Account,

    pub fn deinit(self: *Accounts) void {
        self.arena.deinit();
    }
};

pub const Result = union(enum) {
    /// GOA is not running (or not installed): show nothing, say nothing is wrong.
    unavailable,
    failed,
    ok: Accounts,
};

pub const Callback = *const fn (result: Result, user: ?*anyopaque) void;

const Request = struct { gpa: std.mem.Allocator, connection: *gio.DBusConnection, callback: Callback, user: ?*anyopaque };

/// Reads the accounts, without starting the daemon. `callback` runs on the main
/// loop; the `Accounts` in an `.ok` result belong to the callback, which must
/// `deinit` them.
pub fn fetch(gpa: std.mem.Allocator, callback: Callback, user: ?*anyopaque) void {
    var err: ?*glib.Error = null;
    const connection = gio.busGetSync(.session, null, &err) orelse {
        if (err) |e| e.free();
        return callback(.unavailable, user);
    };
    const request = gpa.create(Request) catch return callback(.failed, user);
    request.* = .{ .gpa = gpa, .connection = connection, .callback = callback, .user = user };
    // NameHasOwner never activates a service, unlike calling GOA directly.
    var args = [_]*glib.Variant{glib.Variant.newString(bus_name)};
    const reply_type = glib.VariantType.new("(b)");
    defer reply_type.free();
    connection.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner", glib.Variant.newTuple(&args, 1), reply_type, .{}, 2000, null, onOwner, request);
}

fn finish(request: *Request, result: Result) void {
    const cb = request.callback;
    const user = request.user;
    request.connection.as(gobject.Object).unref();
    request.gpa.destroy(request);
    cb(result, user);
}

fn onOwner(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
    const request: *Request = @ptrCast(@alignCast(data.?));
    const connection: *gio.DBusConnection = @ptrCast(@alignCast(source.?));
    var err: ?*glib.Error = null;
    const reply = connection.callFinish(result, &err) orelse {
        if (err) |e| e.free();
        return finish(request, .failed);
    };
    defer reply.unref();
    const flag = reply.getChildValue(0);
    defer flag.unref();
    if (flag.getBoolean() == 0) return finish(request, .unavailable);

    const reply_type = glib.VariantType.new("(a{oa{sa{sv}}})");
    defer reply_type.free();
    connection.call(bus_name, root_path, "org.freedesktop.DBus.ObjectManager", "GetManagedObjects", null, reply_type, .{ .no_auto_start = true }, 5000, null, onObjects, request);
}

fn onObjects(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
    const request: *Request = @ptrCast(@alignCast(data.?));
    const connection: *gio.DBusConnection = @ptrCast(@alignCast(source.?));
    var err: ?*glib.Error = null;
    const reply = connection.callFinish(result, &err) orelse {
        if (err) |e| e.free();
        return finish(request, .failed);
    };
    defer reply.unref();
    const parsed = parse(request.gpa, reply) catch return finish(request, .failed);
    finish(request, .{ .ok = parsed });
}

// ---- reading the reply -------------------------------------------------------------------------

fn dupe(a: std.mem.Allocator, z: [*:0]const u8) ![]const u8 {
    return a.dupe(u8, std.mem.span(z));
}

/// The value under `key` in an a{s?} dictionary (a{sv} values come out unboxed), or null.
/// Written out by hand: the bindings' lookupValue is not nullable.
fn dictFind(dict: *glib.Variant, key: []const u8) ?*glib.Variant {
    const n = dict.nChildren();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const entry = dict.getChildValue(i);
        defer entry.unref();
        const k = entry.getChildValue(0);
        defer k.unref();
        if (!std.mem.eql(u8, std.mem.span(k.getString(null)), key)) continue;
        const v = entry.getChildValue(1);
        if (std.mem.eql(u8, std.mem.span(v.getTypeString()), "v")) {
            defer v.unref();
            return v.getVariant();
        }
        return v;
    }
    return null;
}

/// `props` is an a{sv}; the string under `key`, or "".
fn propString(a: std.mem.Allocator, props: *glib.Variant, key: [:0]const u8) ![]const u8 {
    const v = dictFind(props, key) orelse return "";
    defer v.unref();
    if (!std.mem.eql(u8, std.mem.span(v.getTypeString()), "s")) return "";
    return dupe(a, v.getString(null));
}

fn propBool(props: *glib.Variant, key: [:0]const u8) bool {
    const v = dictFind(props, key) orelse return false;
    defer v.unref();
    if (!std.mem.eql(u8, std.mem.span(v.getTypeString()), "b")) return false;
    return v.getBoolean() != 0;
}

/// The interface dictionary of one object: its a{sv}, or null when the object lacks the interface.
fn ifaceProps(interfaces: *glib.Variant, name: [:0]const u8) ?*glib.Variant {
    return dictFind(interfaces, name);
}

fn parse(gpa: std.mem.Allocator, reply: *glib.Variant) !Accounts {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var items: std.ArrayList(Account) = .empty;

    const objects = reply.getChildValue(0);
    defer objects.unref();
    const count = objects.nChildren();
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const entry = objects.getChildValue(i);
        defer entry.unref();
        const path_v = entry.getChildValue(0);
        defer path_v.unref();
        const path = std.mem.span(path_v.getString(null));
        if (!std.mem.startsWith(u8, path, account_prefix)) continue; // the Manager, not an account
        const interfaces = entry.getChildValue(1);
        defer interfaces.unref();

        const account_props = ifaceProps(interfaces, iface ++ "Account") orelse continue;
        defer account_props.unref();

        var title = try propString(a, account_props, "PresentationIdentity");
        if (title.len == 0) title = try propString(a, account_props, "Identity");
        const provider_name = try propString(a, account_props, "ProviderName");
        if (title.len == 0) title = provider_name;

        var acct: Account = .{
            .path = try a.dupe(u8, path),
            .provider_type = try propString(a, account_props, "ProviderType"),
            .provider_name = provider_name,
            .title = title,
            .attention_needed = propBool(account_props, "AttentionNeeded"),
            .has_calendar = false,
            .has_contacts = false,
            .has_mail = false,
            .has_files = false,
            .oauth2 = false,
            .calendar_disabled = propBool(account_props, "CalendarDisabled"),
            .contacts_disabled = propBool(account_props, "ContactsDisabled"),
            .mail_disabled = propBool(account_props, "MailDisabled"),
            .files_disabled = propBool(account_props, "FilesDisabled"),
            .calendar_uri = "",
            .contacts_uri = "",
        };
        if (ifaceProps(interfaces, iface ++ "Calendar")) |p| {
            defer p.unref();
            acct.has_calendar = true;
            acct.calendar_uri = try propString(a, p, "Uri");
        }
        if (ifaceProps(interfaces, iface ++ "Contacts")) |p| {
            defer p.unref();
            acct.has_contacts = true;
            acct.contacts_uri = try propString(a, p, "Uri");
        }
        if (ifaceProps(interfaces, iface ++ "Mail")) |p| {
            p.unref();
            acct.has_mail = true;
        }
        if (ifaceProps(interfaces, iface ++ "OAuth2Based")) |p| {
            p.unref();
            acct.oauth2 = true;
        }
        if (ifaceProps(interfaces, iface ++ "Files")) |p| {
            p.unref();
            acct.has_files = true;
        }
        try items.append(a, acct);
    }
    return .{ .arena = arena, .items = try items.toOwnedSlice(a) };
}

/// The last part of an account's object path: letters, digits and '_', so it is safe in a
/// file name and a TOML group name. This is what dkde stores to find the account again.
pub fn idOf(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

/// The object path of the account stored as `id`, or null when `id` is not an id.
pub fn pathFor(buf: []u8, id: []const u8) ?[]const u8 {
    if (id.len == 0) return null;
    for (id) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return null;
    return std.fmt.bufPrint(buf, "{s}{s}", .{ account_prefix, id }) catch null;
}

pub const TokenError = error{ NoSession, NoToken, OutOfMemory };

/// A short-lived OAuth2 access token for account `id`, from the GOA daemon (which
/// refreshes it when it has expired; that can mean a network round trip, so call this
/// from a worker thread). The daemon is asked directly: if GOA is not running this
/// starts it, which is right here because the person asked for a sync. The token is
/// owned by the caller and must never be logged.
pub fn accessToken(allocator: std.mem.Allocator, id: []const u8) TokenError![]u8 {
    var buf: [160]u8 = undefined;
    const path = pathFor(&buf, id) orelse return error.NoToken;
    var path_z: [160:0]u8 = undefined;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    var err: ?*glib.Error = null;
    const connection = gio.busGetSync(.session, null, &err) orelse {
        if (err) |e| e.free();
        return error.NoSession;
    };
    defer connection.as(gobject.Object).unref();
    const reply_type = glib.VariantType.new("(si)");
    defer reply_type.free();
    const reply = connection.callSync(bus_name, &path_z, iface ++ "OAuth2Based", "GetAccessToken", null, reply_type, .{}, 30000, null, &err) orelse {
        if (err) |e| e.free();
        return error.NoToken;
    };
    defer reply.unref();
    const tok = reply.getChildValue(0);
    defer tok.unref();
    const text = std.mem.span(tok.getString(null));
    if (text.len == 0) return error.NoToken;
    return allocator.dupe(u8, text);
}

/// The program that opens GOA's own account window, if one is installed: GNOME's
/// standalone window, or the Settings app on its Online Accounts page.
pub fn managerCommand() ?[]const [:0]const u8 {
    const have = struct {
        fn f(n: [:0]const u8) bool {
            const found = glib.findProgramInPath(n) orelse return false;
            glib.free(found);
            return true;
        }
    }.f;
    if (have("gnome-online-accounts-gtk")) return &.{"gnome-online-accounts-gtk"};
    if (have("gnome-control-center")) return &.{ "gnome-control-center", "online-accounts" };
    return null;
}

test "parse reads accounts and their services from GetManagedObjects" {
    const text =
        \\({objectpath '/org/gnome/OnlineAccounts/Manager': {'org.gnome.OnlineAccounts.Manager': @a{sv} {}},
        \\  objectpath '/org/gnome/OnlineAccounts/Accounts/account_1': {
        \\    'org.gnome.OnlineAccounts.Account': {'ProviderType': <'google'>, 'ProviderName': <'Google'>,
        \\      'Identity': <'a@example.org'>, 'PresentationIdentity': <'a@example.org'>,
        \\      'AttentionNeeded': <true>, 'CalendarDisabled': <false>, 'MailDisabled': <true>},
        \\    'org.gnome.OnlineAccounts.Calendar': {'Uri': <'https://example.org/dav/'>},
        \\    'org.gnome.OnlineAccounts.Mail': @a{sv} {}}},)
    ;
    const t = glib.VariantType.new("(a{oa{sa{sv}}})");
    defer t.free();
    var err: ?*glib.Error = null;
    const v = glib.Variant.parse(t, text, null, null, &err) orelse return error.TestUnexpectedResult;
    defer v.unref();
    var got = try parse(std.testing.allocator, v);
    defer got.deinit();
    try std.testing.expectEqual(@as(usize, 1), got.items.len);
    const a = got.items[0];
    try std.testing.expectEqualStrings("google", a.provider_type);
    try std.testing.expectEqualStrings("a@example.org", a.title);
    try std.testing.expect(a.attention_needed);
    try std.testing.expect(!a.oauth2);
    try std.testing.expectEqualStrings("account_1", idOf(a.path));
    try std.testing.expect(a.offers(.calendar));
    try std.testing.expect(!a.offers(.mail)); // switched off in GOA
    try std.testing.expect(!a.offers(.contacts));
    try std.testing.expectEqualStrings("https://example.org/dav/", a.calendar_uri);
}
