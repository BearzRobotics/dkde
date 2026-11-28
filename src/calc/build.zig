// SPDX-License-Identifier: GPL-2.0-or-later
//! How dkde-calc is built; called by the top-level build.zig.

const std = @import("std");
const Ctx = @import("../../build.zig").Ctx;

pub const menu_entry = true;
pub const data: []const []const u8 = &.{"calc.toml"};

/// The lessons of the Learn view.
pub fn install(ctx: *const Ctx) void {
    ctx.b.installDirectory(.{ .source_dir = ctx.b.path("data/learn"), .install_dir = .prefix, .install_subdir = "share/dkde/learn" });
}

pub fn configure(ctx: *const Ctx, mod: *std.Build.Module) void {
    ctx.gtk(mod);
    // The graph is drawn with cairo and its numbers with Pango.
    ctx.imports(mod, &.{ "cairo1", "pangocairo1" });
    // Date Calculation works in every calendar dkde-calendar knows: its own code.
    mod.addImport("toml", ctx.b.dependency("toml", .{ .target = ctx.target, .optimize = ctx.optimize }).module("toml"));
    const calsys = ctx.b.createModule(.{ .root_source_file = ctx.b.path("src/calendar/calsys.zig"), .target = ctx.target, .optimize = ctx.optimize });
    calsys.addImport("common", ctx.common);
    mod.addImport("calsys", calsys);
}
