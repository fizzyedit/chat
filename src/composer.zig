//! What the message box decides, std-only so it tests without a window: what Enter does and how
//! tall the box grows.
const std = @import("std");
const builtin = @import("builtin");

/// Lines the message box grows to; past this it scrolls.
pub const max_lines: f32 = 8;

pub const Enter = enum { send, newline };

/// Enter sends on a desktop and is a new line on a phone, where the Send button sends; Shift+Enter
/// is a new line anywhere.
pub fn enter(shift: bool, mobile: bool) Enter {
    return if (shift or mobile) .newline else .send;
}

/// Whether this build runs on a phone or tablet. The SDK does not hand plugins the app's form
/// factor yet, so this is the target's own answer: a phone's browser still reads as a desktop.
pub fn isMobile() bool {
    return builtin.os.tag == .ios or builtin.abi.isAndroid();
}

test "Enter sends on a desktop and breaks the line on a phone or with Shift" {
    try std.testing.expectEqual(Enter.send, enter(false, false));
    try std.testing.expectEqual(Enter.newline, enter(true, false));
    try std.testing.expectEqual(Enter.newline, enter(false, true));
    try std.testing.expectEqual(Enter.newline, enter(true, true));
}

test "this desktop build is not mobile" {
    if (builtin.os.tag == .macos or builtin.os.tag == .linux or builtin.os.tag == .windows) {
        if (!builtin.abi.isAndroid()) try std.testing.expect(!isMobile());
    }
}
