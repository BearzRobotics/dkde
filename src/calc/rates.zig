//! Exchange rates for the calculator: fiat money, crypto coins and Goldbacks,
//! each from its own public source, kept in a cache file so conversions work
//! offline from the last update.
//!
//!   fiat       European Central Bank daily reference rates (about 30 currencies;
//!              the ECB publishes one rate a working day, not a live price)
//!   crypto     CoinGecko's public "simple price" list, in US dollars
//!   Goldback   goldback.com's own daily exchange rate (updated daily at 10 AM MST):
//!              the page https://www.goldback.com/exchange-rates/ reads it from
//!              https://www.goldback.com/gb-proxy.php. That address is not documented
//!              as an interface; if it changes, Goldbacks show their last rate and the
//!              other sources go on working.
//!
//! Nothing here touches the network by itself: the program asks for an update
//! only when the user chooses it (or has turned on the daily update).

const std = @import("std");
const quantity = @import("quantity.zig");
const Currency = quantity.Currency;

pub const ecb_url = "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml";
pub const goldback_url = "https://www.goldback.com/gb-proxy.php";
pub const coingecko_url = blk: {
    var ids: []const u8 = "";
    for (quantity.crypto_list, 0..) |c, i| ids = ids ++ (if (i > 0) "," else "") ++ c.id;
    break :blk "https://api.coingecko.com/api/v3/simple/price?ids=" ++ ids ++ "&vs_currencies=usd";
};

pub const source_ecb = "European Central Bank";
pub const source_coingecko = "CoinGecko";
pub const source_goldback = "goldback.com";

/// A number as typed in a feed: digits, one point, an optional exponent.
fn plainNumber(s: []const u8) bool {
    if (s.len == 0 or s.len > 40) return false;
    var digits: usize = 0;
    var seen_e = false;
    for (s, 0..) |c, i| {
        if (std.ascii.isDigit(c)) {
            digits += 1;
        } else if (c == '.') {
            if (seen_e) return false;
        } else if ((c == 'e' or c == 'E') and !seen_e and digits > 0) {
            seen_e = true;
        } else if ((c == '-' or c == '+') and i > 0 and (s[i - 1] == 'e' or s[i - 1] == 'E')) {} else return false;
    }
    return digits > 0;
}

fn positive(s: []const u8) bool {
    const f = std.fmt.parseFloat(f64, s) catch return false;
    return std.math.isFinite(f) and f > 0;
}

/// ECB's eurofxref XML: `<Cube time='2026-11-13'>` and `<Cube currency='USD' rate='1.1052'/>`.
pub fn parseEcb(a: std.mem.Allocator, xml: []const u8) ![]Currency {
    const t = std.mem.indexOf(u8, xml, "time='") orelse return error.BadFeed;
    const t_end = std.mem.indexOfScalarPos(u8, xml, t + 6, '\'') orelse return error.BadFeed;
    const date = xml[t + 6 .. t_end];
    if (date.len != 10) return error.BadFeed;
    var codes: std.ArrayList([]const u8) = .empty;
    var rates: std.ArrayList([]const u8) = .empty;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, xml, pos, "currency='")) |i| {
        const c_end = std.mem.indexOfScalarPos(u8, xml, i + 10, '\'') orelse break;
        const code = xml[i + 10 .. c_end];
        const r = std.mem.indexOfPos(u8, xml, c_end, "rate='") orelse break;
        const r_end = std.mem.indexOfScalarPos(u8, xml, r + 6, '\'') orelse break;
        const rate = xml[r + 6 .. r_end];
        pos = r_end;
        if (code.len != 3 or !plainNumber(rate) or !positive(rate)) continue;
        try codes.append(a, try a.dupe(u8, code));
        try rates.append(a, try a.dupe(u8, rate));
    }
    // Rates are per euro; everything here is in dollars.
    var usd_rate: ?[]const u8 = null;
    for (codes.items, rates.items) |c, r| if (std.mem.eql(u8, c, "USD")) {
        usd_rate = r;
    };
    const per_eur = usd_rate orelse return error.BadFeed;
    var out: std.ArrayList(Currency) = .empty;
    try out.append(a, .{ .code = "USD", .kind = .fiat, .usd = "1", .date = try a.dupe(u8, date), .source = source_ecb });
    try out.append(a, .{ .code = "EUR", .kind = .fiat, .usd = per_eur, .date = try a.dupe(u8, date), .source = source_ecb });
    for (codes.items, rates.items) |c, r| {
        if (std.mem.eql(u8, c, "USD")) continue;
        try out.append(a, .{
            .code = c,
            .kind = .fiat,
            .usd = try std.fmt.allocPrint(a, "{s}/{s}", .{ per_eur, r }),
            .date = try a.dupe(u8, date),
            .source = source_ecb,
        });
    }
    return out.items;
}

fn jsonNumber(a: std.mem.Allocator, v: std.json.Value) ?[]const u8 {
    const f: f64 = switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |x| x,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch return null,
        else => return null,
    };
    if (!std.math.isFinite(f) or f <= 0) return null;
    return std.fmt.allocPrint(a, "{d}", .{f}) catch null;
}

/// `{"bitcoin":{"usd":66480},…}`; `when` is the date and time of the download.
pub fn parseCoingecko(a: std.mem.Allocator, json: []const u8, when: []const u8) ![]Currency {
    const parsed = std.json.parseFromSlice(std.json.Value, a, json, .{}) catch return error.BadFeed;
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.BadFeed,
    };
    var out: std.ArrayList(Currency) = .empty;
    for (quantity.crypto_list) |c| {
        const entry = root.get(c.id) orelse continue;
        const obj = switch (entry) {
            .object => |o| o,
            else => continue,
        };
        const price = jsonNumber(a, obj.get("usd") orelse continue) orelse continue;
        try out.append(a, .{ .code = c.code, .kind = .crypto, .usd = price, .date = try a.dupe(u8, when), .source = source_coingecko });
    }
    if (out.items.len == 0) return error.BadFeed;
    return out.items;
}

/// "2026-11-14 17:30 UTC" from a unix time.
pub fn dateText(a: std.mem.Allocator, unix: i64) ![]u8 {
    const secs: u64 = @intCast(@max(unix, 0));
    const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.allocPrint(a, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC", .{
        day.year,
        md.month.numeric(),
        md.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
    });
}

/// `{"success":true,"timestamp":…,"quotes":{"USDUSD":7.75,…}}`: USDUSD is what one Goldback is worth in dollars.
pub fn parseGoldback(a: std.mem.Allocator, json: []const u8) ![]Currency {
    const parsed = std.json.parseFromSlice(std.json.Value, a, json, .{}) catch return error.BadFeed;
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.BadFeed,
    };
    const quotes = switch (root.get("quotes") orelse return error.BadFeed) {
        .object => |o| o,
        else => return error.BadFeed,
    };
    const price = jsonNumber(a, quotes.get("USDUSD") orelse return error.BadFeed) orelse return error.BadFeed;
    var when: []const u8 = "";
    if (root.get("timestamp")) |ts| switch (ts) {
        .integer => |i| when = try dateText(a, i),
        else => {},
    };
    const out = try a.alloc(Currency, 1);
    out[0] = .{ .code = "GBK", .kind = .goldback, .usd = price, .date = when, .source = source_goldback };
    return out;
}

// ---- the cache file ----------------------------------------------------------------

/// One line a currency: code, kind, dollars per unit, date, source (tab apart).
pub fn serialize(a: std.mem.Allocator, list: []const Currency) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (list) |c| try out.print(a, "{s}\t{s}\t{s}\t{s}\t{s}\n", .{ c.code, @tagName(c.kind), c.usd, c.date, c.source });
    return out.toOwnedSlice(a);
}

pub fn deserialize(a: std.mem.Allocator, text: []const u8) ![]Currency {
    var out: std.ArrayList(Currency) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var f = std.mem.splitScalar(u8, line, '\t');
        const code = f.next() orelse continue;
        const kind_text = f.next() orelse continue;
        const usd = f.next() orelse continue;
        const date = f.next() orelse continue;
        const source = f.next() orelse continue;
        const kind = std.meta.stringToEnum(quantity.Kind, kind_text) orelse continue;
        if (!quantity.currencyKnown(code)) continue;
        if (!validRate(usd)) continue;
        try out.append(a, .{
            .code = quantity.canonicalCode(code) orelse continue,
            .kind = kind,
            .usd = try a.dupe(u8, usd),
            .date = try a.dupe(u8, date),
            .source = try a.dupe(u8, source),
        });
    }
    return out.items;
}

/// "1.1052", "1.1052/176.83", "1e-7": what quantity.zig can read as a rate.
fn validRate(s: []const u8) bool {
    if (std.mem.indexOfScalar(u8, s, '/')) |i| return plainNumber(s[0..i]) and plainNumber(s[i + 1 ..]) and positive(s[0..i]) and positive(s[i + 1 ..]);
    return plainNumber(s) and positive(s);
}

/// New rates over old ones: a code in `new` replaces the same code in `old`.
pub fn merge(a: std.mem.Allocator, old: []const Currency, new: []const Currency) ![]Currency {
    var out: std.ArrayList(Currency) = .empty;
    for (old) |o| {
        var replaced = false;
        for (new) |n| if (std.mem.eql(u8, n.code, o.code)) {
            replaced = true;
        };
        if (!replaced) try out.append(a, o);
    }
    try out.appendSlice(a, new);
    return out.items;
}

// ---- tests -----------------------------------------------------------------------------

test "ECB, CoinGecko and Goldback feeds are read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ecb = try parseEcb(a, "<Cube time='2026-11-13'><Cube currency='USD' rate='1.1052'/><Cube currency='JPY' rate='176.83'/></Cube>");
    try std.testing.expectEqual(@as(usize, 3), ecb.len);
    try std.testing.expectEqualStrings("1.1052/176.83", ecb[2].usd);
    const cg = try parseCoingecko(a, "{\"bitcoin\":{\"usd\":66480},\"ethereum\":{\"usd\":3000.5}}", "2026-11-14 08:00 UTC");
    try std.testing.expectEqual(@as(usize, 2), cg.len);
    try std.testing.expectEqualStrings("BTC", cg[0].code);
    const gb = try parseGoldback(a, "{\"success\":true,\"timestamp\":1794497409,\"quotes\":{\"USDUSD\":7.75}}");
    try std.testing.expectEqualStrings("7.75", gb[0].usd);
    try std.testing.expectEqualStrings("2026-11-14 14:30 UTC", gb[0].date);
    try std.testing.expectError(error.BadFeed, parseGoldback(a, "{\"quotes\":{}}"));
}

test "the cache file round-trips and refuses junk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const list = [_]Currency{
        .{ .code = "EUR", .kind = .fiat, .usd = "1.1052", .date = "2026-11-13", .source = source_ecb },
        .{ .code = "GBK", .kind = .goldback, .usd = "7.75", .date = "x", .source = source_goldback },
    };
    const text = try serialize(a, &list);
    const back = try deserialize(a, text);
    try std.testing.expectEqual(@as(usize, 2), back.len);
    try std.testing.expectEqualStrings("7.75", back[1].usd);
    const junk = try deserialize(a, "EUR\tfiat\t$(rm)\t-\t-\nXXX\tfiat\t1\t-\t-\nEUR\tfiat\t-5\t-\t-\n");
    try std.testing.expectEqual(@as(usize, 0), junk.len);
}
