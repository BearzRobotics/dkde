// SPDX-License-Identifier: GPL-2.0-or-later
//! Pending operations (SPEC.md 5.6), as in GParted: changes are queued, shown
//! on a predicted layout, and run together when applied. Each operation is
//! turned into commands against the layout as it will be at that point, so
//! numbers stay right when several are queued. No GTK here, so all of it is
//! tested.

const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("model.zig");
const fs = @import("fs.zig");

pub const Op = union(enum) {
    new_table: struct { kind: []const u8 },
    create: struct { start_mib: u64, end_mib: u64 },
    delete: struct { number: u32 },
    format: struct { number: u32, fs: *const fs.Fs, label: []const u8 },
    resize: struct { number: u32, new_end_mib: u64 },
    label: struct { number: u32, label: []const u8 },
    flag: struct { number: u32, flag: []const u8, on: bool },
    wipe: struct { number: u32 },
};

fn partIndex(d: model.Disk, number: u32) ?usize {
    for (d.parts, 0..) |p, i| if (p.number == number) return i;
    return null;
}

/// The id lsblk would report for a filesystem made as `f`.
fn reportedId(f: *const fs.Fs) []const u8 {
    return if (std.mem.eql(u8, f.id, "vfat16")) "vfat" else f.id;
}

/// A line for the pending list, such as "Delete partition 2".
pub fn describe(arena: Allocator, d: model.Disk, op: Op) Allocator.Error![]const u8 {
    const where = if (d.image) d.name else d.path;
    return switch (op) {
        .new_table => |o| std.fmt.allocPrint(arena, "Create a {s} partition table on {s}", .{ if (std.mem.eql(u8, o.kind, "msdos")) "MBR" else "GPT", where }),
        .create => |o| std.fmt.allocPrint(arena, "Create a {d} MiB partition on {s}", .{ o.end_mib - o.start_mib, where }),
        .delete => |o| std.fmt.allocPrint(arena, "Delete partition {d} of {s}", .{ o.number, where }),
        .format => |o| std.fmt.allocPrint(arena, "Format partition {d} of {s} as {s}{s}{s}", .{ o.number, where, o.fs.name, if (o.label.len > 0) " labelled " else "", o.label }),
        .resize => |o| std.fmt.allocPrint(arena, "Resize partition {d} of {s} to end at {d} MiB", .{ o.number, where, o.new_end_mib }),
        .label => |o| std.fmt.allocPrint(arena, "Label partition {d} of {s} \"{s}\"", .{ o.number, where, o.label }),
        .flag => |o| std.fmt.allocPrint(arena, "{s} flag {s} on partition {d} of {s}", .{ if (o.on) "Set" else "Clear", o.flag, o.number, where }),
        .wipe => |o| std.fmt.allocPrint(arena, "Erase signatures on partition {d} of {s}", .{ o.number, where }),
    };
}

/// Where, in MiB from the start of the disk, a partition beginning at
/// `start_bytes` ends when made `size_mib` long. A partition may begin between
/// two MiB marks: shrinking rounds the end up, so what was asked for still
/// fits; growing rounds down, so it stays inside the free space.
pub fn resizeEnd(start_bytes: u64, size_mib: u64, shrink: bool) u64 {
    const end = start_bytes + size_mib * model.mib;
    return if (shrink) std.math.divCeil(u64, end, model.mib) catch unreachable else end / model.mib;
}

/// The disk as it will be after `op`.
pub fn simulate(arena: Allocator, d: model.Disk, op: Op) Allocator.Error!model.Disk {
    var out = d;
    var parts: std.ArrayList(model.Part) = .empty;
    try parts.appendSlice(arena, d.parts);
    switch (op) {
        .new_table => |o| {
            parts.clearRetainingCapacity();
            out.table = try arena.dupe(u8, o.kind);
            out.fstype = "";
        },
        .create => |o| {
            const n = fs.nextNumber(d);
            const path = if (d.image) try std.fmt.allocPrint(arena, "{s}#{d}", .{ d.path, n }) else try fs.partitionPath(arena, d.path, n);
            try parts.append(arena, .{
                .path = path,
                .number = n,
                .start = o.start_mib * model.mib / d.sector,
                .size = (o.end_mib - o.start_mib) * model.mib,
                .fstype = "",
                .label = "",
                .mounts = &.{},
            });
            std.mem.sort(model.Part, parts.items, {}, struct {
                fn less(_: void, a: model.Part, b: model.Part) bool {
                    return a.start < b.start;
                }
            }.less);
        },
        .delete => |o| if (partIndex(d, o.number)) |i| {
            _ = parts.orderedRemove(i);
        },
        .format => |o| if (partIndex(d, o.number)) |i| {
            parts.items[i].fstype = reportedId(o.fs);
            parts.items[i].label = try arena.dupe(u8, o.label);
            parts.items[i].used = null;
            parts.items[i].avail = null;
        },
        .resize => |o| if (partIndex(d, o.number)) |i| {
            parts.items[i].size = o.new_end_mib * model.mib -| parts.items[i].start * d.sector;
            parts.items[i].used = null;
            parts.items[i].avail = null;
        },
        .label => |o| if (partIndex(d, o.number)) |i| {
            parts.items[i].label = try arena.dupe(u8, o.label);
        },
        .flag => |o| if (partIndex(d, o.number)) |i| {
            parts.items[i].flags = try toggleFlag(arena, parts.items[i].flags, o.flag, o.on);
        },
        .wipe => |o| if (partIndex(d, o.number)) |i| {
            parts.items[i].fstype = "";
            parts.items[i].label = "";
        },
    }
    out.parts = parts.items;
    return out;
}

fn toggleFlag(arena: Allocator, current: []const u8, flag: []const u8, on: bool) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var seen = false;
    var it = std.mem.tokenizeAny(u8, current, ", ");
    while (it.next()) |f| {
        if (std.mem.eql(u8, f, flag)) {
            seen = true;
            if (!on) continue;
        }
        if (out.items.len > 0) try out.appendSlice(arena, ", ");
        try out.appendSlice(arena, f);
    }
    if (on and !seen) {
        if (out.items.len > 0) try out.appendSlice(arena, ", ");
        try out.appendSlice(arena, flag);
    }
    return out.items;
}

pub const Cmd = struct {
    argv: []const []const u8,
    /// Needs administrator rights.
    root: bool,
};

/// The commands for `op`, against the layout `d` as it is just before it runs.
pub fn commands(arena: Allocator, d: model.Disk, op: Op) Allocator.Error!?Cmd {
    const image: ?[]const u8 = if (d.image) d.path else null;
    switch (op) {
        .new_table => |o| return .{ .argv = try fs.newTable(arena, d.path, o.kind), .root = !model.plainImage(d) },
        .create => |o| return .{ .argv = try fs.newPartition(arena, d.path, o.start_mib, o.end_mib), .root = !model.plainImage(d) },
        .delete => |o| return .{ .argv = try fs.deletePartition(arena, d.path, o.number), .root = !model.plainImage(d) },
        .format => |o| {
            const dev = if (d.image) "" else try fs.partitionPath(arena, d.path, o.number);
            return .{ .argv = try fs.formatScript(arena, image, o.number, dev, o.fs, o.label), .root = true };
        },
        .resize => |o| {
            const i = partIndex(d, o.number) orelse return null;
            const p = d.parts[i];
            const new_size = std.math.sub(u64, o.new_end_mib * model.mib, p.start * d.sector) catch return null;
            const shrink = new_size < p.size;
            const dev = if (d.image) "" else try fs.partitionPath(arena, d.path, o.number);
            const argv = (try fs.resizeScript(arena, image, d.path, o.number, dev, p.fstype, new_size / model.mib, o.new_end_mib, shrink)) orelse return null;
            return .{ .argv = argv, .root = !model.plainImage(d) or p.fstype.len > 0 };
        },
        .label => |o| {
            const i = partIndex(d, o.number) orelse return null;
            const f = fs.byId(d.parts[i].fstype) orelse return null;
            const dev = if (d.image) "" else try fs.partitionPath(arena, d.path, o.number);
            const argv = (try fs.relabelScript(arena, image, o.number, dev, f, o.label)) orelse return null;
            return .{ .argv = argv, .root = true };
        },
        .flag => |o| return .{ .argv = try fs.setFlag(arena, d.path, o.number, o.flag, o.on), .root = !model.plainImage(d) },
        .wipe => |o| {
            const dev = if (d.image) "" else try fs.partitionPath(arena, d.path, o.number);
            return .{ .argv = try fs.wipeScript(arena, image, o.number, dev), .root = true };
        },
    }
}

/// Words quoted for `sh`.
fn shellLine(arena: Allocator, argv: []const []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (argv, 0..) |w, i| {
        if (i > 0) try out.append(arena, ' ');
        try out.appendSlice(arena, try fs.quote(arena, w));
    }
    return out.items;
}

/// One script that runs `cmds` in order and stops at the first failure, so a
/// single password covers all of them.
pub fn master(arena: Allocator, cmds: []const Cmd) Allocator.Error![]const []const u8 {
    var s: std.ArrayList(u8) = .empty;
    try s.appendSlice(arena, "set -e");
    for (cmds) |c| {
        try s.appendSlice(arena, "; ");
        try s.appendSlice(arena, try shellLine(arena, c.argv));
    }
    return arena.dupe([]const u8, &.{ "sh", "-c", s.items });
}

/// The check that runs, as administrator, right before the first change: it
/// stops everything when the disk is no longer the one that was read (another
/// drive can take its name while the password is being typed) or has come into
/// use. `d` is the disk as it was read, before any queued operation.
pub fn guard(arena: Allocator, d: model.Disk) Allocator.Error!Cmd {
    const q = try fs.quote(arena, d.path);
    const script = if (d.image)
        try std.fmt.allocPrint(arena, "if command -v losetup >/dev/null && [ -n \"$(losetup -j {s})\" ]; then echo {s} >&2; exit 1; fi", .{ q, try fs.quote(arena, try std.fmt.allocPrint(arena, "{s} is attached to a loop device. Detach it first. Nothing was changed.", .{d.path})) })
    else
        try std.fmt.allocPrint(arena,
            \\if [ "$(lsblk -bdno SIZE {s} | tr -d ' ')" != {d} ] || [ "$(lsblk -dno PTUUID {s} | tr -d ' ')" != {s} ] || [ "$(lsblk -dno SERIAL {s} | sed 's/^ *//;s/ *$//')" != {s} ]; then echo {s} >&2; exit 1; fi
            \\if [ -n "$(lsblk -nro MOUNTPOINT {s} | tr -d '[:space:]')" ] || lsblk -nro TYPE {s} | grep -qvxE 'disk|part'; then echo {s} >&2; exit 1; fi
        , .{
            q,                                                                                                                        d.size,
            q,                                                                                                                        try fs.quote(arena, d.ptuuid),
            q,                                                                                                                        try fs.quote(arena, d.serial),
            try fs.quote(arena, try std.fmt.allocPrint(arena, "{s} is not the disk that was read. Nothing was changed.", .{d.path})), q,
            q,                                                                                                                        try fs.quote(arena, try std.fmt.allocPrint(arena, "{s} is now in use. Nothing was changed.", .{d.path})),
        });
    return .{ .argv = try arena.dupe([]const u8, &.{ "sh", "-c", script }), .root = true };
}

/// What would run, for the preview: one command per line.
pub fn preview(arena: Allocator, cmds: []const Cmd) Allocator.Error![]const u8 {
    var s: std.ArrayList(u8) = .empty;
    for (cmds) |c| {
        try s.print(arena, "{s}{s}\n", .{ if (c.root) "# as administrator\n" else "", try shellLine(arena, c.argv) });
    }
    return s.items;
}

// -- tests ---------------------------------------------------------------------------------

fn sampleDisk() model.Disk {
    return .{ .path = "/dev/sdb", .name = "sdb", .model = "", .size = 1 << 30, .sector = 512, .table = "gpt", .removable = false, .readonly = false, .parts = &.{
        .{ .path = "/dev/sdb1", .number = 1, .start = 2048, .size = 100 << 20, .fstype = "ext4", .label = "a", .mounts = &.{} },
    } };
}

test "queued operations are simulated in order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = sampleDisk();
    d = try simulate(a, d, .{ .create = .{ .start_mib = 200, .end_mib = 300 } });
    d = try simulate(a, d, .{ .create = .{ .start_mib = 300, .end_mib = 400 } });
    try std.testing.expectEqual(@as(usize, 3), d.parts.len);
    try std.testing.expectEqual(@as(u32, 2), d.parts[1].number);
    try std.testing.expectEqual(@as(u32, 3), d.parts[2].number);
    d = try simulate(a, d, .{ .format = .{ .number = 2, .fs = fs.byId("btrfs").?, .label = "x" } });
    try std.testing.expectEqualStrings("btrfs", d.parts[1].fstype);
    d = try simulate(a, d, .{ .delete = .{ .number = 1 } });
    try std.testing.expectEqual(@as(usize, 2), d.parts.len);
    d = try simulate(a, d, .{ .flag = .{ .number = 2, .flag = "esp", .on = true } });
    d = try simulate(a, d, .{ .flag = .{ .number = 2, .flag = "boot", .on = true } });
    try std.testing.expectEqualStrings("esp, boot", d.parts[0].flags);
    d = try simulate(a, d, .{ .flag = .{ .number = 2, .flag = "esp", .on = false } });
    try std.testing.expectEqualStrings("boot", d.parts[0].flags);
    d = try simulate(a, d, .{ .new_table = .{ .kind = "msdos" } });
    try std.testing.expectEqual(@as(usize, 0), d.parts.len);
    try std.testing.expectEqualStrings("msdos", d.table);
}

test "commands use the layout at that point" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d0 = sampleDisk();
    const make: Op = .{ .create = .{ .start_mib = 200, .end_mib = 300 } };
    const d1 = try simulate(a, d0, make);
    const fmt: Op = .{ .format = .{ .number = 2, .fs = fs.byId("ext4").?, .label = "new" } };
    const c = (try commands(a, d1, fmt)).?;
    try std.testing.expect(c.root);
    try std.testing.expect(std.mem.indexOf(u8, c.argv[2], "/dev/sdb2") != null);
    // On an image, table and partition changes need no root.
    var img = sampleDisk();
    img.image = true;
    img.path = "/tmp/dkde-ops-test.img";
    _ = std.c.fclose(std.c.fopen("/tmp/dkde-ops-test.img", "w").?);
    defer _ = std.c.unlink("/tmp/dkde-ops-test.img");
    try std.testing.expect(!(try commands(a, img, make)).?.root);
    // One the user cannot write (here: missing) goes through administrator rights.
    img.path = "/nonexistent/a.img";
    try std.testing.expect((try commands(a, img, make)).?.root);
    img.path = "/tmp/dkde-ops-test.img";
    try std.testing.expect((try commands(a, img, fmt)).?.root);
    // Shrinking works out the direction from the partition as it is.
    const shrink = (try commands(a, d0, .{ .resize = .{ .number = 1, .new_end_mib = 50 } })).?;
    try std.testing.expect(std.mem.indexOf(u8, shrink.argv[2], "pretend-input-tty") != null);
    try std.testing.expect((try commands(a, d0, .{ .label = .{ .number = 9, .label = "x" } })) == null);
}

test "a partition off the MiB marks never gets a filesystem bigger than itself" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The classic first MBR partition, at sector 63.
    var d = sampleDisk();
    d.parts = &.{.{ .path = "/dev/sdb1", .number = 1, .start = 63, .size = 2000 * model.mib, .fstype = "ext4", .label = "", .mounts = &.{} }};
    const end = resizeEnd(63 * 512, 1000, true);
    try std.testing.expectEqual(@as(u64, 1001), end);
    const c = (try commands(a, d, .{ .resize = .{ .number = 1, .new_end_mib = end } })).?;
    try std.testing.expect(std.mem.indexOf(u8, c.argv[2], "resize2fs \"$DEV\" 1000M") != null);
    try std.testing.expect(std.mem.indexOf(u8, c.argv[2], "resizepart 1 1001MiB") != null);
    // Even for an end given without rounding up, the filesystem is the smaller.
    const tight = (try commands(a, d, .{ .resize = .{ .number = 1, .new_end_mib = 1000 } })).?;
    try std.testing.expect(std.mem.indexOf(u8, tight.argv[2], "resize2fs \"$DEV\" 999M") != null);
    const after = try simulate(a, d, .{ .resize = .{ .number = 1, .new_end_mib = end } });
    try std.testing.expect(after.parts[0].size >= 1000 * model.mib);
    // Growing stays within the space measured in whole MiB.
    try std.testing.expectEqual(@as(u64, 3000), resizeEnd(63 * 512, 3000, false));
    try std.testing.expectEqual(@as(u64, 3001), resizeEnd(model.mib, 3000, false));
}

test "the master script runs everything once and stops on failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = sampleDisk();
    const c1 = (try commands(a, d, .{ .delete = .{ .number = 1 } })).?;
    const c2 = (try commands(a, d, .{ .new_table = .{ .kind = "gpt" } })).?;
    const m = try master(a, &.{ c1, c2 });
    try std.testing.expect(std.mem.startsWith(u8, m[2], "set -e; "));
    try std.testing.expect(std.mem.indexOf(u8, m[2], "'rm'") != null and std.mem.indexOf(u8, m[2], "'mklabel'") != null);
    const text = try preview(a, &.{c1});
    try std.testing.expect(std.mem.indexOf(u8, text, "administrator") != null);
    const desc = try describe(a, d, .{ .delete = .{ .number = 1 } });
    try std.testing.expectEqualStrings("Delete partition 1 of /dev/sdb", desc);
}

/// Runs `cmd` with stand-ins for lsblk and losetup that report `answers`.
fn runGuard(a: Allocator, cmd: Cmd, size: []const u8, ptuuid: []const u8, serial: []const u8, mounts: []const u8, types: []const u8) !u32 {
    const script = try std.fmt.allocPrint(a,
        \\exec 2>/dev/null
        \\lsblk() {{ for w; do case $w in SIZE|PTUUID|SERIAL|MOUNTPOINT|TYPE) col=$w;; esac; done
        \\case $col in SIZE) echo '{s}';; PTUUID) echo '{s}';; SERIAL) echo '{s}';;
        \\MOUNTPOINT) printf '%b' '{s}';; TYPE) printf '%b' '{s}';; esac; }}
        \\{s}
    , .{ size, ptuuid, serial, mounts, types, cmd.argv[2] });
    const z = try a.dupeSentinel(u8, script, 0);
    return @intCast(system(z.ptr));
}

extern fn system(command: [*:0]const u8) c_int;

test "the guard stops when the disk was swapped or is in use" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = sampleDisk();
    d.serial = "AB 12";
    d.ptuuid = "1111-22";
    const g = try guard(a, d);
    try std.testing.expect(g.root);
    const size = "1073741824";
    const idle = "\\n\\n";
    const plain = "disk\\npart\\n";
    try std.testing.expectEqual(@as(u32, 0), try runGuard(a, g, size, "1111-22", "AB 12", idle, plain));
    try std.testing.expect(try runGuard(a, g, "999", "1111-22", "AB 12", idle, plain) != 0);
    try std.testing.expect(try runGuard(a, g, size, "other", "AB 12", idle, plain) != 0);
    try std.testing.expect(try runGuard(a, g, size, "1111-22", "CD 34", idle, plain) != 0);
    try std.testing.expect(try runGuard(a, g, size, "1111-22", "AB 12", "\\n/mnt\\n", plain) != 0);
    try std.testing.expect(try runGuard(a, g, size, "1111-22", "AB 12", idle, "disk\\npart\\ncrypt\\n") != 0);
}
