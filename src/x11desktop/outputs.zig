//! Outputs on X11 through RandR 1.3 and up (ai/COMPOSITOR-SPEC.md 6.5): what is
//! connected, its modes, and changes of mode and power. RandR has no
//! per-output scale, so that is not offered. A change is applied the way
//! xrandr does: the affected CRTCs are switched off, the screen is resized to
//! fit, then they are set again.

const std = @import("std");
const c = @import("c");
const desktop = @import("core").desktop;

pub const Outputs = struct {
    allocator: std.mem.Allocator,
    conn: *c.xcb_connection_t,
    root: c.xcb_window_t,
    /// Owns the strings and mode lists of `list`; replaced on every refresh.
    arena: std.heap.ArenaAllocator,
    list: std.ArrayList(desktop.Output) = .empty,
    first_event: u8 = 0,
    present: bool = false,

    pub fn init(allocator: std.mem.Allocator, conn: *c.xcb_connection_t, root: c.xcb_window_t) Outputs {
        var self: Outputs = .{ .allocator = allocator, .conn = conn, .root = root, .arena = .init(allocator) };
        const data = c.xcb_get_extension_data(conn, &c.xcb_randr_id);
        if (data == null or data.?.*.present == 0) return self;
        const v = c.xcb_randr_query_version_reply(conn, c.xcb_randr_query_version(conn, 1, 5), null) orelse return self;
        defer std.c.free(v);
        // Resources and CRTC configuration need 1.2; 1.3 adds the "current" query used here.
        if (v.*.major_version < 1 or (v.*.major_version == 1 and v.*.minor_version < 3)) return self;
        self.present = true;
        self.first_event = data.?.*.first_event;
        // Screen, CRTC and output changes.
        _ = c.xcb_randr_select_input(conn, root, c.XCB_RANDR_NOTIFY_MASK_SCREEN_CHANGE | c.XCB_RANDR_NOTIFY_MASK_CRTC_CHANGE | c.XCB_RANDR_NOTIFY_MASK_OUTPUT_CHANGE);
        self.refresh();
        return self;
    }

    pub fn deinit(self: *Outputs) void {
        self.list.deinit(self.allocator);
        self.arena.deinit();
    }

    /// Whether `response_type` is one of RandR's events.
    pub fn isEvent(self: *const Outputs, response_type: u8) bool {
        return self.present and (response_type & 0x7f) >= self.first_event and (response_type & 0x7f) <= self.first_event + 1;
    }

    fn modeRefresh(m: *const c.xcb_randr_mode_info_t) u32 {
        const total = @as(u64, m.htotal) * m.vtotal;
        if (total == 0) return 0;
        var mhz: u64 = @as(u64, m.dot_clock) * 1000 / total;
        if (m.mode_flags & c.XCB_RANDR_MODE_FLAG_DOUBLE_SCAN != 0) mhz /= 2;
        if (m.mode_flags & c.XCB_RANDR_MODE_FLAG_INTERLACE != 0) mhz *= 2;
        return @intCast(mhz);
    }

    /// Re-reads everything. Strings and mode slices from the last call are freed.
    pub fn refresh(self: *Outputs) void {
        if (!self.present) return;
        self.list.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();

        const res = c.xcb_randr_get_screen_resources_current_reply(self.conn, c.xcb_randr_get_screen_resources_current(self.conn, self.root), null) orelse return;
        defer std.c.free(res);
        const ts = res.*.config_timestamp;
        const outs = c.xcb_randr_get_screen_resources_current_outputs(res)[0..@intCast(c.xcb_randr_get_screen_resources_current_outputs_length(res))];
        const modes = c.xcb_randr_get_screen_resources_current_modes(res)[0..@intCast(c.xcb_randr_get_screen_resources_current_modes_length(res))];

        for (outs) |out| {
            const info = c.xcb_randr_get_output_info_reply(self.conn, c.xcb_randr_get_output_info(self.conn, out, ts), null) orelse continue;
            defer std.c.free(info);
            if (info.*.connection != c.XCB_RANDR_CONNECTION_CONNECTED) continue;

            var o: desktop.Output = .{ .id = out, .enabled = false };
            const name_ptr = c.xcb_randr_get_output_info_name(info);
            o.name = a.dupe(u8, name_ptr[0..@intCast(c.xcb_randr_get_output_info_name_length(info))]) catch continue;
            o.description = o.name;

            // The mode of the CRTC driving it, and where it sits.
            var current_mode: u32 = 0;
            if (info.*.crtc != 0) {
                if (c.xcb_randr_get_crtc_info_reply(self.conn, c.xcb_randr_get_crtc_info(self.conn, info.*.crtc, ts), null)) |crtc| {
                    defer std.c.free(crtc);
                    if (crtc.*.mode != 0) {
                        current_mode = crtc.*.mode;
                        o.enabled = true;
                        o.x = crtc.*.x;
                        o.y = crtc.*.y;
                        o.width = crtc.*.width;
                        o.height = crtc.*.height;
                    }
                }
            }

            const ids = c.xcb_randr_get_output_info_modes(info)[0..@intCast(c.xcb_randr_get_output_info_modes_length(info))];
            const preferred: usize = info.*.num_preferred;
            var list = a.alloc(desktop.Mode, ids.len) catch continue;
            var n: usize = 0;
            for (ids, 0..) |id, i| {
                for (modes) |*m| if (m.id == id) {
                    list[n] = .{ .width = m.width, .height = m.height, .refresh_mhz = modeRefresh(m), .preferred = i < preferred, .current = id == current_mode };
                    if (id == current_mode) o.refresh_mhz = list[n].refresh_mhz;
                    n += 1;
                    break;
                };
            }
            o.modes = list[0..n];
            self.list.append(self.allocator, o) catch {};
        }
    }

    const Plan = struct { out: c.xcb_randr_output_t, crtc: c.xcb_randr_crtc_t, mode: c.xcb_randr_mode_t, x: i32, y: i32, w: u32, h: u32 };

    fn modeId(self: *Outputs, out: c.xcb_randr_output_t, ts: u32, want: desktop.Mode) ?struct { id: u32, w: u32, h: u32 } {
        const info = c.xcb_randr_get_output_info_reply(self.conn, c.xcb_randr_get_output_info(self.conn, out, ts), null) orelse return null;
        defer std.c.free(info);
        const res = c.xcb_randr_get_screen_resources_current_reply(self.conn, c.xcb_randr_get_screen_resources_current(self.conn, self.root), null) orelse return null;
        defer std.c.free(res);
        const modes = c.xcb_randr_get_screen_resources_current_modes(res)[0..@intCast(c.xcb_randr_get_screen_resources_current_modes_length(res))];
        const ids = c.xcb_randr_get_output_info_modes(info)[0..@intCast(c.xcb_randr_get_output_info_modes_length(info))];
        var best: ?struct { id: u32, w: u32, h: u32, hz: u32 } = null;
        for (ids) |id| for (modes) |*m| if (m.id == id and m.width == want.width and m.height == want.height) {
            const hz = modeRefresh(m);
            if (want.refresh_mhz != 0 and hz == want.refresh_mhz) return .{ .id = id, .w = m.width, .h = m.height };
            if (best == null or hz > best.?.hz) best = .{ .id = id, .w = m.width, .h = m.height, .hz = hz };
        };
        if (want.refresh_mhz != 0) return null;
        return if (best) |b| .{ .id = b.id, .w = b.w, .h = b.h } else null;
    }

    /// Applies the edits; returns whether the server accepted all of them.
    pub fn configure(self: *Outputs, edits: []const desktop.OutputEdit) bool {
        if (!self.present) return false;
        // RandR cannot scale an output.
        for (edits) |e| if (e.change.scale) |s| if (s != 1) return false;

        const res = c.xcb_randr_get_screen_resources_current_reply(self.conn, c.xcb_randr_get_screen_resources_current(self.conn, self.root), null) orelse return false;
        defer std.c.free(res);
        const ts = res.*.config_timestamp;
        const now = res.*.timestamp;

        // What each CRTC does now, for the outputs that stay as they are.
        var plans: std.ArrayList(Plan) = .empty;
        defer plans.deinit(self.allocator);
        var disabled: std.ArrayList(c.xcb_randr_crtc_t) = .empty;
        defer disabled.deinit(self.allocator);
        var used_crtcs: std.ArrayList(c.xcb_randr_crtc_t) = .empty;
        defer used_crtcs.deinit(self.allocator);

        for (self.list.items) |o| {
            var edit: ?desktop.OutputChange = null;
            for (edits) |e| if (e.id == o.id) {
                edit = e.change;
            };
            const info = c.xcb_randr_get_output_info_reply(self.conn, c.xcb_randr_get_output_info(self.conn, @intCast(o.id), ts), null) orelse return false;
            defer std.c.free(info);
            const crtc: u32 = info.*.crtc;
            const enabled = edit.?.enabled orelse o.enabled;
            if (edit == null or (edit.?.mode == null and edit.?.enabled == null and edit.?.x == null and edit.?.y == null)) {
                // Untouched: keeps its place, counts toward the screen size.
                if (o.enabled and crtc != 0) {
                    plans.append(self.allocator, .{ .out = @intCast(o.id), .crtc = crtc, .mode = 0, .x = o.x, .y = o.y, .w = o.width, .h = o.height }) catch return false;
                    used_crtcs.append(self.allocator, crtc) catch {};
                }
                continue;
            }
            if (!enabled) {
                if (crtc != 0) disabled.append(self.allocator, crtc) catch return false;
                continue;
            }
            // Enabled with a new mode, or switched on: pick the mode and a free CRTC.
            const want: desktop.Mode = edit.?.mode orelse blk: {
                // Only moved: keep the mode it has.
                for (o.modes) |m| if (m.current) break :blk m;
                for (o.modes) |m| if (m.preferred) break :blk m;
                break :blk if (o.modes.len > 0) o.modes[0] else return false;
            };
            const found = self.modeId(@intCast(o.id), ts, want) orelse return false;
            var use_crtc = crtc;
            if (use_crtc == 0) {
                const possible = c.xcb_randr_get_output_info_crtcs(info)[0..@intCast(c.xcb_randr_get_output_info_crtcs_length(info))];
                for (possible) |p| if (std.mem.indexOfScalar(u32, used_crtcs.items, p) == null) {
                    use_crtc = p;
                    break;
                };
                if (use_crtc == 0) return false;
            }
            used_crtcs.append(self.allocator, use_crtc) catch {};
            // Newly switched on: to the right of what is there.
            var x = o.x;
            if (!o.enabled) {
                x = 0;
                for (self.list.items) |other| if (other.enabled) {
                    x = @max(x, other.x + @as(i32, @intCast(other.width)));
                };
            }
            if (edit.?.x) |ex| x = ex;
            const y = edit.?.y orelse o.y;
            plans.append(self.allocator, .{ .out = @intCast(o.id), .crtc = use_crtc, .mode = found.id, .x = x, .y = y, .w = found.w, .h = found.h }) catch return false;
        }

        // The screen must hold every enabled output.
        var sw: u32 = 0;
        var sh: u32 = 0;
        for (plans.items) |p| {
            sw = @max(sw, @as(u32, @intCast(@max(p.x, 0))) + p.w);
            sh = @max(sh, @as(u32, @intCast(@max(p.y, 0))) + p.h);
        }
        if (plans.items.len == 0) return false; // never switch every screen off from here

        // 1. Everything that changes is switched off first, so the new size is never smaller than a live CRTC.
        for (disabled.items) |crtc| _ = c.xcb_randr_set_crtc_config(self.conn, crtc, 0, ts, 0, 0, 0, c.XCB_RANDR_ROTATION_ROTATE_0, 0, null);
        for (plans.items) |p| if (p.mode != 0) {
            _ = c.xcb_randr_set_crtc_config(self.conn, p.crtc, 0, ts, 0, 0, 0, c.XCB_RANDR_ROTATION_ROTATE_0, 0, null);
        };
        // 2. The screen size, with the millimetres of a typical 96 dpi display.
        _ = c.xcb_randr_set_screen_size(self.conn, self.root, @intCast(sw), @intCast(sh), @intCast(sw * 254 / 960), @intCast(sh * 254 / 960));
        // 3. The CRTCs that carry a changed output.
        var ok = true;
        for (plans.items) |p| if (p.mode != 0) {
            const out = [_]c.xcb_randr_output_t{p.out};
            const r = c.xcb_randr_set_crtc_config_reply(self.conn, c.xcb_randr_set_crtc_config(self.conn, p.crtc, now, ts, @intCast(p.x), @intCast(p.y), p.mode, c.XCB_RANDR_ROTATION_ROTATE_0, 1, &out), null);
            if (r) |reply| {
                if (reply.*.status != c.XCB_RANDR_SET_CONFIG_SUCCESS) ok = false;
                std.c.free(reply);
            } else ok = false;
        };
        _ = c.xcb_flush(self.conn);
        self.refresh();
        return ok;
    }
};
