//! The parts of the compositor with no display code in them, for the X11
//! window manager (src/xwm) to share: layout policy, shortcut parsing and
//! the settings file.
pub const layout = @import("layout.zig");
pub const keys = @import("keys.zig");
pub const config = @import("config.zig");
pub const developer = @import("developer.zig");
pub const place = @import("place.zig");
pub const rules = @import("rules.zig");
pub const anim = @import("anim.zig");
