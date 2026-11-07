//! The command-line contract every DKDE program follows (DKDE-024):
//! `--help` and `--version` print to stdout and exit 0; an unknown option is
//! reported on stderr and exits 2; `--` ends option processing. Operands
//! (files, URIs) are never interpreted as options or shell text.
//!
//! This is its own module (no GTK) so that programs that do not link the UI
//! toolkit, such as the Polkit agent, can use it too.

const std = @import("std");
const build_options = @import("build_options");

pub const Info = struct {
    /// Program name as installed, e.g. "dkde-calc".
    name: []const u8,
    /// One line: what the program is.
    summary: []const u8,
    /// Text after the program name in the usage line, e.g. "[FILE...]". Empty if none.
    usage: []const u8 = "",
    /// Extra option lines for the help text, already formatted; may be empty.
    options: []const u8 = "",
    /// Flags the program parses itself (no value). Skipped here, not validated.
    accepted: []const []const u8 = &.{},
    /// Options that take the next argument as their value (`--page network`,
    /// `-t -1`), also accepted as `--opt=value`. The value is never checked here.
    value_options: []const []const u8 = &.{},
    /// Options after which the rest of the line belongs to the program
    /// (`dkde-term -e COMMAND ARGS...`); nothing further is examined.
    stop_at: []const []const u8 = &.{},
};

pub const Outcome = union(enum) {
    run,
    help,
    version,
    /// An option nobody accepts; the slice borrows from the argument.
    unknown: []const u8,
};

/// Option prefixes GLib and GTK strip before the program sees them
/// (`GApplication.run` handles them), so they are not unknown.
const toolkit_prefixes = [_][]const u8{ "--gapplication-", "--gtk-", "--gdk-", "--g-fatal-" };

/// Decides what the arguments ask for. `args` includes argv[0], which is skipped.
pub fn classify(args: []const [*:0]const u8, info: Info) Outcome {
    var i: usize = @min(1, args.len);
    while (i < args.len) : (i += 1) {
        const arg = std.mem.span(args[i]);
        if (std.mem.eql(u8, arg, "--")) return .run;
        if (arg.len < 2 or arg[0] != '-') continue; // an operand (or a lone "-")
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return .help;
        if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) return .version;
        if (isAccepted(arg, info.stop_at)) return .run;
        if (isAccepted(arg, info.accepted)) continue;
        if (isAccepted(arg, info.value_options)) {
            if (std.mem.indexOfScalar(u8, arg, '=') == null) i += 1; // skip the separate value
            continue;
        }
        if (startsWithAny(arg, &toolkit_prefixes)) continue;
        return .{ .unknown = arg };
    }
    return .run;
}

fn startsWithAny(s: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |p| if (std.mem.startsWith(u8, s, p)) return true;
    return false;
}

/// `--name` or `--name=value` for any `name` in `accepted` (which lists the full option).
fn isAccepted(arg: []const u8, accepted: []const []const u8) bool {
    for (accepted) |a| {
        if (std.mem.eql(u8, arg, a)) return true;
        if (std.mem.startsWith(u8, arg, a) and arg.len > a.len and arg[a.len] == '=') return true;
    }
    return false;
}

pub fn versionLine(buf: []u8, info: Info) []const u8 {
    return std.fmt.bufPrint(buf, "{s} {s}\n", .{ info.name, build_options.version }) catch buf[0..0];
}

fn helpText(w: *std.Io.Writer, info: Info) std.Io.Writer.Error!void {
    try w.print("{s} - {s}\n\nUsage: {s}{s}{s}\n", .{ info.name, info.summary, info.name, if (info.usage.len != 0) " " else "", info.usage });
    if (info.options.len != 0) try w.print("\n{s}\n", .{info.options});
    try w.print("\n  -h, --help     show this help and exit\n  -V, --version  show the version and exit\n", .{});
}

fn writeAll(fd: c_int, bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = std.c.write(fd, rest.ptr, rest.len);
        if (n <= 0) return;
        rest = rest[@intCast(n)..];
    }
}

/// Call first in `main`, before any toolkit or configuration is touched.
/// Returns only when the program should go on to run.
pub fn handle(args: std.process.Args, info: Info) void {
    const argv = args.vector;
    switch (classify(argv, info)) {
        .run => return,
        .help => {
            var buf: [2048]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            helpText(&w, info) catch {};
            writeAll(1, w.buffered());
            std.process.exit(0);
        },
        .version => {
            var buf: [128]u8 = undefined;
            writeAll(1, versionLine(&buf, info));
            std.process.exit(0);
        },
        .unknown => |arg| {
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "{s}: unknown option '{s}'\nTry '{s} --help'.\n", .{ info.name, arg, info.name }) catch "unknown option\n";
            writeAll(2, msg);
            std.process.exit(2);
        },
    }
}

test "classify: operands and no arguments run" {
    const info: Info = .{ .name = "x", .summary = "" };
    try std.testing.expectEqual(Outcome.run, classify(&.{"x"}, info));
    try std.testing.expectEqual(Outcome.run, classify(&.{ "x", "file.txt", "-", "dir/" }, info));
    try std.testing.expectEqual(Outcome.run, classify(&.{}, info));
}

test "classify: help, version and unknown options" {
    const info: Info = .{ .name = "x", .summary = "", .accepted = &.{"--check"} };
    try std.testing.expectEqual(Outcome.help, classify(&.{ "x", "--help" }, info));
    try std.testing.expectEqual(Outcome.help, classify(&.{ "x", "a", "-h" }, info));
    try std.testing.expectEqual(Outcome.version, classify(&.{ "x", "--version" }, info));
    try std.testing.expectEqual(Outcome.version, classify(&.{ "x", "-V" }, info));
    try std.testing.expectEqualStrings("--bogus", classify(&.{ "x", "--bogus" }, info).unknown);
    try std.testing.expectEqualStrings("-z", classify(&.{ "x", "-z" }, info).unknown);
}

test "classify: accepted options, toolkit options and the -- terminator" {
    const info: Info = .{ .name = "x", .summary = "", .accepted = &.{ "--check", "--out" } };
    try std.testing.expectEqual(Outcome.run, classify(&.{ "x", "--check" }, info));
    try std.testing.expectEqual(Outcome.run, classify(&.{ "x", "--out=/tmp/a" }, info));
    try std.testing.expectEqual(Outcome.run, classify(&.{ "x", "--gapplication-service" }, info));
    // Everything after "--" is an operand, even if it looks like an option.
    try std.testing.expectEqual(Outcome.run, classify(&.{ "x", "--", "--help", "--weird" }, info));
    try std.testing.expectEqualStrings("--checkx", classify(&.{ "x", "--checkx" }, info).unknown);
}

test "classify: value options and stop_at" {
    const info: Info = .{ .name = "x", .summary = "", .value_options = &.{ "-t", "--page" }, .stop_at = &.{"-e"} };
    try std.testing.expectEqual(Outcome.run, classify(&.{ "x", "-t", "-1" }, info));
    try std.testing.expectEqual(Outcome.run, classify(&.{ "x", "--page=net" }, info));
    try std.testing.expectEqual(Outcome.run, classify(&.{ "x", "-e", "ls", "-la", "--help" }, info));
    // The value is skipped, but a bad option after it is still caught.
    try std.testing.expectEqualStrings("--bad", classify(&.{ "x", "--page", "net", "--bad" }, info).unknown);
}

test "help text names the program and the standard options" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try helpText(&w, .{ .name = "dkde-calc", .summary = "Calculator", .usage = "[EXPRESSION]" });
    const text = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "Usage: dkde-calc [EXPRESSION]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "--version") != null);
}
