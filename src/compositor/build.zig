//! dkde-compositor: DKDE's own Wayland compositor (experimental; see
//! ai/COMPOSITOR-SPEC.md). A separate package so the rest of dkde builds
//! without wlroots; build it from this folder:
//!
//!   zig build                      the compositor
//!   zig build run                  run it (nested in a Wayland session, or headless)
//!
//! Needs wlroots-0.19 (and its -dev files), wayland-server, xkbcommon, pixman,
//! wayland-scanner and the wayland-protocols XML files.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const protocols = b.option([]const u8, "wayland-protocols", "Folder with the wayland-protocols XML files") orelse "/usr/share/wayland-protocols";

    // The C header of xdg-shell, which wlroots' headers include.
    const xdg_xml = b.fmt("{s}/stable/xdg-shell/xdg-shell.xml", .{protocols});
    const scan = b.addSystemCommand(&.{ "wayland-scanner", "server-header", xdg_xml });
    const xdg_header = scan.addOutputFileArg("xdg-shell-protocol.h");

    // The same for the layer shell and the foreign-toplevel protocol (wlroots' headers include them).
    const layer_scan = b.addSystemCommand(&.{ "wayland-scanner", "server-header" });
    layer_scan.addFileArg(b.path("protocols/wlr-layer-shell-unstable-v1.xml"));
    const layer_header = layer_scan.addOutputFileArg("wlr-layer-shell-unstable-v1-protocol.h");
    const toplevel_scan = b.addSystemCommand(&.{ "wayland-scanner", "server-header" });
    toplevel_scan.addFileArg(b.path("../../protocols/wlr-foreign-toplevel-management-unstable-v1.xml"));
    const toplevel_header = toplevel_scan.addOutputFileArg("wlr-foreign-toplevel-management-unstable-v1-protocol.h");

    // wlroots, wayland-server and xkbcommon through Zig's C interop.
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.addIncludePath(xdg_header.dirname());
    translate_c.addIncludePath(layer_header.dirname());
    translate_c.addIncludePath(toplevel_header.dirname());
    translate_c.linkSystemLibrary("wlroots-0.19", .{});
    translate_c.linkSystemLibrary("wayland-server", .{});
    translate_c.linkSystemLibrary("xkbcommon", .{});
    translate_c.linkSystemLibrary("pixman-1", .{});

    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root.addImport("c", translate_c.createModule());
    const toml = b.dependency("toml", .{ .target = target, .optimize = optimize }).module("toml");
    root.addImport("toml", toml);
    root.linkSystemLibrary("wlroots-0.19", .{});
    root.linkSystemLibrary("wayland-server", .{});
    root.linkSystemLibrary("xkbcommon", .{});
    root.linkSystemLibrary("pixman-1", .{});

    const exe = b.addExecutable(.{ .name = "dkde-compositor", .root_module = root });
    b.installArtifact(exe);

    // The pieces with no wlroots in them (layout, settings) are tested on their own.
    const test_step = b.step("test", "Run the tests");
    inline for (.{ "src/layout.zig", "src/config.zig" }) |file| {
        const test_mod = b.createModule(.{ .root_source_file = b.path(file), .target = target, .optimize = optimize });
        test_mod.addImport("toml", toml);
        const t = b.addTest(.{ .root_module = test_mod });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    const run = b.addRunArtifact(exe);
    b.step("run", "Run the compositor").dependOn(&run.step);
}
