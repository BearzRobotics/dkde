//! Physical key mapping for the kitty keyboard protocol: Linux evdev codes to
//! the W3C-style key names libghostty-vt wants. GTK reports the evdev code + 8;
//! dkde-console reads evdev codes directly.

const std = @import("std");
const vt = @import("ghostty-vt");

const Key = vt.input.Key;

/// GTK/Wayland hardware keycode -> key, or `.unidentified`.
pub fn fromHardwareKeycode(keycode: u32) Key {
    if (keycode < 8) return .unidentified;
    return fromEvdev(keycode - 8);
}

/// Linux evdev key code (`KEY_*`) -> key, or `.unidentified`.
pub fn fromEvdev(code: u32) Key {
    return if (code < table.len) table[code] else .unidentified;
}

const table = blk: {
    var t: [128]Key = @splat(.unidentified);
    t[1] = .escape;
    const digits = [_]Key{ .digit_1, .digit_2, .digit_3, .digit_4, .digit_5, .digit_6, .digit_7, .digit_8, .digit_9, .digit_0 };
    for (digits, 0..) |k, i| t[2 + i] = k;
    t[12] = .minus;
    t[13] = .equal;
    t[14] = .backspace;
    t[15] = .tab;
    const row_q = [_]Key{ .key_q, .key_w, .key_e, .key_r, .key_t, .key_y, .key_u, .key_i, .key_o, .key_p };
    for (row_q, 0..) |k, i| t[16 + i] = k;
    t[26] = .bracket_left;
    t[27] = .bracket_right;
    t[28] = .enter;
    t[29] = .control_left;
    const row_a = [_]Key{ .key_a, .key_s, .key_d, .key_f, .key_g, .key_h, .key_j, .key_k, .key_l };
    for (row_a, 0..) |k, i| t[30 + i] = k;
    t[39] = .semicolon;
    t[40] = .quote;
    t[41] = .backquote;
    t[42] = .shift_left;
    t[43] = .backslash;
    const row_z = [_]Key{ .key_z, .key_x, .key_c, .key_v, .key_b, .key_n, .key_m };
    for (row_z, 0..) |k, i| t[44 + i] = k;
    t[51] = .comma;
    t[52] = .period;
    t[53] = .slash;
    t[54] = .shift_right;
    t[55] = .numpad_multiply;
    t[56] = .alt_left;
    t[57] = .space;
    t[58] = .caps_lock;
    const fkeys = [_]Key{ .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10 };
    for (fkeys, 0..) |k, i| t[59 + i] = k;
    t[69] = .num_lock;
    t[70] = .scroll_lock;
    t[71] = .numpad_7;
    t[72] = .numpad_8;
    t[73] = .numpad_9;
    t[74] = .numpad_subtract;
    t[75] = .numpad_4;
    t[76] = .numpad_5;
    t[77] = .numpad_6;
    t[78] = .numpad_add;
    t[79] = .numpad_1;
    t[80] = .numpad_2;
    t[81] = .numpad_3;
    t[82] = .numpad_0;
    t[83] = .numpad_decimal;
    t[86] = .intl_backslash;
    t[87] = .f11;
    t[88] = .f12;
    t[96] = .numpad_enter;
    t[97] = .control_right;
    t[98] = .numpad_divide;
    t[99] = .print_screen;
    t[100] = .alt_right;
    t[102] = .home;
    t[103] = .arrow_up;
    t[104] = .page_up;
    t[105] = .arrow_left;
    t[106] = .arrow_right;
    t[107] = .end;
    t[108] = .arrow_down;
    t[109] = .page_down;
    t[110] = .insert;
    t[111] = .delete;
    t[119] = .pause;
    t[125] = .meta_left;
    t[126] = .meta_right;
    t[127] = .context_menu;
    break :blk t;
};

test "evdev codes map to physical keys" {
    // GTK keycode = evdev + 8.
    try std.testing.expectEqual(Key.key_a, fromHardwareKeycode(38));
    try std.testing.expectEqual(Key.enter, fromHardwareKeycode(36));
    try std.testing.expectEqual(Key.arrow_up, fromHardwareKeycode(111));
    try std.testing.expectEqual(Key.f1, fromHardwareKeycode(67));
    try std.testing.expectEqual(Key.escape, fromHardwareKeycode(9));
    try std.testing.expectEqual(Key.unidentified, fromHardwareKeycode(0));
    try std.testing.expectEqual(Key.unidentified, fromHardwareKeycode(5000));
}
