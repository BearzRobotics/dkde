//! Locations of dkde's data, config and state (SPEC.md 6.1, 6.2).

const std = @import("std");
const glib = @import("glib2");

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
    return join(allocator, glib.getUserConfigDir(), file);
}

/// `$XDG_STATE_HOME/dkde/<file>`.
pub fn userStateFile(allocator: std.mem.Allocator, file: []const u8) ![:0]u8 {
    return join(allocator, glib.getUserStateDir(), file);
}

/// The system copy of `file`: `$DKDE_DATA_DIR/<file>` if set, otherwise the
/// first `$XDG_DATA_DIRS/dkde/<file>` that exists. Null when none exists.
pub fn systemDataFile(allocator: std.mem.Allocator, file: []const u8) !?[:0]u8 {
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
