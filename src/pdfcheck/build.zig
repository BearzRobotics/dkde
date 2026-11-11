//! How dkde-pdfcheck is built; called by the top-level build.zig.

const std = @import("std");
const Ctx = @import("../../build.zig").Ctx;

pub fn configure(ctx: *const Ctx, mod: *std.Build.Module) void {
    // Draws many PDFs without a display and reports what was not drawn.
    mod.addImport("pdfrender", ctx.pdfrender);
    ctx.imports(mod, &.{ "cairo1", "glib2" });
    mod.linkSystemLibrary("cairo", .{});
    mod.linkSystemLibrary("glib-2.0", .{});
}
