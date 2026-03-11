const std = @import("std");
const Widget = @import("Widget.zig");
const WidgetId = Widget.WidgetId;
const NULL_WIDGET = Widget.NULL_WIDGET;
const WidgetTree = @import("WidgetTree.zig").WidgetTree;
const EventDispatch = @import("EventDispatch.zig");

const MAX_FOCUSABLE = 64;

pub const Direction = enum { up, down, left, right };

/// Move focus to the nearest focusable widget in the given direction.
/// Falls back to wrapping (first/last) if nothing is found in that direction.
pub fn navigateSpatial(tree: *WidgetTree, dir: Direction) void {
    var focusable: [MAX_FOCUSABLE]WidgetId = undefined;
    var count: u8 = 0;

    for (0..tree.count) |i| {
        const id: WidgetId = @intCast(i);
        const w = &tree.widgets[id];
        if (w.active and w.visible and w.focusable and isAncestryVisible(tree, id)) {
            if (count < MAX_FOCUSABLE) {
                focusable[count] = id;
                count += 1;
            }
        }
    }

    if (count == 0) return;

    const current = EventDispatch.findFocused(tree);

    // If nothing focused, pick first or last depending on direction
    if (current == NULL_WIDGET) {
        const pick: u8 = switch (dir) {
            .up, .left => count - 1,
            .down, .right => 0,
        };
        EventDispatch.setFocusTo(tree, focusable[pick]);
        return;
    }

    const src = tree.widgets[current].computed_rect;
    const cx = src.x + src.w * 0.5;
    const cy = src.y + src.h * 0.5;

    var best: WidgetId = NULL_WIDGET;
    var best_score: f32 = std.math.inf(f32);

    for (0..count) |i| {
        const id = focusable[i];
        if (id == current) continue;

        const dst = tree.widgets[id].computed_rect;
        const tx = dst.x + dst.w * 0.5;
        const ty = dst.y + dst.h * 0.5;

        const dx = tx - cx;
        const dy = ty - cy;

        // Check the candidate is in the correct direction
        const in_dir: bool = switch (dir) {
            .up => dy < -1.0,
            .down => dy > 1.0,
            .left => dx < -1.0,
            .right => dx > 1.0,
        };
        if (!in_dir) continue;

        // Cross-axis: use edge gap (0 if overlapping) plus center offset.
        // Edge gap catches items clearly on a different row/column.
        // Center offset breaks ties when multiple items have zero gap.
        const cross_gap: f32 = switch (dir) {
            .up, .down => blk: {
                const gap = @max(dst.x - (src.x + src.w), src.x - (dst.x + dst.w));
                break :blk @max(gap, 0);
            },
            .left, .right => blk: {
                const gap = @max(dst.y - (src.y + src.h), src.y - (dst.y + dst.h));
                break :blk @max(gap, 0);
            },
        };

        const cross_center: f32 = switch (dir) {
            .up, .down => @abs(dx),
            .left, .right => @abs(dy),
        };

        const primary_dist: f32 = switch (dir) {
            .up, .down => @abs(dy),
            .left, .right => @abs(dx),
        };

        // For left/right: penalize cross-axis heavily (edge gap + center offset)
        // so same-row items always win over different-row items.
        // For up/down: only penalize edge gap (not center offset) so a wide widget
        // like a search bar treats all items in the row below equally by distance.
        const score = switch (dir) {
            .left, .right => primary_dist + cross_gap * 50.0 + cross_center * 5.0,
            .up, .down => primary_dist + cross_gap * 50.0,
        };

        if (score < best_score) {
            best_score = score;
            best = id;
        }
    }

    if (best != NULL_WIDGET) {
        EventDispatch.setFocusTo(tree, best);
    } else if (count > 1) {
        // Wrap: find the widget furthest away in the navigation direction.
        // e.g. pressing down past the bottom wraps to the topmost widget;
        //      pressing up past the top wraps to the bottommost widget.
        var wrap_best: WidgetId = NULL_WIDGET;
        var wrap_extreme: f32 = -std.math.inf(f32);

        for (0..count) |i| {
            const id = focusable[i];
            if (id == current) continue;

            const r = tree.widgets[id].computed_rect;
            const rcy = r.y + r.h * 0.5;
            const rcx = r.x + r.w * 0.5;

            // We want the widget at the opposite extreme:
            // going down wraps to topmost (most negative y),
            // going up wraps to bottommost (most positive y), etc.
            const extremeness: f32 = switch (dir) {
                .down => -rcy,   // largest negative = smallest y = topmost
                .up => rcy,      // largest positive = biggest y = bottommost
                .right => -rcx,  // largest negative = smallest x = leftmost
                .left => rcx,    // largest positive = biggest x = rightmost
            };

            if (extremeness > wrap_extreme) {
                wrap_extreme = extremeness;
                wrap_best = id;
            }
        }

        if (wrap_best != NULL_WIDGET) {
            EventDispatch.setFocusTo(tree, wrap_best);
        }
    }
}

pub fn cycleFocus(tree: *WidgetTree, reverse: bool) void {
    var focusable: [MAX_FOCUSABLE]WidgetId = undefined;
    var count: u8 = 0;

    for (0..tree.count) |i| {
        const id: WidgetId = @intCast(i);
        const w = &tree.widgets[id];
        if (w.active and w.visible and w.focusable and isAncestryVisible(tree, id)) {
            if (count < MAX_FOCUSABLE) {
                focusable[count] = id;
                count += 1;
            }
        }
    }

    if (count == 0) return;

    const current_focused = EventDispatch.findFocused(tree);
    var current_idx: ?u8 = null;
    for (0..count) |i| {
        if (focusable[i] == current_focused) {
            current_idx = @intCast(i);
            break;
        }
    }

    const next_idx: u8 = if (current_idx) |idx| blk: {
        if (reverse) {
            break :blk if (idx == 0) count - 1 else idx - 1;
        } else {
            break :blk if (idx >= count - 1) 0 else idx + 1;
        }
    } else 0;

    EventDispatch.setFocusTo(tree, focusable[next_idx]);
}

/// Check that all ancestors of a widget are visible.
fn isAncestryVisible(tree: *const WidgetTree, id: WidgetId) bool {
    var pid = tree.widgets[id].parent;
    while (pid != NULL_WIDGET) {
        const pw = &tree.widgets[pid];
        if (!pw.visible) return false;
        pid = pw.parent;
    }
    return true;
}


test "cycleFocus forward through focusable widgets" {
    var tree = WidgetTree{};

    const root = tree.addWidget(.panel, NULL_WIDGET).?;
    const btn1 = tree.addWidget(.button, root).?;
    _ = tree.addWidget(.label, root).?;
    const btn2 = tree.addWidget(.button, root).?;
    const btn3 = tree.addWidget(.button, root).?;

    cycleFocus(&tree, false);
    try std.testing.expect(tree.widgets[btn1].focused);

    cycleFocus(&tree, false);
    try std.testing.expect(tree.widgets[btn2].focused);

    cycleFocus(&tree, false);
    try std.testing.expect(tree.widgets[btn3].focused);

    cycleFocus(&tree, false);
    try std.testing.expect(tree.widgets[btn1].focused);
}

test "cycleFocus reverse" {
    var tree = WidgetTree{};

    const root = tree.addWidget(.panel, NULL_WIDGET).?;
    const btn1 = tree.addWidget(.button, root).?;
    const btn2 = tree.addWidget(.button, root).?;

    EventDispatch.setFocusTo(&tree, btn2);

    cycleFocus(&tree, true);
    try std.testing.expect(tree.widgets[btn1].focused);

    cycleFocus(&tree, true);
    try std.testing.expect(tree.widgets[btn2].focused);
}
