//! Terminal code shared by dkde-term and dkde-console (SPEC.md 4.3).
//! Imports only `std` and libghostty-vt: no GTK, GLib or Pango.

pub const ini = @import("ini.zig");
pub const pty = @import("pty.zig");
pub const schemes = @import("schemes.zig");
pub const keymap = @import("keymap.zig");
pub const glue = @import("glue.zig");

test {
    _ = ini;
    _ = pty;
    _ = schemes;
    _ = keymap;
    _ = glue;
}
