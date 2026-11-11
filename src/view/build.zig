//! How dkde-view is built; called by the top-level build.zig.

const std = @import("std");
const Ctx = @import("../../build.zig").Ctx;

pub const menu_entry = true;
// Its own settings, and the panel's (for Set as Wallpaper).
pub const data: []const []const u8 = &.{ "view.toml", "panel.toml" };

pub fn configure(ctx: *const Ctx, mod: *std.Build.Module) void {
    ctx.gtk(mod);
    mod.addImport("imgcodec", ctx.imgcodec);
    ctx.imports(mod, &.{"cairo1"});
}
