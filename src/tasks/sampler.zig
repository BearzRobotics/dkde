//! What is running, read from /proc once per refresh and shared by the
//! Processes, Details and Users pages: each process's CPU, memory, disk and
//! GPU use, who owns it, what it is (an app with a window, a background
//! process, a system process) and which app it belongs to.
//!
//! Figures follow the Windows Task Manager: CPU is the share of the whole
//! machine (all processes add up to the total), memory is the process's own
//! (private) memory, GPU is the busiest engine's share.

const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");

const proc = @import("proc.zig");
const gpu = @import("gpu.zig");

extern fn sysconf(name: c_int) c_long;
extern fn readlink(path: [*:0]const u8, buf: [*]u8, size: usize) isize;
const SC_CLK_TCK = 2;
const SC_PAGESIZE = 30;
const SC_NPROCESSORS_ONLN = 84;

pub const Kind = enum { app, background, system };

pub fn copyInto(dst: []u8, len: *usize, src: []const u8) void {
    const n = @min(src.len, dst.len);
    @memcpy(dst[0..n], src[0..n]);
    len.* = n;
}

pub const Process = struct {
    pid: u32,
    ppid: u32 = 0,
    uid: u32 = 0,
    euid: u32 = 0,
    name: [64]u8 = undefined,
    name_len: usize = 0,
    user: [32]u8 = undefined,
    user_len: usize = 0,
    state: u8 = '?',
    ticks: u64 = 0,
    prev_ticks: u64 = 0,
    /// Share of the whole machine, 0 to 100.
    cpu: f64 = 0,
    /// The process's own memory, in kB (private working set).
    private_kb: u64 = 0,
    rss_kb: u64 = 0,
    swap_kb: u64 = 0,
    threads: u32 = 0,
    nice: i32 = 0,
    start_ticks: u64 = 0,
    /// Bytes per second to and from storage, and the totals since it started.
    disk_rate: f64 = 0,
    read_bytes: u64 = 0,
    write_bytes: u64 = 0,
    prev_io: u64 = 0,
    io: enum { unknown, ok, denied } = .unknown,
    /// GPU: the busiest engine's share (0 to 1) and memory held, in kB.
    gpu: f64 = 0,
    gpu_mem_kb: u64 = 0,
    has_gpu: bool = false,
    /// The kernel's name, to notice a program changing identity (exec).
    comm: [16]u8 = undefined,
    comm_len: usize = 0,
    path: [192]u8 = undefined,
    path_len: usize = 0,
    cmd: [256]u8 = undefined,
    cmd_len: usize = 0,
    unit: [64]u8 = undefined,
    unit_len: usize = 0,
    kind: Kind = .background,
    /// The desktop entry the program matches (its display name and icon).
    app: ?*const AppEntry = null,
    /// The app process this one belongs to (itself for an app's main process).
    group: u32 = 0,
    seen: bool = false,
    identified: bool = false,

    pub fn nameSlice(self: *const Process) []const u8 {
        return self.name[0..self.name_len];
    }
    pub fn userSlice(self: *const Process) []const u8 {
        return self.user[0..self.user_len];
    }
    pub fn pathSlice(self: *const Process) []const u8 {
        return self.path[0..self.path_len];
    }
    pub fn cmdSlice(self: *const Process) []const u8 {
        return self.cmd[0..self.cmd_len];
    }
    pub fn unitSlice(self: *const Process) []const u8 {
        return self.unit[0..self.unit_len];
    }
    /// Kernel threads have no program and no memory of their own.
    pub fn isKernel(self: *const Process) bool {
        return self.pid == 2 or self.ppid == 2;
    }
    /// Efficiency mode: the lowest CPU priority (and, set with it, idle disk priority).
    pub fn efficient(self: *const Process) bool {
        return self.nice == 19;
    }
};

/// One installed program, from its desktop entry.
pub const AppEntry = struct {
    name: [64]u8 = @splat(0),
    icon: [96]u8 = @splat(0),
    id: [96]u8 = @splat(0),

    pub fn nameSlice(self: *const AppEntry) []const u8 {
        return std.mem.sliceTo(&self.name, 0);
    }
    pub fn iconSlice(self: *const AppEntry) [:0]const u8 {
        return std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&self.icon)), 0);
    }
};

/// Per-process GPU bookkeeping: which descriptors are GPU files, and their
/// last readings.
const GpuState = struct {
    fds: [8]u32 = undefined,
    fd_count: usize = 0,
    prev: [8]?gpu.Client = @splat(null),
    scanned_tick: u64 = 0,
};

pub const Sampler = struct {
    gpa: std.mem.Allocator,
    processes: std.AutoHashMapUnmanaged(u32, Process) = .empty,
    gpu_states: std.AutoHashMapUnmanaged(u32, GpuState) = .empty,
    /// Program name (lower case) to desktop entry.
    apps: std.StringHashMapUnmanaged(*AppEntry) = .empty,
    app_entries: std.ArrayList(*AppEntry) = .empty,
    passwd: ?[]u8 = null,
    my_uid: u32 = 0,
    cpu_count: usize = 1,
    clock_ticks: f64 = 100,
    page_kb: u64 = 4,
    /// Seconds since the epoch at boot (for start times).
    boot_time: i64 = 0,
    prev_cpu: ?proc.CpuTimes = null,
    prev_us: i64 = 0,
    tick: u64 = 0,
    /// Whole-machine figures of the last refresh.
    cpu_total: f64 = 0,
    mem_used_fraction: f64 = 0,
    mem_total_kb: u64 = 0,
    disk_total_rate: f64 = 0,
    threads_total: usize = 0,
    /// Each GPU's busy time over the last interval, from its clients.
    loads: std.ArrayList(gpu.Load) = .empty,
    load_elapsed_ns: u64 = 0,

    pub fn init(gpa: std.mem.Allocator) Sampler {
        var s: Sampler = .{
            .gpa = gpa,
            .cpu_count = @intCast(@max(1, sysconf(SC_NPROCESSORS_ONLN))),
            .clock_ticks = @floatFromInt(@max(1, sysconf(SC_CLK_TCK))),
            .page_kb = @intCast(@max(1, @divTrunc(sysconf(SC_PAGESIZE), 1024))),
            .my_uid = @intCast(std.c.getuid()),
        };
        s.passwd = readFile(gpa, "/etc/passwd");
        if (readFile(gpa, "/proc/stat")) |stat| {
            defer gpa.free(stat);
            var lines = std.mem.splitScalar(u8, stat, '\n');
            while (lines.next()) |line| if (std.mem.startsWith(u8, line, "btime ")) {
                s.boot_time = std.fmt.parseInt(i64, std.mem.trim(u8, line[6..], " "), 10) catch 0;
            };
        }
        s.loadApps();
        return s;
    }

    pub fn deinit(self: *Sampler) void {
        self.processes.deinit(self.gpa);
        self.gpu_states.deinit(self.gpa);
        var it = self.apps.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.apps.deinit(self.gpa);
        for (self.app_entries.items) |e| self.gpa.destroy(e);
        self.app_entries.deinit(self.gpa);
        self.loads.deinit(self.gpa);
        if (self.passwd) |p| self.gpa.free(p);
    }

    pub fn readFile(gpa: std.mem.Allocator, path: [:0]const u8) ?[]u8 {
        var contents: [*]u8 = undefined;
        var length: usize = 0;
        if (glib.fileGetContents(path, &contents, &length, null) == 0) return null;
        defer glib.free(contents);
        return gpa.dupe(u8, contents[0..length]) catch null;
    }

    // ---- installed programs -------------------------------------------------------

    /// Every desktop entry, by the names its program may run under: the
    /// command's file name ("firefox"), the entry's id ("org.gnome.Nautilus"
    /// and "nautilus") and its startup window class.
    fn loadApps(self: *Sampler) void {
        const list = gio.AppInfo.getAll();
        var node: ?*glib.List = list;
        defer list.free();
        while (node) |n| : (node = n.f_next) {
            const info: *gio.AppInfo = @ptrCast(@alignCast(n.f_data orelse continue));
            defer info.as(gobject.Object).unref();
            // Entries hidden from menus (portals, helpers) are not apps.
            if (info.shouldShow() == 0) continue;
            // An interpreter's own entry ("Python 3.14") would claim every script.
            const exec_key = if (info.getCommandline()) |cl| execKey(std.mem.span(cl)) else "";
            if (isInterpreter(exec_key)) continue;
            const e = self.gpa.create(AppEntry) catch continue;
            e.* = .{};
            const name = std.mem.span(info.getDisplayName());
            @memcpy(e.name[0..@min(name.len, e.name.len - 1)], name[0..@min(name.len, e.name.len - 1)]);
            if (info.getIcon()) |icon| {
                if (icon.toString()) |text| {
                    defer glib.free(text);
                    const t = std.mem.span(text);
                    if (t.len < e.icon.len) @memcpy(e.icon[0..t.len], t);
                }
            }
            const id = if (info.getId()) |i| std.mem.span(i) else "";
            const stem = if (std.mem.endsWith(u8, id, ".desktop")) id[0 .. id.len - 8] else id;
            @memcpy(e.id[0..@min(stem.len, e.id.len - 1)], stem[0..@min(stem.len, e.id.len - 1)]);
            self.app_entries.append(self.gpa, e) catch {
                self.gpa.destroy(e);
                continue;
            };
            self.addAppKey(exec_key, e);
            self.addAppKey(stem, e);
            // "org.gnome.Nautilus" runs as "nautilus".
            if (std.mem.lastIndexOfScalar(u8, stem, '.')) |dot| self.addAppKey(stem[dot + 1 ..], e);
        }
    }

    fn addAppKey(self: *Sampler, key: []const u8, e: *AppEntry) void {
        if (key.len == 0 or key.len > 64) return;
        var lower: [64]u8 = undefined;
        const k = std.ascii.lowerString(&lower, key);
        if (self.apps.contains(k)) return;
        const owned = self.gpa.dupe(u8, k) catch return;
        self.apps.put(self.gpa, owned, e) catch self.gpa.free(owned);
    }

    /// The program a command line runs: "env A=b /usr/bin/foo --x" gives
    /// "foo"; "flatpak run org.x.Y" gives "org.x.Y".
    fn execKey(cl: []const u8) []const u8 {
        var it = std.mem.tokenizeScalar(u8, cl, ' ');
        var first = it.next() orelse return "";
        if (std.mem.eql(u8, std.fs.path.basename(first), "env")) {
            while (it.next()) |t| if (std.mem.indexOfScalar(u8, t, '=') == null) {
                first = t;
                break;
            };
        }
        if (std.mem.eql(u8, std.fs.path.basename(first), "flatpak")) {
            while (it.next()) |t| if (t.len > 0 and t[0] != '-' and !std.mem.eql(u8, t, "run")) return t;
        }
        return std.mem.trim(u8, std.fs.path.basename(first), "\"'");
    }

    fn isInterpreter(name: []const u8) bool {
        const prefixes = [_][]const u8{ "python", "perl", "ruby", "node", "java", "lua", "php", "tclsh", "wish", "irb", "sh", "bash", "zsh", "fish", "dash", "env", "wine", "mono", "dotnet", "gjs", "qml" };
        for (prefixes) |p| {
            if (!std.mem.startsWith(u8, name, p)) continue;
            const rest = name[p.len..];
            // "python3.14", "lua5.4"; not "shotwell" or "javelin".
            if (rest.len == 0 or std.ascii.isDigit(rest[0]) or rest[0] == '-' or rest[0] == '.') return true;
        }
        return false;
    }

    fn appFor(self: *Sampler, p: *const Process) ?*const AppEntry {
        var lower: [64]u8 = undefined;
        for ([_][]const u8{ std.fs.path.basename(p.pathSlice()), p.comm[0..p.comm_len], p.nameSlice() }) |name| {
            if (name.len == 0 or name.len > lower.len) continue;
            if (self.apps.get(std.ascii.lowerString(&lower, name))) |e| return e;
        }
        return null;
    }

    // ---- refreshing ----------------------------------------------------------------

    pub fn refresh(self: *Sampler) void {
        const a = self.gpa;
        self.tick +%= 1;
        var total_delta: u64 = 0;
        if (readFile(a, "/proc/stat")) |content| {
            defer a.free(content);
            if (proc.parseCpuTimes(content)) |now| {
                if (self.prev_cpu) |prev| {
                    total_delta = now.total -| prev.total;
                    self.cpu_total = if (total_delta > 0) 100 * (1 - @as(f64, @floatFromInt(now.idle -| prev.idle)) / @as(f64, @floatFromInt(total_delta))) else 0;
                }
                self.prev_cpu = now;
            }
        }
        if (readFile(a, "/proc/meminfo")) |content| {
            defer a.free(content);
            if (proc.parseMeminfo(content)) |m| {
                self.mem_total_kb = m.total_kb;
                self.mem_used_fraction = @as(f64, @floatFromInt(m.total_kb -| m.available_kb)) / @as(f64, @floatFromInt(@max(1, m.total_kb)));
            }
        }
        const now_us = glib.getMonotonicTime();
        const dt: f64 = if (self.prev_us == 0) 0 else @as(f64, @floatFromInt(now_us - self.prev_us)) / 1e6;
        self.load_elapsed_ns = if (self.prev_us == 0) 0 else @intCast((now_us - self.prev_us) * 1000);
        self.prev_us = now_us;
        self.loads.clearRetainingCapacity();

        var it = self.processes.valueIterator();
        while (it.next()) |p| p.seen = false;
        const dir = gio.File.newForPath("/proc");
        defer dir.as(gobject.Object).unref();
        if (dir.enumerateChildren("standard::name", .{}, null, null)) |children| {
            defer children.as(gobject.Object).unref();
            while (children.nextFile(null, null)) |info| {
                defer info.as(gobject.Object).unref();
                const pid = std.fmt.parseInt(u32, std.mem.span(info.getName()), 10) catch continue;
                self.sample(pid, total_delta, dt);
            }
        }
        var dead: std.ArrayList(u32) = .empty;
        defer dead.deinit(a);
        var all = self.processes.iterator();
        while (all.next()) |e| if (!e.value_ptr.seen) dead.append(a, e.key_ptr.*) catch {};
        for (dead.items) |pid| {
            _ = self.processes.remove(pid);
            _ = self.gpu_states.remove(pid);
        }
        self.classify();

        self.threads_total = 0;
        self.disk_total_rate = 0;
        var counted = self.processes.valueIterator();
        while (counted.next()) |p| {
            self.threads_total += p.threads;
            self.disk_total_rate += p.disk_rate;
        }
    }

    fn sample(self: *Sampler, pid: u32, total_delta: u64, dt: f64) void {
        const a = self.gpa;
        var path_buf: [64]u8 = undefined;
        const content = readFile(a, std.fmt.bufPrintSentinel(&path_buf, "/proc/{d}/stat", .{pid}, 0) catch return) orelse return;
        defer a.free(content);
        const stat = proc.parseStat(content) orelse return;

        const entry = self.processes.getOrPut(a, pid) catch return;
        if (!entry.found_existing) {
            entry.value_ptr.* = .{ .pid = pid, .prev_ticks = stat.cpu_ticks, .start_ticks = stat.start_ticks };
        }
        const p = entry.value_ptr;
        p.seen = true;
        p.ppid = stat.ppid;
        const comm = stat.comm[0..@min(stat.comm.len, p.comm.len)];
        if (!p.identified or !std.mem.eql(u8, comm, p.comm[0..p.comm_len])) {
            @memcpy(p.comm[0..comm.len], comm);
            p.comm_len = comm.len;
            self.identify(p, stat.comm);
        }
        // Memory and owners: status changes as the process runs.
        if (readFile(a, std.fmt.bufPrintSentinel(&path_buf, "/proc/{d}/status", .{pid}, 0) catch return)) |status| {
            defer a.free(status);
            const st = proc.parseStatus(status);
            p.uid = st.uid;
            p.euid = st.euid;
            p.swap_kb = st.swap_kb;
            p.private_kb = if (st.has_memory) st.private_kb else stat.rss_pages * self.page_kb;
        }
        p.nice = stat.nice;
        p.state = stat.state;
        p.threads = stat.threads;
        p.rss_kb = stat.rss_pages * self.page_kb;
        p.ticks = stat.cpu_ticks;
        // A share of the whole machine, as Windows shows it.
        p.cpu = proc.cpuPercent(stat.cpu_ticks -| p.prev_ticks, total_delta, self.cpu_count) / @as(f64, @floatFromInt(self.cpu_count));
        p.prev_ticks = stat.cpu_ticks;
        self.sampleIo(p, dt);
        if (!p.isKernel()) self.sampleGpu(p);
    }

    /// Name, program file, command line, owner name and unit: once per program.
    fn identify(self: *Sampler, p: *Process, comm: []const u8) void {
        const a = self.gpa;
        p.identified = true;
        var pb: [64]u8 = undefined;
        var exe: []const u8 = "";
        var exe_owned: ?[*:0]u8 = null;
        defer if (exe_owned) |e| glib.free(e);
        if (std.fmt.bufPrintSentinel(&pb, "/proc/{d}/exe", .{p.pid}, 0)) |path| {
            if (glib.fileReadLink(path, null)) |target| {
                exe_owned = target;
                exe = std.mem.span(target);
            }
        } else |_| {}
        var cmdline: []const u8 = "";
        var cmd_owned: ?[]u8 = null;
        defer if (cmd_owned) |c| a.free(c);
        if (std.fmt.bufPrintSentinel(&pb, "/proc/{d}/cmdline", .{p.pid}, 0)) |path| {
            if (readFile(a, path)) |c| {
                cmd_owned = c;
                cmdline = c;
            }
        } else |_| {}
        copyInto(&p.name, &p.name_len, proc.displayName(exe, cmdline, comm));
        copyInto(&p.path, &p.path_len, exe);
        if (std.mem.endsWith(u8, exe, " (deleted)")) p.path_len = 0;
        p.cmd_len = proc.cmdlineText(cmdline, &p.cmd).len;
        if (std.fmt.bufPrintSentinel(&pb, "/proc/{d}/cgroup", .{p.pid}, 0)) |path| {
            if (readFile(a, path)) |cg| {
                defer a.free(cg);
                copyInto(&p.unit, &p.unit_len, proc.cgroupUnit(cg) orelse "");
            }
        } else |_| {}
        if (std.fmt.bufPrintSentinel(&pb, "/proc/{d}/status", .{p.pid}, 0)) |path| {
            if (readFile(a, path)) |status| {
                defer a.free(status);
                const st = proc.parseStatus(status);
                const name = if (self.passwd) |pw| proc.userName(pw, st.uid) else null;
                copyInto(&p.user, &p.user_len, name orelse "?");
            }
        } else |_| {}
        p.app = self.appFor(p);
    }

    fn sampleIo(self: *Sampler, p: *Process, dt: f64) void {
        if (p.io == .denied) return;
        var pb: [64]u8 = undefined;
        const content = readFile(self.gpa, std.fmt.bufPrintSentinel(&pb, "/proc/{d}/io", .{p.pid}, 0) catch return) orelse {
            p.io = .denied;
            p.disk_rate = 0;
            return;
        };
        defer self.gpa.free(content);
        const io = proc.parseIo(content) orelse {
            p.io = .denied;
            return;
        };
        const total = io.read +| io.write;
        if (p.io == .ok and dt > 0) p.disk_rate = @as(f64, @floatFromInt(total -| p.prev_io)) / dt;
        p.prev_io = total;
        p.read_bytes = io.read;
        p.write_bytes = io.write;
        p.io = .ok;
    }

    /// GPU use from the process's GPU files: looked for every few refreshes,
    /// read every refresh.
    fn sampleGpu(self: *Sampler, p: *Process) void {
        const st = self.gpu_states.getOrPut(self.gpa, p.pid) catch return;
        if (!st.found_existing) st.value_ptr.* = .{};
        const g = st.value_ptr;
        if (g.scanned_tick == 0 or self.tick - g.scanned_tick >= 5) {
            g.scanned_tick = self.tick;
            self.scanGpuFds(p.pid, g);
        }
        p.gpu = 0;
        p.gpu_mem_kb = 0;
        p.has_gpu = g.fd_count > 0;
        if (g.fd_count == 0) return;
        // A client may be open on several descriptors: count it once.
        var seen_ids: [8]u64 = undefined;
        var seen_n: usize = 0;
        for (g.fds[0..g.fd_count], 0..) |fd, i| {
            var pb: [64]u8 = undefined;
            const path = std.fmt.bufPrintSentinel(&pb, "/proc/{d}/fdinfo/{d}", .{ p.pid, fd }, 0) catch continue;
            var buf: [2048]u8 = undefined;
            const text = readSmall(path, &buf) orelse continue;
            const c = gpu.parseFdinfo(text) orelse continue;
            const dup = for (seen_ids[0..seen_n]) |id| {
                if (id == c.client_id) break true;
            } else false;
            if (!dup and seen_n < seen_ids.len) {
                seen_ids[seen_n] = c.client_id;
                seen_n += 1;
                p.gpu_mem_kb += c.memory_kb;
                if (g.prev[i]) |*prev| if (prev.client_id == c.client_id) {
                    p.gpu = @max(p.gpu, gpu.clientBusy(prev, &c, self.load_elapsed_ns));
                    self.addLoad(prev, &c);
                };
            }
            g.prev[i] = c;
        }
    }

    fn scanGpuFds(self: *Sampler, pid: u32, g: *GpuState) void {
        _ = self;
        g.fd_count = 0;
        var pb: [64]u8 = undefined;
        const dir_path = std.fmt.bufPrintSentinel(&pb, "/proc/{d}/fd", .{pid}, 0) catch return;
        const dir = gio.File.newForPath(dir_path);
        defer dir.as(gobject.Object).unref();
        // Only the owner may look; others' descriptors are not listed.
        const children = dir.enumerateChildren("standard::name", .{ .nofollow_symlinks = true }, null, null) orelse return;
        defer children.as(gobject.Object).unref();
        while (children.nextFile(null, null)) |info| {
            defer info.as(gobject.Object).unref();
            const name = std.mem.span(info.getName());
            var lb: [96]u8 = undefined;
            const link = std.fmt.bufPrintSentinel(&lb, "{s}/{s}", .{ dir_path, name }, 0) catch continue;
            var tb: [64]u8 = undefined;
            const n = readlink(link, &tb, tb.len);
            if (n <= 0) continue;
            if (!std.mem.startsWith(u8, tb[0..@intCast(n)], "/dev/dri/")) continue;
            if (g.fd_count == g.fds.len) break;
            g.fds[g.fd_count] = std.fmt.parseInt(u32, name, 10) catch continue;
            g.prev[g.fd_count] = null;
            g.fd_count += 1;
        }
    }

    fn addLoad(self: *Sampler, prev: *const gpu.Client, now: *const gpu.Client) void {
        const pdev = now.pdevSlice();
        const load = for (self.loads.items) |*l| {
            if (std.mem.eql(u8, std.mem.sliceTo(&l.pdev, 0), pdev)) break l;
        } else blk: {
            var l: gpu.Load = .{};
            @memcpy(l.pdev[0..@min(pdev.len, l.pdev.len - 1)], pdev[0..@min(pdev.len, l.pdev.len - 1)]);
            self.loads.append(self.gpa, l) catch return;
            break :blk &self.loads.items[self.loads.items.len - 1];
        };
        for (now.engines[0..now.engine_count]) |*e| {
            for (prev.engines[0..prev.engine_count]) |*pe| {
                if (std.mem.eql(u8, pe.nameSlice(), e.nameSlice())) load.add(e.nameSlice(), e.ns -| pe.ns);
            }
        }
    }

    /// The utilization (0 to 1) of the GPU at PCI address `pdev`, from its
    /// clients this interval; null when none of its clients could be read.
    pub fn gpuLoad(self: *const Sampler, pdev: []const u8) ?f64 {
        if (self.load_elapsed_ns == 0) return null;
        for (self.loads.items) |*l| {
            if (std.mem.eql(u8, std.mem.sliceTo(&l.pdev, 0), pdev)) return l.busy(self.load_elapsed_ns);
        }
        return null;
    }

    // ---- what is what -----------------------------------------------------------------

    /// Apps (the session user's programs that have a desktop entry), their
    /// helper processes under them, background processes, and system
    /// processes (other users and the kernel).
    fn classify(self: *Sampler) void {
        var it = self.processes.valueIterator();
        while (it.next()) |p| {
            p.group = 0;
            if (p.isKernel() or p.uid != self.my_uid) {
                p.kind = .system;
            } else if (p.app != null) {
                p.kind = .app;
            } else p.kind = .background;
        }
        // An app's helpers (its children, of the same user) belong to the
        // topmost app process above them.
        var it2 = self.processes.valueIterator();
        while (it2.next()) |p| {
            if (p.kind == .system) continue;
            var top: ?u32 = null;
            var cur = p.pid;
            var hops: usize = 0;
            while (hops < 64) : (hops += 1) {
                const q = self.processes.get(cur) orelse break;
                if (q.kind == .app) top = q.pid;
                if (q.ppid == 0 or q.ppid == cur) break;
                cur = q.ppid;
            }
            if (top) |t| {
                p.group = t;
                if (p.pid != t) p.kind = .app;
            }
        }
    }

    pub fn startTime(self: *const Sampler, p: *const Process) i64 {
        return self.boot_time + @as(i64, @intFromFloat(@as(f64, @floatFromInt(p.start_ticks)) / self.clock_ticks));
    }

    /// `pid` and every process below it, children first (for ending a tree).
    pub fn tree(self: *const Sampler, gpa: std.mem.Allocator, pid: u32) ![]u32 {
        var out: std.ArrayList(u32) = .empty;
        try self.collect(gpa, pid, &out, 0);
        return out.toOwnedSlice(gpa);
    }

    fn collect(self: *const Sampler, gpa: std.mem.Allocator, pid: u32, out: *std.ArrayList(u32), depth: usize) !void {
        if (depth > 64) return;
        var it = self.processes.valueIterator();
        while (it.next()) |p| if (p.ppid == pid and p.pid != pid) try self.collect(gpa, p.pid, out, depth + 1);
        try out.append(gpa, pid);
    }
};

fn readSmall(path: [:0]const u8, buf: []u8) ?[]const u8 {
    const fd = std.c.open(path, .{}, @as(std.c.mode_t, 0));
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    const n = std.c.read(fd, buf.ptr, buf.len);
    if (n <= 0) return null;
    return buf[0..@intCast(n)];
}

test "interpreters are not apps" {
    try std.testing.expect(Sampler.isInterpreter("python3.14"));
    try std.testing.expect(Sampler.isInterpreter("bash"));
    try std.testing.expect(!Sampler.isInterpreter("shotwell"));
    try std.testing.expect(!Sampler.isInterpreter("javelin"));
}

test "program names from command lines" {
    try std.testing.expectEqualStrings("firefox", Sampler.execKey("/usr/lib/firefox/firefox %u"));
    try std.testing.expectEqualStrings("gimp", Sampler.execKey("env GDK_BACKEND=x11 gimp --x"));
    try std.testing.expectEqualStrings("org.x.Y", Sampler.execKey("flatpak run --branch=stable org.x.Y @@u %U"));
}
