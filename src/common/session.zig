//! Which window system the running DKDE session uses, so programs know where its
//! settings live. DKDE's own compositor and X11 window manager read
//! `~/.config/dkde/compositor.toml` and say who they are in the environment
//! (`DKDE_SESSION_COMPOSITOR`, and `DKDE_SESSION_PID` to end the session);
//! anything else, labwc included, is configured through its own files.

const std = @import("std");

pub const Kind = enum {
    /// labwc, or any compositor DKDE does not own: its rc.xml and environment file.
    labwc,
    dkde_compositor,
    dkde_wm,

    /// DKDE's own: settings are in compositor.toml and apply at once.
    pub fn isDkde(self: Kind) bool {
        return self != .labwc;
    }
};

pub fn kindFromName(name: ?[]const u8) Kind {
    const n = name orelse return .labwc;
    if (std.mem.eql(u8, n, "dkde-compositor")) return .dkde_compositor;
    if (std.mem.eql(u8, n, "dkde-wm")) return .dkde_wm;
    return .labwc;
}

extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;

pub fn kind() Kind {
    const v = getenv("DKDE_SESSION_COMPOSITOR");
    return kindFromName(if (v) |p| std.mem.span(p) else null);
}

/// The command "Log Off" runs unless the person set their own.
pub fn defaultLogoff(k: Kind) []const u8 {
    return switch (k) {
        .labwc => "labwc --exit",
        // Both of DKDE's own end the session on SIGTERM.
        .dkde_compositor, .dkde_wm => "sh -c 'kill \"$DKDE_SESSION_PID\"'",
    };
}

test "session kinds" {
    try std.testing.expectEqual(Kind.labwc, kindFromName(null));
    try std.testing.expectEqual(Kind.labwc, kindFromName("labwc"));
    try std.testing.expectEqual(Kind.dkde_compositor, kindFromName("dkde-compositor"));
    try std.testing.expectEqual(Kind.dkde_wm, kindFromName("dkde-wm"));
    try std.testing.expect(Kind.dkde_wm.isDkde() and !Kind.labwc.isDkde());
    try std.testing.expect(std.mem.indexOf(u8, defaultLogoff(.dkde_wm), "DKDE_SESSION_PID") != null);
}
