//! The Users page: who is signed in, and what each user's programs use
//! together. A user can be signed out (their session ended); signing out
//! someone else needs the administrator password.

const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");

const simplelist = @import("simplelist.zig");
const sampler_mod = @import("sampler.zig");
const perf = @import("perf.zig");
const columns = @import("columns.zig");
const services = @import("services.zig");
const proc = @import("proc.zig");

const Sampler = sampler_mod.Sampler;
const t = common.tr;

const User = struct {
    uid: u32,
    name: [32]u8 = @splat(0),
    state: [16]u8 = @splat(0),
    cpu: f64 = 0,
    memory_kb: u64 = 0,
    disk_rate: f64 = 0,
    gpu: f64 = 0,
    processes: u32 = 0,

    fn nameSlice(self: *const User) []const u8 {
        return std.mem.sliceTo(&self.name, 0);
    }
};

/// "UID USER LINGER STATE" lines of `loginctl list-users --no-legend`.
pub fn parseUsers(text: []const u8, out: []User) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (n == out.len) break;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const uid = std.fmt.parseInt(u32, it.next() orelse continue, 10) catch continue;
        const name = it.next() orelse continue;
        var last: []const u8 = "";
        while (it.next()) |w| last = w;
        var u: User = .{ .uid = uid };
        @memcpy(u.name[0..@min(name.len, 31)], name[0..@min(name.len, 31)]);
        @memcpy(u.state[0..@min(last.len, 15)], last[0..@min(last.len, 15)]);
        out[n] = u;
        n += 1;
    }
    return n;
}

const Col = enum { user, status, cpu, memory, disk, gpu, processes };

pub const Page = struct {
    gpa: std.mem.Allocator,
    window: *gtk.Window,
    sampler: *Sampler,
    widget: *gtk.Widget,
    list: *simplelist.SimpleList,
    users: [64]User = undefined,
    count: usize = 0,
    /// From loginctl: who has a session.
    signed_in: [64]User = undefined,
    signed_count: usize = 0,
    guard: *common.proc.Guard(Page),
    sign_out: *gtk.Button,
    asked: bool = false,
    /// "Show processes": the owner shows the user's processes.
    on_show: ?*const fn (*anyopaque, []const u8) void = null,
    owner: *anyopaque = undefined,
    pending_uid: u32 = 0,

    const specs = [_]simplelist.ColumnSpec{
        .{ .title = "User", .expand = true },
        .{ .title = "Status", .width = 110 },
        .{ .title = "CPU", .right = true, .width = 80, .big_first = true },
        .{ .title = "Memory", .right = true, .width = 100, .big_first = true },
        .{ .title = "Disk", .right = true, .width = 100, .big_first = true },
        .{ .title = "GPU", .right = true, .width = 70, .big_first = true },
        .{ .title = "Processes", .right = true, .width = 90, .big_first = true },
    };

    pub fn create(gpa: std.mem.Allocator, window: *gtk.Window, sampler: *Sampler) *Page {
        const self = gpa.create(Page) catch @panic("OOM");
        self.* = .{
            .gpa = gpa,
            .window = window,
            .sampler = sampler,
            .widget = undefined,
            .list = undefined,
            .guard = undefined,
            .sign_out = gtk.Button.newWithLabel(t("Sign out")),
        };
        self.guard = common.proc.Guard(Page).create(self);
        self.list = simplelist.SimpleList.create(gpa, &specs, .{
            .owner = self,
            .text = text,
            .less = less,
            .key = key,
            .heat = heat,
            .icon = icon,
            .activate = onActivate,
            .selection_changed = onSelection,
        });
        const root = gtk.Box.new(.vertical, 0);
        const bar = services.commandBar(t("Users"));
        const show = gtk.Button.newWithLabel(t("Show processes"));
        _ = gtk.Button.signals.clicked.connect(show, *Page, &onShow, self, .{});
        bar.append(show.as(gtk.Widget));
        self.sign_out.as(gtk.Widget).setSensitive(0);
        _ = gtk.Button.signals.clicked.connect(self.sign_out, *Page, &onSignOut, self, .{});
        bar.append(self.sign_out.as(gtk.Widget));
        root.append(bar.as(gtk.Widget));
        root.append(self.list.widget);
        self.widget = root.as(gtk.Widget);
        self.list.sortBy(0, false);
        return self;
    }

    pub fn destroy(self: *Page) void {
        self.guard.kill();
        self.list.destroy();
        self.gpa.destroy(self);
    }

    /// Who is signed in: asked again now and then.
    pub fn reload(self: *Page) void {
        if (self.asked or !common.proc.hasProgram("loginctl")) return;
        self.asked = true;
        common.proc.run(Page, self.guard, &.{ "loginctl", "list-users", "--no-legend" }, onUsers);
    }

    fn onUsers(self: *Page, ok: bool, out: []const u8) void {
        self.asked = false;
        self.signed_count = if (ok) parseUsers(out, &self.signed_in) else 0;
        self.refresh();
    }

    pub fn refresh(self: *Page) void {
        const s = self.sampler;
        self.count = 0;
        // The signed-in users, and always the one running this.
        for (self.signed_in[0..self.signed_count]) |u| self.add(u);
        if (self.find(s.my_uid) == null) {
            var u: User = .{ .uid = s.my_uid };
            const name = std.mem.span(glib.getUserName());
            @memcpy(u.name[0..@min(name.len, 31)], name[0..@min(name.len, 31)]);
            @memcpy(u.state[0..6], "active");
            self.add(u);
        }
        for (self.users[0..self.count]) |*u| {
            u.cpu = 0;
            u.memory_kb = 0;
            u.disk_rate = 0;
            u.gpu = 0;
            u.processes = 0;
        }
        var it = s.processes.valueIterator();
        while (it.next()) |p| {
            const u = self.find(p.uid) orelse continue;
            u.cpu += p.cpu;
            u.memory_kb += p.private_kb;
            u.disk_rate += p.disk_rate;
            u.gpu = @max(u.gpu, p.gpu);
            u.processes += 1;
        }
        self.list.update(self.count);
        onSelection(self);
    }

    fn add(self: *Page, u: User) void {
        if (self.count == self.users.len or self.find(u.uid) != null) return;
        self.users[self.count] = u;
        self.count += 1;
    }

    fn find(self: *Page, uid: u32) ?*User {
        for (self.users[0..self.count]) |*u| if (u.uid == uid) return u;
        return null;
    }

    fn text(owner: *anyopaque, row: usize, col: usize, buf: []u8) []const u8 {
        const self: *Page = @ptrCast(@alignCast(owner));
        const u = &self.users[row];
        return switch (@as(Col, @enumFromInt(col))) {
            .user => if (u.uid == self.sampler.my_uid) std.fmt.bufPrint(buf, "{s} (you)", .{u.nameSlice()}) catch "" else u.nameSlice(),
            .status => blk: {
                const st = std.mem.sliceTo(&u.state, 0);
                break :blk if (std.mem.eql(u8, st, "active")) "Active" else if (std.mem.eql(u8, st, "online")) "Signed in" else if (std.mem.eql(u8, st, "lingering")) "Services only" else if (std.mem.eql(u8, st, "closing")) "Signing out" else st;
            },
            .cpu => std.fmt.bufPrint(buf, "{d:.1}%", .{u.cpu}) catch "",
            .memory => std.fmt.bufPrint(buf, "{d:.1} MB", .{@as(f64, @floatFromInt(u.memory_kb)) / 1024}) catch "",
            .disk => blk: {
                var rb: [32]u8 = undefined;
                break :blk std.fmt.bufPrint(buf, "{s}", .{perf.fmtByteRate(&rb, u.disk_rate)}) catch "";
            },
            .gpu => std.fmt.bufPrint(buf, "{d:.0}%", .{u.gpu * 100}) catch "",
            .processes => std.fmt.bufPrint(buf, "{d}", .{u.processes}) catch "",
        };
    }

    fn less(owner: *anyopaque, a: usize, b: usize, col: usize) bool {
        const self: *Page = @ptrCast(@alignCast(owner));
        const x = &self.users[a];
        const y = &self.users[b];
        return switch (@as(Col, @enumFromInt(col))) {
            .user, .status => std.ascii.lessThanIgnoreCase(x.nameSlice(), y.nameSlice()),
            .cpu => x.cpu < y.cpu,
            .memory => x.memory_kb < y.memory_kb,
            .disk => x.disk_rate < y.disk_rate,
            .gpu => x.gpu < y.gpu,
            .processes => x.processes < y.processes,
        };
    }

    fn key(owner: *anyopaque, row: usize) u64 {
        const self: *Page = @ptrCast(@alignCast(owner));
        return self.users[row].uid;
    }

    fn heat(owner: *anyopaque, row: usize, col: usize) u8 {
        const self: *Page = @ptrCast(@alignCast(owner));
        const u = &self.users[row];
        const p: sampler_mod.Process = .{ .pid = 0, .cpu = u.cpu, .private_kb = u.memory_kb, .disk_rate = u.disk_rate, .gpu = u.gpu };
        return switch (@as(Col, @enumFromInt(col))) {
            .cpu => columns.heat(&p, .cpu),
            .memory => columns.heat(&p, .memory),
            .disk => columns.heat(&p, .disk),
            .gpu => columns.heat(&p, .gpu),
            else => 0,
        };
    }

    fn icon(_: *anyopaque, _: usize) [:0]const u8 {
        return "avatar-default-symbolic";
    }

    fn selected(self: *Page) ?*User {
        const row = self.list.selectedRow() orelse return null;
        if (row >= self.count) return null;
        return &self.users[row];
    }

    fn onSelection(owner: *anyopaque) void {
        const self: *Page = @ptrCast(@alignCast(owner));
        self.sign_out.as(gtk.Widget).setSensitive(@intFromBool(self.selected() != null and common.proc.hasProgram("loginctl")));
    }

    fn onActivate(owner: *anyopaque, _: usize) void {
        const self: *Page = @ptrCast(@alignCast(owner));
        onShow(undefined, self);
    }

    fn onShow(_: *gtk.Button, self: *Page) callconv(.c) void {
        const u = self.selected() orelse return;
        if (self.on_show) |f| f(self.owner, u.nameSlice());
    }

    fn onSignOut(_: *gtk.Button, self: *Page) callconv(.c) void {
        const u = self.selected() orelse return;
        self.pending_uid = u.uid;
        var b: [160]u8 = undefined;
        const yourself = u.uid == self.sampler.my_uid;
        const message = if (yourself)
            std.fmt.bufPrintSentinel(&b, "Sign out now?", .{}, 0) catch return
        else
            std.fmt.bufPrintSentinel(&b, "Sign out {s}?", .{u.nameSlice()}, 0) catch return;
        common.dialogs.choose(self.window, message, t("All of the user's programs are closed. Unsaved work in them is lost."), &.{ t("Cancel"), t("Sign out") }, 0, Page, onSignOutAnswer, self);
    }

    fn onSignOutAnswer(self: *Page, index: c_int) void {
        if (index != 1) return;
        const u = self.find(self.pending_uid) orelse return;
        var nb: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&nb, "{s}", .{u.nameSlice()}) catch return;
        if (u.uid == self.sampler.my_uid) {
            common.proc.run(Page, self.guard, &.{ "loginctl", "terminate-user", name }, onDone);
        } else {
            common.elevate.run(self.window, "Sign out another user", &.{ "loginctl", "terminate-user", name }, "", Page, onElevated, self);
        }
    }

    fn onDone(self: *Page, ok: bool, _: []const u8) void {
        if (!ok) common.dialogs.showError(self.window, t("The user could not be signed out"), null);
        self.reload();
    }

    fn onElevated(self: *Page, outcome: common.elevate.Outcome, _: []const u8) void {
        if (outcome == .failed) common.dialogs.showError(self.window, t("The user could not be signed out"), null);
        self.reload();
    }
};

test "loginctl users" {
    var out: [4]User = undefined;
    const n = parseUsers("1000 dakota no active\n 1001 guest  yes lingering\n", &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("guest", out[1].nameSlice());
    try std.testing.expectEqualStrings("lingering", std.mem.sliceTo(&out[1].state, 0));
}
