const std = @import("std");
const Widget = @import("Widget.zig");
const WidgetId = Widget.WidgetId;
const NULL_WIDGET = Widget.NULL_WIDGET;
const WidgetTree = @import("WidgetTree.zig").WidgetTree;
const EventDispatch = @import("EventDispatch.zig");

const MAX_FOCUSABLE = 64;

/// Cycle focus to the next (or previous if reverse=true) focusable widget.
/// Collects all focusable widgets in index order, finds the current focused one,
/// and moves to next/prev with wraparound.
pub fn cycleFocus(tree: *WidgetTree, reverse: bool) void {
    var focusable: [MAX_FOCUSABLE]WidgetId = undefined;
    var count: u8 = 0;

    // Collect focusable widgets in index order
    for (0..tree.count) |i| {
        const id: WidgetId = @intCast(i);
        const w = &tree.widgets[id];
        if (w.active and w.visible and w.focusable) {
            if (count < MAX_FOCUSABLE) {
                focusable[count] = id;
                count += 1;
            }
        }
    }

    if (count == 0) return;

    // Find currently focused widget's position in the list
    const current_focused = EventDispatch.findFocused(tree);
    var current_idx: ?u8 = null;
    for (0..count) |i| {
        if (focusable[i] == current_focused) {
            current_idx = @intCast(i);
            break;
        }
    }

    // Compute next index
    const next_idx: u8 = if (current_idx) |idx| blk: {
        if (reverse) {
            break :blk if (idx == 0) count - 1 else idx - 1;
        } else {
            break :blk if (idx >= count - 1) 0 else idx + 1;
        }
    } else 0; // No current focus — start at first

    EventDispatch.setFocusTo(tree, focusable[next_idx]);
}

// ── Tests ──

test "cycleFocus forward through focusable widgets" {
    var tree = WidgetTree{};

    const root = tree.addWidget(.panel, NULL_WIDGET).?;
    const btn1 = tree.addWidget(.button, root).?;
    _ = tree.addWidget(.label, root).?; // not focusable
    const btn2 = tree.addWidget(.button, root).?;
    const btn3 = tree.addWidget(.button, root).?;

    // No focus initially — cycles to first focusable
    cycleFocus(&tree, false);
    try std.testing.expect(tree.widgets[btn1].focused);

    cycleFocus(&tree, false);
    try std.testing.expect(tree.widgets[btn2].focused);

    cycleFocus(&tree, false);
    try std.testing.expect(tree.widgets[btn3].focused);

    // Wrap around
    cycleFocus(&tree, false);
    try std.testing.expect(tree.widgets[btn1].focused);
}

test "cycleFocus reverse" {
    var tree = WidgetTree{};

    const root = tree.addWidget(.panel, NULL_WIDGET).?;
    const btn1 = tree.addWidget(.button, root).?;
    const btn2 = tree.addWidget(.button, root).?;

    // Start with focus on btn2
    EventDispatch.setFocusTo(&tree, btn2);

    cycleFocus(&tree, true);
    try std.testing.expect(tree.widgets[btn1].focused);

    // Wrap around backwards
    cycleFocus(&tree, true);
    try std.testing.expect(tree.widgets[btn2].focused);
}
