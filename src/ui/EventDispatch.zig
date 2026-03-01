const std = @import("std");
const Widget = @import("Widget.zig");
const WidgetId = Widget.WidgetId;
const NULL_WIDGET = Widget.NULL_WIDGET;
const WidgetTree = @import("WidgetTree.zig").WidgetTree;
const WidgetData = @import("WidgetData.zig");
const ActionRegistry = @import("ActionRegistry.zig").ActionRegistry;
const glfw = @import("../platform/glfw.zig");

const log = std.log.scoped(.UI);

const HIT_TEST_STACK_DEPTH = 32;

pub fn hitTest(tree: *const WidgetTree, x: f32, y: f32) WidgetId {
    if (tree.root == NULL_WIDGET) return NULL_WIDGET;

    var stack: [HIT_TEST_STACK_DEPTH]WidgetId = undefined;
    var sp: u8 = 0;
    stack[0] = tree.root;
    sp = 1;

    var deepest: WidgetId = NULL_WIDGET;

    while (sp > 0) {
        sp -= 1;
        const id = stack[sp];
        const w = tree.getWidgetConst(id) orelse continue;
        if (!w.visible) continue;

        if (w.computed_rect.contains(x, y)) {
            deepest = id;

            var children_buf: [HIT_TEST_STACK_DEPTH]WidgetId = undefined;
            var child_count: u8 = 0;
            var iter = tree.children(id);
            while (iter.next()) |cid| {
                if (child_count < HIT_TEST_STACK_DEPTH) {
                    children_buf[child_count] = cid;
                    child_count += 1;
                }
            }
            var i: u8 = child_count;
            while (i > 0) {
                i -= 1;
                if (sp < HIT_TEST_STACK_DEPTH) {
                    stack[sp] = children_buf[i];
                    sp += 1;
                }
            }
        }
    }

    return deepest;
}

pub fn updateHoverState(tree: *WidgetTree, target: WidgetId) void {
    for (0..tree.count) |i| {
        tree.widgets[i].hovered = false;
    }

    var id = target;
    while (id != NULL_WIDGET) {
        const w = tree.getWidget(id) orelse break;
        w.hovered = true;
        id = w.parent;
    }
}

pub fn dispatchMousePress(tree: *WidgetTree, target: WidgetId, registry: *const ActionRegistry) bool {
    _ = registry;

    if (target == NULL_WIDGET) return false;

    const w = tree.getWidget(target) orelse return false;

    w.pressed = true;

    if (w.focusable) {
        setFocusTo(tree, target);
    }

    return switch (w.kind) {
        .button, .text_input, .checkbox, .slider, .dropdown => true,
        else => false,
    };
}

pub fn dispatchMouseRelease(tree: *WidgetTree, target: WidgetId, pressed_widget: WidgetId, registry: *const ActionRegistry) bool {
    for (0..tree.count) |i| {
        tree.widgets[i].pressed = false;
    }

    if (pressed_widget == NULL_WIDGET) return false;

    if (target == pressed_widget) {
        fireWidgetAction(tree, target, registry);
        return true;
    }

    return false;
}

pub fn fireWidgetAction(tree: *WidgetTree, id: WidgetId, registry: *const ActionRegistry) void {
    const w = tree.getWidget(id) orelse return;
    const data = tree.getData(id) orelse return;

    switch (w.kind) {
        .button => {
            const action_name = data.button.getAction();
            if (action_name.len > 0) {
                log.info("Button action: '{s}'", .{action_name});
                _ = registry.dispatch(action_name);
            }
        },
        .checkbox => {
            data.checkbox.checked = !data.checkbox.checked;
            const action_name = data.checkbox.on_change_action[0..data.checkbox.on_change_action_len];
            if (action_name.len > 0) {
                log.info("Checkbox action: '{s}' checked={}", .{ action_name, data.checkbox.checked });
                _ = registry.dispatch(action_name);
            }
        },
        .dropdown => {
            data.dropdown.open = !data.dropdown.open;
        },
        else => {},
    }
}

pub fn dispatchChar(tree: *WidgetTree, codepoint: u32) bool {
    const focused_id = findFocused(tree);
    if (focused_id == NULL_WIDGET) return false;

    const w = tree.getWidgetConst(focused_id) orelse return false;
    if (w.kind != .text_input) return false;

    if (codepoint >= 0x20 and codepoint <= 0x7E) {
        const data = tree.getData(focused_id) orelse return false;
        data.text_input.insertChar(@intCast(codepoint));
        data.text_input.cursor_blink_counter = 0;
        return true;
    }

    return false;
}

pub fn dispatchKey(tree: *WidgetTree, key: c_int, action: c_int, mods: c_int, registry: *const ActionRegistry) bool {
    if (action != glfw.GLFW_PRESS and action != glfw.GLFW_REPEAT) return false;

    const focused_id = findFocused(tree);
    if (focused_id == NULL_WIDGET) return false;

    const w = tree.getWidgetConst(focused_id) orelse return false;
    const shift = (mods & glfw.GLFW_MOD_SHIFT) != 0;
    const ctrl = (mods & glfw.GLFW_MOD_CONTROL) != 0;

    switch (w.kind) {
        .text_input => {
            const data = tree.getData(focused_id) orelse return false;
            const ti = &data.text_input;

            if (ctrl and key == glfw.GLFW_KEY_A) {
                ti.selectAll();
                ti.cursor_blink_counter = 0;
                return true;
            }

            if (key == glfw.GLFW_KEY_BACKSPACE) {
                ti.deleteBack();
                ti.cursor_blink_counter = 0;
                return true;
            } else if (key == glfw.GLFW_KEY_DELETE) {
                if (ti.hasSelection()) {
                    ti.deleteSelection();
                } else if (ti.cursor_pos < ti.buffer_len) {
                    ti.cursor_pos += 1;
                    ti.selection_start = ti.cursor_pos;
                    ti.deleteBack();
                }
                ti.cursor_blink_counter = 0;
                return true;
            } else if (key == glfw.GLFW_KEY_LEFT) {
                if (shift) {
                    if (ti.cursor_pos > 0) {
                        ti.cursor_pos -= 1;
                    }
                } else if (ti.hasSelection()) {
                    const sel = ti.selectionRange();
                    ti.cursor_pos = sel.start;
                    ti.selection_start = sel.start;
                } else if (ti.cursor_pos > 0) {
                    ti.cursor_pos -= 1;
                    ti.selection_start = ti.cursor_pos;
                }
                ti.cursor_blink_counter = 0;
                return true;
            } else if (key == glfw.GLFW_KEY_RIGHT) {
                if (shift) {
                    if (ti.cursor_pos < ti.buffer_len) {
                        ti.cursor_pos += 1;
                    }
                } else if (ti.hasSelection()) {
                    const sel = ti.selectionRange();
                    ti.cursor_pos = sel.end;
                    ti.selection_start = sel.end;
                } else if (ti.cursor_pos < ti.buffer_len) {
                    ti.cursor_pos += 1;
                    ti.selection_start = ti.cursor_pos;
                }
                ti.cursor_blink_counter = 0;
                return true;
            } else if (key == glfw.GLFW_KEY_HOME) {
                if (shift) {
                    ti.cursor_pos = 0;
                } else {
                    ti.cursor_pos = 0;
                    ti.selection_start = 0;
                }
                ti.cursor_blink_counter = 0;
                return true;
            } else if (key == glfw.GLFW_KEY_END) {
                if (shift) {
                    ti.cursor_pos = ti.buffer_len;
                } else {
                    ti.cursor_pos = ti.buffer_len;
                    ti.selection_start = ti.buffer_len;
                }
                ti.cursor_blink_counter = 0;
                return true;
            }
            return false;
        },
        .button => {
            if (key == glfw.GLFW_KEY_ENTER or key == glfw.GLFW_KEY_SPACE) {
                fireWidgetAction(tree, focused_id, registry);
                return true;
            }
            return false;
        },
        .checkbox => {
            if (key == glfw.GLFW_KEY_ENTER or key == glfw.GLFW_KEY_SPACE) {
                fireWidgetAction(tree, focused_id, registry);
                return true;
            }
            return false;
        },
        .slider => {
            const data = tree.getData(focused_id) orelse return false;
            const step = (data.slider.max_value - data.slider.min_value) * 0.05;
            if (key == glfw.GLFW_KEY_LEFT) {
                data.slider.value = @max(data.slider.min_value, data.slider.value - step);
                return true;
            } else if (key == glfw.GLFW_KEY_RIGHT) {
                data.slider.value = @min(data.slider.max_value, data.slider.value + step);
                return true;
            }
            return false;
        },
        .dropdown => {
            const data = tree.getData(focused_id) orelse return false;
            const dd = &data.dropdown;
            if (key == glfw.GLFW_KEY_ENTER or key == glfw.GLFW_KEY_SPACE) {
                if (dd.open) {
                    dd.open = false;
                    const action_name = dd.on_change_action[0..dd.on_change_action_len];
                    if (action_name.len > 0) {
                        _ = registry.dispatch(action_name);
                    }
                } else {
                    dd.open = true;
                }
                return true;
            } else if (key == glfw.GLFW_KEY_ESCAPE) {
                if (dd.open) {
                    dd.open = false;
                    return true;
                }
                return false;
            } else if (key == glfw.GLFW_KEY_DOWN or key == glfw.GLFW_KEY_RIGHT) {
                if (dd.open) {
                    if (dd.selected < dd.item_count -| 1) {
                        dd.selected += 1;
                    }
                } else {
                    dd.open = true;
                }
                return true;
            } else if (key == glfw.GLFW_KEY_UP or key == glfw.GLFW_KEY_LEFT) {
                if (dd.open) {
                    if (dd.selected > 0) {
                        dd.selected -= 1;
                    }
                }
                return true;
            }
            return false;
        },
        else => return false,
    }
}


pub fn findFocused(tree: *const WidgetTree) WidgetId {
    for (0..tree.count) |i| {
        const id: WidgetId = @intCast(i);
        if (tree.widgets[id].active and tree.widgets[id].focused) {
            return id;
        }
    }
    return NULL_WIDGET;
}

pub fn setFocusTo(tree: *WidgetTree, target: WidgetId) void {
    for (0..tree.count) |i| {
        tree.widgets[i].focused = false;
    }
    if (target != NULL_WIDGET) {
        if (tree.getWidget(target)) |w| {
            if (w.focusable) {
                w.focused = true;
            }
        }
    }
}

pub fn clearFocus(tree: *WidgetTree) void {
    for (0..tree.count) |i| {
        tree.widgets[i].focused = false;
    }
}


test "hitTest returns deepest widget" {
    var tree = WidgetTree{};

    const root = tree.addWidget(.panel, NULL_WIDGET).?;
    tree.widgets[root].computed_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };

    const btn = tree.addWidget(.button, root).?;
    tree.widgets[btn].computed_rect = .{ .x = 100, .y = 100, .w = 80, .h = 28 };

    const result = hitTest(&tree, 120, 110);
    try std.testing.expectEqual(btn, result);
}

test "hitTest returns NULL_WIDGET for miss" {
    var tree = WidgetTree{};

    const root = tree.addWidget(.panel, NULL_WIDGET).?;
    tree.widgets[root].computed_rect = .{ .x = 100, .y = 100, .w = 200, .h = 200 };

    const result = hitTest(&tree, 50, 50);
    try std.testing.expectEqual(NULL_WIDGET, result);
}

test "updateHoverState sets ancestors" {
    var tree = WidgetTree{};

    const root = tree.addWidget(.panel, NULL_WIDGET).?;
    const child = tree.addWidget(.panel, root).?;
    const btn = tree.addWidget(.button, child).?;

    updateHoverState(&tree, btn);
    try std.testing.expect(tree.widgets[btn].hovered);
    try std.testing.expect(tree.widgets[child].hovered);
    try std.testing.expect(tree.widgets[root].hovered);
}

test "focus helpers" {
    var tree = WidgetTree{};

    const root = tree.addWidget(.panel, NULL_WIDGET).?;
    const btn1 = tree.addWidget(.button, root).?;
    const btn2 = tree.addWidget(.button, root).?;

    setFocusTo(&tree, btn1);
    try std.testing.expect(tree.widgets[btn1].focused);
    try std.testing.expect(!tree.widgets[btn2].focused);
    try std.testing.expectEqual(btn1, findFocused(&tree));

    setFocusTo(&tree, btn2);
    try std.testing.expect(!tree.widgets[btn1].focused);
    try std.testing.expect(tree.widgets[btn2].focused);

    clearFocus(&tree);
    try std.testing.expectEqual(NULL_WIDGET, findFocused(&tree));
}
