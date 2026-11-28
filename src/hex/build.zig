// SPDX-License-Identifier: GPL-2.0-or-later
//! How dkde-hex is built; called by the top-level build.zig.

const std = @import("std");
const Ctx = @import("../../build.zig").Ctx;

pub const menu_entry = true;
pub const data: []const []const u8 = &.{ "hex.toml", "pdf.hexpat" };

pub fn configure(ctx: *const Ctx, mod: *std.Build.Module) void {
    ctx.gtk(mod);
    ctx.imports(mod, &.{ "cairo1", "pangocairo1" });
    // yaml-zig, for Kaitai Struct format files.
    mod.addImport("yaml", ctx.b.dependency("yaml", .{ .target = ctx.target, .optimize = ctx.optimize }).module("yaml"));
}
