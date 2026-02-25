const Widget = @import("Widget.zig");
const Color = Widget.Color;

pub const MAX_TEXT_LEN = 128;
pub const MAX_ACTION_LEN = 64;

pub const WidgetData = union(Widget.WidgetKind) {
    panel: PanelData,
    label: LabelData,
    button: ButtonData,
    text_input: TextInputData,
    image: ImageData,
    scroll_view: ScrollViewData,
    list_view: ListViewData,
    progress_bar: ProgressBarData,
    checkbox: CheckboxData,
    slider: SliderData,
    grid: GridData,
    dropdown: DropdownData,
};

pub const PanelData = struct {
    // Panel is purely structural — visual properties live on Widget
};

pub const LabelData = struct {
    text: [MAX_TEXT_LEN]u8 = .{0} ** MAX_TEXT_LEN,
    text_len: u8 = 0,
    color: Color = Color.white,
    font_size: u8 = 1, // multiplier (1 = default 16px, 2 = 32px)
    wrap: bool = false,

    pub fn setText(self: *LabelData, str: []const u8) void {
        const len: u8 = @intCast(@min(str.len, MAX_TEXT_LEN));
        @memcpy(self.text[0..len], str[0..len]);
        self.text_len = len;
    }

    pub fn getText(self: *const LabelData) []const u8 {
        return self.text[0..self.text_len];
    }
};

pub const ButtonData = struct {
    text: [MAX_TEXT_LEN]u8 = .{0} ** MAX_TEXT_LEN,
    text_len: u8 = 0,
    text_color: Color = Color.white,
    hover_color: Color = Color.fromHex(0x444444FF),
    press_color: Color = Color.fromHex(0x222222FF),
    on_click_action: [MAX_ACTION_LEN]u8 = .{0} ** MAX_ACTION_LEN,
    on_click_action_len: u8 = 0,

    pub fn setText(self: *ButtonData, str: []const u8) void {
        const len: u8 = @intCast(@min(str.len, MAX_TEXT_LEN));
        @memcpy(self.text[0..len], str[0..len]);
        self.text_len = len;
    }

    pub fn getText(self: *const ButtonData) []const u8 {
        return self.text[0..self.text_len];
    }

    pub fn setAction(self: *ButtonData, str: []const u8) void {
        const len: u8 = @intCast(@min(str.len, MAX_ACTION_LEN));
        @memcpy(self.on_click_action[0..len], str[0..len]);
        self.on_click_action_len = len;
    }

    pub fn getAction(self: *const ButtonData) []const u8 {
        return self.on_click_action[0..self.on_click_action_len];
    }
};

pub const TextInputData = struct {
    buffer: [MAX_TEXT_LEN]u8 = .{0} ** MAX_TEXT_LEN,
    buffer_len: u8 = 0,
    cursor_pos: u8 = 0,
    selection_start: u8 = 0,
    placeholder: [MAX_TEXT_LEN]u8 = .{0} ** MAX_TEXT_LEN,
    placeholder_len: u8 = 0,
    text_color: Color = Color.white,
    placeholder_color: Color = Color.fromHex(0x888888FF),
    cursor_blink_counter: u16 = 0,
    max_len: u8 = MAX_TEXT_LEN,
    scroll_offset: f32 = 0,

    pub fn getText(self: *const TextInputData) []const u8 {
        return self.buffer[0..self.buffer_len];
    }

    pub fn hasSelection(self: *const TextInputData) bool {
        return self.selection_start != self.cursor_pos;
    }

    pub fn selectionRange(self: *const TextInputData) struct { start: u8, end: u8 } {
        return .{
            .start = @min(self.selection_start, self.cursor_pos),
            .end = @max(self.selection_start, self.cursor_pos),
        };
    }

    pub fn deleteSelection(self: *TextInputData) void {
        if (!self.hasSelection()) return;
        const sel = self.selectionRange();
        const tail_len = self.buffer_len - sel.end;
        if (tail_len > 0) {
            var i: u8 = 0;
            while (i < tail_len) : (i += 1) {
                self.buffer[sel.start + i] = self.buffer[sel.end + i];
            }
        }
        self.buffer_len -= (sel.end - sel.start);
        self.cursor_pos = sel.start;
        self.selection_start = sel.start;
    }

    pub fn selectAll(self: *TextInputData) void {
        self.selection_start = 0;
        self.cursor_pos = self.buffer_len;
    }

    pub fn insertChar(self: *TextInputData, ch: u8) void {
        if (self.hasSelection()) self.deleteSelection();
        if (self.buffer_len >= self.max_len) return;
        if (self.cursor_pos < self.buffer_len) {
            // Shift right
            var i: u8 = self.buffer_len;
            while (i > self.cursor_pos) : (i -= 1) {
                self.buffer[i] = self.buffer[i - 1];
            }
        }
        self.buffer[self.cursor_pos] = ch;
        self.buffer_len += 1;
        self.cursor_pos += 1;
        self.selection_start = self.cursor_pos;
    }

    pub fn deleteBack(self: *TextInputData) void {
        if (self.hasSelection()) {
            self.deleteSelection();
            return;
        }
        if (self.cursor_pos == 0) return;
        self.cursor_pos -= 1;
        if (self.cursor_pos < self.buffer_len - 1) {
            var i = self.cursor_pos;
            while (i < self.buffer_len - 1) : (i += 1) {
                self.buffer[i] = self.buffer[i + 1];
            }
        }
        self.buffer_len -= 1;
        self.selection_start = self.cursor_pos;
    }
};

pub const ImageData = struct {
    // Source path stored as string (namespace:path)
    src: [MAX_TEXT_LEN]u8 = .{0} ** MAX_TEXT_LEN,
    src_len: u8 = 0,
    // Atlas region (set during loading)
    atlas_u: f32 = 0,
    atlas_v: f32 = 0,
    atlas_w: f32 = 0,
    atlas_h: f32 = 0,
    tint: Color = Color.white,
    nine_slice_border: f32 = 0, // 0 = stretch, >0 = 9-slice inset
};

pub const ScrollViewData = struct {
    scroll_x: f32 = 0,
    scroll_y: f32 = 0,
    content_width: f32 = 0,
    content_height: f32 = 0,
    scroll_bar_visible: bool = true,
};

pub const ListViewData = struct {
    item_height: f32 = 24,
    item_count: u16 = 0,
    selected_index: u16 = 0,
    scroll_offset: f32 = 0,
    selection_color: Color = Color.fromHex(0x3366AAFF),
    on_change_action: [MAX_ACTION_LEN]u8 = .{0} ** MAX_ACTION_LEN,
    on_change_action_len: u8 = 0,
};

pub const ProgressBarData = struct {
    value: f32 = 0, // 0.0 to 1.0
    fill_color: Color = Color.fromHex(0xCC3333FF),
    track_color: Color = Color.fromHex(0x333333FF),
};

pub const CheckboxData = struct {
    checked: bool = false,
    check_color: Color = Color.white,
    box_color: Color = Color.fromHex(0x666666FF),
    on_change_action: [MAX_ACTION_LEN]u8 = .{0} ** MAX_ACTION_LEN,
    on_change_action_len: u8 = 0,
};

pub const SliderData = struct {
    value: f32 = 0, // 0.0 to 1.0
    min_value: f32 = 0,
    max_value: f32 = 1.0,
    track_color: Color = Color.fromHex(0x444444FF),
    fill_color: Color = Color.fromHex(0x6699CCFF),
    thumb_color: Color = Color.white,
    dragging: bool = false,
    on_change_action: [MAX_ACTION_LEN]u8 = .{0} ** MAX_ACTION_LEN,
    on_change_action_len: u8 = 0,
};

pub const GridData = struct {
    columns: u8 = 1,
    rows: u8 = 1,
    cell_size: f32 = 32,
    cell_gap: f32 = 2,
};

pub const DropdownData = struct {
    items: [8][32]u8 = .{.{0} ** 32} ** 8,
    item_lens: [8]u8 = .{0} ** 8,
    item_count: u8 = 0,
    selected: u8 = 0,
    open: bool = false,
    text_color: Color = Color.white,
    item_bg: Color = Color.fromHex(0x2A2A3EFF),
    hover_color: Color = Color.fromHex(0x444466FF),
    on_change_action: [MAX_ACTION_LEN]u8 = .{0} ** MAX_ACTION_LEN,
    on_change_action_len: u8 = 0,
    hovered_item: u8 = 0xFF, // 0xFF = none

    pub fn getSelectedText(self: *const DropdownData) []const u8 {
        if (self.selected >= self.item_count) return "";
        return self.items[self.selected][0..self.item_lens[self.selected]];
    }

    pub fn addItem(self: *DropdownData, text: []const u8) void {
        if (self.item_count >= 8) return;
        const len: u8 = @intCast(@min(text.len, 32));
        @memcpy(self.items[self.item_count][0..len], text[0..len]);
        self.item_lens[self.item_count] = len;
        self.item_count += 1;
    }
};
