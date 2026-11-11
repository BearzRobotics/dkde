//! How dkde-snip is built; called by the top-level build.zig.

const std = @import("std");
const Ctx = @import("../../build.zig").Ctx;

pub const menu_entry = true;

pub fn configure(ctx: *const Ctx, mod: *std.Build.Module) void {
    ctx.gtk(mod);
    ctx.imports(mod, &.{"cairo1"});
    // Screen capture through wlr-screencopy.
    ctx.wayland(mod);
}
