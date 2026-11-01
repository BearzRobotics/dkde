//! KMS through the DRM ioctls, without libdrm (SPEC.md 5.11, *Display*).
//! The structures are the kernel's `drm.h` and `drm_mode.h`. Rendering is on
//! the CPU into two dumb buffers that are swapped with page flips, so this
//! works with any kernel DRM driver, `simpledrm` included.

const std = @import("std");
const sys = @import("sys.zig");

const log = std.log.scoped(.drm);

// ---- ioctl numbers ----------------------------------------------------------

const IOC_NONE = 0;
const IOC_WRITE = 1;
const IOC_READ = 2;

fn ioc(dir: u32, nr: u32, size: u32) c_ulong {
    return (@as(c_ulong, dir) << 30) | (@as(c_ulong, size) << 16) | (@as(c_ulong, 'd') << 8) | nr;
}
fn iowr(nr: u32, comptime T: type) c_ulong {
    return ioc(IOC_READ | IOC_WRITE, nr, @sizeOf(T));
}

pub const ModeInfo = extern struct {
    clock: u32,
    hdisplay: u16,
    hsync_start: u16,
    hsync_end: u16,
    htotal: u16,
    hskew: u16,
    vdisplay: u16,
    vsync_start: u16,
    vsync_end: u16,
    vtotal: u16,
    vscan: u16,
    vrefresh: u32,
    flags: u32,
    type: u32,
    name: [32]u8,
};

const CardRes = extern struct {
    fb_id_ptr: u64 = 0,
    crtc_id_ptr: u64 = 0,
    connector_id_ptr: u64 = 0,
    encoder_id_ptr: u64 = 0,
    count_fbs: u32 = 0,
    count_crtcs: u32 = 0,
    count_connectors: u32 = 0,
    count_encoders: u32 = 0,
    min_width: u32 = 0,
    max_width: u32 = 0,
    min_height: u32 = 0,
    max_height: u32 = 0,
};

const GetConnector = extern struct {
    encoders_ptr: u64 = 0,
    modes_ptr: u64 = 0,
    props_ptr: u64 = 0,
    prop_values_ptr: u64 = 0,
    count_modes: u32 = 0,
    count_props: u32 = 0,
    count_encoders: u32 = 0,
    encoder_id: u32 = 0,
    connector_id: u32 = 0,
    connector_type: u32 = 0,
    connector_type_id: u32 = 0,
    connection: u32 = 0,
    mm_width: u32 = 0,
    mm_height: u32 = 0,
    subpixel: u32 = 0,
    pad: u32 = 0,
};

const GetEncoder = extern struct {
    encoder_id: u32,
    encoder_type: u32 = 0,
    crtc_id: u32 = 0,
    possible_crtcs: u32 = 0,
    possible_clones: u32 = 0,
};

const Crtc = extern struct {
    set_connectors_ptr: u64 = 0,
    count_connectors: u32 = 0,
    crtc_id: u32 = 0,
    fb_id: u32 = 0,
    x: u32 = 0,
    y: u32 = 0,
    gamma_size: u32 = 0,
    mode_valid: u32 = 0,
    mode: ModeInfo = std.mem.zeroes(ModeInfo),
};

const CreateDumb = extern struct { height: u32, width: u32, bpp: u32, flags: u32 = 0, handle: u32 = 0, pitch: u32 = 0, size: u64 = 0 };
const MapDumb = extern struct { handle: u32, pad: u32 = 0, offset: u64 = 0 };
const DestroyDumb = extern struct { handle: u32 };
const FbCmd2 = extern struct {
    fb_id: u32 = 0,
    width: u32,
    height: u32,
    pixel_format: u32,
    flags: u32 = 0,
    handles: [4]u32 = @splat(0),
    pitches: [4]u32 = @splat(0),
    offsets: [4]u32 = @splat(0),
    modifier: [4]u64 = @splat(0),
};
const PageFlip = extern struct { crtc_id: u32, fb_id: u32, flags: u32, reserved: u32 = 0, user_data: u64 = 0 };
const GetCap = extern struct { capability: u64, value: u64 = 0 };
const Event = extern struct { type: u32, length: u32 };

const IOCTL_GET_CAP = iowr(0x0c, GetCap);
const IOCTL_SET_MASTER = ioc(IOC_NONE, 0x1e, 0);
const IOCTL_DROP_MASTER = ioc(IOC_NONE, 0x1f, 0);
const IOCTL_GETRESOURCES = iowr(0xA0, CardRes);
const IOCTL_GETCRTC = iowr(0xA1, Crtc);
const IOCTL_SETCRTC = iowr(0xA2, Crtc);
const IOCTL_GETENCODER = iowr(0xA6, GetEncoder);
const IOCTL_GETCONNECTOR = iowr(0xA7, GetConnector);
const IOCTL_RMFB = iowr(0xAF, c_uint);
const IOCTL_PAGE_FLIP = iowr(0xB0, PageFlip);
const IOCTL_CREATE_DUMB = iowr(0xB2, CreateDumb);
const IOCTL_MAP_DUMB = iowr(0xB3, MapDumb);
const IOCTL_DESTROY_DUMB = iowr(0xB4, DestroyDumb);
const IOCTL_ADDFB2 = iowr(0xB8, FbCmd2);

const DRM_CAP_DUMB_BUFFER = 1;
const DRM_MODE_CONNECTED = 1;
const DRM_MODE_TYPE_PREFERRED = 1 << 3;
const DRM_MODE_FLAG_INTERLACE = 1 << 4;
const DRM_MODE_FLAG_DBLSCAN = 1 << 5;
const DRM_MODE_PAGE_FLIP_EVENT = 1;
const DRM_EVENT_FLIP_COMPLETE = 2;
const FOURCC_XRGB8888: u32 = 0x34325258; // 'X' 'R' '2' '4'

extern fn mmap(addr: ?*anyopaque, len: usize, prot: c_int, flags: c_int, fd: c_int, offset: i64) ?*anyopaque;
extern fn munmap(addr: *anyopaque, len: usize) c_int;
const PROT_READ = 1;
const PROT_WRITE = 2;
const MAP_SHARED = 1;

/// ioctl that retries when interrupted.
fn call(fd: c_int, request: c_ulong, arg: anytype) bool {
    while (true) {
        const r = if (@typeInfo(@TypeOf(arg)) == .null) sys.ioctl(fd, request) else sys.ioctl(fd, request, arg);
        if (r == 0) return true;
        if (sys.errno() == sys.EINTR) continue;
        return false;
    }
}

// ---- the device ---------------------------------------------------------------

pub const Output = struct {
    connector_id: u32,
    crtc_id: u32,
    mode: ModeInfo,
    mm_width: u32,
    mm_height: u32,

    pub fn width(self: Output) u32 {
        return self.mode.hdisplay;
    }
    pub fn height(self: Output) u32 {
        return self.mode.vdisplay;
    }
};

pub const Buffer = struct {
    handle: u32,
    fb_id: u32,
    pitch: u32,
    size: usize,
    width: u32,
    height: u32,
    pixels: []align(4096) u8,

    pub fn row(self: *const Buffer, y: u32) []u32 {
        const bytes = self.pixels[@as(usize, y) * self.pitch ..][0 .. self.width * 4];
        return @alignCast(std.mem.bytesAsSlice(u32, bytes));
    }
};

pub const Device = struct {
    fd: c_int,
    master: bool = false,

    pub const Error = error{ NoDevice, NoDumbBuffers, NoOutput, ModeSetFailed, OutOfMemory, BufferFailed };

    /// Open the first /dev/dri/cardN that has a connected display.
    pub fn openFirst(allocator: std.mem.Allocator) Error!Device {
        var best: ?Device = null;
        var n: u32 = 0;
        while (n < 8) : (n += 1) {
            var pb: [32]u8 = undefined;
            const path = std.fmt.bufPrintSentinel(&pb, "/dev/dri/card{d}", .{n}, 0) catch continue;
            const fd = sys.open(path.ptr, sys.O_RDWR | sys.O_CLOEXEC);
            if (fd < 0) {
                if (sys.errno() != 2) log.warn("{s}: cannot open (errno {d})", .{ path, sys.errno() });
                continue;
            }
            var dev: Device = .{ .fd = fd };
            var cap: GetCap = .{ .capability = DRM_CAP_DUMB_BUFFER };
            if (!call(fd, IOCTL_GET_CAP, &cap) or cap.value == 0) {
                log.info("{s}: no dumb buffers, skipped", .{path});
                _ = sys.close(fd);
                continue;
            }
            dev.setMaster();
            if (dev.probe(allocator)) |_| {
                log.info("{s}: in use", .{path});
                if (best) |old| _ = sys.close(old.fd);
                return dev;
            } else |e| {
                log.info("{s}: no usable output ({s})", .{ path, @errorName(e) });
                // No display on this card (a render-only or empty GPU).
                if (best == null) best = dev else _ = sys.close(fd);
            }
        }
        if (best) |b| _ = sys.close(b.fd);
        return error.NoDevice;
    }

    pub fn close(self: *Device) void {
        self.dropMaster();
        _ = sys.close(self.fd);
        self.fd = -1;
    }

    pub fn setMaster(self: *Device) void {
        self.master = call(self.fd, IOCTL_SET_MASTER, null);
    }

    pub fn dropMaster(self: *Device) void {
        if (call(self.fd, IOCTL_DROP_MASTER, null)) self.master = false;
    }

    /// Find the first connected connector, its preferred mode and a CRTC for it.
    pub fn probe(self: *Device, allocator: std.mem.Allocator) Error!Output {
        var res: CardRes = .{};
        if (!call(self.fd, IOCTL_GETRESOURCES, &res)) return error.NoOutput;
        const connectors = try allocator.alloc(u32, res.count_connectors);
        defer allocator.free(connectors);
        const crtcs = try allocator.alloc(u32, res.count_crtcs);
        defer allocator.free(crtcs);
        const encoders = try allocator.alloc(u32, res.count_encoders);
        defer allocator.free(encoders);
        res = .{
            .connector_id_ptr = @intFromPtr(connectors.ptr),
            .crtc_id_ptr = @intFromPtr(crtcs.ptr),
            .encoder_id_ptr = @intFromPtr(encoders.ptr),
            .count_connectors = res.count_connectors,
            .count_crtcs = res.count_crtcs,
            .count_encoders = res.count_encoders,
        };
        if (!call(self.fd, IOCTL_GETRESOURCES, &res)) return error.NoOutput;

        for (connectors[0..@min(res.count_connectors, connectors.len)]) |cid| {
            var c: GetConnector = .{ .connector_id = cid };
            if (!call(self.fd, IOCTL_GETCONNECTOR, &c)) continue;
            if (c.connection != DRM_MODE_CONNECTED or c.count_modes == 0) continue;

            const modes = try allocator.alloc(ModeInfo, c.count_modes);
            defer allocator.free(modes);
            const conn_encoders = try allocator.alloc(u32, c.count_encoders);
            defer allocator.free(conn_encoders);
            var c2: GetConnector = .{
                .connector_id = cid,
                .modes_ptr = @intFromPtr(modes.ptr),
                .encoders_ptr = @intFromPtr(conn_encoders.ptr),
                .count_modes = c.count_modes,
                .count_encoders = c.count_encoders,
            };
            if (!call(self.fd, IOCTL_GETCONNECTOR, &c2)) continue;
            const mode = pickMode(modes[0..@min(c2.count_modes, modes.len)]) orelse continue;
            const crtc = self.pickCrtc(c2.encoder_id, conn_encoders[0..@min(c2.count_encoders, conn_encoders.len)], crtcs[0..@min(res.count_crtcs, crtcs.len)]) orelse continue;
            return .{ .connector_id = cid, .crtc_id = crtc, .mode = mode, .mm_width = c2.mm_width, .mm_height = c2.mm_height };
        }
        return error.NoOutput;
    }

    fn pickCrtc(self: *Device, current_encoder: u32, conn_encoders: []const u32, crtcs: []const u32) ?u32 {
        // The CRTC already driving the connector keeps it, so there is no flicker.
        if (current_encoder != 0) {
            var e: GetEncoder = .{ .encoder_id = current_encoder };
            if (call(self.fd, IOCTL_GETENCODER, &e) and e.crtc_id != 0) return e.crtc_id;
        }
        for (conn_encoders) |eid| {
            var e: GetEncoder = .{ .encoder_id = eid };
            if (!call(self.fd, IOCTL_GETENCODER, &e)) continue;
            for (crtcs, 0..) |cid, i| {
                if (i < 32 and e.possible_crtcs & (@as(u32, 1) << @intCast(i)) != 0) return cid;
            }
        }
        return null;
    }

    pub fn createBuffer(self: *Device, width: u32, height: u32) Error!Buffer {
        var cd: CreateDumb = .{ .width = width, .height = height, .bpp = 32 };
        if (!call(self.fd, IOCTL_CREATE_DUMB, &cd)) return error.BufferFailed;
        errdefer _ = call(self.fd, IOCTL_DESTROY_DUMB, &DestroyDumb{ .handle = cd.handle });

        var fb: FbCmd2 = .{ .width = width, .height = height, .pixel_format = FOURCC_XRGB8888 };
        fb.handles[0] = cd.handle;
        fb.pitches[0] = cd.pitch;
        if (!call(self.fd, IOCTL_ADDFB2, &fb)) return error.BufferFailed;
        errdefer {
            var id: c_uint = fb.fb_id;
            _ = call(self.fd, IOCTL_RMFB, &id);
        }

        var md: MapDumb = .{ .handle = cd.handle };
        if (!call(self.fd, IOCTL_MAP_DUMB, &md)) return error.BufferFailed;
        const p = mmap(null, @intCast(cd.size), PROT_READ | PROT_WRITE, MAP_SHARED, self.fd, @intCast(md.offset));
        if (p == null or @intFromPtr(p) == std.math.maxInt(usize)) return error.BufferFailed;
        const bytes: [*]align(4096) u8 = @ptrCast(@alignCast(p.?));
        @memset(bytes[0..@intCast(cd.size)], 0);
        return .{
            .handle = cd.handle,
            .fb_id = fb.fb_id,
            .pitch = cd.pitch,
            .size = @intCast(cd.size),
            .width = width,
            .height = height,
            .pixels = bytes[0..@intCast(cd.size)],
        };
    }

    pub fn destroyBuffer(self: *Device, b: *Buffer) void {
        _ = munmap(@ptrCast(b.pixels.ptr), b.size);
        var id: c_uint = b.fb_id;
        _ = call(self.fd, IOCTL_RMFB, &id);
        _ = call(self.fd, IOCTL_DESTROY_DUMB, &DestroyDumb{ .handle = b.handle });
    }

    /// Show `fb` on the output with a full mode set.
    pub fn setMode(self: *Device, out: *const Output, b: *const Buffer) Error!void {
        var conn = out.connector_id;
        var crtc: Crtc = .{
            .set_connectors_ptr = @intFromPtr(&conn),
            .count_connectors = 1,
            .crtc_id = out.crtc_id,
            .fb_id = b.fb_id,
            .mode_valid = 1,
            .mode = out.mode,
        };
        if (!call(self.fd, IOCTL_SETCRTC, &crtc)) return error.ModeSetFailed;
    }

    /// Queue a flip to `b`; completion arrives as an event on the fd.
    pub fn flip(self: *Device, out: *const Output, b: *const Buffer) bool {
        return call(self.fd, IOCTL_PAGE_FLIP, &PageFlip{ .crtc_id = out.crtc_id, .fb_id = b.fb_id, .flags = DRM_MODE_PAGE_FLIP_EVENT });
    }

    /// Read the pending events. Returns how many flips completed.
    pub fn readEvents(self: *Device) u32 {
        var buf: [1024]u8 align(8) = undefined;
        const n = sys.read(self.fd, &buf, buf.len);
        if (n <= 0) return 0;
        var done: u32 = 0;
        var off: usize = 0;
        const total: usize = @intCast(n);
        while (off + @sizeOf(Event) <= total) {
            const ev: *const Event = @ptrCast(@alignCast(&buf[off]));
            if (ev.length < @sizeOf(Event)) break;
            if (ev.type == DRM_EVENT_FLIP_COMPLETE) done += 1;
            off += ev.length;
        }
        return done;
    }
};

/// The preferred mode, else the largest progressive one.
pub fn pickMode(modes: []const ModeInfo) ?ModeInfo {
    var best: ?ModeInfo = null;
    for (modes) |m| {
        if (m.flags & (DRM_MODE_FLAG_INTERLACE | DRM_MODE_FLAG_DBLSCAN) != 0) continue;
        if (m.type & DRM_MODE_TYPE_PREFERRED != 0) return m;
        if (best == null or @as(u32, m.hdisplay) * m.vdisplay > @as(u32, best.?.hdisplay) * best.?.vdisplay) best = m;
    }
    return best orelse if (modes.len > 0) modes[0] else null;
}

/// Pick the built-in font height (16, 24 or 32) for a screen (SPEC.md 5.11,
/// *Fonts*): about the same physical size everywhere, never below 80x24 cells.
pub fn chooseFontHeight(width_px: u32, height_px: u32, mm_height: u32) u32 {
    const sizes = [_]u32{ 32, 24, 16 };
    var want: u32 = 16;
    if (mm_height >= 50 and mm_height <= 2000) {
        // Aim for a cell about 4.7 mm tall, within a quarter of a step.
        const px_per_mm = @as(f32, @floatFromInt(height_px)) / @as(f32, @floatFromInt(mm_height));
        const target = px_per_mm * 4.7;
        want = 16;
        for (sizes) |s| {
            if (@as(f32, @floatFromInt(s)) <= target * 1.15) {
                want = s;
                break;
            }
        }
    } else {
        // Unknown size (virtual machines, simpledrm): go by resolution.
        want = if (height_px >= 2000) 32 else if (height_px >= 1300) 24 else 16;
    }
    // Keep at least 80x24 cells: the cell is half as wide as it is tall.
    for (sizes) |s| {
        if (s > want) continue;
        if (width_px / (s / 2) >= 80 and height_px / s >= 24) return s;
    }
    return 16;
}

const testing = std.testing;

test "ioctl numbers match the kernel headers" {
    // Values computed from drm.h: DRM_IOWR(0xA0, struct drm_mode_card_res) etc.
    try testing.expectEqual(@as(c_ulong, 0xC04064A0), IOCTL_GETRESOURCES);
    try testing.expectEqual(@as(c_ulong, 0xC05064A7), IOCTL_GETCONNECTOR);
    try testing.expectEqual(@as(c_ulong, 0xC02064B2), IOCTL_CREATE_DUMB);
    try testing.expectEqual(@as(c_ulong, 0x0000641E), IOCTL_SET_MASTER);
    try testing.expectEqual(@as(c_ulong, 0xC01864B0), IOCTL_PAGE_FLIP);
}

test "structure sizes match the kernel" {
    try testing.expectEqual(@as(usize, 68), @sizeOf(ModeInfo));
    try testing.expectEqual(@as(usize, 104), @sizeOf(Crtc));
    try testing.expectEqual(@as(usize, 80), @sizeOf(GetConnector));
    try testing.expectEqual(@as(usize, 64), @sizeOf(CardRes));
    try testing.expectEqual(@as(usize, 104), @sizeOf(FbCmd2));
}

test "font height follows physical size and keeps 80x24" {
    // 24-inch 1080p: about 3.6 px/mm -> 17 px target -> 16.
    try testing.expectEqual(@as(u32, 16), chooseFontHeight(1920, 1080, 300));
    // 14-inch 4K laptop: about 14 px/mm... -> larger.
    try testing.expectEqual(@as(u32, 32), chooseFontHeight(3840, 2160, 180));
    // Unknown size, 1366x768.
    try testing.expectEqual(@as(u32, 16), chooseFontHeight(1366, 768, 0));
    // 640x480 can only hold 16 and still have 80 columns (640 / 8).
    try testing.expectEqual(@as(u32, 16), chooseFontHeight(640, 480, 0));
    try testing.expectEqual(@as(u32, 16), chooseFontHeight(800, 480, 100));
}

test "preferred mode wins, interlaced is skipped" {
    var a = std.mem.zeroes(ModeInfo);
    a.hdisplay = 1920;
    a.vdisplay = 1080;
    var b = a;
    b.hdisplay = 1024;
    b.vdisplay = 768;
    b.type = DRM_MODE_TYPE_PREFERRED;
    var c = a;
    c.hdisplay = 3840;
    c.vdisplay = 2160;
    c.flags = DRM_MODE_FLAG_INTERLACE;
    try testing.expectEqual(@as(u16, 1024), pickMode(&.{ a, c, b }).?.hdisplay);
    try testing.expectEqual(@as(u16, 1920), pickMode(&.{ a, c }).?.hdisplay);
}
