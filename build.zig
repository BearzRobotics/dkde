const std = @import("std");
const Scanner = @import("wayland").Scanner;

const components = [_][]const u8{ "panel", "term", "files", "settings", "calc", "edit", "view", "tasks", "snip", "setup", "greeter", "pointer", "hex" };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const x11 = b.option(bool, "x11", "Build the optional X11 backend (needs libx11-dev)") orelse false;
    const build_options = b.addOptions();
    build_options.addOption(bool, "x11", x11);

    const gobject = b.dependency("gobject", .{ .target = target, .optimize = optimize });

    const common = b.addModule("common", .{
        .root_source_file = b.path("src/common/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addGtk(common, gobject);

    // Protocol bindings for what GTK does not expose (SPEC.md 3).
    const scanner = Scanner.create(b, .{});
    scanner.addCustomProtocol(b.path("protocols/wlr-foreign-toplevel-management-unstable-v1.xml"));
    scanner.addCustomProtocol(b.path("protocols/wlr-screencopy-unstable-v1.xml"));
    scanner.addCustomProtocol(b.path("protocols/wlr-virtual-pointer-unstable-v1.xml"));
    scanner.addCustomProtocol(b.path("protocols/ext-workspace-v1.xml"));
    scanner.generate("wl_seat", 1);
    scanner.generate("wl_output", 1);
    scanner.generate("zwlr_foreign_toplevel_manager_v1", 3);
    scanner.generate("wl_shm", 1);
    scanner.generate("zwlr_screencopy_manager_v1", 3);
    scanner.generate("zwlr_virtual_pointer_manager_v1", 2);
    scanner.generate("ext_workspace_manager_v1", 1);
    const wayland_module = b.createModule(.{ .root_source_file = scanner.result, .target = target, .optimize = optimize });

    const test_step = b.step("test", "Run unit tests");
    const common_tests = b.addTest(.{ .root_module = common });
    test_step.dependOn(&b.addRunArtifact(common_tests).step);

    inline for (components) |name| {
        const mod = b.createModule(.{
            .root_source_file = b.path("src/" ++ name ++ "/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        mod.addImport("common", common);
        // gtk4-layer-shell must be linked before libwayland, so before GTK.
        if (std.mem.eql(u8, name, "panel")) mod.linkSystemLibrary("gtk4-layer-shell-0", .{});
        addGtk(mod, gobject);
        if (std.mem.eql(u8, name, "term")) {
            // Debug builds of libghostty-vt run integrity checks on every linefeed,
            // which makes a screenful of output take seconds. Always build it fast.
            const ghostty = b.dependency("ghostty", .{ .target = target, .optimize = .ReleaseFast });
            mod.addImport("ghostty-vt", ghostty.module("ghostty-vt"));
            mod.addImport("cairo1", gobject.module("cairo1"));
            mod.addImport("pangocairo1", gobject.module("pangocairo1"));
        }
        mod.addOptions("build_options", build_options);
        if (x11 and (std.mem.eql(u8, name, "panel") or std.mem.eql(u8, name, "snip"))) {
            mod.linkSystemLibrary("x11", .{});
            mod.addImport("gdkx114", gobject.module("gdkx114"));
        }
        if (std.mem.eql(u8, name, "snip") or std.mem.eql(u8, name, "panel") or std.mem.eql(u8, name, "tasks") or std.mem.eql(u8, name, "hex")) mod.addImport("cairo1", gobject.module("cairo1"));
        if (std.mem.eql(u8, name, "hex")) mod.addImport("pangocairo1", gobject.module("pangocairo1"));
        if (std.mem.eql(u8, name, "panel") or std.mem.eql(u8, name, "snip") or std.mem.eql(u8, name, "pointer")) {
            mod.addImport("gdkwayland4", gobject.module("gdkwayland4"));
            mod.addImport("wayland", wayland_module);
            mod.linkSystemLibrary("wayland-client", .{});
        }

        const exe = b.addExecutable(.{ .name = "dkde-" ++ name, .root_module = mod });
        b.installArtifact(exe);

        const run = b.addRunArtifact(exe);
        // Dev runs read data files straight from the source tree.
        run.setCwd(b.path("."));
        run.setEnvironmentVariable("DKDE_DATA_DIR", "data");
        b.step("run-" ++ name, "Build and run dkde-" ++ name).dependOn(&run.step);

        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
    }

    for ([_][]const u8{ "dkde-files", "dkde-term", "dkde-settings", "dkde-calc", "dkde-edit", "dkde-view", "dkde-tasks", "dkde-snip", "dkde-hex" }) |name| {
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(
            b.path(b.fmt("data/{s}.desktop", .{name})),
            .prefix,
            b.fmt("share/applications/{s}.desktop", .{name}),
        ).step);
    }

    // The X11 session: scripts and the login-manager entry. Harmless on a
    // Wayland-only system, so they always install.
    for ([_][]const u8{ "dkde-xsession", "dkde-startx", "dkde-session", "dkde-greeter-session", "dkde-greeter-start" }) |script| {
        b.getInstallStep().dependOn(&b.addInstallBinFile(b.path(b.fmt("scripts/{s}", .{script})), script).step);
    }
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(b.path("data/dkde-x11.desktop"), .prefix, "share/xsessions/dkde-x11.desktop").step);
    // The Wayland session entry for greetd and other login managers.
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(b.path("data/dkde.desktop"), .prefix, "share/wayland-sessions/dkde.desktop").step);

    b.installDirectory(.{
        .source_dir = b.path("data"),
        .install_dir = .prefix,
        .install_subdir = "share/dkde",
    });
}

fn addGtk(mod: *std.Build.Module, gobject: *std.Build.Dependency) void {
    mod.linkSystemLibrary("gtk4", .{});
    inline for (.{ "glib2", "gobject2", "gio2", "giounix2", "gtk4", "gdk4", "pango1", "gdkpixbuf2" }) |name| {
        mod.addImport(name, gobject.module(name));
    }
}
