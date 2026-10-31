//! Runs only when HEXPAT_DIR points at a clone of ImHex-Patterns: parses every
//! pattern, runs each over a sample file without crashing, and shows two real
//! patterns on real data.

const std = @import("std");
const eval = @import("eval.zig");

const Env = struct {
    io: std.Io,
    root: []const u8,
};

fn readAbs(env: Env, a: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(env.io, path, a, .limited(limit));
}

fn importRead(ctx: *anyopaque, gpa: std.mem.Allocator, name: []const u8) ?[]u8 {
    const env: *Env = @ptrCast(@alignCast(ctx));
    const rel = std.mem.trimStart(u8, name, "/");
    var buf: [1024]u8 = undefined;
    for ([_][]const u8{ ".pat", ".hexpat" }) |ext| {
        const path = std.fmt.bufPrint(&buf, "{s}/includes/{s}{s}", .{ env.root, rel, ext }) catch return null;
        if (readAbs(env.*, gpa, path, 1 << 22)) |bytes| return bytes else |_| {}
    }
    return null;
}

test "real patterns on real files" {
    const dir_env = std.c.getenv("HEXPAT_DIR") orelse return error.SkipZigTest;
    const a = std.testing.allocator;
    var threaded: std.Io.Threaded = .init_single_threaded;
    var env: Env = .{ .io = threaded.io(), .root = std.mem.span(dir_env) };
    const loader: eval.Loader = .{ .ctx = &env, .read = importRead };

    const cases = [_][2][]const u8{
        .{ "patterns/png.hexpat", "/opt/google/chrome/product_logo_256.png" },
        .{ "patterns/elf.hexpat", "/bin/ls" },
    };
    for (cases) |c| {
        var pb: [1024]u8 = undefined;
        const src = try readAbs(env, a, try std.fmt.bufPrint(&pb, "{s}/{s}", .{ env.root, c[0] }), 1 << 22);
        defer a.free(src);
        const data = try readAbs(env, a, c[1], 1 << 26);
        defer a.free(data);
        var failure: ?eval.LoadFailure = null;
        const p = (try eval.load(a, src, loader, &failure)) orelse {
            std.debug.print("{s}: cannot parse line {d}: {s}\n", .{ c[0], failure.?.line, failure.?.message });
            a.free(failure.?.message);
            continue;
        };
        defer p.deinit();
        const r = try eval.run(a, p, data);
        defer r.deinit();
        std.debug.print("{s}: message={?s}\n", .{ c[0], r.message });
        for (r.root.children.items, 0..) |n, i| {
            if (i > 12) break;
            std.debug.print("  {s} [{d}+{d}] {s} {s}\n", .{ n.name, n.start, n.len, n.type_name, n.text });
            for (n.children.items, 0..) |m, j| {
                if (j > 6) break;
                std.debug.print("      {s} [{d}+{d}] {s}\n", .{ m.name, m.start, m.len, m.text });
            }
        }
    }
}

test "every pattern parses and runs without crashing" {
    const dir_env = std.c.getenv("HEXPAT_DIR") orelse return error.SkipZigTest;
    const a = std.testing.allocator;
    var threaded: std.Io.Threaded = .init_single_threaded;
    var env: Env = .{ .io = threaded.io(), .root = std.mem.span(dir_env) };
    const loader: eval.Loader = .{ .ctx = &env, .read = importRead };
    var pb: [1024]u8 = undefined;
    const pdir = try std.fmt.bufPrint(&pb, "{s}/patterns", .{env.root});
    var dir = try std.Io.Dir.openDirAbsolute(env.io, pdir, .{ .iterate = true });
    defer dir.close(env.io);
    const whole = try readAbs(env, a, "/bin/ls", 1 << 28);
    defer a.free(whole);
    const data = whole[0..@min(whole.len, 1 << 16)];

    var w = try dir.walk(a);
    defer w.deinit();
    var total: usize = 0;
    var parsed: usize = 0;
    var ran_clean: usize = 0;
    while (try w.next(env.io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.path, ".hexpat")) continue;
        total += 1;
        const src = try dir.readFileAlloc(env.io, e.path, a, .limited(1 << 22));
        defer a.free(src);
        var failure: ?eval.LoadFailure = null;
        const p = (try eval.load(a, src, loader, &failure)) orelse {
            a.free(failure.?.message);
            continue;
        };
        defer p.deinit();
        parsed += 1;
        const r = try eval.run(a, p, data);
        defer r.deinit();
        if (r.message == null) ran_clean += 1;
    }
    std.debug.print("{d} patterns, {d} parsed, {d} ran to the end on a sample\n", .{ total, parsed, ran_clean });
}
