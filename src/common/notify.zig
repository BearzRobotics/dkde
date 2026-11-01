//! Sends a desktop notification through the session bus
//! (org.freedesktop.Notifications), for apps that need to tell the user
//! something later: a timer ending, an alarm. Without a bus or a notification
//! daemon it does nothing and says so in the log.

const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");

pub fn send(summary: [:0]const u8, body: [:0]const u8, icon: [:0]const u8) void {
    sendTimed(summary, body, icon, -1);
}

/// `timeout_ms`: -1 for the server's default, 0 to stay until dismissed.
pub fn sendTimed(summary: [:0]const u8, body: [:0]const u8, icon: [:0]const u8, timeout_ms: i32) void {
    var err: ?*glib.Error = null;
    const connection = gio.busGetSync(.session, null, &err) orelse {
        if (err) |e| {
            std.log.warn("no session bus for a notification: {s}", .{e.f_message orelse "unknown error"});
            e.free();
        }
        return;
    };
    const no_actions = [_]?[*:0]const u8{};
    var args = [_]*glib.Variant{
        glib.Variant.newString("dkde"),
        glib.Variant.newUint32(0),
        glib.Variant.newString(icon),
        glib.Variant.newString(summary),
        glib.Variant.newString(body),
        glib.Variant.newStrv(&no_actions, 0),
        emptyHints(),
        glib.Variant.newInt32(timeout_ms),
    };
    connection.call(
        "org.freedesktop.Notifications",
        "/org/freedesktop/Notifications",
        "org.freedesktop.Notifications",
        "Notify",
        glib.Variant.newTuple(&args, args.len),
        null,
        .{},
        2000,
        null,
        null,
        null,
    );
}

/// An empty `a{sv}`.
fn emptyHints() *glib.Variant {
    const element_type = glib.VariantType.new("{sv}");
    defer element_type.free();
    return glib.Variant.newArray(element_type, null, 0);
}
