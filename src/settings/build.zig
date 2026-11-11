//! How dkde-settings is built; called by the top-level build.zig.

const std = @import("std");
const Ctx = @import("../../build.zig").Ctx;

pub const menu_entry = true;
// Settings edits every program's configuration, so it reads all defaults.
pub const data: []const []const u8 = &.{ "panel.toml", "term.toml", "files.toml", "edit.toml", "calendar.toml" };

pub fn configure(ctx: *const Ctx, mod: *std.Build.Module) void {
    ctx.gtk(mod);
    mod.addImport("util_unix", ctx.util_unix);
    // The Terminal page previews colour schemes with termcore's tables, and
    // offers the schemes dkde-term has.
    const termcore = ctx.dkterm().module("termcore");
    mod.addImport("termcore", termcore);
    const termschemes = ctx.b.createModule(.{ .root_source_file = ctx.b.path("src/term/schemes.zig"), .target = ctx.target, .optimize = ctx.optimize });
    termschemes.addImport("termcore", termcore);
    mod.addImport("termschemes", termschemes);
}
