//! The build of every dkde program. What each program needs (libraries,
//! modules, embedded files, data files, a menu entry) is in its own
//! `src/<name>/build.zig`; this file sets up what programs share and calls
//! each of them.
//!
//!   zig build                    every program (also: -Dapp=all)
//!   zig build -Dapp=calc         one program, with only its own data
//!   zig build -Dapp=term,edit    a few programs
//!   zig build test               the tests of what is selected
//!   zig build run-<name>         build and run one program from the tree

const std = @import("std");

/// Every program, in the order they are configured. Each has a
/// `src/<name>/build.zig`; see `Ctx` for what one may declare.
const programs = .{
    .{ "panel", @import("src/panel/build.zig") },
    .{ "term", @import("src/term/build.zig") },
    .{ "files", @import("src/files/build.zig") },
    .{ "settings", @import("src/settings/build.zig") },
    .{ "calc", @import("src/calc/build.zig") },
    .{ "edit", @import("src/edit/build.zig") },
    .{ "view", @import("src/view/build.zig") },
    .{ "tasks", @import("src/tasks/build.zig") },
    .{ "snip", @import("src/snip/build.zig") },
    .{ "setup", @import("src/setup/build.zig") },
    .{ "greeter", @import("src/greeter/build.zig") },
    .{ "pointer", @import("src/pointer/build.zig") },
    .{ "charmap", @import("src/charmap/build.zig") },
    .{ "clock", @import("src/clock/build.zig") },
    .{ "calendar", @import("src/calendar/build.zig") },
    .{ "color", @import("src/color/build.zig") },
    .{ "idle", @import("src/idle/build.zig") },
    .{ "pdf", @import("src/pdf/build.zig") },
    .{ "parted", @import("src/parted/build.zig") },
    .{ "notify", @import("src/notify/build.zig") },
    .{ "polkit", @import("src/polkit/build.zig") },
    .{ "polkit-ui", @import("src/polkit-ui/build.zig") },
    .{ "help", @import("src/help/build.zig") },
    .{ "pdfcheck", @import("src/pdfcheck/build.zig") },
};

/// Data files (under data/) installed with every program in a per-app install.
const shared_data = [_][]const u8{ "style.css", "dkde.toml" };

/// What a program's `build.zig` is given. A program's build file declares:
///
///   pub fn configure(ctx: *const Ctx, mod: *std.Build.Module) void
///       adds the program's imports and libraries to its root module
///       (`src/<name>/main.zig`); it must call `ctx.gtk(mod)` or
///       `ctx.glib(mod)` for the toolkit it uses.
///   pub const data: []const []const u8   its own files under data/ (optional)
///   pub const menu_entry = true          installs data/dkde-<name>.desktop (optional)
pub const Ctx = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    gobject: *std.Build.Dependency,
    /// The command-line contract (--help, --version); every program has it.
    cli: *std.Build.Module,
    build_options: *std.Build.Module,
    /// Toolkit-free shared code (GLib/GIO only).
    core: *std.Build.Module,
    /// `core` plus the GTK widgets.
    common: *std.Build.Module,
    util_unix: *std.Build.Module,
    /// Bindings for the Wayland protocols GTK does not expose.
    wayland_protocols: *std.Build.Module,
    /// Image decoding in Zig (vendored zigimg).
    imgcodec: *std.Build.Module,
    /// The PDF page renderer and pdf-zig.
    pdfrender: *std.Build.Module,
    pdf: *std.Build.Module,
    /// polkit's line protocol, shared by the agent and its dialog.
    polkit_proto: *std.Build.Module,

    /// GTK 4 and what comes with it (GLib, Pango, GdkPixbuf).
    pub fn gtk(ctx: *const Ctx, mod: *std.Build.Module) void {
        mod.addImport("common", ctx.common);
        mod.linkSystemLibrary("gtk4", .{});
        ctx.imports(mod, &.{ "glib2", "gobject2", "gio2", "giounix2", "gtk4", "gdk4", "pango1", "gdkpixbuf2" });
    }

    /// GLib and GIO without GTK, for programs that open no window.
    pub fn glib(ctx: *const Ctx, mod: *std.Build.Module) void {
        mod.addImport("core", ctx.core);
        ctx.glibOnly(mod);
    }

    /// GLib and GIO without dkde's `core`.
    pub fn glibOnly(ctx: *const Ctx, mod: *std.Build.Module) void {
        mod.linkSystemLibrary("gio-2.0", .{});
        ctx.imports(mod, &.{ "glib2", "gobject2", "gio2", "giounix2" });
    }

    /// Modules from the GObject bindings, e.g. "cairo1", "pangocairo1".
    pub fn imports(ctx: *const Ctx, mod: *std.Build.Module, names: []const []const u8) void {
        for (names) |name| mod.addImport(name, ctx.gobject.module(name));
    }

    /// The Wayland protocol bindings and libwayland-client.
    pub fn wayland(ctx: *const Ctx, mod: *std.Build.Module) void {
        mod.addImport("gdkwayland4", ctx.gobject.module("gdkwayland4"));
        mod.addImport("wayland", ctx.wayland_protocols);
        mod.linkSystemLibrary("wayland-client", .{});
    }

    /// DKTermCore, which builds libghostty-vt once for every user of it.
    pub fn dkterm(ctx: *const Ctx) *std.Build.Dependency {
        return ctx.b.dependency("dkterm", .{ .target = ctx.target, .optimize = ctx.optimize });
    }

    /// The terminal as a widget other programs can host (dkde-files,
    /// dkde-edit): the same view dkde-term uses.
    pub fn termEmbed(ctx: *const Ctx) *std.Build.Module {
        const m = ctx.b.createModule(.{ .root_source_file = ctx.b.path("src/term/embed.zig"), .target = ctx.target, .optimize = ctx.optimize, .link_libc = true });
        m.addImport("common", ctx.common);
        const dep = ctx.dkterm();
        m.addImport("ghostty-vt", dep.module("ghostty-vt"));
        m.addImport("termcore", dep.module("termcore"));
        ctx.imports(m, &.{ "glib2", "gobject2", "gio2", "gtk4", "gdk4", "pango1", "pangocairo1", "cairo1", "gdkpixbuf2" });
        return m;
    }
};

pub fn build(b: *std.Build) void {
    addWindowsCalendar(b);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Debug information makes a release program ten times larger on disk (the
    // programs together were 134 MB, and 19 MB without it) and is never loaded
    // when the program runs. Debug builds keep it; every other build drops it,
    // unless -Dstrip=false asks for it (for perf or a debugger).
    const strip = b.option(bool, "strip", "Drop debug information from the programs (default: all builds but Debug)") orelse (optimize != .debug);

    // -Dapp=<name>[,<name>...] builds, tests and installs those programs and
    // what they need; nothing else is configured or compiled. Without it (or
    // with -Dapp=all), everything is.
    const app_option = b.option([]const u8, "app", "Build only these programs (e.g. -Dapp=calc or -Dapp=term,edit); default: all");
    const selection = Selection.parse(b, app_option);

    const build_options = b.addOptions();
    // Shown on the About page and by --version.
    build_options.addOption([]const u8, "version", @import("build.zig.zon").version);
    // One module instance: the same generated file may not sit in two modules.
    const build_options_mod = build_options.createModule();

    const Scanner = (b.lazyImport(@This(), "wayland") orelse return).Scanner;
    const gobject = b.lazyDependency("gobject", .{ .target = target, .optimize = optimize }) orelse return;

    const cli = b.createModule(.{ .root_source_file = b.path("src/cli.zig"), .target = target, .optimize = optimize, .link_libc = true });
    cli.addImport("build_options", build_options_mod);

    const core = b.addModule("core", .{ .root_source_file = b.path("src/common/core.zig"), .target = target, .optimize = optimize, .link_libc = true });
    core.linkSystemLibrary("gio-2.0", .{});
    inline for (.{ "glib2", "gobject2", "gio2", "giounix2" }) |name| core.addImport(name, gobject.module(name));
    // The shipped defaults, so core's tests can check that they parse.
    inline for (.{ "dkde", "panel", "term", "files", "edit", "calendar", "view" }) |name| {
        core.addAnonymousImport("data-" ++ name ++ ".toml", .{ .root_source_file = b.path("data/" ++ name ++ ".toml") });
    }
    core.addImport("toml", b.dependency("toml", .{ .target = target, .optimize = optimize }).module("toml"));
    // /etc/passwd and /etc/group parsing (no NSS), shared with the other Unix tools.
    const util_unix = b.dependency("util_unix", .{ .target = target, .optimize = optimize }).module("util_unix");
    core.addImport("util_unix", util_unix);

    const common = b.addModule("common", .{ .root_source_file = b.path("src/common/root.zig"), .target = target, .optimize = optimize, .link_libc = true });
    common.addImport("core", core);
    common.linkSystemLibrary("gtk4", .{});
    inline for (.{ "glib2", "gobject2", "gio2", "giounix2", "gtk4", "gdk4", "pango1", "gdkpixbuf2" }) |name| common.addImport(name, gobject.module(name));

    // Protocol bindings for what GTK does not expose (SPEC.md 3).
    const scanner = Scanner.create(b, .{});
    inline for (.{ "wlr-foreign-toplevel-management-unstable-v1", "wlr-screencopy-unstable-v1", "wlr-virtual-pointer-unstable-v1", "ext-workspace-v1", "ext-idle-notify-v1", "virtual-keyboard-unstable-v1" }) |p| {
        scanner.addCustomProtocol(b.path("protocols/" ++ p ++ ".xml"));
    }
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

    const zigimg = b.dependency("zigimg", .{ .target = target, .optimize = optimize });
    const imgcodec = b.createModule(.{ .root_source_file = b.path("src/imgcodec/root.zig"), .target = target, .optimize = optimize, .link_libc = true });
    imgcodec.addImport("zigimg", zigimg.module("zigimg"));

    // The PDF page renderer: cairo drawing from pdf-zig's display list.
    const pdf_mod = b.dependency("pdf", .{ .target = target, .optimize = optimize }).module("pdf");
    const truetype = b.createModule(.{ .root_source_file = b.path("src/truetype.zig"), .target = target, .optimize = optimize, .link_libc = true });
    const pdfrender = b.createModule(.{ .root_source_file = b.path("src/pdfrender/render.zig"), .target = target, .optimize = optimize, .link_libc = true });
    pdfrender.addImport("pdf", pdf_mod);
    pdfrender.addImport("truetype", truetype);
    pdfrender.addImport("imgcodec", imgcodec);
    pdfrender.addImport("cairo1", gobject.module("cairo1"));
    pdfrender.linkSystemLibrary("cairo", .{});
    // JPEG decoding for image streams: stb_image, vendored, built by Zig's own C compiler.
    pdfrender.addCSourceFile(.{ .file = b.path("third_party/stb/stb_impl.c"), .flags = &.{"-O2"} });
    pdfrender.addIncludePath(b.path("third_party/stb"));

    const polkit_proto = b.createModule(.{ .root_source_file = b.path("src/polkit/proto.zig"), .target = target, .optimize = optimize });

    const ctx: Ctx = .{
        .b = b,
        .target = target,
        .optimize = optimize,
        .gobject = gobject,
        .cli = cli,
        .build_options = build_options_mod,
        .core = core,
        .common = common,
        .util_unix = util_unix,
        .wayland_protocols = wayland_module,
        .imgcodec = imgcodec,
        .pdfrender = pdfrender,
        .pdf = pdf_mod,
        .polkit_proto = polkit_proto,
    };

    const test_step = b.step("test", "Run unit tests");
    const addTests = struct {
        fn f(bb: *std.Build, step: *std.Build.Step, mod: *std.Build.Module) *std.Build.Step.Run {
            const run = bb.addRunArtifact(bb.addTest(.{ .root_module = mod }));
            step.dependOn(&run.step);
            return run;
        }
    }.f;
    // core and common are dependencies of most programs, so their tests always run.
    _ = addTests(b, test_step, cli);
    _ = addTests(b, test_step, core);
    _ = addTests(b, test_step, common);
    // Shared modules are tested when a program that uses them is selected.
    if (selection.any(&.{ "view", "pdf", "pdfcheck" })) {
        addTests(b, test_step, imgcodec).has_side_effects = true; // DKDE_TEST_IMAGE is read from the environment
    }
    if (selection.any(&.{ "pdf", "pdfcheck" })) {
        _ = addTests(b, test_step, pdfrender);
        _ = addTests(b, test_step, truetype);
    }
    if (selection.any(&.{ "polkit", "polkit-ui" })) _ = addTests(b, test_step, polkit_proto);

    inline for (programs) |p| {
        const name = p[0];
        const sub = p[1];
        if (selection.has(name)) {
            const mod = b.createModule(.{
                .root_source_file = b.path("src/" ++ name ++ "/main.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .strip = strip,
            });
            mod.addImport("build_options", build_options_mod);
            mod.addImport("cli", cli);
            sub.configure(&ctx, mod);

            const exe = b.addExecutable(.{ .name = "dkde-" ++ name, .root_module = mod });
            b.installArtifact(exe);

            const run = b.addRunArtifact(exe);
            // Dev runs read data files straight from the source tree.
            run.setCwd(b.path("."));
            run.setEnvironmentVariable("DKDE_DATA_DIR", "data");
            run.setEnvironmentVariable("DKDE_HELP_DIR", "docs/manpages");
            b.step("run-" ++ name, "Build and run dkde-" ++ name).dependOn(&run.step);

            const run_tests = addTests(b, test_step, mod);
            b.step("test-" ++ name, "Run the tests of dkde-" ++ name).dependOn(&run_tests.step);

            if (@hasDecl(sub, "menu_entry") and sub.menu_entry) {
                b.getInstallStep().dependOn(&b.addInstallFileWithDir(
                    b.path("data/dkde-" ++ name ++ ".desktop"),
                    .prefix,
                    "share/applications/dkde-" ++ name ++ ".desktop",
                ).step);
            }
            if (selection.single() and @hasDecl(sub, "data")) {
                for (sub.data) |file| installDataFile(b, file);
            }
            if (@hasDecl(sub, "install")) sub.install(&ctx);
        }
    }

    if (selection.single()) {
        // A per-app install carries only that program's data (and the shared defaults).
        for (shared_data) |file| installDataFile(b, file);
    } else {
        // Several programs share data/, so the whole folder is installed.
        b.installDirectory(.{ .source_dir = b.path("data"), .install_dir = .prefix, .install_subdir = "share/dkde" });
    }

    if (selection.all) {
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
        // Which DKDE program opens what, until the person chooses otherwise.
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(b.path("data/dkde-mimeapps.list"), .prefix, "share/applications/dkde-mimeapps.list").step);
        // The Fluent icon theme goes where every toolkit looks for icon themes.
        b.installDirectory(.{ .source_dir = b.path("icons/Fluent"), .install_dir = .prefix, .install_subdir = "share/icons/Fluent" });
        // Microsoft's Fluent UI System Icons for dkde's own controls; it inherits Fluent.
        b.installDirectory(.{ .source_dir = b.path("icons/dkde-ui"), .install_dir = .prefix, .install_subdir = "share/icons/dkde-ui" });
    }
}

/// The programs -Dapp chose.
const Selection = struct {
    all: bool,
    names: []const []const u8,

    fn parse(b: *std.Build, option: ?[]const u8) Selection {
        const text = option orelse return .{ .all = true, .names = &.{} };
        var names: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeAny(u8, text, ", ");
        while (it.next()) |name| {
            if (std.mem.eql(u8, name, "all")) return .{ .all = true, .names = &.{} };
            if (!known(name)) {
                var list: std.ArrayList(u8) = .empty;
                inline for (programs) |p| list.print(b.allocator, " {s}", .{p[0]}) catch @panic("OOM");
                std.process.fatal("unknown -Dapp={s}; choose all or any of:{s}", .{ name, list.items });
            }
            names.append(b.allocator, name) catch @panic("OOM");
        }
        if (names.items.len == 0) return .{ .all = true, .names = &.{} };
        return .{ .all = false, .names = names.items };
    }

    fn known(name: []const u8) bool {
        inline for (programs) |p| if (std.mem.eql(u8, p[0], name)) return true;
        return false;
    }

    fn has(self: Selection, name: []const u8) bool {
        if (self.all) return true;
        for (self.names) |n| if (std.mem.eql(u8, n, name)) return true;
        return false;
    }

    fn any(self: Selection, names: []const []const u8) bool {
        for (names) |n| if (self.has(n)) return true;
        return false;
    }

    /// One program chosen: install only its own data.
    fn single(self: Selection) bool {
        return !self.all and self.names.len == 1;
    }
};

fn installDataFile(b: *std.Build, file: []const u8) void {
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(b.path(b.fmt("data/{s}", .{file})), .prefix, b.fmt("share/dkde/{s}", .{file})).step);
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
