const std = @import("std");

/// Programs that can be built on their own with -Dapp=<name> and are built
/// outside the `components` loop.
const standalone = [_][]const u8{ "polkit", "pdfcheck" };

/// Data files (under data/) installed with each program in a per-app install.
/// Every program reads the shared appearance defaults; the rest read their own.
const shared_data = [_][]const u8{ "style.css", "dkde.toml" };

fn appData(name: []const u8) []const []const u8 {
    const pairs = .{
        .{ "panel", &[_][]const u8{"panel.toml"} },
        .{ "term", &[_][]const u8{"term.toml"} },
        .{ "files", &[_][]const u8{"files.toml"} },
        .{ "edit", &[_][]const u8{"edit.toml"} },
        .{ "calendar", &[_][]const u8{"calendar.toml"} },
        // Settings edits every program's configuration, so it reads all defaults.
        .{ "settings", &[_][]const u8{ "panel.toml", "term.toml", "files.toml", "edit.toml", "calendar.toml" } },
        // Programs that read the panel's settings.
        .{ "view", &[_][]const u8{"panel.toml"} },
        .{ "idle", &[_][]const u8{"panel.toml"} },
    };
    inline for (pairs) |pair| {
        if (std.mem.eql(u8, name, pair[0])) return pair[1];
    }
    return &.{};
}

/// Programs that open no window and import only `core`.
const gtk_free = [_][]const u8{ "notify", "setup", "idle" };

fn isGtkFree(name: []const u8) bool {
    for (gtk_free) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

const components = [_][]const u8{ "panel", "term", "files", "settings", "calc", "edit", "view", "tasks", "snip", "setup", "greeter", "pointer", "charmap", "clock", "calendar", "color", "idle", "pdf", "parted", "notify", "polkit-ui", "help" };

pub fn build(b: *std.Build) void {
    addWindowsCalendar(b);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Debug information makes a release program ten times larger on disk (the
    // programs together were 134 MB, and 19 MB without it) and is never loaded
    // when the program runs. Debug builds keep it; every other build drops it,
    // unless -Dstrip=false asks for it (for perf or a debugger).
    const strip = b.option(bool, "strip", "Drop debug information from the programs (default: all builds but Debug)") orelse (optimize != .debug);

    // -Dapp=<name> builds, tests and installs one program and what it needs;
    // nothing else is configured or compiled. Without it, everything is.
    const app = b.option([]const u8, "app", "Build only this program (e.g. -Dapp=calc); default: all");
    if (app) |name| validateApp(b, name);

    const build_options = b.addOptions();
    // Shown on the About page and by --version.
    build_options.addOption([]const u8, "version", @import("build.zig.zon").version);
    // One module instance: the same generated file may not sit in two modules.
    const build_options_mod = build_options.createModule();

    const Scanner = (b.lazyImport(@This(), "wayland") orelse return).Scanner;
    const gobject = b.lazyDependency("gobject", .{ .target = target, .optimize = optimize }) orelse return;

    // The command-line contract (--help, --version, unknown options). Needs
    // no GTK, so it is also used by the programs that do not link it.
    const cli = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cli.addImport("build_options", build_options_mod);

    // core: toolkit-free (GLib/GIO only); common: core plus the GTK widgets.
    const core = b.addModule("core", .{
        .root_source_file = b.path("src/common/core.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addGlib(core, gobject);
    // The shipped defaults, so core's tests can check that they parse.
    inline for (.{ "dkde", "panel", "term", "files", "edit", "calendar" }) |name| {
        core.addAnonymousImport("data-" ++ name ++ ".toml", .{ .root_source_file = b.path("data/" ++ name ++ ".toml") });
    }
    core.addImport("toml", b.dependency("toml", .{ .target = target, .optimize = optimize }).module("toml"));
    // /etc/passwd and /etc/group parsing (no NSS), shared with the other Unix tools.
    const util_unix = b.dependency("util_unix", .{ .target = target, .optimize = optimize }).module("util_unix");
    core.addImport("util_unix", util_unix);

    const common = b.addModule("common", .{
        .root_source_file = b.path("src/common/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    common.addImport("core", core);
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
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = cli })).step);
    // core and common are dependencies of most programs, so their tests always run.
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = core })).step);
    const common_tests = b.addTest(.{ .root_module = common });
    test_step.dependOn(&b.addRunArtifact(common_tests).step);

    // Image decoding in Zig (vendored zigimg), shared by dkde-view and the PDF renderer.
    const zigimg = b.dependency("zigimg", .{ .target = target, .optimize = optimize });
    const imgcodec = b.createModule(.{ .root_source_file = b.path("src/imgcodec/root.zig"), .target = target, .optimize = optimize, .link_libc = true });
    imgcodec.addImport("zigimg", zigimg.module("zigimg"));
    if (wanted(app, "view") or wanted(app, "pdf") or wanted(app, "pdfcheck")) {
        const imgcodec_run = b.addRunArtifact(b.addTest(.{ .root_module = imgcodec }));
        imgcodec_run.has_side_effects = true; // DKDE_TEST_IMAGE is read from the environment
        test_step.dependOn(&imgcodec_run.step);
    }

    // The PDF page renderer: cairo drawing from pdf-zig's display list.
    // It does not need GTK, so its tests always run.
    const pdf_dep = b.dependency("pdf", .{ .target = target, .optimize = optimize });
    const pdf_mod = pdf_dep.module("pdf");
    const pdfrender = b.createModule(.{ .root_source_file = b.path("src/pdfrender/render.zig"), .target = target, .optimize = optimize, .link_libc = true });
    pdfrender.addImport("pdf", pdf_mod);
    pdfrender.addImport("truetype", truetypeModule(b, target, optimize));
    pdfrender.addImport("imgcodec", imgcodec);
    pdfrender.addImport("cairo1", gobject.module("cairo1"));
    pdfrender.linkSystemLibrary("cairo", .{});
    // JPEG decoding for image streams: stb_image, vendored, built by Zig's own C compiler.
    pdfrender.addCSourceFile(.{ .file = b.path("third_party/stb/stb_impl.c"), .flags = &.{"-O2"} });
    pdfrender.addIncludePath(b.path("third_party/stb"));
    if (wanted(app, "pdf") or wanted(app, "pdfcheck")) {
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = pdfrender })).step);
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = truetypeModule(b, target, optimize) })).step);
    }

    // dkde-pdfcheck: draws many PDFs without a display and reports what was not drawn.
    const check_mod = b.createModule(.{ .root_source_file = b.path("src/pdfcheck/main.zig"), .target = target, .optimize = optimize, .link_libc = true, .strip = strip });
    check_mod.addImport("cli", cli);
    check_mod.addImport("pdfrender", pdfrender);
    check_mod.addImport("cairo1", gobject.module("cairo1"));
    check_mod.addImport("glib2", gobject.module("glib2"));
    check_mod.linkSystemLibrary("cairo", .{});
    check_mod.linkSystemLibrary("glib-2.0", .{});
    if (wanted(app, "pdfcheck")) b.installArtifact(b.addExecutable(.{ .name = "dkde-pdfcheck", .root_module = check_mod }));

    // polkit's line protocol and session helpers, shared by the agent and its dialog.
    const polkitProtoModule = b.createModule(.{
        .root_source_file = b.path("src/polkit/proto.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (wanted(app, "polkit") or wanted(app, "polkit-ui")) {
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = polkitProtoModule })).step);
    }

    inline for (components) |name| {
        if (wanted(app, name)) {
            const mod = b.createModule(.{
                .root_source_file = b.path("src/" ++ name ++ "/main.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .strip = strip,
            });
            if (isGtkFree(name)) {
                // No window: GLib and GIO only, so no GTK is linked or loaded.
                mod.addImport("core", core);
                addGlib(mod, gobject);
            } else {
                mod.addImport("common", common);
                // gtk4-layer-shell must be linked before libwayland, so before GTK.
                if (std.mem.eql(u8, name, "panel")) mod.linkSystemLibrary("gtk4-layer-shell-0", .{});
                addGtk(mod, gobject);
            }
            if (std.mem.eql(u8, name, "polkit-ui")) mod.addImport("polkitproto", polkitProtoModule);
            if (std.mem.eql(u8, name, "calendar")) {
                mod.linkSystemLibrary("fontconfig", .{});
                // The glyph font is built into the program.
                mod.addAnonymousImport("rosquin-font", .{ .root_source_file = b.path("data/fonts/RosquinGlyphs.ttf") });
                mod.addAnonymousImport("branding", .{ .root_source_file = b.path("data/branding.png") });
                // The open-source fonts for the native names of the Chinese, Hebrew, Coptic and Ethiopian calendars.
                mod.addAnonymousImport("font-cjk", .{ .root_source_file = b.path("data/fonts/native/DroidSansFallbackSubset.ttf") });
                mod.addAnonymousImport("font-he", .{ .root_source_file = b.path("data/fonts/native/NotoSansHebrew-Regular.ttf") });
                mod.addAnonymousImport("font-et", .{ .root_source_file = b.path("data/fonts/native/NotoSansEthiopic-Regular.ttf") });
                mod.addAnonymousImport("font-cop", .{ .root_source_file = b.path("data/fonts/native/NotoSansCoptic-Regular.ttf") });
            }
            if (std.mem.eql(u8, name, "settings")) {
                // The Terminal page previews colour schemes with termcore's tables.
                mod.addImport("termcore", b.dependency("dkterm", .{ .target = target, .optimize = optimize }).module("termcore"));
            }
            if (std.mem.eql(u8, name, "files") or std.mem.eql(u8, name, "edit")) {
                mod.addImport("termembed", termEmbedModule(b, target, optimize, common, gobject));
            }
            if (std.mem.eql(u8, name, "term")) {
                // Debug builds of libghostty-vt run integrity checks on every linefeed,
                // which makes a screenful of output take seconds. Always build it fast.
                // termcore must use the same libghostty-vt as the program that imports it:
                // take both from DKTermCore, which builds libghostty-vt once.
                const dkterm = b.dependency("dkterm", .{ .target = target, .optimize = optimize });
                mod.addImport("ghostty-vt", dkterm.module("ghostty-vt"));
                mod.addImport("termcore", dkterm.module("termcore"));
                mod.addImport("cairo1", gobject.module("cairo1"));
                mod.addImport("pangocairo1", gobject.module("pangocairo1"));
            }
            mod.addImport("build_options", build_options_mod);
            mod.addImport("cli", cli);
            if (std.mem.eql(u8, name, "snip") or std.mem.eql(u8, name, "files") or std.mem.eql(u8, name, "panel") or std.mem.eql(u8, name, "tasks") or std.mem.eql(u8, name, "color") or std.mem.eql(u8, name, "parted") or std.mem.eql(u8, name, "pdf")) mod.addImport("cairo1", gobject.module("cairo1"));
            if (std.mem.eql(u8, name, "pdf")) {
                mod.addImport("pdfrender", pdfrender);
                mod.addImport("pdf", pdf_mod);
            }
            if (std.mem.eql(u8, name, "parted")) mod.addImport("pangocairo1", gobject.module("pangocairo1"));
            if (std.mem.eql(u8, name, "view")) mod.addImport("imgcodec", imgcodec);
            if (std.mem.eql(u8, name, "settings") or std.mem.eql(u8, name, "tasks")) mod.addImport("util_unix", util_unix);
            if (std.mem.eql(u8, name, "help")) {
                // Manual-page lookup and rendering: dkman's library (which brings md-zig and gtroff-zig).
                const dkman = b.lazyDependency("dkman", .{ .target = target, .optimize = optimize }) orelse return;
                mod.addImport("dkman", dkman.module("dkman"));
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
            run.setEnvironmentVariable("DKDE_HELP_DIR", "docs/manpages");
            b.step("run-" ++ name, "Build and run dkde-" ++ name).dependOn(&run.step);

            const run_tests = b.addRunArtifact(b.addTest(.{ .root_module = mod }));
            test_step.dependOn(&run_tests.step);
            b.step("test-" ++ name, "Run the tests of dkde-" ++ name).dependOn(&run_tests.step);
        }
    }

    // The polkit agent: D-Bus only, so it links GLib and GIO but not GTK and
    // idles in a few megabytes (SPEC.md 5.12). Its dialog is `dkde-polkit-ui`.
    if (wanted(app, "polkit")) {
        const mod = b.createModule(.{
            .root_source_file = b.path("src/polkit/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .strip = strip,
        });
        mod.addImport("polkitproto", polkitProtoModule);
        mod.addImport("cli", cli);
        mod.linkSystemLibrary("gio-2.0", .{});
        inline for (.{ "glib2", "gobject2", "gio2" }) |name| mod.addImport(name, gobject.module(name));
        b.installArtifact(b.addExecutable(.{ .name = "dkde-polkit", .root_module = mod }));
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
    }

    for ([_][]const u8{ "dkde-files", "dkde-term", "dkde-settings", "dkde-calc", "dkde-edit", "dkde-view", "dkde-pdf", "dkde-tasks", "dkde-snip", "dkde-charmap", "dkde-clock", "dkde-calendar", "dkde-color", "dkde-parted", "dkde-help" }) |name| {
        if (!wanted(app, name["dkde-".len..])) continue;
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(
            b.path(b.fmt("data/{s}.desktop", .{name})),
            .prefix,
            b.fmt("share/applications/{s}.desktop", .{name}),
        ).step);
    }

    // The help viewer shows these (and the system's manual pages).
    if (wanted(app, "help")) {
        b.installDirectory(.{ .source_dir = b.path("docs/manpages"), .install_dir = .prefix, .install_subdir = "share/dkde/help", .exclude_extensions = &.{} });
    }

    if (app) |name| {
        // A per-app install carries only that program's data (and the shared defaults).
        for (shared_data) |file| installDataFile(b, file);
        for (appData(name)) |file| installDataFile(b, file);
    } else {
        // Session scripts and the login-manager entry.
        for ([_][]const u8{ "dkde-session", "dkde-greeter-session", "dkde-greeter-start", "dkde-seatd" }) |script| {
            // @VERSION@ in a script is replaced by the package version.
            const sed = b.addSystemCommand(&.{ "sh", "-c", "sed -e \"s/@VERSION@/$0/g\" \"$1\" > \"$2\" && chmod 755 \"$2\"", @import("build.zig.zon").version });
            sed.addFileArg(b.path(b.fmt("scripts/{s}", .{script})));
            const generated = sed.addOutputFileArg(script);
            b.getInstallStep().dependOn(&b.addInstallBinFile(generated, script).step);
        }
        // The Wayland session entry for greetd and other login managers.
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(b.path("data/dkde.desktop"), .prefix, "share/wayland-sessions/dkde.desktop").step);

        b.installDirectory(.{
            .source_dir = b.path("data"),
            .install_dir = .prefix,
            .install_subdir = "share/dkde",
        });
        // The Fluent icon theme goes where every toolkit looks for icon themes.
        b.installDirectory(.{
            .source_dir = b.path("icons/Fluent"),
            .install_dir = .prefix,
            .install_subdir = "share/icons/Fluent",
        });
        // Microsoft's Fluent UI System Icons for dkde's own controls; it inherits Fluent.
        b.installDirectory(.{
            .source_dir = b.path("icons/dkde-ui"),
            .install_dir = .prefix,
            .install_subdir = "share/icons/dkde-ui",
        });
    }
}

fn installDataFile(b: *std.Build, file: []const u8) void {
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(b.path(b.fmt("data/{s}", .{file})), .prefix, b.fmt("share/dkde/{s}", .{file})).step);
}

fn isApp(app: ?[]const u8, name: []const u8) bool {
    return if (app) |a| std.mem.eql(u8, a, name) else false;
}

/// Is `name` part of this build? Everything is when no -Dapp was given.
fn wanted(app: ?[]const u8, name: []const u8) bool {
    return app == null or isApp(app, name);
}

fn validateApp(b: *std.Build, name: []const u8) void {
    for (components) |c| if (std.mem.eql(u8, c, name)) return;
    for (standalone) |c| if (std.mem.eql(u8, c, name)) return;
    var list: std.ArrayList(u8) = .empty;
    for (components ++ standalone) |c| list.print(b.allocator, " {s}", .{c}) catch @panic("OOM");
    std.process.fatal("unknown -Dapp={s}; choose one of:{s}", .{ name, list.items });
}

/// GLib and GIO, without GTK.
fn addGlib(mod: *std.Build.Module, gobject: *std.Build.Dependency) void {
    mod.linkSystemLibrary("gio-2.0", .{});
    inline for (.{ "glib2", "gobject2", "gio2", "giounix2" }) |name| {
        mod.addImport(name, gobject.module(name));
    }
}

fn addGtk(mod: *std.Build.Module, gobject: *std.Build.Dependency) void {
    mod.linkSystemLibrary("gtk4", .{});
    inline for (.{ "glib2", "gobject2", "gio2", "giounix2", "gtk4", "gdk4", "pango1", "gdkpixbuf2" }) |name| {
        mod.addImport(name, gobject.module(name));
    }
}

/// The terminal as a widget other programs can host (dkde-files, dkde-edit):
/// the same view dkde-term uses, on DKTermCore. Compiled only into the
/// programs that import it.
fn termEmbedModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, common: *std.Build.Module, gobject: *std.Build.Dependency) *std.Build.Module {
    const m = b.createModule(.{ .root_source_file = b.path("src/term/embed.zig"), .target = target, .optimize = optimize, .link_libc = true });
    m.addImport("common", common);
    const dkterm = b.dependency("dkterm", .{ .target = target, .optimize = optimize });
    m.addImport("ghostty-vt", dkterm.module("ghostty-vt"));
    m.addImport("termcore", dkterm.module("termcore"));
    inline for (.{ "glib2", "gobject2", "gio2", "gtk4", "gdk4", "pango1", "pangocairo1", "cairo1" }) |name| {
        m.addImport(name, gobject.module(name));
    }
    return m;
}

/// The TrueType reader used by the PDF renderer. Pure Zig.
fn truetypeModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    return b.createModule(.{ .root_source_file = b.path("src/truetype.zig"), .target = target, .optimize = optimize, .link_libc = true });
}

/// `zig build wincal`: the standalone Windows calendar (zig-out/bin/rosquin-calendar.exe).
/// Opt-in only: it is not part of the default install (`zig build`), of `-Dapp=...` builds or
/// of `zig build test`; nothing compiles it unless this step is named.
/// One executable for 64-bit Windows with no GTK, no runtime and no data files;
/// it shares the calendar rules with dkde-calendar and has the glyph font built in.
fn addWindowsCalendar(b: *std.Build) void {
    const step = b.step("wincal", "Build the standalone Windows calendar (rosquin-calendar.exe)");
    const target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu });
    const rules = b.createModule(.{ .root_source_file = b.path("src/common/wincommon.zig"), .target = target, .optimize = .ReleaseSmall });
    const mod = b.createModule(.{ .root_source_file = b.path("src/calendar/win.zig"), .target = target, .optimize = .ReleaseSmall, .strip = true });
    rules.addImport("toml", b.dependency("toml", .{ .target = target, .optimize = .ReleaseSmall }).module("toml"));
    mod.addImport("common", rules);
    mod.addAnonymousImport("rosquin-font", .{ .root_source_file = b.path("data/fonts/RosquinGlyphs.ttf") });
    mod.addAnonymousImport("calendar-defaults", .{ .root_source_file = b.path("data/calendar.toml") });
    mod.addAnonymousImport("branding", .{ .root_source_file = b.path("data/branding-128.bgra") });
    mod.addAnonymousImport("font-cjk", .{ .root_source_file = b.path("data/fonts/native/DroidSansFallbackSubset.ttf") });
    mod.addAnonymousImport("font-he", .{ .root_source_file = b.path("data/fonts/native/NotoSansHebrew-Regular.ttf") });
    mod.addAnonymousImport("font-et", .{ .root_source_file = b.path("data/fonts/native/NotoSansEthiopic-Regular.ttf") });
    mod.addAnonymousImport("font-cop", .{ .root_source_file = b.path("data/fonts/native/NotoSansCoptic-Regular.ttf") });
    mod.linkSystemLibrary("user32", .{});
    mod.linkSystemLibrary("comdlg32", .{});
    mod.linkSystemLibrary("gdi32", .{});
    mod.linkSystemLibrary("kernel32", .{});
    const exe = b.addExecutable(.{ .name = "rosquin-calendar", .root_module = mod });
    exe.subsystem = .windows;
    step.dependOn(&b.addInstallArtifact(exe, .{}).step);
}
