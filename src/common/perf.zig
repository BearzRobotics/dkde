//! Low-resource start-up shared by every dkde program (SPEC.md 11).
//!
//! `init` must run before GTK starts. It picks GTK's renderer from
//! `[performance] renderer` in dkde.conf and, on glibc only, caps malloc arenas.
//! `Gpa` is the allocator the mains use: the checking allocator in Debug
//! builds, plain malloc otherwise (no per-allocation bookkeeping).

const std = @import("std");
const builtin = @import("builtin");
const glib = @import("glib2");

const config = @import("config.zig");

// glibc only. Declared unconditionally but referenced only behind a comptime
// check, so it never reaches the linker on musl.
extern fn mallopt(param: c_int, value: c_int) c_int;
const M_ARENA_MAX: c_int = -8;

pub fn init() void {
    // glibc gives every thread its own arena; GTK and Mesa start dozens. musl's
    // allocator (mallocng) has no per-thread arenas and no mallopt, so there is
    // nothing to cap there.
    if (comptime builtin.target.isGnuLibC()) _ = mallopt(M_ARENA_MAX, 2);

    // An explicit GSK_RENDERER in the environment always wins.
    if (glib.getenv("GSK_RENDERER") != null) return;
    const alloc = std.heap.c_allocator;
    var cfg = config.Config.load(alloc, "dkde.conf") catch return;
    defer cfg.deinit();
    const choice = cfg.getString(alloc, "performance", "renderer", "cairo") catch return;
    defer alloc.free(choice);
    // "auto" leaves the choice to GTK (OpenGL or Vulkan when it can).
    if (choice.len == 0 or std.mem.eql(u8, choice, "auto")) return;
    if (std.mem.eql(u8, choice, "cairo") or std.mem.eql(u8, choice, "gl") or std.mem.eql(u8, choice, "ngl") or std.mem.eql(u8, choice, "vulkan")) {
        const value = alloc.dupeSentinel(u8, choice, 0) catch return;
        defer alloc.free(value);
        _ = glib.setenv("GSK_RENDERER", value, 1);
    }
}

pub const Gpa = struct {
    inner: if (builtin.mode == .debug) std.heap.DebugAllocator(.{}) else void =
        if (builtin.mode == .debug) .init else {},

    pub fn allocator(self: *Gpa) std.mem.Allocator {
        if (builtin.mode == .debug) return self.inner.allocator();
        return std.heap.c_allocator;
    }

    pub fn deinit(self: *Gpa) void {
        if (builtin.mode == .debug) _ = self.inner.deinit();
    }
};
