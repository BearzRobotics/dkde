# (category, expression, overrides)
# overrides: dict tool -> expression text, or None to skip that tool.
# Tools: ours, qalc, insect, kalker. Angles are radians everywhere.
C = []
def add(cat, expr, **ov):
    C.append((cat, expr, ov))

# ---- exact arithmetic
for e in ["0.1+0.2", "1/3+1/4", "2^100", "3^-2", "(2/3)^5", "123456789*987654321", "17/4", "-7/3",
          "2^0.5", "7^(1/3)", "100/7", "(1+1/3)^10", "2^64-1", "10^20+1", "1/7", "22/7-pi", "999999999*999999999"]:
    add("arith", e)

# ---- factorials, number theory
add("number", "10!"); add("number", "20!"); add("number", "50!"); add("number", "100!/98!")
add("number", "gcd(84,36)", insect=None)
add("number", "lcm(4,6)", insect=None)
add("number", "nCr(52,5)", qalc="binomial(52,5)", insect=None, kalker=None)
add("number", "nPr(10,3)", qalc="perm(10,3)", insect=None, kalker=None)
add("number", "7 mod 3", qalc="mod(7,3)", insect=None, kalker="7 % 3")
add("number", "-7 mod 3", qalc="mod(-7,3)", insect=None, kalker=None)
add("number", "totient(36)", insect=None, kalker=None)
add("number", "isprime(97)", qalc="isprime(97)", insect=None, kalker=None)
add("number", "fibonacci(30)", qalc="fibonacci(30)", insect=None, kalker=None)

# ---- elementary functions (radians)
KNONE = {"log10(1000)", "log2(8)", "atan2(1,2)", "cos(1e5)", "sqrt(1e-10)", "exp(-20)", "sec(1)", "csc(1)", "cot(1)", "sinh(1)", "cosh(1)", "tanh(0.5)", "asinh(2)", "acosh(2)", "atanh(0.5)"}
INONE = {"log2(8)", "cbrt(27)", "sec(1)", "csc(1)", "cot(1)", "sinh(1)", "cosh(1)", "tanh(0.5)", "asinh(2)", "acosh(2)", "atanh(0.5)"}
for e in ["sin(1)", "cos(2)", "tan(0.5)", "asin(0.5)", "acos(0.3)", "atan(2)", "sinh(1)", "cosh(1)", "tanh(0.5)",
          "asinh(2)", "acosh(2)", "atanh(0.5)", "exp(2)", "ln(10)", "log10(1000)", "log2(8)", "sqrt(2)", "cbrt(27)",
          "abs(-3.5)", "floor(-2.5)", "ceil(2.1)", "round(2.5)", "sec(1)", "csc(1)", "cot(1)", "atan2(1,2)",
          "sin(100)", "cos(1e5)", "exp(-20)", "ln(0.001)", "sqrt(1e-10)", "tan(1.5707)"]:
    ov = {}
    if e in KNONE: ov["kalker"] = None
    if e in INONE: ov["insect"] = None
    add("elementary", e, **ov)
add("elementary", "sec(1)", insect=None)

# ---- special functions
add("special", "gamma(5.5)")
add("special", "gamma(0.1)")
add("special", "erf(0.5)", insect=None, kalker=None)
add("special", "erfc(1.5)", insect=None, kalker=None)
add("special", "beta(2,3)", insect=None, kalker=None)
add("special", "zeta(2)", insect=None, kalker=None)
add("special", "digamma(1)", insect=None, kalker=None)
add("special", "lambertw(1)", insect=None, kalker=None)

# ---- constants and big/small
add("constants", "pi*e"); add("constants", "phi", qalc="golden", insect=None, kalker="phi")
add("constants", "e^pi"); add("constants", "pi^pi")
add("constants", "2^1000")
add("constants", "10^-30*3", kalker=None)

# ---- complex
add("complex", "(1+2i)*(3-i)", insect=None)
add("complex", "sqrt(-4)", insect=None)
add("complex", "e^(i*pi)", insect=None)
add("complex", "(1+i)^10", insect=None)
add("complex", "abs(3+4i)", insect=None)
add("complex", "conj(1+2i)", insect=None, kalker=None)
add("complex", "ln(-1)", insect=None)
add("complex", "asin(2)", insect=None)
add("complex", "(-8)^(1/3)", insect=None)
add("complex", "(2+3i)/(1-i)", insect=None)
add("complex", "i^i", insect=None)
add("complex", "sqrt(3+4i)", insect=None)

# ---- matrices
add("matrix", "[1,2;3,4]*[5,6;7,8]", insect=None, qalc="[1,2;3,4]*[5,6;7,8]")
add("matrix", "det([1,2;3,4])", insect=None)
add("matrix", "inv([1,2;3,4])", insect=None, kalker=None)
add("matrix", "transpose([1,2;3,4])", insect=None, kalker=None)
add("matrix", "[1,2;3,4]^3", insect=None)
add("matrix", "det([2,0,1;1,3,2;1,1,1])", insect=None)
add("matrix", "[1,2,3]+[4,5,6]", insect=None)
add("matrix", "2*[1,2;3,4]", insect=None)

# ---- statistics
add("stats", "mean(1,2,3,10)", qalc="mean(1,2,3,10)", insect=None, kalker=None)
add("stats", "median(5,1,9,3)", insect=None, kalker=None)
add("stats", "stdev(2,4,4,4,5,5,7,9)", insect=None, kalker=None)
add("stats", "var(2,4,4,4,5,5,7,9)", insect=None, kalker=None)
add("stats", "max(3,9,2)", insect=None)
add("stats", "sum(1,2,3)", qalc="total(1,2,3)", insect=None, kalker=None)

# ---- calculus
add("calculus", "integral(x^2, x, 0, 3)", qalc=None, insect=None, kalker=None)
add("calculus", "limit(sin(x)/x, x, 0)", qalc=None, insect=None, kalker=None)
add("calculus", "sum(k^2, k, 1, 10)", qalc=None, insect=None, kalker="sum(k=1,10,k^2)")

# ---- units (ours: units in entries)
add("units", "5 ft + 3 in", qalc="(5 ft + 3 in) to ft", kalker=None)
add("units", "5 kg * 2 m/s^2", kalker=None)
add("units", "60 mph to km/h", insect="60 mph -> km/h", kalker=None)
add("units", "100 degF to degC", ours="100 °F to °C", insect="100 °F -> °C", kalker=None)
add("units", "1 mi to km", insect="1 mi -> km", kalker=None)
add("units", "8 GiB to GB", insect="8 GiB -> GB", kalker=None)
add("units", "10 m / 2 s", kalker=None)
add("units", "3 hours + 20 min to s", insect="3 hours + 20 min -> s", kalker=None)
add("units", "1 atm to psi", insect="1 atm -> psi", kalker=None)
add("units", "1 kWh to J", insect="1 kWh -> J", kalker=None)
add("units", "90 deg to rad", insect="90 deg -> rad", kalker=None)
add("units", "1 lightyear to km", insect="1 lightyear -> km", kalker=None)
add("units", "2 L to gal", qalc="2 L to gal", insect="2 L -> gal", kalker=None)
add("units", "5 N * 3 m", kalker=None)
add("units", "1 hp to W", insect="1 hp -> W", kalker=None)

# ---- percent / misc
add("misc", "50 + 10%", insect="50 + 10%", kalker=None)
add("misc", "200 * 15%", insect="200 * 15%", kalker=None)
add("misc", "(2+3)*4^2/8")
add("misc", "2^3^2")
add("misc", "-2^2")
add("misc", "2(3+4)")
add("misc", "1/0", qalc="1/0", insect="1/0", kalker="1/0")
add("misc", "sqrt(-1)", insect=None)
add("misc", "0^0")
add("misc", "(-2)^0.5", insect=None)

# ---- dates (qalc has date functions; insect/kalker do not)
add("dates", "weekday(2026-12-25)", insect=None, kalker=None)
add("dates", "days(2026-11-14, 2026-12-25)", insect=None, kalker=None)
add("dates", "week(2026-11-14)", ours="weeknumber(2026-11-14)", insect=None, kalker=None)
add("dates", "addmonths(2026-01-31, 1)", insect=None, kalker=None)
