//! Every user-visible string goes through `tr` so translations can be added
//! later without touching call sites.

pub fn tr(comptime msg: [:0]const u8) [:0]const u8 {
    return msg;
}
