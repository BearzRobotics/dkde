//! The shared module of the GTK programs: everything in `core` plus the
//! widgets and stylesheet. Programs without a window import "core" instead.
//! See SPEC.md 4.2 and ai/DKDE-SPEC.md section 22.

const core = @import("core");

// Toolkit-free parts, re-exported so `common.config` and friends keep working.
pub const appdirs = core.appdirs;
pub const appimage = core.appimage;
pub const appinfo = core.appinfo;
pub const autostart = core.autostart;
pub const apps = core.apps;
pub const audio = core.audio;
pub const civil = core.civil;
pub const rosquin = core.rosquin;
pub const rrule = core.rrule;
pub const config = core.config;
pub const events = core.events;
pub const feeds = core.feeds;
pub const goa = core.goa;
pub const gcal = core.gcal;
pub const fsio = core.fsio;
pub const i18n = core.i18n;
pub const icons = core.icons;
pub const ics = core.ics;
pub const labwc = core.labwc;
pub const log = core.log;
pub const migrate = core.migrate;
pub const notify = core.notify;
pub const paths = core.paths;
pub const perf = core.perf;
pub const power = core.power;
pub const proc = core.proc;
pub const state = core.state;
pub const toolkits = core.toolkits;
pub const user = core.user;

// GTK parts.
pub const contextmenu = @import("contextmenu.zig");
pub const dialogs = @import("dialogs.zig");
pub const elevate = @import("elevate.zig");
pub const header = @import("header.zig");
pub const menubar = @import("menubar.zig");
pub const runapp = @import("runapp.zig");
pub const style = @import("style.zig");

pub const Config = core.Config;
pub const tr = core.tr;

test {
    @import("std").testing.refAllDecls(@This());
}
