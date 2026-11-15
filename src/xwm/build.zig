//! dkde-wm: DKDE's X11 window manager (experimental; see ai/COMPOSITOR-SPEC.md
//! section 5). A separate package, like the compositor, so the main build
//! needs no X11 development files. Build it from this folder:
//!
//!   zig build        the window manager
//!   zig build test   its tests
//!
//! Needs libxcb and libxkbcommon (and their -dev files). Layout, shortcuts and
//! settings come from the compositor's source, which is shared.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const translate_c = b.addTranslateC(.{ .root_source_file = b.path("src/c.h"), .target = target, .optimize = optimize });
    translate_c.linkSystemLibrary("xcb", .{});
    translate_c.linkSystemLibrary("xkbcommon", .{});

    const toml = b.dependency("toml", .{ .target = target, .optimize = optimize }).module("toml");
    const shared = b.createModule(.{ .root_source_file = b.path("../compositor/src/shared.zig"), .target = target, .optimize = optimize });
    shared.addImport("toml", toml);

    const root = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    root.addImport("c", translate_c.createModule());
    root.addImport("shared", shared);
    root.linkSystemLibrary("xcb", .{});
    root.linkSystemLibrary("xkbcommon", .{});
    b.installArtifact(b.addExecutable(.{ .name = "dkde-wm", .root_module = root }));

    const test_step = b.step("test", "Run the tests");
    const test_mod = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    test_mod.addImport("c", translate_c.createModule());
    test_mod.addImport("shared", shared);
    test_mod.linkSystemLibrary("xcb", .{});
    test_mod.linkSystemLibrary("xkbcommon", .{});
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = test_mod })).step);
}
