//! Which screen edge the panel sits on.

const std = @import("std");
const layer_shell = @import("layer_shell.zig");

pub const Position = enum {
    bottom,
    top,
    left,
    right,

    pub fn fromName(name: []const u8) Position {
        inline for (@typeInfo(Position).@"enum".field_names) |field| {
            if (std.ascii.eqlIgnoreCase(name, field)) return @field(Position, field);
        }
        return .bottom;
    }

    /// The screen edge the panel sits on.
    pub fn edge(self: Position) layer_shell.Edge {
        return switch (self) {
            .bottom => .bottom,
            .top => .top,
            .left => .left,
            .right => .right,
        };
    }

    pub fn isVertical(self: Position) bool {
        return self == .left or self == .right;
    }

    /// The edges the layer surface is anchored to: its own edge and both
    /// neighbours, so it spans the whole side.
    pub fn anchors(self: Position) []const layer_shell.Edge {
        return switch (self) {
            .bottom => &.{ .bottom, .left, .right },
            .top => &.{ .top, .left, .right },
            .left => &.{ .left, .top, .bottom },
            .right => &.{ .right, .top, .bottom },
        };
    }
};

test "position names" {
    try std.testing.expectEqual(Position.top, Position.fromName("Top"));
    try std.testing.expectEqual(Position.bottom, Position.fromName("nonsense"));
    try std.testing.expect(Position.left.isVertical());
    try std.testing.expect(!Position.bottom.isVertical());
}
