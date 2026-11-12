//! The Online accounts page (Accounts, in Settings): optional online calendars
//! for dkde-calendar and the panel's reminders. Nothing here runs until the user
//! adds an account; see src/common/feeds.zig for what an account is and is not.
//!
//! Changes are written at once (an account is added, switched or removed by its
//! own button), not staged with Apply like the rest of Settings: there is no
//! half-finished state to take back.

const std = @import("std");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gio = @import("gio2");
const gtk = @import("gtk4");
const common = @import("common");

const win = @import("window.zig");
const SettingsWindow = win.SettingsWindow;
const feeds = common.feeds;

const gpa = std.heap.c_allocator;

/// The choices of "Update", as minutes (0: only when asked).
const intervals = [_]i32{ 0, 60, 360, 1440 };
const interval_names = [_]?[*:0]const u8{ "Only when I ask", "On start, if older than an hour", "On start, if older than 6 hours", "On start, if older than a day", null };

pub const OnlinePage = struct {
    window: *SettingsWindow,
    /// dkde.toml, not staged.
    cfg: common.Config,
    accounts: feeds.Accounts,
    list: *gtk.ListBox,
    status: *gtk.Label,
    name_entry: *gtk.Entry,
    url_entry: *gtk.Entry,
    interval: *gtk.DropDown,
    refresh_button: *gtk.Button,
    busy: bool = false,
    /// An account was added while an update was running: update again when it ends.
    pending: bool = false,
    /// The page was destroyed while a refresh was still running; the refresh frees it.
    dead: bool = false,

    pub fn build(window: *SettingsWindow) *gtk.Box {
        const page = SettingsWindow.newPage(common.tr("Online accounts"));
        const cfg = common.Config.load(gpa, "dkde.toml") catch {
            // Not a reason to take Settings down: say what is wrong and leave the page empty.
            const msg = gtk.Label.new(common.tr("dkde.toml could not be read, so online calendars cannot be set up. Fix or remove the file and open this page again."));
            msg.setXalign(0);
            msg.setWrap(1);
            page.append(msg.as(gtk.Widget));
            return page;
        };
        const self = gpa.create(OnlinePage) catch @panic("OOM");
        self.* = .{
            .window = window,
            .cfg = cfg,
            .accounts = .{ .arena = std.heap.ArenaAllocator.init(gpa), .items = &.{} },
            .list = gtk.ListBox.new(),
            .status = gtk.Label.new(""),
            .name_entry = gtk.Entry.new(),
            .url_entry = gtk.Entry.new(),
            .interval = gtk.DropDown.newFromStrings(@ptrCast(&interval_names)),
            .refresh_button = gtk.Button.newWithLabel(common.tr("Update now")),
        };
        _ = gtk.Widget.signals.destroy.connect(page, *OnlinePage, &onDestroy, self, .{});

        const intro = gtk.Label.new(common.tr("Optional. Add a calendar from the internet to see its events in the calendar and in reminders. Nothing is contacted until you add one, and nothing is ever sent to the server: the events are only read. The apps do not ask you to sign in."));
        intro.setXalign(0);
        intro.setWrap(1);
        intro.as(gtk.Widget).addCssClass("dim-label");
        page.append(intro.as(gtk.Widget));

        self.list.as(gtk.Widget).addCssClass("boxed-list");
        self.list.setSelectionMode(.none);
        page.append(self.list.as(gtk.Widget));

        const heading = gtk.Label.new(common.tr("Add a calendar"));
        heading.setXalign(0);
        heading.as(gtk.Widget).addCssClass("heading");
        heading.as(gtk.Widget).setMarginTop(12);
        page.append(heading.as(gtk.Widget));

        const how = gtk.Label.new(common.tr("Paste the private iCal (.ics) link of the calendar. Google Calendar calls it \"Secret address in iCal format\" (calendar settings), Nextcloud and Fastmail \"subscription link\", Outlook \"Publish calendar\". Anyone with the link can read that calendar, so do not share it; it is kept in your dkde.toml."));
        how.setXalign(0);
        how.setWrap(1);
        how.as(gtk.Widget).addCssClass("dim-label");
        page.append(how.as(gtk.Widget));

        self.name_entry.setPlaceholderText(common.tr("Name, for example Work"));
        self.url_entry.setPlaceholderText("https://…/calendar.ics");
        self.url_entry.as(gtk.Widget).setHexpand(1);
        self.name_entry.setMaxLength(60);
        page.append(self.name_entry.as(gtk.Widget));
        page.append(self.url_entry.as(gtk.Widget));
        SettingsWindow.addRow(page, common.tr("Update"), self.interval.as(gtk.Widget));

        const add_button = gtk.Button.newWithLabel(common.tr("Add calendar"));
        add_button.as(gtk.Widget).addCssClass("suggested-action");
        _ = gtk.Button.signals.clicked.connect(add_button, *OnlinePage, &onAdd, self, .{});
        _ = gtk.Entry.signals.activate.connect(self.url_entry, *OnlinePage, &onActivate, self, .{});
        _ = gtk.Button.signals.clicked.connect(self.refresh_button, *OnlinePage, &onRefreshClicked, self, .{});
        const buttons = gtk.Box.new(.horizontal, 6);
        buttons.append(add_button.as(gtk.Widget));
        buttons.append(self.refresh_button.as(gtk.Widget));
        page.append(buttons.as(gtk.Widget));

        self.status.setXalign(0);
        self.status.setWrap(1);
        self.status.as(gtk.Widget).addCssClass("dim-label");
        page.append(self.status.as(gtk.Widget));

        const note = gtk.Label.new(common.tr("dkde-calendar updates these on start when you chose that above, and with Sync now in its Options menu. It never updates them otherwise."));
        note.setXalign(0);
        note.setWrap(1);
        note.as(gtk.Widget).addCssClass("dim-label");
        page.append(note.as(gtk.Widget));

        self.reload();
        return page;
    }

    fn onDestroy(_: *gtk.Box, self: *OnlinePage) callconv(.c) void {
        if (self.busy) {
            self.dead = true; // a worker thread is about to call back: let it free this
            return;
        }
        self.free();
    }

    fn free(self: *OnlinePage) void {
        self.accounts.deinit();
        self.cfg.deinit();
        gpa.destroy(self);
    }

    fn say(self: *OnlinePage, text: []const u8) void {
        var buf: [600]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{text}, 0) catch "";
        self.status.setText(z);
    }

    // ---- the list --------------------------------------------------------------------------

    const RowCtx = struct { page: *OnlinePage, id: [:0]u8, name: [:0]u8 };

    fn reload(self: *OnlinePage) void {
        while (self.list.as(gtk.Widget).getFirstChild()) |child| self.list.remove(child);
        self.accounts.deinit();
        self.cfg.reload() catch {};
        self.accounts = feeds.loadAccounts(gpa, &self.cfg) catch .{ .arena = std.heap.ArenaAllocator.init(gpa), .items = &.{} };
        if (self.accounts.items.len == 0) {
            const none = gtk.Label.new(common.tr("No online calendars."));
            none.setXalign(0);
            none.as(gtk.Widget).setMarginTop(10);
            none.as(gtk.Widget).setMarginBottom(10);
            none.as(gtk.Widget).setMarginStart(12);
            none.as(gtk.Widget).addCssClass("dim-label");
            self.list.append(none.as(gtk.Widget));
        }
        for (self.accounts.items) |acct| self.list.append(self.rowFor(acct).as(gtk.Widget));
        self.refresh_button.as(gtk.Widget).setSensitive(@intFromBool(self.accounts.items.len > 0 and !self.busy));
    }

    fn describeAccount(buf: []u8, acct: feeds.Account) [:0]const u8 {
        var when_buf: [48]u8 = undefined;
        var when: []const u8 = "not yet updated";
        if (feeds.lastSync(gpa, acct.id)) |secs| {
            if (glib.DateTime.newFromUnixUtc(secs)) |utc| {
                defer utc.unref();
                if (utc.toLocal()) |local| {
                    defer local.unref();
                    if (local.format("%Y-%m-%d %H:%M")) |t| {
                        defer glib.free(t);
                        when = std.fmt.bufPrint(&when_buf, "updated {s}", .{std.mem.span(t)}) catch when;
                    }
                }
            }
        }
        return std.fmt.bufPrintSentinel(buf, "{s}  ·  {s}", .{ feeds.hostOf(acct.url), when }, 0) catch "";
    }

    fn rowFor(self: *OnlinePage, acct: feeds.Account) *gtk.Box {
        const row = gtk.Box.new(.horizontal, 12);
        row.as(gtk.Widget).setMarginTop(8);
        row.as(gtk.Widget).setMarginBottom(8);
        row.as(gtk.Widget).setMarginStart(12);
        row.as(gtk.Widget).setMarginEnd(12);
        const texts = gtk.Box.new(.vertical, 2);
        texts.as(gtk.Widget).setHexpand(1);
        texts.as(gtk.Widget).setValign(.center);
        const name_z = gpa.dupeSentinel(u8, acct.name, 0) catch @panic("OOM");
        const title = gtk.Label.new(name_z);
        title.setXalign(0);
        title.setEllipsize(.end);
        texts.append(title.as(gtk.Widget));
        var buf: [300]u8 = undefined;
        const sub = gtk.Label.new(describeAccount(&buf, acct));
        sub.setXalign(0);
        sub.setEllipsize(.end);
        sub.as(gtk.Widget).addCssClass("dkde-setting-desc");
        texts.append(sub.as(gtk.Widget));
        row.append(texts.as(gtk.Widget));

        const ctx = gpa.create(RowCtx) catch @panic("OOM");
        ctx.* = .{ .page = self, .id = gpa.dupeSentinel(u8, acct.id, 0) catch @panic("OOM"), .name = name_z };
        _ = gtk.Widget.signals.destroy.connect(row, *RowCtx, &onRowDestroy, ctx, .{});

        const on = gtk.Switch.new();
        on.setActive(@intFromBool(acct.enabled));
        on.as(gtk.Widget).setValign(.center);
        on.as(gtk.Widget).setTooltipText(common.tr("Show this calendar"));
        _ = gtk.Switch.signals.state_set.connect(on, *RowCtx, &onSwitch, ctx, .{});
        row.append(on.as(gtk.Widget));

        const remove = gtk.Button.newWithLabel(common.tr("Remove"));
        remove.as(gtk.Widget).setValign(.center);
        remove.as(gtk.Widget).addCssClass("destructive-action");
        _ = gtk.Button.signals.clicked.connect(remove, *RowCtx, &onRemove, ctx, .{});
        row.append(remove.as(gtk.Widget));
        return row;
    }

    fn onRowDestroy(_: *gtk.Box, ctx: *RowCtx) callconv(.c) void {
        gpa.free(ctx.id);
        gpa.free(ctx.name);
        gpa.destroy(ctx);
    }

    fn accountById(self: *OnlinePage, id: []const u8) ?feeds.Account {
        for (self.accounts.items) |a| if (std.mem.eql(u8, a.id, id)) return a;
        return null;
    }

    fn onSwitch(_: *gtk.Switch, state: c_int, ctx: *RowCtx) callconv(.c) c_int {
        const self = ctx.page;
        var acct = self.accountById(ctx.id) orelse return 0;
        acct.enabled = state != 0;
        feeds.saveAccount(gpa, &self.cfg, acct) catch |e| self.say(@errorName(e));
        return 0;
    }

    fn onRemove(button: *gtk.Button, ctx: *RowCtx) callconv(.c) void {
        const Ask = struct {
            ctx_page: *OnlinePage,
            id: [:0]u8,

            fn answered(ask: *@This(), index: c_int) void {
                defer gpa.destroy(ask);
                defer gpa.free(ask.id);
                if (index != 1) return;
                const p = ask.ctx_page;
                feeds.removeAccount(gpa, &p.cfg, ask.id) catch |e| {
                    p.say(@errorName(e));
                    return;
                };
                p.say("Removed. Its events are no longer shown.");
                p.reload();
            }
        };
        const ask = gpa.create(Ask) catch return;
        ask.* = .{ .ctx_page = ctx.page, .id = gpa.dupeSentinel(u8, ctx.id, 0) catch {
            gpa.destroy(ask);
            return;
        } };
        const parent: ?*gtk.Window = if (button.as(gtk.Widget).getRoot()) |root| @ptrCast(@alignCast(root)) else null;
        common.dialogs.choose(parent, common.tr("Remove this calendar?"), ctx.name, &.{ "Cancel", "Remove" }, 0, Ask, Ask.answered, ask);
    }

    // ---- adding ----------------------------------------------------------------------------

    fn onActivate(_: *gtk.Entry, self: *OnlinePage) callconv(.c) void {
        self.add();
    }

    fn onAdd(_: *gtk.Button, self: *OnlinePage) callconv(.c) void {
        self.add();
    }

    fn add(self: *OnlinePage) void {
        const typed = std.mem.span(self.url_entry.as(gtk.Editable).getText());
        const url = feeds.normalizeUrl(gpa, typed) catch |e| {
            self.say(feeds.describe(e));
            return;
        };
        defer gpa.free(url);
        var name: []const u8 = std.mem.trim(u8, std.mem.span(self.name_entry.as(gtk.Editable).getText()), " \t");
        if (name.len == 0) name = feeds.hostOf(url);
        var idbuf: [32]u8 = undefined;
        const id = common.events.newId(&idbuf, glib.getRealTime());
        const index = self.interval.getSelected();
        feeds.saveAccount(gpa, &self.cfg, .{
            .id = id,
            .name = name,
            .url = url,
            .enabled = true,
            .refresh_minutes = if (index < intervals.len) intervals[index] else 0,
        }) catch |e| {
            self.say(@errorName(e));
            return;
        };
        self.name_entry.as(gtk.Editable).setText("");
        self.url_entry.as(gtk.Editable).setText("");
        self.reload();
        self.refreshNow(); // asked for just now, so fetch it now
    }

    // ---- updating --------------------------------------------------------------------------

    fn onRefreshClicked(_: *gtk.Button, self: *OnlinePage) callconv(.c) void {
        self.refreshNow();
    }

    fn refreshNow(self: *OnlinePage) void {
        if (self.busy) {
            self.pending = true; // started again as soon as this one ends
            return;
        }
        const started = feeds.Job.start(gpa, self.accounts.items, false, &refreshed, self) catch false;
        if (!started) return self.say("Nothing to update.");
        self.busy = true;
        // No adding, switching or removing while the download runs: it would write a copy
        // for an account that was just removed.
        self.list.as(gtk.Widget).setSensitive(0);
        self.refresh_button.as(gtk.Widget).setSensitive(0);
        self.say("Updating…");
    }

    fn refreshed(job: *const feeds.Job, user: ?*anyopaque) void {
        const self: *OnlinePage = @ptrCast(@alignCast(user.?));
        self.busy = false;
        if (self.dead) return self.free();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        for (job.accounts, job.results) |acct, res| {
            if (!res.ran) continue;
            if (out.items.len > 0) out.appendSlice(gpa, "  ") catch {};
            if (res.err) |e| {
                out.print(gpa, "{s}: {s}", .{ acct.name, feeds.describe(e) }) catch {};
            } else out.print(gpa, "{s}: {d} events.", .{ acct.name, res.count }) catch {};
        }
        self.say(out.items);
        self.list.as(gtk.Widget).setSensitive(1);
        self.reload();
        // The panel's reminders read the new copies when it hears of them.
        feeds.dropOrphans(gpa, job.accounts, self.accounts.items);
        feeds.markUpdated(gpa);
        if (self.pending) {
            self.pending = false;
            self.refreshNow();
        }
    }
};
