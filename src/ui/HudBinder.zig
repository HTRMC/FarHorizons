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

const log = std.log.scoped(.UI);

const HOTBAR_SIZE = GameState.HOTBAR_SIZE;

pub const HudBinder = struct {
    crosshair_id: WidgetId = NULL_WIDGET,
    hotbar_bg_id: WidgetId = NULL_WIDGET,
    selection_id: WidgetId = NULL_WIDGET,
    offhand_id: WidgetId = NULL_WIDGET,
    block_name_id: WidgetId = NULL_WIDGET,
    slot_ids: [HOTBAR_SIZE]WidgetId = .{NULL_WIDGET} ** HOTBAR_SIZE,

    pub fn init(tree: *const WidgetTree) HudBinder {
        var self = HudBinder{};
        self.crosshair_id = tree.findById("crosshair") orelse NULL_WIDGET;
        self.hotbar_bg_id = tree.findById("hotbar_bg") orelse NULL_WIDGET;
        self.selection_id = tree.findById("selection") orelse NULL_WIDGET;
        self.offhand_id = tree.findById("offhand") orelse NULL_WIDGET;
        self.block_name_id = tree.findById("block_name") orelse NULL_WIDGET;

        inline for (0..HOTBAR_SIZE) |i| {
            const name = comptime std.fmt.comptimePrint("slot_{d}", .{i});
            self.slot_ids[i] = tree.findById(name) orelse NULL_WIDGET;
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
        if (self.selection_id != NULL_WIDGET) {
            if (tree.getWidget(self.selection_id)) |w| {
                const slot_pitch: f32 = 40.0;
                w.offset_x = @as(f32, @floatFromInt(gs.selected_slot)) * slot_pitch - 2.0;
            }
        }

        for (0..HOTBAR_SIZE) |i| {
            if (self.slot_ids[i] != NULL_WIDGET) {
                if (tree.getWidget(self.slot_ids[i])) |w| {
                    const block = gs.hotbar[i];
                    if (block != .air) {
                        const c = GameState.blockColor(block);
                        w.background = .{ .r = c[0], .g = c[1], .b = c[2], .a = c[3] };
                    } else {
                        w.background = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
                    }
                }
            }
        }

        if (self.block_name_id != NULL_WIDGET) {
            const selected_block = gs.hotbar[gs.selected_slot];
            if (tree.getWidget(self.block_name_id)) |w| {
                w.visible = (selected_block != .air);
            }
            if (selected_block != .air) {
                if (tree.getData(self.block_name_id)) |data| {
                    data.label.setText(GameState.blockName(selected_block));
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
