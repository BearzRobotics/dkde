const std = @import("std");

const components = [_][]const u8{ "panel", "term", "files", "settings", "calc", "edit", "view", "tasks", "snip", "setup", "greeter", "pointer", "hex", "charmap", "clock", "calendar", "color", "disks", "idle", "pdf", "parted", "notify" };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const pdf = b.option(bool, "pdf", "Build dkde-pdf (needs libpoppler-glib-dev)") orelse false;
    const x11 = b.option(bool, "x11", "Build the optional X11 backend (needs libx11-dev)") orelse false;
    const build_options = b.addOptions();
    build_options.addOption(bool, "x11", x11);
    // Shown on the About page.
    build_options.addOption([]const u8, "version", @import("build.zig.zon").version);

    // The console and termcore come first and need no GTK-side dependency
    // (SPEC.md 5.11, *Build*). With -Dgui=false nothing below is configured, so
    // gobject and zig-wayland, which are lazy, are never fetched.
    const gui = b.option(bool, "gui", "Build the GTK programs (default). -Dgui=false builds only the console") orelse true;
    addConsole(b, target, optimize);
    if (!gui) return;

    const Scanner = (b.lazyImport(@This(), "wayland") orelse return).Scanner;
    const gobject = b.lazyDependency("gobject", .{ .target = target, .optimize = optimize }) orelse return;

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
    scanner.addCustomProtocol(b.path("protocols/ext-idle-notify-v1.xml"));
    scanner.addCustomProtocol(b.path("protocols/virtual-keyboard-unstable-v1.xml"));
    scanner.generate("wl_seat", 1);
    scanner.generate("wl_output", 1);
    scanner.generate("zwlr_foreign_toplevel_manager_v1", 3);
    scanner.generate("wl_shm", 1);
    scanner.generate("zwlr_screencopy_manager_v1", 3);
    scanner.generate("zwlr_virtual_pointer_manager_v1", 2);
    scanner.generate("ext_workspace_manager_v1", 1);
    scanner.generate("ext_idle_notifier_v1", 1);
    scanner.generate("zwp_virtual_keyboard_manager_v1", 1);
    const wayland_module = b.createModule(.{ .root_source_file = scanner.result, .target = target, .optimize = optimize });

    const test_step = b.step("test", "Run unit tests");
    const common_tests = b.addTest(.{ .root_module = common });
    test_step.dependOn(&b.addRunArtifact(common_tests).step);

    // Image decoding in Zig (vendored zigimg), shared by dkde-view and the PDF renderer.
    const zigimg = b.dependency("zigimg", .{ .target = target, .optimize = optimize });
    const imgcodec = b.createModule(.{ .root_source_file = b.path("src/imgcodec/root.zig"), .target = target, .optimize = optimize, .link_libc = true });
    imgcodec.addImport("zigimg", zigimg.module("zigimg"));
    const imgcodec_run = b.addRunArtifact(b.addTest(.{ .root_module = imgcodec }));
    imgcodec_run.has_side_effects = true; // DKDE_TEST_IMAGE is read from the environment
    test_step.dependOn(&imgcodec_run.step);

    // The PDF page renderer: cairo drawing on top of the vendored zpdf parser.
    // It does not need GTK or poppler, so its tests always run.
    const zpdf_mod = b.createModule(.{ .root_source_file = b.path("third_party/zpdf/src/root.zig"), .target = target, .optimize = optimize, .link_libc = true });
    const pdfrender = b.createModule(.{ .root_source_file = b.path("src/pdfrender/render.zig"), .target = target, .optimize = optimize, .link_libc = true });
    pdfrender.addImport("zpdf", zpdf_mod);
    pdfrender.addImport("truetype", truetypeModule(b, target, optimize));
    pdfrender.addImport("imgcodec", imgcodec);
    pdfrender.addImport("cairo1", gobject.module("cairo1"));
    pdfrender.linkSystemLibrary("cairo", .{});
    // JPEG decoding for image streams: stb_image, vendored, built by Zig's own C compiler.
    pdfrender.addCSourceFile(.{ .file = b.path("third_party/stb/stb_impl.c"), .flags = &.{"-O2"} });
    pdfrender.addIncludePath(b.path("third_party/stb"));
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = pdfrender })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = truetypeModule(b, target, optimize) })).step);

    // dkde-pdfcheck: draws many PDFs without a display and reports what was not drawn.
    const check_mod = b.createModule(.{ .root_source_file = b.path("src/pdfcheck/main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    check_mod.addImport("zpdf", zpdf_mod);
    check_mod.addImport("pdfrender", pdfrender);
    check_mod.addImport("cairo1", gobject.module("cairo1"));
    check_mod.addImport("glib2", gobject.module("glib2"));
    check_mod.linkSystemLibrary("cairo", .{});
    check_mod.linkSystemLibrary("glib-2.0", .{});
    b.installArtifact(b.addExecutable(.{ .name = "dkde-pdfcheck", .root_module = check_mod }));

    inline for (components) |name| {
        // dkde-pdf needs poppler, so it is only built when asked for.
        const is_pdf = comptime std.mem.eql(u8, name, "pdf");
        if (!is_pdf or pdf) {
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
            if (std.mem.eql(u8, name, "settings")) {
                // The Console page draws its preview with the console's own font code.
                const ghostty = b.dependency("ghostty", .{ .target = target, .optimize = .ReleaseFast });
                const tc = termcoreModule(b, target, optimize, ghostty);
                mod.addImport("termcore", tc);
                mod.addImport("consolefont", consoleFontModule(b, target, optimize, tc));
            }
            if (std.mem.eql(u8, name, "term")) {
                // Debug builds of libghostty-vt run integrity checks on every linefeed,
                // which makes a screenful of output take seconds. Always build it fast.
                const ghostty = b.dependency("ghostty", .{ .target = target, .optimize = .ReleaseFast });
                mod.addImport("ghostty-vt", ghostty.module("ghostty-vt"));
                // termcore must use the same libghostty-vt as the program that imports it.
                mod.addImport("termcore", termcoreModule(b, target, optimize, ghostty));
                mod.addImport("cairo1", gobject.module("cairo1"));
                mod.addImport("pangocairo1", gobject.module("pangocairo1"));
            }
            mod.addOptions("build_options", build_options);
            if (x11 and (std.mem.eql(u8, name, "panel") or std.mem.eql(u8, name, "snip"))) {
                mod.linkSystemLibrary("x11", .{});
                mod.addImport("gdkx114", gobject.module("gdkx114"));
            }
            if (std.mem.eql(u8, name, "snip") or std.mem.eql(u8, name, "panel") or std.mem.eql(u8, name, "tasks") or std.mem.eql(u8, name, "hex") or std.mem.eql(u8, name, "color") or std.mem.eql(u8, name, "parted") or std.mem.eql(u8, name, "pdf")) mod.addImport("cairo1", gobject.module("cairo1"));
            if (std.mem.eql(u8, name, "pdf")) mod.linkSystemLibrary("poppler-glib", .{});
            if (std.mem.eql(u8, name, "parted")) mod.addImport("pangocairo1", gobject.module("pangocairo1"));
            if (std.mem.eql(u8, name, "view")) mod.addImport("imgcodec", imgcodec);
            if (std.mem.eql(u8, name, "hex")) {
                mod.addImport("pangocairo1", gobject.module("pangocairo1"));
                // YAML, for Kaitai Struct format files (third_party/zig-yaml).
                mod.addImport("yaml", b.createModule(.{
                    .root_source_file = b.path("third_party/zig-yaml/src/lib.zig"),
                    .target = target,
                    .optimize = optimize,
                }));
            }
            if (std.mem.eql(u8, name, "panel") or std.mem.eql(u8, name, "snip") or std.mem.eql(u8, name, "pointer") or std.mem.eql(u8, name, "idle")) {
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
    }

    for ([_][]const u8{ "dkde-files", "dkde-term", "dkde-settings", "dkde-calc", "dkde-edit", "dkde-view", "dkde-tasks", "dkde-snip", "dkde-hex", "dkde-charmap", "dkde-clock", "dkde-calendar", "dkde-color", "dkde-disks", "dkde-parted" }) |name| {
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(
            b.path(b.fmt("data/{s}.desktop", .{name})),
            .prefix,
            b.fmt("share/applications/{s}.desktop", .{name}),
        ).step);
    }

    if (pdf) {
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(b.path("data/dkde-pdf.desktop"), .prefix, "share/applications/dkde-pdf.desktop").step);
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

/// The TrueType reader, shared by the PDF renderer and the console. Pure Zig.
fn truetypeModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    return b.createModule(.{ .root_source_file = b.path("src/truetype.zig"), .target = target, .optimize = optimize, .link_libc = true });
}

/// The console's font readers and settings table, shared with dkde-settings.
fn consoleFontModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, termcore: *std.Build.Module) *std.Build.Module {
    const m = b.createModule(.{
        .root_source_file = b.path("src/console/font.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    m.addImport("termcore", termcore);
    m.addImport("truetype", truetypeModule(b, target, optimize));
    m.addAnonymousImport("terminus16", .{ .root_source_file = b.path("third_party/terminus/Uni3-Terminus16.psf") });
    m.addAnonymousImport("terminus24", .{ .root_source_file = b.path("third_party/terminus/Uni3-Terminus24x12.psf") });
    m.addAnonymousImport("terminus32", .{ .root_source_file = b.path("third_party/terminus/Uni3-Terminus32x16.psf") });
    return m;
}

/// termcore, dkde-console and their tests. Imports only std and libghostty-vt.
fn termcoreModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, ghostty: *std.Build.Dependency) *std.Build.Module {
    const m = b.createModule(.{
        .root_source_file = b.path("src/termcore/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    m.addImport("ghostty-vt", ghostty.module("ghostty-vt"));
    return m;
}

fn addConsole(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    // Debug builds of libghostty-vt run integrity checks on every linefeed, so
    // it is always built fast (as for dkde-term).
    // simd=false leaves out simdutf and highway, which are C++ (SPEC.md 5.11,
    // *Dependencies*).
    const ghostty = b.dependency("ghostty", .{ .target = target, .optimize = .ReleaseFast, .simd = false });
    const termcore = termcoreModule(b, target, optimize, ghostty);

    const font = consoleFontModule(b, target, optimize, termcore);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/console/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addImport("termcore", termcore);
    mod.addImport("consolefont", font);
    mod.addImport("ghostty-vt", ghostty.module("ghostty-vt"));

    const exe = b.addExecutable(.{ .name = "dkde-console", .root_module = mod });
    // A rescue system must not need a dynamic loader (SPEC.md 5.11).
    if (target.result.abi.isMusl()) exe.linkage = .static;
    const install = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install.step);
    b.step("console", "Build only dkde-console").dependOn(&install.step);

    // Both modules are tested with nothing else in the graph: if either
    // imports GTK, GLib or a system library, this step stops building.
    const test_console = b.step("test-console", "Run the tests of termcore and the console");
    test_console.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = termcore })).step);
    test_console.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
    test_console.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = font })).step);
}
