//! Locations of dkde's data, config and state (SPEC.md 6.1, 6.2).

const std = @import("std");
const builtin = @import("builtin");
const glib = @import("glib2");

const is_windows = builtin.os.tag == .windows;

extern "kernel32" fn GetEnvironmentVariableW([*:0]const u16, ?[*]u16, u32) callconv(.winapi) u32;

/// The value of a Windows environment variable as UTF-8 (caller frees), or null.
fn winEnv(allocator: std.mem.Allocator, comptime name: []const u8) !?[]u8 {
    const wname = std.unicode.utf8ToUtf16LeStringLiteral(name);
    var buf: [1024]u16 = undefined;
    const n = GetEnvironmentVariableW(wname, &buf, buf.len);
    if (n == 0 or n >= buf.len) return null;
    return try std.unicode.utf16LeToUtf8Alloc(allocator, buf[0..n]);
}

/// `<base>\\dkde\\<file>` for the Windows user directories: `%APPDATA%` (roaming,
/// the usual home of a program's settings) or `%LOCALAPPDATA%`.
fn winJoin(allocator: std.mem.Allocator, comptime var_name: []const u8, file: []const u8) ![:0]u8 {
    const base = (try winEnv(allocator, var_name)) orelse return error.NoUserDirectory;
    defer allocator.free(base);
    return std.fmt.allocPrintSentinel(allocator, "{s}\\dkde\\{s}", .{ base, file }, 0);
}

/// Environment variable that points at a data directory to use instead of
/// `$XDG_DATA_DIRS/dkde`. Set by `zig build run-<component>` so a dev build
/// reads `data/` from the source tree.
pub const data_dir_env = "DKDE_DATA_DIR";

/// Returns `<base>/dkde` joined with `file`, owned by the caller (free with
/// `allocator`).
fn join(allocator: std.mem.Allocator, base: [*:0]const u8, file: []const u8) ![:0]u8 {
    return std.fmt.allocPrintSentinel(allocator, "{s}/dkde/{s}", .{ std.mem.span(base), file }, 0);
}

/// `$XDG_CONFIG_HOME/dkde/<file>`.
pub fn userConfigFile(allocator: std.mem.Allocator, file: []const u8) ![:0]u8 {
    if (comptime is_windows) return winJoin(allocator, "APPDATA", file);
    return join(allocator, glib.getUserConfigDir(), file);
}

/// `$XDG_STATE_HOME/dkde/<file>`.
pub fn userStateFile(allocator: std.mem.Allocator, file: []const u8) ![:0]u8 {
    if (comptime is_windows) return winJoin(allocator, "LOCALAPPDATA", file);
    return join(allocator, glib.getUserStateDir(), file);
}

/// The system copy of `file`: `$DKDE_DATA_DIR/<file>` if set, otherwise the
/// first `$XDG_DATA_DIRS/dkde/<file>` that exists. Null when none exists.
pub fn systemDataFile(allocator: std.mem.Allocator, file: []const u8) !?[:0]u8 {
    // No system data directories on Windows: the defaults are built into the program.
    if (comptime is_windows) return null;
    if (glib.getenv(data_dir_env)) |dir| {
        return try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ std.mem.span(dir), file }, 0);
    }
    // The binding types this NULL-terminated array without its terminator.
    const dirs: [*:null]const ?[*:0]const u8 = @ptrCast(glib.getSystemDataDirs());
    var i: usize = 0;
    while (dirs[i]) |dir| : (i += 1) {
        const candidate = try join(allocator, dir, file);
        if (glib.fileTest(candidate, .{ .exists = true }) != 0) return candidate;
        allocator.free(candidate);
    }
    return null;
}
