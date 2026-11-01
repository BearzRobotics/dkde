//! dkde-console: the Linux text console, rebuilt (SPEC.md 5.11).
//!
//!     dkde-console --vt N          run on virtual terminal N (what init starts)
//!     dkde-console config ...      read and change /etc/dkde/console.conf

const std = @import("std");
const configtool = @import("configtool.zig");
const console = @import("console.zig");

pub const std_options: std.Options = .{ .log_level = .warn };

pub fn main(init: std.process.Init.Minimal) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var args: std.ArrayList([]const u8) = .empty;
    for (init.args.vector[1..]) |a| try args.append(arena, std.mem.span(a));

    if (args.items.len >= 1 and std.mem.eql(u8, args.items[0], "config")) {
        std.process.exit(configtool.run(arena, args.items[1..]));
    }
    if (args.items.len == 2 and std.mem.eql(u8, args.items[0], "--vt")) {
        const n = std.fmt.parseInt(u32, args.items[1], 10) catch 0;
        if (n >= 1 and n <= 63) std.process.exit(console.run(arena, .{ .vt = n }));
    }
    const usage =
        \\usage: dkde-console --vt N          run on virtual terminal N
        \\       dkde-console config ...      change the console settings
        \\
    ;
    _ = std.c.write(2, usage.ptr, usage.len);
    std.process.exit(2);
}

test {
    _ = @import("psf.zig");
    _ = @import("issue.zig");
    _ = @import("config.zig");
    _ = @import("configtool.zig");
    _ = @import("kbd.zig");
    _ = @import("drm.zig");
    _ = @import("evdev.zig");
    _ = @import("vt.zig");
    _ = @import("fallback.zig");
    _ = @import("render.zig");
    _ = @import("console.zig");
}
