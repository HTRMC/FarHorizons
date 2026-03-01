const std = @import("std");
const Widget = @import("Widget.zig");
const WidgetId = Widget.WidgetId;
const NULL_WIDGET = Widget.NULL_WIDGET;
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

pub const FadeState = enum { none, in, out };

pub const Screen = struct {
    tree: WidgetTree = .{},
    passthrough: bool = false,
    active: bool = false,
    fade: f32 = 1.0,
    fading: FadeState = .none,
};

pub const UiManager = struct {
    screens: [MAX_SCREEN_STACK]Screen = [_]Screen{.{}} ** MAX_SCREEN_STACK,
    screen_count: u8 = 0,
    screen_width: f32 = 800.0,
    screen_height: f32 = 600.0,
    ui_scale: f32 = 1.0,

    registry: ActionRegistry = .{},
    last_mouse_x: f32 = 0,
    last_mouse_y: f32 = 0,
    pressed_widget: WidgetId = NULL_WIDGET,
    text_renderer: ?*const TextRenderer = null,

    hover_widget: WidgetId = NULL_WIDGET,
    hover_timer: u16 = 0,

    last_click_widget: WidgetId = NULL_WIDGET,
    last_click_index: u16 = 0xFFFF,
    last_click_time: f64 = 0,

    pub fn pushScreen(self: *UiManager) ?*Screen {
        if (self.screen_count >= MAX_SCREEN_STACK) return null;
        const idx = self.screen_count;
        self.screen_count += 1;
        self.screens[idx] = .{ .active = true, .fade = 1.0, .fading = .none };
        return &self.screens[idx];
    }

    pub fn popScreen(self: *UiManager) void {
        if (self.screen_count == 0) return;
        const screen = &self.screens[self.screen_count - 1];
        if (screen.fading == .out) return;
        screen.fading = .out;
    }

    pub fn removeTopScreen(self: *UiManager) void {
        if (self.screen_count == 0) return;
        self.screen_count -= 1;
        self.screens[self.screen_count].active = false;
        self.screens[self.screen_count].tree.clear();
        self.screens[self.screen_count].fading = .none;
        self.screens[self.screen_count].fade = 1.0;
    }

    pub fn topScreen(self: *UiManager) ?*Screen {
        if (self.screen_count == 0) return null;
        return &self.screens[self.screen_count - 1];
    }

    pub fn updateScreenSize(self: *UiManager, width: u32, height: u32) void {
        self.screen_width = @floatFromInt(width);
        self.screen_height = @floatFromInt(height);
    }

    pub fn layout(self: *UiManager, text_renderer: *const TextRenderer) void {
        self.text_renderer = text_renderer;
        for (0..self.screen_count) |i| {
            if (self.screens[i].active) {
                Layout.layoutTree(&self.screens[i].tree, self.screen_width, self.screen_height, text_renderer);
            }
        }
    }

    pub fn draw(self: *UiManager, ui: *UiRenderer, tr: *TextRenderer) void {
        for (0..self.screen_count) |i| {
            const screen = &self.screens[i];
            if (!screen.active) continue;

            ui.beginLayer();

            if (screen.tree.root != NULL_WIDGET) {
                WidgetOps.drawWidget(&screen.tree, screen.tree.root, ui, tr);
            }

            if (screen.fading != .none) {
                const alpha = 1.0 - screen.fade;
                if (alpha > 0.01) {
                    ui.drawRect(0, 0, self.screen_width, self.screen_height, .{ 0, 0, 0, alpha });
                }
            }

            ui.endLayer();
        }

        if (self.topScreen()) |screen| {
            if (screen.active) {
                ui.beginLayer();
                const tooltip_id = if (self.hover_timer >= 30) self.hover_widget else NULL_WIDGET;
                WidgetOps.drawOverlays(
                    &screen.tree,
                    ui,
                    tr,
                    tooltip_id,
                    self.last_mouse_x,
                    self.last_mouse_y,
                    self.screen_width,
                    self.screen_height,
                );
                ui.endLayer();
            }
        }
    }

    pub fn blocksInput(self: *const UiManager) bool {
        if (self.screen_count == 0) return false;
        return !self.screens[self.screen_count - 1].passthrough;
    }


    pub fn handleMouseMove(self: *UiManager, x: f32, y: f32) bool {
        self.last_mouse_x = x;
        self.last_mouse_y = y;

        const tree = self.topTree() orelse return false;

        if (self.pressed_widget != NULL_WIDGET) {
            const pw = tree.getWidgetConst(self.pressed_widget);
            if (pw) |w| {
                if (w.kind == .slider) {
                    self.updateSliderDrag(tree, self.pressed_widget, x);
                    return true;
                } else if (w.kind == .text_input) {
                    self.extendTextSelection(tree, self.pressed_widget, x);
                    return true;
                }
            }
        }

        const target = EventDispatch.hitTest(tree, x, y);
        EventDispatch.updateHoverState(tree, target);

        self.updateDropdownHover(tree, x, y);

        if (target != self.hover_widget) {
            self.hover_widget = target;
            self.hover_timer = 0;
        }

        return target != NULL_WIDGET;
    }

    pub fn handleMouseButton(self: *UiManager, button: c_int, action: c_int, x: f32, y: f32) bool {
        _ = button;

        const tree = self.topTree() orelse return false;

        if (action == glfw.GLFW_PRESS) {
            if (self.handleDropdownClick(tree, x, y)) return true;
        }

        const target = EventDispatch.hitTest(tree, x, y);

        if (action == glfw.GLFW_PRESS) {
            self.closeOpenDropdowns(tree, target);
            self.pressed_widget = target;

            if (target == NULL_WIDGET) {
                EventDispatch.clearFocus(tree);
                return false;
            }

            const consumed = EventDispatch.dispatchMousePress(tree, target, &self.registry);

            if (tree.getWidgetConst(target)) |w| {
                if (w.kind == .text_input) {
                    self.positionTextCursor(tree, target, x);
                } else if (w.kind == .slider) {
                    self.updateSliderDrag(tree, target, x);
                }
            }

            self.handleListViewClick(tree, target, y);

            return consumed;
        } else if (action == glfw.GLFW_RELEASE) {
            const consumed = EventDispatch.dispatchMouseRelease(tree, target, self.pressed_widget, &self.registry);
            self.pressed_widget = NULL_WIDGET;
            return consumed;
        }

        return false;
    }

    pub fn handleKey(self: *UiManager, key: c_int, action: c_int, mods: c_int) bool {
        const tree = self.topTree() orelse return false;

        if (key == glfw.GLFW_KEY_TAB and (action == glfw.GLFW_PRESS or action == glfw.GLFW_REPEAT)) {
            const reverse = (mods & glfw.GLFW_MOD_SHIFT) != 0;
            Focus.cycleFocus(tree, reverse);
            return true;
        }

        return EventDispatch.dispatchKey(tree, key, action, mods, &self.registry);
    }

    pub fn handleChar(self: *UiManager, codepoint: u32) bool {
        const tree = self.topTree() orelse return false;
        return EventDispatch.dispatchChar(tree, codepoint, &self.registry);
    }

    pub fn handleScroll(self: *UiManager, mouse_x: f32, mouse_y: f32, _: f32, y_delta: f32) bool {
        const tree = self.topTree() orelse return false;

        const target = EventDispatch.hitTest(tree, mouse_x, mouse_y);
        if (target == NULL_WIDGET) return false;

        var id = target;
        while (id != NULL_WIDGET) {
            const w = tree.getWidgetConst(id) orelse break;
            if (w.kind == .scroll_view) {
                const data = tree.getData(id) orelse break;
                const sv = &data.scroll_view;
                const vp_h = w.computed_rect.h - w.padding.vertical();
                const max_scroll = @max(sv.content_height - vp_h, 0);
                sv.scroll_y = std.math.clamp(sv.scroll_y - y_delta * 24.0, 0, max_scroll);
                return true;
            } else if (w.kind == .list_view) {
                const data = tree.getData(id) orelse break;
                const lv = &data.list_view;
                const vp_h = w.computed_rect.h - w.padding.vertical();
                const total_h = @as(f32, @floatFromInt(lv.item_count)) * lv.item_height;
                const max_scroll = @max(total_h - vp_h, 0);
                lv.scroll_offset = std.math.clamp(lv.scroll_offset - y_delta * lv.item_height, 0, max_scroll);
                return true;
            }
            id = w.parent;
        }

        return false;
    }

    pub fn tick(self: *UiManager) void {
        if (self.topTree()) |tree| {
            const focused_id = EventDispatch.findFocused(tree);
            if (focused_id != NULL_WIDGET) {
                const w = tree.getWidgetConst(focused_id) orelse return;
                if (w.kind == .text_input) {
                    const data = tree.getData(focused_id) orelse return;
                    data.text_input.cursor_blink_counter +%= 1;
                }
            }
        }

        if (self.hover_widget != NULL_WIDGET and self.hover_timer < 60000) {
            self.hover_timer +|= 1;
        }


        self.tickFade();
    }

    pub fn tickCursorBlink(self: *UiManager) void {
        self.tick();
    }


    fn topTree(self: *UiManager) ?*WidgetTree {
        const screen = self.topScreen() orelse return null;
        if (!screen.active) return null;
        return &screen.tree;
    }

    fn textCursorFromX(self: *const UiManager, tree: *const WidgetTree, widget_id: WidgetId, mouse_x: f32) u8 {
        const tr = self.text_renderer orelse return 0;
        const w = tree.getWidgetConst(widget_id) orelse return 0;
        const data = tree.getDataConst(widget_id) orelse return 0;
        const ti = &data.text_input;
        const text = ti.getText();
        if (text.len == 0) return 0;

        const text_x = w.computed_rect.x + 4;
        const rel_x = mouse_x - text_x + ti.scroll_offset;
        if (rel_x <= 0) return 0;

        var best: u8 = @intCast(text.len);
        var i: u8 = 0;
        while (i <= text.len) : (i += 1) {
            const char_x = tr.measureText(text[0..i]);
            if (char_x >= rel_x) {
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

    fn positionTextCursor(self: *const UiManager, tree: *WidgetTree, widget_id: WidgetId, mouse_x: f32) void {
        const data = tree.getData(widget_id) orelse return;
        const pos = self.textCursorFromX(tree, widget_id, mouse_x);
        data.text_input.cursor_pos = pos;
        data.text_input.selection_start = pos;
        data.text_input.cursor_blink_counter = 0;
    }

    fn extendTextSelection(self: *const UiManager, tree: *WidgetTree, widget_id: WidgetId, mouse_x: f32) void {
        const data = tree.getData(widget_id) orelse return;
        const pos = self.textCursorFromX(tree, widget_id, mouse_x);
        data.text_input.cursor_pos = pos;
        data.text_input.cursor_blink_counter = 0;
    }

    fn tickFade(self: *UiManager) void {
        var i: u8 = 0;
        while (i < self.screen_count) {
            const screen = &self.screens[i];
            switch (screen.fading) {
                .in => {
                    screen.fade += 0.05;
                    if (screen.fade >= 1.0) {
                        screen.fade = 1.0;
                        screen.fading = .none;
                    }
                },
                .out => {
                    screen.fade -= 0.05;
                    if (screen.fade <= 0) {
                        self.removeTopScreen();
                        continue;
                    }
                },
                .none => {},
            }
            i += 1;
        }
    }

    fn updateDropdownHover(self: *const UiManager, tree: *WidgetTree, x: f32, y: f32) void {
        for (0..tree.count) |i| {
            const id: WidgetId = @intCast(i);
            const w = tree.getWidgetConst(id) orelse continue;
            if (w.kind != .dropdown or !w.visible) continue;

            const data = tree.getData(id) orelse continue;
            const dd = &data.dropdown;
            if (!dd.open) {
                dd.hovered_item = 0xFF;
                continue;
            }

            const r = w.computed_rect;
            const item_h: f32 = 28;
            const list_h = @as(f32, @floatFromInt(dd.item_count)) * item_h;
            var list_y = r.y + r.h;
            if (list_y + list_h > self.screen_height) {
                list_y = r.y - list_h;
            }

            if (x >= r.x and x < r.x + r.w and y >= list_y and y < list_y + list_h) {
                const idx: u8 = @intFromFloat((y - list_y) / item_h);
                dd.hovered_item = if (idx < dd.item_count) idx else 0xFF;
            } else {
                dd.hovered_item = 0xFF;
            }
        }
    }

    fn handleDropdownClick(self: *const UiManager, tree: *WidgetTree, x: f32, y: f32) bool {
        for (0..tree.count) |i| {
            const id: WidgetId = @intCast(i);
            const w = tree.getWidgetConst(id) orelse continue;
            if (w.kind != .dropdown or !w.visible) continue;

            const data = tree.getData(id) orelse continue;
            const dd = &data.dropdown;
            if (!dd.open) continue;

            const r = w.computed_rect;
            const item_h: f32 = 28;
            const list_h = @as(f32, @floatFromInt(dd.item_count)) * item_h;
            var list_y = r.y + r.h;
            if (list_y + list_h > self.screen_height) {
                list_y = r.y - list_h;
            }

            if (x >= r.x and x < r.x + r.w and y >= list_y and y < list_y + list_h) {
                const clicked_idx: u8 = @intFromFloat((y - list_y) / item_h);
                if (clicked_idx < dd.item_count) {
                    dd.selected = clicked_idx;
                    dd.open = false;
                    const action_name = dd.on_change_action[0..dd.on_change_action_len];
                    if (action_name.len > 0) {
                        _ = self.registry.dispatch(action_name);
                    }
                    return true;
                }
            }
        }
        return false;
    }

    fn closeOpenDropdowns(_: *const UiManager, tree: *WidgetTree, clicked_target: WidgetId) void {
        for (0..tree.count) |i| {
            const id: WidgetId = @intCast(i);
            if (id == clicked_target) continue;
            const w = tree.getWidgetConst(id) orelse continue;
            if (w.kind != .dropdown) continue;
            const data = tree.getData(id) orelse continue;
            data.dropdown.open = false;
        }
    }

    fn handleListViewClick(self: *UiManager, tree: *WidgetTree, target: WidgetId, mouse_y: f32) void {
        var id = target;
        while (id != NULL_WIDGET) {
            const w = tree.getWidgetConst(id) orelse break;
            if (w.kind == .list_view) {
                const data = tree.getData(id) orelse break;
                const lv = &data.list_view;
                const vp_y = w.computed_rect.y + w.padding.top;
                const clicked_f = (mouse_y - vp_y + lv.scroll_offset) / lv.item_height;
                if (clicked_f >= 0) {
                    const clicked_idx: u16 = @intFromFloat(clicked_f);
                    if (clicked_idx < lv.item_count) {
                        const now = glfw.getTime();
                        if (self.last_click_widget == id and self.last_click_index == clicked_idx and (now - self.last_click_time) < 0.5) {
                            const dbl_action = lv.on_double_click_action[0..lv.on_double_click_action_len];
                            if (dbl_action.len > 0) {
                                _ = self.registry.dispatch(dbl_action);
                            }
                            self.last_click_widget = NULL_WIDGET;
                        } else {
                            self.last_click_widget = id;
                            self.last_click_index = clicked_idx;
                            self.last_click_time = now;
                        }

                        lv.selected_index = clicked_idx;
                        const action_name = lv.on_change_action[0..lv.on_change_action_len];
                        if (action_name.len > 0) {
                            _ = self.registry.dispatch(action_name);
                        }
                    }
                }
                return;
            }
            id = w.parent;
        }
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

    pub fn loadScreenFromFile(self: *UiManager, filename: []const u8, allocator: std.mem.Allocator) bool {
        const screen = self.pushScreen() orelse return false;
        if (!ScreenLoader.loadScreen(&screen.tree, &screen.passthrough, filename, allocator)) {
            self.popScreen();
            return false;
        }
        return true;
    }

};
