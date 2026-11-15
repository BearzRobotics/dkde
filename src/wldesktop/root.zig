//! The Wayland implementation of the shared desktop API (core.desktop):
//! windows from `wlr-foreign-toplevel-management`, workspaces from
//! `ext-workspace-v1`, outputs from `wlr-output-management` and screenshots
//! from `wlr-screencopy`. It needs no toolkit: the caller gives it the
//! `wl_display` and dispatches its events (GDK does, in the GTK programs).

const std = @import("std");
const wayland = @import("wayland");
const core = @import("core");

const toplevels = @import("toplevels.zig");
const workspaces = @import("workspaces.zig");
const outputs = @import("outputs.zig");
const capture = @import("capture.zig");

const desktop = core.desktop;
const wl = wayland.client.wl;

const log = std.log.scoped(.wldesktop);

/// Which parts to bind. A program that only takes screenshots asks for
/// `.{ .windows = false, .workspaces = false, .outputs = false }`.
pub const Parts = struct {
    windows: bool = true,
    workspaces: bool = true,
    outputs: bool = true,
    capture: bool = true,
};

/// Called (with `data`) after the matching part changes. Any may be null.
pub const Callbacks = struct {
    data: *anyopaque,
    on_windows: ?*const fn (*anyopaque) void = null,
    on_workspaces: ?*const fn (*anyopaque) void = null,
    on_outputs: ?*const fn (*anyopaque) void = null,
};

fn ignore(_: *anyopaque) void {}

pub const Wayland = struct {
    allocator: std.mem.Allocator,
    display: *wl.Display,
    registry: *wl.Registry,
    seat: ?*wl.Seat = null,
    windows: ?*toplevels.Manager = null,
    workspaces: ?*workspaces.Workspaces = null,
    outputs: ?*outputs.Outputs = null,
    capturer: ?*capture.Capturer = null,

    const vtable: desktop.VTable = .{
        .capabilities = capabilities,
        .windows = windowList,
        .workspaces = workspaceList,
        .activate_workspace = activateWorkspace,
        .outputs = outputList,
        .configure_outputs = configureOutputs,
        .capture = captureOf,
        .destroy = destroy,
    };

    /// Connects the parts to `display` and does one round trip so the
    /// globals are known. Returns an empty Desktop when nothing binds.
    pub fn create(allocator: std.mem.Allocator, display: *wl.Display, parts: Parts, cbs: Callbacks) desktop.Desktop {
        const self = allocator.create(Wayland) catch return .{};
        self.* = .{ .allocator = allocator, .display = display, .registry = display.getRegistry() catch {
            allocator.destroy(self);
            return .{};
        } };
        if (parts.windows) self.windows = toplevels.Manager.create(allocator, cbs.on_windows orelse ignore, cbs.data) catch null;
        if (parts.workspaces) self.workspaces = workspaces.Workspaces.create(allocator, cbs.on_workspaces orelse ignore, cbs.data);
        if (parts.outputs) self.outputs = outputs.Outputs.create(allocator, cbs.on_outputs orelse ignore, cbs.data);
        if (parts.capture) self.capturer = capture.Capturer.create(allocator) catch null;
        self.registry.setListener(*Wayland, registryEvent, self);
        _ = display.roundtrip();
        // The second round trip delivers what the binds asked for (output
        // names and modes), so capabilities are right on return.
        _ = display.roundtrip();
        return .{ .backend = .{ .kind = .wayland, .ptr = self, .vtable = &vtable } };
    }

    fn registryEvent(registry: *wl.Registry, event: wl.Registry.Event, self: *Wayland) void {
        switch (event) {
            .global => |g| {
                if (std.mem.orderZ(u8, g.interface, wl.Seat.interface.name) == .eq) {
                    if (self.seat == null) {
                        self.seat = registry.bind(g.name, wl.Seat, 1) catch null;
                        if (self.windows) |w| w.seat = self.seat;
                    }
                    return;
                }
                if (self.windows) |w| w.onGlobal(registry, g);
                if (self.workspaces) |w| w.onGlobal(registry, g);
                if (self.outputs) |o| o.onGlobal(registry, g);
                if (self.capturer) |c| c.onGlobal(registry, g);
            },
            .global_remove => {},
        }
    }

    fn of(p: *anyopaque) *Wayland {
        return @ptrCast(@alignCast(p));
    }

    fn capabilities(p: *anyopaque) desktop.Capabilities {
        const self = of(p);
        var caps = desktop.Capabilities.empty;
        if (self.windows) |w| {
            if (w.manager != null) {
                for ([_]desktop.Capability{ .window_list, .window_activate, .window_minimize, .window_maximize, .window_close }) |c| caps.insert(c);
            }
        }
        // A compositor without ext-workspace-v1 never gives us a manager.
        if (self.workspaces) |w| {
            if (w.manager != null) {
                caps.insert(.workspaces);
                caps.insert(.workspace_switch);
            }
        }
        if (self.outputs) |o| {
            if (o.manager != null) {
                caps.insert(.outputs);
                caps.insert(.output_config);
            }
        }
        if (self.capturer) |c| if (c.available()) caps.insert(.screenshot_output);
        return caps;
    }

    fn windowList(p: *anyopaque) []const *desktop.Window {
        return if (of(p).windows) |m| m.windows.items else &.{};
    }

    fn workspaceList(p: *anyopaque) []const *const desktop.Workspace {
        return if (of(p).workspaces) |w| w.infos.items else &.{};
    }

    fn activateWorkspace(p: *anyopaque, index: usize) void {
        if (of(p).workspaces) |w| w.activate(index);
    }

    fn outputList(p: *anyopaque) []const desktop.Output {
        return if (of(p).outputs) |o| o.list.items else &.{};
    }

    fn configureOutputs(p: *anyopaque, edits: []const desktop.OutputEdit, done: desktop.ConfigDone, ctx: ?*anyopaque) void {
        if (of(p).outputs) |o| o.configure(edits, done, ctx) else done(ctx, false);
    }

    fn captureOf(p: *anyopaque, allocator: std.mem.Allocator, target: desktop.CaptureTarget, done: desktop.CaptureDone, ctx: ?*anyopaque) void {
        const self = of(p);
        const capturer = self.capturer orelse return done(ctx, error.Unsupported);
        switch (target) {
            .primary => capturer.start(allocator, null, done, ctx),
            .output => |id| {
                const name = if (self.outputs) |o| o.nameOf(id) else null;
                capturer.start(allocator, name orelse return done(ctx, error.CaptureFailed), done, ctx);
            },
            .window => done(ctx, error.Unsupported),
        }
    }

    fn destroy(p: *anyopaque) void {
        const self = of(p);
        if (self.windows) |m| m.destroy();
        if (self.workspaces) |w| w.destroy();
        if (self.outputs) |o| o.destroy();
        if (self.capturer) |c| c.destroy();
        self.registry.destroy();
        self.allocator.destroy(self);
    }
};
