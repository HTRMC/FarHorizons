const std = @import("std");
const Widget = @import("Widget.zig");
const WidgetId = Widget.WidgetId;
const NULL_WIDGET = Widget.NULL_WIDGET;
const Color = Widget.Color;
const WidgetTree = @import("WidgetTree.zig").WidgetTree;
const Layout = @import("Layout.zig");
const WidgetOps = @import("WidgetOps.zig");
const UiRenderer = @import("../renderer/vulkan/UiRenderer.zig").UiRenderer;
const TextRenderer = @import("../renderer/vulkan/TextRenderer.zig").TextRenderer;
const ActionRegistry = @import("ActionRegistry.zig").ActionRegistry;
const EventDispatch = @import("EventDispatch.zig");
const Focus = @import("Focus.zig");
const ScreenLoader = @import("ScreenLoader.zig");
const glfw = @import("../platform/glfw.zig");

const log = std.log.scoped(.UI);

const MAX_SCREEN_STACK = 4;

pub const Screen = struct {
    tree: WidgetTree = .{},
    passthrough: bool = false,
    active: bool = false,
};

pub const UiManager = struct {
    screens: [MAX_SCREEN_STACK]Screen = [_]Screen{.{}} ** MAX_SCREEN_STACK,
    screen_count: u8 = 0,
    screen_width: f32 = 800.0,
    screen_height: f32 = 600.0,

    // Event state
    registry: ActionRegistry = .{},
    last_mouse_x: f32 = 0,
    last_mouse_y: f32 = 0,
    pressed_widget: WidgetId = NULL_WIDGET,
    text_renderer: ?*const TextRenderer = null,

    /// Push a new screen onto the stack. Returns the screen index for building.
    pub fn pushScreen(self: *UiManager) ?*Screen {
        if (self.screen_count >= MAX_SCREEN_STACK) return null;
        const idx = self.screen_count;
        self.screen_count += 1;
        self.screens[idx] = .{ .active = true };
        return &self.screens[idx];
    }

    /// Pop the top screen from the stack.
    pub fn popScreen(self: *UiManager) void {
        if (self.screen_count == 0) return;
        self.screen_count -= 1;
        self.screens[self.screen_count].active = false;
        self.screens[self.screen_count].tree.clear();
    }

    /// Get the top screen (if any).
    pub fn topScreen(self: *UiManager) ?*Screen {
        if (self.screen_count == 0) return null;
        return &self.screens[self.screen_count - 1];
    }

    pub fn updateScreenSize(self: *UiManager, width: u32, height: u32) void {
        self.screen_width = @floatFromInt(width);
        self.screen_height = @floatFromInt(height);
    }

    /// Run layout on all active screens.
    pub fn layout(self: *UiManager, text_renderer: *const TextRenderer) void {
        self.text_renderer = text_renderer;
        for (0..self.screen_count) |i| {
            if (self.screens[i].active) {
                Layout.layoutTree(&self.screens[i].tree, self.screen_width, self.screen_height, text_renderer);
            }
        }
    }

    /// Draw all active screens (bottom to top).
    pub fn draw(self: *UiManager, ui: *UiRenderer, tr: *TextRenderer) void {
        for (0..self.screen_count) |i| {
            const screen = &self.screens[i];
            if (!screen.active) continue;
            if (screen.tree.root != NULL_WIDGET) {
                WidgetOps.drawWidget(&screen.tree, screen.tree.root, ui, tr);
            }
        }
    }

    /// Check if the top screen blocks input passthrough to the game.
    pub fn blocksInput(self: *const UiManager) bool {
        if (self.screen_count == 0) return false;
        return !self.screens[self.screen_count - 1].passthrough;
    }

    // ── Event handling ──

    /// Handle mouse movement. Returns true if UI consumed the event.
    pub fn handleMouseMove(self: *UiManager, x: f32, y: f32) bool {
        self.last_mouse_x = x;
        self.last_mouse_y = y;

        const tree = self.topTree() orelse return false;

        // Handle drag on pressed widget
        if (self.pressed_widget != NULL_WIDGET) {
            const pw = tree.getWidgetConst(self.pressed_widget);
            if (pw) |w| {
                if (w.kind == .slider) {
                    self.updateSliderDrag(tree, self.pressed_widget, x);
                    return true;
                } else if (w.kind == .text_input) {
                    // Drag-to-select: update cursor_pos (selection_start stays at click origin)
                    self.extendTextSelection(tree, self.pressed_widget, x);
                    return true;
                }
            }
        }

        const target = EventDispatch.hitTest(tree, x, y);
        EventDispatch.updateHoverState(tree, target);

        return target != NULL_WIDGET;
    }

    /// Handle mouse button press/release. Returns true if consumed.
    pub fn handleMouseButton(self: *UiManager, button: c_int, action: c_int, x: f32, y: f32) bool {
        _ = button; // Only handle left button for now

        const tree = self.topTree() orelse return false;
        const target = EventDispatch.hitTest(tree, x, y);

        if (action == glfw.GLFW_PRESS) {
            self.pressed_widget = target;

            if (target == NULL_WIDGET) {
                // Click on empty space — clear focus
                EventDispatch.clearFocus(tree);
                return false;
            }

            const consumed = EventDispatch.dispatchMousePress(tree, target, &self.registry);

            // Position cursor in text_input on click
            if (tree.getWidgetConst(target)) |w| {
                if (w.kind == .text_input) {
                    self.positionTextCursor(tree, target, x);
                } else if (w.kind == .slider) {
                    self.updateSliderDrag(tree, target, x);
                }
            }

            return consumed;
        } else if (action == glfw.GLFW_RELEASE) {
            const consumed = EventDispatch.dispatchMouseRelease(tree, target, self.pressed_widget, &self.registry);
            self.pressed_widget = NULL_WIDGET;
            return consumed;
        }

        return false;
    }

    /// Handle key press/release. Returns true if consumed.
    pub fn handleKey(self: *UiManager, key: c_int, action: c_int, mods: c_int) bool {
        const tree = self.topTree() orelse return false;

        // Tab cycles focus
        if (key == glfw.GLFW_KEY_TAB and (action == glfw.GLFW_PRESS or action == glfw.GLFW_REPEAT)) {
            const reverse = (mods & glfw.GLFW_MOD_SHIFT) != 0;
            Focus.cycleFocus(tree, reverse);
            return true;
        }

        return EventDispatch.dispatchKey(tree, key, action, mods, &self.registry);
    }

    /// Handle character input. Returns true if consumed.
    pub fn handleChar(self: *UiManager, codepoint: u32) bool {
        const tree = self.topTree() orelse return false;
        return EventDispatch.dispatchChar(tree, codepoint);
    }

    /// Handle scroll input. Returns true if consumed.
    pub fn handleScroll(_: *UiManager, _: f32, _: f32, _: f32, _: f32) bool {
        // Future: scroll_view support
        return false;
    }

    /// Tick cursor blink counter on focused text_input widgets.
    pub fn tickCursorBlink(self: *UiManager) void {
        const tree = self.topTree() orelse return;
        const focused_id = EventDispatch.findFocused(tree);
        if (focused_id == NULL_WIDGET) return;

        const w = tree.getWidgetConst(focused_id) orelse return;
        if (w.kind == .text_input) {
            const data = tree.getData(focused_id) orelse return;
            data.text_input.cursor_blink_counter +%= 1;
        }
    }

    // ── Internal helpers ──

    fn topTree(self: *UiManager) ?*WidgetTree {
        const screen = self.topScreen() orelse return null;
        if (!screen.active) return null;
        return &screen.tree;
    }

    /// Compute the character index in a text_input closest to the given x position.
    fn textCursorFromX(self: *const UiManager, tree: *const WidgetTree, widget_id: WidgetId, mouse_x: f32) u8 {
        const tr = self.text_renderer orelse return 0;
        const w = tree.getWidgetConst(widget_id) orelse return 0;
        const data = tree.getDataConst(widget_id) orelse return 0;
        const ti = &data.text_input;
        const text = ti.getText();
        if (text.len == 0) return 0;

        const text_x = w.computed_rect.x + 4; // 4px padding matches WidgetOps draw
        const rel_x = mouse_x - text_x + ti.scroll_offset;
        if (rel_x <= 0) return 0;

        // Find which character boundary is closest
        var best: u8 = @intCast(text.len);
        var i: u8 = 0;
        while (i <= text.len) : (i += 1) {
            const char_x = tr.measureText(text[0..i]);
            if (char_x >= rel_x) {
                // Check if closer to this boundary or previous
                if (i > 0) {
                    const prev_x = tr.measureText(text[0 .. i - 1]);
                    if (rel_x - prev_x < char_x - rel_x) {
                        best = i - 1;
                    } else {
                        best = i;
                    }
                } else {
                    best = 0;
                }
                break;
            }
        }
        return best;
    }

    /// Position cursor at mouse click location and clear selection.
    fn positionTextCursor(self: *const UiManager, tree: *WidgetTree, widget_id: WidgetId, mouse_x: f32) void {
        const data = tree.getData(widget_id) orelse return;
        const pos = self.textCursorFromX(tree, widget_id, mouse_x);
        data.text_input.cursor_pos = pos;
        data.text_input.selection_start = pos;
        data.text_input.cursor_blink_counter = 0;
    }

    /// Extend selection by updating cursor_pos to mouse position (selection_start stays).
    fn extendTextSelection(self: *const UiManager, tree: *WidgetTree, widget_id: WidgetId, mouse_x: f32) void {
        const data = tree.getData(widget_id) orelse return;
        const pos = self.textCursorFromX(tree, widget_id, mouse_x);
        data.text_input.cursor_pos = pos;
        data.text_input.cursor_blink_counter = 0;
    }

    fn updateSliderDrag(self: *UiManager, tree: *WidgetTree, slider_id: WidgetId, mouse_x: f32) void {
        _ = self;
        const w = tree.getWidgetConst(slider_id) orelse return;
        const data = tree.getData(slider_id) orelse return;

        const rect = w.computed_rect;
        if (rect.w <= 0) return;

        const frac = std.math.clamp((mouse_x - rect.x) / rect.w, 0.0, 1.0);
        data.slider.value = data.slider.min_value + frac * (data.slider.max_value - data.slider.min_value);
    }

    /// Load a UI screen from an XML file. Returns true on success.
    pub fn loadScreenFromFile(self: *UiManager, filename: []const u8, allocator: std.mem.Allocator) bool {
        const screen = self.pushScreen() orelse return false;
        if (!ScreenLoader.loadScreen(&screen.tree, &screen.passthrough, filename, allocator)) {
            self.popScreen();
            return false;
        }
        return true;
    }

    /// Build the hardcoded test screen (fallback if XML loading fails).
    pub fn buildTestScreen(self: *UiManager) void {
        const screen = self.pushScreen() orelse return;
        var tree = &screen.tree;

        // Root panel — centered, semi-transparent dark background
        const root = tree.addWidget(.panel, NULL_WIDGET) orelse return;
        var root_w = tree.getWidget(root).?;
        root_w.width = .{ .px = 320 };
        root_w.height = .auto;
        root_w.background = Color.fromHex(0x1A1A2ECC);
        root_w.padding = Widget.Edges.uniform(16);
        root_w.layout_mode = .flex;
        root_w.flex_direction = .column;
        root_w.cross_align = .center;
        root_w.justify = .center;
        root_w.gap = 8;
        // Anchor root to center of screen
        root_w.anchor_x = .center;
        root_w.anchor_y = .center;

        // We need the root to be positioned by anchor on the implicit screen container.
        // Since root IS the tree root, layout handles it specially.
        // Instead, let's make a real screen-root that uses anchor layout.
        tree.clear();
        const screen_root = tree.addWidget(.panel, NULL_WIDGET) orelse return;
        var sr = tree.getWidget(screen_root).?;
        sr.width = .fill;
        sr.height = .fill;
        sr.layout_mode = .anchor;
        sr.background = Color.transparent;

        // Centered panel
        const panel = tree.addWidget(.panel, screen_root) orelse return;
        var p = tree.getWidget(panel).?;
        p.width = .{ .px = 320 };
        p.height = .auto;
        p.background = Color.fromHex(0x1A1A2ECC);
        p.padding = Widget.Edges.uniform(16);
        p.layout_mode = .flex;
        p.flex_direction = .column;
        p.cross_align = .center;
        p.justify = .center;
        p.gap = 8;
        p.anchor_x = .center;
        p.anchor_y = .center;
        p.border_width = 1;
        p.border_color = Color.fromHex(0x444466FF);

        // Title label
        const title = tree.addWidget(.label, panel) orelse return;
        tree.getWidget(title).?.width = .auto;
        tree.getWidget(title).?.height = .auto;
        var title_data = &tree.getData(title).?.label;
        title_data.setText("UI System Test");
        title_data.color = Color.fromHex(0xFFCC00FF);
        title_data.font_size = 2;

        // Subtitle
        const subtitle = tree.addWidget(.label, panel) orelse return;
        tree.getWidget(subtitle).?.width = .auto;
        tree.getWidget(subtitle).?.height = .auto;
        var sub_data = &tree.getData(subtitle).?.label;
        sub_data.setText("Phase 2 - Events");
        sub_data.color = Color.fromHex(0xAAAAAAFF);

        // Button row
        const btn_row = tree.addWidget(.panel, panel) orelse return;
        var br = tree.getWidget(btn_row).?;
        br.layout_mode = .flex;
        br.flex_direction = .row;
        br.gap = 8;
        br.width = .auto;
        br.height = .auto;
        br.cross_align = .center;

        // Button 1
        const btn1 = tree.addWidget(.button, btn_row) orelse return;
        var b1 = tree.getWidget(btn1).?;
        b1.width = .{ .px = 80 };
        b1.height = .{ .px = 28 };
        b1.background = Color.fromHex(0x335588FF);
        var b1d = &tree.getData(btn1).?.button;
        b1d.setText("Play");
        b1d.setAction("ui_play");

        // Button 2
        const btn2 = tree.addWidget(.button, btn_row) orelse return;
        var b2 = tree.getWidget(btn2).?;
        b2.width = .{ .px = 80 };
        b2.height = .{ .px = 28 };
        b2.background = Color.fromHex(0x553333FF);
        var b2d = &tree.getData(btn2).?.button;
        b2d.setText("Quit");
        b2d.setAction("ui_quit");

        // Text input
        const ti = tree.addWidget(.text_input, panel) orelse return;
        var tiw = tree.getWidget(ti).?;
        tiw.width = .fill;
        tiw.height = .{ .px = 28 };
        var tid = &tree.getData(ti).?.text_input;
        const ph = "Type here...";
        @memcpy(tid.placeholder[0..ph.len], ph);
        tid.placeholder_len = ph.len;

        // Slider
        const sl = tree.addWidget(.slider, panel) orelse return;
        var slw = tree.getWidget(sl).?;
        slw.width = .fill;
        slw.height = .{ .px = 20 };

        // Progress bar
        const pb = tree.addWidget(.progress_bar, panel) orelse return;
        var pbw = tree.getWidget(pb).?;
        pbw.width = .fill;
        pbw.height = .{ .px = 12 };
        tree.getData(pb).?.progress_bar.value = 0.65;
        tree.getData(pb).?.progress_bar.fill_color = Color.fromHex(0x44AA44FF);
    }
};
