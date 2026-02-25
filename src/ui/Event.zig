const Widget = @import("Widget.zig");
const WidgetId = Widget.WidgetId;
const NULL_WIDGET = Widget.NULL_WIDGET;

pub const MouseButton = enum(u8) {
    left,
    right,
    middle,
};

pub const EventKind = enum(u8) {
    mouse_move,
    mouse_press,
    mouse_release,
    key_press,
    key_release,
    char_input,
    scroll,
};

pub const Event = struct {
    kind: EventKind,
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    button: MouseButton = .left,
    key: c_int = 0,
    mods: c_int = 0,
    codepoint: u32 = 0,
    scroll_x: f32 = 0,
    scroll_y: f32 = 0,
    consumed: bool = false,
    target: WidgetId = NULL_WIDGET,
};
