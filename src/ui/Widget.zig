const std = @import("std");

// ── Identifiers ──

pub const WidgetId = u16;
pub const NULL_WIDGET: WidgetId = std.math.maxInt(WidgetId);
pub const MAX_WIDGETS = 1024;

// ── Enums ──

pub const WidgetKind = enum(u8) {
    panel,
    label,
    button,
    text_input,
    image,
    scroll_view,
    list_view,
    progress_bar,
    checkbox,
    slider,
    grid,
    dropdown,
};

pub const LayoutMode = enum(u8) {
    flex,
    anchor,
};

pub const FlexDirection = enum(u8) {
    row,
    column,
};

pub const Alignment = enum(u8) {
    start,
    center,
    end,
    stretch,
};

pub const Justification = enum(u8) {
    start,
    center,
    end,
    space_between,
};

pub const AnchorPoint = enum(u8) {
    start,
    center,
    end,
};

pub const SizeSpec = union(enum) {
    px: f32,
    percent: f32,
    auto,
    fill,
};

// ── Geometry ──

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn contains(self: Rect, px: f32, py: f32) bool {
        return px >= self.x and px < self.x + self.w and
            py >= self.y and py < self.y + self.h;
    }

    pub fn intersect(a: Rect, b: Rect) Rect {
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.x + a.w, b.x + b.w);
        const y1 = @min(a.y + a.h, b.y + b.h);
        return .{
            .x = x0,
            .y = y0,
            .w = @max(0, x1 - x0),
            .h = @max(0, y1 - y0),
        };
    }
};

pub const Edges = struct {
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,

    pub fn horizontal(self: Edges) f32 {
        return self.left + self.right;
    }

    pub fn vertical(self: Edges) f32 {
        return self.top + self.bottom;
    }

    pub fn uniform(v: f32) Edges {
        return .{ .top = v, .right = v, .bottom = v, .left = v };
    }
};

pub const Color = struct {
    r: f32 = 1.0,
    g: f32 = 1.0,
    b: f32 = 1.0,
    a: f32 = 1.0,

    pub const white = Color{};
    pub const black = Color{ .r = 0, .g = 0, .b = 0 };
    pub const transparent = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };

    pub fn toArray(self: Color) [4]f32 {
        return .{ self.r, self.g, self.b, self.a };
    }

    pub fn fromHex(hex: u32) Color {
        return .{
            .r = @as(f32, @floatFromInt((hex >> 24) & 0xFF)) / 255.0,
            .g = @as(f32, @floatFromInt((hex >> 16) & 0xFF)) / 255.0,
            .b = @as(f32, @floatFromInt((hex >> 8) & 0xFF)) / 255.0,
            .a = @as(f32, @floatFromInt(hex & 0xFF)) / 255.0,
        };
    }
};

// ── Widget ──

pub const Widget = struct {
    // Tree links
    parent: WidgetId = NULL_WIDGET,
    first_child: WidgetId = NULL_WIDGET,
    next_sibling: WidgetId = NULL_WIDGET,

    // Identity
    kind: WidgetKind = .panel,
    id_hash: u32 = 0,
    active: bool = false,

    // Size
    width: SizeSpec = .auto,
    height: SizeSpec = .auto,
    min_width: f32 = 0,
    min_height: f32 = 0,

    // Layout properties (how this widget arranges its children)
    layout_mode: LayoutMode = .flex,
    flex_direction: FlexDirection = .column,
    cross_align: Alignment = .start,
    justify: Justification = .start,
    gap: f32 = 0,
    flex_grow: f32 = 0,

    // Anchor properties (used when parent layout_mode == .anchor)
    anchor_x: AnchorPoint = .start,
    anchor_y: AnchorPoint = .start,
    offset_x: f32 = 0,
    offset_y: f32 = 0,

    // Spacing
    padding: Edges = .{},
    margin: Edges = .{},

    // Visual
    background: Color = Color.transparent,
    border_color: Color = Color.transparent,
    border_width: f32 = 0,

    // State
    visible: bool = true,
    focusable: bool = false,
    hovered: bool = false,
    pressed: bool = false,
    focused: bool = false,

    // Tooltip
    tooltip: [64]u8 = .{0} ** 64,
    tooltip_len: u8 = 0,

    // Computed (set by layout)
    computed_rect: Rect = .{},
    intrinsic_width: f32 = 0,
    intrinsic_height: f32 = 0,
};
