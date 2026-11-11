//! How dkde-notify is built; called by the top-level build.zig.

const std = @import("std");
const Ctx = @import("../../build.zig").Ctx;

pub fn configure(ctx: *const Ctx, mod: *std.Build.Module) void {
    // No window: GLib and GIO only.
    ctx.glib(mod);
}
