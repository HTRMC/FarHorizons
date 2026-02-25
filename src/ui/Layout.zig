const std = @import("std");
const Widget = @import("Widget.zig");
const WidgetId = Widget.WidgetId;
const NULL_WIDGET = Widget.NULL_WIDGET;
const WidgetTree = @import("WidgetTree.zig").WidgetTree;
const WidgetData = @import("WidgetData.zig");
const TextRenderer = @import("../renderer/vulkan/TextRenderer.zig").TextRenderer;

/// Run the full two-pass layout on the tree.
/// Pass 1 (measure): bottom-up, computes intrinsic sizes.
/// Pass 2 (layout): top-down, assigns positions and final sizes.
pub fn layoutTree(tree: *WidgetTree, screen_w: f32, screen_h: f32, text_renderer: *const TextRenderer) void {
    if (tree.root == NULL_WIDGET) return;

    // Set root size to screen
    var root = &tree.widgets[tree.root];
    root.computed_rect.w = screen_w;
    root.computed_rect.h = screen_h;
    root.computed_rect.x = 0;
    root.computed_rect.y = 0;

    // Pass 1: measure (post-order)
    measureWidget(tree, tree.root, text_renderer);

    // Pass 2: layout (pre-order)
    layoutWidget(tree, tree.root, screen_w, screen_h);
}

// ── Pass 1: Measure (bottom-up) ──

fn measureWidget(tree: *WidgetTree, id: WidgetId, text_renderer: *const TextRenderer) void {
    const w = &tree.widgets[id];
    if (!w.active or !w.visible) return;

    // Measure children first (post-order)
    var iter = tree.children(id);
    while (iter.next()) |child_id| {
        measureWidget(tree, child_id, text_renderer);
    }

    // Compute intrinsic size based on widget kind
    const data = &tree.data[id];
    switch (w.kind) {
        .label => {
            const label = &data.label;
            const scale: f32 = @floatFromInt(label.font_size);
            w.intrinsic_width = text_renderer.measureText(label.getText()) * scale + w.padding.horizontal();
            w.intrinsic_height = 16.0 * scale + w.padding.vertical();
        },
        .button => {
            const btn = &data.button;
            w.intrinsic_width = text_renderer.measureText(btn.getText()) + 16.0 + w.padding.horizontal();
            w.intrinsic_height = 24.0 + w.padding.vertical();
        },
        .text_input => {
            w.intrinsic_width = 120.0 + w.padding.horizontal();
            w.intrinsic_height = 24.0 + w.padding.vertical();
        },
        .checkbox => {
            w.intrinsic_width = 16.0 + w.padding.horizontal();
            w.intrinsic_height = 16.0 + w.padding.vertical();
        },
        .progress_bar => {
            w.intrinsic_width = 100.0 + w.padding.horizontal();
            w.intrinsic_height = 16.0 + w.padding.vertical();
        },
        .slider => {
            w.intrinsic_width = 120.0 + w.padding.horizontal();
            w.intrinsic_height = 20.0 + w.padding.vertical();
        },
        .grid => {
            const g = &data.grid;
            const cols: f32 = @floatFromInt(g.columns);
            const rows: f32 = @floatFromInt(g.rows);
            w.intrinsic_width = cols * (g.cell_size + g.cell_gap) - g.cell_gap + w.padding.horizontal();
            w.intrinsic_height = rows * (g.cell_size + g.cell_gap) - g.cell_gap + w.padding.vertical();
        },
        .panel, .scroll_view, .list_view, .image => {
            // Intrinsic size from children for containers
            if (w.layout_mode == .flex) {
                var total_main: f32 = 0;
                var max_cross: f32 = 0;
                var child_count: f32 = 0;

                var child_iter = tree.children(id);
                while (child_iter.next()) |cid| {
                    const child = &tree.widgets[cid];
                    if (!child.active or !child.visible) continue;
                    const cw = resolveIntrinsicWidth(child);
                    const ch = resolveIntrinsicHeight(child);

                    if (w.flex_direction == .column) {
                        total_main += ch + child.margin.vertical();
                        max_cross = @max(max_cross, cw + child.margin.horizontal());
                    } else {
                        total_main += cw + child.margin.horizontal();
                        max_cross = @max(max_cross, ch + child.margin.vertical());
                    }
                    child_count += 1;
                }

                const gaps = if (child_count > 1) (child_count - 1) * w.gap else 0;

                if (w.flex_direction == .column) {
                    w.intrinsic_width = max_cross + w.padding.horizontal();
                    w.intrinsic_height = total_main + gaps + w.padding.vertical();
                } else {
                    w.intrinsic_width = total_main + gaps + w.padding.horizontal();
                    w.intrinsic_height = max_cross + w.padding.vertical();
                }
            } else {
                // Anchor mode: intrinsic is max extent of children
                var max_w: f32 = 0;
                var max_h: f32 = 0;
                var child_iter = tree.children(id);
                while (child_iter.next()) |cid| {
                    const child = &tree.widgets[cid];
                    if (!child.active or !child.visible) continue;
                    max_w = @max(max_w, resolveIntrinsicWidth(child));
                    max_h = @max(max_h, resolveIntrinsicHeight(child));
                }
                w.intrinsic_width = max_w + w.padding.horizontal();
                w.intrinsic_height = max_h + w.padding.vertical();
            }
        },
    }
}

// ── Pass 2: Layout (top-down) ──

fn layoutWidget(tree: *WidgetTree, id: WidgetId, parent_w: f32, parent_h: f32) void {
    const w = &tree.widgets[id];
    if (!w.active or !w.visible) return;

    // Resolve own final size
    w.computed_rect.w = resolveSizeSpec(w.width, parent_w, w.intrinsic_width);
    w.computed_rect.h = resolveSizeSpec(w.height, parent_h, w.intrinsic_height);

    // Content area
    const content_x = w.computed_rect.x + w.padding.left;
    const content_y = w.computed_rect.y + w.padding.top;
    const content_w = w.computed_rect.w - w.padding.horizontal();
    const content_h = w.computed_rect.h - w.padding.vertical();

    if (w.layout_mode == .flex) {
        layoutFlexChildren(tree, id, content_x, content_y, content_w, content_h);
    } else {
        layoutAnchorChildren(tree, id, content_x, content_y, content_w, content_h);
    }
}

fn layoutFlexChildren(tree: *WidgetTree, parent_id: WidgetId, cx: f32, cy: f32, cw: f32, ch: f32) void {
    const parent = &tree.widgets[parent_id];
    const is_column = parent.flex_direction == .column;
    const main_size = if (is_column) ch else cw;
    const cross_size = if (is_column) cw else ch;

    // First pass: sum fixed sizes and flex-grow weights
    var total_fixed: f32 = 0;
    var total_grow: f32 = 0;
    var visible_count: f32 = 0;

    {
        var iter = tree.children(parent_id);
        while (iter.next()) |cid| {
            const child = &tree.widgets[cid];
            if (!child.active or !child.visible) continue;
            visible_count += 1;

            const child_main = if (is_column)
                resolveSizeSpec(child.height, ch, child.intrinsic_height) + child.margin.vertical()
            else
                resolveSizeSpec(child.width, cw, child.intrinsic_width) + child.margin.horizontal();

            if (child.flex_grow > 0) {
                total_grow += child.flex_grow;
            } else {
                total_fixed += child_main;
            }
        }
    }

    const gaps = if (visible_count > 1) (visible_count - 1) * parent.gap else 0;
    var remaining = main_size - total_fixed - gaps;
    if (remaining < 0) remaining = 0;

    // Second pass: position children
    var main_pos: f32 = switch (parent.justify) {
        .start => 0,
        .center => (main_size - total_fixed - gaps - (if (total_grow > 0) remaining else 0)) / 2.0,
        .end => main_size - total_fixed - gaps - (if (total_grow > 0) remaining else 0),
        .space_between => 0,
    };

    const space_between_gap = if (parent.justify == .space_between and visible_count > 1)
        (main_size - total_fixed) / (visible_count - 1)
    else
        parent.gap;

    {
        var first = true;
        var iter = tree.children(parent_id);
        while (iter.next()) |cid| {
            const child = &tree.widgets[cid];
            if (!child.active or !child.visible) continue;

            if (!first) main_pos += if (parent.justify == .space_between) space_between_gap else parent.gap;
            first = false;

            // Main axis size
            var child_main: f32 = undefined;
            if (child.flex_grow > 0 and total_grow > 0) {
                child_main = remaining * (child.flex_grow / total_grow);
            } else {
                child_main = if (is_column)
                    resolveSizeSpec(child.height, ch, child.intrinsic_height)
                else
                    resolveSizeSpec(child.width, cw, child.intrinsic_width);
            }

            // Cross axis size and alignment
            const child_cross_natural = if (is_column)
                resolveSizeSpec(child.width, cw, child.intrinsic_width)
            else
                resolveSizeSpec(child.height, ch, child.intrinsic_height);

            const child_cross = if (parent.cross_align == .stretch)
                cross_size - (if (is_column) child.margin.horizontal() else child.margin.vertical())
            else
                child_cross_natural;

            const cross_offset = switch (parent.cross_align) {
                .start => if (is_column) child.margin.left else child.margin.top,
                .center => (cross_size - child_cross) / 2.0,
                .end => cross_size - child_cross - (if (is_column) child.margin.right else child.margin.bottom),
                .stretch => if (is_column) child.margin.left else child.margin.top,
            };

            const main_margin = if (is_column) child.margin.top else child.margin.left;
            main_pos += main_margin;

            if (is_column) {
                child.computed_rect.x = cx + cross_offset;
                child.computed_rect.y = cy + main_pos;
                child.computed_rect.w = child_cross;
                child.computed_rect.h = child_main;
            } else {
                child.computed_rect.x = cx + main_pos;
                child.computed_rect.y = cy + cross_offset;
                child.computed_rect.w = child_main;
                child.computed_rect.h = child_cross;
            }

            main_pos += child_main + (if (is_column) child.margin.bottom else child.margin.right);

            // Recurse
            layoutWidget(tree, cid, child.computed_rect.w, child.computed_rect.h);
        }
    }
}

fn layoutAnchorChildren(tree: *WidgetTree, parent_id: WidgetId, cx: f32, cy: f32, cw: f32, ch: f32) void {
    var iter = tree.children(parent_id);
    while (iter.next()) |cid| {
        const child = &tree.widgets[cid];
        if (!child.active or !child.visible) continue;

        const child_w = resolveSizeSpec(child.width, cw, child.intrinsic_width);
        const child_h = resolveSizeSpec(child.height, ch, child.intrinsic_height);

        const base_x: f32 = switch (child.anchor_x) {
            .start => cx,
            .center => cx + (cw - child_w) / 2.0,
            .end => cx + cw - child_w,
        };

        const base_y: f32 = switch (child.anchor_y) {
            .start => cy,
            .center => cy + (ch - child_h) / 2.0,
            .end => cy + ch - child_h,
        };

        child.computed_rect.x = base_x + child.offset_x;
        child.computed_rect.y = base_y + child.offset_y;
        child.computed_rect.w = child_w;
        child.computed_rect.h = child_h;

        // Recurse
        layoutWidget(tree, cid, child_w, child_h);
    }
}

// ── Helpers ──

fn resolveSizeSpec(spec: Widget.SizeSpec, parent_size: f32, intrinsic: f32) f32 {
    return switch (spec) {
        .px => |v| v,
        .percent => |v| parent_size * v / 100.0,
        .auto => intrinsic,
        .fill => parent_size,
    };
}

fn resolveIntrinsicWidth(w: *const Widget.Widget) f32 {
    return switch (w.width) {
        .px => |v| v,
        else => w.intrinsic_width,
    };
}

fn resolveIntrinsicHeight(w: *const Widget.Widget) f32 {
    return switch (w.height) {
        .px => |v| v,
        else => w.intrinsic_height,
    };
}
