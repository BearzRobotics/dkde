//! The taskbar surface for one output (SPEC.md 5.1): start button, a
//! stretching area for the taskbar buttons (M2), and the clock.

const std = @import("std");
const cairo = @import("cairo1");
const gdk = @import("gdk4");
const glib = @import("glib2");
const gtk = @import("gtk4");
const common = @import("common");

const surface = @import("surface.zig");
const Position = @import("position.zig").Position;
const Taskbar = @import("taskbar.zig").Taskbar;
const Tray = @import("tray.zig").Tray;
const Quick = @import("quick.zig").Quick;
const Workspaces = @import("workspaces.zig").Workspaces;

const StartClick = struct { callback: *const fn (*anyopaque) void, data: *anyopaque };

fn onStartClicked(_: *gtk.Button, click: *StartClick) callconv(.c) void {
    click.callback(click.data);
}

fn onStartDestroy(_: *gtk.Button, click: *StartClick) callconv(.c) void {
    std.heap.c_allocator.destroy(click);
}

const task_manager = 0;
const open_settings = 1;

fn onBarRightClick(_: *gtk.GestureClick, _: c_int, x: f64, y: f64, box: *gtk.Box) callconv(.c) void {
    common.contextmenu.show(box.as(gtk.Widget), x, y, &.{
        .{ .label = common.tr("Task Manager"), .id = task_manager },
        .{ .label = common.tr("Settings"), .id = open_settings },
    }, gtk.Box, onBarChosen, box);
}

fn onBarChosen(_: *gtk.Box, id: usize) void {
    switch (id) {
        task_manager => common.appinfo.spawn(std.heap.c_allocator, &.{"dkde-tasks"}),
        open_settings => common.appinfo.spawn(std.heap.c_allocator, &.{"dkde-settings"}),
        else => {},
    }
}

const adjust_time = 0;
const clock_settings = 1;

fn onClockRightClick(_: *gtk.GestureClick, _: c_int, x: f64, y: f64, label: *gtk.Label) callconv(.c) void {
    common.contextmenu.show(label.as(gtk.Widget), x, y, &.{
        .{ .label = common.tr("Adjust date/time"), .id = adjust_time },
        .{ .label = common.tr("Clock format"), .id = clock_settings },
    }, gtk.Label, onClockChosen, label);
}

fn onClockChosen(_: *gtk.Label, id: usize) void {
    // Both live on the Date & time page.
    _ = id;
    common.appinfo.spawn(std.heap.c_allocator, &.{ "dkde-settings", "--page", "datetime" });
}

/// Left click: a month calendar above or beside the clock.
fn onClockClick(_: *gtk.GestureClick, _: c_int, _: f64, _: f64, label: *gtk.Label) callconv(.c) void {
    const popover = gtk.Popover.new();
    popover.as(gtk.Widget).addCssClass("dkde-calendar");
    popover.as(gtk.Widget).setParent(label.as(gtk.Widget));
    const calendar = gtk.Calendar.new();
    popover.setChild(calendar.as(gtk.Widget));
    _ = gtk.Popover.signals.closed.connect(popover, *gtk.Popover, &onCalendarClosed, popover, .{});
    popover.popup();
}

fn onCalendarClosed(_: *gtk.Popover, popover: *gtk.Popover) callconv(.c) void {
    // Unparent once the close animation is done.
    _ = glib.idleAdd(unparent, popover);
}

fn unparent(data: ?*anyopaque) callconv(.c) c_int {
    const popover: *gtk.Popover = @ptrCast(@alignCast(data.?));
    popover.as(gtk.Widget).unparent();
    return 0;
}

pub const Bar = struct {
    allocator: std.mem.Allocator,
    window: *gtk.Window,
    root: *gtk.Box,
    revealer: *gtk.Revealer,
    clock: *gtk.Label,
    taskbar: *Taskbar,
    tray_box: *gtk.Box,
    tray: ?*Tray,
    quick_box: *gtk.Box,
    quick: ?*Quick,
    desktops_box: *gtk.Box,
    desktops_scroll: ?*gtk.EventControllerScroll = null,
    desktops_label: ?*gtk.Label = null,
    desktops_popover: ?*gtk.Popover = null,
    position: Position,
    autohide: bool,
    thickness: c_int,
    /// Set while the start menu is open, so an auto-hidden bar stays put.
    keep_open: bool = false,
    expanded: bool = true,
    hide_source: c_uint = 0,

    /// How much of an auto-hidden bar stays at the edge to catch the pointer.
    const sliver = 8;

    pub fn create(
        allocator: std.mem.Allocator,
        monitor: *gdk.Monitor,
        thickness: c_int,
        position: Position,
        autohide: bool,
        on_start: *const fn (*anyopaque) void,
        on_start_data: *anyopaque,
        tray: ?*Tray,
        quick: ?*Quick,
    ) !*Bar {
        // Auto-hide needs layer-shell; on X11 the bar stays put.
        const autohide_on = autohide and !surface.isX11();
        const vertical = position.isVertical();
        const window = gtk.Window.new();
        window.as(gtk.Widget).addCssClass("dkde-panel");
        window.as(gtk.Widget).addCssClass(switch (position) {
            .bottom => "pos-bottom",
            .top => "pos-top",
            .left => "pos-left",
            .right => "pos-right",
        });
        if (vertical) window.as(gtk.Widget).addCssClass("vertical");

        const root = gtk.Box.new(if (vertical) .vertical else .horizontal, 0);
        root.as(gtk.Widget).addCssClass("dkde-panel-body");
        // The bar slides in and out inside a surface that never changes size,
        // so revealing it needs no round trip to the compositor.
        const revealer = gtk.Revealer.new();
        revealer.setTransitionType(switch (position) {
            .bottom => .slide_up,
            .top => .slide_down,
            .left => .slide_right,
            .right => .slide_left,
        });
        revealer.setTransitionDuration(if (autohide_on) 150 else 0);
        revealer.setRevealChild(1);
        revealer.setChild(root.as(gtk.Widget));
        // GTK only delivers pointer events over widgets, and a collapsed
        // revealer is none: an invisible strip at the screen edge is what the
        // pointer touches to bring an auto-hidden bar back.
        const overlay = gtk.Overlay.new();
        overlay.setChild(revealer.as(gtk.Widget));
        const edge = gtk.Box.new(.horizontal, 0);
        edge.as(gtk.Widget).addCssClass("dkde-panel-edge");
        switch (position) {
            .bottom => {
                edge.as(gtk.Widget).setSizeRequest(-1, sliver);
                edge.as(gtk.Widget).setValign(.end);
            },
            .top => {
                edge.as(gtk.Widget).setSizeRequest(-1, sliver);
                edge.as(gtk.Widget).setValign(.start);
            },
            .left => {
                edge.as(gtk.Widget).setSizeRequest(sliver, -1);
                edge.as(gtk.Widget).setHalign(.start);
            },
            .right => {
                edge.as(gtk.Widget).setSizeRequest(sliver, -1);
                edge.as(gtk.Widget).setHalign(.end);
            },
        }
        if (autohide_on) overlay.addOverlay(edge.as(gtk.Widget));
        window.setChild(overlay.as(gtk.Widget));

        // The Start button: a grid icon and the word, as one flat button.
        const start = gtk.Button.new();
        const start_content = gtk.Box.new(.horizontal, 8);
        const start_icon = gtk.Image.newFromIconName("view-app-grid-symbolic");
        start_icon.setPixelSize(16);
        start_content.append(start_icon.as(gtk.Widget));
        if (!vertical) start_content.append(gtk.Label.new(common.tr("Start")).as(gtk.Widget));
        start.setChild(start_content.as(gtk.Widget));
        start.as(gtk.Widget).addCssClass("dkde-start");
        const click = try std.heap.c_allocator.create(StartClick);
        click.* = .{ .callback = on_start, .data = on_start_data };
        _ = gtk.Button.signals.clicked.connect(start, *StartClick, &onStartClicked, click, .{});
        _ = gtk.Widget.signals.destroy.connect(start, *StartClick, &onStartDestroy, click, .{});
        root.append(start.as(gtk.Widget));

        // Virtual desktop switcher, shown when there is more than one desktop.
        const desktops_box = gtk.Box.new(if (vertical) .vertical else .horizontal, 2);
        desktops_box.as(gtk.Widget).addCssClass("dkde-desktops");
        desktops_box.as(gtk.Widget).setVisible(0);

        const taskbar = try Taskbar.create(allocator, vertical);
        errdefer taskbar.destroy();
        if (vertical) taskbar.box.as(gtk.Widget).setVexpand(1) else taskbar.box.as(gtk.Widget).setHexpand(1);
        root.append(taskbar.box.as(gtk.Widget));

        const bar_click = gtk.GestureClick.new();
        bar_click.as(gtk.GestureSingle).setButton(3);
        _ = gtk.GestureClick.signals.pressed.connect(bar_click, *gtk.Box, &onBarRightClick, taskbar.box, .{});
        taskbar.box.as(gtk.Widget).addController(bar_click.as(gtk.EventController));

        // The virtual desktop indicator sits with the other system icons.
        root.append(desktops_box.as(gtk.Widget));

        // Status icons of apps (StatusNotifierItem), left of the clock.
        const tray_box = gtk.Box.new(if (vertical) .vertical else .horizontal, 4);
        tray_box.as(gtk.Widget).addCssClass("dkde-tray");
        tray_box.as(gtk.Widget).setVisible(0);
        root.append(tray_box.as(gtk.Widget));

        // Quick settings: network, sound and battery status, with a flyout.
        const quick_box = gtk.Box.new(if (vertical) .vertical else .horizontal, 0);
        quick_box.as(gtk.Widget).addCssClass("dkde-quick");
        root.append(quick_box.as(gtk.Widget));

        const clock = gtk.Label.new(null);
        clock.as(gtk.Widget).addCssClass("dkde-clock");
        // Only a vertical bar is narrow enough to need the clock to wrap.
        clock.setWrap(@intFromBool(vertical));
        clock.setJustify(.center);
        const clock_left = gtk.GestureClick.new();
        clock_left.as(gtk.GestureSingle).setButton(1);
        _ = gtk.GestureClick.signals.pressed.connect(clock_left, *gtk.Label, &onClockClick, clock, .{});
        clock.as(gtk.Widget).addController(clock_left.as(gtk.EventController));
        const clock_right = gtk.GestureClick.new();
        clock_right.as(gtk.GestureSingle).setButton(3);
        _ = gtk.GestureClick.signals.pressed.connect(clock_right, *gtk.Label, &onClockRightClick, clock, .{});
        clock.as(gtk.Widget).addController(clock_right.as(gtk.EventController));
        root.append(clock.as(gtk.Widget));

        const self = try allocator.create(Bar);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .window = window,
            .root = root,
            .revealer = revealer,
            .clock = clock,
            .taskbar = taskbar,
            .tray_box = tray_box,
            .tray = tray,
            .quick_box = quick_box,
            .quick = quick,
            .desktops_box = desktops_box,
            .position = position,
            .autohide = autohide_on,
            .thickness = thickness,
        };

        surface.setup(window, .{
            .name_space = "dkde-panel",
            .layer = .top,
            .monitor = monitor,
            .anchors = position.anchors(),
            // An auto-hidden bar floats over windows instead of pushing them.
            .exclusive_zone = if (autohide_on) 0 else thickness,
            .size = thickness,
        });
        self.applySize(true);

        if (autohide_on) {
            const motion = gtk.EventControllerMotion.new();
            _ = gtk.EventControllerMotion.signals.enter.connect(motion, *Bar, &onEnter, self, .{});
            _ = gtk.EventControllerMotion.signals.motion.connect(motion, *Bar, &onMotionDbg, self, .{});
            _ = gtk.EventControllerMotion.signals.leave.connect(motion, *Bar, &onLeave, self, .{});
            window.as(gtk.Widget).addController(motion.as(gtk.EventController));
        }
        if (tray) |t| t.addBox(tray_box);
        if (quick) |q| q.addBox(quick_box);
        if (autohide_on) {
            _ = gtk.Widget.signals.map.connect(window, *Bar, &onMap, self, .{});
            self.expanded = false;
            if (glib.getenv("DKDE_KEEP_SHOWN") == null) revealer.setRevealChild(0);
        }
        window.present();
        return self;
    }

    pub fn destroy(self: *Bar) void {
        if (self.hide_source != 0) _ = glib.Source.remove(self.hide_source);
        if (self.tray) |t| t.removeBox(self.tray_box);
        if (self.quick) |q| q.removeBox(self.quick_box);
        // Widgets first: their destroy handlers still use the taskbar's entries.
        self.window.destroy();
        self.taskbar.destroy();
        self.allocator.destroy(self);
    }

    /// An auto-hidden bar stays the same size (see `create`); only the part of it
    /// that is shown changes. While hidden, only a thin strip at the screen edge
    /// takes pointer input, so the transparent rest does not block windows.
    fn applySize(self: *Bar, _: bool) void {
        const t: c_int = self.thickness;
        surface.setSize(self.window, t);
        // The window keeps its size even while the bar inside it is slid away.
        if (self.position.isVertical()) {
            self.window.as(gtk.Widget).setSizeRequest(self.thickness, -1);
        } else {
            self.window.as(gtk.Widget).setSizeRequest(-1, self.thickness);
        }
        if (self.position.isVertical()) {
            self.root.as(gtk.Widget).setSizeRequest(self.thickness, -1);
            if (!surface.isX11()) self.window.setDefaultSize(t, 0);
        } else {
            self.root.as(gtk.Widget).setSizeRequest(-1, self.thickness);
            if (!surface.isX11()) self.window.setDefaultSize(0, t);
        }
    }

    const DesktopClick = struct { workspaces: *Workspaces, index: usize, popover: *gtk.Popover };

    fn onDesktopDestroy(_: *gtk.Button, ctx: *DesktopClick) callconv(.c) void {
        std.heap.c_allocator.destroy(ctx);
    }

    fn onDesktopClicked(_: *gtk.Button, ctx: *DesktopClick) callconv(.c) void {
        ctx.popover.popdown();
        ctx.workspaces.activate(ctx.index);
    }

    /// Mouse wheel over the icon moves to the next or previous desktop.
    fn onDesktopScroll(_: *gtk.EventControllerScroll, _: f64, dy: f64, ws: *Workspaces) callconv(.c) c_int {
        const count = ws.list.items.len;
        const now = ws.activeIndex() orelse return 0;
        if (dy > 0 and now + 1 < count) ws.activate(now + 1);
        if (dy < 0 and now > 0) ws.activate(now - 1);
        return 1;
    }

    fn onDesktopsButton(_: *gtk.Button, popover: *gtk.Popover) callconv(.c) void {
        popover.popup();
    }

    /// One icon for all desktops: it shows the current number, a click opens a
    /// chooser, and the wheel switches.
    pub fn setWorkspaces(self: *Bar, ws: ?*Workspaces) void {
        const box = self.desktops_box;
        const w = ws orelse return box.as(gtk.Widget).setVisible(0);
        box.as(gtk.Widget).setVisible(@intFromBool(w.list.items.len > 1));

        if (self.desktops_popover == null) {
            const button = gtk.Button.new();
            button.as(gtk.Widget).addCssClass("dkde-desktops-button");
            button.setHasFrame(0);
            const content = gtk.Box.new(.horizontal, 5);
            content.append(gtk.Image.newFromIconName("view-grid-symbolic").as(gtk.Widget));
            const label = gtk.Label.new("1");
            content.append(label.as(gtk.Widget));
            button.setChild(content.as(gtk.Widget));
            button.as(gtk.Widget).setTooltipText(common.tr("Virtual desktops"));
            const popover = gtk.Popover.new();
            popover.as(gtk.Widget).addCssClass("dkde-desktops-popover");
            popover.as(gtk.Widget).setParent(button.as(gtk.Widget));
            _ = gtk.Button.signals.clicked.connect(button, *gtk.Popover, &onDesktopsButton, popover, .{});
            box.append(button.as(gtk.Widget));
            const scroll = gtk.EventControllerScroll.new(.{ .vertical = true });
            _ = gtk.EventControllerScroll.signals.scroll.connect(scroll, *Workspaces, &onDesktopScroll, w, .{});
            button.as(gtk.Widget).addController(scroll.as(gtk.EventController));
            self.desktops_scroll = scroll;
            self.desktops_label = label;
            self.desktops_popover = popover;
        }

        // The current number on the icon.
        if (self.desktops_label) |label| {
            var buf: [8]u8 = undefined;
            const active = (w.activeIndex() orelse 0) + 1;
            label.setText(std.fmt.bufPrintSentinel(&buf, "{d}", .{active}, 0) catch "");
        }

        // The chooser: one button per desktop, in rows of five.
        const popover = self.desktops_popover.?;
        const grid = gtk.Grid.new();
        grid.setRowSpacing(4);
        grid.setColumnSpacing(4);
        grid.as(gtk.Widget).setMarginTop(8);
        grid.as(gtk.Widget).setMarginBottom(8);
        grid.as(gtk.Widget).setMarginStart(8);
        grid.as(gtk.Widget).setMarginEnd(8);
        for (w.list.items, 0..) |item, i| {
            var buf: [16]u8 = undefined;
            const text = std.fmt.bufPrintSentinel(&buf, "{d}", .{i + 1}, 0) catch continue;
            const button = gtk.Button.newWithLabel(text);
            button.as(gtk.Widget).addCssClass("dkde-desktop");
            if (item.active) button.as(gtk.Widget).addCssClass("active");
            if (item.urgent) button.as(gtk.Widget).addCssClass("urgent");
            const ctx = std.heap.c_allocator.create(DesktopClick) catch continue;
            ctx.* = .{ .workspaces = w, .index = i, .popover = popover };
            _ = gtk.Button.signals.clicked.connect(button, *DesktopClick, &onDesktopClicked, ctx, .{});
            _ = gtk.Widget.signals.destroy.connect(button, *DesktopClick, &onDesktopDestroy, ctx, .{});
            grid.attach(button.as(gtk.Widget), @intCast(i % 5), @intCast(i / 5), 1, 1);
        }
        popover.setChild(grid.as(gtk.Widget));
    }

    pub fn setThickness(self: *Bar, thickness: c_int) void {
        self.thickness = thickness;
        self.applySize(self.expanded);
        surface.setExclusiveZone(self.window, if (self.autohide) 0 else thickness);
    }

    fn expand(self: *Bar) void {
        if (self.hide_source != 0) {
            _ = glib.Source.remove(self.hide_source);
            self.hide_source = 0;
        }
        if (self.expanded) return;
        self.expanded = true;
        self.revealer.setRevealChild(1);
        self.applyInputRegion();
    }

    fn collapse(self: *Bar) void {
        if (!self.autohide or self.keep_open) return;
        self.expanded = false;
        self.revealer.setRevealChild(0);
        self.applyInputRegion();
    }

    fn dbgSize(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Bar = @ptrCast(@alignCast(data.?));
        std.debug.print("DEBUG later size={d}x{d}\n", .{ self.window.as(gtk.Widget).getWidth(), self.window.as(gtk.Widget).getHeight() });
        self.applyInputRegion();
        return 0;
    }

    fn onMap(_: *gtk.Window, self: *Bar) callconv(.c) void {
        _ = glib.timeoutAdd(600, dbgSize, self);
        self.applyInputRegion();
    }

    fn applyInputRegion(self: *Bar) void {
        std.debug.print("DEBUG region autohide={} expanded={} size={d}x{d}\n", .{ self.autohide, self.expanded, self.window.as(gtk.Widget).getWidth(), self.window.as(gtk.Widget).getHeight() });
        if (!self.autohide) return;
        const native: *gtk.Native = @ptrCast(self.window);
        const gdk_surface = native.getSurface() orelse return;
        if (self.expanded or glib.getenv("DKDE_NO_REGION") != null) return gdk_surface.setInputRegion(null);
        const wide = 32767;
        const t = self.thickness;
        const rect: cairo.RectangleInt = switch (self.position) {
            .bottom => .{ .x = 0, .y = t - sliver, .width = wide, .height = sliver },
            .top => .{ .x = 0, .y = 0, .width = wide, .height = sliver },
            .left => .{ .x = 0, .y = 0, .width = sliver, .height = wide },
            .right => .{ .x = t - sliver, .y = 0, .width = sliver, .height = wide },
        };
        const region = cairo.Region.createRectangle(&rect);
        defer region.destroy();
        gdk_surface.setInputRegion(region);
    }

    /// Called when the start menu closes: an auto-hidden bar may hide again.
    pub fn menuClosed(self: *Bar) void {
        self.keep_open = false;
        if (self.autohide) self.scheduleHide();
    }

    fn scheduleHide(self: *Bar) void {
        if (self.hide_source != 0) return;
        self.hide_source = glib.timeoutAdd(500, onHideTimer, self);
    }

    fn onHideTimer(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Bar = @ptrCast(@alignCast(data.?));
        self.hide_source = 0;
        self.collapse();
        return 0;
    }

    fn onMotionDbg(_: *gtk.EventControllerMotion, x: f64, y: f64, _: *Bar) callconv(.c) void {
        std.debug.print("DEBUG motion {d},{d}\n", .{ x, y });
    }

    fn onEnter(_: *gtk.EventControllerMotion, x: f64, y: f64, self: *Bar) callconv(.c) void {
        std.debug.print("DEBUG enter {d},{d}\n", .{ x, y });
        self.expand();
    }

    fn onLeave(_: *gtk.EventControllerMotion, self: *Bar) callconv(.c) void {
        if (!self.keep_open) self.scheduleHide();
    }

    pub fn setClockText(self: *Bar, text: [:0]const u8) void {
        self.clock.setText(text);
    }
};
