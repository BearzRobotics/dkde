// SPDX-License-Identifier: GPL-2.0-or-later
//! How dkde-snap is built; called by the top-level build.zig.

const std = @import("std");
const Ctx = @import("../../build.zig").Ctx;

pub fn configure(ctx: *const Ctx, mod: *std.Build.Module) void {
    ctx.gtk(mod);
    // Snap assist lists the open windows through the shared desktop API.
    ctx.desktopApi(mod);
    ctx.imports(mod, &.{"gdkx114"});
}
