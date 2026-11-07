//! Where the panel's windows live: layer-shell surfaces on Wayland.

const layer_shell = @import("layer_shell.zig");

pub const Layer = layer_shell.Layer;
pub const Edge = layer_shell.Edge;
pub const KeyboardMode = layer_shell.KeyboardMode;
pub const Options = layer_shell.Options;

pub const setup = layer_shell.setup;
pub const setExclusiveZone = layer_shell.setExclusiveZone;
