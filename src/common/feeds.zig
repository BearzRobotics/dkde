//! Optional online calendars ("accounts"): calendars that live on a server and
//! are read into dkde-calendar, and from there into the panel's reminders.
//!
//! What this is, and is not. An account is a private https link to an iCalendar
//! (.ics) feed, which Google Calendar, Nextcloud, Fastmail, iCloud, Outlook and
//! most other services can give out ("secret address in iCal format",
//! "subscribe"). dkde downloads the feed, keeps the last copy in the cache
//! directory and shows its events next to the user's own. It is read-only:
//! nothing is ever sent to the server, there is no password to store, and an
//! event from a feed cannot be edited here (the next refresh would undo it).
//! CalDAV and sign-in flows are not implemented; see docs/decisions/0001.
//!
//! It is entirely optional. With no account set up nothing in this file runs:
//! no connection is made, no file is read. Accounts are added and removed only
//! in dkde-settings (Online accounts). dkde-calendar refreshes the ones the user
//! marked for it, on start and on its Sync now button, and never otherwise.
//!
//! Where things are:
//!   accounts   dkde.toml, groups [account.<id>]: name, url, enabled, refresh-minutes, color
//!   copies     $XDG_CACHE_HOME/dkde/feeds/<id>.ics (private directory)
//!
//! The link is a secret: anyone who has it can read the calendar. It is kept in
//! dkde.toml as written, so keep that file private (mode 0600) on a shared
//! computer, and the programs never print the whole link, only its host.

const std = @import("std");
const glib = @import("glib2");
const config_mod = @import("config.zig");
const events = @import("events.zig");
const ics = @import("ics.zig");
const civil = @import("civil.zig");
const goa = @import("goa.zig");
const gcal = @import("gcal.zig");

pub const group_prefix = "account.";

/// The largest feed that is read (a calendar of many years is well below this).
pub const max_feed_bytes: usize = 8 * 1024 * 1024;

/// How far around today repeats are worked out when a feed is read (days).
pub const window_back_days: i64 = 3 * 366;
pub const window_forward_days: i64 = 5 * 366;

pub const Account = struct {
    /// Letters, digits, '-' and '_' only: it becomes a file name.
    id: []const u8,
    name: []const u8,
    /// As the user entered it; `normalizeUrl` gives what is fetched.
    url: []const u8,
    enabled: bool = true,
    /// Refresh on start when the copy is older than this many minutes; 0 means only on request.
    refresh_minutes: i32 = 0,
    color: events.Color = .default,
    /// For a calendar of a GNOME Online Accounts account (Google): the id of that account
    /// (goa.idOf) and the provider's id of the calendar. Then `url` is empty and nothing
    /// is stored that could read the calendar: the token comes from GOA at each sync.
    goa: []const u8 = "",
    calendar: []const u8 = "",

    pub fn isGoa(self: Account) bool {
        return self.goa.len > 0;
    }
};

pub const Accounts = struct {
    arena: std.heap.ArenaAllocator,
    items: []Account,

    pub fn deinit(self: *Accounts) void {
        self.arena.deinit();
    }
};

// ---- accounts in the configuration ------------------------------------------------------------

/// An id that is safe as a file name and a TOML group name.
pub fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    return true;
}

/// The accounts in `cfg` (dkde.toml). A group with a bad id or no link is skipped.
pub fn loadAccounts(allocator: std.mem.Allocator, cfg: *const config_mod.Config) !Accounts {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const ids = try cfg.groupsWithPrefix(allocator, group_prefix);
    defer config_mod.freeStringList(allocator, ids);
    var items: std.ArrayList(Account) = .empty;
    for (ids) |id| {
        if (!validId(id)) continue;
        const group = try std.fmt.allocPrintSentinel(allocator, "{s}{s}", .{ group_prefix, id }, 0);
        defer allocator.free(group);
        const url = try cfg.getString(a, group, "url", "");
        const goa_id = try cfg.getString(a, group, "goa", "");
        const calendar = try cfg.getString(a, group, "calendar", "");
        if (url.len == 0 and (goa_id.len == 0 or calendar.len == 0)) continue;
        const color_text = try cfg.getString(allocator, group, "color", "default");
        defer allocator.free(color_text);
        const name = try cfg.getString(a, group, "name", "");
        try items.append(a, .{
            .id = try a.dupe(u8, id),
            .name = if (name.len > 0) name else try a.dupe(u8, id),
            .url = url,
            .enabled = cfg.getBool(group, "enabled", true),
            .refresh_minutes = @max(0, cfg.getInt(group, "refresh-minutes", 0)),
            .color = events.Color.parse(color_text),
            .goa = goa_id,
            .calendar = calendar,
        });
    }
    return .{ .arena = arena, .items = try items.toOwnedSlice(a) };
}

/// Writes (or replaces) an account. Each field is its own typed value, so the
/// file reads back the same; `cfg` must not be a staged one.
pub fn saveAccount(allocator: std.mem.Allocator, cfg: *config_mod.Config, acct: Account) !void {
    if (!validId(acct.id)) return error.BadId;
    const group = try std.fmt.allocPrintSentinel(allocator, "{s}{s}", .{ group_prefix, acct.id }, 0);
    defer allocator.free(group);
    const name = try allocator.dupeSentinel(u8, acct.name, 0);
    defer allocator.free(name);
    const url = try allocator.dupeSentinel(u8, acct.url, 0);
    defer allocator.free(url);
    try cfg.setString(group, "name", name);
    try cfg.setString(group, "url", url);
    if (acct.isGoa()) {
        const g = try allocator.dupeSentinel(u8, acct.goa, 0);
        defer allocator.free(g);
        const c = try allocator.dupeSentinel(u8, acct.calendar, 0);
        defer allocator.free(c);
        try cfg.setString(group, "goa", g);
        try cfg.setString(group, "calendar", c);
    }
    try cfg.setBool(group, "enabled", acct.enabled);
    try cfg.setInt(group, "refresh-minutes", acct.refresh_minutes);
    const color = try allocator.dupeSentinel(u8, acct.color.name(), 0);
    defer allocator.free(color);
    try cfg.setString(group, "color", color);
}

/// Removes an account and its cached copy.
pub fn removeAccount(allocator: std.mem.Allocator, cfg: *config_mod.Config, id: []const u8) !void {
    if (!validId(id)) return error.BadId;
    const group = try std.fmt.allocPrintSentinel(allocator, "{s}{s}", .{ group_prefix, id }, 0);
    defer allocator.free(group);
    try cfg.removeGroup(group);
    if (cachePath(allocator, id)) |path| {
        defer allocator.free(path);
        if (allocator.dupeSentinel(u8, path, 0)) |z| {
            defer allocator.free(z);
            _ = std.c.unlink(z);
        } else |_| {}
    } else |_| {}
}

// ---- links ------------------------------------------------------------------------------------

pub const UrlError = error{ BadUrl, NotHttps };

/// The address to fetch for what the user typed: "webcal://" and "webcals://"
/// are https, and plain "http://" is refused (the link is a secret). The result is
/// owned by the caller.
pub fn normalizeUrl(allocator: std.mem.Allocator, typed: []const u8) (UrlError || std.mem.Allocator.Error)![]u8 {
    const text = std.mem.trim(u8, typed, " \t\r\n");
    for (text) |c| if (c <= ' ' or c == 0x7f) return error.BadUrl;
    const schemes = [_]struct { prefix: []const u8, https: bool }{
        .{ .prefix = "https://", .https = true },
        .{ .prefix = "webcals://", .https = true },
        .{ .prefix = "webcal://", .https = true },
        .{ .prefix = "http://", .https = false },
    };
    for (schemes) |s| {
        if (!std.ascii.startsWithIgnoreCase(text, s.prefix)) continue;
        if (!s.https) return error.NotHttps;
        const rest = text[s.prefix.len..];
        if (rest.len == 0 or rest[0] == '/') return error.BadUrl;
        const out = try std.fmt.allocPrint(allocator, "https://{s}", .{rest});
        errdefer allocator.free(out);
        _ = std.Uri.parse(out) catch return error.BadUrl;
        return out;
    }
    return error.BadUrl;
}

/// The host of a link, for showing the user which server an account talks to
/// without showing the secret path.
pub fn hostOf(url: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, url, "://") orelse return "";
    const rest = url[at + 3 ..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    var host = rest[0..end];
    if (std.mem.lastIndexOfScalar(u8, host, '@')) |i| host = host[i + 1 ..]; // never show user:password
    return host;
}

// ---- fetching ---------------------------------------------------------------------------------

pub const FetchError = error{ SignInNeeded, HttpStatus, TooLarge, UnsupportedEncoding, NotACalendar, InsecureRedirect, TooManyRedirects } || std.mem.Allocator.Error;

/// At most this many redirects are followed.
const max_redirects = 3;

/// Where a redirect from `current` to `location` goes. Only an https address, or a
/// path on the same server, is followed: a redirect to plain http would send the
/// secret link over the network in the clear.
fn redirectTarget(allocator: std.mem.Allocator, current: []const u8, location: []const u8) (FetchError)![]u8 {
    if (std.ascii.startsWithIgnoreCase(location, "https://")) return allocator.dupe(u8, location);
    if (location.len > 0 and location[0] == '/' and !std.mem.startsWith(u8, location, "//")) {
        const scheme_end = std.mem.indexOf(u8, current, "://") orelse return error.InsecureRedirect;
        return std.fmt.allocPrint(allocator, "{s}://{s}{s}", .{ current[0..scheme_end], hostOf(current), location });
    }
    return error.InsecureRedirect;
}

/// Downloads `url` (already normalized) and returns the body, at most
/// `max_feed_bytes`. Blocks until done: call it from a worker thread. It makes
/// its own `Io`, so it shares nothing with the program's main thread.
pub fn fetchText(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    return fetchWith(allocator, url, null, "text/calendar, text/plain;q=0.5");
}

/// `fetchText` with an `Accept` type and, when `bearer` is given, an OAuth2 access token
/// (from GOA) sent as `Authorization: Bearer`. A request that carries a token follows no
/// redirect at all: the token must go only where it was meant to.
pub fn fetchWith(allocator: std.mem.Allocator, url: []const u8, bearer: ?[]const u8, accept: []const u8) ![]u8 {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var client: std.http.Client = .{ .allocator = allocator, .io = threaded.io() };
    defer client.deinit();

    const auth: ?[]u8 = if (bearer) |t| try std.fmt.allocPrint(allocator, "Bearer {s}", .{t}) else null;
    defer if (auth) |v| {
        std.crypto.secureZero(u8, v);
        allocator.free(v);
    };

    // Redirects are followed here, not by the client, so each one can be checked.
    var current = try allocator.dupe(u8, url);
    defer allocator.free(current);
    var hops: u8 = 0;
    while (true) {
        const uri = try std.Uri.parse(current);
        var req = try client.request(.GET, uri, .{
            .redirect_behavior = .unhandled,
            // The body is read as sent; a feed is text and the limit below counts what arrives.
            .headers = .{
                .accept_encoding = .{ .override = "identity" },
                .user_agent = .{ .override = "dkde-calendar" },
                .authorization = if (auth) |v| .{ .override = v } else .default,
            },
            .extra_headers = &.{.{ .name = "Accept", .value = accept }},
        });
        defer req.deinit();
        try req.sendBodiless();
        var response = try req.receiveHead(&.{});
        if (response.head.status.class() == .redirect) {
            if (bearer != null) return error.HttpStatus;
            if (hops >= max_redirects) return error.TooManyRedirects;
            const next = try redirectTarget(allocator, current, response.head.location orelse return error.HttpStatus);
            allocator.free(current);
            current = next;
            hops += 1;
            continue;
        }
        if (response.head.status != .ok) return error.HttpStatus;
        if (response.head.content_encoding != .identity) return error.UnsupportedEncoding;
        if (response.head.content_length) |n| if (n > max_feed_bytes) return error.TooLarge;
        var transfer_buffer: [64]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        return reader.allocRemaining(allocator, .limited(max_feed_bytes)) catch |e| switch (e) {
            error.StreamTooLong => error.TooLarge,
            error.ReadFailed => response.bodyErr() orelse error.ReadFailed,
            else => e,
        };
    }
}

/// A short sentence for an error from a refresh, for the status line.
pub fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.BadUrl, error.UriMissingHost, error.UriHostTooLong, error.InvalidFormat, error.InvalidPort => "The link is not a valid address.",
        error.NotHttps => "Only https links are used; a plain http link would show the secret to the network.",
        error.SignInNeeded => "GNOME Online Accounts could not give access: sign in to the account again in its window.",
        error.HttpStatus => "The server did not return the calendar (wrong link, or access removed).",
        error.TooLarge => "The calendar is larger than 8 MB.",
        error.InsecureRedirect => "The server tried to send the request to a plain http address, which is refused.",
        error.TooManyRedirects => "The server redirected the request too many times.",
        error.NotACalendar => "The address did not return an iCalendar file.",
        error.UnknownHostName, error.TemporaryNameServerFailure, error.NameServerFailure, error.ConnectionRefused, error.NetworkUnreachable, error.ConnectionTimedOut, error.ConnectionResetByPeer => "The server could not be reached.",
        error.TlsInitializationFailed, error.CertificateBundleLoadFailure => "A secure connection could not be made.",
        error.OutOfMemory => "Out of memory.",
        else => "The calendar could not be downloaded.",
    };
}

// ---- the cached copies --------------------------------------------------------------------------

/// `$XDG_CACHE_HOME/dkde/feeds`.
pub fn cacheDir(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/dkde/feeds", .{std.mem.span(glib.getUserCacheDir())});
}

pub fn cachePath(allocator: std.mem.Allocator, id: []const u8) ![]u8 {
    if (!validId(id)) return error.BadId;
    const dir = try cacheDir(allocator);
    defer allocator.free(dir);
    return std.fmt.allocPrint(allocator, "{s}/{s}.ics", .{ dir, id });
}

fn readWhole(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const z = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(z);
    var contents: [*]u8 = undefined;
    var len: usize = 0;
    var err: ?*glib.Error = null;
    if (glib.fileGetContents(z, &contents, &len, &err) == 0) {
        if (err) |e| e.free();
        return null;
    }
    defer glib.free(contents);
    if (len > max_feed_bytes) return null;
    return try allocator.dupe(u8, contents[0..len]);
}

/// Seconds since the epoch when the copy of `id` was last written, or null when none.
pub fn lastSync(allocator: std.mem.Allocator, id: []const u8) ?i64 {
    const path = cachePath(allocator, id) catch return null;
    defer allocator.free(path);
    // Its own Io: this is also called from the refresh thread.
    var threaded: std.Io.Threaded = .init_single_threaded;
    const st = std.Io.Dir.cwd().statFile(threaded.io(), path, .{}) catch return null;
    return @intCast(@divFloor(st.mtime.nanoseconds, std.time.ns_per_s));
}

/// Deletes the copy of every account in `ran` that is no longer in `current`: the user
/// removed it while its update was running, and the update wrote the copy back.
pub fn dropOrphans(allocator: std.mem.Allocator, ran: []const Account, current: []const Account) void {
    for (ran) |acct| {
        var still = false;
        for (current) |c| if (std.mem.eql(u8, c.id, acct.id)) {
            still = true;
        };
        if (still) continue;
        const path = cachePath(allocator, acct.id) catch continue;
        defer allocator.free(path);
        const z = allocator.dupeSentinel(u8, path, 0) catch continue;
        defer allocator.free(z);
        _ = std.c.unlink(z);
    }
}

/// True when two lists name the same accounts with the same settings: used to skip a
/// reload when the file changed for some other reason.
pub fn sameAccounts(a: []const Account, b: []const Account) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x.id, y.id) or !std.mem.eql(u8, x.url, y.url)) return false;
        if (!std.mem.eql(u8, x.goa, y.goa) or !std.mem.eql(u8, x.calendar, y.calendar)) return false;
        if (x.enabled != y.enabled or x.color != y.color or x.refresh_minutes != y.refresh_minutes) return false;
    }
    return true;
}

/// Tells programs that watch calendar.toml (the panel, for its reminders) that the
/// copies changed. For programs, such as Settings, that do not hold calendar.toml open.
pub fn markUpdated(allocator: std.mem.Allocator) void {
    var cfg = config_mod.Config.load(allocator, "calendar.toml") catch return;
    defer cfg.deinit();
    var b: [24]u8 = undefined;
    const stamp = std.fmt.bufPrintSentinel(&b, "{d}", .{@divFloor(glib.getRealTime(), std.time.us_per_s)}, 0) catch return;
    cfg.setString("sync", "feeds-updated", stamp) catch {};
}

/// True when `acct` should be refreshed on start: it is on, has an interval
/// and its copy is older than that (or missing).
pub fn isDue(allocator: std.mem.Allocator, acct: Account, now: i64) bool {
    if (!acct.enabled or acct.refresh_minutes <= 0) return false;
    const last = lastSync(allocator, acct.id) orelse return true;
    return now - last >= @as(i64, acct.refresh_minutes) * 60;
}

fn looksLikeCalendar(text: []const u8) bool {
    var t = text;
    if (std.mem.startsWith(u8, t, "\xEF\xBB\xBF")) t = t[3..]; // a byte order mark
    t = std.mem.trimStart(u8, t, " \t\r\n");
    return std.ascii.startsWithIgnoreCase(t, "BEGIN:VCALENDAR");
}

/// The events of a calendar of a GOA account, as iCalendar text.
fn fetchGoa(allocator: std.mem.Allocator, acct: Account) ![]u8 {
    const token = goa.accessToken(allocator, acct.goa) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.SignInNeeded,
    };
    defer {
        std.crypto.secureZero(u8, token);
        allocator.free(token);
    }
    return gcal.fetchIcs(allocator, token, acct.calendar, @divFloor(glib.getRealTime(), std.time.us_per_day));
}

/// Downloads the feed of `acct` and replaces its copy when what came back is a
/// calendar. Returns how many events it holds. Blocks: call from a worker thread.
pub fn refresh(allocator: std.mem.Allocator, acct: Account) !usize {
    if (!validId(acct.id)) return error.BadId;
    const body = if (acct.isGoa()) try fetchGoa(allocator, acct) else blk: {
        const url = try normalizeUrl(allocator, acct.url);
        defer allocator.free(url);
        break :blk try fetchText(allocator, url);
    };
    defer allocator.free(body);
    if (!looksLikeCalendar(body)) return error.NotACalendar;
    const count = try countEvents(allocator, body);

    const dir = try cacheDir(allocator);
    defer allocator.free(dir);
    const dir_z = try allocator.dupeSentinel(u8, dir, 0);
    defer allocator.free(dir_z);
    _ = glib.mkdirWithParents(dir_z, 0o700); // the events are private
    const path = try cachePath(allocator, acct.id);
    defer allocator.free(path);
    const path_z = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(path_z);
    var err: ?*glib.Error = null;
    if (glib.fileSetContents(path_z, body.ptr, @intCast(body.len), &err) == 0) {
        if (err) |e| e.free();
        return error.WriteFailed;
    }
    return count;
}

// ---- reading the copies --------------------------------------------------------------------------

/// How many events a copy holds once its repeats are worked out; used to
/// report what a refresh found, and to prove the text parses before it is kept.
fn countEvents(allocator: std.mem.Allocator, text: []const u8) !usize {
    var parsed = try ics.parseWith(allocator, text, null, .{ .window = defaultWindow() });
    defer parsed.deinit();
    return parsed.events.len;
}

fn defaultWindow() ics.Window {
    const now_days = @divFloor(glib.getRealTime(), std.time.us_per_day);
    return .{ .from = civil.Date.fromDays(now_days - window_back_days), .to = civil.Date.fromDays(now_days + window_forward_days) };
}

fn dupeEvent(a: std.mem.Allocator, ev: events.Event, acct: Account) !events.Event {
    var idbuf: [32]u8 = undefined;
    var out = ev;
    out.uid = try a.dupe(u8, ev.uid);
    // The account in the id keeps two feeds that share a UID apart.
    out.id = try std.fmt.allocPrint(a, "{s}-{s}", .{ acct.id, ics.idForUid(&idbuf, ev.uid) });
    out.title = try a.dupe(u8, ev.title);
    out.location = try a.dupe(u8, ev.location);
    out.notes = try a.dupe(u8, ev.notes);
    out.source = try a.dupe(u8, acct.id);
    if (out.color == .default) out.color = acct.color;
    return out;
}

/// Appends the events of every enabled account's copy in `dir` to `items`,
/// allocated from `a`. A missing or unreadable copy is skipped. Events with no
/// UID get one made from their title and start so a refresh finds them again.
fn appendFromDir(
    a: std.mem.Allocator,
    temp: std.mem.Allocator,
    dir: []const u8,
    accounts: []const Account,
    utc_to_local: ?ics.UtcToLocal,
    window: ics.Window,
    items: *std.ArrayList(events.Event),
) !void {
    for (accounts) |acct| {
        if (!acct.enabled or !validId(acct.id)) continue;
        const path = try std.fmt.allocPrint(temp, "{s}/{s}.ics", .{ dir, acct.id });
        defer temp.free(path);
        const text = (try readWhole(temp, path)) orelse continue;
        defer temp.free(text);
        var parsed = ics.parseWith(temp, text, utc_to_local, .{ .window = window }) catch continue;
        defer parsed.deinit();
        for (parsed.events) |ev| {
            var e = ev;
            if (e.uid.len == 0) {
                var db: [16]u8 = undefined;
                e.uid = try std.fmt.allocPrint(temp, "{s}-{s}-{d}", .{ e.title, events.formatDate(&db, e.date), e.start });
            }
            try items.append(a, try dupeEvent(a, e, acct));
        }
    }
}

/// Local wall-clock minutes (days * 1440 + minute of day) for a UTC time given the
/// same way: what `ics.parse` needs to show a UTC time in the user's zone.
pub fn utcToLocal(utc_minutes: i64) i64 {
    const utc = glib.DateTime.newFromUnixUtc(utc_minutes * 60) orelse return utc_minutes;
    defer utc.unref();
    const local = utc.toLocal() orelse return utc_minutes;
    defer local.unref();
    const days = civil.daysFromCivil(local.getYear(), @intCast(local.getMonth()), @intCast(local.getDayOfMonth()));
    return days * 1440 + local.getHour() * 60 + local.getMinute();
}

/// All the events to show: the user's own (dkde's calendar.toml) and those of the
/// enabled accounts' copies. With no accounts this is just `events.load`, and
/// no feed file is touched.
pub fn loadAll(
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
    accounts: []const Account,
    utc_to_local: ?ics.UtcToLocal,
) !events.List {
    var list = try events.load(allocator, cfg);
    errdefer list.deinit();
    var any = false;
    for (accounts) |acct| if (acct.enabled) {
        any = true;
    };
    if (!any) return list;

    const a = list.arena.allocator();
    var items: std.ArrayList(events.Event) = .empty;
    try items.appendSlice(a, list.items);
    const dir = try cacheDir(allocator);
    defer allocator.free(dir);
    var temp_arena = std.heap.ArenaAllocator.init(allocator);
    defer temp_arena.deinit();
    try appendFromDir(a, temp_arena.allocator(), dir, accounts, utc_to_local orelse utcToLocal, defaultWindow(), &items);
    list.items = try items.toOwnedSlice(a);
    return list;
}

// ---- refreshing in the background ---------------------------------------------------------------

pub const Result = struct {
    /// Events in the new copy; meaningful when `err` is null.
    count: usize = 0,
    err: ?anyerror = null,
    /// False when the account was left alone (off, or not due).
    ran: bool = false,
};

/// Refreshes each account in `accounts` in turn (blocking), writing one result each.
/// With `only_due`, an account is left alone unless `isDue`.
pub fn refreshAll(allocator: std.mem.Allocator, accounts: []const Account, only_due: bool, now: i64, results: []Result) void {
    for (accounts, results) |acct, *res| {
        res.* = .{};
        if (!acct.enabled) continue;
        if (only_due and !isDue(allocator, acct, now)) continue;
        res.ran = true;
        if (refresh(allocator, acct)) |n| res.count = n else |e| res.err = e;
    }
}

/// A refresh on a worker thread. The thread only downloads and writes the copies;
/// `done` is called back on the GLib main loop, where the program may touch its
/// widgets. Give it a thread-safe allocator (`std.heap.c_allocator`).
pub const Job = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    /// A private copy of the accounts: the caller's may change while this runs.
    accounts: []Account,
    results: []Result,
    only_due: bool,
    now: i64,
    done: *const fn (job: *const Job, user: ?*anyopaque) void,
    user: ?*anyopaque,

    /// Starts the refresh of `accounts`. Nothing is started (and `done` is not
    /// called) when no account would be looked at, so a program with no accounts
    /// does no work at all. Returns false in that case.
    pub fn start(
        allocator: std.mem.Allocator,
        accounts: []const Account,
        only_due: bool,
        done: *const fn (job: *const Job, user: ?*anyopaque) void,
        user: ?*anyopaque,
    ) !bool {
        const now: i64 = @divFloor(glib.getRealTime(), std.time.us_per_s);
        var any = false;
        for (accounts) |acct| if (acct.enabled and (!only_due or isDue(allocator, acct, now))) {
            any = true;
        };
        if (!any) return false;

        const job = try allocator.create(Job);
        errdefer allocator.destroy(job);
        job.arena = std.heap.ArenaAllocator.init(allocator);
        errdefer job.arena.deinit();
        const a = job.arena.allocator();
        const copy = try a.alloc(Account, accounts.len);
        for (accounts, copy) |src, *dst| dst.* = .{
            .id = try a.dupe(u8, src.id),
            .name = try a.dupe(u8, src.name),
            .url = try a.dupe(u8, src.url),
            .goa = try a.dupe(u8, src.goa),
            .calendar = try a.dupe(u8, src.calendar),
            .enabled = src.enabled,
            .refresh_minutes = src.refresh_minutes,
            .color = src.color,
        };
        // Everything that allocates from the arena is done before `job.*` is assigned: the
        // assignment copies the arena's state, which must not change after that.
        const results = try a.alloc(Result, accounts.len);
        job.* = .{
            .allocator = allocator,
            .arena = job.arena,
            .accounts = copy,
            .results = results,
            .only_due = only_due,
            .now = now,
            .done = done,
            .user = user,
        };
        const thread = try std.Thread.spawn(.{}, run, .{job});
        thread.detach();
        return true;
    }

    fn run(job: *Job) void {
        refreshAll(job.allocator, job.accounts, job.only_due, job.now, job.results);
        _ = glib.idleAdd(finish, job);
    }

    fn finish(data: ?*anyopaque) callconv(.c) c_int {
        const job: *Job = @ptrCast(@alignCast(data.?));
        job.done(job, job.user);
        const allocator = job.allocator;
        job.arena.deinit();
        allocator.destroy(job);
        return 0; // G_SOURCE_REMOVE
    }
};

// ---- tests -----------------------------------------------------------------------------------

const testing = std.testing;

test "normalizeUrl: webcal is https, plain http and junk are refused" {
    const a = testing.allocator;
    const ok = try normalizeUrl(a, "  webcal://cal.example.org/u/abc.ics\n");
    defer a.free(ok);
    try testing.expectEqualStrings("https://cal.example.org/u/abc.ics", ok);
    const ok2 = try normalizeUrl(a, "HTTPS://cal.example.org/x");
    defer a.free(ok2);
    try testing.expectEqualStrings("https://cal.example.org/x", ok2);
    try testing.expectError(error.NotHttps, normalizeUrl(a, "http://cal.example.org/x"));
    try testing.expectError(error.BadUrl, normalizeUrl(a, "ftp://cal.example.org/x"));
    try testing.expectError(error.BadUrl, normalizeUrl(a, "https://"));
    try testing.expectError(error.BadUrl, normalizeUrl(a, "https://exa mple.org/x"));
    try testing.expectError(error.BadUrl, normalizeUrl(a, ""));
}

test "hostOf shows the server and never a password or the secret path" {
    try testing.expectEqualStrings("cal.example.org", hostOf("https://cal.example.org/private/abc.ics?x=1"));
    try testing.expectEqualStrings("cal.example.org:8443", hostOf("https://user:pw@cal.example.org:8443/x"));
    try testing.expectEqualStrings("", hostOf("nonsense"));
}

test "validId keeps ids safe as file names" {
    try testing.expect(validId("a1b2-c_3"));
    try testing.expect(!validId(""));
    try testing.expect(!validId("../etc"));
    try testing.expect(!validId("a/b"));
    try testing.expect(!validId("a.b"));
    var long: [65]u8 = undefined;
    @memset(&long, 'x');
    try testing.expect(!validId(&long));
    try testing.expect(validId(long[0..64]));
}

test "every public function compiles (Zig skips what nothing uses)" {
    _ = &saveAccount;
    _ = &removeAccount;
    _ = &fetchText;
    _ = &fetchWith;
    _ = &refresh;
    _ = &refreshAll;
    _ = &loadAll;
    _ = &utcToLocal;
    _ = &dropOrphans;
    _ = &markUpdated;
    _ = &lastSync;
    _ = &isDue;
    _ = &Job.start;
    _ = &describe;
}

test "looksLikeCalendar" {
    try testing.expect(looksLikeCalendar("BEGIN:VCALENDAR\r\n"));
    try testing.expect(looksLikeCalendar("\xEF\xBB\xBF\r\nbegin:vcalendar\r\n"));
    try testing.expect(!looksLikeCalendar("<html>Sign in</html>"));
}

test "events are read from a copy, marked read-only and given their account" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    defer a.free(dir);
    const feed =
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:one@example.org\r\nDTSTART:20261103T100000\r\n" ++
        "DTEND:20261103T110000\r\nSUMMARY:Dentist\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "work.ics", .data = feed });

    const accounts = [_]Account{
        .{ .id = "work", .name = "Work", .url = "https://x/y", .color = .blue },
        .{ .id = "off", .name = "Off", .url = "https://x/z", .enabled = false },
        .{ .id = "none", .name = "No copy yet", .url = "https://x/w" },
    };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var temp_arena = std.heap.ArenaAllocator.init(a);
    defer temp_arena.deinit();
    var items: std.ArrayList(events.Event) = .empty;
    const w: ics.Window = .{ .from = .{ .year = 2026, .month = 1, .day = 1 }, .to = .{ .year = 2027, .month = 1, .day = 1 } };
    try appendFromDir(arena.allocator(), temp_arena.allocator(), dir, &accounts, null, w, &items);
    try testing.expectEqual(@as(usize, 1), items.items.len);
    const e = items.items[0];
    try testing.expectEqualStrings("Dentist", e.title);
    try testing.expectEqualStrings("work", e.source);
    try testing.expect(std.mem.startsWith(u8, e.id, "work-"));
    try testing.expectEqual(events.Color.blue, e.color);
}

/// Answers one request with `status` and `body`, then returns.
fn serveOnce(server: *std.Io.net.Server, io: std.Io, status: std.http.Status, body: []const u8) void {
    const stream = server.accept(io) catch return;
    defer stream.close(io);
    var read_buffer: [4096]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var writer = stream.writer(io, &write_buffer);
    var http_server = std.http.Server.init(&reader.interface, &writer.interface);
    var request = http_server.receiveHead() catch return;
    request.respond(body, .{ .status = status }) catch {};
}

fn fetchFromLocalServer(status: std.http.Status, body: []const u8) ![]u8 {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    const thread = try std.Thread.spawn(.{}, serveOnce, .{ &server, io, status, body });
    defer thread.join();
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/private/cal.ics", .{server.socket.address.ip4.port});
    return fetchText(testing.allocator, url);
}

test "fetchText reads a feed from a server and rejects an error page" {
    const feed = "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n";
    const got = try fetchFromLocalServer(.ok, feed);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(feed, got);
    try testing.expectError(error.HttpStatus, fetchFromLocalServer(.not_found, "gone"));
}

test "redirects: https and same-server paths only" {
    const a = testing.allocator;
    const ok = try redirectTarget(a, "https://cal.example.org/a/b.ics", "https://other.example.net/x.ics");
    defer a.free(ok);
    try testing.expectEqualStrings("https://other.example.net/x.ics", ok);
    const rel = try redirectTarget(a, "https://cal.example.org/a/b.ics", "/moved/b.ics");
    defer a.free(rel);
    try testing.expectEqualStrings("https://cal.example.org/moved/b.ics", rel);
    try testing.expectError(error.InsecureRedirect, redirectTarget(a, "https://cal.example.org/a", "http://cal.example.org/a"));
    try testing.expectError(error.InsecureRedirect, redirectTarget(a, "https://cal.example.org/a", "//evil.example.net/a"));
    try testing.expectError(error.InsecureRedirect, redirectTarget(a, "https://cal.example.org/a", "relative.ics"));
}

test "sameAccounts notices a change and ignores a rename" {
    const a1 = [_]Account{.{ .id = "x", .name = "One", .url = "https://h/p" }};
    const a2 = [_]Account{.{ .id = "x", .name = "Renamed", .url = "https://h/p" }};
    const a3 = [_]Account{.{ .id = "x", .name = "One", .url = "https://h/p", .enabled = false }};
    try testing.expect(sameAccounts(&a1, &a2));
    try testing.expect(!sameAccounts(&a1, &a3));
    try testing.expect(!sameAccounts(&a1, &.{}));
}
