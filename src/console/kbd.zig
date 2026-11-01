//! The kernel's own keymap (SPEC.md 5.11, *Input*): the table `loadkeys`
//! loaded, read back with `KDGKBENT` and `KDGKBDIACRUC`, and the small state
//! machine the kernel's keyboard driver runs (shift state, Caps Lock, Num Lock,
//! dead keys), so the console types what `loadkeys` says it should. No xkbcommon.
//!
//! The decoder produces the text of a key press; the program sees it through
//! libghostty-vt's key encoder, which also gets the physical key and the
//! modifiers. Function, cursor and keypad keys are sent as physical keys.

const std = @import("std");
const sys = @import("sys.zig");

// linux/keyboard.h
const KT_LATIN = 0;
const KT_SPEC = 2;
const KT_PAD = 3;
const KT_DEAD = 4;
const KT_SHIFT = 7;
const KT_META = 8;
const KT_LETTER = 11;
const KT_DEAD2 = 13;
const NR_TYPES = 15;

const KG_SHIFT = 0;
const KG_ALTGR = 1;
const KG_CTRL = 2;
const KG_ALT = 3;
const KG_SHIFTL = 4;
const KG_SHIFTR = 5;
const KG_CTRLL = 6;
const KG_CTRLR = 7;
const NR_SHIFT = 9;

const K_HOLE: u16 = 0x0200;
const K_NOSUCHMAP: u16 = 0x027F;
const K_CAPS: u16 = 0x0207;
const K_NUM: u16 = 0x0208;
const K_BARENUMLOCK: u16 = 0x0213;

const KDGKBENT: c_ulong = 0x4B46;
const KDGKBDIACRUC: c_ulong = 0x4BFA;

pub const Diacr = extern struct { diacr: u32, base: u32, result: u32 };
const DiacrTable = extern struct { count: c_uint, entries: [256]Diacr };
const KbEntry = extern struct { table: u8, index: u8, value: u16 };

/// evdev codes the decoder needs to know.
const KEY_LEFTMETA = 125;
const KEY_RIGHTMETA = 126;

/// Entries are stored as the ioctl returns them, in `loadkeys` form: the high
/// byte is the type (0-14), or the value is `0xF000 ^ code point` for a
/// Unicode character outside that range.
pub const Keymap = struct {
    allocator: std.mem.Allocator,
    tables: [256]?*[256]u16 = @splat(null),
    diacr: []Diacr = &.{},

    pub fn init(allocator: std.mem.Allocator) Keymap {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Keymap) void {
        for (self.tables) |t| if (t) |p| self.allocator.destroy(p);
        self.allocator.free(self.diacr);
        self.* = init(self.allocator);
    }

    /// Read the keymap the kernel holds for the console on `fd`. A table that
    /// cannot be read is left out; an empty keymap still types nothing
    /// harmful, so this never fails except for memory.
    pub fn load(allocator: std.mem.Allocator, fd: c_int) !Keymap {
        var km = init(allocator);
        errdefer km.deinit();
        for (0..256) |t| {
            var first = KbEntry{ .table = @intCast(t), .index = 0, .value = 0 };
            if (sys.ioctl(fd, KDGKBENT, &first) != 0) continue;
            if (first.value == K_NOSUCHMAP) continue;
            const table = try allocator.create([256]u16);
            errdefer allocator.destroy(table);
            for (0..256) |i| {
                var e = KbEntry{ .table = @intCast(t), .index = @intCast(i), .value = 0 };
                table[i] = if (sys.ioctl(fd, KDGKBENT, &e) == 0) e.value else K_HOLE;
            }
            km.tables[t] = table;
        }
        var dt: DiacrTable = undefined;
        if (sys.ioctl(fd, KDGKBDIACRUC, &dt) == 0 and dt.count <= 256) {
            km.diacr = try allocator.dupe(Diacr, dt.entries[0..dt.count]);
        }
        return km;
    }

    pub fn get(self: *const Keymap, table: usize, code: u32) u16 {
        if (table >= 256 or code >= 256) return K_HOLE;
        const t = self.tables[table] orelse return K_HOLE;
        return t[code];
    }

    fn compose(self: *const Keymap, diacr: u32, base: u32) ?u32 {
        for (self.diacr) |d| if (d.diacr == diacr and d.base == base) return d.result;
        return null;
    }
};

pub const Action = enum { press, repeat, release };

/// What a key event came to. `text` is what the key types (empty for keys that
/// type nothing, and for releases).
pub const Event = struct {
    code: u16,
    action: Action,
    text: [16]u8 = undefined,
    text_len: u8 = 0,
    /// The character the key types with no shift held; 0 if none.
    unshifted: u21 = 0,
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,

    pub fn textSlice(self: *const Event) []const u8 {
        return self.text[0..self.text_len];
    }
};

pub const Decoder = struct {
    km: *const Keymap,
    held: [NR_SHIFT]u8 = @splat(0),
    meta_left: bool = false,
    meta_right: bool = false,
    caps: bool = false,
    num: bool = false,
    /// The pending dead key's diacritic, as a code point.
    dead: ?u32 = null,

    pub fn init(km: *const Keymap) Decoder {
        return .{ .km = km };
    }

    /// Release everything: used when the VT is left, so a key still held then
    /// does not stay stuck.
    pub fn reset(self: *Decoder) void {
        self.held = @splat(0);
        self.meta_left = false;
        self.meta_right = false;
        self.dead = null;
    }

    fn shiftIndex(self: *const Decoder) usize {
        var idx: usize = 0;
        inline for (.{ KG_SHIFT, KG_ALTGR, KG_SHIFTL, KG_SHIFTR }) |bit| {
            if (self.held[bit] > 0) idx |= @as(usize, 1) << bit;
        }
        return idx;
    }

    fn shiftHeld(self: *const Decoder) bool {
        return self.held[KG_SHIFT] > 0 or self.held[KG_SHIFTL] > 0 or self.held[KG_SHIFTR] > 0;
    }

    /// Feed one `EV_KEY` event (`value` 0 release, 1 press, 2 repeat).
    pub fn feed(self: *Decoder, code: u16, value: i32) Event {
        const action: Action = switch (value) {
            0 => .release,
            2 => .repeat,
            else => .press,
        };
        const plain = self.km.get(0, code);

        // Modifier bookkeeping happens on press and release only.
        if (code == KEY_LEFTMETA) self.meta_left = action != .release;
        if (code == KEY_RIGHTMETA) self.meta_right = action != .release;
        if (plain >> 8 == KT_SHIFT and (plain & 0xff) < NR_SHIFT and action != .repeat) {
            const bit = plain & 0xff;
            if (action == .press) {
                self.held[bit] +|= 1;
            } else if (self.held[bit] > 0) self.held[bit] -= 1;
        }
        if (action == .press) {
            if (plain == K_CAPS) self.caps = !self.caps;
            if (plain == K_NUM or plain == K_BARENUMLOCK) self.num = !self.num;
        }

        var ev: Event = .{
            .code = code,
            .action = action,
            .shift = self.shiftHeld(),
            .ctrl = self.held[KG_CTRL] > 0 or self.held[KG_CTRLL] > 0 or self.held[KG_CTRLR] > 0,
            .alt = self.held[KG_ALT] > 0,
            .super = self.meta_left or self.meta_right,
            .caps_lock = self.caps,
            .num_lock = self.num,
        };
        if (action == .release) return ev;

        ev.unshifted = self.charOf(0, plain, false) orelse 0;
        const shifted = self.km.get(self.shiftIndex(), code);
        if (self.charOf(self.shiftIndex(), shifted, true)) |cp| {
            self.emit(&ev, cp);
        } else if (self.deadOf(shifted)) |diacr| {
            if (action == .press) self.startDead(&ev, diacr);
        }
        return ev;
    }

    /// The character an entry types, or null if it types none (modifier,
    /// function key, dead key, hole...). `letter_caps` applies Caps Lock to
    /// KT_LETTER entries by re-reading the table with Shift flipped.
    fn charOf(self: *const Decoder, table: usize, value: u16, letter_caps: bool) ?u21 {
        _ = table;
        const t = value >> 8;
        if (t >= NR_TYPES) return unicode(value ^ 0xF000);
        switch (t) {
            KT_LATIN => return if (value & 0xff == 0) null else @intCast(value & 0xff),
            KT_LETTER => {
                const c: u21 = @intCast(value & 0xff);
                if (c == 0) return null;
                if (letter_caps and self.caps) return flipCase(c);
                return c;
            },
            KT_PAD => {
                if (!self.num) return null;
                const pad = "0123456789+-*/\r,.?()#";
                const i = value & 0xff;
                return if (i < pad.len) pad[i] else null;
            },
            else => return null,
        }
    }

    fn unicode(v: u16) ?u21 {
        return if (v < 0x20 or v == 0x7f) null else @intCast(v);
    }

    fn flipCase(c: u21) u21 {
        // Latin-1 and the Basic Latin letters, which is all KT_LETTER holds in
        // an 8-bit keymap. Unicode letters come as full code points and are
        // looked up through the Shift table by the kernel; here ASCII suffices.
        if (c >= 'a' and c <= 'z') return c - 32;
        if (c >= 'A' and c <= 'Z') return c + 32;
        if (c >= 0xE0 and c <= 0xFE and c != 0xF7) return c - 32;
        if (c >= 0xC0 and c <= 0xDE and c != 0xD7) return c + 32;
        return c;
    }

    fn deadOf(self: *const Decoder, value: u16) ?u32 {
        _ = self;
        const t = value >> 8;
        if (t == KT_DEAD) {
            const ret = "`'^~\",";
            const i = value & 0xff;
            return if (i < ret.len) ret[i] else null;
        }
        if (t == KT_DEAD2) return value & 0xff;
        return null;
    }

    fn startDead(self: *Decoder, ev: *Event, diacr: u32) void {
        if (self.dead) |pending| {
            // Two dead keys in a row type the first one's accent itself.
            self.dead = null;
            if (pending == diacr) self.emit(ev, @intCast(pending));
            return;
        }
        self.dead = diacr;
    }

    fn emit(self: *Decoder, ev: *Event, cp: u21) void {
        var n: usize = 0;
        if (self.dead) |diacr| {
            self.dead = null;
            if (cp == ' ') {
                n += encode(ev.text[n..], @intCast(diacr));
            } else if (self.km.compose(diacr, cp)) |res| {
                n += encode(ev.text[n..], @intCast(res));
            } else {
                n += encode(ev.text[n..], @intCast(diacr));
                n += encode(ev.text[n..], cp);
            }
        } else n += encode(ev.text[n..], cp);
        ev.text_len = @intCast(n);
    }

    fn encode(buf: []u8, cp: u21) usize {
        return std.unicode.utf8Encode(cp, buf) catch 0;
    }
};

/// Whether the key switches to another VT (Ctrl+Alt+F1..F12): returns the VT.
pub fn vtSwitch(ev: *const Event) ?u32 {
    if (ev.action != .press or !ev.ctrl or !ev.alt) return null;
    return switch (ev.code) {
        59...68 => ev.code - 59 + 1, // KEY_F1..KEY_F10
        87 => 11, // KEY_F11
        88 => 12, // KEY_F12
        else => null,
    };
}

// ---- tests ---------------------------------------------------------------

const testing = std.testing;

fn K(t: u16, v: u16) u16 {
    return (t << 8) | v;
}

/// A tiny US-like keymap: Esc is 1, 'a' is 30, left Shift 42, left Ctrl 29,
/// left Alt 56, Caps 58, '1' is 2, numpad 7 is 71, Num 69, 'e' 18, dead acute
/// on 40 (apostrophe key), dead tilde on 41, space 57, AltGr 100.
fn testKeymap(a: std.mem.Allocator) !Keymap {
    var km = Keymap.init(a);
    errdefer km.deinit();
    for ([_]usize{ 0, 1, 2, 3 }) |t| {
        const tab = try a.create([256]u16);
        tab.* = @splat(K(KT_SPEC, 0));
        km.tables[t] = tab;
    }
    const t0 = km.tables[0].?;
    const t1 = km.tables[1].?; // shift
    const t2 = km.tables[2].?; // altgr
    t0[30] = K(KT_LETTER, 'a');
    t1[30] = K(KT_LETTER, 'A');
    t0[18] = K(KT_LETTER, 'e');
    t1[18] = K(KT_LETTER, 'E');
    t0[2] = K(KT_LATIN, '1');
    t1[2] = K(KT_LATIN, '!');
    t2[2] = 0xF000 ^ 0x00B9; // U+00B9 superscript one, as a Unicode entry
    t0[57] = K(KT_LATIN, ' ');
    t1[57] = K(KT_LATIN, ' ');
    t0[42] = K(KT_SHIFT, KG_SHIFT);
    t0[29] = K(KT_SHIFT, KG_CTRL);
    t0[56] = K(KT_SHIFT, KG_ALT);
    t0[100] = K(KT_SHIFT, KG_ALTGR);
    t0[58] = K_CAPS;
    t0[69] = K_NUM;
    t0[71] = K(KT_PAD, 7);
    t0[40] = K(KT_DEAD, 1); // acute
    t1[40] = K(KT_DEAD, 4); // diaeresis on Shift
    t0[41] = K(KT_DEAD, 3); // tilde
    km.diacr = try a.dupe(Diacr, &.{
        .{ .diacr = '\'', .base = 'e', .result = 0xE9 },
        .{ .diacr = '"', .base = 'e', .result = 0xEB },
    });
    return km;
}

fn typed(d: *Decoder, code: u16) []const u8 {
    const ev = d.feed(code, 1);
    _ = d.feed(code, 0);
    // The text is copied out of the stack event before it goes away.
    const S = struct {
        var buf: [16]u8 = undefined;
    };
    @memcpy(S.buf[0..ev.text_len], ev.textSlice());
    return S.buf[0..ev.text_len];
}

test "plain, shifted and caps-lock letters" {
    var km = try testKeymap(testing.allocator);
    defer km.deinit();
    var d = Decoder.init(&km);
    try testing.expectEqualStrings("a", typed(&d, 30));
    _ = d.feed(42, 1);
    try testing.expectEqualStrings("A", typed(&d, 30));
    try testing.expectEqualStrings("!", typed(&d, 2));
    _ = d.feed(42, 0);
    try testing.expectEqualStrings("a", typed(&d, 30));
    _ = d.feed(58, 1);
    _ = d.feed(58, 0);
    try testing.expectEqualStrings("A", typed(&d, 30));
    try testing.expectEqualStrings("1", typed(&d, 2)); // caps does not shift digits
    _ = d.feed(42, 1);
    try testing.expectEqualStrings("a", typed(&d, 30)); // shift + caps cancel on letters
}

test "AltGr reaches the unicode entry" {
    var km = try testKeymap(testing.allocator);
    defer km.deinit();
    var d = Decoder.init(&km);
    _ = d.feed(100, 1);
    try testing.expectEqualStrings("\u{B9}", typed(&d, 2));
}

test "modifiers are reported and releases type nothing" {
    var km = try testKeymap(testing.allocator);
    defer km.deinit();
    var d = Decoder.init(&km);
    _ = d.feed(29, 1);
    const ev = d.feed(30, 1);
    try testing.expect(ev.ctrl and !ev.shift and !ev.alt);
    try testing.expectEqual(@as(u21, 'a'), ev.unshifted);
    const rel = d.feed(30, 0);
    try testing.expectEqual(@as(u8, 0), rel.text_len);
    _ = d.feed(29, 0);
    try testing.expect(!d.feed(30, 1).ctrl);
}

test "dead keys compose, and fall back to the accent" {
    var km = try testKeymap(testing.allocator);
    defer km.deinit();
    var d = Decoder.init(&km);
    try testing.expectEqualStrings("", typed(&d, 40));
    try testing.expectEqualStrings("\u{E9}", typed(&d, 18)); // ' + e
    try testing.expectEqualStrings("", typed(&d, 40));
    try testing.expectEqualStrings("'", typed(&d, 57)); // ' + space
    try testing.expectEqualStrings("", typed(&d, 40));
    try testing.expectEqualStrings("'", typed(&d, 40)); // ' ' types an accent
    try testing.expectEqualStrings("", typed(&d, 41));
    try testing.expectEqualStrings("~a", typed(&d, 30)); // no composition: both
}

test "numpad types digits only with Num Lock" {
    var km = try testKeymap(testing.allocator);
    defer km.deinit();
    var d = Decoder.init(&km);
    try testing.expectEqualStrings("", typed(&d, 71));
    _ = d.feed(69, 1);
    _ = d.feed(69, 0);
    try testing.expectEqualStrings("7", typed(&d, 71));
}

test "ctrl+alt+function switches vt" {
    var km = try testKeymap(testing.allocator);
    defer km.deinit();
    var d = Decoder.init(&km);
    _ = d.feed(29, 1);
    _ = d.feed(56, 1);
    const ev = d.feed(60, 1); // F2
    try testing.expectEqual(@as(?u32, 2), vtSwitch(&ev));
    const f12 = d.feed(88, 1);
    try testing.expectEqual(@as(?u32, 12), vtSwitch(&f12));
    _ = d.feed(56, 0);
    try testing.expect(vtSwitch(&d.feed(60, 1)) == null);
}
