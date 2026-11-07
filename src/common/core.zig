//! dkde-core: what every DKDE program can use without a toolkit. Needs GLib
//! and GIO, but not GTK, so small programs (notifications, setup, the
//! Polkit agent) do not link it. Widgets and the shared stylesheet are in
//! `ui` (root.zig).
//!
//! Dependency rule: nothing here imports GTK or GDK.

pub const appinfo = @import("appinfo.zig");
pub const apps = @import("apps.zig");
pub const audio = @import("audio.zig");
pub const civil = @import("civil.zig");
pub const rosquin = @import("rosquin.zig");
pub const config = @import("config.zig");
pub const fsio = @import("fsio.zig");
pub const events = @import("events.zig");
pub const i18n = @import("i18n.zig");
pub const icons = @import("icons.zig");
pub const ics = @import("ics.zig");
pub const labwc = @import("labwc.zig");
pub const log = @import("log.zig");
pub const migrate = @import("migrate.zig");
pub const notify = @import("notify.zig");
pub const paths = @import("paths.zig");
pub const perf = @import("perf.zig");
pub const power = @import("power.zig");
pub const proc = @import("proc.zig");
pub const state = @import("state.zig");
pub const toolkits = @import("toolkits.zig");
pub const tomltext = @import("tomltext.zig");
pub const user = @import("user.zig");

pub const Config = config.Config;
pub const tr = i18n.tr;

test {
    @import("std").testing.refAllDecls(@This());
}
