//! The shared desktop integration API (ai/COMPOSITOR-SPEC.md section 3.1 and 6).
//!
//! DKDE's shell and applications talk to the desktop through this module and
//! never see a Wayland object, an X11 atom or an XID. A display backend (the
//! Wayland one in dkde-panel today, an X11 one later) fills in a `Backend` and
//! the rest of the program uses `Desktop`, which turns every missing
//! capability into a harmless no-op instead of an error.
//!
//! Nothing here depends on GTK or on any display protocol.

const std = @import("std");

/// What a backend can do. Applications check these and hide or disable the
/// matching controls instead of failing (spec 3.2).
pub const Capability = enum {
    window_list,
    window_activate,
    window_minimize,
    window_maximize,
    window_close,
    /// Move or resize another program's window.
    window_move_resize,
    workspaces,
    workspace_switch,
    /// Windows know which workspace they are on.
    window_workspace,
    outputs,
    output_config,
    screenshot_output,
    screenshot_window,
    /// Panels, desktop surfaces and work-area reservation.
    panel_surface,
    desktop_surface,
    compositing_effects,
};

pub const Capabilities = std.EnumSet(Capability);

pub const BackendKind = enum { wayland, x11, none };

/// What a window can be asked to do. Set by the backend that owns the window.
pub const WindowOps = struct {
    activate: *const fn (*Window) void,
    set_minimized: *const fn (*Window, bool) void,
    set_maximized: *const fn (*Window, bool) void,
    close: *const fn (*Window) void,
};

/// One application window as the taskbar sees it. The backend owns the
/// memory and keeps the pointer valid until the window is gone; strings are
/// backend-owned too. The identity of a window is its pointer.
pub const Window = struct {
    ops: *const WindowOps,
    title: []const u8 = "",
    app_id: []const u8 = "",
    maximized: bool = false,
    minimized: bool = false,
    activated: bool = false,
    fullscreen: bool = false,
    /// Index into `Desktop.workspaces()`; null when unknown or on all of them.
    workspace: ?u32 = null,
    /// Set once the backend has told us everything it is going to; before
    /// that the window is not shown.
    ready: bool = false,

    pub fn activate(self: *Window) void {
        if (self.minimized) self.ops.set_minimized(self, false);
        self.ops.activate(self);
    }
    pub fn setMinimized(self: *Window, minimized: bool) void {
        self.ops.set_minimized(self, minimized);
    }
    pub fn setMaximized(self: *Window, maximized: bool) void {
        self.ops.set_maximized(self, maximized);
    }
    pub fn close(self: *Window) void {
        self.ops.close(self);
    }
    /// The text for a list: the title, or the application when there is none.
    pub fn displayName(self: *const Window) []const u8 {
        return if (self.title.len > 0) self.title else self.app_id;
    }
};

pub const Workspace = struct {
    name: []const u8 = "",
    active: bool = false,
    urgent: bool = false,
};

/// An output (monitor). The id is only meaningful to the backend that made it
/// (spec 6.5: ids are not interchangeable between backends).
pub const Output = struct {
    id: u64,
    name: []const u8 = "",
    width: u32 = 0,
    height: u32 = 0,
    /// Millihertz; 0 when unknown.
    refresh_mhz: u32 = 0,
    scale: f32 = 1,
    enabled: bool = true,
};

pub const CaptureTarget = union(enum) {
    output: u64,
    window: *Window,
};

/// A captured image: tightly packed 8-bit RGBA, `width * height * 4` bytes.
pub const Image = struct {
    width: u32,
    height: u32,
    rgba: []u8,

    pub fn deinit(self: Image, allocator: std.mem.Allocator) void {
        allocator.free(self.rgba);
    }
};

pub const Error = error{Unsupported} || std.mem.Allocator.Error || error{CaptureFailed};

/// What a display backend provides. Entries a backend cannot do are null and
/// its capability set leaves the matching capability out.
pub const VTable = struct {
    capabilities: *const fn (*anyopaque) Capabilities,
    windows: *const fn (*anyopaque) []const *Window,
    workspaces: ?*const fn (*anyopaque) []const *const Workspace = null,
    activate_workspace: ?*const fn (*anyopaque, usize) void = null,
    outputs: ?*const fn (*anyopaque) []const Output = null,
    capture: ?*const fn (*anyopaque, std.mem.Allocator, CaptureTarget) Error!Image = null,
    destroy: *const fn (*anyopaque) void,
};

pub const Backend = struct {
    kind: BackendKind,
    ptr: *anyopaque,
    vtable: *const VTable,
};

/// The program's view of the desktop. With no backend (an unsupported
/// session) every query is empty and every request does nothing.
pub const Desktop = struct {
    backend: ?Backend = null,

    pub fn kind(self: Desktop) BackendKind {
        return if (self.backend) |b| b.kind else .none;
    }

    pub fn capabilities(self: Desktop) Capabilities {
        const b = self.backend orelse return Capabilities.empty;
        return b.vtable.capabilities(b.ptr);
    }

    pub fn has(self: Desktop, capability: Capability) bool {
        return self.capabilities().contains(capability);
    }

    pub fn windows(self: Desktop) []const *Window {
        const b = self.backend orelse return &.{};
        if (!self.has(.window_list)) return &.{};
        return b.vtable.windows(b.ptr);
    }

    pub fn workspaces(self: Desktop) []const *const Workspace {
        const b = self.backend orelse return &.{};
        if (!self.has(.workspaces)) return &.{};
        const f = b.vtable.workspaces orelse return &.{};
        return f(b.ptr);
    }

    pub fn activeWorkspace(self: Desktop) ?usize {
        for (self.workspaces(), 0..) |w, i| if (w.active) return i;
        return null;
    }

    pub fn activateWorkspace(self: Desktop, index: usize) void {
        const b = self.backend orelse return;
        if (!self.has(.workspace_switch)) return;
        if (index >= self.workspaces().len) return;
        if (b.vtable.activate_workspace) |f| f(b.ptr, index);
    }

    /// Moves `step` workspaces from the current one (negative goes back),
    /// stopping at the ends. Returns whether it asked for a switch.
    pub fn stepWorkspace(self: Desktop, step: i32) bool {
        const now = self.activeWorkspace() orelse return false;
        const count = self.workspaces().len;
        const target = @as(i64, @intCast(now)) + step;
        if (target < 0 or target >= count or target == now) return false;
        self.activateWorkspace(@intCast(target));
        return true;
    }

    pub fn outputs(self: Desktop) []const Output {
        const b = self.backend orelse return &.{};
        if (!self.has(.outputs)) return &.{};
        const f = b.vtable.outputs orelse return &.{};
        return f(b.ptr);
    }

    /// Captures an output or a window. `error.Unsupported` when the backend
    /// (or the compositor's rules) does not allow that kind of capture.
    pub fn capture(self: Desktop, allocator: std.mem.Allocator, target: CaptureTarget) Error!Image {
        const b = self.backend orelse return error.Unsupported;
        const needed: Capability = switch (target) {
            .output => .screenshot_output,
            .window => .screenshot_window,
        };
        if (!self.has(needed)) return error.Unsupported;
        const f = b.vtable.capture orelse return error.Unsupported;
        return f(b.ptr, allocator, target);
    }

    pub fn destroy(self: *Desktop) void {
        if (self.backend) |b| b.vtable.destroy(b.ptr);
        self.backend = null;
    }
};

// ---------------------------------------------------------------- tests ----

/// A backend that needs no display, for tests here and in programs that want
/// to exercise their shell code.
pub const Fake = struct {
    allocator: std.mem.Allocator,
    caps: Capabilities,
    win_list: std.ArrayList(*Window) = .empty,
    ws_list: std.ArrayList(*const Workspace) = .empty,
    out_list: std.ArrayList(Output) = .empty,
    /// What the window operations did, in order, for assertions.
    log: std.ArrayList(u8) = .empty,

    const window_ops: WindowOps = .{
        .activate = wActivate,
        .set_minimized = wMinimized,
        .set_maximized = wMaximized,
        .close = wClose,
    };

    const vtable: VTable = .{
        .capabilities = capsOf,
        .windows = windowsOf,
        .workspaces = workspacesOf,
        .activate_workspace = switchTo,
        .outputs = outputsOf,
        .capture = captureOf,
        .destroy = destroyOf,
    };

    pub fn create(allocator: std.mem.Allocator, caps: Capabilities) !*Fake {
        const self = try allocator.create(Fake);
        self.* = .{ .allocator = allocator, .caps = caps };
        return self;
    }

    pub fn backend(self: *Fake) Backend {
        return .{ .kind = .none, .ptr = self, .vtable = &vtable };
    }

    const FakeWindow = struct { win: Window, fake: *Fake };

    pub fn addWindow(self: *Fake, title: []const u8, app_id: []const u8) !*Window {
        const w = try self.allocator.create(FakeWindow);
        w.* = .{ .win = .{ .ops = &window_ops, .title = title, .app_id = app_id, .ready = true }, .fake = self };
        try self.win_list.append(self.allocator, &w.win);
        return &w.win;
    }

    pub fn addWorkspace(self: *Fake, name: []const u8, active: bool) !void {
        const w = try self.allocator.create(Workspace);
        w.* = .{ .name = name, .active = active };
        try self.ws_list.append(self.allocator, w);
    }

    fn self_(p: *anyopaque) *Fake {
        return @ptrCast(@alignCast(p));
    }
    fn owner(w: *Window) *Fake {
        const fw: *FakeWindow = @fieldParentPtr("win", w);
        return fw.fake;
    }
    fn note(w: *Window, comptime fmt: []const u8, args: anytype) void {
        const f = owner(w);
        f.log.print(f.allocator, fmt, args) catch {};
    }
    fn wActivate(w: *Window) void {
        note(w, "activate {s};", .{w.title});
        for (owner(w).win_list.items) |o| o.activated = o == w;
    }
    fn wMinimized(w: *Window, m: bool) void {
        note(w, "minimize {s} {};", .{ w.title, m });
        w.minimized = m;
    }
    fn wMaximized(w: *Window, m: bool) void {
        note(w, "maximize {s} {};", .{ w.title, m });
        w.maximized = m;
    }
    fn wClose(w: *Window) void {
        note(w, "close {s};", .{w.title});
    }
    fn capsOf(p: *anyopaque) Capabilities {
        return self_(p).caps;
    }
    fn windowsOf(p: *anyopaque) []const *Window {
        return self_(p).win_list.items;
    }
    fn workspacesOf(p: *anyopaque) []const *const Workspace {
        return self_(p).ws_list.items;
    }
    fn switchTo(p: *anyopaque, index: usize) void {
        const self = self_(p);
        for (self.ws_list.items, 0..) |w, i| @constCast(w).active = i == index;
    }
    fn outputsOf(p: *anyopaque) []const Output {
        return self_(p).out_list.items;
    }
    fn captureOf(p: *anyopaque, allocator: std.mem.Allocator, target: CaptureTarget) Error!Image {
        _ = p;
        _ = target;
        const px = try allocator.alloc(u8, 2 * 2 * 4);
        @memset(px, 0xff);
        return .{ .width = 2, .height = 2, .rgba = px };
    }
    fn destroyOf(p: *anyopaque) void {
        const self = self_(p);
        for (self.win_list.items) |w| self.allocator.destroy(@as(*FakeWindow, @fieldParentPtr("win", w)));
        for (self.ws_list.items) |w| self.allocator.destroy(@constCast(w));
        self.win_list.deinit(self.allocator);
        self.ws_list.deinit(self.allocator);
        self.out_list.deinit(self.allocator);
        self.log.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

test "no backend: queries are empty and requests do nothing" {
    var d: Desktop = .{};
    try std.testing.expectEqual(BackendKind.none, d.kind());
    try std.testing.expect(!d.has(.window_list));
    try std.testing.expectEqual(@as(usize, 0), d.windows().len);
    try std.testing.expectEqual(@as(usize, 0), d.workspaces().len);
    try std.testing.expectEqual(@as(?usize, null), d.activeWorkspace());
    d.activateWorkspace(0);
    try std.testing.expect(!d.stepWorkspace(1));
    try std.testing.expectError(error.Unsupported, d.capture(std.testing.allocator, .{ .output = 0 }));
}

test "windows: activate restores a minimized window first" {
    const a = std.testing.allocator;
    const fake = try Fake.create(a, Capabilities.initMany(&.{.window_list}));
    var d: Desktop = .{ .backend = fake.backend() };
    defer d.destroy();

    const w = try fake.addWindow("Term", "dkde-term");
    w.minimized = true;
    try std.testing.expectEqual(@as(usize, 1), d.windows().len);
    d.windows()[0].activate();
    try std.testing.expectEqualStrings("minimize Term false;activate Term;", fake.log.items);
    try std.testing.expect(w.activated and !w.minimized);
    try std.testing.expectEqualStrings("Term", w.displayName());
    w.title = "";
    try std.testing.expectEqualStrings("dkde-term", w.displayName());
}

test "capabilities gate every query" {
    const a = std.testing.allocator;
    // The backend has data, but does not claim the capabilities.
    const fake = try Fake.create(a, Capabilities.empty);
    var d: Desktop = .{ .backend = fake.backend() };
    defer d.destroy();
    _ = try fake.addWindow("x", "y");
    try fake.addWorkspace("1", true);
    try fake.out_list.append(a, .{ .id = 1 });
    try std.testing.expectEqual(@as(usize, 0), d.windows().len);
    try std.testing.expectEqual(@as(usize, 0), d.workspaces().len);
    try std.testing.expectEqual(@as(usize, 0), d.outputs().len);
    try std.testing.expectError(error.Unsupported, d.capture(a, .{ .output = 1 }));
}

test "workspaces: switching and stepping stop at the ends" {
    const a = std.testing.allocator;
    const fake = try Fake.create(a, Capabilities.initMany(&.{ .workspaces, .workspace_switch }));
    var d: Desktop = .{ .backend = fake.backend() };
    defer d.destroy();
    try fake.addWorkspace("1", true);
    try fake.addWorkspace("2", false);
    try fake.addWorkspace("3", false);

    try std.testing.expectEqual(@as(?usize, 0), d.activeWorkspace());
    try std.testing.expect(!d.stepWorkspace(-1));
    try std.testing.expect(d.stepWorkspace(1));
    try std.testing.expectEqual(@as(?usize, 1), d.activeWorkspace());
    d.activateWorkspace(2);
    try std.testing.expectEqual(@as(?usize, 2), d.activeWorkspace());
    try std.testing.expect(!d.stepWorkspace(1));
    d.activateWorkspace(9); // out of range: ignored
    try std.testing.expectEqual(@as(?usize, 2), d.activeWorkspace());
}

test "capture: output and window are separate capabilities" {
    const a = std.testing.allocator;
    const fake = try Fake.create(a, Capabilities.initMany(&.{.screenshot_output}));
    var d: Desktop = .{ .backend = fake.backend() };
    defer d.destroy();
    const img = try d.capture(a, .{ .output = 1 });
    defer img.deinit(a);
    try std.testing.expectEqual(@as(usize, 16), img.rgba.len);
    const w = try fake.addWindow("x", "y");
    try std.testing.expectError(error.Unsupported, d.capture(a, .{ .window = w }));
}

test "outputs are listed when the capability is present" {
    const a = std.testing.allocator;
    const fake = try Fake.create(a, Capabilities.initMany(&.{.outputs}));
    var d: Desktop = .{ .backend = fake.backend() };
    defer d.destroy();
    try fake.out_list.append(a, .{ .id = 7, .name = "DP-1", .width = 1920, .height = 1080, .refresh_mhz = 60000 });
    try std.testing.expectEqual(@as(usize, 1), d.outputs().len);
    try std.testing.expectEqualStrings("DP-1", d.outputs()[0].name);
}
