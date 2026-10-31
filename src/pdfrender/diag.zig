//! What the renderer could not do, counted and optionally logged. A page that
//! draws wrongly leaves a trail here, so a large set of files can be checked
//! with `dkde-pdfcheck` and the gaps sorted by how often they occur.
//!
//! Each event is logged through `std.log` (scope `.pdfrender`) at debug level,
//! so `DKDE_LOG=debug` shows them in any dkde program; `DKDE_PDF_LOG=1` (any
//! value) raises them to warnings.

const std = @import("std");

const log = std.log.scoped(.pdfrender);

pub const Diag = struct {
    allocator: std.mem.Allocator,
    /// Kind -> number of times, keys owned.
    counts: std.StringHashMapUnmanaged(u32) = .empty,
    verbose: bool = false,
    /// The page being drawn, for log lines.
    page: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Diag {
        return .{ .allocator = allocator, .verbose = std.c.getenv("DKDE_PDF_LOG") != null };
    }

    pub fn deinit(self: *Diag) void {
        var it = self.counts.iterator();
        while (it.next()) |e| self.allocator.free(e.key_ptr.*);
        self.counts.deinit(self.allocator);
    }

    /// Records one event. `kind` is a short stable name such as `image-jpx`;
    /// `detail` is free text for the log (a font name, an operator).
    pub fn note(self: *Diag, kind: []const u8, detail: []const u8) void {
        const gop = self.counts.getOrPut(self.allocator, kind) catch return;
        if (!gop.found_existing) {
            gop.key_ptr.* = self.allocator.dupe(u8, kind) catch {
                _ = self.counts.remove(kind);
                return;
            };
            gop.value_ptr.* = 0;
        }
        gop.value_ptr.* += 1;
        if (self.verbose) log.warn("page {d}: {s}: {s}", .{ self.page + 1, kind, detail }) else log.debug("page {d}: {s}: {s}", .{ self.page + 1, kind, detail });
    }

    pub fn total(self: *const Diag) u32 {
        var n: u32 = 0;
        var it = self.counts.valueIterator();
        while (it.next()) |v| n += v.*;
        return n;
    }

    /// Adds this page's counts to `into` (for a per-file or per-run summary).
    pub fn mergeInto(self: *const Diag, into: *Diag) void {
        var it = self.counts.iterator();
        while (it.next()) |e| {
            const gop = into.counts.getOrPut(into.allocator, e.key_ptr.*) catch continue;
            if (!gop.found_existing) {
                gop.key_ptr.* = into.allocator.dupe(u8, e.key_ptr.*) catch {
                    _ = into.counts.remove(e.key_ptr.*);
                    continue;
                };
                gop.value_ptr.* = 0;
            }
            gop.value_ptr.* += e.value_ptr.*;
        }
    }
};

test "events are counted by kind" {
    var d = Diag.init(std.testing.allocator);
    d.verbose = false;
    defer d.deinit();
    d.note("image-jpx", "a");
    d.note("image-jpx", "b");
    d.note("op-sh", "");
    try std.testing.expectEqual(@as(u32, 3), d.total());
    try std.testing.expectEqual(@as(u32, 2), d.counts.get("image-jpx").?);
    var all = Diag.init(std.testing.allocator);
    defer all.deinit();
    d.mergeInto(&all);
    d.mergeInto(&all);
    try std.testing.expectEqual(@as(u32, 4), all.counts.get("image-jpx").?);
}
