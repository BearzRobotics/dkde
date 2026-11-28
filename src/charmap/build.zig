// SPDX-License-Identifier: GPL-2.0-or-later
//! How dkde-charmap is built; called by the top-level build.zig.

const std = @import("std");
const Ctx = @import("../../build.zig").Ctx;

pub const menu_entry = true;

pub fn configure(ctx: *const Ctx, mod: *std.Build.Module) void {
    ctx.gtk(mod);
    mod.linkSystemLibrary("fontconfig", .{});
    mod.linkSystemLibrary("pangoft2-1.0", .{}); // pango_fc_font_map_config_changed
    // Rosquin Glyphs is part of the program, as in the calendar.
    mod.addAnonymousImport("rosquin-font", .{ .root_source_file = ctx.b.path("data/fonts/RosquinGlyphs.ttf") });
}
