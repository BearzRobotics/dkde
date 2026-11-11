//! How dkde-term is built; called by the top-level build.zig.

const std = @import("std");
const Ctx = @import("../../build.zig").Ctx;

pub const menu_entry = true;
pub const data: []const []const u8 = &.{"term.toml"};

pub fn configure(ctx: *const Ctx, mod: *std.Build.Module) void {
    ctx.gtk(mod);
    // Debug builds of libghostty-vt run integrity checks on every linefeed,
    // which makes a screenful of output take seconds; DKTermCore always builds
    // it fast. termcore must use the same libghostty-vt as the program that
    // imports it, so both come from DKTermCore.
    const dkterm = ctx.dkterm();
    mod.addImport("ghostty-vt", dkterm.module("ghostty-vt"));
    mod.addImport("termcore", dkterm.module("termcore"));
    ctx.imports(mod, &.{ "cairo1", "pangocairo1", "graphene1" });
}
