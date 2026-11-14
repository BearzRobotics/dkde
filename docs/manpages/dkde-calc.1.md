# NAME
dkde-calc - calculator with exact arithmetic, equations, formulas, units, dates and graphs

# SYNOPSIS
dkde-calc [-h | --help] [-V | --version]

dkde-calc

# DESCRIPTION
dkde-calc is the DKDE calculator. You type an expression (or press its keys) and press **Enter** to work it out. The calculator is on the lines of the Windows 7 calculator, GNOME Calculator, KCalc and Qalculate.

Arithmetic is exact: numbers are fractions of integers of any size, so 0.1 + 0.2 is 0.3, 1/3 × 3 is 1 and 2^100 shows all 31 digits. Results that cannot be exact (sines, logarithms, square roots of numbers that are not squares) are worked out to about 16 digits and shown after **≈** instead of **=**.

Besides numbers, an entry can be:

- a variable: **x = 5**, used later as **x**; **ans** is always the last result;
- a function of your own: **f(x) = x² − 3x + 2**, used as **f(4)**;
- an equation with one unknown: **2y + 3 = 11** gives **y = 4**; **x² = 2** gives both roots;
- an expression with letters that have no value: **2a + 3a** is simplified to **5a**;
- a unit conversion: **5 km in mi**, **100 °F to °C**;
- calculus: **diff(x³, x)** is **3x²**, **integral(x², x, 0, 3)** is **9**, **limit(sin(x)/x, x, 0)** is **1**, **sum(k², k, 1, 10)** is **385**.

**=** is part of what you type (for equations, variables and functions); **Enter**, or the blue **⏎** key, works the entry out.

dkde-calc-guide(7) explains the language in full: the order of operations, every function, percentages, equations, formulas, calculus and the programmer mode.

# CONVENTIONS
Bold represents literal commands, options, keys and keywords.
Italic or uppercase placeholders represent values supplied by the user.
[item] means optional; item... means repeatable; a | b means alternatives.
-- ends option processing: everything after it is an operand, never an option.

# MODES
Standard (**Alt+1**)
: The number keys, the four operations, brackets, square root, square, percent, sign change, **=** and **⏎**.

Scientific (**Alt+2**)
: Adds trigonometric, hyperbolic and logarithmic functions, powers, roots, factorial, modulo, the absolute value, π and e, the letter x, **ans**, the comma between arguments, **Plot** (draws the entry as a graph) and the angle unit: **Deg**, **Rad** or **Grad**.

Programmer (**Alt+3**)
: Whole numbers in a word of 8, 16, 32 or 64 bits (two's complement), typed and shown in hexadecimal, decimal, octal or binary. The keys **A**–**F**, **And**, **Or**, **Xor**, **Not**, **Lsh**, **Rsh**, **RoL**, **RoR** and **Mod**. The result is shown in all four bases at once, and its bits below; click a bit to flip it. Division is whole-number division.

# PANES
A pane opens on the right of the keypad; choosing it again closes it.

History (**Ctrl+H**)
: Every calculation, newest first. Click one to use its result. Below are the variables and functions you have made, with a button to forget each. The history, variables, functions, last result and memory are kept between runs.

Unit Conversion (**Ctrl+U**)
: Converts between units of length, area, volume, mass, temperature, time, speed, pressure, energy, power, data, angle and fuel economy. The amount may be an expression.

Date Calculation (**Ctrl+E**)
: The time between two dates (in years, months and days, and in days and weeks), or a date plus or minus a number of years, months and days. It works in every calendar dkde-calendar(1) shows: Julian, Gregorian, the International Fixed calendar, the Rosquin calendar in its three layouts, Chinese, Hebrew, Coptic and Ethiopian. Dates are typed year-month-day in the chosen calendar's own numbering (or picked on a Gregorian calendar and converted), each is described under its field with its Gregorian date, and changing the calendar keeps the same days. Years and months are counted in the chosen calendar: a Hebrew year from Kislev 1 is Kislev 1 the next year.

Graph (**Ctrl+G**)
: Draws up to six functions of x, each in its own colour. Drag to move, scroll or pinch to zoom. Where a curve crosses zero, and where two curves cross, a point is marked; point at it for its coordinates. Point near a curve to read its value. **Scale…** sets the ranges shown on the axes (numbers or expressions such as 2π), fits the vertical range to the curves, or gives both axes the same scale. **Save…** writes the graph as a PNG picture, a scalable SVG drawing, or a CSV table, chosen by the file name (.png, .svg, .csv) or the file type list. The CSV has a header row (x, then each function as typed) and 401 rows across the x range on screen; a value that is not defined at a point (a pole, a square root of a negative) is left empty. Graphs are drawn in radians. **Plot** on the scientific keypad, and **Graph** in the Formulas pane, draw what is in the entry and fit the view to it.

Formulas (**Ctrl+Shift+F**)
: About 140 formulas in geometry, trigonometry, algebra, physics, electricity, chemistry, statistics, money, health and everyday life, with a search box. Picking one puts it in the entry and gives each of its letters a field. Fill in what you know: the values are put into the entry as you type. **Enter** works out the one letter left empty; with several left empty, the formula is simplified as far as it goes. **Graph** draws the formula when the letter on its own on one side is left empty and exactly one other letter is too: the first goes up, the second along, and the axes are labelled with them (**A = π·r²** draws A against r). **Save Entry as Formula** keeps the equation in the entry among **My Formulas**.

# KEYS
**Enter**, keypad **Enter**
: Work the entry out (wherever the keyboard focus is).

**Esc**
: Clear the entry.

**Up**, **Down**
: Go back and forth through earlier entries.

**Ctrl+Shift+C**
: Copy the result (without the digit grouping).

**Alt+1**, **Alt+2**, **Alt+3**
: Standard, Scientific and Programmer modes.

**Ctrl+H**, **Ctrl+U**, **Ctrl+E**, **Ctrl+G**, **Ctrl+Shift+F**
: The History, Unit Conversion, Date Calculation, Graph and Formulas panes.

**Ctrl+W**
: Close the window.

Typing anywhere in the window goes into the entry.

# MEMORY
**MS** stores the result (or what the entry works out to), **MR** puts it into the entry, **M+** and **M−** add to it and subtract from it, **MC** clears it. An **M** beside the display shows that something is stored.

# OPTIONS
-h, --help
: Print help to standard output and exit.

-V, --version
: Print the version to standard output and exit.

# OPERANDS
dkde-calc takes no operands.

# OUTPUT
Results are shown in the display, rounded to the number of decimal places chosen in **View ▸ Decimal Places** (10 by default, trailing zeros dropped). Thousands are grouped with a narrow space (**View ▸ Digit Grouping**), which is never mistaken for the comma between a function's arguments. A non-whole exact result also shows as a fraction above the display: **0.3333333333** **(= 1/3)**. Very large and very small numbers are written as d.ddd×10^n; **View** offers scientific and engineering notation for every result.

# EXIT STATUS
0 on a normal exit. 2 when an option is not recognised (the message goes to standard error). Other nonzero values mean the program could not start; the reason is written to standard error.

# ENVIRONMENT
XDG_CONFIG_HOME, XDG_STATE_HOME, XDG_DATA_DIRS
: Where the settings, the remembered history and the shipped defaults are found (see FILES).

# FILES
$XDG_DATA_DIRS/dkde/calc.toml
: The shipped defaults.

~/.config/dkde/calc.toml
: Your settings. The calculator writes the ones changed from its menus.

~/.local/state/dkde/calc-state
: The history, variables, functions, last result, memory and your own formulas: one tab-separated record per line. Delete it to start afresh.

$XDG_DATA_DIRS/dkde/style.css
: The stylesheet shared by every DKDE program. Anything in it can be overridden in ~/.config/dkde/style.css.

~/.config/dkde/dkde.toml
: Shared appearance (dark mode, accent colour, font).

# CONFIGURATION
All keys are in the **[calc]** group.

| Key | Type | Default | Meaning |
|---|---|---|---|
| mode | text | standard | standard, scientific or programmer |
| pane | text | none | none, history, units, dates, graph or formulas |
| angle | text | degrees | degrees, radians or gradians |
| base | number | 10 | programmer mode: 2, 8, 10 or 16 |
| word-bits | number | 64 | programmer mode: 8, 16, 32 or 64 |
| decimals | number | 10 | decimal places at most (0 to 30) |
| grouping | true/false | true | group thousands |
| notation | text | auto | auto, scientific or engineering |
| date-calendar | text | gregorian | the Date Calculation calendar: gregorian, julian, fixed, rosquin_weeks, rosquin_months, rosquin_quarters, chinese, hebrew, coptic or ethiopian |
| history-size | number | 200 | calculations kept in the history |
| width, height | number | 380, 520 | the window's size, remembered |

# EXAMPLES
**(2 + 3) × 4**
: 20.

**50 + 10%**
: 55: a percentage added to a number is that percentage of it, as on a desk calculator.

**2πr** after **r = 3**
: 18.8495559215 (implicit multiplication: 2πr means 2 × π × r).

**sin(30)** in degrees
: 0.5, exactly.

**x² − 5x + 6 = 0**
: x = 2;  x = 3.

**9² = a² + 6²×8**
: No real solution (a² would be −207); the complex ones are given: a = 14.3874945699i;  a = −14.3874945699i.

**E = m·v²/2** with **m = 4**
: E = 2v² (simplified: v has no value).

**gcd(84, 36)**, **nCr(52, 5)**, **mean(3, 5, 10)**
: 12, 2598960, 6.

**5 ft in m**
: 1.524 m.

**diff(x²·sin(x), x)**
: 2x·sin(x) + x²·cos(x) (in radians).

In programmer mode, hexadecimal: **FF and 0F**
: F.

# DIAGNOSTICS
Errors are shown under the display, and the part of the entry where the problem is gets selected.

Something is missing or out of place here
: The entry is not a valid expression from the selected place on.

Unknown name: NAME
: A function that does not exist (letters without values are simplified instead).

Cannot divide by zero; The result is undefined
: Division by zero; a function outside its domain, such as the square root or logarithm of a negative number.

The number is too large
: A result over about 40,000 digits, or a factorial over 3000!.

No real solution was found
: The equation has no real solution (between −10,000,000 and 10,000,000).

Programmer mode works with whole numbers
: A fraction in programmer mode.

# LIMITATIONS
Equations are solved numerically for one unknown; systems of equations are not. Complex solutions are given only for polynomial equations without real ones. Simplification combines numbers, like terms and powers; it does not expand products of sums or factor. There is no symbolic integration: **integral** gives a number. Unit conversions use fixed factors (no currencies). Graphs are drawn in radians.

# SEE ALSO
dkde-calc-guide(7), dkde-calendar(1), dkde-help(1)

# AUTHOR
DKDE contributors.

# LICENSE
MIT. The full text is in the LICENSE file of the source code.

# AVAILABILITY
Source code: https://github.com/BearzRobotics/dkde

# VERSION
This manual describes dkde-calc 0.2.0.
