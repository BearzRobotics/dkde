//! The Learn view of dkde-calc: lessons you step through while the Geometry pane (or any other pane)
//! stays open beside it. Today these are Euclid's Elements (euclid.zig): each lesson states what is to
//! be done in Euclid's words, then walks through it one step at a time, drawing each step on the
//! canvas in colour, with the reason it works at the end.

const std = @import("std");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

const figure = @import("figure.zig");
const lessonfile = @import("lessonfile.zig");
const eval = @import("eval.zig");
const steps_mod = @import("steps.zig");
const mathview = @import("mathview.zig");

const t = common.tr;

pub const Hooks = struct {
    ctx: *anyopaque,
    /// Draw these operations on the Geometry canvas.
    run: *const fn (ctx: *anyopaque, ops: []const figure.Op) void,
    /// Empty the canvas.
    clear: *const fn (ctx: *anyopaque) void,
    /// Make sure the Geometry pane is showing.
    show_canvas: *const fn (ctx: *anyopaque) void,
    /// Put this line in the calculator's entry.
    use_calc: *const fn (ctx: *anyopaque, text: []const u8) void,
    /// Show the Graph pane with these expressions plotted (replacing what was there).
    graph: *const fn (ctx: *anyopaque, exprs: []const []const u8) void,
    /// A step asks for a calculator mode, base and word size (0 keeps the current one).
    set_mode: *const fn (ctx: *anyopaque, mode: []const u8, base: u8, bits: u8) void,
    /// Move the Learn view into a window of its own, or back beside the calculator.
    toggle_window: *const fn (ctx: *anyopaque) void,
    /// The lessons are listed and the view is filled in (the window may need to grow to fit it).
    loaded: *const fn (ctx: *anyopaque) void,
};

const Group = struct { course: []const u8, book: u8 };

pub const Learn = struct {
    gpa: std.mem.Allocator,
    hooks: Hooks,
    /// The lessons (read from the lesson files) and what was wrong with the files that were left out.
    loaded: lessonfile.Loaded,
    lessons: []const figure.Lesson,
    root: *gtk.Box,
    /// "Loading lessons..." shows here while the lessons are read; the rest of the view is `content`.
    loading: *gtk.Box,
    content: *gtk.Box,
    names: *gtk.StringList,
    refresh_button: *gtk.Button,
    /// start() was called before the lessons were ready.
    want_start: bool = false,
    books: *gtk.DropDown,
    list: *gtk.ListBox,
    title: *gtk.Label,
    statement: *gtk.Label,
    steps_box: *gtk.Box,
    proof: *gtk.Label,
    back: *gtk.Button,
    next: *gtk.Button,
    all: *gtk.Button,
    /// The lessons listed now (indexes into self.lessons), and the groups (course and book) in the dropdown.
    listed: std.ArrayList(usize) = .empty,
    groups: std.ArrayList(Group) = .empty,
    /// Where exercise answers and written-out solutions are worked (a session of its own).
    session: eval.Session,
    exercise_box: *gtk.Box,
    current: ?usize = null,
    /// How many steps are shown.
    shown: usize = 0,
    /// False while the view is being built: choosing the first row must not draw yet.
    ready: bool = false,

    /// The folders lessons are read from: DKDE_LEARN_DIR, else the installed data, and always your own
    /// in ~/.local/share/dkde/learn.
    pub fn lessonDirs(gpa: std.mem.Allocator, out: *std.ArrayList([]const u8)) void {
        if (std.c.getenv("DKDE_LEARN_DIR")) |d| {
            out.append(gpa, gpa.dupe(u8, std.mem.span(d)) catch return) catch {};
            return;
        }
        if (common.paths.systemDataFile(gpa, "learn") catch null) |found| {
            defer gpa.free(found);
            out.append(gpa, gpa.dupe(u8, found) catch return) catch {};
        }
        const user = std.fmt.allocPrint(gpa, "{s}/dkde/learn", .{std.mem.span(@import("glib2").getUserDataDir())}) catch return;
        out.append(gpa, user) catch {};
    }

    pub fn create(gpa: std.mem.Allocator, hooks: Hooks) !*Learn {
        const self = try gpa.create(Learn);
        // The courses and books that have lessons, in teaching order, are filled in when the lessons are read.
        const names = gtk.StringList.new(null);
        self.* = .{
            .gpa = gpa,
            .hooks = hooks,
            .loaded = .{ .arena = std.heap.ArenaAllocator.init(gpa) },
            .lessons = &.{},
            .root = gtk.Box.new(.vertical, 6),
            .loading = gtk.Box.new(.horizontal, 8),
            .content = gtk.Box.new(.vertical, 6),
            .names = names,
            .refresh_button = gtk.Button.newFromIconName("view-refresh-symbolic"),
            .books = gtk.DropDown.new(names.as(@import("gio2").ListModel), null),
            .list = gtk.ListBox.new(),
            .title = gtk.Label.new(""),
            .statement = gtk.Label.new(""),
            .steps_box = gtk.Box.new(.vertical, 6),
            .proof = gtk.Label.new(""),
            .back = gtk.Button.newWithLabel(t("◀ Back")),
            .next = gtk.Button.newWithLabel(t("Next step ▶")),
            .all = gtk.Button.newWithLabel(t("Show all")),
            .session = .{ .gpa = gpa },
            .exercise_box = gtk.Box.new(.vertical, 6),
        };

        const heading = gtk.Label.new(t("Learn"));
        heading.setXalign(0);
        heading.as(gtk.Widget).setHexpand(1);
        heading.as(gtk.Widget).addCssClass("heading");
        const top = gtk.Box.new(.horizontal, 6);
        top.append(heading.as(gtk.Widget));
        self.refresh_button.as(gtk.Widget).setTooltipText(t("Refresh lessons (after adding lesson files of your own)"));
        self.refresh_button.as(gtk.Widget).addCssClass("flat");
        _ = gtk.Button.signals.clicked.connect(self.refresh_button, *Learn, &onRefresh, self, .{});
        top.append(self.refresh_button.as(gtk.Widget));
        const pop = gtk.Button.newFromIconName("window-new-symbolic");
        pop.as(gtk.Widget).setTooltipText(t("Open Learn in its own window, or put it back"));
        pop.as(gtk.Widget).addCssClass("flat");
        _ = gtk.Button.signals.clicked.connect(pop, *Learn, &onPop, self, .{});
        top.append(pop.as(gtk.Widget));
        self.root.append(top.as(gtk.Widget));
        const spinner = gtk.Spinner.new();
        spinner.start();
        self.loading.append(spinner.as(gtk.Widget));
        self.loading.append(gtk.Label.new(t("Loading lessons...")).as(gtk.Widget));
        self.loading.as(gtk.Widget).setMarginTop(12);
        self.root.append(self.loading.as(gtk.Widget));
        self.content.as(gtk.Widget).setVisible(0);
        self.content.as(gtk.Widget).setVexpand(1);
        self.root.append(self.content.as(gtk.Widget));
        self.content.append(self.books.as(gtk.Widget));
        _ = gobject.Object.signals.notify.connect(self.books, *Learn, &onBook, self, .{ .detail = "selected" });

        self.list.setSelectionMode(.browse);
        _ = gtk.ListBox.signals.row_selected.connect(self.list, *Learn, &onRow, self, .{});
        const list_scroll = gtk.ScrolledWindow.new();
        list_scroll.setChild(self.list.as(gtk.Widget));
        list_scroll.setMinContentHeight(150);
        list_scroll.setMaxContentHeight(300);
        list_scroll.setPolicy(.never, .automatic);
        self.content.append(list_scroll.as(gtk.Widget));

        self.title.setXalign(0);
        self.title.setWrap(1);
        self.title.setMaxWidthChars(40);
        self.title.as(gtk.Widget).addCssClass("heading");
        self.content.append(self.title.as(gtk.Widget));
        self.statement.setXalign(0);
        self.statement.setWrap(1);
        self.statement.setMaxWidthChars(40);
        self.statement.setSelectable(1);
        self.statement.as(gtk.Widget).addCssClass("dim-label");
        self.content.append(self.statement.as(gtk.Widget));

        const steps_scroll = gtk.ScrolledWindow.new();
        steps_scroll.setChild(self.steps_box.as(gtk.Widget));
        steps_scroll.setMinContentHeight(160);
        steps_scroll.as(gtk.Widget).setVexpand(1);
        steps_scroll.setPolicy(.never, .automatic);
        self.content.append(steps_scroll.as(gtk.Widget));

        const buttons = gtk.Box.new(.horizontal, 6);
        _ = gtk.Button.signals.clicked.connect(self.back, *Learn, &onBack, self, .{});
        _ = gtk.Button.signals.clicked.connect(self.next, *Learn, &onNext, self, .{});
        _ = gtk.Button.signals.clicked.connect(self.all, *Learn, &onAll, self, .{});
        self.next.as(gtk.Widget).addCssClass("suggested-action");
        buttons.append(self.back.as(gtk.Widget));
        buttons.append(self.next.as(gtk.Widget));
        buttons.append(self.all.as(gtk.Widget));
        self.content.append(buttons.as(gtk.Widget));

        self.proof.setXalign(0);
        self.proof.setWrap(1);
        self.proof.setMaxWidthChars(40);
        self.proof.as(gtk.Widget).setVisible(0);
        self.content.append(self.proof.as(gtk.Widget));

        self.exercise_box.as(gtk.Widget).setVisible(0);
        self.content.append(self.exercise_box.as(gtk.Widget));

        self.beginLoad(false);
        return self;
    }

    /// Called when the view is shown: draws the lesson that is selected (dev aid: DKDE_LEARN_LESSON=I.1
    /// opens that lesson, DKDE_LEARN_STEPS=n shows n steps).
    pub fn start(self: *Learn) void {
        if (!self.ready) {
            self.want_start = true;
            return;
        }
        if (std.c.getenv("DKDE_LEARN_LESSON")) |want_z| {
            const want = std.mem.span(want_z);
            for (self.lessons, 0..) |lesson, i| if (std.mem.eql(u8, lesson.id, want)) {
                for (self.groups.items, 0..) |g, gi| {
                    if (g.book == lesson.book and std.mem.eql(u8, g.course, lesson.course)) self.books.setSelected(@intCast(gi));
                }
                self.open(i);
                if (std.c.getenv("DKDE_LEARN_STEPS")) |n| self.replay(std.fmt.parseInt(usize, std.mem.span(n), 10) catch 1);
                return;
            };
        }
        if (self.current == null) {
            if (self.list.getSelectedRow()) |row| {
                const index: usize = @intCast(row.getIndex());
                if (index < self.listed.items.len) self.open(self.listed.items[index]);
            }
        }
    }

    pub fn widget(self: *Learn) *gtk.Widget {
        return self.root.as(gtk.Widget);
    }

    pub fn destroy(self: *Learn) void {
        self.listed.deinit(self.gpa);
        self.groups.deinit(self.gpa);
        self.session.deinit();
        self.loaded.deinit();
        self.gpa.destroy(self);
    }

    /// Lesson `i`, read from its file first when it came from the index.
    fn lessonAt(self: *Learn, i: usize) figure.Lesson {
        lessonfile.ensureFull(&self.loaded, common.fsio.io(), i);
        return self.loaded.lessons[i];
    }

    const Job = struct {
        learn: *Learn,
        dirs: []const []const u8,
        cache: []const u8,
        force: bool,
        result: lessonfile.Loaded = undefined,
    };

    fn cachePath(a: std.mem.Allocator) ?[]u8 {
        return std.fmt.allocPrint(a, "{s}/dkde/calc-learn-index", .{std.mem.span(@import("glib2").getUserCacheDir())}) catch null;
    }

    /// Reads the lessons on a thread (from the index when there is one, else from every file, and writes the
    /// index), with "Loading lessons..." showing meanwhile.
    fn beginLoad(self: *Learn, force: bool) void {
        const a = std.heap.c_allocator;
        self.ready = false;
        self.loading.as(gtk.Widget).setVisible(1);
        self.content.as(gtk.Widget).setVisible(0);
        self.refresh_button.as(gtk.Widget).setSensitive(0);
        const job = a.create(Job) catch return;
        var dirs: std.ArrayList([]const u8) = .empty;
        lessonDirs(a, &dirs);
        job.* = .{ .learn = self, .dirs = dirs.items, .cache = if (std.c.getenv("DKDE_LEARN_DIR") != null) "" else (cachePath(a) orelse ""), .force = force };
        const thread = std.Thread.spawn(.{}, loadThread, .{job}) catch {
            // No thread: read them here (the message does not show, but it works).
            loadThread(job);
            return;
        };
        thread.detach();
    }

    fn loadThread(job: *Job) void {
        const a = std.heap.c_allocator;
        const io = common.fsio.io();
        const version = @import("build_options").version;
        if (!job.force and job.cache.len > 0) {
            if (lessonfile.loadIndex(a, io, job.cache, version)) |l| {
                job.result = l;
                _ = @import("glib2").idleAdd(finishIdle, job);
                return;
            }
        }
        job.result = lessonfile.load(a, io, job.dirs);
        if (job.cache.len > 0) lessonfile.writeIndex(a, io, job.cache, version, &job.result);
        _ = @import("glib2").idleAdd(finishIdle, job);
    }

    fn finishIdle(data: ?*anyopaque) callconv(.c) c_int {
        const job: *Job = @ptrCast(@alignCast(data.?));
        const a = std.heap.c_allocator;
        job.learn.finish(job.result);
        for (job.dirs) |d| a.free(d);
        a.free(job.dirs);
        if (job.cache.len > 0) a.free(job.cache);
        a.destroy(job);
        return 0; // G_SOURCE_REMOVE
    }

    /// The lessons are read: list them and show the view.
    fn finish(self: *Learn, loaded: lessonfile.Loaded) void {
        self.loaded.deinit();
        self.loaded = loaded;
        self.lessons = self.loaded.lessons;
        for (self.loaded.problems) |p| std.log.warn("lesson: {s}", .{p});
        self.current = null;
        self.shown = 0;
        self.groups.clearRetainingCapacity();
        self.names.splice(0, self.names.as(@import("gio2").ListModel).getNItems(), null);
        for (self.lessons) |l| {
            var seen = false;
            for (self.groups.items) |g| {
                if (g.book == l.book and std.mem.eql(u8, g.course, l.course)) seen = true;
            }
            if (seen) continue;
            self.groups.append(self.gpa, .{ .course = l.course, .book = l.book }) catch continue;
            var z: [96]u8 = undefined;
            const euclid = std.mem.eql(u8, l.course, "Euclid");
            const zt = (if (euclid and l.book == 0) std.fmt.bufPrintSentinel(&z, "Euclid: Foundations", .{}, 0) else if (euclid) std.fmt.bufPrintSentinel(&z, "Euclid: Book {s}", .{roman(l.book)}, 0) else if (unitName(l.course, l.book)) |u| std.fmt.bufPrintSentinel(&z, "{s}: {s}", .{ l.course, u }, 0) else if (l.book <= 1) std.fmt.bufPrintSentinel(&z, "{s}", .{l.course}, 0) else std.fmt.bufPrintSentinel(&z, "{s}: unit {d}", .{ l.course, l.book }, 0)) catch "Lessons";
            self.names.append(zt);
        }
        self.books.setSelected(0);
        self.fillList();
        self.ready = true;
        self.loading.as(gtk.Widget).setVisible(0);
        self.content.as(gtk.Widget).setVisible(1);
        self.refresh_button.as(gtk.Widget).setSensitive(1);
        self.hooks.loaded(self.hooks.ctx);
        if (self.want_start) {
            self.want_start = false;
            self.start();
        }
    }

    fn onPop(_: *gtk.Button, self: *Learn) callconv(.c) void {
        // Not now: the button being clicked is about to move to another window, so wait until the click is done.
        _ = @import("glib2").idleAdd(popIdle, self);
    }

    fn popIdle(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Learn = @ptrCast(@alignCast(data.?));
        self.hooks.toggle_window(self.hooks.ctx);
        return 0; // G_SOURCE_REMOVE
    }

    fn onRefresh(_: *gtk.Button, self: *Learn) callconv(.c) void {
        self.want_start = true;
        self.beginLoad(true);
    }

    /// What a unit (book) of a course is about, for the dropdown.
    fn unitName(course: []const u8, book: u8) ?[]const u8 {
        const Unit = struct { []const u8, u8, []const u8 };
        const units = [_]Unit{
            .{ "Arithmetic", 1, "whole numbers and fractions" },
            .{ "Arithmetic", 2, "decimals, ratios and averages" },
            .{ "Arithmetic", 3, "powers and roots" },
            .{ "Algebra", 1, "equations and factoring" },
            .{ "Algebra", 2, "functions and logarithms" },
            .{ "Trigonometry", 1, "right triangles" },
            .{ "Calculus", 1, "limits and derivatives" },
            .{ "Calculus", 2, "integrals and series" },
            .{ "Linear Algebra", 1, "vectors and matrices" },
            .{ "Linear Algebra", 2, "eigenvalues" },
            .{ "Computing", 1, "number bases" },
            .{ "Computing", 2, "binary arithmetic and bits" },
            .{ "Computing", 3, "sizes, limits and logarithms" },
            .{ "Computing", 4, "data and encodings" },
            .{ "Computing", 5, "logic and floating point" },
            .{ "Computer Science", 1, "hashing, bits and checks" },
            .{ "Computer Science", 2, "graphics maths and random numbers" },
            .{ "Computer Science", 3, "information, precision and cryptography" },
            .{ "Computer Science", 4, "algorithms and counting" },
            .{ "Computer Science", 5, "logic and hardware" },
            .{ "Computer Science", 6, "formats and text encoding" },
            .{ "Computer Science", 7, "memory and networks" },
            .{ "Computer Science", 8, "complexity" },
            .{ "Computer Science", 9, "probability for systems" },
            .{ "Computer Science", 10, "patterns and passwords" },
            .{ "Computer Science", 11, "cryptography" },
            .{ "Computer Science", 12, "linear algebra in practice" },
            .{ "Networking", 1, "addressing" },
            .{ "Networking", 2, "delay, throughput and loss" },
            .{ "Networking", 3, "signals and frames" },
            .{ "Networking", 4, "reliability" },
        };
        for (units) |u| if (u[1] == book and std.mem.eql(u8, u[0], course)) return u[2];
        return null;
    }

    fn roman(n: u8) []const u8 {
        const table = [_][]const u8{ "", "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X", "XI", "XII", "XIII" };
        return if (n < table.len) table[n] else "?";
    }

    fn onBook(_: *gtk.DropDown, _: *gobject.ParamSpec, self: *Learn) callconv(.c) void {
        if (!self.ready) return;
        self.fillList();
    }

    fn fillList(self: *Learn) void {
        while (self.list.as(gtk.Widget).getFirstChild()) |c| self.list.remove(c);
        self.listed.clearRetainingCapacity();
        const sel = self.books.getSelected();
        if (sel >= self.groups.items.len) return;
        const group = self.groups.items[sel];
        for (self.lessons, 0..) |l, i| {
            if (l.book != group.book or !std.mem.eql(u8, l.course, group.course)) continue;
            self.listed.append(self.gpa, i) catch continue;
            var buf: [200]u8 = undefined;
            const text = std.fmt.bufPrintSentinel(&buf, "{s}   {s}", .{ l.id, l.title }, 0) catch continue;
            const label = gtk.Label.new(text);
            label.setXalign(0);
            label.setEllipsize(.end);
            // Under the title, one line on what the lesson covers.
            const row = gtk.Box.new(.vertical, 1);
            row.as(gtk.Widget).setMarginTop(4);
            row.as(gtk.Widget).setMarginBottom(4);
            row.append(label.as(gtk.Widget));
            if (l.statement.len > 0) {
                var sb: [400]u8 = undefined;
                const st = std.fmt.bufPrintSentinel(&sb, "{s}", .{l.statement}, 0) catch "";
                const about = gtk.Label.new(st);
                about.setXalign(0);
                about.setEllipsize(.end);
                about.setMaxWidthChars(34);
                about.as(gtk.Widget).addCssClass("dim-label");
                about.as(gtk.Widget).addCssClass("caption");
                row.append(about.as(gtk.Widget));
                row.as(gtk.Widget).setTooltipText(st);
            }
            self.list.append(row.as(gtk.Widget));
        }
        if (self.list.getRowAtIndex(0)) |first| self.list.selectRow(first);
    }

    fn onRow(_: *gtk.ListBox, row: ?*gtk.ListBoxRow, self: *Learn) callconv(.c) void {
        if (!self.ready) return;
        const r = row orelse return;
        const index: usize = @intCast(r.getIndex());
        if (index >= self.listed.items.len) return;
        self.open(self.listed.items[index]);
    }

    /// Starts a lesson: its first step (the given figure) is drawn at once.
    fn open(self: *Learn, lesson: usize) void {
        self.current = lesson;
        self.replay(1);
    }

    /// Draws the first `count` steps from an empty canvas.
    fn replay(self: *Learn, count: usize) void {
        const lesson = self.lessonAt(self.current orelse return);
        self.hooks.clear(self.hooks.ctx);
        const n = @min(count, lesson.steps.len);
        var drawn = false;
        for (lesson.steps[0..n]) |step| {
            if (step.ops.len > 0) drawn = true;
            self.hooks.run(self.hooks.ctx, step.ops);
        }
        if (drawn) self.hooks.show_canvas(self.hooks.ctx);
        self.shown = n;
        if (n > 0) self.showGraph(lesson.steps[n - 1]);
        self.refresh();
    }

    fn showGraph(self: *Learn, step: figure.Step) void {
        if (step.graph.len > 0) self.hooks.graph(self.hooks.ctx, step.graph);
        if (step.mode.len > 0 or step.base != 0 or step.bits != 0) self.hooks.set_mode(self.hooks.ctx, step.mode, step.base, step.bits);
    }

    fn refresh(self: *Learn) void {
        const lesson = self.lessonAt(self.current orelse return);
        var buf: [400]u8 = undefined;
        self.title.setText(std.fmt.bufPrintSentinel(&buf, "{s}  {s}", .{ lesson.id, lesson.title }, 0) catch "");
        var sbuf: [2048]u8 = undefined;
        self.statement.setText(std.fmt.bufPrintSentinel(&sbuf, "{s}", .{lesson.statement}, 0) catch "");
        while (self.steps_box.as(gtk.Widget).getFirstChild()) |c| self.steps_box.remove(c);
        for (lesson.steps, 0..) |step, i| {
            if (i >= self.shown) break;
            var tb: [2048]u8 = undefined;
            // Euclid's own numbers are in the foundations' text; the propositions' steps are numbered here.
            const text = (if (lesson.book == 0) std.fmt.bufPrintSentinel(&tb, "{s}", .{step.text}, 0) else std.fmt.bufPrintSentinel(&tb, "{d}.  {s}", .{ i + 1, step.text }, 0)) catch continue;
            const label = gtk.Label.new(text);
            label.setXalign(0);
            label.setWrap(1);
            label.setMaxWidthChars(40);
            label.setSelectable(1);
            if (i + 1 != self.shown) label.as(gtk.Widget).addCssClass("dim-label");
            self.steps_box.append(label.as(gtk.Widget));
            // Calculator lines of the step: a click puts one in the entry.
            for (step.calc) |line| {
                var cb: [300]u8 = undefined;
                const shown = std.fmt.bufPrintSentinel(&cb, "\u{25B8} {s}", .{line}, 0) catch continue;
                const b = gtk.Button.newWithLabel(shown);
                b.setHasFrame(0);
                if (b.getChild()) |child| {
                    const lb: *gtk.Label = @ptrCast(child);
                    lb.setXalign(0);
                }
                b.as(gtk.Widget).setTooltipText(t("Put this in the calculator"));
                const ctx = std.heap.c_allocator.create(CalcLine) catch continue;
                ctx.* = .{ .learn = self, .text = line };
                _ = gtk.Button.signals.clicked.connect(b, *CalcLine, &onCalcLine, ctx, .{});
                _ = gtk.Widget.signals.destroy.connect(b, *CalcLine, &onCalcLineDestroy, ctx, .{});
                self.steps_box.append(b.as(gtk.Widget));
            }
            for (step.work) |line| self.addWork(line);
        }
        const done = self.shown >= lesson.steps.len;
        self.next.as(gtk.Widget).setSensitive(@intFromBool(!done));
        self.all.as(gtk.Widget).setSensitive(@intFromBool(!done));
        self.back.as(gtk.Widget).setSensitive(@intFromBool(self.shown > 1));
        if (done and lesson.proof.len > 0) {
            var pb: [2048]u8 = undefined;
            self.proof.setText(std.fmt.bufPrintSentinel(&pb, "{s}", .{lesson.proof}, 0) catch "");
            self.proof.as(gtk.Widget).setVisible(1);
        } else self.proof.as(gtk.Widget).setVisible(0);
        self.fillExercises(lesson, done);
    }

    /// The written-out solution of one entry: each step with what was done and the line after it.
    fn addWork(self: *Learn, line: []const u8) void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const got = steps_mod.explain(.{ .a = arena.allocator(), .session = &self.session, .mode = .{} }, line) catch null;
        const list = got orelse return;
        const head = gtk.Label.new(t("By hand"));
        head.setXalign(0);
        head.as(gtk.Widget).addCssClass("heading");
        self.steps_box.append(head.as(gtk.Widget));
        for (list, 0..) |st, n| {
            var nb: [1024]u8 = undefined;
            const note = std.fmt.bufPrintSentinel(&nb, "{d}. {s}", .{ n + 1, st.note }, 0) catch continue;
            const nl = gtk.Label.new(note);
            nl.setXalign(0);
            nl.setWrap(1);
            nl.setMaxWidthChars(40);
            self.steps_box.append(nl.as(gtk.Widget));
            if (mathview.MathView.create(std.heap.c_allocator, st.math, null)) |w| {
                w.setMarginStart(18);
                self.steps_box.append(w);
            } else {
                var mb: [1024]u8 = undefined;
                const ml = gtk.Label.new(std.fmt.bufPrintSentinel(&mb, "{s}", .{st.math}, 0) catch "");
                ml.setXalign(0);
                ml.as(gtk.Widget).setMarginStart(18);
                ml.setSelectable(1);
                self.steps_box.append(ml.as(gtk.Widget));
            }
        }
    }

    const Exercise = struct {
        learn: *Learn,
        ex: figure.Exercise,
        entry: *gtk.Entry,
        verdict: *gtk.Label,
    };

    fn fillExercises(self: *Learn, lesson: figure.Lesson, done: bool) void {
        while (self.exercise_box.as(gtk.Widget).getFirstChild()) |c| self.exercise_box.remove(c);
        const show = done and lesson.exercises.len > 0;
        self.exercise_box.as(gtk.Widget).setVisible(@intFromBool(show));
        if (!show) return;
        const head = gtk.Label.new(t("Practice"));
        head.setXalign(0);
        head.as(gtk.Widget).addCssClass("heading");
        self.exercise_box.append(head.as(gtk.Widget));
        for (lesson.exercises) |ex| {
            var pb: [1024]u8 = undefined;
            const prompt = gtk.Label.new(std.fmt.bufPrintSentinel(&pb, "{s}", .{ex.prompt}, 0) catch "");
            prompt.setXalign(0);
            prompt.setWrap(1);
            prompt.setMaxWidthChars(40);
            self.exercise_box.append(prompt.as(gtk.Widget));
            const row = gtk.Box.new(.horizontal, 6);
            const entry = gtk.Entry.new();
            entry.as(gtk.Widget).setHexpand(1);
            entry.setPlaceholderText(t("Your answer"));
            const check = gtk.Button.newWithLabel(t("Check"));
            const hint = gtk.Button.newWithLabel(t("Hint"));
            row.append(entry.as(gtk.Widget));
            row.append(check.as(gtk.Widget));
            if (ex.hint.len > 0) row.append(hint.as(gtk.Widget));
            self.exercise_box.append(row.as(gtk.Widget));
            const verdict = gtk.Label.new("");
            verdict.setXalign(0);
            verdict.setWrap(1);
            verdict.setMaxWidthChars(40);
            self.exercise_box.append(verdict.as(gtk.Widget));
            const ctx = std.heap.c_allocator.create(Exercise) catch continue;
            ctx.* = .{ .learn = self, .ex = ex, .entry = entry, .verdict = verdict };
            _ = gtk.Button.signals.clicked.connect(check, *Exercise, &onCheck, ctx, .{});
            _ = gtk.Entry.signals.activate.connect(entry, *Exercise, &onActivate, ctx, .{});
            _ = gtk.Button.signals.clicked.connect(hint, *Exercise, &onHint, ctx, .{});
            _ = gtk.Widget.signals.destroy.connect(check, *Exercise, &onExerciseDestroy, ctx, .{});
        }
    }

    fn onExerciseDestroy(_: *gtk.Button, ctx: *Exercise) callconv(.c) void {
        std.heap.c_allocator.destroy(ctx);
    }

    fn onHint(_: *gtk.Button, ctx: *Exercise) callconv(.c) void {
        var b: [1024]u8 = undefined;
        ctx.verdict.setText(std.fmt.bufPrintSentinel(&b, "{s}", .{ctx.ex.hint}, 0) catch "");
    }

    fn onActivate(_: *gtk.Entry, ctx: *Exercise) callconv(.c) void {
        ctx.learn.grade(ctx);
    }

    fn onCheck(_: *gtk.Button, ctx: *Exercise) callconv(.c) void {
        ctx.learn.grade(ctx);
    }

    /// The text of what an entry works out to, for comparing an answer with the right one.
    fn valueText(self: *Learn, a: std.mem.Allocator, text: []const u8) ?[]const u8 {
        var p: eval.Problem = .{};
        var sess: eval.Session = .{ .gpa = self.gpa };
        defer sess.deinit();
        const out = eval.run(a, &sess, text, .{}, &p) catch return null;
        const n = eval.plainValue(out) orelse return null;
        return steps_mod.numText(a, n) catch null;
    }

    fn grade(self: *Learn, ctx: *Exercise) void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const given = std.mem.span(ctx.entry.as(gtk.Editable).getText());
        if (given.len == 0) return;
        const want = self.valueText(a, ctx.ex.answer) orelse return;
        const got = self.valueText(a, given);
        var b: [512]u8 = undefined;
        if (got) |g| {
            if (std.mem.eql(u8, g, want)) {
                ctx.verdict.setText(t("Right."));
                return;
            }
        }
        ctx.verdict.setText(if (got == null) t("That is not a number or sum the calculator can read.") else (std.fmt.bufPrintSentinel(&b, "Not quite. Try again, or press Hint.", .{}, 0) catch ""));
    }

    const CalcLine = struct { learn: *Learn, text: []const u8 };

    fn onCalcLine(_: *gtk.Button, ctx: *CalcLine) callconv(.c) void {
        ctx.learn.hooks.use_calc(ctx.learn.hooks.ctx, ctx.text);
    }

    fn onCalcLineDestroy(_: *gtk.Button, ctx: *CalcLine) callconv(.c) void {
        std.heap.c_allocator.destroy(ctx);
    }

    fn onNext(_: *gtk.Button, self: *Learn) callconv(.c) void {
        const lesson = self.lessonAt(self.current orelse return);
        if (self.shown >= lesson.steps.len) return;
        const step = lesson.steps[self.shown];
        self.hooks.run(self.hooks.ctx, step.ops);
        if (step.ops.len > 0) self.hooks.show_canvas(self.hooks.ctx);
        self.showGraph(step);
        self.shown += 1;
        self.refresh();
    }

    fn onBack(_: *gtk.Button, self: *Learn) callconv(.c) void {
        if (self.shown > 1) self.replay(self.shown - 1);
    }

    fn onAll(_: *gtk.Button, self: *Learn) callconv(.c) void {
        const lesson = self.lessonAt(self.current orelse return);
        self.replay(lesson.steps.len);
    }
};
