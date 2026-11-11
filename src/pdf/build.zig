//! How dkde-pdf is built; called by the top-level build.zig.

const std = @import("std");
const Ctx = @import("../../build.zig").Ctx;

pub const menu_entry = true;

pub fn configure(ctx: *const Ctx, mod: *std.Build.Module) void {
    ctx.gtk(mod);
    ctx.imports(mod, &.{"cairo1"});
    mod.addImport("pdfrender", ctx.pdfrender);
    mod.addImport("pdf", ctx.pdf);
}
