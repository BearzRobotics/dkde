//! How dkde-calc is built; called by the top-level build.zig.

const std = @import("std");
const Ctx = @import("../../build.zig").Ctx;

pub const menu_entry = true;
pub const data: []const []const u8 = &.{"calc.toml"};

pub fn configure(ctx: *const Ctx, mod: *std.Build.Module) void {
    ctx.gtk(mod);
    // The graph is drawn with cairo and its numbers with Pango.
    ctx.imports(mod, &.{ "cairo1", "pangocairo1" });
    // Date Calculation works in every calendar dkde-calendar knows: its own code.
    const calsys = ctx.b.createModule(.{ .root_source_file = ctx.b.path("src/calendar/calsys.zig"), .target = ctx.target, .optimize = ctx.optimize });
    calsys.addImport("common", ctx.common);
    mod.addImport("calsys", calsys);
}
