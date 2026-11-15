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
    const wlroots = b.fmt("wlroots-{s}", .{b.option([]const u8, "wlroots", "wlroots version (pkg-config name wlroots-<version>)") orelse "0.19"});
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

    // ext-workspace-v1 is not in wlroots 0.19: the compositor serves it itself, from wayland-scanner's
    // header (for the C interop) and glue code (the protocol's wl_interface tables).
    const ws_xml = b.fmt("{s}/staging/ext-workspace/ext-workspace-v1.xml", .{protocols});
    const ws_head = b.addSystemCommand(&.{ "wayland-scanner", "server-header", ws_xml });
    const ws_header = ws_head.addOutputFileArg("ext-workspace-v1-protocol.h");
    const ws_glue = b.addSystemCommand(&.{ "wayland-scanner", "private-code", ws_xml });
    const ws_code = ws_glue.addOutputFileArg("ext-workspace-v1-protocol.c");

    // Server headers of the other protocols wlroots' headers include.
    const more = [_][2][]const u8{
        .{ "staging/cursor-shape/cursor-shape-v1", "cursor-shape-v1" },
        .{ "unstable/tablet/tablet-unstable-v2", "tablet-unstable-v2" },
        .{ "staging/fractional-scale/fractional-scale-v1", "fractional-scale-v1" },
        .{ "unstable/xdg-decoration/xdg-decoration-unstable-v1", "xdg-decoration-unstable-v1" },
        .{ "staging/ext-idle-notify/ext-idle-notify-v1", "ext-idle-notify-v1" },
        .{ "unstable/primary-selection/primary-selection-unstable-v1", "primary-selection-unstable-v1" },
        .{ "stable/viewporter/viewporter", "viewporter" },
    };
    var more_headers: [more.len]std.Build.LazyPath = undefined;
    for (more, 0..) |entry, i| {
        const run = b.addSystemCommand(&.{ "wayland-scanner", "server-header", b.fmt("{s}/{s}.xml", .{ protocols, entry[0] }) });
        more_headers[i] = run.addOutputFileArg(b.fmt("{s}-protocol.h", .{entry[1]}));
    }

    // And the ones whose XML is in the repository's protocols/ folder.
    const repo = [_][]const u8{ "virtual-keyboard-unstable-v1", "wlr-virtual-pointer-unstable-v1" };
    var repo_headers: [repo.len]std.Build.LazyPath = undefined;
    for (repo, 0..) |name, i| {
        const run = b.addSystemCommand(&.{ "wayland-scanner", "server-header" });
        run.addFileArg(b.path(b.fmt("../../protocols/{s}.xml", .{name})));
        repo_headers[i] = run.addOutputFileArg(b.fmt("{s}-protocol.h", .{name}));
    }

    // wlroots, wayland-server and xkbcommon through Zig's C interop.
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.addIncludePath(xdg_header.dirname());
    translate_c.addIncludePath(layer_header.dirname());
    translate_c.addIncludePath(toplevel_header.dirname());
    translate_c.addIncludePath(ws_header.dirname());
    for (more_headers) |h| translate_c.addIncludePath(h.dirname());
    for (repo_headers) |h| translate_c.addIncludePath(h.dirname());
    translate_c.linkSystemLibrary(wlroots, .{});
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
    root.addCSourceFile(.{ .file = ws_code });
    const toml = b.dependency("toml", .{ .target = target, .optimize = optimize }).module("toml");
    root.addImport("toml", toml);
    root.linkSystemLibrary(wlroots, .{});
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
