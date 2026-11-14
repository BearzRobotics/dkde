//! How dkde-panel is built; called by the top-level build.zig.

const std = @import("std");
const Ctx = @import("../../build.zig").Ctx;

pub const data: []const []const u8 = &.{"panel.toml"};

pub fn configure(ctx: *const Ctx, mod: *std.Build.Module) void {
    // gtk4-layer-shell must be linked before libwayland, so before GTK.
    mod.linkSystemLibrary("gtk4-layer-shell-0", .{});
    ctx.gtk(mod);
    ctx.imports(mod, &.{"cairo1"});
    ctx.wayland(mod);
    // The clock shows the date in any calendar dkde-calendar knows: its own code.
    const calsys = ctx.b.createModule(.{ .root_source_file = ctx.b.path("src/calendar/calsys.zig"), .target = ctx.target, .optimize = ctx.optimize });
    calsys.addImport("common", ctx.common);
    mod.addImport("calsys", calsys);
}
