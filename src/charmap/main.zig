// SPDX-License-Identifier: GPL-2.0-or-later
//! dkde-charmap: pick Unicode characters from blocks and copy them (SPEC.md 5.6).

const std = @import("std");
const cli = @import("cli");
const gdk = @import("gdk4");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

const unidata = @import("unidata.zig");
const fontcfg = @import("fontcfg.zig");
const glyphnames = @import("glyphnames.zig");

// saveList writes the whole file, so each remembered thing has a file of its own.
const font_state = "charmap-font.state";
const block_state = "charmap-block.state";
const recent_state = "charmap-recent.state";
const fonts_state = "charmap-fonts.state";

pub const std_options: std.Options = .{ .logFn = common.log.logFn, .log_level = .debug };

const page_size = 256;
const max_results = 1000;
const max_recent = 16;

const Charmap = struct {
    allocator: std.mem.Allocator,
    db: unidata.Db,
    /// Block names as C strings, kept alive for the drop-down.
    block_names: [][:0]u8,
    window: *gtk.ApplicationWindow,
    chooser: *gtk.DropDown,
    font_chooser: *gtk.DropDown,
    /// "Default font" is index 0; the installed families follow.
    families: [][:0]u8,
    font_css: *gtk.CssProvider,
    cover: ?fontcfg.Cover = null,
    /// The chosen font's own glyph names, read the first time a private-use
    /// character needs one (`names_tried` says whether that has happened).
    font_bytes: ?[]u8 = null,
    names: ?glyphnames.Names = null,
    names_tried: bool = false,
    private_block: bool = false,
    search: *gtk.SearchEntry,
    grid: *gtk.FlowBox,
    picked: *gtk.Entry,
    recent_row: *gtk.Box,
    prev: *gtk.Button,
    next: *gtk.Button,
    page_label: *gtk.Label,
    preview: *gtk.Label,
    info: *gtk.Label,
    /// What the grid shows: a block's characters, or the search results.
    cells: std.ArrayList(u21) = .empty,
    recent: std.ArrayList(u21) = .empty,
    page: usize = 0,
    /// Set while the saved choices are put back, so that doing so saves nothing.
    restoring: bool = false,

    pub fn create(allocator: std.mem.Allocator, app: *gtk.Application) !*Charmap {
        const self = try allocator.create(Charmap);
        errdefer allocator.destroy(self);
        var db = try unidata.Db.load(allocator);
        errdefer db.deinit(allocator);

        const names = try allocator.alloc([:0]u8, db.blocks.len);
        var made: usize = 0;
        errdefer {
            for (names[0..made]) |n| allocator.free(n);
            allocator.free(names);
        }
        const ptrs = try allocator.alloc(?[*:0]const u8, db.blocks.len + 1);
        defer allocator.free(ptrs);
        for (db.blocks, 0..) |b, i| {
            names[i] = try allocator.allocSentinel(u8, b.name.len, 0);
            @memcpy(names[i], b.name);
            made += 1;
            ptrs[i] = names[i].ptr;
        }
        ptrs[db.blocks.len] = null;

        const families = try fontcfg.families(allocator);
        errdefer {
            for (families) |n| allocator.free(n);
            allocator.free(families);
        }
        const fptrs = try allocator.alloc(?[*:0]const u8, families.len + 2);
        defer allocator.free(fptrs);
        fptrs[0] = common.tr("Default font");
        for (families, 0..) |f, i| fptrs[i + 1] = f.ptr;
        fptrs[families.len + 1] = null;

        self.* = .{
            .allocator = allocator,
            .db = db,
            .block_names = names,
            .families = families,
            .font_chooser = gtk.DropDown.newFromStrings(@ptrCast(fptrs.ptr)),
            .font_css = gtk.CssProvider.new(),
            .window = gtk.ApplicationWindow.new(app),
            .chooser = gtk.DropDown.newFromStrings(@ptrCast(ptrs.ptr)),
            .search = gtk.SearchEntry.new(),
            .grid = gtk.FlowBox.new(),
            .picked = gtk.Entry.new(),
            .recent_row = gtk.Box.new(.horizontal, 2),
            .prev = gtk.Button.newWithLabel(common.tr("Previous")),
            .next = gtk.Button.newWithLabel(common.tr("Next")),
            .page_label = gtk.Label.new(""),
            .preview = gtk.Label.new(""),
            .info = gtk.Label.new(""),
        };
        _ = gtk.Widget.signals.destroy.connect(self.window, *Charmap, &onDestroy, self, .{});
        const window = self.window.as(gtk.Window);
        window.setTitle(common.tr("Character Map"));
        window.setDefaultSize(660, 600);
        self.window.as(gtk.Widget).addCssClass("dkde");
        _ = common.header.create(window, "accessories-character-map", true);

        self.search.as(gtk.Widget).setHexpand(1);
        self.search.setPlaceholderText(common.tr("Search by name, character or code (U+00E9)"));
        _ = gtk.SearchEntry.signals.search_changed.connect(self.search, *Charmap, &onSearch, self, .{});
        _ = gobject.Object.signals.notify.connect(self.chooser, *Charmap, &onBlock, self, .{ .detail = "selected" });
        self.chooser.as(gtk.Widget).setTooltipText(common.tr("Unicode block"));
        self.font_chooser.as(gtk.Widget).setTooltipText(common.tr("Font: also shows what a font puts in the Private Use Area"));
        self.font_chooser.setEnableSearch(1);
        self.font_chooser.setExpression(@ptrCast(gtk.PropertyExpression.new(gtk.StringObject.getGObjectType(), null, "string")));
        self.font_chooser.as(gtk.Widget).setSizeRequest(150, -1);
        _ = gobject.Object.signals.notify.connect(self.font_chooser, *Charmap, &onFont, self, .{ .detail = "selected" });
        gtk.StyleContext.addProviderForDisplay(
            self.window.as(gtk.Widget).getDisplay(),
            self.font_css.as(gtk.StyleProvider),
            gtk.STYLE_PROVIDER_PRIORITY_USER,
        );
        const top = gtk.Box.new(.horizontal, 8);
        top.as(gtk.Widget).setMarginStart(8);
        top.as(gtk.Widget).setMarginEnd(8);
        top.as(gtk.Widget).setMarginTop(8);
        top.append(self.search.as(gtk.Widget));
        top.append(self.chooser.as(gtk.Widget));
        top.append(self.font_chooser.as(gtk.Widget));
        const add_font = gtk.Button.newFromIconName("list-add-symbolic");
        add_font.as(gtk.Widget).setTooltipText(common.tr("Add a font file (TTF or OTF) without installing it"));
        _ = gtk.Button.signals.clicked.connect(add_font, *Charmap, &onAddFont, self, .{});
        top.append(add_font.as(gtk.Widget));

        self.grid.setSelectionMode(.none);
        self.grid.setMaxChildrenPerLine(16);
        self.grid.setMinChildrenPerLine(8);
        self.grid.as(gtk.Widget).addCssClass("dkde-charmap-grid");
        const scroller = gtk.ScrolledWindow.new();
        scroller.setChild(self.grid.as(gtk.Widget));
        scroller.as(gtk.Widget).setVexpand(1);

        _ = gtk.Button.signals.clicked.connect(self.prev, *Charmap, &onPrev, self, .{});
        _ = gtk.Button.signals.clicked.connect(self.next, *Charmap, &onNext, self, .{});
        const pager = gtk.Box.new(.horizontal, 8);
        pager.as(gtk.Widget).setHalign(.center);
        pager.append(self.prev.as(gtk.Widget));
        pager.append(self.page_label.as(gtk.Widget));
        pager.append(self.next.as(gtk.Widget));

        const recent_title = gtk.Label.new(common.tr("Recent"));
        recent_title.as(gtk.Widget).addCssClass("dim-label");
        const recent = gtk.Box.new(.horizontal, 8);
        recent.as(gtk.Widget).setMarginStart(8);
        recent.as(gtk.Widget).setMarginEnd(8);
        recent.append(recent_title.as(gtk.Widget));
        recent.append(self.recent_row.as(gtk.Widget));

        self.picked.as(gtk.Widget).setHexpand(1);
        self.picked.setPlaceholderText(common.tr("Click characters to collect them here"));
        _ = gtk.Entry.signals.activate.connect(self.picked, *Charmap, &onActivate, self, .{});
        const copy = gtk.Button.newWithLabel(common.tr("Copy"));
        copy.as(gtk.Widget).addCssClass("suggested-action");
        _ = gtk.Button.signals.clicked.connect(copy, *Charmap, &onCopy, self, .{});
        const clear = gtk.Button.newWithLabel(common.tr("Clear"));
        _ = gtk.Button.signals.clicked.connect(clear, *Charmap, &onClear, self, .{});
        const row = gtk.Box.new(.horizontal, 8);
        row.as(gtk.Widget).setMarginStart(8);
        row.as(gtk.Widget).setMarginEnd(8);
        row.append(self.picked.as(gtk.Widget));
        row.append(clear.as(gtk.Widget));
        row.append(copy.as(gtk.Widget));

        self.preview.as(gtk.Widget).addCssClass("dkde-charmap-preview");
        self.preview.as(gtk.Widget).setSizeRequest(72, -1);
        self.info.setXalign(0);
        self.info.setWrap(1);
        self.info.as(gtk.Widget).setHexpand(1);
        self.info.as(gtk.Widget).addCssClass("dim-label");
        const details = gtk.Box.new(.horizontal, 8);
        details.as(gtk.Widget).setMarginStart(8);
        details.as(gtk.Widget).setMarginEnd(8);
        details.as(gtk.Widget).setMarginBottom(8);
        details.append(self.preview.as(gtk.Widget));
        details.append(self.info.as(gtk.Widget));

        const root = gtk.Box.new(.vertical, 8);
        root.append(top.as(gtk.Widget));
        root.append(scroller.as(gtk.Widget));
        root.append(pager.as(gtk.Widget));
        root.append(recent.as(gtk.Widget));
        root.append(row.as(gtk.Widget));
        root.append(details.as(gtk.Widget));
        window.setChild(root.as(gtk.Widget));

        self.restore();
        self.showBlock(self.chooser.getSelected());
        return self;
    }

    fn onDestroy(_: *gtk.ApplicationWindow, self: *Charmap) callconv(.c) void {
        const a = self.allocator;
        for (self.block_names) |n| a.free(n);
        a.free(self.block_names);
        for (self.families) |n| a.free(n);
        a.free(self.families);
        if (self.cover) |c| c.deinit();
        self.freeNames();
        self.cells.deinit(a);
        self.recent.deinit(a);
        self.db.deinit(a);
        a.destroy(self);
    }

    pub fn present(self: *Charmap) void {
        self.window.as(gtk.Window).present();
    }

    fn searching(self: *Charmap) bool {
        return std.mem.trim(u8, std.mem.span(self.search.as(gtk.Editable).getText()), " \t").len > 0;
    }

    fn onBlock(dd: *gtk.DropDown, _: *gobject.ParamSpec, self: *Charmap) callconv(.c) void {
        // Choosing a block leaves search mode.
        if (self.searching()) self.search.as(gtk.Editable).setText("");
        self.showBlock(dd.getSelected());
    }

    fn showBlock(self: *Charmap, index: usize) void {
        self.cells.clearRetainingCapacity();
        self.private_block = false;
        if (index < self.db.blocks.len) {
            const block = self.db.blocks[index];
            self.private_block = block.private;
            if (block.private) {
                // Private use characters mean whatever the chosen font says.
                if (self.cover) |c| {
                    var cp = block.first;
                    while (cp <= block.last) : (cp += 1) {
                        if (c.has(cp)) self.cells.append(self.allocator, cp) catch break;
                    }
                }
            } else {
                self.db.fillBlock(self.allocator, block, &self.cells) catch {};
            }
        }
        self.page = 0;
        self.render();
        self.saveState();
    }

    /// The family selected in the font drop-down, null for the default font.
    fn family(self: *Charmap) ?[:0]const u8 {
        const i = self.font_chooser.getSelected();
        if (i == 0 or i > self.families.len) return null;
        return self.families[i - 1];
    }

    fn onFont(_: *gtk.DropDown, _: *gobject.ParamSpec, self: *Charmap) callconv(.c) void {
        self.applyFont();
        if (self.searching()) {
            onSearch(self.search, self);
        } else {
            self.showBlock(self.chooser.getSelected());
        }
        self.saveState();
    }

    fn freeNames(self: *Charmap) void {
        if (self.font_bytes) |b| glib.free(b.ptr);
        self.font_bytes = null;
        self.names = null;
        self.names_tried = false;
    }

    /// The chosen font's name for `cp`, read from the font file on first use.
    fn glyphName(self: *Charmap, cp: u21) ?[]const u8 {
        if (!self.names_tried) {
            self.names_tried = true;
            const path = (self.cover orelse return null).file() orelse return null;
            var data: [*]u8 = undefined;
            var len: usize = 0;
            if (glib.fileGetContents(path.ptr, &data, &len, null) == 0) return null;
            self.font_bytes = data[0..len];
            self.names = glyphnames.Names.parse(self.font_bytes.?);
        }
        return (self.names orelse return null).name(cp);
    }

    // ---- Add font ---------------------------------------------------------------------------

    fn onAddFont(_: *gtk.Button, self: *Charmap) callconv(.c) void {
        const dialog = gtk.FileDialog.new();
        defer dialog.as(gobject.Object).unref();
        dialog.setTitle(common.tr("Add a font file"));
        const filter = gtk.FileFilter.new();
        filter.setName(common.tr("Fonts (TTF, OTF)"));
        filter.addPattern("*.ttf");
        filter.addPattern("*.otf");
        filter.addPattern("*.TTF");
        filter.addPattern("*.OTF");
        const filters = gio.ListStore.new(gtk.FileFilter.getGObjectType());
        defer filters.as(gobject.Object).unref();
        filters.append(filter.as(gobject.Object));
        dialog.setFilters(filters.as(gio.ListModel));
        dialog.open(self.window.as(gtk.Window), null, onFontFile, self);
    }

    fn onFontFile(source: ?*gobject.Object, result: *gio.AsyncResult, raw: ?*anyopaque) callconv(.c) void {
        const self: *Charmap = @ptrCast(@alignCast(raw.?));
        const dialog: *gtk.FileDialog = @ptrCast(@alignCast(source.?));
        var err: ?*glib.Error = null;
        const file = dialog.openFinish(result, &err) orelse {
            if (err) |e| e.free(); // cancelled
            return;
        };
        defer file.as(gobject.Object).unref();
        const path = file.getPath() orelse return;
        defer glib.free(path);
        self.addFont(std.mem.span(path));
    }

    /// Make a font file available now and keep it for the next run.
    fn addFont(self: *Charmap, path: [:0]const u8) void {
        if (!fontcfg.addFileLive(path.ptr)) {
            self.info.setText(common.tr("That file could not be used as a font."));
            return;
        }
        self.rememberFontFile(path);
        const a = self.allocator;
        const fresh = fontcfg.families(a) catch return;
        defer {
            for (fresh) |n| a.free(n);
            a.free(fresh);
        }
        const model: *gtk.StringList = @ptrCast(self.font_chooser.getModel() orelse return);
        var first_new: ?usize = null;
        for (fresh) |f| {
            var known = false;
            for (self.families) |k| {
                if (std.mem.eql(u8, k, f)) known = true;
            }
            if (known) continue;
            const copy = a.allocSentinel(u8, f.len, 0) catch return;
            @memcpy(copy, f);
            const grown = a.realloc(self.families, self.families.len + 1) catch {
                a.free(copy);
                return;
            };
            grown[grown.len - 1] = copy;
            self.families = grown;
            model.append(copy.ptr);
            if (first_new == null) first_new = grown.len; // dropdown index: "Default font" is 0
        }
        if (first_new) |i| {
            self.font_chooser.setSelected(@intCast(i));
        } else {
            self.info.setText(common.tr("That font is already in the list."));
        }
    }

    fn rememberFontFile(self: *Charmap, path: []const u8) void {
        const a = self.allocator;
        var files = common.state.loadList(a, fonts_state, "charmap", "fonts") catch std.ArrayList([]u8).empty;
        defer common.state.freeList(a, &files);
        for (files.items) |f| if (std.mem.eql(u8, f, path)) return;
        const copy = a.dupe(u8, path) catch return;
        files.append(a, copy) catch {
            a.free(copy);
            return;
        };
        common.state.saveList(a, fonts_state, "charmap", "fonts", files.items) catch {};
    }

    /// Draw the cells and preview in the chosen font, and learn what it covers.
    fn applyFont(self: *Charmap) void {
        if (self.cover) |c| c.deinit();
        self.freeNames();
        self.cover = fontcfg.Cover.load(self.family());
        var css: [512]u8 = undefined;
        const text = if (self.family()) |f| blk: {
            // A family name goes into a CSS string: drop what could end it.
            var clean: [256]u8 = undefined;
            var n: usize = 0;
            for (f) |ch| {
                if (ch == '"' or ch == '\\' or ch < 0x20 or n >= clean.len) continue;
                clean[n] = ch;
                n += 1;
            }
            break :blk std.fmt.bufPrintSentinel(&css, "button.dkde-charmap-cell, .dkde-charmap-preview {{ font-family: \"{s}\"; }}", .{clean[0..n]}, 0) catch "";
        } else "";
        self.font_css.loadFromString(text);
    }

    fn onSearch(entry: *gtk.SearchEntry, self: *Charmap) callconv(.c) void {
        const query = std.mem.span(entry.as(gtk.Editable).getText());
        if (std.mem.trim(u8, query, " \t").len == 0) {
            self.showBlock(self.chooser.getSelected());
            return;
        }
        self.private_block = false;
        self.cells.clearRetainingCapacity();
        self.db.search(self.allocator, query, max_results, &self.cells) catch {};
        self.page = 0;
        self.render();
    }

    // ---- what is remembered between runs: the font, block and recent characters -----------

    fn restore(self: *Charmap) void {
        self.restoring = true;
        defer self.restoring = false;
        const a = self.allocator;
        var font = common.state.loadList(a, font_state, "charmap", "font") catch std.ArrayList([]u8).empty;
        defer common.state.freeList(a, &font);
        if (font.items.len > 0) {
            for (self.families, 0..) |f, i| {
                if (std.mem.eql(u8, f, font.items[0])) self.font_chooser.setSelected(@intCast(i + 1));
            }
        }
        self.applyFont();

        var block = common.state.loadList(a, block_state, "charmap", "block") catch std.ArrayList([]u8).empty;
        defer common.state.freeList(a, &block);
        const want: []const u8 = if (block.items.len > 0) block.items[0] else "Basic Latin";
        for (self.db.blocks, 0..) |b, i| {
            if (std.mem.eql(u8, b.name, want)) self.chooser.setSelected(@intCast(i));
        }

        var recent = common.state.loadList(a, recent_state, "charmap", "recent") catch std.ArrayList([]u8).empty;
        defer common.state.freeList(a, &recent);
        var i = recent.items.len;
        while (i > 0) { // oldest first, so the newest ends up in front
            i -= 1;
            const cp = std.fmt.parseInt(u21, recent.items[i], 16) catch continue;
            if (cp > 0x10FFFF) continue;
            self.remember(cp);
        }
    }

    fn saveState(self: *Charmap) void {
        if (self.restoring) return;
        const a = self.allocator;
        const state = common.state;
        const bi = self.chooser.getSelected();
        if (bi < self.db.blocks.len) {
            const items = [_][]u8{@constCast(self.db.blocks[bi].name)};
            state.saveList(a, block_state, "charmap", "block", &items) catch {};
        }
        const fam: []const u8 = if (self.family()) |f| f else "";
        const items = [_][]u8{@constCast(fam)};
        state.saveList(a, font_state, "charmap", "font", &items) catch {};
    }

    fn saveRecent(self: *Charmap) void {
        if (self.restoring) return;
        const a = self.allocator;
        var items: std.ArrayList([]u8) = .empty;
        defer {
            for (items.items) |s| a.free(s);
            items.deinit(a);
        }
        for (self.recent.items) |cp| {
            const s = std.fmt.allocPrint(a, "{X}", .{cp}) catch return;
            items.append(a, s) catch {
                a.free(s);
                return;
            };
        }
        common.state.saveList(a, recent_state, "charmap", "recent", items.items) catch {};
    }

    fn pageCount(self: *Charmap) usize {
        return @max(1, (self.cells.items.len + page_size - 1) / page_size);
    }

    fn onPrev(_: *gtk.Button, self: *Charmap) callconv(.c) void {
        if (self.page > 0) self.page -= 1;
        self.render();
    }

    fn onNext(_: *gtk.Button, self: *Charmap) callconv(.c) void {
        if (self.page + 1 < self.pageCount()) self.page += 1;
        self.render();
    }

    const Cell = struct { owner: *Charmap, cp: u21 };

    fn onCellDestroy(_: *gtk.Button, cell: *Cell) callconv(.c) void {
        cell.owner.allocator.destroy(cell);
    }

    /// The text to draw for `cp`: combining marks get a dotted circle to sit on.
    fn glyph(self: *Charmap, cp: u21, buf: *[12]u8) [:0]const u8 {
        var n: usize = 0;
        if (self.db.isMark(cp)) n += std.unicode.utf8Encode(0x25CC, buf[0..4]) catch 0;
        n += std.unicode.utf8Encode(cp, buf[n..][0..4]) catch 0;
        buf[n] = 0;
        return buf[0..n :0];
    }

    fn makeCell(self: *Charmap, cp: u21) ?*gtk.Button {
        var z: [12]u8 = undefined;
        const button = gtk.Button.newWithLabel(self.glyph(cp, &z).ptr);
        button.setHasFrame(0);
        button.as(gtk.Widget).addCssClass("dkde-charmap-cell");
        const cell = self.allocator.create(Cell) catch return null;
        cell.* = .{ .owner = self, .cp = cp };
        _ = gtk.Button.signals.clicked.connect(button, *Cell, &onCell, cell, .{});
        _ = gtk.Widget.signals.destroy.connect(button, *Cell, &onCellDestroy, cell, .{});
        const motion = gtk.EventControllerMotion.new();
        _ = gtk.EventControllerMotion.signals.enter.connect(motion, *Cell, &onHover, cell, .{});
        button.as(gtk.Widget).addController(motion.as(gtk.EventController));
        var tip: [160:0]u8 = undefined;
        var nb: [96]u8 = undefined;
        const nm = self.db.name(cp, &nb) orelse self.glyphName(cp) orelse common.tr("Private use character");
        button.as(gtk.Widget).setTooltipText(std.fmt.bufPrintSentinel(&tip, "{s}", .{nm}, 0) catch "");
        return button;
    }

    fn render(self: *Charmap) void {
        while (self.grid.as(gtk.Widget).getFirstChild()) |child| self.grid.remove(child);
        const pages = self.pageCount();
        if (self.page >= pages) self.page = pages - 1;
        const start = self.page * page_size;
        const end = @min(self.cells.items.len, start + page_size);
        for (self.cells.items[start..end]) |cp| {
            const button = self.makeCell(cp) orelse continue;
            self.grid.append(button.as(gtk.Widget));
        }
        self.prev.as(gtk.Widget).setSensitive(@intFromBool(self.page > 0));
        self.next.as(gtk.Widget).setSensitive(@intFromBool(self.page + 1 < pages));
        var z: [96:0]u8 = undefined;
        const total = self.cells.items.len;
        const text = if (self.searching() and total == 0)
            common.tr("No matches")
        else if (self.private_block and total == 0)
            common.tr("This font has no characters here. Pick a font made for the Private Use Area.")
        else if (pages > 1)
            std.fmt.bufPrintSentinel(&z, "{d}\u{2013}{d} of {d}  (page {d} of {d})", .{ start + 1, end, total, self.page + 1, pages }, 0) catch ""
        else
            std.fmt.bufPrintSentinel(&z, "{d} characters", .{total}, 0) catch "";
        self.page_label.setText(text);
    }

    fn show(self: *Charmap, cp: u21) void {
        var g: [12]u8 = undefined;
        self.preview.setText(self.glyph(cp, &g).ptr);
        var code: [16]u8 = undefined;
        var hex: [16]u8 = undefined;
        var nb: [96]u8 = undefined;
        var z: [200:0]u8 = undefined;
        const text = std.fmt.bufPrintSentinel(&z, "{s}  {s}\nUTF-8: {s}", .{
            unidata.codeLabel(cp, &code),
            self.db.name(cp, &nb) orelse self.glyphName(cp) orelse common.tr("Private use character (the font gives it no name)"),
            unidata.utf8Hex(cp, &hex),
        }, 0) catch "";
        self.info.setText(text);
    }

    fn onHover(_: *gtk.EventControllerMotion, _: f64, _: f64, cell: *Cell) callconv(.c) void {
        cell.owner.show(cell.cp);
    }

    fn onCell(_: *gtk.Button, cell: *Cell) callconv(.c) void {
        const self = cell.owner;
        const cp = cell.cp;
        var enc: [5]u8 = @splat(0);
        const n = std.unicode.utf8Encode(cp, enc[0..4]) catch return;
        const entry = self.picked.as(gtk.Editable);
        var position: c_int = -1;
        entry.insertText(@ptrCast(enc[0..n :0]), @intCast(n), &position);
        self.show(cp);
        self.pick(cp);
    }

    /// Put `cp` first in the recent row (without duplicates, newest first).
    /// The buttons are rebuilt from the list, so `cell` must not be used after this.
    fn remember(self: *Charmap, cp: u21) void {
        if (std.mem.indexOfScalar(u21, self.recent.items, cp)) |i| _ = self.recent.orderedRemove(i);
        self.recent.insert(self.allocator, 0, cp) catch return;
        if (self.recent.items.len > max_recent) self.recent.shrinkRetainingCapacity(max_recent);
        while (self.recent_row.as(gtk.Widget).getFirstChild()) |child| self.recent_row.remove(child);
        for (self.recent.items) |r| {
            const button = self.makeCell(r) orelse continue;
            self.recent_row.append(button.as(gtk.Widget));
        }
    }

    /// `remember`, and keep the list for the next run.
    fn pick(self: *Charmap, cp: u21) void {
        self.remember(cp);
        self.saveRecent();
    }

    fn onCopy(_: *gtk.Button, self: *Charmap) callconv(.c) void {
        self.copyText();
    }

    fn onActivate(_: *gtk.Entry, self: *Charmap) callconv(.c) void {
        self.copyText();
    }

    fn copyText(self: *Charmap) void {
        const text = self.picked.as(gtk.Editable).getText();
        self.window.as(gtk.Widget).getClipboard().setText(text);
    }

    fn onClear(_: *gtk.Button, self: *Charmap) callconv(.c) void {
        self.picked.as(gtk.Editable).setText("");
    }
};

extern fn FcConfigAppFontAddFile(config: ?*anyopaque, file: [*:0]const u8) c_int;

/// The Rosquin glyph font is part of the program, so its private-use characters
/// can be browsed without installing it: written to the user's cache and
/// registered with Fontconfig for this process. Must run before GTK starts.
fn loadRosquinFont(allocator: std.mem.Allocator) void {
    const cache = std.mem.span(glib.getUserCacheDir());
    const dir = std.fmt.allocPrintSentinel(allocator, "{s}/dkde", .{cache}, 0) catch return;
    defer allocator.free(dir);
    const path = std.fmt.allocPrintSentinel(allocator, "{s}/RosquinGlyphs.ttf", .{dir}, 0) catch return;
    defer allocator.free(path);
    _ = glib.mkdirWithParents(dir, 0o755);
    if (!common.fsio.tryWrite(path, @embedFile("rosquin-font"))) return;
    _ = FcConfigAppFontAddFile(null, path.ptr);

    // Fonts added with the + button in earlier runs.
    var files = common.state.loadList(allocator, fonts_state, "charmap", "fonts") catch return;
    defer common.state.freeList(allocator, &files);
    for (files.items) |f| {
        const z = allocator.dupeSentinel(u8, f, 0) catch continue;
        defer allocator.free(z);
        _ = FcConfigAppFontAddFile(null, z.ptr);
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    cli.handle(init.args, .{ .name = "dkde-charmap", .summary = "Character map" });
    loadRosquinFont(std.heap.page_allocator);
    try common.runapp.run("org.dkde.charmap", Charmap, init);
}

test {
    _ = @import("unidata.zig");
    _ = @import("glyphnames.zig");
}
