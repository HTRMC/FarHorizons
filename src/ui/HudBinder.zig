const std = @import("std");
const Widget = @import("Widget.zig");
const WidgetId = Widget.WidgetId;
const NULL_WIDGET = Widget.NULL_WIDGET;
const Color = Widget.Color;
const WidgetTree = @import("WidgetTree.zig").WidgetTree;
const ui_renderer_mod = @import("../renderer/vulkan/UiRenderer.zig");
const UiRenderer = ui_renderer_mod.UiRenderer;
const SpriteRect = ui_renderer_mod.SpriteRect;
const GameState = @import("../GameState.zig");
const WorldState = @import("../world/WorldState.zig");
const BlockState = WorldState.BlockState;

const log = std.log.scoped(.UI);

const HOTBAR_SIZE = GameState.HOTBAR_SIZE;

pub const HudBinder = struct {
    crosshair_id: WidgetId = NULL_WIDGET,
    hotbar_bg_id: WidgetId = NULL_WIDGET,
    selection_id: WidgetId = NULL_WIDGET,
    offhand_id: WidgetId = NULL_WIDGET,
    block_name_id: WidgetId = NULL_WIDGET,
    health_bar_id: WidgetId = NULL_WIDGET,
    air_bar_id: WidgetId = NULL_WIDGET,
    break_bar_id: WidgetId = NULL_WIDGET,
    slot_ids: [HOTBAR_SIZE]WidgetId = .{NULL_WIDGET} ** HOTBAR_SIZE,
    count_ids: [HOTBAR_SIZE]WidgetId = .{NULL_WIDGET} ** HOTBAR_SIZE,

    pub fn init(tree: *WidgetTree) HudBinder {
        var self = HudBinder{};
        self.crosshair_id = tree.findById("crosshair") orelse NULL_WIDGET;
        self.hotbar_bg_id = tree.findById("hotbar_bg") orelse NULL_WIDGET;
        self.selection_id = tree.findById("selection") orelse NULL_WIDGET;
        self.offhand_id = tree.findById("offhand") orelse NULL_WIDGET;
        self.block_name_id = tree.findById("block_name") orelse NULL_WIDGET;
        self.health_bar_id = tree.findById("health_bar") orelse NULL_WIDGET;
        self.air_bar_id = tree.findById("air_bar") orelse NULL_WIDGET;
        self.break_bar_id = tree.findById("break_bar") orelse NULL_WIDGET;

        inline for (0..HOTBAR_SIZE) |i| {
            const name = comptime std.fmt.comptimePrint("slot_{d}", .{i});
            const id = tree.findById(name) orelse NULL_WIDGET;
            self.slot_ids[i] = id;
            if (id != NULL_WIDGET) {
                if (tree.getData(id)) |data| {
                    data.panel.draw_isometric = true;
                }
            }

            const count_name = comptime std.fmt.comptimePrint("count_{d}", .{i});
            self.count_ids[i] = tree.findById(count_name) orelse NULL_WIDGET;
        }

        return self;
    }

    pub fn resolveSprites(self: *const HudBinder, tree: *WidgetTree, ui_renderer: *const UiRenderer) void {
        if (!ui_renderer.hud_atlas_loaded) return;

        setImageAtlas(tree, self.crosshair_id, ui_renderer.crosshair_rect);
        setImageAtlas(tree, self.hotbar_bg_id, ui_renderer.hotbar_rect);
        setImageAtlas(tree, self.selection_id, ui_renderer.selection_rect);
        setImageAtlas(tree, self.offhand_id, ui_renderer.offhand_rect);
    }

    pub fn update(self: *const HudBinder, tree: *WidgetTree, gs: *const GameState) void {
        // Hide crosshair in third person unless explicitly enabled
        if (self.crosshair_id != NULL_WIDGET) {
            if (tree.getWidget(self.crosshair_id)) |w| {
                w.visible = !gs.third_person or gs.third_person_crosshair;
            }
        }

        if (self.selection_id != NULL_WIDGET) {
            if (tree.getWidget(self.selection_id)) |w| {
                const slot_pitch: f32 = 50.0;
                w.offset_x = @as(f32, @floatFromInt(gs.selected_slot)) * slot_pitch - 2.0;
            }
        }

        // Break progress bar
        if (self.break_bar_id != NULL_WIDGET) {
            if (tree.getWidget(self.break_bar_id)) |w| {
                w.visible = gs.break_progress > 0;
            }
            if (gs.break_progress > 0) {
                if (tree.getData(self.break_bar_id)) |data| {
                    data.progress_bar.value = gs.break_progress;
                }
            }
        }

        for (0..HOTBAR_SIZE) |i| {
            const id = self.slot_ids[i];
            const stack = gs.playerInv().hotbar[i];
            if (id != NULL_WIDGET) {
                if (tree.getWidget(id)) |w| {
                    if (!stack.isEmpty()) {
                        const c = GameState.itemColor(stack.block);
                        w.background = .{ .r = c[0], .g = c[1], .b = c[2], .a = c[3] };
                        if (tree.getData(id)) |data| {
                            data.panel.block_state = if (stack.isTool())
                                BlockState.defaultState(.air)
                            else
                                BlockState.getDisplayState(stack.block);
                        }
                    } else {
                        w.background = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
                        if (tree.getData(id)) |data| {
                            data.panel.block_state = BlockState.defaultState(.air);
                        }
                    }
                }
            }

            // Update stack count label
            const cid = self.count_ids[i];
            if (cid != NULL_WIDGET) {
                if (tree.getWidget(cid)) |cw| {
                    if (!stack.isEmpty() and stack.count > 1) {
                        cw.visible = true;
                        if (tree.getData(cid)) |data| {
                            var buf: [4]u8 = undefined;
                            const text = std.fmt.bufPrint(&buf, "{d}", .{stack.count}) catch "?";
                            data.label.setText(text);
                        }
                    } else {
                        cw.visible = false;
                    }
                }
            }
        }

        // Health bar: visible in survival mode
        if (self.health_bar_id != NULL_WIDGET) {
            if (tree.getWidget(self.health_bar_id)) |w| {
                w.visible = gs.game_mode == .survival;
            }
            if (gs.game_mode == .survival) {
                if (tree.getData(self.health_bar_id)) |data| {
                    data.progress_bar.value = gs.health / gs.max_health;
                }
            }
        }

        // Air bar: visible in survival when air is depleting
        if (self.air_bar_id != NULL_WIDGET) {
            if (tree.getWidget(self.air_bar_id)) |w| {
                w.visible = gs.game_mode == .survival and gs.air_supply < gs.max_air;
            }
            if (gs.game_mode == .survival and gs.air_supply < gs.max_air) {
                if (tree.getData(self.air_bar_id)) |data| {
                    data.progress_bar.value = @as(f32, @floatFromInt(gs.air_supply)) / @as(f32, @floatFromInt(gs.max_air));
                }
            }
        }

        if (self.block_name_id != NULL_WIDGET) {
            const selected_stack = gs.playerInv().hotbar[gs.selected_slot];
            if (tree.getWidget(self.block_name_id)) |w| {
                w.visible = !selected_stack.isEmpty();
            }
            if (!selected_stack.isEmpty()) {
                if (tree.getData(self.block_name_id)) |data| {
                    data.label.setText(GameState.itemName(selected_stack.block));
                }
            }
        }
    }

    fn setImageAtlas(tree: *WidgetTree, id: WidgetId, rect: SpriteRect) void {
        if (id == NULL_WIDGET) return;
        const data = tree.getData(id) orelse return;
        data.image.atlas_u = rect.u0;
        data.image.atlas_v = rect.v0;
        data.image.atlas_w = rect.u1 - rect.u0;
        data.image.atlas_h = rect.v1 - rect.v0;
    }
};
