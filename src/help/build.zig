//! How dkde-help is built; called by the top-level build.zig.

const std = @import("std");
const Ctx = @import("../../build.zig").Ctx;

pub const menu_entry = true;

pub fn configure(ctx: *const Ctx, mod: *std.Build.Module) void {
    ctx.gtk(mod);
    // Manual-page lookup and rendering: dkman's library (which brings md-zig and gtroff-zig).
    const dkman = ctx.b.lazyDependency("dkman", .{ .target = ctx.target, .optimize = ctx.optimize }) orelse return;
    mod.addImport("dkman", dkman.module("dkman"));
}

/// The help viewer shows these (and the system's manual pages).
pub fn install(ctx: *const Ctx) void {
    ctx.b.installDirectory(.{ .source_dir = ctx.b.path("docs/manpages"), .install_dir = .prefix, .install_subdir = "share/dkde/help", .exclude_extensions = &.{} });
}
