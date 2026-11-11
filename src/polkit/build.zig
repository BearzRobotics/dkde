//! How dkde-polkit is built; called by the top-level build.zig.

const std = @import("std");
const Ctx = @import("../../build.zig").Ctx;

pub fn configure(ctx: *const Ctx, mod: *std.Build.Module) void {
    // The agent: D-Bus only, so it links GLib and GIO but not GTK and idles
    // in a few megabytes (SPEC.md 5.12). Its dialog is dkde-polkit-ui.
    ctx.glibOnly(mod);
    mod.addImport("polkitproto", ctx.polkit_proto);
}
