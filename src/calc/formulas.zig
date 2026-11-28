// SPDX-License-Identifier: GPL-2.0-or-later
//! The formulas offered in the Formulas pane. Picking one puts it in the
//! entry; a field for each of its letters fills values in; Enter then
//! solves for the one left out (or tidies the formula when several are).
//!
//! Angles in trigonometric formulas are in the calculator's angle unit
//! (degrees unless changed); formulas that need degrees or radians say so.

pub const Var = struct {
    name: []const u8,
    what: []const u8,
    /// Filled in at the start (constants such as g).
    default: []const u8 = "",
};

pub const Formula = struct {
    group: []const u8,
    name: []const u8,
    text: []const u8,
    vars: []const Var,
};

fn v(name: []const u8, what: []const u8) Var {
    return .{ .name = name, .what = what };
}

fn c(name: []const u8, what: []const u8, default: []const u8) Var {
    return .{ .name = name, .what = what, .default = default };
}

const g_earth = c("g", "gravity (m/s²)", "9.80665");

pub const all = blk: {
    @setEvalBranchQuota(1_000_000);
    break :blk [_]Formula{
    // ---- Plane geometry
    .{ .group = "Plane geometry", .name = "Area of a circle", .text = "A = π·r²", .vars = &.{ v("A", "area"), v("r", "radius") } },
    .{ .group = "Plane geometry", .name = "Circumference of a circle", .text = "C = 2π·r", .vars = &.{ v("C", "circumference"), v("r", "radius") } },
    .{ .group = "Plane geometry", .name = "Diameter of a circle", .text = "d = 2r", .vars = &.{ v("d", "diameter"), v("r", "radius") } },
    .{ .group = "Plane geometry", .name = "Area of a sector", .text = "A = θ/360·π·r²", .vars = &.{ v("A", "area"), v("θ", "angle in degrees"), v("r", "radius") } },
    .{ .group = "Plane geometry", .name = "Length of an arc", .text = "L = θ/360·2π·r", .vars = &.{ v("L", "arc length"), v("θ", "angle in degrees"), v("r", "radius") } },
    .{ .group = "Plane geometry", .name = "Area of a square", .text = "A = s²", .vars = &.{ v("A", "area"), v("s", "side") } },
    .{ .group = "Plane geometry", .name = "Diagonal of a square", .text = "d = s·√2", .vars = &.{ v("d", "diagonal"), v("s", "side") } },
    .{ .group = "Plane geometry", .name = "Area of a rectangle", .text = "A = w·h", .vars = &.{ v("A", "area"), v("w", "width"), v("h", "height") } },
    .{ .group = "Plane geometry", .name = "Perimeter of a rectangle", .text = "P = 2(w + h)", .vars = &.{ v("P", "perimeter"), v("w", "width"), v("h", "height") } },
    .{ .group = "Plane geometry", .name = "Diagonal of a rectangle", .text = "d = √(w² + h²)", .vars = &.{ v("d", "diagonal"), v("w", "width"), v("h", "height") } },
    .{ .group = "Plane geometry", .name = "Area of a triangle", .text = "A = b·h/2", .vars = &.{ v("A", "area"), v("b", "base"), v("h", "height") } },
    .{ .group = "Plane geometry", .name = "Area of a triangle from its sides (Heron)", .text = "A = √((a + b + c)·(−a + b + c)·(a − b + c)·(a + b − c))/4", .vars = &.{ v("A", "area"), v("a", "side a"), v("b", "side b"), v("c", "side c") } },
    .{ .group = "Plane geometry", .name = "Area of an equilateral triangle", .text = "A = √3/4·s²", .vars = &.{ v("A", "area"), v("s", "side") } },
    .{ .group = "Plane geometry", .name = "Area of a trapezoid", .text = "A = (a + b)·h/2", .vars = &.{ v("A", "area"), v("a", "one parallel side"), v("b", "the other parallel side"), v("h", "height") } },
    .{ .group = "Plane geometry", .name = "Area of a parallelogram", .text = "A = b·h", .vars = &.{ v("A", "area"), v("b", "base"), v("h", "height") } },
    .{ .group = "Plane geometry", .name = "Area of a rhombus", .text = "A = p·q/2", .vars = &.{ v("A", "area"), v("p", "one diagonal"), v("q", "the other diagonal") } },
    .{ .group = "Plane geometry", .name = "Area of an ellipse", .text = "A = π·a·b", .vars = &.{ v("A", "area"), v("a", "half the long axis"), v("b", "half the short axis") } },
    .{ .group = "Plane geometry", .name = "Perimeter of an ellipse (Ramanujan)", .text = "P = π·(3(a + b) − √((3a + b)·(a + 3b)))", .vars = &.{ v("P", "perimeter"), v("a", "half the long axis"), v("b", "half the short axis") } },
    .{ .group = "Plane geometry", .name = "Angles of a polygon", .text = "S = (n − 2)·180", .vars = &.{ v("S", "sum of the inside angles (°)"), v("n", "number of sides") } },
    .{ .group = "Plane geometry", .name = "Area of a regular hexagon", .text = "A = 3√3/2·s²", .vars = &.{ v("A", "area"), v("s", "side") } },

    // ---- Solid geometry
    .{ .group = "Solid geometry", .name = "Volume of a cube", .text = "V = s³", .vars = &.{ v("V", "volume"), v("s", "side") } },
    .{ .group = "Solid geometry", .name = "Surface of a cube", .text = "A = 6s²", .vars = &.{ v("A", "surface area"), v("s", "side") } },
    .{ .group = "Solid geometry", .name = "Volume of a box", .text = "V = l·w·h", .vars = &.{ v("V", "volume"), v("l", "length"), v("w", "width"), v("h", "height") } },
    .{ .group = "Solid geometry", .name = "Surface of a box", .text = "A = 2(l·w + l·h + w·h)", .vars = &.{ v("A", "surface area"), v("l", "length"), v("w", "width"), v("h", "height") } },
    .{ .group = "Solid geometry", .name = "Volume of a sphere", .text = "V = 4/3·π·r³", .vars = &.{ v("V", "volume"), v("r", "radius") } },
    .{ .group = "Solid geometry", .name = "Surface of a sphere", .text = "A = 4π·r²", .vars = &.{ v("A", "surface area"), v("r", "radius") } },
    .{ .group = "Solid geometry", .name = "Volume of a hemisphere", .text = "V = 2/3·π·r³", .vars = &.{ v("V", "volume"), v("r", "radius") } },
    .{ .group = "Solid geometry", .name = "Volume of a cylinder", .text = "V = π·r²·h", .vars = &.{ v("V", "volume"), v("r", "radius"), v("h", "height") } },
    .{ .group = "Solid geometry", .name = "Surface of a cylinder", .text = "A = 2π·r·(r + h)", .vars = &.{ v("A", "surface area"), v("r", "radius"), v("h", "height") } },
    .{ .group = "Solid geometry", .name = "Volume of a cone", .text = "V = π·r²·h/3", .vars = &.{ v("V", "volume"), v("r", "radius"), v("h", "height") } },
    .{ .group = "Solid geometry", .name = "Slant height of a cone", .text = "s = √(r² + h²)", .vars = &.{ v("s", "slant height"), v("r", "radius"), v("h", "height") } },
    .{ .group = "Solid geometry", .name = "Surface of a cone", .text = "A = π·r·(r + √(r² + h²))", .vars = &.{ v("A", "surface area"), v("r", "radius"), v("h", "height") } },
    .{ .group = "Solid geometry", .name = "Volume of a pyramid", .text = "V = B·h/3", .vars = &.{ v("V", "volume"), v("B", "area of the base"), v("h", "height") } },
    .{ .group = "Solid geometry", .name = "Volume of a torus", .text = "V = 2π²·R·r²", .vars = &.{ v("V", "volume"), v("R", "radius to the tube's centre"), v("r", "radius of the tube") } },
    .{ .group = "Solid geometry", .name = "Volume of a prism", .text = "V = B·h", .vars = &.{ v("V", "volume"), v("B", "area of the base"), v("h", "height") } },

    // ---- Coordinate geometry
    .{ .group = "Coordinate geometry", .name = "Distance between two points", .text = "d = √((x2 − x1)² + (y2 − y1)²)", .vars = &.{ v("d", "distance"), v("x1", "first x"), v("y1", "first y"), v("x2", "second x"), v("y2", "second y") } },
    .{ .group = "Coordinate geometry", .name = "Distance in space", .text = "d = √((x2 − x1)² + (y2 − y1)² + (z2 − z1)²)", .vars = &.{ v("d", "distance"), v("x1", "first x"), v("y1", "first y"), v("z1", "first z"), v("x2", "second x"), v("y2", "second y"), v("z2", "second z") } },
    .{ .group = "Coordinate geometry", .name = "Midpoint (one coordinate)", .text = "m = (x1 + x2)/2", .vars = &.{ v("m", "midpoint"), v("x1", "first"), v("x2", "second") } },
    .{ .group = "Coordinate geometry", .name = "Slope of a line", .text = "m = (y2 − y1)/(x2 − x1)", .vars = &.{ v("m", "slope"), v("x1", "first x"), v("y1", "first y"), v("x2", "second x"), v("y2", "second y") } },
    .{ .group = "Coordinate geometry", .name = "Straight line", .text = "y = m·x + b", .vars = &.{ v("y", "y"), v("m", "slope"), v("x", "x"), v("b", "y at x = 0") } },
    .{ .group = "Coordinate geometry", .name = "Line through a point", .text = "y − y1 = m·(x − x1)", .vars = &.{ v("y", "y"), v("x", "x"), v("m", "slope"), v("x1", "the point's x"), v("y1", "the point's y") } },
    .{ .group = "Coordinate geometry", .name = "Circle", .text = "(x − h)² + (y − k)² = r²", .vars = &.{ v("x", "x"), v("y", "y"), v("h", "centre x"), v("k", "centre y"), v("r", "radius") } },

    // ---- Trigonometry
    .{ .group = "Trigonometry", .name = "Pythagoras", .text = "c² = a² + b²", .vars = &.{ v("c", "hypotenuse"), v("a", "one side"), v("b", "the other side") } },
    .{ .group = "Trigonometry", .name = "Sine in a right triangle", .text = "sin(θ) = o/h", .vars = &.{ v("θ", "angle"), v("o", "opposite side"), v("h", "hypotenuse") } },
    .{ .group = "Trigonometry", .name = "Cosine in a right triangle", .text = "cos(θ) = a/h", .vars = &.{ v("θ", "angle"), v("a", "adjacent side"), v("h", "hypotenuse") } },
    .{ .group = "Trigonometry", .name = "Tangent in a right triangle", .text = "tan(θ) = o/a", .vars = &.{ v("θ", "angle"), v("o", "opposite side"), v("a", "adjacent side") } },
    .{ .group = "Trigonometry", .name = "Law of sines", .text = "a/sin(A) = b/sin(B)", .vars = &.{ v("a", "side a"), v("A", "angle opposite a"), v("b", "side b"), v("B", "angle opposite b") } },
    .{ .group = "Trigonometry", .name = "Law of cosines", .text = "c² = a² + b² − 2a·b·cos(C)", .vars = &.{ v("c", "side c"), v("a", "side a"), v("b", "side b"), v("C", "angle between a and b") } },
    .{ .group = "Trigonometry", .name = "Area from two sides and an angle", .text = "S = a·b·sin(C)/2", .vars = &.{ v("S", "area"), v("a", "side a"), v("b", "side b"), v("C", "angle between them") } },
    .{ .group = "Trigonometry", .name = "Angles of a triangle", .text = "A + B + C = 180", .vars = &.{ v("A", "angle A (°)"), v("B", "angle B (°)"), v("C", "angle C (°)") } },
    .{ .group = "Trigonometry", .name = "Degrees to radians", .text = "r = d·π/180", .vars = &.{ v("r", "radians"), v("d", "degrees") } },
    .{ .group = "Trigonometry", .name = "Arc length (radians)", .text = "s = r·θ", .vars = &.{ v("s", "arc length"), v("r", "radius"), v("θ", "angle in radians") } },
    .{ .group = "Trigonometry", .name = "Height from an angle of elevation", .text = "h = d·tan(θ)", .vars = &.{ v("h", "height"), v("d", "distance along the ground"), v("θ", "angle of elevation") } },

    // ---- Algebra
    .{ .group = "Algebra", .name = "Quadratic equation", .text = "a·x² + b·x + c = 0", .vars = &.{ v("x", "unknown"), v("a", "x² coefficient"), v("b", "x coefficient"), v("c", "constant") } },
    .{ .group = "Algebra", .name = "Proportion", .text = "a/b = c/d", .vars = &.{ v("a", "a"), v("b", "b"), v("c", "c"), v("d", "d") } },
    .{ .group = "Algebra", .name = "Percentage", .text = "p = part/whole·100", .vars = &.{ v("p", "percent"), v("part", "part"), v("whole", "whole") } },
    .{ .group = "Algebra", .name = "Percentage change", .text = "p = (new − old)/old·100", .vars = &.{ v("p", "change in %"), v("new", "new value"), v("old", "old value") } },
    .{ .group = "Algebra", .name = "Arithmetic sequence", .text = "an = a1 + (n − 1)·d", .vars = &.{ v("an", "the n-th term"), v("a1", "first term"), v("n", "n"), v("d", "difference") } },
    .{ .group = "Algebra", .name = "Arithmetic series", .text = "S = n·(a1 + an)/2", .vars = &.{ v("S", "sum"), v("n", "number of terms"), v("a1", "first term"), v("an", "last term") } },
    .{ .group = "Algebra", .name = "Geometric sequence", .text = "an = a1·q^(n − 1)", .vars = &.{ v("an", "the n-th term"), v("a1", "first term"), v("q", "ratio"), v("n", "n") } },
    .{ .group = "Algebra", .name = "Geometric series", .text = "S = a1·(1 − q^n)/(1 − q)", .vars = &.{ v("S", "sum"), v("a1", "first term"), v("q", "ratio"), v("n", "number of terms") } },
    .{ .group = "Algebra", .name = "Exponential growth", .text = "N = N0·e^(k·t)", .vars = &.{ v("N", "amount"), v("N0", "starting amount"), v("k", "growth rate"), v("t", "time") } },
    .{ .group = "Algebra", .name = "Half-life", .text = "N = N0·(1/2)^(t/T)", .vars = &.{ v("N", "amount left"), v("N0", "starting amount"), v("t", "time"), v("T", "half-life") } },

    // ---- Motion
    .{ .group = "Motion", .name = "Speed", .text = "v = d/t", .vars = &.{ v("v", "speed"), v("d", "distance"), v("t", "time") } },
    .{ .group = "Motion", .name = "Acceleration", .text = "a = (v − u)/t", .vars = &.{ v("a", "acceleration"), v("v", "final speed"), v("u", "starting speed"), v("t", "time") } },
    .{ .group = "Motion", .name = "Speed after accelerating", .text = "v = u + a·t", .vars = &.{ v("v", "final speed"), v("u", "starting speed"), v("a", "acceleration"), v("t", "time") } },
    .{ .group = "Motion", .name = "Distance while accelerating", .text = "s = u·t + a·t²/2", .vars = &.{ v("s", "distance"), v("u", "starting speed"), v("a", "acceleration"), v("t", "time") } },
    .{ .group = "Motion", .name = "Speed and distance", .text = "v² = u² + 2a·s", .vars = &.{ v("v", "final speed"), v("u", "starting speed"), v("a", "acceleration"), v("s", "distance") } },
    .{ .group = "Motion", .name = "Free fall", .text = "d = g·t²/2", .vars = &.{ v("d", "distance (m)"), g_earth, v("t", "time (s)") } },
    .{ .group = "Motion", .name = "Range of a projectile", .text = "R = u²·sin(2θ)/g", .vars = &.{ v("R", "range (m)"), v("u", "launch speed (m/s)"), v("θ", "launch angle"), g_earth } },
    .{ .group = "Motion", .name = "Centripetal acceleration", .text = "a = v²/r", .vars = &.{ v("a", "acceleration"), v("v", "speed"), v("r", "radius") } },
    .{ .group = "Motion", .name = "Period of a pendulum", .text = "T = 2π·√(L/g)", .vars = &.{ v("T", "period (s)"), v("L", "length (m)"), g_earth } },

    // ---- Forces and energy
    .{ .group = "Forces and energy", .name = "Force", .text = "F = m·a", .vars = &.{ v("F", "force (N)"), v("m", "mass (kg)"), v("a", "acceleration (m/s²)") } },
    .{ .group = "Forces and energy", .name = "Weight", .text = "W = m·g", .vars = &.{ v("W", "weight (N)"), v("m", "mass (kg)"), g_earth } },
    .{ .group = "Forces and energy", .name = "Momentum", .text = "p = m·v", .vars = &.{ v("p", "momentum"), v("m", "mass (kg)"), v("v", "speed (m/s)") } },
    .{ .group = "Forces and energy", .name = "Friction", .text = "F = μ·N", .vars = &.{ v("F", "friction (N)"), v("μ", "coefficient of friction"), v("N", "normal force (N)") } },
    .{ .group = "Forces and energy", .name = "Work", .text = "W = F·d", .vars = &.{ v("W", "work (J)"), v("F", "force (N)"), v("d", "distance (m)") } },
    .{ .group = "Forces and energy", .name = "Power", .text = "P = W/t", .vars = &.{ v("P", "power (W)"), v("W", "work (J)"), v("t", "time (s)") } },
    .{ .group = "Forces and energy", .name = "Kinetic energy", .text = "E = m·v²/2", .vars = &.{ v("E", "energy (J)"), v("m", "mass (kg)"), v("v", "speed (m/s)") } },
    .{ .group = "Forces and energy", .name = "Potential energy", .text = "E = m·g·h", .vars = &.{ v("E", "energy (J)"), v("m", "mass (kg)"), g_earth, v("h", "height (m)") } },
    .{ .group = "Forces and energy", .name = "Spring force (Hooke)", .text = "F = k·x", .vars = &.{ v("F", "force (N)"), v("k", "spring constant (N/m)"), v("x", "stretch (m)") } },
    .{ .group = "Forces and energy", .name = "Energy in a spring", .text = "E = k·x²/2", .vars = &.{ v("E", "energy (J)"), v("k", "spring constant (N/m)"), v("x", "stretch (m)") } },
    .{ .group = "Forces and energy", .name = "Turning force (torque)", .text = "M = F·r", .vars = &.{ v("M", "torque (N·m)"), v("F", "force (N)"), v("r", "lever arm (m)") } },
    .{ .group = "Forces and energy", .name = "Pressure", .text = "P = F/A", .vars = &.{ v("P", "pressure (Pa)"), v("F", "force (N)"), v("A", "area (m²)") } },
    .{ .group = "Forces and energy", .name = "Density", .text = "ρ = m/V", .vars = &.{ v("ρ", "density"), v("m", "mass"), v("V", "volume") } },
    .{ .group = "Forces and energy", .name = "Buoyancy", .text = "F = ρ·g·V", .vars = &.{ v("F", "lift (N)"), v("ρ", "fluid density (kg/m³)"), g_earth, v("V", "volume under water (m³)") } },
    .{ .group = "Forces and energy", .name = "Gravitation", .text = "F = G·m1·m2/r²", .vars = &.{ v("F", "force (N)"), c("G", "gravitational constant", "6.6743e-11"), v("m1", "first mass (kg)"), v("m2", "second mass (kg)"), v("r", "distance (m)") } },
    .{ .group = "Forces and energy", .name = "Efficiency", .text = "η = out/in·100", .vars = &.{ v("η", "efficiency (%)"), v("out", "useful energy out"), v("in", "energy in") } },

    // ---- Waves and light
    .{ .group = "Waves and light", .name = "Wave speed", .text = "v = f·λ", .vars = &.{ v("v", "speed (m/s)"), v("f", "frequency (Hz)"), v("λ", "wavelength (m)") } },
    .{ .group = "Waves and light", .name = "Frequency and period", .text = "f = 1/T", .vars = &.{ v("f", "frequency (Hz)"), v("T", "period (s)") } },
    .{ .group = "Waves and light", .name = "Energy of a photon", .text = "E = h·f", .vars = &.{ v("E", "energy (J)"), c("h", "Planck constant", "6.62607015e-34"), v("f", "frequency (Hz)") } },
    .{ .group = "Waves and light", .name = "Refraction (Snell)", .text = "n1·sin(a1) = n2·sin(a2)", .vars = &.{ v("n1", "first refractive index"), v("a1", "angle in"), v("n2", "second refractive index"), v("a2", "angle out") } },
    .{ .group = "Waves and light", .name = "Thin lens", .text = "1/f = 1/u + 1/v", .vars = &.{ v("f", "focal length"), v("u", "object distance"), v("v", "image distance") } },
    .{ .group = "Waves and light", .name = "Magnification", .text = "M = v/u", .vars = &.{ v("M", "magnification"), v("v", "image distance"), v("u", "object distance") } },
    .{ .group = "Waves and light", .name = "Sound level", .text = "L = 10log(I/I0)", .vars = &.{ v("L", "level (dB)"), v("I", "intensity (W/m²)"), c("I0", "threshold of hearing", "1e-12") } },

    // ---- Heat and gases
    .{ .group = "Heat and gases", .name = "Ideal gas", .text = "P·V = n·R·T", .vars = &.{ v("P", "pressure (Pa)"), v("V", "volume (m³)"), v("n", "amount (mol)"), c("R", "gas constant", "8.314462618"), v("T", "temperature (K)") } },
    .{ .group = "Heat and gases", .name = "Boyle's law", .text = "P1·V1 = P2·V2", .vars = &.{ v("P1", "first pressure"), v("V1", "first volume"), v("P2", "second pressure"), v("V2", "second volume") } },
    .{ .group = "Heat and gases", .name = "Charles's law", .text = "V1/T1 = V2/T2", .vars = &.{ v("V1", "first volume"), v("T1", "first temperature (K)"), v("V2", "second volume"), v("T2", "second temperature (K)") } },
    .{ .group = "Heat and gases", .name = "Heat", .text = "Q = m·c·dT", .vars = &.{ v("Q", "heat (J)"), v("m", "mass (kg)"), v("c", "specific heat (J/(kg·K))"), v("dT", "temperature change") } },
    .{ .group = "Heat and gases", .name = "Fahrenheit and Celsius", .text = "F = C·9/5 + 32", .vars = &.{ v("F", "°F"), v("C", "°C") } },
    .{ .group = "Heat and gases", .name = "Kelvin and Celsius", .text = "K = C + 273.15", .vars = &.{ v("K", "kelvin"), v("C", "°C") } },

    // ---- Electricity
    .{ .group = "Electricity", .name = "Ohm's law", .text = "V = I·R", .vars = &.{ v("V", "voltage (V)"), v("I", "current (A)"), v("R", "resistance (Ω)") } },
    .{ .group = "Electricity", .name = "Power", .text = "P = V·I", .vars = &.{ v("P", "power (W)"), v("V", "voltage (V)"), v("I", "current (A)") } },
    .{ .group = "Electricity", .name = "Power from current", .text = "P = I²·R", .vars = &.{ v("P", "power (W)"), v("I", "current (A)"), v("R", "resistance (Ω)") } },
    .{ .group = "Electricity", .name = "Power from voltage", .text = "P = V²/R", .vars = &.{ v("P", "power (W)"), v("V", "voltage (V)"), v("R", "resistance (Ω)") } },
    .{ .group = "Electricity", .name = "Energy used", .text = "E = P·t", .vars = &.{ v("E", "energy (Wh if t in hours)"), v("P", "power (W)"), v("t", "time") } },
    .{ .group = "Electricity", .name = "Resistors in series", .text = "R = R1 + R2 + R3", .vars = &.{ v("R", "total (Ω)"), v("R1", "first (Ω)"), v("R2", "second (Ω)"), v("R3", "third (Ω)") } },
    .{ .group = "Electricity", .name = "Resistors in parallel", .text = "1/R = 1/R1 + 1/R2", .vars = &.{ v("R", "total (Ω)"), v("R1", "first (Ω)"), v("R2", "second (Ω)") } },
    .{ .group = "Electricity", .name = "Charge on a capacitor", .text = "Q = C·V", .vars = &.{ v("Q", "charge (C)"), v("C", "capacitance (F)"), v("V", "voltage (V)") } },
    .{ .group = "Electricity", .name = "Energy in a capacitor", .text = "E = C·V²/2", .vars = &.{ v("E", "energy (J)"), v("C", "capacitance (F)"), v("V", "voltage (V)") } },
    .{ .group = "Electricity", .name = "RC time constant", .text = "t = R·C", .vars = &.{ v("t", "time constant (s)"), v("R", "resistance (Ω)"), v("C", "capacitance (F)") } },
    .{ .group = "Electricity", .name = "Coulomb's law", .text = "F = k·q1·q2/r²", .vars = &.{ v("F", "force (N)"), c("k", "Coulomb constant", "8.9875517923e9"), v("q1", "first charge (C)"), v("q2", "second charge (C)"), v("r", "distance (m)") } },
    .{ .group = "Electricity", .name = "Resonant frequency", .text = "f = 1/(2π·√(L·C))", .vars = &.{ v("f", "frequency (Hz)"), v("L", "inductance (H)"), v("C", "capacitance (F)") } },
    .{ .group = "Electricity", .name = "Voltage divider", .text = "Vout = Vin·R2/(R1 + R2)", .vars = &.{ v("Vout", "output voltage"), v("Vin", "input voltage"), v("R1", "upper resistor (Ω)"), v("R2", "lower resistor (Ω)") } },
    .{ .group = "Electricity", .name = "Two resistors in parallel", .text = "R = R1·R2/(R1 + R2)", .vars = &.{ v("R", "total resistance"), v("R1", "first resistor"), v("R2", "second resistor") } },
    .{ .group = "Electricity", .name = "Current divider", .text = "I1 = I·R2/(R1 + R2)", .vars = &.{ v("I1", "current in the first branch"), v("I", "total current"), v("R1", "first resistor"), v("R2", "second resistor") } },
    .{ .group = "Electricity", .name = "Resistor for an LED", .text = "R = (Vs − Vf)/I", .vars = &.{ v("R", "resistor"), v("Vs", "supply voltage"), v("Vf", "LED forward voltage"), v("I", "LED current") } },
    .{ .group = "Electricity", .name = "Voltage on a charging capacitor", .text = "V = Vs·(1 − e^(−t/(R·C)))", .vars = &.{ v("V", "capacitor voltage"), v("Vs", "supply voltage"), v("t", "time"), v("R", "resistance"), v("C", "capacitance") } },
    .{ .group = "Electricity", .name = "Time to charge to a fraction", .text = "t = −R·C·ln(1 − f)", .vars = &.{ v("t", "time"), v("R", "resistance"), v("C", "capacitance"), v("f", "fraction of the supply (0 to 1)") } },
    .{ .group = "Electricity", .name = "RC filter cutoff frequency", .text = "f = 1/(2π·R·C)", .vars = &.{ v("f", "cutoff frequency"), v("R", "resistance"), v("C", "capacitance") } },
    .{ .group = "Electricity", .name = "Capacitive reactance", .text = "X = 1/(2π·f·C)", .vars = &.{ v("X", "reactance (Ω)"), v("f", "frequency"), v("C", "capacitance") } },
    .{ .group = "Electricity", .name = "Inductive reactance", .text = "X = 2π·f·L", .vars = &.{ v("X", "reactance (Ω)"), v("f", "frequency"), v("L", "inductance") } },
    .{ .group = "Electricity", .name = "Impedance of a series circuit", .text = "Z = √(R² + X²)", .vars = &.{ v("Z", "impedance"), v("R", "resistance"), v("X", "net reactance") } },
    .{ .group = "Electricity", .name = "Energy in an inductor", .text = "E = L·I²/2", .vars = &.{ v("E", "energy"), v("L", "inductance"), v("I", "current") } },
    .{ .group = "Electricity", .name = "Quality factor", .text = "Q = X/R", .vars = &.{ v("Q", "quality factor"), v("X", "reactance at resonance"), v("R", "resistance") } },
    .{ .group = "Electricity", .name = "Bandwidth of a resonant circuit", .text = "B = f/Q", .vars = &.{ v("B", "bandwidth"), v("f", "resonant frequency"), v("Q", "quality factor") } },
    .{ .group = "Electricity", .name = "Gain in decibels", .text = "G = 20·log10(Vout/Vin)", .vars = &.{ v("G", "gain (dB)"), v("Vout", "output voltage"), v("Vin", "input voltage") } },
    .{ .group = "Electricity", .name = "Non-inverting op-amp gain", .text = "A = 1 + Rf/Rg", .vars = &.{ v("A", "gain"), v("Rf", "feedback resistor"), v("Rg", "resistor to ground") } },
    .{ .group = "Electricity", .name = "Inverting op-amp gain", .text = "A = −Rf/Rin", .vars = &.{ v("A", "gain"), v("Rf", "feedback resistor"), v("Rin", "input resistor") } },
    .{ .group = "Electricity", .name = "Op-amp bandwidth", .text = "B = G/A", .vars = &.{ v("B", "bandwidth"), v("G", "gain-bandwidth product"), v("A", "gain") } },
    .{ .group = "Electricity", .name = "Base resistor for a transistor switch", .text = "R = (Vin − 0.7)·β/(k·Ic)", .vars = &.{ v("R", "base resistor"), v("Vin", "drive voltage"), v("β", "transistor gain"), v("k", "overdrive (about 5)"), v("Ic", "load current") } },
    .{ .group = "Electricity", .name = "PWM average voltage", .text = "V = d/100·Vs", .vars = &.{ v("V", "average voltage"), v("d", "duty cycle (%)"), v("Vs", "supply voltage") } },
    .{ .group = "Electricity", .name = "Battery energy", .text = "E = V·Ah", .vars = &.{ v("E", "energy (Wh)"), v("V", "voltage"), v("Ah", "capacity (amp-hours)") } },
    .{ .group = "Electricity", .name = "Battery run time", .text = "t = Ah/I", .vars = &.{ v("t", "hours"), v("Ah", "capacity (amp-hours)"), v("I", "average current (amps)") } },
    .{ .group = "Electricity", .name = "Average current with sleeping", .text = "I = d/100·Ia + (1 − d/100)·Is", .vars = &.{ v("I", "average current"), v("d", "time awake (%)"), v("Ia", "awake current"), v("Is", "sleep current") } },

    // ---- Chemistry
    .{ .group = "Chemistry", .name = "Amount of substance", .text = "n = m/M", .vars = &.{ v("n", "amount (mol)"), v("m", "mass (g)"), v("M", "molar mass (g/mol)") } },
    .{ .group = "Chemistry", .name = "Concentration", .text = "c = n/V", .vars = &.{ v("c", "concentration (mol/L)"), v("n", "amount (mol)"), v("V", "volume (L)") } },
    .{ .group = "Chemistry", .name = "Dilution", .text = "c1·V1 = c2·V2", .vars = &.{ v("c1", "first concentration"), v("V1", "first volume"), v("c2", "second concentration"), v("V2", "second volume") } },
    .{ .group = "Chemistry", .name = "pH", .text = "pH = −log(H)", .vars = &.{ v("pH", "pH"), v("H", "hydrogen ion concentration (mol/L)") } },
    .{ .group = "Chemistry", .name = "Percent yield", .text = "y = actual/theory·100", .vars = &.{ v("y", "yield (%)"), v("actual", "actual yield"), v("theory", "theoretical yield") } },

    // ---- Statistics and probability
    .{ .group = "Statistics and probability", .name = "Combinations", .text = "N = n!/(k!·(n − k)!)", .vars = &.{ v("N", "number of ways"), v("n", "items"), v("k", "chosen") } },
    .{ .group = "Statistics and probability", .name = "Permutations", .text = "N = n!/(n − k)!", .vars = &.{ v("N", "number of orders"), v("n", "items"), v("k", "chosen") } },
    .{ .group = "Statistics and probability", .name = "Binomial probability", .text = "P = nCr(n, k)·p^k·(1 − p)^(n − k)", .vars = &.{ v("P", "probability"), v("n", "trials"), v("k", "successes"), v("p", "chance of success") } },
    .{ .group = "Statistics and probability", .name = "Standard score", .text = "z = (x − μ)/σ", .vars = &.{ v("z", "z-score"), v("x", "value"), v("μ", "mean"), v("σ", "standard deviation") } },
    .{ .group = "Statistics and probability", .name = "Standard error", .text = "SE = s/√n", .vars = &.{ v("SE", "standard error"), v("s", "standard deviation"), v("n", "sample size") } },
    .{ .group = "Statistics and probability", .name = "Expected value", .text = "E = p·w − (1 − p)·l", .vars = &.{ v("E", "expected gain"), v("p", "chance of winning"), v("w", "win"), v("l", "loss") } },
    .{ .group = "Statistics and probability", .name = "Poisson probability", .text = "P = e^(−λ)·λ^k/k!", .vars = &.{ v("P", "probability"), v("λ", "average rate"), v("k", "number of events") } },
    .{ .group = "Statistics and probability", .name = "Bayes' theorem", .text = "P = a·b/(a·b + c·(1 − b))", .vars = &.{ v("P", "probability given the evidence"), v("a", "chance of the evidence if true (sensitivity)"), v("b", "prior probability (base rate)"), v("c", "chance of the evidence if false") } },
    .{ .group = "Statistics and probability", .name = "Standard deviation of a binomial", .text = "σ = √(n·p·(1 − p))", .vars = &.{ v("σ", "standard deviation of the count"), v("n", "trials"), v("p", "probability of success") } },
    .{ .group = "Statistics and probability", .name = "Coefficient of variation", .text = "CV = s/m", .vars = &.{ v("CV", "coefficient of variation"), v("s", "standard deviation"), v("m", "mean") } },
    .{ .group = "Statistics and probability", .name = "Upper outlier fence", .text = "U = Q3 + 1.5·(Q3 − Q1)", .vars = &.{ v("U", "upper fence"), v("Q1", "first quartile"), v("Q3", "third quartile") } },
    .{ .group = "Statistics and probability", .name = "Lower outlier fence", .text = "L = Q1 − 1.5·(Q3 − Q1)", .vars = &.{ v("L", "lower fence"), v("Q1", "first quartile"), v("Q3", "third quartile") } },
    .{ .group = "Statistics and probability", .name = "Margin of error", .text = "E = z·s/√n", .vars = &.{ v("E", "margin of error"), v("z", "z value (1.96 for 95%)"), v("s", "standard deviation"), v("n", "sample size") } },
    .{ .group = "Statistics and probability", .name = "Sample size for a mean", .text = "n = (z·s/E)²", .vars = &.{ v("n", "sample size (round up)"), v("z", "z value (1.96 for 95%)"), v("s", "standard deviation"), v("E", "margin of error") } },
    .{ .group = "Statistics and probability", .name = "t statistic", .text = "t = (m − μ)/(s/√n)", .vars = &.{ v("t", "t statistic"), v("m", "sample mean"), v("μ", "claimed mean"), v("s", "sample standard deviation"), v("n", "sample size") } },
    .{ .group = "Statistics and probability", .name = "Correlation from covariance", .text = "r = cv/(sx·sy)", .vars = &.{ v("r", "correlation"), v("cv", "covariance"), v("sx", "standard deviation of x"), v("sy", "standard deviation of y") } },
    .{ .group = "Statistics and probability", .name = "Regression slope", .text = "b = r·sy/sx", .vars = &.{ v("b", "slope"), v("r", "correlation"), v("sx", "standard deviation of x"), v("sy", "standard deviation of y") } },
    .{ .group = "Statistics and probability", .name = "Regression intercept", .text = "a = my − b·mx", .vars = &.{ v("a", "intercept"), v("my", "mean of y"), v("b", "slope"), v("mx", "mean of x") } },
    .{ .group = "Statistics and probability", .name = "Normal density", .text = "y = e^(−(x − μ)²/(2σ²))/(σ·√(2π))", .vars = &.{ v("y", "density"), v("x", "value"), v("μ", "mean"), v("σ", "standard deviation") } },

    // ---- Money
    .{ .group = "Money", .name = "Simple interest", .text = "I = P·r·t/100", .vars = &.{ v("I", "interest"), v("P", "principal"), v("r", "rate (% a year)"), v("t", "years") } },
    .{ .group = "Money", .name = "Compound interest", .text = "A = P·(1 + r/100/n)^(n·t)", .vars = &.{ v("A", "final amount"), v("P", "principal"), v("r", "rate (% a year)"), c("n", "times a year", "12"), v("t", "years") } },
    .{ .group = "Money", .name = "Continuous compounding", .text = "A = P·e^(r/100·t)", .vars = &.{ v("A", "final amount"), v("P", "principal"), v("r", "rate (% a year)"), v("t", "years") } },
    .{ .group = "Money", .name = "Loan payment", .text = "M = P·(r/1200)/(1 − (1 + r/1200)^(−n))", .vars = &.{ v("M", "monthly payment"), v("P", "loan"), v("r", "rate (% a year)"), v("n", "months") } },
    .{ .group = "Money", .name = "Rule of 72", .text = "y = 72/r", .vars = &.{ v("y", "years to double"), v("r", "rate (% a year)") } },
    .{ .group = "Money", .name = "Discount", .text = "S = p·(1 − d/100)", .vars = &.{ v("S", "sale price"), v("p", "price"), v("d", "discount (%)") } },
    .{ .group = "Money", .name = "Price with tax", .text = "T = p·(1 + t/100)", .vars = &.{ v("T", "total"), v("p", "price"), v("t", "tax (%)") } },
    .{ .group = "Money", .name = "Tip", .text = "T = b·(1 + t/100)", .vars = &.{ v("T", "total"), v("b", "bill"), v("t", "tip (%)") } },
    .{ .group = "Money", .name = "Profit margin", .text = "m = (r − c)/r·100", .vars = &.{ v("m", "margin (%)"), v("r", "revenue"), v("c", "cost") } },
    .{ .group = "Money", .name = "Markup", .text = "m = (p − c)/c·100", .vars = &.{ v("m", "markup (%)"), v("p", "price"), v("c", "cost") } },
    .{ .group = "Money", .name = "Break-even point", .text = "u = F/(p − v)", .vars = &.{ v("u", "units to sell"), v("F", "fixed costs"), v("p", "price per unit"), v("v", "cost per unit") } },
    .{ .group = "Money", .name = "Unit price", .text = "u = p/q", .vars = &.{ v("u", "price per unit"), v("p", "price"), v("q", "quantity") } },

    // ---- Health
    .{ .group = "Health", .name = "Body mass index", .text = "B = m/h²", .vars = &.{ v("B", "BMI"), v("m", "mass (kg)"), v("h", "height (m)") } },
    .{ .group = "Health", .name = "Basal metabolic rate (men)", .text = "B = 10m + 6.25h − 5a + 5", .vars = &.{ v("B", "kcal a day"), v("m", "mass (kg)"), v("h", "height (cm)"), v("a", "age (years)") } },
    .{ .group = "Health", .name = "Basal metabolic rate (women)", .text = "B = 10m + 6.25h − 5a − 161", .vars = &.{ v("B", "kcal a day"), v("m", "mass (kg)"), v("h", "height (cm)"), v("a", "age (years)") } },
    .{ .group = "Health", .name = "Maximum heart rate", .text = "H = 220 − a", .vars = &.{ v("H", "beats a minute"), v("a", "age (years)") } },

    // ---- Everyday
    .{ .group = "Everyday", .name = "Fuel used", .text = "L = f·d/100", .vars = &.{ v("L", "litres used"), v("f", "litres per 100 km"), v("d", "distance (km)") } },
    .{ .group = "Everyday", .name = "Fuel cost", .text = "C = d/m·p", .vars = &.{ v("C", "cost"), v("d", "distance"), v("m", "distance per unit of fuel"), v("p", "price per unit of fuel") } },
    .{ .group = "Everyday", .name = "Travel time", .text = "t = d/v", .vars = &.{ v("t", "time"), v("d", "distance"), v("v", "speed") } },
    .{ .group = "Everyday", .name = "Scaling a recipe", .text = "q2 = q1·s2/s1", .vars = &.{ v("q2", "new amount"), v("q1", "amount in the recipe"), v("s2", "servings wanted"), v("s1", "servings in the recipe") } },
    .{ .group = "Everyday", .name = "Paint needed", .text = "L = A/c·k", .vars = &.{ v("L", "litres"), v("A", "area (m²)"), v("c", "coverage (m² per litre)"), c("k", "coats", "2") } },
    .{ .group = "Everyday", .name = "Screen size", .text = "d = √(w² + h²)", .vars = &.{ v("d", "diagonal"), v("w", "width"), v("h", "height") } },

    // ---- Investments and loans
    .{ .group = "Investments and loans", .name = "Present value of a future amount", .text = "P = F/(1 + r/100)^n", .vars = &.{ v("P", "present value"), v("F", "future value"), v("r", "rate per period (%)"), v("n", "periods") } },
    .{ .group = "Investments and loans", .name = "Future value of regular payments", .text = "F = M·((1 + r/100)^n − 1)/(r/100)", .vars = &.{ v("F", "future value"), v("M", "payment each period"), v("r", "rate per period (%)"), v("n", "periods") } },
    .{ .group = "Investments and loans", .name = "Present value of regular payments", .text = "P = M·(1 − (1 + r/100)^(−n))/(r/100)", .vars = &.{ v("P", "present value"), v("M", "payment each period"), v("r", "rate per period (%)"), v("n", "periods") } },
    .{ .group = "Investments and loans", .name = "Regular payment to reach a goal", .text = "M = F·(r/100)/((1 + r/100)^n − 1)", .vars = &.{ v("M", "payment each period"), v("F", "goal"), v("r", "rate per period (%)"), v("n", "periods") } },
    .{ .group = "Investments and loans", .name = "Balance of a loan after k payments", .text = "B = P·(1 + r/100)^k − M·((1 + r/100)^k − 1)/(r/100)", .vars = &.{ v("B", "balance owed"), v("P", "loan"), v("M", "payment each period"), v("r", "rate per period (%)"), v("k", "payments made") } },
    .{ .group = "Investments and loans", .name = "Interest in payment k of a loan", .text = "I = (P·(1 + r/100)^(k − 1) − M·((1 + r/100)^(k − 1) − 1)/(r/100))·r/100", .vars = &.{ v("I", "interest in that payment"), v("P", "loan"), v("M", "payment each period"), v("r", "rate per period (%)"), v("k", "number of the payment") } },
    .{ .group = "Investments and loans", .name = "Principal in payment k of a loan", .text = "Q = M − (P·(1 + r/100)^(k − 1) − M·((1 + r/100)^(k − 1) − 1)/(r/100))·r/100", .vars = &.{ v("Q", "principal in that payment"), v("M", "payment each period"), v("P", "loan"), v("r", "rate per period (%)"), v("k", "number of the payment") } },
    .{ .group = "Investments and loans", .name = "Effective annual rate", .text = "E = ((1 + r/100/m)^m − 1)·100", .vars = &.{ v("E", "effective rate (% a year)"), v("r", "nominal rate (% a year)"), v("m", "times compounded a year") } },
    .{ .group = "Investments and loans", .name = "Nominal rate from the effective rate", .text = "r = m·((1 + E/100)^(1/m) − 1)·100", .vars = &.{ v("r", "nominal rate (% a year)"), v("m", "times compounded a year"), v("E", "effective rate (% a year)") } },
    .{ .group = "Investments and loans", .name = "Real interest rate (Fisher)", .text = "r = ((1 + n/100)/(1 + f/100) − 1)·100", .vars = &.{ v("r", "real rate (%)"), v("n", "nominal rate (%)"), v("f", "inflation (%)") } },
    .{ .group = "Investments and loans", .name = "Return on investment", .text = "R = (G − C)/C·100", .vars = &.{ v("R", "return (%)"), v("G", "final value"), v("C", "cost") } },
    .{ .group = "Investments and loans", .name = "Compound annual growth rate", .text = "g = ((E/B)^(1/n) − 1)·100", .vars = &.{ v("g", "growth (% a year)"), v("E", "end value"), v("B", "beginning value"), v("n", "years") } },
    .{ .group = "Investments and loans", .name = "Time to double", .text = "t = ln(2)/ln(1 + r/100)", .vars = &.{ v("t", "periods to double"), v("r", "rate per period (%)") } },
    .{ .group = "Investments and loans", .name = "Straight-line depreciation", .text = "D = (C − S)/L", .vars = &.{ v("D", "depreciation each year"), v("C", "cost"), v("S", "salvage value"), v("L", "life (years)") } },
    .{ .group = "Investments and loans", .name = "Sum-of-years'-digits depreciation", .text = "D = (C − S)·(L − p + 1)·2/(L·(L + 1))", .vars = &.{ v("D", "depreciation in that year"), v("C", "cost"), v("S", "salvage value"), v("L", "life (years)"), v("p", "the year") } },
    .{ .group = "Investments and loans", .name = "Price elasticity of demand (midpoint)", .text = "E = ((q2 − q1)/(q1 + q2))/((p2 − p1)/(p1 + p2))", .vars = &.{ v("E", "elasticity"), v("q1", "quantity before"), v("q2", "quantity after"), v("p1", "price before"), v("p2", "price after") } },
    .{ .group = "Investments and loans", .name = "Zero-coupon bond yield", .text = "y = ((F/P)^(1/n) − 1)·100", .vars = &.{ v("y", "yield (% a year)"), v("F", "face value"), v("P", "price"), v("n", "years") } },
    .{ .group = "Investments and loans", .name = "Treasury bill price", .text = "P = F·(1 − d/100·t/360)", .vars = &.{ v("P", "price"), v("F", "face value"), v("d", "discount rate (%)"), v("t", "days to maturity") } },
    .{ .group = "Investments and loans", .name = "Treasury bill discount rate", .text = "d = (F − P)/F·360/t·100", .vars = &.{ v("d", "discount rate (%)"), v("F", "face value"), v("P", "price"), v("t", "days to maturity") } },
    .{ .group = "Investments and loans", .name = "Treasury bill yield", .text = "y = (F − P)/P·365/t·100", .vars = &.{ v("y", "yield (% a year)"), v("F", "face value"), v("P", "price"), v("t", "days to maturity") } },
    .{ .group = "Investments and loans", .name = "Accrued interest", .text = "A = F·c/100·t/360", .vars = &.{ v("A", "accrued interest"), v("F", "face value"), v("c", "coupon rate (% a year)"), v("t", "days (30/360)") } },
    .{ .group = "Investments and loans", .name = "Total interest paid on a loan", .text = "I = M·n − P", .vars = &.{ v("I", "total interest"), v("M", "payment"), v("n", "number of payments"), v("P", "amount borrowed") } },
    .{ .group = "Investments and loans", .name = "Number of payments to clear a loan", .text = "n = −ln(1 − P·(r/100)/M)/ln(1 + r/100)", .vars = &.{ v("n", "number of payments"), v("P", "balance"), v("r", "rate per period (%)"), v("M", "payment") } },
    .{ .group = "Investments and loans", .name = "First-period interest", .text = "I = P·r/100", .vars = &.{ v("I", "interest"), v("P", "balance"), v("r", "rate per period (%)") } },
    .{ .group = "Investments and loans", .name = "Value of a perpetuity", .text = "P = M/(r/100)", .vars = &.{ v("P", "present value"), v("M", "payment each period"), v("r", "rate per period (%)") } },
    .{ .group = "Investments and loans", .name = "Growing perpetuity (Gordon growth)", .text = "P = M/((r − g)/100)", .vars = &.{ v("P", "present value"), v("M", "next payment"), v("r", "discount rate (%)"), v("g", "growth rate (%)") } },
    .{ .group = "Investments and loans", .name = "Purchasing power after inflation", .text = "P = A/(1 + i/100)^t", .vars = &.{ v("P", "value in today's money"), v("A", "future amount"), v("i", "inflation (%)"), v("t", "years") } },
    .{ .group = "Investments and loans", .name = "Gain needed to recover a loss", .text = "G = (1/(1 − L/100) − 1)·100", .vars = &.{ v("G", "gain needed (%)"), v("L", "loss (%)") } },
    .{ .group = "Investments and loans", .name = "Years to reach a goal", .text = "t = ln(G/P)/ln(1 + r/100)", .vars = &.{ v("t", "years"), v("G", "goal"), v("P", "starting amount"), v("r", "yearly rate (%)") } },
    .{ .group = "Investments and loans", .name = "Net present value of one cash flow", .text = "N = F/(1 + r/100)^t − C", .vars = &.{ v("N", "net present value"), v("F", "future cash"), v("r", "discount rate (%)"), v("t", "years"), v("C", "cost today") } },
    .{ .group = "Investments and loans", .name = "Payback period", .text = "t = C/F", .vars = &.{ v("t", "years"), v("C", "cost"), v("F", "yearly inflow") } },
    .{ .group = "Investments and loans", .name = "Sharpe ratio", .text = "S = (R − f)/s", .vars = &.{ v("S", "Sharpe ratio"), v("R", "return"), v("f", "risk-free rate"), v("s", "standard deviation of return") } },
    .{ .group = "Investments and loans", .name = "Nest egg for a withdrawal rate", .text = "N = S/(w/100)", .vars = &.{ v("N", "nest egg"), v("S", "yearly spending"), v("w", "withdrawal rate (%)") } },
    .{ .group = "Investments and loans", .name = "Premium over spot", .text = "p = (P − S)/S·100", .vars = &.{ v("p", "premium (%)"), v("P", "price paid"), v("S", "spot (melt) value") } },
    .{ .group = "Investments and loans", .name = "Currency spread", .text = "s = (a − b)/a·100", .vars = &.{ v("s", "spread (%)"), v("a", "ask price"), v("b", "bid price") } },

    // ---- More geometry
    .{ .group = "Solid geometry", .name = "Volume of a regular tetrahedron", .text = "V = a³/(6√2)", .vars = &.{ v("V", "volume"), v("a", "edge") } },
    .{ .group = "Solid geometry", .name = "Surface of a regular tetrahedron", .text = "A = √3·a²", .vars = &.{ v("A", "surface area"), v("a", "edge") } },
    .{ .group = "Solid geometry", .name = "Height of a regular tetrahedron", .text = "h = a·√(2/3)", .vars = &.{ v("h", "height"), v("a", "edge") } },
    .{ .group = "Solid geometry", .name = "Volume of a square pyramid", .text = "V = b²·h/3", .vars = &.{ v("V", "volume"), v("b", "base side"), v("h", "height") } },
    .{ .group = "Solid geometry", .name = "Slant height of a square pyramid", .text = "s = √(h² + b²/4)", .vars = &.{ v("s", "slant height"), v("h", "height"), v("b", "base side") } },
    .{ .group = "Solid geometry", .name = "Surface of a square pyramid", .text = "A = b² + 2b·√(h² + b²/4)", .vars = &.{ v("A", "surface area"), v("b", "base side"), v("h", "height") } },
    .{ .group = "Solid geometry", .name = "Volume of a triangular prism", .text = "V = b·h·l/2", .vars = &.{ v("V", "volume"), v("b", "triangle base"), v("h", "triangle height"), v("l", "length") } },
    .{ .group = "Solid geometry", .name = "Side area of a cone", .text = "A = π·r·s", .vars = &.{ v("A", "side area"), v("r", "radius"), v("s", "slant height") } },
    .{ .group = "Solid geometry", .name = "Side area of a cylinder", .text = "A = 2π·r·h", .vars = &.{ v("A", "side area"), v("r", "radius"), v("h", "height") } },

    // ---- More plane geometry
    .{ .group = "Plane geometry", .name = "Perimeter of a square", .text = "P = 4s", .vars = &.{ v("P", "perimeter"), v("s", "side") } },
    .{ .group = "Plane geometry", .name = "Perimeter of a triangle", .text = "P = a + b + c", .vars = &.{ v("P", "perimeter"), v("a", "side"), v("b", "side"), v("c", "side") } },
    .{ .group = "Plane geometry", .name = "Perimeter of a parallelogram", .text = "P = 2(a + b)", .vars = &.{ v("P", "perimeter"), v("a", "side"), v("b", "side") } },
    .{ .group = "Plane geometry", .name = "Perimeter of a trapezoid", .text = "P = a + b + c + d", .vars = &.{ v("P", "perimeter"), v("a", "side"), v("b", "side"), v("c", "side"), v("d", "side") } },
    .{ .group = "Plane geometry", .name = "Perimeter of a rhombus", .text = "P = 4s", .vars = &.{ v("P", "perimeter"), v("s", "side") } },

    // ---- Electronics and computers
    .{ .group = "Electronics and computers", .name = "Wire diameter from the AWG gauge", .text = "d = 0.127·92^((36 − n)/39)", .vars = &.{ v("d", "diameter (mm)"), v("n", "AWG gauge") } },
    .{ .group = "Electronics and computers", .name = "RAID 0 capacity", .text = "C = n·s", .vars = &.{ v("C", "usable capacity"), v("n", "disks"), v("s", "size of one disk") } },
    .{ .group = "Electronics and computers", .name = "RAID 5 capacity", .text = "C = (n − 1)·s", .vars = &.{ v("C", "usable capacity"), v("n", "disks"), v("s", "size of one disk") } },
    .{ .group = "Electronics and computers", .name = "RAID 6 capacity", .text = "C = (n − 2)·s", .vars = &.{ v("C", "usable capacity"), v("n", "disks"), v("s", "size of one disk") } },
    .{ .group = "Electronics and computers", .name = "RAID 10 capacity", .text = "C = n·s/2", .vars = &.{ v("C", "usable capacity"), v("n", "disks"), v("s", "size of one disk") } },
    .{ .group = "Electronics and computers", .name = "Memory latency in nanoseconds", .text = "L = 2000·c/f", .vars = &.{ v("L", "latency (ns)"), v("c", "CAS latency (cycles)"), v("f", "speed (MT/s)") } },
    .{ .group = "Electronics and computers", .name = "Hyperfocal distance", .text = "H = f²/(N·c) + f", .vars = &.{ v("H", "hyperfocal distance (mm)"), v("f", "focal length (mm)"), v("N", "f-number"), v("c", "circle of confusion (mm)") } },
    .{ .group = "Electronics and computers", .name = "Depth of field", .text = "D = 2·N·c·f²·s²/(f^4 − N²·c²·s²)", .vars = &.{ v("D", "total depth of field (mm)"), v("N", "f-number"), v("c", "circle of confusion (mm)"), v("f", "focal length (mm)"), v("s", "distance to the subject (mm)") } },
    // ---- Computer science
    .{ .group = "Number systems and bits", .name = "Values in n bits", .text = "V = 2^n", .vars = &.{ v("V", "number of values"), v("n", "bits") } },
    .{ .group = "Number systems and bits", .name = "Largest unsigned value in n bits", .text = "M = 2^n − 1", .vars = &.{ v("M", "largest value"), v("n", "bits") } },
    .{ .group = "Number systems and bits", .name = "Smallest signed value (two's complement)", .text = "m = −2^(n − 1)", .vars = &.{ v("m", "smallest value"), v("n", "bits") } },
    .{ .group = "Number systems and bits", .name = "Largest signed value (two's complement)", .text = "M = 2^(n − 1) − 1", .vars = &.{ v("M", "largest value"), v("n", "bits") } },
    .{ .group = "Number systems and bits", .name = "Bits needed for N values (round up)", .text = "n = log2(N)", .vars = &.{ v("n", "bits, rounded up"), v("N", "number of values") } },
    .{ .group = "Number systems and bits", .name = "Hex digits in n bits", .text = "h = n/4", .vars = &.{ v("h", "hex digits"), v("n", "bits") } },
    .{ .group = "Number systems and bits", .name = "Decimal digits in n bits", .text = "D = n·log10(2)", .vars = &.{ v("D", "decimal digits"), v("n", "bits") } },
    .{ .group = "Number systems and bits", .name = "Remainder (mod)", .text = "r = mod(a, n)", .vars = &.{ v("r", "remainder"), v("a", "number"), v("n", "divisor") } },
    .{ .group = "Number systems and bits", .name = "Usable hosts in a subnet", .text = "H = 2^h − 2", .vars = &.{ v("H", "usable hosts"), v("h", "host bits") } },
    .{ .group = "Number systems and bits", .name = "Bytes in an image", .text = "B = w·h·b", .vars = &.{ v("B", "bytes"), v("w", "width (pixels)"), v("h", "height (pixels)"), v("b", "bytes per pixel") } },
    .{ .group = "Number systems and bits", .name = "Bytes in an array", .text = "B = n·s", .vars = &.{ v("B", "bytes"), v("n", "items"), v("s", "bytes per item") } },
    .{ .group = "Number systems and bits", .name = "Download time", .text = "t = 8·s/r", .vars = &.{ v("t", "time (s)"), v("s", "size (bytes)"), v("r", "rate (bits per second)") } },
    .{ .group = "Number systems and bits", .name = "Space saved by compression", .text = "S = 1 − c/o", .vars = &.{ v("S", "fraction saved"), v("c", "compressed size"), v("o", "original size") } },
    .{ .group = "Number systems and bits", .name = "Days since 1 Jan 1970 from a Unix timestamp", .text = "d = t/86400", .vars = &.{ v("d", "days"), v("t", "seconds") } },
    .{ .group = "Number systems and bits", .name = "Single-precision float value", .text = "v = 2^(p − 127)·(1 + f)", .vars = &.{ v("v", "value"), v("p", "exponent field"), v("f", "fraction (0 to 1)") } },
    .{ .group = "Algorithms and data", .name = "Binary search steps (round up)", .text = "s = log2(n)", .vars = &.{ v("s", "steps"), v("n", "items") } },
    .{ .group = "Algorithms and data", .name = "Merge sort steps (about)", .text = "T = n·log2(n)", .vars = &.{ v("T", "steps"), v("n", "items") } },
    .{ .group = "Algorithms and data", .name = "Bubble sort comparisons", .text = "C = n·(n − 1)/2", .vars = &.{ v("C", "comparisons"), v("n", "items") } },
    .{ .group = "Algorithms and data", .name = "Fewest comparisons to sort n items (round up)", .text = "C = log2(n!)", .vars = &.{ v("C", "comparisons"), v("n", "items") } },
    .{ .group = "Algorithms and data", .name = "Tower of Hanoi moves", .text = "T = 2^n − 1", .vars = &.{ v("T", "moves"), v("n", "discs") } },
    .{ .group = "Algorithms and data", .name = "Nodes in a full binary tree of height h", .text = "N = 2^(h + 1) − 1", .vars = &.{ v("N", "nodes"), v("h", "height") } },
    .{ .group = "Algorithms and data", .name = "Height of a balanced binary tree (round down)", .text = "h = log2(n)", .vars = &.{ v("h", "height"), v("n", "nodes") } },
    .{ .group = "Algorithms and data", .name = "Edges in a tree", .text = "E = n − 1", .vars = &.{ v("E", "edges"), v("n", "nodes") } },
    .{ .group = "Algorithms and data", .name = "Edges in a complete graph", .text = "E = n·(n − 1)/2", .vars = &.{ v("E", "edges"), v("n", "nodes") } },
    .{ .group = "Algorithms and data", .name = "Edges from the degrees (handshake)", .text = "E = n·d/2", .vars = &.{ v("E", "edges"), v("n", "nodes"), v("d", "degree of each node") } },
    .{ .group = "Algorithms and data", .name = "Catalan number (binary tree shapes)", .text = "C = nCr(2n, n)/(n + 1)", .vars = &.{ v("C", "shapes"), v("n", "nodes") } },
    .{ .group = "Algorithms and data", .name = "Routes across a grid, right and down", .text = "P = nCr(m + n, n)", .vars = &.{ v("P", "routes"), v("m", "steps right"), v("n", "steps down") } },
    .{ .group = "Algorithms and data", .name = "Subsets of n items", .text = "S = 2^n", .vars = &.{ v("S", "subsets"), v("n", "items") } },
    .{ .group = "Algorithms and data", .name = "Hash table load factor", .text = "L = n/m", .vars = &.{ v("L", "load factor"), v("n", "items"), v("m", "buckets") } },
    .{ .group = "Algorithms and data", .name = "Chance of a hash collision (birthday)", .text = "p = 1 − exp(−k·(k − 1)/(2·N))", .vars = &.{ v("p", "probability"), v("k", "items"), v("N", "possible values") } },
    .{ .group = "Algorithms and data", .name = "Items before a collision is likely", .text = "k = √N", .vars = &.{ v("k", "items"), v("N", "possible values") } },
    .{ .group = "Algorithms and data", .name = "Expected tries until success", .text = "T = 1/p", .vars = &.{ v("T", "expected tries"), v("p", "chance each try") } },
    .{ .group = "Algorithms and data", .name = "Linear search, average checks", .text = "A = (n + 1)/2", .vars = &.{ v("A", "average checks"), v("n", "items") } },
    .{ .group = "Graphics and information", .name = "Linear interpolation (lerp)", .text = "v = a + (b − a)·t", .vars = &.{ v("v", "value"), v("a", "start"), v("b", "end"), v("t", "fraction (0 to 1)") } },
    .{ .group = "Graphics and information", .name = "Smoothstep easing", .text = "s = 3t² − 2t³", .vars = &.{ v("s", "eased value"), v("t", "fraction (0 to 1)") } },
    .{ .group = "Graphics and information", .name = "Quadratic Bezier curve", .text = "B = (1 − t)²·a + 2·(1 − t)·t·b + t²·c", .vars = &.{ v("B", "value"), v("a", "first point"), v("b", "control point"), v("c", "last point"), v("t", "fraction (0 to 1)") } },
    .{ .group = "Graphics and information", .name = "Dot product of two 2D vectors", .text = "d = p·r + q·s", .vars = &.{ v("d", "dot product"), v("p", "x of the first"), v("q", "y of the first"), v("r", "x of the second"), v("s", "y of the second") } },
    .{ .group = "Graphics and information", .name = "Length of a 2D vector", .text = "L = √(x² + y²)", .vars = &.{ v("L", "length"), v("x", "x part"), v("y", "y part") } },
    .{ .group = "Graphics and information", .name = "Rotate a point: new x", .text = "X = x·cos(θ) − y·sin(θ)", .vars = &.{ v("X", "new x"), v("x", "x"), v("y", "y"), v("θ", "angle of rotation") } },
    .{ .group = "Graphics and information", .name = "Rotate a point: new y", .text = "Y = x·sin(θ) + y·cos(θ)", .vars = &.{ v("Y", "new y"), v("x", "x"), v("y", "y"), v("θ", "angle of rotation") } },
    .{ .group = "Graphics and information", .name = "Byte to a 0 to 1 value", .text = "n = b/255", .vars = &.{ v("n", "value from 0 to 1"), v("b", "byte (0 to 255)") } },
    .{ .group = "Graphics and information", .name = "sRGB to linear light", .text = "c = ((s + 0.055)/1.055)^2.4", .vars = &.{ v("c", "linear value"), v("s", "sRGB value (0 to 1)") } },
    .{ .group = "Graphics and information", .name = "Information in an outcome (bits)", .text = "I = −log2(p)", .vars = &.{ v("I", "bits"), v("p", "probability") } },
    .{ .group = "Graphics and information", .name = "Entropy of a two-outcome source (bits)", .text = "H = −p·log2(p) − (1 − p)·log2(1 − p)", .vars = &.{ v("H", "bits"), v("p", "probability of one outcome") } },
    .{ .group = "Algebra", .name = "Difference of squares", .text = "D = (a − b)·(a + b)", .vars = &.{ v("D", "a² − b²"), v("a", "first number"), v("b", "second number") } },
    .{ .group = "Algebra", .name = "Square of a sum", .text = "S = (a + b)²", .vars = &.{ v("S", "square of the sum"), v("a", "first number"), v("b", "second number") } },
    .{ .group = "Algebra", .name = "Square of a difference", .text = "S = (a − b)²", .vars = &.{ v("S", "square of the difference"), v("a", "first number"), v("b", "second number") } },
    .{ .group = "Algebra", .name = "Discriminant of a quadratic", .text = "D = b² − 4·a·c", .vars = &.{ v("D", "discriminant"), v("a", "coefficient of x²"), v("b", "coefficient of x"), v("c", "constant") } },
    .{ .group = "Algebra", .name = "Vertex of a parabola (x)", .text = "x = −b/(2·a)", .vars = &.{ v("x", "x of the vertex"), v("a", "coefficient of x²"), v("b", "coefficient of x") } },
    .{ .group = "Algebra", .name = "Sum of the roots of a quadratic", .text = "S = −b/a", .vars = &.{ v("S", "sum of the roots"), v("a", "coefficient of x²"), v("b", "coefficient of x") } },
    .{ .group = "Algebra", .name = "Product of the roots of a quadratic", .text = "P = c/a", .vars = &.{ v("P", "product of the roots"), v("a", "coefficient of x²"), v("c", "constant") } },
    .{ .group = "Algebra", .name = "Change of logarithm base", .text = "L = ln(x)/ln(b)", .vars = &.{ v("L", "log to the base b"), v("x", "number"), v("b", "base") } },
    .{ .group = "Algebra", .name = "Product of gcd and lcm", .text = "P = a·b", .vars = &.{ v("P", "gcd × lcm"), v("a", "first number"), v("b", "second number") } },
    .{ .group = "Algebra", .name = "Mean of values", .text = "m = S/n", .vars = &.{ v("m", "mean"), v("S", "sum of the values"), v("n", "how many values") } },
    .{ .group = "Algebra", .name = "Weighted mean of two values", .text = "m = (w1·x1 + w2·x2)/(w1 + w2)", .vars = &.{ v("m", "weighted mean"), v("w1", "first weight"), v("x1", "first value"), v("w2", "second weight"), v("x2", "second value") } },
    .{ .group = "Algebra", .name = "Geometric mean of two numbers", .text = "g = √(a·b)", .vars = &.{ v("g", "geometric mean (mean proportional)"), v("a", "first number"), v("b", "second number") } },
    .{ .group = "Algebra", .name = "Percent of a total", .text = "p = part/total·100", .vars = &.{ v("p", "percent"), v("part", "the part"), v("total", "the whole") } },
    .{ .group = "Calculus", .name = "Derivative of a power", .text = "d = n·x^(n − 1)", .vars = &.{ v("d", "slope of x^n"), v("n", "power"), v("x", "x") } },
    .{ .group = "Calculus", .name = "Integral of a power", .text = "I = x^(n + 1)/(n + 1)", .vars = &.{ v("I", "integral of x^n (no constant)"), v("n", "power (not −1)"), v("x", "x") } },
    .{ .group = "Calculus", .name = "Area under a power from 0 to x", .text = "A = x^(n + 1)/(n + 1)", .vars = &.{ v("A", "area under x^n from 0 to x"), v("n", "power"), v("x", "upper limit") } },
    .{ .group = "Calculus", .name = "Taylor series of e^x (first terms)", .text = "y = 1 + x + x²/2 + x³/6", .vars = &.{ v("y", "approximation of e^x"), v("x", "x near 0") } },
    .{ .group = "Calculus", .name = "Taylor series of sin (first terms)", .text = "y = x − x³/6 + x^5/120", .vars = &.{ v("y", "approximation of sin(x)"), v("x", "x in radians, near 0") } },
    .{ .group = "Calculus", .name = "Newton's method step", .text = "X = x − f/d", .vars = &.{ v("X", "next guess"), v("x", "this guess"), v("f", "function value at x"), v("d", "slope at x") } },
    .{ .group = "Calculus", .name = "Tangent line value", .text = "y = f + d·(x − a)", .vars = &.{ v("y", "tangent line value"), v("f", "function value at a"), v("d", "slope at a"), v("x", "x"), v("a", "point of tangency") } },
    .{ .group = "Calculus", .name = "Average rate of change", .text = "r = (f2 − f1)/(x2 − x1)", .vars = &.{ v("r", "average slope"), v("f1", "value at x1"), v("f2", "value at x2"), v("x1", "first x"), v("x2", "second x") } },
    .{ .group = "Trigonometry", .name = "Cosine from sine (Pythagorean identity)", .text = "c = √(1 − s²)", .vars = &.{ v("c", "cosine (positive)"), v("s", "sine") } },
    .{ .group = "Trigonometry", .name = "Tangent from sine and cosine", .text = "t = s/c", .vars = &.{ v("t", "tangent"), v("s", "sine"), v("c", "cosine") } },
    .{ .group = "Trigonometry", .name = "Double angle: sine", .text = "y = 2·sin(a)·cos(a)", .vars = &.{ v("y", "sin(2a)"), v("a", "angle") } },
    .{ .group = "Trigonometry", .name = "Double angle: cosine", .text = "y = cos(a)² − sin(a)²", .vars = &.{ v("y", "cos(2a)"), v("a", "angle") } },
    .{ .group = "Trigonometry", .name = "Radians to degrees", .text = "d = r·180/π", .vars = &.{ v("d", "degrees"), v("r", "radians") } },
    .{ .group = "Trigonometry", .name = "Opposite side from the hypotenuse", .text = "o = h·sin(a)", .vars = &.{ v("o", "opposite side"), v("h", "hypotenuse"), v("a", "angle") } },
    .{ .group = "Trigonometry", .name = "Adjacent side from the hypotenuse", .text = "j = h·cos(a)", .vars = &.{ v("j", "adjacent side"), v("h", "hypotenuse"), v("a", "angle") } },
    .{ .group = "Trigonometry", .name = "Slope angle from rise and run", .text = "a = atan(r/d)", .vars = &.{ v("a", "angle"), v("r", "rise"), v("d", "run") } },
    .{ .group = "Linear algebra", .name = "Determinant of a 2 × 2 matrix", .text = "D = a·d − b·c", .vars = &.{ v("D", "determinant"), v("a", "top left"), v("b", "top right"), v("c", "bottom left"), v("d", "bottom right") } },
    .{ .group = "Linear algebra", .name = "Trace of a 2 × 2 matrix", .text = "T = a + d", .vars = &.{ v("T", "trace"), v("a", "top left"), v("d", "bottom right") } },
    .{ .group = "Linear algebra", .name = "Larger eigenvalue of a 2 × 2 matrix", .text = "L = (T + √(T² − 4·D))/2", .vars = &.{ v("L", "larger eigenvalue"), v("T", "trace"), v("D", "determinant") } },
    .{ .group = "Linear algebra", .name = "Smaller eigenvalue of a 2 × 2 matrix", .text = "L = (T − √(T² − 4·D))/2", .vars = &.{ v("L", "smaller eigenvalue"), v("T", "trace"), v("D", "determinant") } },
    .{ .group = "Linear algebra", .name = "Dot product of two 3D vectors", .text = "d = a1·b1 + a2·b2 + a3·b3", .vars = &.{ v("d", "dot product"), v("a1", "x of the first"), v("a2", "y of the first"), v("a3", "z of the first"), v("b1", "x of the second"), v("b2", "y of the second"), v("b3", "z of the second") } },
    .{ .group = "Linear algebra", .name = "Length of a 3D vector", .text = "L = √(x² + y² + z²)", .vars = &.{ v("L", "length"), v("x", "x part"), v("y", "y part"), v("z", "z part") } },
    .{ .group = "Linear algebra", .name = "Angle between two vectors", .text = "a = acos(d/(p·q))", .vars = &.{ v("a", "angle"), v("d", "dot product"), v("p", "length of the first"), v("q", "length of the second") } },
    .{ .group = "Linear algebra", .name = "Area of the parallelogram of two 2D vectors", .text = "A = x1·y2 − y1·x2", .vars = &.{ v("A", "signed area"), v("x1", "x of the first"), v("y1", "y of the first"), v("x2", "x of the second"), v("y2", "y of the second") } },
    .{ .group = "Number systems and bits", .name = "Two's complement of a number", .text = "t = 2^n − x", .vars = &.{ v("t", "stored value"), v("n", "bits"), v("x", "size of the negative number") } },
    .{ .group = "Number systems and bits", .name = "Shift left (multiply by 2^k)", .text = "y = x·2^k", .vars = &.{ v("y", "result"), v("x", "number"), v("k", "places shifted") } },
    .{ .group = "Number systems and bits", .name = "Shift right (divide by 2^k, round down)", .text = "y = x/2^k", .vars = &.{ v("y", "result"), v("x", "number"), v("k", "places shifted") } },
    .{ .group = "Number systems and bits", .name = "Base64 length", .text = "L = 4·n/3", .vars = &.{ v("L", "characters (round up to a multiple of 4)"), v("n", "bytes") } },
    .{ .group = "Number systems and bits", .name = "Colours from bits per pixel", .text = "N = 2^b", .vars = &.{ v("N", "colours"), v("b", "bits per pixel") } },
    .{ .group = "Number systems and bits", .name = "Place value of a digit", .text = "V = d·b^p", .vars = &.{ v("V", "value"), v("d", "digit"), v("b", "base"), v("p", "position from the right (starting at 0)") } },
    .{ .group = "Number systems and bits", .name = "Quotient and remainder", .text = "a = n·q + r", .vars = &.{ v("a", "number"), v("n", "divisor"), v("q", "quotient"), v("r", "remainder") } },
    .{ .group = "Number systems and bits", .name = "Addresses in a prefix", .text = "N = 2^(32 − p)", .vars = &.{ v("N", "addresses"), v("p", "prefix length") } },
    .{ .group = "Number systems and bits", .name = "Subnets from borrowed bits", .text = "N = 2^s", .vars = &.{ v("N", "subnets"), v("s", "bits borrowed") } },
    .{ .group = "Number systems and bits", .name = "Host bits for H hosts (round up)", .text = "h = log2(H + 2)", .vars = &.{ v("h", "host bits"), v("H", "hosts wanted") } },
    .{ .group = "Number systems and bits", .name = "Subnets in a larger block", .text = "N = 2^(p2 − p1)", .vars = &.{ v("N", "subnets"), v("p1", "prefix of the big block"), v("p2", "prefix of the small blocks") } },
    .{ .group = "Number systems and bits", .name = "UTF-16 code point from a surrogate pair", .text = "c = 65536 + (h − 55296)·1024 + (l − 56320)", .vars = &.{ v("c", "code point"), v("h", "high surrogate"), v("l", "low surrogate") } },
    .{ .group = "Number systems and bits", .name = "Double-precision float value", .text = "v = 2^(p − 1023)·(1 + f)", .vars = &.{ v("v", "value"), v("p", "exponent field"), v("f", "fraction (0 to 1)") } },
    .{ .group = "Number systems and bits", .name = "Hamming code length", .text = "n = 2^r − 1", .vars = &.{ v("n", "total bits"), v("r", "parity bits") } },
    .{ .group = "Number systems and bits", .name = "Hamming data bits", .text = "k = 2^r − r − 1", .vars = &.{ v("k", "data bits"), v("r", "parity bits") } },
    .{ .group = "Algorithms and data", .name = "Address of an array element", .text = "a = b + i·s", .vars = &.{ v("a", "address"), v("b", "address of the first element"), v("i", "index (from 0)"), v("s", "size of an element") } },
    .{ .group = "Algorithms and data", .name = "Cache sets", .text = "S = c/(l·w)", .vars = &.{ v("S", "sets"), v("c", "cache size"), v("l", "line size"), v("w", "ways") } },
    .{ .group = "Algorithms and data", .name = "Average memory access time", .text = "T = h + m·p", .vars = &.{ v("T", "average time"), v("h", "hit time"), v("m", "miss rate (0 to 1)"), v("p", "miss penalty") } },
    .{ .group = "Algorithms and data", .name = "Pages needed (round up)", .text = "N = s/p", .vars = &.{ v("N", "pages"), v("s", "size"), v("p", "page size") } },
    .{ .group = "Algorithms and data", .name = "Bloom filter false positive rate", .text = "p = (1 − exp(−k·n/m))^k", .vars = &.{ v("p", "false positive rate"), v("k", "hash functions"), v("n", "items"), v("m", "bits") } },
    .{ .group = "Algorithms and data", .name = "Best number of Bloom filter hashes", .text = "k = m/n·ln(2)", .vars = &.{ v("k", "hash functions"), v("m", "bits"), v("n", "items") } },
    .{ .group = "Algorithms and data", .name = "Bloom filter bits for a false positive rate", .text = "m = −n·ln(p)/ln(2)²", .vars = &.{ v("m", "bits"), v("n", "items"), v("p", "false positive rate") } },
    .{ .group = "Algorithms and data", .name = "Fullest bucket with random choice (about)", .text = "M = ln(n)/ln(ln(n))", .vars = &.{ v("M", "most items in one bucket"), v("n", "items and buckets") } },
    .{ .group = "Algorithms and data", .name = "Fullest bucket with two choices (about)", .text = "M = ln(ln(n))/ln(2)", .vars = &.{ v("M", "most items in one bucket"), v("n", "items and buckets") } },
    .{ .group = "Algorithms and data", .name = "Strings of a given length", .text = "N = c^l", .vars = &.{ v("N", "strings"), v("c", "characters to choose from"), v("l", "length") } },
    .{ .group = "Algorithms and data", .name = "Password entropy (bits)", .text = "H = l·log2(c)", .vars = &.{ v("H", "bits"), v("l", "length"), v("c", "characters to choose from") } },
    .{ .group = "Algorithms and data", .name = "Brute-force time (average)", .text = "t = 2^(b − 1)/r", .vars = &.{ v("t", "seconds"), v("b", "bits of the key or hash"), v("r", "guesses per second") } },
    .{ .group = "Algorithms and data", .name = "Master theorem: leaf work", .text = "W = n^(log2(a)/log2(b))", .vars = &.{ v("W", "work at the leaves"), v("n", "size"), v("a", "subproblems"), v("b", "shrink factor") } },
    .{ .group = "Algorithms and data", .name = "Recursion depth of halving", .text = "d = log2(n)", .vars = &.{ v("d", "depth (round up)"), v("n", "size") } },
    .{ .group = "Cryptography", .name = "RSA encryption", .text = "c = mod(m^k, n)", .vars = &.{ v("c", "ciphertext"), v("m", "message"), v("k", "public exponent (e)"), v("n", "modulus") } },
    .{ .group = "Cryptography", .name = "RSA decryption", .text = "m = mod(c^d, n)", .vars = &.{ v("m", "message"), v("c", "ciphertext"), v("d", "private exponent"), v("n", "modulus") } },
    .{ .group = "Cryptography", .name = "RSA modulus", .text = "n = p·q", .vars = &.{ v("n", "modulus"), v("p", "first prime"), v("q", "second prime") } },
    .{ .group = "Cryptography", .name = "Euler totient of a product of two primes", .text = "t = (p − 1)·(q − 1)", .vars = &.{ v("t", "totient"), v("p", "first prime"), v("q", "second prime") } },
    .{ .group = "Cryptography", .name = "Diffie-Hellman public value", .text = "A = mod(g^a, p)", .vars = &.{ v("A", "public value"), v("g", "generator"), v("a", "secret"), v("p", "prime") } },
    .{ .group = "Cryptography", .name = "Diffie-Hellman shared secret", .text = "K = mod(B^a, p)", .vars = &.{ v("K", "shared secret"), v("B", "other side's public value"), v("a", "own secret"), v("p", "prime") } },
    .{ .group = "Cryptography", .name = "One-time pad (XOR)", .text = "c = m xor k", .vars = &.{ v("c", "ciphertext"), v("m", "message"), v("k", "key") } },
    .{ .group = "Networking", .name = "Serialisation delay", .text = "d = 8·s/r", .vars = &.{ v("d", "time (s)"), v("s", "packet size (bytes)"), v("r", "rate (bits per second)") } },
    .{ .group = "Networking", .name = "Propagation delay", .text = "d = L/v", .vars = &.{ v("d", "time (s)"), v("L", "distance (m)"), v("v", "signal speed (m/s, about 2e8 in fibre)") } },
    .{ .group = "Networking", .name = "Bandwidth-delay product", .text = "B = r·t", .vars = &.{ v("B", "bits in flight"), v("r", "rate (bits per second)"), v("t", "round-trip time (s)") } },
    .{ .group = "Networking", .name = "TCP throughput limit from the window", .text = "R = 8·w/t", .vars = &.{ v("R", "bits per second"), v("w", "window (bytes)"), v("t", "round-trip time (s)") } },
    .{ .group = "Networking", .name = "TCP throughput under loss (Mathis)", .text = "R = 8·m/t·1.22/√(p)", .vars = &.{ v("R", "bits per second"), v("m", "segment size (bytes)"), v("t", "round-trip time (s)"), v("p", "loss rate (0 to 1)") } },
    .{ .group = "Networking", .name = "Expected sends with loss", .text = "N = 1/(1 − p)", .vars = &.{ v("N", "sends per packet"), v("p", "loss rate (0 to 1)") } },
    .{ .group = "Networking", .name = "Chance a path delivers", .text = "D = (1 − p)^h", .vars = &.{ v("D", "delivery chance"), v("p", "loss per hop (0 to 1)"), v("h", "hops") } },
    .{ .group = "Networking", .name = "Queue utilisation", .text = "u = a/s", .vars = &.{ v("u", "utilisation"), v("a", "arrival rate"), v("s", "service rate") } },
    .{ .group = "Networking", .name = "Queue: mean time in system (M/M/1)", .text = "W = 1/(s − a)", .vars = &.{ v("W", "time in system"), v("s", "service rate"), v("a", "arrival rate") } },
    .{ .group = "Networking", .name = "Queue: mean number in system (M/M/1)", .text = "N = u/(1 − u)", .vars = &.{ v("N", "packets in the system"), v("u", "utilisation (0 to 1)") } },
    .{ .group = "Networking", .name = "Little's law", .text = "N = a·W", .vars = &.{ v("N", "number in the system"), v("a", "arrival rate"), v("W", "time in the system") } },
    .{ .group = "Networking", .name = "Shannon channel capacity", .text = "C = B·log2(1 + r)", .vars = &.{ v("C", "bits per second"), v("B", "bandwidth (Hz)"), v("r", "signal-to-noise ratio (not dB)") } },
    .{ .group = "Networking", .name = "Nyquist rate", .text = "C = 2·B·log2(L)", .vars = &.{ v("C", "bits per second"), v("B", "bandwidth (Hz)"), v("L", "signal levels") } },
    .{ .group = "Networking", .name = "Decibels from a power ratio", .text = "D = 10·log10(r)", .vars = &.{ v("D", "decibels"), v("r", "power ratio") } },
    .{ .group = "Networking", .name = "Power ratio from decibels", .text = "r = 10^(D/10)", .vars = &.{ v("r", "power ratio"), v("D", "decibels") } },
    .{ .group = "Networking", .name = "Power in dBm", .text = "D = 10·log10(P)", .vars = &.{ v("D", "dBm"), v("P", "power (milliwatts)") } },
    .{ .group = "Networking", .name = "Free-space path loss (dB)", .text = "L = 20·log10(d) + 20·log10(f) + 32.44", .vars = &.{ v("L", "loss (dB)"), v("d", "distance (km)"), v("f", "frequency (MHz)") } },
    .{ .group = "Networking", .name = "Link budget", .text = "R = T + g − L", .vars = &.{ v("R", "received power (dBm)"), v("T", "transmit power (dBm)"), v("g", "total antenna gain (dB)"), v("L", "total loss (dB)") } },
    .{ .group = "Networking", .name = "Ethernet efficiency", .text = "E = p/(p + 38)·100", .vars = &.{ v("E", "efficiency (%)"), v("p", "payload (bytes)") } },
    .{ .group = "Networking", .name = "Packets per second at line rate", .text = "N = r/(8·(p + 38))", .vars = &.{ v("N", "packets per second"), v("r", "line rate (bits per second)"), v("p", "payload (bytes)") } },
    .{ .group = "Networking", .name = "Downtime per year at an availability", .text = "D = 525600·(1 − a/100)", .vars = &.{ v("D", "minutes"), v("a", "availability (%)") } },
    .{ .group = "Networking", .name = "Availability in series", .text = "A = a1·a2", .vars = &.{ v("A", "availability (0 to 1)"), v("a1", "first part (0 to 1)"), v("a2", "second part (0 to 1)") } },
    .{ .group = "Networking", .name = "Availability in parallel", .text = "A = 1 − (1 − a1)·(1 − a2)", .vars = &.{ v("A", "availability (0 to 1)"), v("a1", "first part (0 to 1)"), v("a2", "second part (0 to 1)") } },
    .{ .group = "Networking", .name = "Availability from failures", .text = "A = f/(f + r)", .vars = &.{ v("A", "availability (0 to 1)"), v("f", "mean time between failures"), v("r", "mean time to repair") } },
    .{ .group = "Networking", .name = "IPv6 subnets in a prefix", .text = "N = 2^(64 − p)", .vars = &.{ v("N", "/64 subnets"), v("p", "prefix length") } },
    .{ .group = "Plane geometry", .name = "Inscribed angle (Euclid III.20)", .text = "a = c/2", .vars = &.{ v("a", "angle at the circle"), v("c", "angle at the centre on the same arc") } },
    .{ .group = "Plane geometry", .name = "Intersecting chords (Euclid III.35)", .text = "P = a·b", .vars = &.{ v("P", "product of one chord's parts"), v("a", "first part"), v("b", "second part") } },
    .{ .group = "Plane geometry", .name = "Tangent and secant (Euclid III.36)", .text = "t = √(a·b)", .vars = &.{ v("t", "tangent length"), v("a", "secant, whole length"), v("b", "secant, outside part") } },
    .{ .group = "Plane geometry", .name = "Similar figures: area scale", .text = "A = a·k²", .vars = &.{ v("A", "new area"), v("a", "old area"), v("k", "length scale factor") } },
    .{ .group = "Plane geometry", .name = "Radius of the circle about a triangle", .text = "R = a·b·c/(4·A)", .vars = &.{ v("R", "circumradius"), v("a", "side a"), v("b", "side b"), v("c", "side c"), v("A", "area") } },
    .{ .group = "Plane geometry", .name = "Radius of the circle inside a triangle", .text = "r = 2·A/(a + b + c)", .vars = &.{ v("r", "inradius"), v("A", "area"), v("a", "side a"), v("b", "side b"), v("c", "side c") } },
    .{ .group = "Plane geometry", .name = "Area of a regular polygon", .text = "A = n·s²/(4·tan(180/n))", .vars = &.{ v("A", "area"), v("n", "sides"), v("s", "side") } },
    .{ .group = "Plane geometry", .name = "Inside angle of a regular polygon", .text = "a = (n − 2)·180/n", .vars = &.{ v("a", "angle (°)"), v("n", "sides") } },
    .{ .group = "Plane geometry", .name = "Diagonal of a regular pentagon", .text = "d = s·(1 + √5)/2", .vars = &.{ v("d", "diagonal"), v("s", "side") } },
    .{ .group = "Plane geometry", .name = "Area of a regular pentagon", .text = "A = 5·s²/(4·tan(36))", .vars = &.{ v("A", "area"), v("s", "side") } },
    .{ .group = "Plane geometry", .name = "Angle bisector theorem", .text = "x = a·c/(b + c)", .vars = &.{ v("x", "part of the opposite side next to side b"), v("a", "opposite side"), v("b", "first adjacent side"), v("c", "second adjacent side") } },
    .{ .group = "Plane geometry", .name = "Pythagorean triple from two numbers", .text = "c = m² + n²", .vars = &.{ v("c", "hypotenuse (legs are m² − n² and 2·m·n)"), v("m", "larger number"), v("n", "smaller number") } },
    .{ .group = "Plane geometry", .name = "Median of a triangle", .text = "m = √(2·b² + 2·c² − a²)/2", .vars = &.{ v("m", "median to side a"), v("a", "side a"), v("b", "side b"), v("c", "side c") } },
    .{ .group = "Plane geometry", .name = "Altitude of a triangle from its sides", .text = "h = 2·A/a", .vars = &.{ v("h", "height on side a"), v("A", "area"), v("a", "base") } },
    .{ .group = "Solid geometry", .name = "Volume of a regular octahedron", .text = "V = s³·√2/3", .vars = &.{ v("V", "volume"), v("s", "edge") } },
    .{ .group = "Solid geometry", .name = "Surface of a regular octahedron", .text = "S = 2·√3·s²", .vars = &.{ v("S", "surface"), v("s", "edge") } },
    .{ .group = "Solid geometry", .name = "Volume of a regular dodecahedron", .text = "V = s³·(15 + 7·√5)/4", .vars = &.{ v("V", "volume"), v("s", "edge") } },
    .{ .group = "Solid geometry", .name = "Surface of a regular dodecahedron", .text = "S = 3·√(25 + 10·√5)·s²", .vars = &.{ v("S", "surface"), v("s", "edge") } },
    .{ .group = "Solid geometry", .name = "Volume of a regular icosahedron", .text = "V = 5·s³·(3 + √5)/12", .vars = &.{ v("V", "volume"), v("s", "edge") } },
    .{ .group = "Solid geometry", .name = "Surface of a regular icosahedron", .text = "S = 5·√3·s²", .vars = &.{ v("S", "surface"), v("s", "edge") } },
    .{ .group = "Solid geometry", .name = "Cube in a sphere: edge", .text = "s = 2·r/√3", .vars = &.{ v("s", "edge"), v("r", "radius of the sphere") } },
    .{ .group = "Solid geometry", .name = "Tetrahedron in a sphere: edge", .text = "s = r·√(8/3)", .vars = &.{ v("s", "edge"), v("r", "radius of the sphere") } },
    .{ .group = "Solid geometry", .name = "Volumes of similar solids", .text = "V = a·k³", .vars = &.{ v("V", "new volume"), v("a", "old volume"), v("k", "length scale factor") } },
    .{ .group = "Solid geometry", .name = "Frustum of a cone: volume", .text = "V = π·h·(R² + R·r + r²)/3", .vars = &.{ v("V", "volume"), v("h", "height"), v("R", "big radius"), v("r", "small radius") } },
    .{ .group = "Solid geometry", .name = "Surface of a sphere cap", .text = "S = 2·π·r·h", .vars = &.{ v("S", "curved surface"), v("r", "sphere radius"), v("h", "cap height") } },
    .{ .group = "Solid geometry", .name = "Volume of a spherical cap", .text = "V = π·h²·(3·r − h)/3", .vars = &.{ v("V", "volume"), v("r", "sphere radius"), v("h", "cap height") } },
        .{ .group = "Differential equations", .name = "Exponential growth or decay: y' = k·y", .text = "y = y0·exp(k·t)", .vars = &.{ v("y", "value at time t"), v("y0", "starting value"), v("k", "rate (negative for decay)"), v("t", "time") } },
        .{ .group = "Differential equations", .name = "Doubling time from the growth rate", .text = "T = ln(2)/k", .vars = &.{ v("T", "doubling time"), v("k", "growth rate") } },
        .{ .group = "Differential equations", .name = "Decay rate from the half-life", .text = "k = ln(2)/h", .vars = &.{ v("k", "decay rate"), v("h", "half-life") } },
        .{ .group = "Differential equations", .name = "Newton's law of cooling", .text = "T = a + (s − a)·exp(−k·t)", .vars = &.{ v("T", "temperature at time t"), v("a", "surroundings"), v("s", "starting temperature"), v("k", "cooling rate"), v("t", "time") } },
        .{ .group = "Differential equations", .name = "Cooling rate from one measurement", .text = "k = ln((s − a)/(T − a))/t", .vars = &.{ v("k", "cooling rate"), v("s", "starting temperature"), v("a", "surroundings"), v("T", "temperature at time t"), v("t", "time") } },
        .{ .group = "Differential equations", .name = "Logistic growth", .text = "y = K/(1 + ((K − y0)/y0)·exp(−r·t))", .vars = &.{ v("y", "value at time t"), v("K", "carrying capacity"), v("y0", "starting value"), v("r", "growth rate"), v("t", "time") } },
        .{ .group = "Differential equations", .name = "Time of fastest logistic growth", .text = "t = ln((K − y0)/y0)/r", .vars = &.{ v("t", "time"), v("K", "carrying capacity"), v("y0", "starting value"), v("r", "growth rate") } },
        .{ .group = "Differential equations", .name = "Fastest logistic growth rate", .text = "g = r·K/4", .vars = &.{ v("g", "growth per unit time"), v("r", "growth rate"), v("K", "carrying capacity") } },
        .{ .group = "Differential equations", .name = "First-order step response", .text = "y = Y·(1 − exp(−t/c))", .vars = &.{ v("y", "value at time t"), v("Y", "final value"), v("t", "time"), v("c", "time constant") } },
        .{ .group = "Differential equations", .name = "Steady state of y' + p·y = q", .text = "y = q/p", .vars = &.{ v("y", "steady-state value"), v("q", "forcing"), v("p", "coefficient of y") } },
        .{ .group = "Differential equations", .name = "Euler step", .text = "Y = y + h·f", .vars = &.{ v("Y", "next value"), v("y", "this value"), v("h", "step size"), v("f", "slope at this point") } },
        .{ .group = "Differential equations", .name = "Euler's method for y' = k·y after n steps", .text = "y = y0·(1 + h·k)^n", .vars = &.{ v("y", "value after n steps"), v("y0", "starting value"), v("h", "step size"), v("k", "rate"), v("n", "steps") } },
        .{ .group = "Differential equations", .name = "Midpoint step for y' = k·y", .text = "Y = y·(1 + h·k + (h·k)²/2)", .vars = &.{ v("Y", "next value"), v("y", "this value"), v("h", "step size"), v("k", "rate") } },
        .{ .group = "Differential equations", .name = "Spring: angular frequency", .text = "w = √(k/m)", .vars = &.{ v("w", "angular frequency (rad/s)"), v("k", "spring constant"), v("m", "mass") } },
        .{ .group = "Differential equations", .name = "Spring: period", .text = "T = 2·π·√(m/k)", .vars = &.{ v("T", "period"), v("m", "mass"), v("k", "spring constant") } },
        .{ .group = "Differential equations", .name = "Damped angular frequency", .text = "w = √(k/m − (c/(2·m))²)", .vars = &.{ v("w", "damped angular frequency"), v("k", "spring constant"), v("m", "mass"), v("c", "damping") } },
        .{ .group = "Differential equations", .name = "Critical damping", .text = "c = 2·√(m·k)", .vars = &.{ v("c", "critical damping"), v("m", "mass"), v("k", "spring constant") } },
        .{ .group = "Differential equations", .name = "Damping ratio", .text = "z = c/(2·√(m·k))", .vars = &.{ v("z", "damping ratio (1 = critical)"), v("c", "damping"), v("m", "mass"), v("k", "spring constant") } },
        .{ .group = "Differential equations", .name = "Decay of the envelope of a damped oscillation", .text = "A = exp(−c·t/(2·m))", .vars = &.{ v("A", "fraction of the amplitude left"), v("c", "damping"), v("t", "time"), v("m", "mass") } },
        .{ .group = "Differential equations", .name = "Root of a second-order characteristic equation (larger)", .text = "r = (−b + √(b² − 4·a·c))/(2·a)", .vars = &.{ v("r", "larger root"), v("a", "coefficient of y''"), v("b", "coefficient of y'"), v("c", "coefficient of y") } },
        .{ .group = "Differential equations", .name = "Root of a second-order characteristic equation (smaller)", .text = "r = (−b − √(b² − 4·a·c))/(2·a)", .vars = &.{ v("r", "smaller root"), v("a", "coefficient of y''"), v("b", "coefficient of y'"), v("c", "coefficient of y") } },
        .{ .group = "Differential equations", .name = "Laplace partial fraction coefficient", .text = "A = (n + a)/(a − b)", .vars = &.{ v("A", "coefficient of 1/(s − a)"), v("n", "number in the numerator s + n"), v("a", "first pole"), v("b", "second pole") } },
    };
};

const std = @import("std");
const eval = @import("eval.zig");

/// The letters of a tree that are not constants.
fn letters(a: std.mem.Allocator, n: *const eval.Node, out: *std.ArrayList([]const u8)) !void {
    switch (n.*) {
        .number => {},
        .name => |nm| {
            if (eval.isConstant(nm.text)) return;
            for (out.items) |o| if (std.mem.eql(u8, o, nm.text)) return;
            try out.append(a, nm.text);
        },
        .unary => |u| try letters(a, u.arg, out),
        .binary => |b| {
            try letters(a, b.l, out);
            try letters(a, b.r, out);
        },
        .call => |cl| for (cl.args) |x| try letters(a, x, out),
    }
}

test "every formula reads, and its fields are exactly its letters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (all) |f| {
        var p: eval.Problem = .{};
        const st = eval.parse(a, f.text, .{}, &p) catch |e| {
            std.debug.print("{s}: {s} does not parse ({s} at {d})\n", .{ f.name, f.text, @errorName(e), p.pos });
            return e;
        };
        var found: std.ArrayList([]const u8) = .empty;
        switch (st) {
            .equation => |eq| {
                try letters(a, eq.l, &found);
                try letters(a, eq.r, &found);
            },
            .expr => return error.NotAnEquation,
        }
        for (found.items) |name| {
            const listed = for (f.vars) |var_| {
                if (std.mem.eql(u8, var_.name, name)) break true;
            } else false;
            if (!listed) {
                std.debug.print("{s}: {s} has no field\n", .{ f.name, name });
                return error.MissingField;
            }
        }
        for (f.vars) |var_| {
            const used = for (found.items) |name| {
                if (std.mem.eql(u8, var_.name, name)) break true;
            } else false;
            if (!used) {
                std.debug.print("{s}: field {s} is not in the formula\n", .{ f.name, var_.name });
                return error.ExtraField;
            }
        }
    }
}

test "formulas work out" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var session: eval.Session = .{ .gpa = std.testing.allocator };
    defer session.deinit();
    var p: eval.Problem = .{};
    const num = @import("num.zig");
    // A circle of radius 3: A = 9π.
    const o = try eval.run(a, &session, "A = π·3²", .{ .solve_only = true }, &p);
    try std.testing.expectEqualStrings("9π", o.solved.form.?);
    // Law of sines, degrees: a = 10, A = 30°, B = 45° gives b = 10√2.
    const o2 = try eval.run(a, &session, "10/sin(30) = b/sin(45)", .{ .solve_only = true }, &p);
    try std.testing.expectApproxEqAbs(@as(f64, 14.142135623730951), o2.solved.roots[0].toFloat(), 1e-9);
    // Kinetic energy with only the mass: tidied.
    const o3 = try eval.run(a, &session, "E = 4·v²/2", .{ .solve_only = true }, &p);
    try std.testing.expectEqualStrings("E = 2v²", o3.simplified);
    _ = num;
}
