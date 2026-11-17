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
};

const Group = struct { course: []const u8, book: u8 };

pub const Learn = struct {
    gpa: std.mem.Allocator,
    hooks: Hooks,
    /// The lessons (read from the lesson files) and what was wrong with the files that were left out.
    loaded: lessonfile.Loaded,
    lessons: []const figure.Lesson,
    root: *gtk.Box,
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
        var dirs: std.ArrayList([]const u8) = .empty;
        defer {
            for (dirs.items) |d| gpa.free(d);
            dirs.deinit(gpa);
        }
        lessonDirs(gpa, &dirs);
        const loaded = lessonfile.load(gpa, common.fsio.io(), dirs.items);
        for (loaded.problems) |p| std.log.warn("lesson: {s}", .{p});
        // The courses and books that have lessons, in teaching order.
        var groups: std.ArrayList(Group) = .empty;
        const names = gtk.StringList.new(null);
        for (loaded.lessons) |l| {
            var seen = false;
            for (groups.items) |g| {
                if (g.book == l.book and std.mem.eql(u8, g.course, l.course)) seen = true;
            }
            if (seen) continue;
            try groups.append(gpa, .{ .course = l.course, .book = l.book });
            var z: [96]u8 = undefined;
            const euclid = std.mem.eql(u8, l.course, "Euclid");
            const zt = (if (euclid and l.book == 0) std.fmt.bufPrintSentinel(&z, "Euclid: Foundations", .{}, 0) else if (euclid) std.fmt.bufPrintSentinel(&z, "Euclid: Book {s}", .{roman(l.book)}, 0) else if (l.book <= 1) std.fmt.bufPrintSentinel(&z, "{s}", .{l.course}, 0) else std.fmt.bufPrintSentinel(&z, "{s}: unit {d}", .{ l.course, l.book }, 0)) catch "Lessons";
            names.append(zt);
        }
        self.* = .{
            .gpa = gpa,
            .hooks = hooks,
            .loaded = loaded,
            .lessons = loaded.lessons,
            .root = gtk.Box.new(.vertical, 6),
            .books = gtk.DropDown.new(names.as(@import("gio2").ListModel), null),
            .list = gtk.ListBox.new(),
            .title = gtk.Label.new(""),
            .statement = gtk.Label.new(""),
            .steps_box = gtk.Box.new(.vertical, 6),
            .proof = gtk.Label.new(""),
            .back = gtk.Button.newWithLabel(t("◀ Back")),
            .next = gtk.Button.newWithLabel(t("Next step ▶")),
            .all = gtk.Button.newWithLabel(t("Show all")),
            .groups = groups,
            .session = .{ .gpa = gpa },
            .exercise_box = gtk.Box.new(.vertical, 6),
        };

        const heading = gtk.Label.new(t("Learn"));
        heading.setXalign(0);
        heading.as(gtk.Widget).addCssClass("heading");
        self.root.append(heading.as(gtk.Widget));
        self.root.append(self.books.as(gtk.Widget));
        _ = gobject.Object.signals.notify.connect(self.books, *Learn, &onBook, self, .{ .detail = "selected" });

        self.list.setSelectionMode(.browse);
        _ = gtk.ListBox.signals.row_selected.connect(self.list, *Learn, &onRow, self, .{});
        const list_scroll = gtk.ScrolledWindow.new();
        list_scroll.setChild(self.list.as(gtk.Widget));
        list_scroll.setMinContentHeight(110);
        list_scroll.setMaxContentHeight(150);
        list_scroll.setPolicy(.never, .automatic);
        self.root.append(list_scroll.as(gtk.Widget));

        self.title.setXalign(0);
        self.title.setWrap(1);
        self.title.setMaxWidthChars(40);
        self.title.as(gtk.Widget).addCssClass("heading");
        self.root.append(self.title.as(gtk.Widget));
        self.statement.setXalign(0);
        self.statement.setWrap(1);
        self.statement.setMaxWidthChars(40);
        self.statement.setSelectable(1);
        self.statement.as(gtk.Widget).addCssClass("dim-label");
        self.root.append(self.statement.as(gtk.Widget));

        const steps_scroll = gtk.ScrolledWindow.new();
        steps_scroll.setChild(self.steps_box.as(gtk.Widget));
        steps_scroll.setMinContentHeight(160);
        steps_scroll.as(gtk.Widget).setVexpand(1);
        steps_scroll.setPolicy(.never, .automatic);
        self.root.append(steps_scroll.as(gtk.Widget));

        const buttons = gtk.Box.new(.horizontal, 6);
        _ = gtk.Button.signals.clicked.connect(self.back, *Learn, &onBack, self, .{});
        _ = gtk.Button.signals.clicked.connect(self.next, *Learn, &onNext, self, .{});
        _ = gtk.Button.signals.clicked.connect(self.all, *Learn, &onAll, self, .{});
        self.next.as(gtk.Widget).addCssClass("suggested-action");
        buttons.append(self.back.as(gtk.Widget));
        buttons.append(self.next.as(gtk.Widget));
        buttons.append(self.all.as(gtk.Widget));
        self.root.append(buttons.as(gtk.Widget));

        self.proof.setXalign(0);
        self.proof.setWrap(1);
        self.proof.setMaxWidthChars(40);
        self.proof.as(gtk.Widget).setVisible(0);
        self.root.append(self.proof.as(gtk.Widget));

        self.exercise_box.as(gtk.Widget).setVisible(0);
        self.root.append(self.exercise_box.as(gtk.Widget));

        self.fillList();
        self.ready = true;
        return self;
    }

    /// Called when the view is shown: draws the lesson that is selected (dev aid: DKDE_LEARN_LESSON=I.1
    /// opens that lesson, DKDE_LEARN_STEPS=n shows n steps).
    pub fn start(self: *Learn) void {
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

    fn roman(n: u8) []const u8 {
        const table = [_][]const u8{ "", "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X", "XI", "XII", "XIII" };
        return if (n < table.len) table[n] else "?";
    }

    fn onBook(_: *gtk.DropDown, _: *gobject.ParamSpec, self: *Learn) callconv(.c) void {
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
            label.as(gtk.Widget).setMarginTop(4);
            label.as(gtk.Widget).setMarginBottom(4);
            self.list.append(label.as(gtk.Widget));
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
        const lesson = self.lessons[self.current orelse return];
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
    }

    fn refresh(self: *Learn) void {
        const lesson = self.lessons[self.current orelse return];
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
            if (mathview.MathView.create(self.gpa, st.math, null)) |w| {
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
        const lesson = self.lessons[self.current orelse return];
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
        const lesson = self.lessons[self.current orelse return];
        self.replay(lesson.steps.len);
    }
};
