//! How dkde-calc is built; called by the top-level build.zig.

const std = @import("std");
const Ctx = @import("../../build.zig").Ctx;

pub const menu_entry = true;
pub const data: []const []const u8 = &.{"calc.toml"};

pub fn configure(ctx: *const Ctx, mod: *std.Build.Module) void {
    ctx.gtk(mod);
    // The graph is drawn with cairo and its numbers with Pango.
    ctx.imports(mod, &.{ "cairo1", "pangocairo1" });
}
