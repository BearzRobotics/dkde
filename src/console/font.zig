//! What the console and the Settings page share: the font readers and the
//! settings table (SPEC.md 5.11). One module, so there is one copy of each.

pub const psf = @import("psf.zig");
pub const ttf = @import("ttf.zig");
pub const config = @import("config.zig");
pub const fontscan = @import("fontscan.zig");
pub const sample = @import("sample.zig");

test {
    _ = psf;
    _ = ttf;
    _ = config;
    _ = fontscan;
    _ = sample;
}
