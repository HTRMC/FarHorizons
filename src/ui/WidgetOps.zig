const std = @import("std");
const Widget = @import("Widget.zig");
const WidgetId = Widget.WidgetId;
const NULL_WIDGET = Widget.NULL_WIDGET;
const Color = Widget.Color;
const WidgetTree = @import("WidgetTree.zig").WidgetTree;
const WidgetData = @import("WidgetData.zig");
const UiRenderer = @import("../renderer/vulkan/UiRenderer.zig").UiRenderer;
const TextRenderer = @import("../renderer/vulkan/TextRenderer.zig").TextRenderer;

/// Draw a widget and all its descendants.
pub fn drawWidget(
    tree: *const WidgetTree,
    id: WidgetId,
    ui: *UiRenderer,
    tr: *TextRenderer,
) void {
    const w = tree.getWidgetConst(id) orelse return;
    if (!w.visible) return;

    const r = w.computed_rect;
    const data = tree.getDataConst(id) orelse return;

    // Draw background (all widgets can have one)
    if (w.background.a > 0.01) {
        ui.drawRect(r.x, r.y, r.w, r.h, w.background.toArray());
    }

    // Draw border
    if (w.border_width > 0 and w.border_color.a > 0.01) {
        ui.drawRectOutline(r.x, r.y, r.w, r.h, w.border_width, w.border_color.toArray());
    }

    // Kind-specific drawing
    switch (w.kind) {
        .panel => {}, // Just background/border, already drawn

        .label => {
            const label = &data.label;
            const text = label.getText();
            if (text.len > 0) {
                const scale: f32 = @floatFromInt(label.font_size);
                const text_w = tr.measureText(text) * scale;
                const text_h: f32 = 16.0 * scale;
                // Center text within the widget
                const tx = r.x + w.padding.left + (r.w - w.padding.horizontal() - text_w) / 2.0;
                const ty = r.y + w.padding.top + (r.h - w.padding.vertical() - text_h) / 2.0;
                tr.drawText(tx, ty, text, label.color.toArray());
            }
        },

        .button => {
            const btn = &data.button;
            // Draw hover/press state overlay
            if (w.pressed) {
                ui.drawRect(r.x, r.y, r.w, r.h, btn.press_color.toArray());
            } else if (w.hovered) {
                ui.drawRect(r.x, r.y, r.w, r.h, btn.hover_color.toArray());
            }

            // Draw focus indicator
            if (w.focused) {
                ui.drawRectOutline(r.x, r.y, r.w, r.h, 1.0, Color.fromHex(0xFFCC00FF).toArray());
            }

            // Draw text centered
            const text = btn.getText();
            if (text.len > 0) {
                const text_w = tr.measureText(text);
                const tx = r.x + (r.w - text_w) / 2.0;
                const ty = r.y + (r.h - 16.0) / 2.0;
                tr.drawText(tx, ty, text, btn.text_color.toArray());
            }
        },

        .text_input => {
            const ti = @constCast(&data.text_input);
            // Draw input background
            ui.drawRect(r.x + 1, r.y + 1, r.w - 2, r.h - 2, Color.fromHex(0x222222FF).toArray());
            // Draw border
            const border_color = if (w.focused) Color.fromHex(0xFFCC00FF) else Color.fromHex(0x666666FF);
            ui.drawRectOutline(r.x, r.y, r.w, r.h, 1.0, border_color.toArray());

            const padding: f32 = 4;
            const content_area = r.w - padding * 2;

            // Set clip rect to content area for text/selection/cursor
            ui.setClipRect(r.x + padding, r.y, content_area, r.h);
            tr.setClipRect(r.x + padding, r.y, content_area, r.h);

            const text = ti.getText();
            if (text.len > 0) {
                const full_text_width = tr.measureText(text);
                const cursor_x_abs = tr.measureText(text[0..ti.cursor_pos]);

                // Auto-scroll so cursor stays visible
                if (cursor_x_abs - ti.scroll_offset > content_area) {
                    ti.scroll_offset = cursor_x_abs - content_area;
                }
                if (cursor_x_abs < ti.scroll_offset) {
                    ti.scroll_offset = cursor_x_abs;
                }
                const max_scroll = @max(full_text_width - content_area, 0);
                ti.scroll_offset = std.math.clamp(ti.scroll_offset, 0, max_scroll);

                const tx = r.x + padding - ti.scroll_offset;
                const ty = r.y + (r.h - 16.0) / 2.0;

                // Draw selection highlight behind text
                if (w.focused and ti.hasSelection()) {
                    const sel = ti.selectionRange();
                    const sel_x = tx + tr.measureText(text[0..sel.start]);
                    const sel_w = tr.measureText(text[0..sel.end]) - tr.measureText(text[0..sel.start]);
                    ui.drawRect(sel_x, ty, sel_w, 16, Color.fromHex(0x3366AA88).toArray());
                }

                tr.drawText(tx, ty, text, ti.text_color.toArray());

                // Draw cursor
                if (w.focused and (ti.cursor_blink_counter / 90) % 2 == 0) {
                    const cursor_x = tx + cursor_x_abs;
                    ui.drawRect(cursor_x, ty, 1, 16, Color.white.toArray());
                }
            } else {
                ti.scroll_offset = 0;
                if (ti.placeholder_len > 0) {
                    const tx = r.x + padding;
                    const ty = r.y + (r.h - 16.0) / 2.0;
                    tr.drawText(tx, ty, ti.placeholder[0..ti.placeholder_len], ti.placeholder_color.toArray());

                    if (w.focused and (ti.cursor_blink_counter / 90) % 2 == 0) {
                        ui.drawRect(r.x + padding, ty, 1, 16, Color.white.toArray());
                    }
                }
            }

            ui.clearClipRect();
            tr.clearClipRect();
        },

        .progress_bar => {
            const pb = &data.progress_bar;
            // Track
            ui.drawRect(r.x, r.y, r.w, r.h, pb.track_color.toArray());
            // Fill
            const fill_w = r.w * std.math.clamp(pb.value, 0.0, 1.0);
            if (fill_w > 0) {
                ui.drawRect(r.x, r.y, fill_w, r.h, pb.fill_color.toArray());
            }
        },

        .checkbox => {
            const cb = &data.checkbox;
            // Box
            ui.drawRect(r.x, r.y, r.w, r.h, cb.box_color.toArray());
            ui.drawRectOutline(r.x, r.y, r.w, r.h, 1.0, Color.fromHex(0x888888FF).toArray());
            // Check mark (simple filled inner rect)
            if (cb.checked) {
                const inset: f32 = 3;
                ui.drawRect(r.x + inset, r.y + inset, r.w - inset * 2, r.h - inset * 2, cb.check_color.toArray());
            }
            if (w.focused) {
                ui.drawRectOutline(r.x - 1, r.y - 1, r.w + 2, r.h + 2, 1.0, Color.fromHex(0xFFCC00FF).toArray());
            }
        },

        .slider => {
            const sl = &data.slider;
            const track_h: f32 = 4;
            const track_y = r.y + (r.h - track_h) / 2.0;
            // Track
            ui.drawRect(r.x, track_y, r.w, track_h, sl.track_color.toArray());
            // Fill
            const fill_frac = std.math.clamp((sl.value - sl.min_value) / (sl.max_value - sl.min_value), 0.0, 1.0);
            ui.drawRect(r.x, track_y, r.w * fill_frac, track_h, sl.fill_color.toArray());
            // Thumb
            const thumb_w: f32 = 8;
            const thumb_x = r.x + (r.w - thumb_w) * fill_frac;
            ui.drawRect(thumb_x, r.y, thumb_w, r.h, sl.thumb_color.toArray());
            if (w.focused) {
                ui.drawRectOutline(r.x - 1, r.y - 1, r.w + 2, r.h + 2, 1.0, Color.fromHex(0xFFCC00FF).toArray());
            }
        },

        .grid => {
            const g = &data.grid;
            // Draw grid cell outlines
            const cell_w = g.cell_size;
            const cell_h = g.cell_size;
            const base_x = r.x + w.padding.left;
            const base_y = r.y + w.padding.top;
            for (0..g.rows) |row| {
                for (0..g.columns) |col| {
                    const cx = base_x + @as(f32, @floatFromInt(col)) * (cell_w + g.cell_gap);
                    const cy = base_y + @as(f32, @floatFromInt(row)) * (cell_h + g.cell_gap);
                    ui.drawRectOutline(cx, cy, cell_w, cell_h, 1.0, Color.fromHex(0x555555FF).toArray());
                }
            }
        },

        .image => {
            // Phase 4: atlas sampling. For now, just tint-colored rect.
            const img = &data.image;
            if (img.tint.a > 0.01) {
                ui.drawRect(r.x, r.y, r.w, r.h, img.tint.toArray());
            }
        },

        .scroll_view, .list_view => {
            // Phase 4: scroll/clip support. For now, just draw children normally.
        },
    }

    // Draw children
    var iter = tree.children(id);
    while (iter.next()) |child_id| {
        drawWidget(tree, child_id, ui, tr);
    }
}
