//! The Language & region page (SPEC.md 5.5): the user's locale. It is written
//! to `~/.config/locale.conf`, which `dkde-session` reads at sign-in, so no
//! administrator is needed and the system's own default is left alone. The
//! change reaches programs started in the next session, not the running ones.

const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

const info = @import("sysinfo.zig");
const win = @import("window.zig");
const SettingsWindow = win.SettingsWindow;

const gpa = std.heap.c_allocator;
const log = std.log.scoped(.region);

/// One drop-down per setting. The first entry means "same as the language"
/// (for the formats) or "system default" (for the language): the key is removed.
const Field = struct {
    key: []const u8,
    /// What a drop-down shows for the empty choice.
    unset: [:0]const u8,
};

const fields = [_]Field{
    .{ .key = "LANG", .unset = "System default" },
    .{ .key = "LC_TIME", .unset = "Same as the language" },
    .{ .key = "LC_NUMERIC", .unset = "Same as the language" },
    .{ .key = "LC_MONETARY", .unset = "Same as the language" },
    .{ .key = "LC_PAPER", .unset = "Same as the language" },
    .{ .key = "LC_MEASUREMENT", .unset = "Same as the language" },
};

pub const RegionPage = struct {
    window: *SettingsWindow,
    locales: [][]u8,
    status: *gtk.Label,
    /// The drop-downs, in `fields` order.
    dropdowns: [fields.len]*gtk.DropDown = undefined,

    fn confPath() ?[:0]u8 {
        return std.fmt.allocPrintSentinel(gpa, "{s}/locale.conf", .{std.mem.span(glib.getUserConfigDir())}, 0) catch null;
    }

    fn readConf() ?[]u8 {
        const path = confPath() orelse return null;
        defer gpa.free(path);
        var contents: [*]u8 = undefined;
        var length: usize = 0;
        if (glib.fileGetContents(path, &contents, &length, null) == 0) return null;
        defer glib.free(contents);
        return gpa.dupe(u8, contents[0..length]) catch null;
    }

    pub fn build(window: *SettingsWindow) *gtk.Box {
        const page = SettingsWindow.newPage(common.tr("Language & region"));
        const self = gpa.create(RegionPage) catch @panic("OOM");

        // The locales this system has generated: the only ones that work.
        var listing: [*:0]u8 = undefined;
        const have_list = glib.spawnCommandLineSync("locale -a", &listing, null, null, null) != 0;
        defer if (have_list) glib.free(listing);
        const locales = info.usableLocales(gpa, if (have_list) std.mem.span(listing) else "") catch &.{};
        self.* = .{ .window = window, .locales = @constCast(locales), .status = gtk.Label.new("") };

        const intro = gtk.Label.new(common.tr("The language and formats for your programs. This is your own setting and needs no password. It applies the next time you sign in."));
        intro.setXalign(0);
        intro.setWrap(1);
        intro.as(gtk.Widget).addCssClass("dim-label");
        page.append(intro.as(gtk.Widget));

        const conf = readConf();
        defer if (conf) |c| gpa.free(c);
        const lang_sys: ?[]const u8 = if (glib.getenv("LANG")) |l| std.mem.span(l) else null;

        const labels = [_][:0]const u8{ "Language", "Dates and times", "Numbers", "Currency", "Paper size", "Measurements" };
        const descs = [_]?[:0]const u8{ "The language of programs that are translated, and the default for the formats below", null, null, null, null, null };
        inline for (fields, 0..) |f, i| {
            const list = gtk.StringList.new(null);
            list.append(f.unset);
            const current = if (conf) |c| info.shellValue(c, f.key) else null;
            var selected: c_uint = 0;
            for (self.locales, 0..) |l, n| {
                const z = gpa.dupeSentinel(u8, l, 0) catch continue;
                defer gpa.free(z);
                list.append(z.ptr);
                if (current) |cur| {
                    if (std.mem.eql(u8, cur, l)) selected = @intCast(n + 1);
                }
            }
            const dd = gtk.DropDown.new(list.as(gio.ListModel), null);
            dd.setSelected(selected);
            dd.as(gtk.Widget).setSizeRequest(220, -1);
            self.dropdowns[i] = dd;
            SettingsWindow.addRowDesc(page, labels[i], descs[i], dd.as(gtk.Widget));
        }
        // Connect after filling, so setting the starting choice does not write the file.
        inline for (0..fields.len) |i| {
            _ = gobject.Object.signals.notify.connect(self.dropdowns[i], *RegionPage, &onChanged, self, .{ .detail = "selected" });
        }

        self.status.setXalign(0);
        self.status.as(gtk.Widget).addCssClass("dim-label");
        page.append(self.status.as(gtk.Widget));

        const sys_note = std.fmt.allocPrintSentinel(gpa, "The system default is {s}.", .{lang_sys orelse "not set (C)"}, 0) catch null;
        if (sys_note) |n| {
            defer gpa.free(n);
            const l = gtk.Label.new(n.ptr);
            l.setXalign(0);
            l.as(gtk.Widget).addCssClass("dim-label");
            page.append(l.as(gtk.Widget));
        }
        if (self.locales.len == 0) {
            const l = gtk.Label.new(common.tr("No UTF-8 locales are installed. Generate some first (on Debian and Ubuntu: dpkg-reconfigure locales; elsewhere edit /etc/locale.gen and run locale-gen), then open this page again."));
            l.setXalign(0);
            l.setWrap(1);
            page.append(l.as(gtk.Widget));
        }
        const kb = gtk.Label.new(common.tr("The keyboard layout is on the Keyboard page. The time zone and clock format are on Date & time."));
        kb.setXalign(0);
        kb.setWrap(1);
        kb.as(gtk.Widget).addCssClass("dim-label");
        page.append(kb.as(gtk.Widget));
        return page;
    }

    fn onChanged(_: *gtk.DropDown, _: *gobject.ParamSpec, self: *RegionPage) callconv(.c) void {
        self.save();
    }

    /// Writes every drop-down's choice into locale.conf, keeping other lines.
    fn save(self: *RegionPage) void {
        const path = confPath() orelse return;
        defer gpa.free(path);
        var text: []u8 = gpa.dupe(u8, readConf() orelse "") catch return;
        defer gpa.free(text);
        inline for (fields, 0..) |f, i| {
            const sel = self.dropdowns[i].getSelected();
            const value: []const u8 = if (sel == 0 or sel - 1 >= self.locales.len) "" else self.locales[sel - 1];
            // A name from `locale -a` is checked all the same: the file is read by a shell script.
            if (value.len == 0 or info.validLocaleName(value)) {
                const next = info.setAssignment(gpa, text, f.key, value) catch return;
                gpa.free(text);
                text = next;
            }
        }
        // LANGUAGE follows LANG, so programs that read only it agree.
        const lang_sel = self.dropdowns[0].getSelected();
        const lang: []const u8 = if (lang_sel == 0 or lang_sel - 1 >= self.locales.len) "" else self.locales[lang_sel - 1];
        const language = if (std.mem.indexOfScalar(u8, lang, '.')) |d| lang[0..d] else lang;
        if (language.len == 0 or info.validLocaleName(language)) {
            const next = info.setAssignment(gpa, text, "LANGUAGE", language) catch return;
            gpa.free(text);
            text = next;
        }

        const dir = glib.pathGetDirname(path);
        defer glib.free(dir);
        _ = glib.mkdirWithParents(dir, 0o755);
        var err: ?*glib.Error = null;
        if (glib.fileSetContents(path, text.ptr, @intCast(text.len), &err) == 0) {
            if (err) |e| {
                log.warn("cannot write {s}: {s}", .{ path, std.mem.span(e.f_message.?) });
                e.free();
            }
            self.status.setText(common.tr("The setting could not be saved."));
            return;
        }
        self.status.setText(common.tr("Saved. It applies the next time you sign in."));
    }
};
