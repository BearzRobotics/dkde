//! Shared module for every dkde component. See SPEC.md section 4.2.

pub const apps = @import("apps.zig");
pub const audio = @import("audio.zig");
pub const proc = @import("proc.zig");
pub const notify = @import("notify.zig");
pub const power = @import("power.zig");
pub const runapp = @import("runapp.zig");
pub const appinfo = @import("appinfo.zig");
pub const config = @import("config.zig");
pub const contextmenu = @import("contextmenu.zig");
pub const dialogs = @import("dialogs.zig");
pub const header = @import("header.zig");
pub const elevate = @import("elevate.zig");
pub const menubar = @import("menubar.zig");
pub const labwc = @import("labwc.zig");
pub const log = @import("log.zig");
pub const i18n = @import("i18n.zig");
pub const icons = @import("icons.zig");
pub const paths = @import("paths.zig");
pub const perf = @import("perf.zig");
pub const state = @import("state.zig");
pub const user = @import("user.zig");
pub const style = @import("style.zig");

pub const Config = config.Config;
pub const tr = i18n.tr;

test {
    @import("std").testing.refAllDecls(@This());
}
