% DKDE-CALENDAR(1) Version 0.0.4 | DKDE Manual
% DKDE contributors
% 2026-11-06

NAME
dkde-calendar - month calendar with events, notes, liturgical calendars and ten calendar systems (Julian, Gregorian, Fixed, the Rosquin calendar in three layouts, Chinese, Hebrew, Coptic and Ethiopian)

SYNOPSIS
dkde-calendar [-h | --help] [-V | --version]

dkde-calendar

DESCRIPTION
dkde-calendar is the DKDE calendar. It shows one month at a time in a grid, with the selected day, its notes and its events beside it. The same day can be read in four calendar systems (Gregorian, Julian, Fixed and Rosquin), and three liturgical calendars can be laid over the grid. Events and notes are stored in the user's calendar.toml. The panel reads that file and sends the reminders; dkde-calendar itself only stores them, and reminders fire whether or not it is running.

The toolbar has two rows. The first moves between months and copies dates (previous and next month, the month name, Today, Go to, Copy date). The second row starts at the calendar selector and holds Save as default, Liturgical and Options and the button that adds an event. The day panel on the right is narrow and wraps its text; in it each calendar's name (the other calendar systems and the liturgical calendars) is shown in bold in the accent colour above its date. In the Rosquin views the glyph of a day is drawn below the civil date line of its cell.

The program is a single window. It takes no operands and no options other than help and version. Everything else is set in the window and remembered in the configuration file.

Events, reminders and the liturgical overlays always use the civil (Gregorian) date. A calendar system only decides how a day is numbered and where its months begin, so changing the system never moves an event.

CONVENTIONS
Bold represents literal commands, options, and keywords.
Italic or uppercase placeholders represent values supplied by the user.
Dates are written year-month-day in the Gregorian calendar unless a calendar system is named.
Times are local wall-clock time. Moon-phase dates are local to the configured location (see CALENDAR SYSTEMS, Rosquin).
Paths follow the XDG Base Directory rules; defaults are documented under FILES.

ROSQUIN FONT
**The Rosquin glyphs are characters of a font, RosquinGlyphs.ttf (family "Rosquin Glyphs"). A glyph can be shown in any other program only if that font is installed on the computer and the program is told to use it for the text.** Without it, a copied glyph appears as empty boxes or as nothing.

The calendar itself needs no installation: the font is built into the program, which writes a copy to ~/.cache/dkde/RosquinGlyphs.ttf at every start (the Windows build to a file you choose, see below) and uses it for its own windows only.

To use a copied glyph elsewhere:
1. Install the font. Linux: copy ~/.cache/dkde/RosquinGlyphs.ttf (or data/fonts/RosquinGlyphs.ttf in the source tree) to ~/.local/share/fonts/ and run `fc-cache -f`. Windows: File, Save the Rosquin font, then right-click the saved file and choose Install (or Install for all users).
2. In the program where you paste (a word processor, a note, a message), select the pasted glyph and set its font to "Rosquin Glyphs". A glyph is several characters in the Unicode Private Use Area (U+E000 and up) followed by one EM SPACE (U+2003); the font gives the characters no width of their own, so they land on top of one another, and the EM SPACE gives the whole run the width of the glyph (one em, the font size). The glyph is as big as the font size you choose.
3. A program that cannot choose a font for part of the text, or that replaces the font of pasted text, will not show the glyph. Copy the date as text instead (below), which needs no font.

Copy menu (a right-click on any day, the Copy date button, and Edit, Copy in the Windows build; Ctrl+C copies the text form): Copy date as text ("18309/47  Yr 50  Gleaning 47  Harrow (2026-11-06)", in the layout that is on screen), Copy day code (18309), Copy glyph (needs the Rosquin font), Copy glyph and text, and Copy date as 2026-11-06. In the other calendar systems the first form is the day written out, and only it and the ISO date are offered.

OPTIONS
Global options
-h, --help
: Print the usage text to standard output and exit with status 0.

-V, --version
: Print "dkde-calendar VERSION" to standard output and exit with status 0.

--
: End option processing. The program has no operands, so nothing is read after it.

Toolkit options
: Options that GLib and GTK handle themselves (for example --gapplication-*, --gtk-*, --gdk-*) are passed through and are not reported as unknown.

Option interactions and precedence
Any other option is reported on standard error and the program exits with status 2. There is no command-line way to choose the calendar system or the location; use the window or the configuration file. The window's choices are written back to the configuration file and win over the shipped defaults.

THE WINDOW
Toolbar
Previous and next month, Today, Go to, the calendar-system menu, and the Options menu.

Calendar system menu
Julian, Gregorian, Fixed (13 months), Rɛ°Cᴀʟ—28.wѻ, Rɛ°Cᴀʟ—7ᴍọ/4.wѻ, Rɛ°Cᴀʟ—4ᴍọ/7.wѻ, Chinese, Hebrew (Jewish), Coptic and Ethiopian. Choosing one only changes what is on screen. It is not saved as the default until Save as default (below); view.system holds the default (julian, gregorian, fixed, rosquin_weeks, rosquin_months, rosquin_quarters, chinese, hebrew, coptic or ethiopian; the older value rosquin reads as rosquin_months).

Save as default
: Makes the calendar system, the liturgical calendars and Named days only that are on screen the ones the program opens with (view.system, view.novus-ordo, view.tlm-1962, view.orthodox-ru, view.named-days-only). Changing any of them to look at something never changes the default by itself; the button is greyed while the view on screen is the saved default. (The 12-hour clock is a preference, shared with the panel's reminders, and is saved when it is changed.) The grid moves to the month that holds the selected day in the new system.

Options
Liturgical (a drop-down in the toolbar): Novus Ordo, Traditional (1962), Russian Orthodox
: Lay the corresponding liturgical calendar over the grid and the day panel. Each can be on at the same time as the others.

Named days only
: In the grid, show only Sundays, feasts, memorials and other special days, not every plain weekday.

12-hour clock (AM/PM)
: Choose 12-hour or 24-hour times in the grid and in reminders.

New event, Import, Export, Sync now
: See EVENTS AND NOTES.

Go to
: Opens a small window for jumping to any date, past or future. The calendar widget has month and year buttons for a civil date. "Rosquin day code" takes a day code (18309 is 2026-11-06). "Rosquin year" with "Day of the year" takes a Rosquin year and a day from 1 to 366; day 365 is Year-End Day, and day 366 is Leap Day, which a year without one refuses with a message. The four buttons step to the previous or next Leap Day or Year-End Day from the selected day, which is the quick way to check a leap year: the next Leap Day from 2026-11-06 is 2028-02-29, day code 18789, in Year 51. The window shows the selected day's date, day code, day of the year and year, and the main window follows every jump.

Window size
The window is never larger than the first monitor (it opens at most 1060 by 700, less the monitor's size minus a margin). When the grid does not fit, the grid scrolls, with scroll bars, instead of making the window bigger; cells keep a readable size, so the 28-week layout, 28 rows tall, scrolls vertically.

Month grid
Each cell is a day. It shows the day number in the chosen system (or the Rosquin glyph), the civil month/day in small type when the system is not Gregorian, liturgical lines if they are switched on, and up to two events, with a "+N" for the rest. Days outside the month are dimmed. Today and the selected day are marked. Clicking a day selects it. In the Fixed calendar the extra days that belong to no week (Leap Day, Year Day) have a row of their own under the grid; in the Rosquin calendar the inter-calendar days have the 14th column.

Day panel
The heading names the selected day in the chosen system; the other systems are listed under it in small type. Below are the liturgical observances, the events of the day and a free-text note for the day.

CALENDAR SYSTEMS
A system is a rule that turns a civil date into a (year, month, day) and back. All are proleptic: they extend backward and forward without a start or end. The code is in src/calendar/calsys.zig.

Gregorian
The civil calendar. 12 months, weeks of 7 days starting on Sunday, a leap day (February 29) in years divisible by 4 except century years not divisible by 400. This is the default (view.system = "gregorian").

Julian
The Old Calendar. 12 months, the same month names and 7-day week, but a leap day in every year divisible by 4, with no century exception. It is therefore 13 days behind the Gregorian calendar in 2026: October 31, 2026 is Julian October 18, and Gregorian January 1 is Julian December 19. Old New Year (Julian January 1) falls on Gregorian January 14; Old-Style Christmas on January 7. The grid heading is marked "(Julian)". The conversion goes through the Julian Day Number and round-trips exactly over centuries. The Russian Orthodox calendar uses this system for its fixed feasts and for Pascha.

Fixed (the International Fixed Calendar)
13 months of exactly 28 days, every month starting on a Sunday and made of four 7-day weeks. The months are January to June, then Sol, then July to December. Day 365 is Year Day, outside any week, placed after December 28 (the 13th month's 28th day). In a leap year Leap Day is inserted after June 28, so Sol begins one day later. In this implementation Leap Day is civil day 169 of a leap year and the leap rule is the Gregorian one. Because the week restarts every month, the weekday of a civil date is generally not its Gregorian weekday; Year Day and Leap Day have no weekday. Each month shows its 28 days in 4 rows and, when it has one, the extra day in a fifth row.

Rosquin
A calendar of 13-day weeks whose year starts at the September equinox, in three layouts that all count the same days. The rules are in src/common/rosquin.zig (shared with the panel's clock). The source material is the Rosquin calendar workbook and glyph master supplied with the project (src/calendar/rosquincalander/); the workbook has one sheet per layout.

*Day code.* Every day has a number: 1976-09-21 is day 1, so 2026-11-06 is day 18309. The code is printed in every cell of the grid, at the start of the day panel's heading, and is available to the panel clock as @D.

*Day of the year.* A second number that starts over at 1 on September 21 and reaches 364 on September 20. Year-End Day is 365 and Leap Day is 366, as in the workbook, so the regular days of a year are 1 to 364 and the two special days follow in their own right. It is printed after the day code in every cell (18309 · 47), in the day panel's heading, and is @y in the panel clock.

*Week.* 13 days: days 1 to 12 and day 13, the Ankh. A year has 28 weeks (364 days). The week is not tied to the 7-day week. The grid has 13 columns, one per day of the week, headed 1 to 12 and the Ankh (☥), and a 14th for the inter-calendar days.

*Year.* A year starts on September 21 and ends on September 20. Its number is the civil year of the September 21 that starts it, minus 1976. September 21, 2026 begins Year 50. The workbook formulas count the day of the year from September 21 in the same way: September 21 is day 1, December 30 is day 101, January 1 is day 102 and September 20 is day 364.

*Inter-calendar days.* Year-End Day (every December 31) and Leap Day (every February 29) belong to no week and no month; they are days of the year only. They keep their place in the count: Year-End Day falls in week 8, after day 101 (December 30) and before day 102 (January 1); Leap Day falls in week 13, after day 160 (February 28) and before day 161 (March 1). Every month and every week keeps its length, so a year is 364 regular days plus these. In the grid they stand in a 14th column, headed "Inter", to the right of the 13 days of the week: in the row of the week they fall in, on the page that holds that week (week 8 is the 4th row of Month 2 in the 7-month layout, the first row of the 4-month layout's Month 2 and row 8 of the 28-week layout; week 13 is row 13, row 1 of Month 4 and the last row but one of Month 2 respectively). Selecting one shows that page. Their day of the year is 365 and 366. The first row of the 14th column always carries the calendar's branding picture (a gold ankh in a shield and ring on a white ground, data/branding.png, built into the program), on every page of every Rosquin layout. Where an inter-calendar day falls in that same row (Leap Day on month 4 of the 7-month layout, Year-End Day on month 2 of the 4-month layout), the picture shrinks to the top of the cell and the day takes the rest.

*The three layouts.* The author's names for them are Rɛ°Cᴀʟ—28.wѻ, Rɛ°Cᴀʟ—7ᴍọ/4.wѻ and Rɛ°Cᴀʟ—4ᴍọ/7.wѻ (28 weeks; 7 months of 4 weeks; 4 months of 7 weeks), which are also the names in the calendar-system menu. Each is chosen independently.

Rɛ°Cᴀʟ—28.wѻ (28 weeks)
: The year is one page of 28 rows of 13 days. There are no months. Previous and next move a year. The inter-calendar days are under the last row.

Rɛ°Cᴀʟ—7ᴍọ/4.wѻ (7 months of 4 weeks)
: Months of 4 weeks (52 days), 7 to the year, four rows of 13 days.

Rɛ°Cᴀʟ—4ᴍọ/7.wѻ (4 months of 7 weeks)
: Months of 7 weeks (91 days), 4 to the year (called quarters in the code), seven rows of 13 days.

*Names.* The author of the calendar has not named the days, months or quarters. The names below are provisional, chosen by the DKDE contributors, and are in one place (src/common/rosquin.zig) so they can be replaced. Only names are provisional; the numbers are the calendar's.

Day of the week	Name
1 to 6	Kindling, Furrow, Lantern, Tidewater, Cairn, Wellspring
7 to 12	Plumbline, Harrow, Thistle, Compass, Vesper, Threshold
13 (the Ankh)	Ankhtide
Year-End Day	Stillpoint
Leap Day	Wanderday
Months 1 to 4	Gleaning, Emberfast, Hollowmoon, Thawbright
Months 5 to 7	Greenwake, Highsun, Reapglow
Quarters 1 to 4	Gathering, Stillwater, Quickening, Highsummer

*Day 13.* In every Rosquin layout the cells of day 13 of the week, the Ankh, have a very light orange ground (#fff3e0), so the 14 columns read as 12 plain days, the Ankh and the inter-calendar days. A selected or current day keeps its own colour.

*Moon.* The moon phase of each day is computed (src/calendar/lunar.zig), not looked up. New moon, first quarter, full moon and last quarter come from Jean Meeus, Astronomical Algorithms, 2nd ed., chapter 49, with the periodic terms for the Moon's anomaly, the Sun's anomaly, the argument of latitude and the node. The result is the instant of the phase, good to a minute or two in the present era. ΔT is taken as 69 seconds. A phase is one instant for the whole Earth, so the place decides only which local day it falls on. The site defaults to Lake Odessa, Michigan (42.7889 N, 85.1417 W) and uses the America/Detroit clock, daylight saving included; see CONFIGURATION. A phase shows its moon symbol in the cell.

*The glyph.* In the Rosquin systems a day is drawn as a glyph above its day code. The glyph is a stack: every component is a character of the font RosquinGlyphs.ttf, all on the same 900 by 900 canvas, printed on top of one another, and the day's value is written in binary by which components are present. src/calendar/rosstamp.zig decides the components; the grid prints them on top of each other with the font size as the stamp size (88px). The glyph always counts months of 4 weeks, whatever the layout. Hovering a cell shows the full date as text. The components are:

Component	Where	What it says
Year corners	top-left, top-right	year in the 4-year leap cycle: Year mod 4, bit 1 and bit 2
Quarter corners	bottom-right, bottom-left	quarter of the year, 0 to 3, bit 1 and bit 2
Week of quarter	bottom edge, three marks	week 1 to 7 of the quarter, bits 1, 2 and 4
Month	upper edge, three marks	month 1 to 7, bits 1, 2 and 4
Week of month	far corners, two marks	week 1 to 4 of the month, written 0 to 3, bit 1 and bit 2
Quarter of the moon	left and right edges	quarter of the lunation the day is in: 0 new to first quarter, 1 to full, 2 to last quarter, 3 back to new; bit 1 and bit 2
Day dots	centre, four dots	day 1 to 12 of the week, bits 1, 2, 4 and 8
Ankh	centre	day 13 of the week
Year-End Day	centre	one symbol (the value 15)
Leap Day	centre	four outlined circles
Carry mark	over the centre	on the Ankh, Year-End Day and Leap Day only
Sabbath mark	top	every Saturday (the civil seventh day)
Fifth-day mark	bottom	every fifth day of the year by the day of the year (Year-End Day, 365, counts)

The inter-calendar days show only the year corners, the moon quarter, the Sabbath and fifth-day marks, their centre symbol and the carry mark. The mapping from the layers of the glyph master to these roles is read from the layer names; the choices that the master does not settle are listed under LIMITATIONS.

*In the panel.* The clock in dkde-panel can show Rosquin dates; see PANEL CLOCK.

Chinese
The lunisolar calendar, computed from the Moon and the Sun (src/calendar/worldcal.zig; new moons from the Meeus series of lunar.zig, the Sun's longitude from Meeus chapter 25), in China Standard Time (UTC+8) all through. A year starts at the Chinese New Year (the second new moon after the winter solstice, with the usual rule for a leap year; 2026 starts on February 17). A month is a lunation of 29 or 30 days starting on a new moon. A year has 12 months, or 13 when it has a leap month: the first month that has no major solar term (2025 has a leap sixth month, 2023 a leap second month). The pages are the months in order, so a leap year has 13 pages and the leap month is titled "Leap Month 6". The year is shown by its stem-branch and element-animal name (2026 is "Bing-Wu, Fire Horse"; the Gregorian year it starts in is what the calendar calls its number). The result matches the new years of 2020 to 2027 and the leap months of 2023 and 2025; a new moon or a solar term within about a quarter of an hour of midnight in China could fall on the neighbouring day.

Hebrew (Jewish)
The Hebrew calendar by the molad and the four postponements (Dehiyyot), as computed by Reingold and Dershowitz. The year starts on 1 Tishri (2026-09-12 begins 5787) and has 12 months, or 13 in a leap year (5784, 5787... by the 19-year cycle: years where (7 × year + 1) mod 19 is below 7), when Adar splits into Adar I and Adar II. Heshvan and Kislev have 29 or 30 days by the length of the year. Pages run from Tishri through Elul. Each day is shown on its civil date: the Hebrew day really starts at sunset the evening before, which the grid does not show.

Coptic
12 months of 30 days and a 13th month, Pi Kogi Enavot, of 5 days (6 in a leap year, the year before a Julian leap year), counted from 284 CE. The year starts on 11 or 12 September (Gregorian). 2026-09-11 is 1 Thout 1743.

Ethiopian
The same structure as the Coptic calendar, 276 years behind it, with the months Meskerem, Tikimt, Hidar, Tahsas, Tir, Yekatit, Megabit, Miazia, Genbot, Sene, Hamle, Nehase and Pagume (5 or 6 days). 2026-09-11 is 1 Meskerem 2019, and Christmas, 29 Tahsas, is January 7.

*Native script.* Options, Show native script (view.native-script, off by default) writes the month, the day and the year of these four calendars in their own script beside the Latin names, in the page title, in the cells, and in the day panel (where each of the other calendars also gets a line):

Calendar	Native names and numerals
Chinese	the stems and branches of the year with the element and animal (丙午年 火马), the months (正月, 二月 ... 冬月, 腊月, with 闰 for a leap month), the days (初一 ... 初十, 十一 ... 二十, 廿一 ... 廿九, 三十) and the weekdays (星期日 ...)
Hebrew	the months in Hebrew (תשרי, חשוון ... אדר א׳, אדר ב׳), the day and the year as letters (gematria: כ״ו for 26, ה׳תשפ״ז for 5787) and the weekdays (יום ראשון ... שבת)
Coptic	the months in the Coptic alphabet (ⲑⲱⲟⲩⲧ, ⲡⲁⲟⲡⲓ, ϩⲁⲑⲱⲣ ...); the day and the year stay as digits
Ethiopian	the months in Ge'ez (መስከረም, ጥቅምት ...), the day and the year in Ge'ez numerals (፳፯ for 27, ፳፻፲፱ for 2019) and the weekdays (እሑድ, ሰኞ ...)

Fonts: the program carries open-source ones, so nothing needs installing: Noto Sans Hebrew, Noto Sans Ethiopic and Noto Sans Coptic (SIL Open Font License 1.1) and a subset of Droid Sans Fallback with just the Chinese characters above (Apache License 2.0); the licenses are in data/fonts/native/LICENSES.txt. To use a font of your own instead, choose it under Options, Native font (the Windows build: Options, Native font); its family name is saved as view.native-font. Options, Built-in goes back to the carried fonts. Native names only appear while one of the four calendars is chosen (Chinese, Hebrew, Coptic or Ethiopian). In the Windows build the same option is the Native script check box under the title, and Options, Native font check shows which font each script is drawn in on that PC. (The check boxes for the liturgical calendars, Named days only and Native script are in one Show drop-down in the Windows build.) Each text is drawn in the first font that has all its characters: the font you chose, then the carried font, then Windows' own (Microsoft YaHei or SimSun, Segoe UI, Segoe UI Historic, Nyala or Ebrima). Hebrew is drawn right to left. A font of your own must have the script, or the names show as boxes. The names are written by src/calendar/native.zig.

Liturgical calendars
These are overlays, independent of the calendar system, always keyed to the civil date. They are enabled in the Options menu.

Novus Ordo
: The General Roman Calendar as it is now (Roman Rite, ordinary form): solemnities, feasts and memorials, with the colour of the day. The moving days (everything that depends on Easter or Advent) are computed from Easter; the fixed days come from a text table. A fast and abstinence guide follows the Catholic rules: ⛔ fast and abstinence, 🐟 abstinence from meat, 🍽️ fast only. The guide is only that: bishops' conferences and indults change the rules.

Traditional (1962)
: The General Roman Calendar as it was in 1962 (the Traditional Latin Mass), with the 1962 ranks and seasons, and the fasts of that calendar.

Russian Orthodox
: The Old Calendar. Pascha is reckoned by the Julian rule (Meeus, Julian algorithm) and the Triodion and Pentecostarion are counted from it. The fixed feasts and saints are keyed by their Julian dates. The four fasting seasons show what food is allowed each day: ⛔ total fast, 🥣 strict fast (no meat, dairy, fish, oil or wine), 🍇 wine and oil, 🐟 fish (shown with 🍇), 🍷 wine without oil, 🧀 dairy, eggs and fish allowed (no meat).

The fixed days of each calendar are in tables built into the program (liturgy-no.txt, liturgy-1962.txt, liturgy-ru.txt). A file of the same name in the user's configuration directory replaces the built-in table.

PANEL CLOCK
The taskbar clock in dkde-panel takes a format of strftime codes (panel.clock-format). The calendar tokens below are replaced before strftime sees the format, so they can be mixed with it. Choose "Rosquin: day code and date" or "Rosquin: day code only" under Settings, Date & time, Clock style, or write the tokens in the custom format.

Token	Meaning
@D	day code (18309)
@y	day of the year, 1 to 366 (47); starts over on September 21
@Y	Rosquin year (50)
@n	month or quarter name (Gleaning); "Year" in the 28-week layout
@m	its number
@d	day of the month or quarter (47); the day's name on the inter-calendar days, where @n, @m, @w and @e are empty
@w	week of the year, 1 to 28 (empty on the two special days)
@e	day of the 13-day week, 1 to 13 (empty on the two special days)
@N	name of the day (Harrow)
@@	a literal @

panel.clock-rosquin-layout (weeks, months or quarters) says what @n, @m and @d count in; Settings has it as "Rosquin calendar". Example: clock-format = "%-I:%M %p\n@D/@y  Yr @Y  @n @d" shows "9:30 AM" over "18309/47  Yr 50  Gleaning 47". The clock redraws every minute and follows the local date.

EVENTS AND NOTES
The lunar-events table that accompanied the workbook (16965 Lunar Eventz.pdf) was made by hand and its author says it may contain errors, so the program does not use it; moon phases are computed.

New event opens the event editor: title, place, start and end dates and times (or all day), repeat (none, daily, weekly, monthly, yearly), colour, reminder and notes. A reminder is one of: none, at the start, 5, 10, 15 or 30 minutes before, 1 or 2 hours before, 1 or 2 days before, 1 week before. Events are always written with local wall-clock time and no zone arithmetic.

The Notes box under the day holds one free-text note per civil day, saved when the day changes or the window closes.

Import and Export read and write an iCalendar (.ics) file. Import merges: an event whose UID is already present replaces it, and the others are added. A file chosen for sync is read again whenever Sync now is used. Times in an imported file are converted from UTC to the local zone.

ONLINE CALENDARS
Optional. An online calendar is a private https link to an iCalendar (.ics) feed, such as Google Calendar's "Secret address in iCal format", a Nextcloud or Fastmail subscription link, or an Outlook published calendar. Its events are shown with the user's own, in the grid, the day panel and the panel's reminders, with a "From NAME" line and in the colour chosen for it. They are read-only: they have no Edit or Delete buttons, because the next update would undo the change, and they are left out of Export and of the sync file. Nothing is ever sent to the server.

Online calendars are added, switched off and removed only in dkde-settings, on the Online accounts page (Options, Online calendars… opens it). Until one is added, nothing in this section happens: no connection is made and no file is read.

Updating. The calendar updates an online calendar only (a) when Sync now is used, and (b) on start, if the calendar was set to update on start and its copy is older than the interval chosen for it. It never polls in the background and never asks the user to sign in. The download runs on its own thread, so the window stays usable, and the previous copy is kept when an update fails; the reason is shown under Sync now. The last good copy is shown while the computer is offline.

Repeats. A feed's repeating events are worked out for three years back and five years ahead of today: FREQ with INTERVAL, COUNT, UNTIL and weekly BYDAY, removed days (EXDATE), changed days (a RECURRENCE-ID entry replaces that day) and cancelled events (STATUS:CANCELLED are not shown). A repeat that is only FREQ stays a plain repeat and goes on forever. A rule of another kind (a monthly rule on "the second Tuesday", BYMONTHDAY, BYMONTH, BYSETPOS) is shown as its FREQ alone, which is only an approximation.

Limits. Times in UTC are converted to the local zone. A time with a zone name (TZID) is taken as local wall-clock time, so an event kept in another zone can be shown at the wrong hour. A feed larger than 8 MB, a link that is not https, and a reply that is not an iCalendar file are refused. Invitations, attendees and attachments are ignored. Only reading is done: there is no CalDAV, no sign-in, and a calendar that needs a password cannot be used.

INPUT
Configuration is TOML. The calendar file is calendar.toml in the user's configuration directory. Imported events are iCalendar text. Liturgical tables are line-oriented text files. A malformed configuration file is not an error for reading: the program uses the defaults and does not overwrite the file until it is fixed.

OUTPUT
Standard output
Only --help and --version write anything: the usage or version line, then exit.

Standard error
Warnings and errors go to standard error through the DKDE log. The program logs (and carries on) when a liturgical table cannot be loaded, when RosquinGlyphs.ttf is not found (Rosquin days then show as plain text) and when the configuration file has a syntax error.

EXIT STATUS
Status	Meaning
0	Normal exit, or --help or --version.
2	An unknown command-line option.
Other statuses are not defined by the program; a failure to start a GTK session is reported by GTK/GLib.

ENVIRONMENT
DKDE_DATA_DIR
: A directory searched first for the shared data (style.css, dkde.toml, calendar.toml). Used for running from a build tree.

XDG_CONFIG_HOME
: The user configuration directory; default ~/.config. The calendar file is in its dkde subdirectory.

XDG_DATA_DIRS
: The system data directories searched for dkde/; default /usr/local/share:/usr/share.

LANG, LC_ALL
: The language of the interface (strings are looked up through the DKDE translation table).

HOME, TZ
: HOME locates the default user directories. TZ decides the local clock used for reminders and for the "today" mark. It does not decide the moon-phase clock, which is the [location] timezone.

FILES
~/.config/dkde/calendar.toml
: The user's settings, events and notes. Created and replaced atomically: written to a temporary file in the same directory and renamed over the old one, under a lock file calendar.toml.lock.

/usr/share/dkde/calendar.toml
: The shipped defaults. Every key is listed in it with its default.

~/.cache/dkde/RosquinGlyphs.ttf
: The glyph font (see ROSQUIN FONT). It is built into the program and written here at every start, then registered with fontconfig for this process only, so it works wherever the program is run from and needs no installation or root. It is never installed system-wide.

/usr/share/dkde/style.css
: The shared style sheet. The glyph stamp's own style (font "Rosquin Glyphs", 88px, 64px in the 28-week layout) is set inside the program, so a missing style.css does not affect it.

~/.config/dkde/liturgy-no.txt, liturgy-1962.txt, liturgy-ru.txt
: Optional replacements for the built-in liturgical tables.

An iCalendar file of the user's choice
: Kept in sync when sync.ics-file is set.

~/.config/dkde/dkde.toml
: Holds the online calendars, as [account.ID] groups. Written by dkde-settings; the calendar only reads it. The link in it is a secret (anyone who has it can read that calendar), so keep the file private on a shared computer.

~/.cache/dkde/feeds/ID.ics
: The last downloaded copy of each online calendar. The directory is private (mode 700) and may be deleted at any time; the next update brings the copies back.

CONFIGURATION
Search paths and precedence
The system file /usr/share/dkde/calendar.toml (or the first dkde/calendar.toml in XDG_DATA_DIRS, or DKDE_DATA_DIR/calendar.toml) is read first and the user's ~/.config/dkde/calendar.toml is laid over it key by key. A key in the user file wins; a missing key falls back to the shipped default. Reads never fail: a missing key, a value of the wrong type or a malformed user file gives the default and a warning. Changes made in the window are written to the user file; a syntax error in that file blocks all writes until it is fixed. The file is watched, so edits made by hand (or by dkde-settings) show up without restarting.

Configuration format
[view]
system = "rosquin_months"
novus-ordo = true

[location]
latitude = 42.7889
longitude = -85.1417
timezone = "America/Detroit"

[sync]
ics-file = "/home/user/calendar.ics"

Configuration keys
Key	Type	Default	Description
view.system	String	gregorian	julian, gregorian, fixed, rosquin_weeks, rosquin_months or rosquin_quarters (rosquin reads as rosquin_months). Anything else reads as gregorian.
view.novus-ordo	Boolean	false	Show the Novus Ordo calendar.
view.tlm-1962	Boolean	false	Show the 1962 Roman calendar.
view.orthodox-ru	Boolean	false	Show the Russian Orthodox calendar.
view.named-days-only	Boolean	true	Show only named days in the grid.
view.twelve-hour	Boolean	true	12-hour clock.
location.latitude	Number	42.7889	Degrees north of the place the moon is seen from (Lake Odessa, Michigan).
location.longitude	Number	-85.1417	Degrees east (west is negative).
location.timezone	String	America/Detroit	IANA zone name of that place's clock, daylight saving included. Empty: local mean solar time from the longitude, rounded to a whole hour, with no daylight saving.
sync.ics-file	String	(empty)	An .ics file to read events from. Empty: none.
event:ID, notes	Groups	-	Events and notes written by the calendar. Do not edit them while the program is running.

Unknown keys are kept and ignored. Values of the wrong type are ignored with a warning.

EXAMPLES
Basic use
dkde-calendar
Opens the window on today's month in the saved system.

Starting in the Rosquin calendar
printf '[view]\nsystem = "rosquin_months"\n' >> ~/.config/dkde/calendar.toml && dkde-calendar
The first Rosquin month, Gleaning of Year 50, opens when run on 2026-11-06, with day code 18309 in today's cell.

Running from a build tree
DKDE_DATA_DIR=zig-out/share/dkde zig-out/bin/dkde-calendar
Finds the shared files, including the glyph font, in the build output.

Seeing the moon from another place
Set location.latitude, location.longitude and location.timezone in calendar.toml. A phase can fall on a different day in another zone: the full moon of 2000-01-21 04:40 UTC is January 20 in Michigan and January 21 in Europe.

DIAGNOSTICS
dkde-calendar: unknown option: OPTION
: An option the program does not take. Exit status 2.

cannot write PATH; Rosquin days will show as boxes
: The cache directory is not writable, so the glyph font could not be put where fontconfig can read it. Fix the permissions of ~/.cache/dkde. The calendar still works.

user.toml: not saving; the file has a syntax error. Fix or remove it.
: The user's calendar.toml does not parse. The defaults are used. Nothing is written until the file is fixed.

liturgical calendar not loaded: ERROR
: A user-supplied liturgical table could not be read. That overlay is not shown.

SECURITY CONSIDERATIONS
The program runs as the user with no elevated privilege. It starts one other program, and only when asked: Options, Online calendars… runs dkde-settings. An imported .ics file is parsed as data and is never run; event text is shown as text and is not interpreted as markup. The configuration file and the glyph font are read from the user's and the system's data directories; the font is parsed by fontconfig and FreeType in the process, so only install fonts from a source you trust.

Online calendars (see ONLINE CALENDARS) are the only thing that uses the network, and only after the user adds one. The program makes an https request to that link and to nothing else, sends no cookie, no account name and no event, and follows at most three redirects. Plain http links are refused, since the link is a secret. The server learns that the link was fetched, the computer's address and the program name "dkde-calendar".

PRIVACY
Unless the user adds an online calendar, nothing is sent anywhere. Events, notes and the location live in the user's calendar.toml, in the clear and readable by the user's other programs. The latitude and longitude are only used for the moon-phase clock, and are used for nothing else, but they are stored in that file. Remove [location] to stop storing them.

RESOURCE USAGE
The month grid holds 54 cells; the Rosquin glyph stacks up to 20 labels per cell. The moon phases of a month need a few hundred evaluations of the lunar series and take well under a millisecond. These are estimates, not measurements.

CONCURRENCY AND ATOMICITY
Several windows or programs may use calendar.toml at the same time. A write takes the lock file calendar.toml.lock, re-reads the file, makes the change and replaces the file by renaming a temporary file over it, so readers never see half a file. A write from another program in between is merged, not lost, because the file is re-read under the lock.

COMPATIBILITY
Platforms
Linux, with GTK 4, GLib/GIO 2, Pango and fontconfig. Built with Zig 0.17.1 or later. The dkde session is a Wayland session; the calendar itself runs on any GTK 4 display.

Standards
iCalendar (RFC 5545) for import and export of events. IANA time zone names for location.timezone. XDG Base Directory Specification. Moon phases: J. Meeus, Astronomical Algorithms, 2nd ed., ch. 49. Julian and Gregorian arithmetic as in the Julian Day Number (Fliegel-Van Flandern style) and Hinnant's civil-date algorithms. Compliance with RFC 5545 is partial: only the properties the calendar stores are written or read.

Stability guarantees
The configuration keys above are stable. The glyph encoding, the Rosquin day rules and the moon-phase API are new and may change with the calendar they describe.

LIMITATIONS
The Rosquin systems follow the workbook for the year start (September 21), the day code (day 1 is 1976-09-21), the 364-day year and the two special days. The PNG in the project folder, with Year 45 and day 16745, was a mock-up and is not followed. The names of days, months and quarters are provisional. The workbook's era letters, circled week numbers and its weight, calorie and labour tables are not part of the calendar and are not implemented.

The Rosquin glyph encoding is read from the layer names of the glyph master. The master does not say, and the program chooses: the leap-cycle position is Year mod 4 (so Year 51, which holds the leap day of 2028, is shown as 3); weeks of a month and quarters are written 0 to 3; the Sabbath mark is every civil Saturday; and the fifth-day mark uses the day of the year. If these are not what the author meant, change src/calendar/rosstamp.zig; nothing else depends on them.

The moon phases are those of the Moon's centre as seen from the whole Earth. They are not topocentric: the observer's position shifts the instant by no more than a few minutes, which is invisible at the resolution of a day. A phase that falls within about two minutes of local midnight may be placed on the neighbouring day. Phases for dates far from the present era are less exact.

The Fixed calendar uses the Gregorian leap rule. The Julian and Gregorian calendars are proleptic, with no year 0 adjustment beyond the astronomical one.

The glyph is dense at the small stamp size and its detail is hard to read on a low-resolution screen; use the tooltip, or raise the size in installGlyphStyle() in src/calendar/main.zig (88px; 64px in the 28-week layout; set in the program).

BUGS
Report defects on the project's issue tracker. Include dkde-calendar --version, the calendar system in use, the date involved, and the relevant lines (without personal event text) of calendar.toml.

TROUBLESHOOTING
Program fails to start
Run it from a terminal and read standard error. Check that a Wayland or X display is available and that the shared data directory is found (set DKDE_DATA_DIR when running from a build tree).

Rosquin days show as numbers or boxes
The glyph font could not be written or loaded. The program writes it to ~/.cache/dkde/RosquinGlyphs.ttf before GTK starts; check that the file exists and run fc-scan on it (the family name is "Rosquin Glyphs").

A moon phase is one day off
The phase belongs to the local day at location.timezone. Check that latitude, longitude and timezone are those of the place you mean. With an empty timezone the clock is the longitude's mean solar time without daylight saving.

The calendar system or settings do not stick
Look for a syntax error in ~/.config/dkde/calendar.toml. While there is one nothing is saved.

NOTES
The calendar app has no knowledge of other programs. The panel reads the same calendar.toml to send reminders, and dkde-settings edits its keys. The Rosquin rules are in the shared library (common/rosquin.zig), not in the calendar, so the panel's clock does not depend on the calendar program.

The Rosquin day code is the day count of the Rosquin workbook: day 1 is 1976-09-21.

CAVEATS
Switching the calendar system changes only how days are numbered and grouped. In Rosquin the first day of a page is not the first of any Gregorian month, and the page changes on its own schedule (month 1 begins on September 21). Do not edit the [event:...] groups of calendar.toml by hand while the calendar is open.

HISTORY
The calendar began with the Gregorian and Julian systems and the Roman and Orthodox liturgical overlays. The Fixed calendar and iCalendar import and export followed. Version 0.0.4 and the following work added the Rosquin calendar: the 13-day week in three layouts, the September year, the day code, the glyph font, the computed moon phases for Lake Odessa, Michigan, and the Rosquin date in the panel clock.

SEE ALSO
dkde-panel(1), dkde-settings(1), dkde(7), fc-scan(1), calendar.toml(5)

Source files: src/calendar/calsys.zig (the calendar systems), src/common/rosquin.zig (the Rosquin rules and names), src/calendar/lunar.zig (the moon), src/calendar/rosstamp.zig (the glyph), scripts/build-rosquin-font.py (builds the font), docs/architecture.md.

AUTHOR
DKDE contributors.

COPYRIGHT
Copyright 2026 DKDE contributors. SPDX-License-Identifier: see LICENSE.

LICENSE
See the LICENSE file at the top of the source tree for the applicable license and its complete text.

WINDOWS
The whole calendar is also built for Windows as one executable, rosquin-calendar.exe, with `zig build wincal` (any host; zig-out/bin/rosquin-calendar.exe, under a megabyte). It is a 64-bit program with no GTK, no runtime and no installer; the glyph font, the branding picture, the liturgical tables and the default settings are built in. It draws with Win32 and GDI and shares the calendar rules with dkde-calendar (calsys.zig, lunar.zig, rosstamp.zig, liturgy.zig, orthodox.zig, fasting.zig, common/rosquin.zig, events.zig, ics.zig and config.zig).

*Settings.* On the first run it writes %APPDATA%\\dkde\\calendar.toml (for example C:\\Users\\NAME\\AppData\\Roaming\\dkde\\calendar.toml), the usual Windows place for a program's settings, from the same defaults and with the same keys and the same event and note groups as the Linux calendar's ~/.config/dkde/calendar.toml; a file can be copied from one to the other. Options, Where are my settings? shows the exact path. Changes are written as they are made (the calendar chosen, the liturgical calendars, named days only, the 12-hour clock, the sync file, every event and every note), by writing a temporary file and renaming it, so a crash cannot leave half a file. There is no file lock and no change watcher on Windows: edit the file while the program is closed.

*What it has.* Everything dkde-calendar has: the month grid in the six calendar systems (a selector button under the title, and the Calendar menu), the Rosquin glyphs, day codes and days of the year, the inter-calendar days in the 14th column, the orange day 13, the branding picture, moon phases, the three liturgical calendars (check boxes under the title), Go to (Ctrl+G), Copy date (right-click a day, the Copy date button, Edit, Ctrl+C), events, a note for every day, import and export of .ics files, a file kept in sync, and reminders.

Events: New event (the button, File, or Ctrl+N), or Edit and Del beside an event in the side panel. The event window has the title, the place, the first and last date (2026-11-06), All day, the start and end time (09:00), Repeat, Reminder, Colour and Notes. Notes: the box at the bottom of the side panel holds the note of the selected day and is saved a moment after typing and when another day is selected. File: Import calendar file merges an .ics file (an event with a UID already here is replaced), Export calendar writes all events to an .ics file, Choose sync file picks a file that is read and rewritten by Sync now, and Save the Rosquin font writes RosquinGlyphs.ttf where you choose (see ROSQUIN FONT).

*Reminders.* There is no panel on Windows, so the program shows its reminders itself, in a message box on top of the other windows, while it is running; it checks every 15 seconds. A reminder that falls due while the program is closed is not shown later.

*Moon phases.* Dated in the PC's own time zone (daylight saving included), for Lake Odessa, Michigan; the latitude and longitude are not used for any other calculation.

*Default view.* As in the Linux program, changing the calendar or the liturgical calendars on screen is temporary. The Save as default button (also File, Save this view as the default) writes them to the settings file; it is greyed while the view on screen is the saved one.

*Window.* The window opens no bigger than the screen's work area, and a grid that does not fit scrolls with scroll bars, the mouse wheel and the keys.

*Limits.* The liturgical tables cannot be replaced by files on Windows. Settings cannot be changed in another program while it is open. It was checked under Wine; it has not been run on a Windows machine. Under Wine the emoji and the ankh sign in the heading draw as boxes because Wine lacks those fonts.

AVAILABILITY
Source code: the DKDE source tree (this repository).

VERSION
This manual describes dkde-calendar version 0.0.4.
