//! How dkde-hex is built; called by the top-level build.zig.

const std = @import("std");
const Ctx = @import("../../build.zig").Ctx;

pub const menu_entry = true;
pub const data: []const []const u8 = &.{"hex.toml"};

pub fn configure(ctx: *const Ctx, mod: *std.Build.Module) void {
    ctx.gtk(mod);
    ctx.imports(mod, &.{ "cairo1", "pangocairo1" });
    // YAML, for Kaitai Struct format files (third_party/zig-yaml).
    mod.addImport("yaml", ctx.b.createModule(.{
        .root_source_file = ctx.b.path("third_party/zig-yaml/src/lib.zig"),
        .target = ctx.target,
        .optimize = ctx.optimize,
    }));
}
