//! `dkde-console config ...` (SPEC.md 5.11, *Configuration tools*): the text
//! front end to /etc/dkde/console.conf. It follows 6.1's static-files rule,
//! so setting a value that is already in effect writes nothing.

const std = @import("std");
const termcore = @import("termcore");
const ini = termcore.ini;
const config = @import("config.zig");
const psf = @import("psf.zig");
const sys = @import("sys.zig");

const out_fd = 1;
const err_fd = 2;

pub fn etcPath() []const u8 {
    return sys.env("DKDE_CONSOLE_CONF") orelse "/etc/dkde/console.conf";
}

pub fn defaultsPath(buf: []u8) []const u8 {
    const dir = sys.env("DKDE_DATA_DIR") orelse "/usr/share/dkde";
    return std.fmt.bufPrint(buf, "{s}/console.conf", .{dir}) catch "";
}

/// Load a file as a document; a missing or unreadable file is an empty one.
pub fn loadDoc(allocator: std.mem.Allocator, path: []const u8) ini.Document {
    const text = sys.readFile(allocator, path, 1 << 20) catch return ini.Document.init(allocator);
    defer allocator.free(text);
    return ini.Document.parse(allocator, text) catch ini.Document.init(allocator);
}

const usage =
    \\usage: dkde-console config list [--vt N]
    \\       dkde-console config get [--vt N] KEY
    \\       dkde-console config set [--vt N] KEY VALUE
    \\       dkde-console config reset [--vt N] KEY
    \\       dkde-console config fonts
    \\
;

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) u8 {
    if (args.len == 0) {
        sys.print(err_fd, "{s}", .{usage});
        return 2;
    }
    const cmd = args[0];
    var rest = args[1..];
    var vt: u32 = 0;
    if (rest.len >= 2 and std.mem.eql(u8, rest[0], "--vt")) {
        vt = std.fmt.parseInt(u32, rest[1], 10) catch {
            sys.print(err_fd, "dkde-console: --vt needs a number\n", .{});
            return 2;
        };
        if (vt == 0 or vt > 63) {
            sys.print(err_fd, "dkde-console: --vt must be 1 to 63\n", .{});
            return 2;
        }
        rest = rest[2..];
    }

    var etc = loadDoc(allocator, etcPath());
    defer etc.deinit();
    var dbuf: [std.fs.max_path_bytes]u8 = undefined;
    var defs = loadDoc(allocator, defaultsPath(&dbuf));
    defer defs.deinit();
    const layers: config.Layers = .{ .etc = &etc, .defaults = &defs };

    if (std.mem.eql(u8, cmd, "list") and rest.len == 0) return list(layers, vt);
    if (std.mem.eql(u8, cmd, "get") and rest.len == 1) return get(layers, vt, rest[0]);
    if (std.mem.eql(u8, cmd, "set") and rest.len == 2) return set(allocator, &etc, vt, rest[0], rest[1]);
    if (std.mem.eql(u8, cmd, "reset") and rest.len == 1) return reset(allocator, &etc, vt, rest[0]);
    if (std.mem.eql(u8, cmd, "fonts") and rest.len == 0) return fonts(allocator);
    sys.print(err_fd, "{s}", .{usage});
    return 2;
}

fn sourceName(s: config.Source) []const u8 {
    return switch (s) {
        .default => "default",
        .system_defaults => "share/dkde/console.conf",
        .etc => "/etc",
        .vt => "[vt]",
    };
}

fn list(layers: config.Layers, vt: u32) u8 {
    for (&config.keys) |*k| {
        const v = config.lookup(layers, vt, k);
        sys.print(out_fd, "{s} = {s}    ({s})\n", .{ k.name, v.text, sourceName(v.source) });
    }
    return 0;
}

fn get(layers: config.Layers, vt: u32, name: []const u8) u8 {
    const k = config.find(name) orelse return unknownKey(name);
    sys.print(out_fd, "{s}\n", .{config.lookup(layers, vt, k).text});
    return 0;
}

fn unknownKey(name: []const u8) u8 {
    sys.print(err_fd, "dkde-console: unknown key '{s}'. Keys:", .{name});
    for (&config.keys) |k| sys.print(err_fd, " {s}", .{k.name});
    sys.print(err_fd, "\n", .{});
    return 1;
}

/// Why a value is not acceptable, beyond the type check: files must exist and
/// load, as SPEC.md 5.11 requires.
fn deepCheck(allocator: std.mem.Allocator, key: *const config.Key, value: []const u8) ?[]const u8 {
    if (config.check(key, value)) |why| return why;
    if (std.mem.eql(u8, key.name, "font")) {
        if (value.len > 0 and !fontLoads(allocator, value)) return "font file not found or not a PSF font";
    } else if (std.mem.eql(u8, key.name, "fallback-fonts")) {
        var it = std.mem.tokenizeAny(u8, value, ", ");
        while (it.next()) |f| if (!fontLoads(allocator, f)) return "a listed font file is not found or not a PSF font";
    }
    return null;
}

fn fontLoads(allocator: std.mem.Allocator, name: []const u8) bool {
    for (psf.builtin_data) |b| if (std.mem.eql(u8, b.name, name)) return true;
    const data = sys.readFile(allocator, name, 16 << 20) catch return false;
    defer allocator.free(data);
    var f = psf.Font.parse(allocator, data) catch return false;
    f.deinit(allocator);
    return true;
}

fn groupFor(buf: []u8, vt: u32) []const u8 {
    if (vt == 0) return config.group;
    return std.fmt.bufPrint(buf, "vt:{d}", .{vt}) catch config.group;
}

fn save(allocator: std.mem.Allocator, doc: *ini.Document) u8 {
    const text = doc.toOwnedString(allocator) catch {
        sys.print(err_fd, "dkde-console: out of memory\n", .{});
        return 1;
    };
    defer allocator.free(text);
    const path = etcPath();
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| sys.makeDir(path[0..i]);
    sys.writeFileAtomic(path, text) catch |e| {
        if (e == error.AccessDenied or sys.geteuid() != 0) {
            sys.print(err_fd, "dkde-console: changing the console settings needs root (cannot write {s}). Try: sudo dkde-console config ...\n", .{path});
        } else sys.print(err_fd, "dkde-console: cannot write {s}\n", .{path});
        return 1;
    };
    return 0;
}

fn set(allocator: std.mem.Allocator, etc: *ini.Document, vt: u32, name: []const u8, value: []const u8) u8 {
    const k = config.find(name) orelse return unknownKey(name);
    if (deepCheck(allocator, k, value)) |why| {
        sys.print(err_fd, "dkde-console: {s}: '{s}' refused: {s}\n", .{ name, value, why });
        return 1;
    }
    var gbuf: [24]u8 = undefined;
    const changed = etc.set(groupFor(&gbuf, vt), name, value) catch {
        sys.print(err_fd, "dkde-console: out of memory\n", .{});
        return 1;
    };
    if (!changed) return 0; // already in effect: write nothing
    return save(allocator, etc);
}

fn reset(allocator: std.mem.Allocator, etc: *ini.Document, vt: u32, name: []const u8) u8 {
    _ = config.find(name) orelse return unknownKey(name);
    var gbuf: [24]u8 = undefined;
    if (!etc.remove(groupFor(&gbuf, vt), name)) return 0;
    return save(allocator, etc);
}

const font_dirs = [_][:0]const u8{ "/usr/share/consolefonts", "/usr/share/kbd/consolefonts", "/lib/kbd/consolefonts", "/usr/lib/kbd/consolefonts" };

fn fonts(allocator: std.mem.Allocator) u8 {
    sys.print(out_fd, "Built in:\n", .{});
    for (psf.builtin_data) |b| {
        var f = psf.Font.parse(allocator, b.data) catch continue;
        defer f.deinit(allocator);
        sys.print(out_fd, "  {s}  ({d}x{d})\n", .{ b.name, f.width, f.height });
    }
    for (font_dirs) |dir| {
        const d = std.c.opendir(dir.ptr) orelse continue;
        defer _ = std.c.closedir(d);
        var header = false;
        while (std.c.readdir(d)) |ent| {
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.name)), 0);
            if (!std.mem.endsWith(u8, name, ".psf") and !std.mem.endsWith(u8, name, ".psfu")) continue;
            if (!header) {
                sys.print(out_fd, "{s}:\n", .{dir});
                header = true;
            }
            sys.print(out_fd, "  {s}/{s}\n", .{ dir, name });
        }
    }
    sys.print(out_fd, "Fonts compressed with gzip (.psf.gz) must be unpacked first.\n", .{});
    return 0;
}
