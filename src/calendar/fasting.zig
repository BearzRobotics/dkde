//! Fast and abstinence days for the Catholic calendars, as food emoji. These
//! are a guide only: bishops' conferences and indults change the rules.
//!
//!   ⛔  fast and abstinence      🐟  abstinence from meat (fish is allowed)
//!   🍽️  fast only (one full meal)

const std = @import("std");
const common = @import("common");
const liturgy = @import("liturgy.zig");

const civil = common.civil;
const Date = civil.Date;

pub const fast_and_abstinence = "⛔";
pub const abstinence = "🐟";
pub const fast_only = "🍽️";

fn set(out: *liturgy.Day, emoji: []const u8, text: []const u8) void {
    out.fast_emoji = emoji;
    out.fast_text = text;
}

/// Adds the day's fast to `out`, which already holds its celebration.
pub fn catholic(kind: liturgy.Kind, d: Date, out: *liturgy.Day) void {
    const n = d.days();
    const wd = d.weekday();
    const e = civil.easter(d.year).days();
    const ash = e - 46;
    const in_lent = n >= ash and n < e;
    const high_rank = std.mem.eql(u8, out.rank, "Solemnity") or std.mem.eql(u8, out.rank, "Highest rank") or std.mem.eql(u8, out.rank, "Class I");

    switch (kind) {
        .novus_ordo => {
            if (n == ash or n == e - 2) return set(out, fast_and_abstinence, "Fast and abstinence from meat");
            if (n == e - 1) return set(out, fast_only, "Paschal fast until the Easter Vigil (recommended)");
            if (wd == 5 and in_lent) return set(out, abstinence, "Friday of Lent: abstinence from meat");
            if (wd == 5 and !high_rank) return set(out, abstinence, "Friday penance: abstain from meat, or do another penance");
        },
        .tlm1962 => {
            const vigil_dates = [_][2]u8{ .{ 12, 24 }, .{ 8, 14 }, .{ 10, 31 } };
            for (vigil_dates) |v| if (d.month == v[0] and d.day == v[1] and wd != 0)
                return set(out, fast_and_abstinence, "Vigil: fast and abstinence");
            if (n == e + 48) return set(out, fast_and_abstinence, "Vigil of Pentecost: fast and abstinence");
            if (std.mem.startsWith(u8, out.name, "Ember ")) return set(out, fast_and_abstinence, "Ember day: fast and abstinence");
            if (n == ash) return set(out, fast_and_abstinence, "Ash Wednesday: fast and abstinence");
            if (in_lent and wd != 0) {
                if (wd == 5 or wd == 6) return set(out, fast_and_abstinence, "Lent, Friday or Saturday: fast and abstinence");
                return set(out, fast_only, "Lent: fast (one full meal)");
            }
            if (wd == 5 and !(high_rank and !in_lent)) return set(out, abstinence, "Friday: abstinence from meat");
        },
        .orthodox_ru => {},
    }
}
