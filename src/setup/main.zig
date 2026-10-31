//! dkde-setup: a first-run check that finds what is missing for a working
//! dkde session and fixes what it can.
//!
//! Two kinds of fix:
//!   * user-level: files under the user's own config directory. Applied after
//!     one confirmation; existing labwc files are only added to, and backed up
//!     once before the first edit.
//!   * system-level: anything that needs root. Never run silently: the exact
//!     command and the reason are shown, and each is run only on a "y".
//!
//! `dkde-setup --check` only reports (exit status 1 if something is missing);
//! `dkde-setup --yes` applies the user-level fixes without asking.

const std = @import("std");
const glib = @import("glib2");
const giounix = @import("giounix2");
const gobject = @import("gobject2");
const common = @import("common");

extern fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern fn system(command: [*:0]const u8) c_int;

fn out(text: []const u8) void {
    var rest = text;
    while (rest.len > 0) {
        const n = write(1, rest.ptr, rest.len);
        if (n <= 0) return;
        rest = rest[@intCast(n)..];
    }
}

fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    out(std.fmt.bufPrint(&buf, fmt, args) catch return);
}

/// Asks a yes/no question; `default` is used for a bare Enter or end of input.
fn confirm(question: []const u8, default: bool) bool {
    print("{s} [{s}] ", .{ question, if (default) "Y/n" else "y/N" });
    var buf: [16]u8 = undefined;
    const n = read(0, &buf, buf.len);
    if (n <= 0) return default;
    const answer = std.mem.trim(u8, buf[0..@intCast(n)], " \t\r\n");
    if (answer.len == 0) return default;
    return answer[0] == 'y' or answer[0] == 'Y';
}

const Status = enum { ok, todo, info };

const Item = struct {
    title: []const u8,
    status: Status,
    detail: []const u8 = "",
    /// User-level fix: new content for `path`, owned by the checker's allocator.
    write_path: ?[:0]const u8 = null,
    write_content: ?[]const u8 = null,
    /// User-level fix: folders to create (absolute paths).
    make_dirs: []const [:0]const u8 = &.{},
    /// System-level fix: a shell command (needs root) and why.
    command: ?[]const u8 = null,
    reason: []const u8 = "",
};

const Setup = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Item) = .empty,
    /// Everything allocated for items lives here.
    arena: std.heap.ArenaAllocator,

    fn init(allocator: std.mem.Allocator) Setup {
        return .{ .allocator = allocator, .arena = .init(allocator) };
    }

    fn deinit(self: *Setup) void {
        self.items.deinit(self.allocator);
        self.arena.deinit();
    }

    fn add(self: *Setup, item: Item) void {
        self.items.append(self.allocator, item) catch {};
    }

    fn fmt(self: *Setup, comptime f: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(self.arena.allocator(), f, args) catch "";
    }

    fn fmtZ(self: *Setup, comptime f: []const u8, args: anytype) [:0]const u8 {
        return std.fmt.allocPrintSentinel(self.arena.allocator(), f, args, 0) catch "";
    }

    fn readFile(self: *Setup, path: [:0]const u8) ?[]const u8 {
        var contents: [*]u8 = undefined;
        var length: usize = 0;
        if (glib.fileGetContents(path, &contents, &length, null) == 0) return null;
        defer glib.free(contents);
        return self.arena.allocator().dupe(u8, contents[0..length]) catch null;
    }

    fn exists(path: [:0]const u8) bool {
        return glib.fileTest(path, .{ .exists = true }) != 0;
    }

    // ---- user-level checks ----------------------------------------------------

    fn labwcFile(self: *Setup, name: []const u8) [:0]const u8 {
        return self.fmtZ("{s}/labwc/{s}", .{ std.mem.span(glib.getUserConfigDir()), name });
    }

    const user_dirs = [_]struct { key: []const u8, name: []const u8 }{
        .{ .key = "DESKTOP", .name = "Desktop" },
        .{ .key = "DOCUMENTS", .name = "Documents" },
        .{ .key = "DOWNLOAD", .name = "Downloads" },
        .{ .key = "MUSIC", .name = "Music" },
        .{ .key = "PICTURES", .name = "Pictures" },
        .{ .key = "VIDEOS", .name = "Videos" },
        .{ .key = "TEMPLATES", .name = "Templates" },
        .{ .key = "PUBLICSHARE", .name = "Public" },
    };

    /// The standard home folders, and the `user-dirs.dirs` file that names
    /// them (GLib, the file manager and the start menu all read it).
    fn checkUserDirs(self: *Setup) void {
        const home = std.mem.span(glib.getHomeDir());
        var missing: std.ArrayList([:0]const u8) = .empty;
        for (user_dirs) |d| {
            const path = self.fmtZ("{s}/{s}", .{ home, d.name });
            if (!exists(path)) missing.append(self.arena.allocator(), path) catch {};
        }
        const file = self.fmtZ("{s}/user-dirs.dirs", .{std.mem.span(glib.getUserConfigDir())});
        var content: std.ArrayList(u8) = .empty;
        const has_file = exists(file);
        if (!has_file) {
            content.appendSlice(self.arena.allocator(), "# Written by dkde-setup.\n") catch {};
            for (user_dirs) |d| {
                content.appendSlice(self.arena.allocator(), self.fmt("XDG_{s}_DIR=\"$HOME/{s}\"\n", .{ d.key, d.name })) catch {};
            }
        }
        if (missing.items.len == 0 and has_file) {
            self.add(.{ .title = "standard home folders exist", .status = .ok });
            return;
        }
        self.add(.{
            .title = "standard home folders exist",
            .status = .todo,
            .detail = "create Desktop, Documents, Downloads, Music, Pictures, Videos, Templates and Public as needed",
            .write_path = if (has_file) null else file,
            .write_content = if (has_file) null else content.items,
            .make_dirs = missing.items,
        });
    }

    fn checkAutostart(self: *Setup) void {
        const path = self.labwcFile("autostart");
        const current = self.readFile(path) orelse "";
        const updated = common.labwc.ensureAutostart(self.arena.allocator(), current) catch null;
        if (updated) |content| {
            self.add(.{ .title = "labwc autostart starts the panel", .status = .todo, .detail = self.fmt("add the panel to {s}", .{path}), .write_path = path, .write_content = content });
        } else self.add(.{ .title = "labwc autostart starts the panel", .status = .ok });
    }

    fn checkKeybinds(self: *Setup) void {
        const path = self.labwcFile("rc.xml");
        const current = self.readFile(path) orelse "";
        // dkde owns every shortcut, labwc's window ones included, so they can be
        // changed in one place (Settings > Keyboard shortcuts).
        const updated = common.labwc.takeOverKeybinds(self.arena.allocator(), current, &common.labwc.dkde_keybinds) catch null;
        const title = "labwc keybindings (dkde's shortcuts, in place of labwc's built-in ones)";
        if (updated) |content| {
            self.add(.{ .title = title, .status = .todo, .detail = self.fmt("add the missing ones to {s} and drop labwc's <default />; your own are kept", .{path}), .write_path = path, .write_content = content });
        } else self.add(.{ .title = title, .status = .ok });
    }

    fn checkEnvironment(self: *Setup) void {
        const path = self.labwcFile("environment");
        const current = self.readFile(path) orelse "";
        var has = false;
        var lines = std.mem.splitScalar(u8, current, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, std.mem.trim(u8, line, " \t"), "NO_AT_BRIDGE=")) has = true;
        }
        if (has) return self.add(.{ .title = "no accessibility-bus warnings (NO_AT_BRIDGE)", .status = .ok });
        const content = common.labwc.setEnvVar(self.arena.allocator(), current, "NO_AT_BRIDGE", "1") catch return;
        self.add(.{ .title = "no accessibility-bus warnings (NO_AT_BRIDGE)", .status = .todo, .detail = self.fmt("set NO_AT_BRIDGE=1 in {s} (dkde has no D-Bus/AT-SPI)", .{path}), .write_path = path, .write_content = content });
    }

    fn checkPrograms(self: *Setup) void {
        const names = [_][:0]const u8{ "dkde-panel", "dkde-term", "dkde-files", "dkde-settings" };
        var missing: usize = 0;
        for (names) |name| {
            if (glib.findProgramInPath(name)) |p| glib.free(p) else missing += 1;
        }
        if (missing == 0) return self.add(.{ .title = "dkde programs are on PATH", .status = .ok });
        self.add(.{ .title = "dkde programs are on PATH", .status = .info, .detail = "install them (`zig build install --prefix ~/.local`) and put ~/.local/bin on PATH" });
    }

    fn checkDesktopEntries(self: *Setup) void {
        if (giounix.DesktopAppInfo.new("dkde-term.desktop")) |info| {
            info.as(gobject.Object).unref();
            return self.add(.{ .title = "dkde desktop entries are installed", .status = .ok });
        }
        self.add(.{ .title = "dkde desktop entries are installed", .status = .info, .detail = "the start menu needs them in an applications directory (`zig build install` does this)" });
    }

    fn checkIcons(self: *Setup) void {
        const home = std.mem.span(glib.getHomeDir());
        const candidates = [_][:0]const u8{ "/usr/share/icons/Papirus", self.fmtZ("{s}/.local/share/icons/Papirus", .{home}) };
        for (candidates) |c| if (exists(c)) return self.add(.{ .title = "Papirus icon theme", .status = .ok });
        self.add(.{ .title = "Papirus icon theme", .status = .info, .detail = "install it for the default icons (Ubuntu: sudo apt install papirus-icon-theme)" });
    }

    // ---- system-level checks --------------------------------------------------

    fn isWsl(self: *Setup) bool {
        const release = self.readFile("/proc/sys/kernel/osrelease") orelse return false;
        return std.ascii.findIgnoreCase(release, "microsoft") != null or std.ascii.findIgnoreCase(release, "wsl") != null;
    }

    fn hasLogind() bool {
        return exists("/run/systemd/seats");
    }

    fn checkStickyBit(self: *Setup) void {
        if (!self.isWsl()) return;
        const path: [:0]const u8 = "/tmp/.X11-unix";
        if (!exists(path)) return;
        var info_ok = false;
        // st_mode sticky bit: 0o1000. GLib has no stat; read it through GIO.
        const file = @import("gio2").File.newForPath(path);
        defer file.as(gobject.Object).unref();
        if (file.queryInfo("unix::mode", .{}, null, null)) |info| {
            defer info.as(gobject.Object).unref();
            info_ok = info.getAttributeUint32("unix::mode") & 0o1000 != 0;
        }
        if (info_ok) return self.add(.{ .title = "WSL: /tmp/.X11-unix has the sticky bit", .status = .ok });
        self.add(.{
            .title = "WSL: /tmp/.X11-unix has the sticky bit",
            .status = .todo,
            .command = "sudo chmod +t /tmp/.X11-unix",
            .reason = "labwc prepares for Xwayland and exits when this directory lacks the bit. dkde itself does not use X11. Without it, scripts/dev-session.sh needs a workaround that breaks sudo and Chrome. WSL resets the directory on restart.",
        });
    }

    fn checkSeatGroups(self: *Setup) void {
        if (hasLogind()) return;
        const status = self.readFile("/proc/self/status") orelse return;
        const group_file = self.readFile("/etc/group") orelse return;
        const gids = common.user.parseGroups(self.arena.allocator(), status) catch return;
        var need_video = true;
        var need_input = true;
        var lines = std.mem.splitScalar(u8, group_file, '\n');
        while (lines.next()) |line| {
            var f = std.mem.splitScalar(u8, line, ':');
            const name = f.next() orelse continue;
            _ = f.next();
            const gid = std.fmt.parseInt(u32, f.next() orelse continue, 10) catch continue;
            const member = std.mem.indexOfScalar(u32, gids, gid) != null;
            if (std.mem.eql(u8, name, "video") and member) need_video = false;
            if (std.mem.eql(u8, name, "input") and member) need_input = false;
        }
        if (!need_video and !need_input) return self.add(.{ .title = "seat access (groups video and input)", .status = .ok });
        self.add(.{
            .title = "seat access (groups video and input)",
            .status = .todo,
            .command = self.fmt("sudo usermod -aG video,input {s}", .{std.mem.span(glib.getUserName())}),
            .reason = "there is no logind here to hand the session its display and input devices, so the user needs these groups (a seat daemon such as seatd is also needed). Log out and in afterwards.",
        });
    }

    /// null when the group does not exist; otherwise whether the user is in it,
    /// by the running process's groups or by the member list in /etc/group.
    fn isMember(group_file: []const u8, gids: []const u32, user: []const u8, name: []const u8) ?bool {
        var lines = std.mem.splitScalar(u8, group_file, '\n');
        while (lines.next()) |line| {
            var f = std.mem.splitScalar(u8, line, ':');
            const group = f.next() orelse continue;
            if (!std.mem.eql(u8, group, name)) continue;
            _ = f.next();
            const gid = std.fmt.parseInt(u32, f.next() orelse return false, 10) catch return false;
            if (std.mem.indexOfScalar(u32, gids, gid) != null) return true;
            var members = std.mem.splitScalar(u8, f.next() orelse "", ',');
            while (members.next()) |m| if (std.mem.eql(u8, std.mem.trim(u8, m, " \r"), user)) return true;
            return false;
        }
        return null;
    }

    const service_groups = [_]struct { name: []const u8, why: []const u8 }{
        .{ .name = "audio", .why = "sound devices (without logind)" },
        .{ .name = "netdev", .why = "NetworkManager and airplane mode (rfkill)" },
        .{ .name = "plugdev", .why = "removable drives" },
        .{ .name = "bluetooth", .why = "Bluetooth (BlueZ)" },
        .{ .name = "lpadmin", .why = "managing printers without the root password" },
    };

    /// Groups that let the user reach hardware and services the Settings pages
    /// and quick settings use. Only groups that exist on this system are asked for.
    fn checkServiceGroups(self: *Setup) void {
        const status = self.readFile("/proc/self/status") orelse return;
        const group_file = self.readFile("/etc/group") orelse return;
        const gids = common.user.parseGroups(self.arena.allocator(), status) catch return;
        const user = std.mem.span(glib.getUserName());

        var missing: std.ArrayList(u8) = .empty;
        var reasons: std.ArrayList(u8) = .empty;
        const a = self.arena.allocator();
        for (service_groups) |g| {
            // Without logind nothing else hands out sound devices; with it, audio is not needed.
            if (std.mem.eql(u8, g.name, "audio") and hasLogind()) continue;
            const member = isMember(group_file, gids, user, g.name) orelse continue;
            if (member) continue;
            if (missing.items.len > 0) {
                missing.append(a, ',') catch {};
                reasons.appendSlice(a, "; ") catch {};
            }
            missing.appendSlice(a, g.name) catch {};
            reasons.appendSlice(a, g.name) catch {};
            reasons.appendSlice(a, ": ") catch {};
            reasons.appendSlice(a, g.why) catch {};
        }
        if (missing.items.len == 0) return self.add(.{ .title = "device and service groups", .status = .ok });
        self.add(.{
            .title = "device and service groups",
            .status = .todo,
            .detail = self.fmt("add {s} to: {s}", .{ user, missing.items }),
            .command = self.fmt("sudo usermod -aG {s} {s}", .{ missing.items, user }),
            .reason = self.fmt("these groups let you use hardware and services without root ({s}). Log out and in afterwards.", .{reasons.items}),
        });
    }

    fn checkSessionEntry(self: *Setup) void {
        const path: [:0]const u8 = "/usr/share/wayland-sessions/dkde.desktop";
        if (exists(path)) return self.add(.{ .title = "login-manager session entry", .status = .ok });
        self.add(.{
            .title = "login-manager session entry (optional)",
            .status = .todo,
            .command = "printf '[Desktop Entry]\\nName=dkde\\nComment=dkde desktop on labwc\\nExec=labwc\\nType=Application\\n' | sudo tee /usr/share/wayland-sessions/dkde.desktop >/dev/null",
            .reason = "only needed to pick dkde from a graphical login screen. The session runs labwc, which reads ~/.config/labwc/autostart.",
        });
    }

    fn checkXSession(self: *Setup) void {
        // Only relevant where an X server exists.
        if (glib.findProgramInPath("Xorg")) |p| glib.free(p) else return;
        const path: [:0]const u8 = "/usr/share/xsessions/dkde-x11.desktop";
        if (exists(path)) return self.add(.{ .title = "X11 session entry (for Xorg users)", .status = .ok });
        self.add(.{
            .title = "X11 session entry (optional, for Xorg users)",
            .status = .todo,
            .command = "printf '[Desktop Entry]\\nName=dkde (X11)\\nComment=dkde desktop on Xorg\\nExec=dkde-xsession\\nType=XSession\\nDesktopNames=dkde\\n' | sudo tee /usr/share/xsessions/dkde-x11.desktop >/dev/null",
            .reason = "lets you pick dkde from a graphical login screen when running Xorg. It needs a dkde built with -Dx11=true and an EWMH window manager such as openbox. From a console, scripts/dkde-startx works without it.",
        });
    }

    fn run(self: *Setup) void {
        self.checkUserDirs();
        self.checkAutostart();
        self.checkKeybinds();
        self.checkEnvironment();
        self.checkPrograms();
        self.checkDesktopEntries();
        self.checkIcons();
        self.checkStickyBit();
        self.checkSeatGroups();
        self.checkServiceGroups();
        self.checkSessionEntry();
        self.checkXSession();
    }

    // ---- reporting and fixing --------------------------------------------------

    fn report(self: *const Setup) usize {
        var todo: usize = 0;
        for (self.items.items) |item| {
            const tag = switch (item.status) {
                .ok => "ok   ",
                .todo => "FIX  ",
                .info => "note ",
            };
            print("  [{s}] {s}\n", .{ tag, item.title });
            if (item.status != .ok and item.detail.len > 0) print("          {s}\n", .{item.detail});
            if (item.status == .todo) todo += 1;
        }
        return todo;
    }

    fn applyUserFixes(self: *Setup) void {
        for (self.items.items) |item| {
            for (item.make_dirs) |dir| {
                if (glib.mkdirWithParents(dir, 0o755) == 0) print("  created {s}\n", .{dir}) else print("  could not create {s}\n", .{dir});
            }
            const path = item.write_path orelse continue;
            const content = item.write_content orelse continue;
            const dir = glib.pathGetDirname(path);
            defer glib.free(dir);
            _ = glib.mkdirWithParents(dir, 0o755);

            // One backup of an existing file, before the first edit.
            const backup = self.fmtZ("{s}.dkde-backup", .{path});
            if (exists(path) and !exists(backup)) {
                if (self.readFile(path)) |old| _ = glib.fileSetContents(backup, old.ptr, @intCast(old.len), null);
            }
            if (glib.fileSetContents(path, content.ptr, @intCast(content.len), null) != 0) {
                print("  wrote {s}\n", .{path});
            } else print("  could not write {s}\n", .{path});
        }
    }

    fn offerSystemFixes(self: *Setup) void {
        for (self.items.items) |item| {
            const command = item.command orelse continue;
            if (item.status != .todo) continue;
            print("\n{s}\n  why: {s}\n  command: {s}\n", .{ item.title, item.reason, command });
            if (!confirm("Run it now?", false)) {
                print("  skipped; you can run it yourself later.\n", .{});
                continue;
            }
            const z = self.arena.allocator().dupeSentinel(u8, command, 0) catch continue;
            const status = system(z);
            print("  {s}\n", .{if (status == 0) "done" else "the command failed"});
        }
    }
};

test "group membership by gid or member list" {
    const groups = "netdev:x:108:alice,bob\nplugdev:x:46:\naudio:x:29:bob\n";
    try std.testing.expectEqual(@as(?bool, true), Setup.isMember(groups, &.{}, "alice", "netdev"));
    try std.testing.expectEqual(@as(?bool, false), Setup.isMember(groups, &.{}, "carol", "netdev"));
    try std.testing.expectEqual(@as(?bool, true), Setup.isMember(groups, &.{46}, "carol", "plugdev"));
    try std.testing.expectEqual(@as(?bool, null), Setup.isMember(groups, &.{}, "alice", "bluetooth"));
}

pub const std_options: std.Options = .{ .logFn = common.log.logFn, .log_level = .debug };

/// Written once setup has run for this user; see `--once`.
fn markerPath(allocator: std.mem.Allocator) ?[:0]u8 {
    return common.paths.userStateFile(allocator, "setup-done") catch null;
}

fn markerExists(allocator: std.mem.Allocator) bool {
    const path = markerPath(allocator) orelse return false;
    defer allocator.free(path);
    return glib.fileTest(path, .{ .exists = true }) != 0;
}

fn writeMarker(allocator: std.mem.Allocator) void {
    const path = markerPath(allocator) orelse return;
    defer allocator.free(path);
    const dir = glib.pathGetDirname(path);
    defer glib.free(dir);
    _ = glib.mkdirWithParents(dir, 0o755);
    const text = "dkde-setup has run for this user. Delete this file to let the first-login run repeat.\n";
    _ = glib.fileSetContents(path, text.ptr, text.len, null);
}

/// `--write-config`: complete, hand-editable files in the user's config folder.
fn writeConfig(allocator: std.mem.Allocator) void {
    const names = [_][]const u8{ "dkde.conf", "panel.conf", "term.conf", "files.conf", "hex.conf", "edit.conf" };
    for (names) |name| {
        const extra = if (std.mem.eql(u8, name, "term.conf")) common.config.term_profile_template else "";
        if (common.config.writeAllDefaults(allocator, name, extra)) |result| {
            print("{s}: {s}\n", .{ name, switch (result) {
                .created => "written with every default",
                .merged => "missing defaults added",
                .unchanged => "already complete",
            } });
        } else |err| print("{s}: {s}\n", .{ name, @errorName(err) });
    }
    print("Files are in ~/.config/dkde/. Edit them by hand; the programs pick changes up while running.\n", .{});
}

pub fn main(init: std.process.Init.Minimal) !void {
    var debug_allocator: common.perf.Gpa = .{};
    defer debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var check_only = false;
    var yes = false;
    var once = false;
    var write_config = false;
    for (init.args.vector[1..]) |arg| {
        const text = std.mem.span(arg);
        if (std.mem.eql(u8, text, "--check")) check_only = true;
        if (std.mem.eql(u8, text, "--once")) once = true;
        if (std.mem.eql(u8, text, "--write-config")) write_config = true;
        if (std.mem.eql(u8, text, "--yes") or std.mem.eql(u8, text, "-y")) yes = true;
        if (std.mem.eql(u8, text, "--help") or std.mem.eql(u8, text, "-h")) {
            out("usage: dkde-setup [--check] [--yes] [--once] [--write-config]\n  --write-config  write every config file with all defaults in it (missing files are\n                  created, existing ones only gain the keys they lack), for editing by hand\n  --check  only report; exit 1 if something is missing\n  --yes    apply user-level fixes without asking\n  --once   the first-login run: apply the user-level fixes quietly, and only if\n           setup has never run for this user (dkde-session does this)\n");
            return;
        }
    }

    if (write_config) return writeConfig(allocator);

    // The automatic run happens once. After that, setup runs only when asked
    // for by hand, so it never puts back what the user changed or removed.
    if (once and markerExists(allocator)) return;

    var setup = Setup.init(allocator);
    defer setup.deinit();
    setup.run();

    if (once) {
        // Quiet and non-interactive: user-level fixes only, nothing that needs root.
        setup.applyUserFixes();
        writeMarker(allocator);
        std.log.info("first-run setup done", .{});
        return;
    }

    out("dkde setup\n\n");
    const todo = setup.report();
    out("\n");
    if (check_only) {
        if (todo > 0) std.process.exit(1);
        return;
    }
    // A hand run counts as the setup, so the first login does not repeat it.
    defer writeMarker(allocator);
    if (todo == 0) {
        out("Everything is in place.\n");
        return;
    }

    var user_fixes: usize = 0;
    for (setup.items.items) |item| if (item.write_path != null) {
        user_fixes += 1;
    };
    if (user_fixes > 0) {
        print("{d} change(s) to your own config files (nothing outside your home directory).\n", .{user_fixes});
        if (yes or confirm("Apply them?", true)) setup.applyUserFixes() else out("Skipped.\n");
    }
    setup.offerSystemFixes();
    out("\nDone. Run `dkde-setup --check` any time to re-check.\n");
}

test {
    _ = common;
}
