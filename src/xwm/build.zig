//! dkde-wm: DKDE's X11 window manager (experimental; see ai/COMPOSITOR-SPEC.md
//! section 5). A package of its own, like the compositor: the main build takes
//! it in, and it also builds alone from this folder:
//!
//!   zig build        the window manager
//!   zig build test   its tests
//!
//! Needs libxcb, libxcb-randr and libxkbcommon (and their -dev files). Layout, shortcuts and
//! settings come from the compositor's source, which is shared.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // libxcb-randr's header and library, when they are not installed system-wide (as in the main build).
    const randr_prefix = b.option([]const u8, "xcb-randr-prefix", "Folder with include/ and lib/ of libxcb-randr (default: system)");
    const translate_c = b.addTranslateC(.{ .root_source_file = b.path("src/c.h"), .target = target, .optimize = optimize });
    translate_c.linkSystemLibrary("xcb", .{});
    translate_c.linkSystemLibrary("xkbcommon", .{});
    translate_c.linkSystemLibrary("pangocairo", .{});
    translate_c.linkSystemLibrary("cairo", .{});
    if (randr_prefix) |prefix| {
        translate_c.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{prefix}) });
        translate_c.addIncludePath(.{ .cwd_relative = "/usr/include/xcb" });
    }

    const toml = b.dependency("toml", .{ .target = target, .optimize = optimize }).module("toml");
    const shared = b.createModule(.{ .root_source_file = b.path("../compositor/src/shared.zig"), .target = target, .optimize = optimize });
    shared.addImport("toml", toml);

    const root = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    root.addImport("c", translate_c.createModule());
    root.addImport("shared", shared);
    root.addImport("toml", toml);
    root.linkSystemLibrary("xcb", .{});
    if (randr_prefix) |prefix| root.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{prefix}) });
    root.linkSystemLibrary("xcb-randr", .{});
    root.linkSystemLibrary("xkbcommon", .{});
    root.linkSystemLibrary("pangocairo", .{});
    root.linkSystemLibrary("cairo", .{});
    b.installArtifact(b.addExecutable(.{ .name = "dkde-wm", .root_module = root }));
    // The login-manager entry for an X11 session (`zig build --prefix /usr`).
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(b.path("../../data/dkde-x11.desktop"), .prefix, "share/xsessions/dkde-x11.desktop").step);

    const test_step = b.step("test", "Run the tests");
    const test_mod = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    test_mod.addImport("c", translate_c.createModule());
    test_mod.addImport("shared", shared);
    test_mod.addImport("toml", toml);
    test_mod.linkSystemLibrary("xcb", .{});
    if (randr_prefix) |prefix| test_mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{prefix}) });
    test_mod.linkSystemLibrary("xcb-randr", .{});
    test_mod.linkSystemLibrary("xkbcommon", .{});
    test_mod.linkSystemLibrary("pangocairo", .{});
    test_mod.linkSystemLibrary("cairo", .{});
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = test_mod })).step);
}
