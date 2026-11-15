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

    // wlroots, wayland-server and xkbcommon through Zig's C interop.
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.addIncludePath(xdg_header.dirname());
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
    root.linkSystemLibrary("wlroots-0.19", .{});
    root.linkSystemLibrary("wayland-server", .{});
    root.linkSystemLibrary("xkbcommon", .{});
    root.linkSystemLibrary("pixman-1", .{});

    const exe = b.addExecutable(.{ .name = "dkde-compositor", .root_module = root });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    b.step("run", "Run the compositor").dependOn(&run.step);
}
