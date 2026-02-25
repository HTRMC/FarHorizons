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
                if (label.wrap) {
                    const avail_w = r.w - w.padding.horizontal();
                    const tx = r.x + w.padding.left;
                    const ty = r.y + w.padding.top;
                    _ = tr.drawTextWrapped(tx, ty, text, avail_w, label.color.toArray());
                } else {
                    const scale: f32 = @floatFromInt(label.font_size);
                    const text_w = tr.measureText(text) * scale;
                    const text_h: f32 = 16.0 * scale;
                    // Center text within the widget
                    const tx = r.x + w.padding.left + (r.w - w.padding.horizontal() - text_w) / 2.0;
                    const ty = r.y + w.padding.top + (r.h - w.padding.vertical() - text_h) / 2.0;
                    tr.drawText(tx, ty, text, label.color.toArray());
                }
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
            const img = &data.image;
            // Check if we have atlas UVs to sample from
            if (img.atlas_w > 0 and img.atlas_h > 0) {
                ui.drawTexturedRect(r.x, r.y, r.w, r.h, img.atlas_u, img.atlas_v, img.atlas_u + img.atlas_w, img.atlas_v + img.atlas_h, img.tint.toArray());
            } else if (img.tint.a > 0.01) {
                ui.drawRect(r.x, r.y, r.w, r.h, img.tint.toArray());
            }
        },

        .dropdown => {
            const dd = &data.dropdown;
            // Draw closed state: background + selected item text + ▼ indicator
            if (w.pressed) {
                ui.drawRect(r.x, r.y, r.w, r.h, Color.fromHex(0x222222FF).toArray());
            } else if (w.hovered) {
                ui.drawRect(r.x, r.y, r.w, r.h, Color.fromHex(0x444444FF).toArray());
            }

            if (w.focused) {
                ui.drawRectOutline(r.x, r.y, r.w, r.h, 1.0, Color.fromHex(0xFFCC00FF).toArray());
            }

            // Draw selected item text
            const selected_text = dd.getSelectedText();
            if (selected_text.len > 0) {
                const tx = r.x + 6;
                const ty = r.y + (r.h - 16.0) / 2.0;
                tr.drawText(tx, ty, selected_text, dd.text_color.toArray());
            }

            // Draw ▼ indicator (just a small "v" text for now)
            const arrow_x = r.x + r.w - 16;
            const arrow_y = r.y + (r.h - 16.0) / 2.0;
            tr.drawText(arrow_x, arrow_y, "v", dd.text_color.toArray());
        },

        .scroll_view => {
            // Clip children to viewport, draw scroll bar
            const sv = &@constCast(data).scroll_view;
            const vp_x = r.x + w.padding.left;
            const vp_y = r.y + w.padding.top;
            const vp_w = r.w - w.padding.horizontal();
            const vp_h = r.h - w.padding.vertical();

            ui.pushClipRect(vp_x, vp_y, vp_w, vp_h);
            tr.pushClipRect(vp_x, vp_y, vp_w, vp_h);

            // Draw children (already offset by layout)
            var iter2 = tree.children(id);
            while (iter2.next()) |child_id| {
                drawWidget(tree, child_id, ui, tr);
            }

            ui.popClipRect();
            tr.popClipRect();

            // Draw scroll bar
            if (sv.scroll_bar_visible and sv.content_height > vp_h) {
                const bar_w: f32 = 6;
                const bar_x = r.x + r.w - bar_w;
                const visible_ratio = vp_h / sv.content_height;
                const thumb_h = @max(vp_h * visible_ratio, 16);
                const max_scroll = sv.content_height - vp_h;
                const scroll_frac = if (max_scroll > 0) sv.scroll_y / max_scroll else 0;
                const thumb_y = vp_y + (vp_h - thumb_h) * scroll_frac;

                // Track
                ui.drawRect(bar_x, vp_y, bar_w, vp_h, Color.fromHex(0x22222288).toArray());
                // Thumb
                ui.drawRect(bar_x, thumb_y, bar_w, thumb_h, Color.fromHex(0x888888CC).toArray());
            }

            return; // Children already drawn above
        },

        .list_view => {
            const lv = &@constCast(data).list_view;
            const vp_x = r.x + w.padding.left;
            const vp_y = r.y + w.padding.top;
            const vp_w = r.w - w.padding.horizontal();
            const vp_h = r.h - w.padding.vertical();

            ui.pushClipRect(vp_x, vp_y, vp_w, vp_h);
            tr.pushClipRect(vp_x, vp_y, vp_w, vp_h);

            // Draw selection highlight
            if (lv.item_count > 0) {
                const sel_y = vp_y + @as(f32, @floatFromInt(lv.selected_index)) * lv.item_height - lv.scroll_offset;
                if (sel_y + lv.item_height > vp_y and sel_y < vp_y + vp_h) {
                    ui.drawRect(vp_x, sel_y, vp_w, lv.item_height, lv.selection_color.toArray());
                }
            }

            // Draw children (skip those outside viewport for virtual rendering)
            var child_idx: u16 = 0;
            var iter2 = tree.children(id);
            while (iter2.next()) |child_id| {
                const child_w = tree.getWidgetConst(child_id) orelse continue;
                const child_bottom = child_w.computed_rect.y + child_w.computed_rect.h;
                const child_top = child_w.computed_rect.y;

                // Only draw if visible in viewport
                if (child_bottom > vp_y and child_top < vp_y + vp_h) {
                    drawWidget(tree, child_id, ui, tr);
                }
                child_idx += 1;
            }

            ui.popClipRect();
            tr.popClipRect();

            // Draw scroll bar if content overflows
            const total_h = @as(f32, @floatFromInt(lv.item_count)) * lv.item_height;
            if (total_h > vp_h) {
                const bar_w: f32 = 6;
                const bar_x = r.x + r.w - bar_w;
                const visible_ratio = vp_h / total_h;
                const thumb_h = @max(vp_h * visible_ratio, 16);
                const max_scroll = total_h - vp_h;
                const scroll_frac = if (max_scroll > 0) lv.scroll_offset / max_scroll else 0;
                const thumb_y = vp_y + (vp_h - thumb_h) * scroll_frac;

                ui.drawRect(bar_x, vp_y, bar_w, vp_h, Color.fromHex(0x22222288).toArray());
                ui.drawRect(bar_x, thumb_y, bar_w, thumb_h, Color.fromHex(0x888888CC).toArray());
            }

            return; // Children already drawn above
        },
    }

    // Draw children
    var iter = tree.children(id);
    while (iter.next()) |child_id| {
        drawWidget(tree, child_id, ui, tr);
    }
}

/// Draw overlays: open dropdowns, tooltips. Called after all widgets are drawn.
pub fn drawOverlays(
    tree: *const WidgetTree,
    ui: *UiRenderer,
    tr: *TextRenderer,
    tooltip_widget: WidgetId,
    mouse_x: f32,
    mouse_y: f32,
    screen_w: f32,
    screen_h: f32,
) void {
    // Draw open dropdown overlays
    for (0..tree.count) |i| {
        const id: WidgetId = @intCast(i);
        const w = tree.getWidgetConst(id) orelse continue;
        if (w.kind != .dropdown or !w.visible) continue;

        const data = tree.getDataConst(id) orelse continue;
        const dd = &data.dropdown;
        if (!dd.open) continue;

        const r = w.computed_rect;
        const item_h: f32 = 28;
        const list_h = @as(f32, @floatFromInt(dd.item_count)) * item_h;

        // Position below dropdown, clamp to screen
        var list_y = r.y + r.h;
        if (list_y + list_h > screen_h) {
            list_y = r.y - list_h; // flip above
        }

        // Background
        ui.drawRect(r.x, list_y, r.w, list_h, dd.item_bg.toArray());
        ui.drawRectOutline(r.x, list_y, r.w, list_h, 1.0, Color.fromHex(0x666666FF).toArray());

        // Draw each option
        for (0..dd.item_count) |j| {
            const iy = list_y + @as(f32, @floatFromInt(j)) * item_h;
            const item_text = dd.items[j][0..dd.item_lens[j]];

            // Hover highlight
            if (j == dd.hovered_item) {
                ui.drawRect(r.x, iy, r.w, item_h, dd.hover_color.toArray());
            }

            // Text
            if (item_text.len > 0) {
                const tx = r.x + 6;
                const ty = iy + (item_h - 16.0) / 2.0;
                tr.drawText(tx, ty, item_text, dd.text_color.toArray());
            }
        }
    }

    // Draw tooltip
    if (tooltip_widget != NULL_WIDGET) {
        const tw = tree.getWidgetConst(tooltip_widget) orelse return;
        if (tw.tooltip_len == 0) return;

        const tip_text = tw.tooltip[0..tw.tooltip_len];
        const text_w = tr.measureText(tip_text);
        const pad: f32 = 4;
        const tip_w = text_w + pad * 2;
        const tip_h: f32 = 16 + pad * 2;

        // Position near cursor, clamp to screen
        var tx = mouse_x + 12;
        var ty = mouse_y + 16;
        if (tx + tip_w > screen_w) tx = screen_w - tip_w;
        if (ty + tip_h > screen_h) ty = mouse_y - tip_h - 4;
        if (tx < 0) tx = 0;
        if (ty < 0) ty = 0;

        // Background
        ui.drawRect(tx, ty, tip_w, tip_h, Color.fromHex(0x222233EE).toArray());
        // Text
        tr.drawText(tx + pad, ty + pad, tip_text, Color.white.toArray());
    }
}
