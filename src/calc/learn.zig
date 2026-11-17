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
};

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
    /// The lessons listed now (indexes into self.lessons), and the book chosen.
    listed: std.ArrayList(usize) = .empty,
    book_ids: std.ArrayList(u8) = .empty,
    current: ?usize = null,
    /// How many steps are shown.
    shown: usize = 0,
    /// False while the view is being built: choosing the first row must not draw yet.
    ready: bool = false,

    /// The folders lessons are read from: DKDE_LEARN_DIR, else the installed data, and always your own
    /// in ~/.local/share/dkde/learn.
    fn lessonDirs(gpa: std.mem.Allocator, out: *std.ArrayList([]const u8)) void {
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
        // The books that have lessons, in order.
        var book_ids: std.ArrayList(u8) = .empty;
        for (loaded.lessons) |l| {
            if (std.mem.indexOfScalar(u8, book_ids.items, l.book) == null) try book_ids.append(gpa, l.book);
        }
        std.mem.sort(u8, book_ids.items, {}, std.sort.asc(u8));
        const names = gtk.StringList.new(null);
        for (book_ids.items) |b| {
            var buf: [24]u8 = undefined;
            const text = if (b == 0) "Foundations" else std.fmt.bufPrint(&buf, "Book {s}", .{roman(b)}) catch "Book";
            var z: [40]u8 = undefined;
            const zt = std.fmt.bufPrintSentinel(&z, "{s}", .{text}, 0) catch "Book";
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
            .book_ids = book_ids,
        };

        const heading = gtk.Label.new(t("Euclid's Elements"));
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
                const sel = std.mem.indexOfScalar(u8, self.book_ids.items, lesson.book) orelse 0;
                self.books.setSelected(@intCast(sel));
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
        self.book_ids.deinit(self.gpa);
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
        const book: u8 = if (sel < self.book_ids.items.len) self.book_ids.items[sel] else 0;
        for (self.lessons, 0..) |l, i| {
            if (l.book != book) continue;
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
        self.hooks.show_canvas(self.hooks.ctx);
        self.replay(1);
    }

    /// Draws the first `count` steps from an empty canvas.
    fn replay(self: *Learn, count: usize) void {
        const lesson = self.lessons[self.current orelse return];
        self.hooks.clear(self.hooks.ctx);
        const n = @min(count, lesson.steps.len);
        for (lesson.steps[0..n]) |step| self.hooks.run(self.hooks.ctx, step.ops);
        self.shown = n;
        self.refresh();
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
        self.hooks.run(self.hooks.ctx, lesson.steps[self.shown].ops);
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
