//! Running command-line tools without blocking the UI (SPEC.md 5.5). dkde
//! drives hardware through small tools (`nmcli`, `wpctl`, ...), so several
//! components share this runner.

const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");

pub fn hasProgram(name: [:0]const u8) bool {
    const found = glib.findProgramInPath(name) orelse return false;
    glib.free(found);
    return true;
}

/// Lets a page's callbacks outlive the page safely: commands finish after the
/// user may have closed the window. The state frees itself once the page is
/// gone and nothing is pending.
pub fn Guard(comptime Page: type) type {
    return struct {
        page: *Page,
        pending: u32 = 0,
        dead: bool = false,

        const Self = @This();

        pub fn create(page: *Page) *Self {
            const g = std.heap.c_allocator.create(Self) catch @panic("OOM");
            g.* = .{ .page = page };
            return g;
        }

        /// Call from the page's destroy handler.
        pub fn kill(self: *Self) void {
            self.dead = true;
            if (self.pending == 0) std.heap.c_allocator.destroy(self);
        }
    };
}

const Run = struct {
    /// Adapts the page's own callback type; `target` is that callback.
    callback: *const fn (*anyopaque, *const anyopaque, bool, []const u8) void,
    target: *const anyopaque,
    data: *anyopaque,
    alive: *bool,
    release: *const fn (*anyopaque) void,
};

/// Runs `argv` and calls `callback(guard.page, ok, stdout)` when it ends; `ok`
/// is false if it could not start or exited non-zero. The callback is skipped
/// if the page was destroyed meanwhile.
pub fn run(
    comptime Page: type,
    guard: *Guard(Page),
    argv: []const []const u8,
    callback: *const fn (*Page, bool, []const u8) void,
) void {
    const a = std.heap.c_allocator;
    const G = Guard(Page);
    const Thunk = struct {
        fn call(raw: *anyopaque, target: *const anyopaque, ok: bool, out: []const u8) void {
            const g: *G = @ptrCast(@alignCast(raw));
            const f: *const fn (*Page, bool, []const u8) void = @ptrCast(@alignCast(target));
            f(g.page, ok, out);
        }
        fn release(raw: *anyopaque) void {
            const g: *G = @ptrCast(@alignCast(raw));
            g.pending -= 1;
            if (g.dead and g.pending == 0) std.heap.c_allocator.destroy(g);
        }
        fn dead(raw: *anyopaque) *bool {
            const g: *G = @ptrCast(@alignCast(raw));
            return &g.dead;
        }
    };
    const z = a.alloc(?[*:0]u8, argv.len + 1) catch return;
    defer a.free(z);
    var made: usize = 0;
    defer for (z[0..made]) |p| a.free(std.mem.span(p.?));
    for (argv, 0..) |arg, i| {
        z[i] = (a.dupeSentinel(u8, arg, 0) catch return).ptr;
        made += 1;
    }
    z[argv.len] = null;

    var err: ?*glib.Error = null;
    const proc = gio.Subprocess.newv(@ptrCast(z.ptr), .{ .stdout_pipe = true, .stderr_silence = true }, &err) orelse {
        if (err) |e| e.free();
        callback(guard.page, false, "");
        return;
    };
    const job = a.create(Run) catch return;
    job.* = .{ .callback = Thunk.call, .target = @ptrCast(callback), .data = guard, .alive = Thunk.dead(guard), .release = Thunk.release };
    guard.pending += 1;
    proc.communicateUtf8Async(null, null, &onDone, job);
}

fn onDone(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
    const job: *Run = @ptrCast(@alignCast(data.?));
    const proc: *gio.Subprocess = @ptrCast(@alignCast(source.?));
    defer {
        proc.as(gobject.Object).unref();
        std.heap.c_allocator.destroy(job);
    }
    var buf: [*:0]u8 = undefined;
    var err: ?*glib.Error = null;
    const finished = proc.communicateUtf8Finish(result, &buf, null, &err) != 0;
    if (err) |e| e.free();
    const out: ?[*:0]u8 = if (finished) buf else null;
    defer if (out) |o| glib.free(o);
    const ok = finished and proc.getIfExited() != 0 and proc.getExitStatus() == 0;
    const dead = job.alive.*;
    const text: []const u8 = if (out) |o| std.mem.span(o) else "";
    if (!dead) job.callback(job.data, job.target, ok, text);
    job.release(job.data);
}
