# NAME
dkde-calc-guide - how to use the DKDE calculator: numbers, the order of operations, functions, equations, formulas, calculus and the programmer mode

# DESCRIPTION
This guide explains what you can type into dkde-calc(1) and how it is worked out. Everything here can also be done with the keys; the keys only type text into the entry. **Enter** (or the blue **⏎** key) works the entry out; **=** is something you type, for equations.

# NUMBERS
**12**, **3.75**, **.5**, **1.5e3** (1500), **2e−4** (0.0002)
: Decimal numbers. They are read exactly: **0.1** is one tenth, not the nearest binary fraction, so **0.1 + 0.2** is exactly **0.3**.

**0x1F**, **0b1011**, **0o17**
: Whole numbers in hexadecimal, binary and octal, in any mode.

Exact and approximate
: The calculator works with fractions of whole numbers of any size: **1/3** stays one third, **1/3 × 3** is **1**, **2^200** has all 61 digits. A result that cannot be a fraction (**√2**, **sin(1)**, **ln 5**, anything with π) is worked out to about 16 significant digits and shown after **≈**. A fraction that is shown as a decimal also shows as a fraction above the display: **0.1428571429** **(= 1/7)**.

Digit grouping
: Results group thousands with a narrow space (**1 234 567**). You can type such a result back in: the spaces are ignored.

# THE ORDER OF OPERATIONS
Operations are done in this order, from the first (binding most tightly) to the last. Operations on the same line are done from left to right, except powers, which are done from right to left.

| Order | Operations | Examples |
|---|---|---|
| 1 | brackets **( )**, absolute value **\|x\|** | (2 + 3) × 4 = 20 |
| 2 | functions **sin(…)**, **√**, **∛** | √9 + 1 = 4 |
| 3 | after a number: factorial **!**, percent **%**, squares and cubes **²** **³** | 3! = 6, 3² = 9 |
| 4 | powers **^** (right to left) | 2^3^2 = 2^9 = 512 |
| 5 | sign **−x**, bitwise **not** | −2^2 = −4, (−2)^2 = 4 |
| 6 | multiplication **×** **·** **\***, division **÷** **/**, **mod**, and multiplication without a sign (**2π**, **3x**, **2(1 + 1)**) | 10 − 6 ÷ 2 = 7 |
| 7 | addition **+**, subtraction **−** | 10 − 2 − 1 = 7 |
| 8 | shifts **<<** **>>** | 1 << 2 + 1 = 8 |
| 9 | **and**, then **xor**, then **or** | 6 and 3 = 2 |

Things to know:

- **−2^2** is **−4**: the power comes first, then the sign. Write **(−2)^2** for 4.
- **2^3^2** is **2^(3^2)** = 512, as in mathematics.
- **6 ÷ 2(1 + 2)** is **9**: multiplication without a sign is ordinary multiplication, done from left to right with division (6 ÷ 2 = 3, then 3 × 3).
- A missing multiplication sign needs the two parts to touch: **2π** and **2(3)** multiply, but **2 3** is an error.
- **ab** is one name ("ab"), not a × b. Write **a·b** (or **a b** inside a formula's fields). Greek letters are always single letters: **πr** is π × r.

# PERCENT
**50%**
: 0.5: a number followed by % is divided by 100.

**200 × 15%**
: 30: fifteen percent of 200.

**50 + 10%**, **50 − 10%**
: 55 and 45: a percentage added to or taken from a number is that percentage of the number, as on a desk calculator.

**x % y**
: Not modulo. Use **mod** for the remainder: **17 mod 5** = 2.

# CONSTANTS
| Name | Value |
|---|---|
| **π**, **pi** | 3.14159265358979… |
| **e** | 2.71828182845904… (Euler's number) |
| **τ**, **tau** | 2π |
| **φ**, **phi** | 1.61803398874989… (the golden ratio) |
| **ans** | the last result |

**e** is a constant only on its own: **2e3** is 2000, but **2e** is 2 × e.

# FUNCTIONS
Arguments are separated by commas: **gcd(12, 18)**.

Trigonometry
: **sin**, **cos**, **tan**, **sec**, **csc**, **cot**, and the inverses **asin**, **acos**, **atan**, **atan2(y, x)**. Angles are in the unit chosen with **Deg**, **Rad** or **Grad** (or in **View**). In degrees, **sin**, **cos** and **tan** of multiples of 30° and 45° are exact: **sin(30)** is 0.5, **tan(45)** is 1.

Hyperbolic
: **sinh**, **cosh**, **tanh**, **asinh**, **acosh**, **atanh**.

Powers and roots
: **x^y**, **x²**, **x³**, **√x**, **sqrt(x)**, **∛x**, **cbrt(x)**, **root(x, n)**, **pow(x, y)**, **exp(x)**. Roots that come out whole stay exact: **√49** = 7, **8^(1/3)** = 2, **root(−27, 3)** = −3.

Logarithms
: **ln** (natural), **log** and **log10** (base 10), **log2**, **log(x, b)** (base b). **log(8, 2)** is exactly 3.

Rounding and parts
: **abs**, **floor**, **ceil**, **round** (halves away from zero), **trunc**, **frac** (the part after the point), **sign**.

Whole numbers
: **n!** and **fact(n)**, **gcd**, **lcm** (any number of arguments), **nCr(n, r)** (combinations), **nPr(n, r)** (arrangements), **mod(a, b)** or **a mod b** (the remainder, with the sign of b: −1 mod 3 = 2).

Lists
: **min**, **max**, **sum**, **mean** (or **avg**), **median**, **stdev** (sample standard deviation), **var** (sample variance): **mean(2, 4, 9)** = 5.

Random
: **rand()**: a number between 0 and 1.

# VARIABLES
**x = 5**
: Stores 5 in x. Variables keep their values between runs; the History pane lists them, with a button to forget each.

**x = x + 1**
: Sets x to 6 (x already has a value).

**ans**
: The last result: **ans × 2**.

Names start with a letter and go on with letters, digits and **_**: **x**, **total**, **v0**, **rate_2**. A Greek letter is a name by itself, with digits after it: **θ**, **θ1**.

Styled letters from mathematics (𝑥, 𝐅, 𝒜, 𝔸, 𝛼, ℝ …) and subscript digits (x₁) are read as plain letters and digits, so pasted formulas work: **𝐹 = 𝑚𝑎** is F = m·a.

# FUNCTIONS OF YOUR OWN
**f(x) = x² − 3x + 2**
: Defines f. Then **f(4)** is 6, and **f** can be used anywhere, plotted (type **f** in the Graph pane) and differentiated.

**area(w, h) = w·h**
: Several arguments.

A definition may use variables and other functions; it is kept between runs.

# EQUATIONS
An entry with **=** whose left side is not a plain name to store is an equation, solved for its one unknown.

**2x + 3 = 11**
: x = 4

**x² − 5x + 6 = 0**
: x = 2;  x = 3 (all real solutions between −10,000,000 and 10,000,000 are listed)

**x² = 2**
: x ≈ −1.4142135624;  x ≈ 1.4142135624

**cos(x) = x** (in radians)
: x ≈ 0.7390851332

**2 + 2 = 4**
: true

Solutions are found numerically, then checked: a solution that is a simple fraction is given exactly (**3x = 1** gives x = 1/3, shown as 0.3333333333 with **(= 1/3)**). An equation without real solutions (**x² = −1**) says so.

When an equation has more than one unknown, it is simplified as far as it goes instead: **E = 4·v²/2** gives **E = 2v²**.

# SIMPLIFYING
An expression with letters that have no value is tidied rather than refused:

- numbers are worked out: **4·v²/2** is **2v²**;
- like terms are added: **2a + 3a** is **5a**, **x − x** is **0**;
- powers of the same thing are combined: **x²·x** is **x³**, **x/x** is **1**;
- a number times a bracket is multiplied out: **2(x + 1)** is **2x + 2**;
- π, e, τ and φ stay as letters: **π·3²** is **9π**.

Products of brackets are not multiplied out and nothing is factored: this is tidying, not computer algebra.

# FORMULAS
The Formulas pane (**Ctrl+Shift+F**) has about 140 formulas, grouped by subject and searchable. Pick one: it goes into the entry, and each of its letters gets a field, described ("radius", "rate (% a year)"). Constants such as g are filled in already.

- Fill in all but one letter and press **Enter**: the empty one is worked out. **A = π·r²** with r = 3 gives **A = 9π ≈ 28.2743338823**; with A = 50 instead, r ≈ ±3.9894228040.
- Leave several empty: the formula is simplified with the values you gave.
- Fill in all of them: the calculator says whether the formula holds (true or false).

A formula in the entry is always solved; it never stores a variable. **Save Entry as Formula** keeps the equation in the entry among My Formulas.

# CALCULUS
**diff(f, x)**
: The derivative of f by x, as a formula: **diff(x³ + 2x, x)** is **3x² + 2**; **diff(sin(x), x)** is **cos(x)**. Functions of your own are differentiated through their definitions.

**diff(f, x, a)**
: The derivative at x = a: **diff(x³, x, 2)** is 12.

**integral(f, x, a, b)**
: The definite integral from a to b, worked out numerically to about 12 digits (exact when it is a simple fraction): **integral(x², x, 0, 3)** is 9; **integral(sin(x), x, 0, π)** is 2.

**limit(f, x, a)**
: The limit as x goes to a, from both sides: **limit(sin(x)/x, x, 0)** is 1. **a** may be **inf** (or **∞**) or **−inf**: **limit((1 + 1/n)^n, n, inf)** is e.

**sum(f, k, m, n)**, **prod(f, k, m, n)**
: f added up, or multiplied together, for k = m, m + 1, … n, exactly: **sum(k², k, 1, 10)** is 385; **prod(k, k, 1, 5)** is 120.

In degrees, derivatives of trigonometric functions carry the factor π/180 (the rate per degree). Use **Rad** for the usual textbook results.

# UNITS
**AMOUNT UNIT in UNIT**, **AMOUNT UNIT to UNIT**
: **5 km in mi**, **(2 + 3) kg to lb**, **100 °F to °C**, **3 nautical miles in km**, **8 GiB in GB**.

The Unit Conversion pane (**Ctrl+U**) lists every unit: length, area, volume, mass, temperature, time, speed, pressure, energy, power, data (decimal and binary prefixes), angle and fuel economy (including litres per 100 km).

# DATES
The Date Calculation pane (**Ctrl+E**) gives the time between two dates in years, months, weeks and days (and in days alone), or the date a number of years, months and days before or after another, with its weekday. A day that does not exist in the month reached (31 February) becomes the month's last day. Dates are written **2024-07-19** (or **19.7.2024**), or picked on a calendar.

# PROGRAMMER MODE
**Alt+3** works with whole numbers of 8, 16, 32 or 64 bits (byte, word, dword, qword), negative numbers in two's complement. The base buttons choose how numbers are typed and shown; all four bases are shown under the display, and the bits under them (click a bit to flip it).

| Typed | Meaning |
|---|---|
| **and**, **&** | bitwise and |
| **or**, **\|** | bitwise or |
| **xor** | bitwise exclusive or |
| **not**, **~** | bitwise not |
| **<<**, **>>** | shift left, right |
| **rol(x)**, **ror(x)**, **rol(x, n)** | rotate within the word |
| **/** | whole-number division (towards zero) |
| **mod** | remainder |

In hexadecimal, **A**–**F** are digits: **FF + 1** is 100. Results that do not fit the word wrap around, as in a processor: in a byte, **255** is −1.

# THE GRAPH
Each row of the Graph pane is a function of x: **x²/4 − 1**, **sin(x)**, **f** (a function of your own), **diff(x³, x)** (a derivative). Up to six are drawn together. Points where a curve crosses zero, and where two curves cross, are marked; point at one to read it. Graphs use radians.

# SEE ALSO
dkde-calc(1), dkde-help(1)

# VERSION
This guide describes dkde-calc 0.1.1.
