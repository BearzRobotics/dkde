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

pub const all = [_]Formula{
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
