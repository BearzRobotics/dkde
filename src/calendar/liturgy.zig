//! The liturgical calendars the calendar app can lay over the months: the
//! General Roman Calendar as it is now (Novus Ordo) and as it was in 1962
//! (the Traditional Latin Mass). Fixed days come from a text table
//! (liturgy-no.txt, liturgy-1962.txt, built in and replaceable from
//! ~/.config/dkde/); everything that moves with Easter or Advent is worked out
//! here. `compute` says what is celebrated on a day and what else is kept.

const std = @import("std");
const glib = @import("glib2");
const common = @import("common");
const civil = common.civil;
const fasting = @import("fasting.zig");
const orthodox = @import("orthodox.zig");

pub const Date = civil.Date;

pub const Kind = enum {
    novus_ordo,
    tlm1962,
    orthodox_ru,

    pub fn fileName(self: Kind) []const u8 {
        return switch (self) {
            .novus_ordo => "liturgy-no.txt",
            .tlm1962 => "liturgy-1962.txt",
            .orthodox_ru => "liturgy-ru.txt",
        };
    }

    pub fn builtinText(self: Kind) []const u8 {
        return switch (self) {
            .novus_ordo => @embedFile("liturgy-no.txt"),
            .tlm1962 => @embedFile("liturgy-1962.txt"),
            .orthodox_ru => @embedFile("liturgy-ru.txt"),
        };
    }
};

pub const Color = enum {
    white,
    red,
    green,
    violet,
    rose,
    black,
    blue,
    gold,

    pub fn cssClass(self: Color) []const u8 {
        return switch (self) {
            .white => "lit-white",
            .red => "lit-red",
            .green => "lit-green",
            .violet => "lit-violet",
            .rose => "lit-rose",
            .black => "lit-black",
            .blue => "lit-blue",
            .gold => "lit-gold",
        };
    }

    pub fn label(self: Color) []const u8 {
        return @tagName(self);
    }
};

// ---- the fixed-day tables ----------------------------------------------------------------------

/// Precedence, lower wins. Novus Ordo uses the numbers of the Universal Norms
/// (1 the Triduum, Easter, Sundays of Advent/Lent/Easter...; 2 solemnities;
/// 4 feasts of the Lord; 5 Sundays of Christmas and Ordinary Time; 6 feasts;
/// 8 Lent weekdays...; 9 memorials; 10 optional memorials; 11, 12 weekdays).
/// 1962 uses class * 10 plus a place within the class (see `Tlm`).
pub const Entry = struct {
    month: u8,
    day: u8,
    p: u8,
    class: u8,
    color: Color,
    name: []const u8,
};

const Tlm = struct {
    const temporal_1: u8 = 10; // Sundays and days of the first class
    const lord_1: u8 = 11; // feasts of the Lord of the first class
    const saint_1: u8 = 15;
    const lord_2: u8 = 19; // beats a second-class Sunday
    const sunday_2: u8 = 20;
    const saint_2: u8 = 25;
    const feria_2: u8 = 28; // Ember days, greater ferias
    const saint_3: u8 = 35;
    const feria_3: u8 = 38;
    const saint_4: u8 = 45;
    const feria_4: u8 = 48;
};

pub const Table = struct {
    allocator: std.mem.Allocator,
    text: []u8,
    entries: []Entry,
    kind: Kind,

    pub fn deinit(self: *Table) void {
        self.allocator.free(self.entries);
        self.allocator.free(self.text);
    }

    /// The user's copy in ~/.config/dkde if there is one, else the built-in table.
    pub fn load(allocator: std.mem.Allocator, kind: Kind) !Table {
        if (common.paths.userConfigFile(allocator, kind.fileName())) |path| {
            defer allocator.free(path);
            var contents: [*]u8 = undefined;
            var len: usize = 0;
            if (glib.fileGetContents(path, &contents, &len, null) != 0) {
                defer glib.free(contents);
                if (parse(allocator, kind, contents[0..len])) |t| return t else |_| {}
            }
        } else |_| {}
        return parse(allocator, kind, kind.builtinText());
    }

    pub fn parse(allocator: std.mem.Allocator, kind: Kind, source: []const u8) !Table {
        const text = try allocator.dupe(u8, source);
        errdefer allocator.free(text);
        var list: std.ArrayList(Entry) = .empty;
        errdefer list.deinit(allocator);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            var parts = std.mem.splitScalar(u8, line, '|');
            const date = std.mem.trim(u8, parts.next() orelse continue, " \t");
            const rank = std.mem.trim(u8, parts.next() orelse continue, " \t");
            const color = std.mem.trim(u8, parts.next() orelse continue, " \t");
            const name = std.mem.trim(u8, parts.rest(), " \t");
            if (date.len != 5 or date[2] != '-' or name.len == 0 or color.len != 1) continue;
            const month = std.fmt.parseInt(u8, date[0..2], 10) catch continue;
            const day = std.fmt.parseInt(u8, date[3..5], 10) catch continue;
            const col: Color = switch (color[0]) {
                'W' => .white,
                'R' => .red,
                'G' => .green,
                'V' => .violet,
                'P' => .rose,
                'B' => .black,
                'L' => .blue,
                'Y' => .gold,
                else => continue,
            };
            const ranked = rankOf(kind, rank) orelse continue;
            try list.append(allocator, .{ .month = month, .day = day, .p = ranked.p, .class = ranked.class, .color = col, .name = name });
        }
        return .{ .allocator = allocator, .text = text, .entries = try list.toOwnedSlice(allocator), .kind = kind };
    }
};

const Ranked = struct { p: u8, class: u8 };

fn rankOf(kind: Kind, code: []const u8) ?Ranked {
    switch (kind) {
        .novus_ordo => {
            if (std.mem.eql(u8, code, "S+")) return .{ .p = 1, .class = 0 };
            if (std.mem.eql(u8, code, "S")) return .{ .p = 2, .class = 0 };
            if (std.mem.eql(u8, code, "FL")) return .{ .p = 4, .class = 0 };
            if (std.mem.eql(u8, code, "F")) return .{ .p = 6, .class = 0 };
            if (std.mem.eql(u8, code, "M")) return .{ .p = 9, .class = 0 };
            if (std.mem.eql(u8, code, "O")) return .{ .p = 10, .class = 0 };
        },
        .orthodox_ru => {
            if (std.mem.eql(u8, code, "G")) return .{ .p = 1, .class = 0 };
            if (std.mem.eql(u8, code, "V")) return .{ .p = 2, .class = 0 };
            if (std.mem.eql(u8, code, "F")) return .{ .p = 3, .class = 0 };
            if (std.mem.eql(u8, code, "S")) return .{ .p = 6, .class = 0 };
            if (std.mem.eql(u8, code, "C")) return .{ .p = 9, .class = 0 };
        },
        .tlm1962 => {
            if (std.mem.eql(u8, code, "1L")) return .{ .p = Tlm.lord_1, .class = 1 };
            if (std.mem.eql(u8, code, "1")) return .{ .p = Tlm.saint_1, .class = 1 };
            if (std.mem.eql(u8, code, "2L")) return .{ .p = Tlm.lord_2, .class = 2 };
            if (std.mem.eql(u8, code, "2")) return .{ .p = Tlm.saint_2, .class = 2 };
            if (std.mem.eql(u8, code, "3")) return .{ .p = Tlm.saint_3, .class = 3 };
            if (std.mem.eql(u8, code, "4")) return .{ .p = Tlm.saint_4, .class = 4 };
        },
    }
    return null;
}

// ---- the answer --------------------------------------------------------------------------------

pub const Line = struct { label: []const u8, text: []const u8 };

/// What a day is. Strings point into the table or into `buf`, so a Day must
/// stay where it is while they are used.
pub const Day = struct {
    name: []const u8 = "",
    rank: []const u8 = "",
    color: Color = .green,
    season: []const u8 = "",
    /// Lectionary cycle (Novus Ordo only), for example "Sunday Year A, weekday Year II".
    cycle: []const u8 = "",
    /// Food emoji for a fast or abstinence day, and what they mean (empty on other days).
    fast_emoji: []const u8 = "",
    fast_text: []const u8 = "",
    /// An ordinary weekday with no feast of its own; a month grid can leave it out.
    plain: bool = false,
    also: [8]Line = undefined,
    n_also: usize = 0,
    buf: [768]u8 = undefined,
    used: usize = 0,

    pub fn alsoLines(self: *const Day) []const Line {
        return self.also[0..self.n_also];
    }

    pub fn print(self: *Day, comptime fmt: []const u8, args: anytype) []const u8 {
        const rest = self.buf[self.used..];
        const text = std.fmt.bufPrint(rest, fmt, args) catch return "";
        self.used += text.len;
        return text;
    }

    pub fn ord(self: *Day, n: i64) []const u8 {
        const k: u64 = @intCast(@max(n, 0));
        const suffix: []const u8 = if (k % 100 >= 11 and k % 100 <= 13) "th" else switch (k % 10) {
            1 => "st",
            2 => "nd",
            3 => "rd",
            else => "th",
        };
        return self.print("{d}{s}", .{ k, suffix });
    }

    pub fn addAlso(self: *Day, label: []const u8, text: []const u8) void {
        if (self.n_also == self.also.len) return;
        self.also[self.n_also] = .{ .label = label, .text = text };
        self.n_also += 1;
    }
};

const weekdays = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };

pub fn weekdayName(wd: u8) []const u8 {
    return weekdays[wd % 7];
}

/// A candidate for the day's celebration.
const Cand = struct {
    name: []const u8,
    p: u8,
    class: u8 = 0,
    color: Color,
    /// Kept apart so a sanctoral entry can be told from the day of the season.
    sanctoral: bool = false,
    /// A solemnity or first-class feast that may have to move to another day.
    movable: bool = false,
};

const CandList = struct {
    items: [24]Cand = undefined,
    n: usize = 0,

    fn add(self: *CandList, c: Cand) void {
        if (self.n == self.items.len) return;
        self.items[self.n] = c;
        self.n += 1;
    }

    fn best(self: *const CandList) usize {
        var at: usize = 0;
        for (self.items[0..self.n], 0..) |c, i| if (c.p < self.items[at].p) {
            at = i;
        };
        return at;
    }

    /// The lowest p among all but index `skip`.
    fn bestExcept(self: *const CandList, skip: usize) u8 {
        var low: u8 = 255;
        for (self.items[0..self.n], 0..) |c, i| if (i != skip and c.p < low) {
            low = c.p;
        };
        return low;
    }
};

fn nth(n: i64) u8 {
    return @intCast(n);
}

fn dateOf(year: i32, month: u8, day: u8) i64 {
    return civil.daysFromCivil(year, month, day);
}

/// The first Sunday of Advent: the Sunday on or after November 27.
fn adventStart(year: i32) i64 {
    const nov27 = dateOf(year, 11, 27);
    return nov27 + @mod(7 - @as(i64, civil.weekdayOfDays(nov27)), 7);
}

/// First Sunday on or after `n`.
fn sundayOnOrAfter(n: i64) i64 {
    return n + @mod(7 - @as(i64, civil.weekdayOfDays(n)), 7);
}

// =============================================================================================
// Novus Ordo
// =============================================================================================

const NoTemporal = struct { cand: Cand, season: []const u8 };

fn temporalNo(d: Date, out: *Day) NoTemporal {
    const y = d.year;
    const n = d.days();
    const wd = d.weekday();
    const e = civil.easter(y).days();
    const a1 = adventStart(y);
    const jan7 = dateOf(y, 1, 7);
    const baptism = sundayOnOrAfter(jan7);
    const ash = e - 46;
    const dn = weekdays[wd];

    if (n >= a1) {
        const dec25 = dateOf(y, 12, 25);
        if (n < dec25) { // Advent
            const k = @divFloor(n - a1, 7) + 1;
            if (wd == 0) return .{ .cand = .{ .name = out.print("{s} Sunday of Advent", .{out.ord(k)}), .p = 1, .color = if (k == 3) .rose else .violet }, .season = "Advent" };
            if (d.month == 12 and d.day >= 17) return .{ .cand = .{ .name = out.print("{s} of Advent, December {d}", .{ dn, d.day }), .p = 8, .color = .violet }, .season = "Advent" };
            return .{ .cand = .{ .name = out.print("{s} of the {s} week of Advent", .{ dn, out.ord(k) }), .p = 11, .color = .violet }, .season = "Advent" };
        }
        // Christmas, December 25-31
        if (wd == 0) return .{ .cand = .{ .name = "Sunday in the Octave of Christmas", .p = 5, .color = .white }, .season = "Christmas" };
        return .{ .cand = .{ .name = out.print("{s} day in the Octave of Christmas", .{out.ord(d.day - 24)}), .p = 8, .color = .white }, .season = "Christmas" };
    }

    if (n <= baptism) { // January: Christmas time continues
        if (n == baptism) return .{ .cand = .{ .name = "The Baptism of the Lord", .p = 4, .color = .white }, .season = "Christmas" };
        if (d.month == 1 and d.day <= 5) {
            if (wd == 0) return .{ .cand = .{ .name = "Second Sunday after Christmas", .p = 5, .color = .white }, .season = "Christmas" };
            return .{ .cand = .{ .name = out.print("{s} of Christmas time, January {d}", .{ dn, d.day }), .p = 11, .color = .white }, .season = "Christmas" };
        }
        return .{ .cand = .{ .name = out.print("{s} after Epiphany", .{dn}), .p = 11, .color = .white }, .season = "Christmas" };
    }

    if (n < ash) { // Ordinary Time, first part
        const w = @divFloor(n - (baptism + 1), 7) + (if (wd == 0) @as(i64, 2) else 1);
        if (wd == 0) return .{ .cand = .{ .name = out.print("{s} Sunday in Ordinary Time", .{out.ord(w)}), .p = 5, .color = .green }, .season = "Ordinary Time" };
        return .{ .cand = .{ .name = out.print("{s} of the {s} week in Ordinary Time", .{ dn, out.ord(w) }), .p = 12, .color = .green }, .season = "Ordinary Time" };
    }

    if (n < e) { // Lent
        const palm = e - 7;
        if (n == ash) return .{ .cand = .{ .name = "Ash Wednesday", .p = 1, .color = .violet }, .season = "Lent" };
        if (n < ash + 4) return .{ .cand = .{ .name = out.print("{s} after Ash Wednesday", .{dn}), .p = 8, .color = .violet }, .season = "Lent" };
        if (n >= palm) {
            if (n == palm) return .{ .cand = .{ .name = "Palm Sunday of the Passion of the Lord", .p = 1, .color = .red }, .season = "Holy Week" };
            if (n == e - 3) return .{ .cand = .{ .name = "Holy Thursday", .p = 1, .color = .white }, .season = "Easter Triduum" };
            if (n == e - 2) return .{ .cand = .{ .name = "Good Friday of the Lord's Passion", .p = 1, .color = .red }, .season = "Easter Triduum" };
            if (n == e - 1) return .{ .cand = .{ .name = "Holy Saturday", .p = 1, .color = .violet }, .season = "Easter Triduum" };
            return .{ .cand = .{ .name = out.print("{s} of Holy Week", .{dn}), .p = 1, .color = .violet }, .season = "Holy Week" };
        }
        const k = @divFloor(n - (e - 42), 7) + 1;
        if (wd == 0) return .{ .cand = .{ .name = out.print("{s} Sunday of Lent", .{out.ord(k)}), .p = 1, .color = if (k == 4) .rose else .violet }, .season = "Lent" };
        return .{ .cand = .{ .name = out.print("{s} of the {s} week of Lent", .{ dn, out.ord(k) }), .p = 8, .color = .violet }, .season = "Lent" };
    }

    if (n <= e + 49) { // Easter time
        const k = @divFloor(n - e, 7) + 1;
        if (n == e) return .{ .cand = .{ .name = "Easter Sunday of the Resurrection of the Lord", .p = 1, .color = .white }, .season = "Easter" };
        if (n == e + 49) return .{ .cand = .{ .name = "Pentecost Sunday", .p = 1, .color = .red }, .season = "Easter" };
        if (n == e + 39) return .{ .cand = .{ .name = "The Ascension of the Lord", .p = 1, .color = .white }, .season = "Easter" };
        if (n < e + 7) return .{ .cand = .{ .name = out.print("{s} in the Octave of Easter", .{dn}), .p = 1, .color = .white }, .season = "Easter" };
        if (n == e + 7) return .{ .cand = .{ .name = "Second Sunday of Easter (Divine Mercy Sunday)", .p = 1, .color = .white }, .season = "Easter" };
        if (wd == 0) return .{ .cand = .{ .name = out.print("{s} Sunday of Easter", .{out.ord(k)}), .p = 1, .color = .white }, .season = "Easter" };
        return .{ .cand = .{ .name = out.print("{s} of the {s} week of Easter", .{ dn, out.ord(k) }), .p = 11, .color = .white }, .season = "Easter" };
    }

    // Ordinary Time, second part: counted back from Advent so the last week is the 34th.
    const w = 35 - @divFloor(a1 - n + 6, 7);
    if (wd == 0) return .{ .cand = .{ .name = out.print("{s} Sunday in Ordinary Time", .{out.ord(w)}), .p = 5, .color = .green }, .season = "Ordinary Time" };
    return .{ .cand = .{ .name = out.print("{s} of the {s} week in Ordinary Time", .{ dn, out.ord(w) }), .p = 12, .color = .green }, .season = "Ordinary Time" };
}

/// The moving feasts and memorials that are not on the temporal cycle itself.
fn movableNo(d: Date, list: *CandList) void {
    const y = d.year;
    const n = d.days();
    const e = civil.easter(y).days();
    const wd = d.weekday();
    if (n == e + 50) list.add(.{ .name = "Mary, Mother of the Church", .p = 9, .color = .white, .sanctoral = true });
    if (n == e + 56) list.add(.{ .name = "The Most Holy Trinity", .p = 2, .color = .white, .sanctoral = true });
    if (n == e + 60) list.add(.{ .name = "The Most Holy Body and Blood of Christ (Corpus Christi)", .p = 2, .color = .white, .sanctoral = true });
    if (n == e + 68) list.add(.{ .name = "The Most Sacred Heart of Jesus", .p = 2, .color = .white, .sanctoral = true });
    if (n == e + 69) list.add(.{ .name = "The Immaculate Heart of the Blessed Virgin Mary", .p = 9, .color = .white, .sanctoral = true });
    if (n == adventStart(y) - 7) list.add(.{ .name = "Our Lord Jesus Christ, King of the Universe", .p = 2, .color = .white, .sanctoral = true });
    // The Holy Family: the Sunday within the Octave of Christmas, else December 30.
    if (d.month == 12 and d.day >= 26) {
        const dec25 = dateOf(y, 12, 25);
        const has_sunday = civil.weekdayOfDays(dec25) != 0;
        if ((has_sunday and wd == 0) or (!has_sunday and d.day == 30))
            list.add(.{ .name = "The Holy Family of Jesus, Mary and Joseph", .p = 4, .color = .white, .sanctoral = true });
    }
}

fn collectNo(table: *const Table, d: Date, out: *Day, list: *CandList, season: *[]const u8) void {
    const t = temporalNo(d, out);
    season.* = t.season;
    list.add(t.cand);
    movableNo(d, list);
    for (table.entries) |en| {
        if (en.month == d.month and en.day == d.day) list.add(.{ .name = en.name, .p = en.p, .color = en.color, .sanctoral = true, .movable = en.p <= 2 });
    }
}

/// Where a solemnity that cannot be kept on its day goes.
fn transferTargetNo(table: *const Table, d: Date, name: []const u8) Date {
    const y = d.year;
    const n = d.days();
    const e = civil.easter(y).days();
    const sunday = d.weekday() == 0;
    const lent_sunday = sunday and n >= e - 42 and n <= e - 14;
    if (std.mem.startsWith(u8, name, "Joseph, Spouse")) {
        if (n >= e - 7 and n < e) return Date.fromDays(e - 8); // the Saturday before Palm Sunday
        if (lent_sunday) return Date.fromDays(n + 1);
    }
    if (std.mem.startsWith(u8, name, "The Annunciation")) {
        if (n >= e - 7 and n <= e + 7) return Date.fromDays(e + 8); // Monday after the Octave of Easter
        if (lent_sunday) return Date.fromDays(n + 1);
    }
    // Otherwise the next day that is not itself a solemnity or a first-rank day.
    var probe = n + 1;
    var guard: u8 = 0;
    var scratch: Day = .{};
    while (guard < 14) : (guard += 1) {
        var list: CandList = .{};
        var season: []const u8 = "";
        scratch.used = 0;
        collectNo(table, Date.fromDays(probe), &scratch, &list, &season);
        if (list.items[list.best()].p > 2) return Date.fromDays(probe);
        probe += 1;
    }
    return Date.fromDays(probe);
}

fn computeNo(table: *const Table, d: Date, out: *Day) void {
    var list: CandList = .{};
    var season: []const u8 = "";
    collectNo(table, d, out, &list, &season);

    // Solemnities from nearby days that were displaced and land here.
    var scratch: Day = .{};
    var off: i64 = -12;
    while (off <= 12) : (off += 1) {
        if (off == 0) continue;
        const other = Date.fromDays(d.days() + off);
        var ol: CandList = .{};
        var os: []const u8 = "";
        scratch.used = 0;
        collectNo(table, other, &scratch, &ol, &os);
        for (ol.items[0..ol.n], 0..) |c, i| {
            if (!c.movable or c.p != 2) continue;
            if (ol.bestExcept(i) > 2) continue; // it keeps its own day
            const target = transferTargetNo(table, other, c.name);
            if (target.eql(d)) list.add(.{ .name = c.name, .p = 2, .color = c.color, .sanctoral = true });
        }
    }

    const temporal = list.items[0];
    var at = list.best();
    // Optional memorials: the day of the season is the celebration; they are offered.
    const optional_only = list.items[at].p == 10;
    if (optional_only) at = 0;
    const main = list.items[at];

    out.name = main.name;
    out.color = main.color;
    out.season = season;
    out.rank = rankLabelNo(main.p, main.sanctoral);
    out.plain = !main.sanctoral and (main.p == 8 or main.p == 11 or main.p == 12);
    if (optional_only or (!main.sanctoral and temporal.p == 8)) {
        for (list.items[1..list.n]) |c| if (c.p == 9 or c.p == 10) out.addAlso("Optional memorial", c.name);
    }
    out.cycle = lectionaryCycle(d, out);
}

fn rankLabelNo(p: u8, sanctoral: bool) []const u8 {
    return switch (p) {
        1 => if (sanctoral) "Solemnity" else "Highest rank",
        2, 3 => "Solemnity",
        4 => "Feast of the Lord",
        5 => "Sunday",
        6, 7 => "Feast",
        8 => "Weekday",
        9 => "Memorial",
        10 => "Optional memorial",
        else => "Weekday",
    };
}

fn lectionaryCycle(d: Date, out: *Day) []const u8 {
    const y = d.year;
    const l = if (d.days() >= adventStart(y)) y + 1 else y; // the liturgical year's number
    const sunday: u8 = switch (@mod(l, 3)) {
        1 => 'A',
        2 => 'B',
        else => 'C',
    };
    return out.print("Sunday Year {c}, weekday Year {s}", .{ sunday, @as([]const u8, if (@mod(l, 2) == 1) "I" else "II") });
}

// =============================================================================================
// 1962
// =============================================================================================

const TlmTemporal = struct { cand: Cand, season: []const u8 };

fn tc(name: []const u8, p: u8, class: u8, color: Color) Cand {
    return .{ .name = name, .p = p, .class = class, .color = color };
}

/// Which Sunday after Pentecost (or the Epiphany Sundays resumed at its end) a Sunday is.
fn pentecostSundayName(sn: i64, y: i32, out: *Day) []const u8 {
    const e = civil.easter(y).days();
    const pent = e + 49;
    const last = adventStart(y) - 7;
    if (sn == last) return "24th Sunday after Pentecost";
    const k = @divFloor(sn - pent, 7);
    if (k <= 23) return out.print("{s} Sunday after Pentecost", .{out.ord(k)});
    const septuagesima = e - 63;
    const first = sundayOnOrAfter(dateOf(y, 1, 7));
    const used = @divFloor(septuagesima - first, 7); // Sundays after Epiphany before Septuagesima
    return out.print("{s} Sunday after Epiphany", .{out.ord(used + (k - 23))});
}

fn temporalTlm(d: Date, out: *Day) TlmTemporal {
    const y = d.year;
    const n = d.days();
    const wd = d.weekday();
    const e = civil.easter(y).days();
    const pent = e + 49;
    const a1 = adventStart(y);
    const dn = weekdays[wd];
    const sept = e - 63;
    const first_sun = sundayOnOrAfter(dateOf(y, 1, 7));

    if (n >= a1) {
        const dec25 = dateOf(y, 12, 25);
        if (n < dec25) {
            const k = @divFloor(n - a1, 7) + 1;
            if (wd == 0) return .{ .cand = tc(out.print("{s} Sunday of Advent", .{out.ord(k)}), Tlm.temporal_1, 1, if (k == 3) .rose else .violet), .season = "Advent" };
            const third = a1 + 14;
            if (n == third + 3 or n == third + 5 or n == third + 6) return .{ .cand = tc(out.print("Ember {s} in Advent", .{dn}), Tlm.feria_2, 2, .violet), .season = "Advent" };
            if (d.month == 12 and d.day >= 17) return .{ .cand = tc(out.print("{s}, greater feria of Advent (December {d})", .{ dn, d.day }), Tlm.feria_2, 2, .violet), .season = "Advent" };
            return .{ .cand = tc(out.print("{s} after the {s} Sunday of Advent", .{ dn, out.ord(@divFloor(n - @as(i64, wd) - a1, 7) + 1) }), Tlm.feria_3, 3, .violet), .season = "Advent" };
        }
        if (wd == 0) return .{ .cand = tc("Sunday within the Octave of the Nativity", Tlm.sunday_2, 2, .white), .season = "Christmastide" };
        return .{ .cand = tc(out.print("{s} day within the Octave of the Nativity", .{out.ord(d.day - 24)}), Tlm.feria_3, 3, .white), .season = "Christmastide" };
    }

    if (n < sept) { // January to Septuagesima
        if (d.month == 1 and d.day <= 5) {
            if (wd == 0) return .{ .cand = tc("Sunday after the Circumcision (Holy Name)", Tlm.sunday_2, 2, .white), .season = "Christmastide" };
            return .{ .cand = tc(out.print("{s} after the Circumcision", .{dn}), Tlm.feria_4, 4, .white), .season = "Christmastide" };
        }
        if (n < first_sun) return .{ .cand = tc(out.print("{s} after Epiphany", .{dn}), Tlm.feria_4, 4, .white), .season = "Time after Epiphany" };
        const k = @divFloor(n - first_sun, 7) + 1;
        if (n == first_sun) return .{ .cand = tc("Feast of the Holy Family (1st Sunday after Epiphany)", Tlm.lord_2, 2, .white), .season = "Time after Epiphany" };
        if (wd == 0) return .{ .cand = tc(out.print("{s} Sunday after Epiphany", .{out.ord(k)}), Tlm.sunday_2, 2, .green), .season = "Time after Epiphany" };
        return .{ .cand = tc(out.print("{s} after the {s} Sunday after Epiphany", .{ dn, out.ord(@divFloor(n - first_sun, 7) + 1) }), Tlm.feria_4, 4, .green), .season = "Time after Epiphany" };
    }

    if (n < e - 46) { // Septuagesima to Quinquagesima
        const names = [_][]const u8{ "Septuagesima", "Sexagesima", "Quinquagesima" };
        const k: usize = @intCast(@divFloor(n - sept, 7));
        if (wd == 0) return .{ .cand = tc(out.print("{s} Sunday", .{names[k]}), Tlm.sunday_2, 2, .violet), .season = "Septuagesima" };
        return .{ .cand = tc(out.print("{s} after {s} Sunday", .{ dn, names[k] }), Tlm.feria_4, 4, .violet), .season = "Septuagesima" };
    }

    if (n < e) { // Lent
        const palm = e - 7;
        if (n == e - 46) return .{ .cand = tc("Ash Wednesday", Tlm.temporal_1, 1, .violet), .season = "Lent" };
        if (n < e - 42) return .{ .cand = tc(out.print("{s} after Ash Wednesday", .{dn}), Tlm.feria_3, 3, .violet), .season = "Lent" };
        if (n >= palm) {
            if (n == palm) return .{ .cand = tc("Palm Sunday", Tlm.temporal_1, 1, .red), .season = "Holy Week" };
            if (n == e - 3) return .{ .cand = tc("Holy Thursday", Tlm.temporal_1, 1, .white), .season = "Holy Week" };
            if (n == e - 2) return .{ .cand = tc("Good Friday", Tlm.temporal_1, 1, .black), .season = "Holy Week" };
            if (n == e - 1) return .{ .cand = tc("Holy Saturday", Tlm.temporal_1, 1, .violet), .season = "Holy Week" };
            return .{ .cand = tc(out.print("{s} of Holy Week", .{dn}), Tlm.temporal_1, 1, .violet), .season = "Holy Week" };
        }
        const k = @divFloor(n - (e - 42), 7) + 1;
        const season: []const u8 = if (n >= e - 14) "Passiontide" else "Lent";
        if (n == e - 14) return .{ .cand = tc("Passion Sunday", Tlm.temporal_1, 1, .violet), .season = season };
        if (wd == 0) return .{ .cand = tc(out.print("{s} Sunday of Lent", .{out.ord(k)}), Tlm.temporal_1, 1, if (k == 4) .rose else .violet), .season = season };
        if (k == 1 and (wd == 3 or wd == 5 or wd == 6)) return .{ .cand = tc(out.print("Ember {s} in Lent", .{dn}), Tlm.feria_2, 2, .violet), .season = season };
        if (n > e - 14) return .{ .cand = tc(out.print("{s} in Passion Week", .{dn}), Tlm.feria_3, 3, .violet), .season = season };
        return .{ .cand = tc(out.print("{s} after the {s} Sunday of Lent", .{ dn, out.ord(k) }), Tlm.feria_3, 3, .violet), .season = season };
    }

    if (n < pent) { // Eastertide
        const k = @divFloor(n - e, 7);
        if (n == e) return .{ .cand = tc("Easter Sunday", Tlm.temporal_1, 1, .white), .season = "Eastertide" };
        if (n < e + 7) return .{ .cand = tc(out.print("{s} in Easter Week", .{dn}), Tlm.temporal_1, 1, .white), .season = "Eastertide" };
        if (n == e + 7) return .{ .cand = tc("Low Sunday (Octave Day of Easter)", Tlm.temporal_1, 1, .white), .season = "Eastertide" };
        if (n == e + 39) return .{ .cand = tc("Ascension Thursday", Tlm.temporal_1, 1, .white), .season = "Eastertide" };
        if (n == e + 48) return .{ .cand = tc("Vigil of Pentecost", Tlm.temporal_1, 1, .violet), .season = "Eastertide" };
        if (n >= e + 36 and n <= e + 38) return .{ .cand = tc(out.print("Rogation {s}", .{dn}), Tlm.feria_2, 2, .violet), .season = "Eastertide" };
        if (n == e + 42) return .{ .cand = tc("Sunday after the Ascension", Tlm.sunday_2, 2, .white), .season = "Eastertide" };
        if (wd == 0) return .{ .cand = tc(out.print("{s} Sunday after Easter", .{out.ord(k)}), Tlm.sunday_2, 2, .white), .season = "Eastertide" };
        if (n > e + 39) return .{ .cand = tc(out.print("{s} after the Ascension", .{dn}), Tlm.feria_4, 4, .white), .season = "Eastertide" };
        if (k == 1) return .{ .cand = tc(out.print("{s} after Low Sunday", .{dn}), Tlm.feria_4, 4, .white), .season = "Eastertide" };
        return .{ .cand = tc(out.print("{s} after the {s} Sunday after Easter", .{ dn, out.ord(k) }), Tlm.feria_4, 4, .white), .season = "Eastertide" };
    }

    // Pentecost and the time after it.
    const season = "Time after Pentecost";
    if (n == pent) return .{ .cand = tc("Pentecost Sunday", Tlm.temporal_1, 1, .red), .season = season };
    if (n <= pent + 2) return .{ .cand = tc(out.print("{s} in Whitsun Week", .{dn}), Tlm.temporal_1, 1, .red), .season = season };
    if (n <= pent + 6) {
        if (wd == 3 or wd == 5 or wd == 6) return .{ .cand = tc(out.print("Ember {s} in Whitsun Week", .{dn}), Tlm.feria_2, 2, .red), .season = season };
        return .{ .cand = tc(out.print("{s} in Whitsun Week", .{dn}), Tlm.feria_4, 4, .red), .season = season };
    }
    if (n == pent + 7) return .{ .cand = tc("Trinity Sunday", Tlm.temporal_1, 1, .white), .season = season };
    if (n == pent + 11) return .{ .cand = tc("Corpus Christi", Tlm.temporal_1, 1, .white), .season = season };
    if (n == pent + 19) return .{ .cand = tc("Most Sacred Heart of Jesus", Tlm.temporal_1, 1, .white), .season = season };
    const sunday = n - wd;
    // Ember days of September: the Wednesday, Friday and Saturday after the third Sunday.
    const sep15 = dateOf(y, 9, 15);
    const third_sunday = sundayOnOrAfter(sep15);
    if (sunday == third_sunday and (wd == 3 or wd == 5 or wd == 6)) return .{ .cand = tc(out.print("Ember {s} in September", .{dn}), Tlm.feria_2, 2, .violet), .season = season };
    if (wd == 0) return .{ .cand = tc(pentecostSundayName(n, y, out), Tlm.sunday_2, 2, .green), .season = season };
    if (sunday == pent + 7) return .{ .cand = tc(out.print("{s} after Trinity Sunday", .{dn}), Tlm.feria_4, 4, .green), .season = season };
    return .{ .cand = tc(out.print("{s} after the {s}", .{ dn, pentecostSundayName(sunday, y, out) }), Tlm.feria_4, 4, .green), .season = season };
}

fn movableTlm(d: Date, list: *CandList) void {
    const y = d.year;
    const n = d.days();
    // Christ the King: the last Sunday of October.
    if (d.month == 10 and d.weekday() == 0 and d.day >= 25)
        list.add(.{ .name = "Feast of Our Lord Jesus Christ the King", .p = Tlm.lord_1, .class = 1, .color = .white, .sanctoral = true });
    // The Holy Name: the Sunday from January 2 to 5, else January 2.
    const jan2 = dateOf(y, 1, 2);
    const sunday = sundayOnOrAfter(jan2);
    const holy_name = if (sunday <= dateOf(y, 1, 5)) sunday else jan2;
    if (n == holy_name) list.add(.{ .name = "Most Holy Name of Jesus", .p = Tlm.lord_2, .class = 2, .color = .white, .sanctoral = true });
}

fn collectTlm(table: *const Table, d: Date, out: *Day, list: *CandList, season: *[]const u8) void {
    const t = temporalTlm(d, out);
    season.* = t.season;
    list.add(t.cand);
    movableTlm(d, list);
    const leap = civil.isLeap(d.year);
    for (table.entries) |en| {
        var m = en.month;
        var day = en.day;
        // Leap years: Feb 24-28 move one day later (the extra day is the sixth of the Kalends).
        if (leap and m == 2 and day >= 24 and day <= 28) {
            day += 1;
        }
        if (m != d.month or day != d.day) continue;
        var p = en.p;
        // The Immaculate Conception is kept even on a Sunday of Advent.
        if (m == 12 and en.day == 8) p = 9;
        // All Souls on a Sunday is kept on the Monday.
        if (m == 11 and en.day == 2 and d.weekday() == 0) p = 99;
        m = 0;
        list.add(.{
            .name = en.name,
            .p = p,
            .class = en.class,
            .color = en.color,
            .sanctoral = true,
            .movable = en.class == 1 and !std.mem.startsWith(u8, en.name, "Vigil"),
        });
    }
}

fn transferTargetTlm(table: *const Table, d: Date) Date {
    var probe = d.days() + 1;
    var guard: u8 = 0;
    var scratch: Day = .{};
    while (guard < 30) : (guard += 1) {
        var list: CandList = .{};
        var season: []const u8 = "";
        scratch.used = 0;
        collectTlm(table, Date.fromDays(probe), &scratch, &list, &season);
        if (list.items[list.best()].p >= 30) return Date.fromDays(probe);
        probe += 1;
    }
    return Date.fromDays(probe);
}

fn classLabel(class: u8) []const u8 {
    return switch (class) {
        1 => "Class I",
        2 => "Class II",
        3 => "Class III",
        else => "Class IV",
    };
}

fn computeTlm(table: *const Table, d: Date, out: *Day) void {
    var list: CandList = .{};
    var season: []const u8 = "";
    collectTlm(table, d, out, &list, &season);

    // First-class feasts from the last days that were impeded come here.
    var scratch: Day = .{};
    var off: i64 = -30;
    while (off < 0) : (off += 1) {
        const other = Date.fromDays(d.days() + off);
        var ol: CandList = .{};
        var os: []const u8 = "";
        scratch.used = 0;
        collectTlm(table, other, &scratch, &ol, &os);
        for (ol.items[0..ol.n], 0..) |c, i| {
            if (!c.movable or c.class != 1) continue;
            if (ol.bestExcept(i) >= c.p) continue; // it keeps its own day
            if (transferTargetTlm(table, other).eql(d)) list.add(.{ .name = c.name, .p = Tlm.saint_1 - 6, .class = 1, .color = c.color, .sanctoral = true });
        }
    }

    const at = list.best();
    const main = list.items[at];
    out.name = main.name;
    out.color = main.color;
    out.season = season;
    out.rank = classLabel(main.class);
    out.plain = !main.sanctoral and main.p >= Tlm.feria_3;
    for (list.items[0..list.n], 0..) |c, i| {
        if (i == at or c.class == 0 or c.class > main.class) continue;
        if (c.sanctoral and c.movable) continue; // a first-class feast that moves, not commemorated
        out.addAlso("Commemoration", c.name);
    }
}

// =============================================================================================

pub fn compute(table: *const Table, date: Date, out: *Day) void {
    out.* = .{};
    switch (table.kind) {
        .novus_ordo => {
            computeNo(table, date, out);
            fasting.catholic(.novus_ordo, date, out);
        },
        .tlm1962 => {
            computeTlm(table, date, out);
            fasting.catholic(.tlm1962, date, out);
        },
        .orthodox_ru => orthodox.compute(table, date, out),
    }
}

// ---- tests -------------------------------------------------------------------------------------

fn testTable(kind: Kind) !Table {
    return Table.parse(std.testing.allocator, kind, kind.builtinText());
}

fn dayOf(table: *const Table, y: i32, m: u8, d: u8, out: *Day) void {
    compute(table, .{ .year = y, .month = m, .day = d }, out);
}

test "both tables parse" {
    var no = try testTable(.novus_ordo);
    defer no.deinit();
    var tlm = try testTable(.tlm1962);
    defer tlm.deinit();
    try std.testing.expect(no.entries.len > 200);
    try std.testing.expect(tlm.entries.len > 230);
}

test "Novus Ordo temporal cycle, 2026" {
    var t = try testTable(.novus_ordo);
    defer t.deinit();
    var d: Day = undefined;
    dayOf(&t, 2026, 2, 18, &d);
    try std.testing.expectEqualStrings("Ash Wednesday", d.name);
    dayOf(&t, 2026, 4, 5, &d);
    try std.testing.expectEqualStrings("Easter Sunday of the Resurrection of the Lord", d.name);
    dayOf(&t, 2026, 6, 14, &d);
    try std.testing.expectEqualStrings("11th Sunday in Ordinary Time", d.name);
    dayOf(&t, 2026, 11, 22, &d);
    try std.testing.expectEqualStrings("Our Lord Jesus Christ, King of the Universe", d.name);
    dayOf(&t, 2026, 11, 29, &d);
    try std.testing.expectEqualStrings("1st Sunday of Advent", d.name);
    try std.testing.expectEqualStrings("Sunday Year B, weekday Year I", d.cycle);
    dayOf(&t, 2026, 1, 11, &d);
    try std.testing.expectEqualStrings("Sunday Year A, weekday Year II", d.cycle);
    try std.testing.expectEqualStrings("The Baptism of the Lord", d.name);
    dayOf(&t, 2026, 1, 18, &d);
    try std.testing.expectEqualStrings("2nd Sunday in Ordinary Time", d.name);
    dayOf(&t, 2026, 5, 25, &d);
    try std.testing.expectEqualStrings("Mary, Mother of the Church", d.name);
}

test "Novus Ordo precedence and transfers" {
    var t = try testTable(.novus_ordo);
    defer t.deinit();
    var d: Day = undefined;
    // St Joseph on the third Sunday of Lent 2028 moves to Monday.
    dayOf(&t, 2028, 3, 19, &d);
    try std.testing.expectEqualStrings("3rd Sunday of Lent", d.name);
    dayOf(&t, 2028, 3, 20, &d);
    try std.testing.expect(std.mem.startsWith(u8, d.name, "Joseph, Spouse"));
    // The Immaculate Conception on the second Sunday of Advent 2024 moves to Monday.
    dayOf(&t, 2024, 12, 8, &d);
    try std.testing.expectEqualStrings("2nd Sunday of Advent", d.name);
    dayOf(&t, 2024, 12, 9, &d);
    try std.testing.expect(std.mem.startsWith(u8, d.name, "The Immaculate Conception"));
    // A memorial in Lent is only optional.
    dayOf(&t, 2026, 3, 7, &d); // Perpetua and Felicity, Saturday of the 2nd week
    try std.testing.expect(std.mem.indexOf(u8, d.name, "week of Lent") != null);
    try std.testing.expectEqual(@as(usize, 1), d.n_also);
    // A feast of the Lord displaces an Ordinary Sunday.
    dayOf(&t, 2027, 8, 6, &d);
    try std.testing.expectEqualStrings("The Transfiguration of the Lord", d.name);
    // An obligatory memorial in Ordinary Time is the celebration.
    dayOf(&t, 2026, 8, 4, &d);
    try std.testing.expectEqualStrings("John Vianney, priest", d.name);
}

test "1962 temporal cycle, 2026" {
    var t = try testTable(.tlm1962);
    defer t.deinit();
    var d: Day = undefined;
    dayOf(&t, 2026, 2, 1, &d);
    try std.testing.expectEqualStrings("Septuagesima Sunday", d.name);
    dayOf(&t, 2026, 4, 5, &d);
    try std.testing.expectEqualStrings("Easter Sunday", d.name);
    try std.testing.expectEqualStrings("Class I", d.rank);
    dayOf(&t, 2026, 10, 25, &d);
    try std.testing.expectEqualStrings("Feast of Our Lord Jesus Christ the King", d.name);
    dayOf(&t, 2026, 11, 8, &d);
    try std.testing.expectEqualStrings("4th Sunday after Epiphany", d.name);
    dayOf(&t, 2026, 11, 22, &d);
    try std.testing.expectEqualStrings("24th Sunday after Pentecost", d.name);
    dayOf(&t, 2026, 9, 23, &d);
    try std.testing.expectEqualStrings("Ember Wednesday in September", d.name);
    dayOf(&t, 2026, 12, 8, &d);
    try std.testing.expect(std.mem.startsWith(u8, d.name, "Immaculate Conception"));
}

test "1962 precedence, commemorations and transfers" {
    var t = try testTable(.tlm1962);
    defer t.deinit();
    var d: Day = undefined;
    // A third-class saint in Lent is kept, the Lenten feria commemorated.
    dayOf(&t, 2026, 3, 12, &d);
    try std.testing.expectEqualStrings("Gregory the Great, pope, confessor and doctor", d.name);
    try std.testing.expectEqual(@as(usize, 1), d.n_also);
    // A second-class Sunday outranks a second-class saint, which is commemorated.
    dayOf(&t, 2026, 7, 26, &d); // St Anne on the 8th Sunday after Pentecost
    try std.testing.expect(std.mem.indexOf(u8, d.name, "Sunday after Pentecost") != null);
    try std.testing.expectEqual(@as(usize, 1), d.n_also);
    // St Joseph on the second Sunday of Lent 2027? Easter 2027 is Mar 28: Mar 19 is a Friday. Use 2028.
    dayOf(&t, 2028, 3, 19, &d);
    try std.testing.expectEqualStrings("3rd Sunday of Lent", d.name);
    dayOf(&t, 2028, 3, 20, &d);
    try std.testing.expect(std.mem.startsWith(u8, d.name, "Joseph"));
    // Leap year: St Matthias on Feb 25.
    dayOf(&t, 2028, 2, 25, &d);
    try std.testing.expectEqualStrings("Matthias, apostle", d.name);
    dayOf(&t, 2027, 2, 24, &d);
    try std.testing.expectEqualStrings("Matthias, apostle", d.name);
}

test "Catholic fast and abstinence days" {
    var no = try testTable(.novus_ordo);
    defer no.deinit();
    var tlm = try testTable(.tlm1962);
    defer tlm.deinit();
    var d: Day = undefined;
    dayOf(&no, 2026, 2, 18, &d); // Ash Wednesday
    try std.testing.expectEqualStrings("⛔", d.fast_emoji);
    dayOf(&no, 2026, 2, 27, &d); // Friday of Lent
    try std.testing.expectEqualStrings("🐟", d.fast_emoji);
    dayOf(&no, 2026, 2, 26, &d); // Thursday of Lent: nothing in the current rules
    try std.testing.expectEqualStrings("", d.fast_emoji);
    dayOf(&no, 2026, 12, 25, &d); // Christmas on a Friday: a solemnity
    try std.testing.expectEqualStrings("", d.fast_emoji);
    dayOf(&tlm, 2026, 2, 26, &d); // Thursday of Lent: fast (one full meal)
    try std.testing.expectEqualStrings("🍽️", d.fast_emoji);
    dayOf(&tlm, 2026, 9, 23, &d); // Ember Wednesday in September
    try std.testing.expectEqualStrings("⛔", d.fast_emoji);
    dayOf(&tlm, 2026, 8, 14, &d); // Vigil of the Assumption
    try std.testing.expectEqualStrings("⛔", d.fast_emoji);
}
