//! How dkde-files is built; called by the top-level build.zig.

const std = @import("std");
const Ctx = @import("../../build.zig").Ctx;

pub const menu_entry = true;
pub const data: []const []const u8 = &.{"files.toml"};

pub fn configure(ctx: *const Ctx, mod: *std.Build.Module) void {
    ctx.gtk(mod);
    // Archives: libarchive (libarchive-dev at build time).
    mod.linkSystemLibrary("archive", .{});
    ctx.imports(mod, &.{"cairo1"});
    // The terminal pane.
    mod.addImport("termembed", ctx.termEmbed());
}
