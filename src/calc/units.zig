//! Converting between units, for the Unit Conversion pane and for entries
//! such as "5 km in mi" or "100 °F to °C". Each unit is a factor to its
//! category's base unit (temperature also has an offset).

const std = @import("std");

pub const Unit = struct {
    /// What is shown in lists.
    label: []const u8,
    /// What can be typed (the first is the short name shown in results).
    names: []const []const u8,
    /// value in base = (value + offset) × factor
    factor: f64,
    offset: f64 = 0,
};

pub const Category = struct {
    label: []const u8,
    units: []const Unit,
};

fn u(label: []const u8, names: []const []const u8, factor: f64) Unit {
    return .{ .label = label, .names = names, .factor = factor };
}

pub const categories = [_]Category{
    .{ .label = "Length", .units = &.{
        u("Nanometres", &.{ "nm", "nanometre", "nanometer", "nanometres", "nanometers" }, 1e-9),
        u("Micrometres", &.{ "µm", "um", "micrometre", "micron" }, 1e-6),
        u("Millimetres", &.{ "mm", "millimetre", "millimeter", "millimetres", "millimeters" }, 1e-3),
        u("Centimetres", &.{ "cm", "centimetre", "centimeter", "centimetres", "centimeters" }, 1e-2),
        u("Metres", &.{ "m", "metre", "meter", "metres", "meters" }, 1),
        u("Kilometres", &.{ "km", "kilometre", "kilometer", "kilometres", "kilometers" }, 1e3),
        u("Inches", &.{ "in", "inch", "inches", "\"" }, 0.0254),
        u("Feet", &.{ "ft", "foot", "feet", "'" }, 0.3048),
        u("Yards", &.{ "yd", "yard", "yards" }, 0.9144),
        u("Miles", &.{ "mi", "mile", "miles" }, 1609.344),
        u("Nautical miles", &.{ "nmi", "nautical mile", "nautical miles" }, 1852),
        u("Light years", &.{ "ly", "light year", "light years", "lightyear" }, 9.4607304725808e15),
        u("Astronomical units", &.{ "au", "AU" }, 1.495978707e11),
    } },
    .{ .label = "Area", .units = &.{
        u("Square millimetres", &.{ "mm²", "mm2", "sq mm" }, 1e-6),
        u("Square centimetres", &.{ "cm²", "cm2", "sq cm" }, 1e-4),
        u("Square metres", &.{ "m²", "m2", "sq m" }, 1),
        u("Hectares", &.{ "ha", "hectare", "hectares" }, 1e4),
        u("Square kilometres", &.{ "km²", "km2", "sq km" }, 1e6),
        u("Square inches", &.{ "in²", "in2", "sq in" }, 0.00064516),
        u("Square feet", &.{ "ft²", "ft2", "sq ft" }, 0.09290304),
        u("Square yards", &.{ "yd²", "yd2", "sq yd" }, 0.83612736),
        u("Acres", &.{ "acre", "acres", "ac" }, 4046.8564224),
        u("Square miles", &.{ "mi²", "mi2", "sq mi" }, 2589988.110336),
    } },
    .{ .label = "Volume", .units = &.{
        u("Millilitres", &.{ "ml", "mL", "millilitre", "milliliter", "millilitres", "milliliters" }, 1e-3),
        u("Litres", &.{ "l", "L", "litre", "liter", "litres", "liters" }, 1),
        u("Cubic metres", &.{ "m³", "m3" }, 1000),
        u("Cubic centimetres", &.{ "cm³", "cm3", "cc" }, 1e-3),
        u("Teaspoons (US)", &.{ "tsp", "teaspoon", "teaspoons" }, 0.00492892159375),
        u("Tablespoons (US)", &.{ "tbsp", "tablespoon", "tablespoons" }, 0.01478676478125),
        u("Fluid ounces (US)", &.{ "floz", "fl oz", "fluid ounce", "fluid ounces" }, 0.0295735295625),
        u("Cups (US)", &.{ "cup", "cups" }, 0.2365882365),
        u("Pints (US)", &.{ "pt", "pint", "pints" }, 0.473176473),
        u("Quarts (US)", &.{ "qt", "quart", "quarts" }, 0.946352946),
        u("Gallons (US)", &.{ "gal", "gallon", "gallons" }, 3.785411784),
        u("Pints (UK)", &.{ "uk pt", "imperial pint" }, 0.56826125),
        u("Gallons (UK)", &.{ "uk gal", "imperial gallon" }, 4.54609),
        u("Cubic inches", &.{ "in³", "in3", "cu in" }, 0.016387064),
        u("Cubic feet", &.{ "ft³", "ft3", "cu ft" }, 28.316846592),
    } },
    .{ .label = "Mass", .units = &.{
        u("Milligrams", &.{ "mg", "milligram", "milligrams" }, 1e-6),
        u("Grams", &.{ "g", "gram", "grams" }, 1e-3),
        u("Kilograms", &.{ "kg", "kilogram", "kilograms", "kilo", "kilos" }, 1),
        u("Tonnes", &.{ "t", "tonne", "tonnes" }, 1000),
        u("Ounces", &.{ "oz", "ounce", "ounces" }, 0.028349523125),
        u("Pounds", &.{ "lb", "lbs", "pound", "pounds" }, 0.45359237),
        u("Stone", &.{ "st", "stone" }, 6.35029318),
        u("Short tons (US)", &.{ "ton", "tons", "short ton" }, 907.18474),
        u("Long tons (UK)", &.{ "long ton" }, 1016.0469088),
        u("Carats", &.{ "ct", "carat", "carats" }, 2e-4),
    } },
    .{ .label = "Temperature", .units = &.{
        .{ .label = "Celsius", .names = &.{ "°C", "C", "celsius", "degC" }, .factor = 1, .offset = 273.15 },
        .{ .label = "Fahrenheit", .names = &.{ "°F", "F", "fahrenheit", "degF" }, .factor = 5.0 / 9.0, .offset = 459.67 },
        .{ .label = "Kelvin", .names = &.{ "K", "kelvin" }, .factor = 1 },
        .{ .label = "Rankine", .names = &.{ "°R", "rankine" }, .factor = 5.0 / 9.0 },
    } },
    .{ .label = "Time", .units = &.{
        u("Milliseconds", &.{ "ms", "millisecond", "milliseconds" }, 1e-3),
        u("Seconds", &.{ "s", "sec", "second", "seconds" }, 1),
        u("Minutes", &.{ "min", "minute", "minutes" }, 60),
        u("Hours", &.{ "h", "hr", "hour", "hours" }, 3600),
        u("Days", &.{ "d", "day", "days" }, 86400),
        u("Weeks", &.{ "wk", "week", "weeks" }, 604800),
        u("Years (365.25 days)", &.{ "yr", "year", "years" }, 31557600),
    } },
    .{ .label = "Speed", .units = &.{
        u("Metres per second", &.{ "m/s", "mps" }, 1),
        u("Kilometres per hour", &.{ "km/h", "kph", "kmh" }, 1.0 / 3.6),
        u("Miles per hour", &.{ "mph", "mi/h" }, 0.44704),
        u("Feet per second", &.{ "ft/s", "fps" }, 0.3048),
        u("Knots", &.{ "kn", "knot", "knots", "kt" }, 1852.0 / 3600.0),
        u("Speed of sound (sea level)", &.{"mach"}, 340.29),
    } },
    .{ .label = "Pressure", .units = &.{
        u("Pascals", &.{ "Pa", "pascal", "pascals" }, 1),
        u("Kilopascals", &.{ "kPa", "kilopascal" }, 1e3),
        u("Bar", &.{ "bar", "bars" }, 1e5),
        u("Millibar", &.{ "mbar", "millibar" }, 100),
        u("Atmospheres", &.{ "atm", "atmosphere", "atmospheres" }, 101325),
        u("Pounds per square inch", &.{ "psi" }, 6894.757293168),
        u("Millimetres of mercury", &.{ "mmHg", "torr" }, 133.322387415),
    } },
    .{ .label = "Energy", .units = &.{
        u("Joules", &.{ "J", "joule", "joules" }, 1),
        u("Kilojoules", &.{ "kJ", "kilojoule", "kilojoules" }, 1e3),
        u("Calories", &.{ "cal", "calorie", "calories" }, 4.184),
        u("Kilocalories", &.{ "kcal", "Cal", "kilocalorie", "kilocalories" }, 4184),
        u("Watt hours", &.{ "Wh" }, 3600),
        u("Kilowatt hours", &.{ "kWh" }, 3.6e6),
        u("British thermal units", &.{ "BTU", "btu" }, 1055.05585262),
        u("Electronvolts", &.{ "eV" }, 1.602176634e-19),
    } },
    .{ .label = "Power", .units = &.{
        u("Watts", &.{ "W", "watt", "watts" }, 1),
        u("Kilowatts", &.{ "kW", "kilowatt", "kilowatts" }, 1e3),
        u("Megawatts", &.{ "MW", "megawatt", "megawatts" }, 1e6),
        u("Horsepower (mechanical)", &.{ "hp", "horsepower" }, 745.69987158227022),
        u("Horsepower (metric)", &.{ "PS" }, 735.49875),
        u("BTU per hour", &.{ "BTU/h" }, 0.29307107017),
    } },
    .{ .label = "Data", .units = &.{
        u("Bits", &.{ "bit", "bits" }, 0.125),
        u("Bytes", &.{ "B", "byte", "bytes" }, 1),
        u("Kilobytes (1000)", &.{ "kB", "KB" }, 1e3),
        u("Megabytes (1000²)", &.{ "MB" }, 1e6),
        u("Gigabytes (1000³)", &.{ "GB" }, 1e9),
        u("Terabytes (1000⁴)", &.{ "TB" }, 1e12),
        u("Kibibytes (1024)", &.{ "KiB" }, 1024),
        u("Mebibytes (1024²)", &.{ "MiB" }, 1048576),
        u("Gibibytes (1024³)", &.{ "GiB" }, 1073741824),
        u("Tebibytes (1024⁴)", &.{ "TiB" }, 1099511627776),
    } },
    .{ .label = "Angle", .units = &.{
        u("Degrees", &.{ "°", "deg", "degree", "degrees" }, std.math.pi / 180.0),
        u("Radians", &.{ "rad", "radian", "radians" }, 1),
        u("Gradians", &.{ "grad", "gon", "gradian", "gradians" }, std.math.pi / 200.0),
        u("Turns", &.{ "turn", "turns", "rev" }, 2 * std.math.pi),
        u("Minutes of arc", &.{ "arcmin" }, std.math.pi / 10800.0),
        u("Seconds of arc", &.{ "arcsec" }, std.math.pi / 648000.0),
    } },
    .{ .label = "Fuel economy", .units = &.{
        // Base: kilometres per litre. Litres per 100 km is the reciprocal kind, handled apart.
        u("Kilometres per litre", &.{ "km/l", "km/L" }, 1),
        u("Miles per gallon (US)", &.{ "mpg" }, 0.425143707),
        u("Miles per gallon (UK)", &.{ "mpg uk" }, 0.354006189),
        u("Litres per 100 km", &.{ "l/100km", "L/100km" }, -100),
    } },
};

pub const Found = struct { category: usize, unit: usize };

/// The unit with this name (exact case first, then any case).
pub fn find(name: []const u8) ?Found {
    const n = std.mem.trim(u8, name, " ");
    if (n.len == 0) return null;
    for (categories, 0..) |c, ci| for (c.units, 0..) |un, ui| for (un.names) |nm| {
        if (std.mem.eql(u8, nm, n)) return .{ .category = ci, .unit = ui };
    };
    for (categories, 0..) |c, ci| for (c.units, 0..) |un, ui| {
        for (un.names) |nm| if (nm.len > 2 and std.ascii.eqlIgnoreCase(nm, n)) return .{ .category = ci, .unit = ui };
        if (std.ascii.eqlIgnoreCase(un.label, n)) return .{ .category = ci, .unit = ui };
    };
    return null;
}

fn toBase(un: Unit, v: f64) f64 {
    // Litres per 100 km: the reciprocal of distance per volume.
    if (un.factor < 0) return if (v == 0) std.math.inf(f64) else -un.factor / v;
    return (v + un.offset) * un.factor;
}

fn fromBase(un: Unit, v: f64) f64 {
    if (un.factor < 0) return if (v == 0) std.math.inf(f64) else -un.factor / v;
    return v / un.factor - un.offset;
}

/// `v` in unit `from` as unit `to`, within one category.
pub fn convert(category: usize, from: usize, to: usize, v: f64) f64 {
    const c = categories[category];
    return fromBase(c.units[to], toBase(c.units[from], v));
}

pub const Request = struct {
    /// The amount, as typed (an expression).
    amount: []const u8,
    from: Found,
    to: Found,
};

/// "5 km in mi", "100 °F to °C", "3.5 kg in lb": the amount, and the two
/// units of one category. Null when the entry is not such a request.
pub fn request(text: []const u8) ?Request {
    const t = std.mem.trim(u8, text, " ");
    // The last " in " or " to ".
    var split: ?usize = null;
    var sep_len: usize = 0;
    var i: usize = 0;
    while (i + 4 <= t.len) : (i += 1) {
        if (std.mem.eql(u8, t[i .. i + 4], " in ") or std.mem.eql(u8, t[i .. i + 4], " to ")) {
            split = i;
            sep_len = 4;
        }
    }
    const at = split orelse return null;
    const left = std.mem.trim(u8, t[0..at], " ");
    const to_name = std.mem.trim(u8, t[at + sep_len ..], " ");
    const to = find(to_name) orelse return null;
    // The longest unit name at the end of the left side.
    var best: ?Request = null;
    var k: usize = left.len;
    while (k > 0) {
        k -= 1;
        const tail = std.mem.trim(u8, left[k..], " ");
        if (find(tail)) |from| {
            if (from.category != to.category) continue;
            const amount = std.mem.trim(u8, left[0..k], " ");
            if (amount.len == 0) continue;
            // The amount must end where the unit begins (no letters run into it: "5km" is fine).
            best = .{ .amount = amount, .from = from, .to = to };
        }
    }
    return best;
}

pub fn shortName(f: Found) []const u8 {
    return categories[f.category].units[f.unit].names[0];
}

test "conversions" {
    const len = find("km").?;
    const mi = find("mi").?;
    try std.testing.expectApproxEqAbs(@as(f64, 3.10685596), convert(len.category, len.unit, mi.unit, 5), 1e-6);
    const c = find("°C").?;
    const f = find("°F").?;
    try std.testing.expectApproxEqAbs(@as(f64, 212), convert(c.category, c.unit, f.unit, 100), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -40), convert(f.category, f.unit, c.unit, -40), 1e-9);
    const k = find("kelvin").?;
    try std.testing.expectApproxEqAbs(@as(f64, 273.15), convert(c.category, c.unit, k.unit, 0), 1e-9);
    const mpg = find("mpg").?;
    const l100 = find("L/100km").?;
    try std.testing.expectApproxEqAbs(@as(f64, 7.84049), convert(mpg.category, mpg.unit, l100.unit, 30), 1e-4);
    const gib = find("GiB").?;
    const gb = find("GB").?;
    try std.testing.expectApproxEqAbs(@as(f64, 1.073741824), convert(gib.category, gib.unit, gb.unit, 1), 1e-12);
}

test "requests in the entry" {
    const r = request("5 km in mi").?;
    try std.testing.expectEqualStrings("5", r.amount);
    try std.testing.expectEqualStrings("km", shortName(r.from));
    try std.testing.expectEqualStrings("mi", shortName(r.to));
    const r2 = request("(2+3) * 4 kg to lb").?;
    try std.testing.expectEqualStrings("(2+3) * 4", r2.amount);
    const r3 = request("100 °F to °C").?;
    try std.testing.expectEqualStrings("°C", shortName(r3.to));
    const r4 = request("3 nautical miles in km").?;
    try std.testing.expectEqualStrings("nmi", shortName(r4.from));
    try std.testing.expect(request("5 km in kg") == null);
    try std.testing.expect(request("2 + 3") == null);
    try std.testing.expect(request("5 apples in mi") == null);
}
