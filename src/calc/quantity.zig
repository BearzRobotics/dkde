//! Numbers with units: `5 ft + 3 in`, `60 mph to km/h`, `5 kg * 2 m/s^2`
//! (= 10 N). A quantity is an exact number and a list of units with
//! exponents; every unit knows its dimensions (length, mass, time, current,
//! temperature, amount, light, data, money) and its factor to the SI unit,
//! so sums and conversions are checked and exact.
//!
//! The table below is written from the SI brochure and the definitions of
//! the customary units (every factor is exact by definition unless noted).

const std = @import("std");
const num = @import("num.zig");
const Number = num.Number;

pub const ndim = 9;
pub const Dims = [ndim]i8;
const base_names = [ndim][]const u8{ "m", "kg", "s", "A", "K", "mol", "cd", "bit", "cur" };

pub const Error = error{ OutOfMemory, TooLarge, DivisionByZero, Domain, Units };

/// A unit as used in an entry (prefix applied).
pub const Unit = struct {
    sym: []const u8,
    dims: Dims,
    factor: Number,
    /// Temperatures: base = (value + offset) × factor.
    offset: ?Number = null,
};

pub const UPow = struct { unit: Unit, exp: i32 };

pub const Quantity = struct {
    value: Number,
    units: []const UPow,
};

// ---- the table ---------------------------------------------------------------------

const Pre = enum { none, si, bin, both };

const Def = struct {
    /// Symbols, case-sensitive, '|' apart; the first is shown.
    sym: []const u8,
    /// Names, any case, '|' apart (a plural "s" is accepted).
    long: []const u8,
    dims: []const u8,
    /// Decimal, "n/d", or "p180" for π/180 (an approximation).
    factor: []const u8,
    pre: Pre = .none,
    offset: []const u8 = "",
};

fn d(sym: []const u8, long: []const u8, dims: []const u8, factor: []const u8, pre: Pre) Def {
    return .{ .sym = sym, .long = long, .dims = dims, .factor = factor, .pre = pre };
}

const defs = [_]Def{
    // SI base and derived.
    d("m", "meter|metre", "m", "1", .si),
    d("g", "gram|gramme", "kg", "0.001", .si),
    d("s", "second|sec", "s", "1", .si),
    d("A", "ampere|amp", "A", "1", .si),
    d("K", "kelvin", "K", "1", .si),
    d("mol", "mole", "mol", "1", .si),
    d("cd", "candela", "cd", "1", .si),
    d("Hz", "hertz", "s-1", "1", .si),
    d("N", "newton", "kg m s-2", "1", .si),
    d("Pa", "pascal", "kg m-1 s-2", "1", .si),
    d("J", "joule", "kg m2 s-2", "1", .si),
    d("W", "watt", "kg m2 s-3", "1", .si),
    d("C", "coulomb", "A s", "1", .si),
    d("V", "volt", "kg m2 s-3 A-1", "1", .si),
    d("Ω|ohm", "ohm", "kg m2 s-3 A-2", "1", .si),
    d("F", "farad", "kg-1 m-2 s4 A2", "1", .si),
    d("S", "siemens", "kg-1 m-2 s3 A2", "1", .si),
    d("Wb", "weber", "kg m2 s-2 A-1", "1", .si),
    d("T", "tesla", "kg s-2 A-1", "1", .si),
    d("H", "henry|henries", "kg m2 s-2 A-2", "1", .si),
    d("lm", "lumen", "cd", "1", .si),
    d("lx", "lux", "cd m-2", "1", .si),
    d("Bq", "becquerel", "s-1", "1", .si),
    d("Gy", "gray", "m2 s-2", "1", .si),
    d("Sv", "sievert", "m2 s-2", "1", .si),
    d("kat", "katal", "mol s-1", "1", .si),
    d("L|l", "liter|litre", "m3", "0.001", .si),
    d("rad", "radian", "", "1", .si),
    d("bit", "bit", "bit", "1", .both),
    d("B", "byte", "bit", "8", .both),
    // Angle.
    d("°|deg", "degree", "", "p180", .none),
    d("grad|gon", "gradian|gon", "", "p200", .none),
    d("arcmin|′", "arcminute", "", "p10800", .none),
    d("arcsec|″", "arcsecond", "", "p648000", .none),
    d("turn|rev", "turn|revolution", "", "6.283185307179586", .none),
    // Time.
    d("min", "minute", "s", "60", .none),
    d("h|hr", "hour", "s", "3600", .none),
    d("d", "day", "s", "86400", .none),
    d("wk", "week", "s", "604800", .none),
    d("yr", "year", "s", "31557600", .none),
    d("rpm", "rpm", "s-1", "1/60", .none),
    // Length.
    d("in", "inch|inches", "m", "0.0254", .none),
    d("ft", "foot|feet", "m", "0.3048", .none),
    d("yd", "yard", "m", "0.9144", .none),
    d("mi", "mile", "m", "1609.344", .none),
    d("nmi", "nauticalmile", "m", "1852", .none),
    d("ly", "lightyear", "m", "9460730472580800", .si),
    d("au|AU", "astronomicalunit", "m", "149597870700", .none),
    d("pc", "parsec", "m", "30856775814913673", .si),
    d("Å|angstrom", "angstrom", "m", "1e-10", .none),
    d("mil|thou", "mil|thou", "m", "0.0000254", .none),
    d("fathom", "fathom", "m", "1.8288", .none),
    d("furlong", "furlong", "m", "201.168", .none),
    d("chain", "chain", "m", "20.1168", .none),
    d("league", "league", "m", "4828.032", .none),
    // Area and volume.
    d("ha", "hectare", "m2", "10000", .none),
    d("acre|ac", "acre", "m2", "4046.8564224", .none),
    d("gal", "gallon", "m3", "0.003785411784", .none),
    d("qt", "quart", "m3", "0.000946352946", .none),
    d("pt", "pint", "m3", "0.000473176473", .none),
    d("cup", "cup", "m3", "0.0002365882365", .none),
    d("floz", "fluidounce", "m3", "0.0000295735295625", .none),
    d("tbsp", "tablespoon", "m3", "0.00001478676478125", .none),
    d("tsp", "teaspoon", "m3", "0.00000492892159375", .none),
    d("galUK|impgal", "imperialgallon", "m3", "0.00454609", .none),
    // Mass.
    d("t", "tonne", "kg", "1000", .si),
    d("lb|lbs", "pound", "kg", "0.45359237", .none),
    d("oz", "ounce", "kg", "0.028349523125", .none),
    d("st", "stone", "kg", "6.35029318", .none),
    d("ton", "ton", "kg", "907.18474", .none),
    d("ct", "carat", "kg", "0.0002", .none),
    d("gr", "grain", "kg", "0.00006479891", .none),
    d("u|Da", "dalton", "kg", "1.66053906660e-27", .si),
    d("slug", "slug", "kg", "14.5939029372064", .none),
    // Force, pressure, energy, power, speed.
    d("lbf", "poundforce", "kg m s-2", "4.4482216152605", .none),
    d("kgf", "kilogramforce", "kg m s-2", "9.80665", .none),
    d("dyn", "dyne", "kg m s-2", "0.00001", .none),
    d("bar", "bar", "kg m-1 s-2", "100000", .si),
    d("atm", "atmosphere", "kg m-1 s-2", "101325", .none),
    d("psi", "psi", "kg m-1 s-2", "6894.757293168361", .none),
    d("mmHg|torr|Torr", "torr", "kg m-1 s-2", "101325/760", .none),
    d("inHg", "inhg", "kg m-1 s-2", "3386.389", .none),
    d("cal", "calorie", "kg m2 s-2", "4.184", .si),
    d("Wh", "watthour", "kg m2 s-2", "3600", .si),
    d("eV", "electronvolt", "kg m2 s-2", "1.602176634e-19", .si),
    d("BTU|btu", "btu", "kg m2 s-2", "1055.05585262", .none),
    d("erg", "erg", "kg m2 s-2", "0.0000001", .none),
    d("hp", "horsepower", "kg m2 s-3", "745.69987158227022", .none),
    d("PS", "ps", "kg m2 s-3", "735.49875", .none),
    d("kn|knot", "knot", "m s-1", "463/900", .none),
    d("mph", "mph", "m s-1", "0.44704", .none),
    d("Ci", "curie", "s-1", "3.7e10", .none),
};

/// Temperature scales with an offset.
const temps = [_]Def{
    .{ .sym = "°C|degC", .long = "celsius", .dims = "K", .factor = "1", .offset = "273.15" },
    .{ .sym = "°F|degF", .long = "fahrenheit", .dims = "K", .factor = "5/9", .offset = "459.67" },
    .{ .sym = "°R|degR", .long = "rankine", .dims = "K", .factor = "5/9", .offset = "0" },
};

const Prefix = struct { sym: []const u8, long: []const u8, exp: i32 };

const si_prefixes = [_]Prefix{
    .{ .sym = "Q", .long = "quetta", .exp = 30 },  .{ .sym = "R", .long = "ronna", .exp = 27 },
    .{ .sym = "Y", .long = "yotta", .exp = 24 },   .{ .sym = "Z", .long = "zetta", .exp = 21 },
    .{ .sym = "E", .long = "exa", .exp = 18 },     .{ .sym = "P", .long = "peta", .exp = 15 },
    .{ .sym = "T", .long = "tera", .exp = 12 },    .{ .sym = "G", .long = "giga", .exp = 9 },
    .{ .sym = "M", .long = "mega", .exp = 6 },     .{ .sym = "k", .long = "kilo", .exp = 3 },
    .{ .sym = "h", .long = "hecto", .exp = 2 },    .{ .sym = "da", .long = "deca", .exp = 1 },
    .{ .sym = "d", .long = "deci", .exp = -1 },    .{ .sym = "c", .long = "centi", .exp = -2 },
    .{ .sym = "m", .long = "milli", .exp = -3 },   .{ .sym = "µ", .long = "micro", .exp = -6 },
    .{ .sym = "μ", .long = "micro", .exp = -6 },   .{ .sym = "u", .long = "micro", .exp = -6 },
    .{ .sym = "n", .long = "nano", .exp = -9 },    .{ .sym = "p", .long = "pico", .exp = -12 },
    .{ .sym = "f", .long = "femto", .exp = -15 },  .{ .sym = "a", .long = "atto", .exp = -18 },
    .{ .sym = "z", .long = "zepto", .exp = -21 },  .{ .sym = "y", .long = "yocto", .exp = -24 },
    .{ .sym = "r", .long = "ronto", .exp = -27 },  .{ .sym = "q", .long = "quecto", .exp = -30 },
    .{ .sym = "deka", .long = "deka", .exp = 1 },
};

const bin_prefixes = [_]Prefix{
    .{ .sym = "Ki", .long = "kibi", .exp = 10 }, .{ .sym = "Mi", .long = "mebi", .exp = 20 },
    .{ .sym = "Gi", .long = "gibi", .exp = 30 }, .{ .sym = "Ti", .long = "tebi", .exp = 40 },
    .{ .sym = "Pi", .long = "pebi", .exp = 50 }, .{ .sym = "Ei", .long = "exbi", .exp = 60 },
    .{ .sym = "Zi", .long = "zebi", .exp = 70 }, .{ .sym = "Yi", .long = "yobi", .exp = 80 },
};

// ---- finding a unit ----------------------------------------------------------------

const Found = struct { def: *const Def, prefix: ?Prefix = null, binary: bool = false };

fn hasWord(list: []const u8, word: []const u8, ci: bool) bool {
    var it = std.mem.splitScalar(u8, list, '|');
    while (it.next()) |w| {
        if (if (ci) std.ascii.eqlIgnoreCase(w, word) else std.mem.eql(u8, w, word)) return true;
    }
    return false;
}

fn allDefs(i: usize) ?*const Def {
    if (i < defs.len) return &defs[i];
    if (i < defs.len + temps.len) return &temps[i - defs.len];
    return null;
}

/// The longest names first would not matter: a name either is one unit or a prefix and one.
fn matchPlain(name: []const u8, comptime long: bool) ?*const Def {
    var i: usize = 0;
    while (allDefs(i)) |df| : (i += 1) {
        if (long) {
            if (hasWord(df.long, name, true)) return df;
        } else if (hasWord(df.sym, name, false)) return df;
    }
    return null;
}

fn allowsSi(df: *const Def) bool {
    return df.pre == .si or df.pre == .both;
}

fn allowsBin(df: *const Def) bool {
    return df.pre == .bin or df.pre == .both;
}

/// Strips a plural from a long name: "meters", "inches", "feet" (listed), "henries".
fn longMatch(name: []const u8) ?*const Def {
    if (matchPlain(name, true)) |x| return x;
    if (name.len > 1 and (name[name.len - 1] == 's' or name[name.len - 1] == 'S')) {
        if (matchPlain(name[0 .. name.len - 1], true)) |x| return x;
        if (name.len > 2 and std.ascii.eqlIgnoreCase(name[name.len - 2 ..], "es")) {
            if (matchPlain(name[0 .. name.len - 2], true)) |x| return x;
        }
    }
    return null;
}

fn find(name: []const u8) ?Found {
    if (name.len == 0 or name.len > 40) return null;
    if (matchPlain(name, false)) |df| return .{ .def = df };
    if (longMatch(name)) |df| return .{ .def = df };
    // A prefix and a unit.
    for (si_prefixes) |p| {
        if (name.len > p.sym.len and std.mem.startsWith(u8, name, p.sym)) {
            const rest = name[p.sym.len..];
            if (matchPlain(rest, false)) |df| if (allowsSi(df)) return .{ .def = df, .prefix = p };
        }
    }
    for (bin_prefixes) |p| {
        if (name.len > p.sym.len and std.mem.startsWith(u8, name, p.sym)) {
            const rest = name[p.sym.len..];
            if (matchPlain(rest, false)) |df| if (allowsBin(df)) return .{ .def = df, .prefix = p, .binary = true };
        }
    }
    // Long names: kilometers, milligram, gibibyte.
    var lower_buf: [48]u8 = undefined;
    const lower = std.ascii.lowerString(&lower_buf, name);
    for (si_prefixes) |p| {
        if (p.long.len > 1 and lower.len > p.long.len and std.mem.startsWith(u8, lower, p.long)) {
            if (longMatch(lower[p.long.len..])) |df| if (allowsSi(df)) return .{ .def = df, .prefix = p };
        }
    }
    for (bin_prefixes) |p| {
        if (lower.len > p.long.len and std.mem.startsWith(u8, lower, p.long)) {
            if (longMatch(lower[p.long.len..])) |df| if (allowsBin(df)) return .{ .def = df, .prefix = p, .binary = true };
        }
    }
    return null;
}

/// Is `name` a unit? (No allocation; for deciding how to read an entry.)
pub fn isUnitName(name: []const u8) bool {
    return find(name) != null;
}

// ---- building units ---------------------------------------------------------------------

fn parseDims(text: []const u8) Dims {
    var dims = @as(Dims, @splat(0));
    var it = std.mem.tokenizeScalar(u8, text, ' ');
    while (it.next()) |tok| {
        var k: usize = 0;
        while (k < tok.len and tok[k] != '-' and !std.ascii.isDigit(tok[k])) k += 1;
        const nm = tok[0..k];
        const e: i8 = if (k == tok.len) 1 else std.fmt.parseInt(i8, tok[k..], 10) catch 1;
        for (base_names, 0..) |b, i| if (std.mem.eql(u8, b, nm)) {
            dims[i] += e;
        };
    }
    return dims;
}

fn parseFactor(a: std.mem.Allocator, text: []const u8) Error!Number {
    if (text.len > 0 and text[0] == 'p') {
        const k = std.fmt.parseFloat(f64, text[1..]) catch return error.Domain;
        return .{ .approx = std.math.pi / k };
    }
    if (std.mem.indexOfScalar(u8, text, '/')) |s| {
        return num.div(a, try num.parseDecimal(a, text[0..s]), try num.parseDecimal(a, text[s + 1 ..]));
    }
    return num.parseDecimal(a, text);
}

fn tenPow(a: std.mem.Allocator, e: i32) Error!Number {
    return num.pow(a, try num.fromInt(a, 10), try num.fromInt(a, e));
}

pub fn resolve(a: std.mem.Allocator, name: []const u8) Error!?Unit {
    const f = find(name) orelse return null;
    var factor = try parseFactor(a, f.def.factor);
    var sym: []const u8 = std.mem.sliceTo(f.def.sym, '|');
    if (f.prefix) |p| {
        const scale = if (f.binary) try num.pow(a, try num.fromInt(a, 2), try num.fromInt(a, p.exp)) else try tenPow(a, p.exp);
        factor = try num.mul(a, factor, scale);
        sym = try std.fmt.allocPrint(a, "{s}{s}", .{ if (std.mem.eql(u8, p.sym, "deka")) "da" else if (std.mem.eql(u8, p.sym, "u")) "µ" else p.sym, sym });
    }
    return .{
        .sym = sym,
        .dims = parseDims(f.def.dims),
        .factor = factor,
        .offset = if (f.def.offset.len > 0) try parseFactor(a, f.def.offset) else null,
    };
}

// ---- constants ------------------------------------------------------------------------

const Constant = struct { names: []const u8, value: []const u8, dims: []const u8 };

const constants = [_]Constant{
    .{ .names = "c|c_0|lightspeed", .value = "299792458", .dims = "m s-1" },
    .{ .names = "G|gravitation", .value = "6.67430e-11", .dims = "m3 kg-1 s-2" },
    .{ .names = "planck|h_P", .value = "6.62607015e-34", .dims = "kg m2 s-1" },
    .{ .names = "hbar|ħ", .value = "1.054571817646156e-34", .dims = "kg m2 s-1" },
    .{ .names = "k_B|boltzmann", .value = "1.380649e-23", .dims = "kg m2 s-2 K-1" },
    .{ .names = "N_A|avogadro", .value = "6.02214076e23", .dims = "mol-1" },
    .{ .names = "R_gas|gasconstant", .value = "8.31446261815324", .dims = "kg m2 s-2 K-1 mol-1" },
    .{ .names = "q_e|elementarycharge", .value = "1.602176634e-19", .dims = "A s" },
    .{ .names = "m_e|electronmass", .value = "9.1093837015e-31", .dims = "kg" },
    .{ .names = "m_p|protonmass", .value = "1.67262192369e-27", .dims = "kg" },
    .{ .names = "m_n|neutronmass", .value = "1.67492749804e-27", .dims = "kg" },
    .{ .names = "epsilon_0|ε0|eps0", .value = "8.8541878128e-12", .dims = "kg-1 m-3 s4 A2" },
    .{ .names = "mu_0|μ0|mu0", .value = "1.25663706212e-6", .dims = "kg m s-2 A-2" },
    .{ .names = "g0|g_0|gravity", .value = "9.80665", .dims = "m s-2" },
    .{ .names = "sigma_sb|stefanboltzmann", .value = "5.670374419e-8", .dims = "kg s-3 K-4" },
    .{ .names = "F_const|faraday", .value = "96485.33212", .dims = "A s mol-1" },
    .{ .names = "alpha_fs|finestructure", .value = "0.0072973525693", .dims = "" },
    .{ .names = "R_inf|rydberg", .value = "10973731.568160", .dims = "m-1" },
    .{ .names = "a_0|bohrradius", .value = "5.29177210903e-11", .dims = "m" },
};

pub fn constant(a: std.mem.Allocator, name: []const u8) Error!?Quantity {
    for (constants) |k| {
        if (!hasWord(k.names, name, false)) continue;
        const dims = parseDims(k.dims);
        return try fromDims(a, try num.parseDecimal(a, k.value), dims);
    }
    return null;
}

pub fn isConstantName(name: []const u8) bool {
    for (constants) |k| if (hasWord(k.names, name, false)) return true;
    return false;
}

/// A value in SI base units with these dimensions.
fn fromDims(a: std.mem.Allocator, value: Number, dims: Dims) Error!Quantity {
    var list: std.ArrayList(UPow) = .empty;
    for (dims, 0..) |e, i| {
        if (e == 0) continue;
        const u = (try resolve(a, if (i == 1) "kg" else base_names[i])) orelse return error.Domain;
        try list.append(a, .{ .unit = u, .exp = e });
    }
    const q: Quantity = .{ .value = value, .units = list.items };
    return try derive(a, q);
}

// ---- arithmetic -----------------------------------------------------------------------

pub fn dimsOf(units: []const UPow) Dims {
    var out = @as(Dims, @splat(0));
    for (units) |u| for (0..ndim) |i| {
        out[i] += @intCast(@as(i32, u.unit.dims[i]) * u.exp);
    };
    return out;
}

fn dimsEqual(x: Dims, y: Dims) bool {
    return std.mem.eql(i8, &x, &y);
}

fn isZeroDims(x: Dims) bool {
    return std.mem.allEqual(i8, &x, 0);
}

fn factorOf(a: std.mem.Allocator, units: []const UPow) Error!Number {
    var f = try num.fromInt(a, 1);
    for (units) |u| f = try num.mul(a, f, try num.pow(a, u.unit.factor, try num.fromInt(a, u.exp)));
    return f;
}

fn sameUnit(x: Unit, y: Unit) bool {
    return std.mem.eql(u8, x.sym, y.sym) and dimsEqual(x.dims, y.dims);
}

/// Tidies a product: like units merge, units of one kind become the first,
/// cancelled ones vanish, SI products take their own name (kg·m/s² is N).
fn normalize(a: std.mem.Allocator, value_in: Number, list_in: []const UPow) Error!Quantity {
    var value = value_in;
    var list: std.ArrayList(UPow) = .empty;
    try list.appendSlice(a, list_in);
    // Merge units of the same dimensions into the first of them.
    var i: usize = 0;
    while (i < list.items.len) : (i += 1) {
        var j = i + 1;
        while (j < list.items.len) {
            if (dimsEqual(list.items[i].unit.dims, list.items[j].unit.dims) and list.items[i].unit.offset == null and list.items[j].unit.offset == null) {
                const ui = list.items[i];
                const uj = list.items[j];
                if (!sameUnit(ui.unit, uj.unit)) {
                    const ratio = try num.div(a, uj.unit.factor, ui.unit.factor);
                    value = try num.mul(a, value, try num.pow(a, ratio, try num.fromInt(a, uj.exp)));
                }
                list.items[i].exp += uj.exp;
                _ = list.orderedRemove(j);
            } else j += 1;
        }
    }
    // Zero exponents go.
    var k: usize = 0;
    while (k < list.items.len) {
        if (list.items[k].exp == 0) _ = list.orderedRemove(k) else k += 1;
    }
    const dims = dimsOf(list.items);
    // A dimensional product loses dimensionless units (angles).
    if (!isZeroDims(dims)) {
        var m: usize = 0;
        while (m < list.items.len) {
            if (isZeroDims(list.items[m].unit.dims)) {
                const u = list.items[m];
                value = try num.mul(a, value, try num.pow(a, u.unit.factor, try num.fromInt(a, u.exp)));
                _ = list.orderedRemove(m);
            } else m += 1;
        }
    }
    return derive(a, .{ .value = value, .units = list.items });
}

const derived_order = [_][]const u8{ "N", "J", "W", "Pa", "C", "V", "Ω", "F", "S", "Wb", "T", "H", "Hz" };

/// A product of coherent SI units that is a named unit takes its name.
fn derive(a: std.mem.Allocator, q: Quantity) Error!Quantity {
    if (q.units.len == 0) return q;
    for (q.units) |u| {
        if (u.unit.offset != null) return q;
        if (!num.isOneNumber(u.unit.factor)) return q;
    }
    if (q.units.len == 1 and q.units[0].exp == 1) return q;
    const dims = dimsOf(q.units);
    for (derived_order) |nm| {
        const u = (try resolve(a, nm)) orelse continue;
        if (dimsEqual(u.dims, dims)) {
            const out = try a.alloc(UPow, 1);
            out[0] = .{ .unit = u, .exp = 1 };
            return .{ .value = q.value, .units = out };
        }
    }
    return q;
}

pub fn mul(a: std.mem.Allocator, x: Quantity, y: Quantity) Error!Quantity {
    var list: std.ArrayList(UPow) = .empty;
    try list.appendSlice(a, x.units);
    try list.appendSlice(a, y.units);
    return normalize(a, try num.mul(a, x.value, y.value), list.items);
}

pub fn inverse(a: std.mem.Allocator, x: Quantity) Error!Quantity {
    const out = try a.alloc(UPow, x.units.len);
    for (x.units, 0..) |u, i| out[i] = .{ .unit = u.unit, .exp = -u.exp };
    return .{ .value = try num.div(a, try num.fromInt(a, 1), x.value), .units = out };
}

pub fn div(a: std.mem.Allocator, x: Quantity, y: Quantity) Error!Quantity {
    return mul(a, x, try inverse(a, y));
}

pub fn powInt(a: std.mem.Allocator, x: Quantity, n: i32) Error!Quantity {
    const out = try a.alloc(UPow, x.units.len);
    for (x.units, 0..) |u, i| out[i] = .{ .unit = u.unit, .exp = u.exp * n };
    return normalize(a, try num.pow(a, x.value, try num.fromInt(a, n)), out);
}

/// A root: the exponents must divide.
pub fn root(a: std.mem.Allocator, x: Quantity, n: i32, value_root: Number) Error!Quantity {
    const out = try a.alloc(UPow, x.units.len);
    for (x.units, 0..) |u, i| {
        if (@rem(u.exp, n) != 0) return error.Units;
        out[i] = .{ .unit = u.unit, .exp = @divExact(u.exp, n) };
    }
    return normalize(a, value_root, out);
}

pub fn neg(a: std.mem.Allocator, x: Quantity) Error!Quantity {
    return .{ .value = try num.neg(a, x.value), .units = x.units };
}

/// x ± y, in the unit of x.
pub fn add(a: std.mem.Allocator, x: Quantity, y: Quantity, subtract: bool) Error!Quantity {
    if (!dimsEqual(dimsOf(x.units), dimsOf(y.units))) return error.Units;
    const yv = try inUnitsOf(a, y, x.units);
    const v = if (subtract) try num.sub(a, x.value, yv) else try num.add(a, x.value, yv);
    return .{ .value = v, .units = x.units };
}

/// The value of `y` expressed in `units` (same dimensions).
fn inUnitsOf(a: std.mem.Allocator, y: Quantity, units: []const UPow) Error!Number {
    if (!dimsEqual(dimsOf(y.units), dimsOf(units))) return error.Units;
    // A lone temperature scale: through kelvin, with offsets.
    if (y.units.len == 1 and units.len == 1 and y.units[0].exp == 1 and units[0].exp == 1 and (y.units[0].unit.offset != null or units[0].unit.offset != null)) {
        const s = y.units[0].unit;
        const t = units[0].unit;
        var kelvin = y.value;
        if (s.offset) |o| kelvin = try num.add(a, kelvin, o);
        kelvin = try num.mul(a, kelvin, s.factor);
        var out = try num.div(a, kelvin, t.factor);
        if (t.offset) |o| out = try num.sub(a, out, o);
        return out;
    }
    return num.div(a, try num.mul(a, y.value, try factorOf(a, y.units)), try factorOf(a, units));
}

/// `x to target`: the same amount in the target's units.
pub fn convert(a: std.mem.Allocator, x: Quantity, target: []const UPow) Error!Quantity {
    return .{ .value = try inUnitsOf(a, x, target), .units = target };
}

/// The plain number a dimensionless quantity stands for (an angle in radians, a ratio).
pub fn dimensionless(a: std.mem.Allocator, x: Quantity) Error!?Number {
    if (!isZeroDims(dimsOf(x.units))) return null;
    return try num.mul(a, x.value, try factorOf(a, x.units));
}

pub fn isDimensionless(x: Quantity) bool {
    return isZeroDims(dimsOf(x.units));
}

// ---- showing -------------------------------------------------------------------------

const sup = [_][]const u8{ "⁰", "¹", "²", "³", "⁴", "⁵", "⁶", "⁷", "⁸", "⁹" };

fn writeUnit(a: std.mem.Allocator, out: *std.ArrayList(u8), u: UPow, exp: u32) !void {
    try out.appendSlice(a, u.unit.sym);
    if (exp != 1) {
        var buf: [12]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{exp}) catch return;
        for (s) |c| try out.appendSlice(a, sup[c - '0']);
    }
}

/// "m/s", "kg·m²/s", "1/s".
pub fn unitText(a: std.mem.Allocator, units: []const UPow) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var top: usize = 0;
    var bottom: usize = 0;
    for (units) |u| {
        if (u.exp > 0) top += 1 else bottom += 1;
    }
    var first = true;
    for (units) |u| if (u.exp > 0) {
        if (!first) try out.appendSlice(a, "·");
        first = false;
        try writeUnit(a, &out, u, @intCast(u.exp));
    };
    if (top == 0 and bottom > 0) try out.append(a, '1');
    if (bottom > 0) {
        try out.append(a, '/');
        if (bottom > 1) try out.append(a, '(');
        var f2 = true;
        for (units) |u| if (u.exp < 0) {
            if (!f2) try out.appendSlice(a, "·");
            f2 = false;
            try writeUnit(a, &out, u, @intCast(-u.exp));
        };
        if (bottom > 1) try out.append(a, ')');
    }
    return out.toOwnedSlice(a);
}

pub fn format(a: std.mem.Allocator, q: Quantity, style: num.Style) Error![]u8 {
    const v = try num.format(a, q.value, style);
    if (q.units.len == 0) return v;
    return std.fmt.allocPrint(a, "{s} {s}", .{ v, try unitText(a, q.units) });
}

// ---- tests ------------------------------------------------------------------------------

fn parseUnits(a: std.mem.Allocator, names: []const []const u8, exps: []const i32) ![]UPow {
    const out = try a.alloc(UPow, names.len);
    for (names, exps, 0..) |nm, e, i| out[i] = .{ .unit = (try resolve(a, nm)).?, .exp = e };
    return out;
}

test "units are found by symbol, name and prefix" {
    try std.testing.expect(isUnitName("km") and isUnitName("kilometers") and isUnitName("ft") and isUnitName("feet"));
    try std.testing.expect(isUnitName("MiB") and isUnitName("GB") and isUnitName("µm") and isUnitName("min"));
    try std.testing.expect(!isUnitName("x") and !isUnitName("foo"));
}

test "sums and conversions are exact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const five_ft: Quantity = .{ .value = try num.fromInt(a, 5), .units = try parseUnits(a, &.{"ft"}, &.{1}) };
    const three_in: Quantity = .{ .value = try num.fromInt(a, 3), .units = try parseUnits(a, &.{"in"}, &.{1}) };
    const s = try add(a, five_ft, three_in, false);
    try std.testing.expectEqualStrings("5.25 ft", try format(a, s, .{}));
    const cm = try convert(a, s, try parseUnits(a, &.{"cm"}, &.{1}));
    try std.testing.expectEqualStrings("160.02 cm", try format(a, cm, .{}));
    const f = try convert(a, .{ .value = try num.fromInt(a, 100), .units = try parseUnits(a, &.{"°C"}, &.{1}) }, try parseUnits(a, &.{"°F"}, &.{1}));
    try std.testing.expectEqualStrings("212 °F", try format(a, f, .{}));
    try std.testing.expectError(error.Units, add(a, five_ft, .{ .value = try num.fromInt(a, 1), .units = try parseUnits(a, &.{"s"}, &.{1}) }, false));
}

test "products take derived names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m5: Quantity = .{ .value = try num.fromInt(a, 5), .units = try parseUnits(a, &.{"kg"}, &.{1}) };
    const acc: Quantity = .{ .value = try num.fromInt(a, 2), .units = try parseUnits(a, &.{ "m", "s" }, &.{ 1, -2 }) };
    try std.testing.expectEqualStrings("10 N", try format(a, try mul(a, m5, acc), .{}));
    const x: Quantity = .{ .value = try num.fromInt(a, 3), .units = try parseUnits(a, &.{"m"}, &.{1}) };
    const y: Quantity = .{ .value = try num.fromInt(a, 2), .units = try parseUnits(a, &.{"ft"}, &.{1}) };
    try std.testing.expectEqualStrings("1.8288 m²", try format(a, try mul(a, x, y), .{ .decimals = 6 }));
}
