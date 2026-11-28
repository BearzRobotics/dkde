// SPDX-License-Identifier: GPL-2.0-or-later
//! How dkde-idle is built; called by the top-level build.zig.

const std = @import("std");
const Ctx = @import("../../build.zig").Ctx;

pub const data: []const []const u8 = &.{"panel.toml"};

pub fn configure(ctx: *const Ctx, mod: *std.Build.Module) void {
    // No window: GLib and GIO only, and the idle protocol.
    ctx.glib(mod);
    ctx.desktopApi(mod);
}
