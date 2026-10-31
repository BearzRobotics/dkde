//! Runs only when KSY_FORMATS_DIR points at a clone of kaitai_struct_formats:
//! checks that every .ksy file there loads through the YAML parser.

const std = @import("std");
const prep = @import("prep.zig");
const Yaml = @import("yaml").Yaml;

test "every format file parses as YAML" {
    const dir_env = std.c.getenv("KSY_FORMATS_DIR") orelse return error.SkipZigTest;
    const root = std.mem.span(dir_env);
    const a = std.testing.allocator;
    var count: usize = 0;
    var failed: usize = 0;
    var io_threaded: std.Io.Threaded = .init_single_threaded;
    const io = io_threaded.io();
    var dir = try std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".ksy")) continue;
        const source = try dir.readFileAlloc(io, entry.path, a, .limited(1 << 22));
        defer a.free(source);
        const prepared = try prep.prepare(a, source);
        defer a.free(prepared);
        var y: Yaml = .{ .source = prepared };
        defer y.deinit(a);
        count += 1;
        y.load(a) catch |err| {
            var msg: []const u8 = "";
            if (err == error.ParseFailure and y.parse_errors.errorMessageCount() > 0) msg = y.parse_errors.nullTerminatedString(y.parse_errors.getErrorMessage(y.parse_errors.getMessages()[0]).msg);
            failed += 1;
            std.debug.print("YAML failed: {s}: {s} {s}\n", .{ entry.path, @errorName(err), msg });
        };
    }
    std.debug.print("{d} files, {d} failed\n", .{ count, failed });
    try std.testing.expectEqual(@as(usize, 0), failed);
}
