//! How dkde-edit is built; called by the top-level build.zig.

const std = @import("std");
const Ctx = @import("../../build.zig").Ctx;

pub const menu_entry = true;
pub const data: []const []const u8 = &.{"edit.toml"};

pub fn configure(ctx: *const Ctx, mod: *std.Build.Module) void {
    ctx.gtk(mod);
    // Printing, the overview map and the plain editor's line numbers.
    ctx.imports(mod, &.{ "cairo1", "pangocairo1" });
    // The terminal pane.
    mod.addImport("termembed", ctx.termEmbed());
}
