//! What the standalone Windows calendar takes from `common`: only the pure
//! calendar arithmetic, with no GLib and no GTK.
pub const civil = @import("civil.zig");
pub const rosquin = @import("rosquin.zig");
pub const events = @import("events.zig");
pub const ics = @import("ics.zig");
pub const paths = @import("paths.zig");
pub const fsio = @import("fsio.zig");
pub const Config = @import("config.zig").Config;
