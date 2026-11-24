//! dkde-xcomp: DKDE's X11 compositing manager (see ai/COMPOSITOR-SPEC.md section 5). A separate package, like
//! the compositor and dkde-wm, so the main build needs no X11 development files. Build it from this folder:
//!
//!   zig build        the compositing manager
//!   zig build test   its tests
//!
//! Needs libxcb with its composite, damage and xfixes extensions, EGL and GLES2 (and their -dev files).
//! The effects code, the shaders and the settings file come from the compositor's source, which is shared.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Folder with include/ and lib/ of libxcb-composite, -damage and -xfixes, when they are not installed system-wide.
    const xcb_prefix = b.option([]const u8, "xcb-prefix", "Folder with include/ and lib/ of the xcb composite, damage and xfixes libraries (default: system)");
    const translate_c = b.addTranslateC(.{ .root_source_file = b.path("src/c.h"), .target = target, .optimize = optimize });
    translate_c.linkSystemLibrary("xcb", .{});
    translate_c.linkSystemLibrary("egl", .{});
    translate_c.linkSystemLibrary("glesv2", .{});
    if (xcb_prefix) |prefix| {
        translate_c.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{prefix}) });
        translate_c.addIncludePath(.{ .cwd_relative = "/usr/include/xcb" });
    }

    const toml = b.dependency("toml", .{ .target = target, .optimize = optimize }).module("toml");
    const shared = b.createModule(.{ .root_source_file = b.path("../compositor/src/shared.zig"), .target = target, .optimize = optimize });
    shared.addImport("toml", toml);

    const root = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    root.addImport("c", translate_c.createModule());
    root.addImport("shared", shared);
    link(b, root, xcb_prefix);
    b.installArtifact(b.addExecutable(.{ .name = "dkde-xcomp", .root_module = root }));

    const test_step = b.step("test", "Run the tests");
    const test_mod = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    test_mod.addImport("c", translate_c.createModule());
    test_mod.addImport("shared", shared);
    link(b, test_mod, xcb_prefix);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = test_mod })).step);
}

fn link(b: *std.Build, m: *std.Build.Module, xcb_prefix: ?[]const u8) void {
    if (xcb_prefix) |prefix| m.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{prefix}) });
    m.linkSystemLibrary("xcb", .{});
    m.linkSystemLibrary("xcb-composite", .{});
    m.linkSystemLibrary("xcb-damage", .{});
    m.linkSystemLibrary("xcb-xfixes", .{});
    m.linkSystemLibrary("egl", .{});
    m.linkSystemLibrary("glesv2", .{});
}
