//! How dkde-calendar is built; called by the top-level build.zig.

const std = @import("std");
const Ctx = @import("../../build.zig").Ctx;

pub const menu_entry = true;
pub const data: []const []const u8 = &.{"calendar.toml"};

pub fn configure(ctx: *const Ctx, mod: *std.Build.Module) void {
    ctx.gtk(mod);
    mod.linkSystemLibrary("fontconfig", .{});
    const b = ctx.b;
    // The glyph font is built into the program.
    mod.addAnonymousImport("rosquin-font", .{ .root_source_file = b.path("data/fonts/RosquinGlyphs.ttf") });
    mod.addAnonymousImport("branding", .{ .root_source_file = b.path("data/branding.png") });
    // The open-source fonts for the native names of the Chinese, Hebrew, Coptic and Ethiopian calendars.
    mod.addAnonymousImport("font-cjk", .{ .root_source_file = b.path("data/fonts/native/DroidSansFallbackSubset.ttf") });
    mod.addAnonymousImport("font-he", .{ .root_source_file = b.path("data/fonts/native/NotoSansHebrew-Regular.ttf") });
    mod.addAnonymousImport("font-et", .{ .root_source_file = b.path("data/fonts/native/NotoSansEthiopic-Regular.ttf") });
    mod.addAnonymousImport("font-cop", .{ .root_source_file = b.path("data/fonts/native/NotoSansCoptic-Regular.ttf") });
}
