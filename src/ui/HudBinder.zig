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
const Gamepad = @import("../Gamepad.zig");

const log = std.log.scoped(.UI);

const HOTBAR_SIZE = GameState.HOTBAR_SIZE;
const MAX_HINTS = 5;

pub const HudBinder = struct {
    crosshair_id: WidgetId = NULL_WIDGET,
    hotbar_bg_id: WidgetId = NULL_WIDGET,
    selection_id: WidgetId = NULL_WIDGET,
    offhand_id: WidgetId = NULL_WIDGET,
    block_name_id: WidgetId = NULL_WIDGET,
    health_bar_id: WidgetId = NULL_WIDGET,
    air_bar_id: WidgetId = NULL_WIDGET,
    slot_ids: [HOTBAR_SIZE]WidgetId = .{NULL_WIDGET} ** HOTBAR_SIZE,
    count_ids: [HOTBAR_SIZE]WidgetId = .{NULL_WIDGET} ** HOTBAR_SIZE,
    hints_panel_id: WidgetId = NULL_WIDGET,
    hint_group_ids: [MAX_HINTS]WidgetId = .{NULL_WIDGET} ** MAX_HINTS,
    hint_btn_ids: [MAX_HINTS]WidgetId = .{NULL_WIDGET} ** MAX_HINTS,
    hint_act_ids: [MAX_HINTS]WidgetId = .{NULL_WIDGET} ** MAX_HINTS,
    block_name_timer: f32 = 0,
    prev_selected_slot: u8 = 0,
    prev_selected_block: u16 = 0,

    pub fn init(tree: *WidgetTree) HudBinder {
        var self = HudBinder{};
        self.crosshair_id = tree.findById("crosshair") orelse NULL_WIDGET;
        self.hotbar_bg_id = tree.findById("hotbar_bg") orelse NULL_WIDGET;
        self.selection_id = tree.findById("selection") orelse NULL_WIDGET;
        self.offhand_id = tree.findById("offhand") orelse NULL_WIDGET;
        self.block_name_id = tree.findById("block_name") orelse NULL_WIDGET;
        self.health_bar_id = tree.findById("health_bar") orelse NULL_WIDGET;
        self.air_bar_id = tree.findById("air_bar") orelse NULL_WIDGET;

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

        self.hints_panel_id = tree.findById("gamepad_hints") orelse NULL_WIDGET;
        inline for (0..MAX_HINTS) |i| {
            self.hint_group_ids[i] = tree.findById(comptime std.fmt.comptimePrint("hint_group_{d}", .{i})) orelse NULL_WIDGET;
            self.hint_btn_ids[i] = tree.findById(comptime std.fmt.comptimePrint("hint_btn_{d}", .{i})) orelse NULL_WIDGET;
            self.hint_act_ids[i] = tree.findById(comptime std.fmt.comptimePrint("hint_act_{d}", .{i})) orelse NULL_WIDGET;
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

    pub fn update(self: *HudBinder, tree: *WidgetTree, gs: *const GameState, gamepad: *const Gamepad) void {
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
            const cur_block = selected_stack.block;

            // Reset timer when slot or item changes
            if (gs.selected_slot != self.prev_selected_slot or cur_block != self.prev_selected_block) {
                self.prev_selected_slot = gs.selected_slot;
                self.prev_selected_block = cur_block;
                if (!selected_stack.isEmpty()) {
                    self.block_name_timer = 2.0;
                }
            }

            // Tick down the timer
            if (self.block_name_timer > 0) {
                self.block_name_timer -= gs.delta_time;
                if (self.block_name_timer < 0) self.block_name_timer = 0;
            }

            const show = !selected_stack.isEmpty() and !gs.inventory_open and self.block_name_timer > 0;
            if (tree.getWidget(self.block_name_id)) |w| {
                w.visible = show;
            }
            if (show) {
                if (tree.getData(self.block_name_id)) |data| {
                    data.label.setText(GameState.itemName(cur_block));
                    // Fade out during last 0.5s
                    const alpha: f32 = if (self.block_name_timer < 0.5)
                        self.block_name_timer / 0.5
                    else
                        1.0;
                    data.label.color.a = alpha * (230.0 / 255.0);
                    data.label.shadow_color.a = alpha * (170.0 / 255.0);
                }
            }
        }

        self.updateHints(tree, gs, gamepad);
    }

    const Hint = struct {
        btn: Gamepad.Button,
        is_trigger: bool = false,
        trigger_left: bool = false,
        action: []const u8,
    };

    fn updateHints(self: *HudBinder, tree: *WidgetTree, gs: *const GameState, gamepad: *const Gamepad) void {
        const show = gamepad.connected();
        if (self.hints_panel_id != NULL_WIDGET) {
            if (tree.getWidget(self.hints_panel_id)) |w| {
                w.visible = show;
            }
        }
        if (!show) return;

        const ct = gamepad.controller_type;

        // Build hints based on game context
        var hints: [MAX_HINTS]?Hint = .{null} ** MAX_HINTS;

        if (gs.inventory_open) {
            hints[0] = .{ .btn = .a, .action = "Select" };
            hints[1] = .{ .btn = .b, .action = "Close" };
        } else {
            hints[0] = .{ .btn = .y, .action = "Inventory" };
            hints[1] = .{ .btn = .x, .action = "Crafting" };
            hints[2] = .{ .is_trigger = true, .trigger_left = true, .btn = .a, .action = "Place" };
            hints[3] = .{ .is_trigger = true, .trigger_left = false, .btn = .a, .action = "Mine" };
            hints[4] = .{ .btn = .left_bumper, .action = "Pick Block" };
        }

        for (0..MAX_HINTS) |i| {
            const group_id = self.hint_group_ids[i];
            if (group_id == NULL_WIDGET) continue;

            if (hints[i]) |hint| {
                if (tree.getWidget(group_id)) |w| w.visible = true;

                // Button label text
                const btn_id = self.hint_btn_ids[i];
                if (btn_id != NULL_WIDGET) {
                    if (tree.getData(btn_id)) |data| {
                        var buf: [16]u8 = undefined;
                        const label = if (hint.is_trigger)
                            ct.triggerLabel(hint.trigger_left)
                        else
                            ct.buttonLabel(hint.btn);
                        const text = std.fmt.bufPrint(&buf, "[{s}]", .{label}) catch "";
                        data.label.setText(text);
                        data.label.color = if (hint.is_trigger)
                            Color.white
                        else
                            buttonColor(ct, hint.btn);
                    }
                }

                // Action label text
                const act_id = self.hint_act_ids[i];
                if (act_id != NULL_WIDGET) {
                    if (tree.getData(act_id)) |data| {
                        data.label.setText(hint.action);
                    }
                }
            } else {
                if (tree.getWidget(group_id)) |w| w.visible = false;
            }
        }
    }

    fn buttonColor(ct: Gamepad.ControllerType, btn: Gamepad.Button) Color {
        return switch (ct) {
            .playstation => switch (btn) {
                .a => Color.fromHex(0x6699FFFF), // X - blue
                .b => Color.fromHex(0xFF6666FF), // O - red
                .x => Color.fromHex(0xFF88CCFF), // Square - pink
                .y => Color.fromHex(0x66DD99FF), // Triangle - green
                else => Color.white,
            },
            .xbox => switch (btn) {
                .a => Color.fromHex(0x66CC66FF), // A - green
                .b => Color.fromHex(0xFF6666FF), // B - red
                .x => Color.fromHex(0x6699FFFF), // X - blue
                .y => Color.fromHex(0xFFCC44FF), // Y - yellow
                else => Color.white,
            },
            else => Color.white,
        };
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
